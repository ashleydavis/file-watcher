//
// Tests for the CLI tool, run end to end against the in-memory file system and clock, with
// output captured in memory.
//

const std = @import("std");
const main = @import("main.zig");
const mock_io_module = @import("mock_io");

const testing = std.testing;
const MockIo = mock_io_module.MockIo;

//
// The captured result of one run.
//
const Result = struct {
    code: u8,
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn deinit(self: *Result) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

fn run(mock: *MockIo, argv: []const []const u8) !Result {
    var result: Result = .{
        .code = 0,
        .stdout = .init(testing.allocator),
        .stderr = .init(testing.allocator),
    };
    errdefer result.deinit();
    result.code = try main.run(testing.allocator, mock.io(), argv, &result.stdout.writer, &result.stderr.writer);
    return result;
}

//
// Adds a file the first time the tool waits, as if a user saved it.
//
fn add_file_on_sleep(mock: *MockIo) void {
    if (!mock.nodes.contains("/root/new.txt")) {
        mock.add_file("/root/new.txt", 1) catch unreachable;
    }
}

//
// Goal: help, version and bad usage print to the right stream with the right exit code.
// Method: run each and check output and exit code.
//
test "run prints help, version and usage errors" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();

    var help = try run(&mock, &.{"--help"});
    defer help.deinit();
    try testing.expectEqual(@as(u8, 0), help.code);
    try testing.expect(std.mem.startsWith(u8, help.stdout.written(), "Usage: file-watcher"));

    var version = try run(&mock, &.{"--version"});
    defer version.deinit();
    try testing.expectEqual(@as(u8, 0), version.code);
    try testing.expect(std.mem.startsWith(u8, version.stdout.written(), "file-watcher "));

    var usage = try run(&mock, &.{});
    defer usage.deinit();
    try testing.expectEqual(@as(u8, 2), usage.code);
    try testing.expect(std.mem.startsWith(u8, usage.stderr.written(), "error: No directory"));
}

//
// Goal: the tool prints changes in the chosen format, prints counters and exits after the
// duration.
// Method: watch a mock tree by polling, add a file while the tool waits and check the output.
//
test "run prints changes until the duration ends" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try mock.add_directory("/root");
    mock.sleep_callback = add_file_on_sleep;

    var result = try run(&mock, &.{ "--poll", "-i", "100", "-d", "2500", "-s", "-f", "json", "/root" });
    defer result.deinit();
    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings(
        "{\"kind\":\"created\",\"type\":\"file\",\"path\":\"/root/new.txt\"}\n",
        result.stdout.written(),
    );
    try testing.expect(std.mem.startsWith(u8, result.stderr.written(), "stats: directories=1"));
    try testing.expect(mock.clock_ns >= 2500 * std.time.ns_per_ms);
}

//
// Goal: problems are printed as warnings while watching continues.
// Method: watch a tree with an unreadable directory and check the warning.
//
test "run prints problems as warnings" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try mock.add_directory("/root");
    try mock.add_directory("/root/locked");
    try mock.set_faults("/root/locked", .{
        .open = true,
    });

    var result = try run(&mock, &.{ "--poll", "-d", "10", "/root" });
    defer result.deinit();
    try testing.expectEqual(@as(u8, 0), result.code);
    try testing.expectEqualStrings(
        "warning: /root/locked: permission denied. It is left out of the watch. Check that it is readable.\n",
        result.stderr.written(),
    );
}

//
// Goal: a directory that cannot be watched stops the tool with an explanation.
// Method: name a missing directory.
//
test "run refuses a missing directory" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();

    var result = try run(&mock, &.{ "--poll", "/missing" });
    defer result.deinit();
    try testing.expectEqual(@as(u8, 1), result.code);
    try testing.expectEqualStrings(
        "error: Cannot watch /missing: it does not exist. Name an existing directory that does not overlap another one.\n",
        result.stderr.written(),
    );
}

fn run_with(gpa: std.mem.Allocator, mock: *MockIo) !void {
    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();
    _ = try main.run(gpa, mock.io(), &.{ "--poll", "-d", "300", "-i", "100", "/root" }, &stdout.writer, &stderr.writer);
    _ = try main.run(gpa, mock.io(), &.{ "--poll", "/missing" }, &stdout.writer, &stderr.writer);
}

//
// Goal: an allocation failure anywhere in the tool is reported and leaks nothing.
// Method: run the tool under checkAllAllocationFailures.
//
test "run survives allocation failure" {
    var mock: MockIo = undefined;
    mock.init(testing.allocator);
    defer mock.deinit();
    try mock.add_directory("/root");
    try mock.add_directory("/root/sub");
    try testing.checkAllAllocationFailures(testing.allocator, run_with, .{&mock});
}
