//
// The native backend for Linux. inotify reports changes to the entries of each
// watched directory, by name, so one watch per directory covers every file in it.
//

const std = @import("std");
const hints_module = @import("hints.zig");
const paths_module = @import("paths.zig");

const assert = std.debug.assert;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const HintSet = hints_module.HintSet;
const IN = linux.IN;

//
// The changes inotify reports for each watched directory: entries created, deleted, renamed or
// written, metadata changes, and the directory itself being deleted or moved. Symbolic links
// are not followed and events for unlinked files are dropped.
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
    // Allocates the path maps.
    //
    gpa: Allocator,

    //
    // The inotify file descriptor.
    //
    fd: i32,

    //
    // An eventfd that `wake` writes to. `wait` polls it beside the inotify descriptor, so a
    // write from another thread ends the wait at once.
    //
    wake_fd: i32,

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
        const result = linux.errno(rc);
        if (result != .SUCCESS) {
            return init_error(result);
        }
        const fd: i32 = @intCast(rc);
        const wake_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        const wake_result = linux.errno(wake_rc);
        if (wake_result != .SUCCESS) {
            _ = linux.close(fd);
            return init_error(wake_result);
        }
        self.gpa = gpa;
        self.fd = fd;
        self.wake_fd = @intCast(wake_rc);
        self.paths = .empty;
        self.descriptors = .empty;
        assert(self.fd >= 0);
        assert(self.wake_fd >= 0);
    }

    //
    // Closes the instance, which drops every watch.
    //
    pub fn deinit(self: *Inotify) void {
        assert(self.fd >= 0);
        _ = linux.close(self.fd);
        _ = linux.close(self.wake_fd);
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
        const result = linux.errno(rc);
        if (result != .SUCCESS) {
            return watch_error(result);
        }
        const descriptor: i32 = @intCast(rc);
        const owned = self.gpa.dupe(u8, path) catch |err| {
            // Drop the watch the kernel just added, unless it belongs to another path. Its result
            // is not needed: the watch is dropped either way when the instance closes.
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
    // The number of directories watched.
    pub fn watch_count(self: *const Inotify) u32 {
        return @intCast(self.descriptors.count());
    }

    // Stops watching the directory at `path` and every directory under it.
    pub fn unwatch_tree(self: *Inotify, path: []const u8) !void {
        assert(path.len > 0);
        var under: std.ArrayList([]const u8) = .empty;
        defer under.deinit(self.gpa);
        var keys = self.descriptors.keyIterator();
        while (keys.next()) |key| {
            if (paths_module.is_within(key.*, path)) {
                try under.append(self.gpa, key.*);
            }
        }
        // `unwatch` frees each path after looking it up, and no path is used after its removal.
        for (under.items) |watched| {
            assert(self.unwatch(watched));
        }
    }

    // Stops watching the directory at `path`. Returns false when the path had no watch of its
    // own, for example because its watch moved to another path.
    //
    pub fn unwatch(self: *Inotify, path: []const u8) bool {
        assert(path.len > 0);
        const entry = self.descriptors.fetchRemove(path) orelse return false;
        const removed = self.paths.fetchRemove(entry.value).?;
        // The kernel reports an invalid watch when it already dropped the watch because the
        // directory was deleted.
        const result = linux.errno(linux.inotify_rm_watch(self.fd, entry.value));
        if (result != .SUCCESS) assert(result == .INVAL);
        self.gpa.free(removed.value);
        assert(self.paths.count() == self.descriptors.count());
        return true;
    }

    //
    // Ends a `wait` running on another thread, or the next one to start, at once. Writing to an
    // eventfd is safe from any thread and from a signal handler.
    //
    pub fn wake(self: *Inotify) void {
        const one = std.mem.toBytes(@as(u64, 1));
        const rc = linux.write(self.wake_fd, &one, one.len);
        // The write fails only when the counter is full, in which case a wake is pending anyway.
        if (linux.errno(rc) != .SUCCESS) assert(linux.errno(rc) == .AGAIN);
    }

    //
    // Waits up to `timeout_ms` for changes and records the paths they touch in `hints`.
    //
    pub fn wait(self: *Inotify, timeout_ms: u32, hints: *HintSet) !void {
        var poll_fds = [_]std.posix.pollfd{
            .{
                .fd = self.fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = self.wake_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const timeout: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const ready = try std.posix.poll(&poll_fds, timeout);
        if (ready == 0) {
            return;
        }
        if (poll_fds[1].revents != 0) {
            // Reading the counter clears it, so the next wait blocks again.
            var counter: [8]u8 = undefined;
            _ = std.posix.read(self.wake_fd, &counter) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
        }
        var reads: u32 = 0;
        while (reads < reads_per_wait_max) : (reads += 1) {
            const count = std.posix.read(self.fd, &self.buffer) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            assert(count > 0);
            try decode_events(self.buffer[0..count], &self.paths, &self.descriptors, hints);
        }
    }
};

//
// Turns the error number of a failed `inotify_init1` or `eventfd` into an error.
//
pub fn init_error(result: linux.E) anyerror {
    assert(result != .SUCCESS);
    return switch (result) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

//
// Turns the error number of a failed `inotify_add_watch` into an error. Running out of watches
// is `LimitReached`, which tells the watcher to poll from then on.
//
pub fn watch_error(result: linux.E) anyerror {
    assert(result != .SUCCESS);
    return switch (result) {
        .NOSPC => error.LimitReached,
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

//
// Turns a buffer of raw inotify events into hints. A directory created or moved in is a
// `directory` hint, so it and what it holds get watches; one deleted or moved away is a `gone`
// hint, so its watches are dropped; anything else is an `entry` hint. A watch the kernel dropped,
// because its directory was deleted, is a `gone` hint too. When the kernel's queue overflowed,
// every watched tree is checked. Pure, so it is tested with built buffers.
//
pub fn decode_events(
    buffer: []align(@alignOf(linux.inotify_event)) const u8,
    paths: *const std.AutoHashMapUnmanaged(i32, []const u8),
    descriptors: *const std.StringHashMapUnmanaged(i32),
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
            try add_tops(paths, descriptors, hints);
            continue;
        }
        const path = paths.get(header.wd) orelse continue;
        if (header.mask & IN.IGNORED != 0) {
            try hints.add(path, .gone);
            continue;
        }
        const name = std.mem.sliceTo(buffer[name_start..name_end], 0);
        if (name.len == 0) {
            try hints.add(path, .entry);
            continue;
        }
        const scope: hints_module.Scope = if (header.mask & IN.ISDIR == 0)
            .entry
        else if (header.mask & (IN.CREATE | IN.MOVED_TO) != 0)
            .directory
        else if (header.mask & (IN.DELETE | IN.MOVED_FROM) != 0)
            .gone
        else
            .entry;
        try hints.add_child(path, name, scope);
    }
    assert(offset == buffer.len);
}

// Adds a `tree` hint for each watched directory whose parent is not watched, which are the tops
// of the watched trees.
fn add_tops(
    paths: *const std.AutoHashMapUnmanaged(i32, []const u8),
    descriptors: *const std.StringHashMapUnmanaged(i32),
    hints: *HintSet,
) !void {
    var all = paths.valueIterator();
    while (all.next()) |path| {
        if (std.fs.path.dirname(path.*)) |parent| {
            if (descriptors.contains(parent)) {
                continue;
            }
        }
        try hints.add(path.*, .tree);
    }
}

test {
    _ = @import("inotify.test.zig");
}
