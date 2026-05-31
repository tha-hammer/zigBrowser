# Zig Browser — TDD Implementation Plan (v1)

**Scope:** A layout-first, static-HTML rendering engine in Zig. Fetches a real URL over HTTPS and renders a readable, styled, scrollable, clickable page in a native window on Linux and macOS.

**Identity decision:** No JavaScript in v1, **but architected with an engine-agnostic `ScriptEngine` seam** so the chosen engine drops in for v2 without a rewrite. (See §2.3.) The bootstrap engine is TBD by spike (QuickJS-ng default vs Moddable XS); the end-state engine is native-JIT (JSC) or a WASM-hybrid — see `JS_ENGINE_STRATEGY.md`. **Not** QuickJS-locked.

**Companion & precedence:** This document is the **v1 build plan**. `JS_ENGINE_STRATEGY.md` is the authoritative design for everything scripting-related (its four layers: engine, integration, isolation/delivery, object lifetime). Where the two touch scripting, **the strategy doc governs**; this plan only reserves v1 seams that must not preclude it. The strategy doc (its §10) confirms v1 here is **unchanged** — content-focused, no-JS — and is the *deliberate first vertical slice* of a browser whose **locked end-state scope is app-like sites** (Gmail/Figma/Linear/Docs-class), not just content sites.

**Method:** Test-first. Every milestone is a Red → Green → Refactor loop. No production code without a failing test that demands it.

---

## 1. Goal & Success Gate

**Goal (one sentence):** Type a URL, see the page — readable text, applied CSS, scrollable, with working links.

**Success gate (must all pass to call v1 done):**
1. Fetches `https://` URLs with real certificate validation.
2. Renders a correct box tree (block + inline) for a real document.
3. Text is shaped and rasterized correctly (Latin first; UTF-8 throughout).
4. Scroll works; clicking a link navigates and frees the previous page's arena.
5. Passes a curated **WPT subset** (parsing + CSS2.1 cascade + box model).
6. Renders **≥90% of a fixed 50-page corpus** acceptably: Wikipedia articles, MDN pages, plain blogs, docs sites, Hacker News.

**Out of scope for v1 (hard NOs):** JS execution, flexbox/grid, transforms/animations, GPU compositing, tabs, history DB, incremental/dirty-flag layout, web fonts (`@font-face`).

**Deferred but must not be precluded by v1 architecture:** multi-process / per-origin renderer isolation. Per `JS_ENGINE_STRATEGY.md` D9, the engine *will* be exploited and OS-process isolation is the security model. v1 ships single-process (acceptable *only because there is no JS*), but the render/document boundary must stay process-portable — no v1 design may assume a shared address space that a later renderer split would have to undo.

---

## 2. Architecture

### 2.1 The arena strategy (the reason this is in Zig)
Every page load owns a single `std.heap.ArenaAllocator`. All DOM nodes, CSSOM rules, computed styles, the box tree, and parse scratch buffers allocate from it. **On navigate, `arena.deinit()` frees the entire previous document in one shot.** This eliminates the use-after-free / leak class that defines C browsers. This invariant is load-bearing — no document-scoped data may escape the page arena.

Long-lived state (the window, font cache, the libcurl handle, the HTTP connection pool) lives in a separate process-lifetime allocator (GPA in debug for leak detection, or a long-lived arena).

### 2.2 Module layout
```
src/
  main.zig            — entry, event loop, navigation controller
  net/
    fetch.zig         — libcurl wrapper: URL → bytes + content-type
    url.zig           — URL parsing/resolution (pure Zig)
  html/
    tokenizer.zig     — HTML5 spec tokenizer
    tree_builder.zig  — tokens → DOM
    dom.zig           — Node/Element/Text types, tree API
  css/
    tokenizer.zig     — CSS tokenizer
    parser.zig        — tokens → stylesheet (rules, selectors, declarations)
    cssom.zig         — stylesheet types
    cascade.zig       — selector matching + specificity + inheritance → ComputedStyle
  layout/
    box.zig           — box tree types
    block.zig         — block formatting
    inline.zig        — inline/line-box formatting, line breaking
    float.zig         — floats (last)
  paint/
    display_list.zig  — paint commands (rects, text runs, images)
    raster.zig        — software rasterizer → framebuffer
    text.zig          — FreeType + HarfBuzz wrapper, glyph/font cache
  image/
    decode.zig        — PNG/JPEG via zigimg
  platform/
    window.zig        — SDL2/GLFW window, input, blit, scroll
  script/
    engine.zig        — engine-agnostic ScriptEngine interface (NoopEngine in v1);
                        reserves runScript / pumpMicrotasks + the full 5-step
                        teardown order: stopScript / severHandles / drainFinalizers
                        / (arena.deinit) / tearDownIsolate. NO engine named here (§2.3).
```

### 2.3 Scripting seams — engine-agnostic (the v2 enabler)
Per the locked decision, v1 ships no JS but must not bake in "no scripting" assumptions. These seams are derived from `JS_ENGINE_STRATEGY.md` (L1–L4); v1 *reserves* them, v2 *fills* them. All are engine-agnostic — the engine is chosen by spike, never hard-coded.

1. **`script/engine.zig` defines an engine-agnostic `ScriptEngine` interface** (Zig vtable or tagged union) — this seam *is* the strategy doc's L2 pattern (per-page isolate + hard exception boundary, D5). v1 wires `NoopEngine`; v2 wires the spike-selected bootstrap engine (QuickJS-ng default vs Moddable XS). Navigation controller calls `engine.runScript(...)` at spec-defined points; Noop returns immediately. **No symbol, type, or comment may name a specific engine** — the seam outlives any one engine (bootstrap → end-state JSC/WASM swap).
2. **The HTML tree builder handles `<script>` correctly today:** switch the tokenizer to raw-text/script-data state, capture the script source into the DOM node, **store it without executing.** Hard spec interaction; getting the states right now means v2 just adds the execute call.
3. **DOM is mutable and event-ready:** nodes expose insert/remove/setAttribute; reserve (don't implement) event-target hooks. No layout code may assume the DOM is immutable after parse.
4. **Strict DOM ↔ layout separation:** layout reads DOM + computed style → box tree; it never mutates the DOM. Keeps "JS mutates DOM → relayout" a clean v2 addition.
5. **host-owns-handles readiness (L4 — the load-bearing one).** Per strategy §2, JS will never hold raw DOM pointers; it holds opaque handles into a per-page table, with a node→wrapper cache for `===`/`[SameObject]` identity. v1 has no JS, but **every DOM node must already reserve an inline wrapper-cache slot** (e.g. a nullable `script_wrapper: ?WrapperRef` field, unused in v1). Skipping this forces a DOM-wide refactor in v2. Zig owns the node (arena); the future JS→DOM edge is weak-by-default.
6. **Ordered navigation teardown hook (L4 — crash-prevention invariant).** The naïve v1 path is just `arena.deinit()`. But the engine's collector runs on its own schedule, so v2 requires strict order (strategy §2.2 — **all five steps**): **(1) `engine.stopScript()` — stop execution, block new tasks/microtasks → (2) `engine.severHandles()` — null/generation the handle table → (3) `engine.drainFinalizers()` — drain or cancel pending finalizers → (4) `arena.deinit()` — only now is DOM memory freed → (5) `engine.tearDownIsolate()` — destroy the page-scoped engine context.** v1 implements only step 4, but the navigation controller **must reserve all four engine hooks as no-ops in this exact order** around `arena.deinit()` — *including step 1 `stopScript` before `severHandles` and step 5 `tearDownIsolate` after `deinit`*. Reserving only the middle two (the original gap PlanReview caught) would force v2 to **insert a call before the first hook**, which is exactly the navigation-controller edit the seam exists to prevent. v2 fills the bodies without touching call order. A finalizer dereferencing a node after `deinit()` is forbidden. (`drainFinalizers` must be synchronous — it may not return until all finalizers for the page have completed or been cancelled.)
7. **Microtask-pump hook (the quiet quarter-killer, strategy §8).** The HTML event loop must drive the engine's job pump at spec microtask checkpoints, not let the engine self-schedule. Reserve a `engine.pumpMicrotasks()` call site in the event-loop/navigation controller now (no-op under `NoopEngine`), positioned at the spec checkpoint relative to tasks and rendering.
8. **Same-origin from first execution (strategy §9 MVP non-negotiable).** v1 has no script, but origin-keyed storage/cookie scoping (origin = scheme+host+port) must be in place so that when scripts arrive, one origin's script structurally cannot reach another origin's DOM/storage.

---

## 3. Toolchain & Dependencies

**Step 0 (blocking — not yet present):** Zig is **not installed** on this machine (`zig version` → not found; platform is Debian x86_64). First action of Phase 0 is to install and pin a Zig version.

- **Pin Zig** via `build.zig.zon` `minimum_zig_version` and a `.zigversion` file. Target the current stable (0.16.x as of 2026-04). **Pin hard** — pre-1.0 Zig breaks every ~6 months; budget for 1–2 migration cycles before 1.0 (late 2026). Treat a Zig upgrade as its own ticket with its own test run.
- **C libraries** (wrapped via Zig's `translate-c` from `build.zig`, the 0.16 replacement for `@cImport`):
  - **libcurl** — HTTP/1.1 + HTTP/2 + TLS with cert validation. (Avoids `std.http`'s missing HTTP/2 + TLS 1.2.)
  - **FreeType** — glyph rasterization (`hexops/freetype` build package).
  - **HarfBuzz** — text shaping. Never reimplement; no pure-Zig equivalent exists.
  - **SDL2** (or GLFW) — window, input, framebuffer blit. SDL2 chosen for simpler software-surface blitting.
- **Pure-Zig deps** (`build.zig.zon`): `zigimg` (PNG/JPEG decode).
- **Optional Rust bridge (fallback only):** if the pure-Zig HTML5 tree builder stalls, bridge `html5ever` via FFI as Lightpanda does. Decision point at end of Phase 2.

---

## 4. Test Strategy

**Three test tiers, all run in CI:**

1. **Unit tests** (`zig test`, colocated `test "..."` blocks) — the TDD workhorse. Every tokenizer state, selector-matching rule, box-layout case, and cascade resolution gets a focused test written *before* the code.
2. **WPT subset** — vendor a curated slice of Web Platform Tests covering: HTML parsing (`html/syntax/`), CSS cascade/specificity, and box model (`css/CSS2/`). Run as data-driven tests: input HTML/CSS → assert serialized DOM / computed style / box geometry. Start with ~50 tests, grow per milestone.
3. **Corpus snapshot tests** — the fixed 50-page corpus. Each page renders to a framebuffer; compare against an approved PNG snapshot (perceptual diff with tolerance). Catches regressions in real-world rendering. The 90% gate is measured here.

**Red-Green-Refactor discipline:** each behavior below is phrased Given/When/Then. Write the test, watch it fail (Red), implement minimally (Green), clean up (Refactor). No skipping Red.

**Fixtures:** local HTML/CSS files for unit tests (no network in unit tests — the no-side-effects-during-verify rule applies). Network only in a dedicated integration suite hitting a local static-file server, never live sites during automated verification.

---

## 5. Phased Milestones

Each phase ends with green tests and a demoable artifact. Build the vertical slice thin first, then widen.

### Phase 0 — Toolchain & skeleton
- Install + pin Zig. `build.zig` builds an empty exe and runs `zig test`.
- Wire one C dep end-to-end (libcurl) to prove `translate-c` + linking on Linux *and* macOS.
- **Behavior:** *Given a built binary, When run with `--version`, Then it prints and exits 0.*
- **Exit:** CI green on both platforms; libcurl symbol callable from Zig.

### Phase 1 — Fetch + arena
- `net/url.zig`: parse + resolve relative URLs. (Pure Zig, heavy unit tests — RFC 3986 cases.)
- `net/fetch.zig`: libcurl wrapper → bytes + content-type, **cert validation ON, no silent cert errors.**
- Page arena lifecycle: allocate on load, `deinit` on navigate — **wrapped in the §2.3.6 ordered-teardown hooks** (`severHandles` → `drainFinalizers` → `arena.deinit()`), no-op bodies in v1.
- Origin-keyed storage/cookie scope (origin = scheme+host+port) per §2.3.8.
- **Behaviors:**
  - *Given `http://localhost/x.html`, When fetched, Then body bytes + `text/html` returned.*
  - *Given an HTTPS URL with a bad cert, When fetched, Then it errors (does not silently accept).*
  - *Given two sequential loads, When the second begins, Then the first arena is freed (leak check passes).*
  - *Given a navigation, When teardown runs, Then the spy `ScriptEngine` records the full ordered sequence `stopScript → severHandles → drainFinalizers → (arena.deinit) → tearDownIsolate` (assert all five steps, in order — not just the middle two).*
  - *Given resources from two origins, When stored, Then each is keyed to its own origin (no cross-origin read).*
- **Exit:** can fetch a real HTTPS page to stdout; GPA reports zero leaks across N navigations; teardown-order test green.

### Phase 2 — HTML5 tokenizer → DOM  *(highest-risk phase)*
- `html/tokenizer.zig`: spec state machine. Build incrementally: data state → tags → attributes → character references → **script/raw-text states (capture, don't execute).**
- `html/tree_builder.zig`: insertion modes, the implicit-tag and misnesting recovery the spec mandates.
- `html/dom.zig`: Node/Element/Text, mutable tree API (event hooks reserved per §2.3). **Node reserves the inline wrapper-cache slot** (`script_wrapper: ?WrapperRef`, unused in v1) per §2.3.5.
- **Behaviors (sample):**
  - *Given `<p>Hi<b>x`, When parsed, Then DOM is `p > [text "Hi", b > text "x"]` with implicit closes.*
  - *Given `<script>let x=1<p>`, When parsed, Then script content is captured verbatim as text and NOT executed; following `<p>` parses normally.*
  - *Given malformed misnested tags, When parsed, Then recovery matches the WPT expected tree.*
  - *Given any parsed node, When inspected, Then its `script_wrapper` slot exists and is null (host-owns-handles readiness).*
- **Exit:** passes the HTML-parsing WPT subset. **Decision point:** if tree-builder conformance is stalling the schedule, bridge `html5ever` and revisit pure-Zig later.

### Phase 3 — CSS parse → CSSOM
- `css/tokenizer.zig` + `css/parser.zig`: rules, selectors (tag/class/id/descendant/child/pseudo subset), declarations, `@media`.
- **Behaviors:**
  - *Given `a.b > #c { color: red }`, When parsed, Then one rule with the correct selector chain + declaration.*
  - *Given a malformed declaration, When parsed, Then it's skipped and parsing continues (no crash).*
- **Exit:** parses the CSS of all 50 corpus pages without crashing; CSS-parsing unit tests green.

### Phase 4 — Cascade → ComputedStyle
- `css/cascade.zig`: selector matching (right-to-left), specificity, origin/`!important` ordering, inheritance, initial values.
- **Behaviors:**
  - *Given competing rules, When cascaded, Then higher specificity wins; source order breaks ties.*
  - *Given an inherited property unset on a child, When computed, Then it takes the parent's computed value.*
- **Exit:** passes the cascade/specificity WPT subset; every DOM node has a complete `ComputedStyle`.

### Phase 5 — Block + inline layout  *(the core milestone)*
- `layout/box.zig`, `layout/block.zig`: box model (content/padding/border/margin), block stacking, width/height resolution, margin collapsing.
- `layout/inline.zig`: line boxes, inline fragment measurement, UAX#14 line breaking, `text-align`, `line-height`.
- **Behaviors:**
  - *Given nested blocks with margins/padding, When laid out, Then each box has correct x/y/w/h (assert against WPT box-model geometry).*
  - *Given a long paragraph in a fixed width, When laid out, Then text wraps into correctly-measured line boxes.*
- **Exit:** box-model WPT subset green; box tree dumps match expected geometry for content pages.

### Phase 6 — Paint + text + window (first pixels)
- `paint/text.zig`: FreeType + HarfBuzz, glyph/font cache (process-lifetime), system font lookup.
- `paint/display_list.zig` + `paint/raster.zig`: rects, borders, backgrounds, text runs → software framebuffer.
- `platform/window.zig`: SDL2 window, blit framebuffer, scroll, link hit-test, dispatch navigation.
- Event-loop controller reserves the `pumpMicrotasks()` call site at the spec checkpoint (no-op under `NoopEngine`) per §2.3.7.
- **Behaviors:**
  - *Given a laid-out page, When painted, Then a framebuffer matches the approved snapshot (perceptual diff within tolerance).*
  - *Given a rendered page, When the user scrolls, Then the viewport offset updates and repaints.*
  - *Given a click on an `<a href>`, When hit-tested, Then the engine navigates and frees the prior arena.*
  - *Given one event-loop turn, When it completes, Then `pumpMicrotasks` is invoked once at the spec checkpoint (assert on a spy `ScriptEngine`).*
- **Exit:** **end-to-end vertical slice works** — URL in, scrollable styled page out, links navigate.

### Phase 7 — Floats
- `layout/float.zig`: `float`/`clear`, float-aware line-box width, block formatting contexts, margin-collapse interactions.
- **Behavior:** *Given Wikipedia-style `float: right` infobox, When laid out, Then surrounding text flows around it and `clear` works.*
- **Exit:** Wikipedia infobox articles render acceptably; float WPT cases green.

### Phase 8 — Images
- `image/decode.zig`: PNG/JPEG via zigimg; `<img>` as a replaced inline-block; intrinsic sizing; `width`/`height` attrs.
- **Behavior:** *Given `<img src>` with intrinsic 200×100, When laid out with no CSS size, Then the box is 200×100 and the decoded bitmap paints.*
- **Exit:** corpus pages with images render; **measure the 90% corpus gate → v1 done.**

---

## 6. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| HTML5 tree-builder conformance (Phase 2) eats the schedule | High | WPT-driven from day one; `html5ever` FFI fallback decision point at end of Phase 2 |
| Zig pre-1.0 breaking changes mid-project | High | Hard version pin; upgrades are isolated tickets with full test runs; expect 1–2 cycles before 1.0 |
| Inline layout + line breaking underestimated | Medium | Latin-only first; lean entirely on HarfBuzz for shaping; defer complex scripts |
| C interop friction on macOS (FreeType/HarfBuzz/SDL paths) | Medium | Prove both platforms in Phase 0 before building on the toolchain |
| Floats interact with everything | Medium | Sequenced last (Phase 7); time-boxed; WPT-gated |
| Snapshot tests flaky across font versions | Low | Bundle a fixed test font; perceptual-diff tolerance |
| v1 DOM omits wrapper-cache slot → v2 host-owns-handles forces DOM-wide refactor | High | Reserve `script_wrapper` slot in Phase 2; asserted by a unit test (§2.3.5) |
| v1 hard-codes a single engine → blocks bootstrap→end-state swap (QuickJS-ng → JSC/WASM) | Medium | Engine-agnostic `ScriptEngine` seam; no engine named in code (§2.3.1); engine chosen by `JS_ENGINE_STRATEGY.md` spikes |
| v1 navigation teardown ordered wrong → v2 finalizer UAF after `arena.deinit()` | High | Reserve the full 5-step order `stopScript→severHandles→drainFinalizers→deinit→tearDownIsolate` in Phase 1 (§2.3.6) — all four engine hooks, not just the middle two; call-sequence test asserts all five |
| Single-process v1 precludes later per-origin renderer split | Medium | Keep render/document boundary process-portable (strategy D9); no shared-address-space assumptions |

---

## 7. First Concrete Actions (Phase 0)
1. Install Zig (pin 0.16.x), commit `.zigversion` + `build.zig.zon` with `minimum_zig_version`.
2. `build.zig` building an exe + wiring `zig test`; CI on Linux + macOS.
3. `translate-c` wire libcurl; one passing test that calls `curl_version()` from Zig on both platforms.
4. Stand up the local static-file server fixture for integration tests.
5. Vendor the initial ~50-test WPT subset and the 50-page corpus manifest.
