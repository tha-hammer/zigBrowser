# How to add a test fixture

This guide adds a new fixture module that root-suite tests can import (for example, `@import("fixture_static")`).

## Prerequisites

- A fixture use-case in a test under `src/`.

## Steps

1. Create a fixture module under `tests/fixtures/` (for example, `tests/fixtures/my_fixture.zig`).
2. If the fixture needs files, add them under `tests/fixtures/` as committed test assets.
3. Register the fixture in `build.zig` by adding an entry to `root_test_support_specs`:
   ```zig
   .{ .name = "fixture_my", .path = "tests/fixtures/my_fixture.zig" },
   ```
4. Import and use the fixture in your root-suite test:
   ```zig
   const my_fixture = @import("fixture_my");
   ```
5. Run tests:
   ```bash
   zig build test
   ```

## Result

Your fixture is available to tests compiled through the root suite in `build.zig`.
