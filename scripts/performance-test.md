# performance-test.sh

Measures the built CLI tool on a generated tree and prints the results for native watching and for polling side by side.

## Usage

```bash
zig build -Doptimize=ReleaseFast
```

```bash
scripts/performance-test.sh zig-out/bin/file-watcher 100000
```

## Arguments

- `<path-to-file-watcher>`: the CLI tool to measure. Build it with `-Doptimize=ReleaseFast` for meaningful numbers.
- `[file-count]`: the number of files in the generated tree, spread over directories of 100 files. Default 100000.

## What it measures

- Watch counters: directories, native watches, polled directories, budget and limit, from the tool's `-s` output.
- Startup: the time to scan the tree, set up every watch and exit (`-d 0`).
- Peak memory: the tool's peak resident memory (`VmHWM`) after the other measurements, also given per watched entry.
- Idle CPU: CPU time used while watching the unchanged tree for a few seconds.
- Single change latency: the time from appending to a file until its event is printed, as the median and maximum of a series of samples. A second watcher prints through a pipe, so the script wakes the moment the event arrives, and the clock is read with bash's `EPOCHREALTIME`, so timing starts no process. Each sample still includes the time bash takes to write the file and read the line.
- Burst: the time from starting to create a batch of new files until every one is reported, including the time to create them. The output file is checked every millisecond, so the time includes up to a millisecond of the script's own delay.

The script exits with code 1 when a change goes unreported. It reads `/proc`, so it runs on Linux.
