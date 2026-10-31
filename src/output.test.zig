//
// Tests for the output formats.
//

const std = @import("std");
const file_watcher = @import("file_watcher");
const output = @import("output.zig");

const testing = std.testing;
const Event = file_watcher.Event;

//
// Goal: each format writes an event exactly as documented.
// Method: write a file event and a directory event in every format and compare the text.
//
test "write_event writes every format" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    const file_event: Event = .{
        .kind = .created,
        .path = "/root/a \"b\".txt",
        .is_directory = false,
    };
    const directory_event: Event = .{
        .kind = .deleted,
        .path = "/root/dir",
        .is_directory = true,
    };

    try output.write_event(&buffer.writer, .text, &file_event);
    try output.write_event(&buffer.writer, .text, &directory_event);
    try output.write_event(&buffer.writer, .json, &file_event);
    try output.write_event(&buffer.writer, .yaml, &directory_event);
    try testing.expectEqualStrings(
        "created file /root/a \"b\".txt\n" ++
            "deleted directory /root/dir\n" ++
            "{\"kind\":\"created\",\"type\":\"file\",\"path\":\"/root/a \\\"b\\\".txt\"}\n" ++
            "- kind: deleted\n  type: directory\n  path: \"/root/dir\"\n",
        buffer.written(),
    );
}

//
// Goal: quoting escapes everything JSON and YAML forbid and keeps valid UTF-8 readable.
// Method: quote strings with escapes, control characters, C1 characters, valid multibyte text
// and invalid bytes.
//
test "write_quoted escapes for JSON and YAML" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try output.write_quoted(&buffer.writer, "a\\b\n\t\x01\x7f\u{85}caf\u{e9}\u{1f600}\xff\xe2\x82\xc3\x28");
    try testing.expectEqualStrings(
        "\"a\\\\b\\n\\t\\u0001\\u007f\\u0085caf\u{e9}\u{1f600}\\ufffd\\ufffd\\ufffd\\ufffd(\"",
        buffer.written(),
    );
}

//
// Goal: problems read as sentences that say what happened and what the watcher does.
// Method: write a skipped path, a polled path and a whole-watcher problem.
//
test "write_problem explains each problem" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try output.write_problem(&buffer.writer, &.{
        .path = "/root/locked",
        .reason = error.AccessDenied,
        .action = .skipped,
    });
    try output.write_problem(&buffer.writer, &.{
        .path = "/root/big",
        .reason = error.LimitReached,
        .action = .polled,
    });
    try output.write_problem(&buffer.writer, &.{
        .path = "",
        .reason = error.Unsupported,
        .action = .polled,
    });
    try testing.expectEqualStrings(
        "warning: /root/locked: permission denied. It is left out of the watch. Check that it is readable.\n" ++
            "warning: /root/big: the native watch quota is used up. It is watched by polling instead.\n" ++
            "warning: Native watching stopped: this platform has no native watch method. Every directory is watched by polling instead.\n",
        buffer.written(),
    );
}

//
// Goal: every error the watcher produces has a readable description, and others keep their name.
// Method: describe each known error and an unknown one.
//
test "describe_error covers the watcher's errors" {
    const known = [_]anyerror{
        error.AccessDenied,
        error.PermissionDenied,
        error.FileNotFound,
        error.NotDir,
        error.LimitReached,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Unsupported,
        error.OverlappingRoot,
        error.NameTooLong,
        error.SymLinkLoop,
    };
    for (known) |err| {
        try testing.expect(!std.mem.eql(u8, output.describe_error(err), @errorName(err)));
    }
    try testing.expectEqualStrings("Unexpected", output.describe_error(error.Unexpected));
}

//
// Goal: the counters are written on one line.
// Method: write a set of counters and compare the text.
//
test "write_stats writes the counters" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try output.write_stats(&buffer.writer, &.{
        .native_limit = 100,
        .watch_budget = 50,
        .native_watches = 3,
        .polled_directories = 1,
        .directories = 4,
        .is_native_active = true,
    });
    try testing.expectEqualStrings(
        "stats: directories=4 native_watches=3 polled_directories=1 watch_budget=50 native_limit=100 native_active=true\n",
        buffer.written(),
    );
}
