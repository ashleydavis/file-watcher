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
// The number of native watches the platform allows this process. On Linux and Android it is the
// per-user inotify watch limit. On macOS, iOS and the BSDs it is the open file limit, because
// kqueue needs one open descriptor per watched path. On Windows it is the number of roots one
// wait can cover.
//
pub fn native_watch_limit(io: Io) !u32 {
    const limit = switch (builtin.os.tag) {
        .linux => read_inotify_limit(io),
        .windows => windows_roots_max,
        .macos,
        .ios,
        .tvos,
        .watchos,
        .visionos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        => try read_open_file_limit(),
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
