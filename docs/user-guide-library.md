# User guide: code library

The `file_watcher` module watches directory trees from Zig code. It works on Linux, Windows and macOS, and the CLI tool is built on it. Other platforms are polled.

## Add the library to a project

Fetch it from Git by version tag or commit SHA. Zig records the URL and a hash in your `build.zig.zon`, so every build uses the same code.

```bash
zig fetch --save git+https://github.com/ashleydavis/file-watcher#<version-tag>
```

```bash
zig fetch --save git+https://github.com/ashleydavis/file-watcher#<commit-sha>
```

Import the module in your `build.zig`:

```zig
const file_watcher = b.dependency("file_watcher", .{
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "file_watcher",
                .module = file_watcher.module("file_watcher"),
            },
        },
    }),
});
```

The library needs Zig 0.16.0. On macOS the module links the C library and loads CoreServices for FSEvents when a watcher starts, so building needs no Apple SDK.

## Watch a directory

```zig
const std = @import("std");
const file_watcher = @import("file_watcher");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // The watcher is large and keeps a pointer into itself, so it lives on the heap.
    const watcher = try gpa.create(file_watcher.Watcher);
    defer gpa.destroy(watcher);

    try watcher.init(gpa, init.io, &.{
        .excluded_extensions = &.{".log"},
        .quota_percent = 50,
        .poll_interval_ms = 1000,
        .throttle_ms = 1000,
    });
    defer watcher.deinit();

    try watcher.add("src");

    while (true) {
        // Blocks this thread until a change arrives or a second passes. While it waits, the
        // thread sleeps in the operating system and uses no CPU.
        const batch = try watcher.next(1000);
        for (batch.problems) |problem| {
            std.log.warn("{s}: {t} ({t})", .{ problem.path, problem.reason, problem.action });
        }
        for (batch.changed) |path| {
            std.log.info("{s} changed", .{path});
        }
    }
}
```

## Exclude directories and file types

`excluded_directories` leaves out every directory with one of the given names, together with everything inside it. Names match exactly and anywhere in the tree: `"generated"` leaves out `src/generated` and `tests/generated` alike. `excluded_extensions` leaves out files by the text after their last dot.

Setting `excluded_directories` replaces the default list. To keep the defaults (`node_modules`, `.git` and the other heavy tool directories) and add your own, join the two lists:

```zig
const excluded = file_watcher.default_excluded_directories ++ [_][]const u8{ "build", "dist" };

try watcher.init(gpa, init.io, &.{
    .excluded_directories = &excluded,
    .excluded_extensions = &.{ ".log", ".tmp" },
});
```

To use only your own list, pass it on its own:

```zig
try watcher.init(gpa, init.io, &.{
    .excluded_directories = &.{ "build", "dist", "generated" },
});
```

The lists are borrowed, so they must outlive the watcher. A `const` declared in the same scope as the watcher, or at the top level, does.

## API

### `Watcher`

The watcher for the platform being built for.

- `init(self: *Watcher, gpa: Allocator, io: std.Io, options: *const Options) !void`: creates a watcher in place. The watcher keeps a pointer into itself, so it stays at the address given to `init`. Problems found here, such as the native method being unavailable, come back in the first batch.
- `deinit(self: *Watcher) void`: stops every watch and frees every record.
- `add(self: *Watcher, path: []const u8) !void`: starts watching the tree at `path`. Changes before this call are not reported. Fails with `error.FileNotFound` when the path is missing, `error.NotDir` when it is a file and `error.OverlappingRoot` when it is inside, or contains, a path added before. Trailing separators are removed.
- `next(self: *Watcher, timeout_ms: u32) !Batch`: blocks the calling thread until a change arrives or `timeout_ms` passes, then returns the batch: at least one changed directory or problem, or an empty batch when the time runs out. With native watching it waits in the operating system (`poll`, `kevent` or `WaitForMultipleObjects`), so a waiting thread uses no CPU and wakes as soon as a change arrives. A timeout of 0 never blocks: it returns the changes already queued. The batch stays valid until the next call to `next` or `add`.
- `wake(self: *Watcher) void`: makes a `next` that is waiting on another thread return at once with the changes found so far, or, when no `next` is waiting, makes the next call to `next` return at once. Safe to call from any thread and from a signal handler. Use it to stop a watcher thread without waiting for its timeout, for example when an app quits.
- `stats(self: *const Watcher) Stats`: counters that show how the watcher spends its quota.

The watcher keeps nothing per file. It does not say which file changed, only which watched directory did, and it reports the same directory at most once per `throttle_ms`.

The timeout only limits how long `next` waits when nothing changes. A change is reported as soon as it arrives, whatever the timeout, so a long timeout costs nothing in speed. Choose it by how often your loop needs to do something other than wait: an idle loop wakes once per timeout and gets an empty batch. To stop a waiting thread, call `wake` from another thread instead of relying on the timeout. Use 0 from a timer or event loop that must never block. The largest timeout, `std.math.maxInt(u32)`, is about 49.7 days. In polling mode `next` also wakes for each poll interval, whatever the timeout.

`next` and `add` return errors only for failures the watcher cannot work around, such as running out of memory. After such an error, call `deinit`. Paths that cannot be read or watched natively are problems in the batch instead, and the watcher carries on.

### `Options`

| Field | Default | Meaning |
| --- | --- | --- |
| `excluded_directories` | `default_excluded_directories` | Directory names to leave out, matched exactly against each directory's own name. Everything inside is left out too. |
| `excluded_extensions` | empty | File extensions to leave out, including the dot (`".log"`), matched against the text after the last dot of each file name. |
| `quota_percent` | `50` | The share of the platform's native watch limit to use, from 0 to 100. With 0, every watched directory is polled. |
| `native_watches_max` | `null` | The most native watches to use, whatever the quota allows. A watched directory that needs more is polled as well. `null` means the quota alone sets the limit. |
| `poll_interval_ms` | `1000` | How often polled directories are checked. Must be above 0. |
| `throttle_ms` | `1000` | The shortest time between two reports of the same watched directory. The first change after a quiet spell is reported at once; changes within this time after a report are reported once when it ends, so none is lost. 0 reports every change at once. |
| `method` | `.native` | `.native` uses native watches up to the quota. `.polling` polls every watched directory, which suits network file systems whose clock agrees with this machine's to within 100 ms. |

The slices in `Options` are borrowed, so keep them alive while the watcher runs. `is_valid(&options)` says whether every setting is in range; the watcher asserts it.

`default_excluded_directories` holds `.git`, `node_modules` and other dependency, cache, build output and version control directories. To add names to it, build a list that contains both.

### `Batch`

- `changed: []const []const u8`: the watched directories that changed, each once, exactly as they were passed to `add` without trailing separators. Any file or directory under a watched directory being created, modified, deleted or renamed counts, unless it is excluded.
- `problems: []const Problem`: paths that could not be read or watched natively.

### `Problem`

- `path: []const u8`: the path concerned, or empty when the problem concerns the whole watcher, such as the native backend failing.
- `reason: anyerror`: why, for example `error.AccessDenied` or `error.LimitReached`.
- `action: ProblemAction`: `.skipped` when the path is left out, `.polled` when its watched directory is polled instead.

`error.LimitReached` is reported once, the first time the quota or the platform limit is reached.

### `Stats`

- `native_limit`: the platform's native watch limit.
- `watch_budget`: the share of the limit this watcher may use.
- `native_watches`: native watches in use.
- `roots`: watched directories.
- `polled_roots`: watched directories that are polled, because native watching is off or could not cover all of them.
- `is_native_active`: whether the native backend is running.

## Blocking, threads and GUI apps

`next` blocks the thread that calls it, so a GUI app keeps it off the UI thread, or calls it with a timeout of 0. A watcher is used from one thread at a time.

### A watcher thread

Run the watcher on its own thread and hand the changes to the UI thread. Copy each path out of the batch, because the batch is reused by the next call to `next`. Use your GUI toolkit's way of running code on the UI thread, or a locked list the UI thread empties on a timer, as here:

```zig
const std = @import("std");
const file_watcher = @import("file_watcher");

// Watched directories that changed, found by the watcher thread, waiting for the UI thread.
const Inbox = struct {
    mutex: std.Io.Mutex = .init,
    paths: std.ArrayList([]u8) = .empty,
};

// Runs on its own thread until `stop` is set and the watcher is woken.
fn watch(
    gpa: std.mem.Allocator,
    io: std.Io,
    watcher: *file_watcher.Watcher,
    inbox: *Inbox,
    stop: *std.atomic.Value(bool),
) void {
    while (!stop.load(.acquire)) {
        // Blocks until a change arrives or another thread calls `wake`.
        const batch = watcher.next(std.math.maxInt(u32)) catch |err| {
            std.log.err("The file watcher stopped: {t}.", .{err});
            return;
        };
        inbox.mutex.lockUncancelable(io);
        defer inbox.mutex.unlock(io);
        for (batch.changed) |changed| {
            // Copy each path, because the batch is reused by the next call to `next`.
            const path = gpa.dupe(u8, changed) catch |err| {
                std.log.err("The file watcher stopped: {t}.", .{err});
                return;
            };
            inbox.paths.append(gpa, path) catch |err| {
                gpa.free(path);
                std.log.err("The file watcher stopped: {t}.", .{err});
                return;
            };
        }
    }
}

// Called by the UI thread, for example from a timer: takes every path waiting in the inbox.
// The caller frees the paths and the list.
fn take_changes(io: std.Io, inbox: *Inbox) std.ArrayList([]u8) {
    inbox.mutex.lockUncancelable(io);
    defer inbox.mutex.unlock(io);
    const paths = inbox.paths;
    inbox.paths = .empty;
    return paths;
}
```

Start the thread after adding the directories. To stop it, for example when the user quits, set `stop`, then call `wake` so the thread's waiting `next` returns at once, then join the thread before `deinit`:

```zig
var inbox: Inbox = .{};
var stop: std.atomic.Value(bool) = .init(false);
const thread = try std.Thread.spawn(.{}, watch, .{ gpa, io, watcher, &inbox, &stop });

// ... the app runs ...

stop.store(true, .release);
watcher.wake();
thread.join();
```

The app quits without waiting for a timeout, so the thread can wait with the largest timeout and wakes only for changes and for `wake`.

### A UI timer

If the app already has a timer or an idle callback on the UI thread, call `next(0)` from it. A zero timeout returns at once with the changes already queued, so the UI never blocks:

```zig
// On each timer tick, on the UI thread.
const batch = try watcher.next(0);
for (batch.changed) |path| {
    // Update the UI.
}
```

Changes then reach the UI on the next tick, so a 50 to 100 ms timer shows them without a visible delay.

Both patterns were compiled and run against the library with real file changes.
