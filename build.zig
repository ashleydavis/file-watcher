//
// Builds the file watcher library and CLI tool and its unit tests.
//

const std = @import("std");
const manifest = @import("build.zig.zon");

//
// Defines the build steps: install, run, check, test and install-tests.
//
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    // kcov reads only LLVM's debug information, so coverage runs build the tests with LLVM.
    const use_llvm = builder.option(bool, "llvm", "Build with the LLVM backend, for kcov");

    // The macOS backend reaches kqueue and loads FSEvents through the C library.
    const library = builder.addModule("file_watcher", .{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (os.isDarwin()) true else null,
    });

    const build_options = builder.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

    const cli = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
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

    // Analysing the CLI tool without emitting a binary checks that the library compiles for a
    // target.
    const check_step = builder.step("check", "Compile the library and CLI tool without linking");
    const check = builder.addExecutable(.{
        .name = "file-watcher",
        .root_module = cli,
    });
    check_step.dependOn(&check.step);

    const exe = builder.addExecutable(.{
        .name = "file-watcher",
        .root_module = cli,
    });
    builder.installArtifact(exe);

    const run_step = builder.step("run", "Run the CLI tool");
    const run = builder.addRunArtifact(exe);
    run.step.dependOn(builder.getInstallStep());
    if (builder.args) |args| {
        run.addArgs(args);
    }
    run_step.dependOn(&run.step);

    // The test helpers are modules of their own, imported by name, because Zig allows a file in
    // one module only and both the library tests and the CLI tests use them. The library
    // module consumers import has no such imports.
    const mock_io = builder.createModule(.{
        .root_source_file = builder.path("src/mock_io.test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fake_backend = builder.createModule(.{
        .root_source_file = builder.path("src/fake_backend.test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "mock_io",
                .module = mock_io,
            },
        },
    });
    const library_test_module = builder.createModule(.{
        .root_source_file = builder.path("src/root.zig"),
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
    const cli_test_module = builder.createModule(.{
        .root_source_file = builder.path("src/main.zig"),
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

    const library_tests = builder.addTest(.{
        .name = "library-tests",
        .root_module = library_test_module,
        .use_llvm = use_llvm,
    });
    const cli_tests = builder.addTest(.{
        .name = "cli-tests",
        .root_module = cli_test_module,
        .use_llvm = use_llvm,
    });
    const test_step = builder.step("test", "Run the unit tests");
    test_step.dependOn(&builder.addRunArtifact(library_tests).step);
    test_step.dependOn(&builder.addRunArtifact(cli_tests).step);

    // Installing the test binaries lets them run without Zig: in CI jobs that reuse one build,
    // and under kcov.
    const install_tests_step = builder.step("install-tests", "Install the unit test binaries");
    for ([_]*std.Build.Step.Compile{ library_tests, cli_tests }) |tests| {
        const install = builder.addInstallArtifact(tests, .{
            .dest_dir = .{
                .override = .{
                    .custom = "tests",
                },
            },
        });
        install_tests_step.dependOn(&install.step);
    }
}
