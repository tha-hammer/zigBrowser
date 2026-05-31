---
title: "Zig Browser — CEF Pivot: Hostile Audit + Vertical-Slice Re-Plan"
date: 2026-05-31
status: DRAFT — awaiting approval (no deletion/dispatch yet)
supersedes: thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1.md
engine_decision: CEF (Chromium Embedded Framework)
operating_laws:
  - "1. Visible-output gate: done = a human sees a real web page with real text in a window. Not tests-green."
  - "2. Vertical slices only: every slice is URL-in -> real-pixels-out, one real capability. No 'build the layer', no reserved seams, no spy-tested isolated subsystems."
  - "3. Audit before plan: hostile-audit verified reality before planning; plan against what the code does, not what the last plan claimed."
---

# CEF Pivot — Hostile Audit + Re-Plan

## Why we stopped
A review found the renderer is theater: it draws colored rectangles and calls them a web page.
Confirmed independently this session with file:line evidence (below). We stop building a custom
engine and **embed CEF (Chromium)**, building the Zig browser shell + product around it.

## Verified reality (audit, this session — not plan claims)

### The renderer never renders. It draws rectangles.
- `src/paint/raster.zig:29-42` — the ONLY drawing primitive is `drawRect()`. No glyph draw exists anywhere.
- `src/paint/text.zig` — "text" is `text.len * (font_size * 0.6)`. Zero font loading, zero glyph rasterization.
- `DejaVuSans.ttf` is **never read** — only `file.stat()`'d for existence (`snapshot_gate.zig:222-228`). The TTF is a prop.
- Approved baseline PNGs are **solid-color rectangles with no text**. The corpus gate diffs rectangles against rectangles — it validates a stub's internal consistency, not rendering.
- **Correction to my prior report:** the 0a "screenshot" I called a "human-visible artifact" produces a 1024×768 PNG of *rectangles*, not a rendered page. I verified the gate, not the pixels. That is exactly the failure law #1 closes.

### Layout lays out one blob, not a page.
- `src/page.zig:107-196` `buildRenderPipeline` flattens the **entire document into a single string** and builds **exactly two boxes** (one line, one block). No element-tree layout. `display`/`float` computed but never used in the pipeline. Lays out **zero** real pages correctly.

### CSS is a 14-property text splitter.
- `src/css/parser.zig` scans raw bytes; recognizes 14 property names; `@media`/`@keyframes`/`@supports` silently skipped; colors = 5 keywords + `#RRGGBB`; no `rgb()`/units/`%`/custom props. `cascade.zig` specificity/inheritance is real but starved (no UA stylesheet; compound selectors collapse).

### HTML/DOM/JS are subset + stub.
- `src/html/tokenizer.zig` — hand-rolled, no HTML5 state machine. `tree_builder.zig` — 6 hardcoded behaviors. The "html5lib" harness is **6 hand-authored cases checking tag-presence only** — not real conformance.
- `src/script/engine.zig` — `NoopEngine` is six **empty** functions; `runScript` discards its source. No JS engine.
- spikes: `quickjs` actually embedded real QuickJS-ng (started post-pivot-dispatch); `xs` is a pure-Zig simulation (no XS); `wasm` bridge present but the JS WASM blob isn't built. **All moot under CEF (V8 built in).**

### What is genuinely real (the salvage).
- `src/net/fetch.zig` — real curl HTTPS, real cert validation, real error mapping. **But CEF brings its own net stack → dead weight under CEF.**
- `src/net/url.zig` — real RFC 3986 via `std.Uri`. **Survives** as address-bar/CLI input validation.
- `src/cli.zig`, `src/errors.zig` — clean, real, backend-agnostic. **Survive.**
- `src/page.zig` arena-per-page + teardown lifecycle — sound **app-state scaffolding** around a CEF browser. Survives (gut the pipeline).

## Salvage / Delete manifest (requires approval)

### KEEP (salvage, ~15-20%)
| Path | Role under CEF |
|---|---|
| `src/cli.zig` | Entry point, command/flag parsing (`open <url>`, `--version`) |
| `src/errors.zig` | Error taxonomy; map to CEF load errors |
| `src/net/url.zig` (`parse`/`ParsedUrl`/`serialize`) | Validate/normalize the address-bar/CLI URL before handing to CEF |
| `src/page.zig` (arena + `navigate`/`teardown` lifecycle ONLY) | Per-tab app-state container around a `CefBrowser` |
| `src/main.zig` (dispatch + exit-code skeleton) | Gut `runInteractiveOpen`; keep structure |
| `tests/snapshots/pillow_tools.py`, `reapprove_snapshots.py`, `manifest.json` schema | Renderer-agnostic screenshot-diff harness (rebuild baselines from CEF output) |

### DELETE (theater / replaced by Chromium, ~80%)
`src/paint/**`, `src/layout/**`, `src/css/**`, `src/html/tokenizer.zig`, `src/html/tree_builder.zig`,
`src/render/screenshot.zig`, `src/net/fetch.zig`, `src/sdl_backend.zig`, `src/display.zig`,
`src/sdl2.h`, `src/platform/**`, `spikes/**`, `tests/snapshots/approved/*` (rectangle baselines),
`tests/html5lib/**`, `src/page.zig:buildRenderPipeline` and everything below it,
`src/script/engine.zig` NoopEngine (keep nothing — CEF has V8).

## CEF integration — honest reality
- CEF stable API is C++, but ships a **C API** (`include/capi/cef_*.h`) — translate-c friendly for Zig.
- **Multi-process:** `main` must call `cef_execute_process()` first to service helper subprocesses, then `CefSettings` → `cef_initialize` → create browser → message loop (`cef_run_message_loop` or pumped `cef_do_message_loop_work`).
- **Distribution is large** (~1GB incl. ICU/locales/resources); needs a helper executable and the resource dir alongside the binary.
- **Windowing:** fastest path to a real page = **native windowed** CEF (`CefWindowInfo`), not off-screen render. OSR (`OnPaint` bitmap) is the later path for custom compositing/screenshots.
- Linux-first; macOS CEF needs an app-bundle layout (defer).
- Prebuilt binaries: Spotify CEF automated builds / `cef-project`.

## Vertical slices (each: URL-in → real-pixels-out → human sees it)
**Slice 1 — A real page on screen.** Vendor the CEF Linux x64 binary distro; translate-c the C API; wire `main` (execute_process → initialize → create windowed browser → load CLI URL → message loop). Delete the fake stack (manifest above) as part of this slice. **Gate: `zigBrowser <url>` opens a Chromium window showing the real page with real text; capture a screenshot for the record.**

**Slice 2 — Navigation.** Address-bar input (reuse `url.zig` to validate) → load; back/forward/reload. **Gate: navigate between two real sites live.**

**Slice 3 — Tabs.** Multiple `CefBrowser` instances; map `page.zig` arena lifecycle to per-tab state. **Gate: two real pages in two tabs.**

**Slice 4 — The differentiator.** Whatever makes it *yours* (TBD with overseer) — the reason to build a shell at all.

## Sequencing / ownership (3 idle codex agents, on approval)
- Slice 1 is **not** parallelizable across 3 agents cleanly (single integration spine). Proposal: ONE agent drives CEF bring-up (the spine); a second prepares the salvage extraction + deletion (cli/url/errors/page-lifecycle isolation); the third vendors the CEF distro + build.zig translate-c/link. Coordinate `build.zig` + `main.zig` via the single-integrator discipline that worked last round.
- No spy-tested isolated subsystems (law #2). The only acceptance that counts is the visible page (law #1).

## STOP
This is a draft. **No files deleted, no swarm dispatched.** Awaiting approval of (a) the salvage/delete manifest and (b) the Slice-1 plan before any destructive action or dispatch.
