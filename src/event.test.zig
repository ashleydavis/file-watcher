//
// Tests for the batch list: recording changed roots and problems, and clearing between batches.
//

const std = @import("std");
const event = @import("event.zig");

const testing = std.testing;
const EventList = event.EventList;

//
// Goal: changed roots and problems are recorded with copies of their paths, and a root is
// recorded once however often it changes in a batch.
// Method: append from a buffer twice, overwrite the buffer and check the recorded paths.
//
test "append_changed and append_problem copy the path" {
    var list = EventList.init(testing.allocator);
    defer list.deinit();

    var buffer = "/root".*;
    try list.append_changed(&buffer);
    try list.append_changed(&buffer);
    try list.append_changed("/other");
    try list.append_problem(&buffer, error.AccessDenied, .skipped);
    buffer[1] = 'X';

    try testing.expectEqual(@as(usize, 2), list.changed.items.len);
    try testing.expectEqualStrings("/root", list.changed.items[0]);
    try testing.expectEqualStrings("/other", list.changed.items[1]);
    try testing.expectEqualStrings("/root", list.problems.items[0].path);
    try testing.expectEqual(error.AccessDenied, list.problems.items[0].reason);
    try testing.expectEqual(event.ProblemAction.skipped, list.problems.items[0].action);
}

//
// Goal: clear empties the list so the next batch starts fresh.
// Method: append, clear, append again and check only the second batch is present.
//
test "clear starts a new batch" {
    var list = EventList.init(testing.allocator);
    defer list.deinit();

    try list.append_changed("/root");
    try list.append_problem("/root/old", error.AccessDenied, .polled);
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.changed.items.len);
    try testing.expectEqual(@as(usize, 0), list.problems.items.len);

    try list.append_changed("/root");
    try testing.expectEqual(@as(usize, 1), list.changed.items.len);
}

//
// Appends one change and one problem, for the allocation failure test.
//
fn append_both(gpa: std.mem.Allocator) !void {
    var list = EventList.init(gpa);
    defer list.deinit();

    try list.append_changed("/root");
    try list.append_problem("/root/b", error.AccessDenied, .skipped);
}

//
// Goal: an allocation failure while appending is reported and leaks nothing.
// Method: run the appends under checkAllAllocationFailures.
//
test "append survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, append_both, .{});
}
