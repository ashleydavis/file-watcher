//
// Tests for tree fingerprints, run against the in-memory file system so every change and
// failure is exact.
//

const std = @import("std");
const event_module = @import("event.zig");
const fingerprint_module = @import("fingerprint.zig");
const mock_io_module = @import("mock_io");
const options_module = @import("options.zig");

const testing = std.testing;
const EventList = event_module.EventList;
const Listed = fingerprint_module.Listed;
const MockIo = mock_io_module.MockIo;
const native_path = mock_io_module.native_path;

//
// A mock file system holding a small tree, and the options that leave out `.log` files.
//
const Fixture = struct {
    mock: MockIo,
    options: options_module.Options,

    fn init(self: *Fixture) !void {
        self.mock.init(testing.allocator);
        self.options = .{
            .excluded_extensions = &.{".log"},
        };
        try self.mock.add_directory(native_path("/root"));
        try self.mock.add_file(native_path("/root/a.txt"), 1);
        try self.mock.add_directory(native_path("/root/sub"));
        try self.mock.add_file(native_path("/root/sub/b.txt"), 2);
        try self.mock.add_directory(native_path("/root/node_modules"));
        try self.mock.add_file(native_path("/root/node_modules/c.js"), 3);
    }

    fn deinit(self: *Fixture) void {
        self.mock.deinit();
    }

    //
    // The fingerprint of `/root`, read the generic way or through `lister`.
    //
    fn sum(self: *Fixture, lister: ?fingerprint_module.Lister) !u64 {
        return fingerprint_module.fingerprint(
            testing.allocator,
            self.mock.io(),
            native_path("/root"),
            &self.options,
            lister,
            null,
        );
    }
};

//
// Goal: every kind of change to an entry that counts changes the fingerprint, and reading the
// same tree twice gives the same fingerprint.
// Method: change the tree one way at a time and compare fingerprints before and after.
//
test "fingerprint changes with every counted change" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var previous = try fixture.sum(null);
    try testing.expectEqual(previous, try fixture.sum(null));

    try fixture.mock.add_file(native_path("/root/new.txt"), 1);
    var current = try fixture.sum(null);
    try testing.expect(current != previous);
    previous = current;

    fixture.mock.write_file(native_path("/root/a.txt"), 9);
    current = try fixture.sum(null);
    try testing.expect(current != previous);
    previous = current;

    fixture.mock.remove(native_path("/root/sub/b.txt"));
    current = try fixture.sum(null);
    try testing.expect(current != previous);
    previous = current;

    try fixture.mock.add_directory(native_path("/root/sub/deeper"));
    current = try fixture.sum(null);
    try testing.expect(current != previous);
    previous = current;

    fixture.mock.remove(native_path("/root/sub"));
    current = try fixture.sum(null);
    try testing.expect(current != previous);
}

//
// Goal: changes in excluded directories and to excluded files leave the fingerprint alone, even
// though they change the time of the directory holding them.
// Method: add and change excluded entries and compare fingerprints.
//
test "fingerprint ignores excluded entries" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const before = try fixture.sum(null);
    try fixture.mock.add_file(native_path("/root/node_modules/d.js"), 1);
    fixture.mock.write_file(native_path("/root/node_modules/c.js"), 8);
    try fixture.mock.add_file(native_path("/root/debug.log"), 1);
    try fixture.mock.add_file(native_path("/root/sub/trace.log"), 1);
    try testing.expectEqual(before, try fixture.sum(null));
}

//
// Goal: a deleted root differs from an empty one, and a special entry counts like a file.
// Method: empty the root, then delete it, then add a special entry to a fresh root.
//
test "fingerprint tells a missing root from an empty one" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    fixture.mock.remove(native_path("/root/a.txt"));
    fixture.mock.remove(native_path("/root/sub"));
    fixture.mock.remove(native_path("/root/node_modules"));
    const empty = try fixture.sum(null);
    fixture.mock.remove(native_path("/root"));
    const missing = try fixture.sum(null);
    try testing.expect(empty != missing);

    try fixture.mock.add_directory(native_path("/root"));
    try testing.expectEqual(empty, try fixture.sum(null));
    try fixture.mock.put(native_path("/root/pipe"), .named_pipe, 0);
    try testing.expect(try fixture.sum(null) != empty);
}

//
// Goal: unreadable directories and entries are left out and reported when the caller asks, and
// left out quietly otherwise; cancellation is passed on.
// Method: make a directory unopenable, another unreadable and a file's metadata unreadable.
//
test "fingerprint reports what it cannot read" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.mock.add_directory(native_path("/root/locked"));
    try fixture.mock.set_faults(native_path("/root/locked"), .{
        .open = true,
    });
    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .read = true,
    });
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
    });

    var list = EventList.init(testing.allocator);
    defer list.deinit();
    const reported = try fingerprint_module.fingerprint(
        testing.allocator,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        null,
        &list,
    );
    try testing.expectEqual(@as(usize, 3), list.problems.items.len);
    try testing.expectEqual(reported, try fixture.sum(null));

    // Each cancellation is set on its own, so the walk reaches it.
    try fixture.mock.set_faults(native_path("/root/sub"), .{});
    try fixture.mock.set_faults(native_path("/root/locked"), .{});
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.sum(null));
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{});
    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .read = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.sum(null));
    try fixture.mock.set_faults(native_path("/root/sub"), .{});
    try fixture.mock.set_faults(native_path("/root/locked"), .{
        .open = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.sum(null));
}

//
// A lister for tests that reads the mock file system the generic way, so its fingerprint must
// match the generic one.
//
fn mock_lister(
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void {
    try testing.expect(dir_path.len > 0);
    try testing.expectEqual(@as(?[]const u8, null), name);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        });
        try entries.append(arena, .{
            .name = try arena.dupe(u8, entry.name),
            .stamp = fingerprint_module.stamp_from_stat(&stat),
        });
    }
}

//
// A lister that cannot read anything, as on a file system without the query it uses.
//
fn unsupported_lister(
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void {
    _ = io;
    _ = dir;
    _ = dir_path;
    _ = name;
    try entries.append(arena, .{
        .name = "partial",
        .stamp = .{
            .kind = .file,
            .size = 0,
            .mtime_ns = 0,
            .inode = 0,
        },
    });
    return error.Unexpected;
}

//
// A lister that runs out of memory.
//
fn out_of_memory_lister(
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void {
    _ = io;
    _ = dir;
    _ = dir_path;
    _ = name;
    _ = arena;
    _ = entries;
    return error.OutOfMemory;
}

//
// A lister that reports cancellation.
//
fn canceled_lister(
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: std.mem.Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void {
    _ = io;
    _ = dir;
    _ = dir_path;
    _ = name;
    _ = arena;
    _ = entries;
    return error.Canceled;
}

//
// Goal: a lister gives the same fingerprint as the generic way, a lister that fails falls back
// to the generic way, and running out of memory or cancellation is passed on.
// Method: fingerprint the same tree with each lister.
//
test "fingerprint uses a lister and falls back when it fails" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    const generic = try fixture.sum(null);
    try testing.expectEqual(generic, try fixture.sum(mock_lister));
    try testing.expectEqual(generic, try fixture.sum(unsupported_lister));
    try testing.expectError(error.OutOfMemory, fixture.sum(out_of_memory_lister));
    try testing.expectError(error.Canceled, fixture.sum(canceled_lister));
}

//
// Runs a fingerprint with `gpa`, for the allocation failure test.
//
fn run_fingerprint(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var list = EventList.init(gpa);
    defer list.deinit();
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
    });
    _ = try fingerprint_module.fingerprint(
        gpa,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        null,
        &list,
    );
}

//
// Goal: an allocation failure anywhere in a walk is returned and leaks nothing.
// Method: run a walk under checkAllAllocationFailures.
//
test "fingerprint survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, run_fingerprint, .{});
}
