# Requirements

This checklist records every requirement of the project. Each item is ticked once it is built and checked, with how it was checked. Checks were run on 2026-10-31 on Linux x86_64.

## Language and coding rules

- [x] Written in Zig, locked to Zig 0.16.0 (`minimum_zig_version` in `build.zig.zon`).
- [x] Follows the coding rules in https://github.com/ashleydavis/agent-config (`rules/general.md`, `rules/zig.md`, `rules/testing.md`, `rules/writing.md`), audited after the code was written: 100-column limit, `zig fmt`, a comment block on every file, type, function and field, split compound conditions, no one-line struct literals, tests in `.test.zig` files beside the code, `std.testing.allocator` and `checkAllAllocationFailures` tests, and shell scripts with usage text and a `.md` file each.
- [x] Idiomatic Zig style, simple and easy to read, with no overengineering: one comptime-selected backend per platform behind a generic watcher, and the standard `std.Io` interface for file system access.

## Code library

- [x] A code library that the CLI tool uses (`src/root.zig`, module `file_watcher`).
- [x] Usable in other projects directly from Git, by commit SHA or version tag (`zig fetch --save git+https://...#<ref>`). Checked by building and running an example project that depends on the package, for Linux, Windows, macOS and Android targets.
- [x] Works on Linux, Windows, macOS, Android and iOS. Linux: unit, smoke and performance tests. Android: the static Android build runs on this machine's Linux kernel and reports changes. Windows: the Windows build runs under Wine, where native events for files in the root and polling of the whole tree were checked; Wine delivers no events for subdirectories, so tree-wide native events were checked through the decoding unit tests. macOS and iOS: CI runs the unit, smoke and performance tests on macOS runners and in the iOS simulator, and the FSEvents and kqueue decoding is unit tested on every platform.
- [x] Uses the most efficient native watch method on each platform: inotify on Linux and Android, FSEvents on macOS, kqueue on iOS, `ReadDirectoryChangesW` on Windows. [How it works](how-it-works.md) explains each.
- [x] Knows the platform's limit on the number of files and directories that can be watched (`src/limit.zig`).
- [x] Uses a configurable quota percentage of that limit (`quota_percent`, `--quota`).
- [x] Falls back to polling once the quota is used up. Checked by unit tests and by the smoke test that overflows a 1% quota of the real inotify limit.
- [x] Falls back to polling when native watching fails, at start or while waiting. Checked by unit tests.
- [x] Excludes configurable file types (extensions).
- [x] Excludes configurable directories.
- [x] By default excludes `node_modules` and other well known hefty directories.

## CLI tool

- [x] A CLI tool for Linux, Windows and macOS (`zig-out/bin/file-watcher`).
- [x] Text output.
- [x] YAML output.
- [x] JSON output (JSON Lines).
- [x] Exposes the library's options: excluded directories, excluded extensions, quota percentage, poll interval and forced polling.

## Build

- [x] Compiles on Linux.
- [x] Cross compiles for Windows (x86_64 and aarch64).
- [x] Cross compiles for macOS (x86_64 and aarch64).
- [x] Cross compiles for Android (aarch64, x86_64 and arm).
- [x] Cross compiles for iOS (device and simulator, compiled without linking because linking needs Apple's SDK).

## Tests

- [x] Unit tests with 100% coverage of the code, measured with kcov by `scripts/coverage.sh run` over the code compiled into the Linux test binaries.
- [x] Unit tests use mocks where possible and keep file system use to a minimum: an in-memory `std.Io` file system and clock and a scripted backend. Only the inotify system call tests and one end-to-end watcher test use a temporary directory.
- [x] Smoke tests (shell script) that cover the features of the CLI tool (`scripts/smoke-test.sh`).
- [x] Performance tests (shell script) that print stats (`scripts/performance-test.sh`).
- [x] The CLI tool has been tested.
- [x] The unit, smoke and performance tests have been run and all pass.
- [x] A CI pipeline tests on each platform, with one build job per platform, cached by commit SHA and reused by that platform's test jobs, one job per kind of test and no matrix (`.github/workflows/ci.yml`). Run 12 passed every job on Linux, Windows, macOS, Android and the iOS simulator.

## Docs

- [x] README: how to build for the local platform.
- [x] README: how to cross compile for Linux, Windows, macOS, Android and iOS.
- [x] README: how to run the unit tests and smoke tests.
- [x] AI quick start.
- [x] User guide for the CLI.
- [x] User guide for the code library.
- [x] How it works.
