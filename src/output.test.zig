//
// Tests for the output formats.
//

const std = @import("std");
const file_watcher = @import("file_watcher");
const output = @import("output.zig");

const testing = std.testing;

//
// Goal: each format writes a change exactly as documented.
// Method: write a change in every format and compare the text.
//
test "write_change writes every format" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();

    try output.write_change(&buffer.writer, .text, "/root/a \"b\"");
    try output.write_change(&buffer.writer, .json, "/root/a \"b\"");
    try output.write_change(&buffer.writer, .yaml, "/root/dir");
    try testing.expectEqualStrings(
        "changed /root/a \"b\"\n" ++
            "{\"changed\":\"/root/a \\\"b\\\"\"}\n" ++
            "- changed: \"/root/dir\"\n",
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
    try output.write_quoted(
        &buffer.writer,
        "a\\b\n\t\x01\x7f\u{85}caf\u{e9}\u{1f600}\xff\xe2\x82\xc3\x28",
    );
    try testing.expectEqualStrings(
        "\"a\\\\b\\n\\t\\u0001\\u007f\\u0085caf\u{e9}\u{1f600}\\ufffd\\ufffd\\ufffd\\ufffd(\"",
        buffer.written(),
    );
}

//
// Goal: a multibyte sequence cut short by the end of the text becomes U+FFFD.
// Method: quote text ending in the first byte of a three-byte sequence.
//
test "write_quoted replaces a truncated sequence" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try output.write_quoted(&buffer.writer, "a\xe2");
    try testing.expectEqualStrings("\"a\\ufffd\"", buffer.written());
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
        "warning: /root/locked: permission denied. " ++
            "It is left out of the watch. Check that it is readable.\n" ++
            "warning: /root/big: the native watch quota is used up. " ++
            "Its watched directory is polled instead.\n" ++
            "warning: Native watching stopped: this platform has no native watch method. " ++
            "Every watched directory is polled instead.\n",
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
        .roots = 4,
        .polled_roots = 1,
        .is_native_active = true,
    });
    try testing.expectEqualStrings(
        "stats: roots=4 polled_roots=1 native_watches=3 " ++
            "watch_budget=50 native_limit=100 native_active=true\n",
        buffer.written(),
    );
}
