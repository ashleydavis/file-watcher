//
// Tests for decoding Windows change records. The system calls only exist on Windows, where they
// are exercised by the smoke tests; the decoding is pure and tested everywhere.
//

const std = @import("std");
const hints_module = @import("hints.zig");
const read_directory_changes = @import("read_directory_changes.zig");

const testing = std.testing;
const FileNotifyInformation = read_directory_changes.FileNotifyInformation;
const HintSet = hints_module.HintSet;

//
// Builds a buffer of change records the way Windows lays them out.
//
const RecordBuffer = struct {
    bytes: [1024]u8 align(4) = undefined,
    len: usize = 0,
    last: ?usize = null,

    fn add(self: *RecordBuffer, action: u32, name: []const u8) void {
        if (self.last) |last| {
            const header: *FileNotifyInformation = @ptrCast(@alignCast(self.bytes[last..].ptr));
            header.NextEntryOffset = @intCast(self.len - last);
        }
        var wide: [128]u16 = undefined;
        const units = std.unicode.wtf8ToWtf16Le(&wide, name) catch unreachable;
        const header: FileNotifyInformation = .{
            .NextEntryOffset = 0,
            .Action = action,
            .FileNameLength = @intCast(units * 2),
        };
        self.last = self.len;
        @memcpy(self.bytes[self.len..][0..@sizeOf(FileNotifyInformation)], std.mem.asBytes(&header));
        self.len += @sizeOf(FileNotifyInformation);
        @memcpy(self.bytes[self.len..][0 .. units * 2], std.mem.sliceAsBytes(wide[0..units]));
        self.len += std.mem.alignForward(usize, units * 2, 4);
    }
};

//
// Goal: every record becomes an entry hint for its full path, including non-ASCII names.
// Method: decode a buffer of several records and check the hinted paths.
//
test "decode_changes turns records into entry hints" {
    var buffer: RecordBuffer = .{};
    buffer.add(1, "a.txt");
    buffer.add(3, "sub\\b.txt");
    buffer.add(5, "caf\u{e9}\u{1f600}");

    var hints = HintSet.init(testing.allocator);
    defer hints.deinit();
    try read_directory_changes.decode_changes(buffer.bytes[0..buffer.len], "C:\\root", &hints);
    try testing.expectEqual(@as(usize, 3), hints.paths.count());
    try testing.expect(hints.paths.get("C:\\root\\a.txt").?.entry);
    try testing.expect(hints.paths.get("C:\\root\\sub\\b.txt").?.entry);
    try testing.expect(hints.paths.get("C:\\root\\caf\u{e9}\u{1f600}").?.entry);
}
