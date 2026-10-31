#!/usr/bin/env bash
#
# Measures the built CLI tool on a generated tree and prints the results: time to scan and
# watch the tree, memory, CPU use while idle, how fast a burst of new files is reported and how
# long a single change takes to be reported. Runs native watching and polling side by side.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-file-watcher> [file-count]"
    echo
    echo "Measures the given file-watcher binary. Build it with -Doptimize=ReleaseFast first:"
    echo "  zig build -Doptimize=ReleaseFast"
    echo "  $0 zig-out/bin/file-watcher 100000"
    echo
    echo "file-count is the number of files in the generated tree (default 100000)."
    exit 2
fi

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -x "$binary" ]; then
    echo "error: $1 is not an executable file. Build it with 'zig build -Doptimize=ReleaseFast' first."
    exit 2
fi
file_count="${2:-100000}"
if [ ! -r /proc/self/stat ]; then
    echo "error: This script reads CPU time and memory from /proc, so it runs on Linux only."
    exit 2
fi

# Files per directory in the generated tree, typical of a source tree.
files_per_directory=100
# Files created in the burst test.
burst_count=10000
# Single changes timed in the latency test.
latency_samples=20
# How long the idle CPU test watches an unchanging tree.
idle_seconds=5

work="$(mktemp -d)"
watcher_pid=""
stop_watcher() {
    if [ -n "$watcher_pid" ]; then
        kill "$watcher_pid" 2> /dev/null || true
        wait "$watcher_pid" 2> /dev/null || true
        watcher_pid=""
    fi
}
trap 'stop_watcher; rm -rf "$work"' EXIT
tree="$work/tree"
clock_ticks=$(getconf CLK_TCK)
failed=0

# Prints the current time in microseconds, from bash's own clock.
now_us() {
    echo "${EPOCHREALTIME/./}"
}

# Waits until the file has at least the given number of lines, up to the given seconds.
wait_lines() {
    local file="$1" count="$2" seconds="$3"
    local deadline=$(( ${EPOCHREALTIME/./} + seconds * 1000000 ))
    while [ "$(wc -l < "$file")" -lt "$count" ]; do
        if [ "${EPOCHREALTIME/./}" -gt "$deadline" ]; then
            return 1
        fi
        sleep 0.001
    done
}

# Prints the CPU time used by a process so far, in milliseconds.
cpu_ms() {
    local fields
    read -r -a fields < "/proc/$1/stat"
    echo $(( (fields[13] + fields[14]) * 1000 / clock_ticks ))
}

# Prints the peak resident memory of a process, in KiB.
peak_kib() {
    sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB/\1/p' "/proc/$1/status"
}

echo "Generating $file_count files in $(( (file_count + files_per_directory - 1) / files_per_directory )) directories..."
mkdir -p "$tree"
directory_index=0
remaining=$file_count
while [ "$remaining" -gt 0 ]; do
    directory="$tree/d$((directory_index / 100))/d$directory_index"
    mkdir -p "$directory"
    batch=$(( remaining < files_per_directory ? remaining : files_per_directory ))
    (cd "$directory" && seq -f "f%g.txt" 1 "$batch" | xargs touch)
    remaining=$(( remaining - batch ))
    directory_index=$(( directory_index + 1 ))
done
directory_count=$(find "$tree" -type d | wc -l)
echo "Tree: $file_count files, $directory_count directories."
echo

# Measures one watch method. The arguments after the label are passed to the watcher.
measure() {
    local label="$1"
    shift

    # Startup: scan the tree and set up every watch, then exit.
    local start
    start=$(now_us)
    "$binary" "$@" -s -d 0 "$tree" > /dev/null 2> "$work/startup-$label.txt"
    local startup_ms=$(( ($(now_us) - start) / 1000 ))

    # Idle and burst: the watcher writes events to a file.
    local out="$work/out-$label.txt"
    "$binary" "$@" "$tree" > "$out" 2> "$work/err-$label.txt" &
    watcher_pid=$!
    sleep 1

    # Idle: watch an unchanging tree and measure CPU use.
    local idle_start_cpu
    idle_start_cpu=$(cpu_ms "$watcher_pid")
    sleep "$idle_seconds"
    local idle_cpu=$(( $(cpu_ms "$watcher_pid") - idle_start_cpu ))

    # Burst: create many files at once and time until every one is reported. The file is
    # checked every millisecond, so the time includes up to a millisecond of the script's delay.
    local burst_dir="$tree/burst-$label"
    mkdir "$burst_dir"
    sleep 1.2
    local before
    before=$(wc -l < "$out")
    start=${EPOCHREALTIME/./}
    (cd "$burst_dir" && seq -f "b%g.txt" 1 "$burst_count" | xargs touch)
    local burst_ok=1
    if ! wait_lines "$out" $((before + burst_count)) 60; then
        burst_ok=0
        failed=1
    fi
    local burst_ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
    local reported=$(( $(wc -l < "$out") - before ))
    local peak
    peak=$(peak_kib "$watcher_pid")
    stop_watcher
    rm -rf "$burst_dir"

    # Latency: a second watcher prints through a pipe, so the script wakes the moment an event
    # is printed. The clock is read with bash's own variable, so no process is started.
    local watch_fd
    exec {watch_fd}< <(exec "$binary" "$@" "$tree" 2> /dev/null)
    watcher_pid=$!
    sleep 1
    local latencies=()
    local sample line end
    for sample in $(seq 1 "$latency_samples"); do
        start=${EPOCHREALTIME/./}
        echo "$sample" >> "$tree/d0/d0/f1.txt"
        if ! read -r -t 10 -u "$watch_fd" line; then
            echo "FAIL $label: change $sample was not reported within 10 s"
            failed=1
            break
        fi
        end=${EPOCHREALTIME/./}
        latencies+=($(( end - start )))
        sleep 0.05
    done
    stop_watcher
    exec {watch_fd}<&-

    local sorted
    sorted=$(printf '%s\n' "${latencies[@]}" | sort -n)
    local median_us max_us
    median_us=$(echo "$sorted" | sed -n "$(( (${#latencies[@]} + 1) / 2 ))p")
    max_us=$(echo "$sorted" | tail -n 1)
    local stats
    stats=$(grep "^stats:" "$work/startup-$label.txt" | head -n 1 || true)

    echo "== $label"
    echo "  watch counters:          ${stats#stats: }"
    echo "  startup (scan + watch):  ${startup_ms} ms ($(( file_count * 1000 / (startup_ms > 0 ? startup_ms : 1) )) files/s)"
    echo "  peak memory:             $(( peak / 1024 )) MiB ($(( peak * 1024 / (file_count + directory_count) )) bytes per entry)"
    echo "  idle CPU over ${idle_seconds} s:      ${idle_cpu} ms"
    echo "  single change latency:   median ${median_us} us, max ${max_us} us (${#latencies[@]} samples)"
    if [ "$burst_ok" -eq 1 ]; then
        echo "  burst of $burst_count files:   all reported in ${burst_ms} ms ($(( burst_count * 1000 / (burst_ms > 0 ? burst_ms : 1) )) events/s)"
    else
        echo "  FAIL burst of $burst_count files: $reported reported in ${burst_ms} ms"
    fi
    echo
}

measure native
measure polling --poll -i 1000

if [ "$failed" -ne 0 ]; then
    echo "Some changes were not reported."
    exit 1
fi
echo "Every change was reported."
