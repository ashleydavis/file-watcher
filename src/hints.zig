//
// Collects the paths a native backend says changed, so the watcher handles each path once per
// batch however many raw events the platform sent for it.
//

const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

//
// What a backend says about a path. Every scope means the path's watched directory changed; the
// scopes other than `entry` also tell a backend that watches each directory which watches to
// add or drop.
//
pub const Scope = enum {
    //
    // The path itself appeared, changed or disappeared.
    //
    entry,

    //
    // The directory at the path is new, or its entries changed, so directories and files under
    // it may need watches.
    //
    directory,

    //
    // Anything under the directory at the path may have changed, because the platform dropped
    // events, so every watch under it is checked.
    //
    tree,

    //
    // The directory at the path was deleted or moved away, so its watches and every watch under
    // it are dropped.
    //
    gone,
};

//
// The scopes reported for one path in a batch. A path can have more than one, for example when a
// directory is moved away and another created in its place within one batch.
//
pub const Checks = struct {
    entry: bool = false,
    directory: bool = false,
    tree: bool = false,
    gone: bool = false,
};

//
// The paths reported in one batch, without duplicates and in the order they were first seen.
//
pub const HintSet = struct {
    //
    // Owns the map and every path in it, so a batch is released in one step.
    //
    arena: std.heap.ArenaAllocator,

    //
    // The scopes reported for each path.
    //
    paths: std.StringArrayHashMapUnmanaged(Checks),

    //
    // Creates an empty set that allocates from `gpa`.
    //
    pub fn init(gpa: Allocator) HintSet {
        return .{
            .arena = .init(gpa),
            .paths = .empty,
        };
    }

    //
    // Frees the set and every path in it.
    //
    pub fn deinit(self: *HintSet) void {
        self.arena.deinit();
        self.* = undefined;
    }

    //
    // Empties the set for the next batch and keeps the memory.
    //
    pub fn clear(self: *HintSet) void {
        _ = self.arena.reset(.retain_capacity);
        self.paths = .empty;
        assert(self.paths.count() == 0);
    }

    //
    // Records that `path` was reported with `scope`. The path is copied.
    //
    pub fn add(self: *HintSet, path: []const u8, scope: Scope) Allocator.Error!void {
        assert(path.len > 0);
        const arena = self.arena.allocator();
        const result = try self.paths.getOrPut(arena, path);
        if (!result.found_existing) {
            result.key_ptr.* = try arena.dupe(u8, path);
            result.value_ptr.* = .{};
        }
        switch (scope) {
            .entry => result.value_ptr.entry = true,
            .directory => result.value_ptr.directory = true,
            .tree => result.value_ptr.tree = true,
            .gone => result.value_ptr.gone = true,
        }
        assert(self.paths.count() > 0);
    }

    //
    // Records that the entry `name` inside the directory `parent` was reported with `scope`.
    //
    pub fn add_child(
        self: *HintSet,
        parent: []const u8,
        name: []const u8,
        scope: Scope,
    ) Allocator.Error!void {
        assert(parent.len > 0);
        assert(name.len > 0);
        const path = try std.fs.path.join(self.arena.allocator(), &.{ parent, name });
        try self.add(path, scope);
    }
};

test {
    _ = @import("hints.test.zig");
}
