---
title: "Zig Browser Post-v1 Roadmap — Detailed TDD Plan (Tier 1 + v2a; v2b→v3 outline)"
date: 2026-05-30
status: revised   # major revision applied per PlanReview 2026-05-30 (8 critical + 45 warnings resolved via §C2)
type: tdd-plan
project: zigBrowser
zig_version: "0.16.0"
companion_docs:
  - Plans/TDD_IMPLEMENTATION_PLAN.md                                            # high-level v1 plan
  - Plans/JS_ENGINE_STRATEGY.md                                                 # v4 — scripting authority (L1–L4, §10 phasing)
  - thoughts/searchable/shared/plans/2026-05-30-14-58-ENG-0001-tdd-zig-browser-v1.md  # v1 detailed plan + §C Canonical Contracts
precedence: "Companion to the v1 detailed plan. Scripting decisions defer to JS_ENGINE_STRATEGY.md. Shared types/signatures reuse the v1 plan's §C Canonical Contracts — referenced, not duplicated."
scope: "Tier 1 (0a→3) and Tier 2 v2a (spikes + decision gate) are DETAILED as Red-Green-Refactor cycles. v2b→v3 are OUTLINE-only — they depend on the engine-decision-gate outcome."
beads: "Pipeline run started without --mint; beads minted separately after write (no --mint-restart)."
review:
  source: thoughts/searchable/shared/plans/2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1-REVIEW.md
  status: "all 8 critical + 45 warning findings addressed (see §C2 Canonical Contracts + per-cycle notes + Review Resolution table)"
---

# Zig Browser Post-v1 Roadmap — Detailed TDD Plan

## Overview

v1 (Phases 0–8) is built: a real, headless **fetch → parse → cascade → layout → rasterize** pipeline.
This plan is the **executable, code-writing plan for what comes next** — the post-v1 roadmap — written
to the same Red→Green→Refactor discipline as the v1 detailed plan.

**The #1 deliverable is making the browser actually display a page.** Verified against the code: today
there is *no way for a human to see a rendered page* — `build.zig` links no windowing library, `window.zig`
is pure math, and `main.zig` renders a framebuffer in the arena and discards it (keeps only a `u64`
checksum). "Test the browser" is impossible as a user until this is fixed, so it leads.

**Scope discipline:** Tier 1 (0a→3) and Tier 2 **v2a** (spikes + decision gate) are fully detailed.
**v2b→v3 are outline-only** — they are downstream of the engine choice the v2a gate produces; detailing
them now would be speculative rework.

**Core principle (non-negotiable):** No production code without a failing test that demands it. No skipping Red.

## Current State Analysis (verified against the code, this session)

### Real and reusable
- **JS seams are real, typed stubs.** Full 6-method `ScriptEngine` vtable (`src/script/engine.zig:10-17`): `stopScript / severHandles / drainFinalizers / teardownIsolate / runScript([]const u8) / pumpMicrotasks`; `NoopEngine` fully wired. `Node.script_wrapper: ?WrapperRef = null` present on every node (`src/html/dom.zig`); `WrapperRef{index,generation}` defined. **No handle table, no engine yet** — exactly the v2 work.
- **Teardown order correct** (`src/page.zig:92-104`): `stopScript → severHandles → drainFinalizers → arena.deinit() → teardownIsolate`.
- **Microtask pump call site** exists in `src/platform/event_loop.zig:42` (`engine.pumpMicrotasks()` once per `runTurn`).
- **Net does real HTTPS** (`src/net/fetch.zig:20-72`) via a **`curl` subprocess** (not the libcurl C API), cert validation on by default (no `--insecure`), maps exit 51/60 → `error.CertInvalid`, `--max-time 5`.
- **Render-to-PNG already exists** in test-only `src/paint/snapshot_gate.zig` (`renderNavigatedPageArgb` :111, `exportArgbPng` :177) — reusable for the 0a stopgap.
- **Real corpus data on disk & git-tracked:** 50 `tests/corpus_pages/*.html`, 50 `tests/corpus_css/*.css`, `tests/snapshots/manifest.json` (50 pages), 50 approved PNGs under `tests/snapshots/approved/`, `tests/fonts/DejaVuSans.ttf` (742KB).

### Confirmed gaps (this plan's targets)
- **No display path** (Tier 1·0). Zero SDL/FreeType/HarfBuzz in `build.zig`; only a **hard-coded** `const curl_object = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libcurl.so.4" }` (`build.zig:7`) — Linux-only, breaks macOS. `window.zig` never instantiated in `main`; `event_loop.runTurn` never called from `main`; `main.zig:17-21` `.open` path renders then returns, discarding pixels.
- **macOS unproven** (Tier 1·1). No `.github/workflows`; hard-coded Linux `.so` path guarantees a macOS break.
- **Conformance partly hollow** (Tier 1·3):
  - html5lib tree-construction gate is **REAL** (`src/html/tree_builder.zig:426` loads `tests/html5lib/tree_construction_curated.json`, 6 cases, asserts).
  - **Harness aggregator is hollow:** `tests/harness/root.zig` is only `test "harness scaffold sanity" { try std.testing.expect(true); }`. The git-tracked `tests/harness/wpt_subset.json` and `tests/harness/html5lib_subset.json` are **orphaned — loaded by nothing.**
  - **Dead loaders:** `tests/html5lib/html5lib_loader.zig` and `css_corpus_loader.zig` are imported by no build step — never run.
  - **Corpus/90% gate is CONDITIONAL-HOLLOW:** `src/paint/snapshot_gate.zig:28,63` `return error.SkipZigTest` when python3/curl/**Pillow** absent → passes vacuously on any machine without Pillow.
- **SDL2 absent on the dev box** (`pkg-config` has no `sdl2`, no `/usr/include/SDL2/SDL.h`) → 0b needs `libsdl2-dev`; reinforces leading with the 0a screenshot stopgap.

## Desired End State

A browser you can **run and watch render a page** (0a: a PNG; 0b: a live scrollable window), that **builds
and tests green on Linux and macOS in CI**, whose **conformance gates actually assert on real data**, that
**renders live sites without crashing**, and that has a **data-backed decision** on which JS engine and
delivery model (native vs WASM) v2 will build on.

### What We're NOT Doing (this plan)
- Detailing v2b (handle table + 5 WebIDL interfaces), v2c (WebIDL→Zig codegen), or v3 (end-state JSC/WASM) — outline only, pending the engine-decision-gate.
- Growing the WPT/html5lib subsets (Tier 1·3 is *wire what exists*, not *expand coverage*).
- Replacing the curl-subprocess fetch with the libcurl C API (works today; out of scope).
- Flexbox/grid, GPU compositing, multi-process sandbox (still v1 hard-NOs).

## Testing Strategy

- **Framework:** Zig 0.16 built-in runner — `zig test` + colocated `test` blocks, `std.testing` asserts, `std.testing.allocator` (leak gate; also the spike no-leak mechanism), `std.testing.io` for fixture/network.
- **SDL2:** `b.addTranslateC(SDL2/SDL.h)` + `module.linkSystemLibrary("SDL2", .{.use_pkg_config = .yes})` on Linux / `linkFramework("SDL2", .{})` on macOS. **No hard-coded paths** (libcurl moves to the same portable resolution).
- **Display behind an injectable vtable interface** so all pixel logic is unit-tested via **`NullDisplay`** (captures pixels, zero SDL); only the thin **`SdlDisplay` + `SDL_PollEvent` shell** is untested. Headless CI exercises SDL init via `SDL_VIDEODRIVER=dummy`.
- **Test types:** UNIT (Display via NullDisplay, scroll/hit-test/teardown spies, conformance data-driven, render-module extraction keeps snapshot tests green); INTEGRATION (screenshot PNG decodes, corpus/90% gate made fail-loud, html5lib/wpt subset assertions, spike button-churn lifecycle); E2E/SHELL (thin SdlDisplay+poll loop, minimal); SMOKE (opt-in, non-deterministic — live sites, skip when offline, never a pass/fail gate).
- **Spike acceptance** reuses the v1 plan's **§C button-churn no-leak/no-UAF generational-handle test**.
- TDD loop: `zig build test --watch -fincremental`.

## §C Carry-forward

Shared types/signatures (handle table shape, `ScriptEngine` vtable, generational `WrapperRef`, teardown
ordering, error sets) are defined in the **v1 plan's §C Canonical Contracts**
(`…ENG-0001-tdd-zig-browser-v1.md`). The v2a cycles reference §C; they do not re-define it.

---

# §C2 — Canonical Contracts (post-v1; pin before any cycle)

> **Why this section exists.** The PlanReview flagged that new types, vtable signatures, return types,
> error sets, exit codes, and the SDL/page teardown composition were described loosely, so Red tests
> could not compile and independent cycles risked diverging. §C2 is the **single source of truth** for
> everything this plan introduces; it extends the v1 plan's §C (handle table, ScriptEngine vtable,
> error discipline). Cycles reference §C2; they do not re-define it. **Ground-truthed against the code.**

## C2.0 — Error-return discipline (global, inherited from v1 §C.0)
Every new public function returns a **named** `error{...}!T`; no public `anyerror`. New error sets:
```zig
// src/render/screenshot.zig
pub const ScreenshotError = error{ RenderFailed, EncodeFailed, WriteFailed } || NavError; // NavError from fetch path
// src/display.zig
pub const DisplayError = error{ DimensionMismatch, BackendFailure };
// src/sdl_backend.zig
pub const SdlError = error{ SdlInitFailed, WindowCreateFailed, RendererCreateFailed, TextureCreateFailed, TextureUpdateFailed };
// src/cli.zig (already: Command); CLI dispatch surfaces ScreenshotError
```
Existing sets (confirmed verbatim in `src/errors.zig`): `NetError{InvalidUrl,DnsFailed,ConnectionRefused,Timeout,CertInvalid,TlsError,TransferFailed}`, `ParseError{MalformedDocument}`, `NavError = NetError || ParseError`, `StoreError{CrossOriginDenied}`. **Reuse these; do not redefine.** (Note: HTTP status incl. 4xx/5xx lives in `Response.status:u16`, not an error — `src/net/fetch.zig:8-11`.)

## C2.1 — `Display` interface (resolves 4 criticals: present return type, vtable shape, deinit lifecycle, pixel format)
Mirrors the `ScriptEngine` fat-pointer pattern. **`present` returns `DisplayError!void`** (NOT void — SDL is fallible); the vtable carries the mandatory `*anyopaque self`; a **`deinit` slot** exists so `main.zig` can hold the interface (not the concrete type) and still release SDL resources.
```zig
// src/display.zig
pub const PIXEL_FORMAT = "ARGB8888"; // u32 0xAARRGGBB, little-endian; matches SDL_PIXELFORMAT_ARGB8888
pub const Display = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        present: *const fn (*anyopaque, pixels: []const u32, w: u32, h: u32) DisplayError!void,
        deinit:  *const fn (*anyopaque) void,
    };
    pub fn present(self: Display, px: []const u32, w: u32, h: u32) DisplayError!void { return self.vtable.present(self.ptr, px, w, h); }
    pub fn deinit(self: Display) void { self.vtable.deinit(self.ptr); }
};
```
- **Pixel slice is caller-owned and valid only for the duration of the `present` call.** No backend may cache the pointer past return (prevents repaint UAF). `NullDisplay` copies; `SdlDisplay` uploads then drops the reference.
- **Dimension precondition:** `present` returns `error.DimensionMismatch` if `pixels.len != w*h` (the texture is created at fixed 1024×768; a w/h not matching the texture is rejected). Pitch is always `w * @sizeOf(u32)`.

```zig
// NullDisplay — test backend, mirrors NoopEngine; captures the frame for assertion
pub const NullDisplay = struct {
    allocator: std.mem.Allocator,
    last_pixels: ?[]u32 = null,
    last_w: u32 = 0, last_h: u32 = 0,
    pub fn deinitOwned(self: *NullDisplay) void { if (self.last_pixels) |p| self.allocator.free(p); }
    fn present(ptr: *anyopaque, px: []const u32, w: u32, h: u32) DisplayError!void { /* dup px into last_pixels */ }
    fn vdeinit(_: *anyopaque) void {}
    pub fn lastFrame(self: *const NullDisplay) ?[]const u32 { return self.last_pixels; } // testing-only accessor, NOT on the interface
    pub fn display(self: *NullDisplay) Display { ... }
};
```

## C2.2 — `event_loop.Event` (ALREADY EXISTS — cite + reuse; EXTEND minimally)
Confirmed verbatim at `src/platform/event_loop.zig:5-10`:
```zig
pub const Event = union(enum) {
    scroll: f32,   // delta; carries a payload
    click,         // NO payload today
    resize,        // NO payload today
    key,           // NO payload today
};
```
**Reality check:** today only `scroll` carries data (an `f32` delta); `click`/`resize`/`key` are bare tags, and `runTurn` only sets a dirty flag for them (`event_loop.zig:36-38`). For 0b.4, link hit-test needs click coords and resize needs new dimensions, so this cycle **extends** the union to `click: struct{x: f32, y: f32}` and `resize: struct{w: f32, h: f32}` (payload added; `runTurn`'s existing `.click,.resize,.key => dirty=true` arm is updated to capture/forward). This extension is itself a tracked change in cycle 0b.4 (not a silent assumption). **Scroll sign:** SDL `wheel.y` positive = wheel-away = content up → map to the sign that `Window.applyScrollDelta` (f32 delta, `window.zig:46`) already expects. **No `quit` variant** — quit is the loop running-flag (§C2.5), not an `Event`.

## C2.3 — `screenshot.zig` public signatures (resolves multi-caller contract + naming + arena ownership)
Canonical names (keep the existing `renderNavigatedPageArgb`; add a thin `renderPageArgb` only if a URL-level entry is wanted — the Red test name is aligned to the real fn):
```zig
// src/render/screenshot.zig
pub fn renderNavigatedPageArgb(arena: std.mem.Allocator, page: *Page, w: u32, h: u32) ScreenshotError![]u32; // caller (arena) owns the returned buffer; callee retains no reference past return
pub fn exportArgbPng(allocator: std.mem.Allocator, io: std.Io, w: u32, h: u32, argb: []const u32, out_path: []const u8) ScreenshotError!void;
```
- **ARGB element type is `[]const u32` everywhere** (matches `Display.present` + `SDL_PIXELFORMAT_ARGB8888`); `snapshot_gate.zig` reuse and `main.zig` dispatch both use this exact type. No `[]u8` at this boundary.
- **Ownership chain (screenshot CLI):** `main` creates the `Page` (owns the page arena) → `renderNavigatedPageArgb` allocates the `[]u32` **from that arena** → `exportArgbPng` reads it → `page.deinit()` frees it. No separate free; no double-free.

## C2.4 — `Command` extension (resolves exhaustive-switch breakage + dimensions)
Confirmed current (`src/cli.zig`): `union(enum){ version, open: []const u8, usage }`, dispatched by an exhaustive `switch (command)` in `main.zig:10`. Adding `.screenshot` **requires adding a switch arm** (non-breaking once added):
```zig
pub const Command = union(enum){ version, open: []const u8, usage,
    screenshot: struct { url: []const u8, out: []const u8, w: u32 = 1024, h: u32 = 768 } };
pub fn parseArgs(args: []const []const u8) Command; // pure; unknown flags → .usage
```

## C2.5 — Quit/teardown composition (resolves the CRITICAL UAF; SDL + page ordering)
On `SDL_QUIT` the order is **fixed and composed** (each half was specified; their composition was not):
```
1. set running=false; STOP the event loop — no further events processed (no repaint after this point)
2. page.deinit()            // runs the v1 teardown: stopScript→severHandles→drainFinalizers→arena.deinit→teardownIsolate
3. display.deinit()         // SdlDisplay: SDL_DestroyTexture→SDL_DestroyRenderer→SDL_DestroyWindow→SDL_Quit
```
**Invariant:** no `present()` may run after step 2 (the pixel buffer lives in the page arena freed there). The loop's running-flag check guarantees this; the composed-order test asserts no `present` Step is recorded after the teardown begins. Wired in `main` via a `defer` chain ordered to match.

## C2.6 — SDL error normalization (resolves unnamed boundary)
A private `fn sdlCheck(rc: c_int) SdlError!void` (and `fn sdlCheckPtr(p: ?*anyopaque) SdlError!void`) in `src/sdl_backend.zig` is the **only** place raw SDL return codes become Zig errors; on failure it reads `SDL_GetError()`, writes it to stderr, and returns the mapped `SdlError`. **No raw SDL code crosses into `main.zig`.** `SDL_Init<0 → error.SdlInitFailed` (process exits nonzero via `main` error propagation).

## C2.7 — `--screenshot` exit codes (resolves CI-targetable codes)
`0` success · `1` URL parse failure (`error.InvalidUrl`) · `2` fetch failure (`NetError` except InvalidUrl) · `3` render failure (`error.RenderFailed/MalformedDocument`) · `4` PNG write failure (`error.EncodeFailed/WriteFailed`). Documented in `--help`; asserted in the 0a.2 integration test. SIGINT/SIGTERM mid-run: the temp file (C2-atomic write) is removed by a `defer`-based cleanup so no partial/orphan file persists.

## C2.8 — Env-var contracts (resolves comptime-vs-runtime + truthiness)
Both are **runtime** reads via `std.process.getEnvVarOwned` (not comptime build options): `SMOKE` and `REQUIRE_SNAPSHOTS` are **truthy iff the value equals `"1"`** (any other value, or absent, = false). `REQUIRE_SNAPSHOTS=1` turns a missing-tool `SkipZigTest` into `error.TestUnexpectedResult`; CI sets it.

## C2.9 — Spike handle-table interface + decision metrics (resolves divergent spikes + metric count)
All three spikes implement the **same** minimal generational handle table so results are comparable (`WrapperRef{index:u32,generation:u32}` confirmed in `src/html/dom.zig`):
```zig
pub fn put(self: *Table, node: *Node) WrapperRef;     // fresh (index,generation)
pub fn get(self: *Table, ref: WrapperRef) ?*Node;     // generation mismatch → null (detached)
pub fn invalidate(self: *Table, ref: WrapperRef) void;// bumps the slot generation
```
**Decision-record metrics = FIVE (authoritative list)**, resolving the four-vs-five inconsistency: `ergonomics_locs`, `teardown_complexity`, `throughput_ops_per_sec`, `license_spdx`, `wasm_footprint_bytes`. The v2a.4 doc-lint asserts all **five** present for each spike. WASM-runtime **traps** are normalized to a Zig `error.WasmTrap` at the host-call boundary in the spike's runtime shim (foreign errors do not propagate raw).

## C2.10 — Memory-flatness predicate (resolves "flat" being untestable)
`std.testing.allocator` only catches leaks at end. For the button-churn spikes, wrap it in a **counting allocator** and assert **live-allocation count after cycle N == after cycle 1** (per-iteration flatness), not just end-state zero. This catches a slow accumulation released only at teardown.

## C2.11 — Conformance case schema + Page state-slicing
- WPT/html5lib case struct (`tests/harness/`): `const Case = struct { name: []const u8, input: []const u8, expect: []const u8 }`; loader returns `[]Case`; `cases.len > 0` asserted (zero = hard fail).
- **Page field classification** (for the v2b navigate() contract): *navigation-scoped* (reset per load) = `dom_root, style_for, box_root, render_checksum, current_url, has_loaded, scroll_y`; *session-scoped* (survives navigation) = `engine, process_allocator`. `arena` is re-created per navigation.

---

# The Red–Green–Refactor Cycles

Each cycle: 🔴 **Red** (exact failing test) → 🟢 **Green** (minimal code) → 🔵 **Refactor** (cleanup invariant
that stays green). Execute top-to-bottom. **0a leads** — fastest path to a visible artifact.

---

## Tier 1 · 0a — Visible pixels (screenshot stopgap)

### Cycle 0a.1 — render-module-extracted
**Given** `renderNavigatedPageArgb` + `exportArgbPng` live in test-only `src/paint/snapshot_gate.zig`
**When** they are lifted into a reusable non-test module `src/render/screenshot.zig`
**Then** both the snapshot tests and `main.zig` call the same functions; existing snapshot tests stay green.
**Edge cases:** no behavior change to snapshot tests; PNG-encoder dependency (Pillow shell-out) made explicit; arena ownership per **§C2.3** (caller arena owns the `[]const u32`).
**Types:** signatures + `ScreenshotError` per **§C2.3 / §C2.0**; canonical name is `renderNavigatedPageArgb` (§C2.3 — Red test uses the real name, resolving the naming inconsistency).
**Files touched:** `src/render/screenshot.zig` (new), `src/paint/snapshot_gate.zig` (import the moved fns), `src/root.zig` (reachability).

- 🔴 **Red** — new `test "renderNavigatedPageArgb produces a 1024x768 []u32 for a fixture page"` against `src/render/screenshot.zig` (doesn't exist → fail).
- 🟢 **Green** — move the two fns into `screenshot.zig` as `pub` with the §C2.3 signatures; re-point `snapshot_gate.zig` to import them.
- 🔵 **Refactor** — keep the Pillow shell-out behind one fn so the future pure-Zig PNG encoder is a drop-in; run the existing snapshot suite to confirm zero regression.

### Cycle 0a.2 — screenshot-flag
**Given** the browser binary and a reachable URL
**When** run as `zigBrowser --screenshot out.png <url>`
**Then** it fetches, renders, and writes a non-empty, valid PNG of the page to `out.png` and exits 0 — **the first human-visible artifact.**
**Edge cases:** fetch failure → exit code per **§C2.7** + no partial PNG; unwritable path → `error.WriteFailed`(exit 4); default 1024×768 (§C2.4 defaulted fields); output is a decodable PNG of expected dimensions; SIGINT mid-run leaves no temp file (§C2.7).
**Types:** `Command.screenshot` per **§C2.4** (`{url,out,w=1024,h=768}`); `parseArgs([]const []const u8) Command` (§C2.4); **must add the `.screenshot` arm to main.zig's exhaustive switch** (§C2.4 — non-breaking once added). Exit codes per §C2.7.
**Files touched:** `src/cli.zig` (parse `--screenshot`), `src/main.zig` (dispatch arm), `src/render/screenshot.zig` (reuse).

- 🔴 **Red** — `test "parseArgs --screenshot yields .screenshot{url,out}"` + an integration test running the binary against the local static server, asserting the PNG exists, is non-empty, decodes to 1024×768, **and exits 0**; plus a fetch-failure case asserting **exit 2** and no output file. Fails (no flag).
- 🟢 **Green** — parse the flag; add the switch arm; in `main`, fetch+render via `screenshot.zig`, write the PNG; map errors→exit codes per §C2.7.
- 🔵 **Refactor** — atomic write (temp+rename, §C2.7) with `defer` cleanup so no partial/orphan file on failure or signal; document exit codes in `--help`.

**0a exit gate:** `zigBrowser --screenshot out.png https://…` produces a real PNG you can open. **Visible output achieved.**

---

## Tier 1 · 0b — SDL2 interactive window

### Cycle 0b.1 — display-interface
**Given** the **§C2.1 `Display` vtable** — `present(*anyopaque, []const u32, u32, u32) DisplayError!void` **and `deinit(*anyopaque) void`** — with an injectable backend
**When** the render loop presents a frame
**Then** pixels are handed to the backend; a `NullDisplay` test backend captures them (via the testing-only `lastFrame()` accessor, §C2.1) with **zero SDL dependency**.
**Edge cases:** `NullDisplay` copies the exact buffer (caller-owned, not retained past return — §C2.1); pitch = `w*4`; `pixels.len != w*h` → `error.DimensionMismatch`; `deinit` slot present so `main` holds the interface, not the concrete type (resolves the lifecycle critical).
**Types:** full §C2.1 struct (`ptr`+`vtable{present,deinit}`, `*anyopaque self`, `DisplayError`, `PIXEL_FORMAT`).
**Files touched:** `src/display.zig` (new — interface + `NullDisplay`), `src/root.zig`.

- 🔴 **Red** — `test "NullDisplay.present captures pixels exactly and lastFrame returns them"` + `test "present rejects len!=w*h with DimensionMismatch"` (no `display.zig` → fail).
- 🟢 **Green** — define the §C2.1 vtable (present+deinit), `DisplayError`, `NullDisplay` with `last_pixels`/`lastFrame()`.
- 🔵 **Refactor** — assert **no browser logic imports SDL — only `main.zig`/`sdl_backend.zig` do** by keeping `display.zig` SDL-free; document the caller-owned pixel-lifetime rule.

### Cycle 0b.2 — sdl-build-link
**Given** `build.zig` using `b.addTranslateC` for `SDL2/SDL.h`
**When** building on Linux (pkg-config) and macOS (`linkFramework`)
**Then** SDL2 links portably with **no hard-coded library path**; the binary compiles on both targets.
**Edge cases:** missing `pkg-config sdl2` → clear build error; macOS framework path via homebrew/`xcrun`; `libsdl2-dev` prerequisite documented.
**Files touched:** `build.zig`, `src/sdl2.h` (new wrapper header `#include <SDL2/SDL.h>`), `README`/prereqs.

- 🔴 **Red** — a build that imports the `sdl2` translate-c module and references `SDL_Init`; fails until linked.
- 🟢 **Green** — add the `addTranslateC` step + `linkSystemLibrary("SDL2", .{.use_pkg_config=.yes})` (Linux) / `linkFramework` (macOS) per `target.result.os.tag`.
- 🔵 **Refactor** — **also remove the hard-coded `libcurl.so.4` path** here (shared portability fix; formalized in cycle 1·curl-path-portable). `zig build` green on Linux.

### Cycle 0b.3 — sdl-window-blit
**Given** an `SdlDisplay` backend and a rendered 1024×768 ARGB framebuffer
**When** a page is rendered and presented
**Then** an OS window opens showing the page pixels (`SDL_PIXELFORMAT_ARGB8888` streaming texture; `UpdateTexture`→`RenderCopy`→`RenderPresent`).
**Edge cases:** ARGB8888 correct on little-endian (u32 high-byte alpha — no `_32` alias); window resizable; **headless CI uses `SDL_VIDEODRIVER=dummy`** so the init test passes without a display.
**Files touched:** `src/sdl_backend.zig` (new — `SdlDisplay`), `src/main.zig`.

**Types/errors:** `SdlDisplay` implements §C2.1 `Display` (fat-pointer like `NoopEngine.make()`); all SDL calls go through **`sdlCheck` (§C2.6)** → `SdlError`; `SDL_Init<0 → error.SdlInitFailed` + stderr `SDL_GetError()` (§C2.6). `present` returns `DisplayError` (maps `SdlError.TextureUpdateFailed`→`BackendFailure`).
- 🔴 **Red** — `test "SdlDisplay init+present under SDL_VIDEODRIVER=dummy succeeds"` (sets env, inits, presents one frame, asserts no error) + `test "sdlCheck maps a forced failure to SdlError, not a raw code"`. Fails (no backend).
- 🟢 **Green** — implement `SdlInit→CreateWindow→CreateRenderer→CreateTexture(ARGB8888,STREAMING)→present`, every call wrapped in `sdlCheck`.
- 🔵 **Refactor** — `SdlDisplay.display()` returns the §C2.1 fat pointer; pixel-format gotcha (`ARGB8888`, not `_32`, §C2.1) documented; `deinit` implements the §C2.5 SDL destroy sequence.

### Cycle 0b.4 — sdl-event-loop
**Given** `main.zig` driving `event_loop.runTurn` with real `SDL_PollEvent` input
**When** the user scrolls, clicks a link, resizes, or closes the window
**Then** scroll moves+repaints, link click navigates+frees the prior arena+repaints, resize **re-renders at the new viewport width** (not just re-present), close quits via the **§C2.5 composed order**.
**Contract decisions (resolve implicit state):** link-click navigation **resets `scroll_y` to 0** (§C2.11 navigation-scoped); resize updates the layout-viewport width **then** triggers a full re-render; repaint only on dirty flag.
**Types:** the existing `event_loop.Event` (§C2.2) today is `scroll:f32 / click / resize / key` — this cycle **extends** `click`→`{x,y:f32}` and `resize`→`{w,h:f32}` (payloads needed for hit-test/relayout) and updates `runTurn`'s `.click,.resize` arm accordingly; **scroll sign per §C2.2**; quit is the loop running-flag, not an Event. Hit-test via the confirmed `window.zig:58 clickNavigate(self, io, page, links: []const LinkHit, click_x: f32, click_y: f32) NavError!LinkNavigateResult` (+ `LinkHit`, `LinkNavigateResult{no_target,fragment_only,navigated}`).
**CRITICAL composition (§C2.5):** on quit — (1) stop loop, (2) `page.deinit()`, (3) `display.deinit()`; **no `present` after step 2** (pixel buffer is in the freed arena).
**Files touched:** `src/main.zig` (the real loop + §C2.5 defer chain), `src/sdl_backend.zig` (event translation + `sdlCheck`), `src/platform/window.zig` (wire real destroy callbacks).

- 🔴 **Red** — `test "SDL events translate to existing event_loop.Event (scroll/click/resize)"` over a synthetic `SDL_Event` slice asserting f32 payloads + scroll sign; `test "quit composition: page.deinit before display.deinit; no present after teardown"` (spy records Step order); plus the existing `Window.deinit` callback-order test with real SDL callbacks. Fails (no translation/composition).
- 🟢 **Green** — translate `MOUSEWHEEL/MOUSEBUTTONDOWN/WINDOWEVENT_RESIZED` → `event_loop.Event`; handle `SDL_QUIT` via running-flag; wire `main` poll→`runTurn`→present-on-dirty with the §C2.5 teardown.
- 🔵 **Refactor** — keep translation pure/testable; the only untested surface is the `SDL_PollEvent` call; assert the no-present-after-teardown invariant holds.

**0b exit gate:** `zigBrowser <url>` opens a window, shows the page, scrolls, follows links, closes cleanly. **Interactive browser achieved.**

---

## Tier 1 · 1 — macOS portability + CI

### Cycle 1.1 — curl-path-portable
**Given** `build.zig:7` hard-codes `/usr/lib/x86_64-linux-gnu/libcurl.so.4`
**When** the build resolves libcurl via pkg-config / system library
**Then** the build references no absolute `.so` path and links curl on both Linux and macOS.
**Edge cases:** `pkg-config libcurl` on Linux; macOS curl via SDK; fetch still does real HTTPS after the change.
**Files touched:** `build.zig`.

- 🔴 **Red** — a build assertion / CI step that greps `build.zig` for `cwd_relative.*\.so` and fails if present (guards the regression); plus the macOS build leg (cycle 1.2) failing until fixed.
- 🟢 **Green** — replace the hard-coded object file with `linkSystemLibrary("curl", .{.use_pkg_config=.yes})` (and the existing `addTranslateC` header).
- 🔵 **Refactor** — confirm `fetch` still passes its real-HTTPS + bad-cert tests post-change.

### Cycle 1.2 — ci-matrix
**Given** no CI exists
**When** a `.github/workflows/ci.yml` matrix runs on `ubuntu-latest` and `macos-latest`
**Then** both build the exe and run `zig build test` green — proving curl/FreeType/HarfBuzz/SDL2 C interop on macOS.
**Edge cases:** `SDL_VIDEODRIVER=dummy` in CI; **Pillow installed** so the corpus gate runs (not skips); Zig 0.16.0 pinned via setup action; `libsdl2-dev`/brew `sdl2` installed per-OS.
**Files touched:** `.github/workflows/ci.yml` (new).

- 🔴 **Red** — push the workflow with the macOS leg; it fails first run if any C interop is unportable (this is the proof).
- 🟢 **Green** — install per-OS deps (apt `libsdl2-dev libcurl4-openssl-dev` + pip Pillow; brew `sdl2 curl`), pin Zig 0.16.0, run build+test with `SDL_VIDEODRIVER=dummy`.
- 🔵 **Refactor** — cache the Zig toolchain; matrix-factor common steps.

**Tier 1·1 exit gate:** green CI badge on both OSes; no hard-coded paths remain.

---

## Tier 1 · 2 — Real-web smoke tier

### Cycle 2.1 — realweb-smoke
**Given** a smoke harness **separate from** the deterministic unit suite
**When** it fetches live Wikipedia/MDN/HN pages over the network
**Then** each renders without crashing and produces a non-trivial result (box-tree node count > threshold; framebuffer not blank).
**Edge cases:** network-unavailable → **skip, never fail**; not a snapshot/pass-fail gate; **per-page timeout = 10s → skip that page (log URL+elapsed), continue** (not a crash); opt-in via `SMOKE=1` (§C2.8 truthiness) so it never runs offline; fetch errors at this call site are **non-retryable → skip the page** (§C2.0).
**Types:** smoke fixture schema = JSON array of `{ url: []const u8, min_node_count: u32, timeout_ms: u32 }`; thresholds live in the fixture, not hard-coded. "Non-blank" = framebuffer checksum ≠ the all-white sentinel (`0xFFFFFFFF * pixel_count` mod 2^64).
**Files touched:** `tests/smoke/real_web.zig` (new), `tests/smoke/urls.json` (fixture), `build.zig` (a separate `smoke` step, not in `test`).

- 🔴 **Red** — `test "real-web smoke: live pages render non-trivially"` gated behind `SMOKE=1`; fails until the harness exists.
- 🟢 **Green** — read the fixture, fetch each URL (10s timeout), run the pipeline, assert `node_count > min_node_count` and non-blank checksum per page.
- 🔵 **Refactor** — offline / per-page timeout → skip-and-continue; keep it out of the default `test` step (own `smoke` step).

**Tier 1·2 exit gate:** `SMOKE=1 zig build smoke` renders live Wikipedia/MDN/HN without crashing.

---

## Tier 1 · 3 — Conformance repair (wire what exists; defer growth)

### Cycle 3.1 — conformance-harness-wired
**Given** `tests/harness/wpt_subset.json` + `html5lib_subset.json` exist but `tests/harness/root.zig` is only a scaffold-sanity test
**When** the harness root is wired to load and assert on both JSON files (data-driven)
**Then** the harness suite parses each case and fails on a regression; an empty/missing JSON **fails loudly**, not vacuously.
**Edge cases:** zero-case file → hard fail (not skip); case count asserted > 0; each case asserts a concrete expectation.
**Types:** `Case` struct + `[]Case` loader return per **§C2.11**.
**Files touched:** `tests/harness/root.zig`, a small loader (or reuse the dead loaders — see 3.2).

- 🔴 **Red** — replace the scaffold test with `test "wpt subset: all cases assert"` + `test "html5lib subset: all cases assert"`; fail (not loaded yet).
- 🟢 **Green** — read+parse each JSON via `std.Io` + `std.json` into `[]Case` (§C2.11), loop, assert per case; assert `cases.len > 0`.
- 🔵 **Refactor** — share the loader between wpt + html5lib; document subset-growth as a separate future effort.

### Cycle 3.2 — dead-loaders-resolved
**Given** `html5lib_loader.zig` and `css_corpus_loader.zig` are imported by no build step
**When** each is either wired into the harness/build or deleted
**Then** no orphaned test file remains; every test file on disk is reachable by `zig build test`.
**Edge cases:** if wired, its assertions actually run; if deleted, no real coverage lost; a meta-check that all `*_loader.zig` are referenced.
**Files touched:** `tests/harness/root.zig` or `src/root.zig` (wire), or delete the files; a reachability meta-test.

- 🔴 **Red** — `test "no orphaned *_loader.zig test files"` — a meta-test enumerating `*_loader.zig` and asserting each is imported by an aggregator. Fails (2 orphans).
- 🟢 **Green** — wire the ones with real coverage into an aggregator; delete the redundant.
- 🔵 **Refactor** — keep the meta-check so future orphans are caught.

### Cycle 3.3 — corpus-gate-fails-loud
**Given** the corpus/90% gate returns `error.SkipZigTest` when Pillow is absent
**When** running where snapshots are declared required (`REQUIRE_SNAPSHOTS=1`, set in CI)
**Then** missing Pillow causes a **hard failure**, not a vacuous skip; locally without the flag it still skips gracefully.
**Edge cases:** local dev without Pillow still skips; CI sets `REQUIRE_SNAPSHOTS=1` → skip becomes failure; **pure-Zig PNG path** considered to remove the Pillow dependency entirely (flagged follow-up).
**Contract:** `REQUIRE_SNAPSHOTS` is a **runtime** `getEnvVarOwned` read, **truthy iff `"1"`** (§C2.8).
**Files touched:** `src/paint/snapshot_gate.zig`.

- 🔴 **Red** — `test "corpus gate hard-fails when REQUIRE_SNAPSHOTS=1 and Pillow missing"` (simulate by pointing the tool check at a bogus path). Fails (currently skips).
- 🟢 **Green** — branch on `REQUIRE_SNAPSHOTS` (§C2.8): when `"1"`, a missing tool is `error.TestUnexpectedResult`, not `SkipZigTest`.
- 🔵 **Refactor** — file the pure-Zig PNG encoder as the dependency-removing follow-up so CI needn't install Pillow.

**Tier 1·3 exit gate:** harness JSON actually asserts; no orphan loaders; corpus gate cannot pass vacuously in CI.

---

## Tier 2 · v2a — JS engine spikes + decision gate

> Acceptance for the spikes is the v1 plan **§C button-churn no-leak/no-UAF generational-handle test**:
> build a DOM node + a JS handler that captures it (the cross-heap cycle), JS holds the node only via a
> generational handle; on teardown assert (a) NO LEAK — the handler is collected by ordinary GC via the
> weak edge, and (b) NO UAF — a stale handle resolves to "detached." Repeat ~10k cycles.
>
> **Shared across all three spikes (§C2.9):** the same handle-table interface (`put/get/invalidate`) so
> results are comparable; the same FIVE decision metrics (`ergonomics_locs, teardown_complexity,
> throughput_ops_per_sec, license_spdx, wasm_footprint_bytes`). **Memory-flatness is testable per §C2.10**
> — wrap `std.testing.allocator` in a counting allocator and assert live-allocation count after cycle N
> equals after cycle 1 (catches slow accumulation, not just end-state leaks). `runScript` returns
> `NavError!void` (v1 §C / `errors.zig`); spike error handling references those variants.

### Cycle v2a.1 — spike1-quickjs
**Given** QuickJS-ng vendored and embedded from Zig via `translate-c`
**When** a trivial script runs and the button-churn lifecycle test executes
**Then** the script evaluates correctly AND no-leak + no-UAF pass under `std.testing.allocator`.
**Edge cases:** non-moving refcount GC teardown order; ~10k open/close cycles stay memory-flat; MIT license noted.
**Files touched:** `spikes/quickjs/` (vendored + `build.zig` integration), a spike test.

- 🔴 **Red** — `test "quickjs button-churn: no leak, no UAF"` (engine not embedded → fail).
- 🟢 **Green** — vendor quickjs-ng, `addTranslateC` its header, embed; implement the minimal handle table for the test.
- 🔵 **Refactor** — record ergonomics (LOC, sharp edges) + perf + license in the decision record.

### Cycle v2a.2 — spike1-xs
**Given** Moddable XS embedded from Zig
**When** the same button-churn acceptance test runs
**Then** no-leak + no-UAF pass under XS's **moving/compacting GC** (`xsRemember`/`xsForget` rooting); ergonomics/perf/license recorded vs QuickJS.
**Edge cases:** moving-GC pointer invalidation handled — **after `pumpMicrotasks()` returns, all live `WrapperRef` handles must be re-resolved through the handle table; no cached raw XS pointers survive a pump** (§C2.9 table); a sub-case forces an XS GC during a pump to verify; LGPL/GPL/commercial license noted; perf delta vs QuickJS measured.
**Files touched:** `spikes/xs/` (vendored + build), a spike test.

- 🔴 **Red** — `test "xs button-churn: no leak, no UAF"` + `test "xs handles survive a GC forced during pumpMicrotasks"` (not embedded → fail).
- 🟢 **Green** — embed XS; implement the §C2.9 handle table honoring its rooting API; re-resolve handles post-pump.
- 🔵 **Refactor** — record the moving-GC rooting cost — it's the rehearsal for JSC.

### Cycle v2a.3 — spike2-wasm
**Given** a WASM-compiled JS engine driven from Zig via a WASM runtime
**When** JS calls host DOM functions across the linear-memory boundary and the button-churn test runs
**Then** the boundary **structurally forbids raw DOM pointers** (handles only) and no-leak + no-UAF hold; perf + ~8MB footprint recorded.
**Edge cases:** handle marshalling across the canonical ABI; **WASM runtime traps normalized to `error.WasmTrap` at the host-call boundary** (§C2.9 — foreign errors never propagate raw); weval AOT on/off perf; per-DOM-crossing marshalling tax measured.
**Files touched:** `spikes/wasm/` (engine + runtime + build), a spike test.

- 🔴 **Red** — `test "wasm-engine button-churn across linear-memory: no leak, no UAF"` + `test "a WASM trap surfaces as error.WasmTrap, not a raw runtime panic"` (no runtime wired → fail).
- 🟢 **Green** — drive the WASM engine; expose 2–3 host DOM fns as imports (§C2.9 handle table); normalize traps; run the test.
- 🔵 **Refactor** — confirm the ABI makes raw pointers impossible (the §C no-raw-pointer invariant enforced by the boundary); record perf/footprint.

### Cycle v2a.4 — engine-decision-gate
**Given** Spike 1 + Spike 2 evidence (ergonomics, teardown, perf, license, footprint)
**When** the L1 bootstrap engine and L3 native-vs-WASM fork are decided
**Then** a **decision record** is written citing measured data; v2b is unblocked against the chosen engine.
**Edge cases:** decision is evidence-backed, not asserted; records the rejected option's reason; updates `JS_ENGINE_STRATEGY.md` phasing.
**Metrics (authoritative = FIVE, §C2.9):** `ergonomics_locs, teardown_complexity, throughput_ops_per_sec, license_spdx, wasm_footprint_bytes` — resolves the four-vs-five inconsistency; the doc-lint asserts all **five** per spike.
**Files touched:** `Plans/JS_ENGINE_STRATEGY.md` (decision + phasing update), a short ADR under `thoughts/`.

- 🔴 **Red** — a doc-lint asserting the decision record exists and cites **all five** §C2.9 metrics for each spike (fails until written).
- 🟢 **Green** — write the decision: pick the bootstrap engine + native-vs-WASM, with the five metrics per spike.
- 🔵 **Refactor** — update the strategy doc's §10 phasing; this gate is the precondition for detailing v2b.

**v2a exit gate:** both spikes pass the button-churn acceptance test; the engine + delivery model are chosen on data; v2b is ready to detail.

---

## Per-Stage Exit Gates (summary)

| Stage | Gate (demoable) |
|---|---|
| 1·0a | `--screenshot out.png <url>` writes a real, openable PNG of a page |
| 1·0b | `zigBrowser <url>` opens a window; scroll + link-click + close work |
| 1·1 | CI green on Linux **and** macOS; no hard-coded lib paths |
| 1·2 | `SMOKE=1` renders live Wikipedia/MDN/HN without crashing |
| 1·3 | harness JSON asserts on real cases; no orphan loaders; corpus gate fails-loud in CI |
| 2·v2a | both spikes pass no-leak/no-UAF; engine + native-vs-WASM chosen on evidence |

## v2b → v3 — OUTLINE only (deferred, pending the engine-decision-gate)

- **v2b — fill the seam (against the chosen engine):** implement the generational **handle table** (`WrapperRef`↔`Node`, §C2.9 / v1 §C); confirm the ordered teardown drives the real engine; drive the microtask pump from `runTurn`; **hand-write the 5 core WebIDL interfaces** (`EventTarget`, `Node`, `Element`, `Event`, `Document`); a script mutates the DOM → relayout. The navigate() contract uses the **§C2.11 Page field classification** (navigation-scoped vs session-scoped). Acceptance: a real `<script>` that does `document.getElementById(...).textContent = ...` changes the rendered output.
- **v2c — WebIDL→Zig codegen scale-out:** build `tools/webidl-gen`; generate bindings from `.idl`; assert a generated binding matches the hand-written one; grow test262 / WPT-DOM coverage.
- **v3 — end-state engine:** swap in native-JIT (JSC) or the WASM hybrid behind the same seam per the gate; re-target the codegen backend, not the interfaces; gate on measured perf of the app-like target corpus.

These are intentionally not decomposed into cycles yet: their shape depends on which engine and delivery
model the v2a gate selects. Detail them in a follow-up plan once the gate closes.

## Fixtures & Prerequisites
- **`libsdl2-dev`** (Linux) / brew `sdl2` (macOS) — required for 0b; absent on the current dev box.
- **Pillow** in CI — so the corpus/90% gate runs (and, with `REQUIRE_SNAPSHOTS=1`, fails loud).
- **`SDL_VIDEODRIVER=dummy`** — headless SDL init in CI.
- **Live-URL smoke list** — small fixture of Wikipedia/MDN/HN URLs (opt-in `SMOKE=1`).
- **Existing data** — `tests/harness/*.json`, `tests/corpus_pages/*`, `tests/snapshots/*`, `tests/fonts/DejaVuSans.ttf`.

## Risks & Mitigations
| Risk | Severity | Mitigation |
|---|---|---|
| SDL2 absent on dev box → 0b blocked | Medium | 0a screenshot stopgap delivers visible output first with no new dep; document `libsdl2-dev` install |
| macOS C interop (curl/FreeType/HarfBuzz/SDL2) unproven | High | The macOS CI leg (cycle 1.2) IS the proof; portability fix (1.1) precedes it |
| Live-site flakiness | Medium | Smoke tier is non-deterministic & opt-in; skip (never fail) offline; not a gate |
| XS moving-GC rooting bugs in the spike | Medium | Re-fetch pointers after GC; the spike's no-UAF test catches violations; it's the JSC rehearsal |
| Pillow dependency in CI | Low-Med | `REQUIRE_SNAPSHOTS` makes it explicit; pure-Zig PNG encoder filed as the removal follow-up |
| SDL pixel-format byte-order bug | Medium | `SDL_PIXELFORMAT_ARGB8888` (not `_32`); NullDisplay unit-asserts exact pixels before SDL is involved |
| Detailing v2b→v3 prematurely | Medium | Outline-only until the engine-decision-gate; avoids speculative rework |

## Review Resolution (PlanReview 2026-05-30 — 8 critical + 45 warnings)

All findings resolved; **§C2 Canonical Contracts** is the primary fix (cycles reference it).

| Finding (review) | Resolution |
|---|---|
| **CRIT** Contracts/Interfaces/APIs — `Display.present` return type + vtable shape + missing `*anyopaque` self | §C2.1 — `present(*anyopaque,[]const u32,u32,u32) DisplayError!void`; full fat-pointer struct |
| **CRIT** APIs — `Display` has no deinit/lifecycle | §C2.1 — `deinit` vtable slot; `main` holds the interface; §C2.5 SDL destroy sequence |
| **CRIT** Interfaces — `event_loop.Event` "never defined" | §C2.2 — it ALREADY EXISTS (`event_loop.zig:5-10`: `scroll:f32/click/resize/key`); cited verbatim; cycle 0b.4 extends click/resize with f32 payloads (tracked change) |
| **CRIT** Interfaces — `screenshot.zig` signatures (multi-caller) | §C2.3 — both signatures + `[]const u32` element type + arena ownership chain |
| **CRIT** Interfaces — error discipline for new modules | §C2.0 — `ScreenshotError`/`DisplayError`/`SdlError`, no public `anyerror` |
| **CRIT** Promises — SDL + page teardown composition (UAF) | §C2.5 — fixed order: stop loop → `page.deinit()` → `display.deinit()`; no `present` after step 2; tested |
| WARN renderPageArgb input/arena, NullDisplay retrieval, present lifetime, w/h mismatch, pixel format | §C2.1, §C2.3 (caller-owned, `lastFrame()`, `DimensionMismatch`, `ARGB8888`) |
| WARN SDL error boundary, SDL_Init failure | §C2.6 — `sdlCheck` normalization point; `error.SdlInitFailed` + stderr |
| WARN --screenshot exit codes, signal cleanup | §C2.7 — codes 0–4; `defer` temp-file cleanup |
| WARN env-var contracts (comptime/runtime, truthiness) | §C2.8 — runtime `getEnvVarOwned`, truthy iff `"1"` |
| WARN Command discriminants/switch breakage, .screenshot dims | §C2.4 — current union cited; add switch arm; `w=1024,h=768` defaults |
| WARN scroll-reset, resize semantics | Cycle 0b.4 — link-click resets `scroll_y=0`; resize re-renders at new width (§C2.11) |
| WARN spike handle-table divergence, metric count 4-vs-5, WASM trap norm, memory-flatness, XS GC re-resolve | §C2.9 (shared `put/get/invalidate`, five metrics, `error.WasmTrap`), §C2.10 (counting allocator), cycle v2a.2 |
| WARN conformance Case schema, dead-loader meta-check | §C2.11 `Case` struct; cycle 3.2 meta-test |
| WARN smoke fixture schema/thresholds/timeout, fetch retryability | Cycle 2.1 — JSON `{url,min_node_count,timeout_ms}`, 10s skip-and-continue, non-retryable |
| WARN NavError/WrapperRef field types, Page state-slicing | confirmed `errors.zig` + `dom.zig` (`WrapperRef{index:u32,generation:u32}`); §C2.11 classification |

## References
- `Plans/TDD_IMPLEMENTATION_PLAN.md` — high-level v1 plan.
- `Plans/JS_ENGINE_STRATEGY.md` — v4 scripting authority (§2 lifetime contract, §6 spikes, §10 phasing).
- `thoughts/searchable/shared/plans/2026-05-30-14-58-ENG-0001-tdd-zig-browser-v1.md` — v1 detailed plan + §C Canonical Contracts.
- Verified code: `build.zig:7`, `src/main.zig:17-21`, `src/page.zig:92-104,185-195`, `src/platform/window.zig`, `src/platform/event_loop.zig:42`, `src/script/engine.zig:10-17`, `src/html/dom.zig`, `src/net/fetch.zig:20-72`, `src/paint/snapshot_gate.zig:28,63,111,177`, `tests/harness/root.zig`.
- Zig 0.16 + SDL2: ziglang.org 0.16 release notes (`addTranslateC`, `std.testing.io`); SDL wiki (`SDL_PIXELFORMAT_ARGB8888`, `SDL_UpdateTexture`, `SDL_WindowEvent`); `SDL_VIDEODRIVER=dummy` (libsdl discourse); zig-gamedev/zsdl; dvui SDL backend.
