//
// Builds the file watcher library and CLI tool, runs the unit tests and measures their coverage.
//

const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    // kqueue is reached through the C library on Apple platforms.
    const library = b.addModule("file_watcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (os.isDarwin()) true else null,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    const cli = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "file_watcher",
                .module = library,
            },
            .{
                .name = "build_options",
                .module = build_options.createModule(),
            },
        },
    });

    // The static library is the artifact for platforms that embed the watcher in an app, such as
    // Android and iOS. Every target builds it.
    const static_library = b.addLibrary(.{
        .name = "file_watcher",
        .linkage = .static,
        .root_module = library,
    });
    b.installArtifact(static_library);

    // The CLI tool targets desktops. iOS apps cannot run command line tools, so it is skipped
    // there.
    if (os != .ios) {
        const exe = b.addExecutable(.{
            .name = "file-watcher",
            .root_module = cli,
        });
        b.installArtifact(exe);

        const run_step = b.step("run", "Run the CLI tool");
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run.addArgs(args);
        }
        run_step.dependOn(&run.step);
    }

    // The test helpers are modules of their own, imported by name, because Zig allows a file in
    // one module only and both the library tests and the CLI tests use them. The library
    // module consumers import has no such imports.
    const mock_io = b.createModule(.{
        .root_source_file = b.path("src/mock_io.test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fake_backend = b.createModule(.{
        .root_source_file = b.path("src/fake_backend.test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "mock_io",
                .module = mock_io,
            },
        },
    });
    const library_test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (os.isDarwin()) true else null,
        .imports = &.{
            .{
                .name = "mock_io",
                .module = mock_io,
            },
            .{
                .name = "fake_backend",
                .module = fake_backend,
            },
        },
    });
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "file_watcher",
                .module = library,
            },
            .{
                .name = "build_options",
                .module = build_options.createModule(),
            },
            .{
                .name = "mock_io",
                .module = mock_io,
            },
        },
    });

    const library_tests = b.addTest(.{
        .root_module = library_test_module,
    });
    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // kcov reads the debug information of LLVM builds, so coverage builds use LLVM.
    const coverage_step = b.step("coverage", "Measure unit test coverage with kcov");
    const coverage_library_tests = b.addTest(.{
        .name = "library-tests",
        .root_module = library_test_module,
        .use_llvm = true,
    });
    const coverage_cli_tests = b.addTest(.{
        .name = "cli-tests",
        .root_module = cli_test_module,
        .use_llvm = true,
    });
    const merge = b.addSystemCommand(&.{ "kcov", "--merge" });
    const merged_directory = merge.addOutputDirectoryArg("merged");
    for ([_]*std.Build.Step.Compile{ coverage_library_tests, coverage_cli_tests }) |tests| {
        const kcov = b.addSystemCommand(&.{"kcov"});
        kcov.addPrefixedDirectoryArg("--include-path=", b.path("src"));
        kcov.addArg("--exclude-pattern=.test.zig");
        const report = kcov.addOutputDirectoryArg(tests.name);
        kcov.addArtifactArg(tests);
        merge.addDirectoryArg(report);
    }
    const install_coverage = b.addInstallDirectory(.{
        .source_dir = merged_directory,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    });
    coverage_step.dependOn(&install_coverage.step);
}
