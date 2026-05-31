---
title: "WebKitGTK Browser — Slice 1: real page in a real window (TDD)"
date: 2026-05-31
status: ready-for-implementation
type: tdd-plan
project: zigBrowser
engine: WebKitGTK (webkit2gtk-4.1 + GTK3)
zig_version: "0.16.0"
audit_source: thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md
archive_tag: archive/custom-engine-pre-webkit
laws:
  - "LAW 1 — real working software, no scaffolding: every behavior produces real, user-observable output."
  - "LAW 2 — hostile audit before planning: built against verified reality (below)."
  - "VISIBLE-OUTPUT GATE — every milestone ends in a human-observable artifact, not 'tests green'."
---

# WebKitGTK Browser — Slice 1 TDD Implementation Plan

## Overview

Build the **first real, working vertical slice** of the browser by **embedding WebKitGTK**
(webkit2gtk-4.1 + GTK3): a GTK top-level window hosts a `WebKitWebView` that loads a
CLI-provided URL and renders the **real page with real text** via real WebKit + JavaScriptCore.

This is a single end-to-end slice — **URL in → real pixels out** — not a layer. Every milestone
ends in a human-observable artifact: a version line produced by the linked library, a window
showing real text, a PNG of real text, a clean exit. Tests assert against **independent oracles**
(WebKit's own DOM parse + known `file://` fixtures + OS-level checks) — never against our own output.

## Current State Analysis (verified hostile audit — LAW 2)

This plan was built against what the box and tree **actually contain**, not prior claims.

### Key Discoveries
- **Clean slate is real:** `git ls-files | grep -E '\.(zig|h)$'` → **0 files**. Working tree is docs/config only (`docs/`, `specs/`, `Plans/`, `thoughts/`, `.beads`, `CLAUDE.md`).
- **WebKitGTK is actually installed and linkable here** (the decisive LAW-2 check): `pkg-config webkit2gtk-4.1` → **v2.52.3**, link line `-lwebkit2gtk-4.1 -lgtk-3 … -ljavascriptcoregtk-4.1`; header `/usr/include/webkitgtk-4.1/webkit2/webkit2.h`; `/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.1.so` dev symlink present. **Not a named-but-missing dependency.**
- **Version path forced by reality:** only **webkit2gtk-4.1 + GTK3 (3.24.49)** has a dev package. `gtk4` and `webkitgtk-6.0` dev are **absent** (only a runtime `libwebkitgtk-6.0.so.4`). → Target 4.1 + GTK3.
- **JavaScript is built in:** `-ljavascriptcoregtk-4.1` — no separate JS engine to vendor.
- **Display available:** `DISPLAY=:1` is set → a real window can open (visible-output gate achievable here).
- **Salvage verified real in tag `archive/custom-engine-pre-webkit`:** `src/net/url.zig:15-31` real `std.Uri.parse`/`resolveInPlace`/serialize; `src/cli.zig:14` clean `parseArgs` union; `src/errors.zig` `NetError` taxonomy; `src/page.zig` arena + ordered teardown; `build.zig.zon` zig-0.16 manifest (name `zigBrowser`, fingerprint preserved).
- **Toolchain:** zig 0.16.0 — `b.addTranslateC` + `linkSystemLibrary(use_pkg_config = .yes)` is the build path.

### Hard-but-essential realities kept IN SCOPE (LAW 1 — not dropped)
- `translate-c` must digest the macro-heavy `webkit2/webkit2.h` (pulls GTK/GLib/GObject). Confirmed in M1.
- **`g_signal_connect`, `G_CALLBACK`, `GTK_WINDOW`, `WEBKIT_WEB_VIEW` are C macros that zig `translate-c` does NOT expose.** Embedding must call `g_signal_connect_data` and do GObject pointer casts directly, with `callconv(.C)` callbacks. This is the single most likely place a naive plan silently fails — it is an explicit behavior here.
- `webkit_web_view_get_snapshot` is **async** — always await the `load-changed` `FINISHED` state before snapshot/title.

## Desired End State

`zigBrowser <url>` opens a GTK window rendering the real page with real text; `zigBrowser
--screenshot out.png <url>` writes a PNG of the real rendered text; closing the window exits 0
cleanly; bad URLs surface real errors without crashing.

### Observable Behaviors
1. `zigBrowser --version` → real `WebKitGTK 2.52.3, GTK 3.24.49` printed from the linked libs.
2. `zigBrowser file://…/live.html` → a window shows the real page (real text).
3. Closing the window → process exits 0, no orphaned WebKit helpers.
4. `zigBrowser --screenshot out.png file://…/live.html` → an openable PNG of real text.
5. Bad URL → real stderr error / WebKit error page, non-zero exit, no bogus PNG.

## What We're NOT Doing (later vertical slices)
Address bar + interactive navigation, back/forward/reload, tabs (`GtkNotebook` + multi-WebView),
the product differentiator, and the macOS/`WKWebView` backend (a thin Zig seam is left in M2 so it
can be added later). No custom rendering/layout/CSS/HTML/JS — WebKit owns all of that.

## Salvage Manifest (cherry-pick from the archive tag, then adapt)
```bash
git checkout archive/custom-engine-pre-webkit -- \
  src/cli.zig src/net/url.zig src/errors.zig src/page.zig build.zig.zon
```
- `cli.zig` — `parseArgs` entry (repurpose the `.screenshot` arm to WebKit `get_snapshot`).
- `url.zig` — validate/normalize the URL before `webkit_web_view_load_uri`.
- `errors.zig` — `NetError` taxonomy; map WebKit `load-failed` codes onto it.
- `page.zig` — arena + ordered teardown as the per-window state container.
Everything else stays archived (not restored).

## Testing Strategy
- **Framework:** Zig 0.16 built-in test runner (`zig build test`) for unit behaviors; a **spawn-the-real-binary E2E harness** (under `DISPLAY=:1`, Xvfb in CI) for window/render/screenshot/quit/bad-url.
- **Test types:** UNIT — `url.zig` vectors, `cli.parseArgs`, `--version` composition from `webkit_get_*_version`. E2E — load `file://` fixtures, await WebKit `FINISHED`, assert `get_title()`==fixture title + snapshot PNG non-uniform; exit codes; orphaned-process check.
- **Independent oracles only:** WebKit's own `get_title`/`get_snapshot` + the known fixture + OS checks. **No self-referential tests** (we never assert our output against our own output).
- **Fixtures:** `tests/fixtures/live.html` (`<title>WebKitGTK Live</title>`, `<h1>Hello Real Text</h1>`) — deterministic, no network.
- **Build:** `addTranslateC(webkit2/webkit2.h)` + `linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes })`, no hardcoded paths; build fails loudly if pkg-config is absent.

---

## Behavior 1: link-proof-version  (bootstraps project + build + salvage)

### Test Specification
**Given**: webkit2gtk-4.1 (v2.52.3) + GTK3 installed; the build translate-c's `webkit2.h` and links via pkg-config.
**When**: `zigBrowser --version`.
**Then**: prints a real version line whose numbers come **from the linked libraries** — e.g. `zigBrowser — WebKitGTK 2.52.3, GTK 3.24.49` (via `webkit_get_major/minor/micro_version` + `gtk_get_major/minor/micro_version`), exit 0.

**Edge Cases**: build fails loudly if `pkg-config webkit2gtk-4.1` absent (no silent fallback); print **runtime** version (may differ from build-time header); `--version` with trailing args still prints.

**Files touched**: `build.zig.zon` (from tag), `build.zig` (new), `src/webkit.zig` (new — the single C-import module), `src/cli.zig` (from tag), `src/errors.zig` (from tag), `src/main.zig` (new), `tests/version_test.zig` (new). Healthy blast radius (project bootstrap).

### TDD Cycle
#### 🔴 Red
**File**: `tests/version_test.zig` (+ an E2E assertion script)
```zig
// Unit: the version line is composed from the lib getters, not a literal.
test "version string is sourced from linked webkit/gtk getters" {
    const v = @import("../src/webkit.zig").versionLine(std.testing.allocator);
    defer std.testing.allocator.free(v);
    // webkit_get_major_version() is comptime-unknowable → must be >0 at runtime
    try std.testing.expect(std.mem.indexOf(u8, v, "WebKitGTK ") != null);
    try std.testing.expect(std.mem.indexOf(u8, v, "GTK ") != null);
}
```
E2E: `zig build && ./zig-out/bin/zigBrowser --version` exits 0 and stdout contains `WebKitGTK ` + `GTK `. Fails: no project/binary yet.

#### 🟢 Green
- `build.zig.zon` from tag; `build.zig`: `const wk = b.addTranslateC(.{ .root_source_file = b.path("src/webkit2.h") , ... });` (`webkit2.h` = `#include <webkit2/webkit2.h>`), `exe.root_module.addImport("c", wk.createModule()); exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes });`
- `src/webkit.zig`: `pub const c = @import("c");` + `pub fn versionLine(a) []u8` calling `c.webkit_get_major_version()` etc. and `c.gtk_get_major_version()`.
- `src/cli.zig`, `src/errors.zig` from tag; `src/main.zig` dispatch `.version` → print `versionLine`.

#### 🔵 Refactor
All WebKit/GTK C access funnels through `src/webkit.zig` (deep module; the rest of the code never imports `c` directly). Assert (in code review) the version numbers are getter-derived, not string literals. Confirm `translate-c` digested `webkit2.h` cleanly.

### Success Criteria
**Automated:** Red fails for the right reason (no binary); `zig build` succeeds and links webkit2gtk-4.1 (`ldd zig-out/bin/zigBrowser | grep webkit2gtk-4.1`); `zig build test` green.
**Manual / VISIBLE ARTIFACT:** real stdout `zigBrowser — WebKitGTK 2.52.3, GTK 3.24.49` from a genuinely-linked binary. **ORACLE:** printed versions == `pkg-config --modversion webkit2gtk-4.1` and `gtk+-3.0`.

---

## Behavior 2: real-page-in-window

### Test Specification
**Given**: `tests/fixtures/live.html` (`<title>WebKitGTK Live</title>`, `<h1>Hello Real Text</h1>`) and `DISPLAY=:1`.
**When**: `zigBrowser file:///abs/tests/fixtures/live.html`.
**Then**: a GTK top-level window opens hosting a `WebKitWebView` that renders the **real page with real text glyphs**, after the `load-changed` `FINISHED` signal.

**Edge Cases**: `DISPLAY` unset → fail loudly (clear message, not a silent no-window); missing fixture → WebKit `load-failed` surfaced; no `<title>` → still renders (title oracle falls back to body innerText); **await `FINISHED` before asserting** (no race); macros → `g_signal_connect_data` + GObject casts + `callconv(.C)`.

**Files touched**: `src/webkit.zig` (web view + window + signal wiring), `src/main.zig` (`.open` path). Two files — healthy.

### TDD Cycle
#### 🔴 Red
**File**: `tests/e2e/window_test.zig` (spawns the binary)
```
DISPLAY=:1 ./zig-out/bin/zigBrowser file:///abs/tests/fixtures/live.html &
# harness waits for FINISHED, then queries title via a test hook / the --screenshot title capture
assert get_title == "WebKitGTK Live"
```
Fails: no window code.

#### 🟢 Green (real embedding — the hard part, in scope)
```zig
// src/webkit.zig (sketch — real calls, macros expanded manually)
_ = c.gtk_init_check(0, null);
const win = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);          // GTK_WINDOW_TOPLEVEL is an enum const (ok)
const view = c.webkit_web_view_new();                          // returns *GtkWidget
_ = c.g_signal_connect_data(view, "load-changed", @ptrCast(&onLoadChanged), null, null, 0); // macro→_data
c.gtk_container_add(@ptrCast(win), view);                      // GTK_CONTAINER cast = pointer cast
c.webkit_web_view_load_uri(@ptrCast(view), url_z);             // WEBKIT_WEB_VIEW cast
c.gtk_widget_show_all(win);
c.gtk_main();
// fn onLoadChanged(view, load_event, user) callconv(.C) void { if (load_event == FINISHED) {...} }
```
`src/main.zig` `.open` → validate URL (B5 salvage) → `webkit.openWindow(url)`.

#### 🔵 Refactor
Extract a thin `WebView`/`Window` seam in `src/webkit.zig` (all GTK/WebKit calls live here) so a future macOS `WKWebView` backend swaps in behind the same Zig interface. No logic duplicated with M4's load path.

### Success Criteria
**Automated:** E2E asserts `get_title()` == `"WebKitGTK Live"`; snapshot PNG non-uniform.
**Manual / VISIBLE ARTIFACT:** a real GTK window on `:1` showing **Hello Real Text** + a `get_snapshot` PNG. **ORACLE:** `webkit_web_view_get_title()` (WebKit's real parse of the known fixture) + non-uniform text pixels — both WebKit-produced, checked vs the fixture.

---

## Behavior 3: clean-quit

### Test Specification
**Given**: the window is open and a page has loaded.
**When**: the user closes the window (`destroy` signal).
**Then**: `gtk_main` returns, the process exits 0, WebKit Network/Web helper processes are reaped — no hang, no crash, no zombies.

**Edge Cases**: close before load finishes; double-close / destroy during snapshot; SIGINT/SIGTERM mid-load also exits cleanly; no orphaned `WebKitNetworkProcess`/`WebKitWebProcess`.

**Files touched**: `src/webkit.zig` (destroy wiring + teardown), `src/page.zig` (from tag — lifecycle).

### TDD Cycle
#### 🔴 Red
E2E: launch, wait for load, send window close (or `xdotool`/`gtk` destroy), assert `exit code == 0` AND `pgrep -P <pid>` empty after exit. Fails: hangs / no quit wiring.
#### 🟢 Green
`_ = c.g_signal_connect_data(win, "destroy", @ptrCast(&c.gtk_main_quit), null, null, 0);` `main` returns 0 after `gtk_main`. Ensure the `WebKitWebContext` disposes so helpers exit.
#### 🔵 Refactor
Adopt salvaged `page.zig` arena + ordered teardown as the per-window state container; teardown runs in a `defer` chain in the documented order.

### Success Criteria
**VISIBLE ARTIFACT:** shell prompt returns with exit 0 after close; no zombie WebKit helpers. **ORACLE:** exit code 0 + clean process table (independent OS check).

---

## Behavior 4: headless-screenshot

### Test Specification
**Given**: `tests/fixtures/live.html` and `--screenshot out.png <url>`.
**When**: `zigBrowser --screenshot /tmp/live.png file:///abs/tests/fixtures/live.html`.
**Then**: loads the real page, awaits `FINISHED`, calls `webkit_web_view_get_snapshot`, writes a real PNG of the rendered page (with real text) to `out.png`, exits 0.

**Edge Cases**: unwritable path → `error.WriteFailed`, non-zero exit, no partial file; snapshot before `FINISHED` must wait (async cb); async snapshot error → clean failure; offscreen/unmapped window path when no DISPLAY.

**Files touched**: `src/webkit.zig` (snapshot + async cb + cairo PNG write), `src/main.zig` (`.screenshot` path), `tests/snapshots/pillow_tools.py` (salvage — assertion helper).

### TDD Cycle
#### 🔴 Red
E2E: run `--screenshot`, assert PNG decodes to expected dims, is non-blank, and the captured title == fixture title. Fails: no screenshot path.
#### 🟢 Green
`.screenshot` → load + await `FINISHED` → `c.webkit_web_view_get_snapshot(view, FULL_DOCUMENT, NONE, null, &onSnapshot, ctx)`; in finish cb `webkit_web_view_get_snapshot_finish` → `cairo_surface_t*` → `cairo_surface_write_to_png(surface, tmp)`; atomic temp+rename with `defer` cleanup; map errors → exit codes (0 ok / 1 url / 2 load / 3 snapshot / 4 write).
#### 🔵 Refactor
Share the load-then-act flow with M2 (one `loadThen(url, action)` in `webkit.zig`). Reuse salvaged `pillow_tools.py` (`diff`/non-uniformity) for the harness assertion.

### Success Criteria
**VISIBLE ARTIFACT:** an openable PNG showing the real page with readable text. **ORACLE:** PNG non-uniform with text-like pixels + captured `get_title()` == fixture — WebKit produced both.

---

## Behavior 5: bad-url-real-error

### Test Specification
**Given**: a malformed URL (`http://`) or unreachable host (`http://127.0.0.1:9/`).
**When**: `zigBrowser <bad-url>` or `--screenshot out.png <bad-url>`.
**Then**: malformed → rejected up front by salvaged `url.zig` (clear stderr, non-zero exit, no window/PNG); unreachable → WebKit's real `load-failed` surfaced as a clean stderr message / WebKit error page in-window; never crashes; writes no bogus PNG.

**Edge Cases**: non-http(s) scheme (`ftp://`, `javascript:`) rejected by `url.zig` before load; TLS/cert failure → `load-failed` TLS error; DNS failure → `load-failed`; `--screenshot` on failed load writes **no** file.

**Property**: `parse(serialize(x)) == x` for all valid URLs (property test on salvaged `url.zig`); all non-http(s)/malformed inputs → `error.InvalidUrl` (never a panic, never a load).

**Files touched**: `src/url.zig` (from tag), `src/main.zig` (validate-before-load), `src/webkit.zig` (`load-failed` cb → `errors.zig` map), `tests/url_test.zig`.

### TDD Cycle
#### 🔴 Red
Unit: `url.zig` rejects `http://`, `ftp://x`, `javascript:alert(1)` → `error.InvalidUrl`. E2E: `zigBrowser http://127.0.0.1:9/` exits non-zero, prints a real network error, opens no PNG. Fails: crash/silent.
#### 🟢 Green
Cherry-pick `url.zig`; in `main` parse+normalize, reject non-http(s)/malformed → stderr + non-zero exit before any window/load. `g_signal_connect_data(view, "load-failed", &onLoadFailed, …)` → map `WebKitNetworkError` via `errors.zig` → stderr; `--screenshot` writes nothing on failure.
#### 🔵 Refactor
Unify error surfacing (one `reportError(NetError)`); map WebKit error domains onto `errors.zig` taxonomy.

### Success Criteria
**VISIBLE ARTIFACT:** real stderr error message (and WebKit's real error page in-window); non-zero exit; no bogus PNG. **ORACLE:** `url.zig` `std.Uri` vectors (malformed) + WebKit's real `load-failed` `WebKitNetworkError` (unreachable) — both independent of our code.

---

## Integration & E2E Testing
- **Integration:** the `loadThen(url, action)` flow shared by window-display (M2) and screenshot (M4), each awaiting `FINISHED`.
- **E2E user flows:** (a) `zigBrowser <file-url>` → window with real text; (b) close → exit 0; (c) `--screenshot` → PNG of real text; (d) bad URL → real error, no PNG. Run under `DISPLAY=:1` locally, **Xvfb** in CI.
- **CI note:** install `libwebkit2gtk-4.1-dev` + `libgtk-3-dev`; run E2E under `xvfb-run`. (CI workflow is a later slice; flagged here.)

## Risks & Mitigations
| Risk | Mitigation |
|---|---|
| `translate-c` chokes on macro-heavy `webkit2.h` | Prove it compiles in M1 (the bootstrap slice); isolate all C in `src/webkit.zig` |
| `g_signal_connect`/cast macros not exposed | Call `g_signal_connect_data` + GObject pointer casts directly; `callconv(.C)` callbacks — explicit in M2 |
| async `get_snapshot` race | Always await `load-changed` `FINISHED` before snapshot/title (M2/M4) |
| headless CI (no DISPLAY) | Xvfb; offscreen/unmapped window fallback for `--screenshot` |
| orphaned WebKit helper processes | Dispose `WebKitWebContext`; assert clean process table (M3) |

## References
- Audit + engine direction: `thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md`
- Salvage source: git tag `archive/custom-engine-pre-webkit` (`src/cli.zig`, `src/net/url.zig:15-31`, `src/errors.zig`, `src/page.zig`, `build.zig.zon`)
- WebKitGTK API: `webkit_web_view_new`, `webkit_web_view_load_uri`, `webkit_web_view_get_title`, `webkit_web_view_get_snapshot`/`_finish`, signals `load-changed`/`load-failed`; GTK3 `gtk_init`/`gtk_window_new`/`gtk_main`/`gtk_main_quit`; `g_signal_connect_data`.
- Toolchain: zig 0.16 `b.addTranslateC` + `linkSystemLibrary(.{ .use_pkg_config = .yes })`.
