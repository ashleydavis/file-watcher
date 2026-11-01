//
// Finds how many native watches the platform allows and how many of them a watcher may use.
//

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const Io = std.Io;

//
// The kernel's default for `max_user_watches` on Linux, used when the real value cannot be read.
// Android refuses apps access to `/proc/sys`, so this is the value an app has to assume there.
//
pub const inotify_watches_default: u32 = 8192;

//
// The number of handles one call to `WaitForMultipleObjects` can wait on (`MAXIMUM_WAIT_OBJECTS`).
//
pub const windows_handles_max: u32 = 64;

//
// The roots one Windows watcher can watch natively: one wait handle goes to the event `wake` sets,
// and the rest to one root each.
//
pub const windows_roots_max: u32 = windows_handles_max - 1;

//
// The roots one macOS watcher watches natively, one FSEvents stream each. FSEvents documents no
// limit per process; this bound keeps one watcher from tying up the system's event daemon.
//
pub const fsevents_streams_max: u32 = 1024;

//
// `OPEN_MAX` on Apple platforms: the highest soft open file limit `setrlimit` accepts there,
// whatever the hard limit says.
//
pub const darwin_open_max: u64 = 10240;

//
// The number of native watches the platform allows this process. On Linux and Android it is the
// per-user inotify watch limit. On macOS it is the number of FSEvents streams, one per root. On
// iOS and the BSDs it is the open file limit, because kqueue needs one open descriptor per
// watched path; the soft limit is first raised to the hard limit, so the quota counts every
// descriptor the process may open. On Windows it is the number of roots one wait can cover.
//
pub fn native_watch_limit(io: Io) !u32 {
    const limit = switch (builtin.os.tag) {
        .linux => read_inotify_limit(io),
        .windows => windows_roots_max,
        .macos => fsevents_streams_max,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        => raise_and_read: {
            raise_open_file_limit();
            break :raise_and_read try read_open_file_limit();
        },
        else => 0,
    };
    assert(limit <= std.math.maxInt(u32));
    return limit;
}

//
// Reads the per-user inotify watch limit, falling back to the kernel default when the value
// cannot be read or parsed.
//
pub fn read_inotify_limit(io: Io) u32 {
    var buffer: [32]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/sys/fs/inotify/max_user_watches", &buffer) catch {
        return inotify_watches_default;
    };
    return parse_limit(text) orelse inotify_watches_default;
}

//
// Parses a limit written as decimal text with an optional trailing newline. Values above the
// range of `u32` are clamped, because no watcher can use more watches than that.
//
pub fn parse_limit(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) {
        return null;
    }
    const value = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    const limit: u32 = @intCast(@min(value, std.math.maxInt(u32)));
    assert(limit <= value);
    return limit;
}

//
// Reads the soft limit on open files for this process.
//
//
// The soft open file limit to ask for: the hard limit, capped at `OPEN_MAX` on Apple platforms,
// and never lower than the current soft limit.
//
pub fn raised_open_file_limit(current: u64, hard: u64, is_darwin: bool) u64 {
    assert(current <= hard);
    const target = if (is_darwin) @min(hard, darwin_open_max) else hard;
    return @max(current, target);
}

//
// Raises the soft open file limit as far as `raised_open_file_limit` allows, as the Go runtime
// does on every Unix. A refusal leaves the limit as it was, which the quota then counts.
//
fn raise_open_file_limit() void {
    const limits = std.posix.getrlimit(.NOFILE) catch return;
    const wanted = raised_open_file_limit(limits.cur, limits.max, builtin.os.tag.isDarwin());
    if (wanted == limits.cur) {
        return;
    }
    std.posix.setrlimit(.NOFILE, .{
        .cur = wanted,
        .max = limits.max,
    }) catch {};
}

fn read_open_file_limit() !u32 {
    const limits = try std.posix.getrlimit(.NOFILE);
    assert(limits.cur <= limits.max);
    return @intCast(@min(limits.cur, std.math.maxInt(u32)));
}

//
// The number of native watches a watcher may use: `quota_percent` of `limit`, rounded down.
//
pub fn watch_budget(limit: u32, quota_percent: u8) u32 {
    assert(quota_percent <= 100);
    const budget: u32 = @intCast(@divFloor(@as(u64, limit) * quota_percent, 100));
    assert(budget <= limit);
    return budget;
}

test {
    _ = @import("limit.test.zig");
}
