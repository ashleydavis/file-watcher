# How it works

The watcher keeps a record of every watched directory in memory and compares it with the file system. The native watch method of each platform says where to look, and polling covers every directory beyond the reach of the native method. Every change is found by the same comparison, so all platforms and both methods report changes the same way.

## Parts

| File | Job |
| --- | --- |
| `src/root.zig` | The library's public interface. |
| `src/watcher.zig` | Ties the parts together: roots, the quota, polling, falling back and batches. |
| `src/snapshot.zig` | The in-memory record of each directory's entries, and the comparison that produces events. |
| `src/hints.zig` | The set of paths a native backend says may have changed in one batch. |
| `src/inotify.zig` | The Linux and Android backend. |
| `src/kqueue.zig` | The macOS and iOS backend. |
| `src/read_directory_changes.zig` | The Windows backend. |
| `src/unsupported.zig` | The backend for other platforms, which always polls. |
| `src/limit.zig` | The platform's native watch limit and the quota arithmetic. |
| `src/filter.zig` | Which directories and files are left out. |
| `src/options.zig` | The watcher settings and their defaults. |
| `src/event.zig` | Events, problems and the list that collects them for one batch. |
| `src/main.zig` | The CLI tool. |
| `src/arguments.zig` | The CLI tool's command line. |
| `src/output.zig` | The CLI tool's text, JSON and YAML output. |

## The snapshot

For each watched directory the snapshot keeps a map from entry name to a stamp: kind, size, modification time and inode number. The snapshot records only entries that pass the exclusion rules, so the watcher reads and watches only the entries the caller wants.

The snapshot answers three kinds of question:

- Check one path: read its metadata and compare it with the stamp in its parent's map. A new name is `created`, a missing one is `deleted`, and a file whose size, time or inode changed is `modified`. The inode catches editors that save by writing a new file and renaming it over the old one.
- Rescan one directory: list it, check every entry and report every name in the record that is missing from the listing.
- Rescan a tree: rescan every recorded directory under a path.

A new directory is listed straight away and its contents reported as created, so files written into it before its watch started are reported too. A deleted directory is removed from the record together with everything under it, and each entry is reported as deleted.

When a directory cannot be read, the snapshot reports a problem and keeps the directory's old record.

## Native backends

A backend only says which paths may have changed. The watcher collects those paths for one batch, merging repeats, then asks the snapshot to check each one. A burst of raw events for one file costs one check.

| Platform | Method | One watch covers | Limit |
| --- | --- | --- | --- |
| Linux, Android | inotify | One directory and the files in it | `max_user_watches`, per user |
| macOS, iOS | kqueue | One directory or one file | The open file limit |
| Windows | `ReadDirectoryChangesW` | A whole tree | 63 trees per watcher |

### inotify

Each directory gets one watch. inotify reports the name of each entry that is created, deleted, moved, written or changed, and the watcher checks that path. When the kernel's event queue overflows, every watched directory is rescanned. Events are read in batches of up to 64 KiB.

### kqueue

kqueue watches open descriptors. A directory's descriptor reports that its entries changed, without names, so the watcher rescans that directory. A file's descriptor reports writes to that file. Files need their own descriptors, so on macOS and iOS the quota covers files as well as directories.

kqueue is used rather than FSEvents. kqueue is part of the C library on macOS and iOS, so the library cross compiles from any machine. FSEvents needs Apple's SDK frameworks to link and is unavailable to iOS apps.

### ReadDirectoryChangesW

Each root gets one directory handle and one asynchronous read covering its whole tree, with a 64 KiB buffer. Windows reports the relative path of each change, and the watcher checks that path. When the buffer overflows, the whole tree is rescanned. One `WaitForMultipleObjects` call waits on every root at once, plus the event `wake` sets. One call covers 64 handles, which limits a watcher to 63 roots.

## The quota

At start the watcher reads the platform limit:

- Linux and Android: `/proc/sys/fs/inotify/max_user_watches`. When it cannot be read, as in Android apps, the kernel default of 8192 is used.
- macOS and iOS: the soft limit on open files.
- Windows: 63.

The budget is `quota_percent` of the limit, rounded down. Each native watch takes one from the budget, and each removed watch gives one back. When the budget is used up, the next directory is polled instead, and a file's directory is polled when the file cannot get its own watch. On Windows, where one watch covers a whole tree, a root that cannot get its watch has every directory under it polled, including directories created later. When the platform refuses a watch for lack of resources before the budget is used up, the budget drops to the number in use. The first time either happens, a `LimitReached` problem is reported.

## Polling

Polled directories are rescanned every `poll_interval_ms`. A rescan lists the directory and reads the metadata of each entry, so its cost grows with the number of entries. New directories found by polling get a native watch when the budget allows.

When native watching fails to start, or fails while waiting for events, the watcher reports a problem with an empty path, stops the backend and polls every directory.

## Batches

`next` runs one loop until it has events or problems, or the timeout ends:

1. Rescan polled directories when the poll interval has passed.
2. Wait for native events until the next poll or the timeout, whichever is first. With no native watches, sleep instead.
3. Check every path the backend reported and record the events.

New directories in the events get watches and deleted ones lose them, before the batch is returned. Event paths live in an arena that is reset at the start of the next batch, so a steady stream of batches stops allocating once the arena fits a typical batch.

## Waking a waiting watcher

`wake` lets another thread, or a signal handler, end a `next` that is waiting. Each backend waits on one extra signal beside its watches: an eventfd on Linux and Android, a kqueue user event on macOS and iOS, and an event handle on Windows. Polled waits sleep on a futex holding a wake count. `wake` raises the count, signals the backend and wakes the futex, and `next` returns as soon as it sees the count move. A wake made while no `next` is waiting is kept, so the next call returns at once.

The CLI tool calls `wake` from its Ctrl+C and SIGTERM handlers, so it waits for changes with no timeout and still stops at once.

## Memory

Each recorded entry costs its stamp, its name and its slot in its directory's hash map. On a tree of 100000 files in 1011 directories, peak memory was 12 MiB, about 127 bytes per entry (measured 2026-10-31 with a ReleaseFast build on Linux x86_64).

## Tests

- Unit tests run the real code against an in-memory file system and clock, behind the standard `std.Io` interface, and a scripted backend that can report any hint or fail on demand. The inotify backend is also tested against the kernel in a temporary directory.
- `scripts/coverage.sh run` measures line coverage with kcov and fails below 100%. Coverage counts the code compiled into the test binaries on the machine running it.
- `scripts/smoke-test.sh` drives the built CLI tool against real directories.
- `scripts/performance-test.sh` measures startup, memory, idle CPU, latency and load: ten thousand files created, modified and deleted, each at once and in sequence, in three modes: native, mixed (some directories native, the rest polled) and polling.
