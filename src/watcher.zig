//
// Watches directory trees and reports which of them changed. It uses the platform's native watch
// method within a quota of the platform limit, and polls a tree the native method cannot fully
// cover by comparing a fingerprint of the tree. Nothing is kept per file: native events say
// directly that a tree changed, and polling keeps one number per tree.
//

const std = @import("std");
const builtin = @import("builtin");
const event_module = @import("event.zig");
const filter = @import("filter.zig");
const fingerprint_module = @import("fingerprint.zig");
const fsevents = @import("fsevents.zig");
const hints_module = @import("hints.zig");
const inotify = @import("inotify.zig");
const kqueue = @import("kqueue.zig");
const limit = @import("limit.zig");
const options_module = @import("options.zig");
const paths = @import("paths.zig");
const read_directory_changes = @import("read_directory_changes.zig");
const unsupported = @import("unsupported.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const EventList = event_module.EventList;
const HintSet = hints_module.HintSet;
const Options = options_module.Options;
const Problem = event_module.Problem;

//
// The native backend of the platform being built for.
//
pub const NativeBackend = switch (builtin.os.tag) {
    .linux => inotify.Inotify,
    .windows => read_directory_changes.ReadDirectoryChanges,
    .macos => fsevents.FsEvents,
    .ios, .tvos, .watchos, .visionos => kqueue.Kqueue,
    else => unsupported.Unsupported,
};

//
// A watcher using the platform's native backend.
//
pub const Watcher = GenericWatcher(NativeBackend);

//
// What one call to `next` found. The slices stay valid until the next call to `next` or `add`.
//
pub const Batch = struct {
    //
    // The watched directories that changed, each once, exactly as they were passed to `add`.
    //
    changed: []const []const u8,

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
    // Watched directories.
    //
    roots: u32,

    //
    // Watched directories that are polled, because native watching cannot cover them fully.
    //
    polled_roots: u32,

    //
    // Whether the native backend is running.
    //
    is_native_active: bool,
};

//
// One watched directory.
//
const Root = struct {
    //
    // The directory as it was passed to `add`, without trailing separators. Owned by the watcher.
    //
    path: []const u8,

    //
    // Whether the tree is polled, because native watching is off or could not cover all of it.
    //
    is_polled: bool,

    //
    // The tree's fingerprint at the last poll, while it is polled.
    //
    fingerprint: u64,

    //
    // When the root was last reported changed, in nanoseconds on the awake clock, or null
    // before its first report.
    //
    reported_ns: ?i96,

    //
    // Whether the root changed while its throttle held the report back. It is reported when the
    // throttle time has passed.
    //
    is_pending: bool,
};

//
// How an attempt to watch one path ended.
//
const WatchResult = enum {
    //
    // The path got a new native watch.
    //
    new,

    //
    // The path was watched already.
    //
    existing,

    //
    // The path could not be watched, and the reason was reported where it matters.
    //
    failed,

    //
    // The quota is used up, so the root is now polled and its walk can stop.
    //
    quota,
};

//
// A watcher built on `Backend`, which is a native backend or, in tests, a fake. The backend is
// a type parameter rather than a runtime interface because each build has exactly one.
//
pub fn GenericWatcher(comptime Backend: type) type {
    return struct {
        const Self = @This();

        //
        // Lists directories with their entries' metadata for polling, when the backend has a
        // faster way than reading each entry's metadata.
        //
        const lister: ?fingerprint_module.Lister = if (@hasDecl(Backend, "lister"))
            Backend.lister
        else
            null;

        //
        // Allocates every record the watcher keeps.
        //
        gpa: Allocator,

        //
        // Reads the file system and the clock.
        //
        io: Io,

        //
        // The caller's settings.
        //
        options: Options,

        //
        // The native backend, valid while `is_backend_started` is set.
        //
        backend: Backend,

        //
        // Whether the backend was started. It stays set after the backend fails, because the
        // backend is only freed by `deinit`, so `wake` can always reach it from another thread.
        //
        is_backend_started: bool,

        //
        // Whether the native backend is running.
        //
        is_native_active: bool,

        //
        // Counts calls to `wake`. A call to `next` returns as soon as the count moves, and polled
        // waits sleep on it, so `wake` can end them early.
        //
        wake_count: std.atomic.Value(u32),

        //
        // The wake count when `next` last returned because of a wake. A wake since then is
        // pending, even when it came before `next` started. Only the thread calling `next` uses it.
        //
        wake_count_handled: u32,

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
        // Whether the quota being used up has been reported, so it is reported once.
        //
        is_limit_reported: bool,

        //
        // The watched directories.
        //
        roots: std.ArrayList(Root),

        //
        // When polled roots are next checked, in nanoseconds on the awake clock.
        //
        poll_due_ns: i96,

        //
        // The current batch.
        //
        list: EventList,

        //
        // Whether `list` holds a batch already handed to the caller, which is cleared before
        // anything new is recorded.
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
                .backend = undefined,
                .is_backend_started = false,
                .is_native_active = false,
                .wake_count = .init(0),
                .wake_count_handled = 0,
                .native_limit = 0,
                .watch_budget = 0,
                .is_limit_reported = false,
                .roots = .empty,
                .poll_due_ns = 0,
                .list = EventList.init(gpa),
                .is_list_returned = false,
                .hints = HintSet.init(gpa),
            };
            self.poll_due_ns = self.now_ns() + self.poll_interval_ns();
            if (self.options.method == .native) {
                try self.start_native();
            }
        }

        //
        // Stops every watch and frees every record.
        //
        pub fn deinit(self: *Self) void {
            if (self.is_backend_started) {
                self.backend.deinit();
            }
            for (self.roots.items) |root| {
                self.gpa.free(root.path);
            }
            self.roots.deinit(self.gpa);
            self.list.deinit();
            self.hints.deinit();
            self.* = undefined;
        }

        //
        // Starts watching the directory tree at `path`. Fails with `error.FileNotFound` when the
        // path is missing, `error.NotDir` when it is not a directory and `error.OverlappingRoot`
        // when it is inside, or contains, a directory added before.
        //
        pub fn add(self: *Self, path: []const u8) !void {
            assert(path.len > 0);
            self.clear_returned_batch();
            const trimmed = paths.trim_root(path);
            const stat = try Dir.cwd().statFile(self.io, trimmed, .{
                .follow_symlinks = true,
            });
            if (stat.kind != .directory) {
                return error.NotDir;
            }
            for (self.roots.items) |root| {
                if (paths.is_within(trimmed, root.path) or paths.is_within(root.path, trimmed)) {
                    return error.OverlappingRoot;
                }
            }
            try self.roots.ensureUnusedCapacity(self.gpa, 1);
            const owned = try self.gpa.dupe(u8, trimmed);
            self.roots.appendAssumeCapacity(.{
                .path = owned,
                .is_polled = false,
                .fingerprint = 0,
                .reported_ns = null,
                .is_pending = false,
            });
            const index = self.roots.items.len - 1;
            if (!self.is_native_active) {
                try self.poll_root(index);
                return;
            }
            if (Backend.is_recursive) {
                _ = try self.watch_one(index, owned, true);
                return;
            }
            try self.sync_watches(index, owned, true);
        }

        //
        // Waits up to `timeout_ms` for changes and returns them. Returns as soon as a watched
        // directory changed or a problem was found, or with an empty batch when the time runs
        // out or `wake` is called.
        //
        pub fn next(self: *Self, timeout_ms: u32) !Batch {
            self.clear_returned_batch();
            const wake_count = self.wake_count_handled;
            const deadline_ns = self.now_ns() + @as(i96, timeout_ms) * std.time.ns_per_ms;
            var rounds: u32 = 0;
            while (true) : (rounds += 1) {
                assert(rounds < std.math.maxInt(u32));
                try self.report_pending();
                try self.poll_if_due();
                if (self.has_batch()) {
                    break;
                }
                // The backend is asked for events even when the time is up, so a zero timeout
                // still collects the events already queued instead of skipping them.
                const current_ns = self.now_ns();
                var wait_ns = @max(deadline_ns - current_ns, 0);
                if (self.polled_count() > 0) {
                    wait_ns = @min(wait_ns, @max(self.poll_due_ns - current_ns, 0));
                }
                if (self.pending_due_ns()) |due_ns| {
                    wait_ns = @min(wait_ns, @max(due_ns - current_ns, 0));
                }
                try self.wait_for_changes(wait_ns, wake_count);
                try self.apply_hints();
                if (self.has_batch()) {
                    break;
                }
                const current_wake_count = self.wake_count.load(.acquire);
                if (current_wake_count != wake_count) {
                    self.wake_count_handled = current_wake_count;
                    break;
                }
                if (self.now_ns() >= deadline_ns) {
                    break;
                }
            }
            self.is_list_returned = true;
            return .{
                .changed = self.list.changed.items,
                .problems = self.list.problems.items,
            };
        }

        //
        // Makes a call to `next` that is waiting, or the next call to start, return at once.
        // Safe to call from any thread, so another thread can stop a thread that waits in `next`,
        // for example when an app quits.
        //
        pub fn wake(self: *Self) void {
            _ = self.wake_count.fetchAdd(1, .release);
            if (self.is_backend_started) {
                self.backend.wake();
            }
            self.io.futexWake(u32, &self.wake_count.raw, 1);
        }

        //
        // Counters that show how the watcher is spending its quota.
        //
        pub fn stats(self: *const Self) Stats {
            const watches = self.native_watch_count();
            assert(watches <= self.watch_budget);
            return .{
                .native_limit = self.native_limit,
                .watch_budget = self.watch_budget,
                .native_watches = watches,
                .roots = @intCast(self.roots.items.len),
                .polled_roots = self.polled_count(),
                .is_native_active = self.is_native_active,
            };
        }

        //
        // Whether the current batch holds anything to hand to the caller.
        //
        fn has_batch(self: *const Self) bool {
            return self.list.changed.items.len + self.list.problems.items.len > 0;
        }

        //
        // The number of native watches in use.
        //
        fn native_watch_count(self: *const Self) u32 {
            if (!self.is_native_active) {
                return 0;
            }
            return self.backend.watch_count();
        }

        //
        // The number of polled roots.
        //
        fn polled_count(self: *const Self) u32 {
            var count: u32 = 0;
            for (self.roots.items) |root| {
                if (root.is_polled) {
                    count += 1;
                }
            }
            return count;
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
            if (self.options.native_watches_max) |watches_max| {
                self.watch_budget = @min(self.watch_budget, watches_max);
            }
            if (self.watch_budget == 0) {
                return;
            }
            self.backend.init(self.gpa) catch |err| {
                try self.list.append_problem("", err, .polled);
                return;
            };
            self.is_backend_started = true;
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
        // Watches what is under `start` in root `index`, for backends that watch each directory
        // (and, for some, each file). The start directory is always listed. Below it, a
        // directory is listed when it got a new watch, or always when `is_full`, so a check after
        // dropped events reaches everything while a new directory costs only its own tree.
        //
        fn sync_watches(self: *Self, index: usize, start: []const u8, is_full: bool) !void {
            assert(!Backend.is_recursive);
            var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var pending: std.ArrayList([]const u8) = .empty;
            try pending.append(arena, start);
            var walked: u32 = 0;
            while (pending.pop()) |path| {
                assert(walked < std.math.maxInt(u32));
                walked += 1;
                switch (try self.watch_one(index, path, true)) {
                    .quota => return,
                    .failed => continue,
                    .existing => if (path.ptr != start.ptr and !is_full) continue,
                    .new => {},
                }
                var dir = Dir.cwd().openDir(self.io, path, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    // The directory went away, which its parent's events report.
                    error.FileNotFound, error.NotDir => continue,
                    else => {
                        try self.list.append_problem(path, err, .skipped);
                        continue;
                    },
                };
                defer dir.close(self.io);
                var iterator = dir.iterate();
                while (true) {
                    const entry = iterator.next(self.io) catch |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        else => {
                            try self.list.append_problem(path, err, .skipped);
                            break;
                        },
                    } orelse break;
                    if (entry.kind == .directory) {
                        if (filter.is_excluded_directory(&self.options, entry.name)) {
                            continue;
                        }
                        const child = try std.fs.path.join(arena, &.{ path, entry.name });
                        try pending.append(arena, child);
                        continue;
                    }
                    if (!Backend.watches_files) {
                        continue;
                    }
                    if (filter.is_excluded_file(&self.options, entry.name)) {
                        continue;
                    }
                    const file_path = try std.fs.path.join(arena, &.{ path, entry.name });
                    if (try self.watch_one(index, file_path, false) == .quota) {
                        return;
                    }
                }
            }
        }

        //
        // Watches `path` natively when the quota allows. When it is used up, or the platform
        // refuses for lack of resources, root `index` is polled instead.
        //
        fn watch_one(self: *Self, index: usize, path: []const u8, is_directory: bool) !WatchResult {
            assert(self.is_native_active);
            assert(path.len > 0);
            if (self.backend.watch_count() >= self.watch_budget) {
                try self.quota_reached(index, path);
                return .quota;
            }
            const is_new = self.backend.watch(path, is_directory) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitReached => {
                    self.watch_budget = self.backend.watch_count();
                    try self.quota_reached(index, path);
                    return .quota;
                },
                // The path went away before it could be watched, which its parent's events report.
                error.FileNotFound, error.NotDir => return .failed,
                else => {
                    try self.list.append_problem(path, err, .skipped);
                    return .failed;
                },
            };
            assert(self.backend.watch_count() <= self.watch_budget);
            return if (is_new) .new else .existing;
        }

        //
        // Polls root `index`, because native watches ran out while covering it. The quota being
        // used up is reported once, for the first path that did not fit.
        //
        fn quota_reached(self: *Self, index: usize, path: []const u8) !void {
            if (!self.is_limit_reported) {
                self.is_limit_reported = true;
                try self.list.append_problem(path, error.LimitReached, .polled);
            }
            try self.poll_root(index);
        }

        //
        // Starts polling root `index` from its current state. Paths that cannot be read are
        // reported now, once, rather than on every poll.
        //
        fn poll_root(self: *Self, index: usize) !void {
            const root = &self.roots.items[index];
            if (root.is_polled) {
                return;
            }
            root.fingerprint = try fingerprint_module.fingerprint(
                self.gpa,
                self.io,
                root.path,
                &self.options,
                lister,
                &self.list,
            );
            root.is_polled = true;
        }

        //
        // Checks every polled root when the poll interval has passed.
        //
        fn poll_if_due(self: *Self) !void {
            if (self.polled_count() == 0) {
                return;
            }
            const current_ns = self.now_ns();
            if (current_ns < self.poll_due_ns) {
                return;
            }
            self.poll_due_ns = current_ns + self.poll_interval_ns();
            for (self.roots.items) |*root| {
                if (!root.is_polled) {
                    continue;
                }
                const current = try fingerprint_module.fingerprint(
                    self.gpa,
                    self.io,
                    root.path,
                    &self.options,
                    lister,
                    null,
                );
                if (current != root.fingerprint) {
                    root.fingerprint = current;
                    try self.mark_changed(root);
                }
            }
        }

        //
        // Waits for native events, or sleeps when nothing is watched natively. A wait of zero
        // collects the events already queued without blocking. Either wait ends early when `wake`
        // moves the wake count away from `wake_count`.
        //
        fn wait_for_changes(self: *Self, wait_ns: i96, wake_count: u32) !void {
            assert(wait_ns >= 0);
            if (self.native_watch_count() > 0) {
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
            if (wait_ns > 0) {
                try self.io.futexWaitTimeout(u32, &self.wake_count.raw, wake_count, .{
                    .duration = .{
                        .raw = .fromNanoseconds(wait_ns),
                        .clock = .awake,
                    },
                });
            }
        }

        //
        // Stops using the native backend after it failed and polls every root instead. The
        // backend stays allocated until `deinit`, so `wake` stays safe from other threads.
        //
        fn fall_back_to_polling(self: *Self, err: anyerror) !void {
            assert(self.is_native_active);
            assert(self.is_backend_started);
            try self.list.append_problem("", err, .polled);
            self.is_native_active = false;
            self.hints.clear();
            for (0..self.roots.items.len) |index| {
                try self.poll_root(index);
            }
            assert(self.polled_count() == self.roots.items.len);
        }

        //
        // Records the root of every path the backend reported as changed, unless the path is
        // excluded, and keeps the watches of backends that watch each directory in step.
        //
        fn apply_hints(self: *Self) !void {
            defer self.hints.clear();
            for (self.hints.paths.keys(), self.hints.paths.values()) |path, checks| {
                const index = self.root_of(path) orelse continue;
                const root = self.roots.items[index];
                if (filter.is_excluded_path(&self.options, root.path, path)) {
                    continue;
                }
                try self.mark_changed(&self.roots.items[index]);
                if (comptime Backend.is_recursive) {
                    continue;
                }
                if (!self.is_native_active or root.is_polled) {
                    continue;
                }
                if (checks.gone) {
                    try self.backend.unwatch_tree(path);
                }
                if (checks.tree) {
                    try self.sync_watches(index, path, true);
                } else if (checks.directory) {
                    try self.sync_watches(index, path, false);
                }
            }
        }

        //
        // Reports that `root` changed, unless it was reported less than the throttle time ago,
        // in which case the report waits until that time has passed.
        //
        fn mark_changed(self: *Self, root: *Root) !void {
            if (root.reported_ns) |reported_ns| {
                if (self.now_ns() - reported_ns < self.throttle_ns()) {
                    root.is_pending = true;
                    return;
                }
            }
            try self.report(root);
        }

        //
        // Adds `root` to the batch and starts its throttle time.
        //
        fn report(self: *Self, root: *Root) !void {
            try self.list.append_changed(root.path);
            root.reported_ns = self.now_ns();
            root.is_pending = false;
        }

        //
        // Reports every root whose held-back change has waited out its throttle time.
        //
        fn report_pending(self: *Self) !void {
            const current_ns = self.now_ns();
            for (self.roots.items) |*root| {
                if (!root.is_pending) {
                    continue;
                }
                if (current_ns - root.reported_ns.? >= self.throttle_ns()) {
                    try self.report(root);
                }
            }
        }

        //
        // When the earliest held-back change is due, or null when none is held back.
        //
        fn pending_due_ns(self: *const Self) ?i96 {
            var earliest: ?i96 = null;
            for (self.roots.items) |root| {
                if (!root.is_pending) {
                    continue;
                }
                const due_ns = root.reported_ns.? + self.throttle_ns();
                if (earliest == null or due_ns < earliest.?) {
                    earliest = due_ns;
                }
            }
            return earliest;
        }

        //
        // The throttle time in nanoseconds, the unit of the clock.
        //
        fn throttle_ns(self: *const Self) i96 {
            return @as(i96, self.options.throttle_ms) * std.time.ns_per_ms;
        }

        //
        // The index of the root `path` is in, or null when it is in none of them.
        //
        fn root_of(self: *const Self, path: []const u8) ?usize {
            for (self.roots.items, 0..) |root, index| {
                if (paths.is_within(path, root.path)) {
                    return index;
                }
            }
            return null;
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
