# Plan Review Report: Zig Browser v1 — Detailed TDD Implementation Plan

> **Plan tier: L1** (confidence: high) — 3 L1 keyword(s) + plan size 517 lines (bounded scope; L1 >= L2 signal)
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 7 issues |
| Interfaces | ❌ | 16 issues |
| Promises | ⚠️ | 11 issues |
| Data Models | ❌ | 11 issues |
| APIs | ⚠️ | 11 issues |

## Contracts Review

### Well-Defined
- ✅ Arena-per-page invariant with std.testing.allocator leak detection — Cycle 1.5: 'std.testing.allocator flags any unfreed node'; N repeated navigations must stay flat; confirmed at Plans/TDD_IMPLEMENTATION_PLAN.md:33-36
- ✅ Navigation teardown order: severHandles → drainFinalizers → arena.deinit — Cycle 1.6: SpyScriptEngine records exact sequence; matches JS_ENGINE_STRATEGY.md:69-77 steps 2-4
- ✅ `<script>` capture-not-execute: runScript spy count == 0 asserted — Cycle 2.3; confirmed at Plans/TDD_IMPLEMENTATION_PLAN.md:77
- ✅ TLS certificate verification unconditionally ON — Cycle 1.4: CURLOPT_SSL_VERIFYPEER/VERIFYHOST asserted; error.CertInvalid named
- ✅ Engine-agnostic seam: no symbol/type/comment may name a specific engine — Cycle 1.6 refactor; confirmed at Plans/TDD_IMPLEMENTATION_PLAN.md:76
- ✅ Origin equality contract: scheme+host+port with default-port normalization, reflexive/symmetric tested — Cycle 1.7
- ✅ URL round-trip idempotence: parse(serialize(parse(u))) == parse(u) — Cycle 1.1 property loop
- ✅ Layout never mutates the DOM — Cycle 5.1; confirmed at Plans/TDD_IMPLEMENTATION_PLAN.md:79
- ✅ Cross-origin read returns error.CrossOriginDenied — Cycle 1.7

### Missing or Unclear
- ⚠️ fetch() error taxonomy incomplete: only error.CertInvalid named; no errors for DNS failure, connection refused, timeout; transport-error-vs-Response.status rule unstated — Cycles 1.3 and 1.4
- ⚠️ runScript() vtable method has no input/output contract: parameter and return types absent; v2 has no agreed shape to target — Cycle 1.6; Plans/TDD_IMPLEMENTATION_PLAN.md:76
- ⚠️ WrapperRef type body undefined: 'opaque generational-handle placeholder' with no fields/size; affects per-node arena pressure — Cycle 2.6
- ⚠️ store.zig value contract undefined: stored data, value type, and write isolation all unspecified on a security boundary — Cycle 1.7; Plans/TDD_IMPLEMENTATION_PLAN.md:83 §2.3 item 8
- ⚠️ pumpMicrotasks call-site position within the event-loop turn not asserted: ordering relative to task-body and rendering step unverified — Cycle 6.4
- ⚠️ No vtable hook reserved for teardown step 1 ('stop script execution; block new tasks/microtasks'): forces a new call site in v2 — Cycle 1.6 vs JS_ENGINE_STRATEGY.md:69-77 step 1
- ⚠️ Process-lifetime vs page-arena boundary has no complementary survival test: no test asserts font cache / libcurl handle / connection pool survive navigation — Cycle 1.5 / Plans/TDD_IMPLEMENTATION_PLAN.md:36; Cycle 6.1 refactor

### Critical
- None

### Recommendations
- fetch() error contract (Cycles 1.3–1.4): Enumerate the complete Zig error set (DnsFailure, Timeout, ConnectionRefused, CertInvalid) and state 'CURLE_* codes become named Zig errors; HTTP 4xx/5xx surface in Response.status'; add a non-TLS transport-failure integration test.
- runScript() vtable signature (Cycle 1.6): Add a concrete stub now, e.g. `runScript(self: *ScriptEngine, source: []const u8, base_url: []const u8) void`, marked as v2 fill-in.
- WrapperRef type (Cycle 2.6): Define as explicit zero-size sentinel `const WrapperRef = struct {};` with a comment to replace with `struct { index: u32, generation: u32 }` in v2.
- store.zig value contract (Cycle 1.7): Narrow to a concrete scope (cookie jar / response-cache / bytes-per-origin), add a cross-origin write test alongside the read test.
- pumpMicrotasks ordering (Cycle 6.4): Extend the spy to record a 'repaint' event and assert 'pumpMicrotasks' precedes 'repaint'.
- Missing stopScript teardown hook (Cycle 1.6): Add stopScript()/blockNewTasks() to the vtable, call it first inside teardown(), and assert order [stopScript, severHandles, drainFinalizers].

## Interfaces Review

### Well-Defined
- ✅ parseArgs([]const []const u8) -> Command — Cycle 0.2 Green
- ✅ fetch(allocator, io, url) -> Response{bytes, content_type, status} — Cycle 1.3 Green
- ✅ CurlHandle.init / CurlHandle.deinit — Cycle 0.3 Refactor
- ✅ script_wrapper: ?WrapperRef = null field on all DOM nodes — Cycle 2.6 Green
- ✅ ScriptEngine vtable method names: severHandles, drainFinalizers, runScript, pumpMicrotasks — Cycle 1.6 Green
- ✅ Origin{scheme, host, port} struct with normalization and equality — Cycle 1.7 Green
- ✅ error.CertInvalid in the fetch error set — Cycle 1.4 Red
- ✅ error.CrossOriginDenied from origin-keyed store — Cycle 1.7 Red
- ✅ SpyScriptEngine records calls into an unmanaged ArrayList; NoopEngine implements the same vtable as no-op — Cycle 1.6 Red/Green

### Missing or Unclear
- ⚠️ ScriptEngine method return types not stated for severHandles, drainFinalizers, pumpMicrotasks — Cycles 1.6, 6.4 Green
- ⚠️ ScriptEngine representation undecided ('vtable or tagged union'); tagged union is incompatible with the engine-swap goal — Cycle 1.6 Green; TDD_IMPLEMENTATION_PLAN.md:76
- ⚠️ WrapperRef concrete type not specified; v1/v2 potentially type-incompatible — Cycle 2.6 Green
- ⚠️ HTML tokenizer API shape not specified (pull iterator vs callback vs slice) — Cycles 2.1–2.5 Green
- ⚠️ HTML tree builder public API not stated — Cycles 2.4, 2.5
- ⚠️ Response struct field types not specified (bytes/status/content_type lifetimes) — Cycle 1.3 Green
- ⚠️ ParsedUrl struct fields not formally specified — Cycle 1.1 Red/Green
- ⚠️ Command enum .open variant payload not specified — Cycle 0.2 Green
- ⚠️ fetch() error set incomplete beyond error.CertInvalid — Cycles 1.3–1.4 Refactor
- ⚠️ Origin-keyed store public interface (get/set/delete, ownership) not specified — Cycle 1.7 Green
- ⚠️ CSS parser, cascade, layout, and paint modules have no public function signatures — Phases 3–6 Green
- ⚠️ Error-return discipline not committed per module (sentinel vs error union) — Cycles 0.2, 1.3, 1.4, 1.7
- ⚠️ ScriptEngine vtable has no stated extension policy (additive-only rule) — Cycle 1.6; Phase 1 seam
- ⚠️ Visibility modifiers (pub vs file-private) not stated for any declaration — all cycles

### Critical
- ❌ ScriptEngine.runScript parameter types are undefined (literal ellipsis) — Cycles 1.6 and 2.3 cannot be implemented; NoopEngine and SpyEngine require a concrete signature to compile, and any ad-hoc v1 signature breaks at the v2 seam
- ❌ Page.navigate() signature is never defined — Cycles 1.5, 1.6, 6.3 invoke it without a definition; implementers will invent incompatible signatures, discovered only at Cycle 6.3 integration, forcing a refactoring pass

### Recommendations
- ScriptEngine.runScript: Add `fn runScript(self: *ScriptEngine, source: []const u8, source_url: []const u8) void` to Cycle 1.6 Green; NoopEngine ignores args; comment what v2 passes.
- ScriptEngine method return types: State `void` for severHandles, drainFinalizers, pumpMicrotasks.
- ScriptEngine representation: Commit to a vtable struct (extern struct with fn-pointer fields), not a tagged union.
- Page.navigate(): Define `fn navigate(self: *Page, url: ParsedUrl) !void` in Cycle 1.5 Green before 1.6 and 6.3 reference it.
- WrapperRef: Specify `const WrapperRef = struct { index: u32, generation: u32 };` per JS_ENGINE_STRATEGY.md §2.1.
- HTML tokenizer API shape: Commit to `fn next(self: *Tokenizer) ?Token` (or callback) in Cycle 2.1 Green.
- Response struct field types: Specify `bytes: []const u8` (arena-owned), `content_type: []const u8`, `status: u16` with ownership note in Cycle 1.3.
- Error-return discipline: Declare cli.zig uses sentinel returns; all other public modules use typed error-set unions (not anyerror).
- Command enum .open payload: `const Command = union(enum) { version, usage, open: []const u8 }`.

## Promises Review

### Well-Defined
- ✅ URL round-trip idempotence over generated valid inputs — Cycle 1.1 Refactor
- ✅ Arena freed on all navigate paths including mid-parse failure — Cycle 1.5
- ✅ Teardown call ordering severHandles → drainFinalizers before arena.deinit — Cycle 1.6; JS_ENGINE_STRATEGY.md §2.2
- ✅ `<script>` captured verbatim, never executed in v1 (spy count == 0) — Cycle 2.3
- ✅ TLS verification unconditionally enforced — Cycle 1.4 Refactor
- ✅ script_wrapper slot null on every node type in v1 — Cycle 2.6
- ✅ Cross-origin reads return error.CrossOriginDenied; equality reflexive/symmetric — Cycle 1.7
- ✅ Layout never mutates the DOM; box tree is derived read-only view — Cycle 5.1 Refactor
- ✅ Finalizer running is opportunistic; correctness must not depend on it firing — JS_ENGINE_STRATEGY.md §2.4

### Missing or Unclear
- ⚠️ Fetch timeout behavior unspecified: no duration, no error value for hung connection — Cycles 1.3, 1.4
- ⚠️ No halt-vs-log+continue disposition declared for any emitted error category — Cycles 1.3, 1.4, 1.7
- ⚠️ SpyScriptEngine call-record ArrayList allocator unspecified; could mask real leaks — Cycles 1.6, 6.4
- ⚠️ Test infrastructure teardown guarantee absent for local static/TLS servers — Cycles 1.3, 1.4
- ⚠️ Process-lifetime font/glyph cache deinit site not specified; may trip the leak gate — Cycle 6.1 Refactor
- ⚠️ Failed-parse arena cleanup mechanism (errdefer) not prescribed; failure path has no dedicated test — Cycle 1.5
- ⚠️ pumpMicrotasks 'one event-loop turn' boundary undefined; spy assertion can be vacuously satisfied — Cycle 6.4
- ⚠️ drainFinalizers synchrony contract unspecified (must it block before arena.deinit?) — Cycle 1.6 Refactor; JS_ENGINE_STRATEGY.md §2.2
- ⚠️ Teardown seam missing hooks for strategy steps 1 and 5 — Cycle 1.6 Green; JS_ENGINE_STRATEGY.md §2.2
- ⚠️ [VERIFY] Fetch blocking vs. async mode not specified; async/multi mode risks use-after-free during navigate — Cycles 1.3 and 1.5
- ⚠️ Leak-detection coverage limited to Zig-side allocations; libcurl internal malloc not tracked — Cycle 0.3 Refactor and Cycle 1.5

### Critical
- None

### Recommendations
- Fetch timeout (Cycles 1.3, 1.4): Define CURLOPT_TIMEOUT_MS, document 'halt with error on expiry', add a Red step with a server that never sends data.
- Error disposition (Cycles 1.3, 1.4, 1.7): Add a one-line halt/log+continue comment per error category; no retry machinery at this tier.
- SpyScriptEngine ArrayList (Cycles 1.6, 6.4): Allocate from std.testing.allocator with a defer free.
- Test server teardown (Cycles 1.3, 1.4): Add defer-based shutdown immediately after startup.
- Font/glyph cache cleanup (Cycle 6.1): Name a concrete deinit call site; in integration tests use std.testing.allocator with deferred deinit.
- Failed-parse arena cleanup (Cycle 1.5): Add 'mid-parse-fail leaves zero leaks' Red step; specify errdefer arena.deinit().
- pumpMicrotasks turn definition (Cycle 6.4): Define 'one turn' as one SDL-event-drain-and-dispatch call; anchor the assertion to that boundary.
- drainFinalizers synchrony (Cycle 1.6): Comment that it must be synchronous/blocking.
- Teardown seam completeness (Cycle 1.6): Add stopScript hook before severHandles; note tearDownIsolate as future addition.
- Fetch blocking contract (Cycles 1.3, 1.5): Note v1 uses curl's blocking easy interface; flag that async curl requires a fetch-cancel before arena.deinit.

## Data Models Review

### Well-Defined
- ✅ script_wrapper field on DOM nodes — Cycle 2.6: `script_wrapper: ?WrapperRef = null`; corroborated by Plans/TDD_IMPLEMENTATION_PLAN.md:80
- ✅ ScriptEngine vtable (four methods, NoopEngine wiring, teardown ordering) — Cycle 1.6
- ✅ Command tagged union (.version, .open, .usage; unknown-flag → .usage) — Cycle 0.2
- ✅ Page / arena ownership and lifecycle — Cycle 1.5 + Plans/TDD_IMPLEMENTATION_PLAN.md:34
- ✅ Origin equality semantics (scheme+host+port, default-port normalization) — Cycle 1.7

### Missing or Unclear
- ⚠️ ParsedUrl field types/optionality unspecified; serialize() determinism depends on absent-port representation — Cycle 1.1 (src/net/url.zig)
- ⚠️ port field type in ParsedUrl vs Origin not aligned; normalization conversion undescribed — Cycles 1.1 and 1.7
- ⚠️ Token variant enumeration incomplete (DOCTYPE, comment, character, EOF absent) — Cycle 2.1 (src/html/tokenizer.zig)
- ⚠️ Response.status field type unspecified (u16 vs enum); affects redirect/404 handling — Cycle 1.3
- ⚠️ Response.bytes ownership/allocator unspecified — Cycle 1.3
- ⚠️ DOM node internal structure unspecified (child list, parent, attributes, tag encoding) — Cycles 2.3–2.6 (src/html/dom.zig)
- ⚠️ CSS Rule and Selector model incompletely defined (combinators, specificity tuple) — Cycle 3.1
- ⚠️ Box geometry coordinate/dimension types unspecified (f32/i32/fixed-point); affects margin collapsing and perceptual-diff gate — Cycles 5.1–5.2
- ⚠️ Command.open payload type unspecified — Cycle 0.2 (src/cli.zig)
- ⚠️ WrapperRef concrete stub type unspecified ('opaque placeholder' is not a compilable type) — Cycle 2.6

### Critical
- ❌ ComputedStyle has no schema definition anywhere in the plan — Phase 4 exit gate requires 'every DOM node has a complete ComputedStyle' and Phase 5 layout reads properties from it, but neither the property set nor Zig types are defined; cascade.zig cannot produce it and layout/*.zig cannot read it, forcing each subsystem to invent divergent field names/types — Phase 4 exit gate; Cycles 4.1–4.2, 5.1–5.2, Phase 7

### Recommendations
- ComputedStyle: Add a minimal field table to Phase 4 (display, width/height, margin/padding/border, float, clear, line-height, text-align, color, font-size with Zig types) to prevent cascade.zig and layout/*.zig divergence.
- ParsedUrl and Origin port: Declare `port: ?u16` in ParsedUrl and `u16` (normalized) in Origin; document the conversion in Cycle 1.7.
- Token variant enumeration: Add a complete list to Cycle 2.1 (start_tag, end_tag, character, doctype, comment, eof).
- DOM node internal structure: Add a field sketch in Cycle 2.3/2.4 (tag, attributes, children, parent, script_wrapper).
- WrapperRef: Define `const WrapperRef = struct { index: u32, generation: u32 };` per JS_ENGINE_STRATEGY.md §2.1.
- Command.open: Add `open: []const u8` payload.

## APIs Review

### Well-Defined
- ✅ CLI parseArgs() signature and Command enum variants — Cycle 0.2 Green
- ✅ Navigation teardown ordering severHandles → drainFinalizers → arena.deinit — Cycle 1.6 + TDD_IMPLEMENTATION_PLAN.md:81
- ✅ pumpMicrotasks call-site contract: once per turn, no-op under NoopEngine — Cycle 6.4 Red
- ✅ error.CertInvalid for bad TLS certificate — Cycle 1.4 Red
- ✅ error.CrossOriginDenied for cross-origin store reads — Cycle 1.7 Red
- ✅ Origin equality semantics — Cycle 1.7 Green + Refactor
- ✅ ScriptEngine vtable method names — Cycle 1.6 Green
- ✅ CURLOPT_SSL_VERIFYPEER/VERIFYHOST unconditionally ON — Cycle 1.4 Refactor

### Missing or Unclear
- ⚠️ ScriptEngine vtable function-pointer types undefined; NoopEngine and SpyScriptEngine will diverge — Cycle 1.6 Green
- ⚠️ runScript has no defined call site in v1; ambiguous whether declared-only or stubbed in navigation controller — Cycle 1.6 vs Cycle 2.3
- ⚠️ fetch() URL parameter type not specified; must be consistent across Cycles 1.1, 1.3, 6.3 — Cycle 1.3 Green; Cycle 6.3
- ⚠️ Response struct field types and memory ownership unspecified; affects Cycle 1.5 leak-check — Cycle 1.3 Green
- ⚠️ Page.navigate() parameter and return types undefined; error union matters for mid-parse teardown — Cycle 1.5 Green
- ⚠️ WrapperRef concrete Zig type undefined; field cannot be written without it — Cycle 2.6 Green
- ⚠️ ParsedUrl field types unspecified (esp. port); serializer needs them — Cycle 1.1 Red
- ⚠️ Curl error set incomplete beyond error.CertInvalid (timeout, DNS, connection refused, HTTP error range) — Cycles 1.3 and 1.4
- ⚠️ store.zig read/write API undefined beyond the single error name; same-origin positive path has no interface — Cycle 1.7 Green
- ⚠️ .open Command variant does not specify how the URL argument is carried — Cycle 0.2 Green
- ⚠️ Local TLS server for fetch-bad-cert has no defined setup API (start/stop, port, discovery) — Cycle 1.4 Red

### Critical
- None

### Recommendations
- ScriptEngine vtable (Cycle 1.6): Show the four Zig field types (e.g. `severHandles: *const fn (*ScriptEngine) void`); state whether runScript is declared-only or stubbed.
- Response struct (Cycle 1.3): Add a struct sketch with types and ownership note (`bytes: []u8` caller-owned; `content_type: []const u8`; `status: u16`).
- ParsedUrl struct (Cycle 1.1): Add a field-type table (`port: ?u16`; scheme/host/path/query/fragment as slices into input).
- WrapperRef type (Cycle 2.6): Declare a concrete type so the null-slot test and v2 handle table are settled.
- Page.navigate() (Cycle 1.5): State `fn navigate(self: *Page, url: []const u8) !void`; confirm Cycle 6.3 calls the same signature.
- Curl error set (Cycles 1.3–1.4): Add a named-error table (timeout, DNS failure, connection refused, cert) to make the mapping testable.
- Local TLS server fixture (Cycle 1.4): Specify how the self-signed-cert server is created/torn down and how the port is passed to fetch().

## Critical Issues (Must Address Before Implementation)

- ❌ **ScriptEngine.runScript parameter types are undefined** (Interfaces) — Cycles 1.6 and 2.3 cannot compile; any ad-hoc v1 signature breaks at the v2 seam.
- ❌ **Page.navigate() signature is never defined** (Interfaces) — Cycles 1.5, 1.6, and 6.3 invoke it without a definition; incompatible signatures surface only at Cycle 6.3 integration.
- ❌ **ComputedStyle has no schema definition anywhere in the plan** (Data Models) — Phases 4 and 5 cannot be implemented without independently inventing divergent schemas.

## Approval Status

- [ ] Ready for Implementation — no critical issues
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues must be resolved first


## Beads Tracking

Epic: **[Plan Review Epic] 2026-05-30-14-58-ENG-0001-tdd-zig-browser-v1 — 3 critical, 53 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **3** critical, **53** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | warning | [Plan Review §contracts] fetch() error taxonomy is incomplete: error.CertInvalid is … <!-- fp:163b267b --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] runScript() vtable method has no input/output contract: par… <!-- fp:380232b3 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] WrapperRef type body is undefined: the plan says 'define Wr… <!-- fp:970ba378 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] store.zig value contract is undefined: origin-keyed key equ… <!-- fp:827df803 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] pumpMicrotasks call-site position within the event-loop tur… <!-- fp:7c074015 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] No vtable hook reserved for teardown step 1 ('stop script e… <!-- fp:dc83c90a --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Process-lifetime vs page-arena boundary has no complementar… <!-- fp:1d702bf1 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] ScriptEngine.runScript parameter types are undefined — the … <!-- fp:0e6e1bd9 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] Page.navigate() signature is never defined — the function i… <!-- fp:ad7553c5 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] ScriptEngine method return types not stated — severHandles,… <!-- fp:3a4f5b89 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] ScriptEngine representation undecided — plan writes 'Zig vt… <!-- fp:44298f13 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] WrapperRef concrete type not specified — described as 'opaq… <!-- fp:c6a2c3b3 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] HTML tokenizer API shape not specified — no decision betwee… <!-- fp:1dc3f375 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] HTML tree builder public API not stated — whether it takes … <!-- fp:2195fd5a --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Response struct field types not specified — 'bytes' could b… <!-- fp:def517c3 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] ParsedUrl struct fields not formally specified — field name… <!-- fp:1a0bb506 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Command enum .open variant payload not specified — .version… <!-- fp:2aad7623 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] fetch() error set incomplete — only error.CertInvalid is na… <!-- fp:2003b7c6 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Origin-keyed store public interface not specified — Cycle 1… <!-- fp:689a5891 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] CSS parser, cascade, layout, and paint modules have no publ… <!-- fp:04f37e06 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Error-return discipline not committed per module — parseArg… <!-- fp:a4baac24 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] ScriptEngine vtable has no stated extension policy — adding… <!-- fp:36eeaddb --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Visibility modifiers (pub vs file-private) not stated for a… <!-- fp:c813523c --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Fetch timeout behavior unspecified: no timeout duration def… <!-- fp:436db461 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] No halt-vs-log+continue disposition declared for any emitte… <!-- fp:386349a0 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] SpyScriptEngine call-record ArrayList allocator unspecified… <!-- fp:7fbeeb1a --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Test infrastructure teardown guarantee absent. The local st… <!-- fp:b6c658cc --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Process-lifetime font/glyph cache deinit site not specified… <!-- fp:8e16a825 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Failed-parse arena cleanup mechanism not prescribed. Cycle … <!-- fp:dc94d09a --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] pumpMicrotasks 'one event-loop turn' boundary undefined. Th… <!-- fp:138f1156 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] drainFinalizers synchrony contract unspecified. The spy tes… <!-- fp:6fb5200b --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Teardown seam is missing hooks for strategy doc steps 1 and… <!-- fp:fe51a7f7 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] [VERIFY] Fetch blocking vs. async mode not specified. If li… <!-- fp:f2eca2b1 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Leak-detection coverage limited to Zig-side allocations. li… <!-- fp:6a46aac9 --> | _(not minted)_ |
| data_models | critical | [Plan Review §data_models] ComputedStyle has no schema definition anywhere in the plan… <!-- fp:6e1e40d4 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] ParsedUrl field types and optionality unspecified — port, q… <!-- fp:6b1dd6eb --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] port field type in ParsedUrl vs Origin not aligned — both s… <!-- fp:2ebf8b41 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Token variant enumeration incomplete — only start-tag, text… <!-- fp:a209fd76 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Response.status field type unspecified — u16 and a dedicate… <!-- fp:f1e89961 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Response.bytes ownership and allocator unspecified — it is … <!-- fp:f1fb4883 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] DOM node internal structure unspecified — the plan names on… <!-- fp:a9cb1e31 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] CSS Rule and Selector model incompletely defined — a single… <!-- fp:e4110a2f --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Box geometry coordinate and dimension types unspecified — f… <!-- fp:b06bca84 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Command.open payload type unspecified — the .open variant m… <!-- fp:05a304ab --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] WrapperRef concrete stub type unspecified — described only … <!-- fp:ac2cf8b2 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] ScriptEngine vtable: Zig function-pointer types (parameter … <!-- fp:c5dced33 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] runScript has no defined call site in v1. Cycle 1.6 include… <!-- fp:d8c216d2 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] fetch() URL parameter type is not specified. Cycle 1.3 show… <!-- fp:d5447651 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Response struct field types and memory ownership are unspec… <!-- fp:6329669d --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Page.navigate() parameter and return types are undefined. C… <!-- fp:4c574e4b --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] WrapperRef concrete Zig type is undefined. Cycle 2.6 says '… <!-- fp:87d150a8 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] ParsedUrl field types are unspecified. Cycle 1.1 names six … <!-- fp:f5c21b72 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Curl error set is incomplete beyond error.CertInvalid. Cycl… <!-- fp:4b28e182 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] store.zig read/write API is undefined beyond the single err… <!-- fp:36b7be55 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] .open Command variant does not specify how the URL argument… <!-- fp:1faa587e --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Local TLS server for fetch-bad-cert has no defined setup AP… <!-- fp:ca0be5ca --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.