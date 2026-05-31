# Plan Review Report: zigBrowser Slice 3/4 — IPC Command Surface + Cross-OS Backends TDD Implementation Plan

> **Plan tier: L1** (confidence: medium) — 2 L1 keyword(s) + plan size 425 lines (bounded scope; L1 >= L2 signal)
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ❌ | 8 issues |
| Interfaces | ❌ | 8 issues |
| Promises | ❌ | 9 issues |
| Data Models | ❌ | 5 issues |
| APIs | ❌ | 8 issues |

## Contracts Review

### Well-Defined
- ✅ zb_* C-ABI seam entry points — webkit_shim.h:34-45 enumerates all eight functions (zb_run_open, zb_app_run, zb_run_screenshot, zb_version_line, zb_reload, zb_window_new, zb_policy_decide, zb_ipc_dispatch) with fully-typed C signatures
- ✅ dispatch() input/output contract — src/ipc.zig:14 — (allocator, cmd: []const u8, args_json: []const u8) → IpcError![]const u8; IpcError is {UnknownCommand, BadArgs}; returned slice is allocator-owned
- ✅ IPC error-code mapping at the C-ABI boundary — ipc.zig:121-126 — UnknownCommand→1, BadArgs→2; ipc.zig:56 — @errorName is the single source of the JS-side error name string
- ✅ Buffer size limits at the C-ABI boundary — ipc.zig:11-12 — 8 KB scratch, 4 KB result, 128 B err; copyToCStr fails closed on oversize; M1 edge cases explicitly document the 4 KB result-buffer bound
- ✅ decide() input/output contract — nav_policy.zig:24-38 — (app_base, candidate, dtype: DecisionType) → Decision; all three dtype branches defined; POSIX normalization path fully implemented at lines 110-144
- ✅ Exit-code table ownership — errors.zig:22-31 — nine named exits; else→1 fallback; M7 correctly cites Cancelled→130
- ✅ Oracle discipline — Testing Strategy — all oracles are independent: hand-known values, fixed error constants, pillow nonuniform on a known fixture, exit-code table

### Missing or Unclear
- ⚠️ [VERIFY] build.zig:53-63 cited code shows ipc_tests module setup, not configureWebKit(). The plan's claim that lines 53-63 are 'the place backend selection must be introduced' may point at the wrong location; the M4 Green step relies on this reference to locate the unconditional GTK linkage. — Current State Analysis — 'build.zig:53-63'; M4 TDD Cycle Green step
- ⚠️ zb_run_open (webkit_shim.h:34) is part of the seam contract but absent from M8/M9 implementation scope. The Green steps list zb_app_run, zb_window_new, zb_reload, zb_version_line, and zb_run_screenshot — but not zb_run_open. If new backends must satisfy the full seam, omitting it leaves the seam partially unimplemented. If it is GTK-only, the plan should say so explicitly. — M8 Green step; M9 Green step; webkit_shim.h:34
- ⚠️ UnsupportedTarget (M4) and NoBackendLinked (M5) error forms are unspecified. The plan names the literal strings but does not say whether they are produced by @compileError, a build.zig panic, or stderr output from a build step. The build-test script's exit-code + string oracle depends on knowing the emission mechanism. — M4 Edge Cases; M5 TDD Cycle Red/Green
- ⚠️ M2 unit-test red phase cannot be genuinely red. The cited ipc.zig:37 already returns error.UnknownCommand for all unrecognised commands; the test 'try std.testing.expectError(error.UnknownCommand, ...)' passes immediately on the existing code. Only the E2E IPCERR assertion is a real discriminator for M2. — M2 TDD Cycle Red — tests/ipc_test.zig
- ⚠️ M8/M9 foreign error ingestion points are unnamed. HRESULT codes from the WebView2 COM layer and NSError domains from WKWebView will be raw OS-shaped errors. The plan does not identify where in each shim these are mapped to ZB_EXIT_* codes before being returned from zb_app_run / zb_run_screenshot; raw HRESULT / NSError shapes must not propagate past the shim boundary. — M8 Green step — webview2_shim.c; M9 Green step — wkwebview_shim.m

### Critical
- ❌ zb_window_new seam signature contains a GTK-specific type. webkit_shim.h:40 declares ZbWindow *zb_window_new(ZbApp *app, WebKitWebView *view). New backends cannot implement this exact signature — WebView2's view handle is ICoreWebView2 * and WKWebView's is an Objective-C class pointer. The plan simultaneously says 'new backends must match it exactly' and 'the zb_* seam is the stable contract'; those claims are mutually exclusive given the current header. — Impact: webview2_shim.c and wkwebview_shim.m cannot compile against webkit_shim.h as written without including GTK-WebKit headers. Either the seam must change or each backend gets its own header — which invalidates the 'single stable seam' thesis and leaves no contract to test against in M4/M5.
- ❌ RuntimeMissing (M8) and WebViewInitFailed (M9) are named as observable error exits but are absent from errors.zig:22-31. The else => 1 fallback silently coerces both to exit code 1 — the same as Usage. Neither errors.zig nor any other file is named in M8/M9's 'Files touched' list for this addition, and no exit-code values are assigned. — Impact: The E2E exit-code oracle for M8/M9 has no correct expected value to assert; a CI runner missing the WebView2 runtime reports exit 1 indistinguishably from a bad command-line, so automated triage is impossible.
- ❌ ipc.zig uses std.posix.uname() in the os.info branch (ipc.zig:28). The plan claims the Zig core is 'reused verbatim' on Windows (M8 Green). std.posix.uname() is POSIX-only; it will not compile on a Windows target. The verbatim-reuse thesis is internally contradicted by the cited source. — Impact: zig build -Dtarget=x86_64-windows fails to compile ipc.zig; neither a target-OS condition nor an exclusion is specified, so M8 cannot reach a green build step.

### Recommendations
- zb_window_new seam (M8/M9 blocker): Change the second parameter from WebKitWebView * to void * (a type-erased view handle) in webkit_shim.h. Each backend shim casts internally to its own view type; add a per-backend comment naming the expected concrete type.
- RuntimeMissing / WebViewInitFailed exit codes: Add error.RuntimeMissing and error.WebViewInitFailed to the errors.zig switch with distinct exit codes (e.g. 9 and 10). Add errors.zig to the 'Files touched' list in M8 and M9; update E2E oracle tests to assert the new values.
- os.info on Windows (ipc.zig:28): Wrap std.posix.uname() in a comptime builtin.os.tag branch; on Windows return sysname/machine from builtin.cpu.arch and a compile-time release constant. Document this as an explicit divergence from 'verbatim reuse'.
- UnsupportedTarget / NoBackendLinked error forms (M4, M5): Specify the emission mechanism in one sentence per milestone (e.g. @compileError in build.zig so strings appear in zig build stderr); the build-test oracle then asserts substring + nonzero exit.
- zb_run_open scope in M8/M9: Either add zb_run_open to the Green implementation list, or add an explicit note stating it is GTK-only and not part of the cross-OS seam.

## Interfaces Review

### Well-Defined
- ✅ ipc.dispatch() Zig public function — ipc.zig:14 — `pub fn dispatch(allocator, cmd, args_json) IpcError![]const u8`; single error-return discipline throughout; no throws-style mixing
- ✅ zb_ipc_dispatch C-ABI export — ipc.zig:40-72 — full signature with sentinel-terminated params, two out-param pointers, c_int return; clean Zig/C boundary
- ✅ zb_policy_decide C-ABI export — nav_policy.zig:40-44 — `pub export fn zb_policy_decide(base, candidate, dtype: c_int) c_int`; consistent with webkit_shim.h:43
- ✅ nav_policy.decide() Zig public function — nav_policy.zig:24-38 — infallible pure-logic predicate, no error union
- ✅ ipcErrorCode() error-to-int mapping — ipc.zig:121-126 — two variants explicitly mapped, exhaustive over IpcError
- ✅ errors.exitCode() exit-code table for existing errors — errors.zig:22-31 — complete switch over current error tags; else => 1 catch-all
- ✅ E2E protocol line format (tab-separated event stream) — Plan testing strategy names IPC\t<cmd>, IPCERR, BLOCKED\t<candidate>, LOAD_FAIL, WINCOUNT consistently
- ✅ ipc.dispatch() error-return discipline — no mixing — ipc.zig:14-38 — every branch returns IpcError![]const u8; helpers propagate via try

### Missing or Unclear
- ⚠️ build.zig:53-63 citation contradicts cited ground truth: plan claims this range contains configureWebKit() (the unconditional GTK linker call), but the cited ground truth shows the IPC test module setup. The actual location of backend selection is unverified. — Plan 'Key Discoveries' bullet build.zig:53-63; M4 TDD Cycle Green step
- ⚠️ parseEchoArg (M1 Green) — return type and full signature not stated. Unclear whether it returns []const u8 (arena slice), a parsed struct, or something else; callers cannot reason about ownership or error propagation. — M1 TDD Cycle Green, src/ipc.zig snippet
- ⚠️ configure<Backend>() build-step function signatures are not specified. M4 introduces configureWebKit, configureWebView2, and an implied configureWKWebView, but no parameter list or return type is stated. — M4 TDD Cycle Green and Refactor
- ⚠️ NoBackendLinked (M5) and UnsupportedTarget (M4) build-error emission interface is unspecified: @compileError, std.Build.Step.fail, or stderr text from a wrapper? The oracle asserts literal text but the producing mechanism is undefined. — M4 Test Specification Edge Cases; M5 TDD Cycle Red / Success Criteria
- ⚠️ [VERIFY] ZbApp * and ZbWindow * portability: the cited seam forward-declares both types but their struct definitions are not shown. If typedef'd to GTK types in the unexposed header, they are not portable to WebView2/WKWebView. Only WebKitWebView * is confirmed GTK-specific; the opaqueness of ZbApp/ZbWindow needs verification before M8/M9. — webkit_shim.h:34-45 (cited); M8/M9 'implements the zb_* contract'
- ⚠️ zb_run_open omitted from M8/M9 required seam enumeration. The plan lists five functions new backends must implement but zb_run_open (webkit_shim.h:34) is absent. If not needed it should be stated; if needed, the checklist is incomplete. — M8/M9 TDD Cycle Green; webkit_shim.h:34

### Critical
- ❌ zb_window_new(ZbApp *app, WebKitWebView *view) embeds a GTK-specific type (WebKitWebView, a GObject type from webkit2gtk-4.1) in what the plan calls 'the stable contract; new backends must match it exactly.' It does not exist on Windows (WebView2) or macOS (WKWebView). Neither a seam change nor per-backend headers is specified. — Impact: M8 (webview2_shim.c) and M9 (wkwebview_shim.m) cannot satisfy the cited seam without a prior unplanned seam-breaking change; any silent workaround diverges from 'match exactly' and makes the cross-OS reuse claim unverifiable.
- ❌ RuntimeMissing (M8) and WebViewInitFailed (M9) exit paths have no exit-code values assigned and are absent from errors.zig:22-31. The else => 1 catch-all silently maps both to Usage (exit 1); M8/M9 oracles assert these exits with no stated code, so the harness has nothing to assert against. — Impact: Both failure modes alias to exit 1, indistinguishable from a bad CLI invocation; E2E oracles cannot be written and the plan's own 'independent oracle' discipline is violated.

### Recommendations
- zb_window_new seam (M4/M8/M9): Before implementing M4's backend selection table, replace WebKitWebView *view with void *native_view in the seam declaration and update the GTK shim to cast internally; add a per-backend comment. One-line header change, no caller change in main.zig.
- errors.zig — RuntimeMissing and WebViewInitFailed (M8/M9): Add explicit branches (e.g. error.RuntimeMissing => 9, error.WebViewInitFailed => 10) before M8/M9 and state the codes in the M8/M9 test specification.
- parseEchoArg signature (M1): Add a one-line signature to the M1 Green block (e.g. fn parseEchoArg(allocator, args_json) IpcError![]const u8) to keep the IpcError discipline explicit.
- build.zig line reference (M4/M5): Correct the 'Key Discoveries' bullet to the actual configureWebKit() line numbers per a fresh grep; the current reference points to IPC test setup.
- NoBackendLinked / UnsupportedTarget emission (M4/M5): State the exact emission mechanism (e.g. @compileError surfaced as a build stderr line) so the build-test oracle has a concrete string and mechanism.
- zb_run_open in M8/M9 seam checklist: Either explicitly list it in M8/M9's Green requirements, or note it is not required for cross-OS backends.

## Promises Review

### Well-Defined
- ✅ echo round-trip identity: for any UTF-8 string s within the 4 KB result buffer, dispatch('echo', {msg:s}) == s — M1 property-test spec; buffer bound confirmed in ipc.zig:11; copyToCStr fail-closed at ipc.zig:64-68
- ✅ copyToCStr fails closed on oversized result: oversized echo payload → BadArgs, not silent truncation — M1 edge case; ipc.zig:64-68
- ✅ UnknownCommand→error code 1, BadArgs→error code 2 via ipcErrorCode — M2; ipc.zig:121-126
- ✅ POSIX ..-traversal normalization: any candidate that normalizes outside app_base is decided ignore — M3; nav_policy.zig:110-144 and containsPath at 85-89
- ✅ SIGINT → exit code 130 (error.Cancelled) from errors.zig — M7; errors.zig:30
- ✅ Threadlocal IPC buffers: 8 KB scratch, 4 KB result, 128 B err — shared-nothing between calls on the same thread — M1/M2; ipc.zig:11-12
- ✅ No-backend build hard-fails: nonzero exit with NoBackendLinked text, no binary emitted — M5 test specification and success criteria
- ✅ file:// host=localhost accepted; non-file scheme → ignore — M3 edge cases; nav_policy.zig:74-78
- ✅ Milestone ordering guarantee: M1→M2→M3→M4→M5→M6→M7→M8→M9 — Order section

### Missing or Unclear
- ⚠️ No per-error-category retryability declared for any error the plan emits. BadArgs, UnknownCommand, Timeout, Cancelled, LoadFailed, RuntimeMissing, WebViewInitFailed all lack a retryable: yes/no statement; the JS rejection handler and CI harness have no guidance. — M1/M2, M6, M7, M8, M9
- ⚠️ RuntimeMissing (M8) and WebViewInitFailed (M9) are new error categories with no entry in errors.zig:22-31; the else=>1 fallback would silently misreport both as Usage errors. The plan does not declare their exit codes or how the E2E oracle should assert them. — M8 edge case; M9 edge case; errors.zig:22-31
- ⚠️ [VERIFY] build.zig:53-63 is cited as the location of the unconditional configureWebKit() call, but the cited ground truth shows IPC test module setup (ipc_tests_module / run_ipc_tests). Developers following the plan will not find configureWebKit there. — M4 TDD Green step; M5 refactor step; Current State Analysis
- ⚠️ M7 promises the process exits 130 'within a bounded time' after SIGINT during a load, but the bound is never quantified. The E2E test has no numeric timeout to assert against. — M7 test specification and success criteria
- ⚠️ Race condition in M6 unaddressed: if a page-load completion event and the per-backend timeout fire simultaneously, which promise wins? Whether LOAD_FAIL is emitted, which page shows, and final window state are unspecified. — M6 test specification and success criteria
- ⚠️ Thread ownership of the threadlocal IPC buffers for new backends is undeclared. The plan does not document which thread WebView2 / WKWebView script-message callbacks invoke zb_ipc_dispatch on, nor whether the seam requires single-thread dispatch. — M8/M9 Green step; ipc.zig:40-72
- ⚠️ SIGHUP → reload windows[0] is stated as a behavioral promise in M7 edge cases but has no test case, no implementation path, and no success criterion — a dangling guarantee with no verification path. — M7 edge cases
- ⚠️ [VERIFY] The 'stable seam' at webkit_shim.h:40 declares zb_window_new(ZbApp *app, WebKitWebView *view) with a WebKit-specific parameter type; the plan promises 'new backends must match it exactly.' WebView2/WKWebView backends cannot implement a function naming WebKitWebView*; the cross-OS seam completeness guarantee may be unsatisfiable for this entry point. — M8/M9 Green step; Risks/Constraints; webkit_shim.h:40

### Critical
- ❌ The promise 'ipc_core reused verbatim across all backends' is broken by the existing os.info command. ipc.zig:26-35 shows os.info calls std.posix.uname(), POSIX-only, which will not compile for the x86_64-windows target. The plan provides no comptime guard, platform branch, or exclusion. — Impact: The Windows backend (M8) cannot compile ipc_core verbatim; either the verbatim-reuse guarantee is false and must be qualified, or os.info needs a platform branch the plan never specifies, leaving M8 with no valid implementation path and the cross-OS thesis unsupported.

### Recommendations
- os.info cross-OS compatibility (critical fix for M8): Either (a) add a comptime platform check returning error.UnknownCommand for os.info on non-POSIX targets and qualify the verbatim-reuse promise, or (b) replace std.posix.uname() with a thin per-OS shim. Choose before M8 begins and update the cross-OS reuse assertions.
- build.zig backend selection location (M4/M5): Find the actual configureWebKit() call site (not lines 53-63 per cited ground truth) and update the plan's instructions to the correct location.
- Error retryability (M1/M2/M6/M7/M8/M9): Add a one-line annotation per error category in the test spec (e.g. '-- retryable: no; on error, log and halt').
- RuntimeMissing / WebViewInitFailed exit codes (M8/M9): Add explicit errors.zig entries with distinct exit codes (e.g. 9 and 10) before M8/M9 and record them in the success criteria.
- M7 SIGINT bounded-time guarantee: Quantify the wall-clock bound (e.g. 'exit within 3 s of SIGINT') in the M7 test spec and harness; reuse the constant in the kill-timer and teardown path.
- M6 timeout-vs-completion race: Add one explicit promise sentence picking a winner and an E2E variant delivering a successful load at T-epsilon before the timeout.
- SIGHUP→reload guarantee (M7): Either promote it to a tested behavior with an E2E case and success criterion, or explicitly mark it out of scope.

## Data Models Review

### Well-Defined
- ✅ IpcError error set + C-ABI integer codes — ipc.zig:121-126: UnknownCommand→1, BadArgs→2; used consistently in M1/M2
- ✅ Decision enum variants — nav_policy.zig:24-37: .use, .ignore, .open_in_subwindow exhaustively dispatched; M3 oracle uses .ignore correctly
- ✅ DecisionType enum with .response==2 hard assertion — nav_policy.zig:21: comptime assert guards the C-ABI integer mapping; decisionTypeFromInt covers all three variants
- ✅ IPC thread-local buffer sizes (result 4096 B, err 128 B) — ipc.zig:11-12; M1 edge cases reference these bounds explicitly
- ✅ Exit code table for all pre-existing error kinds — errors.zig:22-31: Usage=1, InvalidUri/UnsupportedScheme=2, DisplayUnavailable=3, GtkInitFailed=4, LoadFailed=5, SnapshotFailed=6, WriteFailed=7, Timeout=8, Cancelled=130; M7 consistent
- ✅ os.info response schema ({sysname, release, machine}: all []const u8) — ipc.zig:26-35: fields derived from std.posix.uname(), serialised as JSON object
- ✅ dispatch() function model (allocator + cmd + args_json → IpcError![]const u8) — ipc.zig:14; flat if-chain extension point identified at lines 14-38

### Missing or Unclear
- ⚠️ Echo command args JSON schema has no formal field constraints: only '{msg: string}' in prose. Required/optional status of 'msg', behaviour on empty-string vs. absent key, and effective max byte length are unspecified. M1 edge cases test missing args, not empty-string value. — Behavior M1 test specification and Green step
- ⚠️ Backend selection table schema is informal: M4 names 'target.os → {csource, libs, version_fn}' but never defines key type (OS string vs. full triple), whether architecture is part of the key, the exhaustive valid entries, or whether it is a comptime switch or runtime map. M5's NoBackendLinked guard depends on exhaustiveness. — M4 TDD Cycle (Refactor), M5 specification
- ⚠️ New-backend recovery tracking structs (WebView2/WKWebView) are never named or schematized. The GTK ZbShot struct fields are visible in cited code, but M8/M9 provide no field inventory for the equivalent tracking structs, leaving implementers without a schema for the shared recovery shape from M6. — M6 Refactor, M8 Green step, M9 Green step

### Critical
- ❌ Exit code table in errors.zig is missing integer assignments for RuntimeMissing (M8) and WebViewInitFailed (M9). Both are named error conditions with explicit 'exit' semantics but neither appears in errors.zig:22-31; else => 1 silently aliases them to Usage. — Impact: E2E exit-code oracles for M8/M9 failure paths are untestable; a Windows binary failing to find the WebView2 runtime exits 1 (same as a bad CLI invocation), making the failure mode invisible to any automated gate.
- ❌ os.info response schema ({sysname, release, machine}) is definitionally POSIX-only: produced by std.posix.uname() (ipc.zig:28), which does not exist on Windows. The plan asserts 'the same OS-agnostic Zig core reused verbatim' including on the Windows M8 target, but provides no Windows-compatible schema. — Impact: The Windows build of ipc.zig fails or the 'verbatim reuse' invariant is silently violated by an unplanned conditional-compile patch; if omitted, the IPC surface is inconsistent across OS targets, breaking any cross-OS E2E test that calls os.info.

### Recommendations
- errors.zig exit code table: Before M8/M9, add explicit integer entries for RuntimeMissing and WebViewInitFailed (e.g. 9 and 10) and state them in the M8/M9 specs.
- os.info cross-OS schema: Document os.info as POSIX-only in ipc.zig and the plan; either exclude it from Windows builds via a comptime branch (and note the surface difference) or define a Windows schema via GetVersionEx/RtlGetVersion and add it to the M8 spec.
- Echo command args JSON schema: Add a one-line schema comment specifying 'msg' is a required string key, empty string is valid, max byte length = 4 KB result buffer minus JSON quoting; cover empty-string-value distinctly in M1 edge cases.
- Backend selection table: Define the mapping as a concrete comptime table keyed on target triple strings with value fields {c_source, link_libs}; state that any triple not in the table triggers the NoBackendLinked build error.

## APIs Review

### Well-Defined
- ✅ zb_ipc_dispatch C-ABI (cmd, args_json, out_result, out_err) → c_int — webkit_shim.h:44-45, ipc.zig:40-72 — signature, buffer sizes, error-code mapping cited verbatim
- ✅ zb_policy_decide C-ABI (base, candidate, dtype) → c_int — webkit_shim.h:43, nav_policy.zig:40-44 — signature and integer enum mapping confirmed
- ✅ IPC error codes: UnknownCommand=1, BadArgs=2 — ipc.zig:121-126 — ipcErrorCode() switch matches M2 spec exactly
- ✅ Existing IPC commands: ping / add / os.info — ipc.zig:14-38 — dispatch() if-chain cited in full
- ✅ Exit code table (Usage=1, InvalidUri=2, LoadFailed=5, Timeout=8, Cancelled=130) — errors.zig:22-31 — M7 exit-130 assertion grounded here
- ✅ nav_policy.decide() traversal containment logic — nav_policy.zig:24-144 — M3 unit test oracle is hand-computable
- ✅ E2E harness invocation: real binary + --e2e-protocol flag → stdout tab-separated lines — main.zig:32-46, plan Testing Strategy section

### Missing or Unclear
- ⚠️ E2E protocol line schema is never formally enumerated. Each type (IPC, IPCERR, BLOCKED, LOAD_FAIL, SUBWIN, WINCOUNT) is mentioned in prose but the exact field sequence, delimiter count, and field semantics are not written down. M8/M9 implementers must independently reproduce the GTK shim's format with no normative reference. — Testing Strategy section; M1–M6 line mentions
- ⚠️ JS Promise rejection value shape is unspecified. M2 says 'rejects with UnknownCommand (code 1)' and the refactor says @errorName is the reply string, implying a bare string — but whether JS receives a string, an Error object, or a structured object is never stated. — M2 Test Specification; M2 Refactor step
- ⚠️ --version output format is specified only for GTK ('WebKitGTK x.y.z, GTK a.b.c'); the analog for WebView2 and WKWebView is undefined, so M4's '--version reports the matching engine' criterion is untestable for M8/M9. — M4 Test Specification; M4 Success Criteria
- ⚠️ echo property-test domain upper bound is imprecisely stated as 'UTF-8 string s within the buffer bound'. The actual constraint is JSON-encoded length + 2 (quotes) + 1 (NUL) ≤ 4096 bytes; the spec does not state this ceiling, so a generator can't be written without reading source. — M1 Test Specification — Property paragraph
- ⚠️ [VERIFY] Plan attributes configureWebKit() unconditional GTK/WebKit linking to build.zig:53-63, but the cited code there is IPC test module setup. If the line numbers are wrong, M4/M5 implementers will modify the wrong location. — Key Discoveries — build.zig:53-63 bullet; M4 Green step

### Critical
- ❌ The zb_window_new seam signature (webkit_shim.h:40) contains a WebKitWebView* parameter — a libwebkit2gtk-specific type unavailable on Windows or macOS — yet the plan declares this seam 'the stable contract any backend must satisfy' and requires backends to 'match it exactly'. webview2_shim.c cannot include WebKitWebView* without GTK headers; wkwebview_shim.m has WKWebView*, not WebKitWebView*. — Impact: Both shims cannot satisfy the stated seam; either the seam must change (breaking 'match exactly') or both milestones are blocked at compile time. The plan provides no resolution path.
- ❌ The JS→backend Promise resolution/rejection mechanism is specified only for GTK (webkit_script_message_reply_return_value / _return_error_message). WebView2 (ExecuteScript on the UI thread) and WKWebView (evaluateJavaScript:completionHandler:) use different async patterns; M8/M9 have no normative contract for how the Zig dispatch result travels back to the JS Promise, and the fixture's postMessage has no reply path on either new backend. — Impact: M8/M9 implementers must independently discover WebView2/WKWebView callback patterns; the cross-backend 'zbHost ping→pong' test cannot be written or verified until the implementation already exists — inverting TDD order.
- ❌ New error conditions RuntimeMissing (M8) and WebViewInitFailed (M9) are not present in errors.zig's exitCode() switch (errors.zig:22-31). The else => 1 catch-all means both silently map to exit 1 (Usage); the M8/M9 E2E tests assert 'RuntimeMissing exit' / 'WebViewInitFailed exit' with no distinct code to assert against, so any exit satisfies the test. — Impact: M8/M9 error paths are untestable at the exit-code level; a backend that crashes with exit 1 for any unrelated reason passes the same assertion as one that correctly detects a missing runtime. The discriminating signal the plan promises does not exist.

### Recommendations
- zb_window_new seam (webkit_shim.h:40): Replace WebKitWebView* with void* (or typedef ZbNativeView void*) before M8/M9; each shim casts internally with a one-line comment. Minimal change that makes 'match the seam exactly' true across all three backends.
- JS→backend reply mechanism (M8, M9): Add a 'Reply channel spec' naming exact APIs — WebView2: PostWebMessageAsString from the CoreWebView2 controller on the UI thread; WKWebView: WKScriptMessageHandlerWithReply reply(withResult:errorMessage:) (macOS 14+) or evaluateJavaScript: fallback.
- RuntimeMissing / WebViewInitFailed exit codes (M8, M9): Add both to errors.zig's exitCode() with distinct non-colliding codes (e.g. 9 and 10) before implementation; update E2E assertions to check the specific numeric code.
- E2E stdout protocol (all milestones, critical for M8/M9): Add a single reference table (or checked-in PROTOCOL.md): one row per line type — prefix, tab-delimited field names, example line. Minimal rows now: IPC, IPCERR, BLOCKED, LOAD_FAIL.
- JS zbHost API cross-backend compatibility (fixture HTML, M8): State explicitly whether the shared fixture uses window.webkit.messageHandlers.zbHost (WebKit-specific) or a thin JS bridge that normalizes postMessage across backends; if per-backend fixtures are acceptable, say so.

## Scaffolding & Realness (Hostile Check)

This plan's tests would go green on multiple milestones without the real functionality existing. The following are realness violations:

- ❌ **M8/M9 error-path oracles pass for any exit code (FAKED/ILLUSORY ORACLE).** RuntimeMissing and WebViewInitFailed are not in errors.zig:22-31, so the else => 1 fallback maps both to exit 1. The M8/M9 E2E tests assert "RuntimeMissing exit" / "WebViewInitFailed exit" with no distinct code — "any exit would satisfy the test, making the error-path coverage illusory." A backend that crashes for an unrelated reason, or never implements runtime detection at all, passes the same assertion as a correct one. The discriminating signal the plan promises does not exist. — Location: M8 Edge Cases; M9 Edge Cases; errors.zig:22-31.
- ❌ **M2 unit-test Red phase is green before any work (SELF-PASSING TEST / TESTS-GREEN-AS-DONE).** ipc.zig:37 already returns error.UnknownCommand for all unrecognised commands, so `try std.testing.expectError(error.UnknownCommand, ...)` passes immediately on existing code. The TDD "Red" step is not red; the unit milestone can be reported done with zero new functionality. Only the E2E IPCERR assertion is a real discriminator. — Location: M2 TDD Cycle Red — tests/ipc_test.zig.
- ❌ **M8/M9 cross-backend ping→pong test cannot exist before the implementation (INVERTED TDD / NO INDEPENDENT CONTRACT).** The JS→backend reply mechanism is specified only for GTK; WebView2/WKWebView have no normative reply-channel contract, so the "zbHost ping→pong" success test "cannot be written or verified until the implementation already exists." A milestone whose verifying test is authored after the code is self-referential and cannot serve as an independent oracle. — Location: M8 Green step; M9 Green step; M2 Test Specification.

Note: M8/M9 also rest on a seam (zb_window_new with WebKitWebView*) and a "verbatim" core (std.posix.uname on Windows) that cannot compile on the target platforms — these are tracked as Critical blockers above and compound the realness risk: a non-GTK backend cannot produce any human-observable artifact (page/pong/pixels) on its target until those are resolved.

## Critical Issues (Must Address Before Implementation)

Confirmed critical findings across all domains plus all Scaffolding & Realness entries (deduplicated by theme; [VERIFY] items excluded):

1. **zb_window_new seam embeds a GTK-only type (WebKitWebView*) while claiming to be the stable cross-backend contract** — webview2_shim.c and wkwebview_shim.m cannot compile against it; no seam-change or per-backend-header path is planned. (Contracts, Interfaces, APIs)
2. **RuntimeMissing (M8) and WebViewInitFailed (M9) are absent from errors.zig's exitCode() switch** — else => 1 aliases both to Usage; no exit codes assigned, errors.zig not in M8/M9 'Files touched', and E2E exit-code oracles have nothing distinct to assert. (Contracts, Interfaces, Data Models, APIs)
3. **os.info / ipc_core cannot be reused verbatim on Windows** — ipc.zig:28 calls std.posix.uname() (POSIX-only); zig build -Dtarget=x86_64-windows fails to compile, contradicting the "verbatim reuse" thesis with no platform branch or exclusion specified. (Contracts, Promises, Data Models)
4. **JS→backend Promise reply mechanism is GTK-only** — WebView2 and WKWebView async-eval/reply patterns are unspecified, so the cross-backend reply contract does not exist for M8/M9. (APIs)
5. **M8/M9 error-path oracles pass for any exit code** — illusory error-path coverage (Scaffolding & Realness).
6. **M2 Red phase is green before any new work** — self-passing unit test (Scaffolding & Realness).
7. **M8/M9 ping→pong verification test cannot be authored before its implementation** — inverted TDD / no independent oracle (Scaffolding & Realness).

## Approval Status

- [ ] Ready for Implementation — no critical issues AND Scaffolding & Realness is clean
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues OR any Scaffolding & Realness violation must be resolved first

The plan carries multiple confirmed critical issues and three Scaffolding & Realness violations. Per the verdict rule, any Scaffolding & Realness entry forces Major Revision. The cross-OS milestones (M8/M9) in particular cannot compile against the cited seam, cannot reuse the core verbatim, lack distinct error-exit codes, lack a JS reply contract, and have verification tests that would go green without the real functionality. Resolve all seven critical issues before implementation begins.


## Beads Tracking

Epic: **[Plan Review Epic] 2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4 — 11 critical, 27 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **11** critical, **27** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | critical | [Plan Review §contracts] zb_window_new seam signature contains a GTK-specific type. … <!-- fp:556894f7 --> | _(not minted)_ |
| contracts | critical | [Plan Review §contracts] RuntimeMissing (M8) and WebViewInitFailed (M9) are named as… <!-- fp:5f086ec5 --> | _(not minted)_ |
| contracts | critical | [Plan Review §contracts] ipc.zig uses std.posix.uname() in the os.info branch (ipc.z… <!-- fp:69abea30 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] [VERIFY] build.zig:53-63 cited code shows ipc_tests module … <!-- fp:19ad5132 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] zb_run_open (webkit_shim.h:34) is part of the seam contract… <!-- fp:df206056 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] UnsupportedTarget (M4) and NoBackendLinked (M5) error forms… <!-- fp:a38706c2 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] M2 unit-test red phase cannot be genuinely red. The cited i… <!-- fp:f7c0536f --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] M8/M9 foreign error ingestion points are unnamed. HRESULT c… <!-- fp:a7b2e9a3 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] `zb_window_new(ZbApp *app, WebKitWebView *view)` embeds a G… <!-- fp:022f5b87 --> | _(not minted)_ |
| interfaces | critical | [Plan Review §interfaces] `RuntimeMissing` (M8) and `WebViewInitFailed` (M9) exit pat… <!-- fp:8e357f69 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] build.zig:53-63 citation contradicts cited ground truth: pl… <!-- fp:c41ea588 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] `parseEchoArg` (M1 Green) — return type and full signature … <!-- fp:bdb804bc --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] `configure<Backend>()` build-step function signatures are n… <!-- fp:8ad8ecb2 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] `NoBackendLinked` (M5) and `UnsupportedTarget` (M4) build-e… <!-- fp:b6c0c2b1 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] `ZbApp *` and `ZbWindow *` portability: the cited … <!-- fp:e8804808 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] `zb_run_open` omitted from M8/M9 required seam enumeration.… <!-- fp:95b208bf --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] The behavioral promise 'ipc_core reused verbatim across all… <!-- fp:bcb7a11d --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] No per-error-category retryability declared for any error t… <!-- fp:f4f80220 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] RuntimeMissing (M8) and WebViewInitFailed (M9) are new erro… <!-- fp:f53a4264 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] [VERIFY] build.zig:53-63 is cited in the plan as the locati… <!-- fp:2464ef1a --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] M7 promises the process exits 130 'within a bounded time' a… <!-- fp:6c26a260 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Race condition in M6 unaddressed: if a page-load completion… <!-- fp:da62eead --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Thread ownership of the threadlocal IPC buffers (dispatch_s… <!-- fp:cd1b3218 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] SIGHUP → reload windows[0] is stated as a behavioral promis… <!-- fp:e7b309ab --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] [VERIFY] The 'stable seam' cited at webkit_shim.h:40 declar… <!-- fp:0ec08a2a --> | _(not minted)_ |
| data_models | critical | [Plan Review §data_models] Exit code table in errors.zig is missing integer assignment… <!-- fp:b9e793f1 --> | _(not minted)_ |
| data_models | critical | [Plan Review §data_models] os.info command response schema ({sysname, release, machine… <!-- fp:1a53e8a7 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Echo command args JSON schema has no formal field constrain… <!-- fp:bc077df5 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] Backend selection table schema is informal: M4 refactor nam… <!-- fp:1b203d2f --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] New-backend recovery tracking structs (WebView2/WKWebView) … <!-- fp:3305da65 --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] The zb_window_new seam signature (cited webkit_shim.h:40) c… <!-- fp:cdea8ffd --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] The JS→backend Promise resolution/rejection mechanism is sp… <!-- fp:0c1e2c90 --> | _(not minted)_ |
| apis | critical | [Plan Review §apis] New error conditions RuntimeMissing (M8) and WebViewInitFai… <!-- fp:85c431c6 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] E2E protocol line schema is never formally enumerated. Each… <!-- fp:fc9e7d5d --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] JS Promise rejection value shape is unspecified. M2 says 'r… <!-- fp:357936f3 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] --version output format is specified only for the GTK backe… <!-- fp:78d9e99e --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] echo property-test domain upper bound is imprecisely stated… <!-- fp:de6ce4bf --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] [VERIFY] Plan attributes configureWebKit() unconditional GT… <!-- fp:ef218044 --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.