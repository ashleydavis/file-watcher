//
// Tests for the event list: recording events and problems, and clearing between batches.
//

const std = @import("std");
const event = @import("event.zig");

const testing = std.testing;
const EventList = event.EventList;

//
// Goal: events and problems are recorded with copies of their paths.
// Method: append from a buffer, overwrite the buffer and check the recorded paths are intact.
//
test "append_event and append_problem copy the path" {
    var list = EventList.init(testing.allocator);
    defer list.deinit();

    var buffer = "/root/a.txt".*;
    try list.append_event(.created, &buffer, false);
    try list.append_problem(&buffer, error.AccessDenied, .skipped);
    buffer[1] = 'X';

    try testing.expectEqual(@as(usize, 1), list.events.items.len);
    try testing.expectEqualStrings("/root/a.txt", list.events.items[0].path);
    try testing.expectEqual(event.EventKind.created, list.events.items[0].kind);
    try testing.expect(!list.events.items[0].is_directory);
    try testing.expectEqualStrings("/root/a.txt", list.problems.items[0].path);
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

    try list.append_event(.deleted, "/root/old", true);
    try list.append_problem("/root/old", error.AccessDenied, .polled);
    list.clear();
    try testing.expectEqual(@as(usize, 0), list.events.items.len);
    try testing.expectEqual(@as(usize, 0), list.problems.items.len);

    try list.append_event(.modified, "/root/new", false);
    try testing.expectEqual(@as(usize, 1), list.events.items.len);
    try testing.expectEqualStrings("/root/new", list.events.items[0].path);
}

//
// Appends one event and one problem, for the allocation failure test.
//
fn append_both(gpa: std.mem.Allocator) !void {
    var list = EventList.init(gpa);
    defer list.deinit();

    try list.append_event(.created, "/root/a", false);
    try list.append_problem("/root/b", error.AccessDenied, .skipped);
}

//
// Goal: an allocation failure while appending is reported and leaks nothing.
// Method: run the appends under checkAllAllocationFailures.
//
test "append survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, append_both, .{});
}
