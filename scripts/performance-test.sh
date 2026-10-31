#!/usr/bin/env bash
#
# Measures the built CLI tool on a generated tree and prints the results: time to scan and
# watch the tree, memory, CPU use while idle, how long a single change takes to be reported, and
# load: ten thousand files created at once, modified at once and modified one after another.
# Runs native watching and polling side by side, and fails when any change goes unreported.
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
        memory_label="Memory after the load tests"
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
# Files changed in each load test.
load_count=10000
# The longest wait for one load test's changes to be reported, in seconds.
load_timeout_seconds=300
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

# Waits until the watcher writing standard error to the given file is watching: with -s it
# prints its counters once every directory is added. Starting can take seconds, for example in
# the iOS simulator, so a fixed sleep would let changes land before the first scan.
wait_ready() {
    local attempt
    for attempt in $(seq 1 1200); do
        if grep -q "^stats:" "$1" 2> /dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "error: The watcher did not start within 120 seconds."
    exit 1
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

# Creates the given number of empty files under a directory, in subdirectories of 100.
make_files() {
    local root="$1" count="$2"
    local index=0
    local remaining=$count
    while [ "$remaining" -gt 0 ]; do
        local directory="$root/d$index"
        mkdir -p "$directory"
        local batch=$(( remaining < files_per_directory ? remaining : files_per_directory ))
        (cd "$directory" && seq -f "f%g.txt" 1 "$batch" | xargs touch)
        remaining=$(( remaining - batch ))
        index=$(( index + 1 ))
    done
}

# Load actions. Each makes $load_count changes under the given directory.
create_at_once() {
    mkdir -p "$1"
    (cd "$1" && seq -f "n%g.txt" 1 "$load_count" | xargs touch)
}
modify_at_once() {
    find "$1" -type f -print0 | xargs -0 touch
}
modify_in_sequence() {
    local file
    while IFS= read -r -d '' file; do
        echo "x" >> "$file"
    done < <(find "$1" -type f -print0)
}

# Prints the number of distinct files reported with the given kind since the given line of the
# output, among paths containing the marker.
count_reported() {
    local out="$1" from="$2" kind="$3" marker="$4"
    # grep finds no line until the first change is reported, which is not an error here.
    tail -n +"$(( from + 1 ))" "$out" | { grep "^$kind file .*$marker" || true; } | sort -u |
        wc -l | tr -d ' '
}

# Runs one load test: makes the changes with the action, then waits until every changed file is
# reported. Sets load_result to the time taken to make the changes and to have them all reported,
# both counted from the first change, so they include the time the system took to make them.
load_case() {
    local label="$1" kind="$2" out="$3" marker="$4" action="$5" target="$6"
    if [ "$action" = create_at_once ]; then
        # The new directory is made first and given time to be watched, so the test measures
        # the files inside it.
        mkdir -p "$target"
        sleep 1.2
    fi
    local before
    before=$(wc -l < "$out")
    local start=${EPOCHREALTIME/./}
    "$action" "$target"
    local made_ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
    local deadline=$(( start + load_timeout_seconds * 1000000 ))
    local reported
    reported=$(count_reported "$out" "$before" "$kind" "$marker")
    while [ "$reported" -lt "$load_count" ]; do
        if [ "${EPOCHREALTIME/./}" -gt "$deadline" ]; then
            break
        fi
        sleep 0.05
        reported=$(count_reported "$out" "$before" "$kind" "$marker")
    done
    local done_ms=$(( (${EPOCHREALTIME/./} - start) / 1000 ))
    if [ "$reported" -lt "$load_count" ]; then
        failed=1
        load_result="FAILED: $reported of $load_count reported after ${done_ms} ms"
        echo "FAIL $label: $action reported $reported of $load_count changes"
        return
    fi
    load_result="all reported after ${done_ms} ms ($(( load_count * 1000 / (done_ms > 0 ? done_ms : 1) )) events/s); changes made in ${made_ms} ms"
}

# Measures one watch method. The arguments after the label are passed to the watcher.
measure() {
    local label="$1"
    shift

    # Startup: scan the tree and set up every watch, then exit.
    local start
    start=$(now_us)
    run_tool "$@" -s -d 0 "$tree" > /dev/null 2> "$work/startup-$label.txt"
    local startup_ms=$(( ($(now_us) - start) / 1000 ))

    # The files the modify tests change, in directories of 100 like the rest of the tree, made
    # before the watcher starts so they are part of its first scan.
    local load_dir="$tree/load-files-$label"
    make_files "$load_dir" "$load_count"

    # Idle and load: the watcher writes events to a file.
    local out="$work/out-$label.txt"
    exec_tool -s "$@" "$tree" > "$out" 2> "$work/err-$label.txt" &
    watcher_pid=$!
    wait_ready "$work/err-$label.txt"
    local pid
    pid=$(tool_pid "$watcher_pid")
    sleep 1

    # Idle: watch an unchanging tree and measure CPU use.
    local idle_start_cpu
    idle_start_cpu=$(cpu_ms "$pid")
    sleep "$idle_seconds"
    local idle_cpu=$(( $(cpu_ms "$pid") - idle_start_cpu ))

    # Load: ten thousand files created at once, ten thousand existing files modified at once
    # and the same files modified one after another.
    load_case "$label" created "$out" "load-new-$label" create_at_once "$tree/load-new-$label"
    result_load_created[$label]="$load_result"
    load_case "$label" modified "$out" "load-files-$label" modify_at_once "$load_dir"
    result_load_modified[$label]="$load_result"
    load_case "$label" modified "$out" "load-files-$label" modify_in_sequence "$load_dir"
    result_load_sequence[$label]="$load_result"
    local peak
    peak=$(memory_kib "$pid")
    stop_watcher
    rm -rf "$tree/load-new-$label" "$load_dir"

    # Latency: a second watcher prints through a pipe, so the script wakes the moment an event
    # is printed. The clock is read with bash's own variable, so no process is started.
    local watch_fd
    exec {watch_fd}< <(exec_tool -s "$@" "$tree" 2> "$work/latency-err-$label.txt")
    watcher_pid=$!
    wait_ready "$work/latency-err-$label.txt"
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
    local entries=$(( file_count + directory_count + load_count * 2 ))
    result_memory[$label]="$(( peak / 1024 )) MiB ($(( peak * 1024 / entries )) bytes per entry)"
    result_idle[$label]="${idle_cpu} ms"
    result_latency[$label]="median ${median_us} us, max ${max_us} us"

    echo "== $label"
    echo "  watch counters:          ${stats#stats: }"
    echo "  startup (scan + watch):  ${startup_ms} ms ($(( file_count * 1000 / (startup_ms > 0 ? startup_ms : 1) )) files/s)"
    echo "  memory:                  ${result_memory[$label]}"
    echo "  idle CPU over ${idle_seconds} s:      ${idle_cpu} ms"
    echo "  single change latency:   median ${median_us} us, max ${max_us} us (${#latencies[@]} samples)"
    echo "  $load_count created at once:          ${result_load_created[$label]}"
    echo "  $load_count modified at once:         ${result_load_modified[$label]}"
    echo "  $load_count modified one by one:      ${result_load_sequence[$label]}"
    echo
}

declare -A result_counters result_startup result_memory result_idle result_latency
declare -A result_load_created result_load_modified result_load_sequence
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
    echo "| $load_count files created at once | ${result_load_created[native]} | ${result_load_created[polling]} |"
    echo "| $load_count files modified at once | ${result_load_modified[native]} | ${result_load_modified[polling]} |"
    echo "| $load_count files modified one after another | ${result_load_sequence[native]} | ${result_load_sequence[polling]} |"
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
