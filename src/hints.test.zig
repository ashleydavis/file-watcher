//
// Tests for the hint set: merging repeated hints and joining child paths.
//

const std = @import("std");
const hints = @import("hints.zig");

const testing = std.testing;
const HintSet = hints.HintSet;

//
// Goal: repeated hints for one path merge into one record with every requested check.
// Method: add the same path at each scope and check the merged record.
//
test "add merges scopes for one path" {
    var set = HintSet.init(testing.allocator);
    defer set.deinit();

    try set.add("/root/a", .entry);
    try set.add("/root/a", .entry);
    try set.add("/root/a", .directory);
    try set.add("/root/a", .tree);
    try set.add("/root/b", .entry);

    try testing.expectEqual(@as(usize, 2), set.paths.count());
    const checks = set.paths.get("/root/a").?;
    try testing.expect(checks.entry);
    try testing.expect(checks.directory);
    try testing.expect(checks.tree);
    try testing.expectEqualStrings("/root/a", set.paths.keys()[0]);
    try testing.expectEqualStrings("/root/b", set.paths.keys()[1]);

    set.clear();
    try testing.expectEqual(@as(usize, 0), set.paths.count());
}

//
// Goal: add_child joins the parent and name with one separator, including at the file system
// root.
// Method: add children of a normal directory and of "/".
//
test "add_child joins parent and name" {
    var set = HintSet.init(testing.allocator);
    defer set.deinit();

    try set.add_child("/root", "a.txt", .entry);
    try set.add_child("/", "top", .entry);
    try testing.expect(set.paths.contains("/root/a.txt"));
    try testing.expect(set.paths.contains("/top"));

    try testing.expectEqual(@as(usize, 2), set.paths.count());
}

fn add_paths(gpa: std.mem.Allocator) !void {
    var set = HintSet.init(gpa);
    defer set.deinit();

    try set.add("/root/a", .entry);
    try set.add_child("/root", "b", .tree);
}

//
// Goal: an allocation failure while adding is reported and leaks nothing.
// Method: run the adds under checkAllAllocationFailures.
//
test "add survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, add_paths, .{});
}
