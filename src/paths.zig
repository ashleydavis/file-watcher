//
// Compares paths against watched roots: whether a path is inside a root, and the form roots are
// kept in.
//

const std = @import("std");

const assert = std.debug.assert;

//
// Whether `path` is `root` or inside it. Separators are respected, so `/rooted` is not inside
// `/root`.
//
pub fn is_within(path: []const u8, root: []const u8) bool {
    assert(root.len > 0);
    if (!std.mem.startsWith(u8, path, root)) {
        return false;
    }
    if (path.len == root.len) {
        return true;
    }
    if (std.fs.path.isSep(root[root.len - 1])) {
        return true;
    }
    return std.fs.path.isSep(path[root.len]);
}

//
// Removes trailing separators from a root path, so it compares equal to the paths backends
// report. A separator that is the whole path ("/") or follows a drive ("C:\\") is kept, because
// removing it changes which directory the path names.
//
pub fn trim_root(path: []const u8) []const u8 {
    assert(path.len > 0);
    var end = path.len;
    while (end > 1) : (end -= 1) {
        if (!std.fs.path.isSep(path[end - 1])) {
            break;
        }
        if (path[end - 2] == ':') {
            break;
        }
    }
    assert(end > 0);
    return path[0..end];
}

test {
    _ = @import("paths.test.zig");
}
