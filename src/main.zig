//
// The CLI tool: watches the directories named on the command line and prints each change.
//

const std = @import("std");
const build_options = @import("build_options");
const arguments = @import("arguments.zig");
const file_watcher = @import("file_watcher");
const output = @import("output.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Watcher = file_watcher.Watcher;
const Writer = std.Io.Writer;

//
// The longest wait for changes in one call, so the duration is checked at least this often.
//
const batch_wait_ms_max: u32 = 1000;

//
// Exit codes. Wrong usage is told apart from failures while running so scripts can react.
//
const exit_success: u8 = 0;
const exit_failure: u8 = 1;
const exit_usage: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(init.io, &stderr_buffer);
    return run(init.gpa, init.io, argv[1..], &stdout.interface, &stderr.interface);
}

//
// Runs the tool with `argv` (without the program name) and returns the exit code. Output goes
// to the writers passed in, so the whole tool can be tested without a terminal.
//
pub fn run(
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    stdout: *Writer,
    stderr: *Writer,
) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const command = try arguments.parse(arena.allocator(), argv);
    switch (command) {
        .help => {
            try stdout.writeAll(arguments.usage);
            try stdout.flush();
            return exit_success;
        },
        .version => {
            try stdout.print("file-watcher {s}\n", .{build_options.version});
            try stdout.flush();
            return exit_success;
        },
        .failure => |message| {
            try stderr.print("error: {s}\n", .{message});
            try stderr.flush();
            return exit_usage;
        },
        .watch => |config| return watch(gpa, io, &config, stdout, stderr),
    }
}

//
// Watches the configured directories until the duration ends, printing every change.
//
fn watch(gpa: Allocator, io: Io, config: *const arguments.Config, stdout: *Writer, stderr: *Writer) !u8 {
    assert(config.paths.len > 0);
    const watcher = try gpa.create(Watcher);
    defer gpa.destroy(watcher);
    try watcher.init(gpa, io, &config.options);
    defer watcher.deinit();

    for (config.paths) |path| {
        watcher.add(path) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }
            try stderr.print("error: Cannot watch {s}: {s}. Name an existing directory that does not overlap another one.\n", .{ path, output.describe_error(err) });
            try stderr.flush();
            return exit_failure;
        };
    }
    if (config.is_stats_shown) {
        try output.write_stats(stderr, &watcher.stats());
        try stderr.flush();
    }

    const start_ns = now_ns(io);
    const duration_ns: ?i96 = if (config.duration_ms) |duration_ms|
        @as(i96, duration_ms) * std.time.ns_per_ms
    else
        null;
    while (true) {
        var wait_ms = batch_wait_ms_max;
        if (duration_ns) |duration| {
            const elapsed_ns = now_ns(io) - start_ns;
            if (elapsed_ns >= duration) {
                break;
            }
            const remaining_ms = std.math.divCeil(i96, duration - elapsed_ns, std.time.ns_per_ms) catch unreachable;
            wait_ms = @intCast(@min(remaining_ms, batch_wait_ms_max));
        }
        const batch = try watcher.next(wait_ms);
        for (batch.problems) |*problem| {
            try output.write_problem(stderr, problem);
        }
        if (batch.problems.len > 0) {
            try stderr.flush();
        }
        for (batch.events) |*event| {
            try output.write_event(stdout, config.format, event);
        }
        if (batch.events.len > 0) {
            try stdout.flush();
        }
    }
    return exit_success;
}

//
// The current time on the awake clock.
//
fn now_ns(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

test {
    _ = @import("main.test.zig");
}
