//
// Tests for comparing paths against roots.
//

const std = @import("std");
const paths = @import("paths.zig");

const testing = std.testing;

//
// Goal: trailing separators are removed, except the one that makes a path the file system root.
// Method: trim roots with and without trailing separators.
//
test "trim_root keeps meaningful separators" {
    try testing.expectEqualStrings("/root", paths.trim_root("/root//"));
    try testing.expectEqualStrings("/root", paths.trim_root("/root"));
    try testing.expectEqualStrings("/", paths.trim_root("/"));
    try testing.expectEqualStrings("/", paths.trim_root("//"));
    try testing.expectEqualStrings("C:\\", paths.trim_root("C:\\"));
}

//
// Goal: a path is inside a root only at a separator boundary.
// Method: compare the root itself, a child, a sibling sharing a prefix and the file system root.
//
test "is_within respects separators" {
    try testing.expect(paths.is_within("/root", "/root"));
    try testing.expect(paths.is_within("/root/a", "/root"));
    try testing.expect(paths.is_within("/root/a", "/"));
    try testing.expect(!paths.is_within("/rooted", "/root"));
    try testing.expect(!paths.is_within("/ro", "/root"));
}
