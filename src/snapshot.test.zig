//
// Tests for the snapshot, run against the in-memory file system so every case, including
// failures, is exact and fast.
//

const std = @import("std");
const event_module = @import("event.zig");
const mock_io_module = @import("mock_io");
const options_module = @import("options.zig");
const snapshot_module = @import("snapshot.zig");

const testing = std.testing;
const EventKind = event_module.EventKind;
const EventList = event_module.EventList;
const MockIo = mock_io_module.MockIo;
const native_path = mock_io_module.native_path;
const Snapshot = snapshot_module.Snapshot;

//
// One event a test expects.
//
const Expected = struct {
    //
    // What happened.
    //
    kind: EventKind,
    path: []const u8,
    is_directory: bool,
};

//
// Builds the expected event for each kind of change, so expectations read as one call each.
//
fn created_file(path: []const u8) Expected {
    return expected_event(.created, path, false);
}

fn created_directory(path: []const u8) Expected {
    return expected_event(.created, path, true);
}

fn modified_file(path: []const u8) Expected {
    return expected_event(.modified, path, false);
}

fn deleted_file(path: []const u8) Expected {
    return expected_event(.deleted, path, false);
}

fn deleted_directory(path: []const u8) Expected {
    return expected_event(.deleted, path, true);
}

fn expected_event(kind: EventKind, path: []const u8, is_directory: bool) Expected {
    return .{
        .kind = kind,
        .path = path,
        .is_directory = is_directory,
    };
}

//
// Orders expected events by path, then kind, so two lists can be compared in any order.
//
fn is_expected_less(context: void, left: Expected, right: Expected) bool {
    _ = context;
    const order = std.mem.order(u8, left.path, right.path);
    if (order == .eq) {
        return @intFromEnum(left.kind) < @intFromEnum(right.kind);
    }
    return order == .lt;
}

//
// Checks the list holds exactly the expected events, in any order, because hash map order
// decides the order the snapshot finds them in.
//
fn expect_events(list: *const EventList, expected: []const Expected) !void {
    const actual = try testing.allocator.alloc(Expected, list.events.items.len);
    defer testing.allocator.free(actual);
    for (list.events.items, 0..) |item, index| {
        actual[index] = .{
            .kind = item.kind,
            .path = item.path,
            .is_directory = item.is_directory,
        };
    }
    const wanted = try testing.allocator.dupe(Expected, expected);
    defer testing.allocator.free(wanted);
    std.mem.sort(Expected, actual, {}, is_expected_less);
    std.mem.sort(Expected, wanted, {}, is_expected_less);
    if (actual.len != wanted.len) {
        std.debug.print("expected {d} events, found {d}:\n", .{ wanted.len, actual.len });
        for (actual) |item| {
            std.debug.print("  {t} {s} {}\n", .{ item.kind, item.path, item.is_directory });
        }
        return error.TestExpectedEqual;
    }
    for (actual, wanted) |found, want| {
        try testing.expectEqual(want.kind, found.kind);
        try testing.expectEqualStrings(want.path, found.path);
        try testing.expectEqual(want.is_directory, found.is_directory);
    }
}

//
// A mock file system, options, snapshot and event list wired together for one test.
//
const Fixture = struct {
    //
    // The in-memory file system.
    //
    mock: MockIo,

    //
    // The settings, which leave out `.log` files.
    //
    options: options_module.Options,

    //
    // The snapshot under test.
    //
    snapshot: Snapshot,

    //
    // The events and problems found.
    //
    list: EventList,

    //
    // Builds the fixture in place, with a small tree holding an excluded directory and file.
    //
    fn init(self: *Fixture) !void {
        self.mock.init(testing.allocator);
        self.options = .{
            .excluded_extensions = &.{".log"},
        };
        self.snapshot = Snapshot.init(testing.allocator, self.mock.io(), &self.options);
        self.list = EventList.init(testing.allocator);
        try self.mock.add_directory(native_path("/root"));
        try self.mock.add_file(native_path("/root/a.txt"), 1);
        try self.mock.add_directory(native_path("/root/sub"));
        try self.mock.add_file(native_path("/root/sub/b.txt"), 2);
        try self.mock.add_directory(native_path("/root/node_modules"));
        try self.mock.add_file(native_path("/root/node_modules/c.js"), 3);
        try self.mock.add_file(native_path("/root/skip.log"), 4);
    }

    //
    // Frees the fixture.
    //
    fn deinit(self: *Fixture) void {
        self.list.deinit();
        self.snapshot.deinit();
        self.mock.deinit();
    }
};

//
// Goal: adding a root records its tree without events and leaves excluded entries out.
// Method: add a root holding an excluded directory and an excluded extension, then check the
// recorded directories and that no events were reported.
//
test "add_root records the tree silently and applies exclusions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.snapshot.add_root(native_path("/root/"), &fixture.list);
    try expect_events(&fixture.list, &.{});
    try testing.expectEqual(@as(u32, 2), fixture.snapshot.directory_count());
    try testing.expect(fixture.snapshot.contains_directory(native_path("/root")));
    try testing.expect(fixture.snapshot.contains_directory(native_path("/root/sub")));
    try testing.expect(!fixture.snapshot.contains_directory(native_path("/root/node_modules")));
}

//
// Goal: add_root rejects missing paths, files and roots that overlap an earlier root.
// Method: add each kind of bad root and check the error.
//
test "add_root rejects bad roots" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try testing.expectError(
        error.FileNotFound,
        fixture.snapshot.add_root(native_path("/missing"), &fixture.list),
    );
    try testing.expectError(error.NotDir, fixture.snapshot.add_root(native_path("/root/a.txt"), &fixture.list));
    try fixture.snapshot.add_root(native_path("/root/sub"), &fixture.list);
    try testing.expectError(
        error.OverlappingRoot,
        fixture.snapshot.add_root(native_path("/root"), &fixture.list),
    );
    try testing.expectError(
        error.OverlappingRoot,
        fixture.snapshot.add_root(native_path("/root/sub"), &fixture.list),
    );
}

//
// Goal: rescanning a directory reports created, modified and deleted entries, including
// everything inside new and removed directories.
// Method: change the mock file system in every way, rescan each directory and check the events.
//
test "rescan_directory reports every kind of change" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    fixture.mock.clock_ns = 5;
    fixture.mock.write_file(native_path("/root/a.txt"), 10);
    fixture.mock.remove(native_path("/root/sub"));
    try fixture.mock.add_directory(native_path("/root/new"));
    try fixture.mock.add_directory(native_path("/root/new/deeper"));
    try fixture.mock.add_file(native_path("/root/new/deeper/d.txt"), 1);
    try fixture.mock.add_file(native_path("/root/new.log"), 1);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);

    try expect_events(&fixture.list, &.{
        modified_file(native_path("/root/a.txt")),
        deleted_directory(native_path("/root/sub")),
        deleted_file(native_path("/root/sub/b.txt")),
        created_directory(native_path("/root/new")),
        created_directory(native_path("/root/new/deeper")),
        created_file(native_path("/root/new/deeper/d.txt")),
    });
    try testing.expect(fixture.snapshot.contains_directory(native_path("/root/new/deeper")));
    try testing.expect(!fixture.snapshot.contains_directory(native_path("/root/sub")));

    fixture.list.clear();
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{});
}

//
// Goal: a file replaced with the same size and time still counts as modified, through its new
// inode, and a directory touched in place is not reported.
// Method: replace a file and add a child to a directory, then rescan.
//
test "rescan_directory detects replaced files and ignores directory times" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.add_file(native_path("/root/a.txt"), 1);
    fixture.mock.clock_ns = 9;
    try fixture.mock.add_file(native_path("/root/sub/e.txt"), 1);
    fixture.mock.nodes.getPtr("/root/sub").?.mtime_ns = 9;
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        modified_file(native_path("/root/a.txt")),
    });
}

//
// Goal: an entry that changes kind is reported as deleted and created, and a directory
// replaced by another directory reports its old and new contents.
// Method: turn a file into a directory, a directory into a file and replace a directory.
//
test "rescan_directory reports kind changes and replaced directories" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    fixture.mock.remove(native_path("/root/a.txt"));
    try fixture.mock.add_directory(native_path("/root/a.txt"));
    fixture.mock.remove(native_path("/root/sub"));
    try fixture.mock.add_file(native_path("/root/sub"), 1);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        deleted_file(native_path("/root/a.txt")),
        created_directory(native_path("/root/a.txt")),
        deleted_directory(native_path("/root/sub")),
        deleted_file(native_path("/root/sub/b.txt")),
        created_file(native_path("/root/sub")),
    });

    fixture.list.clear();
    fixture.mock.remove(native_path("/root/a.txt"));
    try fixture.mock.add_directory(native_path("/root/a.txt"));
    try fixture.mock.add_file(native_path("/root/a.txt/inner"), 1);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        deleted_directory(native_path("/root/a.txt")),
        created_directory(native_path("/root/a.txt")),
        created_file(native_path("/root/a.txt/inner")),
    });
}

//
// Goal: check_entry reports a single path's change and ignores excluded or untracked paths.
// Method: create, modify and delete single entries and check each in turn.
//
test "check_entry reports one path" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.add_file(native_path("/root/sub/new.txt"), 1);
    try fixture.snapshot.check_entry(native_path("/root/sub/new.txt"), &fixture.list);
    fixture.mock.clock_ns = 3;
    fixture.mock.write_file(native_path("/root/a.txt"), 7);
    try fixture.snapshot.check_entry(native_path("/root/a.txt"), &fixture.list);
    fixture.mock.remove(native_path("/root/sub/b.txt"));
    try fixture.snapshot.check_entry(native_path("/root/sub/b.txt"), &fixture.list);
    try fixture.mock.add_file(native_path("/root/ignored.log"), 1);
    try fixture.snapshot.check_entry(native_path("/root/ignored.log"), &fixture.list);
    try fixture.snapshot.check_entry(native_path("/root/node_modules/c.js"), &fixture.list);
    try fixture.snapshot.check_entry(native_path("/elsewhere/file"), &fixture.list);
    try fixture.snapshot.check_entry(native_path("/"), &fixture.list);
    try fixture.mock.add_directory(native_path("/root/node_modules2"));
    try fixture.snapshot.check_entry(native_path("/root/node_modules2"), &fixture.list);
    try fixture.mock.add_directory(native_path("/root/node_modules/inner"));
    try fixture.snapshot.check_entry(native_path("/root/node_modules/inner"), &fixture.list);

    try expect_events(&fixture.list, &.{
        created_file(native_path("/root/sub/new.txt")),
        modified_file(native_path("/root/a.txt")),
        deleted_file(native_path("/root/sub/b.txt")),
        created_directory(native_path("/root/node_modules2")),
    });
}

//
// Goal: a deleted root is reported with everything in it and stops being watched.
// Method: remove the root, check it and confirm it is gone from the snapshot.
//
test "check_entry on a deleted root removes it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    fixture.mock.remove(native_path("/root"));
    try fixture.snapshot.check_entry(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        deleted_directory(native_path("/root")),
        deleted_file(native_path("/root/a.txt")),
        deleted_directory(native_path("/root/sub")),
        deleted_file(native_path("/root/sub/b.txt")),
    });
    try testing.expectEqual(@as(u32, 0), fixture.snapshot.directory_count());

    fixture.list.clear();
    try fixture.snapshot.check_entry(native_path("/root"), &fixture.list);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{});
}

//
// Goal: a root that still exists is rescanned when checked.
// Method: add a file to the root and check the root path itself.
//
test "check_entry on a live root rescans it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.add_file(native_path("/root/f.txt"), 1);
    try fixture.snapshot.check_entry(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        created_file(native_path("/root/f.txt")),
    });
}

//
// Goal: a subdirectory that vanished before its rescan is reported through its parent.
// Method: remove a subdirectory and rescan it directly.
//
test "rescan_directory of a vanished subdirectory reports it deleted" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    fixture.mock.remove(native_path("/root/sub"));
    try fixture.snapshot.rescan_directory(native_path("/root/sub"), &fixture.list);
    try expect_events(&fixture.list, &.{
        deleted_directory(native_path("/root/sub")),
        deleted_file(native_path("/root/sub/b.txt")),
    });
}

//
// Goal: rescan_tree finds changes in every directory under a path.
// Method: change two levels of the tree and rescan from the root.
//
test "rescan_tree rescans every directory under a path" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.add_file(native_path("/root/top.txt"), 1);
    try fixture.mock.add_file(native_path("/root/sub/deep.txt"), 1);
    try fixture.snapshot.rescan_tree(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        created_file(native_path("/root/top.txt")),
        created_file(native_path("/root/sub/deep.txt")),
    });
}

//
// Goal: unreadable directories and entries are reported as problems, and a failed listing does
// not report the directory's entries as deleted.
// Method: inject open, read and stat faults and check problems and events.
//
test "faults are reported as problems" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try fixture.mock.add_directory(native_path("/root/locked"));
    try fixture.mock.set_faults(native_path("/root/locked"), .{
        .open = true,
    });
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
    });
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);
    try testing.expectEqual(@as(usize, 2), fixture.list.problems.items.len);
    try testing.expect(fixture.snapshot.contains_directory(native_path("/root/locked")));

    fixture.list.clear();
    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .read = true,
    });
    try fixture.snapshot.rescan_directory(native_path("/root/sub"), &fixture.list);
    try expect_events(&fixture.list, &.{});
    try testing.expectEqual(@as(usize, 1), fixture.list.problems.items.len);
    try testing.expectEqualStrings(native_path("/root/sub"), fixture.list.problems.items[0].path);
    try testing.expectEqual(error.AccessDenied, fixture.list.problems.items[0].reason);

    fixture.list.clear();
    try fixture.snapshot.check_entry(native_path("/root/a.txt"), &fixture.list);
    try testing.expectEqualStrings(native_path("/root/a.txt"), fixture.list.problems.items[0].path);
}

//
// Goal: cancellation is passed to the caller instead of being reported as a problem.
// Method: make opening, reading and reading metadata fail as cancelled.
//
test "cancellation is passed on" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .open = true,
        .is_canceled = true,
    });
    try testing.expectError(
        error.Canceled,
        fixture.snapshot.rescan_directory(native_path("/root/sub"), &fixture.list),
    );
    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .read = true,
        .is_canceled = true,
    });
    try testing.expectError(
        error.Canceled,
        fixture.snapshot.rescan_directory(native_path("/root/sub"), &fixture.list),
    );
    try fixture.mock.set_faults(native_path("/root/sub/b.txt"), .{
        .stat = true,
        .is_canceled = true,
    });
    try fixture.mock.set_faults(native_path("/root/sub"), .{});
    try testing.expectError(
        error.Canceled,
        fixture.snapshot.rescan_directory(native_path("/root/sub"), &fixture.list),
    );
}

//
// Goal: a file whose time changes while its size stays the same counts as modified.
// Method: change only the modification time and rescan.
//
test "rescan_directory detects a time-only change" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    fixture.mock.clock_ns = 77;
    fixture.mock.write_file(native_path("/root/a.txt"), 1);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        modified_file(native_path("/root/a.txt")),
    });
}

//
// Goal: deleting one of several roots removes only that root.
// Method: add two roots, delete the second and check the first is still watched.
//
test "deleting one root keeps the others" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.mock.add_directory(native_path("/other"));
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);
    try fixture.snapshot.add_root(native_path("/other"), &fixture.list);

    fixture.mock.remove(native_path("/other"));
    try fixture.snapshot.check_entry(native_path("/other"), &fixture.list);
    try expect_events(&fixture.list, &.{
        deleted_directory(native_path("/other")),
    });
    try testing.expect(fixture.snapshot.is_root(native_path("/root")));
    try testing.expect(!fixture.snapshot.is_root(native_path("/other")));
}

//
// Goal: symbolic links and other special entries are reported like files.
// Method: add a symbolic link and a pipe and rescan.
//
test "special entries are reported as files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.snapshot.add_root(native_path("/root"), &fixture.list);

    try fixture.mock.put(native_path("/root/link"), .sym_link, 0);
    try fixture.snapshot.rescan_directory(native_path("/root"), &fixture.list);
    try expect_events(&fixture.list, &.{
        created_file(native_path("/root/link")),
    });
}

//
// Goal: trim_root removes trailing separators except where they name a root directory.
// Method: trim paths with and without trailing separators.
//
test "trim_root keeps meaningful separators" {
    try testing.expectEqualStrings("/root", snapshot_module.trim_root("/root//"));
    try testing.expectEqualStrings("/root", snapshot_module.trim_root("/root"));
    try testing.expectEqualStrings("/", snapshot_module.trim_root("/"));
    try testing.expectEqualStrings("/", snapshot_module.trim_root("//"));
}

//
// Goal: root_of finds the root holding a path, and none for a path outside every root.
// Method: add two roots and look up paths inside and outside them.
//
test "root_of finds the root of a path" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.mock.add_directory("/other");
    try fixture.snapshot.add_root("/root", &fixture.list);
    try fixture.snapshot.add_root("/other", &fixture.list);

    try testing.expectEqualStrings("/root", fixture.snapshot.root_of("/root/sub/b.txt").?);
    try testing.expectEqualStrings("/other", fixture.snapshot.root_of("/other").?);
    try testing.expectEqual(@as(?[]const u8, null), fixture.snapshot.root_of("/elsewhere"));
}

//
// Goal: is_within matches a path inside a root only at separator boundaries.
// Method: compare paths that share a prefix with and without a separator.
//
test "is_within respects separators" {
    try testing.expect(snapshot_module.is_within("/root", "/root"));
    try testing.expect(snapshot_module.is_within("/root/a", "/root"));
    try testing.expect(snapshot_module.is_within("/root/a", "/"));
    try testing.expect(!snapshot_module.is_within("/rooted", "/root"));
    try testing.expect(!snapshot_module.is_within("/ro", "/root"));
}

//
// Adds a root, rescans and checks entries, for the allocation failure test.
//
fn run_full_cycle(gpa: std.mem.Allocator) !void {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    const options: options_module.Options = .{};
    var snapshot = Snapshot.init(gpa, mock.io(), &options);
    defer snapshot.deinit();
    var list = EventList.init(gpa);
    defer list.deinit();

    try mock.add_directory(native_path("/root"));
    try mock.add_directory(native_path("/root/sub"));
    try mock.add_file(native_path("/root/sub/a"), 1);
    try snapshot.add_root(native_path("/root"), &list);
    try mock.add_directory(native_path("/root/new"));
    try mock.add_file(native_path("/root/new/b"), 1);
    mock.remove(native_path("/root/sub"));
    try snapshot.rescan_directory(native_path("/root"), &list);
    try snapshot.rescan_tree(native_path("/root"), &list);
    try mock.add_file(native_path("/root/new/c"), 1);
    try snapshot.check_entry(native_path("/root/new/c"), &list);
}

//
// Goal: an allocation failure anywhere in scanning is reported and leaks nothing.
// Method: run a full cycle of add, rescan and check under checkAllAllocationFailures.
//
test "snapshot survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, run_full_cycle, .{});
}
