//
// Tests for the exclusion rules.
//

const std = @import("std");
const filter = @import("filter.zig");
const options_module = @import("options.zig");

const testing = std.testing;

//
// Goal: directories are matched by exact name.
// Method: check default and custom lists against matching and near-miss names.
//
test "is_excluded_directory matches exact names" {
    try testing.expect(filter.is_excluded_directory(&.{}, "node_modules"));
    try testing.expect(filter.is_excluded_directory(&.{}, ".git"));
    try testing.expect(!filter.is_excluded_directory(&.{}, "node_modules2"));
    try testing.expect(!filter.is_excluded_directory(&.{}, "src"));

    const custom = [_][]const u8{"build"};
    try testing.expect(filter.is_excluded_directory(&.{
        .excluded_directories = &custom,
    }, "build"));
    try testing.expect(!filter.is_excluded_directory(&.{
        .excluded_directories = &custom,
    }, "node_modules"));
}

//
// Goal: files are matched by the extension after the last dot.
// Method: check names with matching, different, compound and missing extensions.
//
test "is_excluded_file matches the last extension" {
    const extensions = [_][]const u8{ ".log", ".gz" };
    const options: options_module.Options = .{
        .excluded_extensions = &extensions,
    };
    try testing.expect(filter.is_excluded_file(&options, "server.log"));
    try testing.expect(filter.is_excluded_file(&options, "archive.tar.gz"));
    try testing.expect(!filter.is_excluded_file(&options, "archive.tar"));
    try testing.expect(!filter.is_excluded_file(&options, "Makefile"));
    try testing.expect(!filter.is_excluded_file(&options, "log"));
    try testing.expect(!filter.is_excluded_file(&.{}, "server.log"));
}
