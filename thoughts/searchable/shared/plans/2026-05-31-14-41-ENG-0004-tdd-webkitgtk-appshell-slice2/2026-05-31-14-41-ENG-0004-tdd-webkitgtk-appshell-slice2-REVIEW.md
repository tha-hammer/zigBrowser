# Plan Review Report: WebKitGTK App Shell — Slice 2 TDD Implementation Plan

> **Plan tier: L1** (confidence: medium) — 2 L1 keyword(s) + plan size 444 lines (bounded scope; L1 >= L2 signal)
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ❌ | 8 issues |
| Interfaces | ❌ | 9 issues |
| Promises | ❌ | 11 issues |
| Data Models | ❌ | 8 issues |
| APIs | ❌ | 8 issues |

## Contracts Review

### Well-Defined
- ✅ C10 NavPolicy decision function signature and routing rules — §C10: `pub fn decide(app_base, candidate, dtype) Decision` with an explicit per-dtype routing table (use / ignore / open_in_subwindow), hash/fragment pass-through, and documented main-frame-only scope
- ✅ C11 sub-window creation, parenting, and tracking contract — §C11: webkit_web_view_new_with_related_view, new owned GtkWindow, ZbApp.children tracking, §C5-ordered teardown, last-window-quits rule, child inherits policy + IPC
- ✅ C12 IPC bridge registration, message path, and synchronous reply threading model — §C12: UCM per WebView, register_script_message_handler_with_reply('zbHost', NULL), reply issued synchronously inside the main-loop callback, g_idle_add documented for future async commands
- ✅ C13 interactive lifetime — no exit on load-failed; exit triggers fully enumerated — §C13: explicit contrast with Slice 1 one-shot model; exit 0 on last-window-closed or SIGINT/SIGTERM (130)
- ✅ C8+ E2E observation protocol lines and --e2e-protocol flag gating — §C8+: NAV / BLOCKED / SUBWIN / IPC tab-separated formats defined; flag ensures no leakage into normal app stdout
- ✅ Test-oracle independence contract — Testing Strategy: oracles are WebKit get_uri/get_title/load events, on-disk fixtures (title-before ≠ title-after), and Zig-computed uname/sum; 'no fixture-and-code-share-a-fiction tests' stated explicitly
- ✅ Slice 2 hard prereq gate on Slice 1 — Prereq & Salvage: 'Slice 2 PRs must not merge until the Slice-1 binary builds and real-page-in-window passes'

### Missing or Unclear
- ⚠️ IpcError → JS: no mechanism is specified for returning errors to the JS caller. §C12 says 'structured JS rejection' and 'handler returns an error value' but never names the WebKit API used (webkit_script_message_reply_return_value with an error-shaped JSON string vs. a JSCValue error object) nor the JSON shape of the error payload. The JS fixture cannot handle the error path without a pinned contract here. — §C12 IPC bridge contract; Behavior 5 edge-cases ('unknown command → IpcError/structured JS rejection')
- ⚠️ load-failed has no C8+ protocol line. The reload edge-case 'reload of now-deleted file → load-failed → app stays alive' requires E2E observability, but C8+ defines only NAV / BLOCKED / SUBWIN / IPC. There is no LOAD_FAIL\t<uri> line, so the harness has no signal to assert the app survived rather than exited. — §C8+; Behavior 1 edge-cases
- ⚠️ [VERIFY] Main-frame vs sub-frame detection: §C10 states 'Slice 2 enforces policy on the main frame only' but cites no WebKit API for determining whether a policy decision targets the main frame. The verified API surface table (WebKitWebView.h, WebKitPolicyDecision.h, WebKitNavigationAction.h) includes no frame-type accessor. Without this, the main-frame-only invariant and the documented sub-frame permissive stance cannot be distinguished in the shim callback. — §C10 sub-frame policy stance; Behavior 3 edge-cases
- ⚠️ JSCValue NULL guard absent from C12 boundary. §C12 says 'C reads the message via … jsc_value_to_string; keep C dumb.' If the JS caller sends a non-string value, jsc_value_to_string returns NULL. No guard is specified — passing NULL to Zig's dispatch is a boundary normalization failure that lets a malformed foreign shape propagate into business logic. — §C12 IPC bridge contract ('C reads the message via webkit_javascript_result_get_js_value → JSCValue → jsc_value_to_string')
- ⚠️ app_base derivation from the CLI argument is unspecified. §C10 references 'canonical file:// dir prefix of the app (from uri.zig)' but never documents the exact transformation: is app_base the directory component of the URI path (everything up to and including the final '/'), the full URI minus the filename, or something else? Without this, the containment check in nav_policy.decide and the B2/B3 unit test vectors cannot be pinned. — §C10; CLI/Run Contract table
- ⚠️ webkit_web_view_new_with_related_view sharing semantics undocumented. §C11 notes the child 'shares the session/context with the parent' without enumerating what that entails (shared web process, cookies, localStorage, HTTP cache). For a Tauri-like shell this may be intentional, but the contract does not confirm it, leaving the sub-window isolation model ambiguous for implementers and test authors. — §C11 sub-window contract

### Critical
- ❌ C↔Zig extern boundary is unspecified for both nav_policy and ipc. The plan defines `nav_policy.decide` and `ipc.dispatch` as pure Zig functions with Zig-native types ([]const u8, IpcError![]const u8) and simultaneously declares C shim header symbols `zb_policy_decide(const char*, const char*, int)` and `zb_ipc_dispatch`. No `pub export fn` adapter with `callconv(.C)` is defined on the Zig side, and no C-compatible wrapper signature is given for the error-union-returning `dispatch`. The plan never resolves how webkit_shim.c — a C file — actually calls across to Zig. — Impact: The C shim cannot call Zig functions with slice and error-union types via ordinary C linkage. The build will fail at link time or require undocumented calling-convention assumptions. The entire nav-policy and IPC contract is untestable and unimplementable until the C-callable adapter layer is specified.
- ❌ ipc.dispatch return-slice lifetime vs WebKit JSC string construction is unspecified. `dispatch` returns `[]const u8` allocated in an arena. The C shim must then construct a JSCValue (via jsc_value_new_string or equivalent) and call webkit_script_message_reply_return_value. The contract does not specify whether jsc_value_new_string copies the bytes before the arena is freed, nor who frees the arena and when. A wrong ordering produces a use-after-free that silently corrupts the IPC reply or crashes the process. — Impact: Unspecified memory ownership at the Zig→C→WebKit boundary makes every IPC reply unsafe by default. Any implementation that frees the arena before jsc_value_new_string copies the string produces a use-after-free with no compile-time signal, directly breaking the 'js-calls-zig-and-sees-result' differentiator behavior.

### Recommendations
- C↔Zig extern boundary (C10 nav_policy / C12 ipc): For nav_policy, add a `pub export fn zb_nav_policy_decide(base: [*:0]const u8, candidate: [*:0]const u8, dtype: c_int) c_int callconv(.C)` adapter in nav_policy.zig that wraps decide() and maps the Decision enum to an integer. For ipc, add a C-compatible `pub export fn zb_ipc_dispatch(cmd: [*:0]const u8, args: [*:0]const u8, out_buf: [*]u8, out_len: usize) c_int callconv(.C)` (or equivalent out-param pattern) so the shim can call it without error-union handling in C. Declare both in webkit_shim.h as `extern` so both sides compile against the same signature.
- ipc.dispatch return-slice lifetime: Document the mandatory ordering with an inline comment in webkit_shim.c's IPC callback: (1) call zb_ipc_dispatch into a local buffer or arena; (2) immediately call jsc_value_new_string — which copies the bytes; (3) free the arena/buffer; (4) call webkit_script_message_reply_return_value with the now-owned JSCValue. No library change needed; a one-line comment pins the contract.
- IpcError → JS error shape: Pick one approach and document it in §C12: either (a) on error, return an error-shaped JSON string such as `{"error":"UnknownCommand"}` via webkit_script_message_reply_return_value so the JS promise resolves with a detectable object, or (b) return a numeric error code via an out-param and construct a JS error in C. The fixture's JS must know which shape to expect in order for the edge-case tests to have a real oracle.
- load-failed E2E observability (C8+): Add a `LOAD_FAIL\t<uri>\t<error-description>` line to the C8+ protocol emitted from the load-failed signal handler. This makes the 'reload of deleted file → app stays alive' edge case assertable in the E2E harness without polling or timeouts.
- Main-frame detection (C10): [VERIFY] Check WebKitNavigationPolicyDecision.h for a frame accessor (e.g. webkit_navigation_policy_decision_get_frame_name returning NULL for the main frame). Add the verified symbol to the §C10 API surface table and document the exact NULL/non-NULL check the shim uses to gate main-frame-only enforcement.
- app_base derivation (C10 containment invariant): Add a one-sentence spec to §C10: e.g., 'app_base = the path component of the app-index URI up to and including the final /, canonicalized via uri.zig realpath.' Add a unit-test vector in nav_policy_test.zig that derives app_base from a known file:// CLI argument and confirms the containment result.
- JSCValue NULL guard (C12 IPC boundary): After jsc_value_to_string in the IPC callback, add: `if (!msg_str) { g_warning("zbHost: non-string message dropped"); return; }` This is a single-line guard sufficient to prevent a NULL from crossing the C→Zig boundary.

## Interfaces Review

### Well-Defined
- ✅ nav_policy.decide — complete Zig signature, pure function, no error return — §C10: pub fn decide(app_base: []const u8, candidate: []const u8, dtype: DecisionType) Decision — single consistent return style, no error union
- ✅ Decision and DecisionType enums — all variants named — §C10: Decision { use, ignore, open_in_subwindow }; DecisionType { navigation_action, new_window_action, response }
- ✅ IpcError error set — variants enumerated — §C12: pub const IpcError = error{ UnknownCommand, BadArgs }
- ✅ zb_reload C signature — parameters and types stated — B1 Files touched, webkit_shim.h: zb_reload(ZbWindow*, int bypass_cache)
- ✅ zb_policy_decide C signature — parameters and return type stated — B2 Files touched, webkit_shim.h: int zb_policy_decide(const char* base, const char* uri, int dtype)
- ✅ C8+ stdout protocol line formats — all four tokens fully specified — §C8+: NAV\t<uri>\t<title>, BLOCKED\t<uri>, SUBWIN\t<uri>, IPC\t<cmd>\t<result>
- ✅ CLI/run contract — flag names, exit codes, C13 lifetime semantics — CLI/Run Contract table: --e2e-protocol, exit 0 / 130, interactive no-exit-on-load-failed
- ✅ ipc.dispatch error-return discipline — IpcError! union only, no mixed style declared — §C12 Zig signature: IpcError![]const u8; no competing throws-style or Result-style declared elsewhere in ipc.zig

### Missing or Unclear
- ⚠️ int zb_policy_decide return value ↔ Decision enum ordinal mapping undocumented — the integer values 0/1/2 are not explicitly mapped to use/ignore/open_in_subwindow; any off-by-one or reordering silently misroutes policy — §C10 C10 contract; B2 Files touched webkit_shim.h
- ⚠️ app.zig public interface entirely absent — referenced as 'host trigger seam' (B1) and 'UCM wiring per window' (B5) but no function names, parameter types, return types, or visibility modifiers are given — B1 Files touched: src/app.zig; B5 Files touched: src/app.zig
- ⚠️ ZbApp.children container type undeclared — C array with fixed cap, GPtrArray*, or GList*? Teardown iteration order (§C5/§C13) and E2E window-count assertion depend on this — §C11 sub-window contract; §C13 interactive lifetime; B4 Files touched webkit_shim.h
- ⚠️ zb_window_new(app, view) mentioned only in B4 refactor — parameter types and return type never stated in any §C contract section; the shared window-build routine has no defined interface — B4 TDD Cycle — Refactor step
- ⚠️ [VERIFY] C shim main-frame detection mechanism not specified — §C10 states main-frame-only enforcement but neither decide() nor zb_policy_decide has an is_main_frame parameter; the WebKit API call the C callback uses to identify main-frame navigations is absent from the verified API surface table — §C10 sub-frame stance; verified API surface table
- ⚠️ --e2e-protocol flag propagation interface undefined — the mechanism by which webkit_shim.c emit functions read this flag (C global set by app.zig, ZbApp field, shim init parameter) is never stated — §C8+; CLI/Run Contract table

### Critical
- ❌ ipc.dispatch arena parameter has no type annotation — 'pub fn dispatch(arena, cmd: []const u8, args_json: []const u8)' is not valid Zig syntax; the allocator type is missing, the returned []const u8 slice has no defined owner, and memory-management responsibility between dispatch and its callers is unspecified — Impact: ipc.zig cannot be compiled; ipc_test.zig cannot call dispatch; the C-ABI wrapper (zb_ipc_dispatch) cannot be written because the allocator strategy is unknown; B5 (the differentiator) is entirely unimplementable from this plan
- ❌ zb_ipc_dispatch C-ABI export has no parameter list or return type — listed only as 'extern' in the shim header note; Zig error unions (IpcError![]const u8) are not C-ABI-compatible and require an explicit export wrapper, but neither the Zig export fn nor its C-compatible signature is defined anywhere in the plan — Impact: The C shim cannot call into ipc.zig; the entire command-dispatch path is broken at the FFI seam; without this bridge B5 cannot be implemented and the Slice-4 IPC extension point ('table is the Slice-4 seam') has no defined interface to extend
- ❌ zb_ipc_reply C signature is literally '(...)' — the function that wraps webkit_script_message_reply_return_value has no defined parameter list; neither the WebKitScriptMessageReply* handle nor the result/error string parameters are specified — Impact: The C shim cannot implement the reply path; the Zig extern declaration for zb_ipc_reply cannot be written; error-reply behaviour (unknown command → structured JS rejection) has no defined calling convention, so the 'no crash on unknown command' edge case in B5 is unverifiable

### Recommendations
- ipc.dispatch arena parameter: Fix §C12 to read: pub fn dispatch(arena: std.mem.Allocator, cmd: []const u8, args_json: []const u8) IpcError![]const u8. Add one sentence stating the caller owns the returned slice and must free it with the same allocator. This is the minimal change that unblocks both ipc_test.zig and the C-ABI wrapper.
- zb_ipc_dispatch Zig→C ABI bridge: Add to §C12 an explicit export fn in ipc.zig (or a thin src/ipc_ffi.zig): e.g. export fn zb_ipc_dispatch(cmd: [*:0]const u8, args: [*:0]const u8, out: *[*:0]const u8) c_int — returns 0 on success (out points to result), non-zero on IpcError, with a companion export fn zb_ipc_free(ptr: [*:0]const u8) void. Declare the matching C extern in webkit_shim.h. Keep ipc.dispatch as the pure internal function.
- zb_ipc_reply C signature: Replace '(...)' in §C12 and webkit_shim.h with a concrete signature, e.g.: void zb_ipc_reply(WebKitScriptMessageReply* reply, const char* result_json, const char* error_msg) — where exactly one of result_json/error_msg is non-NULL. Document which WebKit call handles each branch (webkit_script_message_reply_return_value vs the error path).
- zb_policy_decide int↔Decision ordinal mapping: Add a one-line table to §C10: 'zb_policy_decide returns 0=use, 1=ignore, 2=open_in_subwindow matching Decision enum declaration order.' This costs one line and prevents silent misroutes at the C↔Zig seam.
- app.zig public interface: Add a short §C14 block enumerating app.zig's public functions — at minimum: the entry point (pub fn run or main), the reload trigger (pub fn reload(win: *ZbWindow, bypass: bool) void), and confirmation that UCM wiring is done inside the window-creation routine rather than as a separate call. Without this, the 'host trigger seam' and 'UCM wiring per window' references in B1/B5 are unimplementable.
- ZbApp.children container type: Specify the container type in §C11 — a fixed C array with a small cap (e.g. ZbWindow* children[16]; size_t n_children) is the simplest L1-appropriate choice. State the maximum number of simultaneous child windows and what happens when the cap is exceeded (emit a warning, refuse the create signal). This unblocks both the teardown loop in §C13 and the E2E window-count assertion in B4.

## Promises Review

### Well-Defined
- ✅ C10 `decide` is declared pure and side-effect-free — §C10: 'Pure, side-effect-free decision in Zig (src/nav_policy.zig), called from the C decide-policy cb'
- ✅ Interactive lifetime: load-failed does not exit the process; app shows WebKit error page and stays alive — §C13: 'Process does not exit on load-failed (interactive)'
- ✅ IPC reply is synchronous inside the WebKit main-loop callback; no cross-thread hop in Slice 2 — §C12 Threading: 'replies are issued synchronously inside the callback (no cross-thread hop). Any future async command must hop back via g_idle_add'
- ✅ Path-traversal protection: `…/../outside.html` must NOT be treated as in-base; vector explicitly included in the test table — Behavior 2 Property: 'proven over a vector table incl. path-traversal (…/../outside.html) which must NOT be treated as in-base'
- ✅ Hash/fragment navigation within the same document → `use`; no policy churn, no full reload — §C10: 'Hash/fragment navigation within the same document → use (no policy churn)'
- ✅ Sub-frame policy is explicitly scoped: Slice 2 enforces policy on the main frame only — §C10: 'Sub-frame policy (documented stance): Slice 2 enforces policy on the main frame only; sub-frame loads inside an allowed app page are permitted'
- ✅ `--e2e-protocol` flag gates all stdout protocol lines; default off so real users never see them — §C8+: 'These lines are gated behind an explicit --e2e-protocol flag (default off) so a real user never sees them'
- ✅ IPC commands `ping`, `os.info`, `add` are verified against values JS cannot fabricate (independent oracle) — §C12: 'Minimal command set (all return values JS cannot fabricate on its own — independent oracle)'; Behavior 5 Oracle
- ✅ Child window teardown: closing a child destroys only that child; app quits only when tracked window set is empty — §C11: 'closing a child destroys only that window; closing the last window quits (C13)'; §C13: 'the app tracks all windows and quits gtk_main when the set is empty'

### Missing or Unclear
- ⚠️ Retryability not declared for any error category. The plan surfaces `load-failed` (WebKit), `IpcError.UnknownCommand`, and `IpcError.BadArgs` but never states — even as a boolean false — whether any should be retried. The implied 'log + continue / show error page' behavior is correct for this tier but is unstated, leaving implementers to guess. — §C13 (load-failed), §C12 (IpcError variants), Behavior 5 edge cases
- ⚠️ `create`-signal child policy and IPC wiring mechanism is unspecified. §C11 states the child 'inherits the same decide-policy handler' and 'the same IPC handler', but WebKit policy-decision signals and UCM handlers are per-view — they are not inherited via `webkit_web_view_new_with_related_view`. The plan does not state that the shim must explicitly call `g_signal_connect` and re-register the `zbHost` handler on the child's UCM inside the `create` callback before returning. — §C11 Sub-window contract; Behavior 4 Green step
- ⚠️ E2E 'window-count == 2' oracle has no specified observation mechanism. The §C8+ protocol emits only `SUBWIN\t<uri>` — no count line. How the harness derives a count of 2 (count SUBWIN lines? a separate `WINCOUNT\t<n>` line?) is unspecified. — Behavior 4 Test Specification: 'the app now has two windows; window-count == 2 (via the protocol / tracked count)'; §C8+ protocol definition
- ⚠️ `window.open()` from JS triggering the `create` signal is listed as an edge case ('same path') but the verified API symbol table does not explicitly confirm that `window.open()` fires the `create` signal in webkit2gtk-4.1. `WebKitWebView.h:260` shows the signal signature but does not document which JS constructs trigger it. — Behavior 4 Edge Cases: 'window.open() from JS → same path'
- ⚠️ Cancelled-in-flight load during reload may fire a spurious `load-failed` event. When `zb_reload` cancels the prior in-flight load, WebKit typically delivers a `load-failed` (or `load-changed` with FINISHED) for the cancelled request. The plan does not specify whether this fires a `NAV` or error stdout line, nor whether the E2E harness must ignore it. — Behavior 1 Edge Cases: 'reload while a prior load is in flight → prior cancelled cleanly (Slice 1 §C5)'
- ⚠️ Main window membership in the all-windows tracking set is unspecified. §C13 says 'quits gtk_main when the set is empty', but §C11 defines `ZbApp.children` as the child structure. If the main window is not also in `ZbApp.children`, the quit-on-empty logic requires special-casing that is undocumented. — §C11 (`ZbApp.children`); §C13 (last-window-close)
- ⚠️ `ZbApp.children` data structure and its allocator are unspecified. The plan names the field but does not state the Zig container (ArrayList? fixed-size array? linked list?) or which allocator backs it, leaving cleanup-on-quit undefined. — §C11: 'tracked in the shim's window list (ZbApp.children)'

### Critical
- ❌ B4 property directly contradicts C10 and B3. C10 states: `navigation_action` + foreign origin → `ignore`. B3's property confirms: 'for all `c` not within `app_base` and `dtype == navigation_action`, `decide(...) == .ignore`'. Yet B4's property states: 'every `navigation_action` to a foreign http/https origin resolves to exactly one new tracked child window.' A `navigation_action` to a foreign origin cannot simultaneously be `.ignore` and `.open_in_subwindow`. The fixture makes this concrete: `index.html` includes 'an external link' (a plain href without `target=_blank`, which WebKit classifies as `navigation_action`). An implementer who follows C10 satisfies B3 and fails B4; one who follows B4's property satisfies B4 and fails B3. — Impact: B3 and B4 cannot both pass as written. Whichever rule the implementer follows, one behavior will silently be wrong at runtime, and the contradiction will not be surfaced until integration testing.
- ❌ `NAV` stdout line emit point is ambiguously pinned to 'COMMITTED/FINISHED'. These are distinct WebKit load states. At `WEBKIT_LOAD_COMMITTED` the HTML has not yet been parsed, so `webkit_web_view_get_title` typically returns NULL or an empty string — the `NAV\t<uri>\t<title>` line would have no title, breaking the reload and allow-navigation test oracles. If the intent is 'emit at either state', two `NAV` lines are emitted per navigation, which breaks all harness assertions expecting exactly one. The emit point must be pinned to one named state. — Impact: Every E2E reload and navigation-allowed test is either unconditionally flaky (empty title at COMMITTED) or structurally broken (double emission), making the plan's primary E2E oracle non-functional.
- ❌ UCM GObject caller-reference cleanup is unspecified. `webkit_user_content_manager_new()` returns a GObject with ref-count 1. After passing the pointer to `webkit_web_view_new_with_user_content_manager()` (which adds its own ref), the caller must call `g_object_unref(ucm)` to release the initial reference. The plan specifies neither this release nor who is responsible for it. In a multi-window session (main window + one UCM per child sub-window), every unhandled reference leaks one GObject for the process lifetime. — Impact: Memory leak of one GObject per window opened. In apps that open many sub-windows (e.g., Behavior 4 grandchild edge case), growth is unbounded for the session lifetime.
- ❌ The `arena` parameter to `ipc.dispatch` has no specified owner, lifetime, or cleanup responsibility. The signature `pub fn dispatch(arena, cmd, args_json) IpcError![]const u8` returns a slice backed by the arena, but the plan does not state who supplies the arena, who resets or frees it after the reply is consumed, or what happens on re-entrant calls. Without this, the C shim cannot correctly sequence: call dispatch → use returned slice to build JSCValue → free the arena. — Impact: Memory leak on every IPC call if the arena is never freed; use-after-free if it is freed before `webkit_script_message_reply_return_value` consumes the slice. Either defect is silent — no compile-time or runtime indicator in the plan as written.

### Recommendations
- B3/B4 conflict — foreign navigation_action routing: Pick one rule and state it in C10 without contradiction. Simplest fix: `navigation_action` to any foreign origin → `ignore` (B3 wins); only `new_window_action` (target=_blank / window.open) → `open_in_subwindow` (B4). Remove 'every navigation_action to a foreign http/https origin' from B4's property. Update the B4 fixture so the 'external link' uses `target=_blank`; keep a separate plain-href foreign link for the B3 block test.
- NAV emit timing: Pin `NAV\t<uri>\t<title>` to exactly `WEBKIT_LOAD_FINISHED`. Add one sentence to §C8+: 'Emitted once per main-frame navigation, at WEBKIT_LOAD_FINISHED only; COMMITTED is not an emit point.' This ensures `get_title` is reliably populated when the line is written.
- UCM GObject cleanup: Add to §C12 and the C11 child-builder description: 'After passing ucm to the view constructor, the shim calls g_object_unref(ucm) to release the initial reference; the view holds its own reference for its lifetime.' This is a one-liner in the shim's window-build routine.
- ipc.dispatch arena ownership: Specify in §C12: the C shim declares a fixed stack buffer (e.g. 4 KB `u8` array) and wraps it in a `std.heap.FixedBufferAllocator` before calling `dispatch`; the buffer is valid until after `webkit_script_message_reply_return_value` returns; the shim resets the FBA at the top of each IPC callback. No heap allocator is needed for Slice 2's small replies. Document this constraint in the dispatch signature comment.
- Retryability declarations: Add one sentence to §C12 and §C13: 'No error in this slice is retried. load-failed → show WebKit's error page, log uri to stderr, stay alive. IpcError.UnknownCommand and IpcError.BadArgs → return the error description to JS as a rejected promise value, log to stderr; no retry.'
- Child policy and IPC signal wiring: Add to §C11: 'Inside the create callback, before returning the child GtkWidget, the shim must explicitly call g_signal_connect(child_view, "decide-policy", G_CALLBACK(on_decide_policy), app) and register zbHost on the child UCM — WebKit does not propagate signal connections from a related view.'
- E2E window-count oracle: Add a `WINCOUNT\t<n>` line to §C8+ emitted whenever the tracked window set changes (after create, after destroy). The B4 harness then asserts `WINCOUNT\t2` after the sub-window opens. Alternatively, document that counting `SUBWIN` lines is the intended method — either approach, pick one and state it.

## Data Models Review

### Well-Defined
- ✅ Decision enum — §C10 — `pub const Decision = enum { use, ignore, open_in_subwindow };` — three variants, exhaustive for the described dispatch rules
- ✅ DecisionType enum — §C10 — `pub const DecisionType = enum { navigation_action, new_window_action, response };` — variants align one-to-one with the WebKitPolicyDecisionType values cited at WebKitWebView.h:107-109
- ✅ IpcError error set — §C12 — `pub const IpcError = error{ UnknownCommand, BadArgs };` — two named variants with semantics described
- ✅ E2E protocol line formats — §C8+ — NAV/BLOCKED/SUBWIN/IPC tab-separated lines with exact field order and gating flag (`--e2e-protocol`) specified
- ✅ nav_policy.decide function signature — §C10 — `pub fn decide(app_base: []const u8, candidate: []const u8, dtype: DecisionType) Decision` — all parameter and return types present
- ✅ IPC command surface (names and top-level semantics) — §C12 — ping/os.info/add named with return intent described; B5 TDD shows a concrete unit-test value for `add`

### Missing or Unclear
- ⚠️ os.info return JSON schema not specified — field names, nesting, and string vs object shape are absent — §C12 — 'real uname fields (sysname/release/machine)' stated but no JSON structure given; B5 oracle checks `IPC\tos.info\t<result>` without defining what <result> looks like
- ⚠️ add command return type ambiguity — unit test shows string `"5"` but whether the canonical return is a JSON string or JSON number is never stated — B5 TDD Cycle — `dispatch("add", "{\"a\":2,\"b\":3}")` → `"5"` in the Red step; the JS consumer's expectation (`#zb-out` text) depends on knowing whether this is `"5"` (string) or `5` (number)
- ⚠️ IPC message envelope `args` field has no per-command schema — shape for zero-arg commands (ping, os.info) vs two-int command (add) is never tabulated — §C12 — envelope declared as `{cmd, args}` with `args_json: []const u8`; no rule given for whether `args` is absent, `{}`, or `null` for no-arg commands, and no type constraint on `a`/`b` in add
- ⚠️ DecisionType ↔ C WebKitPolicyDecisionType integer mapping not defined — the shim signature `int zb_policy_decide(…, int dtype)` passes a raw C enum integer but the mapping to Zig `DecisionType` variants is implicit — §C10 / B2 Files touched — `int dtype` in `zb_policy_decide` C signature; WebKitWebView.h:107-109 lists the C enum but no cast/switch table appears in the plan
- ⚠️ E2E protocol `<result>` field in IPC lines has no tab-escaping rule — os.info's JSON-object return will contain braces/colons and may contain tabs, breaking the tab-delimited parser — §C8+ — `IPC\t<cmd>\t<result>`; result for os.info is a multi-field JSON object whose raw form is tab-unsafe; no escaping or encoding rule specified
- ⚠️ ipc.dispatch `arena` parameter has no declared type in the plan — §C12 — `pub fn dispatch(arena, cmd: []const u8, args_json: []const u8) IpcError![]const u8` — `arena` is listed positionally with no type annotation; whether it is `std.mem.Allocator` or something narrower is unresolved

### Critical
- ❌ ZbWindow struct fields are never defined anywhere in this plan — the struct is named and referenced throughout but carries no field list — Impact: The C shim and every Zig caller must agree on memory layout at compile time. Without a field list, B1 (reload), B2/B3 (policy decision), B4 (child tracking and sub-window build), and B5 (UCM wiring) each have an unresolved struct dependency; implementors will independently invent incompatible layouts, breaking the C↔Zig boundary silently at runtime rather than at compile time
- ❌ ZbApp.children field type is unspecified — the plan names the field and mandates it be iterated for teardown and queried for window-count, but gives no concrete type — Impact: Teardown iteration order (§C5/C13), the last-window-close quit condition (C13), and the B4 window-count oracle all depend on the concrete collection type (C array with capacity, GPtrArray, fixed-size sentinel array, etc.). The choice affects allocation strategy, maximum child count, and whether the count is O(1) or O(n); without it the shim and the E2E harness will be coded against incompatible assumptions

### Recommendations
- ZbWindow and ZbApp structs: Add an explicit field list directly in the plan under §C11 or §C13 — for example: `ZbWindow { GtkWidget* gtk_window; WebKitWebView* view; WebKitUserContentManager* ucm; struct ZbApp* app; }` and `ZbApp { ZbWindow* main; ZbWindow** children; int child_count; int child_cap; }` (or equivalent). Exact names matter less than committing to them before any behavior is coded so all five behaviors share one authoritative layout.
- IPC command schemas: Add a compact table in §C12 with three columns — command, args JSON shape, return JSON shape. For example: ping → args `{}`, return `"pong"` (string); add → args `{"a":integer,"b":integer}`, return `"<sum>"` (string); os.info → args `{}`, return `{"sysname":string,"release":string,"machine":string}`. This resolves the os.info nesting ambiguity, the add string-vs-number question, and the no-args encoding question in one place.
- E2E protocol IPC result field: Add one sentence to §C8+ specifying that `<result>` in `IPC\t<cmd>\t<result>` has any literal tab characters replaced with a space (or URL-encoded) before emission. This prevents the os.info JSON-object return from splitting the parser into spurious extra fields without requiring a new protocol format.

## APIs Review

### Well-Defined
- ✅ webkit_web_view_reload / webkit_web_view_reload_bypass_cache — B1 TDD cycle; symbols verified at WebKitWebView.h:415,418; zb_reload(ZbWindow*, int bypass_cache) declared in 'Files touched: webkit_shim.h'
- ✅ nav_policy.decide(app_base: []const u8, candidate: []const u8, dtype: DecisionType) → Decision — C10 canonical contract; all enum variants (use, ignore, open_in_subwindow / navigation_action, new_window_action, response) listed with routing rules
- ✅ zb_policy_decide(const char* base, const char* uri, int dtype) → int [C shim entry] — B2 'Files touched: src/webkit_shim.h' entry; linked to C10 decision table
- ✅ zb_reload(ZbWindow*, int bypass_cache) [C shim entry] — B1 'Files touched: src/webkit_shim.h' entry; bypass_cache semantics tied to webkit_web_view_reload_bypass_cache
- ✅ ipc.dispatch(arena, cmd: []const u8, args_json: []const u8) IpcError![]const u8 — C12 canonical contract; IpcError variants {UnknownCommand, BadArgs} listed; caller/callee roles stated
- ✅ IPC JS call surface: window.webkit.messageHandlers.zbHost.postMessage(JSON.stringify({cmd, args})) — C12; handler name 'zbHost' pinned; JSON envelope shape stated; symbol verified at WebKitUserContentManager.h:119
- ✅ E2E stdout protocol lines: NAV\t<uri>\t<title>, BLOCKED\t<uri>, SUBWIN\t<uri>, IPC\t<cmd>\t<result> — §C8+ — tab-separated format defined per line type; --e2e-protocol flag gating specified
- ✅ CLI contract: positional <app-index>, --e2e-protocol flag, exit 0 / exit 130 on signal — 'CLI / Run Contract' table; C13 interactive lifetime model
- ✅ Sub-window creation via webkit_web_view_new_with_related_view + new owned GtkWindow — C11; symbol verified at WebKitWebView.h:334; child tracking via ZbApp.children stated
- ✅ IPC ping and add command specs — C12 minimal command set: ping→'pong'; add({a,b})→integer sum; independent-oracle rationale stated

### Missing or Unclear
- ⚠️ os.info response JSON shape is unspecified — plan names 'sysname/release/machine' fields but never defines the envelope ({} object? flat string? key order?); B5 E2E and unit assertions against #zb-out cannot be written without a canonical shape — C12 minimal command set; B5 test specification oracle
- ⚠️ IPC error response format on the JS side is undefined — plan says 'structured JS rejection / page shows the error' for UnknownCommand/BadArgs but does not specify what value webkit_script_message_reply_return_value delivers on failure (error string? JSON {error:...}? a WebKit rejection?); B5 edge-case tests cannot assert the correct DOM state — C12 edge cases; B5 'unknown command → IpcError/structured JS rejection'
- ⚠️ NAV and SUBWIN protocol-line emit point is ambiguous — §C8+ says 'on a main-frame COMMITTED/FINISHED success', naming two distinct WebKit load states; get_title is only stable after FINISHED; a test waiting for NAV at COMMITTED may read a stale or empty title — §C8+ E2E observation protocol extension
- ⚠️ dispatch arena/allocator parameter type is not specified — the C12 Zig signature writes 'arena' without a type annotation; callers (the C shim extern) and unit tests (ipc_test.zig) cannot be written without knowing whether it is std.mem.Allocator, *std.heap.ArenaAllocator, or another type — C12 ipc.zig canonical contract
- ⚠️ No E2E protocol line for IPC error paths — §C8+ defines IPC\t<cmd>\t<result> for success only; an UnknownCommand or BadArgs case emits nothing observable, so the E2E harness cannot distinguish a real error response from a silent no-op or crash — §C8+ protocol extension; B5 edge cases
- ⚠️ IPC\t<cmd>\t<result> is tab-delimited but the result field is unbounded and may itself contain tab characters (e.g. pretty-printed JSON, or an os.info value with embedded whitespace); no escaping, quoting, or length-prefixing rule is defined, leaving the harness parser underspecified — §C8+ protocol format

### Critical
- ❌ zb_ipc_reply and zb_ipc_dispatch C signatures are written as '...' (literal ellipsis) in the shim-header entry — no parameter types, no return type, no stated lifetime for the returned char*; the C translation unit cannot be compiled, and the Zig↔C ABI boundary (how IpcError and []const u8 surface across the FFI) is entirely unspecified — Impact: The C shim cannot be written or compiled; the IPC bridge — the plan's stated differentiator and the only behavior that proves Zig does real work — is unbuildable until both signatures are pinned
- ❌ Decision enum integer encoding for the C↔Zig ABI boundary is never defined — zb_policy_decide returns int and the C decide-policy callback must map that int to webkit_policy_decision_use / _ignore / the sub-window branch, but the mapping (use=?, ignore=?, open_in_subwindow=?) is absent; the same gap affects how a raw WebKitPolicyDecisionType integer (from the C callback parameter) is mapped to Zig's DecisionType enum — Impact: nav_policy.zig and the C shim will compile in isolation but silently mis-route decisions at the boundary — allow/block/subwindow behaviors could be inverted or produce undefined behavior with no compile-time or test-time signal

### Recommendations
- zb_ipc_dispatch / zb_ipc_reply C signatures (resolves critical): Add explicit C declarations to webkit_shim.h before any implementation begins. Pin parameter types, return type, and ownership: e.g. 'int zb_ipc_dispatch(const char* cmd, const char* args_json, char** out_result)' with a matching 'void zb_ipc_result_free(char*)'; or use a caller-supplied buffer. Document whether IpcError surfaces as a non-zero return code or a sentinel out-value. The Zig extern must match exactly.
- Decision / DecisionType integer encoding (resolves critical): Add a two-column mapping table in C10 (or as a comment block in webkit_shim.h): Decision.use=0, Decision.ignore=1, Decision.open_in_subwindow=2; WebKitPolicyDecisionType WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION→DecisionType.navigation_action, etc. A comptime std.debug.assert or a C static_assert can enforce the mapping and will catch future enum reordering.
- os.info response JSON shape: Define the exact object in C12: e.g. '{"sysname":"Linux","release":"6.x","machine":"x86_64"}'. Use this as the canonical fixture against which B5 unit vectors and the #zb-out E2E assertion are written.
- NAV / SUBWIN emit point: Resolve the COMMITTED-vs-FINISHED ambiguity in §C8+ by picking WEBKIT_LOAD_FINISHED; state this explicitly. SUBWIN should follow the same rule for the child view's load. This guarantees get_title is stable when the harness reads it.
- IPC error E2E observability: Add an IPCERR\t<cmd>\t<error-code> line to the §C8+ protocol (emitted instead of IPC\t... when dispatch returns an error). This lets the E2E harness assert that UnknownCommand/BadArgs exercised the real C→Zig path rather than a silent swallow or crash.
- dispatch allocator parameter: Spell out the type in the C12 Zig signature — std.mem.Allocator is idiomatic; write it explicitly so ipc_test.zig can pass std.testing.allocator without guessing, and so the C-side caller knows whether it must supply an arena.

## Scaffolding & Realness (Hostile Check)

None — plan builds real, verifiable software.

The plan demonstrates deliberate anti-scaffolding discipline that survives hostile scrutiny:

- **Independent oracles are mandated, not assumed.** The Testing Strategy explicitly states "no fixture-and-code-share-a-fiction tests" and grounds oracles in WebKit `get_uri`/`get_title`/load events, on-disk fixtures (title-before ≠ title-after), and Zig-computed `uname`/`sum`. The IPC command set is chosen so all returns are "values JS cannot fabricate on its own" — `os.info` reads real `uname`, `add` does real arithmetic verified independently (2+3=5 computed by the test, not echoed by the code).
- **Human-observable artifacts exist per milestone.** Real pages render in real GtkWindows; `NAV`/`BLOCKED`/`SUBWIN`/`IPC` stdout lines carry independently-derived content (e.g., the title in `NAV` comes from WebKit parsing the on-disk fixture, not from app logic).
- **No named-but-unbuilt dependency.** WebKit/GTK API symbols are cited with verified header line numbers; nothing is "wired for later" as a stand-in feature. The `g_idle_add` async path and the "Slice-4 seam" are explicitly labeled future work, not presented as completed Slice-2 features.
- **A hard prereq gate prevents shipping on green-only.** "Slice 2 PRs must not merge until the Slice-1 binary builds and real-page-in-window passes" ties done-ness to a real artifact, not to test color.

Note for the verdict: the criticals below are *spec-completeness* defects (undefined FFI signatures, memory ownership, enum encodings, struct fields, a B3/B4 logic contradiction) that make the plan **unimplementable**, not fake-but-green. They are correctly captured under each domain's Critical section. The realness check itself passes.

## Critical Issues (Must Address Before Implementation)

1. **[Contracts]** C↔Zig extern boundary unspecified for both nav_policy and ipc — no `pub export fn` / `callconv(.C)` adapter exists for slice/error-union types; the C shim cannot call Zig as written.
2. **[Contracts]** ipc.dispatch return-slice lifetime vs JSC string construction unspecified — arena free-ordering relative to `jsc_value_new_string` is undefined; use-after-free risk with no compile-time signal.
3. **[Interfaces]** ipc.dispatch arena parameter has no type annotation — signature is not valid Zig; ipc.zig cannot compile, ipc_test.zig cannot call it, B5 (the differentiator) is unimplementable.
4. **[Interfaces]** zb_ipc_dispatch C-ABI export has no parameter list or return type — error union is not C-ABI-compatible and no export wrapper is defined; the IPC FFI seam is broken.
5. **[Interfaces]** zb_ipc_reply C signature is literally `(...)` — reply path uncodable; the unknown-command edge case is unverifiable.
6. **[Promises]** B4 property directly contradicts C10 and B3 — a foreign-origin `navigation_action` cannot be both `.ignore` (B3) and `.open_in_subwindow` (B4); one behavior is silently wrong whichever rule is followed.
7. **[Promises]** NAV stdout emit point ambiguously pinned to "COMMITTED/FINISHED" — title is empty at COMMITTED or the line double-emits; the primary E2E oracle is flaky or structurally broken.
8. **[Promises]** UCM GObject caller-reference cleanup unspecified — missing `g_object_unref(ucm)` leaks one GObject per window for the session lifetime.
9. **[Promises]** ipc.dispatch arena owner/lifetime/cleanup unspecified — guaranteed leak or use-after-free on every IPC call, silently.
10. **[Data Models]** ZbWindow struct fields never defined — every behavior calls into `ZbWindow*` with no agreed layout; implementors will invent incompatible structs and break the C↔Zig boundary at runtime.
11. **[Data Models]** ZbApp.children field type unspecified — teardown order, last-window-quit, and B4 window-count oracle all depend on a collection type that is never chosen.
12. **[APIs]** zb_ipc_reply and zb_ipc_dispatch C signatures written as literal `...` — the C translation unit cannot compile; the IPC bridge is unbuildable.
13. **[APIs]** Decision/DecisionType integer encoding for the C↔Zig ABI undefined — int↔enum mapping absent; allow/block/subwindow can silently invert with no compile-time or test-time signal.

(Note: the [VERIFY]-prefixed main-frame-detection findings are intentionally excluded here — they remain under Missing or Unclear pending confirmation of the WebKit API surface.)

## Approval Status

- [ ] Ready for Implementation — no critical issues AND Scaffolding & Realness is clean
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues OR any Scaffolding & Realness violation must be resolved first

Thirteen confirmed criticals across all five domains — concentrated at the C↔Zig FFI seam (undefined export signatures, integer encodings, struct layouts, and memory ownership) plus a direct B3/B4 routing contradiction — make the plan unimplementable as written. The realness check passes, but the spec gaps must be closed before any code is written.


## Beads Tracking

Epic: **[Plan Review Epic] 2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2 — 13 critical, 31 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **13** critical, **31** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | critical | [Plan Review §contracts] C↔Zig extern boundary is unspecified for both nav_policy an… <!-- fp:c439f729 --> | _(not minted)_ |
| contracts | critical | [Plan Review §contracts] ipc.dispatch return-slice lifetime vs WebKit JSC string con… <!-- fp:87e2e8bd --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] IpcError → JS: no mechanism is specified for returning erro… <!-- fp:b1ef82f7 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] load-failed has no C8+ protocol line. The reload edge-case … <!-- fp:b9cc88c8 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] [VERIFY] Main-frame vs sub-frame detection: §C10 states 'Sl… <!-- fp:d5514823 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] JSCValue NULL guard absent from C12 boundary. §C12 says 'C … <!-- fp:a672194f --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] app_base derivation from the CLI argument is unspecified. §… <!-- fp:c2bc5651 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] webkit_web_view_new_with_related_view sharing semantics und… <!-- fp:e707c217 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] ipc.dispatch arena parameter has no type annotation — 'pub … <!-- fp:52d9cb3a --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] zb_ipc_dispatch C-ABI export has no parameter list or retur… <!-- fp:507b90a7 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] zb_ipc_reply C signature is literally '(...)' — the functio… <!-- fp:2fd42cfd --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] int zb_policy_decide return value ↔ Decision enum ordinal m… <!-- fp:c3c23f0a --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] app.zig public interface entirely absent — referenced as 'h… <!-- fp:51df498a --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] ZbApp.children container type undeclared — C array with fix… <!-- fp:fc25b238 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] zb_window_new(app, view) mentioned only in B4 refactor — pa… <!-- fp:bb0822dc --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] C shim main-frame detection mechanism not specifie… <!-- fp:5e7f5eef --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] --e2e-protocol flag propagation interface undefined — the m… <!-- fp:ddcd43c3 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] B4 property directly contradicts C10 and B3. C10 states: `n… <!-- fp:fbe582e5 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] `NAV` stdout line emit point is ambiguously pinned to 'COMM… <!-- fp:1723c2d7 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] UCM GObject caller-reference cleanup is unspecified. `webki… <!-- fp:a4ad09f5 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] The `arena` parameter to `ipc.dispatch` has no specified ow… <!-- fp:3f596395 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Retryability not declared for any error category. The plan … <!-- fp:0f8f3819 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] `create`-signal child policy and IPC wiring mechanism is un… <!-- fp:59c7ec40 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] E2E 'window-count == 2' oracle has no specified observation… <!-- fp:954ed66f --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] `window.open()` from JS triggering the `create` signal is l… <!-- fp:5356467a --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Cancelled-in-flight load during reload may fire a spurious … <!-- fp:2337ac5b --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Main window membership in the all-windows tracking set is u… <!-- fp:23a26a2d --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] `ZbApp.children` data structure and its allocator are unspe… <!-- fp:4a7a7777 --> | _(not minted)_ |
| data_models | critical | [Plan Review §data_models] ZbWindow struct fields are never defined anywhere in this p… <!-- fp:b6a7d6d8 --> | _(not minted)_ |
| data_models | critical | [Plan Review §data_models] ZbApp.children field type is unspecified — the plan names t… <!-- fp:3f7fcf1e --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] os.info return JSON schema not specified — field names, nes… <!-- fp:0e9762b1 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] add command return type ambiguity — unit test shows string … <!-- fp:a94d853f --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] IPC message envelope `args` field has no per-command schema… <!-- fp:ea20e493 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] DecisionType ↔ C WebKitPolicyDecisionType integer mapping n… <!-- fp:57b23418 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] E2E protocol `<result>` field in IPC lines has no tab-escap… <!-- fp:de5a602b --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] ipc.dispatch `arena` parameter has no declared type in the … <!-- fp:42dd99c3 --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] zb_ipc_reply and zb_ipc_dispatch C signatures are written a… <!-- fp:cac5490c --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] Decision enum integer encoding for the C↔Zig ABI boundary i… <!-- fp:9cb01c61 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] os.info response JSON shape is unspecified — plan names 'sy… <!-- fp:158326aa --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] IPC error response format on the JS side is undefined — pla… <!-- fp:5e378baa --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] NAV and SUBWIN protocol-line emit point is ambiguous — §C8+… <!-- fp:679ef388 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] dispatch arena/allocator parameter type is not specified — … <!-- fp:85d3d162 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] No E2E protocol line for IPC error paths — §C8+ defines IPC… <!-- fp:95d2ab4f --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] IPC\t<cmd>\t<result> is tab-delimited but the result field … <!-- fp:7dea8d0d --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.