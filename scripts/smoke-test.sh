#!/usr/bin/env bash
#
# Runs the built CLI tool against real directories and checks every feature: help, version,
# usage errors, the three output formats, that every kind of change reports its watched
# directory, exclusions, polling, the quota, counters, several roots and the duration.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-file-watcher>"
    echo
    echo "Runs smoke tests against the given file-watcher binary, for example:"
    echo "  $0 zig-out/bin/file-watcher"
    exit 2
fi

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -x "$binary" ]; then
    echo "error: $1 is not an executable file. Build it with 'zig build' first."
    exit 2
fi

# Runs the tool with the given arguments.
run_tool() {
    "$binary" "$@"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# On Windows (Git Bash) the tool prints Windows paths joined with backslashes, so the work
# directory is passed in Windows form and the output's backslashes are turned into slashes.
is_windows=0
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        is_windows=1
        work="$(cygpath -m "$work")"
        ;;
esac

# Windows and macOS watch a whole tree with one watch per root; the other platforms use one
# watch per directory.
is_tree_backend=0
if [ "$is_windows" -eq 1 ]; then
    is_tree_backend=1
elif [ "$(uname -s)" = "Darwin" ]; then
    is_tree_backend=1
fi

passed=0
failed=0
# The longest wait for a case's changes to be reported. Watchers in change cases run with this
# duration too, as a backstop, and are stopped as soon as their changes are reported.
event_timeout_seconds=60
# How long a change that must not be reported is given to show up anyway.
quiet_seconds=1.5
event_duration_ms=$((event_timeout_seconds * 1000 + 5000))

# Records a check's result.
check() {
    local name="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "ok   $name"
    else
        failed=$((failed + 1))
        echo "FAIL $name"
        # Prints the files the check read, so a failure in CI can be diagnosed from its log.
        local argument
        for argument in "$@"; do
            if [ -f "$argument" ]; then
                echo "     $argument:"
                head -n 20 "$argument" | sed 's/^/       /'
            fi
        done
    fi
}

# Whether the file holds the exact line.
has_line() {
    grep -qxF -- "$2" "$1"
}

# Whether the file lacks any line containing the text.
lacks_text() {
    ! grep -qF -- "$2" "$1"
}

# Replaces the current shell with the tool. Used for background runs, so the background
# process ID is the tool's own and signals reach it.
exec_tool() {
    exec "$binary" "$@"
}

# Waits until the watcher writing standard error to the given file is watching: with -s it
# prints its counters once every directory is added. Starting can take seconds on a slow
# machine, so a fixed sleep would let changes land before the first scan. The whole counters
# line is waited for, up to its last field, so a watcher is never stopped while it is still
# writing it.
wait_ready() {
    local err="$1"
    local attempt
    for attempt in $(seq 1 600); do
        if grep -qE "^stats: .*native_active=(true|false)" "$err" 2> /dev/null; then
            return 0
        fi
        if ! kill -0 "$watcher_pid" 2> /dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "error: The watcher did not start within 60 seconds."
    exit 1
}

# Starts the watcher in the background with the given arguments, writing standard output to
# out.txt and standard error to err.txt in the case directory, and waits until it is watching.
start_watcher() {
    local case_dir="$1"
    shift
    exec_tool -s "$@" >> "$case_dir/out.txt" 2>> "$case_dir/err.txt" &
    watcher_pid=$!
    watcher_case_dir="$case_dir"
    wait_ready "$case_dir/err.txt"
}

# Whether the file holds no lines other than the counters printed by -s.
has_no_warnings() {
    ! grep -v "^stats:" "$1" | grep -q .
}

# Turns the backslashes of Windows paths in a file into slashes. JSON escapes each backslash
# as two, which become one slash.
slash_paths() {
    sed -e 's#\\\\#/#g' -e 's#\\#/#g' "$1" > "$1.slashed"
    mv "$1.slashed" "$1"
}

# Waits for the watcher started last to exit.
wait_watcher() {
    wait "$watcher_pid"
    if [ "$is_windows" -eq 1 ]; then
        slash_paths "$watcher_case_dir/out.txt"
        slash_paths "$watcher_case_dir/err.txt"
    fi
}

# Prints the file, with Windows backslashes turned into slashes on Windows, as slash_paths does.
slashed() {
    if [ "$is_windows" -eq 1 ]; then
        sed -e 's#\\\\#/#g' -e 's#\\#/#g' "$1"
    else
        cat "$1"
    fi
}

# Waits until the output file holds every given line, up to $event_timeout_seconds. Changes are
# printed as soon as they are found, so the wait ends as soon as the last one is reported. A
# fixed duration instead fails when the machine is slow.
wait_lines() {
    local out="$1"
    shift
    local deadline=$((SECONDS + event_timeout_seconds))
    local line
    while [ "$SECONDS" -lt "$deadline" ]; do
        local missing=0
        for line in "$@"; do
            if ! slashed "$out" | grep -qxF -- "$line"; then
                missing=1
                break
            fi
        done
        if [ "$missing" -eq 0 ]; then
            return 0
        fi
        sleep 0.1
    done
    echo "     waited ${event_timeout_seconds} s for: $line"
}

# Prints how many lines of the output say `root` changed.
count_changes() {
    local out="$1" root="$2"
    slashed "$out" | { grep -cxF -- "changed $root" || true; }
}

# Waits until the output has gone quiet for half a second, up to $event_timeout_seconds, so
# reports of an earlier change are all in before the next one is made.
settle() {
    local out="$1"
    local deadline=$((SECONDS + event_timeout_seconds))
    local previous
    previous=$(wc -l < "$out")
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 0.5
        local current
        current=$(wc -l < "$out")
        if [ "$current" -eq "$previous" ]; then
            return 0
        fi
        previous=$current
    done
}

# Runs the command after the output and root, then succeeds once a new line says `root` changed,
# up to $event_timeout_seconds.
changes() {
    local out="$1" root="$2"
    shift 2
    settle "$out"
    local before
    before=$(count_changes "$out" "$root")
    "$@"
    local deadline=$((SECONDS + event_timeout_seconds))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(count_changes "$out" "$root")" -gt "$before" ]; then
            return 0
        fi
        sleep 0.05
    done
    echo "     waited ${event_timeout_seconds} s for: changed $root"
    return 1
}

# Waits until the output holds `count` lines saying `root` changed, up to $event_timeout_seconds.
wait_lines_count() {
    local out="$1" root="$2" count="$3"
    local deadline=$((SECONDS + event_timeout_seconds))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(count_changes "$out" "$root")" -ge "$count" ]; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

# Runs the command after the output and root, then succeeds when nothing is reported within
# $quiet_seconds, which is several poll intervals and far longer than a native report takes.
no_changes() {
    local out="$1" root="$2"
    shift 2
    settle "$out"
    local before
    before=$(count_changes "$out" "$root")
    "$@"
    sleep "$quiet_seconds"
    [ "$(count_changes "$out" "$root")" -eq "$before" ]
}

# Stops the watcher started last and waits for it to exit.
stop_watcher() {
    kill -TERM "$watcher_pid" 2> /dev/null || true
    wait "$watcher_pid" 2> /dev/null || true
    if [ "$is_windows" -eq 1 ]; then
        slash_paths "$watcher_case_dir/out.txt"
        slash_paths "$watcher_case_dir/err.txt"
    fi
}

# Creates a fresh directory for one case and prints its path.
new_case() {
    local case_dir="$work/$1"
    mkdir -p "$case_dir/tree"
    echo "$case_dir"
}

echo "Smoke testing $binary"

# Help, version and usage errors.
run_tool --help > "$work/help.txt"
check "help prints usage" grep -q "^Usage: file-watcher" "$work/help.txt"
run_tool --version > "$work/version.txt"
check "version prints the version" grep -qE "^file-watcher [0-9]+\.[0-9]+\.[0-9]+$" "$work/version.txt"
set +e
run_tool > /dev/null 2> "$work/usage.txt"
usage_code=$?
run_tool --format xml "$work" > /dev/null 2> "$work/format.txt"
format_code=$?
run_tool "$work/missing" > /dev/null 2> "$work/missing.txt"
missing_code=$?
run_tool "$work" "$work/help.txt" > /dev/null 2> "$work/file.txt"
file_code=$?
set -e
check "no directory exits with code 2" test "$usage_code" -eq 2
check "no directory explains itself" grep -q "No directory to watch" "$work/usage.txt"
check "bad format exits with code 2" test "$format_code" -eq 2
check "bad format explains itself" grep -q "Unknown format xml" "$work/format.txt"
check "missing directory exits with code 1" test "$missing_code" -eq 1
check "missing directory explains itself" grep -q "it does not exist" "$work/missing.txt"
check "a file as root exits with code 1" test "$file_code" -eq 1

# Every kind of change is reported as its watched directory changing, with native watching. Each
# change is made on its own and waited for, and the output is left to go quiet before the next
# one, so a late report of one change cannot pass for the next.
case_dir="$(new_case text)"
tree="$case_dir/tree"
out="$case_dir/out.txt"
echo "old" > "$tree/modified.txt"
echo "old" > "$tree/deleted.txt"
echo "old" > "$tree/renamed.txt"
mkdir -p "$tree/gone/inner" "$tree/node_modules/pkg"
echo "x" > "$tree/gone/inner/file.txt"
start_watcher "$case_dir" -d "$event_duration_ms" "$tree"
check "text: created file" changes "$out" "$tree" eval 'echo new > "$tree/created.txt"'
check "text: modified file" changes "$out" "$tree" eval 'echo changed >> "$tree/modified.txt"'
check "text: deleted file" changes "$out" "$tree" eval 'rm "$tree/deleted.txt"'
check "text: renamed file" changes "$out" "$tree" eval 'mv "$tree/renamed.txt" "$tree/renamed-to.txt"'
check "text: created directory" changes "$out" "$tree" eval 'mkdir "$tree/new-dir"'
check "text: file in a new directory" changes "$out" "$tree" eval 'echo x > "$tree/new-dir/file.txt"'
check "text: created nested directories" changes "$out" "$tree" eval 'mkdir -p "$tree/new-dir/a/b"'
check "text: file in a nested new directory" changes "$out" "$tree" eval 'echo x > "$tree/new-dir/a/b/file.txt"'
check "text: file in an existing subdirectory" changes "$out" "$tree" eval 'echo y >> "$tree/gone/inner/file.txt"'
check "text: deleted directory" changes "$out" "$tree" eval 'rm -r "$tree/gone"'
check "text: node_modules left out by default" no_changes "$out" "$tree" eval 'echo x > "$tree/node_modules/pkg/index.js"'
stop_watcher
check "text: every line names the watched directory" lacks_text "$out" "$tree/"
check "text: no warnings" has_no_warnings "$case_dir/err.txt"

# The throttle: a second change soon after the first is held back and reported once the
# throttle time has passed, not at once. The throttle is long, so a slow machine cannot make
# the held-back report look immediate.
case_dir="$(new_case throttle)"
tree="$case_dir/tree"
start_watcher "$case_dir" -t 10000 -d "$event_duration_ms" "$tree"
check "throttle: first change reported at once" changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/one.txt"'
SECONDS=0
check "throttle: second change held back" no_changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/two.txt"'
check "throttle: held change reported when the throttle time ends" wait_lines_count "$case_dir/out.txt" "$tree" 2
check "throttle: held change reported no sooner than the throttle time" test "$SECONDS" -ge 5
stop_watcher

# JSON output.
case_dir="$(new_case json)"
tree="$case_dir/tree"
start_watcher "$case_dir" -f json -d "$event_duration_ms" "$tree"
echo "x" > "$tree/a.txt"
wait_lines "$case_dir/out.txt" "{\"changed\":\"$tree\"}"
stop_watcher
out="$case_dir/out.txt"
check "json: changed line" has_line "$out" "{\"changed\":\"$tree\"}"
if command -v python3 > /dev/null; then
    check "json: every line parses" python3 -c '
import json, sys
lines = open(sys.argv[1]).read().splitlines()
assert lines
for line in lines:
    json.loads(line)
' "$out"
fi

# YAML output.
case_dir="$(new_case yaml)"
tree="$case_dir/tree"
start_watcher "$case_dir" -f yaml -d "$event_duration_ms" "$tree"
echo "x" > "$tree/a.txt"
wait_lines "$case_dir/out.txt" "- changed: \"$tree\""
stop_watcher
out="$case_dir/out.txt"
check "yaml: changed line" has_line "$out" "- changed: \"$tree\""
if command -v python3 > /dev/null && python3 -c "import yaml" 2> /dev/null; then
    check "yaml: output parses" python3 -c '
import sys, yaml
items = yaml.safe_load(open(sys.argv[1]))
assert "changed" in items[0]
' "$out"
fi

# Default, custom and disabled exclusions.
case_dir="$(new_case exclude)"
tree="$case_dir/tree"
out="$case_dir/out.txt"
mkdir -p "$tree/node_modules/pkg" "$tree/build" "$tree/.git"
start_watcher "$case_dir" -x build -e log -e .tmp -d "$event_duration_ms" "$tree"
check "exclude: node_modules left out by default" no_changes "$out" "$tree" eval 'echo x > "$tree/node_modules/pkg/index.js"; mkdir "$tree/node_modules/new"'
check "exclude: .git left out by default" no_changes "$out" "$tree" eval 'echo x > "$tree/.git/HEAD"'
check "exclude: custom directory left out" no_changes "$out" "$tree" eval 'echo x > "$tree/build/out.o"'
check "exclude: extension given without a dot left out" no_changes "$out" "$tree" eval 'echo x > "$tree/server.log"'
check "exclude: extension given with a dot left out" no_changes "$out" "$tree" eval 'echo x > "$tree/scratch.tmp"'
check "exclude: kept file reported" changes "$out" "$tree" eval 'echo x > "$tree/kept.txt"'
stop_watcher

case_dir="$(new_case no-default-excludes)"
tree="$case_dir/tree"
mkdir -p "$tree/node_modules"
start_watcher "$case_dir" --no-default-excludes -d "$event_duration_ms" "$tree"
check "exclude: --no-default-excludes watches node_modules" changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/node_modules/index.js"'
stop_watcher

# Polling, the quota and the counters.
case_dir="$(new_case poll)"
tree="$case_dir/tree"
mkdir -p "$tree/sub"
start_watcher "$case_dir" --poll -i 100 -d "$event_duration_ms" "$tree"
check "poll: change found by polling" changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/sub/polled.txt"'
check "poll: excluded change left out" no_changes "$case_dir/out.txt" "$tree" eval 'mkdir -p "$tree/node_modules"; echo x > "$tree/node_modules/a.js"'
stop_watcher
check "poll: counters show polling only" grep -q "roots=1 polled_roots=1 native_watches=0 .* native_active=false" "$case_dir/err.txt"

case_dir="$(new_case quota)"
tree="$case_dir/tree"
start_watcher "$case_dir" -q 0 -i 100 -d "$event_duration_ms" "$tree"
check "quota: zero quota still finds changes" changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/quota.txt"'
stop_watcher
check "quota: zero quota uses no native watches" grep -q "native_watches=0 watch_budget=0" "$case_dir/err.txt"

# A tree that needs more native watches than allowed is polled, keeps the watches it got, and
# the quota being used up is reported.
case_dir="$(new_case overflow)"
tree="$case_dir/tree"
if [ "$is_tree_backend" -eq 1 ]; then
    echo "skip overflow: one watch covers a whole tree on this platform, so a tree never overflows the quota"
else
    mkdir -p "$tree/dir1" "$tree/dir2" "$tree/dir3"
    start_watcher "$case_dir" -m 2 -i 100 -d "$event_duration_ms" "$tree"
    check "overflow: change in a directory without a native watch found" changes "$case_dir/out.txt" "$tree" eval 'echo x > "$tree/dir3/late.txt"; echo x > "$tree/dir2/late.txt"; echo x > "$tree/dir1/late.txt"'
    stop_watcher
    check "overflow: native watches stop at the cap" grep -q "roots=1 polled_roots=1 native_watches=2 watch_budget=2" "$case_dir/err.txt"
    check "overflow: quota reported" grep -q "the native watch quota is used up. Its watched directory is polled instead." "$case_dir/err.txt"
fi

case_dir="$(new_case native-stats)"
tree="$case_dir/tree"
mkdir -p "$tree/a" "$tree/b"
start_watcher "$case_dir" -d 600 "$tree"
wait_watcher
# A tree backend watches the root alone; the other platforms use one watch per directory.
expected_watches=3
if [ "$is_tree_backend" -eq 1 ]; then
    expected_watches=1
fi
check "stats: native watches" grep -q "roots=1 polled_roots=0 native_watches=$expected_watches " "$case_dir/err.txt"

# Several roots, each reported by its own path, and overlapping roots.
case_dir="$(new_case roots)"
mkdir -p "$case_dir/second"
start_watcher "$case_dir" -d "$event_duration_ms" "$case_dir/tree" "$case_dir/second/"
check "roots: first root reported" changes "$case_dir/out.txt" "$case_dir/tree" eval 'echo x > "$case_dir/tree/one.txt"'
check "roots: second root reported, trailing separator removed" changes "$case_dir/out.txt" "$case_dir/second" eval 'echo x > "$case_dir/second/two.txt"'
stop_watcher
set +e
run_tool -d 100 "$case_dir" "$case_dir/tree" > /dev/null 2> "$case_dir/overlap.txt"
overlap_code=$?
set -e
check "roots: overlapping roots refused" test "$overlap_code" -eq 1
check "roots: overlap explained" grep -q "overlaps another watched directory" "$case_dir/overlap.txt"

# Ctrl+C stops the tool at once with exit code 130. Git Bash cannot send Ctrl+C to a Windows
# program, so the case is skipped there.
if [ "$is_windows" -eq 0 ]; then
    case_dir="$(new_case interrupt)"
    tree="$case_dir/tree"
    start_watcher "$case_dir" -i 60000 "$tree"
    echo "x" > "$tree/before-interrupt.txt"
    sleep 0.3
    SECONDS=0
    kill -INT "$watcher_pid"
    set +e
    wait "$watcher_pid"
    interrupt_code=$?
    set -e
    check "interrupt: Ctrl+C exits with code 130" test "$interrupt_code" -eq 130
    check "interrupt: Ctrl+C stops at once" test "$SECONDS" -lt 2
    check "interrupt: changes before Ctrl+C are printed" has_line "$case_dir/out.txt" "changed $tree"
else
    echo "skip interrupt: Ctrl+C cannot be sent to the tool on this platform from this script"
fi

# The duration ends the run on time.
# Starting the tool can take seconds on a slow machine, so that time is measured first and
# allowed for.
mkdir -p "$work/empty"
SECONDS=0
run_tool --version > /dev/null
start_seconds=$SECONDS
SECONDS=0
run_tool -d 300 "$work/empty" > /dev/null
check "duration: exits after the duration" test "$SECONDS" -lt $((start_seconds + 3))

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
