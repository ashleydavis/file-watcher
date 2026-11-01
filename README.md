# file-watcher

A fast file watcher written in Zig: a library for Zig projects and a CLI tool built on it.

- Uses the native watch method of each platform: inotify on Linux, FSEvents on macOS and `ReadDirectoryChangesW` on Windows. Other platforms are polled.
- Knows the platform's limit on native watches, uses a configurable percentage of it and polls every directory beyond that, or every directory when native watching fails.
- Leaves out `node_modules`, `.git` and other well known heavy directories by default. Excluded directories and file extensions are configurable.
- Reports which watched directory changed whenever a file or directory under it is created, modified, deleted or renamed. It keeps nothing per file, so memory stays around 1 MiB even for 100,000 files.
- Throttles reports of each directory to one a second by default, with the throttle configurable.
- The CLI tool prints changes as text, JSON Lines or YAML.

## Docs

- [AI quick start](docs/ai-quick-start.md)
- [User guide: CLI tool](docs/user-guide-cli.md)
- [User guide: code library](docs/user-guide-library.md)
- [How it works](docs/how-it-works.md)
- [Performance baseline](docs/performance-baseline.md)
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

`zig build check -Dtarget=<target>` compiles the library and CLI tool for a target without linking.

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

`.github/workflows/ci.yml` runs on every push, and can be started by hand from the Actions tab. A newer push cancels the run still going for the same branch. Each platform has a build job that builds the CLI tool and the unit test binaries once and saves them to a cache keyed by the commit SHA. That platform's test jobs restore the build and run it, so the code is built once per platform per commit. Each platform and kind of test has its own job, so the run overview shows exactly what failed:

| Job | Runner | What it runs |
| --- | --- | --- |
| Linux build | Ubuntu | The unit test binaries, the CLI tool and a ReleaseFast CLI tool |
| Linux unit tests | Ubuntu | The unit test binaries |
| Linux smoke tests | Ubuntu | `scripts/smoke-test.sh` |
| Linux performance tests | Ubuntu | `scripts/performance-test.sh`, with results in the job summary |
| Windows build | Windows | The unit test binaries, the CLI tool and a ReleaseFast CLI tool |
| Windows unit tests | Windows | The unit test binaries |
| Windows smoke tests | Windows | `scripts/smoke-test.sh` under Git Bash |
| Windows performance tests | Windows | `scripts/performance-test.sh` under Git Bash, with results in the job summary |
| macOS build | macOS | The unit test binaries, the CLI tool and a ReleaseFast CLI tool |
| macOS unit tests | macOS | The unit test binaries |
| macOS smoke tests | macOS | `scripts/smoke-test.sh` |
| macOS performance tests | macOS | `scripts/performance-test.sh`, with results in the job summary |

## Run the performance tests

The performance tests generate a tree of files and print startup time, memory, idle CPU, change latency and load results in three modes: native, mixed (native watches run out, so the watched directories are polled) and polling. Each load test makes ten thousand changes (created, modified and deleted, each at once and in sequence), waits until the reports stop, then checks that one more change is reported. Every test repeats for up to 4 minutes and the script finishes within 5, so each performance job takes about 5 minutes. CI runs the same test on every platform. They run on Linux, macOS and Windows (Git Bash) with bash 5 or later.

```bash
zig build -Doptimize=ReleaseFast
```

```bash
scripts/performance-test.sh zig-out/bin/file-watcher 100000
```
