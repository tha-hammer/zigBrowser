# Plan Review Report: M8 — Windows WebView2 Backend — TDD Implementation Plan

> **Plan tier: L1** (confidence: high) — 3 L1 keyword(s) + plan size 139 lines (bounded scope; L1 >= L2 signal)
>
> Findings below are scoped to this tier's lens. L1 plans receive correctness-and-idempotency findings; L2 plans add typed-interface and schema-compat findings; L3 plans add UnifiedError/retry/observability. Above-tier prescriptions were forbidden in each phase prompt.

## Review Summary

| Category | Status | Issues Found |
|----------|--------|--------------|
| Contracts | ⚠️ | 6 issues |
| Interfaces | ⚠️ | 4 issues |
| Promises | ❌ | 9 issues |
| Data Models | ⚠️ | 4 issues |
| APIs | ⚠️ | 6 issues |

## Contracts Review

### Well-Defined
- ✅ zb_ipc_dispatch C seam signature and ownership — webkit_shim.h:38-41 declares `int zb_ipc_dispatch(cmd, args_json, **out_result, **out_err)` as a Zig-owned hard-linked export; M4 names it as the dispatch target.
- ✅ Exit codes RuntimeMissing=9 / WebViewInitFailed=10 — errors.zig:11-12 confirms both codes exist and are OS-agnostic; M6 cites them as pre-window failure exits.
- ✅ JS→native IPC envelope format {id, cmd, args} — zbhost.js:93-102 shows the exact JSON sent via webview.postMessage; M4/M5 parse this on the native side.
- ✅ Build backend resolution linux→gtk / windows→webview2 / else→panic — build.zig:95-99 shows the existing resolveBackend switch; M2 specifies the exact `.windows => .webview2_backend` addition and unchanged `else => panic`.
- ✅ HW gate mechanism for E2E tests — m8_reply_channel_test.py:26-30 confirms `platform.system()=='Windows'` AND `ZB_ENABLE_M8_E2E=1` are both required; honest deferral with a real test body.
- ✅ Provenance gate (dumpbin/nm shows zb_ipc_dispatch DEFINED in windows exe) — named as the cross-OS-reuse discriminator, complemented by os.info returning real Windows values.

### Missing or Unclear
- ⚠️ LOAD_FAIL `<domain>` column mapping from WebView2 error statuses is unspecified — M6 green state + LOAD_FAIL row format. WebView2 uses COREWEBVIEW2_WEB_ERROR_STATUS; the implementer must guess against the PROTOCOL.md oracle.
- ⚠️ RuntimeMissing vs WebViewInitFailed discrimination condition is not specified — M6 green state; errors.zig:11-12. Both fire before any window opens, but the triggering condition for each is unnamed.
- ⚠️ webkit_shim.h declares six shim functions; plan only covers zb_app_run (M3) and zb_version_line (M2) — webkit_shim.h:30-36; M2/M3 file lists. The other four are absent; even a stub requirement must be stated to avoid undefined-symbol link failures.
- ⚠️ os.info JSON key names ({sysname, release, machine}) not declared platform-invariant — M1 green state; ipc.zig:36-38. If the windows branch uses different key names, M4 protocol rows pass while downstream consumers silently break.
- ⚠️ [VERIFY] installWebViewListener receive-side reply shape is unspecified in cited code — M5 green state + zbhost.js:88. Cited zbhost.js:82-108 shows only the send path; if the message-event handler expects a different shape than the native PostWebMessageAsString output, M5 silently fails.
- ⚠️ [VERIFY] out_err content → JSON {id, error: <value>} mapping is implicit — M5 green state + ipc.zig:35 (partial citation). If out_err contains a human-readable message rather than the token 'BadArgs', the test oracle fails.

### Critical
- None.

### Recommendations
- PROTOCOL.md: Add a table mapping COREWEBVIEW2_WEB_ERROR_STATUS values to the LOAD_FAIL `<domain>` column string so the backend has an authoritative oracle.
- webview2_shim plan (M2/M3 file lists): Enumerate which webkit_shim.h functions the backend must implement per milestone, even as link-safe stubs, to prevent silent linker failures.
- M6 errors spec: Add one line stating which COM/WebView2 failure mode triggers RuntimeMissing vs WebViewInitFailed so the exit-code oracle is unambiguous.
- zbhost.js / plan M5: Cite the line range for installWebViewListener and confirm it expects exactly {id, result} / {id, error}.

## Interfaces Review

### Well-Defined
- ✅ zb_ipc_dispatch C seam signature — webkit_shim.h:40-41 complete; reused unchanged for WebView2; no new declaration required.
- ✅ sendViaWebView2 JS→native reply-channel protocol — zbhost.js:82-108; JS side already written and frozen; plan only adds the native responder.
- ✅ errors.zig exit codes RuntimeMissing(9) / WebViewInitFailed(10) — errors.zig:11-12 existing OS-agnostic variants reused without modification.
- ✅ C seam top-level signatures (zb_app_run, zb_run_screenshot, zb_version_line) — webkit_shim.h:30-33 complete; WebView2 shim must implement them.
- ✅ Backend enum extension point and resolveBackend switch — build.zig:2-4, 95-100; clean extension, no callers change.
- ✅ M8 E2E HW-gate and skip discipline — m8_reply_channel_test.py:22-28; off-Windows skip is explicit and documented, not silent pass.

### Missing or Unclear
- ⚠️ os.info Windows API call mechanism is plan-internally contradictory — M1 Green ('via the shim') vs Files-touched (ipc.zig + ipc_test.zig only); webview2_shim is not created until M2 and no C helper signature is declared. Either the 'via the shim' text is a false interface promise or M1's file list is incomplete.
- ⚠️ webview2_shim source file extension never resolved — M2/M3/M4 Files-touched write 'src/webview2_shim.c[pp]'. WebView2 COM interfaces cannot be used from C; a mid-slice .c→.cpp rename is a silent breaking change in the build graph.
- ⚠️ [VERIFY] zb_run_open, zb_reload, zb_window_new, zb_run_screenshot declared in webkit_shim.h:30-36 but absent from all backend milestone task lists — vs Milestones 2–6. If webkit.zig force-links wrappers via main.zig comptime, the windows binary contains undefined symbols.
- ⚠️ [VERIFY] ZbApp/ZbWindow opaque type definitions absent from cited webkit_shim.h fragment — webkit_shim.h:35-36; M2 'src/webview2_shim.h or reuse webkit_shim.h'. If they live in a GTK-specific header, the WebView2 backend fails to compile; the plan does not decide forward-decl vs separate header.

### Critical
- None.

### Recommendations
- Milestone 1: Pick one os.info mechanism explicitly — use std.os.windows.ntdll.RtlGetVersion directly in ipc.zig (drop 'via the shim') OR declare a C helper and add its stub to M1's file list.
- Milestone 2: Commit to webview2_shim.cpp (not .c) in the file list and the addCSourceFile call.
- Milestones 2–6: Add an explicit M2 note listing every webkit_shim.h symbol the backend must implement or stub.
- Milestone 2: Decide ZbApp/ZbWindow type handling before the first .cpp line; document in PROTOCOL.md or a build comment.

## Promises Review

### Well-Defined
- ✅ os.info Linux regression guard — M1 'Property': byte-identical Linux output preserved across the comptime branch addition; Final Gate keeps Linux test green.
- ✅ Provenance gate — Final Visible-Output Gate; oracle is the binary symbol table (dumpbin/nm), independent of the test harness.
- ✅ Real-render oracle — M3 Testing Strategy: non-uniform PNG pixel check + --print-title == fixture title parsed from source; two independent checks, neither produced by the render path.
- ✅ id-correlation ordering property — M5 'Property' note: each reply resolves exactly the promise whose id it carries; unknown ids dropped.
- ✅ Exit codes 9/10 reused, not invented — errors.zig:11-12 confirms both enum members; M6 references them.
- ✅ 4-field LOAD_FAIL row format with independent oracle — M6 'Oracle': PROTOCOL.md 4-field contract + errors.zig exitCode table.
- ✅ HW gate honest deferral — m8_reply_channel_test.py:22-30; plan acknowledges the prior vacuous off-Windows SKIP and names M5 as the milestone that makes it real.
- ✅ Exactly-one-backend invariant — build.zig:98 panic confirmed; M2 extends to windows arm preserving else-panic.

### Missing or Unclear
- ⚠️ out_result / out_err pointer lifetime across the C/Zig ABI boundary in the WebView2 shim is unspecified — M4/M5 Green; webkit_shim.h:40-41. The C++ shim must copy before returning from AddWebMessageReceived; handoff timing/ownership never stated.
- ⚠️ Win32 navigation timeout mechanism unspecified — M6 Green 'timeout reap mirroring GTK'. Win32 SetTimer/WM_TIMER differs meaningfully from GLib timeout_add; the code-8 promise depends on a named source the plan never identifies.
- ⚠️ PostWebMessageAsString threading model not stated as the basis for id-correlation — M5 'Refactor' + 'Property'. Rests implicitly on WebView2 UI-thread serial dispatch; a future async path would silently break the invariant.
- ⚠️ Win32 window + CoreWebView2 controller cleanup guarantee absent — M3 'Refactor' 'clean window lifecycle' names no COM Release ordering, DestroyWindow call site, or RAII boundary.
- ⚠️ M1 unit test is a shape assertion on a Linux host — M1 Red/Green. Cross-compiling to windows verifies field existence but cannot execute RtlGetVersion; the test passes even if the windows branch returns comptime-constant strings. The plan does not warn that M1 green is shape-only, not value-correct.
- ⚠️ IPC scratch buffer bound for the WebView2 shim is unquantified — M4 'Refactor' 'bounded scratch like the GTK path' states no actual bound.
- ⚠️ [VERIFY] zb_run_open (webkit_shim.h:30) has no implementation slot in M2-M6 — M2 Green enumerates zb_app_run/zb_run_screenshot/zb_version_line but omits zb_run_open. If main.zig dispatches to it on windows, the linker fails at a milestone marked green.

### Critical
- ❌ CoreWebView2 environment creation is an async COM callback and Win32 message-pump integration is never stated as a behavioral requirement — M3 Green ('create the CoreWebView2 environment+controller … Navigate'). CreateCoreWebView2EnvironmentWithOptions fires its completion callback only while the thread's message queue is pumped. **Impact:** without a GetMessage/DispatchMessage loop during init, the callback never fires, zb_app_run blocks indefinitely, M3's screenshot artifact is permanently unreachable, and M4–M6 are entirely blocked — an indefinite stall with no timeout or error path.
- ❌ COM apartment initialization (CoInitializeEx) is not stated as a required precondition for zb_app_run on the windows path — M3 Green / M6 Green. WebView2 requires COINIT_APARTMENTTHREADED before any COM call; omitting it returns a COM error indistinguishable from an absent runtime. **Impact:** M3 always exits through the M6 failure path even when the runtime is present; the M6 RuntimeMissing(9)-vs-WebViewInitFailed(10) discriminating oracle becomes ambiguous, and the 'real window' promise breaks with no TDD-visible signal.

### Recommendations
- M3 async COM init: Add a Property note requiring a GetMessage/DispatchMessage loop on the UI thread while awaiting the env-creation callback, so the red step can test hang-vs-not-hang.
- M3 (or M2) COM apartment: Add to Green that zb_app_run calls CoInitializeEx(NULL, COINIT_APARTMENTTHREADED) first and CoUninitialize on all exit paths; place it on the TDD checklist.
- M4 ownership: State that the C++ shim copies out_result/out_err into the reply buffer before the handler returns; Zig retains ownership and may free immediately after dispatch returns.
- M6 timeout: Name the Win32 mechanism (SetTimer→WM_TIMER reaped by the loop → Timeout(8)).
- M1 scope: Note that the windows-target cross-compile verifies shape/compile only; real values are validated in-guest in M4 against cmd /c ver.

## Data Models Review

### Well-Defined
- ✅ C shim function signatures (zb_app_run, zb_run_screenshot, zb_version_line, zb_window_new, zb_reload, zb_policy_decide, zb_ipc_dispatch) — webkit_shim.h:30-41 all typed, no ambiguity.
- ✅ IPC request envelope {id, cmd, args} — zbhost.js:82-108; id integer (nextRequestId++), cmd string, args passed through.
- ✅ Error enum variants RuntimeMissing/WebViewInitFailed with codes 9/10 — errors.zig:11-12 confirmed; M6 cites them.
- ✅ LOAD_FAIL 4-field tab-delimited record — M6 names all four fields; PROTOCOL.md as independent oracle.
- ✅ Backend enum + resolveBackend dispatch site — build.zig:2-4, 95-99; M2 adds webview2_backend at the same site.
- ✅ IPC reply error field as string code on failure — M5 states {id, error:'BadArgs'}; zbhost.js pending-map resolves/rejects on this shape.

### Missing or Unclear
- ⚠️ os.info Windows field value format for sysname/release/machine is not specified — M1 (unit oracle) and M4 (E2E oracle). Is release '10.0.19041', '10.0 Build 19041', or a raw DWORD tuple? Neither oracle can be written without this contract.
- ⚠️ IPC reply result field type is unspecified per command — M4/M5 PostWebMessageAsString contract. ping→'pong', echo→mirror, os.info→object; serialization format leaves the native side without a schema to match zbhost.js's resolution.
- ⚠️ [VERIFY] machine field presence in os.info struct — ipc.zig:35-38 (truncated); M1 property. If machine is absent from the Linux struct, adding it for Windows breaks the 'Linux unchanged' property; if present, the Windows source is unspecified.
- ⚠️ [VERIFY] LoadFailed exit code 5 not in the cited errors.zig:11-12 snippet — M6 description. Only SnapshotFailed, WriteFailed, Timeout, RuntimeMissing, WebViewInitFailed, Cancelled are shown; if the variant is missing, M6 cannot assert the exit code.

### Critical
- None.

### Recommendations
- os.info Windows struct: Add a one-line table fixing concrete source and string format per field (e.g. sysname='Windows', release=major.minor.build from RtlGetVersion, machine=@tagName(builtin.cpu.arch)).
- IPC reply result schema: Add a per-command reply-shape table so M4 serialization and the test assertion share one definition.
- LoadFailed exit code: Confirm whether LoadFailed is already in errors.zig; if absent, M2/M6 must add it with an explicit value; if present, cite the line.

## APIs Review

### Well-Defined
- ✅ C seam function signatures — webkit_shim.h:30-41; header reused as-is for the WebView2 shim.
- ✅ IPC request envelope schema {id, cmd, args} via chrome.webview.postMessage — zbhost.js:82-108; envelope + pending-id map fully shown.
- ✅ Exit code assignments LoadFailed=5, Timeout=8, RuntimeMissing=9, WebViewInitFailed=10 — errors.zig:11-12 + M6 body agree.
- ✅ E2E hardware double-gate ZB_ENABLE_M8_E2E=1 + platform.system()=='Windows' — m8_reply_channel_test.py:22-28; SKIP logic fully shown.
- ✅ LOAD_FAIL stdout protocol row (4 tab-separated fields) — M6 Green quotes the shape; cross-referenced to PROTOCOL.md.

### Missing or Unclear
- ⚠️ zb_version_line Windows output format unspecified — M2 Green. 'WebView2 + runtime version line' with no exact string shape; E2E tests have no documented format to parse/assert against.
- ⚠️ os.info Windows field value mapping not documented — M1 Green; Observable Behavior 4. RtlGetVersion/GetVersionEx referenced but no commitment to 'Windows' vs 'Windows_NT', full build vs dotted version, 'AMD64' vs 'x86_64'; the 'cmd /c ver' oracle does not fully constrain the three fields.
- ⚠️ zb_ipc_dispatch int return value semantics not documented — M4 Green; webkit_shim.h:40-41. Whether routing to result vs error keys off the int return or out_err non-null is undefined; implementer must reverse-engineer the GTK backend.
- ⚠️ [VERIFY] zb_run_screenshot Windows implementation not in any milestone file list — M2–3 file lists; main.zig:61. main.zig calls webkit.runScreenshot which links zb_run_screenshot; if unconditional, the Windows build fails to link; plan uses PowerShell for the screenshot oracle without clarifying replace-vs-supplement.
- ⚠️ [VERIFY] zb_reload, zb_window_new, zb_run_open Windows implementation not addressed — M2 file list; webkit_shim.h:30-36. If webkit.zig references any unconditionally, the Windows link fails silently.
- ⚠️ [VERIFY] IPC reply JSON field names not confirmed against the JS listener — M5 Green; zbhost.js:88 (referenced, not cited). Plan specifies keys 'result'/'error', but installWebViewListener is the actual parser; if it expects different names all promises silently hang with no protocol-row evidence.

### Critical
- None.

### Recommendations
- zb_version_line Windows format: Fix the exact format string in PROTOCOL.md or M2 so the E2E assert and C++ implementation target the same shape.
- os.info Windows field mapping: Document the three concrete field values in M1; this serves as both API contract and E2E oracle spec.
- zb_ipc_dispatch routing convention: Add one sentence to M4 specifying the result-vs-error routing rule and how out_err maps to the error token.
- Unimplemented C seam symbols: Add a Windows shim symbol checklist to M2 marking each export IMPLEMENT / STUB-NOOP / EXCLUDED-BY-BUILD and confirming the linker won't pull unreferenced symbols.

## Scaffolding & Realness (Hostile Check)

- ❌ M1 green is satisfiable by hardcoded comptime-constant strings — M1 Red/Green ('unit asserting os.info returns a {sysname,release,machine}-shaped result'), cross-compiled on a Linux host. The unit test verifies field shape only and cannot execute RtlGetVersion; it passes even if the windows branch returns faked constants instead of real OS values. This is a SHAPE-ASSERTION milestone whose oracle does not prove the real functionality exists. The plan's only real value-correctness oracle is the in-guest M4 check against `cmd /c ver` — which is HW-gated and skips off-Windows — and the plan does not mark M1 as shape-only. As written, M1 can be reported "green/done" with fabricated values and no human-observable artifact.

Note: the broader plan is largely honest — it carries genuine independent oracles (dumpbin/nm provenance, non-uniform PNG pixel check, in-guest os.info vs cmd /c ver, an explicitly-acknowledged HW gate that replaces a prior vacuous SKIP). The realness defect is localized to the M1 milestone's value-blind oracle, which must be flagged so "M1 green" is not treated as proof the Windows os.info computation exists.

## Critical Issues (Must Address Before Implementation)

1. ❌ **CoreWebView2 environment creation is async and the Win32 message-pump requirement is never stated** (Promises, M3 Green) — without a GetMessage/DispatchMessage loop during init, zb_app_run blocks indefinitely, M3's screenshot is unreachable, and M4–M6 are blocked.
2. ❌ **CoInitializeEx(COINIT_APARTMENTTHREADED) is not stated as a precondition for zb_app_run on windows** (Promises, M3/M6 Green) — its omission makes a present runtime look absent, collapsing M6's RuntimeMissing-vs-WebViewInitFailed discriminating oracle.
3. ❌ **M1 green is satisfiable by hardcoded constants** (Scaffolding & Realness) — the M1 oracle is shape-only on a Linux host; mark M1 as compile/shape-only and bind real value-correctness to the M4 in-guest oracle so "M1 done" is not mistaken for working Windows os.info.

## Approval Status

- [ ] Ready for Implementation — no critical issues AND Scaffolding & Realness is clean
- [ ] Needs Minor Revision — address warnings before proceeding
- [x] Needs Major Revision — critical issues OR any Scaffolding & Realness violation must be resolved first


## Beads Tracking

Epic: **[Plan Review Epic] 2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8 — 2 critical, 27 warnings** — _(not minted; pass `--mint-beads` to create)_
Issues: **2** critical, **27** warning.

| Phase | Severity | Issue | Bead ID |
|---|---|---|---|
| contracts | warning | [Plan Review §contracts] [VERIFY] installWebViewListener receive-side reply shape is… <!-- fp:1b9a6eb3 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] [VERIFY] out_err content → JSON {id, error: <value>} mappin… <!-- fp:3f721717 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] LOAD_FAIL <domain> column mapping from WebView2 error statu… <!-- fp:58bb6b42 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] RuntimeMissing vs WebViewInitFailed discrimination conditio… <!-- fp:554894db --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] webkit_shim.h declares six shim functions (zb_run_open, zb_… <!-- fp:f7ca0874 --> | _(not minted)_ |
| contracts | warning | [Plan Review §contracts] os.info JSON key names ({sysname, release, machine}) are no… <!-- fp:9c4f28ac --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] os.info Windows API call mechanism is plan-internally contr… <!-- fp:07092ab1 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] webview2_shim source file extension is never resolved: plan… <!-- fp:6130dccb --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] zb_run_open, zb_reload, zb_window_new, and zb_run_… <!-- fp:ab025886 --> | _(not minted)_ |
| interfaces | warning | [Plan Review §interfaces] [VERIFY] ZbApp and ZbWindow opaque type definitions are abs… <!-- fp:4ca015dc --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] CoreWebView2 environment creation is asynchronous COM callb… <!-- fp:039b27d0 --> | _(not minted)_ |
| promises | critical | [Plan Review §promises] COM apartment initialization (CoInitializeEx) is not stated… <!-- fp:e8336ffe --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] out_result / out_err pointer lifetime across the C/Zig ABI … <!-- fp:5f031e17 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Win32 navigation timeout mechanism is unspecified. M6 says … <!-- fp:d35d4787 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] PostWebMessageAsString threading model is not stated as the… <!-- fp:1c783fad --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] Win32 window + CoreWebView2 controller cleanup guarantee is… <!-- fp:79a130fb --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] M1 unit test is a shape assertion on a Linux host: zig buil… <!-- fp:4140ec0c --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] IPC scratch buffer bound for the WebView2 shim is unquantif… <!-- fp:e932f3f0 --> | _(not minted)_ |
| promises | warning | [Plan Review §promises] [VERIFY] zb_run_open (webkit_shim.h:30) has no implementati… <!-- fp:d85ce9c1 --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] os.info Windows struct: field value format for sysname, rel… <!-- fp:8a79470b --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] machine field presence in os.info struct: the cite… <!-- fp:e484c6fa --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] [VERIFY] LoadFailed exit code 5: the plan references 'exit … <!-- fp:1a179dbd --> | _(not minted)_ |
| data_models | warning | [Plan Review §data_models] IPC reply result field type is unspecified per command. For… <!-- fp:4d3bdb8d --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] zb_version_line Windows output format unspecified — plan sa… <!-- fp:04f663e5 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] os.info Windows field value mapping not documented — plan r… <!-- fp:a1e68df3 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] zb_ipc_dispatch int return value semantics not documented —… <!-- fp:351a2201 --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] [VERIFY] zb_run_screenshot Windows implementation not menti… <!-- fp:9af2644f --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] [VERIFY] zb_reload, zb_window_new, zb_run_open Windows impl… <!-- fp:760990ad --> | _(not minted)_ |
| apis | warning | [Plan Review §apis] [VERIFY] IPC reply JSON field names not confirmed against t… <!-- fp:bf2948a5 --> | _(not minted)_ |

Run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <path> --mint-beads` to mint these as a beads epic + child issues. The CLI will substitute real Bead IDs into this section.