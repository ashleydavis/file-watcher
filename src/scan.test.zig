//
// Tests for checking a tree for changes by time, run against the in-memory file system and clock
// so every change and failure is exact.
//

const std = @import("std");
const event_module = @import("event.zig");
const scan_module = @import("scan.zig");
const mock_io_module = @import("mock_io");
const options_module = @import("options.zig");

const testing = std.testing;
const EventList = event_module.EventList;
const Listed = scan_module.Listed;
const MockIo = mock_io_module.MockIo;
const Result = scan_module.Result;
const native_path = mock_io_module.native_path;

//
// A mock file system holding a small tree, made at time 0, and the options that leave out
// `.log` files.
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
    // Moves the mock clock to `ns`, so changes made next carry that time.
    //
    fn at(self: *Fixture, ns: i96) void {
        self.mock.clock_ns = ns;
    }

    //
    // Checks `/root` for times after `since_ns` up to `until_ns`, read the generic way or
    // through `lister`.
    //
    fn check(
        self: *Fixture,
        lister: ?scan_module.Lister,
        since_ns: i96,
        until_ns: i96,
    ) !Result {
        return scan_module.scan(
            testing.allocator,
            self.mock.io(),
            native_path("/root"),
            &self.options,
            lister,
            since_ns,
            until_ns,
            null,
        );
    }
};

//
// Goal: every kind of change to an entry that counts is found in the window holding its time,
// and not in the windows before or after it.
// Method: make one change at a time at a new time and check the windows around it.
//
test "scan finds every counted change in its window" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try testing.expectEqual(Result.unchanged, try fixture.check(null, 0, 10));

    fixture.at(20);
    try fixture.mock.add_file(native_path("/root/sub/new.txt"), 1);
    try testing.expectEqual(Result.changed, try fixture.check(null, 10, 20));
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 0, 19));
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 20, 30));

    fixture.at(40);
    fixture.mock.write_file(native_path("/root/a.txt"), 9);
    try testing.expectEqual(Result.changed, try fixture.check(null, 30, 40));

    fixture.at(50);
    fixture.mock.remove(native_path("/root/sub/b.txt"));
    try testing.expectEqual(Result.changed, try fixture.check(null, 40, 50));

    fixture.at(60);
    fixture.mock.remove(native_path("/root/sub"));
    try testing.expectEqual(Result.changed, try fixture.check(null, 50, 60));
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 60, 70));
}

//
// Goal: changes inside excluded directories are not found, and neither is writing an excluded
// file. Creating an excluded file is found, because it changes its directory's time.
// Method: change entries inside `node_modules`, then create and write a `.log` file.
//
test "scan leaves out excluded entries" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    fixture.at(20);
    try fixture.mock.add_file(native_path("/root/node_modules/d.js"), 1);
    fixture.mock.write_file(native_path("/root/node_modules/c.js"), 8);
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 10, 20));

    fixture.at(30);
    try fixture.mock.add_file(native_path("/root/sub/trace.log"), 1);
    try testing.expectEqual(Result.changed, try fixture.check(null, 20, 30));
    fixture.at(40);
    fixture.mock.write_file(native_path("/root/sub/trace.log"), 3);
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 30, 40));
}

//
// Goal: a missing root, a root that is a file and a root changed by itself are each told apart,
// and a special entry counts like a file.
// Method: check the root, delete it, put a file in its place, then add a special entry.
//
test "scan tells a missing root and the root's own changes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    fixture.at(20);
    try fixture.mock.put(native_path("/root/pipe"), .named_pipe, 0);
    fixture.mock.write_file(native_path("/root/pipe"), 0);
    try testing.expectEqual(Result.changed, try fixture.check(null, 10, 20));

    fixture.mock.remove(native_path("/root"));
    try testing.expectEqual(Result.missing, try fixture.check(null, 0, 30));
    try fixture.mock.add_file(native_path("/root"), 1);
    try testing.expectEqual(Result.missing, try fixture.check(null, 0, 30));
}

//
// Goal: a root whose metadata cannot be read is missing and reported, and a root that cannot
// be opened, or disappears between being found and being opened, is missing too.
// Method: inject faults into the root.
//
test "scan treats an unreadable root as missing" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var list = EventList.init(testing.allocator);
    defer list.deinit();
    try fixture.mock.set_faults(native_path("/root"), .{
        .stat = true,
    });
    const stat_result = try scan_module.scan(
        testing.allocator,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        null,
        0,
        0,
        &list,
    );
    try testing.expectEqual(Result.missing, stat_result);
    try testing.expectEqual(@as(usize, 1), list.problems.items.len);
    try fixture.mock.set_faults(native_path("/root"), .{
        .stat = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.check(null, 0, 10));

    try fixture.mock.set_faults(native_path("/root"), .{
        .open = true,
    });
    try testing.expectEqual(Result.missing, try fixture.check(null, 0, 10));
    try fixture.mock.set_faults(native_path("/root"), .{
        .open_missing = true,
    });
    try testing.expectEqual(Result.missing, try fixture.check(null, 0, 10));
}

//
// Goal: unreadable directories and entries are left out and reported when the caller asks, the
// whole tree is walked then even after a change is found, and cancellation is passed on.
// Method: make a directory unopenable, another unreadable and a file's metadata unreadable, and
// change a file the walk reaches first.
//
test "scan reports what it cannot read" {
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
    try fixture.mock.add_directory(native_path("/root/gone"));
    try fixture.mock.set_faults(native_path("/root/gone"), .{
        .open_missing = true,
    });

    var list = EventList.init(testing.allocator);
    defer list.deinit();
    const reported = try scan_module.scan(
        testing.allocator,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        null,
        -1,
        0,
        &list,
    );
    try testing.expectEqual(Result.changed, reported);
    try testing.expectEqual(@as(usize, 3), list.problems.items.len);
    try testing.expectEqual(Result.unchanged, try fixture.check(null, 0, 10));

    // Each cancellation is set on its own, so the walk reaches it.
    try fixture.mock.set_faults(native_path("/root/sub"), .{});
    try fixture.mock.set_faults(native_path("/root/locked"), .{});
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.check(null, 0, 10));
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{});
    try fixture.mock.set_faults(native_path("/root/sub"), .{
        .read = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.check(null, 0, 10));
    try fixture.mock.set_faults(native_path("/root/sub"), .{});
    try fixture.mock.set_faults(native_path("/root/locked"), .{
        .open = true,
        .is_canceled = true,
    });
    try testing.expectError(error.Canceled, fixture.check(null, 0, 10));
}

//
// A lister for tests that reads the mock file system the generic way, so it must find the same
// changes.
//
fn mock_lister(
    io: std.Io,
    dir: std.Io.Dir,
    buffer: []align(8) u8,
    visitor: scan_module.Visitor,
) anyerror!void {
    try testing.expectEqual(scan_module.lister_buffer_size, buffer.len);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const stat = try dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        });
        const is_going_on = try visitor.visit(.{
            .name = entry.name,
            .stamp = scan_module.stamp_from_stat(&stat),
        });
        if (!is_going_on) {
            return;
        }
    }
}

//
// A lister that cannot read anything, as on a file system without the query it uses.
//
fn unsupported_lister(
    io: std.Io,
    dir: std.Io.Dir,
    buffer: []align(8) u8,
    visitor: scan_module.Visitor,
) anyerror!void {
    _ = io;
    _ = dir;
    _ = buffer;
    _ = visitor;
    return error.Unexpected;
}

//
// A lister that hands over one entry with a time in every window, then fails.
//
fn failing_lister(
    io: std.Io,
    dir: std.Io.Dir,
    buffer: []align(8) u8,
    visitor: scan_module.Visitor,
) anyerror!void {
    _ = io;
    _ = dir;
    _ = buffer;
    _ = try visitor.visit(.{
        .name = "partial.log",
        .stamp = .{
            .kind = .file,
            .mtime_ns = 5,
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
    buffer: []align(8) u8,
    visitor: scan_module.Visitor,
) anyerror!void {
    _ = io;
    _ = dir;
    _ = buffer;
    _ = visitor;
    return error.OutOfMemory;
}

//
// A lister that reports cancellation.
//
fn canceled_lister(
    io: std.Io,
    dir: std.Io.Dir,
    buffer: []align(8) u8,
    visitor: scan_module.Visitor,
) anyerror!void {
    _ = io;
    _ = dir;
    _ = buffer;
    _ = visitor;
    return error.Canceled;
}

//
// Goal: a lister finds the same changes as the generic way, a lister that cannot read a
// directory falls back to the generic way, one that fails part way is reported rather than
// listed twice, and running out of memory or cancellation is passed on.
// Method: check the same tree with each lister, before and after a change.
//
test "scan uses a lister and falls back when it fails" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try testing.expectEqual(Result.unchanged, try fixture.check(mock_lister, 0, 10));
    try testing.expectEqual(Result.unchanged, try fixture.check(unsupported_lister, 0, 10));
    fixture.at(20);
    fixture.mock.write_file(native_path("/root/sub/b.txt"), 7);
    try testing.expectEqual(Result.changed, try fixture.check(mock_lister, 10, 20));
    try testing.expectEqual(Result.changed, try fixture.check(unsupported_lister, 10, 20));
    try testing.expectError(error.OutOfMemory, fixture.check(out_of_memory_lister, 0, 10));
    try testing.expectError(error.Canceled, fixture.check(canceled_lister, 0, 10));

    var list = EventList.init(testing.allocator);
    defer list.deinit();
    const partial = try scan_module.scan(
        testing.allocator,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        failing_lister,
        0,
        10,
        &list,
    );
    try testing.expectEqual(Result.unchanged, partial);
    try testing.expectEqual(@as(usize, 1), list.problems.items.len);
    try testing.expectEqualStrings(native_path("/root"), list.problems.items[0].path);
}

//
// Runs a full walk with `gpa`, for the allocation failure test.
//
fn run_scan(gpa: std.mem.Allocator) !void {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var list = EventList.init(gpa);
    defer list.deinit();
    try fixture.mock.set_faults(native_path("/root/a.txt"), .{
        .stat = true,
    });
    _ = try scan_module.scan(
        gpa,
        fixture.mock.io(),
        native_path("/root"),
        &fixture.options,
        null,
        0,
        0,
        &list,
    );
}

//
// Goal: an allocation failure anywhere in a walk is returned and leaks nothing.
// Method: run a walk under checkAllAllocationFailures.
//
test "scan survives allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, run_scan, .{});
}
