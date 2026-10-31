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
- `next(self: *Watcher, timeout_ms: u32) !Batch`: waits up to `timeout_ms` for changes. Returns as soon as there is at least one event or problem, or an empty batch when the time runs out. The batch stays valid until the next call to `next` or `add`.
- `stats(self: *const Watcher) Stats`: counters that show how the watcher spends its quota.

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

## Threads

A watcher is used from one thread at a time. Run it on its own thread and pass batches to the rest of the program, or call `next` with a short timeout from an existing loop.
