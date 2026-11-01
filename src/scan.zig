//
// Tells whether anything in a directory tree changed since the last check, by its modification
// times alone. Nothing is kept between checks except the time of the last one: an entry that was
// created, written or renamed has a newer time, and so does the directory an entry was created
// in, deleted from or renamed in.
//

const std = @import("std");
const event_module = @import("event.zig");
const filter = @import("filter.zig");
const options_module = @import("options.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const EventList = event_module.EventList;
const Options = options_module.Options;

//
// What kind of entry a path is. Symbolic links and special files count as `other` and are never
// followed, which keeps the walk out of link cycles.
//
pub const EntryKind = enum(u8) {
    file,
    directory,
    other,
};

//
// The facts about one entry that a check reads.
//
pub const Stamp = struct {
    //
    // What kind of entry it is.
    //
    kind: EntryKind,

    //
    // The last modification time in nanoseconds since 1970.
    //
    mtime_ns: i96,
};

//
// Turns file metadata into a stamp.
//
pub fn stamp_from_stat(stat: *const Io.File.Stat) Stamp {
    const kind: EntryKind = switch (stat.kind) {
        .directory => .directory,
        .file => .file,
        else => .other,
    };
    return .{
        .kind = kind,
        .mtime_ns = stat.mtime.nanoseconds,
    };
}

//
// One entry found while listing a directory.
//
pub const Listed = struct {
    //
    // The entry's name inside its directory. It is valid only during the visit.
    //
    name: []const u8,

    //
    // The entry's metadata.
    //
    stamp: Stamp,
};

//
// Receives the entries of a directory one at a time, so a listing never holds them all.
//
pub const Visitor = struct {
    //
    // What `visit_fn` works on.
    //
    context: *anyopaque,

    //
    // Takes one entry and returns whether to go on to the next.
    //
    visit_fn: *const fn (context: *anyopaque, entry: Listed) anyerror!bool,

    //
    // Hands one entry to the visitor and returns whether to go on to the next.
    //
    pub fn visit(self: Visitor, entry: Listed) !bool {
        return self.visit_fn(self.context, entry);
    }
};

//
// The size of the buffer a `Lister` is given.
//
pub const lister_buffer_size: usize = 64 * 1024;

//
// Lists the entries of `dir` with their stamps, handing each to `visitor` until it asks to stop,
// using `buffer` for the system's records. A backend provides one when its platform reads a whole
// directory's metadata faster than each entry's on its own; without one the walk lists names and
// reads each entry's metadata.
//
pub const Lister = *const fn (
    io: Io,
    dir: Dir,
    buffer: []align(8) u8,
    visitor: Visitor,
) anyerror!void;

//
// What a check found.
//
pub const Result = enum {
    //
    // The tree's root does not exist or cannot be opened.
    //
    missing,

    //
    // No entry that counts has a time in the window.
    //
    unchanged,

    //
    // An entry that counts, or the root itself, has a time in the window.
    //
    changed,
};

//
// The upper bound on directories walked in one check. It is far above any real tree and exists
// so a file system that keeps producing new directories cannot hold the watcher in one loop.
//
const directories_max: u32 = 1 << 24;

//
// The state of one check, shared by the walk and the visitor that receives each entry.
//
const Walk = struct {
    //
    // Allocates the paths of directories waiting to be walked.
    //
    gpa: Allocator,

    //
    // Which entries are left out.
    //
    options: *const Options,

    //
    // The window: times after `since_ns` and no later than `until_ns` count as changes.
    //
    since_ns: i96,
    until_ns: i96,

    //
    // Where unreadable paths are reported, when the caller wants them; the walk then covers the
    // whole tree.
    //
    problems: ?*EventList,

    //
    // The directory being listed.
    //
    path: []const u8,

    //
    // The directories waiting to be walked, each owned by `gpa`.
    //
    pending: std.ArrayList([]u8),

    //
    // Whether a time in the window has been found.
    //
    is_changed: bool,

    //
    // How many entries the current listing has handed over.
    //
    visited: u32,

    //
    // The visitor that passes entries to `visit`.
    //
    fn visitor(self: *Walk) Visitor {
        return .{
            .context = self,
            .visit_fn = visit_opaque,
        };
    }

    fn visit_opaque(context: *anyopaque, entry: Listed) anyerror!bool {
        const self: *Walk = @ptrCast(@alignCast(context));
        return self.visit(entry);
    }

    //
    // Checks one entry of the current directory and queues it when it is a directory to walk.
    // Returns false to stop the listing once a change is found, unless the whole tree is wanted.
    //
    fn visit(self: *Walk, entry: Listed) !bool {
        self.visited += 1;
        if (!is_kept(self.options, entry.name, entry.stamp)) {
            return true;
        }
        if (is_in_window(entry.stamp.mtime_ns, self.since_ns, self.until_ns)) {
            self.is_changed = true;
            if (self.problems == null) {
                return false;
            }
        }
        if (entry.stamp.kind == .directory) {
            try self.pending.ensureUnusedCapacity(self.gpa, 1);
            const child = try std.fs.path.join(self.gpa, &.{ self.path, entry.name });
            self.pending.appendAssumeCapacity(child);
        }
        return true;
    }

    //
    // Records a path that could not be read, when the caller wants to hear about it.
    //
    fn report(self: *Walk, path: []const u8, err: anyerror) !void {
        if (self.problems) |list| {
            try list.append_problem(path, err, .skipped);
        }
    }

    //
    // Whether the walk can stop: a change is found and the whole tree is not wanted.
    //
    fn is_done(self: *const Walk) bool {
        return self.is_changed and self.problems == null;
    }
};

//
// Checks the tree at `root` for an entry, or the root itself, whose modification time is after
// `since_ns` and no later than `until_ns`, both in nanoseconds since 1970. Entries left out by
// `options` do not count, and excluded directories are not entered. The walk stops at the first
// change found, unless `problems` is given: then it walks the whole tree and reports there every
// directory or entry it cannot read, so the first check of a root tells the caller about them
// and later checks stay quiet. Entries are checked as they are read, so memory grows with the
// number of directories waiting to be walked, not with the number of files.
//
pub fn scan(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    options: *const Options,
    lister: ?Lister,
    since_ns: i96,
    until_ns: i96,
    problems: ?*EventList,
) !Result {
    assert(root.len > 0);
    var walk: Walk = .{
        .gpa = gpa,
        .options = options,
        .since_ns = since_ns,
        .until_ns = until_ns,
        .problems = problems,
        .path = root,
        .pending = .empty,
        .is_changed = false,
        .visited = 0,
    };
    defer {
        for (walk.pending.items) |path| {
            gpa.free(path);
        }
        walk.pending.deinit(gpa);
    }

    const root_stat = Dir.cwd().statFile(io, root, .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.FileNotFound, error.NotDir => return .missing,
        else => {
            try walk.report(root, err);
            return .missing;
        },
    };
    if (root_stat.kind != .directory) {
        return .missing;
    }
    walk.is_changed = is_in_window(root_stat.mtime.nanoseconds, since_ns, until_ns);
    if (walk.is_done()) {
        return .changed;
    }

    const buffer: []align(8) u8 = if (lister != null)
        try gpa.alignedAlloc(u8, .@"8", lister_buffer_size)
    else
        &.{};
    defer gpa.free(buffer);

    try walk.pending.ensureUnusedCapacity(gpa, 1);
    walk.pending.appendAssumeCapacity(try gpa.dupe(u8, root));
    var walked: u32 = 0;
    while (walk.pending.pop()) |path| {
        defer gpa.free(path);
        assert(walked < directories_max);
        const is_root = walked == 0;
        walked += 1;
        walk.path = path;
        var dir = Dir.cwd().openDir(io, path, .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The directory went away during the walk, which its parent's time shows.
            error.FileNotFound, error.NotDir => {
                if (is_root) {
                    return .missing;
                }
                continue;
            },
            else => {
                try walk.report(path, err);
                if (is_root) {
                    return .missing;
                }
                continue;
            },
        };
        defer dir.close(io);
        try list_directory(io, dir, lister, buffer, &walk);
        if (walk.is_done()) {
            return .changed;
        }
    }
    return if (walk.is_changed) .changed else .unchanged;
}

//
// Whether `mtime_ns` is after `since_ns` and no later than `until_ns`.
//
fn is_in_window(mtime_ns: i96, since_ns: i96, until_ns: i96) bool {
    return mtime_ns > since_ns and mtime_ns <= until_ns;
}

//
// Lists `dir` into `walk`, through the lister when there is one and it can read the directory,
// and otherwise by listing names and reading each entry's metadata.
//
fn list_directory(io: Io, dir: Dir, lister: ?Lister, buffer: []align(8) u8, walk: *Walk) !void {
    const list = lister orelse return list_generic(io, dir, walk);
    walk.visited = 0;
    list(io, dir, buffer, walk.visitor()) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // A directory the lister cannot read at all, for example on a file system without
            // the query it uses, is listed the generic way, which reports its own failures. One
            // that fails part way is reported, so no entry is handed over twice.
            if (walk.visited == 0) {
                return list_generic(io, dir, walk);
            }
            try walk.report(walk.path, err);
        },
    };
}

//
// Lists `dir` by name and reads each entry's metadata, handing each entry to `walk` as it goes.
//
fn list_generic(io: Io, dir: Dir, walk: *Walk) !void {
    var iterator = dir.iterate();
    while (true) {
        const entry = iterator.next(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                try walk.report(walk.path, err);
                return;
            },
        } orelse return;
        const stat = dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound, error.NotDir => continue,
            else => {
                if (walk.problems != null) {
                    const child = try std.fs.path.join(walk.gpa, &.{ walk.path, entry.name });
                    defer walk.gpa.free(child);
                    try walk.report(child, err);
                }
                continue;
            },
        };
        const is_going_on = try walk.visit(.{
            .name = entry.name,
            .stamp = stamp_from_stat(&stat),
        });
        if (!is_going_on) {
            return;
        }
    }
}

//
// Whether the entry called `name` with this stamp counts rather than being excluded.
//
fn is_kept(options: *const Options, name: []const u8, stamp: Stamp) bool {
    assert(name.len > 0);
    if (stamp.kind == .directory) {
        return !filter.is_excluded_directory(options, name);
    }
    return !filter.is_excluded_file(options, name);
}

test {
    _ = @import("scan.test.zig");
}
