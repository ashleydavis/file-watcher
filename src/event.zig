//
// Defines the change events a watcher reports and the list that collects them for one batch.
//

const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

//
// What happened to a path. A rename is reported as a deletion of the old path and a creation of
// the new path, because that is the only form every platform can report reliably.
//
pub const EventKind = enum {
    //
    // The path appeared.
    //
    created,

    //
    // The contents, size or modification time of a file changed.
    //
    modified,

    //
    // The path disappeared.
    //
    deleted,
};

//
// One change to one path.
//
pub const Event = struct {
    //
    // What happened.
    //
    kind: EventKind,

    //
    // The full path, built from the root path the caller added.
    //
    path: []const u8,

    //
    // Whether the path is a directory, so callers can tell a new folder from a new file.
    //
    is_directory: bool,
};

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
// The events and problems of one batch. Everything lives in one arena, so a batch is released
// in one step when the next batch starts.
//
pub const EventList = struct {
    //
    // Owns the event list, the problem list and every path in them.
    //
    arena: std.heap.ArenaAllocator,

    //
    // The events of the batch, in the order they were found.
    //
    events: std.ArrayList(Event),

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
            .events = .empty,
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
        self.events = .empty;
        self.problems = .empty;
        assert(self.events.items.len == 0);
        assert(self.problems.items.len == 0);
    }

    //
    // Records an event. The path is copied, so the caller may reuse its buffer.
    //
    pub fn append_event(
        self: *EventList,
        kind: EventKind,
        path: []const u8,
        is_directory: bool,
    ) Allocator.Error!void {
        assert(path.len > 0);
        const arena = self.arena.allocator();
        const path_copy = try arena.dupe(u8, path);
        try self.events.append(arena, .{
            .kind = kind,
            .path = path_copy,
            .is_directory = is_directory,
        });
        assert(self.events.items.len > 0);
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
