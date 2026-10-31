//
// Decides which directory entries the watcher leaves out, from the caller's options.
//

const std = @import("std");
const options_module = @import("options.zig");

const assert = std.debug.assert;
const Options = options_module.Options;

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

test {
    _ = @import("filter.test.zig");
}
