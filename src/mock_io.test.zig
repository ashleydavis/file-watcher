//
// An in-memory file system and clock behind the standard `std.Io` interface, so unit tests run
// the real watcher code without touching the disk or waiting on real time. Only the calls the
// watcher makes are implemented; every other call keeps the behaviour of `std.Io.failing`.
//

const std = @import("std");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

//
// The first handle number given to an opened directory, chosen far from real descriptors and
// from the current directory's special value, so a mix-up fails loudly.
//
const handle_base: usize = 1000;

//
// `path` with every `/` replaced by the separator of the platform the tests run on, so expected
// paths match the paths the code under test joins.
//
pub fn native_path(comptime path: []const u8) []const u8 {
    const result = comptime native: {
        var native: [path.len]u8 = path[0..path.len].*;
        std.mem.replaceScalar(u8, &native, '/', std.fs.path.sep);
        break :native native;
    };
    return &result;
}

//
// Copies `path` into `buffer` with every backslash replaced by a slash. The mock keeps every
// path with slashes, so Windows builds, which join with backslashes, find the same entries.
//
fn slash_path(buffer: []u8, path: []const u8) []const u8 {
    const copy = buffer[0..path.len];
    @memcpy(copy, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

//
// One file or directory in the in-memory file system.
//
pub const Node = struct {
    //
    // What kind of entry it is.
    //
    kind: File.Kind,

    //
    // The size in bytes.
    //
    size: u64,

    //
    // The modification time in nanoseconds.
    //
    mtime_ns: i96,

    //
    // A unique number, changed when the entry is replaced.
    //
    inode: File.INode,
};

//
// Calls that fail for one path, to test how the watcher handles errors.
//
pub const Faults = struct {
    //
    // Opening the directory fails with access denied.
    //
    open: bool = false,

    //
    // Reading the directory's entries fails with access denied.
    //
    read: bool = false,

    //
    // Reading the entry's metadata fails with access denied.
    //
    stat: bool = false,

    //
    // Every call fails as cancelled instead of with access denied.
    //
    is_canceled: bool = false,
};

//
// The in-memory file system and clock.
//
pub const MockIo = struct {
    //
    // Allocates paths and nodes.
    //
    gpa: Allocator,

    //
    // Every entry, keyed by full path, in insertion order so listings are deterministic.
    //
    nodes: std.StringArrayHashMapUnmanaged(Node),

    //
    // The path of each open directory handle, or null once closed.
    //
    handles: std.ArrayList(?[]const u8),

    //
    // Paths whose calls fail.
    //
    faults: std.StringHashMapUnmanaged(Faults),

    //
    // The current time in nanoseconds, advanced by sleeping.
    //
    clock_ns: i96,

    //
    // The next inode number to hand out.
    //
    inode_next: File.INode,

    //
    // Called on every sleep after the clock moves, so a test can change the file system while the
    // watcher waits.
    //
    sleep_callback: ?*const fn (mock: *MockIo) void,

    //
    // The function table behind `io()`.
    //
    vtable: Io.VTable,

    //
    // Creates an empty file system at time zero, in place because `io()` points into it.
    //
    pub fn init(self: *MockIo, gpa: Allocator) void {
        var vtable = Io.failing.vtable.*;
        vtable.dirOpenDir = dir_open_dir;
        vtable.dirStatFile = dir_stat_file;
        vtable.dirClose = dir_close;
        vtable.dirRead = dir_read;
        vtable.now = now;
        vtable.sleep = sleep;
        self.* = .{
            .gpa = gpa,
            .nodes = .empty,
            .handles = .empty,
            .faults = .empty,
            .clock_ns = 0,
            .inode_next = 1,
            .sleep_callback = null,
            .vtable = vtable,
        };
    }

    //
    // Frees everything and checks every directory handle was closed.
    //
    pub fn deinit(self: *MockIo) void {
        for (self.handles.items) |handle| {
            assert(handle == null);
        }
        for (self.nodes.keys()) |path| {
            self.gpa.free(path);
        }
        self.nodes.deinit(self.gpa);
        self.handles.deinit(self.gpa);
        var faults = self.faults.keyIterator();
        while (faults.next()) |path| {
            self.gpa.free(path.*);
        }
        self.faults.deinit(self.gpa);
        self.* = undefined;
    }

    //
    // The `std.Io` backed by this mock.
    //
    pub fn io(self: *MockIo) Io {
        return .{
            .userdata = self,
            .vtable = &self.vtable,
        };
    }

    //
    // Creates or replaces a directory.
    //
    pub fn add_directory(self: *MockIo, path: []const u8) !void {
        try self.put(path, .directory, 0);
    }

    //
    // Creates or replaces a file of `size` bytes.
    //
    pub fn add_file(self: *MockIo, path: []const u8, size: u64) !void {
        try self.put(path, .file, size);
    }

    //
    // Creates or replaces an entry of any kind.
    //
    pub fn put(self: *MockIo, raw_path: []const u8, kind: File.Kind, size: u64) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = slash_path(&buffer, raw_path);
        const result = try self.nodes.getOrPut(self.gpa, path);
        if (!result.found_existing) {
            result.key_ptr.* = try self.gpa.dupe(u8, path);
        }
        result.value_ptr.* = .{
            .kind = kind,
            .size = size,
            .mtime_ns = self.clock_ns,
            .inode = self.inode_next,
        };
        self.inode_next += 1;
    }

    //
    // Changes a file's size and modification time, as a write would.
    //
    pub fn write_file(self: *MockIo, raw_path: []const u8, size: u64) void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = slash_path(&buffer, raw_path);
        const node = self.nodes.getPtr(path).?;
        node.size = size;
        node.mtime_ns = self.clock_ns;
    }

    //
    // Removes an entry and everything under it.
    //
    pub fn remove(self: *MockIo, raw_path: []const u8) void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = slash_path(&buffer, raw_path);
        var index: usize = 0;
        while (index < self.nodes.count()) {
            const key = self.nodes.keys()[index];
            if (is_within(key, path)) {
                self.nodes.orderedRemoveAt(index);
                self.gpa.free(key);
            } else {
                index += 1;
            }
        }
    }

    //
    // Makes calls on `path` fail.
    //
    pub fn set_faults(self: *MockIo, raw_path: []const u8, faults: Faults) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = slash_path(&buffer, raw_path);
        const result = try self.faults.getOrPut(self.gpa, path);
        if (!result.found_existing) {
            result.key_ptr.* = try self.gpa.dupe(u8, path);
        }
        result.value_ptr.* = faults;
    }

    //
    // The number of directory handles still open.
    //
    pub fn open_handle_count(self: *const MockIo) u32 {
        var count: u32 = 0;
        for (self.handles.items) |handle| {
            if (handle != null) {
                count += 1;
            }
        }
        return count;
    }

    //
    // The faults injected for `path`, or none.
    //
    fn faults_of(self: *MockIo, path: []const u8) Faults {
        return self.faults.get(path) orelse .{};
    }

    //
    // Resolves a path relative to an open handle into a full path in `buffer`.
    //
    fn resolve(self: *MockIo, dir: Dir, sub_path: []const u8, buffer: []u8) []const u8 {
        if (dir.handle == Dir.cwd().handle) {
            return slash_path(buffer, sub_path);
        }
        if (std.fs.path.isSep(sub_path[0])) {
            return slash_path(buffer, sub_path);
        }
        const base = self.handles.items[index_from_handle(dir.handle)].?;
        const path = std.fmt.bufPrint(buffer, "{s}/{s}", .{ base, sub_path }) catch unreachable;
        std.mem.replaceScalar(u8, path, '\\', '/');
        return path;
    }
};

//
// The directory handle for an index into `handles`. Handles are descriptors on POSIX systems and
// pointers on Windows, so the number is converted to whichever the target uses.
//
fn handle_from_index(index: usize) Dir.Handle {
    const value = handle_base + index;
    return switch (@typeInfo(Dir.Handle)) {
        .pointer => @ptrFromInt(value),
        else => @intCast(value),
    };
}

//
// The index into `handles` of a directory handle.
//
fn index_from_handle(handle: Dir.Handle) usize {
    const value: usize = switch (@typeInfo(Dir.Handle)) {
        .pointer => @intFromPtr(handle),
        else => @intCast(handle),
    };
    return value - handle_base;
}

//
// The mock behind an `Io`.
//
fn mock_from(userdata: ?*anyopaque) *MockIo {
    return @ptrCast(@alignCast(userdata.?));
}

//
// Whether `path` is `root` or inside it.
//
fn is_within(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }
    if (path.len == root.len) {
        return true;
    }
    return path[root.len] == '/';
}

//
// Opens a directory and hands out a handle that maps back to its path.
//
fn dir_open_dir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    _ = options;
    const self = mock_from(userdata);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = self.resolve(dir, sub_path, &buffer);
    const node = self.nodes.get(path) orelse return error.FileNotFound;
    if (node.kind != .directory) {
        return error.NotDir;
    }
    const faults = self.faults_of(path);
    if (faults.open) {
        return if (faults.is_canceled) error.Canceled else error.AccessDenied;
    }
    const path_copy = self.gpa.dupe(u8, path) catch return error.SystemResources;
    self.handles.append(self.gpa, path_copy) catch {
        self.gpa.free(path_copy);
        return error.SystemResources;
    };
    return .{
        .handle = handle_from_index(self.handles.items.len - 1),
    };
}

//
// Returns the metadata of an entry.
//
fn dir_stat_file(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    _ = options;
    const self = mock_from(userdata);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = self.resolve(dir, sub_path, &buffer);
    const node = self.nodes.get(path) orelse return error.FileNotFound;
    const faults = self.faults_of(path);
    if (faults.stat) {
        return if (faults.is_canceled) error.Canceled else error.AccessDenied;
    }
    return .{
        .inode = node.inode,
        .nlink = 1,
        .size = node.size,
        .permissions = .default_file,
        .kind = node.kind,
        .atime = null,
        .mtime = .{
            .nanoseconds = node.mtime_ns,
        },
        .ctime = .{
            .nanoseconds = node.mtime_ns,
        },
        .block_size = 1,
    };
}

//
// Closes directory handles.
//
fn dir_close(userdata: ?*anyopaque, dirs: []const Dir) void {
    const self = mock_from(userdata);
    for (dirs) |dir| {
        const index = index_from_handle(dir.handle);
        self.gpa.free(self.handles.items[index].?);
        self.handles.items[index] = null;
    }
}

//
// Lists the children of a directory in insertion order, resuming from `reader.index`.
//
fn dir_read(
    userdata: ?*anyopaque,
    reader: *Dir.Reader,
    entries: []Dir.Entry,
) Dir.Reader.Error!usize {
    const self = mock_from(userdata);
    const index = index_from_handle(reader.dir.handle);
    const path = self.handles.items[index].?;
    const faults = self.faults_of(path);
    if (faults.read) {
        return if (faults.is_canceled) error.Canceled else error.AccessDenied;
    }
    if (reader.state == .reset) {
        reader.index = 0;
        reader.state = .reading;
    }
    if (reader.state == .finished) {
        return 0;
    }
    var position: usize = 0;
    var filled: usize = 0;
    for (self.nodes.keys(), self.nodes.values()) |key, node| {
        const parent = std.fs.path.dirname(key) orelse continue;
        if (!std.mem.eql(u8, parent, path)) {
            continue;
        }
        if (position >= reader.index) {
            if (filled < entries.len) {
                entries[filled] = .{
                    .name = std.fs.path.basename(key),
                    .kind = node.kind,
                    .inode = node.inode,
                };
                filled += 1;
            }
        }
        position += 1;
    }
    reader.index += filled;
    if (reader.index >= position) {
        reader.state = .finished;
    }
    return filled;
}

//
// The mock clock, the same for every clock kind.
//
fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = clock;
    const self = mock_from(userdata);
    return .{
        .nanoseconds = self.clock_ns,
    };
}

//
// Moves the mock clock forward instead of waiting, then runs the sleep callback.
//
fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const self = mock_from(userdata);
    switch (timeout) {
        .none => unreachable,
        .duration => |duration| self.clock_ns += duration.raw.nanoseconds,
        .deadline => |deadline| self.clock_ns = @max(self.clock_ns, deadline.raw.nanoseconds),
    }
    if (self.sleep_callback) |callback| {
        callback(self);
    }
}
