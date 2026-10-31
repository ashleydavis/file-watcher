//
// The backend for platforms without a native watch method. It refuses to start, so the watcher
// polls every directory.
//

const std = @import("std");
const hints_module = @import("hints.zig");

const Allocator = std.mem.Allocator;
const HintSet = hints_module.HintSet;

//
// A backend that is never active.
//
pub const Unsupported = struct {
    //
    // Unused, because no directory is ever watched natively.
    //
    pub const is_recursive = false;

    //
    // Unused, because no file is ever watched natively.
    //
    pub const watches_files = false;

    //
    // Always fails, which sends the watcher to polling.
    //
    pub fn init(self: *Unsupported, gpa: Allocator) !void {
        _ = self;
        _ = gpa;
        return error.Unsupported;
    }

    //
    // Never called, because `init` always fails.
    //
    pub fn deinit(self: *Unsupported) void {
        _ = self;
        unreachable;
    }

    //
    // Never called, because `init` always fails.
    //
    pub fn watch(self: *Unsupported, path: []const u8, is_directory: bool) !bool {
        _ = self;
        _ = path;
        _ = is_directory;
        unreachable;
    }

    //
    // Never called, because `init` always fails.
    //
    pub fn unwatch(self: *Unsupported, path: []const u8) bool {
        _ = self;
        _ = path;
        unreachable;
    }

    //
    // Never called, because `init` always fails.
    //
    pub fn wake(self: *Unsupported) void {
        _ = self;
        unreachable;
    }

    //
    // Never called, because `init` always fails.
    //
    pub fn wait(self: *Unsupported, timeout_ms: u32, hints: *HintSet) !void {
        _ = self;
        _ = timeout_ms;
        _ = hints;
        unreachable;
    }
};
