# Plan Review Report: Zig Browser Post-v1 Roadmap — Detailed TDD Plan

> **Plan tier: L2** (confidence: medium) — 4 L2 keyword(s) detected, no dominant L1 or L3 signal — defaulting to L2 mid-tier
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ❌ | 13 issues |
| Interfaces | ❌ | 12 issues |
| Promises | ❌ | 10 issues |
| Data Models | ⚠️ | 7 issues |
| APIs | ❌ | 11 issues |

## Contracts Review

### Well-Defined
- ✅ ScriptEngine teardown order: stopScript → severHandles → drainFinalizers → arena.deinit → teardownIsolate — src/page.zig:92-104 (cited code confirms exact order)
- ✅ curl fetch error mapping: exit 51/60 → CertInvalid; other non-zero → NetError; 5 s max-time; cert validation on — src/net/fetch.zig:20-72 (cited code); mapCurlExit referenced at line 74
- ✅ SDL_VIDEODRIVER=dummy headless CI path for SdlDisplay init test — Cycle 0b.3 Red spec; Cycle 1.2 CI matrix
- ✅ Smoke tier is opt-in (SMOKE=1), skip-not-fail on network absence, excluded from the default test step — Cycle 2.1 edge cases; build.zig separate 'smoke' step
- ✅ Conformance harness: zero-case JSON is a hard failure (not a skip); cases.len > 0 asserted — Cycle 3.1 edge cases
- ✅ Write-to-temp-then-rename on --screenshot output to prevent partial PNGs on failure — Cycle 0a.2 Refactor step
- ✅ ScriptEngine.runScript return type NavError!void defined before this plan; reused, not redefined — src/script/engine.zig:15 (cited code)

### Missing or Unclear
- ⚠️ `renderPageArgb` input type is unspecified. The test says 'fixture page' but the function signature is absent — does it accept a `*Page`, a navigated `PipelineState`, an HTML `[]const u8`, or a URL string? Both `snapshot_gate.zig` and the new `main.zig --screenshot` path must agree on a single type. — Cycle 0a.1 Red test spec; 0a.2 dispatch in main.zig
- ⚠️ Arena/allocator ownership of the ARGB buffer is stated as 'preserved' but not contractually defined. When called from `main.zig`, who creates the arena, who passes it to `renderPageArgb`, and who deinits it? The buffer must stay live from render through `exportArgbPng`; the ownership chain is implicit. — Cycle 0a.1 edge cases; 0a.2 main.zig dispatch
- ⚠️ `NullDisplay` is described as capturing pixels 'for assertion', but the `Display` vtable only exposes `present`. No retrieval method (e.g., `lastFrame() ?[]const u32`) is defined on `NullDisplay`. Tests cannot read back captured pixels without a testing-only concrete-type method that sits outside the interface — this distinction is unspecified. — Cycle 0b.1 — NullDisplay spec; Testing Strategy
- ⚠️ `Display.present` pixel-slice lifetime/ownership is not contractually stated. `NullDisplay` 'copies the exact buffer' implying caller-owned, but nothing binds `SdlDisplay` or future backends to the same rule. If a backend caches a pointer, UAF is possible on the next repaint. — Cycle 0b.1 — present signature and NullDisplay edge cases
- ⚠️ SDL error normalization boundary is unnamed. SDL functions return NULL or a negative int on failure; the plan does not say where these are converted to named Zig errors inside `sdl_backend.zig`. No `sdlCheck` or equivalent normalization point is called out — raw SDL failure codes must not flow past `sdl_backend.zig` into `main.zig`. — Cycle 0b.3 Green; 0b.4 event translation
- ⚠️ `--screenshot` exit codes are not enumerated. The plan says 'map fetch/render errors to clear exit codes' in the Refactor step but lists no mapping. CI scripts and integration-test assertions cannot target specific codes. — Cycle 0a.2 Refactor step
- ⚠️ `present(w, h)` mismatch rejection — 'w/h mismatch rejected' but mismatch against what reference? The window's current size? A stored texture size set at init? The precondition source and the resulting error are both unstated. — Cycle 0b.1 edge cases
- ⚠️ Scroll-offset reset on link-click navigation is an implicit state-mutation choice. The plan says 'link click navigates+frees the prior arena+repaints' but does not state whether the scroll offset resets to (0, 0). The default must be named so it can be revisited for back-navigation. — Cycle 0b.4
- ⚠️ Resize behavior leaves two interpretations: 're-presents' could mean re-render at new dimensions or re-present the existing framebuffer. Which state slices are mutated and by whom is unspecified. — Cycle 0b.4 edge cases
- ⚠️ [VERIFY] Error-set convention for new modules. Cited code shows named Zig error-set unions. New components (`screenshot.zig`, `Display`, `SdlDisplay`) declare no named error sets. Verify whether the project requires a named error set per module boundary or whether `anyerror` propagation is accepted. — Cycles 0a.1, 0a.2, 0b.1, 0b.3
- ⚠️ WASM spike (v2a.3) foreign error normalization is unaddressed. WASM runtime traps are not Zig errors. The plan says nothing about where runtime traps are caught and normalized before they propagate into Zig business logic. — Cycle v2a.3 Green step
- ⚠️ `REQUIRE_SNAPSHOTS` env var contract is underspecified: read at comptime or runtime? Is any non-empty value truthy or only '1'? Must CI declare it as required or is it a per-step override? — Cycle 3.3 Green step

### Critical
- ❌ `Display.present` has no declared return type. If `void`, SDL errors are silently swallowed — the window shows stale or blank pixels with no recoverable signal. If `!void`/`DisplayError!void`, the vtable struct type, every backend, and every call site in `main.zig` must all change simultaneously. This choice must be made before writing cycle 0b.1, because reversing it is a blast-radius change. — Implementing `void` forces panics or silent pixel corruption on SDL failure; retrofitting `!void` after backends are written requires simultaneous edits to the vtable struct, NullDisplay, SdlDisplay, and every call site in main.zig.

### Recommendations
- Display vtable (0b.1): Before writing any cycle 0b.1 code, declare `present` as `present(pixels: []const u32, w: u32, h: u32) DisplayError!void` and define `const DisplayError = error{ TextureUpdateFailed, InvalidDimensions }` in `display.zig`. Document SDL mapping; NullDisplay always succeeds. Mirror the `ScriptEngine` vtable pattern.
- screenshot.zig arena contract (0a.1 / 0a.2): Declare `pub fn renderPageArgb(allocator, page: *Page) ![]u32` and `pub fn exportArgbPng(allocator, pixels, w, h, out_path) !void`. State that caller owns all allocations and callee retains no references past return.
- NullDisplay test retrieval (0b.1): Define `NullDisplay` as a concrete struct (`last_pixels, last_w, last_h`) implementing `Display` via vtable, mirroring `NoopEngine`. Expose a testing-only `lastFrame()` not part of the interface.
- SDL error normalization (0b.3 / 0b.4): Name a private `fn sdlCheck(result: c_int) DisplayError!void` in `sdl_backend.zig`. Cite it as the normalization point in cycle 0b.3's Green step.
- --screenshot exit codes (0a.2): Enumerate codes: 0 = success, 1 = URL parse failure, 2 = fetch failure, 3 = render failure, 4 = PNG write failure. Include in CLI help and assert in the integration test.
- Scroll and resize state mutation (0b.4): State explicitly that link-click navigation resets scroll to (0, 0) and that resize triggers a full re-render at the new viewport width, with the layout-viewport field updated before the render call. Name both as contract items.

## Interfaces Review

### Well-Defined
- ✅ ScriptEngine vtable (stopScript / severHandles / drainFinalizers / teardownIsolate / runScript / pumpMicrotasks) — Cited code src/script/engine.zig:10-17, all six fn-pointer signatures present
- ✅ teardown() ordering: stopScript → severHandles → drainFinalizers → arena.deinit → teardownIsolate — Cited code src/page.zig:92-104
- ✅ fetch signature: pub fn fetch(arena: std.mem.Allocator, io: std.Io, url: ParsedUrl) NetError!Response — Cited code src/net/fetch.zig:20
- ✅ curl_object hard-coded Linux path (confirmed gap, plan targets it) — Cited code build.zig:7; plan's cycle 1.1 removes it
- ✅ pumpMicrotasks call site in event_loop.runTurn — Cited code src/platform/event_loop.zig:42
- ✅ .screenshot Command payload field names: struct { url: []const u8, out: []const u8 } — Cycle 0a.2 Types section
- ✅ SDL pixel format: SDL_PIXELFORMAT_ARGB8888 (not _32); NullDisplay pixel-exact assertion precedes SDL — Cycle 0b.3 edge cases; Risks table
- ✅ SMOKE=1 opt-in env var gates real-web smoke tier; offline → SkipZigTest — Cycle 2.1 edge cases and Fixtures section
- ✅ REQUIRE_SNAPSHOTS=1 env var: absent → skip gracefully, present → hard failure on missing tools — Cycle 3.3 green step and edge cases

### Missing or Unclear
- ⚠️ [VERIFY] Command union's existing discriminants (§C.8 of v1 plan) are not in the cited code — cannot confirm whether adding .screenshot conflicts with an existing exhaustive switch in main.zig or elsewhere — Cycle 0a.2 Types section; src/main.zig:17-21 shows .open already dispatched
- ⚠️ [VERIFY] window.zig:clickNavigate — referenced in Cycle 0b.4 as the hit-test entry point but its parameters, return type, and error discipline appear nowhere in the plan or cited code — Cycle 0b.4 edge cases
- ⚠️ NullDisplay internal capture-buffer type and ownership not specified — test assertions must read back captured pixels, but whether the buffer is a slice, ArrayList, or fixed array (and who owns it) is undefined — Cycle 0b.1 green step
- ⚠️ SdlDisplay implementation mechanism for the Display interface not specified — whether it uses the fat-pointer pattern matching ScriptEngine, a comptime generic, or a wrapper fn is unstated; the conventional make() helper is also absent — Cycle 0b.3 refactor
- ⚠️ parseArgs function signature not defined — the Red step names the test but gives no parameter types, no return type, and no error discipline — Cycle 0a.2 red step
- ⚠️ WPT/html5lib JSON case struct type not defined — Cycle 3.1 says 'assert per case' but the Zig type representing a parsed case is never declared; the loader's public return type is therefore undefined — Cycle 3.1 green step
- ⚠️ REQUIRE_SNAPSHOTS check mechanism (comptime build-option vs runtime std.process.getEnvVarOwned) not specified — the two approaches have different allocator and error-handling implications; the plan is silent on which is used — Cycle 3.3 green step; src/paint/snapshot_gate.zig:28

### Critical
- ❌ Display.present return type absent — SDL can fail and w/h mismatch is 'rejected', so an error path clearly exists; without committing to a return type, NullDisplay and SdlDisplay cannot share a vtable signature and callers have no error contract — NullDisplay and SdlDisplay will be coded against incompatible signatures; whichever backend is written first silently sets the contract
- ❌ Display vtable struct shape not defined — the plan says 'injectable vtable interface' but never specifies the outer struct; the stated present signature also omits the mandatory *anyopaque self parameter all vtable fn-pointers carry — NullDisplay and SdlDisplay will be implemented against incompatible interface shapes; the missing *anyopaque param means the vtable fn-pointer type cannot be written without guessing
- ❌ event_loop.Event enum variants and payloads never defined — SDL_QUIT / MOUSEWHEEL / MOUSEBUTTONDOWN / WINDOWEVENT_RESIZED map to event_loop.Event but discriminants and payload fields are never stated; consumed by main.zig dispatch, SDL translation, and runTurn — The Red-step translation test cannot be written; mismatched payload assumptions will silently compile; scroll-sign normalization cannot be specified
- ❌ screenshot.zig public function signatures not defined — renderNavigatedPageArgb and exportArgbPng given no parameter lists or return types; both called by two independent callers (snapshot_gate.zig and main.zig), a multi-caller contract that must be settled first — snapshot_gate.zig re-import and main.zig dispatch coded against ad-hoc guesses; disagreement on dimensions or arena ownership silently breaks the existing snapshot gate
- ❌ Error-return discipline not stated for any new module — screenshot.zig, display.zig, sdl_backend.zig, and the --screenshot CLI define no error set names; the existing codebase consistently uses named error sets, violating the plan's own 'every public function MUST commit to ONE error-return discipline' requirement — Callers cannot write exhaustive error-switch branches; unnamed error sets compose into anyerror at module seams, silently swallowing errors

### Recommendations
- Display interface (Cycle 0b.1): Define the complete vtable struct following the ScriptEngine pattern: Display { ptr: *anyopaque, vtable: *const VTable } where VTable.present: *const fn (*anyopaque, []const u32, u32, u32) DisplayError!void; define DisplayError = error{ DimensionMismatch, BackendFailure }; add pub fn display(self) Display returning the fat pointer, mirroring NoopEngine.make().
- screenshot.zig (Cycles 0a.1, 0a.2): Specify both public signatures: pub fn renderPageArgb(arena, io, page: *Page, width, height) ScreenshotError![]u32 and pub fn exportArgbPng(io, pixels, width, height, path) ScreenshotError!void; define ScreenshotError = error{ RenderFailed, EncodeFailed, WriteFailed }; state the arena owns the returned []u32.
- event_loop.Event (Cycle 0b.4): Define the tagged union before the Red step: const Event = union(enum) { scroll: struct { delta_y: i32 }, click: struct { x: u32, y: u32 }, resize: struct { w: u32, h: u32 }, quit }; include the sign convention for delta_y.
- Error-return discipline (all new modules): Declare a named error set per module (ScreenshotError, DisplayError, CliError); all pub functions return NamedErrorSet!T exclusively — no anyerror, no mixed style.
- Command union (Cycle 0a.2): Inline the current Command discriminants from §C.8 of the v1 plan directly (or add them to cited ground truth) so implementors can verify the .screenshot addition is non-breaking.

## Promises Review

### Well-Defined
- ✅ Page teardown ordering: stopScript→severHandles→drainFinalizers→arena.deinit()→teardownIsolate — src/page.zig:92-104 (cited); Cycle 0b.4 reuses existing teardown-order test
- ✅ Atomic PNG output: write to temp file, rename on success; no partial file on fetch/render failure — Cycle 0a.2 Refactor
- ✅ Smoke harness: skip (never fail) when network unavailable; opt-in only via SMOKE=1 — Cycle 2.1 edge cases and Refactor
- ✅ SDL pixel format: ARGB8888 (not _32) with byte-order documented; NullDisplay unit-asserts exact pixels before SDL — Cycle 0b.3 edge cases; Cycle 0b.1 Refactor
- ✅ std.testing.allocator as the no-leak enforcement mechanism for all three button-churn spike tests (~10k cycles) — Tier 2 v2a intro; Cycles v2a.1–v2a.3
- ✅ Headless CI: SDL_VIDEODRIVER=dummy ensures SDL_Init succeeds without a display — Cycle 0b.3 edge cases; Cycle 1.2 Green
- ✅ WASM spike: linear-memory ABI structurally forbids raw DOM pointer passing; only handles cross the boundary — Cycle v2a.3 edge cases and Refactor

### Missing or Unclear
- ⚠️ SDL_Init failure path unspecified: Cycle 0b.3 covers the dummy success path and production happy path but specifies no behavior (error type, exit code, stderr message) when SDL_Init fails at runtime — Cycle 0b.3 — sdl-window-blit; SdlDisplay init
- ⚠️ Fetch error retryability not declared at new call sites: the screenshot CLI (0a.2) and smoke harness (2.1) both call fetch(), which emits error.Timeout, error.CertInvalid, error.TransferFailed. Per L2, retryable: true/false must be declared per error category at each new call site. — Cycles 0a.2 and 2.1; src/net/fetch.zig:43-46
- ⚠️ Smoke per-page timeout: 'per-page timeout' is mentioned but neither the value nor the on-timeout behavior is specified — skip this page only? abort the run? count as a crash? — Cycle 2.1 edge cases
- ⚠️ pumpMicrotasks returns void (confirmed in cited vtable): when real engines are wired in v2a, JS errors and unhandled promise rejections during the microtask pump are silently dropped. No behavioral guarantee about their surface or handling is stated. — src/platform/event_loop.zig:42; src/script/engine.zig:16; Cycles v2a.1–v2a.3
- ⚠️ XS moving-GC + pumpMicrotasks void return: the plan states 're-fetch pointers after GC' but does not specify the mechanism — how does Zig know GC ran when the function returns void? The button-churn test may not force a GC during a pump, leaving this path unverified. — Cycle v2a.2 edge cases and Refactor
- ⚠️ [VERIFY] NavError per-category retryability not declared: runScript returns NavError!void (cited engine.zig:15) but NavError's variants are defined in §C of the v1 plan (not cited here). If any category is retryable, the spike cycles must declare this, or reference §C explicitly. — src/script/engine.zig:15; §C Canonical Contracts (uncited)
- ⚠️ v2a.4 metric count inconsistency: the doc-lint test asserts 'all four metrics' but the plan lists five (ergonomics, teardown-correctness, perf, license, footprint). The pass condition cannot be implemented without resolving which set is authoritative. — Cycle v2a.4 Red and Green steps
- ⚠️ Screenshot CLI cancellation/signal handling unspecified: Cycle 0a.2 documents failure cleanup via temp-file rename but not behavior on SIGINT/SIGTERM mid-fetch or mid-render. The temp file may persist with no cleanup handler. — Cycle 0a.2 Refactor
- ⚠️ Memory-flatness for button-churn not quantified: std.testing.allocator detects only leaks-at-end, not per-iteration accumulation. A slow leak released only at teardown would pass while violating the flat-memory promise. — Tier 2 v2a intro; Cycles v2a.1–v2a.3

### Critical
- ❌ SDL + page teardown combined ordering unspecified: Cycle 0b.4 specifies SDL teardown and independently asserts page teardown order, but not where page.teardown() falls relative to SDL_DestroyTexture on the SDL_QUIT path. If a quit handler frees the arena containing the pixel buffer before SDL_DestroyTexture, and a queued repaint event then drains present() with the freed slice, the result is a UAF. The two sequences are each well-specified; their composition is not. — UAF in the pixel buffer: SDL_UpdateTexture called with a slice into a freed arena; corrupts the final frame and may crash; defeats the teardown-correctness guarantee the plan prioritizes

### Recommendations
- Cycle 0b.4 — quit teardown composition (critical fix): Add an explicit combined ordering: 'On SDL_QUIT: (1) set a quit flag and exit the event loop — no further events processed; (2) call page.deinit(); (3) then SDL_DestroyTexture → SDL_DestroyRenderer → SDL_DestroyWindow → SDL_Quit.' Extend the teardown-order test to assert the full composed sequence.
- Cycles 0a.2 and 2.1 — fetch error retryability: Add a small table per cycle declaring retryable: true/false per category — for the screenshot CLI all are not-retryable; for the smoke harness Timeout/CertInvalid/TransferFailed → skip this page. Defer policy details per L2.
- Cycle 0b.3 — SDL_Init failure: Add 'if SDL_Init returns < 0, call SDL_GetError(), write the message to stderr, and return error.SdlInitFailed; the process exits nonzero via main's error propagation.'
- Cycle 2.1 — smoke per-page timeout: Specify the timeout value and the on-timeout behavior ('skip this page, log URL and elapsed time, continue') as a named edge case.
- Cycle v2a.2 — XS moving-GC + pumpMicrotasks void return: Specify 'after pumpMicrotasks() returns, all live WrapperRef handles must be re-resolved through the handle table; no cached raw XS pointers survive across a pump call.' Add a sub-case that forces an XS GC during a pump.
- Cycle v2a.4 — doc-lint metric count: Resolve four-vs-five: pick a definitive list (suggest all five) and align both the doc-lint assertion and decision-record template by name.
- Tier 2 v2a — button-churn memory-flatness: Replace 'memory flat' with a testable predicate: 'wrap std.testing.allocator with a counting allocator; assert live-allocation count after cycle N equals after cycle 1.'

## Data Models Review

### Well-Defined
- ✅ ScriptEngine.VTable — src/script/engine.zig:10-17, 6 methods, all fully typed
- ✅ Page teardown field-reset sequence — src/page.zig:92-104, ordered nullification; engine outlives arena
- ✅ fetch.Response struct — src/net/fetch.zig:67-71, status:u16, content_type:[]u8, bytes:[]u8; content_type default 'application/octet-stream' when empty
- ✅ Display.present vtable signature — Cycle 0b.1, NullDisplay copy-exact-buffer semantics; pitch = w*4; w/h mismatch rejected
- ✅ Command.screenshot variant struct — Cycle 0a.2, .screenshot: struct { url, out } as extension of §C.8 Command enum

### Missing or Unclear
- ⚠️ [VERIFY] event_loop.Event type schema — variants and field types not defined or cited; SDL_MOUSEWHEEL delta type (i32 vs f32), MOUSEBUTTONDOWN coordinate types, WINDOWEVENT_RESIZED payload shape all unspecified — Cycle 0b.4
- ⚠️ ARGB buffer element type inconsistent across modules — Display.present declares pixels: []const u32 but screenshot module buffer type is unnamed; if screenshot.zig returns []u8 it cannot be passed directly to Display.present — Cycle 0a.1 Refactor vs 0b.1 Green vs 0b.3
- ⚠️ Command.screenshot missing width/height fields — plan names 'default 1024×768' but the struct is only { url, out }; unspecified whether dimensions are optional fields with defaults or compile-time constants — Cycle 0a.2 edge cases
- ⚠️ Decision record metric count self-contradicts — v2a.4 asserts 'all four metrics' but the plan enumerates five (ergonomics, teardown order, perf, license, footprint) — Cycle v2a.4 Red vs v2a.1/.2/.3 Refactor and Risks table
- ⚠️ Smoke fixture schema undefined — cycle 2.1 references 'a fixture of Wikipedia/MDN/HN URLs' and asserts 'node-count > N' / 'non-blank framebuffer' but neither the fixture format nor the threshold N is specified — Cycle 2.1 Green and Refactor steps
- ⚠️ [VERIFY] WrapperRef field types not confirmed — plan describes WrapperRef{index, generation} as existing in src/html/dom.zig but cited code does not show the struct; field types (u32? usize? u64?) unknown; spike tests build a handle table against this type — §C Carry-forward + Cycles v2a.1–v2a.3
- ⚠️ Page state-slicing vocabulary absent — Page is touched by teardown() (full reset) and v2b navigate() (partial reset with engine retained); no explicit labels separate navigation-scoped from session-scoped fields; without this vocabulary the v2b navigate() contract is unspecifiable — src/page.zig:92-104 + v2b outline

### Critical
- None.

### Recommendations
- event_loop.Event: Add a schema table to cycle 0b.4 listing every variant with typed fields, e.g. Scroll{ dy: i32 }, Click{ x: u32, y: u32, button: u8 }, Resize{ w: u32, h: u32 }, Quit{}. If the type already exists, cite file and line.
- ARGB buffer element type: Canonicalise on []const u32 (matches SDL_PIXELFORMAT_ARGB8888 and Display.present) and apply it in screenshot.zig's return type and snapshot_gate.zig's reuse. Add a comment for byte layout (0xAARRGGBB, little-endian). Specify the allocator NullDisplay uses when copying.
- Command.screenshot width/height: Make the dimension policy explicit — add default-valued fields (w: u32 = 1024, h: u32 = 768) or a comment citing the compile-time constant name.
- Decision record metric schema: Resolve four-vs-five by explicitly listing the metrics the doc-lint test checks, e.g. [ergonomics_locs, teardown_complexity, throughput_ops_per_sec, license_spdx, wasm_footprint_bytes]. Update v2a.4 Red to match.
- Smoke fixture: Define the schema inline in cycle 2.1 (recommend a JSON array of { url, min_node_count, timeout_ms }) and choose an initial threshold N.
- Page state-slicing vocabulary: Before v2b, add a field-classification table labeling dom_root, style_for, box_root, render_checksum, current_url, has_loaded as 'navigation-scoped' and engine as 'session-scoped'.

## APIs Review

### Well-Defined
- ✅ ScriptEngine vtable (6-method) — Confirmed by ground truth src/script/engine.zig:10-17; teardown order at src/page.zig:92-104
- ✅ fetch(arena, io, url: ParsedUrl) NetError!Response — Confirmed by src/net/fetch.zig:20-72; curl subprocess, --max-time 5, cert error mapping
- ✅ --screenshot out.png <url> CLI shape; .screenshot: struct { url, out } Command variant — Cycle 0a.2; consistent with .open tagged-union pattern in main.zig:17-21
- ✅ SMOKE=1 and REQUIRE_SNAPSHOTS=1 environment-variable gates — Cycle 2.1 and Cycle 3.3; semantics clearly stated
- ✅ SDL_VIDEODRIVER=dummy for headless CI SDL init — Cycle 0b.3 and Tier 1·1 / Cycle 1.2
- ✅ v2a button-churn acceptance criteria: no-leak + no-UAF under std.testing.allocator across ~10k cycles — Cycles v2a.1–v2a.3

### Missing or Unclear
- ⚠️ Display.present return type is unspecified — signature given as present(pixels, w, h) but no return type; SdlDisplay operations are fallible, so the vtable needs void or !void — Cycle 0b.1 — display-interface
- ⚠️ Pixel format is prose-only: u32 element semantics (ARGB8888, little-endian, high-byte alpha) documented in cycle 0b.3 narrative but not encoded in the type signature; NullDisplay and SdlDisplay can silently disagree on byte order — Cycle 0b.1 and 0b.3
- ⚠️ NullDisplay captured-pixel retrieval API not defined; the test must access the captured buffer but no accessor method or field is specified — Cycle 0b.1 Red test requirement
- ⚠️ event_loop.Event enum shape not defined anywhere; cycle 0b.4 asserts produced values for scroll/click/resize/quit but variant names, payloads, and exhaustive set are unspecified — Cycle 0b.4 — sdl-event-loop
- ⚠️ Naming inconsistency within cycle 0a.1: plan says 'move renderNavigatedPageArgb + exportArgbPng' (keeping original names) but the Red test is named 'screenshot.renderPageArgb produces…' — two names for the same function will break a call site — Cycle 0a.1 Red vs Green step
- ⚠️ Exit codes for --screenshot failure paths not enumerated; 'map fetch/render errors to clear exit codes' but no specific code mapping — Cycle 0a.2 Refactor step
- ⚠️ Spike handle table interface shape not specified; cycles v2a.1–v2a.3 say 'implement the minimal handle table' but give no API, no entry struct, no error set — each spike may invent incompatible shapes, undermining comparative evaluation — Cycles v2a.1, v2a.2, v2a.3
- ⚠️ Smoke test assertion thresholds unspecified: 'box-tree node count > threshold' and 'framebuffer not blank (checksum ≠ all-white)' leave N and the checksum sentinel undefined; pass conditions are non-deterministic — Cycle 2.1 Green step
- ⚠️ [VERIFY] Full Command enum shape: only the .open variant is confirmed by ground truth (main.zig:17-21); if the existing switch is exhaustive, adding .screenshot is a breaking change producing compile errors at every unmodified switch site — Cycle 0a.2; src/cli.zig and all Command switch sites
- ⚠️ NavError error set (return type of runScript) referenced in ground truth (engine.zig:15) but its variants are not defined in this plan; new spike code calling runScript cannot handle errors without this definition — src/script/engine.zig:15; Cycles v2a.1–v2a.3

### Critical
- ❌ Display vtable has no deinit/lifecycle method: cycle 0b.1 defines only present(…), but cycle 0b.4 requires ordered SDL teardown on quit; if main.zig holds a Display interface value (not a concrete SdlDisplay), there is no vtable slot to trigger SDL resource release — either SDL resources leak, or main.zig holds the concrete type and bypasses the interface, breaking the backend-agnostic abstraction — SDL handle leak on every quit, or the Display abstraction is hollow and NullDisplay cannot be substituted in main.zig — the testability argument for the vtable design collapses

### Recommendations
- Display vtable (cycle 0b.1): Add deinit: *const fn (*anyopaque) void alongside present; NullDisplay.deinit is a no-op; SdlDisplay.deinit executes the DestroyTexture→DestroyRenderer→DestroyWindow→SDL_Quit sequence; main.zig calls display.deinit() in its defer chain.
- Display.present signature (cycle 0b.1): Decide and document the return type — recommend !void; if void, document the error-swallowing policy; add a comptime-visible pixel_format constant to the vtable or companion DisplayInfo struct.
- event_loop.Event (cycle 0b.4): Define the tagged union explicitly before Red: .scroll{ delta_y: i32 }, .click{ x: u32, y: u32 }, .resize{ w: u32, h: u32 }, .quit; name the source file.
- renderNavigatedPageArgb naming (cycle 0a.1): Pick one canonical name before writing the Red test — keep renderNavigatedPageArgb or rename to renderPageArgb and update all callers.
- Spike handle table (cycles v2a.1–v2a.3): Define a minimal shared interface in the v2a preamble (e.g. get(WrapperRef) ?*Node, put(*Node) WrapperRef, invalidate(WrapperRef) void) so all three spikes exercise a comparable API.
- CLI exit codes (cycle 0a.2): Enumerate exit codes, e.g. 0=success, 1=fetch failure, 2=render failure, 3=output write failure.
- NullDisplay accessor (cycle 0b.1): Define a NullDisplay.lastFrame() []const u32 or a public last_pixels field so the Red test can retrieve and compare the buffer.

## Critical Issues (Must Address Before Implementation)

- ❌ **Contracts:** `Display.present` has no declared return type. The void-vs-`!void` choice must be made before writing cycle 0b.1, because reversing it is a blast-radius change across the vtable struct, NullDisplay, SdlDisplay, and every call site in main.zig.
- ❌ **Interfaces:** Display.present return type absent — NullDisplay and SdlDisplay cannot share a vtable signature and callers have no error contract; whichever backend is written first silently sets the contract.
- ❌ **Interfaces:** Display vtable struct shape not defined — the outer struct is never specified and the stated present signature omits the mandatory *anyopaque self parameter; backends will be implemented against incompatible shapes.
- ❌ **Interfaces:** event_loop.Event variants and payloads never defined — the Red-step translation test cannot be written; mismatched payload assumptions will silently compile.
- ❌ **Interfaces:** screenshot.zig public function signatures not defined — a multi-caller contract (snapshot_gate.zig and main.zig) that must be settled before either caller is written.
- ❌ **Interfaces:** Error-return discipline not stated for any new module — unnamed error sets compose into anyerror at module seams, violating the plan's own one-error-discipline requirement.
- ❌ **Promises:** SDL + page teardown combined ordering unspecified — risks a UAF into freed arena memory if page.deinit() runs before SDL teardown or a repaint is processed mid-quit.
- ❌ **APIs:** Display vtable has no deinit/lifecycle method — SDL resources leak on quit, or main.zig must hold the concrete type and bypass the interface, collapsing the backend-agnostic design.

## Approval Status

- [ ] Ready for Implementation — no critical issues
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues must be resolved first


## Beads Tracking

Epic: **[Plan Review Epic] 2026-05-30-16-46-ENG-0002-tdd-zig-browser-post-v1 — 8 critical, 45 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **8** critical, **45** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | critical | [Plan Review §contracts] `Display.present` has no declared return type. If the vtabl… <!-- fp:d8222092 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `renderPageArgb` input type is unspecified. The test says '… <!-- fp:90615ea7 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Arena/allocator ownership of the ARGB buffer is stated as '… <!-- fp:1fb8300a --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `NullDisplay` is described as capturing pixels 'for asserti… <!-- fp:a80891ae --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `Display.present` pixel-slice lifetime/ownership is not con… <!-- fp:853913ab --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] SDL error normalization boundary is unnamed. SDL functions … <!-- fp:4f6eef71 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `--screenshot` exit codes are not enumerated. The plan says… <!-- fp:cdd36546 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `present(w, h)` mismatch rejection — 'w/h mismatch rejected… <!-- fp:bda7e2ce --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Scroll-offset reset on link-click navigation is an implicit… <!-- fp:21269d8f --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Resize behavior leaves two interpretations: 're-presents' c… <!-- fp:08b5579c --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] [VERIFY] Error-set convention for new modules. Cited code s… <!-- fp:f9a79ad0 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] WASM spike (v2a.3) foreign error normalization is unaddress… <!-- fp:39be9c52 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] `REQUIRE_SNAPSHOTS` env var contract is underspecified: (a)… <!-- fp:7811a965 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] Display.present return type absent — the plan writes 'prese… <!-- fp:615213c5 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] Display vtable struct shape not defined — the plan says 'in… <!-- fp:ef46c3d8 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] event_loop.Event enum variants and payloads are never defin… <!-- fp:df5b5346 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] screenshot.zig public function signatures not defined — the… <!-- fp:7e15620f --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] Error-return discipline not stated for any new module — scr… <!-- fp:ff057009 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] Command union's existing discriminants (§C.8 of v1… <!-- fp:5df6ef24 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] window.zig:clickNavigate — referenced in Cycle 0b.… <!-- fp:788eeb22 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] NullDisplay internal capture-buffer type and ownership not … <!-- fp:369ee463 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] SdlDisplay implementation mechanism for the Display interfa… <!-- fp:19a50f2c --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] parseArgs function signature not defined — the Red step nam… <!-- fp:90b50801 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] WPT/html5lib JSON case struct type not defined — Cycle 3.1 … <!-- fp:86d44556 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] REQUIRE_SNAPSHOTS check mechanism (comptime build-option vs… <!-- fp:48bbd5d8 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] SDL + page teardown combined ordering unspecified: Cycle 0b… <!-- fp:077e41df --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] SDL_Init failure path unspecified: Cycle 0b.3 covers the SD… <!-- fp:236f4232 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Fetch error retryability not declared at new call sites: th… <!-- fp:eb2d3ada --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Smoke per-page timeout: 'per-page timeout' is mentioned but… <!-- fp:adbeb3db --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] pumpMicrotasks returns void (confirmed in cited vtable): wh… <!-- fp:4bf4767f --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] XS moving-GC + pumpMicrotasks void return: the plan states … <!-- fp:bdf391b8 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] [VERIFY] NavError per-category retryability not declared: r… <!-- fp:89c2210d --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] v2a.4 metric count inconsistency: the doc-lint test is spec… <!-- fp:44b885d4 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Screenshot CLI cancellation/signal handling unspecified: Cy… <!-- fp:b565a286 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Memory-flatness for button-churn not quantified: 'memory fl… <!-- fp:793189f4 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] event_loop.Event type schema — variants and field … <!-- fp:b3113651 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] ARGB buffer element type inconsistent across modules — Disp… <!-- fp:1c00b69a --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Command.screenshot missing width/height fields — plan names… <!-- fp:d5d641d1 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Decision record metric count self-contradicts — v2a.4 Red p… <!-- fp:3ceff6fa --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Smoke fixture schema undefined — cycle 2.1 references 'a fi… <!-- fp:4737c239 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] WrapperRef field types not confirmed — plan descri… <!-- fp:01cf9bf7 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Page state-slicing vocabulary absent — Page is a multi-fiel… <!-- fp:77567527 --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] Display vtable has no deinit/lifecycle method: cycle 0b.1 d… <!-- fp:33fa9955 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Display.present return type is unspecified — plan states th… <!-- fp:3988968f --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Pixel format is prose-only: u32 element semantics (ARGB8888… <!-- fp:b4805b82 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] NullDisplay captured-pixel retrieval API is not defined; th… <!-- fp:7980d6c0 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] event_loop.Event enum shape is not defined anywhere in this… <!-- fp:1e5ba409 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Naming inconsistency within cycle 0a.1: the plan says 'move… <!-- fp:34f5f189 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Exit codes for --screenshot failure paths are not enumerate… <!-- fp:c22965ff --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Spike handle table interface shape is not specified; cycles… <!-- fp:c8e9eb72 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Smoke test assertion thresholds are unspecified: 'box-tree … <!-- fp:95065448 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] [VERIFY] Full Command enum shape: only the .open variant is… <!-- fp:1423ea6e --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] NavError error set (return type of ScriptEngine.runScript) … <!-- fp:bb16e7da --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.