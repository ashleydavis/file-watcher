//
// Sums up a directory tree in one 64-bit number, so polling can tell that something in the tree
// changed by comparing one number per root, with nothing kept per file. Every entry that is not
// excluded adds a hash of its path, kind, size, modification time and file number, so creating,
// deleting, renaming or changing any of them changes the sum.
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
// The facts about one entry that a change shows up in.
//
pub const Stamp = struct {
    //
    // What kind of entry it is.
    //
    kind: EntryKind,

    //
    // The size in bytes.
    //
    size: u64,

    //
    // The last modification time in nanoseconds since 1970.
    //
    mtime_ns: i64,

    //
    // The file system's number for the entry. It changes when an editor saves by writing a new
    // file and renaming it over the old one, even when size and time match.
    //
    inode: Io.File.INode,
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
        .size = stat.size,
        .mtime_ns = @truncate(stat.mtime.nanoseconds),
        .inode = stat.inode,
    };
}

//
// One entry found by a `Lister`.
//
pub const Listed = struct {
    //
    // The entry's name inside its directory.
    //
    name: []const u8,

    //
    // The entry's metadata.
    //
    stamp: Stamp,
};

//
// Lists the entries of `dir`, the directory at `dir_path`, with their stamps, or only the entry
// called `name` when it is given, allocating from `arena`. A backend provides one when its
// platform reads a whole directory's metadata faster than each entry's on its own; without one
// the walk lists names and reads each entry's metadata.
//
pub const Lister = *const fn (
    io: Io,
    dir: Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void;

//
// The upper bound on directories walked in one fingerprint. It is far above any real tree and
// exists so a file system that keeps producing new directories cannot hold the watcher in one
// loop.
//
const directories_max: u32 = 1 << 24;

//
// Added to the sum when the root exists, so a deleted root differs from an empty one.
//
const root_present: u64 = 0x9e3779b97f4a7c15;

//
// Walks the tree at `root` and returns its fingerprint. Entries left out by `options` do not
// count. A directory or entry that cannot be read is left out and, when `problems` is given,
// reported there, so the first walk of a root tells the caller about it and later walks stay
// quiet.
//
pub fn fingerprint(
    gpa: Allocator,
    io: Io,
    root: []const u8,
    options: *const Options,
    lister: ?Lister,
    problems: ?*EventList,
) !u64 {
    assert(root.len > 0);
    // Directories still to walk live in one arena for the whole walk; each directory's listing
    // lives in another that is emptied after the directory is summed, so memory grows with the
    // number of directories waiting, not with the number of files.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var listing_state: std.heap.ArenaAllocator = .init(gpa);
    defer listing_state.deinit();
    const listing = listing_state.allocator();

    var sum: u64 = 0;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(arena, root);
    var walked: u32 = 0;
    while (pending.pop()) |path| {
        assert(walked < directories_max);
        walked += 1;
        var dir = Dir.cwd().openDir(io, path, .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // The directory went away during the walk, which the sum shows by its absence.
            error.FileNotFound, error.NotDir => continue,
            else => {
                try report(problems, path, err);
                continue;
            },
        };
        defer dir.close(io);
        if (path.ptr == root.ptr) {
            sum +%= root_present;
        }
        _ = listing_state.reset(.retain_capacity);
        var entries: std.ArrayList(Listed) = .empty;
        try list_directory(io, dir, path, lister, listing, &entries, problems);
        for (entries.items) |entry| {
            if (!is_kept(options, entry.name, entry.stamp)) {
                continue;
            }
            sum +%= hash_entry(path[root.len..], entry.name, &entry.stamp);
            if (entry.stamp.kind == .directory) {
                try pending.append(arena, try std.fs.path.join(arena, &.{ path, entry.name }));
            }
        }
    }
    return sum;
}

//
// Lists `dir` with each entry's stamp, through the lister when there is one and it can read the
// directory, and otherwise by listing names and reading each entry's metadata.
//
fn list_directory(
    io: Io,
    dir: Dir,
    path: []const u8,
    lister: ?Lister,
    arena: Allocator,
    entries: *std.ArrayList(Listed),
    problems: ?*EventList,
) !void {
    if (lister) |list| {
        list(io, dir, path, null, arena, entries) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            // A directory the lister cannot read, for example on a file system without the
            // query it uses, is listed the generic way, which reports its own failures.
            else => {
                entries.clearRetainingCapacity();
                return list_generic(io, dir, path, arena, entries, problems);
            },
        };
        return;
    }
    return list_generic(io, dir, path, arena, entries, problems);
}

//
// Lists `dir` by name and reads each entry's metadata.
//
fn list_generic(
    io: Io,
    dir: Dir,
    path: []const u8,
    arena: Allocator,
    entries: *std.ArrayList(Listed),
    problems: ?*EventList,
) !void {
    var iterator = dir.iterate();
    while (true) {
        const entry = iterator.next(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                try report(problems, path, err);
                return;
            },
        } orelse return;
        const stat = dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound, error.NotDir => continue,
            else => {
                const child = try std.fs.path.join(arena, &.{ path, entry.name });
                try report(problems, child, err);
                continue;
            },
        };
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .stamp = stamp_from_stat(&stat),
        });
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

//
// The hash one entry adds to the sum, from its directory's path below the root and its name. A
// directory counts by its path alone: its own time changes
// whenever an entry in it is added or removed, including excluded entries, which must not count.
//
pub fn hash_entry(parent: []const u8, name: []const u8, stamp: *const Stamp) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(parent);
    hasher.update(&.{0});
    hasher.update(name);
    hasher.update(&.{@intFromEnum(stamp.kind)});
    if (stamp.kind != .directory) {
        hasher.update(std.mem.asBytes(&stamp.size));
        hasher.update(std.mem.asBytes(&stamp.mtime_ns));
        hasher.update(std.mem.asBytes(&stamp.inode));
    }
    return hasher.final();
}

//
// Records a path that could not be read, when the caller wants to hear about it.
//
fn report(problems: ?*EventList, path: []const u8, err: anyerror) !void {
    if (problems) |list| {
        try list.append_problem(path, err, .skipped);
    }
}

test {
    _ = @import("fingerprint.test.zig");
}
