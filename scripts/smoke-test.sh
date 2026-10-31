#!/usr/bin/env bash
#
# Runs the built CLI tool against real directories and checks every feature: help, version,
# usage errors, the three output formats, created, modified, deleted and renamed entries,
# exclusions, polling, the quota, counters, several roots and the duration.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-file-watcher> [launcher...]"
    echo
    echo "Runs smoke tests against the given file-watcher binary, for example:"
    echo "  $0 zig-out/bin/file-watcher"
    echo
    echo "A launcher, when given, is a command that runs the binary, such as"
    echo "'xcrun simctl spawn booted' for a binary built for the iOS simulator."
    exit 2
fi

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -x "$binary" ]; then
    echo "error: $1 is not an executable file. Build it with 'zig build' first."
    exit 2
fi
shift
# The count is kept apart from the array because bash 3.2 rejects an empty array under set -u.
launcher_count=$#
launcher=("$@")

# Runs the tool with the given arguments, through the launcher when there is one.
run_tool() {
    if [ "$launcher_count" -eq 0 ]; then
        "$binary" "$@"
    else
        "${launcher[@]}" "$binary" "$@"
    fi
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

passed=0
failed=0
# The longest wait for a case's changes to be reported. Watchers in change cases run with this
# duration too, as a backstop, and are stopped as soon as their changes are reported.
event_timeout_seconds=60
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

# Replaces the current shell with the tool, through the launcher when there is one. Used for
# background runs, so the background process ID is the tool's own and signals reach it.
exec_tool() {
    if [ "$launcher_count" -eq 0 ]; then
        exec "$binary" "$@"
    else
        exec "${launcher[@]}" "$binary" "$@"
    fi
}

# Waits until the watcher writing standard error to the given file is watching: with -s it
# prints its counters once every directory is added. Starting can take seconds, for example in
# the iOS simulator, so a fixed sleep would let changes land before the first scan.
wait_ready() {
    local err="$1"
    local attempt
    for attempt in $(seq 1 600); do
        if grep -q "^stats:" "$err" 2> /dev/null; then
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
    exec_tool -s "$@" > "$case_dir/out.txt" 2> "$case_dir/err.txt" &
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
# fixed duration instead fails when the machine is slow, as the iOS simulator in CI can be.
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

# Stops the watcher started last and waits for it to exit. Through a launcher, the tool runs as
# its own process, found by its path, and is stopped as well as the launcher.
stop_watcher() {
    if [ "$launcher_count" -gt 0 ]; then
        pkill -TERM -f "$binary" 2> /dev/null || true
    fi
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

# Text output for every kind of change, with native watching.
case_dir="$(new_case text)"
tree="$case_dir/tree"
echo "old" > "$tree/modified.txt"
echo "old" > "$tree/deleted.txt"
echo "old" > "$tree/renamed.txt"
mkdir -p "$tree/gone/inner"
echo "x" > "$tree/gone/inner/file.txt"
start_watcher "$case_dir" -d "$event_duration_ms" "$tree"
echo "new" > "$tree/created.txt"
echo "changed" >> "$tree/modified.txt"
rm "$tree/deleted.txt"
mv "$tree/renamed.txt" "$tree/renamed-to.txt"
mkdir -p "$tree/new-dir/deeper"
sleep 0.3
echo "x" > "$tree/new-dir/deeper/file.txt"
rm -r "$tree/gone"
wait_lines "$case_dir/out.txt" \
    "created file $tree/created.txt" \
    "modified file $tree/modified.txt" \
    "deleted file $tree/deleted.txt" \
    "deleted file $tree/renamed.txt" \
    "created file $tree/renamed-to.txt" \
    "created directory $tree/new-dir" \
    "created directory $tree/new-dir/deeper" \
    "created file $tree/new-dir/deeper/file.txt" \
    "deleted directory $tree/gone" \
    "deleted file $tree/gone/inner/file.txt"
stop_watcher
out="$case_dir/out.txt"
check "text: created file" has_line "$out" "created file $tree/created.txt"
check "text: modified file" has_line "$out" "modified file $tree/modified.txt"
check "text: deleted file" has_line "$out" "deleted file $tree/deleted.txt"
check "text: rename reports the old path deleted" has_line "$out" "deleted file $tree/renamed.txt"
check "text: rename reports the new path created" has_line "$out" "created file $tree/renamed-to.txt"
check "text: created directory" has_line "$out" "created directory $tree/new-dir"
check "text: created nested directory" has_line "$out" "created directory $tree/new-dir/deeper"
check "text: file in a new directory" has_line "$out" "created file $tree/new-dir/deeper/file.txt"
check "text: deleted directory" has_line "$out" "deleted directory $tree/gone"
check "text: deleted file inside a deleted directory" has_line "$out" "deleted file $tree/gone/inner/file.txt"
check "text: no warnings" has_no_warnings "$case_dir/err.txt"

# JSON output.
case_dir="$(new_case json)"
tree="$case_dir/tree"
# Windows forbids quotes in file names, so there the name checks a space instead.
json_name='quote"name.txt'
json_escaped='quote\"name.txt'
if [ "$is_windows" -eq 1 ]; then
    json_name='space name.txt'
    json_escaped='space name.txt'
fi
start_watcher "$case_dir" -f json -d "$event_duration_ms" "$tree"
echo "x" > "$tree/$json_name"
wait_lines "$case_dir/out.txt" "{\"kind\":\"created\",\"type\":\"file\",\"path\":\"$tree/$json_escaped\"}"
stop_watcher
out="$case_dir/out.txt"
check "json: created event" has_line "$out" "{\"kind\":\"created\",\"type\":\"file\",\"path\":\"$tree/$json_escaped\"}"
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
wait_lines "$case_dir/out.txt" "  path: \"$tree/a.txt\""
stop_watcher
out="$case_dir/out.txt"
check "yaml: kind line" has_line "$out" "- kind: created"
check "yaml: type line" has_line "$out" "  type: file"
check "yaml: path line" has_line "$out" "  path: \"$tree/a.txt\""
if command -v python3 > /dev/null && python3 -c "import yaml" 2> /dev/null; then
    check "yaml: output parses" python3 -c '
import sys, yaml
items = yaml.safe_load(open(sys.argv[1]))
assert items[0]["kind"] == "created"
' "$out"
fi

# Default, custom and disabled exclusions.
case_dir="$(new_case exclude)"
tree="$case_dir/tree"
mkdir -p "$tree/node_modules/pkg" "$tree/build" "$tree/.git"
start_watcher "$case_dir" -x build -e log -e .tmp -d "$event_duration_ms" "$tree"
echo "x" > "$tree/node_modules/pkg/index.js"
echo "x" > "$tree/.git/HEAD"
echo "x" > "$tree/build/out.o"
echo "x" > "$tree/server.log"
echo "x" > "$tree/scratch.tmp"
mkdir "$tree/node_modules/new"
# The kept file is written last, so once it is reported the excluded changes before it would
# have been reported too.
echo "x" > "$tree/kept.txt"
wait_lines "$case_dir/out.txt" "created file $tree/kept.txt"
stop_watcher
out="$case_dir/out.txt"
check "exclude: kept file reported" has_line "$out" "created file $tree/kept.txt"
check "exclude: node_modules left out by default" lacks_text "$out" "node_modules"
check "exclude: .git left out by default" lacks_text "$out" ".git"
check "exclude: custom directory left out" lacks_text "$out" "/build"
check "exclude: extension given without a dot left out" lacks_text "$out" "server.log"
check "exclude: extension given with a dot left out" lacks_text "$out" "scratch.tmp"

case_dir="$(new_case no-default-excludes)"
tree="$case_dir/tree"
mkdir -p "$tree/node_modules"
start_watcher "$case_dir" --no-default-excludes -d "$event_duration_ms" "$tree"
echo "x" > "$tree/node_modules/index.js"
wait_lines "$case_dir/out.txt" "created file $tree/node_modules/index.js"
stop_watcher
check "exclude: --no-default-excludes watches node_modules" has_line "$case_dir/out.txt" "created file $tree/node_modules/index.js"

# Polling, the quota and the counters.
case_dir="$(new_case poll)"
tree="$case_dir/tree"
mkdir -p "$tree/sub"
start_watcher "$case_dir" --poll -i 100 -s -d "$event_duration_ms" "$tree"
echo "x" > "$tree/sub/polled.txt"
wait_lines "$case_dir/out.txt" "created file $tree/sub/polled.txt"
stop_watcher
check "poll: change found by polling" has_line "$case_dir/out.txt" "created file $tree/sub/polled.txt"
check "poll: counters show polling only" grep -q "native_watches=0 polled_directories=2 .* native_active=false" "$case_dir/err.txt"

case_dir="$(new_case quota)"
tree="$case_dir/tree"
start_watcher "$case_dir" -q 0 -i 100 -s -d "$event_duration_ms" "$tree"
echo "x" > "$tree/quota.txt"
wait_lines "$case_dir/out.txt" "created file $tree/quota.txt"
stop_watcher
check "quota: zero quota still finds changes" has_line "$case_dir/out.txt" "created file $tree/quota.txt"
check "quota: zero quota uses no native watches" grep -q "native_watches=0 .* watch_budget=0" "$case_dir/err.txt"

# Directories beyond the quota are polled, and the quota being used up is reported.
case_dir="$(new_case overflow)"
tree="$case_dir/tree"
run_tool -q 1 -s -d 0 "$tree" 2> "$case_dir/budget.txt"
budget=$(sed -n 's/.*watch_budget=\([0-9]*\).*/\1/p' "$case_dir/budget.txt")
if [ -n "$budget" ] && [ "$budget" -gt 0 ] && [ "$budget" -lt 20000 ]; then
    for index in $(seq 1 $((budget + 5))); do
        mkdir "$tree/dir$index"
    done
    start_watcher "$case_dir" -q 1 -i 100 -s -d "$event_duration_ms" "$tree"
    echo "x" > "$tree/dir$((budget + 5))/late.txt"
    wait_lines "$case_dir/out.txt" "created file $tree/dir$((budget + 5))/late.txt"
    stop_watcher
    check "overflow: native watches stop at the budget" grep -q "native_watches=$budget polled_directories=" "$case_dir/err.txt"
    check "overflow: quota reported" grep -q "the native watch quota is used up. It is watched by polling instead." "$case_dir/err.txt"
    check "overflow: change in a polled directory found" has_line "$case_dir/out.txt" "created file $tree/dir$((budget + 5))/late.txt"
else
    echo "skip overflow: a 1% quota of this platform's limit is ${budget:-unknown} directories"
fi

case_dir="$(new_case native-stats)"
tree="$case_dir/tree"
mkdir -p "$tree/a" "$tree/b"
start_watcher "$case_dir" -s -d 600 "$tree"
wait_watcher
# Windows watches a whole tree with one watch; the other platforms use one per directory.
expected_watches=3
if [ "$is_windows" -eq 1 ]; then
    expected_watches=1
fi
check "stats: native watches" grep -q "directories=3 native_watches=$expected_watches polled_directories=0" "$case_dir/err.txt"

# Several roots, and overlapping roots.
case_dir="$(new_case roots)"
mkdir -p "$case_dir/second"
start_watcher "$case_dir" -d "$event_duration_ms" "$case_dir/tree" "$case_dir/second/"
echo "x" > "$case_dir/tree/one.txt"
echo "x" > "$case_dir/second/two.txt"
wait_lines "$case_dir/out.txt" "created file $case_dir/tree/one.txt" "created file $case_dir/second/two.txt"
stop_watcher
check "roots: first root watched" has_line "$case_dir/out.txt" "created file $case_dir/tree/one.txt"
check "roots: second root watched, trailing separator removed" has_line "$case_dir/out.txt" "created file $case_dir/second/two.txt"
set +e
run_tool -d 100 "$case_dir" "$case_dir/tree" > /dev/null 2> "$case_dir/overlap.txt"
overlap_code=$?
set -e
check "roots: overlapping roots refused" test "$overlap_code" -eq 1
check "roots: overlap explained" grep -q "overlaps another watched directory" "$case_dir/overlap.txt"

# Ctrl+C stops the tool at once with exit code 130. Git Bash cannot send Ctrl+C to a Windows
# program, and a launcher would receive the signal instead of the tool, so the case runs only
# where the tool is a plain local process.
if [ "$is_windows" -eq 0 ] && [ "$launcher_count" -eq 0 ]; then
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
    check "interrupt: changes before Ctrl+C are printed" has_line "$case_dir/out.txt" "created file $tree/before-interrupt.txt"
else
    echo "skip interrupt: Ctrl+C cannot be sent to the tool on this platform from this script"
fi

# The duration ends the run on time.
# Starting the tool can take seconds through a launcher, so that time is measured first and
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
