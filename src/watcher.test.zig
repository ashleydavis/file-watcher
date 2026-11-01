//
// Tests for the watcher. Most run against the in-memory file system with a scripted backend, so
// quota, fallback and polling behaviour is exact and fast. Two tests run the real native backend
// against a temporary directory to check the parts fit together on the machine running them.
//

const std = @import("std");
const fake_backend = @import("fake_backend");
const hints_module = @import("hints.zig");
const mock_io_module = @import("mock_io");
const options_module = @import("options.zig");
const watcher_module = @import("watcher.zig");

const testing = std.testing;
const Batch = watcher_module.Batch;
const MockIo = mock_io_module.MockIo;
const native_path = mock_io_module.native_path;

//
// A fake backend with the given behaviour, using the library's hint types.
//
fn FakeBackend(comptime config: fake_backend.Config) type {
    return fake_backend.FakeBackend(hints_module.HintSet, hints_module.Scope, config);
}

//
// A watcher on a fake backend that watches each directory, the most common kind.
//
const DirectoryWatcher = watcher_module.GenericWatcher(FakeBackend(.{}));

//
// Whether the batch says `root` changed.
//
fn has_change(batch: Batch, root: []const u8) bool {
    for (batch.changed) |path| {
        if (std.mem.eql(u8, path, root)) {
            return true;
        }
    }
    return false;
}

//
// Whether the batch holds a problem with `reason`.
//
fn has_problem(batch: Batch, reason: anyerror) bool {
    for (batch.problems) |problem| {
        if (problem.reason == reason) {
            return true;
        }
    }
    return false;
}

//
// Fills the mock file system with a small tree, including a directory left out by default.
//
fn add_tree(mock: *MockIo) !void {
    try mock.add_directory(native_path("/root"));
    try mock.add_file(native_path("/root/a.txt"), 1);
    try mock.add_directory(native_path("/root/sub"));
    try mock.add_file(native_path("/root/sub/b.txt"), 1);
    try mock.add_directory(native_path("/root/node_modules"));
}

//
// Goal: in polling mode, a change is reported as its root changing on the next poll, a quiet
// tree times out empty, and excluded changes are left out.
// Method: add a tree, wait with no changes, then change a file, then an excluded file.
//
test "polling reports a changed root on the poll interval" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .method = .polling,
        .poll_interval_ms = 100,
    });
    defer watcher.deinit();
    try watcher.add(native_path("/root/"));

    const stats = watcher.stats();
    try testing.expectEqual(@as(u32, 1), stats.roots);
    try testing.expectEqual(@as(u32, 1), stats.polled_roots);
    try testing.expectEqual(@as(u32, 0), stats.native_watches);
    try testing.expect(!stats.is_native_active);

    const quiet = try watcher.next(250);
    try testing.expectEqual(@as(usize, 0), quiet.changed.len);
    try testing.expectEqual(@as(i96, 250 * std.time.ns_per_ms), mock.clock_ns);

    try mock.add_file(native_path("/root/sub/new.txt"), 1);
    const batch = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 1), batch.changed.len);
    try testing.expectEqualStrings(native_path("/root"), batch.changed[0]);

    try mock.add_file(native_path("/root/node_modules/x.js"), 1);
    const excluded = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 0), excluded.changed.len);
}

//
// Goal: with a backend that watches each directory, every directory that is not excluded is
// watched, hints become changed roots, and new, moved and deleted directories gain or lose
// their watches.
// Method: add a tree, script each kind of hint and check the batches and the watches.
//
test "native watching reports roots and keeps watches in step" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .throttle_ms = 0,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    try testing.expectEqual(@as(u32, 2), watcher.stats().native_watches);
    try testing.expect(watcher.backend.watched.contains(native_path("/root/sub")));
    try testing.expect(!watcher.backend.watched.contains(native_path("/root/node_modules")));

    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub/b.txt"), .scope = .entry }});
    const entry = try watcher.next(1000);
    try testing.expect(has_change(entry, native_path("/root")));

    try mock.add_directory(native_path("/root/sub/new"));
    try mock.add_directory(native_path("/root/sub/new/deeper"));
    try mock.add_directory(native_path("/root/sub/new/node_modules"));
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub/new"), .scope = .directory }});
    const created = try watcher.next(1000);
    try testing.expect(has_change(created, native_path("/root")));
    try testing.expectEqual(@as(u32, 4), watcher.stats().native_watches);

    try watcher.backend.queue(&.{
        .{ .path = native_path("/root/sub"), .scope = .directory },
        .{ .path = native_path("/root/sub/new"), .scope = .directory },
    });
    _ = try watcher.next(1000);
    try testing.expectEqual(@as(u32, 4), watcher.stats().native_watches);

    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .gone }});
    const gone = try watcher.next(1000);
    try testing.expect(has_change(gone, native_path("/root")));
    try testing.expectEqual(@as(u32, 1), watcher.stats().native_watches);

    try watcher.backend.queue(&.{.{ .path = native_path("/root"), .scope = .tree }});
    _ = try watcher.next(1000);
    try testing.expectEqual(@as(u32, 4), watcher.stats().native_watches);

    try watcher.backend.queue(&.{
        .{ .path = native_path("/root/node_modules/x.js"), .scope = .entry },
        .{ .path = native_path("/root/sub/trace.log"), .scope = .entry },
        .{ .path = native_path("/elsewhere/c.txt"), .scope = .entry },
    });
    var options: options_module.Options = .{};
    options.excluded_extensions = &.{".log"};
    watcher.options = options;
    const ignored = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 0), ignored.changed.len);
}

//
// Goal: a backend that watches files watches every file that is not excluded, including files
// in new directories, and runs out of quota on files like on directories.
// Method: add a tree to a file-watching fake, add files, then lower the budget.
//
test "file-watching backends watch files too" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_file(native_path("/root/skip.log"), 1);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{
        .watches_files = true,
    }));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .excluded_extensions = &.{".log"},
        .throttle_ms = 0,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    try testing.expectEqual(@as(u32, 4), watcher.stats().native_watches);
    try testing.expect(watcher.backend.watched.contains(native_path("/root/sub/b.txt")));
    try testing.expect(!watcher.backend.watched.contains(native_path("/root/skip.log")));

    // A directory event alone counts only when names that are not excluded changed.
    try mock.add_file(native_path("/root/sub/trace.log"), 1);
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    const excluded = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 0), excluded.changed.len);
    try mock.add_file(native_path("/root/sub/kept.txt"), 1);
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    const kept = try watcher.next(1000);
    try testing.expect(has_change(kept, native_path("/root")));
    try testing.expectEqual(@as(u32, 5), watcher.stats().native_watches);

    // A deleted directory loses its watches and its recorded names.
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .gone }});
    const gone = try watcher.next(1000);
    try testing.expect(has_change(gone, native_path("/root")));
    try testing.expectEqual(@as(u32, 2), watcher.stats().native_watches);
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .tree }});
    _ = try watcher.next(1000);

    try mock.add_file(native_path("/root/sub/c.txt"), 1);
    watcher.watch_budget = 5;
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    const batch = try watcher.next(1000);
    try testing.expect(has_problem(batch, error.LimitReached));
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_roots);

    // Once polled, a directory event alone is still checked against the recorded names, and a
    // directory that cannot be listed counts as changed.
    try mock.add_file(native_path("/root/more.log"), 1);
    try watcher.backend.queue(&.{.{ .path = native_path("/root"), .scope = .directory }});
    const polled_excluded = try watcher.next(0);
    try testing.expectEqual(@as(usize, 0), polled_excluded.changed.len);
    try watcher.backend.queue(&.{.{ .path = native_path("/root/missing"), .scope = .directory }});
    const unlisted = try watcher.next(0);
    try testing.expect(has_change(unlisted, native_path("/root")));
}

//
// Goal: a backend that watches whole trees uses one watch per root and reports changes anywhere
// under it, and a root that does not fit in the quota is polled, with the quota reported once.
// Method: add three roots to a recursive fake with room for one watch.
//
test "tree backends use one watch per root" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_directory(native_path("/second"));
    try mock.add_directory(native_path("/third"));

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{
        .is_recursive = true,
    }));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .native_watches_max = 1,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    try watcher.add(native_path("/second"));
    try watcher.add(native_path("/third"));
    const stats = watcher.stats();
    try testing.expectEqual(@as(u32, 1), stats.native_watches);
    try testing.expectEqual(@as(u32, 2), stats.polled_roots);

    // Problems found while adding come back in the first batch.
    const first = try watcher.next(0);
    var limit_problems: usize = 0;
    for (first.problems) |problem| {
        if (problem.reason == error.LimitReached) {
            limit_problems += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), limit_problems);

    try watcher.backend.queue(&.{
        .{ .path = native_path("/root/sub/b.txt"), .scope = .entry },
        .{ .path = native_path("/root/sub"), .scope = .tree },
    });
    const batch = try watcher.next(1000);
    try testing.expect(has_change(batch, native_path("/root")));
}

//
// Goal: when native watches run out partway through a tree, the root is polled, keeps its
// native watches, and still reports changes; hints for a polled root report it without adding
// watches.
// Method: cap native watches at one, add a tree, change it and send a directory hint.
//
test "running out of watches polls the root" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .native_watches_max = 1,
        .poll_interval_ms = 100,
        .throttle_ms = 0,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    const stats = watcher.stats();
    try testing.expectEqual(@as(u32, 1), stats.native_watches);
    try testing.expectEqual(@as(u32, 1), stats.polled_roots);

    const first = try watcher.next(0);
    try testing.expect(has_problem(first, error.LimitReached));

    try mock.add_file(native_path("/root/sub/new.txt"), 1);
    const polled = try watcher.next(1000);
    try testing.expect(has_change(polled, native_path("/root")));

    try mock.add_directory(native_path("/root/sub/dir"));
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub/dir"), .scope = .directory }});
    const hinted = try watcher.next(1000);
    try testing.expect(has_change(hinted, native_path("/root")));
    try testing.expectEqual(@as(u32, 1), watcher.stats().native_watches);

    // A root polled already stays as it is when the backend then fails.
    watcher.backend.wait_error = error.Unexpected;
    const failed = try watcher.next(1000);
    try testing.expect(has_problem(failed, error.Unexpected));
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_roots);
}

//
// Goal: a watch the platform refuses is reported, and the watcher carries on: a refused
// directory is left out, a directory that vanished is skipped quietly, and running out of
// platform watches lowers the budget and polls the root.
// Method: make the fake refuse one path with each error.
//
test "refused watches are reported" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{});
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    watcher.backend.failing_path = native_path("/root/sub");
    watcher.backend.watch_error = error.AccessDenied;
    try watcher.add(native_path("/root"));
    const denied = try watcher.next(0);
    try testing.expect(has_problem(denied, error.AccessDenied));
    try testing.expectEqual(@as(u32, 0), watcher.stats().polled_roots);

    watcher.backend.watch_error = error.FileNotFound;
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    const vanished = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 0), vanished.problems.len);

    watcher.backend.watch_error = error.LimitReached;
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    const full = try watcher.next(1000);
    try testing.expect(has_problem(full, error.LimitReached));
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_roots);
    try testing.expectEqual(@as(u32, 1), watcher.stats().watch_budget);
}

//
// Goal: directories that cannot be listed while adding watches are reported, ones that vanished
// are skipped, and cancellation is passed on.
// Method: add a tree with an unopenable and an unreadable directory, then cancel each.
//
test "unreadable directories are reported while watching" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_directory(native_path("/root/locked"));
    try mock.set_faults(native_path("/root/locked"), .{
        .open = true,
    });
    try mock.set_faults(native_path("/root/sub"), .{
        .read = true,
    });

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .throttle_ms = 0,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    const batch = try watcher.next(0);
    try testing.expectEqual(@as(usize, 2), batch.problems.len);

    try watcher.backend.queue(&.{.{ .path = native_path("/root/gone"), .scope = .directory }});
    const vanished = try watcher.next(1000);
    try testing.expectEqual(@as(usize, 0), vanished.problems.len);

    try mock.set_faults(native_path("/root/sub"), .{
        .read = true,
        .is_canceled = true,
    });
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    try testing.expectError(error.Canceled, watcher.next(1000));
    try mock.set_faults(native_path("/root/sub"), .{
        .open = true,
        .is_canceled = true,
    });
    try watcher.backend.queue(&.{.{ .path = native_path("/root/sub"), .scope = .directory }});
    try testing.expectError(error.Canceled, watcher.next(1000));
}

//
// Goal: a backend that cannot start, or fails while waiting, is reported and every root is
// polled; running out of memory while waiting is returned instead.
// Method: use a fake that fails to start, then one whose wait fails.
//
test "backend failures fall back to polling" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Broken = watcher_module.GenericWatcher(FakeBackend(.{
        .init_error = error.SystemResources,
    }));
    var broken: Broken = undefined;
    try broken.init(testing.allocator, mock.io(), &.{});
    defer broken.deinit();
    try broken.add(native_path("/root"));
    const refused = try broken.next(0);
    try testing.expect(has_problem(refused, error.SystemResources));
    try testing.expectEqual(@as(u32, 1), broken.stats().polled_roots);
    broken.wake();

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .poll_interval_ms = 100,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    watcher.backend.wait_error = error.Unexpected;
    const failed = try watcher.next(1000);
    try testing.expect(has_problem(failed, error.Unexpected));
    try testing.expect(!watcher.stats().is_native_active);
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_roots);
    try mock.add_file(native_path("/root/after.txt"), 1);
    const polled = try watcher.next(1000);
    try testing.expect(has_change(polled, native_path("/root")));

    var short: DirectoryWatcher = undefined;
    try short.init(testing.allocator, mock.io(), &.{});
    defer short.deinit();
    short.backend.mock = &mock;
    try short.add(native_path("/root"));
    short.backend.wait_error = error.OutOfMemory;
    try testing.expectError(error.OutOfMemory, short.next(1000));
}

//
// Goal: a zero quota polls everything without a problem, and bad roots are refused with the
// right error.
// Method: watch with a zero quota, then add a missing path, a file and overlapping roots.
//
test "zero quota polls and bad roots are refused" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .quota_percent = 0,
    });
    defer watcher.deinit();
    try watcher.add(native_path("/root/sub"));
    try testing.expect(!watcher.stats().is_native_active);
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_roots);
    try testing.expectError(error.FileNotFound, watcher.add(native_path("/missing")));
    try testing.expectError(error.NotDir, watcher.add(native_path("/root/a.txt")));
    try testing.expectError(error.OverlappingRoot, watcher.add(native_path("/root")));
    try mock.add_directory(native_path("/root/sub/inner"));
    try testing.expectError(error.OverlappingRoot, watcher.add(native_path("/root/sub/inner")));
}

//
// Goal: a zero timeout collects queued hints at once, and wake makes a wait return at once with
// later waits blocking again, both natively and when polling.
// Method: queue a hint and call next(0); wake each kind of watcher before a long wait.
//
test "zero timeouts and wake return at once" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    var native: DirectoryWatcher = undefined;
    try native.init(testing.allocator, mock.io(), &.{});
    defer native.deinit();
    native.backend.mock = &mock;
    try native.add(native_path("/root"));

    try native.backend.queue(&.{.{ .path = native_path("/root/a.txt"), .scope = .entry }});
    const queued = try native.next(0);
    try testing.expect(has_change(queued, native_path("/root")));
    try testing.expectEqual(@as(i96, 0), mock.clock_ns);

    native.wake();
    const woken = try native.next(60_000);
    try testing.expectEqual(@as(usize, 0), woken.changed.len);
    try testing.expectEqual(@as(i96, 0), mock.clock_ns);
    _ = try native.next(100);
    try testing.expectEqual(@as(i96, 100 * std.time.ns_per_ms), mock.clock_ns);

    var polling: DirectoryWatcher = undefined;
    try polling.init(testing.allocator, mock.io(), &.{
        .method = .polling,
        .poll_interval_ms = 60_000,
    });
    defer polling.deinit();
    try polling.add(native_path("/root"));
    const quiet = try polling.next(0);
    try testing.expectEqual(@as(usize, 0), quiet.changed.len);

    const before_ns = mock.clock_ns;
    polling.wake();
    _ = try polling.next(60_000);
    try testing.expectEqual(before_ns, mock.clock_ns);
}

//
// Goal: a thread blocked in next on the platform's own backend returns as soon as another thread
// calls wake, both with native watching and with polling.
// Method: start a thread that calls next with a one-minute timeout until told to stop, then stop
// it with wake and check it ended long before the timeout.
//
test "wake stops a thread waiting in next" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &base);

    for ([_]options_module.Method{ .native, .polling }) |method| {
        const watcher = try testing.allocator.create(watcher_module.Watcher);
        defer testing.allocator.destroy(watcher);
        try watcher.init(testing.allocator, testing.io, &.{
            .method = method,
            .poll_interval_ms = 60_000,
        });
        defer watcher.deinit();
        try watcher.add(base[0..length]);

        var stop: std.atomic.Value(bool) = .init(false);
        const thread = try std.Thread.spawn(.{}, wait_until_stopped, .{ watcher, &stop });
        try testing.io.sleep(.fromMilliseconds(100), .awake);
        const start = std.Io.Timestamp.now(testing.io, .awake);
        stop.store(true, .release);
        watcher.wake();
        thread.join();
        const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
        try testing.expect(elapsed.nanoseconds < 10 * std.time.ns_per_s);
    }
}

//
// Calls next with a one-minute timeout until `stop` is set, as an app's watcher thread does.
//
fn wait_until_stopped(watcher: *watcher_module.Watcher, stop: *std.atomic.Value(bool)) void {
    while (!stop.load(.acquire)) {
        _ = watcher.next(60_000) catch unreachable;
    }
}

//
// Goal: the platform's own backend reports a real change, including one in a directory created
// after the watch started.
// Method: watch a temporary directory, create a file, then a directory and a file inside it.
//
test "native watcher sees a real change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &base);
    const root = base[0..length];

    var watcher: watcher_module.Watcher = undefined;
    try watcher.init(testing.allocator, testing.io, &.{});
    defer watcher.deinit();
    try watcher.add(root);
    try testing.expect(watcher.stats().is_native_active);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    try expect_change(&watcher, root);

    try tmp.dir.createDir(testing.io, "made", .default_dir);
    try expect_change(&watcher, root);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "made/inner.txt",
        .data = "x",
    });
    try expect_change(&watcher, root);
}

//
// Waits up to ten seconds for `root` to be reported changed.
//
fn expect_change(watcher: *watcher_module.Watcher, root: []const u8) !void {
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        const batch = try watcher.next(1000);
        if (has_change(batch, root)) {
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn run_watcher(gpa: std.mem.Allocator, mock: *MockIo) !void {
    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{
        .watches_files = true,
    }));
    var watcher: Watcher = undefined;
    try watcher.init(gpa, mock.io(), &.{
        .poll_interval_ms = 10,
    });
    defer watcher.deinit();
    watcher.backend.mock = mock;
    watcher.watch_budget = 5;
    try watcher.add(native_path("/root"));
    try watcher.backend.queue(&.{
        .{ .path = native_path("/root/more"), .scope = .directory },
        .{ .path = native_path("/root/sub"), .scope = .gone },
    });
    _ = try watcher.next(100);
    _ = try watcher.next(100);
}

//
// Goal: an allocation failure anywhere in the watcher is reported and leaks nothing.
// Method: run a watcher through native and polled paths under checkAllAllocationFailures.
//
test "watcher survives allocation failure" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_directory(native_path("/root/more"));
    try mock.add_file(native_path("/root/more/f"), 1);
    try testing.checkAllAllocationFailures(testing.allocator, run_watcher, .{&mock});
}

//
// Goal: a root's first change is reported at once, later changes within the throttle time are
// held back and reported once when it ends, and a throttle of 0 reports every batch.
// Method: script hints at known times on the mock clock and check when the root is reported.
//
test "changes are throttled per root" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_directory(native_path("/second"));

    var watcher: DirectoryWatcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .throttle_ms = 1000,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    try watcher.add(native_path("/second"));

    try watcher.backend.queue(&.{.{ .path = native_path("/root/a.txt"), .scope = .entry }});
    const first = try watcher.next(0);
    try testing.expect(has_change(first, native_path("/root")));
    try testing.expectEqual(@as(i96, 0), mock.clock_ns);

    mock.clock_ns += 100 * std.time.ns_per_ms;
    try watcher.backend.queue(&.{
        .{ .path = native_path("/root/a.txt"), .scope = .entry },
        .{ .path = native_path("/second/b.txt"), .scope = .entry },
    });
    const held = try watcher.next(0);
    try testing.expect(!has_change(held, native_path("/root")));
    try testing.expect(has_change(held, native_path("/second")));

    const released = try watcher.next(60_000);
    try testing.expect(has_change(released, native_path("/root")));
    try testing.expectEqual(@as(i96, 1000 * std.time.ns_per_ms), mock.clock_ns);

    const quiet = try watcher.next(500);
    try testing.expectEqual(@as(usize, 0), quiet.changed.len);

    var unthrottled: DirectoryWatcher = undefined;
    try unthrottled.init(testing.allocator, mock.io(), &.{
        .throttle_ms = 0,
    });
    defer unthrottled.deinit();
    unthrottled.backend.mock = &mock;
    try unthrottled.add(native_path("/root"));
    for (0..2) |_| {
        try unthrottled.backend.queue(&.{.{ .path = native_path("/root/a.txt"), .scope = .entry }});
        const batch = try unthrottled.next(0);
        try testing.expect(has_change(batch, native_path("/root")));
    }
}
