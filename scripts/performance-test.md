# performance-test.sh

Measures the built CLI tool on a generated tree and prints the results for native, mixed and polling watching side by side. Every test repeats for up to 4 minutes, and the averages are reported. The whole script finishes within about 5 minutes.

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

Every test repeats, all three modes in turn, until 4 minutes have passed since the script started, then the script finishes and reports. A run is not started when the slowest run so far would end after 4 minutes 45 seconds, so the whole script takes at most about 5 minutes. Every mode runs at least once. Set the `RUNS` environment variable to cap how many times each test runs. Default 5.

## What it measures

- Watch counters: directories, native watches, polled directories, budget and limit, from the tool's `-s` output.
- Startup: the time to scan the tree, set up every watch and exit (`-d 0`).
- Memory: the tool's memory after the load tests, also given per watched entry: the peak on Linux and Windows, the memory in use on macOS. Entries include the load test files.
- Idle CPU: CPU time used while watching the unchanged tree for a few seconds.
- Single change latency: the time from appending to a file until its directory's change is printed, as the median and maximum of a series of samples. A second watcher, with the throttle off so samples less than a second apart are each reported, prints through a pipe, so the script wakes the moment the line arrives, and the clock is read with bash's `EPOCHREALTIME`, so timing starts no process. Each sample still includes the time bash takes to write the file and read the line. The file is in the load test root, so in mixed mode it is always polled. The test takes 20 samples, or stops at 5 once 5 seconds have passed: a polled sample waits for the next poll, so latency there is set by the poll interval and a few samples measure it as well as 20.
- Load: six tests of ten thousand changes each: files created at once (one `xargs touch`) and in sequence (one at a time in a loop), each into a directory the test creates; existing files modified at once (one `xargs touch`) and in sequence (appended to one at a time); and files deleted at once (one `xargs rm`) and in sequence (one at a time in a Perl loop, because starting `rm` once per file takes minutes on Windows). Each test gives the time taken to make the changes, how long after the last change the reports stopped (with the one second throttle, a burst gives one report a second), and how long one more change, made once the reports stopped, took to be reported. That last change shows the watcher kept up and still watches the directories the burst created. A test fails when the burst or the later change goes unreported.

The tree is watched as two roots: the generated files and the directory the load tests change. Every measurement runs in three modes: native, where every directory has a native watch; mixed, where `--max-watches 1` gives the only native watch to the files root, so the load root is polled on every platform, Windows included; and polling, where every directory is polled. With `--max-watches 1` a tree backend (Windows, macOS) watches the files root natively, and a backend that watches each directory runs out on the files root too, so both roots are polled there.

Each run measures the three modes in turn, so a slow spell on the machine affects all of them. Every figure is the average over that mode's runs, which the results list, except the latency's worst case, which is the slowest sample of any run. A load test fails if any run misses a burst or the later change.

The script exits with code 1 when a change goes unreported. It runs on Linux, macOS and Windows (Git Bash) with bash 5 or later. CPU time and memory come from `/proc` on Linux, `ps` on macOS and PowerShell's `Get-Process` on Windows. Linux and Windows report peak memory; macOS reports the memory in use after the load tests, because it keeps no peak for another process.
