#!/usr/bin/env bash
#
# Runs the test targets whose watched paths changed since each last passed, as listed by
# what-changed, and records a baseline for each target that passes.
#

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

binary="zig-out/bin/file-watcher"
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        binary="zig-out/bin/file-watcher.exe"
        ;;
esac

# Runs one target. The baseline is captured only after the target passes.
run_target() {
    case "$1" in
        unit-tests)
            zig build test
            ;;
        smoke-tests)
            zig build
            scripts/smoke-test.sh "$binary"
            ;;
        cross-compile)
            scripts/cross-compile.sh
            ;;
        coverage)
            scripts/coverage.sh run
            ;;
        *)
            echo "error: unknown target \"$1\" in what-changed.yaml." >&2
            return 1
            ;;
    esac
    what-changed baseline capture "$1"
}

targets=()
while IFS= read -r line; do
    if [ -n "$line" ]; then
        targets+=("$line")
    fi
done <<< "$(what-changed targets)"

if [ ${#targets[@]} -eq 0 ]; then
    echo "Nothing to test."
    exit 0
fi

for target in "${targets[@]}"; do
    echo "Running: $target"
    run_target "$target"
done
