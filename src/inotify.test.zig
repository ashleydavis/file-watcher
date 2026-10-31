//
// Tests for the inotify backend. Event decoding is tested with built buffers. The system calls
// are tested against a real inotify instance in a temporary directory, because the kernel is
// the only implementation of them; these tests stay in-process and finish in milliseconds.
//

const std = @import("std");
const builtin = @import("builtin");
const hints_module = @import("hints.zig");
const inotify_module = @import("inotify.zig");

const testing = std.testing;
const linux = std.os.linux;
const HintSet = hints_module.HintSet;
const Inotify = inotify_module.Inotify;

//
// Builds a buffer of raw inotify events the way the kernel lays them out.
//
const EventBuffer = struct {
    bytes: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined,
    len: usize = 0,

    fn add(self: *EventBuffer, wd: i32, mask: u32, name: []const u8) void {
        const padded: u32 = if (name.len == 0) 0 else @intCast(std.mem.alignForward(usize, name.len + 1, 16));
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
// Goal: each kind of raw event becomes the right hint, and unknown or ignored watches are
// skipped.
// Method: decode a buffer with named, unnamed, ignored, unknown and overflow events.
//
test "decode_events turns raw events into hints" {
    var paths: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
    defer paths.deinit(testing.allocator);
    try paths.put(testing.allocator, 1, "/root");
    try paths.put(testing.allocator, 2, "/root/sub");

    var buffer: EventBuffer = .{};
    buffer.add(1, linux.IN.CREATE, "a.txt");
    buffer.add(2, linux.IN.DELETE_SELF, "");
    buffer.add(2, linux.IN.IGNORED, "");
    buffer.add(9, linux.IN.MODIFY, "lost");

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();
    try inotify_module.decode_events(buffer.bytes[0..buffer.len], &paths, &hints);
    try testing.expectEqual(@as(usize, 2), hints.paths.count());
    try testing.expect(hints.paths.get("/root/a.txt").?.entry);
    try testing.expect(hints.paths.get("/root/sub").?.entry);

    hints.clear();
    var overflow: EventBuffer = .{};
    overflow.add(-1, linux.IN.Q_OVERFLOW, "");
    try inotify_module.decode_events(overflow.bytes[0..overflow.len], &paths, &hints);
    try testing.expect(hints.paths.get("/root").?.directory);
    try testing.expect(hints.paths.get("/root/sub").?.directory);
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
}
