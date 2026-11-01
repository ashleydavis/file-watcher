//
// Lists a Windows directory with each entry's metadata in one system call per buffer, for
// polling. Reading each entry's metadata separately opens a handle per entry, which made polling
// a large tree cost most of a CPU core on Windows.
//

const std = @import("std");
const fingerprint_module = @import("fingerprint.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = std.Io.Dir;
const Listed = fingerprint_module.Listed;
const Stamp = fingerprint_module.Stamp;

//
// The header of one `FILE_ID_FULL_DIR_INFORMATION` record written by `NtQueryDirectoryFile`.
// The UTF-16 file name of `FileNameLength` bytes follows it at `name_offset`.
//
pub const FileIdFullDirInformation = extern struct {
    NextEntryOffset: u32,
    FileIndex: u32,
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    EndOfFile: i64,
    AllocationSize: i64,
    FileAttributes: u32,
    FileNameLength: u32,
    EaSize: u32,
    FileId: i64,
};

//
// Where the file name starts in a record, as the Windows SDK lays the structure out.
//
pub const name_offset: usize = 80;

comptime {
    assert(@offsetOf(FileIdFullDirInformation, "LastWriteTime") == 24);
    assert(@offsetOf(FileIdFullDirInformation, "EndOfFile") == 40);
    assert(@offsetOf(FileIdFullDirInformation, "FileAttributes") == 56);
    assert(@offsetOf(FileIdFullDirInformation, "FileNameLength") == 60);
    assert(@offsetOf(FileIdFullDirInformation, "FileId") == 72);
    assert(@sizeOf(FileIdFullDirInformation) == name_offset);
}

//
// File attribute bits, with the values from the Windows SDK headers.
//
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

//
// The size of the buffer each `NtQueryDirectoryFile` call fills.
//
const buffer_size: usize = 64 * 1024;

//
// The upper bound on `NtQueryDirectoryFile` calls for one listing. Each call returns at least one
// entry, and NTFS directories hold at most 2^32 entries.
//
const calls_max: u64 = 1 << 32;

//
// Lists the entries of `dir`, or only the entry called `name` when it is given, into `entries`.
// Names and the buffer are allocated from `arena`. Follows the `Lister` signature;
// `io` and `dir_path` are unused because the handle is enough on Windows.
//
pub fn list(
    io: Io,
    dir: Dir,
    dir_path: []const u8,
    name: ?[]const u8,
    arena: Allocator,
    entries: *std.ArrayList(Listed),
) anyerror!void {
    _ = io;
    _ = dir_path;
    const windows = std.os.windows;
    const buffer = try arena.alignedAlloc(u8, .@"8", buffer_size);
    var mask: windows.UNICODE_STRING = .empty;
    if (name) |entry_name| {
        assert(entry_name.len > 0);
        const wide = try std.unicode.wtf8ToWtf16LeAlloc(arena, entry_name);
        mask = .{
            .Length = @intCast(wide.len * 2),
            .MaximumLength = @intCast(wide.len * 2),
            .Buffer = wide.ptr,
        };
    }
    var calls: u64 = 0;
    while (calls < calls_max) : (calls += 1) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        const status = windows.ntdll.NtQueryDirectoryFile(
            dir.handle,
            null,
            null,
            null,
            &io_status_block,
            buffer.ptr,
            @intCast(buffer.len),
            .IdFullDirectory,
            .FALSE,
            if (name != null) &mask else null,
            .fromBool(calls == 0),
        );
        switch (status) {
            .SUCCESS => try decode_records(buffer[0..io_status_block.Information], arena, entries),
            .NO_MORE_FILES, .NO_SUCH_FILE => {
                if (name) |entry_name| {
                    keep_named(entries, entry_name);
                }
                return;
            },
            .ACCESS_DENIED => return error.AccessDenied,
            else => return error.Unexpected,
        }
    }
    unreachable;
}

//
// Removes every entry not called `name`. Windows applies a name filter only on the first query
// of a handle, so a handle that was listed before returns every entry.
//
pub fn keep_named(entries: *std.ArrayList(Listed), name: []const u8) void {
    var kept: usize = 0;
    for (entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            entries.items[kept] = entry;
            kept += 1;
        }
    }
    entries.shrinkRetainingCapacity(kept);
}

//
// Decodes the records `NtQueryDirectoryFile` wrote into `buffer` and appends an entry with a
// stamp for each, leaving out `.` and `..`. The stamps match the ones `stamp_from_stat` makes from
// `statFile`, which reads the same fields from the file itself.
//
pub fn decode_records(buffer: []const u8, arena: Allocator, entries: *std.ArrayList(Listed)) !void {
    assert(buffer.len >= name_offset);
    const records_max = @divFloor(buffer.len, name_offset);
    var offset: usize = 0;
    var records: usize = 0;
    while (true) : (records += 1) {
        assert(records < records_max);
        assert(offset + name_offset <= buffer.len);
        // Records are copied out of the buffer because Wine does not align them.
        const header = std.mem.bytesToValue(
            FileIdFullDirInformation,
            buffer[offset..][0..name_offset],
        );
        const name_bytes = buffer[offset + name_offset ..][0..header.FileNameLength];
        const name_wide = try arena.alloc(u16, @divExact(name_bytes.len, 2));
        @memcpy(std.mem.sliceAsBytes(name_wide), name_bytes);
        const is_dot = std.mem.eql(u16, name_wide, &.{'.'});
        const is_dot_dot = std.mem.eql(u16, name_wide, &.{ '.', '.' });
        if (!is_dot and !is_dot_dot) {
            try entries.append(arena, .{
                .name = try std.unicode.wtf16LeToWtf8Alloc(arena, name_wide),
                .stamp = stamp_from_record(&header),
            });
        }
        if (header.NextEntryOffset == 0) {
            return;
        }
        assert(header.NextEntryOffset >= name_offset);
        offset += header.NextEntryOffset;
    }
}

//
// Turns one record into a stamp, the way `stamp_from_stat` turns `statFile`'s result into one: a
// reparse point, such as a symbolic link, is neither a file nor a directory.
//
fn stamp_from_record(header: *const FileIdFullDirInformation) Stamp {
    const attributes = header.FileAttributes;
    const kind: fingerprint_module.EntryKind = if (attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0)
        .other
    else if (attributes & FILE_ATTRIBUTE_DIRECTORY != 0)
        .directory
    else
        .file;
    const mtime = std.os.windows.fromSysTime(header.LastWriteTime);
    return .{
        .kind = kind,
        .size = @bitCast(header.EndOfFile),
        .mtime_ns = @truncate(mtime.nanoseconds),
        .inode = @bitCast(header.FileId),
    };
}

test {
    _ = @import("windows_listing.test.zig");
}
