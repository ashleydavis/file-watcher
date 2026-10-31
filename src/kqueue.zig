//
// The native backend for macOS and iOS. kqueue watches open descriptors, so every directory and
// every file needs its own descriptor: a directory watch reports entries added or removed, and a
// file watch reports writes to that file. kqueue is used rather than FSEvents because it is part
// of the C library on both platforms, while FSEvents needs Apple's SDK frameworks to link and
// is unavailable to iOS apps.
//

const std = @import("std");
const builtin = @import("builtin");
const hints_module = @import("hints.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Checks = hints_module.Checks;
const HintSet = hints_module.HintSet;

//
// The kqueue vnode flags this backend reads. They are written out here, with the values every
// Apple platform uses, so the decoding is tested on any platform; the comptime block below
// checks them against the system's own values when building for Apple platforms.
//
pub const note_delete: u32 = 0x01;
pub const note_write: u32 = 0x02;
pub const note_extend: u32 = 0x04;
pub const note_attrib: u32 = 0x08;
pub const note_link: u32 = 0x10;
pub const note_rename: u32 = 0x20;
pub const note_revoke: u32 = 0x40;

comptime {
    if (builtin.os.tag.isDarwin()) {
        assert(note_delete == std.c.NOTE.DELETE);
        assert(note_write == std.c.NOTE.WRITE);
        assert(note_extend == std.c.NOTE.EXTEND);
        assert(note_attrib == std.c.NOTE.ATTRIB);
        assert(note_link == std.c.NOTE.LINK);
        assert(note_rename == std.c.NOTE.RENAME);
        assert(note_revoke == std.c.NOTE.REVOKE);
    }
}

//
// Every vnode change the backend asks kqueue to report.
//
const watch_flags: u32 = note_delete | note_write | note_extend | note_attrib | note_link |
    note_rename | note_revoke;

//
// The most events read in one wait. It bounds the work of one batch; further events stay queued
// for the next batch.
//
const events_per_wait_max: u32 = 256;

//
// Which checks a kqueue event calls for. Pure, so it is tested on every platform.
//
pub fn checks_for(fflags: u32, is_directory: bool) Checks {
    var checks: Checks = .{};
    if (fflags & (note_delete | note_rename | note_revoke) != 0) {
        checks.entry = true;
    }
    if (is_directory) {
        if (fflags & (note_write | note_link) != 0) {
            checks.directory = true;
        }
    } else {
        if (fflags & (note_write | note_extend | note_attrib) != 0) {
            checks.entry = true;
        }
    }
    assert(!checks.tree);
    if (checks.directory) assert(is_directory);
    return checks;
}

//
// One watched path.
//
const Watch = struct {
    //
    // The open descriptor kqueue watches.
    //
    fd: i32,

    //
    // Whether the path is a directory, which decides how its events are read.
    //
    is_directory: bool,
};

//
// A kqueue instance and the paths it watches.
//
pub const Kqueue = struct {
    //
    // kqueue watches one path at a time, so the watcher adds every directory.
    //
    pub const is_recursive = false;

    //
    // A directory watch does not report writes to its files, so files are watched too.
    //
    pub const watches_files = true;

    //
    // Allocates the path maps.
    //
    gpa: Allocator,

    //
    // The kqueue descriptor.
    //
    kq: i32,

    //
    // The watch of each path. Keys are owned by this map.
    //
    watches: std.StringHashMapUnmanaged(Watch),

    //
    // The path of each watched descriptor, borrowed from `watches`, so events can be traced back.
    //
    paths: std.AutoHashMapUnmanaged(i32, []const u8),

    //
    // Opens a kqueue instance.
    //
    pub fn init(self: *Kqueue, gpa: Allocator) !void {
        const rc = std.c.kqueue();
        if (rc < 0) {
            return switch (std.c.errno(rc)) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => |err| std.posix.unexpectedErrno(err),
            };
        }
        self.* = .{
            .gpa = gpa,
            .kq = rc,
            .watches = .empty,
            .paths = .empty,
        };
        assert(self.kq >= 0);
    }

    //
    // Closes every watched descriptor and the kqueue.
    //
    pub fn deinit(self: *Kqueue) void {
        var iterator = self.watches.iterator();
        while (iterator.next()) |entry| {
            _ = std.c.close(entry.value_ptr.fd);
            self.gpa.free(entry.key_ptr.*);
        }
        self.watches.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        _ = std.c.close(self.kq);
        self.* = undefined;
    }

    //
    // Starts watching the file or directory at `path`. Returns false when it was watched already.
    //
    pub fn watch(self: *Kqueue, path: []const u8, is_directory: bool) !bool {
        assert(path.len > 0);
        if (self.watches.contains(path)) {
            return false;
        }
        try self.watches.ensureUnusedCapacity(self.gpa, 1);
        try self.paths.ensureUnusedCapacity(self.gpa, 1);
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);

        const path_z = try std.posix.toPosixPath(path);
        const fd = std.c.open(&path_z, .{
            .EVTONLY = true,
            .CLOEXEC = true,
        });
        if (fd < 0) {
            return switch (std.c.errno(fd)) {
                .MFILE, .NFILE => error.LimitReached,
                .ACCES => error.AccessDenied,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .LOOP => error.SymLinkLoop,
                .NAMETOOLONG => error.NameTooLong,
                else => |err| std.posix.unexpectedErrno(err),
            };
        }
        errdefer _ = std.c.close(fd);

        const change: std.c.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR,
            .fflags = watch_flags,
            .data = 0,
            .udata = 0,
        };
        var no_events: [0]std.c.Kevent = .{};
        const rc = std.c.kevent(self.kq, @ptrCast(&change), 1, &no_events, 0, null);
        if (rc < 0) {
            return switch (std.c.errno(rc)) {
                .NOMEM => error.LimitReached,
                else => |err| std.posix.unexpectedErrno(err),
            };
        }
        self.watches.putAssumeCapacityNoClobber(owned, .{
            .fd = fd,
            .is_directory = is_directory,
        });
        self.paths.putAssumeCapacityNoClobber(fd, owned);
        assert(self.watches.count() == self.paths.count());
        return true;
    }

    //
    // Stops watching `path`. Closing the descriptor removes its kqueue registration. Returns
    // false when the path was not watched.
    //
    pub fn unwatch(self: *Kqueue, path: []const u8) bool {
        assert(path.len > 0);
        const entry = self.watches.fetchRemove(path) orelse return false;
        _ = self.paths.remove(entry.value.fd);
        _ = std.c.close(entry.value.fd);
        self.gpa.free(entry.key);
        assert(self.watches.count() == self.paths.count());
        return true;
    }

    //
    // Waits up to `timeout_ms` for changes and records the paths they touch in `hints`.
    //
    pub fn wait(self: *Kqueue, timeout_ms: u32, hints: *HintSet) !void {
        var events: [events_per_wait_max]std.c.Kevent = undefined;
        const timeout: std.c.timespec = .{
            .sec = @intCast(@divFloor(timeout_ms, 1000)),
            .nsec = @intCast(@as(u64, timeout_ms % 1000) * std.time.ns_per_ms),
        };
        const no_changes: [0]std.c.Kevent = .{};
        const rc = std.c.kevent(self.kq, &no_changes, 0, &events, events.len, &timeout);
        if (rc < 0) {
            return switch (std.c.errno(rc)) {
                .INTR => {},
                else => |err| std.posix.unexpectedErrno(err),
            };
        }
        const count: usize = @intCast(rc);
        assert(count <= events.len);
        for (events[0..count]) |event| {
            const fd: i32 = @intCast(event.ident);
            const path = self.paths.get(fd) orelse continue;
            const checks = checks_for(event.fflags, self.watches.get(path).?.is_directory);
            if (checks.entry) {
                try hints.add(path, .entry);
            }
            if (checks.directory) {
                try hints.add(path, .directory);
            }
        }
    }
};

test {
    _ = @import("kqueue.test.zig");
}
