//
// Collects the paths a native backend says may have changed, so the watcher can check each path
// once per batch however many raw events the platform sent for it.
//

const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

//
// How much of the file system around a path needs checking.
//
pub const Scope = enum {
    //
    // The path itself may have appeared, changed or disappeared.
    //
    entry,

    //
    // The children of the directory at the path may have changed, but the platform did not say
    // which ones.
    //
    directory,

    //
    // Anything under the directory at the path may have changed, because the platform dropped
    // events.
    //
    tree,
};

//
// The checks needed for one path. A path can need more than one, for example when a directory
// is both renamed and written to within one batch.
//
pub const Checks = struct {
    //
    // Check the path itself.
    //
    entry: bool = false,

    //
    // Rescan the children of the directory.
    //
    directory: bool = false,

    //
    // Rescan every directory under the path.
    //
    tree: bool = false,
};

//
// The paths to check in one batch, without duplicates and in the order they were first seen.
//
pub const HintSet = struct {
    //
    // Owns the map and every path in it, so a batch is released in one step.
    //
    arena: std.heap.ArenaAllocator,

    //
    // The checks needed for each path.
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
    // Records that `path` needs checking at `scope`. The path is copied.
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
        }
        assert(self.paths.count() > 0);
    }

    //
    // Records that the entry `name` inside the directory `parent` needs checking at `scope`.
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
