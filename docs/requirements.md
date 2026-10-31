# Requirements

This checklist records every requirement of the project. Each item is ticked once it is built and checked.

## Language and coding rules

- [ ] Written in Zig, locked to Zig 0.16.0.
- [ ] Follows the coding rules in https://github.com/ashleydavis/agent-config (`rules/general.md`, `rules/zig.md`, `rules/testing.md`, `rules/writing.md`), audited after the code is written.
- [ ] Idiomatic Zig style, simple and easy to read, with no overengineering.

## Code library

- [ ] A code library that the CLI tool uses.
- [ ] Usable in other projects directly from Git, by commit SHA or version tag (`zig fetch --save git+https://...#<ref>`).
- [ ] Works on Linux, Windows, macOS, Android and iOS.
- [ ] Uses the most efficient native watch method on each platform.
- [ ] Knows the platform's limit on the number of files and directories that can be watched.
- [ ] Uses a configurable quota percentage of that limit.
- [ ] Falls back to polling once the quota is used up.
- [ ] Falls back to polling when native watching fails.
- [ ] Excludes configurable file types (extensions).
- [ ] Excludes configurable directories.
- [ ] By default excludes `node_modules` and other well known hefty directories.

## CLI tool

- [ ] A CLI tool for Linux, Windows and macOS.
- [ ] Text output.
- [ ] YAML output.
- [ ] JSON output.
- [ ] Exposes the library's options: excluded directories, excluded extensions, quota percentage, poll interval and forced polling.

## Build

- [ ] Compiles on Linux.
- [ ] Cross compiles for Windows.
- [ ] Cross compiles for macOS.
- [ ] Cross compiles for Android.
- [ ] Cross compiles for iOS.

## Tests

- [ ] Unit tests with 100% coverage of the code.
- [ ] Unit tests use mocks where possible and keep file system use to a minimum.
- [ ] Smoke tests (shell script) that cover the features of the CLI tool.
- [ ] Performance tests (shell script) that print stats.
- [ ] The CLI tool has been tested.
- [ ] The unit, smoke and performance tests have been run and all pass.

## Docs

- [ ] README: how to build for the local platform.
- [ ] README: how to cross compile for Linux, Windows, macOS, Android and iOS.
- [ ] README: how to run the unit tests and smoke tests.
- [ ] AI quick start.
- [ ] User guide for the CLI.
- [ ] User guide for the code library.
- [ ] How it works.
