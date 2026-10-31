//
// Writes events, problems and counters in the CLI tool's output formats.
//

const std = @import("std");
const arguments = @import("arguments.zig");
const file_watcher = @import("file_watcher");

const assert = std.debug.assert;
const Event = file_watcher.Event;
const Format = arguments.Format;
const Problem = file_watcher.Problem;
const Stats = file_watcher.Stats;
const Writer = std.Io.Writer;

//
// Writes one event in `format`.
//
pub fn write_event(writer: *Writer, format: Format, event: *const Event) Writer.Error!void {
    assert(event.path.len > 0);
    const kind = @tagName(event.kind);
    const entry_type = if (event.is_directory) "directory" else "file";
    switch (format) {
        .text => try writer.print("{s} {s} {s}\n", .{ kind, entry_type, event.path }),
        .json => {
            try writer.print("{{\"kind\":\"{s}\",\"type\":\"{s}\",\"path\":", .{ kind, entry_type });
            try write_quoted(writer, event.path);
            try writer.writeAll("}\n");
        },
        .yaml => {
            try writer.print("- kind: {s}\n  type: {s}\n  path: ", .{ kind, entry_type });
            try write_quoted(writer, event.path);
            try writer.writeAll("\n");
        },
    }
}

//
// Writes `text` as a double-quoted string that is valid in both JSON and YAML. Control
// characters, DEL and the C1 range are escaped, because YAML forbids them unescaped. Bytes that
// are not valid UTF-8, which Linux allows in file names, become U+FFFD, because neither format
// can hold them.
//
pub fn write_quoted(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\t' => try writer.writeAll("\\t"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
                else => try writer.print("\\u{x:0>4}", .{byte}),
            }
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (length == 0 or index + length > text.len) {
            try writer.writeAll("\\ufffd");
            index += 1;
            continue;
        }
        const sequence = text[index..][0..length];
        const code_point = std.unicode.utf8Decode(sequence) catch {
            try writer.writeAll("\\ufffd");
            index += 1;
            continue;
        };
        if (code_point < 0xa0) {
            try writer.print("\\u{x:0>4}", .{code_point});
        } else {
            try writer.writeAll(sequence);
        }
        index += length;
    }
    try writer.writeByte('"');
}

//
// Writes a problem as a warning line that says what happened and what the watcher does about it.
//
pub fn write_problem(writer: *Writer, problem: *const Problem) Writer.Error!void {
    const action = switch (problem.action) {
        .skipped => "It is left out of the watch. Check that it is readable.",
        .polled => "It is watched by polling instead.",
    };
    if (problem.path.len == 0) {
        try writer.print("warning: Native watching stopped: {s}. Every directory is watched by polling instead.\n", .{describe_error(problem.reason)});
        return;
    }
    try writer.print("warning: {s}: {s}. {s}\n", .{ problem.path, describe_error(problem.reason), action });
}

//
// A short description of an error for a person to read.
//
pub fn describe_error(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.FileNotFound => "it does not exist",
        error.NotDir => "it is not a directory",
        error.LimitReached => "the native watch quota is used up",
        error.SystemResources => "the system ran out of resources",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "too many files are open",
        error.Unsupported => "this platform has no native watch method",
        error.OverlappingRoot => "it overlaps another watched directory",
        error.NameTooLong => "the path is too long",
        error.SymLinkLoop => "it is a symbolic link loop",
        else => @errorName(err),
    };
}

//
// Writes the watcher's counters on one line.
//
pub fn write_stats(writer: *Writer, stats: *const Stats) Writer.Error!void {
    assert(stats.native_watches <= stats.watch_budget);
    try writer.print(
        "stats: directories={d} native_watches={d} polled_directories={d} watch_budget={d} native_limit={d} native_active={}\n",
        .{
            stats.directories,
            stats.native_watches,
            stats.polled_directories,
            stats.watch_budget,
            stats.native_limit,
            stats.is_native_active,
        },
    );
}

test {
    _ = @import("output.test.zig");
}
