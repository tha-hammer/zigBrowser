---
title: "Zig Browser — WebKitGTK Pivot: Hostile Audit + Vertical-Slice Direction"
date: 2026-05-31
status: AUDIT COMPLETE — clean slate executed; formal re-plan pending (separate step)
supersedes: thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1.md
engine_decision: WebKitGTK (embedded WebKit via the GTK C API)
engine_history: "Considered CEF (Chromium Embedded); chose WebKitGTK — lighter, cleanest C/Zig fit, no manual helper-subprocess management, system-package dependency instead of a ~1GB distro."
clean_slate: "Executed. Custom-engine code removed at commit 20b741d; all prior code + WIP preserved at git tag archive/custom-engine-pre-webkit (snapshot b52e792)."
operating_laws:
  - "1. Visible-output gate: done = a human sees a real web page with real text in a window. Not tests-green."
  - "2. Vertical slices only: every slice is URL-in -> real-pixels-out, one real capability. No 'build the layer', no reserved seams, no spy-tested isolated subsystems."
  - "3. Audit before plan: hostile-audit verified reality before planning; plan against what the code does, not what the last plan claimed."
note: "This document is the hostile audit + engine direction that FEEDS the formal WebKitGTK plan. The formal re-plan is produced separately via the formal planning process."
---

# WebKitGTK Pivot — Hostile Audit + Direction

## Why we stopped
A review found the renderer is theater: it draws colored rectangles and calls them a web page.
Confirmed independently this session with file:line evidence (below). We stop building a custom
engine and **embed WebKitGTK** (real WebKit layout/text/JS via the GTK C API), building the Zig
browser shell + product around it.

## Verified reality (audit, this session — not plan claims)

### The renderer never renders. It draws rectangles.
- `src/paint/raster.zig:29-42` — the ONLY drawing primitive is `drawRect()`. No glyph draw exists anywhere.
- `src/paint/text.zig` — "text" is `text.len * (font_size * 0.6)`. Zero font loading, zero glyph rasterization.
- `DejaVuSans.ttf` is **never read** — only `file.stat()`'d for existence (`snapshot_gate.zig:222-228`). The TTF is a prop.
- Approved baseline PNGs are **solid-color rectangles with no text**. The corpus gate diffs rectangles against rectangles — it validates a stub's internal consistency, not rendering.
- **Correction to prior reporting:** the 0a "screenshot" called a "human-visible artifact" produces a 1024×768 PNG of *rectangles*, not a rendered page. We verified the gate, not the pixels. That is exactly the failure law #1 closes.

### Layout lays out one blob, not a page.
- `src/page.zig:107-196` `buildRenderPipeline` flattens the **entire document into a single string** and builds **exactly two boxes** (one line, one block). No element-tree layout. `display`/`float` computed but never used in the pipeline. Lays out **zero** real pages correctly.

### CSS is a 14-property text splitter.
- `src/css/parser.zig` scans raw bytes; recognizes 14 property names; `@media`/`@keyframes`/`@supports` silently skipped; colors = 5 keywords + `#RRGGBB`; no `rgb()`/units/`%`/custom props. `cascade.zig` specificity/inheritance is real but starved (no UA stylesheet; compound selectors collapse).

### HTML/DOM/JS are subset + stub.
- `src/html/tokenizer.zig` — hand-rolled, no HTML5 state machine. `tree_builder.zig` — 6 hardcoded behaviors. The "html5lib" harness is **6 hand-authored cases checking tag-presence only** — not real conformance.
- `src/script/engine.zig` — `NoopEngine` is six **empty** functions; `runScript` discards its source. No JS engine.
- spikes: `quickjs` actually embedded real QuickJS-ng; `xs` is a pure-Zig simulation (no XS); `wasm` bridge present but the JS WASM blob isn't built. **All moot under WebKitGTK (JavaScriptCore built in).**

### What was genuinely real (and what survives WebKitGTK).
- `src/net/fetch.zig` — real curl HTTPS, real cert validation, real error mapping. **But WebKitGTK does its own networking/TLS → dead weight under WebKit.**
- `src/net/url.zig` — real RFC 3986 via `std.Uri`. **Survives** as app-entry/CLI URI validation before `webkit_web_view_load_uri`.
- `src/cli.zig`, `src/errors.zig` — clean, real, backend-agnostic. **Survive.**
- `src/page.zig` arena-per-page + teardown lifecycle — sound **app-state scaffolding** around a `WebKitWebView`. Survives (gut the pipeline).

## Salvage / Delete manifest (clean slate already executed)
The clean slate is **done** — everything was removed at `20b741d` and preserved at tag
`archive/custom-engine-pre-webkit`. So "salvage" now means **cherry-pick these files back from the
tag** when rebuilding; "delete" means leave them in the archive only.

### CHERRY-PICK BACK (salvage, ~15-20%) — `git checkout archive/custom-engine-pre-webkit -- <path>`
| Path | Role under WebKitGTK |
|---|---|
| `src/cli.zig` | Entry point, command/flag parsing (`open <url>`, `--version`) |
| `src/errors.zig` | Error taxonomy; map to WebKit `load-failed` / `WebKitNetworkError` |
| `src/net/url.zig` (`parse`/`ParsedUrl`/`serialize`) | Validate/normalize app-entry/CLI URI input before `webkit_web_view_load_uri` |
| `src/page.zig` (arena + `navigate`/`teardown` lifecycle ONLY) | Per-tab app-state container around a `WebKitWebView` |
| `tests/snapshots/pillow_tools.py` schema/diff tooling | Renderer-agnostic screenshot-diff harness (rebuild baselines from `webkit_web_view_get_snapshot` output) |

### LEAVE IN ARCHIVE (theater / replaced by WebKit, ~80%)
`src/paint/**`, `src/layout/**`, `src/css/**`, `src/html/**`, `src/render/screenshot.zig`,
`src/net/fetch.zig`, `src/sdl_backend.zig`, `src/display.zig`, `src/sdl2.h`, `src/platform/**`,
`spikes/**`, the rectangle snapshot baselines, the 6-case "html5lib" harness, and
`src/page.zig:buildRenderPipeline` and everything below it.

## WebKitGTK integration — honest reality
- **C API, excellent Zig fit:** `libwebkit2gtk-4.1` (GTK3) or `libwebkitgtk-6.0` (GTK4); translate-c the public headers. pkg-config: `webkit2gtk-4.1` (or `webkitgtk-6.0`) pulls GTK + GLib cflags/libs.
- **Minimal embedding surface:** `gtk_init` → create a top-level window → `webkit_web_view_new()` → `gtk_window_set_child`/`gtk_container_add` → `webkit_web_view_load_uri(view, url)` → GTK main loop (`g_application_run` / `gtk_main`). That is a real page on screen.
- **No manual multi-process plumbing:** WebKitGTK spawns and manages its own Network/Web/GPU processes internally — unlike CEF, the embedder does **not** ship/launch a helper executable or call an `execute_process` entrypoint. Much smaller integration burden.
- **Networking/TLS/parse/layout/paint/JS** all inside WebKit (JavaScriptCore for JS — not V8). Confirms the custom net/render/parse/JS code is redundant.
- **Screenshots for the visible-output gate:** `webkit_web_view_get_snapshot()` returns a cairo surface (async) — a clean, first-class capture path (no off-screen-render plumbing needed).
- **JS/DOM access (later):** `webkit_web_view_evaluate_javascript()` + `WebKitUserContentManager` for script injection; `WebKitWebView` signals (`load-changed`, `load-failed`, `decide-policy`) for navigation hooks.
- **Dependency weight:** a system dev package (`libwebkit2gtk-4.1-dev`), not a ~1GB redistributable. Lighter than CEF.
- **Platform:** Linux/GTK-first. macOS would use `WKWebView` (different API surface) — defer; keep the engine behind a thin Zig seam so the macOS backend can swap in later.

## Vertical slices (each: URL-in -> real-pixels-out -> human sees it)
**Slice 1 — Real page on screen.** WebKitGTK window with `load_uri` and visible text.

**Slice 2 — App-shell control surface.** Navigation policy allow/block, app-owned sub-windows, and JS<->Zig IPC roundtrip. **Gate: protocol-observed `NAV/BLOCKED/SUBWIN/WINCOUNT/IPC/IPCERR`.**

**Slice 3 — Hardened app-shell UX/runtime.** Reload workflow, deterministic teardown/process hygiene, and policy/IPC error handling under interactive lifetime.

**Slice 4 — Full differentiator.** Expand host command surface and cross-OS backends (WebKitGTK/WebView2/WKWebView) behind one Zig app-shell model.

Tabs/address-bar/bookmarks are not active product commitments in this app-shell pivot.

## Sequencing / ownership (3 halted codex agents, on the formal plan's dispatch)
- Slice 1 is **not** parallelizable across 3 agents cleanly (single integration spine). Proposal: ONE agent drives WebKitGTK bring-up (the spine: `build.zig` translate-c/link + `main` window/webview/loop); a second cherry-picks + reintegrates the salvage (`cli`/`url`/`errors`/`page`-lifecycle); the third handles the `build.zig`/deps + the snapshot-capture gate harness around `get_snapshot`. Coordinate `build.zig` + `main.zig` via the single-integrator discipline that worked before.
- No spy-tested isolated subsystems (law #2). The only acceptance that counts is the visible page (law #1).

## Status / next step
- **Clean slate: DONE** — `20b741d` removed the custom-engine code; `archive/custom-engine-pre-webkit` (`b52e792`) preserves all prior code + WIP. Obsolete custom-engine beads closed.
- **Swarm: HALTED** — all three agents acknowledged the WebKitGTK + clean-slate direction; standing by.
- **Formal re-plan: PENDING (separate step)** — this audit + direction feeds the formal WebKitGTK plan produced via the formal planning process. No swarm dispatch until that plan is approved.
