# How it works

The watcher reports which watched directory changed, not which files changed. That lets it keep almost nothing per file. Native events name a path, and the watcher only has to find the watched directory the path is in. Polling sums each watched tree into one 64-bit fingerprint and compares that number, with no per-file record. Reports are throttled per directory, so a burst of changes gives one report a second, not thousands.

## Parts

| File | Job |
| --- | --- |
| `src/root.zig` | The library's public interface. |
| `src/watcher.zig` | Ties the parts together: roots, the quota, the throttle, polling, falling back and batches. |
| `src/fingerprint.zig` | Sums a directory tree into one number for polling. |
| `src/hints.zig` | The set of paths a native backend reported in one batch. |
| `src/inotify.zig` | The Linux and Android backend. |
| `src/fsevents.zig` | The macOS backend. |
| `src/kqueue.zig` | The iOS backend. |
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

1. Finds the watched directory (the root) the path is in. A path in none of them is ignored.
2. Ignores the path when a directory between the root and it is excluded, such as `node_modules`, or the path's own name is an excluded directory or has an excluded extension.
3. Reports the root as changed, unless the throttle holds the report back.

For backends that need one watch per directory, the backend also says when a directory appeared (`directory`), disappeared (`gone`) or when events were dropped (`tree`). The watcher then adds watches for the new directory and everything under it, drops the watches under the removed one, or checks every watch under the path.

## Native backends

| Platform | Method | One watch covers | Limit |
| --- | --- | --- | --- |
| Linux, Android | inotify | One directory and the files in it | `max_user_watches`, per user |
| macOS | FSEvents | A whole tree | 1024 trees per watcher |
| iOS | kqueue | One directory or one file | The open file limit |
| Windows | `ReadDirectoryChangesW` | A whole tree | 63 trees per watcher |

### inotify

Each directory that is not excluded gets one watch. inotify names each entry that is created, deleted, moved, written or changed. A directory created or moved in gets watches for itself and everything under it. One deleted or moved away loses its watches. When the kernel's event queue overflows, every watched tree is reported changed and its watches are checked. Events are read in batches of up to 64 KiB.

### FSEvents

Each root gets one FSEvents stream, which reports every changed file and directory under it by path, with no open descriptor per entry. Streams deliver their events on a dispatch queue thread. That thread queues them and triggers a kqueue user event, and `next` waits on that kqueue, which `wake` triggers too. FSEvents resolves symbolic links in the paths it reports, such as `/private/tmp` for `/tmp`, so each path is rewritten to start with the root as it was added. When FSEvents drops events, or more than 4 MiB of paths queue up between batches, every root is reported changed.

CoreServices, which provides FSEvents, is loaded when the watcher starts rather than linked. That way macOS builds need no Apple SDK and cross compile from any machine. If it cannot be loaded, the watcher reports a problem and polls.

### kqueue

kqueue watches open descriptors. A directory's descriptor reports that its entries changed, and the watcher then watches any new entries. A file's descriptor reports writes to that file. Files need their own descriptors, so on iOS the quota covers files as well as directories. FSEvents is unavailable to iOS apps, so iOS uses kqueue.

### ReadDirectoryChangesW

Each root gets one directory handle and one asynchronous read covering its whole tree, with a 64 KiB buffer. Windows reports the relative path of each change. When the buffer overflows, the root is reported changed. One `WaitForMultipleObjects` call waits on every root at once, plus the event `wake` sets. One call covers 64 handles, which limits a watcher to 63 roots.

## The quota

At start the watcher reads the platform limit:

- Linux and Android: `/proc/sys/fs/inotify/max_user_watches`. When it cannot be read, as in Android apps, the kernel default of 8192 is used.
- macOS: 1024 streams, one per root.
- iOS: the limit on open files. The watcher first raises the soft limit to the hard limit, capped at `OPEN_MAX` (10240), as the Go runtime does, so the quota counts every descriptor the app may open.
- Windows: 63.

The budget is `quota_percent` of the limit, rounded down, and `native_watches_max` caps it further. When a root needs more watches than the budget has left, it keeps the watches it got and is polled as well, so changes in the directories that missed out are still found. When the platform refuses a watch for lack of resources before the budget is used up, the budget drops to the number in use. The first time either happens, a `LimitReached` problem is reported.

## Polling

A polled root is checked every `poll_interval_ms` by walking its tree and summing a hash of every entry that is not excluded. A file's hash covers its path, size, modification time and file number. A directory's covers its path alone, because a directory's own time changes when excluded entries inside it change. The sum changes when any entry that counts is created, deleted, renamed or changed, and the watcher keeps only that one number per root. The file number catches an editor that saves by writing a new file and renaming it over the old one, even when size and time match.

The walk lists one directory at a time and frees each listing once it is summed. Its memory therefore grows with the number of directories waiting to be walked, not with the number of files.

On Windows, reading one entry's metadata opens a handle to it, which made polling a large tree cost most of a CPU core. The Windows backend therefore gives the walk a lister instead: one `NtQueryDirectoryFile` call returns the size, write time, attributes and file ID of every entry in a directory. A directory the lister cannot read is listed the generic way.

When native watching fails to start, or fails while waiting for events, the watcher reports a problem with an empty path and polls every root.

## The throttle

`throttle_ms`, one second by default, is the shortest time between two reports of the same root. The first change after a quiet spell is reported at once. Changes within the throttle time after a report are held back, and the root is reported once when the time ends. Nothing is lost: a held-back change is always reported. A throttle of 0 reports every batch at once.

## Batches

`next` runs one loop until a root changed, a problem was found or the timeout ends:

1. Report roots whose held-back change has waited out the throttle.
2. Check polled roots when the poll interval has passed.
3. Wait for native events until the next poll, the next held-back report or the timeout, whichever is first. With no native watches, sleep instead.
4. Turn every path the backend reported into a changed root, and keep watches in step.

The batch lives in an arena that is reset at the start of the next batch.

## Waking a waiting watcher

`wake` lets another thread, or a signal handler, end a `next` that is waiting. Each backend waits on one extra signal beside its watches: an eventfd on Linux and Android, a kqueue user event on macOS and iOS, and an event handle on Windows. Polled waits sleep on a futex holding a wake count. `wake` raises the count, signals the backend and wakes the futex, and `next` returns as soon as it sees the count move. A wake made while no `next` is waiting is kept, so the next call returns at once.

The CLI tool calls `wake` from its Ctrl+C and SIGTERM handlers, so it waits for changes with no timeout and still stops at once.

## Memory

Nothing is kept per file. Native watching keeps the path of each watch the backend holds. On Linux that is one per directory, on macOS and Windows one per root, and on iOS one per directory and file. Polling keeps one number per root. On a tree of 100,000 files in 1,011 directories, the CLI tool's peak memory was 1.1 MiB watching natively and 1.0 MiB polling (measured on 2026-11-01 with a ReleaseFast build on Linux x86_64).

## Tests

- Unit tests run the real code against an in-memory file system and clock, behind the standard `std.Io` interface, and a scripted backend that can report any hint or fail on demand. Each native backend is also tested against a real directory on its own platform.
- `scripts/coverage.sh run` measures line coverage with kcov and fails below 100%. Coverage counts the code compiled into the test binaries on the machine running it.
- `scripts/smoke-test.sh` drives the built CLI tool against real directories.
- `scripts/performance-test.sh` measures startup, memory, idle CPU, latency and load in three modes: native, mixed (native watches run out, so roots are polled) and polling. Each load test makes ten thousand changes (created, modified and deleted, each at once and in sequence), waits for the reports to stop, then checks that one more change is reported.
