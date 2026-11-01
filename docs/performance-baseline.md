# Performance baseline

The baseline measured on 2026-11-01 by `scripts/performance-test.sh` in CI, at commit `9a42788`. The run is [CI run 42](https://github.com/ashleydavis/file-watcher/actions/runs/41275104772). Compare later runs against these figures.

## How it was measured

- The ReleaseFast CLI tool, on GitHub's hosted runners: Ubuntu 24.04, Windows Server 2025 and macOS 15.
- A tree of 20,000 files, watched as two roots: the generated files and the load test directory.
- Every test ran 5 times. Each figure is the average of the 5 runs, except the worst latency, which is the slowest sample of any run.
- Every burst, and every change after it, was reported in every run on every platform.

The three modes:

- **Native:** every directory watched natively, up to the platform's quota.
- **Mixed:** `--max-watches 1`. One native watch is allowed, so the load test root is polled.
- **Polling:** every root polled, every second.

Each load test makes 10,000 changes, waits until the reports stop, then times the report of one more change. Reports are throttled to one per root per second, so a burst gives a few reports, not 10,000. "Reports stopped" is how long after the last change the last report came. "Next change" is how long one more change then took to be reported, which shows the watcher kept up.

## Native

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 10 ms | 34 ms | 17 ms |
| Memory | 0.9 MiB | 3.8 MiB | 6.3 MiB |
| Idle CPU over 5 s | 0 ms | 0 ms | 0 ms |
| Single change latency, median | 0.11 ms | 2.1 ms | 15 ms |
| Single change latency, worst | 0.27 ms | 2.6 ms | 20 ms |
| 10,000 created at once: reports stopped / next change | 853 / 1 ms | 610 / 25 ms | 441 / 82 ms |
| 10,000 created in sequence | 768 / 1 ms | 403 / 24 ms | 534 / 58 ms |
| 10,000 modified at once | 961 / 1 ms | 284 / 24 ms | 695 / 82 ms |
| 10,000 modified in sequence | 717 / 1 ms | 255 / 25 ms | 526 / 54 ms |
| 10,000 deleted at once | 895 / 1 ms | 466 / 24 ms | 472 / 83 ms |
| 10,000 deleted in sequence | 900 / 1 ms | 626 / 23 ms | 528 / 104 ms |
| Native watches | 204 | 2 | 2 |

## Mixed

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 27 ms | 24 ms | 17 ms |
| Memory | 2.8 MiB | 5.9 MiB | 24.6 MiB |
| Idle CPU over 5 s | 130 ms | 40 ms | 170 ms |
| Single change latency, median | 950 ms | 941 ms | 885 ms |
| Single change latency, worst | 956 ms | 990 ms | 986 ms |
| 10,000 created at once: reports stopped / next change | 824 / 485 ms | 533 / 360 ms | 258 / 444 ms |
| 10,000 created in sequence | 319 / 482 ms | 519 / 528 ms | 939 / 383 ms |
| 10,000 modified at once | 455 / 487 ms | 596 / 400 ms | 501 / 455 ms |
| 10,000 modified in sequence | 247 / 482 ms | 669 / 418 ms | 785 / 412 ms |
| 10,000 deleted at once | 398 / 483 ms | 349 / 416 ms | 904 / 420 ms |
| 10,000 deleted in sequence | 398 / 486 ms | 166 / 446 ms | 953 / 386 ms |

## Polling

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 18 ms | 35 ms | 94 ms |
| Memory | 2.9 MiB | 5.8 MiB | 20.2 MiB |
| Idle CPU over 5 s | 124 ms | 78 ms | 372 ms |
| Single change latency, median | 948 ms | 941 ms | 871 ms |
| Single change latency, worst | 950 ms | 985 ms | 969 ms |
| 10,000 created at once: reports stopped / next change | 824 / 471 ms | 507 / 332 ms | 293 / 429 ms |
| 10,000 created in sequence | 338 / 480 ms | 362 / 396 ms | 819 / 380 ms |
| 10,000 modified at once | 461 / 484 ms | 593 / 415 ms | 514 / 376 ms |
| 10,000 modified in sequence | 242 / 484 ms | 704 / 394 ms | 498 / 478 ms |
| 10,000 deleted at once | 384 / 481 ms | 687 / 436 ms | 763 / 378 ms |
| 10,000 deleted in sequence | 399 / 474 ms | 245 / 411 ms | 965 / 364 ms |

## Reading the figures

- Native watching costs no CPU while idle on any platform, and a change is reported within a millisecond on Linux, 3 ms on Windows and 20 ms on macOS, where FSEvents batches its events.
- After a burst, reports stop within about a second, which is the throttle, and the next change is reported at once natively and within one poll interval when polled.
- Polling latency is about one poll interval, a second, on every platform.
- Polling on Windows used 78 ms of CPU in 5 seconds, down from about 4 seconds in the earlier design, which opened a handle per entry.
- Memory is the process's peak. It is higher on macOS in mixed and polling modes, 20 to 25 MiB against 6 MiB native; the cause is not yet known.
