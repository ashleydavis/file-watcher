//
// The native backend for Linux and Android. inotify reports changes to the entries of each
// watched directory, by name, so one watch per directory covers every file in it.
//

const std = @import("std");
const hints_module = @import("hints.zig");

const assert = std.debug.assert;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const HintSet = hints_module.HintSet;
const IN = linux.IN;

//
// The changes inotify reports for each watched directory: entries created, deleted, renamed or
// written, metadata changes, and the directory itself being deleted or moved. Symbolic links
// are not followed and events for unlinked files are dropped, matching how the snapshot reads
// entries.
//
const watch_mask: u32 = IN.CREATE | IN.DELETE | IN.MODIFY | IN.ATTRIB | IN.CLOSE_WRITE |
    IN.MOVED_FROM | IN.MOVED_TO | IN.DELETE_SELF | IN.MOVE_SELF | IN.ONLYDIR |
    IN.DONT_FOLLOW | IN.EXCL_UNLINK;

//
// The size of the buffer events are read into. 64 KiB holds hundreds of events, so a burst of
// changes is drained in a few reads.
//
const read_buffer_size: u32 = 64 * 1024;

//
// The most reads in one wait. It bounds the work of one batch; events left in the kernel queue
// are read in the next batch.
//
const reads_per_wait_max: u32 = 64;

comptime {
    assert(read_buffer_size >= @sizeOf(linux.inotify_event) + std.fs.max_name_bytes + 1);
    assert(@sizeOf(linux.inotify_event) == 16);
}

//
// An inotify instance and the directories it watches.
//
pub const Inotify = struct {
    //
    // inotify watches one directory at a time, so the watcher adds every directory.
    //
    pub const is_recursive = false;

    //
    // A directory watch reports changes to the files in it, so files need no watch of their own.
    //
    pub const watches_files = false;

    //
    // Allocates the path maps.
    //
    gpa: Allocator,

    //
    // The inotify file descriptor.
    //
    fd: i32,

    //
    // The path of each watch descriptor, owned by this map.
    //
    paths: std.AutoHashMapUnmanaged(i32, []const u8),

    //
    // The watch descriptor of each path. Keys are borrowed from `paths`.
    //
    descriptors: std.StringHashMapUnmanaged(i32),

    //
    // Events are read into this buffer, aligned for the event header.
    //
    buffer: [read_buffer_size]u8 align(@alignOf(linux.inotify_event)),

    //
    // Opens an inotify instance, in place because the read buffer is large.
    //
    pub fn init(self: *Inotify, gpa: Allocator) !void {
        const rc = linux.inotify_init1(IN.NONBLOCK | IN.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        self.gpa = gpa;
        self.fd = @intCast(rc);
        self.paths = .empty;
        self.descriptors = .empty;
        assert(self.fd >= 0);
    }

    //
    // Closes the instance, which drops every watch.
    //
    pub fn deinit(self: *Inotify) void {
        assert(self.fd >= 0);
        _ = linux.close(self.fd);
        var paths = self.paths.valueIterator();
        while (paths.next()) |path| {
            self.gpa.free(path.*);
        }
        self.paths.deinit(self.gpa);
        self.descriptors.deinit(self.gpa);
        self.* = undefined;
    }

    //
    // Starts watching the directory at `path`. Returns false when the kernel reused an existing
    // watch, which happens when a watched directory was moved to `path`; the watch then moves
    // to the new path and no extra watch is used.
    //
    pub fn watch(self: *Inotify, path: []const u8, is_directory: bool) !bool {
        assert(is_directory);
        assert(path.len > 0);
        try self.paths.ensureUnusedCapacity(self.gpa, 1);
        try self.descriptors.ensureUnusedCapacity(self.gpa, 1);
        const path_z = try std.posix.toPosixPath(path);
        const rc = linux.inotify_add_watch(self.fd, &path_z, watch_mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOSPC => return error.LimitReached,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        const descriptor: i32 = @intCast(rc);
        const owned = self.gpa.dupe(u8, path) catch |err| {
            if (!self.paths.contains(descriptor)) {
                _ = linux.inotify_rm_watch(self.fd, descriptor);
            }
            return err;
        };
        const is_new = !self.paths.contains(descriptor);
        if (self.paths.fetchRemove(descriptor)) |old| {
            _ = self.descriptors.remove(old.value);
            self.gpa.free(old.value);
        }
        self.paths.putAssumeCapacityNoClobber(descriptor, owned);
        self.descriptors.putAssumeCapacityNoClobber(owned, descriptor);
        assert(self.paths.count() == self.descriptors.count());
        return is_new;
    }

    //
    // Stops watching the directory at `path`. Returns false when the path had no watch of its
    // own, for example because its watch moved to another path.
    //
    pub fn unwatch(self: *Inotify, path: []const u8) bool {
        assert(path.len > 0);
        const entry = self.descriptors.fetchRemove(path) orelse return false;
        const removed = self.paths.fetchRemove(entry.value).?;
        const rc = linux.inotify_rm_watch(self.fd, entry.value);
        switch (linux.errno(rc)) {
            // The kernel already dropped the watch because the directory was deleted.
            .SUCCESS, .INVAL => {},
            else => unreachable,
        }
        self.gpa.free(removed.value);
        assert(self.paths.count() == self.descriptors.count());
        return true;
    }

    //
    // Waits up to `timeout_ms` for changes and records the paths they touch in `hints`.
    //
    pub fn wait(self: *Inotify, timeout_ms: u32, hints: *HintSet) !void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const ready = try std.posix.poll(&poll_fds, timeout);
        if (ready == 0) {
            return;
        }
        var reads: u32 = 0;
        while (reads < reads_per_wait_max) : (reads += 1) {
            const count = std.posix.read(self.fd, &self.buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            assert(count > 0);
            try decode_events(self.buffer[0..count], &self.paths, hints);
        }
    }
};

//
// Turns a buffer of raw inotify events into hints. Pure, so it is tested with built buffers.
//
pub fn decode_events(
    buffer: []align(@alignOf(linux.inotify_event)) const u8,
    paths: *const std.AutoHashMapUnmanaged(i32, []const u8),
    hints: *HintSet,
) !void {
    const header_size = @sizeOf(linux.inotify_event);
    var offset: usize = 0;
    while (offset < buffer.len) {
        assert(offset + header_size <= buffer.len);
        const header: *const linux.inotify_event = @ptrCast(@alignCast(buffer[offset..].ptr));
        const name_start = offset + header_size;
        const name_end = name_start + header.len;
        assert(name_end <= buffer.len);
        offset = name_end;

        if (header.mask & IN.Q_OVERFLOW != 0) {
            var all = paths.valueIterator();
            while (all.next()) |path| {
                try hints.add(path.*, .directory);
            }
            continue;
        }
        if (header.mask & IN.IGNORED != 0) {
            continue;
        }
        const path = paths.get(header.wd) orelse continue;
        const name = std.mem.sliceTo(buffer[name_start..name_end], 0);
        if (name.len == 0) {
            try hints.add(path, .entry);
        } else {
            try hints.add_child(path, name, .entry);
        }
    }
    assert(offset == buffer.len);
}

test {
    _ = @import("inotify.test.zig");
}
