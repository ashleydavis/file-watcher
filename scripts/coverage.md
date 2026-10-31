# coverage.sh

Measures the line coverage of the unit tests with [kcov](https://github.com/SimonKagstrom/kcov) and fails when any line of the library or CLI code is left uncovered.

## Usage

```bash
scripts/coverage.sh run
```

## Arguments

- `run`: measures coverage. The script prints its usage when run with no arguments, so the argument confirms the run.

## What it does

- Runs `zig build install-tests -Dllvm=true`, which builds both unit test binaries with the LLVM backend (kcov reads LLVM's debug information) into `zig-out/coverage-build/tests`.
- Runs each binary under kcov and merges the reports into `zig-out/coverage`, with the HTML report at `zig-out/coverage/index.html`.
- Prints the covered and total lines and exits with code 1 when they differ.

Test files (`*.test.zig`) are left out of the report. Coverage counts the code compiled into the test binaries on the machine running the script, so on Linux it counts the inotify backend and the platform-independent parts of the kqueue and Windows backends.
