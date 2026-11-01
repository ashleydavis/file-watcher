//
// Tests for listing Windows directories. Decoding the records is pure and tested everywhere; the
// system call is tested against a real directory on Windows.
//

const std = @import("std");
const builtin = @import("builtin");
const fingerprint_module = @import("fingerprint.zig");
const windows_listing = @import("windows_listing.zig");

const testing = std.testing;
const FileIdFullDirInformation = windows_listing.FileIdFullDirInformation;
const Listed = fingerprint_module.Listed;

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

    var entries: std.ArrayList(Listed) = .empty;
    try windows_listing.decode_records(buffer.slice(), arena, &entries);

    try testing.expectEqual(@as(usize, 4), entries.items.len);
    const file = entries.items[0];
    try testing.expectEqualStrings("a.txt", file.name);
    try testing.expectEqual(fingerprint_module.EntryKind.file, file.stamp.kind);
    try testing.expectEqual(@as(u64, 12), file.stamp.size);
    const expected_time = std.os.windows.fromSysTime(133_000_000_000_000_000);
    try testing.expectEqual(@as(i64, @truncate(expected_time.nanoseconds)), file.stamp.mtime_ns);
    try testing.expectEqual(@as(std.Io.File.INode, 77), file.stamp.inode);
    try testing.expectEqual(fingerprint_module.EntryKind.directory, entries.items[1].stamp.kind);
    try testing.expectEqualStrings("link", entries.items[2].name);
    try testing.expectEqual(fingerprint_module.EntryKind.other, entries.items[2].stamp.kind);
    try testing.expectEqualStrings("é.txt", entries.items[3].name);
    const all_ones: std.Io.File.INode = @bitCast(@as(i64, -1));
    try testing.expectEqual(all_ones, entries.items[3].stamp.inode);
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

    var entries: std.ArrayList(Listed) = .empty;
    try windows_listing.decode_records(buffer.slice(), arena, &entries);
    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("abc", entries.items[1].name);
    try testing.expectEqual(@as(u64, 3), entries.items[2].stamp.size);
}

//
// Goal: only entries with the asked-for name are kept, in any letter case.
// Method: filter a list holding the name in another case and other names.
//
test "keep_named keeps only the named entry" {
    const stamp: fingerprint_module.Stamp = .{
        .kind = .file,
        .size = 0,
        .mtime_ns = 0,
        .inode = 0,
    };
    var items = [_]Listed{
        .{ .name = "a.txt", .stamp = stamp },
        .{ .name = "File.TXT", .stamp = stamp },
        .{ .name = "b.txt", .stamp = stamp },
    };
    var entries: std.ArrayList(Listed) = .initBuffer(&items);
    entries.items.len = items.len;
    windows_listing.keep_named(&entries, "file.txt");
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("File.TXT", entries.items[0].name);
}

//
// Goal: on Windows, listing a real directory gives the same stamps as `statFile`, and asking
// for one name gives that entry alone or nothing.
// Method: make a temporary directory with a file and a subdirectory, list it both ways and
// compare with `statFile`.
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

    var entries: std.ArrayList(Listed) = .empty;
    try windows_listing.list(io, tmp.dir, "tmp", null, arena, &entries);
    try testing.expectEqual(@as(usize, 2), entries.items.len);
    for (entries.items) |entry| {
        const stat = try tmp.dir.statFile(io, entry.name, .{
            .follow_symlinks = false,
        });
        const stamp = fingerprint_module.stamp_from_stat(&stat);
        try testing.expectEqual(stamp.kind, entry.stamp.kind);
        try testing.expectEqual(stamp.inode, entry.stamp.inode);
        try testing.expectEqual(stamp.mtime_ns, entry.stamp.mtime_ns);
        if (stamp.kind == .file) {
            try testing.expectEqual(stamp.size, entry.stamp.size);
        }
    }

    // A name filter applies to a handle's first query only, so each named listing gets a fresh
    // handle, as the snapshot does.
    var fresh = try tmp.dir.openDir(io, ".", .{
        .iterate = true,
    });
    defer fresh.close(io);
    var one: std.ArrayList(Listed) = .empty;
    try windows_listing.list(io, fresh, "tmp", "file.txt", arena, &one);
    try testing.expectEqual(@as(usize, 1), one.items.len);
    try testing.expectEqualStrings("file.txt", one.items[0].name);
    try testing.expectEqual(@as(u64, 5), one.items[0].stamp.size);

    var other = try tmp.dir.openDir(io, ".", .{
        .iterate = true,
    });
    defer other.close(io);
    var none: std.ArrayList(Listed) = .empty;
    try windows_listing.list(io, other, "tmp", "missing.txt", arena, &none);
    try testing.expectEqual(@as(usize, 0), none.items.len);
}
