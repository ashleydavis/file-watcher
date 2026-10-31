# User guide: code library

The `file_watcher` module watches directory trees from Zig code. It works on Linux, Windows, macOS, Android and iOS, and the CLI tool is built on it.

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

The library needs Zig 0.16.0. On Apple platforms the module links the C library, which provides kqueue.

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
        for (batch.events) |event| {
            std.log.info("{t} {s}", .{ event.kind, event.path });
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
- `add(self: *Watcher, path: []const u8) !void`: starts watching the tree at `path`. The current contents are recorded without events. Fails with `error.FileNotFound` when the path is missing, `error.NotDir` when it is a file and `error.OverlappingRoot` when it is inside, or contains, a path added before. Trailing separators are removed.
- `next(self: *Watcher, timeout_ms: u32) !Batch`: blocks the calling thread until a change arrives or `timeout_ms` passes, then returns the batch: at least one event or problem, or an empty batch when the time runs out. With native watching it waits in the operating system (`poll`, `kevent` or `WaitForMultipleObjects`), so a waiting thread uses no CPU and wakes as soon as a change arrives. A timeout of 0 never blocks: it returns the changes already queued. The batch stays valid until the next call to `next` or `add`.
- `stats(self: *const Watcher) Stats`: counters that show how the watcher spends its quota.

The timeout only limits how long `next` waits when nothing changes. A change is reported as soon as it arrives, whatever the timeout, so a long timeout costs nothing in speed. Choose it by how often your loop needs to do something other than wait, such as checking a flag to stop: an idle loop wakes once per timeout and gets an empty batch. Use 0 from a timer or event loop that must never block. The largest timeout, `std.math.maxInt(u32)`, is about 49.7 days. In polling mode `next` also wakes for each poll interval, whatever the timeout.

`next` and `add` return errors only for failures the watcher cannot work around, such as running out of memory. After such an error, call `deinit`. Paths that cannot be read or watched natively are problems in the batch instead, and the watcher carries on.

### `Options`

| Field | Default | Meaning |
| --- | --- | --- |
| `excluded_directories` | `default_excluded_directories` | Directory names to leave out, matched exactly against each directory's own name. Everything inside is left out too. |
| `excluded_extensions` | empty | File extensions to leave out, including the dot (`".log"`), matched against the text after the last dot of each file name. |
| `quota_percent` | `50` | The share of the platform's native watch limit to use, from 0 to 100. With 0, every directory is polled. |
| `poll_interval_ms` | `1000` | How often polled directories are rescanned. Must be above 0. |
| `method` | `.native` | `.native` uses native watches up to the quota. `.polling` polls every directory, which suits network file systems. |

The slices in `Options` are borrowed, so keep them alive while the watcher runs. `is_valid(&options)` says whether every setting is in range; the watcher asserts it.

`default_excluded_directories` holds `.git`, `node_modules` and other dependency, cache, build output and version control directories. To add names to it, build a list that contains both.

### `Batch`

- `events: []const Event`: what changed, in the order it was found.
- `problems: []const Problem`: paths that could not be read or watched natively.

### `Event`

- `kind: EventKind`: `.created`, `.modified` or `.deleted`.
- `path: []const u8`: the full path, built from the root path given to `add`.
- `is_directory: bool`: whether the path is a directory.

A rename is reported as `.deleted` for the old path and `.created` for the new one. A new directory is reported with everything inside it, and a deleted directory with everything that was inside it. Directories get `.created` and `.deleted` events; changes to a directory's own metadata are left out.

### `Problem`

- `path: []const u8`: the path concerned, or empty when the problem concerns the whole watcher, such as the native backend failing.
- `reason: anyerror`: why, for example `error.AccessDenied` or `error.LimitReached`.
- `action: ProblemAction`: `.skipped` when the path is left out, `.polled` when it is watched by polling instead.

`error.LimitReached` is reported once, the first time the quota or the platform limit is reached.

### `Stats`

- `native_limit`: the platform's native watch limit.
- `watch_budget`: the share of the limit this watcher may use.
- `native_watches`: native watches in use.
- `polled_directories`: directories watched by polling.
- `directories`: directories watched in total.
- `is_native_active`: whether the native backend is running.

## Android and iOS

On Android the library uses inotify, like Linux. Android refuses apps access to `/proc/sys`, so the library assumes the kernel's default limit of 8192 watches there.

On iOS the library uses kqueue, like macOS, with the open file limit as the watch limit, because each watched file and directory holds an open descriptor.

Build your app's Zig code for the device target, for example `-Dtarget=aarch64-linux-android` or `-Dtarget=aarch64-ios`, and import the module as shown above. Pass the app's own directories to `add`, because apps can only read inside their sandbox.

## Blocking, threads and GUI apps

`next` blocks the thread that calls it, so a GUI app keeps it off the UI thread, or calls it with a timeout of 0. A watcher is used from one thread at a time.

### A watcher thread

Run the watcher on its own thread and hand the changes to the UI thread. Copy each path out of the batch, because the batch is reused by the next call to `next`. Use your GUI toolkit's way of running code on the UI thread, or a locked list the UI thread empties on a timer, as here:

```zig
const std = @import("std");
const file_watcher = @import("file_watcher");

// Changed paths found by the watcher thread, waiting for the UI thread to take them.
const Inbox = struct {
    mutex: std.Io.Mutex = .init,
    paths: std.ArrayList([]u8) = .empty,
};

// Runs on its own thread until `stop` is set.
fn watch(
    gpa: std.mem.Allocator,
    io: std.Io,
    watcher: *file_watcher.Watcher,
    inbox: *Inbox,
    stop: *std.atomic.Value(bool),
) void {
    while (!stop.load(.acquire)) {
        // Blocks until a change arrives or 250 ms pass, so `stop` is seen within 250 ms.
        const batch = watcher.next(250) catch |err| {
            std.log.err("The file watcher stopped: {t}.", .{err});
            return;
        };
        inbox.mutex.lockUncancelable(io);
        defer inbox.mutex.unlock(io);
        for (batch.events) |event| {
            // Copy each path, because the batch is reused by the next call to `next`.
            const path = gpa.dupe(u8, event.path) catch |err| {
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

Start the thread after adding the directories, and stop it before `deinit`:

```zig
var inbox: Inbox = .{};
var stop: std.atomic.Value(bool) = .init(false);
const thread = try std.Thread.spawn(.{}, watch, .{ gpa, io, watcher, &inbox, &stop });

// ... the app runs ...

stop.store(true, .release);
thread.join();
```

The timeout passed to `next` sets how quickly the thread sees `stop`. It costs nothing while the tree is quiet beyond one wake-up per timeout.

### A UI timer

If the app already has a timer or an idle callback on the UI thread, call `next(0)` from it. A zero timeout returns at once with the changes already queued, so the UI never blocks:

```zig
// On each timer tick, on the UI thread.
const batch = try watcher.next(0);
for (batch.events) |event| {
    // Update the UI.
}
```

Changes then reach the UI on the next tick, so a 50 to 100 ms timer shows them without a visible delay.

Both patterns were compiled and run against the library with real file changes.
