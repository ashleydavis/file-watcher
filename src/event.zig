//
// Defines what a watcher reports for one batch: the watched directories that changed, and the
// problems it ran into.
//

const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

//
// A path the watcher could not read or watch, with the reason. The watcher carries on without it,
// so the caller learns about the gap instead of the watcher failing silently.
//
pub const Problem = struct {
    //
    // The path that could not be read or watched, or empty when the problem concerns the
    // watcher as a whole, such as the native watch method being unavailable.
    //
    path: []const u8,

    //
    // Why the path could not be read or watched.
    //
    reason: anyerror,

    //
    // What the watcher does about it.
    //
    action: ProblemAction,
};

//
// What the watcher does after a problem, so the caller can tell the user.
//
pub const ProblemAction = enum {
    //
    // The path is left out of the watch.
    //
    skipped,

    //
    // The path is watched by polling instead of by the native watch method.
    //
    polled,
};

//
// The changed roots and problems of one batch. Everything lives in one arena, so a batch is
// released in one step when the next batch starts.
//
pub const EventList = struct {
    //
    // Owns the lists and every path in them.
    //
    arena: std.heap.ArenaAllocator,

    //
    // The watched directories that changed, each once, in the order the changes were found.
    //
    changed: std.ArrayList([]const u8),

    //
    // The problems of the batch, in the order they were found.
    //
    problems: std.ArrayList(Problem),

    //
    // Creates an empty list that allocates from `gpa`.
    //
    pub fn init(gpa: Allocator) EventList {
        return .{
            .arena = .init(gpa),
            .changed = .empty,
            .problems = .empty,
        };
    }

    //
    // Frees every event, problem and path.
    //
    pub fn deinit(self: *EventList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    //
    // Empties the list for the next batch and keeps the memory, so a steady stream of batches
    // stops allocating once the arena has grown to fit a typical batch.
    //
    pub fn clear(self: *EventList) void {
        _ = self.arena.reset(.retain_capacity);
        self.changed = .empty;
        self.problems = .empty;
        assert(self.changed.items.len == 0);
        assert(self.problems.items.len == 0);
    }

    //
    // Records that the watched directory `root` changed, once per batch however many changes it
    // had. The path is copied, so the caller may reuse its buffer.
    //
    pub fn append_changed(self: *EventList, root: []const u8) Allocator.Error!void {
        assert(root.len > 0);
        for (self.changed.items) |existing| {
            if (std.mem.eql(u8, existing, root)) {
                return;
            }
        }
        const arena = self.arena.allocator();
        try self.changed.append(arena, try arena.dupe(u8, root));
        assert(self.changed.items.len > 0);
    }

    //
    // Records a problem. The path is copied, so the caller may reuse its buffer.
    //
    pub fn append_problem(
        self: *EventList,
        path: []const u8,
        reason: anyerror,
        action: ProblemAction,
    ) Allocator.Error!void {
        assert(reason != error.OutOfMemory);
        const arena = self.arena.allocator();
        const path_copy = try arena.dupe(u8, path);
        try self.problems.append(arena, .{
            .path = path_copy,
            .reason = reason,
            .action = action,
        });
        assert(self.problems.items.len > 0);
    }
};

test {
    _ = @import("event.test.zig");
}
