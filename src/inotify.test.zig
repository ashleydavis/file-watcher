//
// Tests for the inotify backend. Event decoding is tested with built buffers. The system calls
// are tested against a real inotify instance in a temporary directory, because the kernel is
// the only implementation of them; these tests stay in-process and finish in milliseconds.
//

const std = @import("std");
const mock_io_module = @import("mock_io");
const builtin = @import("builtin");
const hints_module = @import("hints.zig");
const inotify_module = @import("inotify.zig");

const testing = std.testing;
const native_path = mock_io_module.native_path;
const linux = std.os.linux;
const HintSet = hints_module.HintSet;
const Inotify = inotify_module.Inotify;

//
// Builds a buffer of raw inotify events the way the kernel lays them out.
//
const EventBuffer = struct {
    //
    // The raw event bytes.
    //
    bytes: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,

    //
    // The number of bytes written so far.
    //
    len: usize = 0,

    //
    // Appends one event, padding the name with zeros to a multiple of 16 bytes like the kernel.
    //
    fn add(self: *EventBuffer, wd: i32, mask: u32, name: []const u8) void {
        const padded: u32 = if (name.len == 0) 0 else @intCast(
            std.mem.alignForward(usize, name.len + 1, 16),
        );
        const header: linux.inotify_event = .{
            .wd = wd,
            .mask = mask,
            .cookie = 0,
            .len = padded,
        };
        @memcpy(self.bytes[self.len..][0..@sizeOf(linux.inotify_event)], std.mem.asBytes(&header));
        self.len += @sizeOf(linux.inotify_event);
        @memset(self.bytes[self.len..][0..padded], 0);
        @memcpy(self.bytes[self.len..][0..name.len], name);
        self.len += padded;
    }
};

//
// Goal: each kind of raw event becomes the right hint: directories created or moved in are
// `directory` hints, ones deleted or moved away and watches the kernel dropped are `gone` hints,
// anything else is an `entry` hint, and events for unknown watches are skipped.
// Method: decode a buffer with each kind of event.
//
test "decode_events turns raw events into hints" {
    var paths: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
    defer paths.deinit(testing.allocator);
    var descriptors: std.StringHashMapUnmanaged(i32) = .empty;
    defer descriptors.deinit(testing.allocator);
    try paths.put(testing.allocator, 1, native_path("/root"));
    try paths.put(testing.allocator, 2, native_path("/root/sub"));
    try descriptors.put(testing.allocator, native_path("/root"), 1);
    try descriptors.put(testing.allocator, native_path("/root/sub"), 2);

    var buffer: EventBuffer = .{};
    buffer.add(1, linux.IN.CREATE, "a.txt");
    buffer.add(1, linux.IN.CREATE | linux.IN.ISDIR, "new");
    buffer.add(1, linux.IN.MOVED_TO | linux.IN.ISDIR, "moved-in");
    buffer.add(1, linux.IN.DELETE | linux.IN.ISDIR, "deleted");
    buffer.add(1, linux.IN.MOVED_FROM | linux.IN.ISDIR, "moved-out");
    buffer.add(1, linux.IN.ATTRIB | linux.IN.ISDIR, "touched");
    buffer.add(2, linux.IN.DELETE_SELF, "");
    buffer.add(2, linux.IN.IGNORED, "");
    buffer.add(9, linux.IN.MODIFY, "lost");

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();
    try inotify_module.decode_events(buffer.bytes[0..buffer.len], &paths, &descriptors, &hints);
    try testing.expectEqual(@as(usize, 7), hints.paths.count());
    try testing.expect(hints.paths.get(native_path("/root/a.txt")).?.entry);
    try testing.expect(hints.paths.get(native_path("/root/new")).?.directory);
    try testing.expect(hints.paths.get(native_path("/root/moved-in")).?.directory);
    try testing.expect(hints.paths.get(native_path("/root/deleted")).?.gone);
    try testing.expect(hints.paths.get(native_path("/root/moved-out")).?.gone);
    try testing.expect(hints.paths.get(native_path("/root/touched")).?.entry);
    const sub = hints.paths.get(native_path("/root/sub")).?;
    try testing.expect(sub.entry);
    try testing.expect(sub.gone);

    hints.clear();
    try paths.put(testing.allocator, 3, native_path("/other"));
    try descriptors.put(testing.allocator, native_path("/other"), 3);
    var overflow: EventBuffer = .{};
    overflow.add(-1, linux.IN.Q_OVERFLOW, "");
    try inotify_module.decode_events(overflow.bytes[0..overflow.len], &paths, &descriptors, &hints);
    try testing.expectEqual(@as(usize, 2), hints.paths.count());
    try testing.expect(hints.paths.get(native_path("/root")).?.tree);
    try testing.expect(hints.paths.get(native_path("/other")).?.tree);

    hints.clear();
    var top_paths: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
    defer top_paths.deinit(testing.allocator);
    try top_paths.put(testing.allocator, 1, "/");
    const raw = overflow.bytes[0..overflow.len];
    try inotify_module.decode_events(raw, &top_paths, &descriptors, &hints);
    try testing.expect(hints.paths.get("/").?.tree);
}

//
// Joins the temporary directory's real path with `name`.
//
fn temp_path(buffer: []u8, tmp: *testing.TmpDir, name: []const u8) ![]const u8 {
    var base: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &base);
    if (name.len == 0) {
        return std.fmt.bufPrint(buffer, "{s}", .{base[0..length]});
    }
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ base[0..length], name });
}

//
// Goal: a real inotify watch reports a new file, moves a watch to a renamed directory and
// drops watches on request.
// Method: watch a temporary directory, create a file, wait and check the hint; then exercise
// watch errors and unwatch.
//
test "Inotify watches a real directory" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "sub", .default_dir);

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temp_path(&root_buffer, &tmp, "");
    var sub_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sub = try temp_path(&sub_buffer, &tmp, "sub");
    var moved_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const moved = try temp_path(&moved_buffer, &tmp, "moved");
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try temp_path(&file_buffer, &tmp, "a.txt");

    const inotify = try testing.allocator.create(Inotify);
    defer testing.allocator.destroy(inotify);
    try inotify.init(testing.allocator);
    defer inotify.deinit();

    try testing.expect(try inotify.watch(root, true));
    try testing.expect(try inotify.watch(sub, true));
    try testing.expect(!try inotify.watch(root, true));

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();
    try inotify.wait(0, &hints);
    try testing.expectEqual(@as(usize, 0), hints.paths.count());

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "a.txt",
        .data = "x",
    });
    try inotify.wait(1000, &hints);
    try testing.expect(hints.paths.get(file).?.entry);

    try tmp.dir.rename("sub", tmp.dir, "moved", testing.io);
    try testing.expect(!try inotify.watch(moved, true));
    try testing.expect(!inotify.unwatch(sub));
    try testing.expect(inotify.unwatch(moved));
    try testing.expect(!inotify.unwatch(moved));

    try testing.expectError(error.FileNotFound, inotify.watch(sub, true));
    try testing.expectError(error.NotDir, inotify.watch(file, true));

    try tmp.dir.createDir(testing.io, "moved/deeper", .default_dir);
    var deeper_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const deeper = try temp_path(&deeper_buffer, &tmp, "moved/deeper");
    try testing.expect(try inotify.watch(moved, true));
    try testing.expect(try inotify.watch(deeper, true));
    try testing.expectEqual(@as(u32, 3), inotify.watch_count());
    try inotify.unwatch_tree(moved);
    try testing.expectEqual(@as(u32, 1), inotify.watch_count());
    try inotify.unwatch_tree(root);
    try testing.expectEqual(@as(u32, 0), inotify.watch_count());
}

//
// Goal: every error number from the kernel maps to an error that says what went wrong, with
// running out of watches mapped to the limit error the watcher acts on.
// Method: map each documented error number and an undocumented one.
//
test "init_error and watch_error map kernel errors" {
    try testing.expectEqual(error.ProcessFdQuotaExceeded, inotify_module.init_error(.MFILE));
    try testing.expectEqual(error.SystemFdQuotaExceeded, inotify_module.init_error(.NFILE));
    try testing.expectEqual(error.SystemResources, inotify_module.init_error(.NOMEM));
    try testing.expectEqual(error.Unexpected, inotify_module.init_error(.PERM));
    try testing.expectEqual(error.LimitReached, inotify_module.watch_error(.NOSPC));
    try testing.expectEqual(error.AccessDenied, inotify_module.watch_error(.ACCES));
    try testing.expectEqual(error.FileNotFound, inotify_module.watch_error(.NOENT));
    try testing.expectEqual(error.NotDir, inotify_module.watch_error(.NOTDIR));
    try testing.expectEqual(error.SymLinkLoop, inotify_module.watch_error(.LOOP));
    try testing.expectEqual(error.NameTooLong, inotify_module.watch_error(.NAMETOOLONG));
    try testing.expectEqual(error.SystemResources, inotify_module.watch_error(.NOMEM));
    try testing.expectEqual(error.Unexpected, inotify_module.watch_error(.PERM));
}

//
// Watches the same directory twice, for the allocation failure test.
//
fn watch_twice(gpa: std.mem.Allocator, path: []const u8) !void {
    const inotify = try gpa.create(Inotify);
    defer gpa.destroy(inotify);
    try inotify.init(gpa);
    defer inotify.deinit();
    _ = try inotify.watch(path, true);
    _ = try inotify.watch(path, true);
}

//
// Goal: an allocation failure while adding a watch is reported and leaks neither memory nor the
// kernel watch.
// Method: watch a real directory twice under checkAllAllocationFailures.
//
test "Inotify survives allocation failure" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temp_path(&root_buffer, &tmp, "");
    try testing.checkAllAllocationFailures(testing.allocator, watch_twice, .{root});
}

//
// Goal: an instance that cannot be created reports why.
// Method: lower the open file limit to zero so no descriptor can be opened, try to create an
// instance and restore the limit.
//
test "Inotify init reports a full descriptor table" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{
        .cur = 0,
        .max = saved.max,
    });
    defer std.posix.setrlimit(.NOFILE, saved) catch unreachable;

    var inotify: Inotify = undefined;
    try testing.expectError(error.ProcessFdQuotaExceeded, inotify.init(testing.allocator));
}

//
// Goal: wake ends a wait at once, and the next wait blocks again.
// Method: wake an instance, wait with a long timeout and check it returned quickly with no hints,
// then wait briefly and check the wake was cleared.
//
test "Inotify wake ends a wait" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    const inotify = try testing.allocator.create(Inotify);
    defer testing.allocator.destroy(inotify);
    try inotify.init(testing.allocator);
    defer inotify.deinit();
    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();

    inotify.wake();
    inotify.wake();
    const start = std.Io.Timestamp.now(testing.io, .awake);
    try inotify.wait(60_000, &hints);
    const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake));
    try testing.expect(elapsed.nanoseconds < 10 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 0), hints.paths.count());

    const again = std.Io.Timestamp.now(testing.io, .awake);
    try inotify.wait(50, &hints);
    const waited = again.durationTo(std.Io.Timestamp.now(testing.io, .awake));
    try testing.expect(waited.nanoseconds >= 40 * std.time.ns_per_ms);
}

//
// Goal: when the wake descriptor cannot be created, the inotify descriptor is closed and the
// error says why.
// Method: lower the open file limit so the inotify descriptor takes the last free number, then
// create an instance and restore the limit.
//
test "Inotify init reports a missing wake descriptor" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    const saved = try std.posix.getrlimit(.NOFILE);
    const probe = linux.dup(0);
    try testing.expect(linux.errno(probe) == .SUCCESS);
    _ = linux.close(@intCast(probe));
    try std.posix.setrlimit(.NOFILE, .{
        .cur = probe + 1,
        .max = saved.max,
    });
    defer std.posix.setrlimit(.NOFILE, saved) catch unreachable;

    var inotify: Inotify = undefined;
    try testing.expectError(error.ProcessFdQuotaExceeded, inotify.init(testing.allocator));
    const after = linux.dup(0);
    try testing.expectEqual(probe, after);
    _ = linux.close(@intCast(after));
}
