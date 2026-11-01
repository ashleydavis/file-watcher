//
// The native backend for macOS. One FSEvents stream watches a whole tree and reports each
// changed file or directory by path, so one watch per root covers every directory and file
// under it, with no open descriptor per entry. CoreServices, which provides FSEvents, is loaded
// when the backend starts instead of being linked, so macOS builds still need no Apple SDK and
// cross compile from any machine.
//

const std = @import("std");
const builtin = @import("builtin");
const hints_module = @import("hints.zig");
const limit = @import("limit.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const HintSet = hints_module.HintSet;

//
// Event flags from FSEvents.h. They are written out here so the decoding is tested on any
// platform.
//
pub const flag_must_scan_sub_dirs: u32 = 0x00000001;
pub const flag_user_dropped: u32 = 0x00000002;
pub const flag_kernel_dropped: u32 = 0x00000004;
pub const flag_root_changed: u32 = 0x00000020;

//
// Stream creation flags from FSEvents.h: report events at once instead of after the latency,
// report changes to the root itself, and report each file rather than only its directory.
//
const create_flag_no_defer: u32 = 0x00000002;
const create_flag_watch_root: u32 = 0x00000004;
const create_flag_file_events: u32 = 0x00000010;
const create_flags: u32 = create_flag_no_defer | create_flag_watch_root | create_flag_file_events;

//
// Asks for events from now on, rather than replaying history.
//
const event_id_since_now: u64 = 0xFFFFFFFFFFFFFFFF;

//
// How long FSEvents may gather events before delivering them, in seconds. With `no_defer`, the
// first event of a quiet spell is delivered at once and a burst is gathered for this long.
//
const latency_seconds: f64 = 0.01;

//
// `kCFStringEncodingUTF8` from CFString.h.
//
const cf_string_encoding_utf8: u32 = 0x08000100;

//
// The most bytes of event paths held between waits. A burst beyond it is dropped and the next
// wait rescans every root instead, as FSEvents itself does when its own queue overflows.
//
pub const pending_bytes_max: usize = 4 * 1024 * 1024;

//
// The identifiers of the two user events the backend's kqueue waits on: one `wake` triggers and
// one the FSEvents callback triggers when it has queued events.
//
const wake_ident: usize = 1;
const events_ident: usize = 2;

//
// One watched root.
//
pub const Root = struct {
    //
    // The root as the watcher passed it, which event paths are rewritten to start with.
    //
    path: []const u8,

    //
    // The root with symbolic links resolved, as FSEvents reports paths. On macOS `/var` and
    // `/tmp` are links into `/private`, for example.
    //
    canonical: []const u8,

    //
    // The FSEvents stream, or null in tests.
    //
    stream: ?*anyopaque,
};

//
// Rewrites `event_path`, which starts with a root's canonical path, to start with the root's
// path as the watcher knows it. Returns null when the path is under none of the roots.
//
pub fn map_path(arena: Allocator, event_path: []const u8, roots: []const *Root) !?[]const u8 {
    const path = trim_trailing_separator(event_path);
    for (roots) |root| {
        if (!std.mem.startsWith(u8, path, root.canonical)) {
            continue;
        }
        const rest = path[root.canonical.len..];
        if (rest.len == 0) {
            return root.path;
        }
        if (rest[0] != '/' and !std.mem.endsWith(u8, root.canonical, "/")) {
            continue;
        }
        // The rest starts with a separator unless the canonical root ends with one, as `/` does.
        const name = if (rest[0] == '/') rest[1..] else rest;
        const separator = if (std.mem.endsWith(u8, root.path, "/")) "" else "/";
        return try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ root.path, separator, name });
    }
    return null;
}

//
// Removes one trailing separator, which FSEvents adds to directory paths in some events, unless
// the path is the file system root.
//
fn trim_trailing_separator(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') {
        return path[0 .. path.len - 1];
    }
    return path;
}

//
// Turns one FSEvents event into hints. Pure, so it is tested on every platform. Dropped events
// rescan every root; an event asking for a rescan below a path rescans that tree; a change to
// the root itself checks the root; anything else checks the path.
//
pub fn add_event(event_path: []const u8, flags: u32, roots: []const *Root, hints: *HintSet) !void {
    const arena = hints.arena.allocator();
    if (flags & (flag_user_dropped | flag_kernel_dropped) != 0) {
        for (roots) |root| {
            try hints.add(root.path, .tree);
        }
        return;
    }
    const path = try map_path(arena, event_path, roots) orelse return;
    if (flags & flag_must_scan_sub_dirs != 0) {
        try hints.add(path, .tree);
        return;
    }
    try hints.add(path, .entry);
}

//
// Events queued by the FSEvents callback, which runs on a dispatch queue thread, until `wait`
// takes them. Each event is stored as its flags, its path length and its path bytes.
//
const Pending = struct {
    //
    // Guards every field below.
    //
    mutex: std.c.pthread_mutex_t = .{},

    //
    // The encoded events.
    //
    bytes: std.ArrayList(u8) = .empty,

    //
    // Set when events were dropped because `bytes` was full.
    //
    is_overflowed: bool = false,
};

//
// Appends one event to `pending`, or marks it overflowed when the event does not fit. Pure, so
// it is tested on every platform.
//
pub fn queue_event(
    gpa: Allocator,
    bytes: *std.ArrayList(u8),
    is_overflowed: *bool,
    path: []const u8,
    flags: u32,
) void {
    const size = 8 + path.len;
    if (is_overflowed.* or bytes.items.len + size > pending_bytes_max) {
        is_overflowed.* = true;
        return;
    }
    bytes.ensureUnusedCapacity(gpa, size) catch {
        is_overflowed.* = true;
        return;
    };
    const length: u32 = @intCast(path.len);
    bytes.appendSliceAssumeCapacity(std.mem.asBytes(&flags));
    bytes.appendSliceAssumeCapacity(std.mem.asBytes(&length));
    bytes.appendSliceAssumeCapacity(path);
}

//
// Turns events encoded by `queue_event` into hints. Pure, so it is tested on every platform.
//
pub fn decode_pending(
    bytes: []const u8,
    is_overflowed: bool,
    roots: []const *Root,
    hints: *HintSet,
) !void {
    if (is_overflowed) {
        for (roots) |root| {
            try hints.add(root.path, .tree);
        }
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        assert(offset + 8 <= bytes.len);
        const flags = std.mem.readInt(u32, bytes[offset..][0..4], builtin.cpu.arch.endian());
        const length = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], builtin.cpu.arch.endian());
        const path = bytes[offset + 8 ..][0..length];
        if (!is_overflowed) {
            try add_event(path, flags, roots, hints);
        }
        offset += 8 + length;
    }
    assert(offset == bytes.len);
}

//
// The CoreServices, CoreFoundation and libdispatch functions the backend calls, looked up when
// the backend starts.
//
const Api = struct {
    FSEventStreamCreate: *const fn (
        allocator: ?*anyopaque,
        callback: *const Callback,
        context: *const StreamContext,
        paths: *anyopaque,
        since_when: u64,
        latency: f64,
        flags: u32,
    ) callconv(.c) ?*anyopaque,
    FSEventStreamSetDispatchQueue: *const fn (
        stream: *anyopaque,
        queue: ?*anyopaque,
    ) callconv(.c) void,
    FSEventStreamStart: *const fn (stream: *anyopaque) callconv(.c) u8,
    FSEventStreamStop: *const fn (stream: *anyopaque) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (stream: *anyopaque) callconv(.c) void,
    FSEventStreamRelease: *const fn (stream: *anyopaque) callconv(.c) void,
    CFStringCreateWithBytes: *const fn (
        allocator: ?*anyopaque,
        bytes: [*]const u8,
        length: isize,
        encoding: u32,
        is_external: u8,
    ) callconv(.c) ?*anyopaque,
    CFArrayCreate: *const fn (
        allocator: ?*anyopaque,
        values: [*]const ?*anyopaque,
        count: isize,
        callbacks: ?*const anyopaque,
    ) callconv(.c) ?*anyopaque,
    CFRelease: *const fn (object: *anyopaque) callconv(.c) void,
    kCFTypeArrayCallBacks: *const anyopaque,
    dispatch_queue_create: *const fn (
        label: [*:0]const u8,
        attributes: ?*anyopaque,
    ) callconv(.c) ?*anyopaque,
    dispatch_sync_f: *const fn (
        queue: *anyopaque,
        context: ?*anyopaque,
        work: *const fn (?*anyopaque) callconv(.c) void,
    ) callconv(.c) void,
    dispatch_release: *const fn (object: *anyopaque) callconv(.c) void,
};

//
// The FSEvents callback signature, with paths as C strings.
//
const Callback = fn (
    stream: ?*anyopaque,
    info: ?*anyopaque,
    count: usize,
    paths: *const anyopaque,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void;

//
// `FSEventStreamContext` from FSEvents.h.
//
const StreamContext = extern struct {
    version: isize,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
};

//
// Where CoreServices lives on every macOS version.
//
const core_services_path = "/System/Library/Frameworks/CoreServices.framework/CoreServices";

//
// Looks up every function in `Api` from CoreServices, which also exports what it uses from
// CoreFoundation, and from libdispatch, which every process has loaded.
//
fn load_api() !Api {
    const handle = std.c.dlopen(core_services_path, .{
        .NOW = true,
        .LOCAL = true,
    }) orelse return error.FsEventsUnavailable;
    var api: Api = undefined;
    inline for (@typeInfo(Api).@"struct".fields) |field| {
        const symbol = std.c.dlsym(handle, field.name) orelse return error.FsEventsUnavailable;
        @field(api, field.name) = @ptrCast(@alignCast(symbol));
    }
    return api;
}

//
// Resolves symbolic links in `path`, as FSEvents does in the paths it reports.
//
extern "c" fn realpath(noalias path: [*:0]const u8, noalias resolved: [*]u8) ?[*:0]u8;

//
// An FSEvents stream per root, a dispatch queue that runs their callbacks, and a kqueue that
// `wait` blocks on until the callback or `wake` triggers it.
//
pub const FsEvents = struct {
    //
    // One stream watches a whole tree, so the watcher adds roots only.
    //
    pub const is_recursive = true;

    //
    // Allocates the roots and the pending events.
    //
    gpa: Allocator,

    //
    // The functions loaded from CoreServices.
    //
    api: Api,

    //
    // The kqueue descriptor `wait` blocks on.
    //
    kq: i32,

    //
    // The serial queue every stream delivers its events on.
    //
    queue: *anyopaque,

    //
    // The watched roots.
    //
    roots: std.ArrayList(*Root),

    //
    // Events waiting for the next `wait`.
    //
    pending: Pending,

    //
    // Loads CoreServices and creates the kqueue and dispatch queue.
    //
    pub fn init(self: *FsEvents, gpa: Allocator) !void {
        const api = try load_api();
        const kq = std.c.kqueue();
        if (kq < 0) {
            return switch (std.c.errno(kq)) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => |err| std.posix.unexpectedErrno(err),
            };
        }
        errdefer _ = std.c.close(kq);
        const changes = [_]std.c.Kevent{
            user_event(wake_ident, std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR, 0),
            user_event(events_ident, std.c.EV.ADD | std.c.EV.ENABLE | std.c.EV.CLEAR, 0),
        };
        var no_events: [0]std.c.Kevent = .{};
        if (std.c.kevent(kq, &changes, changes.len, &no_events, 0, null) < 0) {
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        const queue = api.dispatch_queue_create("file-watcher.fsevents", null) orelse {
            return error.SystemResources;
        };
        self.* = .{
            .gpa = gpa,
            .api = api,
            .kq = kq,
            .queue = queue,
            .roots = .empty,
            .pending = .{},
        };
    }

    //
    // Ends a `wait` running on another thread, or the next one to start, at once.
    //
    pub fn wake(self: *FsEvents) void {
        assert(self.kq >= 0);
        trigger(self.kq, wake_ident);
    }

    //
    // Stops every stream and frees everything.
    //
    pub fn deinit(self: *FsEvents) void {
        while (self.roots.items.len > 0) {
            const root = self.roots.items[self.roots.items.len - 1];
            assert(self.unwatch(root.path));
        }
        // Running an empty block on the serial queue waits for any callback still running, so
        // nothing touches the pending events or the kqueue once they are freed.
        self.api.dispatch_sync_f(self.queue, null, drain);
        self.roots.deinit(self.gpa);
        self.api.dispatch_release(self.queue);
        self.pending.bytes.deinit(self.gpa);
        _ = std.c.close(self.kq);
        self.* = undefined;
    }

    //
    // Starts watching the tree under the root at `path`. Returns false when it was watched already.
    //
    pub fn watch(self: *FsEvents, path: []const u8, is_directory: bool) !bool {
        assert(is_directory);
        assert(path.len > 0);
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root.path, path)) {
                return false;
            }
        }
        if (self.roots.items.len >= limit.fsevents_streams_max) {
            return error.LimitReached;
        }
        try self.roots.ensureUnusedCapacity(self.gpa, 1);

        const path_z = try std.posix.toPosixPath(path);
        var resolved: [std.posix.PATH_MAX]u8 = undefined;
        const canonical_z = realpath(&path_z, &resolved) orelse {
            return switch (std.c.errno(-1)) {
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .ACCES => error.AccessDenied,
                else => |err| std.posix.unexpectedErrno(err),
            };
        };
        const canonical = std.mem.span(canonical_z);

        const root = try self.gpa.create(Root);
        errdefer self.gpa.destroy(root);
        root.path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(root.path);
        root.canonical = try self.gpa.dupe(u8, canonical);
        errdefer self.gpa.free(root.canonical);

        const string = self.api.CFStringCreateWithBytes(
            null,
            canonical.ptr,
            @intCast(canonical.len),
            cf_string_encoding_utf8,
            0,
        ) orelse return error.SystemResources;
        defer self.api.CFRelease(string);
        const values = [_]?*anyopaque{string};
        const array = self.api.CFArrayCreate(
            null,
            &values,
            1,
            self.api.kCFTypeArrayCallBacks,
        ) orelse return error.SystemResources;
        defer self.api.CFRelease(array);

        const context: StreamContext = .{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copy_description = null,
        };
        const stream = self.api.FSEventStreamCreate(
            null,
            &on_events,
            &context,
            array,
            event_id_since_now,
            latency_seconds,
            create_flags,
        ) orelse return error.SystemResources;
        errdefer self.api.FSEventStreamRelease(stream);
        self.api.FSEventStreamSetDispatchQueue(stream, self.queue);
        if (self.api.FSEventStreamStart(stream) == 0) {
            self.api.FSEventStreamInvalidate(stream);
            return error.LimitReached;
        }
        root.stream = stream;
        self.roots.appendAssumeCapacity(root);
        return true;
    }

    //
    // The number of roots watched.
    //
    pub fn watch_count(self: *const FsEvents) u32 {
        return @intCast(self.roots.items.len);
    }

    //
    // Stops watching the root at `path`. Returns false when it was not watched.
    //
    pub fn unwatch(self: *FsEvents, path: []const u8) bool {
        assert(path.len > 0);
        for (self.roots.items, 0..) |root, index| {
            if (!std.mem.eql(u8, root.path, path)) {
                continue;
            }
            _ = self.roots.orderedRemove(index);
            // Events the stream already queued stay pending; with the root gone they map to no
            // root and are ignored.
            const stream = root.stream.?;
            self.api.FSEventStreamStop(stream);
            self.api.FSEventStreamInvalidate(stream);
            self.api.FSEventStreamRelease(stream);
            self.gpa.free(root.canonical);
            self.gpa.free(root.path);
            self.gpa.destroy(root);
            return true;
        }
        return false;
    }

    //
    // Waits up to `timeout_ms` for changes and records the paths they touch in `hints`.
    //
    pub fn wait(self: *FsEvents, timeout_ms: u32, hints: *HintSet) !void {
        var events: [2]std.c.Kevent = undefined;
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
        // Events are taken whether or not the kqueue said so, so a wake never strands them.
        _ = std.c.pthread_mutex_lock(&self.pending.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.pending.mutex);
        const pending = &self.pending;
        try decode_pending(pending.bytes.items, pending.is_overflowed, self.roots.items, hints);
        self.pending.bytes.clearRetainingCapacity();
        self.pending.is_overflowed = false;
    }
};

//
// Does nothing; run on the dispatch queue to wait for the callbacks before it.
//
fn drain(context: ?*anyopaque) callconv(.c) void {
    assert(context == null);
}

//
// Queues the events of one delivery and wakes the waiting thread. Runs on the dispatch queue.
//
fn on_events(
    stream: ?*anyopaque,
    info: ?*anyopaque,
    count: usize,
    paths: *const anyopaque,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void {
    _ = stream;
    _ = ids;
    const self: *FsEvents = @ptrCast(@alignCast(info.?));
    const c_paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths));
    {
        _ = std.c.pthread_mutex_lock(&self.pending.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.pending.mutex);
        for (0..count) |index| {
            const path = std.mem.span(c_paths[index]);
            const pending = &self.pending;
            queue_event(self.gpa, &pending.bytes, &pending.is_overflowed, path, flags[index]);
        }
    }
    trigger(self.kq, events_ident);
}

//
// Builds a change for one of the backend's user events.
//
fn user_event(ident: usize, flags: u16, fflags: u32) std.c.Kevent {
    return .{
        .ident = ident,
        .filter = std.c.EVFILT.USER,
        .flags = flags,
        .fflags = fflags,
        .data = 0,
        .udata = 0,
    };
}

//
// Triggers the user event `ident`, which ends a wait on `kq`.
//
fn trigger(kq: i32, ident: usize) void {
    const change = user_event(ident, 0, std.c.NOTE.TRIGGER);
    var no_events: [0]std.c.Kevent = .{};
    // Triggering a registered user event cannot fail, so the result needs no check.
    _ = std.c.kevent(kq, @ptrCast(&change), 1, &no_events, 0, null);
}

test {
    _ = @import("fsevents.test.zig");
}
