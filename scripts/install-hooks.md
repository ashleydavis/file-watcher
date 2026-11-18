# install-hooks.sh

Installs the checked-in pre-commit hook, `.githooks/pre-commit`, into this clone, so every commit runs `scripts/test-everything.sh` first and is refused when a test fails. Run it once per clone.

## Usage

```bash
scripts/install-hooks.sh
```

## Arguments

None.

## What it does

- Links `.githooks/pre-commit` into the hooks directory of the clone's git directory, replacing any hook already there. A link keeps the installed hook in step with the checked-in one.
- Leaves the git configuration as it is.

Skip the hook for one commit with `git commit --no-verify`.
