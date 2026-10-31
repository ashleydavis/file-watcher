//
// Keeps an in-memory record of every watched directory and its entries, and turns differences
// between that record and the file system into events. Every watch method, native or polling,
// ends here, so all platforms report changes the same way.
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
// followed, which keeps the watcher out of link cycles.
//
pub const EntryKind = enum {
    //
    // A regular file.
    //
    file,

    //
    // A directory, which the watcher descends into.
    //
    directory,

    //
    // Anything else, reported like a file.
    //
    other,
};

comptime {
    assert(@sizeOf(Stamp) <= 32);
}

//
// The facts recorded for one entry. A change to any of them is a modification.
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
    // The last modification time in nanoseconds since 1970, kept to 64 bits so a stamp packs into
    // 32 bytes. It is only compared for equality, and times that differ by less than 584 years
    // stay distinct.
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
    const stamp: Stamp = .{
        .kind = kind,
        .size = stat.size,
        .mtime_ns = @truncate(stat.mtime.nanoseconds),
        .inode = stat.inode,
    };
    assert(stamp.kind == .directory or stat.kind != .directory);
    assert(stamp.size == stat.size);
    return stamp;
}

//
// The entries of one watched directory, keyed by name.
//
const Directory = struct {
    //
    // The stamp of each entry that is not excluded.
    //
    children: std.StringHashMapUnmanaged(Stamp),
};

//
// The upper bound on directories scanned in one call. It is far above any real tree and exists
// so a file system that keeps producing new directories cannot hold the watcher in one loop.
//
const scan_directories_max: u32 = 1 << 24;

//
// The in-memory record of all watched trees.
//
pub const Snapshot = struct {
    //
    // Allocates the directory records, which live as long as the snapshot.
    //
    gpa: Allocator,

    //
    // Reads the file system.
    //
    io: Io,

    //
    // Decides which entries are left out.
    //
    options: *const Options,

    //
    // The root paths added by the caller, owned by the snapshot.
    //
    roots: std.ArrayList([]const u8),

    //
    // Every watched directory, keyed by its full path.
    //
    directories: std.StringHashMapUnmanaged(Directory),

    //
    // Holds working data for one public call, released when the next call starts.
    //
    scratch: std.heap.ArenaAllocator,

    //
    // Holds the listing of one directory, released when the next directory is listed, so a scan
    // of a large tree holds one listing at a time.
    //
    listing_arena: std.heap.ArenaAllocator,

    //
    // Directories found during a call that still need their first scan. Paths are owned by the
    // snapshot and move into `directories` when scanned.
    //
    pending: std.ArrayList([]const u8),

    //
    // Creates an empty snapshot.
    //
    pub fn init(gpa: Allocator, io: Io, options: *const Options) Snapshot {
        assert(options_module.is_valid(options));
        return .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .roots = .empty,
            .directories = .empty,
            .scratch = .init(gpa),
            .listing_arena = .init(gpa),
            .pending = .empty,
        };
    }

    //
    // Frees every record.
    //
    pub fn deinit(self: *Snapshot) void {
        for (self.pending.items) |path| {
            self.gpa.free(path);
        }
        var iterator = self.directories.iterator();
        while (iterator.next()) |entry| {
            free_directory(self.gpa, entry.key_ptr.*, entry.value_ptr);
        }
        self.directories.deinit(self.gpa);
        for (self.roots.items) |root| {
            self.gpa.free(root);
        }
        self.roots.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.scratch.deinit();
        self.listing_arena.deinit();
        self.* = undefined;
    }

    //
    // Whether the directory at `path` is watched.
    //
    pub fn contains_directory(self: *const Snapshot, path: []const u8) bool {
        assert(path.len > 0);
        return self.directories.contains(path);
    }

    //
    // The number of watched directories.
    //
    pub fn directory_count(self: *const Snapshot) u32 {
        return @intCast(self.directories.count());
    }

    //
    // Records the tree under `path` as the starting point, without reporting its contents as
    // created. Fails when the path is not a directory or overlaps a root added before.
    //
    pub fn add_root(self: *Snapshot, raw_path: []const u8, out: *EventList) !void {
        assert(raw_path.len > 0);
        const path = trim_root(raw_path);
        _ = self.scratch.reset(.retain_capacity);
        const stat = try Dir.cwd().statFile(self.io, path, .{
            .follow_symlinks = true,
        });
        if (stat.kind != .directory) {
            return error.NotDir;
        }
        for (self.roots.items) |root| {
            if (is_within(path, root)) {
                return error.OverlappingRoot;
            }
            if (is_within(root, path)) {
                return error.OverlappingRoot;
            }
        }

        try self.roots.ensureUnusedCapacity(self.gpa, 1);
        try self.pending.ensureUnusedCapacity(self.gpa, 1);
        const root = try self.gpa.dupe(u8, path);
        self.roots.appendAssumeCapacity(root);
        const pending_path = self.gpa.dupe(u8, path) catch |err| {
            self.gpa.free(self.roots.pop().?);
            return err;
        };
        self.pending.appendAssumeCapacity(pending_path);
        try self.scan_pending(false, out);
        assert(self.directories.contains(path));
    }

    //
    // Checks one path that may have appeared, changed or disappeared, and records the difference.
    //
    pub fn check_entry(self: *Snapshot, path: []const u8, out: *EventList) !void {
        assert(path.len > 0);
        _ = self.scratch.reset(.retain_capacity);
        if (self.is_root(path)) {
            try self.sync_directory(path, out);
            try self.scan_pending(true, out);
            return;
        }
        const parent = std.fs.path.dirname(path) orelse return;
        if (!self.directories.contains(parent)) {
            return;
        }
        const stamp = try self.stat_entry(Dir.cwd(), null, path, out);
        try self.apply_child(parent, std.fs.path.basename(path), stamp, true, out);
        try self.scan_pending(true, out);
        assert(self.pending.items.len == 0);
    }

    //
    // Rescans the children of the directory at `path` and records the differences.
    //
    pub fn rescan_directory(self: *Snapshot, path: []const u8, out: *EventList) !void {
        assert(path.len > 0);
        _ = self.scratch.reset(.retain_capacity);
        try self.sync_directory(path, out);
        try self.scan_pending(true, out);
        assert(self.pending.items.len == 0);
    }

    //
    // Rescans every watched directory under `path`, for when the platform dropped events.
    //
    pub fn rescan_tree(self: *Snapshot, path: []const u8, out: *EventList) !void {
        assert(path.len > 0);
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        var iterator = self.directories.keyIterator();
        while (iterator.next()) |key| {
            if (is_within(key.*, path)) {
                try paths.append(scratch, try scratch.dupe(u8, key.*));
            }
        }
        for (paths.items) |directory_path| {
            try self.sync_directory(directory_path, out);
            try self.scan_pending(true, out);
        }
        assert(self.pending.items.len == 0);
    }

    //
    // Whether `path` is one of the roots.
    //
    pub fn is_root(self: *const Snapshot, path: []const u8) bool {
        assert(path.len > 0);
        for (self.roots.items) |root| {
            if (std.mem.eql(u8, root, path)) {
                return true;
            }
        }
        return false;
    }

    //
    // Scans each directory in `pending` for the first time, including directories found while
    // doing so. `report` says whether their contents are reported as created.
    //
    fn scan_pending(self: *Snapshot, report: bool, out: *EventList) !void {
        var scanned: u32 = 0;
        while (self.pending.pop()) |path| {
            assert(scanned < scan_directories_max);
            scanned += 1;
            const result = self.directories.getOrPut(self.gpa, path) catch |err| {
                self.gpa.free(path);
                return err;
            };
            assert(!result.found_existing);
            result.value_ptr.* = .{
                .children = .empty,
            };
            try self.list_directory(path, report, out);
        }
        assert(self.pending.items.len == 0);
    }

    //
    // Rescans a directory that is already watched. A directory that has disappeared is removed
    // together with everything under it.
    //
    fn sync_directory(self: *Snapshot, path: []const u8, out: *EventList) !void {
        assert(path.len > 0);
        if (!self.directories.contains(path)) {
            return;
        }
        try self.list_directory(path, true, out);
    }

    //
    // Lists the directory at `path`, which must be in `directories`, and applies the differences
    // between the listing and the record.
    //
    fn list_directory(self: *Snapshot, path: []const u8, report: bool, out: *EventList) !void {
        assert(self.directories.contains(path));
        _ = self.listing_arena.reset(.retain_capacity);
        const scratch = self.listing_arena.allocator();
        var listing: std.StringArrayHashMapUnmanaged(Stamp) = .empty;
        const listed = try self.read_listing(path, &listing, out);
        if (!listed) {
            return;
        }

        var iterator = listing.iterator();
        while (iterator.next()) |entry| {
            try self.apply_child(path, entry.key_ptr.*, entry.value_ptr.*, report, out);
        }

        var missing: std.ArrayList([]const u8) = .empty;
        const directory = self.directories.getPtr(path).?;
        var children = directory.children.keyIterator();
        while (children.next()) |name| {
            if (!listing.contains(name.*)) {
                try missing.append(scratch, try scratch.dupe(u8, name.*));
            }
        }
        for (missing.items) |name| {
            try self.apply_child(path, name, null, true, out);
        }
        assert(self.directories.contains(path));
    }

    //
    // Reads the entries of the directory at `path` into `listing`, leaving out excluded entries.
    // Returns false when the directory could not be read, so the caller keeps its old record
    // instead of mistaking the failure for every entry being deleted.
    //
    fn read_listing(
        self: *Snapshot,
        path: []const u8,
        listing: *std.StringArrayHashMapUnmanaged(Stamp),
        out: *EventList,
    ) !bool {
        assert(listing.count() == 0);
        const scratch = self.listing_arena.allocator();
        var dir = Dir.cwd().openDir(self.io, path, .{
            .access_sub_paths = true,
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                try self.remove_missing_directory(path, out);
                return false;
            },
            error.Canceled => return error.Canceled,
            else => {
                try out.append_problem(path, err, .skipped);
                return false;
            },
        };
        defer dir.close(self.io);

        var iterator = dir.iterate();
        var count: u32 = 0;
        while (true) {
            const entry = iterator.next(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    try out.append_problem(path, err, .skipped);
                    return false;
                },
            } orelse break;
            assert(count < std.math.maxInt(u32));
            count += 1;
            const stamp = try self.stat_entry(dir, path, entry.name, out) orelse continue;
            try listing.put(scratch, try scratch.dupe(u8, entry.name), stamp);
        }
        return true;
    }

    //
    // Reads the stamp of the entry at `sub_path` inside `dir`. `parent` is the path of `dir`, or
    // null when `sub_path` is a full path. Returns null when the entry is gone or excluded.
    //
    fn stat_entry(
        self: *Snapshot,
        dir: Dir,
        parent: ?[]const u8,
        sub_path: []const u8,
        out: *EventList,
    ) !?Stamp {
        assert(sub_path.len > 0);
        const name = std.fs.path.basename(sub_path);
        assert(name.len > 0);
        const stat = dir.statFile(self.io, sub_path, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            error.Canceled => return error.Canceled,
            else => {
                const path = if (parent) |parent_path|
                    try std.fs.path.join(self.scratch.allocator(), &.{ parent_path, sub_path })
                else
                    sub_path;
                try out.append_problem(path, err, .skipped);
                return null;
            },
        };
        const stamp = stamp_from_stat(&stat);
        if (stamp.kind == .directory) {
            if (filter.is_excluded_directory(self.options, name)) {
                return null;
            }
        } else {
            if (filter.is_excluded_file(self.options, name)) {
                return null;
            }
        }
        return stamp;
    }

    //
    // Records the new state of the entry `name` in the directory at `parent`, where null means
    // the entry is gone, and reports the difference.
    //
    fn apply_child(
        self: *Snapshot,
        parent: []const u8,
        name: []const u8,
        stamp: ?Stamp,
        report: bool,
        out: *EventList,
    ) !void {
        assert(name.len > 0);
        const directory = self.directories.getPtr(parent).?;
        const previous = directory.children.get(name);
        const current = stamp orelse {
            if (previous) |old| {
                try self.remove_child(parent, name, old.kind, out);
            }
            return;
        };
        const old = previous orelse {
            try self.add_child(parent, name, current, report, out);
            return;
        };
        if (old.kind != current.kind) {
            try self.remove_child(parent, name, old.kind, out);
            try self.add_child(parent, name, current, report, out);
            return;
        }
        if (current.kind == .directory) {
            if (old.inode != current.inode) {
                try self.remove_child(parent, name, old.kind, out);
                try self.add_child(parent, name, current, report, out);
                return;
            }
            directory.children.getPtr(name).?.* = current;
            return;
        }
        if (is_changed(&old, &current)) {
            directory.children.getPtr(name).?.* = current;
            const path = try std.fs.path.join(self.scratch.allocator(), &.{ parent, name });
            try out.append_event(.modified, path, false);
        }
    }

    //
    // Adds a new entry, reports it when `report` is set and queues a new directory for its
    // first scan.
    //
    fn add_child(
        self: *Snapshot,
        parent: []const u8,
        name: []const u8,
        stamp: Stamp,
        report: bool,
        out: *EventList,
    ) !void {
        const directory = self.directories.getPtr(parent).?;
        assert(!directory.children.contains(name));
        const is_directory = stamp.kind == .directory;

        try directory.children.ensureUnusedCapacity(self.gpa, 1);
        if (is_directory) {
            try self.pending.ensureUnusedCapacity(self.gpa, 1);
        }
        const name_copy = try self.gpa.dupe(u8, name);
        var pending_path: ?[]const u8 = null;
        if (is_directory) {
            pending_path = std.fs.path.join(self.gpa, &.{ parent, name }) catch |err| {
                self.gpa.free(name_copy);
                return err;
            };
            self.pending.appendAssumeCapacity(pending_path.?);
        }
        directory.children.putAssumeCapacityNoClobber(name_copy, stamp);
        assert(directory.children.contains(name));
        if (report) {
            // The path is joined only when reported, because the first scan of a tree reports
            // nothing and would otherwise join a path for every entry.
            const path = pending_path orelse
                try std.fs.path.join(self.scratch.allocator(), &.{ parent, name });
            try out.append_event(.created, path, is_directory);
        }
    }

    //
    // Removes an entry and reports it, removing and reporting everything under it first when it
    // is a directory.
    //
    fn remove_child(
        self: *Snapshot,
        parent: []const u8,
        name: []const u8,
        kind: EntryKind,
        out: *EventList,
    ) !void {
        const path = try std.fs.path.join(self.scratch.allocator(), &.{ parent, name });
        if (kind == .directory) {
            try self.remove_tree(path, out);
        }
        const directory = self.directories.getPtr(parent).?;
        const removed = directory.children.fetchRemove(name).?;
        self.gpa.free(removed.key);
        try out.append_event(.deleted, path, kind == .directory);
        assert(!directory.children.contains(name));
    }

    //
    // Handles a watched directory that could not be opened because it is gone.
    //
    fn remove_missing_directory(self: *Snapshot, path: []const u8, out: *EventList) !void {
        assert(self.directories.contains(path));
        const parent = std.fs.path.dirname(path) orelse path;
        if (self.directories.contains(parent)) {
            try self.apply_child(parent, std.fs.path.basename(path), null, true, out);
            return;
        }
        assert(self.is_root(path));
        const path_copy = try self.scratch.allocator().dupe(u8, path);
        try self.remove_tree(path_copy, out);
        try out.append_event(.deleted, path_copy, true);
        for (self.roots.items, 0..) |root, index| {
            if (std.mem.eql(u8, root, path_copy)) {
                self.gpa.free(self.roots.orderedRemove(index));
                break;
            }
        }
        assert(!self.is_root(path_copy));
    }

    //
    // Removes the record of the directory at `path` and of every directory under it, reporting
    // every entry inside as deleted. The entry for `path` in its parent is left to the caller.
    //
    fn remove_tree(self: *Snapshot, path: []const u8, out: *EventList) !void {
        const scratch = self.scratch.allocator();
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(scratch, path);
        var removed_count: u32 = 0;
        while (stack.pop()) |directory_path| {
            assert(removed_count < scan_directories_max);
            removed_count += 1;
            var removed = self.directories.fetchRemove(directory_path) orelse continue;
            defer free_directory(self.gpa, removed.key, &removed.value);

            var children = removed.value.children.iterator();
            while (children.next()) |child| {
                const child_path = try std.fs.path.join(scratch, &.{
                    directory_path,
                    child.key_ptr.*,
                });
                const is_directory = child.value_ptr.kind == .directory;
                if (is_directory) {
                    try stack.append(scratch, child_path);
                }
                try out.append_event(.deleted, child_path, is_directory);
            }
        }
        assert(!self.directories.contains(path));
    }
};

//
// Whether `path` is `root` or inside it.
//
pub fn is_within(path: []const u8, root: []const u8) bool {
    assert(root.len > 0);
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }
    if (path.len == root.len) {
        return true;
    }
    if (std.fs.path.isSep(root[root.len - 1])) {
        return true;
    }
    return std.fs.path.isSep(path[root.len]);
}

//
// Removes trailing separators from a root path, so joined child paths and parent lookups agree
// with it. A separator that is the whole path ("/") or follows a drive ("C:\\") is kept, because
// removing it changes which directory the path names.
//
pub fn trim_root(path: []const u8) []const u8 {
    assert(path.len > 0);
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1]) and path[end - 2] != ':') {
        end -= 1;
    }
    assert(end > 0);
    return path[0..end];
}

//
// Whether a file's stamp differs in a way that counts as a modification.
//
fn is_changed(old: *const Stamp, new: *const Stamp) bool {
    assert(old.kind == new.kind);
    assert(new.kind != .directory);
    if (old.size != new.size) {
        return true;
    }
    if (old.mtime_ns != new.mtime_ns) {
        return true;
    }
    return old.inode != new.inode;
}

//
// Frees a directory record and its key.
//
fn free_directory(gpa: Allocator, path: []const u8, directory: *Directory) void {
    var names = directory.children.keyIterator();
    while (names.next()) |name| {
        gpa.free(name.*);
    }
    directory.children.deinit(gpa);
    gpa.free(path);
}

test {
    _ = @import("snapshot.test.zig");
}
