# test-everything.sh

Runs each test target in `what-changed.yaml` whose watched paths changed since it last passed, using [what-changed](https://github.com/ashleydavis/what-changed). The pre-commit hook in `.githooks/pre-commit` runs it before every commit.

## Usage

```bash
scripts/test-everything.sh
```

## Arguments

None.

## What it does

- Reads the targets to run from `what-changed targets`. It prints "Nothing to test." and exits with code 0 when the list is empty.
- Runs each target's command:
  - `unit-tests`: `zig build test`.
  - `smoke-tests`: `zig build`, then `scripts/smoke-test.sh` on the built CLI tool.
  - `cross-compile`: `scripts/cross-compile.sh`.
  - `coverage`: `scripts/coverage.sh run`, on Linux only, as set in `what-changed.yaml`.
- Records a baseline with `what-changed baseline capture` after each target passes, so the target runs again only when its paths change.
- Stops with a non-zero exit code at the first target that fails.

Baselines live in `.what-changed/`, which git ignores. Delete that directory to run every target again.
