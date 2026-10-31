#!/usr/bin/env bash
#
# Measures unit test coverage with kcov, prints the line coverage and fails when any line of the
# library or CLI code is left uncovered.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 run"
    echo
    echo "Runs every unit test under kcov through 'zig build coverage', prints the line coverage"
    echo "and exits with code 1 when it is below 100%. The HTML report is written to"
    echo "zig-out/coverage/index.html."
    exit 2
fi
if [ "$1" != "run" ]; then
    echo "error: Unknown argument $1. Pass 'run' to measure coverage."
    exit 2
fi
if ! command -v kcov > /dev/null; then
    echo "error: kcov is not installed. Install it from https://github.com/SimonKagstrom/kcov and run again."
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
zig build coverage --build-file "$root/build.zig" --prefix "$root/zig-out"

report="$root/zig-out/coverage/kcov-merged/coverage.json"
covered=$(sed -n 's/^ *"covered_lines": \([0-9]*\),/\1/p' "$report" | tail -n 1)
total=$(sed -n 's/^ *"total_lines": \([0-9]*\),/\1/p' "$report" | tail -n 1)
percent=$(sed -n 's/^ *"percent_covered": "\([0-9.]*\)",/\1/p' "$report" | tail -n 1)
echo "Line coverage: $percent% ($covered of $total lines)."
echo "Report: $root/zig-out/coverage/index.html"
if [ "$covered" -ne "$total" ]; then
    echo "error: Some lines are not covered. Open the report to find them and add tests."
    exit 1
fi
