# Performance baseline

The baseline measured on 2026-10-31 by `scripts/performance-test.sh` in CI, at commit `b5500d1`. The run is [CI run 26](https://github.com/ashleydavis/file-watcher/actions/runs/41247466747). Compare later runs against these figures.

## How it was measured

- The ReleaseFast CLI tool, on GitHub's hosted runners: Ubuntu 24.04 for Linux and Android, Windows Server 2025, and macOS 15 for macOS and the iOS simulator.
- A tree of 20,000 files in 205 directories, watched as two roots: the generated files and the load test directory.
- Every test ran 5 times. Each figure is the average of the 5 runs, except the worst latency, which is the slowest sample of any run.
- Every change was reported in every run on every platform.

The three modes:

- **Native:** every directory watched natively, up to the platform's quota.
- **Mixed:** `--max-watches 1`. The files root takes the only native watch and the load test root is polled.
- **Polling:** every directory polled, every second.

Load times run from the first change until the last change is reported, so they include the time taken to make the changes. The tables give the time to have all 10,000 reported. The job logs also give the time taken to make them.

## Native

| Measure | Linux | Android | Windows | macOS | iOS simulator |
| --- | --- | --- | --- | --- | --- |
| Startup (scan and watch) | 41 ms | 35 ms | 484 ms | 131 ms | 2,395 ms |
| Memory | 6 MiB | 6 MiB | 9 MiB | 17 MiB | 26 MiB |
| Idle CPU over 5 s | 0 ms | 0 ms | 0 ms | 338 ms | 504 ms |
| Single change latency, median | 0.21 ms | 0.25 ms | 4.9 ms | 874 ms | 818 ms |
| Single change latency, worst | 0.60 ms | 0.48 ms | 10.8 ms | 967 ms | 1,061 ms |
| 10,000 created at once | 303 ms | 213 ms | 6,213 ms | 1,325 ms | 2,736 ms |
| 10,000 created in sequence | 322 ms | 270 ms | 7,152 ms | 1,641 ms | 2,088 ms |
| 10,000 modified at once | 79 ms | 60 ms | 3,666 ms | 959 ms | 2,272 ms |
| 10,000 modified in sequence | 405 ms | 389 ms | 5,404 ms | 2,505 ms | 5,088 ms |
| 10,000 deleted at once | 200 ms | 152 ms | 2,770 ms | 1,322 ms | 3,161 ms |
| 10,000 deleted in sequence | 182 ms | 121 ms | 2,165 ms | 1,637 ms | 2,517 ms |
| Native watches / polled directories | 204 / 0 | 204 / 0 | 2 / 0 | 5,120 / 154 | 128 / 203 |

## Mixed

| Measure | Linux | Android | Windows | macOS | iOS simulator |
| --- | --- | --- | --- | --- | --- |
| Startup (scan and watch) | 38 ms | 33 ms | 524 ms | 48 ms | 2,988 ms |
| Memory | 10 MiB | 10 MiB | 12 MiB | 16 MiB | 26 MiB |
| Idle CPU over 5 s | 254 ms | 208 ms | 996 ms | 404 ms | 522 ms |
| Single change latency, median | 950 ms | 950 ms | 4.9 ms | 888 ms | 827 ms |
| Single change latency, worst | 971 ms | 957 ms | 6.1 ms | 980 ms | 1,427 ms |
| 10,000 created at once | 804 ms | 768 ms | 4,673 ms | 1,633 ms | 3,371 ms |
| 10,000 created in sequence | 809 ms | 828 ms | 6,524 ms | 1,612 ms | 2,430 ms |
| 10,000 modified at once | 999 ms | 1,004 ms | 5,010 ms | 1,030 ms | 2,012 ms |
| 10,000 modified in sequence | 988 ms | 998 ms | 7,050 ms | 2,421 ms | 4,221 ms |
| 10,000 deleted at once | 977 ms | 969 ms | 3,654 ms | 1,668 ms | 1,935 ms |
| 10,000 deleted in sequence | 989 ms | 996 ms | 2,931 ms | 1,449 ms | 2,051 ms |

## Polling

| Measure | Linux | Android | Windows | macOS | iOS simulator |
| --- | --- | --- | --- | --- | --- |
| Startup (scan and watch) | 41 ms | 29 ms | 517 ms | 53 ms | 2,628 ms |
| Memory | 10 MiB | 10 MiB | 12 MiB | 15 MiB | 25 MiB |
| Idle CPU over 5 s | 250 ms | 190 ms | 3,987 ms | 394 ms | 556 ms |
| Single change latency, median | 948 ms | 948 ms | 934 ms | 874 ms | 840 ms |
| Single change latency, worst | 972 ms | 957 ms | 1,051 ms | 967 ms | 1,206 ms |
| 10,000 created at once | 803 ms | 767 ms | 5,195 ms | 1,279 ms | 1,828 ms |
| 10,000 created in sequence | 793 ms | 821 ms | 6,138 ms | 1,740 ms | 2,045 ms |
| 10,000 modified at once | 1,000 ms | 986 ms | 5,074 ms | 878 ms | 1,740 ms |
| 10,000 modified in sequence | 1,006 ms | 992 ms | 7,512 ms | 2,355 ms | 4,129 ms |
| 10,000 deleted at once | 961 ms | 992 ms | 4,099 ms | 1,574 ms | 2,648 ms |
| 10,000 deleted in sequence | 993 ms | 997 ms | 3,070 ms | 1,187 ms | 2,166 ms |

## Reading the figures

- Linux and Android watch every directory natively. A change is reported in under a millisecond, and 10,000 changes are all reported about 10 ms after the last one is made.
- On Windows most of each load time is the runner making the changes: creating 10,000 files takes about 6 seconds there. In native mode the watcher reported the last change 80 to 160 ms after it was made.
- Windows mixed mode keeps the files root native, because one Windows watch covers a whole tree, so its latency matches native mode. On the other platforms the native watch covers only the files root's top directory, and the file edited for latency is polled.
- macOS and iOS use kqueue, which needs one open file per watched file and directory. The quota is half the open file limit: 5,120 on macOS and 128 in the iOS simulator. That is not enough for the 20,000 files, so most of the tree is polled even in native mode, and latency is about one poll interval.
- Polling costs CPU while idle. On Windows, polling 204 directories every second used about 4 seconds of CPU in 5 seconds, far more than on the other platforms.

## Known gaps

- **Windows polling CPU:** 4 seconds of CPU per 5 seconds while idle is too high. The polling path lists every directory and reads every entry's metadata each second, and these calls are likely much slower on Windows. This needs profiling.
- **macOS and iOS native coverage:** kqueue runs out of descriptors on trees of more than a few thousand files. FSEvents on macOS would watch a whole tree with one stream.
