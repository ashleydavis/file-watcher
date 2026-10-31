//
// Builds the file watcher library and CLI tool, runs the unit tests and measures their coverage.
//

const std = @import("std");
const manifest = @import("build.zig.zon");

//
// Defines the build steps: install, run, check, test and coverage.
//
pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    // kqueue is reached through the C library on Apple platforms.
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
    // target. It is the only way to check iOS, where the linker needs Apple's SDK.
    const check_step = builder.step("check", "Compile the library and CLI tool without linking");
    const check = builder.addExecutable(.{
        .name = "file-watcher",
        .root_module = cli,
    });
    check_step.dependOn(&check.step);

    // The CLI tool targets desktops and Android. iOS apps cannot run command line tools, so on
    // iOS the install step checks that the library compiles instead.
    if (os == .ios) {
        builder.getInstallStep().dependOn(&check.step);
    } else {
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
    }

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

    // Linking iOS tests needs the C library stubs from the SDK given with `--sysroot`. Zig looks
    // in the SDK's `/usr/lib` only when told to, and prefixes the path with the sysroot itself.
    if (os == .ios) {
        if (builder.sysroot != null) {
            for ([_]*std.Build.Module{ library_test_module, cli_test_module }) |module| {
                module.addLibraryPath(.{
                    .cwd_relative = "/usr/lib",
                });
            }
        }
    }

    const library_tests = builder.addTest(.{
        .root_module = library_test_module,
    });
    const cli_tests = builder.addTest(.{
        .root_module = cli_test_module,
    });
    const test_step = builder.step("test", "Run the unit tests");
    test_step.dependOn(&builder.addRunArtifact(library_tests).step);
    test_step.dependOn(&builder.addRunArtifact(cli_tests).step);

    // Installing the test binaries lets them run where the build cannot run them, such as the
    // iOS simulator.
    const install_tests_step = builder.step("install-tests", "Install the unit test binaries");
    for ([_]*std.Build.Step.Compile{ library_tests, cli_tests }, [_][]const u8{
        "library-tests",
        "cli-tests",
    }) |tests, name| {
        const install = builder.addInstallArtifact(tests, .{
            .dest_dir = .{
                .override = .{
                    .custom = "tests",
                },
            },
            .dest_sub_path = name,
        });
        install_tests_step.dependOn(&install.step);
    }

    // kcov reads the debug information of LLVM builds, so coverage builds use LLVM.
    const coverage_step = builder.step("coverage", "Measure unit test coverage with kcov");
    const coverage_library_tests = builder.addTest(.{
        .name = "library-tests",
        .root_module = library_test_module,
        .use_llvm = true,
    });
    const coverage_cli_tests = builder.addTest(.{
        .name = "cli-tests",
        .root_module = cli_test_module,
        .use_llvm = true,
    });
    const merge = builder.addSystemCommand(&.{ "kcov", "--merge" });
    const merged_directory = merge.addOutputDirectoryArg("merged");
    for ([_]*std.Build.Step.Compile{ coverage_library_tests, coverage_cli_tests }) |tests| {
        const kcov = builder.addSystemCommand(&.{"kcov"});
        kcov.addPrefixedDirectoryArg("--include-path=", builder.path("src"));
        kcov.addArg("--exclude-pattern=.test.zig");
        const report = kcov.addOutputDirectoryArg(tests.name);
        kcov.addArtifactArg(tests);
        // The test runner's progress goes to a file, so a passing run prints nothing; a failing
        // run still fails the step through kcov's exit code.
        _ = kcov.captureStdErr(.{});
        merge.addDirectoryArg(report);
    }
    const install_coverage = builder.addInstallDirectory(.{
        .source_dir = merged_directory,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    });
    coverage_step.dependOn(&install_coverage.step);
}
