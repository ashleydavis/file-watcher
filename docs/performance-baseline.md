# Performance baseline

The baseline measured on 2026-11-01 by `scripts/performance-test.sh` in CI, at commit `daf68ef`. The run is [CI run 45](https://github.com/ashleydavis/file-watcher/actions/runs/41281798960). Compare later runs against these figures.

## Leader board

Platforms ranked from best (1st) to worst (3rd) on each measure, from the tables below. Lower is better for every measure.

| Measure | 1st | 2nd | 3rd |
| --- | --- | --- | --- |
| Speed: native change latency, median | Linux, 0.23 ms | Windows, 2.7 ms | macOS, 12 ms |
| Speed: native startup | Linux, 15 ms | Windows, 26 ms | macOS, 34 ms |
| Speed: next change after a native burst, average | Linux, 2 ms | Windows, 35 ms | macOS, 52 ms |
| Memory: native | Linux, 0.9 MiB | Windows, 3.8 MiB | macOS, 6.1 MiB |
| Memory: polling | Linux, 1.0 MiB | macOS, 1.8 MiB | Windows, 3.9 MiB |
| CPU: idle while polling, over 5 s | Windows, 78 ms | Linux, 280 ms | macOS, 390 ms |

The memory rows mostly rank memory the operating system adds to every process, not memory the watcher keeps; see [Reading the figures](#reading-the-figures).

Two measures are left out because every platform ties on them: native idle CPU is 0 ms everywhere, and polling latency is about one poll interval (931 to 948 ms) everywhere.

Overall, adding up the places above (fewest points is best):

| Place | Platform | Points | Best at | Worst at |
| --- | --- | --- | --- | --- |
| 1st | Linux | 7 | Native speed and memory, polling memory | Nothing |
| 2nd | Windows | 12 | Polling CPU | Polling memory |
| 3rd | macOS | 17 | Nothing | Native speed and memory, polling CPU |

## How it was measured

- The ReleaseFast CLI tool, on GitHub's hosted runners: Ubuntu 24.04, Windows Server 2025 and macOS 15.
- A tree of 20,000 files, watched as two roots: the generated files and the load test directory.
- The script repeats its runs for up to 4 minutes and finishes within 5. Each figure is the average of that mode's runs, except the worst latency, which is the slowest sample of any run.
- Every burst, and every change after it, was reported in every run on every platform.

| Runs per mode | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Native | 2 | 1 | 2 |
| Mixed | 2 | 1 | 2 |
| Polling | 2 | 1 | 1 |
| Script time | 4 m 27 s | 4 m 6 s | 4 m 15 s |

The three modes:

- **Native:** every directory watched natively, up to the platform's quota.
- **Mixed:** `--max-watches 1`. One native watch is allowed, so the load test root is polled.
- **Polling:** every root polled, every second.

Each load test makes 10,000 changes, waits until the reports stop, then times the report of one more change. Reports are throttled to one per root per second, so a burst gives a few reports, not 10,000. "Reports stopped" is how long after the last change the last report came. "Next change" is how long one more change then took to be reported, which shows the watcher kept up.

## Native

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 15 ms | 26 ms | 34 ms |
| Memory | 0.9 MiB | 3.8 MiB | 6.1 MiB |
| Idle CPU over 5 s | 0 ms | 0 ms | 0 ms |
| Single change latency, median | 0.23 ms | 2.7 ms | 12 ms |
| Single change latency, worst | 0.28 ms | 3.2 ms | 18 ms |
| 10,000 created at once: reports stopped / next change | 656 / 2 ms | 150 / 36 ms | 365 / 45 ms |
| 10,000 created in sequence | 576 / 2 ms | 521 / 34 ms | 351 / 44 ms |
| 10,000 modified at once | 931 / 2 ms | 873 / 35 ms | 663 / 31 ms |
| 10,000 modified in sequence | 362 / 2 ms | 409 / 35 ms | 821 / 36 ms |
| 10,000 deleted at once | 771 / 2 ms | 518 / 35 ms | 436 / 83 ms |
| 10,000 deleted in sequence | 818 / 2 ms | 533 / 35 ms | 595 / 74 ms |
| Native watches | 204 | 2 | 2 |

## Mixed

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 40 ms | 32 ms | 8 ms |
| Memory | 0.8 MiB | 3.9 MiB | 5.8 MiB |
| Idle CPU over 5 s | 275 ms | 0 ms | 140 ms |
| Single change latency, median | 949 ms | 933 ms | 828 ms |
| Single change latency, worst | 951 ms | 964 ms | 949 ms |
| 10,000 created at once: reports stopped / next change | 649 / 478 ms | 231 / 306 ms | 140 / 484 ms |
| 10,000 created in sequence | 603 / 488 ms | 314 / 379 ms | 966 / 392 ms |
| 10,000 modified at once | 429 / 475 ms | 379 / 369 ms | 684 / 441 ms |
| 10,000 modified in sequence | 967 / 480 ms | 546 / 365 ms | 604 / 269 ms |
| 10,000 deleted at once | 303 / 483 ms | 0 / 324 ms | 663 / 480 ms |
| 10,000 deleted in sequence | 339 / 474 ms | 295 / 359 ms | 859 / 411 ms |

## Polling

| Measure | Linux | Windows | macOS |
| --- | --- | --- | --- |
| Startup (scan and watch) | 39 ms | 39 ms | 170 ms |
| Memory | 1.0 MiB | 3.9 MiB | 1.8 MiB |
| Idle CPU over 5 s | 280 ms | 78 ms | 390 ms |
| Single change latency, median | 948 ms | 945 ms | 931 ms |
| Single change latency, worst | 949 ms | 973 ms | 956 ms |
| 10,000 created at once: reports stopped / next change | 626 / 473 ms | 225 / 408 ms | 788 / 263 ms |
| 10,000 created in sequence | 113 / 483 ms | 218 / 364 ms | 924 / 456 ms |
| 10,000 modified at once | 441 / 461 ms | 381 / 424 ms | 1,185 / 277 ms |
| 10,000 modified in sequence | 992 / 452 ms | 619 / 342 ms | 1,054 / 325 ms |
| 10,000 deleted at once | 314 / 473 ms | 0 / 286 ms | 992 / 311 ms |
| 10,000 deleted in sequence | 340 / 474 ms | 349 / 429 ms | 868 / 478 ms |

## Reading the figures

- Native watching costs no CPU while idle on any platform, and a change is reported within a millisecond on Linux, 4 ms on Windows and 20 ms on macOS, where FSEvents batches its events.
- After a burst, reports stop within about a second, which is the throttle, and the next change is reported at once natively and within one poll interval when polled. A "reports stopped" of 0 ms means the last report came before the last change was made.
- Polling latency is about one poll interval, a second, on every platform.
- Polling keeps only the time of the last check per root and checks each entry as it is read, so its memory is close to native watching's. On macOS polling fell from 20 MiB in the previous baseline to 1.8 MiB, and on Linux from 2.9 MiB to 1.0 MiB.
- Memory is the peak on Linux and Windows. On macOS it is the memory in use after the load tests, because macOS keeps no peak for another process.
- Most of the memory on Windows and macOS is the operating system's, not the watcher's. What the watcher itself keeps is under 1 MiB, as Linux shows:
  - **Windows:** about 3.8 MiB in every mode, polling included, so watching does not add to it. It is the system libraries every Windows process loads, which Windows counts in each process's memory although they are shared between processes.
  - **macOS:** 1.8 MiB polling, but about 6 MiB in native and mixed modes. The 4 MiB difference is Apple's CoreServices framework, which native watching loads to use FSEvents and polling does not.
  - These causes are inferred from how the figures differ between modes, not from a memory profile.
  - The leader board's memory places therefore mostly rank each platform's own overhead.
- Windows fits one run per mode in the time budget, because making 10,000 changes takes 2 to 5 seconds there, so its figures come from a single run.
