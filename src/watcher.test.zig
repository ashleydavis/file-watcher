//
// Tests for the watcher. Most run against the in-memory file system with a scripted backend, so
// quota, fallback and polling behaviour is exact and fast. One test runs the real native backend
// against a temporary directory to check the parts fit together on the machine running the tests.
//

const std = @import("std");
const event_module = @import("event.zig");
const fake_backend = @import("fake_backend");
const hints_module = @import("hints.zig");
const mock_io_module = @import("mock_io");
const options_module = @import("options.zig");
const watcher_module = @import("watcher.zig");

const testing = std.testing;
const Batch = watcher_module.Batch;
const EventKind = event_module.EventKind;
const MockIo = mock_io_module.MockIo;
const native_path = mock_io_module.native_path;
const Options = options_module.Options;

//
// A fake backend with the given behaviour, using the library's hint types.
//
fn FakeBackend(comptime config: fake_backend.Config) type {
    return fake_backend.FakeBackend(hints_module.HintSet, hints_module.Scope, config);
}

//
// Whether the batch holds an event of `kind` for `path`.
//
fn has_event(batch: Batch, kind: EventKind, path: []const u8) bool {
    for (batch.events) |item| {
        if (item.kind == kind) {
            if (std.mem.eql(u8, item.path, path)) {
                return true;
            }
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
// Fills the mock file system with a small tree.
//
fn add_tree(mock: *MockIo) !void {
    try mock.add_directory(native_path("/root"));
    try mock.add_file(native_path("/root/a.txt"), 1);
    try mock.add_directory(native_path("/root/sub"));
    try mock.add_file(native_path("/root/sub/b.txt"), 1);
    try mock.add_directory(native_path("/root/node_modules"));
}

//
// Goal: in polling mode, changes are found on the next poll and a quiet tree times out empty.
// Method: add a tree, wait with no changes, then change files and wait again.
//
test "polling finds changes on the poll interval" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .method = .polling,
        .poll_interval_ms = 100,
    });
    defer watcher.deinit();
    try watcher.add(native_path("/root"));

    const stats = watcher.stats();
    try testing.expectEqual(@as(u32, 2), stats.polled_directories);
    try testing.expectEqual(@as(u32, 2), stats.directories);
    try testing.expect(!stats.is_native_active);

    const quiet = try watcher.next(250);
    try testing.expectEqual(@as(usize, 0), quiet.events.len);
    try testing.expectEqual(@as(i96, 250 * std.time.ns_per_ms), mock.clock_ns);

    try mock.add_file(native_path("/root/sub/new.txt"), 1);
    try mock.add_directory(native_path("/root/sub/dir"));
    const batch = try watcher.next(1000);
    try testing.expect(has_event(batch, .created, native_path("/root/sub/new.txt")));
    try testing.expect(has_event(batch, .created, native_path("/root/sub/dir")));
    try testing.expectEqual(@as(u32, 3), watcher.stats().polled_directories);

    mock.remove(native_path("/root/sub"));
    const removed = try watcher.next(1000);
    try testing.expect(has_event(removed, .deleted, native_path("/root/sub")));
    try testing.expect(has_event(removed, .deleted, native_path("/root/sub/dir")));
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_directories);
}

//
// Goal: with a native backend, every directory is watched, hints become events and new or
// deleted directories gain or lose their watch.
// Method: add a tree, script hints for created and deleted entries and check events and stats.
//
test "native watching turns hints into events" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{});
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root/"));

    try testing.expect(watcher.stats().is_native_active);
    try testing.expectEqual(@as(u32, 2), watcher.stats().native_watches);
    try testing.expect(watcher.backend.watched.contains(native_path("/root")));
    try testing.expect(watcher.backend.watched.contains(native_path("/root/sub")));

    try mock.add_directory(native_path("/root/new"));
    try mock.add_file(native_path("/root/new/c.txt"), 1);
    try watcher.backend.queue(&.{
        .{
            .path = native_path("/root/new"),
            .scope = .entry,
        },
    });
    const created = try watcher.next(1000);
    try testing.expect(has_event(created, .created, native_path("/root/new")));
    try testing.expect(has_event(created, .created, native_path("/root/new/c.txt")));
    try testing.expect(watcher.backend.watched.contains(native_path("/root/new")));

    mock.remove(native_path("/root/sub"));
    try mock.add_file(native_path("/root/d.txt"), 1);
    try watcher.backend.queue(&.{
        .{
            .path = native_path("/root"),
            .scope = .directory,
        },
        .{
            .path = native_path("/root"),
            .scope = .tree,
        },
    });
    const changed = try watcher.next(1000);
    try testing.expect(has_event(changed, .deleted, native_path("/root/sub")));
    try testing.expect(has_event(changed, .created, native_path("/root/d.txt")));
    try testing.expect(!watcher.backend.watched.contains(native_path("/root/sub")));
    try testing.expectEqual(@as(u32, 2), watcher.stats().native_watches);

    const quiet = try watcher.next(10);
    try testing.expectEqual(@as(usize, 0), quiet.events.len);
}

//
// Goal: a zero timeout collects native events already queued without waiting, so a caller can
// check for changes from a timer or an event loop.
// Method: queue a hint, call next with a zero timeout and check the event arrives and the clock
// did not move.
//
test "next with a zero timeout collects queued events" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{});
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));

    const empty = try watcher.next(0);
    try testing.expectEqual(@as(usize, 0), empty.events.len);

    try mock.add_file(native_path("/root/queued.txt"), 1);
    try watcher.backend.queue(&.{
        .{
            .path = native_path("/root/queued.txt"),
            .scope = .entry,
        },
    });
    const batch = try watcher.next(0);
    try testing.expect(has_event(batch, .created, native_path("/root/queued.txt")));
    try testing.expectEqual(@as(i96, 0), mock.clock_ns);

    var polling: Watcher = undefined;
    try polling.init(testing.allocator, mock.io(), &.{
        .method = .polling,
    });
    defer polling.deinit();
    try polling.add(native_path("/root"));
    const quiet = try polling.next(0);
    try testing.expectEqual(@as(usize, 0), quiet.events.len);
    try testing.expectEqual(@as(i96, 0), mock.clock_ns);
}

//
// Goal: a recursive backend watches only roots, and a file-watching backend watches files and
// drops their watches when they are deleted.
// Method: add a tree to each kind of fake backend and check what is watched.
//
test "recursive and file-watching backends" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Recursive = watcher_module.GenericWatcher(FakeBackend(.{
        .is_recursive = true,
    }));
    var recursive: Recursive = undefined;
    try recursive.init(testing.allocator, mock.io(), &.{});
    defer recursive.deinit();
    try recursive.add(native_path("/root"));
    try testing.expectEqual(@as(usize, 1), recursive.backend.watched.count());
    try mock.add_directory(native_path("/root/new"));
    try recursive.backend.queue(&.{
        .{
            .path = native_path("/root/new"),
            .scope = .entry,
        },
    });
    const batch = try recursive.next(1000);
    try testing.expect(has_event(batch, .created, native_path("/root/new")));
    try testing.expectEqual(@as(usize, 1), recursive.backend.watched.count());

    const Files = watcher_module.GenericWatcher(FakeBackend(.{
        .watches_files = true,
    }));
    var files: Files = undefined;
    try files.init(testing.allocator, mock.io(), &.{});
    defer files.deinit();
    files.backend.mock = &mock;
    try files.add(native_path("/root"));
    try testing.expect(files.backend.watched.contains(native_path("/root/a.txt")));
    try testing.expect(files.backend.watched.contains(native_path("/root/sub/b.txt")));

    mock.remove(native_path("/root/a.txt"));
    try files.backend.queue(&.{
        .{
            .path = native_path("/root/a.txt"),
            .scope = .entry,
        },
    });
    const deleted = try files.next(1000);
    try testing.expect(has_event(deleted, .deleted, native_path("/root/a.txt")));
    try testing.expect(!files.backend.watched.contains(native_path("/root/a.txt")));
}

//
// Goal: with a tree backend, every directory under a root is polled when the root cannot be
// watched natively or the watcher polls, including directories created later.
// Method: refuse the root's watch, add a tree and create a directory; then repeat in polling
// mode.
//
test "tree backends poll every directory of a refused root" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Recursive = watcher_module.GenericWatcher(FakeBackend(.{
        .is_recursive = true,
    }));
    var refused: Recursive = undefined;
    try refused.init(testing.allocator, mock.io(), &.{
        .poll_interval_ms = 10,
    });
    defer refused.deinit();
    refused.backend.mock = &mock;
    refused.backend.failing_path = native_path("/root");
    refused.backend.watch_error = error.AccessDenied;
    try refused.add(native_path("/root"));
    try testing.expectEqual(@as(u32, 2), refused.stats().polled_directories);
    try testing.expectEqual(@as(u32, 0), refused.stats().native_watches);

    try mock.add_directory(native_path("/root/sub/later"));
    try mock.add_file(native_path("/root/sub/later/file.txt"), 1);
    var found = false;
    var attempts: u32 = 0;
    while (attempts < 3) : (attempts += 1) {
        const batch = try refused.next(100);
        if (has_event(batch, .created, native_path("/root/sub/later/file.txt"))) {
            found = true;
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(u32, 3), refused.stats().polled_directories);

    var polling: Recursive = undefined;
    try polling.init(testing.allocator, mock.io(), &.{
        .method = .polling,
    });
    defer polling.deinit();
    try polling.add(native_path("/root"));
    try testing.expectEqual(@as(u32, 3), polling.stats().polled_directories);
}

//
// Goal: once the quota is used up, further paths are polled and the limit is reported once.
// Method: lower the budget, add a tree and check what is watched, polled and reported.
//
test "quota overflow falls back to polling" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);
    try mock.add_directory(native_path("/root/more"));

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{
        .watches_files = true,
    }));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .poll_interval_ms = 50,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    watcher.watch_budget = 1;
    try watcher.add(native_path("/root"));

    const stats = watcher.stats();
    try testing.expectEqual(@as(u32, 1), stats.native_watches);
    try testing.expect(stats.polled_directories >= 2);
    const batch = try watcher.next(0);
    try testing.expectEqual(@as(usize, 1), batch.problems.len);
    try testing.expect(has_problem(batch, error.LimitReached));

    // Which directory got the one native watch depends on hash order, so the new file goes into
    // a directory known to be polled.
    const new_path = try std.fs.path.join(testing.allocator, &.{
        watcher.polled.keys()[0],
        "new.txt",
    });
    defer testing.allocator.free(new_path);
    try mock.add_file(new_path, 1);
    const polled = try watcher.next(1000);
    try testing.expect(has_event(polled, .created, new_path));
}

//
// Goal: refused watches are reported and polled, and a platform limit hit before the quota
// lowers the budget.
// Method: make the fake refuse one path with access denied, then another with the limit error.
//
test "refused watches are reported and polled" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{});
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    watcher.backend.failing_path = native_path("/root/sub");
    watcher.backend.watch_error = error.AccessDenied;
    try watcher.add(native_path("/root"));

    const batch = try watcher.next(0);
    try testing.expect(has_problem(batch, error.AccessDenied));
    try testing.expectEqualStrings(native_path("/root/sub"), batch.problems[0].path);
    try testing.expectEqual(@as(u32, 1), watcher.stats().polled_directories);

    try mock.add_directory(native_path("/root/limited"));
    watcher.backend.failing_path = native_path("/root/limited");
    watcher.backend.watch_error = error.LimitReached;
    try watcher.backend.queue(&.{
        .{
            .path = native_path("/root/limited"),
            .scope = .entry,
        },
    });
    const limited = try watcher.next(1000);
    try testing.expect(has_event(limited, .created, native_path("/root/limited")));
    try testing.expect(has_problem(limited, error.LimitReached));
    try testing.expectEqual(watcher.stats().native_watches, watcher.stats().watch_budget);
}

//
// Goal: a backend that fails to start or breaks while waiting is reported and replaced by
// polling, which keeps finding changes.
// Method: use a fake that fails to start, and one whose wait fails.
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
    const start = try broken.next(0);
    try testing.expect(has_problem(start, error.SystemResources));
    try testing.expectEqualStrings("", start.problems[0].path);
    try testing.expectEqual(@as(u32, 2), broken.stats().polled_directories);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .poll_interval_ms = 10,
    });
    defer watcher.deinit();
    watcher.backend.mock = &mock;
    try watcher.add(native_path("/root"));
    watcher.backend.wait_error = error.Unexpected;
    const failed = try watcher.next(1000);
    try testing.expect(has_problem(failed, error.Unexpected));
    try testing.expect(!watcher.stats().is_native_active);
    try testing.expectEqual(@as(u32, 2), watcher.stats().polled_directories);

    try mock.add_file(native_path("/root/after.txt"), 1);
    const polled = try watcher.next(1000);
    try testing.expect(has_event(polled, .created, native_path("/root/after.txt")));
}

//
// Goal: a zero quota polls everything without starting the backend, and bad roots are refused.
// Method: init with a zero quota, add a tree and try to add a file and an overlapping root.
//
test "zero quota polls and bad roots are refused" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try add_tree(&mock);

    const Watcher = watcher_module.GenericWatcher(FakeBackend(.{}));
    var watcher: Watcher = undefined;
    try watcher.init(testing.allocator, mock.io(), &.{
        .quota_percent = 0,
    });
    defer watcher.deinit();
    try watcher.add(native_path("/root"));
    try testing.expect(!watcher.stats().is_native_active);
    try testing.expectEqual(@as(u32, 0), watcher.stats().watch_budget);
    try testing.expectError(error.NotDir, watcher.add(native_path("/root/a.txt")));
    try testing.expectError(error.OverlappingRoot, watcher.add(native_path("/root/sub")));
}

//
// Goal: the watcher using the platform's own backend reports a real file being created.
// Method: watch a temporary directory, write a file and wait for the event.
//
test "native watcher sees a real change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &base);

    var watcher: watcher_module.Watcher = undefined;
    try watcher.init(testing.allocator, testing.io, &.{});
    defer watcher.deinit();
    try watcher.add(base[0..length]);
    try testing.expect(watcher.stats().is_native_active);

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "real.txt",
        .data = "x",
    });
    var expected: [std.fs.max_path_bytes]u8 = undefined;
    const separator = std.fs.path.sep_str;
    const path = try std.fmt.bufPrint(&expected, "{s}" ++ separator ++ "real.txt", .{
        base[0..length],
    });
    var attempts: u32 = 0;
    while (attempts < 10) : (attempts += 1) {
        const batch = try watcher.next(1000);
        if (has_event(batch, .created, path)) {
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
    watcher.watch_budget = 3;
    try watcher.add(native_path("/root"));
    try watcher.backend.queue(&.{
        .{
            .path = native_path("/root/sub"),
            .scope = .directory,
        },
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
