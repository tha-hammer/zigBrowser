---
date: 2026-07-04T12:50:00-05:00
author: FrostyGrove
git_commit: af2e4c3
branch: master
repository: zigBrowser
topic: "TDD plan: build-time JSON config ingestion"
tags: [tdd, plan, build-system, configuration, comptime, json]
status: ready_for_implementation
beads_issue: zigBrowser-2aa
source_research: thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md
last_updated: 2026-07-04
last_updated_by: FrostyGrove
last_updated_note: "Added seam diagrams mapping grammar, interfaces, and contracts"
---

# Build-Time JSON Config Ingestion TDD Implementation Plan

## Overview

Implement build-time JSON site configuration for zigBrowser. The configured site URL replaces the hardcoded no-argument default in `src/cli.zig`, while explicit CLI URL arguments continue to override the configured default.

Resolved design decisions from the research:
- Config is parsed during `zig build`, not at runtime.
- Default config path is `zigbrowser.json` at the repository root.
- Build option `-Dsite_config=<path>` overrides the default path for packaging and tests.
- V1 schema contains only required field `url`; unknown fields are accepted for forward compatibility.
- Backend-specific settings, window settings, navigation policy settings, and runtime discovery paths are out of scope.

## Current State Analysis

### Key Discoveries

- `build.zig:109-123` already uses `b.option()` for build-time inputs, but only for Windows WebView2 paths.
- `build.zig:140-146` creates the main root module and is the insertion point for generated build options.
- `build.zig:162-168` creates the root test module; it will also need the generated options because `src/root.zig` imports `src/cli.zig`.
- `build.zig:176-227` shows the existing pattern for standalone test modules and wiring them into `zig build test`.
- `src/cli.zig:20-21` is the sole hardcoded default URL path for no-argument launches.
- `src/cli.zig:86-89` currently asserts the hardcoded URL and must be changed to assert the generated config default.
- `src/main.zig:37-47` validates `Command.open.url` and passes the null-terminated URI to the C backend.
- `src/uri.zig:5-20` owns the existing URI allowlist: `http`, `https`, `file`, and `about`; `http` and `https` require a host.
- `src/ipc.zig:119-121` demonstrates typed `std.json.parseFromSliceLeaky` usage.
- `src/webkit_shim.h:30-32` is the downstream ABI and does not need to change.
- `packaging/release-build.sh:32` already forwards extra args to `zig build`, so `-Dsite_config=...` will flow through release builds.

### Existing Test Pattern

The project uses Zig's built-in test runner through `zig build test --summary all`. Standalone modules are wired by:

```zig
const nav_policy_module = b.createModule(.{
    .root_source_file = b.path("src/nav_policy.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
const nav_policy_tests_module = b.createModule(.{
    .root_source_file = b.path("tests/nav_policy_test.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
nav_policy_tests_module.addImport("nav_policy", nav_policy_module);
const nav_policy_tests = b.addTest(.{ .root_module = nav_policy_tests_module });
const run_nav_policy_tests = b.addRunArtifact(nav_policy_tests);
run_nav_policy_tests.skip_foreign_checks = true;
test_step.dependOn(&run_nav_policy_tests.step);
```

## Desired End State

Root config:

```json
{
  "url": "https://cosmic-hr-development.up.railway.app/"
}
```

Build behavior:
- `zig build` reads `zigbrowser.json`.
- `zig build -Dsite_config=tests/fixtures/config/valid_http.json` reads the specified config instead.
- Invalid, missing, empty, too-long, relative, malformed, or unsupported URL values fail the build before the binary is produced.
- `b.addOptions()` generates a `build_options.default_url` string for all modules that import CLI/config code.

Runtime behavior:
- No CLI arguments produce `.open.url == config.default_url`.
- An explicit URL argument still wins over config.
- `Command.open.url` still flows through `uri.validate` and the existing C ABI unchanged.

## Diagrams: Grammar, Interfaces, and Contracts at Each Seam

### Seam Topology

Five seams connect six components. Each seam has a grammar (data shape crossing), an
interface (function/module signature), and a contract (invariants the producer guarantees
and the consumer relies on).

```
                            SEAM MAP
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                                                                         │
 │     zigbrowser.json ──S1──▶ build.zig ──S2──▶ build_options module      │
 │                                                   │                     │
 │                                                  S3                     │
 │                                                   │                     │
 │                                                   ▼                     │
 │                                            src/config.zig               │
 │                                                   │                     │
 │                                                  S4                     │
 │                                                   │                     │
 │                                                   ▼                     │
 │     src/cli.zig ◀────────────────────────── (import)                    │
 │          │                                                              │
 │          │ Command.open.url                                             │
 │          ▼                                                              │
 │     src/uri.zig ──validate──▶ src/main.zig ──S5──▶ C ABI (shim.h)      │
 │                                                                         │
 └─────────────────────────────────────────────────────────────────────────┘
```

---

### S1 — File → Build Script (Grammar Seam)

The JSON file is where grammar lives. This is the only human-authored artifact.

```
┌─────────────────────────────────────────────────────────────────────┐
│ SEAM S1: zigbrowser.json → build.zig                                │
├──────────┬──────────────────────────────────────────────────────────┤
│ GRAMMAR  │                                                          │
│          │  Production:  object                                      │
│          │  Rule:        { "url": <URI-string> [, ...ignored] }      │
│          │                                                          │
│          │  URI-string:  RFC 3986 absolute URI                       │
│          │    scheme  ∈ { "http", "https", "file" }                  │
│          │    if scheme ∈ { "http", "https" } → host MUST be present │
│          │    length   ≤ 2048 bytes                                  │
│          │    NOT relative (no ./ or ../ or bare path)               │
│          │                                                          │
│          │  Extensibility:                                           │
│          │    Extra keys at root level are silently accepted.        │
│          │    This enables forward-compatible schema evolution.      │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ INTERFACE│                                                          │
│          │  std.Io.Dir.cwd().readFileAlloc(io, path, alloc, limit)   │
│          │  → []const u8 (raw JSON bytes)                           │
│          │                                                          │
│          │  config_schema.parse(allocator, json_bytes)               │
│          │  → ConfigError!SiteConfig                                │
│          │                                                          │
│          │  Path selection:                                          │
│          │    default = "zigbrowser.json"                            │
│          │    override = b.option("site_config") ?? default          │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ CONTRACT │                                                          │
│          │  PRODUCER (developer/CI) guarantees:                      │
│          │    • File exists at path (or build panics)               │
│          │    • Content is valid UTF-8 JSON                         │
│          │    • "url" key present with non-empty string value       │
│          │                                                          │
│          │  CONSUMER (build.zig) guarantees:                        │
│          │    • Reads file ≤ 64 KiB (prevents OOM on accidental     │
│          │      binary)                                              │
│          │    • Panics with path + error name on any failure        │
│          │    • Never modifies the config file                      │
│          │    • Passes url string unmodified to S2                  │
│          │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
```

---

### S2 — Build Script → Generated Options Module (Code Generation Seam)

```
┌─────────────────────────────────────────────────────────────────────┐
│ SEAM S2: build.zig → build_options                                  │
├──────────┬──────────────────────────────────────────────────────────┤
│ GRAMMAR  │                                                          │
│          │  Generated module exports:                                │
│          │    pub const default_url: []const u8 = "...";            │
│          │    pub const config_path: []const u8 = "...";            │
│          │                                                          │
│          │  default_url:                                             │
│          │    Verbatim "url" value from JSON.                       │
│          │    Non-empty (enforced at S1 parse).                     │
│          │    Valid URI scheme (enforced at S1 parse).               │
│          │                                                          │
│          │  config_path:                                             │
│          │    Path that was read (for diagnostics/logging).         │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ INTERFACE│                                                          │
│          │  const site_options = b.addOptions();                     │
│          │  site_options.addOption([]const u8, "default_url", val); │
│          │  site_options.addOption([]const u8, "config_path", path);│
│          │                                                          │
│          │  root_module.addOptions("build_options", site_options);   │
│          │  test_module.addOptions("build_options", site_options);   │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ CONTRACT │                                                          │
│          │  PRODUCER (build.zig) guarantees:                        │
│          │    • default_url is the exact byte sequence from JSON    │
│          │    • default_url has passed config_schema.parse()        │
│          │      (valid scheme, non-empty, ≤ 2048 bytes)            │
│          │    • Options are attached to BOTH root_module and        │
│          │      test_module                                         │
│          │                                                          │
│          │  CONSUMER (any .zig file) can rely on:                   │
│          │    • @import("build_options").default_url is always      │
│          │      available at comptime                               │
│          │    • Value satisfies URI scheme allowlist                 │
│          │    • Value is non-empty                                  │
│          │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
```

---

### S3 — Generated Options → Config Facade (Import Seam)

```
┌─────────────────────────────────────────────────────────────────────┐
│ SEAM S3: build_options → src/config.zig                             │
├──────────┬──────────────────────────────────────────────────────────┤
│ GRAMMAR  │                                                          │
│          │  src/config.zig re-exports:                               │
│          │    pub const default_url: []const u8;                    │
│          │    pub const config_path: []const u8;                    │
│          │                                                          │
│          │  Comptime assertion:                                     │
│          │    default_url.len > 0 (or @compileError)                │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ INTERFACE│                                                          │
│          │  // src/config.zig                                        │
│          │  const build_options = @import("build_options");          │
│          │  pub const default_url = build_options.default_url;      │
│          │  pub const config_path = build_options.config_path;      │
│          │                                                          │
│          │  comptime {                                               │
│          │      if (default_url.len == 0)                           │
│          │          @compileError("build_options.default_url empty");│
│          │  }                                                       │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ CONTRACT │                                                          │
│          │  PURPOSE: Thin facade insulating source from build       │
│          │  system internals. Only config.zig knows about           │
│          │  "build_options"; cli.zig depends on config.zig.         │
│          │                                                          │
│          │  GUARANTEES:                                              │
│          │    • default_url is comptime-known                       │
│          │    • default_url.len > 0 (compile-time enforced)         │
│          │    • Changing config.zig does not require changing       │
│          │      cli.zig or main.zig                                 │
│          │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
```

---

### S4 — Config Facade → CLI Parser (Module Import Seam)

```
┌─────────────────────────────────────────────────────────────────────┐
│ SEAM S4: src/config.zig → src/cli.zig                               │
├──────────┬──────────────────────────────────────────────────────────┤
│ GRAMMAR  │                                                          │
│          │  Data crossing this seam:                                 │
│          │    config.default_url : []const u8                       │
│          │                                                          │
│          │  Consumed as:                                             │
│          │    Command{ .open = .{ .url = config.default_url } }     │
│          │                                                          │
│          │  Command.open grammar (unchanged):                       │
│          │    url: []const u8      — the URI to load               │
│          │    print_title: bool    — default false                  │
│          │    e2e_protocol: bool   — default false                  │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ INTERFACE│                                                          │
│          │  // src/cli.zig                                           │
│          │  const config = @import("config.zig");                   │
│          │                                                          │
│          │  pub fn parseArgs(args: []const []const u8) Command {    │
│          │      if (args.len <= 1) return .{                        │
│          │          .open = .{ .url = config.default_url }          │
│          │      };                                                  │
│          │      // explicit URL parsing unchanged                   │
│          │  }                                                       │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ CONTRACT │                                                          │
│          │  SEMANTIC:                                                │
│          │    • No-args → config default (single-site browser       │
│          │      identity)                                           │
│          │    • Explicit arg → overrides config (dev/test escape)   │
│          │    • All other CLI parsing (--version, --screenshot,     │
│          │      --print-title, --e2e-protocol) unchanged            │
│          │                                                          │
│          │  BEHAVIORAL INVARIANT:                                    │
│          │    ∀ args where args.len > 1 and first non-flag token    │
│          │    is a URL → that URL is returned, not config default   │
│          │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
```

---

### S5 — Zig Runtime → C ABI (FFI Seam, Unchanged)

```
┌─────────────────────────────────────────────────────────────────────┐
│ SEAM S5: src/main.zig → webkit_shim.h (UNCHANGED)                  │
├──────────┬──────────────────────────────────────────────────────────┤
│ GRAMMAR  │                                                          │
│          │  C function signature:                                    │
│          │    int zb_app_run(const char *uri, int, int);            │
│          │                                                          │
│          │  uri:                                                     │
│          │    Null-terminated C string                               │
│          │    Passed through uri.validate() → [:0]const u8 → .ptr  │
│          │    Valid scheme, valid host (for http/https)              │
│          │                                                          │
│          │  Returns:                                                 │
│          │    ZB_EXIT_* enum value                                  │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ INTERFACE│                                                          │
│          │  // Zig side (main.zig:43-47)                            │
│          │  webkit.c.zb_app_run(valid_uri.ptr, print_title, e2e)   │
│          │                                                          │
│          │  // C side (webkit_shim.h:31)                            │
│          │  int zb_app_run(const char *uri, int print_title,       │
│          │                 int e2e_protocol);                        │
│          │                                                          │
├──────────┼──────────────────────────────────────────────────────────┤
│ CONTRACT │                                                          │
│          │  THIS SEAM IS NOT MODIFIED BY THIS FEATURE.              │
│          │                                                          │
│          │  Existing guarantees preserved:                           │
│          │    • uri is non-null, null-terminated                    │
│          │    • uri has been validated by uri.validate()            │
│          │    • Return value is a valid ZB_EXIT_* code              │
│          │    • GTK backend: derive_app_base(uri) for nav policy   │
│          │    • macOS backend: derive_app_base(uri) for nav policy  │
│          │                                                          │
└──────────┴──────────────────────────────────────────────────────────┘
```

---

### Contract Enforcement Timeline

Shows WHEN each contract is checked and WHAT fails if violated:

```
    TIME ──────────────────────────────────────────────────────▶

    zig build                          binary execution
    ┌──────────────────────────┐       ┌──────────────────────┐
    │                          │       │                      │
    │  S1: readFileAlloc       │       │  S5: zb_app_run      │
    │    ✗ file missing        │       │    (unchanged)       │
    │    ✗ file > 64KiB        │       │                      │
    │                          │       │  uri.validate()      │
    │  S1: config_schema.parse │       │    ✗ bad scheme      │
    │    ✗ invalid JSON        │       │    ✗ no host         │
    │    ✗ no "url" key        │       │    ✗ relative        │
    │    ✗ empty url           │       │                      │
    │    ✗ url > 2048          │       │  C shim load         │
    │    ✗ bad scheme          │       │    ✗ network error   │
    │    ✗ relative URI        │       │    → LOAD_FAILED (5) │
    │                          │       │                      │
    │  S2: addOption           │       └──────────────────────┘
    │    (always succeeds      │
    │     if S1 passed)        │
    │                          │
    │  S3: comptime assert     │
    │    ✗ empty default_url   │
    │    (redundant safety)    │
    │                          │
    │  S4: cli.zig compiles    │
    │    (always succeeds      │
    │     if S3 passed)        │
    │                          │
    └──────────────────────────┘

    Legend: ✗ = build/runtime failure if condition met
```

---

### Grammar ↔ Seam Correspondence Table

```
┌───────────────────────────┬───────────┬────────────────────────────────────┐
│ GRAMMAR ELEMENT           │ SEAM      │ WHERE VALIDATED                    │
├───────────────────────────┼───────────┼────────────────────────────────────┤
│ JSON object structure     │ S1        │ config_schema.parse() in build.zig │
│ "url" field presence      │ S1        │ config_schema.parse() → MissingUrl │
│ "url" non-empty           │ S1        │ config_schema.parse() → EmptyUrl   │
│ "url" ≤ 2048 bytes        │ S1        │ config_schema.parse() → UrlTooLong │
│ "url" scheme allowlist    │ S1        │ uri.checkAllowed() via parse()     │
│ "url" host required       │ S1        │ uri.checkAllowed() → InvalidUri    │
│ "url" not relative        │ S1        │ uri.checkAllowed() → RelativeUri   │
│ Unknown fields ignored    │ S1        │ .ignore_unknown_fields = true      │
├───────────────────────────┼───────────┼────────────────────────────────────┤
│ default_url: []const u8   │ S2        │ b.addOptions() type system         │
│ default_url non-empty     │ S3        │ comptime assert in config.zig      │
├───────────────────────────┼───────────┼────────────────────────────────────┤
│ Command.open.url slice    │ S4        │ Zig type system ([]const u8)       │
├───────────────────────────┼───────────┼────────────────────────────────────┤
│ const char* uri (C str)   │ S5        │ uri.validate() → arena.dupeZ()    │
│ null-terminated           │ S5        │ [:0]const u8 type + .ptr access    │
└───────────────────────────┴───────────┴────────────────────────────────────┘
```

---

### Interface Dependency Graph

Shows which module imports which, and what crosses each edge:

```
                   build.zig
                   ┌────────────────────────────────────────────┐
                   │ @import("src/config_schema.zig")           │
                   │                                            │
                   │ Calls:                                     │
                   │   readFileAlloc(path) → bytes              │
                   │   config_schema.parse(alloc, bytes) → cfg  │
                   │   b.addOptions() → options                 │
                   │   options.addOption("default_url", cfg.url)│
                   │   root_module.addOptions("build_options",  │
                   │                          options)          │
                   └────────────────────┬───────────────────────┘
                                        │ generates
                                        ▼
                   build_options (synthetic .zig)
                   ┌────────────────────────────────────────────┐
                   │ pub const default_url: []const u8 = "..."; │
                   │ pub const config_path: []const u8 = "..."; │
                   └────────────────────┬───────────────────────┘
                                        │ @import
                                        ▼
                   src/config.zig
                   ┌────────────────────────────────────────────┐
                   │ pub const default_url = ...;               │
                   │ pub const config_path = ...;               │
                   │ comptime { assert(default_url.len > 0); }  │
                   └────────────────────┬───────────────────────┘
                                        │ @import
                                        ▼
                   src/cli.zig
                   ┌────────────────────────────────────────────┐
                   │ const config = @import("config.zig");      │
                   │                                            │
                   │ parseArgs:                                  │
                   │   no args → .open.url = config.default_url │
                   │   explicit → .open.url = argv token        │
                   └────────────────────┬───────────────────────┘
                                        │ Command.open.url
                                        ▼
                   src/main.zig
                   ┌────────────────────────────────────────────┐
                   │ uri.validate(arena, spec.url) → valid_uri  │
                   │ webkit.c.zb_app_run(valid_uri.ptr, ...)    │
                   └────────────────────┬───────────────────────┘
                                        │ const char*
                                        ▼
                   webkit_shim.h / C backend
                   ┌────────────────────────────────────────────┐
                   │ load URI in webview (GTK/WK/WV2)           │
                   └────────────────────────────────────────────┘


   Lateral dependency (shared by S1 and S5):

                   src/config_schema.zig ──imports──▶ src/uri.zig
                                                     (checkAllowed)
                   src/main.zig ──imports──▶ src/uri.zig
                                            (validate, which calls checkAllowed)
```

---

## Observable Behaviors

- Given valid JSON with a URL, when the schema parser runs, then it returns that URL and ignores unknown fields.
- Given missing, empty, too-long, malformed, relative, or unsupported URL config, when `zig build` runs, then the build fails with a message naming the config path and reason.
- Given a valid config, when `zig build test` compiles modules that import `src/cli.zig`, then `build_options.default_url` is available and tests pass.
- Given a valid config, when `cli.parseArgs` receives only argv[0], then it returns `.open` with the configured default URL.
- Given a valid config, when `cli.parseArgs` receives an explicit URL, then the explicit URL is returned unchanged.
- Given a valid config, when packaging scripts are invoked with `-Dsite_config=<path>`, then that argument reaches `zig build`.

## What We Are Not Doing

- Runtime config file reading.
- Multiple config search paths.
- Window title, size, icon, permission, IPC, or navigation policy schema fields.
- Backend-specific schema branches.
- Changing `src/webkit_shim.h` or any C ABI.
- Changing the current explicit URL, screenshot URL, or `--version` CLI semantics.

## Testing Strategy

- Framework: Zig `std.testing` via `zig build test --summary all`.
- Unit tests:
  - `src/uri.zig` URI allowlist remains covered by existing tests.
  - New `tests/config_schema_test.zig` covers JSON schema parsing and config URL validation.
  - Existing `src/cli.zig` tests cover no-args default and explicit URL override.
- Build tests:
  - Successful `zig build -Dsite_config=<valid-fixture> test --summary all`.
  - Negative `zig build -Dsite_config=<bad-fixture> test --summary all` commands that must fail without mutating root files.
- Integration/manual checks:
  - `packaging/release-build.sh -Dsite_config=<valid-fixture>` produces `zig-out/bin/zigBrowser`.
  - Optional display-backed no-arg launch verifies the configured app loads, using the existing e2e protocol only when a display or xvfb is available.

## File-Level Change Plan

- Add `zigbrowser.json`.
- Add `src/config_schema.zig` for backend-free JSON schema parsing and URL validation.
- Add `src/config.zig` as the generated build-options facade.
- Modify `src/uri.zig` to expose a shared `checkAllowed(input)` helper used by both runtime validation and build-time config validation.
- Modify `src/cli.zig` to import `config.zig` and use `config.default_url` for the no-args default.
- Modify `src/root.zig` only if needed for explicit config module reachability; `cli.zig` importing `config.zig` may already be enough.
- Modify `build.zig` to read config, generate options, add options to affected modules, and wire config schema tests.
- Add `tests/config_schema_test.zig`.
- Add JSON fixtures under `tests/fixtures/config/`.
- Update `docs/how-to-build.md` and `docs/how-to-run.md` with `zigbrowser.json` and `-Dsite_config`.

## Behavior 1: Shared URI Check Preserves Runtime Semantics

### Test Specification

Given the existing URI allowlist, when a config URL is checked at build time, then it accepts the same URL classes that runtime validation accepts and rejects the same invalid inputs.

Edge cases:
- `https://example.com/` accepted.
- `http://example.com/` accepted.
- `file:///tmp/app/index.html` accepted.
- `about:blank` accepted if preserving existing runtime semantics is desired for defaults.
- `https://` rejected.
- `./relative` rejected.
- `javascript:alert(1)` rejected.

### TDD Cycle

#### Red: Write Failing Test

File: `src/uri.zig`

Add a focused test for a new helper:

```zig
test "checkAllowed validates URI without allocating" {
    try checkAllowed("https://example.com/");
    try checkAllowed("file:///tmp/index.html");
    try checkAllowed("about:blank");

    try std.testing.expectError(error.InvalidUri, checkAllowed("https://"));
    try std.testing.expectError(error.RelativeUri, checkAllowed("./relative"));
    try std.testing.expectError(error.UnsupportedScheme, checkAllowed("javascript:alert(1)"));
}
```

Expected red failure: `checkAllowed` does not exist.

#### Green: Minimal Implementation

File: `src/uri.zig`

```zig
pub fn checkAllowed(input: []const u8) UriError!void {
    const parsed = std.Uri.parse(input) catch return error.InvalidUri;

    if (parsed.scheme.len == 0) return error.RelativeUri;

    if (std.mem.eql(u8, parsed.scheme, "http") or std.mem.eql(u8, parsed.scheme, "https")) {
        if (parsed.host == null) return error.InvalidUri;
    } else if (std.mem.eql(u8, parsed.scheme, "about")) {
        return;
    } else if (!std.mem.eql(u8, parsed.scheme, "file")) {
        return error.UnsupportedScheme;
    }
}

pub fn validate(arena: std.mem.Allocator, input: []const u8) UriError![:0]const u8 {
    try checkAllowed(input);
    return arena.dupeZ(u8, input) catch return error.InvalidUri;
}
```

#### Refactor

- Keep the scheme logic in one function.
- Preserve every existing `uri.validate` test expectation.
- Avoid allocating during build-time validation.

### Success Criteria

Automated:
- [ ] New `checkAllowed` test fails before implementation.
- [ ] `zig build test --summary all` passes after implementation.
- [ ] Existing URI tests still pass unchanged.

Manual:
- [ ] Error mappings in `src/main.zig:67-72` still match the same `UriError` values.

## Behavior 2: Config Schema Parser Accepts V1 JSON

### Test Specification

Given a valid v1 config JSON object, when `config_schema.parse` runs, then it returns the URL. Unknown fields are ignored.

Edge cases:
- Unknown fields accepted.
- Missing `url` rejected.
- Empty `url` rejected.
- Non-string `url` rejected as invalid JSON for the typed schema.
- URL longer than `max_url_len` rejected.
- Unsupported or relative URL rejected.

### TDD Cycle

#### Red: Write Failing Test

File: `tests/config_schema_test.zig`

```zig
const std = @import("std");
const config_schema = @import("config_schema");

test "parse extracts url from valid config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try config_schema.parse(arena.allocator(),
        \\{"url":"https://example.com/app"}
    );
    try std.testing.expectEqualStrings("https://example.com/app", parsed.url);
}

test "parse ignores unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try config_schema.parse(arena.allocator(),
        \\{"url":"https://example.com/app","title":"future","permissions":{"x":true}}
    );
    try std.testing.expectEqualStrings("https://example.com/app", parsed.url);
}

test "parse rejects invalid url fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.MissingUrl, config_schema.parse(allocator, "{}"));
    try std.testing.expectError(error.EmptyUrl, config_schema.parse(allocator, \\{"url":""}));
    try std.testing.expectError(error.UnsupportedScheme, config_schema.parse(allocator, \\{"url":"javascript:alert(1)"}));
    try std.testing.expectError(error.RelativeUri, config_schema.parse(allocator, \\{"url":"./index.html"}));
}
```

Expected red failure: `config_schema` module does not exist.

#### Green: Minimal Implementation

File: `src/config_schema.zig`

```zig
const std = @import("std");
const uri = @import("uri.zig");

pub const max_url_len: usize = 2048;

pub const ConfigError = error{
    InvalidJson,
    MissingUrl,
    EmptyUrl,
    UrlTooLong,
    InvalidUri,
    UnsupportedScheme,
    RelativeUri,
};

pub const SiteConfig = struct {
    url: []const u8,
};

const RawConfig = struct {
    url: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8) ConfigError!SiteConfig {
    const raw = std.json.parseFromSliceLeaky(RawConfig, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;

    const url = raw.url orelse return error.MissingUrl;
    if (url.len == 0) return error.EmptyUrl;
    if (url.len > max_url_len) return error.UrlTooLong;

    uri.checkAllowed(url) catch |err| return switch (err) {
        error.InvalidUri => error.InvalidUri,
        error.UnsupportedScheme => error.UnsupportedScheme,
        error.RelativeUri => error.RelativeUri,
    };

    return .{ .url = url };
}
```

#### Refactor

- Keep `config_schema.zig` backend-free so `build.zig` can safely `@import` it.
- Keep parsing independent from generated options so parser tests do not need `build_options`.
- Use an arena allocator in tests because `parse` returns slices owned by the parser allocator.
- Keep `max_url_len` close to the schema parser so build failures are deterministic.

### Success Criteria

Automated:
- [ ] `tests/config_schema_test.zig` fails before `src/config_schema.zig` exists.
- [ ] `zig build test --summary all` includes and passes config schema tests.
- [ ] Parser rejects bad schema without touching root `zigbrowser.json`.

Manual:
- [ ] Error names are clear enough to surface from build.zig without extra decoding.

## Behavior 3: Build Script Reads Config and Generates Options

### Test Specification

Given a valid config file, when `zig build` runs, then `build_options.default_url` is generated and attached to all modules that compile CLI/config code.

Given a bad config path or bad config file, when `zig build` runs, then it fails before producing the binary.

### TDD Cycle

#### Red: Write Failing Build Dependency

Modify `src/config.zig` and `src/cli.zig` in Behavior 4 before wiring options. The red failure should be a compile error that `build_options` cannot be imported by modules that reach `src/config.zig`.

#### Green: Minimal Implementation

File: `build.zig`

Add near the top:

```zig
const config_schema = @import("src/config_schema.zig");
```

Add after existing `b.option()` declarations:

```zig
const site_config_path = b.option(
    []const u8,
    "site_config",
    "Path to zigBrowser JSON site config",
) orelse "zigbrowser.json";

const site_config = loadSiteConfig(b, site_config_path);
const site_options = b.addOptions();
site_options.addOption([]const u8, "default_url", site_config.url);
site_options.addOption([]const u8, "config_path", site_config_path);
```

Add helper below `build`:

```zig
fn loadSiteConfig(b: *std.Build, path: []const u8) config_schema.SiteConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.panic("failed to read site config '{s}': {s}", .{ path, @errorName(err) });
    };

    return config_schema.parse(b.allocator, bytes) catch |err| {
        std.debug.panic("invalid site config '{s}': {s}", .{ path, @errorName(err) });
    };
}
```

Attach options to affected modules:

```zig
root_module.addOptions("build_options", site_options);
test_module.addOptions("build_options", site_options);
```

If any additional test module imports `src/cli.zig` or `src/config.zig`, attach the same `site_options` there too.

#### Refactor

- Keep `loadSiteConfig` separate from backend configuration.
- Keep config loading before module creation or immediately before adding options, whichever reads most clearly.
- Do not use `@embedFile` in `build.zig`; `readFileAlloc` plus `-Dsite_config` makes negative tests non-destructive and packaging-friendly.

### Success Criteria

Automated:
- [ ] `zig build -Dsite_config=tests/fixtures/config/valid_http.json test --summary all` passes.
- [ ] `zig build -Dsite_config=tests/fixtures/config/missing_url.json test --summary all` fails with `invalid site config` and `MissingUrl`.
- [ ] `zig build -Dsite_config=tests/fixtures/config/bad_json.json test --summary all` fails with `InvalidJson`.
- [ ] `zig build -Dsite_config=tests/fixtures/config/bad_scheme.json test --summary all` fails with `UnsupportedScheme`.
- [ ] `zig build -Dsite_config=tests/fixtures/config/no-such-file.json test --summary all` fails with `failed to read site config`.

Manual:
- [ ] Failure tests do not rename or delete `zigbrowser.json`.
- [ ] `zig build --help` shows the `site_config` option.

## Behavior 4: CLI Uses the Generated Config Default

### Test Specification

Given generated `build_options.default_url`, when `parseArgs` receives only argv[0], then it returns `.open.url == config.default_url`.

Given generated `build_options.default_url`, when `parseArgs` receives an explicit URL, then it returns the explicit URL and preserves current flag behavior.

### TDD Cycle

#### Red: Change the Existing Test First

File: `src/cli.zig`

```zig
const config = @import("config.zig");

test "parseArgs no args yields open with config default URL" {
    const cmd = parseArgs(&.{"zigBrowser"});
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqualStrings(config.default_url, cmd.open.url);
}
```

Expected red failure: `config.zig` or `build_options` is not wired yet.

#### Green: Minimal Implementation

File: `src/config.zig`

```zig
const build_options = @import("build_options");

pub const default_url: []const u8 = build_options.default_url;
pub const config_path: []const u8 = build_options.config_path;

comptime {
    if (default_url.len == 0) {
        @compileError("build_options.default_url must not be empty");
    }
}
```

File: `src/cli.zig`

```zig
const config = @import("config.zig");

pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .{ .open = .{ .url = config.default_url } };
    // existing parsing unchanged
}
```

#### Refactor

- Remove the magic URL literal from `src/cli.zig`.
- Keep all explicit URL and screenshot parsing unchanged.
- If `src/root.zig` needs direct reachability for `config.zig`, add `_ = @import("config.zig");`; otherwise rely on `cli.zig`.

### Success Criteria

Automated:
- [ ] Existing explicit URL tests in `src/cli.zig:97-131` still pass.
- [ ] Existing screenshot tests in `src/cli.zig:133-152` still pass.
- [ ] No-args test asserts `config.default_url`, not the historical literal.

Manual:
- [ ] `src/cli.zig` no longer contains `cosmic-hr-development` directly.

## Behavior 5: Config Schema Tests Are Wired Into `zig build test`

### Test Specification

Given `tests/config_schema_test.zig`, when `zig build test` runs, then config schema tests execute with the rest of the suite.

### TDD Cycle

#### Red: Add the Test File Before Build Wiring

File: `tests/config_schema_test.zig`

Use tests from Behavior 2. Red state: the file exists but is not executed by `zig build test`.

#### Green: Wire Test Module

File: `build.zig`

```zig
const config_schema_module = b.createModule(.{
    .root_source_file = b.path("src/config_schema.zig"),
    .target = target,
    .optimize = optimize,
});

const config_schema_tests_module = b.createModule(.{
    .root_source_file = b.path("tests/config_schema_test.zig"),
    .target = target,
    .optimize = optimize,
});
config_schema_tests_module.addImport("config_schema", config_schema_module);

const config_schema_tests = b.addTest(.{ .root_module = config_schema_tests_module });
const run_config_schema_tests = b.addRunArtifact(config_schema_tests);
run_config_schema_tests.skip_foreign_checks = true;
test_step.dependOn(&run_config_schema_tests.step);
```

If `src/config_schema.zig` imports `src/uri.zig` by relative import, no separate `uri` module import is required.

#### Refactor

- Place the new block near `ipc` and `nav_policy` standalone tests.
- Keep `skip_foreign_checks = true` consistent with existing test artifacts.
- Avoid linking backend C libraries for the schema test module.

### Success Criteria

Automated:
- [ ] Intentionally breaking a config schema expectation causes `zig build test` to fail.
- [ ] Restoring the implementation makes `zig build test --summary all` pass.

Manual:
- [ ] Test module does not depend on GTK, WebView2, or macOS framework linkage.

## Behavior 6: Valid and Invalid Config Fixtures Drive Build Tests

### Test Specification

Given fixture configs, when build commands point at each fixture via `-Dsite_config`, then valid fixtures pass and invalid fixtures fail without mutating the working tree.

### TDD Cycle

#### Red: Add Fixtures and Document Commands

Files:
- `tests/fixtures/config/valid_http.json`
- `tests/fixtures/config/valid_file.json`
- `tests/fixtures/config/extra_fields.json`
- `tests/fixtures/config/missing_url.json`
- `tests/fixtures/config/empty_url.json`
- `tests/fixtures/config/bad_json.json`
- `tests/fixtures/config/bad_scheme.json`
- `tests/fixtures/config/relative_url.json`

Example contents:

```json
{"url":"https://example.com/app"}
```

```json
{"url":"https://example.com/app","title":"future field"}
```

```json
{"title":"missing url"}
```

#### Green: Build With Fixture Override

Commands:

```bash
zig build -Dsite_config=tests/fixtures/config/valid_http.json test --summary all
zig build -Dsite_config=tests/fixtures/config/extra_fields.json test --summary all
```

Negative checks:

```bash
! zig build -Dsite_config=tests/fixtures/config/missing_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/empty_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/bad_json.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/bad_scheme.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/relative_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/no-such-file.json test --summary all
```

#### Refactor

- If repeated negative checks become tedious, add `tests/config_build_failure_test.sh` with non-interactive shell settings and no file mutation.
- Do not implement failure tests by `mv`-ing root `zigbrowser.json`.

### Success Criteria

Automated:
- [ ] Valid fixture builds pass.
- [ ] Invalid fixture builds fail for the expected reason.
- [ ] Negative tests leave `git status --short` unchanged except for intended new files.

Manual:
- [ ] Error text includes the selected config path.

## Behavior 7: Default Root Config Keeps Existing App Identity

### Test Specification

Given `zigbrowser.json` at the repository root, when `zig build` runs without `-Dsite_config`, then the binary default URL remains the current Cosmic HR URL.

### TDD Cycle

#### Red: Add Root Config, Then Remove Hardcoded URL Test Expectation

File: `zigbrowser.json`

```json
{
  "url": "https://cosmic-hr-development.up.railway.app/"
}
```

Red state after changing the CLI test: build fails until build options are wired.

#### Green: Default Build Reads Root Config

Command:

```bash
zig build test --summary all
```

Expected: pass with no `-Dsite_config` flag.

#### Refactor

- Keep root config minimal.
- Preserve forward compatibility by ignoring unknown fields in parser, but do not add future fields to root config yet.

### Success Criteria

Automated:
- [ ] `zig build test --summary all` passes with root `zigbrowser.json`.
- [ ] `rg "cosmic-hr-development" src` returns no hardcoded source references outside tests/docs if any remain intentionally.

Manual:
- [ ] A developer can change only `zigbrowser.json`, rebuild, and get a binary with a different no-arg default.

## Behavior 8: Documentation and Packaging Expose the Config Seam

### Test Specification

Given the new build option, when a developer reads build/run docs or uses `packaging/release-build.sh`, then they can discover and pass a config path.

### TDD Cycle

#### Red: Documentation Missing Config Instructions

Files:
- `docs/how-to-build.md`
- `docs/how-to-run.md`

Add a short section documenting:

```bash
zig build -Dsite_config=path/to/zigbrowser.json
packaging/release-build.sh -Dsite_config=path/to/zigbrowser.json
```

#### Green: Existing Packaging Pass-Through Works

No script change should be required because `packaging/release-build.sh:32` already invokes:

```bash
zig build -Doptimize=ReleaseSafe "$@"
```

Verification:

```bash
packaging/release-build.sh -Dsite_config=tests/fixtures/config/valid_http.json
```

#### Refactor

- Do not add a second packaging flag parser.
- Keep config instructions near existing build invocation docs.

### Success Criteria

Automated:
- [ ] Release build command succeeds with a valid config fixture when platform dependencies are present.

Manual:
- [ ] Docs explain root default path and `-Dsite_config` override.
- [ ] Docs state config is baked into the binary at build time.

## Implementation Order

1. Extract `uri.checkAllowed` and keep `uri.validate` behavior green.
2. Add `src/config_schema.zig` and `tests/config_schema_test.zig`.
3. Add config fixtures under `tests/fixtures/config/`.
4. Add root `zigbrowser.json`.
5. Add `src/config.zig`.
6. Modify `src/cli.zig` to use `config.default_url`.
7. Modify `build.zig` to read config, generate options, attach options to root/test modules, and wire schema tests.
8. Run positive and negative build commands.
9. Update docs.
10. Run final verification.

## Final Verification Commands

Primary:

```bash
zig build test --summary all
zig build -Dsite_config=tests/fixtures/config/valid_http.json test --summary all
zig build -Dsite_config=tests/fixtures/config/extra_fields.json test --summary all
```

Negative:

```bash
! zig build -Dsite_config=tests/fixtures/config/missing_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/empty_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/bad_json.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/bad_scheme.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/relative_url.json test --summary all
! zig build -Dsite_config=tests/fixtures/config/no-such-file.json test --summary all
```

Packaging, when native dependencies are installed:

```bash
packaging/release-build.sh -Dsite_config=tests/fixtures/config/valid_http.json
```

Optional display-backed check:

```bash
DISPLAY="${DISPLAY:-:1}" ./zig-out/bin/zigBrowser --e2e-protocol
```

## Beads Tracking

- Issue: `zigBrowser-2aa`
- Title: `Build-time JSON config ingestion (zigbrowser.json)`
- Plan path: `thoughts/searchable/shared/plans/2026-07-04-12-50-tdd-build-time-json-config.md`
- Source research: `thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md`

## References

- Research: `thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md`
- Build option pattern: `build.zig:109-123`
- Build options insertion point: `build.zig:140-146`
- Root test module requiring generated options: `build.zig:162-168`
- Standalone test module pattern: `build.zig:176-227`
- Default URL seam: `src/cli.zig:20-21`
- Current no-args test: `src/cli.zig:86-89`
- Explicit URL tests: `src/cli.zig:97-131`
- URI validation contract: `src/uri.zig:5-20`
- Runtime URL handoff: `src/main.zig:37-47`
- JSON parse pattern: `src/ipc.zig:119-121`
- C ABI URL contract: `src/webkit_shim.h:30-32`
- Packaging pass-through: `packaging/release-build.sh:32`
