# file-watcher

A fast file watcher written in Zig: a library for Zig projects and a CLI tool built on it.

- Uses the native watch method of each platform: inotify on Linux and Android, kqueue on macOS and iOS, and `ReadDirectoryChangesW` on Windows.
- Knows the platform's limit on native watches, uses a configurable percentage of it and polls every directory beyond that, or every directory when native watching fails.
- Leaves out `node_modules`, `.git` and other well known heavy directories by default. Excluded directories and file extensions are configurable.
- Reports created, modified and deleted files and directories in batches.
- The CLI tool prints events as text, JSON Lines or YAML.

## Docs

- [AI quick start](docs/ai-quick-start.md)
- [User guide: CLI tool](docs/user-guide-cli.md)
- [User guide: code library](docs/user-guide-library.md)
- [How it works](docs/how-it-works.md)
- [Requirements checklist](docs/requirements.md)

## Requirements

- Zig 0.16.0, locked as the minimum version in `build.zig.zon`.
- kcov, only for measuring test coverage.
- bash, only for the smoke and performance test scripts.

## Build for the local platform

```bash
zig build
```

The CLI tool is written to `zig-out/bin/file-watcher` (`file-watcher.exe` on Windows). For a fast build to use or measure:

```bash
zig build -Doptimize=ReleaseFast
```

Run it on a directory:

```bash
zig-out/bin/file-watcher src
```

## Cross compile

Zig cross compiles without extra toolchains. Pass the target with `-Dtarget`. Each command writes the CLI tool to `zig-out/bin`.

Linux:

```bash
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
```

```bash
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
```

Windows:

```bash
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

```bash
zig build -Dtarget=aarch64-windows -Doptimize=ReleaseFast
```

macOS:

```bash
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

```bash
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
```

Android builds a static CLI tool that runs from `adb shell`, and checks the library for use in an Android app:

```bash
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast
```

On iOS the library is embedded in apps, and linking needs Apple's SDK, so the iOS build compiles the library and CLI code and stops before linking. An iOS app links the library through its own Zig build, as the [library guide](docs/user-guide-library.md) shows.

```bash
zig build -Dtarget=aarch64-ios
```

```bash
zig build -Dtarget=aarch64-ios-simulator
```

`zig build check -Dtarget=<target>` runs the same compile-only check for any target.

## Run the unit tests

```bash
zig build test
```

The unit tests run against an in-memory file system and clock, so they finish in well under a second. A few tests use real inotify on a temporary directory.

Measure coverage with kcov:

```bash
scripts/coverage.sh run
```

The HTML report is written to `zig-out/coverage/index.html`.

## Run the smoke tests

The smoke tests drive the built CLI tool against real directories:

```bash
zig build
```

```bash
scripts/smoke-test.sh zig-out/bin/file-watcher
```

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request, with one job per platform:

| Job | Runner | What it runs |
| --- | --- | --- |
| Linux | Ubuntu | Unit tests, coverage with kcov, smoke tests and a short performance run. |
| Windows | Windows | Unit tests and smoke tests, under Git Bash. |
| macOS | macOS | Unit tests and smoke tests. |
| Android | Ubuntu | The x86_64 Android unit tests and smoke tests, which run on the Linux kernel, and builds for every Android ABI. |
| iOS | macOS | A device build and the unit tests in the iOS simulator. |
| Cross compile | Ubuntu | A release build for every supported target. |

## Run the performance tests

The performance tests generate a tree of files and print startup time, memory, idle CPU, change latency and burst throughput for native watching and for polling. They read `/proc`, so they run on Linux.

```bash
zig build -Doptimize=ReleaseFast
```

```bash
scripts/performance-test.sh zig-out/bin/file-watcher 100000
```
