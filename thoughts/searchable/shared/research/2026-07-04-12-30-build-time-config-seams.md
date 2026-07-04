---
date: 2026-07-04T12:30:00-05:00
researcher: FrostyGrove
git_commit: af2e4c3
branch: master
repository: zigBrowser
topic: "Build-time configuration seams for JSON site config ingestion"
tags: [research, codebase, build-system, configuration, cli, build.zig]
status: complete
last_updated: 2026-07-04
last_updated_by: FrostyGrove
---

# Research: Build-time Configuration Seams for JSON Site Config Ingestion

**Date**: 2026-07-04T12:30:00-05:00
**Researcher**: FrostyGrove
**Git Commit**: af2e4c3
**Branch**: master
**Repository**: zigBrowser

## Research Question

The app loads a single web app/SPA/site with no address bar. A JSON configuration file should be ingested at build time to designate the target site and future config. What are the existing seams, interfaces, and contracts where this config could be introduced?

## Summary

The codebase currently has **no build-time configuration mechanism** for the target URL. The default site is a hardcoded string literal in `src/cli.zig:21`. There are three natural seams where a JSON config file can be introduced at build time:

1. **`build.zig` → `@embedFile` / `b.addOptions()`** — the build script can read a JSON file and either embed it as a comptime string or generate a `build_options` module with extracted fields.
2. **`src/cli.zig` default URL** — the consumer of whatever build-time value replaces the current hardcoded `"https://cosmic-hr-development.up.railway.app/"`.
3. **C ABI entry points** (`zb_app_run`, `zb_run_open`, `zb_run_screenshot`) — the `const char *uri` parameter these functions accept is the final handoff point; whatever produces the URL at compile time must flow through this unchanged interface.

## Detailed Findings

### 1. Current Default URL — The Primary Seam

| Property | Value |
|---|---|
| File | `src/cli.zig:21` |
| Current value | `"https://cosmic-hr-development.up.railway.app/"` |
| When used | Process invoked with no CLI arguments (`args.len <= 1`) |
| Test coverage | `src/cli.zig:86-89` asserts this exact string |

This is the **single point** where a build-time config would take effect. When no URL argument is supplied, the app opens this hardcoded default. The app's design as a "single-site browser" means this default IS the app's identity.

### 2. Build Script (`build.zig`) — No Config Ingestion Exists

The build script currently:
- Resolves the backend from target OS (line 230-236)
- Accepts 3 `b.option()` calls, all for WebView2 SDK paths on Windows (lines 109-123)
- Creates `root_module` with `src/main.zig` as root source (line 141)
- Does **not** call `b.addOptions()` to create a generated options module
- Does **not** use `@embedFile` anywhere
- Does **not** read any JSON/TOML/config file

Available Zig build-system mechanisms for config injection:

| Mechanism | How it works | Seam in current code |
|---|---|---|
| `b.addOptions()` + `exe.root_module.addOptions()` | Generates a `build_options` module importable as `@import("build_options")` with typed fields | Would insert between lines 146-148 (after `configureBackend`, before `addExecutable`) |
| `@embedFile("path")` | Embeds file contents as a comptime `[]const u8` at compile time; build.zig can make the path a `b.option` | Would be consumed in `src/cli.zig` or a new `src/config.zig` |
| `b.option()` + string passthrough | Pass URL as `-Dsite_url=...` from CLI | Would add a new `b.option` at line ~109 |

### 3. CLI Layer (`src/cli.zig`) — The Consumer Seam

```zig
// src/cli.zig:20-21
pub fn parseArgs(args: []const []const u8) Command {
    if (args.len <= 1) return .{ .open = .{ .url = "https://cosmic-hr-development.up.railway.app/" } };
```

This function returns a `Command` union. The `.open` variant carries:
```zig
open: struct {
    url: []const u8,
    print_title: bool = false,
    e2e_protocol: bool = false,
},
```

The `url` field is the sole data path for "what site to load". A build-time config would replace the hardcoded string with a comptime-resolved value (from `@embedFile` parse or `@import("build_options").default_url`).

### 4. C ABI Contract — Downstream, Unchanged

The URL flows from Zig through these C entry points:

```c
// src/webkit_shim.h:30-31
int zb_run_open(const char *uri, int print_title);
int zb_app_run(const char *uri, int print_title, int e2e_protocol);
int zb_run_screenshot(const char *uri, const char *out_path, int print_title);
```

Called from `src/main.zig:43-47`:
```zig
const code = webkit.c.zb_app_run(
    valid_uri.ptr,
    if (spec.print_title) 1 else 0,
    if (spec.e2e_protocol) 1 else 0,
);
```

This contract does not need to change — the config system produces a URL string; the downstream ABI consumes it identically.

### 5. URI Validation (`src/uri.zig`) — Constraint on Config Values

```zig
// src/uri.zig:12-18 (scheme allowlist)
if (std.mem.eql(u8, parsed.scheme, "http") or std.mem.eql(u8, parsed.scheme, "https")) {
    if (parsed.host == null) return error.InvalidUri;
} else if (std.mem.eql(u8, parsed.scheme, "about")) {
    // pass through
} else if (!std.mem.eql(u8, parsed.scheme, "file")) {
    return error.UnsupportedScheme;
}
```

Any URL in the JSON config must satisfy: scheme is `http`, `https`, `file`, or `about`; and `http`/`https` must have a host. This is a runtime validation — a build-time config could optionally validate at compile time too.

### 6. Navigation Policy (`src/nav_policy.zig`) — Derived from URL

`app_base` is computed from the loaded URL at runtime in each backend shim (`derive_app_base` in `webkit_shim.c:978` and `wkwebview_shim.m:171`). It gates navigation decisions. A JSON config that specifies navigation policy overrides (allowed domains, etc.) would interact with this system, but the current `app_base` derivation requires no build-time input — it's purely a function of the URL loaded.

### 7. `app.zig` — Library-style Mirror Entry

`src/app.zig` provides a `pub fn run(arena, command)` that mirrors `main.zig`'s logic. It's an alternative entry path consuming the same `cli.Command` type. Any config change to `cli.zig` propagates here automatically.

### 8. Packaging Scripts — Build Invocation Points

| Script | Invocation | Config injection point |
|---|---|---|
| `packaging/release-build.sh:32` | `zig build -Doptimize=ReleaseSafe "$@"` | Extra args passthrough via `"$@"` |
| `tests/mac/build-on-mac.sh` | `zig build` | Would need `-D` flags or env vars |
| `tests/guest/build-in-guest.sh` | Guest VM build | Same |

All packaging scripts pass through to `zig build`. A `-Dconfig=path/to/config.json` option would propagate naturally.

### 9. Existing JSON Parsing Capability

The codebase already uses `std.json` in `src/ipc.zig`:
- `std.json.parseFromSlice` (line 80, 97)
- `std.json.parseFromSliceLeaky` with typed struct target (line 119-121)

This demonstrates the pattern for parsing a config struct from JSON at comptime or runtime.

## Code References

- `build.zig:105-153` — Main build function; insertion point for config ingestion
- `build.zig:140-146` — Module creation; where `addOptions()` would go
- `src/cli.zig:21` — Hardcoded default URL (the value to replace)
- `src/cli.zig:3-18` — `Command` union type (the shape config feeds into)
- `src/main.zig:37-48` — Where `Command.open.url` flows to the C backend
- `src/webkit_shim.h:30-31` — C ABI accepting the URL string
- `src/uri.zig:5-21` — URI validation constraints
- `src/nav_policy.zig:24-38` — Navigation policy consuming `app_base`
- `src/ipc.zig:119-121` — Existing typed JSON parse pattern
- `packaging/release-build.sh:32` — Build invocation passthrough

## Architecture Documentation

### Data Flow: URL from config to window load

```
[JSON config file] (new; does not exist yet)
       │
       ▼ (build.zig reads at build time)
[build_options module OR @embedFile blob]
       │
       ▼ (comptime import in cli.zig or config.zig)
[cli.parseArgs default return value]
       │
       ▼ (main.zig switch on .open)
[uri.validate(arena, spec.url)]
       │
       ▼ (FFI call)
[webkit.c.zb_app_run(valid_uri.ptr, ...)]
       │
       ├──► GTK: webkit_web_view_load_uri(view, uri)
       └──► macOS: [WKWebView loadRequest:[NSURLRequest requestWithURL:url]]
```

### Zig Build System Mechanisms Available

| Mechanism | Compile-time? | Can parse JSON? | Supports future fields? |
|---|---|---|---|
| `b.addOptions()` | Yes | Must extract fields in build.zig | Each field is a separate typed option |
| `@embedFile` + comptime parse | Yes | Yes, `std.json.parseFromSlice` works at comptime | Entire struct, extensible |
| `b.option()` CLI flag | Yes | No (string only) | One flag per field |
| Runtime file read | No | Yes | Fully extensible |

## Open Questions

1. **Comptime vs runtime parse**: Should the JSON be parsed at comptime (baked into the binary, zero runtime overhead, but requires rebuild to change) or at runtime (read from a well-known path at startup)?
2. **Config schema**: Beyond `url`, what future fields are anticipated? (window title, dimensions, navigation policy overrides, IPC permissions, icon path, etc.)
3. **Config file location convention**: Project root `zigbrowser.json`? XDG config path? Alongside the binary?
4. **Per-backend overrides**: Should the config support backend-specific fields (e.g., macOS-only window chrome settings)?
