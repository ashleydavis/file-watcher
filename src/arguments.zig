//
// Parses the CLI tool's command line into what to run and with which settings.
//

const std = @import("std");
const file_watcher = @import("file_watcher");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Options = file_watcher.Options;

//
// How changes are written to standard output.
//
pub const Format = enum {
    //
    // One line per event: kind, type and path, separated by spaces.
    //
    text,

    //
    // One JSON object per line (JSON Lines), so a stream can be parsed line by line.
    //
    json,

    //
    // One YAML sequence item per event, so the whole output is one YAML document.
    //
    yaml,
};

//
// Settings for watching, taken from the command line.
//
pub const Config = struct {
    //
    // The directories to watch.
    //
    paths: []const []const u8,

    //
    // How changes are written.
    //
    format: Format,

    //
    // The watcher settings.
    //
    options: Options,

    //
    // How long to watch before exiting, or null to watch until stopped.
    //
    duration_ms: ?u32,

    //
    // Whether to print the watcher's counters to standard error once the paths are added.
    //
    is_stats_shown: bool,
};

//
// What the command line asks for.
//
pub const Command = union(enum) {
    //
    // Print the usage text.
    //
    help,

    //
    // Print the version.
    //
    version,

    //
    // Watch with these settings.
    //
    watch: Config,

    //
    // The command line is wrong; the message says what is wrong and how to fix it.
    //
    failure: []const u8,
};

//
// The usage text printed by `--help`.
//
pub const usage =
    \\Usage: file-watcher [options] <directory>...
    \\
    \\Watches directory trees and prints which of them changed.
    \\
    \\Options:
    \\  -f, --format <format>        Output format: text, json or yaml. Default: text.
    \\  -x, --exclude-dir <name>     Leave out directories with this name. Repeatable.
    \\      --no-default-excludes    Watch node_modules, .git and the other directories
    \\                               left out by default.
    \\  -e, --exclude-ext <ext>      Leave out files with this extension, such as .log.
    \\                               Repeatable.
    \\  -q, --quota <percent>        Share of the platform's native watch limit to use,
    \\                               from 0 to 100. Default: 50.
    \\  -m, --max-watches <count>    The most native watches to use, whatever the quota
    \\                               allows. Directories beyond it are polled.
    \\  -i, --poll-interval <ms>     How often polled directories are rescanned.
    \\                               Default: 1000.
    \\  -t, --throttle <ms>          The shortest time between two reports of the same
    \\                               directory. 0 reports at once. Default: 1000.
    \\      --poll                   Poll every directory instead of using native watches.
    \\  -d, --duration <ms>          Exit after this many milliseconds.
    \\  -s, --stats                  Print watch counters to standard error at start.
    \\  -h, --help                   Print this help.
    \\  -V, --version                Print the version.
    \\
;

//
// Parses `argv` without the program name. Strings in the result are borrowed from `argv` or
// allocated from `arena`.
//
pub fn parse(arena: Allocator, argv: []const []const u8) Allocator.Error!Command {
    var paths: std.ArrayList([]const u8) = .empty;
    var excluded_directories: std.ArrayList([]const u8) = .empty;
    var excluded_extensions: std.ArrayList([]const u8) = .empty;
    var is_default_excludes = true;
    var config: Config = .{
        .paths = &.{},
        .format = .text,
        .options = .{},
        .duration_ms = null,
        .is_stats_shown = false,
    };

    var index: usize = 0;
    var is_options_ended = false;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        const is_path = if (is_options_ended) true else !is_option(argument);
        if (is_path) {
            try paths.append(arena, argument);
            continue;
        }
        if (std.mem.eql(u8, argument, "--")) {
            is_options_ended = true;
            continue;
        }
        if (is_flag(argument, "-h", "--help")) {
            return .help;
        }
        if (is_flag(argument, "-V", "--version")) {
            return .version;
        }
        if (std.mem.eql(u8, argument, "--no-default-excludes")) {
            is_default_excludes = false;
            continue;
        }
        if (std.mem.eql(u8, argument, "--poll")) {
            config.options.method = .polling;
            continue;
        }
        if (is_flag(argument, "-s", "--stats")) {
            config.is_stats_shown = true;
            continue;
        }

        if (index + 1 == argv.len) {
            if (is_value_flag(argument)) {
                return failure(
                    arena,
                    "Option {s} needs a value. Put the value after it.",
                    .{argument},
                );
            }
            return failure(
                arena,
                "Unknown option {s}. Run with --help to list the options.",
                .{argument},
            );
        }
        index += 1;
        const value = argv[index];
        if (is_flag(argument, "-f", "--format")) {
            config.format = std.meta.stringToEnum(Format, value) orelse {
                return failure(arena, "Unknown format {s}. Use text, json or yaml.", .{value});
            };
        } else if (is_flag(argument, "-x", "--exclude-dir")) {
            try excluded_directories.append(arena, value);
        } else if (is_flag(argument, "-e", "--exclude-ext")) {
            const extension = if (std.mem.startsWith(u8, value, "."))
                value
            else
                try std.fmt.allocPrint(arena, ".{s}", .{value});
            try excluded_extensions.append(arena, extension);
        } else if (is_flag(argument, "-q", "--quota")) {
            const quota = parse_number(value, 100) orelse {
                return failure(arena, "Quota {s} is not a whole number from 0 to 100.", .{value});
            };
            config.options.quota_percent = @intCast(quota);
        } else if (is_flag(argument, "-m", "--max-watches")) {
            config.options.native_watches_max = parse_number(value, std.math.maxInt(u32)) orelse {
                return failure(arena, "Max watches {s} is not a whole number.", .{value});
            };
        } else if (is_flag(argument, "-i", "--poll-interval")) {
            const interval = parse_number(value, std.math.maxInt(u32)) orelse 0;
            if (interval == 0) {
                return failure(
                    arena,
                    "Poll interval {s} is not a whole number of milliseconds above 0.",
                    .{value},
                );
            }
            config.options.poll_interval_ms = interval;
        } else if (is_flag(argument, "-t", "--throttle")) {
            config.options.throttle_ms = parse_number(value, std.math.maxInt(u32)) orelse {
                return failure(
                    arena,
                    "Throttle {s} is not a whole number of milliseconds.",
                    .{value},
                );
            };
        } else if (is_flag(argument, "-d", "--duration")) {
            config.duration_ms = parse_number(value, std.math.maxInt(u32)) orelse {
                return failure(
                    arena,
                    "Duration {s} is not a whole number of milliseconds.",
                    .{value},
                );
            };
        } else {
            return failure(
                arena,
                "Unknown option {s}. Run with --help to list the options.",
                .{argument},
            );
        }
    }

    if (paths.items.len == 0) {
        return failure(arena, "No directory to watch. Name at least one directory.", .{});
    }
    if (is_default_excludes) {
        try excluded_directories.appendSlice(arena, &file_watcher.default_excluded_directories);
    }
    config.paths = paths.items;
    config.options.excluded_directories = excluded_directories.items;
    config.options.excluded_extensions = excluded_extensions.items;
    assert(file_watcher.is_valid(&config.options));
    assert(config.paths.len > 0);
    return .{
        .watch = config,
    };
}

//
// Whether `argument` is the short or long form of a flag.
//
fn is_flag(argument: []const u8, short: []const u8, long: []const u8) bool {
    assert(short.len == 2);
    assert(long.len > 2);
    return std.mem.eql(u8, argument, short) or std.mem.eql(u8, argument, long);
}

//
// Whether `argument` looks like an option rather than a path. A lone "-" is a path.
//
fn is_option(argument: []const u8) bool {
    if (argument.len < 2) {
        return false;
    }
    return argument[0] == '-';
}

//
// Whether `argument` is a flag that takes a value.
//
fn is_value_flag(argument: []const u8) bool {
    const flags = [_][2][]const u8{
        .{ "-f", "--format" },
        .{ "-x", "--exclude-dir" },
        .{ "-e", "--exclude-ext" },
        .{ "-q", "--quota" },
        .{ "-m", "--max-watches" },
        .{ "-i", "--poll-interval" },
        .{ "-t", "--throttle" },
        .{ "-d", "--duration" },
    };
    for (flags) |flag| {
        if (is_flag(argument, flag[0], flag[1])) {
            return true;
        }
    }
    return false;
}

//
// Parses a whole decimal number no larger than `maximum`.
//
fn parse_number(text: []const u8, maximum: u32) ?u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return null;
    if (value > maximum) {
        return null;
    }
    return value;
}

//
// Builds a failure with a formatted message.
//
fn failure(
    arena: Allocator,
    comptime format: []const u8,
    arguments: anytype,
) Allocator.Error!Command {
    return .{
        .failure = try std.fmt.allocPrint(arena, format, arguments),
    };
}

test {
    _ = @import("arguments.test.zig");
}
