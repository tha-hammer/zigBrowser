# Plan Review Report: WebKitGTK Browser — Slice 1 TDD Implementation Plan

> **Plan tier: L1** (confidence: high) — 3 L1 keyword(s) + plan size 264 lines (bounded scope; L1 >= L2 signal)
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ❌ | 8 issues |
| Interfaces | ❌ | 9 issues |
| Promises | ❌ | 7 issues |
| Data Models | ⚠️ | 5 issues |
| APIs | ⚠️ | 6 issues |

## Contracts Review

### Well-Defined
- ✅ C-import boundary: all GTK/WebKit C access funnels exclusively through src/webkit.zig; no other module imports `c` — B1 Refactor: "All WebKit/GTK C access funnels through src/webkit.zig (deep module; the rest of the code never imports c directly)"
- ✅ versionLine(allocator) []u8 contract: heap-allocated, caller-owned, content sourced from linked lib getter calls (not string literals), verified against independent pkg-config oracle — B1 Red test + Success Criteria: "ORACLE: printed versions == pkg-config --modversion webkit2gtk-4.1 and gtk+-3.0"
- ✅ URL validation gate: url.zig rejects malformed and non-http(s) input before any GTK or WebKit call is made; no window is opened for invalid input — B5 Green: "in main parse+normalize, reject non-http(s)/malformed → stderr + non-zero exit before any window/load"
- ✅ Fixture oracle independence: tests/fixtures/live.html has fixed known title and body; get_title() and get_snapshot() are WebKit-produced outputs checked against that known fixture, not against our own code's output — Testing Strategy + B2/B4 Success Criteria: "ORACLE: webkit_web_view_get_title() (WebKit's real parse of the known fixture) + non-uniform text pixels — both WebKit-produced"
- ✅ Macro expansion strategy: g_signal_connect_data replaces g_signal_connect macro; GObject casts are explicit pointer casts; callbacks use callconv(.C) — Current State Analysis: "g_signal_connect, G_CALLBACK … are C macros that zig translate-c does NOT expose"; B2 Green code sketch showing the pattern
- ✅ Salvage file list: exact files cherry-picked from archive tag via an explicit git command; all other archived content stays archived — Salvage Manifest: "git checkout archive/custom-engine-pre-webkit -- src/cli.zig src/net/url.zig src/errors.zig src/page.zig build.zig.zon"

### Missing or Unclear
- ⚠️ loadThen(url, action) signature undefined: B4 Refactor introduces a shared load-then-act function shared by B2 and B4, but the type of 'action', its error contract, and what context it captures are never defined. webkit.zig and main.zig cannot agree on a calling convention without this. — B4 Refactor: "Share the load-then-act flow with M2 (one loadThen(url, action) in webkit.zig)"; B2 Refactor: "No logic duplicated with M4's load path"
- ⚠️ Signal callback user_data/ctx type undefined: onLoadChanged, onLoadFailed, and onSnapshot all receive a user_data or ctx pointer. The plan never defines the type of this context or what fields callbacks read/write to communicate state (exit code, output path, load outcome) back to main after gtk_main returns. B2 Green sketch passes null as user_data, which is inconsistent with callbacks needing to relay error state. — B2 Green: "g_signal_connect_data(view, \"load-changed\", ..., null, null, 0)"; B4 Green: "webkit_web_view_get_snapshot(..., &onSnapshot, ctx)" — ctx is never defined
- ⚠️ page.zig fields in WebKit context undefined: the plan adopts salvaged page.zig as 'per-window state container' but never specifies what fields it holds in the new context (GtkWindow*, WebKitWebView*, exit_code, output_path?). The ownership boundary between page.zig and webkit.zig is not drawn, risking two competing state owners. — B3 Refactor: "Adopt salvaged page.zig arena + ordered teardown as the per-window state container; teardown runs in a defer chain in the documented order"
- ⚠️ Exit-code table has one authoritative definition but is not cross-referenced: codes 0/1/2/3/4 are defined only in B4 Green, while B2, B3, and B5 reference 'non-zero exit' generically. No single named table is cited across behaviors. — B4 Green: "(0 ok / 1 url / 2 load / 3 snapshot / 4 write)" vs B5 Success Criteria: "non-zero exit; no bogus PNG" vs B3 Success Criteria: "exit code 0"
- ⚠️ [VERIFY] GError* translation boundary unnamed: the load-failed signal delivers a GError* from GLib. The plan says 'map WebKitNetworkError via errors.zig → stderr' but never names the function or location where the raw GLib pointer is translated. Without a named translation point, the errors.zig taxonomy is not enforced and raw driver-shaped errors can flow into business logic. — B5 Green: "g_signal_connect_data(view, \"load-failed\", &onLoadFailed, …) → map WebKitNetworkError via errors.zig → stderr"
- ⚠️ pillow_tools.py not included in salvage manifest: B4 names 'tests/snapshots/pillow_tools.py (salvage — assertion helper)' as the E2E oracle tool for screenshot non-uniformity, but the git checkout command in the Salvage Manifest does not include it. If the file is absent, the B4 E2E oracle has no implementation. — B4 Green: "Reuse salvaged pillow_tools.py (diff/non-uniformity) for the harness assertion"; Salvage Manifest: git command omits tests/snapshots/pillow_tools.py

### Critical
- ❌ src/net/url.zig vs src/url.zig naming conflict (plan-internal): the Salvage Manifest's git checkout command and the audit citation both reference src/net/url.zig (git restores that exact path; audit cites 'src/net/url.zig:15-31'), but B5 'Files touched' lists 'src/url.zig (from tag)'. The two paths cannot both be correct; one import will resolve to a nonexistent file. — Compilation fails at the first @import of the URL module: either the salvage command restores to the wrong path, or url_test.zig and main.zig import a file that does not exist.
- ❌ Async callback → exit-code communication path unspecified: load-failed, load-changed FINISHED, and snapshot-finish callbacks all fire inside the GTK event loop with callconv(.C) void returns. The plan guarantees non-zero exit on failure (B5) and specific exit codes (B4), but never specifies the mechanism by which callbacks relay error state out to main after gtk_main returns. The B2 Green sketch passes null as user_data to load-changed, leaving no channel. Without a named shared-state location passed to every g_signal_connect_data call, the exit-code contract is unimplementable as written. — load-failed and snapshot errors silently produce exit 0 (null user_data carries no state), or each implementer independently invents a global — with no contract binding main.zig to read it. B5 E2E test 'exits non-zero' cannot pass; B4 exit codes 2/3/4 are unreachable.

### Recommendations
- src/net/url.zig vs src/url.zig naming: Choose one canonical path and apply it everywhere. The archive tag and audit both use src/net/url.zig — the simplest fix is to update B5 'Files touched' to 'src/net/url.zig (from tag)' and ensure all @import paths match. If flattening to src/url.zig is preferred, update the git checkout command in the Salvage Manifest and the audit citation.
- Async callback → exit-code communication: Define a minimal AppCtx struct (e.g. exit_code: u8, output_path: ?[:0]const u8, load_ok: bool) allocated in main and passed as user_data to every g_signal_connect_data call. Callbacks write their outcome into this struct and call gtk_main_quit. Main reads ctx.exit_code after gtk_main returns and passes it to std.process.exit. Replace the null user_data in the B2 Green sketch with a pointer to this struct. Document ownership: AppCtx lives on main's stack; webkit.zig receives a pointer only.
- loadThen(url, action) + signal callback context: Combine with the AppCtx fix above: store the action as a tagged union field in AppCtx (e.g. const Mode = union(enum) { display, screenshot: [:0]const u8 }). The FINISHED handler reads ctx.mode to decide whether to call gtk_main_quit (display) or trigger get_snapshot (screenshot). This makes the signature visible — fn loadThen(url: [:0]const u8, ctx: *AppCtx) void — and avoids an opaque function-pointer parameter.
- Exit-code table: Promote the B4 exit-code table (0/1/2/3/4) to a named subsection under Overview (e.g. '## Exit Codes'). Replace the generic 'non-zero exit' phrasing in B2, B3, and B5 with explicit references to the named codes (e.g. 'exits with code 2 (load failure), see Exit Codes table').
- page.zig re-use vs AppCtx: Decide explicitly: either list the new fields page.zig gains for the WebKit slice (e.g. 'adds *GtkWidget window, *GtkWidget view to the existing arena'), or clarify that AppCtx (above) serves as the per-window state and page.zig remains archived for this slice. Leaving both as candidates creates ambiguous ownership.
- pillow_tools.py salvage: Add tests/snapshots/pillow_tools.py to the git checkout command in the Salvage Manifest, or note that it must be created fresh and provide its minimum interface (e.g. 'accepts PNG path, exits 0 if pixel variance > threshold, exits 1 if uniform/blank').

## Interfaces Review

### Well-Defined
- ✅ Build system interface: addTranslateC + linkSystemLibrary with use_pkg_config — Behavior 1 Green: `exe.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .yes })` — pkg-config failure is loud, no silent fallback, confirmed by ldd assertion in Success Criteria
- ✅ error.InvalidUrl return from url.zig — Behavior 5 Property: `all non-http(s)/malformed inputs → error.InvalidUrl (never a panic, never a load)`; TDD Red: `url.zig rejects http://, ftp://x, javascript:alert(1) → error.InvalidUrl`
- ✅ Snapshot exit code taxonomy (0/1/2/3/4) — Behavior 4 Green: `map errors → exit codes (0 ok / 1 url / 2 load / 3 snapshot / 4 write)` — enumerated and unambiguous
- ✅ C macro workaround pattern: g_signal_connect_data, callconv(.C), GObject pointer casts — Behavior 2 Edge Cases and Green sketch: explicitly calls out `g_signal_connect_data`; `@ptrCast` for GTK_CONTAINER/WEBKIT_WEB_VIEW; `callconv(.C)` on callbacks
- ✅ Fixture oracle: tests/fixtures/live.html with known title and body — Testing Strategy: `<title>WebKitGTK Live</title>, <h1>Hello Real Text</h1>` — deterministic, no network; used as independent oracle across B2, B4
- ✅ versionLine oracle: cross-check against pkg-config --modversion — Behavior 1 Success Criteria ORACLE: `printed versions == pkg-config --modversion webkit2gtk-4.1 and gtk+-3.0`

### Missing or Unclear
- ⚠️ Visibility modifiers for all webkit.zig functions never specified — the refactor rule says 'all C access funnels through webkit.zig' but does not declare which functions are pub vs private — Behavior 1 Refactor and Behavior 2 Refactor
- ⚠️ parseArgs return type and error discipline not restated for this plan's repurposed .screenshot arm — plan says 'from tag' but the tag arm is being semantically changed (screenshot now maps to webkit get_snapshot instead of original meaning); the union variant set is not declared — Salvage Manifest: cli.zig — repurpose the .screenshot arm; Behavior 1 Green: main.zig dispatch .version
- ⚠️ reportError(NetError) function mentioned in Behavior 5 refactor has no signature, no return type, no visibility modifier, and no stated error-return discipline — Behavior 5 Refactor: `Unify error surfacing (one reportError(NetError))`
- ⚠️ The 'thin WebView/Window seam' for future macOS/WKWebView extensibility is promised as an extension point in Behavior 2 Refactor but no Zig interface (struct fields, function-pointer table, tagged union, or comptime interface) is defined — a future implementor has no contract to satisfy — Behavior 2 Refactor: `Extract a thin WebView/Window seam in src/webkit.zig so a future macOS WKWebView backend swaps in behind the same Zig interface`

### Critical
- ❌ openWindow has no formal interface: no parameter types, no return type, no error-return discipline. It is called as webkit.openWindow(url) from main.zig but never defined. Callers cannot know whether it returns void, !void, or something else, making the main.zig dispatch arm unimplementable. — main.zig cannot compile the .open arm; error propagation from webkit.zig to process exit code is undefined; any implementation is a guess
- ❌ loadThen(url, action) interface is entirely undefined: url type unknown, action parameter type unknown (function pointer? comptime type? tagged union?), return type absent, error-return discipline absent. Both Behavior 2 and Behavior 4 are supposed to converge on this shared flow after refactor. — B2 and B4 cannot share an implementation; the action callback's GObject parameter types must match WebKit's internal GAsyncResult* at the call site or the binary crashes silently
- ❌ versionLine error-return discipline is not stated. The sketch shows return type []u8 with no error union, but the function allocates (the test calls defer allocator.free(v)). An allocator that fails returns error.OutOfMemory. If the return is truly []u8 the plan must say explicitly that allocation failure panics (and why that is acceptable for --version). As written, the allocator parameter is also untyped ('a' with no type annotation). — main.zig cannot handle errors from versionLine correctly; if allocation fails the binary crashes rather than printing an error; the mixed no-error-return + allocating signature forces every caller to guess
- ❌ C callback signatures (onLoadChanged, onLoadFailed, onSnapshot) lack formal parameter types. The plan sketches `fn onLoadChanged(view, load_event, user) callconv(.C) void` with no GObject types. GTK signal callbacks must exactly match the C function-pointer type expected by the signal or the call frame is corrupt. onSnapshot must accept a GObject* source and GAsyncResult* — neither is named. — Wrong parameter types on a callconv(.C) callback produce a corrupt stack frame at signal dispatch; no compiler error, silent crash or undefined behavior at runtime; this is the single most common failure mode when embedding GTK in non-C languages
- ❌ Error propagation path from webkit.zig to main.zig exit codes is undefined. The exit code taxonomy (0–4) is stated but the mechanism is not: does webkit.openWindow / loadThen return an error that main.zig maps, or does webkit.zig call std.process.exit directly, or does it set a shared mutable? These three choices produce incompatible interfaces and incompatible test strategies. — main.zig and webkit.zig cannot be written independently; if webkit.zig calls std.process.exit, the test harness cannot intercept errors; if it returns errors, the return type of every webkit.zig public function is wrong as currently sketched

### Recommendations
- openWindow: Add an explicit one-line signature to the plan: `pub fn openWindow(url: [:0]const u8) !void` — the !void declares that errors propagate to main.zig which maps them to exit codes, resolving both the return-type and error-discipline gaps
- loadThen: Define action as a simple tagged union in webkit.zig — e.g. `const Action = union(enum) { display, screenshot: [:0]const u8 }` — so loadThen's full signature becomes `fn loadThen(url: [:0]const u8, action: Action) !void`; avoids function-pointer types and makes the two callers (B2, B4) statically checkable
- versionLine: Pick one: (a) return `![]u8` and let main.zig handle the error, or (b) return `[]u8` and document in the plan that the function calls `catch unreachable` on alloc failure because --version is non-recoverable. Also rename `a` to `allocator: std.mem.Allocator`. State the choice explicitly so the test and implementation agree.
- C callbacks (onLoadChanged, onLoadFailed, onSnapshot): Add a single table to the plan listing each callback's exact GObject-typed signature — e.g. `fn onLoadChanged(web_view: *c.WebKitWebView, load_event: c.WebKitLoadEvent, user_data: ?*anyopaque) callconv(.C) void` and `fn onSnapshot(source: *c.GObject, result: *c.GAsyncResult, user_data: ?*anyopaque) callconv(.C) void`. These are non-negotiable for a correct callconv(.C) binding.
- Error propagation path: State explicitly in the plan: webkit.zig public functions return `!void`; main.zig catches each error variant and calls `std.process.exit(code)` using the stated taxonomy. This is one sentence that eliminates all ambiguity and keeps the exit-code mapping in one place.
- parseArgs union variant set: List the exact union variants the repurposed cli.zig will expose — e.g. `const Args = union(enum) { version, open: [:0]const u8, screenshot: struct { path: [:0]const u8, url: [:0]const u8 } }` — since the .screenshot arm semantics have changed from the archived version; one-line definition, no new infrastructure

## Promises Review

### Well-Defined
- ✅ Version numbers sourced from runtime C getters, never from compile-time string literals — B1 Green phase: `webkit_get_major/minor/micro_version()` + `gtk_get_major/minor/micro_version()` called at runtime; cross-checked against `pkg-config --modversion`
- ✅ `load-changed` FINISHED ordering guarantee: title and snapshot never queried before FINISHED fires — B2 edge cases ('await FINISHED before asserting — no race') and Risks table row
- ✅ Atomic PNG write with defer-based partial-file cleanup on failure path — B4 Green phase: 'atomic temp+rename with defer cleanup'
- ✅ URL validation rejects malformed/non-http(s) inputs before any GTK window or WebView is created — B5 spec: 'malformed → rejected up front by salvaged url.zig … no window/PNG'; property test `parse(serialize(x)) == x`
- ✅ Window destroy signal wired unconditionally to gtk_main_quit for clean exit — B3 Green phase: `g_signal_connect_data(win, 'destroy', @ptrCast(&c.gtk_main_quit), null, null, 0)`
- ✅ WebKit helper-process reaping guaranteed via WebKitWebContext disposal — B3 Green phase + B3 success criteria: OS-level process-table check as independent oracle

### Missing or Unclear
- ⚠️ Cairo surface resource (`cairo_surface_t*` returned by `webkit_web_view_get_snapshot_finish`) cleanup not specified — `cairo_surface_destroy()` is absent from B4's teardown description, leaving the surface lifetime unguaranteed — Behavior 4 Green phase
- ⚠️ Retryability not declared per error category: exit codes 1–4 are defined but none are annotated as 'do not retry' or 'caller may retry' — Behavior 4 Green phase (exit code map), Behavior 5 spec
- ⚠️ SIGINT/SIGTERM mid-load clean-exit promise has no implementation path: no `g_unix_signal_add` or `signal()` handler is wired anywhere; GTK's default SIGTERM disposition is platform-dependent and not guaranteed to call `gtk_main_quit` — Behavior 3 edge cases
- ⚠️ Signal handler disconnect lifecycle unspecified: handlers are registered but never explicitly disconnected before widget destruction; late-firing callbacks on a partially-torn-down widget are not promised to be safe — Behavior 2 and 4 Green phase
- ⚠️ Teardown 'documented order' (B3 / page.zig) referenced as authoritative but not stated in this plan — the ordering invariant is deferred entirely to the salvaged archive without being reproduced or summarised here — Behavior 3 Refactor phase

### Critical
- ❌ No timeout or watchdog on the async FINISHED wait: if `load-changed(FINISHED)` never fires — stalled server, WebKit render-process crash, offscreen load with a frozen event loop — both the B2 window path and the B4 screenshot path hang indefinitely. No `g_timeout_add_seconds` or GCancellable is mentioned anywhere. — Binary hangs forever on any load that does not complete normally; E2E tests block CI with no timeout; the visible-output gate cannot be met for B2 and B4 in a bounded time window, breaking the plan's own VISIBLE-OUTPUT GATE law
- ❌ Use-after-free on concurrent window destroy during pending snapshot callback: B3 explicitly lists 'double-close / destroy during snapshot' as an edge case but provides zero implementation promise for its resolution. When the GTK window is destroyed while the snapshot GAsyncResult is still in flight, the `ctx` and WebView pointers forwarded to the finish callback are already freed; the finish callback dereferences freed memory. — SIGSEGV or GLib assertion failure during the normal user workflow of closing the window before snapshot completes; B3's clean-exit guarantee is violated; B4 may write a corrupt or zero-byte PNG before crashing

### Recommendations
- Behavior 2 and 4 — async FINISHED wait timeout: Register a `g_timeout_add_seconds(10, onLoadTimeout, ctx)` immediately after `webkit_web_view_load_uri`; in `onLoadTimeout` call `gtk_main_quit()` and set a non-zero exit code. Cancel the timeout (via its return ID) in the FINISHED handler. Mirror this in the E2E harness with `timeout 15 ./zig-out/bin/zigBrowser …` so hung tests fail fast rather than blocking CI.
- Behavior 3/4 — destroy-during-snapshot race (use-after-free): Add a `snapshot_pending: bool` field to the per-window state in `page.zig`. Set it true before calling `webkit_web_view_get_snapshot`; clear it in the finish callback's first line. In the destroy handler, if `snapshot_pending` is true, skip teardown of the WebView until the callback fires (or pass a GCancellable and cancel it on destroy, then guard the finish cb with a cancelled check). A simple bool flag is sufficient at this tier.
- Behavior 4 — cairo surface cleanup: Immediately after `webkit_web_view_get_snapshot_finish` returns the surface, write `defer c.cairo_surface_destroy(surface);` before the `cairo_surface_write_to_png` call.
- All error paths — retryability annotation (L1-appropriate): Add a one-line comment beside each exit-code branch in `main.zig`, e.g. `// exit 1 (url): permanent — fix the URL, do not retry` and `// exit 2 (load): transient network — user may retry manually`. No typed error envelope or backoff policy is needed at L1.
- Behavior 3 — SIGINT/SIGTERM clean exit: In `webkit.zig`, after `gtk_init_check`, add two lines: `_ = c.g_unix_signal_add(std.os.SIG.TERM, @ptrCast(&c.gtk_main_quit), null)` and the same for `SIG.INT`.

## Data Models Review

### Well-Defined
- ✅ Exit code schema (screenshot path) — Behavior 4 §Green: '0 ok / 1 url / 2 load / 3 snapshot / 4 write' — exhaustively enumerated for the screenshot flow
- ✅ Test fixture schema (live.html) — Testing Strategy §Fixtures and Behavior 2 §Test Specification: `<title>WebKitGTK Live</title>`, `<h1>Hello Real Text</h1>` — deterministic, fully specified
- ✅ Version string composition rule — Behavior 1 §Test Specification: fields sourced from `webkit_get_major/minor/micro_version()` + `gtk_get_major/minor/micro_version()` — getter-derived, not literals

### Missing or Unclear
- ⚠️ [VERIFY] `NetError` enum variants are not defined in this plan; the salvaged `src/errors.zig` was authored for a custom HTTP engine. Whether its variants cover WebKit's `WebKitNetworkError` / `WebKitTLSErrors` / DNS-failure domain codes is unspecified. Behavior 5 says 'map WebKit load-failed codes onto it' but the mapping table is absent. — Salvage Manifest §errors.zig; Behavior 5 §Green: 'map `WebKitNetworkError` via `errors.zig` → stderr'
- ⚠️ [VERIFY] `ParseArgs` union arm payloads are not typed in this plan. The `.open` arm implicitly carries a URL string and the `.screenshot` arm implicitly carries `{ output_path, url }`, but field names, types (`[]const u8` vs `[:0]const u8` for C-string hand-off), and required/optional status are never declared. The plan notes the `.screenshot` arm must be 'repurposed', implying the salvaged shape may not match. — Salvage Manifest §cli.zig; Behavior 1 §Green 'src/cli.zig from tag'; Behavior 4 §Green '`.screenshot` → load + await'
- ⚠️ [VERIFY] `page.zig` per-window state container fields are undefined in this plan. The plan adopts it as 'the per-window state container' for the WebKit context but only describes it as 'arena + ordered teardown'. Fields expected in the new context — GTK window pointer, WebKitWebView pointer, current URL, load-state flag, output path for screenshot — are never enumerated, typed, or marked required/optional. — Behavior 3 §Refactor: 'Adopt salvaged `page.zig` arena + ordered teardown as the per-window state container'
- ⚠️ Snapshot async callback context struct `ctx` is referenced in the M4 code sketch (`&onSnapshot, ctx`) but its type, fields, and ownership are never defined anywhere in the plan. At minimum it must carry: the output file path, a reference to the main loop handle (to quit after write), and an error-sink; none of these are specified. — Behavior 4 §Green: `webkit_web_view_get_snapshot(view, FULL_DOCUMENT, NONE, null, &onSnapshot, ctx)`
- ⚠️ Exit code schema is defined only for the screenshot flow (M4: 0–4) but Behavior 5 references 'non-zero exit' for malformed-URL and unreachable-host cases without mapping them to that schema. It is unclear whether `error.InvalidUrl` → exit 1 (url) and `load-failed` → exit 2 (load), or whether a separate code set applies to the non-screenshot path. — Behavior 4 §Green exit-code list vs. Behavior 5 §Test Specification 'non-zero exit' and §Green 'stderr + non-zero exit'

### Critical
- None.

### Recommendations
- NetError taxonomy: Inline the existing variant list from `archive/custom-engine-pre-webkit:src/errors.zig` directly into this plan and annotate each variant with the WebKit error domain/code it covers (e.g. `WEBKIT_NETWORK_ERROR_*`, `WEBKIT_TLS_ERRORS_*`). Add any missing variants before implementation begins.
- ParseArgs union: Add a compact schema block to the Salvage Manifest section that explicitly declares the union shape: e.g. `version: void`, `open: struct { url: [:0]const u8 }`, `screenshot: struct { output_path: [:0]const u8, url: [:0]const u8 }`. Note whether the `.screenshot` arm is added or repurposed and what the old shape was.
- page.zig per-window state container: Add a field table for the WebKit-context incarnation of `PageState`: list each field, its type, required/optional status, and initialization order. This costs one paragraph and prevents the arena teardown order from being guessed at implementation time.
- Snapshot callback context struct: Define the `SnapshotCtx` (or equivalent) struct inline in Behavior 4 with at minimum: `output_path: [:0]const u8`, `main_loop: *c.GMainLoop` (or equivalent quit handle), and an error output field. Specify ownership (stack vs heap, who frees).
- Exit code schema: Promote the M4 exit code table (0–4) to a shared schema section referenced by both Behavior 4 and Behavior 5, and explicitly assign codes to the non-screenshot bad-URL and load-failed cases so both behaviors use the same integer contract.

## APIs Review

### Well-Defined
- ✅ CLI --version invocation — B1 Test Specification: output format 'zigBrowser — WebKitGTK 2.52.3, GTK 3.24.49', exit 0, oracle = pkg-config --modversion webkit2gtk-4.1 + gtk+-3.0
- ✅ CLI --screenshot out.png <url> invocation — B4 Test Specification + green step: PNG written to named path, async FINISHED-then-snapshot flow, exit codes 0/1/2/3/4 named and mapped
- ✅ CLI zigBrowser <url> (window mode) invocation — B2 Test Specification: file:// fixture load, FINISHED signal gate, get_title() as independent oracle
- ✅ webkit.zig versionLine(allocator) — caller-frees ownership — B1 Red test: 'defer std.testing.allocator.free(v)' establishes the ownership convention explicitly
- ✅ Exit codes 0/1/2/3/4 for screenshot mode — B4 green step: '0 ok / 1 url / 2 load / 3 snapshot / 4 write' — five codes named with semantics
- ✅ load-failed signal → stderr + non-zero exit + no bogus PNG contract — B5 Success Criteria and B5 green step: 'reportError(NetError)', no file written on failure

### Missing or Unclear
- ⚠️ Exit code taxonomy (0–4) is scoped to --screenshot mode only; window mode (B2/B3) and bad-URL in window mode (B5) specify only 'non-zero exit' or 'exit 0'. It is unspecified whether codes 1 (url) and 2 (load) apply universally or are screenshot-local. main.zig must return a single integer — without a complete table, the two paths may silently use different values. — B4 green step defines 0-4; B3 Success Criteria says 'exit 0'; B5 Test Specification says 'non-zero exit' with no code
- ⚠️ openWindow(url) internal API signature is unspecified: return type, error set, and whether the call blocks inside gtk_main() or returns after setup are never stated. B2 green calls 'webkit.openWindow(url)' and B4 refactor expects to share a flow with it — divergence is likely without a declared signature. — B2 green step: 'src/main.zig `.open` → validate URL → webkit.openWindow(url)'
- ⚠️ loadThen(url, action) is introduced in B4 refactor as the shared load-then-act seam for both B2 and B4, but parameter types (what is 'action'? fn pointer? tagged union?), return type, and error set are never defined in the plan. — B4 refactor: 'Share the load-then-act flow with M2 (one loadThen(url, action) in webkit.zig)'
- ⚠️ stderr error message format is unspecified: plain text vs structured, whether the WebKit error domain/code is included, whether the originating URL is echoed. Scripts relying on non-zero exit have a contract; scripts parsing stderr do not. — B5 Test Specification: 'clear stderr message'; B5 Success Criteria: 'real stderr error message'
- ⚠️ versionLine(allocator) is declared in the test as returning []u8 (no error union), but the call allocates on the heap and allocation can fail. The error path is unspecified — silent truncation or panic is the likely fallback. — B1 Red test: 'const v = @import("../src/webkit.zig").versionLine(std.testing.allocator)' — no 'try', no '!'
- ⚠️ '--version with trailing args still prints' is listed as an edge case but whether the trailing args are silently ignored, produce a warning on stderr, or cause a non-zero exit is never stated. The cli.zig parseArgs union from the salvage tag governs this — behavior needs to be specified. — B1 Test Specification edge cases

### Critical
- None.

### Recommendations
- Exit code contract: Add a single exit-code table to the plan covering all invocation modes. Specify that codes 1 (bad URL) and 2 (load failure) are universal; codes 3 (snapshot error) and 4 (write error) are screenshot-only; window-mode load failure = exit 2; clean window close = exit 0. One concrete table prevents main.zig from silently diverging between modes.
- openWindow / loadThen internal API: Add minimal Zig-style signatures in the plan, e.g.: 'pub fn openWindow(url: [:0]const u8) void' (blocks on gtk_main) and 'pub fn loadThen(url: [:0]const u8, ctx: *LoadCtx, on_finish: *const fn(*c.WebKitWebView, *LoadCtx) callconv(.C) void) void'. This is enough to prevent B2 and B4 from building incompatible call sites before the B4 refactor lands.
- versionLine return type: Change the declared return type to '![]u8' and update the B1 Red test to 'const v = try webkit.versionLine(std.testing.allocator)'. An allocating function that cannot signal failure is a latent crash on low-memory paths.
- stderr error format: Add one sentence to B5 specifying the format: plain text, one line, e.g. 'zigBrowser: <short category>: <detail>'. Scripts rely on exit codes; stderr is human-readable only.

## Scaffolding & Realness (Hostile Check)

The plan's milestones are anchored to genuinely independent oracles (pkg-config --modversion, WebKit's own get_title() against a fixed fixture, non-uniform pixel variance, OS process-table checks), and versions are sourced from runtime getters rather than literals — these are strong anti-scaffolding signals. However, two realness violations remain:

- ❌ **Named-but-unbuilt dependency — `tests/snapshots/pillow_tools.py`.** B4 designates this file as the E2E oracle for screenshot non-uniformity ("Reuse salvaged pillow_tools.py (diff/non-uniformity) for the harness assertion"), but the Salvage Manifest's `git checkout` command never restores it and nothing else vendors or creates it. The single human-observable artifact for B4 (a PNG proven non-blank) hangs on a tool the plan relies on but never wires. If the file is absent, the B4 oracle has no implementation and "tests green" for the screenshot milestone is unverifiable. — Location: B4 Green / Salvage Manifest.
- ❌ **Scaffolding disguised as a feature — "thin WebView/Window seam" reserved for a future macOS WKWebView backend.** Behavior 2 Refactor promises to "Extract a thin WebView/Window seam in src/webkit.zig so a future macOS WKWebView backend swaps in behind the same Zig interface," but defines no Zig interface (no struct, function-pointer table, tagged union, or comptime contract) and ships no second backend. This is a "reserve a seam / wire for later" extension point with no contract to satisfy and no end-to-end consumer in this slice. — Location: Behavior 2 Refactor.

## Critical Issues (Must Address Before Implementation)

1. **[Contracts] src/net/url.zig vs src/url.zig naming conflict** — Salvage Manifest/audit say `src/net/url.zig`; B5 'Files touched' says `src/url.zig`. One import resolves to a nonexistent file; compilation fails at the first @import of the URL module.
2. **[Contracts] Async callback → exit-code communication path unspecified** — callbacks fire inside the GTK loop with `callconv(.C) void` returns and no named shared-state channel (B2 passes `null` user_data); the non-zero-exit and exit-code contracts are unimplementable, so B5 "exits non-zero" cannot pass and B4 codes 2/3/4 are unreachable.
3. **[Interfaces] openWindow has no formal interface** — no parameter/return types or error discipline; main.zig cannot compile the `.open` arm and error propagation to exit code is undefined.
4. **[Interfaces] loadThen(url, action) interface entirely undefined** — url/action types, return type, and error discipline all absent; B2 and B4 cannot share an implementation and the GObject parameter types may not match WebKit's GAsyncResult* at the call site.
5. **[Interfaces] versionLine error-return discipline not stated** — allocating function declared as `[]u8` with no error union and an untyped allocator param; allocation failure crashes the binary instead of being handled.
6. **[Interfaces] C callback signatures (onLoadChanged, onLoadFailed, onSnapshot) lack formal parameter types** — wrong types on a `callconv(.C)` callback corrupt the call frame at signal dispatch with no compiler error; silent crash/UB at runtime.
7. **[Interfaces] Error-propagation mechanism from webkit.zig to main.zig exit codes undefined** — return-error vs std.process.exit vs shared-mutable are incompatible interfaces and test strategies; the two modules cannot be written independently.
8. **[Promises] No timeout/watchdog on the async FINISHED wait** — any non-completing load hangs the binary forever and blocks CI; the plan's own VISIBLE-OUTPUT GATE cannot be met in bounded time for B2/B4.
9. **[Promises] Use-after-free on window destroy during a pending snapshot callback** — destroy-during-snapshot frees `ctx`/WebView pointers before the finish callback dereferences them; SIGSEGV or GLib assertion during a normal user workflow, violating B3's clean-exit guarantee.
10. **[Scaffolding] Named-but-unbuilt dependency `tests/snapshots/pillow_tools.py`** — B4's E2E oracle is referenced but never salvaged/vendored/created.
11. **[Scaffolding] "Thin WebView/Window seam" reserved for a future backend** — extension point promised with no defined Zig interface and no end-to-end consumer in this slice.

## Approval Status

- [ ] Ready for Implementation — no critical issues AND Scaffolding & Realness is clean
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues OR any Scaffolding & Realness violation must be resolved first


## Beads Tracking

Epic: **[Plan Review Epic] 2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1 — 9 critical, 26 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **9** critical, **26** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | critical | [Plan Review §contracts] src/net/url.zig vs src/url.zig naming conflict (plan-intern… <!-- fp:e09267b1 --> | _(not minted)_ |
| contracts | critical | [Plan Review §contracts] Async callback → exit-code communication path unspecified: … <!-- fp:3fbaa373 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] loadThen(url, action) signature undefined: B4 Refactor intr… <!-- fp:deb7beaa --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Signal callback user_data/ctx type undefined: onLoadChanged… <!-- fp:f40c3165 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] page.zig fields in WebKit context undefined: the plan adopt… <!-- fp:43f8d695 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] Exit-code table has one authoritative definition but is not… <!-- fp:07c9ce73 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] [VERIFY] GError* translation boundary unnamed: the load-fai… <!-- fp:4e9acc78 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] pillow_tools.py not included in salvage manifest: B4 names … <!-- fp:76d90c95 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] openWindow has no formal interface: no parameter types, no … <!-- fp:39e1b2d0 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] loadThen(url, action) interface is entirely undefined: url … <!-- fp:ea1819ea --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] versionLine error-return discipline is not stated. The sket… <!-- fp:159e702e --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] C callback signatures (onLoadChanged, onLoadFailed, onSnaps… <!-- fp:c521bfe6 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] Error propagation path from webkit.zig to main.zig exit cod… <!-- fp:74d0a57b --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] Visibility modifiers for all webkit.zig functions never spe… <!-- fp:bacf2a5b --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] parseArgs return type and error discipline not restated for… <!-- fp:65b95d83 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] reportError(NetError) function mentioned in Behavior 5 refa… <!-- fp:1cd7874a --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] The 'thin WebView/Window seam' for future macOS/WKWebView e… <!-- fp:29edc7ef --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] No timeout or watchdog on the async FINISHED wait: if `load… <!-- fp:e15be8e7 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] Use-after-free on concurrent window destroy during pending … <!-- fp:f597a386 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Cairo surface resource (`cairo_surface_t*` returned by `web… <!-- fp:a70182da --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Retryability not declared per error category: exit codes 1–… <!-- fp:b9e6fe1d --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] SIGINT/SIGTERM mid-load clean-exit promise has no implement… <!-- fp:b6978849 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Signal handler disconnect lifecycle unspecified: `g_signal_… <!-- fp:bd806eeb --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Teardown 'documented order' (B3 / page.zig) referenced as a… <!-- fp:b6fc11b2 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] `NetError` enum variants are not defined in this p… <!-- fp:7da83a23 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] `ParseArgs` union arm payloads are not typed in th… <!-- fp:c992f878 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] `page.zig` per-window state container fields are u… <!-- fp:c1dc7417 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Snapshot async callback context struct `ctx` is referenced … <!-- fp:20a5a0b5 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Exit code schema is defined only for the screenshot flow (M… <!-- fp:a4e7e2ef --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] Exit code taxonomy (0–4) is scoped to --screenshot mode onl… <!-- fp:d03bc024 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] openWindow(url) internal API signature is unspecified: retu… <!-- fp:edb76363 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] loadThen(url, action) is introduced in B4 refactor as the s… <!-- fp:acdefdd0 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] stderr error message format is unspecified: plain text vs s… <!-- fp:a831e568 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] versionLine(allocator) is declared in the test as returning… <!-- fp:5779d8f6 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] '--version with trailing args still prints' is listed as an… <!-- fp:598d8abe --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.