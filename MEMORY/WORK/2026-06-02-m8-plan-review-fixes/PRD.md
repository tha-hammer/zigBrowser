---
title: Enhance M8 WebView2 plan to clear all 29 PlanReview findings
task: Enhance M8 plan to fix all review findings
slug: 2026-06-02-m8-plan-review-fixes
effort: E3
phase: complete
progress: 35/36
mode: algorithm
started: 2026-06-02
updated: 2026-06-02
---

## Context

The PlanReview pipeline reviewed `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`
and returned **Needs Major Revision**: 2 critical + 27 warnings (Contracts 6,
Interfaces 4, Promises 9, Data Models 4, APIs 6), plus 1 Scaffolding/Realness
violation (M1).

The task: **enhance the plan markdown** so every finding is resolved and a
re-run of PlanReview clears all criticals + the realness violation. This is a
PLAN-enhancement task — NOT M8 implementation. Each fix adds a grounded spec to
the plan (or instructs a milestone to add a contract row), it does not write the
Zig/C++/Python code.

All fixes are grounded in the real source the findings cite (read this session):
- `src/webkit_shim.h:12-13,30-41` — opaque ZbApp/ZbWindow typedefs + 6 shim fns + 2 Zig-owned exports; exit-code enum incl. RUNTIME_MISSING=9, WEBVIEW_INIT_FAILED=10, LOAD_FAILED=5.
- `src/ipc.zig:33-42` os.info uses `std.posix.uname()` (windows-incompatible); `:47-79` zb_ipc_dispatch returns 0+out_result (pre-serialized JSON in threadlocal 4096 buf) or nonzero+out_err=@errorName (threadlocal 128 buf).
- `src/main.zig:43,61,21` references only zb_app_run, zb_run_screenshot, zb_version_line; force-links ipc.zig+nav_policy.zig via comptime (:8-11).
- `src/webkit.zig:13` runOpen→zb_run_open is an UNUSED pub fn → dead-code-eliminated → not a link dependency. zb_reload/zb_window_new never referenced.
- `build.zig:2-4,95-118` Backend enum/resolveBackend/configureBackend/pkg_guard insertion points; `:55-70` backend-free `ipc_tests` module (cross-compiles without the C shim).
- `src/errors.zig:7,28` LoadFailed=5 EXISTS (review [VERIFY] was a false alarm).
- `tests/fixtures/app/zbhost.js:36-67` onWebViewReply: requires numeric id, resolve(data.result) / reject(asError(data.error)); unknown ids dropped.
- `tests/e2e/PROTOCOL.md:30-32` LOAD_FAIL\t<uri>\t<domain>\t<code>; `:18-24` IPC/IPCERR raw-JSON result + error token.
- `tests/e2e/m8_reply_channel_test.py:93,100` oracle: IPC echo == `"hi-42"`, IPCERR echo == `BadArgs`.

### Risks
- Over-prescribing above the plan's real tier (it declares L3; review heuristic read L1). Mitigation: fixes stay at "name the mechanism/contract," not invent new architecture.
- A "fix" that contradicts the GTK contract (must stay byte-identical). Mitigation: anti-criteria ISC-A1.
- Claiming a finding is fixed without the plan text actually containing it. Mitigation: independent reviewer Task agent + PlanReview re-run (provenance, not just assertion).

### Plan
Rewrite the plan in place: (1) correct Key Discoveries claims to match verified source; (2) add concrete contracts inline per milestone (os.info field table, version-line format, IPC reply shapes, LOAD_FAIL domain map, exit-code discriminator, shim symbol checklist); (3) inject the two critical COM mechanics (message pump + CoInitializeEx) into M2/M3 with red tests/properties; (4) fix M1 realness framing + compile-gate target; (5) append a "Review Resolution" table mapping all 29 findings → location. Verify via independent reviewer agent + PlanReview CLI re-run.

## Criteria

### Critical (2 review criticals + realness)
- [x] ISC-1: Plan M3 specifies a Win32 GetMessage/DispatchMessage pump on the UI thread during env+controller creation — C7.2 + M3 green/C7-prop
- [x] ISC-2: Plan M3 adds a red test/property that env-creation callback never fires without the pump (hang→timeout detectable) — M3 C7-prop hang oracle
- [x] ISC-3: Plan specifies CoInitializeEx(NULL, COINIT_APARTMENTTHREADED) as first COM action of windows zb_app_run — C7.1 + M3 step 2
- [x] ISC-4: Plan specifies CoUninitialize on all windows zb_app_run exit paths — C7.1/C7.4
- [x] ISC-5: Plan M1 marked compile/shape-only; real os.info Windows values proven only in-guest at M4 — M1 realness banner
- [x] ISC-6: Plan M1 windows compile gate targets backend-free ipc_tests module, not full `zig build test` — M1 red + Testing Strategy

### Contracts
- [x] ISC-7: Plan adds COREWEBVIEW2_WEB_ERROR_STATUS → LOAD_FAIL <domain>/<code> mapping — C6 (domain 2)
- [x] ISC-8: Plan M6 names RuntimeMissing(9) vs WebViewInitFailed(10) discriminator — C8
- [x] ISC-9: Plan M2 enumerates each webkit_shim.h symbol as IMPLEMENT / STUB / EXCLUDED-by-DCE — C10 table
- [x] ISC-10: Plan M1 declares os.info JSON keys {sysname,release,machine} platform-invariant — C1 + M1 property
- [x] ISC-11: Plan M5 cites zbhost.js onWebViewReply receive shape {id:number, result|error} (lines 36-67) — C3
- [x] ISC-12: Plan M5 specifies out_err → JSON error token string ("BadArgs"), not a human message — C2/C3

### Interfaces
- [x] ISC-13: Plan M1 commits os.info windows mechanism to std.os.windows (RtlGetVersion) in ipc.zig; drops "via the shim" — M1 green
- [x] ISC-14: Plan commits webview2 shim to src/webview2_shim.cpp (C++17), not .c — C10 + M2
- [x] ISC-15: Plan resolves zb_run_open/zb_reload/zb_window_new linkage (unreferenced→DCE; stub only if linker pulls) — C10 + Key Discoveries
- [x] ISC-16: Plan states ZbApp/ZbWindow reuse webkit_shim.h opaque typedefs (:12-13); shim #includes webkit_shim.h — C10

### Promises
- [x] ISC-17: Plan specifies out_result/out_err threadlocal-buffer lifetime: shim copies synchronously before handler returns — C4 + M4
- [x] ISC-18: Plan M6 names Win32 timeout mechanism (SetTimer→WM_TIMER reaped by pump→Timeout(8)) — C7.3 + M6
- [x] ISC-19: Plan M5 states PostWebMessageAsString UI-thread serial dispatch as the id-correlation invariant — C5 + M5 property
- [x] ISC-20: Plan M3 specifies window+controller cleanup (COM Release order + DestroyWindow site) — C7.4 + M3 refactor
- [x] ISC-21: Plan M4 quantifies shim IPC scratch bound (mirror ipc.zig 4096 result / 128 err) — C4 (≤4352B) + M4

### Data Models
- [x] ISC-22: Plan adds os.info windows field table (sysname="Windows", release=major.minor.build, machine=@tagName(cpu.arch)) — C1
- [x] ISC-23: Plan confirms machine field already present in struct (ipc.zig:39); Linux output unchanged — C1 + Key Discoveries
- [x] ISC-24: Plan cites LoadFailed=5 present in errors.zig:7,28 (corrects review false-alarm) — Key Discoveries + M6
- [x] ISC-25: Plan adds per-command IPC reply result-shape table (ping→"pong", echo→json string, os.info→object), spliced raw — C2

### APIs
- [x] ISC-26: Plan fixes zb_version_line windows output format string — C9
- [x] ISC-27: Plan documents zb_ipc_dispatch routing (0→result, nonzero→error), cites ipc.zig:47-79 — C2 + Key Discoveries
- [x] ISC-28: Plan addresses zb_run_screenshot windows (stub→SNAPSHOT_FAILED; PowerShell supplements, not replaces in-process) — C10
- [x] ISC-29: Plan confirms IPC reply JSON field names against zbhost.js parser (result/error) — C3

### Meta / Structural
- [x] ISC-30: Plan annotates tier (declares L3; review heuristic L1) clarifying systems-level scope — header tier note
- [x] ISC-31: Plan Key Discoveries updated so every claim matches verified source (incl. webkit.zig runOpen dead) — Key Discoveries rewrite
- [x] ISC-32: Plan appends Review Resolution table mapping each of the 29 findings → location — Review Resolution section
- [DEFERRED-VERIFY] ISC-33: PlanReview re-run shows 0 critical issues AND clean Scaffolding & Realness — re-run wedged on API I/O (zero output, terminated); manual re-run command in Verification. Confirmatory only; Probe 1 covers the same outcome.
- [x] ISC-34: Independent reviewer agent confirms all 29 findings addressed in the rewritten plan — Probe 1: 29/29 ADDRESSED, 0 WEAK, 0 MISSING

### Anti-criteria
- [x] ISC-A1: No change introduces GTK/Linux behavioral divergence (Linux path stays byte-identical per plan) — C1 key-invariance; reviewer found no divergence
- [x] ISC-A2: No new IPC commands beyond ping/add/echo/os.info introduced — "What We're NOT Doing" unchanged; reviewer confirmed

## Decisions
- silmari store healthy but empty for this domain — recall returned zero hits across all layers. No prior memory to apply.
- Scope held to plan-doc enhancement; source/PROTOCOL.md edits are specified AS milestone tasks inside the plan, not performed now (respects "plan means stop" + minimal scope).

## Verification

**Probe 1 — Independent reviewer agent (Writer/Reviewer capability, `Task` tool call).**
Fresh agent read the rewritten plan + all 8 cited source files, scored each of the 29
findings ADDRESSED/WEAK/MISSING, and independently re-derived two of the plan's technical
claims. Verbatim result:

> **ADDRESSED: 29/29 · WEAK: 0 · MISSING: 0** (2 critical + 1 realness + 26 lettered all concrete and source-grounded).
> - **DCE claim SOUND.** `webkit.zig:13` `runOpen` is a `pub fn` never called … `zb_run_open` emits no symbol ref … EXCLUDE is correct; `zb_run_screenshot` correctly STUB (referenced at main.zig:61).
> - **LoadFailed=5 present.** errors.zig:7 + :28. Review [VERIFY] was a false alarm; plan states this correctly.

Non-blocking nits raised: (1) C4 doesn't mention `dispatch_scratch[65536]` — cosmetic, shim only touches the out-pointers; (2) C7 "first action" wording locally contradicted by C8 ordering — **FIXED** (C7.1 reworded so the C8 runtime check is explicitly first, CoInitializeEx is the first *COM* call). (3) pump-thread phrasing assumes zb_app_run owns the main thread (true — called from main.zig main thread).

ISC-1..ISC-32, ISC-34, ISC-A1, ISC-A2 → confirmed ADDRESSED by Probe 1 + the Edit tool results (each plan edit applied successfully). ISC-A1/A2: reviewer found no GTK/Linux divergence and no new IPC commands; the os.info key-invariance (C1) and "What We're NOT Doing" (unchanged) hold.

**Probe 2 — PlanReview CLI re-run (PlanReview capability, `bun` invocation).** Re-ran the
P_REVIEW_PLAN pipeline against the enhanced plan to confirm 0 critical issues + clean
Scaffolding & Realness (ISC-33). Result below:

**[DEFERRED-VERIFY]** — the re-run (bg task b84pgzv33) **wedged on its first LLM inference
call for 20min and produced zero output** (no REVIEW.md, no phase JSONs; process `Sl` the
whole time → terminated). Transient PlanReview/API I/O hang, nothing to do with the plan.
ISC-33 is therefore deferred, NOT claimed passed. Manual re-run to clear it:
```
bun /home/maceo/.claude/skills/PlanReview/Tools/PlanReview.ts \
  --plan-path /home/maceo/ntm_Dev/zigBrowser/thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md
```
**Why finalizing without it:** ISC-33 is a *confirmatory* probe. The load-bearing oracle is
Probe 1 — an independent agent that re-derived both critical resolutions (message pump, COM
apartment) and the realness fix from source, scoring 29/29 ADDRESSED. The criticals are
resolved in the plan text regardless of whether the pipeline re-runs; the re-run would only
re-confirm what Probe 1 already established by a different method.

**Probe 3 — plan-content greps (Read/Bash):** file is 368 lines; 10 normative-contract
sections (C1–C10) present; `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`, `GetMessage`
pump (×2), `M1 is COMPILE/SHAPE-ONLY` banner, `C7-prop`, and `## Review Resolution` all
grep-confirmed present.

## LEARN

🧠 LEARNING:
- **Should-have-done-differently:** I launched the confirmatory PlanReview re-run *in parallel*
  with the content edits and with no bounded timeout. It wedged on its first inference call and
  produced zero output for 20min, stranding the gate. Should have run it *after* edits settled,
  with an explicit timeout, and treated a no-output hang as "defer + fall back to the in-context
  oracle" from the start rather than waiting through three wakeups.
- **Smarter algorithm:** Pair every *external* review-pipeline probe with an *in-context*
  independent-reviewer agent up front, and make the in-context oracle load-bearing — the external
  pipeline is flaky (network/API) and should only ever be confirmatory. Bound external probes with
  a timeout and a deterministic deferral path.
- **Capabilities unused:** None genuinely missed — /simplify is code-only (this was prose); the
  thinking skills would have been phantom given the review already supplied the adversarial pass.
  Honest under-selection held up: Writer/Reviewer alone fully verified.
- **Smarter AI design:** Batch-read all cited source at OBSERVE (done) and derive the ISC list as
  the *claim-vs-source delta* — several findings (LoadFailed=5, machine-field, DCE of unused shim
  symbols) were resolvable to "review was wrong / over-cautious," and reading source first turned
  them from "add a spec" into "correct the claim," which is a cheaper and truer fix.

### Memory cards

#### Q1 — Should-have-done-differently
- body: When a verification step calls an external LLM-review pipeline (e.g. PlanReview CLI), it can wedge on its first inference call and emit zero output indefinitely. Run such probes AFTER edits settle, bound them with a timeout, and on a no-output hang defer the criterion and fall back to an in-context independent-reviewer agent rather than blocking.
- kind: learning
- mode: root
- source: algorithm-2026-06-02-m8-plan-review-fixes-learn
- status: open

#### Q4 — Smarter AI design
- body: For "fix all review findings" tasks, read every cited source file at OBSERVE first and derive the fix list as claim-vs-source deltas — a meaningful fraction of hostile-review findings are the reviewer being over-cautious (the cited symbol/field/code already exists), which converts "write a new spec" into the cheaper, truer "correct the claim and cite the line."
- kind: learning
- mode: root
- source: algorithm-2026-06-02-m8-plan-review-fixes-learn
- status: open
