//
// Lists a Windows directory with each entry's metadata in one system call per buffer, for
// polling. Reading each entry's metadata separately opens a handle per entry, which made polling
// a large tree cost most of a CPU core on Windows.
//

const std = @import("std");
const scan_module = @import("scan.zig");

const assert = std.debug.assert;
const Io = std.Io;
const Dir = std.Io.Dir;
const Stamp = scan_module.Stamp;
const Visitor = scan_module.Visitor;

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
// The longest file name, in UTF-16 code units, that NTFS allows.
//
const name_wide_max: usize = 255;

//
// The upper bound on `NtQueryDirectoryFile` calls for one listing. Each call returns at least one
// entry, and NTFS directories hold at most 2^32 entries.
//
const calls_max: u64 = 1 << 32;

//
// Lists the entries of `dir`, handing each to `visitor` until it asks to stop. `buffer` holds the
// records of one call at a time. Follows the `Lister` signature; `io` is unused because the
// handle is enough on Windows.
//
pub fn list(io: Io, dir: Dir, buffer: []align(8) u8, visitor: Visitor) anyerror!void {
    _ = io;
    assert(buffer.len >= name_offset);
    const windows = std.os.windows;
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
            null,
            .fromBool(calls == 0),
        );
        switch (status) {
            .SUCCESS => {
                const records = buffer[0..io_status_block.Information];
                if (!try decode_records(records, visitor)) {
                    return;
                }
            },
            .NO_MORE_FILES, .NO_SUCH_FILE => return,
            .ACCESS_DENIED => return error.AccessDenied,
            else => return error.Unexpected,
        }
    }
    unreachable;
}

//
// Decodes the records `NtQueryDirectoryFile` wrote into `buffer` and hands an entry with a stamp
// to `visitor` for each, leaving out `.` and `..`. The stamps match the ones `stamp_from_stat`
// makes from `statFile`, which reads the same fields from the file itself. Returns false when the
// visitor asked to stop.
//
pub fn decode_records(buffer: []const u8, visitor: Visitor) !bool {
    assert(buffer.len >= name_offset);
    const records_max = @divFloor(buffer.len, name_offset);
    var name_wide: [name_wide_max]u16 = undefined;
    var name: [name_wide_max * 3]u8 = undefined;
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
        assert(name_bytes.len <= name_wide_max * 2);
        const wide = name_wide[0..@divExact(name_bytes.len, 2)];
        @memcpy(std.mem.sliceAsBytes(wide), name_bytes);
        const is_dot = std.mem.eql(u16, wide, &.{'.'});
        const is_dot_dot = std.mem.eql(u16, wide, &.{ '.', '.' });
        if (!is_dot and !is_dot_dot) {
            const name_len = std.unicode.wtf16LeToWtf8(&name, wide);
            const is_going_on = try visitor.visit(.{
                .name = name[0..name_len],
                .stamp = stamp_from_record(&header),
            });
            if (!is_going_on) {
                return false;
            }
        }
        if (header.NextEntryOffset == 0) {
            return true;
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
    const kind: scan_module.EntryKind = if (attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0)
        .other
    else if (attributes & FILE_ATTRIBUTE_DIRECTORY != 0)
        .directory
    else
        .file;
    const mtime = std.os.windows.fromSysTime(header.LastWriteTime);
    return .{
        .kind = kind,
        .mtime_ns = mtime.nanoseconds,
    };
}

test {
    _ = @import("windows_listing.test.zig");
}
