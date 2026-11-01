# AI quick start

Facts an AI agent needs to work in this repository.

## Project

- A file watcher written in Zig 0.16.0: a library (`src/root.zig`, module `file_watcher`) and a CLI tool (`src/main.zig`, binary `file-watcher`) built on it.
- Native backends: inotify (Linux, Android), FSEvents (macOS, loaded at run time), kqueue (iOS), `ReadDirectoryChangesW` (Windows, which also lists directories with one query for polling). Other platforms poll.
- Every change is found by comparing the in-memory snapshot (`src/snapshot.zig`) with the file system. Backends only report paths to check.
- [How it works](how-it-works.md) describes each file's job.

## Commands

| Task | Command |
| --- | --- |
| Build | `zig build` |
| Unit tests | `zig build test` |
| Coverage (needs kcov) | `scripts/coverage.sh run` |
| Smoke tests | `zig build && scripts/smoke-test.sh zig-out/bin/file-watcher` |
| Performance tests (Linux) | `zig build -Doptimize=ReleaseFast && scripts/performance-test.sh zig-out/bin/file-watcher 100000` |
| Compile check for a target | `zig build check -Dtarget=aarch64-ios` |
| Cross compile | `zig build -Dtarget=x86_64-windows` |
| Install test binaries for another runner | `zig build install-tests -Dtarget=<target>` |
| Windows unit tests under Wine (Linux) | `zig build test -Dtarget=x86_64-windows -fwine` |

CI (`.github/workflows/ci.yml`) has one job per platform and kind of test, written out in full rather than as a matrix. Each platform's build job installs the CLI tool and the test binaries into `zig-out` and saves it to a cache keyed by the commit SHA; that platform's test jobs restore it and run the binaries without building. CI does not measure coverage; run `scripts/coverage.sh run` locally.

Check that these targets compile after any change to a backend or the watcher: `x86_64-windows`, `aarch64-macos`, `aarch64-linux-android` and `aarch64-ios`.

## Conventions

- Coding rules: https://github.com/ashleydavis/agent-config/blob/HEAD/rules/general.md and https://github.com/ashleydavis/agent-config/blob/HEAD/rules/zig.md.
- `snake_case` for functions, variables and files. Every file, type, function and field has a `//` comment block with an empty `//` line above and below.
- Tests live beside the code: `snapshot.zig` is tested by `snapshot.test.zig`, imported from a `test` block at the bottom of the code file.
- Unit tests use `std.testing.allocator` and a `checkAllAllocationFailures` test wherever code allocates.
- Line coverage stays at 100%: `scripts/coverage.sh run` fails otherwise.
- Lines stay within 100 columns.
- Tests build expected paths with `native_path("/root/a")` from the `mock_io` module, which uses the platform's separator, so the tests pass on Windows too. The mock file system accepts either separator.

## Test helpers

- `src/mock_io.test.zig` (module `mock_io`): an in-memory file system and clock behind `std.Io`. Add files with `add_file`, change them with `write_file`, remove them with `remove`, inject failures with `set_faults` and run code during waits with `sleep_callback`.
- `src/fake_backend.test.zig` (module `fake_backend`): a scripted backend. Queue hints with `queue`, fail watches with `failing_path` and `watch_error`, fail a wait with `wait_error`. Its `Config` makes it recursive like Windows or file-watching like kqueue.
- Both are separate modules, imported by name, because Zig 0.16 allows a file in one module only. `build.zig` wires them into the test modules.

## Pitfalls

- A `Watcher` keeps a pointer into itself. Create it in place (`init(self: *Watcher, ...)`) and keep it at that address.
- Zig 0.16 resolves every `@import` path eagerly, including in `test` blocks, so a test file must exist before the code that imports it compiles.
- kcov reads LLVM debug information only, so `scripts/coverage.sh` builds the tests with `-Dllvm=true`.
- The Windows, FSEvents and kqueue system calls are compiled only for their platforms. Their decoding functions are pure and tested on every platform, and each has a test against a real directory that runs only on its own platform.
