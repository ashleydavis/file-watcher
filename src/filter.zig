//
// Decides which directory entries the watcher leaves out, from the caller's options.
//

const std = @import("std");
const builtin = @import("builtin");
const options_module = @import("options.zig");

const assert = std.debug.assert;
const Options = options_module.Options;

//
// The characters that separate path components on the platform being built for.
//
const separators = if (builtin.os.tag == .windows) "/\\" else "/";

//
// Whether a directory with this name is left out, together with everything inside it.
//
pub fn is_excluded_directory(options: *const Options, name: []const u8) bool {
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, '/') == null);
    for (options.excluded_directories) |excluded| {
        if (std.mem.eql(u8, excluded, name)) {
            return true;
        }
    }
    return false;
}

//
// Whether a file with this name is left out because of its extension.
//
pub fn is_excluded_file(options: *const Options, name: []const u8) bool {
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, '/') == null);
    const extension = std.fs.path.extension(name);
    if (extension.len == 0) {
        return false;
    }
    for (options.excluded_extensions) |excluded| {
        if (std.mem.eql(u8, excluded, extension)) {
            return true;
        }
    }
    return false;
}

//
// Whether a change at `path`, inside the watched `root`, is left out: some directory between the
// root and the path is excluded, or the path's own name is an excluded directory or has an
// excluded extension. Backends report paths without saying whether they are files or
// directories, so the last name is checked both ways.
//
pub fn is_excluded_path(options: *const Options, root: []const u8, path: []const u8) bool {
    assert(path.len >= root.len);
    var components = std.mem.tokenizeAny(u8, path[root.len..], separators);
    var current = components.next() orelse return false;
    while (components.next()) |following| {
        if (is_excluded_directory(options, current)) {
            return true;
        }
        current = following;
    }
    return is_excluded_directory(options, current) or is_excluded_file(options, current);
}

test {
    _ = @import("filter.test.zig");
}
