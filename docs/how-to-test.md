# How to run the test suites

This guide runs the project's test step defined in `build.zig`.

## Prerequisites

- Zig `0.16.0`.
- Runtime dependencies used by fixture tests: `curl`, `openssl`, and `python3`.

## Steps

1. Run all tests:
   ```bash
   zig build test
   ```
2. Run all tests with a full build summary:
   ```bash
   zig build test --summary all
   ```
3. Run tests continuously while editing (watch + incremental):
   ```bash
   zig build test --watch -fincremental --summary all
   ```
4. Stop watch mode with `Ctrl+C`.

## Result

You have executed both suites wired in `build.zig`: the root test suite and the harness test suite.
