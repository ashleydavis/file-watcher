#!/usr/bin/env bash
#
# Installs the checked-in pre-commit hook into this clone by linking it into git's hooks
# directory. Run it once per clone.
#

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hooks="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/hooks"

mkdir -p "$hooks"
ln -sfn "$root/.githooks/pre-commit" "$hooks/pre-commit"

echo "Installed the pre-commit hook: $hooks/pre-commit runs scripts/test-everything.sh."
echo "Skip it for one commit with: git commit --no-verify"
