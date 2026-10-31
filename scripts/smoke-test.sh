#!/usr/bin/env bash
#
# Runs the built CLI tool against real directories and checks every feature: help, version,
# usage errors, the three output formats, created, modified, deleted and renamed entries,
# exclusions, polling, the quota, counters, several roots and the duration.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

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

# Starts the watcher in the background with the given arguments, writing standard output to
# out.txt and standard error to err.txt in the case directory, and waits until it is watching.
start_watcher() {
    local case_dir="$1"
    shift
    "$binary" "$@" > "$case_dir/out.txt" 2> "$case_dir/err.txt" &
    watcher_pid=$!
    sleep 0.5
}

# Waits for the watcher started last to exit.
wait_watcher() {
    wait "$watcher_pid"
}

# Creates a fresh directory for one case and prints its path.
new_case() {
    local case_dir="$work/$1"
    mkdir -p "$case_dir/tree"
    echo "$case_dir"
}

echo "Smoke testing $binary"

# Help, version and usage errors.
"$binary" --help > "$work/help.txt"
check "help prints usage" grep -q "^Usage: file-watcher" "$work/help.txt"
"$binary" --version > "$work/version.txt"
check "version prints the version" grep -qE "^file-watcher [0-9]+\.[0-9]+\.[0-9]+$" "$work/version.txt"
set +e
"$binary" > /dev/null 2> "$work/usage.txt"
usage_code=$?
"$binary" --format xml "$work" > /dev/null 2> "$work/format.txt"
format_code=$?
"$binary" "$work/missing" > /dev/null 2> "$work/missing.txt"
missing_code=$?
"$binary" "$work" "$work/help.txt" > /dev/null 2> "$work/file.txt"
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
start_watcher "$case_dir" -d 2500 "$tree"
echo "new" > "$tree/created.txt"
echo "changed" >> "$tree/modified.txt"
rm "$tree/deleted.txt"
mv "$tree/renamed.txt" "$tree/renamed-to.txt"
mkdir -p "$tree/new-dir/deeper"
sleep 0.3
echo "x" > "$tree/new-dir/deeper/file.txt"
rm -r "$tree/gone"
wait_watcher
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
check "text: no warnings" test ! -s "$case_dir/err.txt"

# JSON output.
case_dir="$(new_case json)"
tree="$case_dir/tree"
start_watcher "$case_dir" -f json -d 1500 "$tree"
echo "x" > "$tree/quote\"name.txt"
wait_watcher
out="$case_dir/out.txt"
check "json: created event" has_line "$out" "{\"kind\":\"created\",\"type\":\"file\",\"path\":\"$tree/quote\\\"name.txt\"}"
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
start_watcher "$case_dir" -f yaml -d 1500 "$tree"
echo "x" > "$tree/a.txt"
wait_watcher
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
start_watcher "$case_dir" -x build -e log -e .tmp -d 1500 "$tree"
echo "x" > "$tree/node_modules/pkg/index.js"
echo "x" > "$tree/.git/HEAD"
echo "x" > "$tree/build/out.o"
echo "x" > "$tree/server.log"
echo "x" > "$tree/scratch.tmp"
echo "x" > "$tree/kept.txt"
mkdir "$tree/node_modules/new"
wait_watcher
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
start_watcher "$case_dir" --no-default-excludes -d 1500 "$tree"
echo "x" > "$tree/node_modules/index.js"
wait_watcher
check "exclude: --no-default-excludes watches node_modules" has_line "$case_dir/out.txt" "created file $tree/node_modules/index.js"

# Polling, the quota and the counters.
case_dir="$(new_case poll)"
tree="$case_dir/tree"
mkdir -p "$tree/sub"
start_watcher "$case_dir" --poll -i 100 -s -d 1500 "$tree"
echo "x" > "$tree/sub/polled.txt"
wait_watcher
check "poll: change found by polling" has_line "$case_dir/out.txt" "created file $tree/sub/polled.txt"
check "poll: counters show polling only" grep -q "native_watches=0 polled_directories=2 .* native_active=false" "$case_dir/err.txt"

case_dir="$(new_case quota)"
tree="$case_dir/tree"
start_watcher "$case_dir" -q 0 -i 100 -s -d 1500 "$tree"
echo "x" > "$tree/quota.txt"
wait_watcher
check "quota: zero quota still finds changes" has_line "$case_dir/out.txt" "created file $tree/quota.txt"
check "quota: zero quota uses no native watches" grep -q "native_watches=0 .* watch_budget=0" "$case_dir/err.txt"

# Directories beyond the quota are polled, and the quota being used up is reported.
case_dir="$(new_case overflow)"
tree="$case_dir/tree"
"$binary" -q 1 -s -d 0 "$tree" 2> "$case_dir/budget.txt"
budget=$(sed -n 's/.*watch_budget=\([0-9]*\).*/\1/p' "$case_dir/budget.txt")
if [ -n "$budget" ] && [ "$budget" -gt 0 ] && [ "$budget" -lt 20000 ]; then
    for index in $(seq 1 $((budget + 5))); do
        mkdir "$tree/dir$index"
    done
    start_watcher "$case_dir" -q 1 -i 100 -s -d 1500 "$tree"
    echo "x" > "$tree/dir$((budget + 5))/late.txt"
    wait_watcher
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
check "stats: native watch per directory" grep -q "directories=3 native_watches=3 polled_directories=0" "$case_dir/err.txt"

# Several roots, and overlapping roots.
case_dir="$(new_case roots)"
mkdir -p "$case_dir/second"
start_watcher "$case_dir" -d 1500 "$case_dir/tree" "$case_dir/second/"
echo "x" > "$case_dir/tree/one.txt"
echo "x" > "$case_dir/second/two.txt"
wait_watcher
check "roots: first root watched" has_line "$case_dir/out.txt" "created file $case_dir/tree/one.txt"
check "roots: second root watched, trailing separator removed" has_line "$case_dir/out.txt" "created file $case_dir/second/two.txt"
set +e
"$binary" -d 100 "$case_dir" "$case_dir/tree" > /dev/null 2> "$case_dir/overlap.txt"
overlap_code=$?
set -e
check "roots: overlapping roots refused" test "$overlap_code" -eq 1
check "roots: overlap explained" grep -q "overlaps another watched directory" "$case_dir/overlap.txt"

# The duration ends the run on time.
start_ns=$(date +%s%N)
"$binary" -d 300 "$work" > /dev/null
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
check "duration: exits after the duration" test "$elapsed_ms" -lt 1500

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
