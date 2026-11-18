# cross-compile.sh

Builds the CLI tool and the unit test binaries for every supported platform, so a change that breaks another platform's build fails here, before CI. `scripts/test-everything.sh` runs it as the `cross-compile` target.

## Usage

```bash
scripts/cross-compile.sh
```

## Arguments

None.

## What it does

- Runs `zig build install install-tests -Dtarget=<target>` for each platform the README lists under "Cross compile".
- Writes each target's CLI tool to `zig-out/cross/<target>/bin` and its unit test binaries to `zig-out/cross/<target>/tests`.
- Stops with a non-zero exit code at the first build that fails.

The binaries are built and linked, so a missing symbol fails the build as it would on that platform. Running them needs that platform.
