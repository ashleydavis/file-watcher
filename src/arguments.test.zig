//
// Tests for command line parsing.
//

const std = @import("std");
const arguments = @import("arguments.zig");

const testing = std.testing;
const Command = arguments.Command;

//
// Parses `argv` with an arena that the caller frees.
//
fn parse(arena: *std.heap.ArenaAllocator, argv: []const []const u8) !Command {
    return arguments.parse(arena.allocator(), argv);
}

//
// Goal: help and version win wherever they appear.
// Method: parse each short and long form.
//
test "parse recognises help and version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Command.help, try parse(&arena, &.{"-h"}));
    try testing.expectEqual(Command.help, try parse(&arena, &.{ "dir", "--help" }));
    try testing.expectEqual(Command.version, try parse(&arena, &.{"-V"}));
    try testing.expectEqual(Command.version, try parse(&arena, &.{"--version"}));
}

//
// Goal: every option lands in the configuration, and defaults apply when options are absent.
// Method: parse a command line using every option, and one using none.
//
test "parse reads every option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const command = try parse(&arena, &.{
        "-f",            "json",
        "-x",            "build",
        "--exclude-dir", "dist",
        "-e",            "log",
        "--exclude-ext", ".tmp",
        "-m",            "7",
        "-q",            "25",
        "-i",            "200",
        "-d",            "1500",
        "--poll",        "-s",
        "src",           "--",
        "-odd",
    });
    const config = command.watch;
    try testing.expectEqual(arguments.Format.json, config.format);
    try testing.expectEqual(@as(usize, 2), config.paths.len);
    try testing.expectEqualStrings("src", config.paths[0]);
    try testing.expectEqualStrings("-odd", config.paths[1]);
    try testing.expectEqualStrings("build", config.options.excluded_directories[0]);
    try testing.expectEqualStrings("dist", config.options.excluded_directories[1]);
    try testing.expect(config.options.excluded_directories.len > 2);
    try testing.expectEqualStrings(".log", config.options.excluded_extensions[0]);
    try testing.expectEqualStrings(".tmp", config.options.excluded_extensions[1]);
    try testing.expectEqual(@as(u8, 25), config.options.quota_percent);
    try testing.expectEqual(@as(?u32, 7), config.options.native_watches_max);
    try testing.expectEqual(@as(u32, 200), config.options.poll_interval_ms);
    try testing.expectEqual(@as(?u32, 1500), config.duration_ms);
    try testing.expect(config.is_stats_shown);

    const defaults_command = try parse(&arena, &.{
        "--format",
        "yaml",
        "--no-default-excludes",
        ".",
    });
    const defaults = defaults_command.watch;
    try testing.expectEqual(arguments.Format.yaml, defaults.format);
    try testing.expectEqual(@as(usize, 0), defaults.options.excluded_directories.len);
    try testing.expectEqual(@as(?u32, null), defaults.duration_ms);
    try testing.expect(!defaults.is_stats_shown);
    try testing.expectEqual(@as(u8, 50), defaults.options.quota_percent);
}

//
// Expects `argv` to fail with a message containing `text`.
//
fn expect_failure(argv: []const []const u8, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const message = (try parse(&arena, argv)).failure;
    try testing.expect(std.mem.indexOf(u8, message, text) != null);
    try testing.expect(std.ascii.isUpper(message[0]));
    try testing.expect(message[message.len - 1] == '.');
}

//
// Goal: every kind of bad command line fails with a message that says how to fix it.
// Method: parse each bad command line and check its message.
//
test "parse explains bad command lines" {
    try expect_failure(&.{}, "No directory");
    try expect_failure(&.{"--bogus"}, "Unknown option --bogus");
    try expect_failure(&.{ "--bogus", "dir" }, "Unknown option --bogus");
    try expect_failure(&.{ "dir", "--format" }, "needs a value");
    try expect_failure(&.{ "-f", "xml", "dir" }, "Unknown format xml");
    try expect_failure(&.{ "-q", "101", "dir" }, "Quota 101");
    try expect_failure(&.{ "-q", "x", "dir" }, "Quota x");
    try expect_failure(&.{ "-i", "0", "dir" }, "Poll interval 0");
    try expect_failure(&.{ "-m", "many", "dir" }, "Max watches many");
    try expect_failure(&.{ "-i", "soon", "dir" }, "Poll interval soon");
    try expect_failure(&.{ "-d", "-5", "dir" }, "Duration -5");
}

//
// Parses a valid and an invalid command line, for the allocation failure test.
//
fn parse_with(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try arguments.parse(arena.allocator(), &.{ "-e", "log", "-x", "out", "src" });
    _ = try arguments.parse(arena.allocator(), &.{"--bogus"});
}

//
// Goal: an allocation failure while parsing is reported and leaks nothing.
// Method: parse under checkAllAllocationFailures.
//
test "parse survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, parse_with, .{});
}
