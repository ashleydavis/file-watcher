#!/usr/bin/env bash
#
# Cross compiles the CLI tool and the unit test binaries for every supported platform, so a
# change that breaks another platform's build fails here, not in CI. Each target is built into
# its own directory under zig-out/cross.
#

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Every platform the README lists as a cross compile target.
targets=(
    x86_64-linux-gnu
    aarch64-linux-musl
    x86_64-windows
    aarch64-windows
    x86_64-macos
    aarch64-macos
)

for target in "${targets[@]}"; do
    echo "Cross compiling: $target"
    zig build install install-tests -Dtarget="$target" --prefix "zig-out/cross/$target"
done
