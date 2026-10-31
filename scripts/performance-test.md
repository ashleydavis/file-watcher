# performance-test.sh

Measures the built CLI tool on a generated tree and prints the results for native, mixed and polling watching side by side. Every test runs 5 times and the averages are reported.

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
- `[summary-file]`: a file that receives the results as a markdown table, appended to its end, or `-` for none. CI passes `$GITHUB_STEP_SUMMARY`, so the table shows on the job's summary page.
- `[title]`: the heading of the markdown table, such as the platform measured. Default `Performance`.
- `[launcher...]`: a command that runs the binary, such as `xcrun simctl spawn booted` for a binary built for the iOS simulator. The tool's process is then found by its path to read its CPU time and memory.

Set the `RUNS` environment variable to change how many times each test runs. Default 5.

## What it measures

- Watch counters: directories, native watches, polled directories, budget and limit, from the tool's `-s` output.
- Startup: the time to scan the tree, set up every watch and exit (`-d 0`).
- Memory: the tool's memory after the load tests, also given per watched entry: the peak on Linux and Windows, the memory in use on macOS. Entries include the load test files.
- Idle CPU: CPU time used while watching the unchanged tree for a few seconds.
- Single change latency: the time from appending to a file until its event is printed, as the median and maximum of a series of samples. A second watcher prints through a pipe, so the script wakes the moment the event arrives, and the clock is read with bash's `EPOCHREALTIME`, so timing starts no process. Each sample still includes the time bash takes to write the file and read the line.
- Load: six tests of ten thousand changes each, timed from the first change until every changed file is reported, with the time taken to make the changes shown beside it. The script counts distinct reported files, so a test fails unless every one is reported:
  - files created at once (one `xargs touch`) and created in sequence (one at a time in a loop);
  - existing files modified at once (one `xargs touch`) and in sequence (appended to one at a time);
  - files deleted at once (one `xargs rm`) and in sequence (one at a time in a Perl loop, because starting `rm` once per file takes minutes on Windows).

The tree is watched as two roots: the generated files and the directory the load tests change. Every measurement runs in three modes: native, where every directory has a native watch; mixed, where `--max-watches 1` gives the only native watch to the files root, so the load root is polled on every platform, Windows included; and polling, where every directory is polled.

Each run measures the three modes in turn, so a slow spell on the machine affects all of them. Every figure is the average over the runs, except the latency's worst case, which is the slowest sample of any run. A load test fails if any run misses a change.

The script exits with code 1 when a change goes unreported. It runs on Linux, macOS and Windows (Git Bash) with bash 5 or later. CPU time and memory come from `/proc` on Linux, `ps` on macOS and PowerShell's `Get-Process` on Windows. Linux and Windows report peak memory; macOS reports the memory in use after the load tests, because it keeps no peak for another process.
