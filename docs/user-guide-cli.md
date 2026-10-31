# User guide: CLI tool

`file-watcher` watches directory trees and prints every file and directory that is created, modified or deleted. It runs on Linux, Windows and macOS, and on Android from `adb shell`.

## Usage

```bash
file-watcher [options] <directory>...
```

Watch the current project:

```bash
file-watcher .
```

Watch two trees, print JSON and stop after a minute:

```bash
file-watcher --format json --duration 60000 src tests
```

The tool runs until Ctrl+C, a termination request (SIGTERM) or the end of the duration. Events are printed as soon as each batch is found. Ctrl+C stops the tool at once: it prints the changes already found, frees its watches and exits with code 130.

## Options

| Option | Meaning |
| --- | --- |
| `-f`, `--format <format>` | Output format: `text`, `json` or `yaml`. Default `text`. |
| `-x`, `--exclude-dir <name>` | Leave out directories with this name, and everything in them. Repeat it for more names. The names add to the default list. |
| `--no-default-excludes` | Watch the directories left out by default. |
| `-e`, `--exclude-ext <ext>` | Leave out files with this extension, written as `.log` or `log`. Repeat it for more extensions. |
| `-q`, `--quota <percent>` | The share of the platform's native watch limit to use, from 0 to 100. Default 50. With 0, every directory is polled. |
| `-m`, `--max-watches <count>` | The most native watches to use, whatever the quota allows. Directories past it are polled. |
| `-i`, `--poll-interval <ms>` | How often polled directories are rescanned, in milliseconds. Default 1000. |
| `--poll` | Poll every directory instead of using native watches. Use it on network file systems, where native events are unreliable. |
| `-d`, `--duration <ms>` | Exit after this many milliseconds. |
| `-s`, `--stats` | Print the watch counters to standard error once the directories are added. |
| `-h`, `--help` | Print the usage. |
| `-V`, `--version` | Print the version. |

`--` ends the options, so a directory whose name starts with `-` can follow it.

## Exclude directories and file types

Leave out more directories, on top of the defaults below, and files by extension:

```bash
file-watcher -x build -x dist -e log -e .tmp src
```

Watch only with your own exclusions, dropping the defaults:

```bash
file-watcher --no-default-excludes -x build src
```

Directory names match exactly and anywhere in the tree, so `-x generated` leaves out every directory named `generated`, with everything inside it.

## Directories left out by default

Directory names match exactly. The defaults are dependency, cache, build output and version control directories that tools rewrite in bulk:

`.git`, `.hg`, `.svn`, `node_modules`, `bower_components`, `.pnpm-store`, `.yarn`, `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `.cache`, `.zig-cache`, `zig-cache`, `zig-out`, `__pycache__`, `.venv`, `venv`, `.tox`, `.mypy_cache`, `.pytest_cache`, `.gradle`, `.idea`, `.terraform`, `Pods` and `DerivedData`.

## Output formats

Each event has a kind (`created`, `modified` or `deleted`), a type (`file` or `directory`) and a path. Paths start with the directory as it was typed on the command line.

A rename is printed as `deleted` for the old path and `created` for the new one. A new directory is printed with everything inside it, and a deleted directory with everything that was inside it.

### text

One line per event: kind, type and path, separated by single spaces. The path is last, so it can contain spaces.

```text
created file src/main.zig
modified file src/main.zig
deleted directory src/old
```

### json

One JSON object per line ([JSON Lines](https://jsonlines.org/)), so a stream can be read line by line.

```json
{"kind":"created","type":"file","path":"src/main.zig"}
```

### yaml

One YAML sequence item per event, so the whole output is one YAML document.

```yaml
- kind: created
  type: file
  path: "src/main.zig"
```

In JSON and YAML, paths are double-quoted strings. Control characters are escaped. Invalid UTF-8 bytes, which Linux allows in file names, are written as U+FFFD.

## Warnings and counters

Warnings go to standard error, so standard output carries only events. Each warning names the path, says what went wrong and what the tool does about it:

```text
warning: src/private: permission denied. It is left out of the watch. Check that it is readable.
warning: src/many/dir123: the native watch quota is used up. It is watched by polling instead.
```

The quota warning appears once. Every directory after it is polled.

`--stats` prints one line of counters to standard error:

```text
stats: directories=1011 native_watches=1011 polled_directories=0 watch_budget=65006 native_limit=130013 native_active=true
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The duration ended, or help or the version was printed. |
| 1 | A directory could not be watched: it is missing, is a file or overlaps another directory on the command line. |
| 2 | The command line is wrong. The message says how to fix it. |
| 130 | Stopped by Ctrl+C or a termination request. |

## The quota

Each platform limits native watches:

- Linux and Android: the per-user inotify limit in `/proc/sys/fs/inotify/max_user_watches`. Each directory takes one watch.
- macOS: the open file limit (`ulimit -n`). Each directory and each file takes one open descriptor.
- Windows: 63 directory trees: one wait covers 64 handles, and one of them is kept for stopping the wait. Each directory on the command line takes one watch for its whole tree.

The tool uses `--quota` percent of the limit and polls every directory beyond it. On Linux the limit is shared by every program of the user, so the default of 50% leaves room for editors and other watchers. To watch more directories natively on Linux, raise the limit:

```bash
sudo sysctl fs.inotify.max_user_watches=524288
```

On macOS, raise the open file limit for the shell that runs the tool:

```bash
ulimit -n 65536
```
