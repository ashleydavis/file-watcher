//
// Tests for the native watch limit and the quota arithmetic.
//

const std = @import("std");
const limit = @import("limit.zig");
const mock_io_module = @import("mock_io");

const testing = std.testing;
const MockIo = mock_io_module.MockIo;

//
// Goal: limits are parsed from the text the kernel writes, and bad text is rejected.
// Method: parse valid, padded, huge, empty and non-numeric text.
//
test "parse_limit reads decimal text" {
    try testing.expectEqual(@as(?u32, 8192), limit.parse_limit("8192\n"));
    try testing.expectEqual(@as(?u32, 65536), limit.parse_limit("  65536 "));
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), limit.parse_limit("99999999999"));
    try testing.expectEqual(@as(?u32, null), limit.parse_limit("\n"));
    try testing.expectEqual(@as(?u32, null), limit.parse_limit("many"));
}

//
// Goal: the budget is the quota share of the limit, rounded down, at every edge.
// Method: compute budgets for zero, partial and full quotas, and for the largest limit.
//
test "watch_budget takes the quota share" {
    try testing.expectEqual(@as(u32, 0), limit.watch_budget(8192, 0));
    try testing.expectEqual(@as(u32, 4096), limit.watch_budget(8192, 50));
    try testing.expectEqual(@as(u32, 8192), limit.watch_budget(8192, 100));
    try testing.expectEqual(@as(u32, 0), limit.watch_budget(1, 99));
    try testing.expectEqual(std.math.maxInt(u32), limit.watch_budget(std.math.maxInt(u32), 100));
}

//
// Goal: an unreadable limit file falls back to the kernel default.
// Method: read the limit through a mock file system that has no /proc.
//
test "read_inotify_limit falls back to the default" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try testing.expectEqual(limit.inotify_watches_default, limit.read_inotify_limit(mock.io()));
}

//
// Goal: the real platform limit is readable and positive on the machine running the tests.
// Method: ask for the native limit through the real I/O implementation.
//
test "native_watch_limit reads the platform limit" {
    const value = try limit.native_watch_limit(testing.io);
    try testing.expect(value > 0);
}
