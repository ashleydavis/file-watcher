# smoke-test.sh

Runs the built CLI tool against real directories and checks each feature: help, version, usage errors, the text, JSON and YAML formats, that every kind of change (files and directories created, modified, deleted and renamed, at any depth and in new directories) reports its watched directory, the throttle, default and custom exclusions, polling, the quota and its overflow to polling, the counters, Ctrl+C, several roots and the duration.

## Usage

```bash
zig build
```

```bash
scripts/smoke-test.sh zig-out/bin/file-watcher
```

## Arguments

- `<path-to-file-watcher>`: the CLI tool to test.

## Output

One line per check, `ok` or `FAIL`, then the number passed and failed. The script exits with code 1 when any check fails.

## Notes

- It runs on Linux, macOS (including its bash 3.2) and Windows under Git Bash. On Windows it passes the work directory in Windows form and turns backslashes in the output into slashes before checking it, and the JSON check uses a file name with a space, because Windows forbids quotes in file names.
- Each case runs the watcher in the background and makes one change at a time, waiting for its report before the next and for the output to go quiet in between, so a late report of one change cannot pass for the next. A change that must not be reported, such as one in `node_modules`, is given 1.5 seconds to show up. A slow machine only makes the waits longer. A change unreported after 60 seconds fails its check. A local run takes about half a minute.
- The JSON check parses every line with Python when `python3` is installed. The YAML check parses the output when the Python `yaml` package is installed.
- The interrupt case sends SIGINT to the running tool and checks it stops at once with exit code 130. It is skipped on Windows, because Git Bash cannot send Ctrl+C to a Windows program.
- The overflow case reads the watch budget for a 1% quota from the tool's counters and creates more directories than that, so the last ones are polled. It is skipped when that budget is above 20000 directories.
