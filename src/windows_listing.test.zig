//
// Tests for listing Windows directories. Decoding the records is pure and tested everywhere; the
// system call is tested against a real directory on Windows.
//

const std = @import("std");
const builtin = @import("builtin");
const scan_module = @import("scan.zig");
const windows_listing = @import("windows_listing.zig");

const testing = std.testing;
const FileIdFullDirInformation = windows_listing.FileIdFullDirInformation;
const Listed = scan_module.Listed;

//
// Keeps a copy of every entry it is handed, and asks to stop after `limit` entries.
//
const Collector = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Listed) = .empty,
    limit: usize = std.math.maxInt(usize),

    fn visitor(self: *Collector) scan_module.Visitor {
        return .{
            .context = self,
            .visit_fn = visit,
        };
    }

    fn visit(context: *anyopaque, entry: Listed) anyerror!bool {
        const self: *Collector = @ptrCast(@alignCast(context));
        try self.entries.append(self.arena, .{
            .name = try self.arena.dupe(u8, entry.name),
            .stamp = entry.stamp,
        });
        return self.entries.items.len < self.limit;
    }
};

//
// Builds a buffer of directory records the way `NtQueryDirectoryFile` lays them out.
//
const RecordBuffer = struct {
    //
    // The raw record bytes.
    //
    bytes: [2048]u8 align(8) = undefined,

    //
    // The number of bytes written so far.
    //
    len: usize = 0,

    //
    // Where the last record starts, so the next one can be linked to it.
    //
    last: ?usize = null,

    //
    // Appends one record, padded to `alignment`, and links the previous record to it.
    //
    fn add(
        self: *RecordBuffer,
        name: []const u8,
        attributes: u32,
        size: i64,
        write_time: i64,
        file_id: i64,
        alignment: usize,
    ) void {
        const start = std.mem.alignForward(usize, self.len, alignment);
        if (self.last) |last| {
            const next: u32 = @intCast(start - last);
            @memcpy(self.bytes[last..][0..4], std.mem.asBytes(&next));
        }
        var wide: [64]u16 = undefined;
        const wide_len = std.unicode.wtf8ToWtf16Le(&wide, name) catch unreachable;
        const header: FileIdFullDirInformation = .{
            .NextEntryOffset = 0,
            .FileIndex = 0,
            .CreationTime = 0,
            .LastAccessTime = 0,
            .LastWriteTime = write_time,
            .ChangeTime = 0,
            .EndOfFile = size,
            .AllocationSize = 0,
            .FileAttributes = attributes,
            .FileNameLength = @intCast(wide_len * 2),
            .EaSize = 0,
            .FileId = file_id,
        };
        @memcpy(self.bytes[start..][0..windows_listing.name_offset], std.mem.asBytes(&header));
        const name_start = start + windows_listing.name_offset;
        const name_bytes = std.mem.sliceAsBytes(wide[0..wide_len]);
        @memcpy(self.bytes[name_start..][0..name_bytes.len], name_bytes);
        self.last = start;
        self.len = name_start + name_bytes.len;
    }

    //
    // The records written so far.
    //
    fn slice(self: *const RecordBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

//
// Goal: records decode into named entries with the same stamps `statFile` gives, leaving out
// `.` and `..`.
// Method: build a file, a directory, a reparse point and the dot entries, then decode them.
//
test "decode_records turns records into stamped entries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buffer: RecordBuffer = .{};
    buffer.add(".", 0x10, 0, 0, 1, 8);
    buffer.add("..", 0x10, 0, 0, 2, 8);
    buffer.add("a.txt", 0x20, 12, 133_000_000_000_000_000, 77, 8);
    buffer.add("sub", 0x10, 0, 133_000_000_000_000_001, 78, 8);
    buffer.add("link", 0x10 | 0x400, 0, 0, 79, 8);
    buffer.add("é.txt", 0x80, 3, 0, -1, 8);

    var collector: Collector = .{
        .arena = arena,
    };
    try testing.expect(try windows_listing.decode_records(buffer.slice(), collector.visitor()));
    const entries = &collector.entries;

    try testing.expectEqual(@as(usize, 4), entries.items.len);
    const file = entries.items[0];
    try testing.expectEqualStrings("a.txt", file.name);
    try testing.expectEqual(scan_module.EntryKind.file, file.stamp.kind);
    const expected_time = std.os.windows.fromSysTime(133_000_000_000_000_000);
    try testing.expectEqual(expected_time.nanoseconds, file.stamp.mtime_ns);
    try testing.expectEqual(scan_module.EntryKind.directory, entries.items[1].stamp.kind);
    try testing.expectEqualStrings("link", entries.items[2].name);
    try testing.expectEqual(scan_module.EntryKind.other, entries.items[2].stamp.kind);
    try testing.expectEqualStrings("é.txt", entries.items[3].name);
}

//
// Goal: records packed without alignment, as Wine writes them, decode the same.
// Method: build records on 2-byte boundaries and decode them.
//
test "decode_records reads unaligned records" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buffer: RecordBuffer = .{};
    buffer.add("ab", 0x20, 1, 5, 1, 2);
    buffer.add("abc", 0x20, 2, 6, 2, 2);
    buffer.add("d", 0x20, 3, 7, 3, 2);

    var collector: Collector = .{
        .arena = arena,
    };
    try testing.expect(try windows_listing.decode_records(buffer.slice(), collector.visitor()));
    try testing.expectEqual(@as(usize, 3), collector.entries.items.len);
    try testing.expectEqualStrings("abc", collector.entries.items[1].name);
    try testing.expectEqualStrings("d", collector.entries.items[2].name);

    // A visitor that asks to stop gets no more entries.
    var stopping: Collector = .{
        .arena = arena,
        .limit = 2,
    };
    try testing.expect(!try windows_listing.decode_records(buffer.slice(), stopping.visitor()));
    try testing.expectEqual(@as(usize, 2), stopping.entries.items.len);
}

//
// Goal: on Windows, listing a real directory gives the same stamps as `statFile`.
// Method: make a temporary directory with a file and a subdirectory, list it and compare with
// `statFile`.
//
test "list matches statFile on Windows" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }
    const io = testing.io;
    var tmp = testing.tmpDir(.{
        .iterate = true,
    });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "file.txt",
        .data = "hello",
    });
    try tmp.dir.createDir(io, "sub", .default_dir);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const buffer = try arena.alignedAlloc(u8, .@"8", scan_module.lister_buffer_size);
    var collector: Collector = .{
        .arena = arena,
    };
    try windows_listing.list(io, tmp.dir, buffer, collector.visitor());
    try testing.expectEqual(@as(usize, 2), collector.entries.items.len);
    for (collector.entries.items) |entry| {
        const stat = try tmp.dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        });
        const stamp = scan_module.stamp_from_stat(&stat);
        try testing.expectEqual(stamp.kind, entry.stamp.kind);
        try testing.expectEqual(stamp.mtime_ns, entry.stamp.mtime_ns);
    }
}
