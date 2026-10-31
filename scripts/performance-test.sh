#!/usr/bin/env bash
#
# Measures the built CLI tool on a generated tree and prints the results: time to scan and
# watch the tree, memory, CPU use while idle, how fast a burst of new files is reported and how
# long a single change takes to be reported. Runs native watching and polling side by side.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-file-watcher> [file-count] [summary-file] [title] [launcher...]"
    echo
    echo "Measures the given file-watcher binary. Build it with -Doptimize=ReleaseFast first:"
    echo "  zig build -Doptimize=ReleaseFast"
    echo "  $0 zig-out/bin/file-watcher 100000"
    echo
    echo "file-count is the number of files in the generated tree (default 100000)."
    echo "summary-file, when given, receives the results as a markdown table, for example"
    echo "\$GITHUB_STEP_SUMMARY in GitHub Actions. Pass - for none."
    echo "title heads the markdown summary, such as the platform measured (default Performance)."
    echo "launcher, when given, is a command that runs the binary, such as"
    echo "'xcrun simctl spawn booted' for a binary built for the iOS simulator."
    echo
    echo "Runs on Linux, macOS and Windows (Git Bash), with bash 5 or later."
    exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
    echo "error: This script needs bash 5 or later for its microsecond clock; this is bash $BASH_VERSION. On macOS install it with 'brew install bash'."
    exit 2
fi

binary="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ ! -x "$binary" ]; then
    echo "error: $1 is not an executable file. Build it with 'zig build -Doptimize=ReleaseFast' first."
    exit 2
fi
file_count="${2:-100000}"
summary_file="${3:--}"
summary_title="${4:-Performance}"
shift $(( $# < 4 ? $# : 4 ))
launcher=("$@")

# Each platform reports a process's CPU time and memory in its own way.
case "$(uname -s)" in
    Linux)
        platform=linux
        memory_label="Peak memory"
        ;;
    Darwin)
        platform=macos
        memory_label="Memory after the burst"
        ;;
    MINGW* | MSYS* | CYGWIN*)
        platform=windows
        memory_label="Peak memory"
        ;;
    *)
        echo "error: $(uname -s) is not one of the platforms this script measures: Linux, macOS or Windows."
        exit 2
        ;;
esac

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

# Prints the Windows process ID of a Git Bash process ID.
windows_pid() {
    cat "/proc/$1/winpid"
}

# Prints the CPU time used by a process so far, in milliseconds.
cpu_ms() {
    case "$platform" in
        linux)
            local fields
            read -r -a fields < "/proc/$1/stat"
            echo $(( (fields[13] + fields[14]) * 1000 / $(getconf CLK_TCK) ))
            ;;
        macos)
            # ps prints the CPU time as [hours:]minutes:seconds.hundredths.
            ps -o time= -p "$1" | awk -F: '{
                seconds = 0
                for (field = 1; field <= NF; field++) seconds = seconds * 60 + $field
                printf "%d\n", seconds * 1000
            }'
            ;;
        windows)
            powershell -NoProfile -Command "[int](Get-Process -Id $(windows_pid "$1")).TotalProcessorTime.TotalMilliseconds" | tr -d '\r'
            ;;
    esac
}

# Prints the memory of a process in KiB: the peak on Linux and Windows, the current resident
# memory on macOS, which reports no peak for another process.
memory_kib() {
    case "$platform" in
        linux)
            sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB/\1/p' "/proc/$1/status"
            ;;
        macos)
            ps -o rss= -p "$1" | tr -d ' '
            ;;
        windows)
            powershell -NoProfile -Command "[int]((Get-Process -Id $(windows_pid "$1")).PeakWorkingSet64 / 1024)" | tr -d '\r'
            ;;
    esac
}

# Runs the tool with the given arguments, through the launcher when there is one.
run_tool() {
    if [ ${#launcher[@]} -eq 0 ]; then
        "$binary" "$@"
    else
        "${launcher[@]}" "$binary" "$@"
    fi
}

# Replaces the current shell with the tool, through the launcher when there is one. Used for
# background runs, so the background process ID is the tool's own rather than a subshell's.
exec_tool() {
    if [ ${#launcher[@]} -eq 0 ]; then
        exec "$binary" "$@"
    else
        exec "${launcher[@]}" "$binary" "$@"
    fi
}

# Prints the process ID of the tool started last in the background. With a launcher, the
# background process is the launcher, so the tool is found by its path.
tool_pid() {
    if [ ${#launcher[@]} -eq 0 ]; then
        echo "$1"
        return
    fi
    local attempt
    for attempt in $(seq 1 100); do
        if pgrep -n -f "$binary" 2> /dev/null; then
            return
        fi
        sleep 0.05
    done
    echo "error: The tool started through '${launcher[*]}' was not found among the running processes." >&2
    exit 1
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
    run_tool "$@" -s -d 0 "$tree" > /dev/null 2> "$work/startup-$label.txt"
    local startup_ms=$(( ($(now_us) - start) / 1000 ))

    # Idle and burst: the watcher writes events to a file.
    local out="$work/out-$label.txt"
    exec_tool "$@" "$tree" > "$out" 2> "$work/err-$label.txt" &
    watcher_pid=$!
    local pid
    pid=$(tool_pid "$watcher_pid")
    sleep 1

    # Idle: watch an unchanging tree and measure CPU use.
    local idle_start_cpu
    idle_start_cpu=$(cpu_ms "$pid")
    sleep "$idle_seconds"
    local idle_cpu=$(( $(cpu_ms "$pid") - idle_start_cpu ))

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
    peak=$(memory_kib "$pid")
    stop_watcher
    rm -rf "$burst_dir"

    # Latency: a second watcher prints through a pipe, so the script wakes the moment an event
    # is printed. The clock is read with bash's own variable, so no process is started.
    local watch_fd
    exec {watch_fd}< <(exec_tool "$@" "$tree" 2> /dev/null)
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

    # Results are kept per method for the markdown summary.
    result_counters[$label]="${stats#stats: }"
    result_startup[$label]="${startup_ms} ms"
    result_memory[$label]="$(( peak / 1024 )) MiB ($(( peak * 1024 / (file_count + directory_count) )) bytes per entry)"
    result_idle[$label]="${idle_cpu} ms"
    result_latency[$label]="median ${median_us} us, max ${max_us} us"
    if [ "$burst_ok" -eq 1 ]; then
        result_burst[$label]="${burst_ms} ms ($(( burst_count * 1000 / (burst_ms > 0 ? burst_ms : 1) )) events/s)"
    else
        result_burst[$label]="FAILED: $reported of $burst_count reported"
    fi

    echo "== $label"
    echo "  watch counters:          ${stats#stats: }"
    echo "  startup (scan + watch):  ${startup_ms} ms ($(( file_count * 1000 / (startup_ms > 0 ? startup_ms : 1) )) files/s)"
    echo "  memory:             $(( peak / 1024 )) MiB ($(( peak * 1024 / (file_count + directory_count) )) bytes per entry)"
    echo "  idle CPU over ${idle_seconds} s:      ${idle_cpu} ms"
    echo "  single change latency:   median ${median_us} us, max ${max_us} us (${#latencies[@]} samples)"
    if [ "$burst_ok" -eq 1 ]; then
        echo "  burst of $burst_count files:   all reported in ${burst_ms} ms ($(( burst_count * 1000 / (burst_ms > 0 ? burst_ms : 1) )) events/s)"
    else
        echo "  FAIL burst of $burst_count files: $reported reported in ${burst_ms} ms"
    fi
    echo
}

declare -A result_counters result_startup result_memory result_idle result_latency result_burst
measure native
measure polling --poll -i 1000

# Writes the results as a markdown table, such as a GitHub Actions job summary.
write_summary() {
    echo "## $summary_title"
    echo
    local where="on $(uname -sm)"
    if [ ${#launcher[@]} -gt 0 ]; then
        where="$where through '${launcher[*]}'"
    fi
    echo "A tree of $file_count files in $directory_count directories, measured $where."
    echo
    echo "| Measure | Native | Polling (1 s interval) |"
    echo "| --- | --- | --- |"
    echo "| Startup (scan and watch) | ${result_startup[native]} | ${result_startup[polling]} |"
    echo "| $memory_label | ${result_memory[native]} | ${result_memory[polling]} |"
    echo "| Idle CPU over ${idle_seconds} s | ${result_idle[native]} | ${result_idle[polling]} |"
    echo "| Single change latency ($latency_samples samples) | ${result_latency[native]} | ${result_latency[polling]} |"
    echo "| Burst of $burst_count new files, until all are reported | ${result_burst[native]} | ${result_burst[polling]} |"
    echo "| Watch counters | ${result_counters[native]} | ${result_counters[polling]} |"
    echo
    if [ "$failed" -ne 0 ]; then
        echo "**Some changes were not reported.**"
    else
        echo "Every change was reported."
    fi
}
if [ "$summary_file" != "-" ]; then
    write_summary >> "$summary_file"
fi

if [ "$failed" -ne 0 ]; then
    echo "Some changes were not reported."
    exit 1
fi
echo "Every change was reported."
