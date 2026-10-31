//
// Tests for the kqueue event decoding. The system calls only exist on Apple platforms, where
// they are exercised by the smoke tests; the decoding is pure and tested everywhere.
//

const std = @import("std");
const kqueue = @import("kqueue.zig");

const testing = std.testing;

//
// Goal: each vnode flag calls for the right checks on files and directories.
// Method: decode every flag combination that matters for both kinds of entry.
//
test "checks_for maps vnode flags to checks" {
    const file_write = kqueue.checks_for(kqueue.note_write, false);
    try testing.expect(file_write.entry);
    try testing.expect(!file_write.directory);

    const file_attrib = kqueue.checks_for(kqueue.note_attrib | kqueue.note_extend, false);
    try testing.expect(file_attrib.entry);

    const directory_write = kqueue.checks_for(kqueue.note_write, true);
    try testing.expect(!directory_write.entry);
    try testing.expect(directory_write.directory);

    const directory_link = kqueue.checks_for(kqueue.note_link, true);
    try testing.expect(directory_link.directory);

    const directory_attrib = kqueue.checks_for(kqueue.note_attrib, true);
    try testing.expect(!directory_attrib.entry);
    try testing.expect(!directory_attrib.directory);

    const deleted = kqueue.checks_for(kqueue.note_delete, true);
    try testing.expect(deleted.entry);
    const renamed = kqueue.checks_for(kqueue.note_rename, false);
    try testing.expect(renamed.entry);
    const revoked = kqueue.checks_for(kqueue.note_revoke, false);
    try testing.expect(revoked.entry);
}
