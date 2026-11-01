//
// Tests for the FSEvents backend. Mapping and decoding events is pure and tested everywhere; the
// streams themselves are tested against a real directory on macOS.
//

const std = @import("std");
const builtin = @import("builtin");
const fsevents = @import("fsevents.zig");
const hints_module = @import("hints.zig");

const testing = std.testing;
const HintSet = hints_module.HintSet;
const Root = fsevents.Root;

//
// Two roots: one reached through a symbolic link, as `/tmp` is on macOS, and one given as a
// relative path.
//
var linked_root: Root = .{
    .path = "/tmp/watched",
    .canonical = "/private/tmp/watched",
    .stream = null,
};
var relative_root: Root = .{
    .path = "src",
    .canonical = "/Users/me/project/src",
    .stream = null,
};
const roots = [_]*Root{ &linked_root, &relative_root };

//
// Goal: event paths are rewritten to start with the root as the watcher knows it, and paths
// outside every root, or only sharing a prefix with one, are ignored.
// Method: map the root itself, nested paths, a trailing separator and near misses.
//
test "map_path rewrites canonical paths to watched paths" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("/tmp/watched", (try fsevents.map_path(arena, "/private/tmp/watched", &roots)).?);
    try testing.expectEqualStrings("/tmp/watched/a/b.txt", (try fsevents.map_path(arena, "/private/tmp/watched/a/b.txt", &roots)).?);
    try testing.expectEqualStrings("/tmp/watched/dir", (try fsevents.map_path(arena, "/private/tmp/watched/dir/", &roots)).?);
    try testing.expectEqualStrings("src/main.zig", (try fsevents.map_path(arena, "/Users/me/project/src/main.zig", &roots)).?);
    try testing.expectEqual(@as(?[]const u8, null), try fsevents.map_path(arena, "/private/tmp/watched-other/x", &roots));
    try testing.expectEqual(@as(?[]const u8, null), try fsevents.map_path(arena, "/elsewhere", &roots));

    var top: Root = .{
        .path = "/",
        .canonical = "/",
        .stream = null,
    };
    const top_roots = [_]*Root{&top};
    try testing.expectEqualStrings("/", (try fsevents.map_path(arena, "/", &top_roots)).?);
    try testing.expectEqualStrings("/etc/hosts", (try fsevents.map_path(arena, "/etc/hosts", &top_roots)).?);
}

//
// Goal: each kind of event becomes the right hint.
// Method: add a plain change, a rescan request, a dropped-events flag and an outside path.
//
test "add_event chooses the hint for each flag" {
    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();

    try fsevents.add_event("/private/tmp/watched/a.txt", 0x00010000, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched/a.txt").?.entry);

    try fsevents.add_event("/private/tmp/watched/deep", fsevents.flag_must_scan_sub_dirs, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched/deep").?.tree);

    try fsevents.add_event("/private/tmp/watched", fsevents.flag_root_changed, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched").?.entry);

    try fsevents.add_event("/outside", 0, &roots, &hints);
    try testing.expectEqual(@as(?hints_module.Checks, null), hints.paths.get("/outside"));

    hints.clear();
    try fsevents.add_event("/", fsevents.flag_kernel_dropped, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched").?.tree);
    try testing.expect(hints.paths.get("src").?.tree);
}

//
// Goal: events queued by the callback decode into the same hints, and a full queue rescans every
// root instead.
// Method: queue two events and decode them, then overflow the queue and decode again.
//
test "queue_event and decode_pending carry events between threads" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var is_overflowed = false;
    fsevents.queue_event(testing.allocator, &bytes, &is_overflowed, "/private/tmp/watched/a.txt", 0);
    fsevents.queue_event(testing.allocator, &bytes, &is_overflowed, "/Users/me/project/src", fsevents.flag_must_scan_sub_dirs);
    try testing.expect(!is_overflowed);

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();
    try fsevents.decode_pending(bytes.items, is_overflowed, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched/a.txt").?.entry);
    try testing.expect(hints.paths.get("src").?.tree);

    const big = try testing.allocator.alloc(u8, fsevents.pending_bytes_max);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    fsevents.queue_event(testing.allocator, &bytes, &is_overflowed, big, 0);
    try testing.expect(is_overflowed);
    fsevents.queue_event(testing.allocator, &bytes, &is_overflowed, "/private/tmp/watched/b.txt", 0);

    hints.clear();
    try fsevents.decode_pending(bytes.items, is_overflowed, &roots, &hints);
    try testing.expect(hints.paths.get("/tmp/watched").?.tree);
    try testing.expect(hints.paths.get("src").?.tree);
    try testing.expectEqual(@as(?hints_module.Checks, null), hints.paths.get("/tmp/watched/a.txt"));
}

//
// Goal: running out of memory while queueing marks the queue overflowed instead of losing the
// events silently.
// Method: queue an event with an allocator that always fails.
//
test "queue_event marks the queue overflowed when memory runs out" {
    var bytes: std.ArrayList(u8) = .empty;
    var is_overflowed = false;
    fsevents.queue_event(testing.failing_allocator, &bytes, &is_overflowed, "/a", 0);
    try testing.expect(is_overflowed);
    try testing.expectEqual(@as(usize, 0), bytes.items.len);
}

//
// Goal: on macOS, a stream reports a file created under a watched root by the root's own path,
// `wake` ends a wait at once, and unwatching a root stops its events.
// Method: watch a temporary directory through its unresolved path, create a file, and wait.
//
test "FsEvents reports changes on macOS" {
    if (builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const path = path_buffer[0..length];

    var backend: fsevents.FsEvents = undefined;
    try backend.init(testing.allocator);
    defer backend.deinit();
    try testing.expect(try backend.watch(path, true));
    try testing.expect(!try backend.watch(path, true));

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();

    // Give the stream a moment to start, then make a change.
    try io.sleep(.fromMilliseconds(200), .awake);
    try tmp.dir.writeFile(io, .{
        .sub_path = "new.txt",
        .data = "x",
    });
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/new.txt", .{path});
    defer testing.allocator.free(expected);
    var attempts: u32 = 0;
    while (hints.paths.get(expected) == null and attempts < 50) : (attempts += 1) {
        try backend.wait(100, &hints);
    }
    try testing.expect(hints.paths.get(expected).?.entry);

    backend.wake();
    hints.clear();
    try backend.wait(60_000, &hints);

    try testing.expect(backend.unwatch(path));
    try testing.expect(!backend.unwatch(path));
}
