# smoke-test.sh

Runs the built CLI tool against real directories and checks each feature: help, version, usage errors, the text, JSON and YAML formats, created, modified, deleted and renamed files and directories, default and custom exclusions, polling, the quota and its overflow to polling, the counters, several roots and the duration.

## Usage

```bash
zig build
```

```bash
scripts/smoke-test.sh zig-out/bin/file-watcher
```

## Arguments

- `<path-to-file-watcher>`: the CLI tool to test.
- `[launcher...]`: a command that runs the tool, such as `xcrun simctl spawn booted` for a build for the iOS simulator.

## Output

One line per check, `ok` or `FAIL`, then the number passed and failed. The script exits with code 1 when any check fails.

## Notes

- It runs on Linux, macOS (including its bash 3.2) and Windows under Git Bash. On Windows it passes the work directory in Windows form and turns backslashes in the output into slashes before checking it, and the JSON check uses a file name with a space, because Windows forbids quotes in file names.
- Each case runs the watcher in the background for a fixed duration (`-d`) and makes changes while it runs, so a full run takes under a minute.
- The JSON check parses every line with Python when `python3` is installed. The YAML check parses the output when the Python `yaml` package is installed.
- The overflow case reads the watch budget for a 1% quota from the tool's counters and creates more directories than that, so the last ones are polled. It is skipped when that budget is above 20000 directories.
