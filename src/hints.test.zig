//
// Tests for the hint set: merging repeated hints and joining child paths.
//

const std = @import("std");
const mock_io_module = @import("mock_io");
const hints = @import("hints.zig");

const testing = std.testing;
const native_path = mock_io_module.native_path;
const HintSet = hints.HintSet;

//
// Goal: repeated hints for one path merge into one record with every requested check.
// Method: add the same path at each scope and check the merged record.
//
test "add merges scopes for one path" {
    var set = HintSet.init(testing.allocator);
    defer set.deinit();

    try set.add(native_path("/root/a"), .entry);
    try set.add(native_path("/root/a"), .entry);
    try set.add(native_path("/root/a"), .directory);
    try set.add(native_path("/root/a"), .tree);
    try set.add(native_path("/root/b"), .entry);

    try testing.expectEqual(@as(usize, 2), set.paths.count());
    const checks = set.paths.get(native_path("/root/a")).?;
    try testing.expect(checks.entry);
    try testing.expect(checks.directory);
    try testing.expect(checks.tree);
    try testing.expectEqualStrings(native_path("/root/a"), set.paths.keys()[0]);
    try testing.expectEqualStrings(native_path("/root/b"), set.paths.keys()[1]);

    set.clear();
    try testing.expectEqual(@as(usize, 0), set.paths.count());
}

//
// Goal: add_child joins the parent and name with one separator, including at the file system
// root.
// Method: add children of a normal directory and of native_path("/").
//
test "add_child joins parent and name" {
    var set = HintSet.init(testing.allocator);
    defer set.deinit();

    try set.add_child(native_path("/root"), "a.txt", .entry);
    try set.add_child(native_path("/"), "top", .entry);
    try testing.expect(set.paths.contains(native_path("/root/a.txt")));
    try testing.expect(set.paths.contains(native_path("/top")));

    try testing.expectEqual(@as(usize, 2), set.paths.count());
}

//
// Adds hints of each kind, for the allocation failure test.
//
fn add_paths(gpa: std.mem.Allocator) !void {
    var set = HintSet.init(gpa);
    defer set.deinit();

    try set.add(native_path("/root/a"), .entry);
    try set.add_child(native_path("/root"), "b", .tree);
}

//
// Goal: an allocation failure while adding is reported and leaks nothing.
// Method: run the adds under checkAllAllocationFailures.
//
test "add survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, add_paths, .{});
}
