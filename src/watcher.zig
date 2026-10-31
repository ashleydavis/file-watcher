//
// Watches directory trees for changes. It picks the platform's native watch method, keeps the
// number of native watches within a quota of the platform limit and polls every directory the
// native method cannot cover. Changes come back in batches from `next`.
//

const std = @import("std");
const builtin = @import("builtin");
const event_module = @import("event.zig");
const hints_module = @import("hints.zig");
const inotify = @import("inotify.zig");
const kqueue = @import("kqueue.zig");
const limit = @import("limit.zig");
const options_module = @import("options.zig");
const read_directory_changes = @import("read_directory_changes.zig");
const snapshot_module = @import("snapshot.zig");
const unsupported = @import("unsupported.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Event = event_module.Event;
const EventList = event_module.EventList;
const HintSet = hints_module.HintSet;
const Options = options_module.Options;
const Problem = event_module.Problem;
const Snapshot = snapshot_module.Snapshot;

//
// The native backend of the platform being built for.
//
pub const NativeBackend = switch (builtin.os.tag) {
    .linux => inotify.Inotify,
    .windows => read_directory_changes.ReadDirectoryChanges,
    .macos, .ios, .tvos, .watchos, .visionos => kqueue.Kqueue,
    else => unsupported.Unsupported,
};

//
// A watcher using the platform's native backend.
//
pub const Watcher = GenericWatcher(NativeBackend);

//
// The changes found in one call to `next`. The slices stay valid until the next call to `next`
// or `add`.
//
pub const Batch = struct {
    //
    // What changed, in the order it was found.
    //
    events: []const Event,

    //
    // Paths that could not be read or watched natively, so the caller can tell the user.
    //
    problems: []const Problem,
};

//
// Counters that show how the watcher is spending its quota.
//
pub const Stats = struct {
    //
    // The platform's native watch limit.
    //
    native_limit: u32,

    //
    // The share of the limit this watcher may use.
    //
    watch_budget: u32,

    //
    // Native watches in use.
    //
    native_watches: u32,

    //
    // Directories watched by polling.
    //
    polled_directories: u32,

    //
    // Directories watched in total.
    //
    directories: u32,

    //
    // Whether the native backend is running.
    //
    is_native_active: bool,
};

//
// A watcher built on `Backend`, which is a native backend or, in tests, a fake. The backend is
// a type parameter rather than a runtime interface because each build has exactly one.
//
pub fn GenericWatcher(comptime Backend: type) type {
    return struct {
        const Self = @This();

        //
        // Allocates every record the watcher keeps.
        //
        gpa: Allocator,

        //
        // Reads the file system and the clock.
        //
        io: Io,

        //
        // The caller's settings. The snapshot points at this copy, which is why the watcher is
        // created in place and must not move.
        //
        options: Options,

        //
        // The record of every watched directory.
        //
        snapshot: Snapshot,

        //
        // The native backend, valid while `is_native_active` is set.
        //
        backend: Backend,

        //
        // Whether the native backend is running.
        //
        is_native_active: bool,

        //
        // The platform's native watch limit.
        //
        native_limit: u32,

        //
        // The most native watches this watcher may use. It drops to the number in use when the
        // platform refuses a watch before the quota is reached.
        //
        watch_budget: u32,

        //
        // Native watches in use.
        //
        watch_count: u32,

        //
        // Whether the platform limit has been reported, so it is reported once rather than once
        // per directory that falls back to polling.
        //
        is_limit_reported: bool,

        //
        // Directories watched by polling. Keys are owned by this map.
        //
        polled: std.StringArrayHashMapUnmanaged(void),

        //
        // When the polled directories are next rescanned, in nanoseconds on the awake clock.
        //
        poll_due_ns: i96,

        //
        // The current batch of events and problems.
        //
        list: EventList,

        //
        // Whether `list` holds a batch already handed to the caller, which is cleared before any
        // new event is recorded.
        //
        is_list_returned: bool,

        //
        // The paths the backend reported in the current wait.
        //
        hints: HintSet,

        //
        // Creates a watcher with no roots. Problems found here, such as the native method being
        // unavailable, are reported by the first call to `next`.
        //
        pub fn init(self: *Self, gpa: Allocator, io: Io, options: *const Options) !void {
            assert(options_module.is_valid(options));
            self.* = .{
                .gpa = gpa,
                .io = io,
                .options = options.*,
                .snapshot = undefined,
                .backend = undefined,
                .is_native_active = false,
                .native_limit = 0,
                .watch_budget = 0,
                .watch_count = 0,
                .is_limit_reported = false,
                .polled = .empty,
                .poll_due_ns = 0,
                .list = EventList.init(gpa),
                .is_list_returned = false,
                .hints = HintSet.init(gpa),
            };
            self.snapshot = Snapshot.init(gpa, io, &self.options);
            self.poll_due_ns = self.now_ns() + self.poll_interval_ns();
            if (self.options.method == .native) {
                try self.start_native();
            }
            assert(self.watch_count == 0);
        }

        //
        // Stops every watch and frees every record.
        //
        pub fn deinit(self: *Self) void {
            if (self.is_native_active) {
                self.backend.deinit();
            }
            for (self.polled.keys()) |path| {
                self.gpa.free(path);
            }
            self.polled.deinit(self.gpa);
            self.snapshot.deinit();
            self.list.deinit();
            self.hints.deinit();
            self.* = undefined;
        }

        //
        // Starts watching the directory tree at `path`. Fails when the path is not a directory
        // or overlaps a tree added before.
        //
        pub fn add(self: *Self, path: []const u8) !void {
            assert(path.len > 0);
            self.clear_returned_batch();
            try self.snapshot.add_root(path, &self.list);
            const root = snapshot_module.trim_root(path);
            assert(self.snapshot.contains_directory(root));
            var directories = self.snapshot.directories.iterator();
            while (directories.next()) |entry| {
                const directory_path = entry.key_ptr.*;
                if (!snapshot_module.is_within(directory_path, root)) {
                    continue;
                }
                try self.watch_path(directory_path, true);
                if (Backend.watches_files) {
                    try self.watch_files(directory_path, &entry.value_ptr.children);
                }
            }
        }

        //
        // Waits up to `timeout_ms` for changes and returns them. Returns as soon as there is at
        // least one event or problem, or an empty batch when the time runs out.
        //
        pub fn next(self: *Self, timeout_ms: u32) !Batch {
            self.clear_returned_batch();
            const deadline_ns = self.now_ns() + @as(i96, timeout_ms) * std.time.ns_per_ms;
            var rounds: u32 = 0;
            while (true) : (rounds += 1) {
                assert(rounds < std.math.maxInt(u32));
                if (self.has_batch()) {
                    break;
                }
                try self.poll_if_due();
                if (self.has_batch()) {
                    break;
                }
                // The backend is asked for events even when the time is up, so a zero timeout
                // still collects the events already queued instead of skipping them.
                const current_ns = self.now_ns();
                var wait_ns = @max(deadline_ns - current_ns, 0);
                if (self.polled.count() > 0) {
                    wait_ns = @min(wait_ns, @max(self.poll_due_ns - current_ns, 0));
                }
                try self.wait_for_changes(wait_ns);
                try self.apply_hints();
                if (self.has_batch()) {
                    break;
                }
                if (self.now_ns() >= deadline_ns) {
                    break;
                }
            }
            self.is_list_returned = true;
            return .{
                .events = self.list.events.items,
                .problems = self.list.problems.items,
            };
        }

        //
        // Whether the current batch holds anything to hand to the caller.
        //
        fn has_batch(self: *const Self) bool {
            return self.list.events.items.len + self.list.problems.items.len > 0;
        }

        //
        // Counters that show how the watcher is spending its quota.
        //
        pub fn stats(self: *const Self) Stats {
            assert(self.watch_count <= self.watch_budget);
            return .{
                .native_limit = self.native_limit,
                .watch_budget = self.watch_budget,
                .native_watches = self.watch_count,
                .polled_directories = @intCast(self.polled.count()),
                .directories = self.snapshot.directory_count(),
                .is_native_active = self.is_native_active,
            };
        }

        //
        // Reads the platform limit and starts the backend, recording a problem and falling back
        // to polling when either fails.
        //
        fn start_native(self: *Self) !void {
            assert(!self.is_native_active);
            self.native_limit = limit.native_watch_limit(self.io) catch |err| {
                try self.list.append_problem("", err, .polled);
                return;
            };
            self.watch_budget = limit.watch_budget(self.native_limit, self.options.quota_percent);
            if (self.watch_budget == 0) {
                return;
            }
            self.backend.init(self.gpa) catch |err| {
                try self.list.append_problem("", err, .polled);
                return;
            };
            self.is_native_active = true;
        }

        //
        // Empties the batch handed out by the last call to `next`.
        //
        fn clear_returned_batch(self: *Self) void {
            if (self.is_list_returned) {
                self.list.clear();
                self.is_list_returned = false;
            }
            assert(!self.is_list_returned);
        }

        //
        // Watches every file in a directory, for backends that need a watch per file.
        //
        fn watch_files(
            self: *Self,
            directory_path: []const u8,
            children: *const std.StringHashMapUnmanaged(snapshot_module.Stamp),
        ) !void {
            assert(Backend.watches_files);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var files = children.iterator();
            while (files.next()) |child| {
                if (child.value_ptr.kind == .directory) {
                    continue;
                }
                var allocator = std.heap.FixedBufferAllocator.init(&buffer);
                const file_path = try std.fs.path.join(allocator.allocator(), &.{
                    directory_path,
                    child.key_ptr.*,
                });
                try self.watch_path(file_path, false);
            }
        }

        //
        // Watches `path` natively when the backend needs a watch for it and the quota allows,
        // and polls its directory otherwise.
        //
        fn watch_path(self: *Self, path: []const u8, is_directory: bool) !void {
            assert(path.len > 0);
            if (!self.is_native_active) {
                if (is_directory) {
                    try self.poll_directory(path);
                }
                return;
            }
            if (Backend.is_recursive) {
                // A directory below a root is covered by the root's tree watch, unless the root
                // is polled, in which case every directory under it is polled.
                // A path whose root was deleted earlier in the batch needs no watch.
                const root = self.snapshot.root_of(path) orelse return;
                if (!std.mem.eql(u8, root, path)) {
                    if (is_directory) {
                        if (self.polled.contains(root)) {
                            try self.poll_directory(path);
                        }
                    }
                    return;
                }
            }
            if (!is_directory) {
                if (!Backend.watches_files) {
                    return;
                }
            }
            if (self.watch_count < self.watch_budget) {
                const is_new = self.backend.watch(path, is_directory) catch |err| {
                    try self.record_watch_failure(path, err);
                    try self.poll_instead(path, is_directory);
                    return;
                };
                if (is_new) {
                    self.watch_count += 1;
                }
            } else {
                try self.record_quota_reached(path);
                try self.poll_instead(path, is_directory);
            }
            assert(self.watch_count <= self.watch_budget);
        }

        //
        // Polls what a refused native watch would have covered: the directory itself, the
        // directory holding a file, or every directory under a root for a tree backend.
        //
        fn poll_instead(self: *Self, path: []const u8, is_directory: bool) !void {
            if (!is_directory) {
                try self.poll_directory(std.fs.path.dirname(path).?);
                return;
            }
            if (!Backend.is_recursive) {
                try self.poll_directory(path);
                return;
            }
            assert(self.snapshot.is_root(path));
            var directories = self.snapshot.directories.keyIterator();
            while (directories.next()) |directory_path| {
                if (snapshot_module.is_within(directory_path.*, path)) {
                    try self.poll_directory(directory_path.*);
                }
            }
            assert(self.polled.contains(path));
        }

        //
        // Reports a native watch the backend refused. A refusal because the platform ran out of
        // watches also lowers the budget to the number in use, so later paths go straight to
        // polling instead of asking the platform again.
        //
        fn record_watch_failure(self: *Self, path: []const u8, err: anyerror) !void {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }
            if (err == error.LimitReached) {
                self.watch_budget = self.watch_count;
                try self.record_quota_reached(path);
                return;
            }
            try self.list.append_problem(path, err, .polled);
        }

        //
        // Reports, once, that the quota is used up and further paths are polled.
        //
        fn record_quota_reached(self: *Self, path: []const u8) !void {
            if (self.is_limit_reported) {
                return;
            }
            self.is_limit_reported = true;
            try self.list.append_problem(path, error.LimitReached, .polled);
        }

        //
        // Stops the native watch on `path` and stops polling it.
        //
        fn unwatch_path(self: *Self, path: []const u8, is_directory: bool) void {
            assert(path.len > 0);
            const has_own_watch = if (is_directory) true else Backend.watches_files;
            if (self.is_native_active) {
                if (has_own_watch) {
                    if (self.backend.unwatch(path)) {
                        assert(self.watch_count > 0);
                        self.watch_count -= 1;
                    }
                }
            }
            if (is_directory) {
                if (self.polled.fetchSwapRemove(path)) |removed| {
                    self.gpa.free(removed.key);
                }
            }
        }

        //
        // Adds a directory to the polled set.
        //
        fn poll_directory(self: *Self, path: []const u8) !void {
            assert(path.len > 0);
            const result = try self.polled.getOrPut(self.gpa, path);
            if (result.found_existing) {
                return;
            }
            result.key_ptr.* = self.gpa.dupe(u8, path) catch |err| {
                self.polled.swapRemoveAt(self.polled.count() - 1);
                return err;
            };
            assert(self.polled.contains(path));
        }

        //
        // Keeps native watches and the polled set in step with the events recorded since
        // `first`: new paths are watched and deleted paths are dropped.
        //
        fn track_events(self: *Self, first: usize) !void {
            var index = first;
            while (index < self.list.events.items.len) : (index += 1) {
                const item = self.list.events.items[index];
                switch (item.kind) {
                    .created => try self.watch_path(item.path, item.is_directory),
                    .deleted => self.unwatch_path(item.path, item.is_directory),
                    .modified => {},
                }
            }
            assert(index == self.list.events.items.len);
        }

        //
        // Rescans every polled directory when the poll interval has passed.
        //
        fn poll_if_due(self: *Self) !void {
            if (self.polled.count() == 0) {
                return;
            }
            const current_ns = self.now_ns();
            if (current_ns < self.poll_due_ns) {
                return;
            }
            self.poll_due_ns = current_ns + self.poll_interval_ns();

            // Rescanning can add and remove polled directories, so it walks a copy of the set.
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();

            const paths = try arena.allocator().alloc([]const u8, self.polled.count());
            for (self.polled.keys(), paths) |key, *path| {
                path.* = try arena.allocator().dupe(u8, key);
            }
            for (paths) |path| {
                const first = self.list.events.items.len;
                try self.snapshot.rescan_directory(path, &self.list);
                try self.track_events(first);
            }
        }

        //
        // Waits for native events, or sleeps when no directory is watched natively. A wait of zero
        // collects the events already queued without blocking.
        //
        fn wait_for_changes(self: *Self, wait_ns: i96) !void {
            assert(wait_ns >= 0);
            if (self.is_native_active) {
                if (self.watch_count > 0) {
                    const wait_ms: u32 = @intCast(@min(
                        std.math.divCeil(i96, wait_ns, std.time.ns_per_ms) catch unreachable,
                        std.math.maxInt(u32),
                    ));
                    self.backend.wait(wait_ms, &self.hints) catch |err| {
                        if (err == error.OutOfMemory) {
                            return error.OutOfMemory;
                        }
                        try self.fall_back_to_polling(err);
                    };
                    return;
                }
            }
            if (wait_ns > 0) {
                try self.io.sleep(.fromNanoseconds(wait_ns), .awake);
            }
        }

        //
        // Stops the native backend after it failed and polls every directory instead.
        //
        fn fall_back_to_polling(self: *Self, err: anyerror) !void {
            assert(self.is_native_active);
            try self.list.append_problem("", err, .polled);
            self.backend.deinit();
            self.is_native_active = false;
            self.watch_count = 0;
            self.hints.clear();
            var directories = self.snapshot.directories.keyIterator();
            while (directories.next()) |path| {
                try self.poll_directory(path.*);
            }
            assert(self.polled.count() == self.snapshot.directory_count());
        }

        //
        // Checks every path the backend reported and records the changes.
        //
        fn apply_hints(self: *Self) !void {
            defer self.hints.clear();
            for (self.hints.paths.keys(), self.hints.paths.values()) |path, checks| {
                const first = self.list.events.items.len;
                if (checks.tree) {
                    try self.snapshot.rescan_tree(path, &self.list);
                }
                if (checks.directory) {
                    try self.snapshot.rescan_directory(path, &self.list);
                }
                if (checks.entry) {
                    try self.snapshot.check_entry(path, &self.list);
                }
                try self.track_events(first);
            }
        }

        //
        // The current time on the awake clock, which does not jump when the wall clock is set.
        //
        fn now_ns(self: *const Self) i96 {
            return Io.Timestamp.now(self.io, .awake).nanoseconds;
        }

        //
        // The poll interval in nanoseconds, the unit of the clock.
        //
        fn poll_interval_ns(self: *const Self) i96 {
            return @as(i96, self.options.poll_interval_ms) * std.time.ns_per_ms;
        }
    };
}

test {
    _ = @import("watcher.test.zig");
}
