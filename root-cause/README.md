# Root cause: Windows unit tests failure in run 44242621077

## The failure

- Run: https://github.com/ashleydavis/file-watcher/actions/runs/44242621077 (commit `3660009`, runner `windows-2025`).
- Job: Windows unit tests. Every other job in the run passed, including the Windows smoke tests that watch a file.
- Failing test: `native watcher sees a real file change`, at its first check (`src/watcher.test.zig:616`), after the first write made after `add`:

```
26/74 watcher.test.test.native watcher sees a real file change...FAIL (TestExpectedEqual)
D:\a\file-watcher\file-watcher\src\watcher.test.zig:670:5: 0x7ff72413fef3 in expect_change (library-tests_zcu.obj)
D:\a\file-watcher\file-watcher\src\watcher.test.zig:616:5: 0x7ff7241405ac in test.native watcher sees a real file change (library-tests_zcu.obj)
```

The test was added in that commit, so the run is its first on Windows. The failure is intermittent: 6 of 10 runs failed in experiment 1.

## Root cause

On Windows a watched file is polled. `add` opens the file's first polling window at the exact current time (`poll_root` in `src/watcher.zig`, `checked_ns = start_ns`), and only a file time after that counts as a change. Windows stamps a write with a time that lags that exact clock by up to about a millisecond. The test writes the file a fraction of a millisecond after `add` returns, so the write is often stamped at or before the window start, or with the very same stamp as the write made before `add`. No window ever contains that time, so the change is never reported.

## How it was proven

Both experiments run only this test, ten times each, on `windows-2025`, with each `scan_file` call printing its window and the file's times. The rule set before the runs: 10 passes in a row is good, any failure is bad.

| Side | Change | Result |
| --- | --- | --- |
| Cause present (experiment 1) | None beyond the printing | 6 of 10 failed. In every failing run the write after `add` was stamped before the window start (+187 and -69 microseconds against a start of about +200), or kept the stamp from before `add`. In every passing run it was stamped after the start (+290 to +509). |
| Cause taken away (experiment 2) | The test sleeps 50 ms after `add` before the first write, so the write's stamp lands after the window start | 10 of 10 passed. Every write after `add` was stamped after the window start. |

Run 10 of experiment 1 shows the lag directly: the write was made after `add` returned (about +320 microseconds after "before add"), yet Windows stamped it -69 microseconds, before `add` was even called. Run 7 of experiment 2 shows it again: the write was made more than 50 ms after `add`, and stamped +49613 microseconds.

## Files

- `original-failure-run-44242621077.log`: the failed job's log from the original run.
- `experiment-1-run-44245117710.log`: experiment 1 (https://github.com/ashleydavis/file-watcher/actions/runs/44245117710), ten runs with the window and file times printed. 4 passed, 6 failed.
- `experiment-2-run-44245669971.log`: experiment 2 (https://github.com/ashleydavis/file-watcher/actions/runs/44245669971), the same with a 50 ms sleep after `add`. 10 passed.
- `.github/workflows/experiment.yml`, `build.zig` (test filter), `src/scan.zig` and `src/watcher.test.zig` (printing and the sleep) on this branch: the experiments, so they can be run again. The commit log, oldest first, records each experiment and its result.
