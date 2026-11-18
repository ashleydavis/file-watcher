# How it works

Each path you give the watcher is a watched path: a directory, which covers everything under it, or a single file. The watcher reports which watched path changed, as you gave it. For a directory it reports the directory, and leaves the changed file unnamed. That lets it keep almost nothing per file. Native events name a path, and the watcher only has to find the watched directory the path is in. Polling keeps only the time of each watched tree's last check, and looks for any modification time after it. Reports are throttled per directory, so a burst of changes gives one report a second, not thousands.

## Parts

| File | Job |
| --- | --- |
| `src/root.zig` | The library's public interface. |
| `src/watcher.zig` | Ties the parts together: watched paths, the quota, the throttle, polling, falling back and batches. |
| `src/scan.zig` | Checks a directory tree, or a watched file, for times after the last check, for polling. |
| `src/hints.zig` | The set of paths a native backend reported in one batch. |
| `src/inotify.zig` | The Linux backend. |
| `src/fsevents.zig` | The macOS backend. |
| `src/read_directory_changes.zig` | The Windows backend. |
| `src/windows_listing.zig` | Lists a Windows directory with every entry's metadata in one query, for polling. |
| `src/unsupported.zig` | The backend for other platforms, which always polls. |
| `src/limit.zig` | The platform's native watch limit and the quota arithmetic. |
| `src/filter.zig` | Which directories and files are left out. |
| `src/paths.zig` | Whether a path is inside a watched directory. |
| `src/options.zig` | The watcher settings and their defaults. |
| `src/event.zig` | The changed directories and problems of one batch. |
| `src/main.zig` | The CLI tool. |
| `src/arguments.zig` | The CLI tool's command line. |
| `src/output.zig` | The CLI tool's text, JSON and YAML output. |

## From a native event to a report

A backend reports the paths that changed. For each path, the watcher:

1. Finds the watched path it belongs to: the watched file itself, or the watched directory it is in. A path that belongs to none is ignored.
2. Ignores the path when a directory between the watched directory and it is excluded, such as `node_modules`, or the path's own name is an excluded directory or has an excluded extension.
3. Reports the watched path as changed, unless the throttle holds the report back.

For backends that need one watch per directory, the backend also says when a directory appeared (`directory`), disappeared (`gone`) or when events were dropped (`tree`). The watcher then adds watches for the new directory and everything under it, drops the watches under the removed one, or checks every watch under the path.

## Native backends

| Platform | Method | One watch covers | Limit |
| --- | --- | --- | --- |
| Linux | inotify | One directory and the files in it | `max_user_watches`, per user |
| macOS | FSEvents | A whole tree | 1024 trees per watcher |
| Windows | `ReadDirectoryChangesW` | A whole tree | 63 trees per watcher |

### inotify

Each directory that is not excluded gets one watch. inotify names each entry that is created, deleted, moved, written or changed. A directory created or moved in gets watches for itself and everything under it. One deleted or moved away loses its watches. When the kernel's event queue overflows, every watched tree is reported changed and its watches are checked. Events are read in batches of up to 64 KiB.

### FSEvents

Each watched directory gets one FSEvents stream, which reports every changed file and directory under it by path, with no open descriptor per entry. Streams deliver their events on a dispatch queue thread. That thread queues them and triggers a kqueue user event, and `next` waits on that kqueue, which `wake` triggers too. FSEvents resolves symbolic links in the paths it reports, such as `/private/tmp` for `/tmp`, so each path is rewritten to start with the watched directory as it was given. When FSEvents drops events, or more than 4 MiB of paths queue up between batches, every watched path is reported changed.

CoreServices, which provides FSEvents, is loaded when the watcher starts rather than linked. That way macOS builds need no Apple SDK and cross compile from any machine. If it cannot be loaded, the watcher reports a problem and polls.

### ReadDirectoryChangesW

Each watched directory gets one directory handle and one asynchronous read covering its whole tree, with a 64 KiB buffer. Windows reports the relative path of each change. When the buffer overflows, the directory is reported changed. One `WaitForMultipleObjects` call waits on every watched directory at once, plus the event `wake` sets. One call covers 64 handles, which limits a watcher to 63 watched directories.

## Watched files

A watched path can be a single file. `add` reads whether the path is a file or a directory, following symbolic links.

On Linux a watched file gets one inotify watch on the file itself. inotify reports writes, metadata changes and the file being deleted or moved, each under the file's own path. A watch follows the file it was made on, so after a file is renamed away, deleted or replaced by a rename, as editors do when they save, the watch no longer covers the path. After every report the watcher therefore drops the file's watch and watches whatever file is at the path now. When no file is there, the path is polled, so the file is found when it is made again.

On macOS and Windows a watched file is polled. One watch there covers a whole tree, so watching the file's directory would cover far more than the file.

Polling a file reads its metadata alone and reports the file when its modification time or status change time falls in the window. The status change time counts because a file renamed over the path keeps its own modification time.

A watched file is watched whatever its name and extension, because it was named on purpose. `add` refuses a file inside a watched directory, or a file already watched, as it refuses overlapping directories.

## The quota

At start the watcher reads the platform limit:

- Linux: `/proc/sys/fs/inotify/max_user_watches`. When it cannot be read, the kernel default of 8192 is used.
- macOS: 1024 streams, one per watched directory.
- Windows: 63.

The budget is `quota_percent` of the limit, rounded down, and `native_watches_max` caps it further. When a watched directory needs more watches than the budget has left, it keeps the watches it got and is polled as well, so changes in the directories that missed out are still found. When the platform refuses a watch for lack of resources before the budget is used up, the budget drops to the number in use. The first time either happens, a `LimitReached` problem is reported.

## Polling

A polled path keeps one thing: the time of its last check. Every `poll_interval_ms` the watcher walks the directory tree and reports the directory changed when any entry that is not excluded, or the directory itself, has a modification time after the last check. Creating, writing or renaming a file gives it a new time, and creating, deleting or renaming an entry gives the directory it is in a new time, so every kind of change shows up. The walk stops at the first new time it finds. The watched path being deleted or made again is a change too, so each one also keeps whether it existed at the last check.

Entries in excluded directories, such as `node_modules`, are never read. Writing an excluded file, such as a `.log` file, does not count. Creating or deleting an excluded entry still changes the time of the directory holding it, so polling reports that, where native watching does not.

File systems take modification times from a clock that ticks every few milliseconds, so a file written just after a check began can carry a time just before it. Each check therefore covers times up to 100 ms before it began, and leaves later ones to the next check, so no change falls between two checks. A file system whose times come from another machine's clock, such as a network share, can miss changes when that clock is behind this one by more than that. A file with a time in the future is reported once, when its time comes.

Entries are checked as they are read, one at a time, and nothing is collected. Memory grows only with the number of directories waiting to be walked, not with the number of files.

On Windows, reading one entry's metadata opens a handle to it, which made polling a large tree cost most of a CPU core. The Windows backend therefore gives the walk a lister instead: one `NtQueryDirectoryFile` call returns the write time and attributes of every entry in a directory, up to 64 KiB of records at a time. A directory the lister cannot read is listed the generic way.

When native watching fails to start, or fails while waiting for events, the watcher reports a problem with an empty path and polls every watched path.

## The throttle

`throttle_ms`, one second by default, is the shortest time between two reports of the same watched path. The first change after a quiet spell is reported at once. Changes within the throttle time after a report are held back, and the path is reported once when the time ends. Nothing is lost: a held-back change is always reported. A throttle of 0 reports every batch at once.

## Batches

`next` runs one loop until a watched path changed, a problem was found or the timeout ends:

1. Report watched paths whose held-back change has waited out the throttle.
2. Check polled paths when the poll interval has passed.
3. Wait for native events until the next poll, the next held-back report or the timeout, whichever is first. With no native watches, sleep instead.
4. Turn every path the backend reported into a changed watched path, and keep watches in step.

The batch lives in an arena that is reset at the start of the next batch.

## Waking a waiting watcher

`wake` lets another thread, or a signal handler, end a `next` that is waiting. Each backend waits on one extra signal beside its watches: an eventfd on Linux, a kqueue user event on macOS and an event handle on Windows. Polled waits sleep on a futex holding a wake count. `wake` raises the count, signals the backend and wakes the futex, and `next` returns as soon as it sees the count move. A wake made while no `next` is waiting is kept, so the next call returns at once.

The CLI tool calls `wake` from its Ctrl+C and SIGTERM handlers, so it waits for changes with no timeout and still stops at once.

## Memory

Nothing is kept per file. Native watching keeps the path of each watch the backend holds: one per directory on Linux, and one per watched directory on macOS and Windows. Polling keeps the time of the last check per watched path. On a tree of 100,000 files in 1,001 directories, the CLI tool's peak memory was 1.3 MiB both watching natively and polling (measured on 2026-11-01 with a ReleaseFast build on Linux x86_64).

## Tests

- Unit tests run the real code against an in-memory file system and clock, behind the standard `std.Io` interface, and a scripted backend that can report any hint or fail on demand. Each native backend is also tested against a real directory on its own platform.
- `scripts/coverage.sh run` measures line coverage with kcov and fails below 100%. Coverage counts the code compiled into the test binaries on the machine running it.
- `scripts/smoke-test.sh` drives the built CLI tool against real directories.
- `scripts/performance-test.sh` measures startup, memory, idle CPU, latency and load in three modes: native, mixed (native watches run out, so watched directories are polled) and polling. Each load test makes ten thousand changes (created, modified and deleted, each at once and in sequence), waits for the reports to stop, then checks that one more change is reported.
