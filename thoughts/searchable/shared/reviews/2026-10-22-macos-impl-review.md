# macOS Implementation Review Log — 2026-10-22

**Reviewer:** cod_1 / SilverRidge  
**Role:** reviewer only; writes no product code  
**Standards:** **R1–R4**; the plan's **Verification rule: prove it by running it**; and the **Mac run rule: reviewer approval of one exact commit plus the SHA-256 of every harness file the run uses, followed by the orchestrator's release**.

The normative plan is `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md`, rev 32. Its REVIEW, three milestone VALIDATION files, and RULE-AUDIT are required review context. Every commit review records its verdict, the exact first minimum if blocked, evidence and command exit codes, mutant results, Mac-run authorization if any, and whether the SHA is safe to push.

## R1–R4 review rules

### R1 — behavior proof versus source tripwires

Runtime behavior is accepted only from a driven test of the production seam or a bounded real-platform run. Source-text parsing, symbol checks, `grep`, `nm`, `strings`, `otool`, and similar checks are architecture tripwires only; they do not prove control flow or runtime behavior and cannot close a behavioral obligation.

### R2 — one exact minimum

The first `BLOCK` for a slice states the complete exact minimum needed to close it: named product changes, tests, registration, and platform evidence. Later reviews judge only that minimum. A later blocker may add an obligation only if new evidence establishes an R3-class defect; otherwise it is a non-blocking `SHOULD`.

### R3 — blocking threshold

`BLOCK` only for a product defect, a safety or security risk, a red registered gate, or a purported proof that cannot fail when the claimed behavior is broken. Missing evidence already named by the first minimum is a proof-that-cannot-fail blocker. Additional diagnostics, coverage, mutants, or oracle strengthening beyond that minimum are `SHOULD`s.

### R4 — lightweight compile-only Mac feedback

R4 is a separate compile/link-only evidence tier. An unchanged, reviewed harness digest may be used at one exact clean source commit on both matching hosts (x86_64 Intel and arm64 Apple Silicon), recording exact compiler/link arguments, results, artifact digests, and zero run-owned leftovers. It must not launch any newly built target, access credentials or live services, perform UI/signal/destructive work, install, use `sudo`, mutate persistent host state, or fetch dependencies. Any harness-byte change requires a new digest review. R4 proves only compilation/linking; it cannot satisfy runtime, containment, Keychain, UI, or owner-visible acceptance.

## Plan verification rule — prove it by running it

1. A behavior is proven only by running the real production function, C export, binary, or script with real inputs and asserting an observable result. A mirror or reimplementation proves nothing.
2. A test counts only when registered in a `build.zig` step reached by `zig build test` or the named platform gate. An unregistered test is a draft.
3. Proof requires red, green, and at least one mutation of production code that makes the test fail. The commit message records the mutant, command, and failing output. A mutant that stays green is not proof.
4. Platform code is proven only by a released run on the relevant platform. AppKit/Objective-C, Keychain, and Seatbelt require both Macs (x86_64 and arm64). Linux or cross-compilation proves only compilation.
5. Source and binary-inspection checks are tripwires, never behavioral proof.
6. The production entry point must reach the behavior. Unwired code is `NOT BUILT` even when an isolated unit test passes; an end-to-end test proves the production caller reaches it.
7. A skip, exit 77, or zero real rows/assertions under a gate is failure.
8. Validators and reviews use the same rule: `VERIFIED` or `passes` requires an observed run at a named commit with the command and exit code. Reading alone yields `SUSPECTED`.
9. Every behavior names its production entry point, test file and registered step, production mutant, and—where applicable—platform run and host(s). Missing any item means it is not implementation-ready.

## Mac run rule

No agent may contact either Mac by `ssh`/`scp` or execute a test binary there until both conditions occur in order:

1. SilverRidge approves the exact source commit and records the SHA-256 of **every** harness file the proposed run uses.
2. The orchestrator explicitly releases that exact reviewed run.

Approval never transfers across commits or changed harness bytes. The compile-only R4 tier is the default Mac evidence tier. Runtime platform proof requires its separately reviewed bounded harness and release. No Mac run may execute `tests/mac/ms6_5_reaper_gate.sh`, `hard_gate_driver.py`, or any `SIGKILL` path.

## 2026-10-22 — Session initialization

Read in full before review work: the session brief; plan rev 32; its REVIEW; `VALIDATION-ms0-3`, `VALIDATION-ms4-6`, and `VALIDATION-ms7-9`; and the RULE-AUDIT. Registered with Agent Mail as SilverRidge. No product code was written, no Mac was contacted, no Mac run was authorized, and no implementation SHA has yet been declared safe to push in this review stream.

## 2026-10-22 — Initial implementation queue

### `0d359e6` — 4pa.70 reaper-guard red

**APPROVED AS A VALID RED; SAFE TO PUSH.** This is an unregistered, hostless test only. From an exact `git archive 0d359e6`, inside isolated user/PID/network namespaces, `bash tests/mac/ms6_5_reaper_gate_guard_selftest.sh` exited 1 with the expected 11 failures: the old production script reached stubbed `ssh` in refusal rows and staged the dirty working-tree bytes in its positive control. No real host was contacted and no signal path ran.

### `e818499` — 4pa.70 reaper-guard green

**BLOCK; NOT SAFE TO PUSH AS THE 4pa.70 GREEN.** The implemented portion is sound: from an exact archive, `zig build test-mac-reaper-gate-guard -j4 --summary all` exited 0, the selftest reported 19 checks and the build reported 3/3 steps. The script requires exact-commit approval plus a matching release token and stages committed bytes. The author recorded five production mutants, all exit 1: old guard (10 failures), missing token check (4), missing approval check (4), unchecked token contents (2), and working-tree staging (1).

The first and exact minimum is the missing rev-32 R29-SAFETY condition: define the authoritative `$HOME` Mac-host-list/shared-host contract; add a refusal row proving a configured shared host exits 1 with zero `ssh`/`scp` calls; and record a production mutant deleting that refusal. The present registered proof stays green while that required safety behavior is absent, an R3 safety/R3(d) blocker. Alternatively, the orchestrator must formally amend rev 32 to delete the condition before this SHA is resubmitted against the amended contract. This review does not authorize the destructive gate on either Mac; the session brief independently forbids running it.

### `2aa1abb` — 4pa.72 portable card press green (red `7472674`)

**APPROVED SCOPED; SAFE TO PUSH.** From an exact archive, `zig build test-agent-drawer-card-press -j4 --summary all` exited 0 with 5/5 tests, and `zig build cross-check-agent-tools-mac -j4 --summary all` exited 0 with 7/7 steps. The driven registered test exercises `Approver`, `cardPress`, the C bridge, real `Cards`, single use, expiry, exact card identity, own-control truth, deny, and fail-closed unknown controls. The author-recorded production mutants all exit 1: drop own-control check (3/5 pass), make `else` approve (3/5 pass), and narrow C truth to `own == 1` (4/5 pass). `check-card-authority-mac` remains a tripwire and is not counted as proof.

Rule 6 status remains **NOT BUILT**: no AppKit card calls the bridge and the macOS minters are not live. No Mac evidence is claimed. The aggregate `zig build test` was not run for this review; no known red registered gate was presented, so that absence does not block this scoped portable-seam verdict.

### `751be84` — 4pa.55 unregistered failed-load red

**SAFE TO PUSH ONLY AS AN UNREGISTERED RED DRAFT.** From an exact archive, in-memory syntax compilation of both new Python files exited 0; each file run with `--browser /nonexistent` exited 1 rather than skipping. Rows 1, 2, 4, and 5 match owner option C but remain Mac-unproven. No Mac run is authorized because no exact harness-file digest set has been submitted.

**Row-3 substitution NOT ACCEPTED as plan proof in its current form.** The literal plan row—“a response the policy cancels”—is impossible in the current product because `nav_policy.decide(..., .response)` always returns `.use`; the plan needs an amendment. An undisplayable attachment is potentially a valid replacement only if it causally proves the same production failure seam. The committed row proves merely that `/attach` was fetched and the browser remained alive; it asserts no `LOAD_FAIL` or other observable from `handleLoadFailureForWebView`, so it can pass without entering that function.

Exact minimum before the green registers row 3: amend the plan to the chosen producible failure; assert one direct production failure-handler observable (for this attachment, exactly one matching `LOAD_FAIL`, or an equivalently direct result); record the current failing red on both Macs under exact-commit plus all-harness-digests approval and orchestrator release; and show that restoring the production `requestExit` makes this row fail. No production mutant exists yet because this is a red-only commit.

**Push-safe implementation SHAs after this queue:** `0d359e6`, `2aa1abb`, and `751be84` (the last only as an unregistered draft). `e818499` is not push-safe pending the exact minimum above.

## 2026-10-22 — Fix-forward, red, and guard queue

All commands below ran from clean `git archive` exports with display and askpass variables unset, private HOME/XDG directories, and user/PID/mount/network namespaces where applicable. No Mac was contacted and no Mac run is approved or released.

### `3b81737` red + `843cf3d` green — 4pa.70 shared-host refusal

**APPROVED; BOTH SHAS ARE SAFE TO PUSH.** Judged only against the first exact minimum recorded at `cd515ce`, this closes the `e818499` block. The authoritative list is `$HOME/.ntm/zb-release/shared-mac-hosts`, accepting one `user@host` or `host` per line with comments. Missing/unreadable list data fails closed; either exact target host is refused before staging or any `ssh`/`scp`; a nonmatching list remains a positive control. The test is registered in `test-mac-reaper-gate-guard` and `zig build test`.

Independent evidence: the exact red selftest exited 1 with six intended failures and four stub calls in each refused row. `zig build test-mac-reaper-gate-guard -j4 --summary all` at `843cf3d` exited 0, 4/4 steps. Deleting the production shared-host refusal made the registered step exit 1 with six failures. Author-reported additional production mutants—allow missing list, compare whole `user@host`, and substring-match hosts—also exited 1. This approval does not authorize the destructive reaper gate on a Mac.

### `ffc0330` + `bbba1b3` — 4pa.55 failed-load reds

**SAFE TO PUSH AS UNREGISTERED RED DRAFTS.** `ffc0330` correctly gives every launch a private HOME and explicit per-run profile. `bbba1b3` completes the test half of the `cd515ce` row-3 minimum: every row waits for a `LOAD_FAIL` matching the intended load and, after a grace period, requires exactly one; row 3 also proves `/attach` was fetched. Both exact commits passed `py_compile` (exit 0), and both fail rather than skip with a missing browser (exit 1).

The attachment is acceptable as a candidate platform failure input, not as an app-policy cancellation. It remains an unregistered and Mac-unproven red until a released Mac run shows that WKWebView produces the matching `LOAD_FAIL`. If it does not, another producible response failure is required. Registration/green still requires the already-recorded both-Mac red, the product fix, and the restore-`requestExit` production mutant.

### `7f8b217` — 4pa.58 native close-button red and hook 14

**SEAM ACCEPTED; SAFE TO PUSH AS AN UNREGISTERED RED DRAFT.** The seam is the plan-named production action: an exact title match, one-shot per host, weakly deferred to the main queue, calls `-[NSWindow performClose:]`. Its environment read is behind `zb_auto_test_hooks_enabled()`. The red checks registry removal, routed `no_window`, job settling, opener/process survival, and the shared destroy-path window count. `py_compile` exited 0 and a missing browser exited 1. Objective-C compilation and behavior remain unproved pending a released both-Mac run.

**The green MUST extend `mac_ms2a_hook_inert_test.py` for hook 14.** Without `--e2e-protocol`, set `ZB_DEBUG_NATIVE_CLOSE_ON_TITLE`, create a popup with the matching title, and prove it remains listed and routable; deleting the `zb_auto_test_hooks_enabled()` guard must fail that row. The positive close-button test supplies the with-e2e half. A green that omits this is blocked under R3 safety and R30.2 T15.

### `461deff` red + `78bcbc9` green — 4pa.63 Darwin guard selftest

**APPROVED SCOPED; BOTH SHAS ARE SAFE TO PUSH.** At `461deff`, `zig build test-darwin-guard-selftest -j4 --summary all` exited 1: all four macOS top/nested probes failed because the expected deliberately unreferenced type error was not found. At `78bcbc9`, the same command exited 0, 8/8 steps, and `zig build test-agent-run-ledger-darwin-build -j4 --summary all` exited 0, 4/4 steps. Restoring the old lazy root made the registered selftest exit 1 on all four macOS probes. Author-reported shallow-recursion, no-function-reference, and injected-ledger-error mutants were also caught.

This is a registered compile tripwire for public non-generic declarations through the same ledger/recovery guard helper. Generic functions are explicitly outside its coverage. It proves neither Darwin runtime behavior nor the generic bodies.

### `6074fba` — 4pa.59/4pa.77 build-on-Mac red

**SAFE TO PUSH ONLY AS AN UNREGISTERED RED DRAFT.** The exact hostless selftest exited 1 with the expected 21 failures against the old script: live working-tree bytes, fixed paths, suppressed archive failure, no pinned hosts, and no cleanup. The run was additionally enclosed in a network namespace; no host was contacted.

The remote-directory oracle is presently too weak for registration: it accepts a `zb-gate-<sha>-<nonce>` token anywhere in any argv, so `/tmp/zb-gate-...` or an unrelated echoed token can pass without proving that extraction, build, and cleanup use the exact fresh directory under remote HOME. Before the green registers this test, tighten it to reject those mutants and prove that staging/extraction, build, and cleanup all name the same exact `$HOME/zb-gate-<sha>-<nonce>` directory. The selftest itself should also remain under network isolation in its registered runner.

### `3164dbf` — plan errata

**PARTIAL; BLOCK; NOT SAFE AS THE AUTHORITATIVE PLAN ERRATUM.** The MS2c.6 correction to `no_window` matches `automation_server.zig`; no `window_gone` result exists. The 4pa.55 row-3 wording does not match production code: `nav_policy.decide(..., .response)` unconditionally returns `.use`, and `decidePolicyForNavigationResponse` therefore calls `WKNavigationResponsePolicyAllow` and returns. Its cancel branch is unreachable for current response inputs. A `Content-Disposition: attachment` may become an undisplayable/download response after the app allows it, but that is not the app response policy refusing or cancelling it.

Exact minimum: retain the attachment as a candidate Mac failure input and the exact-one matching `LOAD_FAIL` criterion, but state that the app policy allows every response; remove the `decidePolicyForNavigationResponse -> cancel` claim/citation and describe any refusal/conversion as WebKit behavior to be established by the Mac red. If the released red produces no matching `LOAD_FAIL`, the row must select a different producible failure. Until that documentation fix-forward lands, the submitted aggregate tip through `3164dbf` is not push-safe as plan-correct. A later unreviewed commit moved the shared-worktree HEAD to `79a70d8`; no verdict on that commit is included here.

**Push-safe SHAs from this queue:** `3b81737`, `843cf3d`, `ffc0330`, `bbba1b3`, `7f8b217`, `461deff`, `78bcbc9`, and `6074fba` with the red-draft/scoped qualifications above. `3164dbf` is blocked. No Mac run is requested or authorized.

## 2026-10-22 — Plan fix-forward and 4pa.57 red

### `f974ae7` — fix-forward for the `3164dbf` plan block

**APPROVED; SAFE TO PUSH; CLOSES THE `3164dbf` BLOCK.** Judged only against the exact `2559ea6` minimum, the two authoritative row-3 passages now state that the app response policy allows every response (`nav_policy.zig:27`, `.response => .use`), remove the false `decidePolicyForNavigationResponse -> cancel` claim and citation, retain the attachment only as a candidate WebKit failure input, require exactly one matching `LOAD_FAIL`, attribute any refusal/download conversion to WebKit behavior that the released Mac red must establish, and require a different producible failure if that red emits no matching `LOAD_FAIL`. `git diff --check` exited 0, and a search for either stale policy-refusal/cancel claim exited 1. No runtime proof is claimed by this documentation fix.

`3164dbf` remains wrong in isolation; the plan content is push-safe as the `3164dbf` + `f974ae7` fix-forward series. The current branch tip is not yet approved as an aggregate because the unrelated `a65e15b` lies between review commit `2559ea6` and `f974ae7` and has not been reviewed in this queue.

### `79a70d8` — 4pa.57 later-popup dialog-id red

**SAFE TO PUSH AS AN UNREGISTERED RED DRAFT.** The commit adds only `tests/e2e/mac_ms2b_dialog_popup_id_test.py` and registers no gate. It drives the specified defect non-vacuously: open two popups, preserve their stable `page.list` ids, close the first, open a confirm in the later popup, then require the listed stable id, targeted lookup, response success, and the page-observed accepted result. Against the current `idx + 1` implementation the remaining `window-3` dialog is misreported as `window-2`, so the assertions distinguish the defect. All imports and reused helpers are live and appropriate; every launch has a private HOME and explicit profile.

From an exact clean archive, `python3 -m py_compile tests/e2e/mac_ms2b_dialog_popup_id_test.py` exited 0 and the missing-browser probe exited 1 with `FAIL ...-binary-missing`, not a skip. The Mac red and its future production mutant remain unproved until the exact-commit/harness-digest approval and orchestrator release.

**New push-safe SHAs from this queue:** `79a70d8` as an unregistered red draft, and `f974ae7` as the required fix-forward for `3164dbf`. No verdict is made on intervening `a65e15b`; therefore no aggregate branch-tip push approval is given. No Mac run is requested or authorized.

## 2026-10-22 — 4pa.56 cookie-deadline red

### `a65e15b` — late cookie-store completion seam and red

**SEAM ACCEPTED; SAFE TO PUSH AS AN UNREGISTERED RED DRAFT.** `ZB_DEBUG_COOKIE_DELAY_MS` wraps the real `WKHTTPCookieStore` completion path used by get, set, and delete. It is centralized behind `zb_auto_test_hooks_enabled()` and, when unset, zero, malformed, or used without `--e2e-protocol`, invokes the handler inline as before. This is the correct socket-drivable substitute for the plan's undrivable C-only delay seam.

The unregistered test is non-vacuous for all three operations: each row requires a fresh `zb-cookie-delay-hit`, an `action_timeout` response before the 12.5 s completion, and final live-job baseline/process liveness. It uses private HOME/profile state, all imports and reused helpers are live, and no raw helper bypass was found. From an exact clean archive, `python3 -m py_compile tests/e2e/mac_cookie_timeout_test.py` exited 0, the missing-browser probe exited 1 with an explicit failure, and `git diff --check a65e15b^ a65e15b` exited 0. Objective-C compilation and the runtime red remain unproved until a released both-Mac run.

The green **must** extend `mac_ms2a_hook_inert_test.py` for hook 15 and catch a production mutant that drops `zb_auto_test_hooks_enabled()`. It must also register the red only with the green, retain an ordinary no-hook cookie success row to pin inline/default behavior, and demonstrate that independently deleting each get/set/delete `zb_job_inflight(job)` addition fails its corresponding row.

With `a65e15b` approved, every committed implementation/documentation SHA in the ancestry since reviewed baseline `5ccf442` now has either a direct push-safe verdict or a reviewed fix-forward closing its block (`e818499` by `3b81737` + `843cf3d`; `3164dbf` by `f974ae7`). **The committed branch tip is therefore push-safe as a whole**, with the recorded unregistered-red/scoped qualifications. The unrelated untracked `tests/app_profile_dir_macos_test.zig` is not part of that tip and was not reviewed or touched. No Mac run is requested or authorized.
