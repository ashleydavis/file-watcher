//
// Defines the settings a caller passes to a watcher and their defaults.
//

const std = @import("std");

const assert = std.debug.assert;

//
// Directory names left out of every watch unless the caller replaces the list. Each one is a
// dependency, cache, build output or version control store that tools rewrite in bulk, so
// watching it costs many watches and floods the caller with changes it does not care about.
//
pub const default_excluded_directories = [_][]const u8{
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "bower_components",
    ".pnpm-store",
    ".yarn",
    ".next",
    ".nuxt",
    ".turbo",
    ".parcel-cache",
    ".cache",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "__pycache__",
    ".venv",
    "venv",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    ".gradle",
    ".idea",
    ".terraform",
    "Pods",
    "DerivedData",
};

//
// How the watcher finds changes.
//
pub const Method = enum {
    //
    // Use the platform's native watch method up to the quota, then poll.
    //
    native,

    //
    // Poll every directory. Useful on network file systems, where native events are unreliable.
    //
    polling,
};

//
// Settings for a watcher. The slices are borrowed, so the caller keeps them alive for the life
// of the watcher.
//
pub const Options = struct {
    //
    // Directory names to leave out, matched exactly against each directory's own name.
    //
    excluded_directories: []const []const u8 = &default_excluded_directories,

    //
    // File extensions to leave out, including the dot (".log"), matched exactly against the text
    // after the last dot of each file name.
    //
    excluded_extensions: []const []const u8 = &.{},

    //
    // The share of the platform's native watch limit this watcher may use, from 0 to 100. Half
    // by default, so other programs of the same user still have watches left.
    //
    quota_percent: u8 = 50,

    //
    // The most native watches to use, whatever the quota allows, or null for no cap beyond the
    // quota. A cap keeps a watcher's use of the platform limit small and predictable, and lets
    // tests send most of a tree to the polling fallback.
    //
    native_watches_max: ?u32 = null,

    //
    // How often polled directories are rescanned. One second by default, which notices changes
    // quickly enough for build tools while keeping the cost of each rescan small.
    //
    poll_interval_ms: u32 = 1000,

    //
    // How the watcher finds changes.
    //
    method: Method = .native,
};

//
// Whether every setting is in range. The watcher asserts this, so callers that take settings from
// users check them here first.
//
pub fn is_valid(options: *const Options) bool {
    assert(options.excluded_directories.len < std.math.maxInt(u32));
    assert(options.excluded_extensions.len < std.math.maxInt(u32));
    if (options.quota_percent > 100) {
        return false;
    }
    if (options.poll_interval_ms == 0) {
        return false;
    }
    return true;
}

test {
    _ = @import("options.test.zig");
}
