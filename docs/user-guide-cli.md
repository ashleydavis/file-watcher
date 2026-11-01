# User guide: CLI tool

`file-watcher` watches directory trees and prints the name of each watched directory when anything in it changes: a file or directory created, modified, deleted or renamed. It does not say which file changed. It runs on Linux, Windows and macOS.

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

The tool runs until Ctrl+C, a termination request (SIGTERM) or the end of the duration. A change is printed as soon as it is found. Reports of the same directory are throttled to one a second by default: a burst of changes prints one line at once and, if the burst goes on, one more line when the second is up. Ctrl+C stops the tool at once: it prints the changes already found, frees its watches and exits with code 130.

## Options

| Option | Meaning |
| --- | --- |
| `-f`, `--format <format>` | Output format: `text`, `json` or `yaml`. Default `text`. |
| `-x`, `--exclude-dir <name>` | Leave out directories with this name, and everything in them. Repeat it for more names. The names add to the default list. |
| `--no-default-excludes` | Watch the directories left out by default. |
| `-e`, `--exclude-ext <ext>` | Leave out files with this extension, written as `.log` or `log`. Repeat it for more extensions. |
| `-q`, `--quota <percent>` | The share of the platform's native watch limit to use, from 0 to 100. Default 50. With 0, every watched directory is polled. |
| `-m`, `--max-watches <count>` | The most native watches to use, whatever the quota allows. A watched directory that needs more is polled as well. |
| `-i`, `--poll-interval <ms>` | How often polled directories are checked, in milliseconds. Default 1000. |
| `-t`, `--throttle <ms>` | The shortest time between two reports of the same directory, in milliseconds. Changes inside it are reported once when it ends. 0 reports every change at once. Default 1000. |
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

Each line names a watched directory that changed, exactly as it was typed on the command line, without trailing separators. A change in a directory left out, such as `node_modules`, prints nothing.

### text

One line per change: `changed` and the directory, separated by a space. The directory is last, so it can contain spaces.

```text
changed src
```

### json

One JSON object per line ([JSON Lines](https://jsonlines.org/)), so a stream can be read line by line.

```json
{"changed":"src"}
```

### yaml

One YAML sequence item per change, so the whole output is one YAML document.

```yaml
- changed: "src"
```

In JSON and YAML, directories are double-quoted strings. Control characters are escaped. Invalid UTF-8 bytes, which Linux allows in file names, are written as U+FFFD.

## Warnings and counters

Warnings go to standard error, so standard output carries only changes. Each warning names the path, says what went wrong and what the tool does about it:

```text
warning: src/private: permission denied. It is left out of the watch. Check that it is readable.
warning: src/many/dir123: the native watch quota is used up. Its watched directory is polled instead.
```

The quota warning appears once. A watched directory that runs out of native watches keeps the ones it has and is also polled.

`--stats` prints one line of counters to standard error:

```text
stats: roots=1 polled_roots=0 native_watches=1011 watch_budget=65006 native_limit=130013 native_active=true
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

- Linux: the per-user inotify limit in `/proc/sys/fs/inotify/max_user_watches`. Each directory takes one watch.
- macOS: 1024 directory trees. Each directory on the command line takes one FSEvents stream for its whole tree.
- Windows: 63 directory trees: one wait covers 64 handles, and one of them is kept for stopping the wait. Each directory on the command line takes one watch for its whole tree.

The tool uses `--quota` percent of the limit, and polls a watched directory that needs more native watches than are left. On Linux the limit is shared by every program of the user, so the default of 50% leaves room for editors and other watchers. To watch more directories natively on Linux, raise the limit:

```bash
sudo sysctl fs.inotify.max_user_watches=524288
```
