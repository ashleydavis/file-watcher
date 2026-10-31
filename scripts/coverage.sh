#!/usr/bin/env bash
#
# Measures unit test coverage with kcov, prints the line coverage and fails when any line of the
# library or CLI code is left uncovered.
#

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 run"
    echo
    echo "Builds the unit tests with the LLVM backend, runs them under kcov, prints the line"
    echo "coverage and exits with code 1 when it is below 100%. The HTML report is written to"
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
# kcov reads only LLVM's debug information, so the tests are built with the LLVM backend.
tests="$root/zig-out/coverage-build/tests"
zig build install-tests -Dllvm=true --build-file "$root/build.zig" --prefix "$root/zig-out/coverage-build"

reports="$root/zig-out/coverage-reports"
rm -rf "$reports" "$root/zig-out/coverage"
mkdir -p "$reports"
for binary in "$tests/library-tests" "$tests/cli-tests"; do
    if [ ! -x "$binary" ]; then
        echo "error: $binary is missing after the build. Run 'zig build install-tests -Dllvm=true' to see why."
        exit 2
    fi
    # The test runner's progress goes to a log, so a passing run prints only the result.
    log="$reports/$(basename "$binary").log"
    if ! kcov --include-path="$root/src" --exclude-pattern=.test.zig \
        "$reports/$(basename "$binary")" "$binary" 2> "$log"; then
        cat "$log"
        echo "error: $(basename "$binary") failed under kcov."
        exit 1
    fi
done
kcov --merge "$root/zig-out/coverage" "$reports/library-tests" "$reports/cli-tests"

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
