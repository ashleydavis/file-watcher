//
// Tests for option validation.
//

const std = @import("std");
const options_module = @import("options.zig");

const testing = std.testing;
const Options = options_module.Options;

//
// Goal: the defaults are valid and include node_modules.
// Method: validate a default Options and search its excluded directories.
//
test "defaults are valid and exclude node_modules" {
    const options: Options = .{};
    try testing.expect(options_module.is_valid(&options));

    var found = false;
    for (options.excluded_directories) |name| {
        if (std.mem.eql(u8, name, "node_modules")) {
            found = true;
        }
    }
    try testing.expect(found);
}

//
// Goal: out of range settings are rejected and the edges of the range are accepted.
// Method: validate options at and beyond each limit.
//
test "is_valid rejects out of range settings" {
    try testing.expect(options_module.is_valid(&.{
        .quota_percent = 0,
    }));
    try testing.expect(options_module.is_valid(&.{
        .quota_percent = 100,
    }));
    try testing.expect(!options_module.is_valid(&.{
        .quota_percent = 101,
    }));
    try testing.expect(options_module.is_valid(&.{
        .poll_interval_ms = 1,
    }));
    try testing.expect(!options_module.is_valid(&.{
        .poll_interval_ms = 0,
    }));
}
