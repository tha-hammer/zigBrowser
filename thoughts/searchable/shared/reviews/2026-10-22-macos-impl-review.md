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

## 2026-10-22 — 4pa.60 fresh-profile pacing reds

### `cd1c55f` — portable fresh-directory red

**SAFE TO PUSH ONLY AS AN UNREGISTERED RED DRAFT; NOT ACCEPTED AS THE PLAN'S RED 1 PROOF.** The test is genuinely red and isolated: from an exact clean archive, `zig test -lc --dep atomic_file -Mroot=tests/app_profile_dir_macos_test.zig -Matomic_file=src/atomic_file.zig` exited 1 at the intended missing `atomic_file.ensureDir` call. It uses `std.testing.tmpDir`, first proves the real `atomic_file.replaceJson` consumer fails on the absent nested parent, then specifies directory creation, successful replacement/readback, and idempotence. It is absent from `build.zig`, and `git diff --check` exited 0.

The plan at lines 2040–2042 requires this Linux red to call the macOS branch of production `applyProfileDir`. The committed file instead imports only `atomic_file` and calls the proposed helper directly. It therefore remains green if the helper exists but `src/app.zig:497-507` never calls it. The Mac Red 2 can eventually prove that wiring, but it does not make this file the portable production-branch proof the authoritative plan specifies.

The first exact minimum before the 4pa.60 green may register or claim Red 1 is: make the portable red execute a production-owned macOS profile-application seam used by `applyProfileDir`, with the WebKit binder injected or otherwise safely testable on Linux; assert the fresh nested directory and real pacing write through that seam; register it in `test`; create the directory before the WebKit bind; and record production mutants removing (1) directory creation and (2) the production invocation, each making the registered red fail. If the owner instead keeps this helper-only test, rev 32 must first be amended to label Red 1 helper/consumer coverage and assign all production-call wiring proof to the released Red 2.

### `909053e` — real-binary restart red

**APPROVED AS AN UNREGISTERED RED 2 DRAFT; SAFE TO PUSH.** It launches the production binary twice with the same genuinely fresh nested `--profile-dir`, a private temporary HOME/socket/profile and loopback-only page. Run 1 checks a non-vacuous default, drives `social.set_pacing`, requires the real pacing file and no save warning; run 2 requires the changed cap. `social.set_pacing` is acceptable for the scoped 4pa.60 directory/persistence defect because it synchronously reaches the same `state.changed -> Persister.persist -> pacing_store.save -> atomic_file.replaceJson` path and kills the plan's skip-directory-creation mutant without a UTC-day rollover hazard. It does **not** prove the broader counted-action/`actions_today == 1` contract and must not be cited as that proof.

From an exact clean archive, `python3 -m py_compile tests/e2e/mac_profile_pacing_persist_test.py` exited 0, and the missing-browser row failed closed with exit 1. The file is absent from every gate and `build.zig`; no Mac behavior is proved.

**No Mac run is approved.** Besides the absent exact-commit/harness-digest request and orchestrator release, this file imports `stop_browser_macos`, whose teardown can send `SIGKILL`; the session brief forbids running anything that sends `SIGKILL` on a Mac. Any future run proposal must use a reviewed SIGTERM-only bounded teardown (and include every imported harness digest) before it can be approved.

**Push-safe result:** both `cd1c55f` and `909053e` are safe to push as unregistered drafts, so the committed branch tip is push-safe as a whole. The qualification is substantive: `cd1c55f` cannot be registered as rev-32 Red 1 until the exact minimum above is met. No Mac was contacted.

## 2026-10-22 — 4pa.64 latent-defect plan erratum

### `b182ff3` — defer the options-preservation proof to the first carded DOM write

**APPROVED; SAFE TO PUSH.** The erratum matches the production code. `agent_broker.gated_tools` contains only navigate and reload; only a gated tool assigns `Job.verb` and reaches `awaitApproval`/the card-producing phase A. `gatedArgsOk` admits exactly one non-empty `url` key for navigate and an empty object for reload. Hover and scroll are approval-wired but explicitly cardless. Independently, `router.zig:327-332` accepts `options.guard` only for the five DOM mutation verbs and rejects it for navigate/reload. The replacement of the whole `options` object at `agent_broker.zig:709-714` is real, but no current carded call can arrive with options, and no carded DOM-write entry exists.

The change therefore correctly classifies 4pa.64 as **LATENT** rather than falsely authoring an undrivable red or a dead-code green. It preserves the obligation: the bead stays open, and the first slice that adds a carded DOM-write tool may not register without the driven red, merge fix and restore-the-overwrite production mutant. The dependency-order row is also explicitly deferred. `git diff --check b182ff3^ b182ff3` exited 0; the commit changes only the plan.

Non-blocking **SHOULD**: harmonize the superseded prose at the old status table/paragraphs (notably plan lines 591, 2084 and 2282–2284), which still says raw-DOM cards are presently bound only to origin plus `load_serial`. The new, later authoritative erratum explicitly says no raw-DOM cards exist, so this residue is not an R3 block and does not make `b182ff3` unsafe.

## 2026-10-22 — 4pa.59/4pa.77 build-on-Mac GREEN A

### `7173ddd` — exact-commit archive, fresh remote directory, and pinned host keys

**BLOCK; NOT SAFE TO PUSH AS GREEN A.** Judged only against the exact minimum first recorded for red `6074fba`, the production harness is substantially correct: it resolves one commit, archives committed bytes, gives each run a fresh `zb-gate-<sha>-<nonce>` basename, consistently uses `$HOME/$RDIR` for extraction/build/cleanup, routes every SSH call through strict pinned-host options, and traps local plus best-effort remote cleanup. The six pinned entries cover ECDSA, ED25519, and RSA for both named IPs and match the owner's host keys. From an exact clean archive, `zig build test-mac-build-script -j4 --summary all` exited 0, 3/3 steps, with the hostless selftest reporting 16 checks and PASS. No Mac was contacted.

The registered proof does not close the prior minimum. `remote_dirs()` extracts a bare `zb-gate-...` token anywhere in any recorded argv; the run-dir check requires only one such token, and the cleanup check requires only that token plus `-delete` or `rm -rf` somewhere in the last argv. It never binds the extraction, build, and cleanup commands individually to the same exact `$HOME/zb-gate-<sha>-<nonce>` path. A production mutant changing all four remote `$HOME/$RDIR` paths to `/tmp/$RDIR` still exited 0 with `PASS mac-build-script-selftest`. Because this weak oracle is now registered in both `test-mac-build-script` and `zig build test`, the purported proof can stay green when the exact required behavior is broken: an R3 block.

The registered selftest also fails the previously recorded safety condition: its outer `unshare` has user and mount namespaces but no `--net`. The exact unblock remains unchanged: structurally assert that tar extraction, build cwd, and cleanup each name the same exact remote-HOME path; make both the `/tmp`-prefix and unrelated echoed-token mutants fail; and run the registered selftest under network isolation.

No Mac run is approved. Independently of this block, the orchestrator's hold remains correct: this harness may not contact either Mac until GREEN B moves all eight gate callers and `build-dmg.sh` off `$HOME/zigBrowser`, after which any run still requires the exact source commit, SHA-256 of every harness file, and the orchestrator's explicit release.

## 2026-10-22 — Reworked 4pa.60 Red 1 and build-caller Red B

### `1acb699` — injected-binder production profile-step red

**SAFE TO PUSH AS AN UNREGISTERED RED 1 DRAFT; ACCEPTED AGAINST THE RED-TEST PORTION OF THE `5a2b776` MINIMUM.** The test now targets the proposed production-owned `profile_step.applyMacos` seam rather than calling a storage helper directly. Its injected recording binder proves one bind of the exact profile path after that directory already exists; the test also proves the real pacing writer fails before the step, succeeds through the production pacing path afterward, reads its bytes back, tolerates an existing directory, and does nothing for a null profile. Both imports are live and no raw helper bypass remains.

From an exact clean archive, the stated `zig test -lc --dep profile_step ...` command exited 1 specifically because `src/profile_step.zig` does not exist. The file is absent from `build.zig`, so it is a genuine inert red and proves no production behavior yet. The rest of the exact minimum remains for the green: add and wire the production seam from `app.applyProfileDir`, register the test in `zig build test`, preserve directory-before-bind, and record both distinct production mutants. Removing directory creation (whether the primitive or its call inside the seam) is mutant 1; mutant 2 must remove the production `app.applyProfileDir` invocation/delegation and be caught by a driven proof. A second remove-`ensureDir` mutant is not a substitute for that wiring mutant. If the portable test cannot reach that outer delegation, the already-required released Red 2 must catch it before 4pa.60 can close.

### `46e24b1` — all build-on-Mac callers use their fresh run directory

**SAFE TO PUSH ONLY AS AN UNREGISTERED RED B DRAFT; NOT REGISTRATION-READY.** It adds only `tests/mac/mac_gate_callers_selftest.sh` and is absent from `build.zig`. The hostless script executes all seven real Mac gate callers plus `build-dmg.sh` end to end with stubbed SSH/SCP/Python. From an exact clean archive under a network namespace, all eight callers reached their final line, all fifteen expected per-host builds produced a `zb-gate-<sha>-<nonce>` token, and the script exited 1 with 312 intended failures for stale shared paths, work outside the run directory, missing final cleanup, and unpinned caller channels. `bash -n` and `git diff --check` exited 0; no Mac was contacted.

Before GREEN B registers this proof, its oracle must be tightened. C4 presently accepts the run-directory basename anywhere in an SSH argv, so work in another directory plus an unrelated token can pass; C6 accepts a basename plus `-delete` in the final call and does not reject `build-on-mac.sh` deleting the directory before caller work. The exact Green B minimum is: bind every caller work command structurally to the exact `$HOME/zb-gate-<sha>-<nonce>` directory; require every SCP remote path inside that directory; reject any early deletion; require one exact final cleanup after caller work; reject unexpected SSH/SCP hosts rather than skipping their checks; demonstrate shared-path-plus-token and early-delete/fake-cleanup mutants fail; and run the registered test under network isolation. This incorporates the `de1751c` path-oracle minimum already forwarded to BlueHollow.

**Aggregate push status:** the content of `1acb699` and `46e24b1` is safe as unregistered red drafts, but both descend from blocked `7173ddd`. Neither ancestry tip is push-safe as a whole until the GREEN A fix-forward closes `de1751c`. No Mac run is approved.

## 2026-10-22 — GREEN A proof fix-forward

### `4f0b0a2` — exact remote-path oracle and network isolation

**APPROVED; SAFE TO PUSH; CLOSES THE `de1751c` BLOCK.** Judged only against that first exact minimum, the registered selftest now derives the run directory from exactly one anchored extraction command whose `mkdir` and `tar -C` operands are the same exact `$HOME/zb-gate-<sha>-<nonce>` path, proves the archive was supplied to that extraction call, requires exactly one build command beginning in that same exact directory, and requires the last remote command to be the exact cleanup of that path. Its outer registered runner now uses `unshare --user --map-root-user --mount --net`.

Independent clean-archive evidence: `zig build test-mac-build-script -j4 --summary all` exited 0 with 3/3 steps and `PASS mac-build-script-selftest`. Changing every remote `$HOME/$RDIR` path to `/tmp/$RDIR` made the selftest exit 1 with six failures. Replacing the build command with an echoed run-directory token followed by a build in `$HOME/zigBrowser` made it exit 1 with one failure. `git diff --check 4f0b0a2^ 4f0b0a2` exited 0; the commit changes only the registered selftest, not the already-reviewed production harness.

Every other implementation/documentation commit in the ancestry through `4f0b0a2` now has a direct push-safe verdict or a reviewed fix-forward closing its block; `46e24b1` and `1acb699` retain their unregistered-red qualifications. **The ancestry tip through `4f0b0a2` is therefore push-safe as a whole.** No Mac run is approved: GREEN B must still migrate and register all eight callers, and a later Mac request still requires the exact source commit, SHA-256 of every harness file, and the orchestrator's explicit release.

## 2026-10-22 — 4pa.65/4pa.68 store-name/PID red

### `ffcb887` — recovery fixtures carry their entry PID

**APPROVED; SAFE TO PUSH AS AN UNREGISTERED RED DRAFT.** At exact commit `ffcb88744c913493de7a90f633c0fc2b0c368a9b`, all eight build-step owners of the nine edited existing tests passed from a clean archive: grammar 13/13, load 4/4, lock 2/2, parse 10/10, publish 6/6, start-kind 8/8, concrete recovery 29/29, and startup recovery 17/17 (27/27 build steps). The ninth existing file, `agent_run_ledger_recovery_txn_test.zig`, is explicitly unregistered and has no `build.zig` owner; its direct private-PID-namespace run passed 6/6. The new unregistered `agent_run_recovery_store_pid_test.zig` failed 0/3 for the three intended missing production checks.

No assertion or test was removed or weakened. Existing changes are confined to fixture basename/PID alignment, matching expected-basename literals, and two helper generalizations for live-PID fixtures; per-file test and assertion-site counts are unchanged. The residual `DEAD_PID` comment in `agent_run_ledger_recovery_txn_test.zig` names the adjacent exact constant and is non-blocking commentary. `git diff --check` passed; no product/build file changed.

## 2026-10-22 — 4pa.59/4pa.77 build-on-Mac GREEN B

### `cbf5865` — all eight callers use their exact fresh run directory

**APPROVED AGAINST THE `3665306` MINIMUM; SAFE TO PUSH.** All seven Mac gates and `packaging/macos/build-dmg.sh` source the shared helper after entering the repository root, use pinned-host SSH/SCP options, and keep remote work and transfers within the validated per-host `zb-gate-<40-hex-sha>-<nonce>` directory. C4 now structurally binds every heredoc to exactly one `cd "$HOME/${N:?}"` whose positional argument equals that host's discovered run directory, constrains inline `$HOME` paths and `cd`, and delegates remote-copy confinement to C5. C6 identifies every deletion, accepts only the exact shared-helper cleanup of that same directory, and requires exactly one cleanup as the host's last call. No executable `$HOME/zigBrowser` reference remains in the eight callers or helper; the one repository match is explanatory selftest prose.

Independent exact-commit evidence from `cbf58651298b5ee949c175a5fce05b1a29ef8027`: clean-archive `zig build test-mac-build-script test-mac-reaper-gate-guard -j4 --summary all` exited 0 with 7/7 steps and both Mac-build selftests PASS. The callers oracle drove all eight callers and classified 38 gate calls, 23 MS1b calls, eight calls for each MS2a/MS2b/MS2c/MS3/MS4 gate, and six build-DMG calls. `bash -n` and `git diff --check` passed. Independently reproduced mutants all exited 1: shared path plus still-present run token (six C4 failures), echoed token plus shared-path work (two C4 failures), early deletion (30 C6 failures), fake/wrong deleter (15 C6 failures), and a `/tmp`-prefixed work directory (two C4 failures). The recorded shared-home SCP, missing cleanup, and unexpected-host mutants exercise C5, C6, and C2 respectively.

The exact first build-only two-Mac request is technically fit: source commit `cbf58651298b5ee949c175a5fce05b1a29ef8027`, `tests/mac/build-on-mac.sh` SHA-256 `36922e316fa2d866e75da336282dc491e58a76f42a32991f23b6f5681f80fb0b`, and `tests/mac/known_hosts` SHA-256 `15e45024f0e0f9c82743b1095739bf7d8d2c5ab61028255bcae6dc7522595221` independently match the clean archive. This is readiness, **not release**: no Mac may be contacted until the orchestrator explicitly releases that exact request. No Mac was contacted during review.

## 2026-10-22 — 4pa.65/4pa.68/4pa.71 recovery green

### `a2bc627` — caller store, entry PID checks, and registered transaction tests

**BLOCK; NOT SAFE TO PUSH AS THE COMPLETE REV-32 GREEN.** The implemented 4pa.65 and 4pa.68 behavior is correct, and the two tests are genuinely registered. The caller's `sub_path` reaches the load and both retirement publishes; parsing rejects `pid < 2`, a basename/PID mismatch, and PID overflow in the basename. `test-agent-run-recovery-store-pid` and `test-agent-run-ledger-recovery-txn` are attached to the Linux `test` aggregate, and the new transaction launcher preserves the child status.

Exact-commit evidence from a clean archive of `a2bc627ef74588d17b642a6c5537f4e0b8b056c8`, with fd 9 held and an outer private user/PID/mount/proc/network namespace: all 29 `test-agent-run-*` steps exited 0 (`90/90` build steps, `79/79` Zig tests). The new store/PID test passed 3/3, the new registered transaction test passed 6/6, startup passed 17/17, and the manual concrete test passed 29/29. Two older build launchers still mask child status with `; :`; their exact compiled binaries were therefore rerun directly with status preservation and passed 1/1 (busy holder) and 29/29 (concrete recovery).

Independent scratch production mutants were caught: hard-code the authoritative load to `runs.json` (store/PID 2/3, startup 10/17, transaction 3/6); remove low-PID rejection (store/PID 1/3); remove basename/PID equality (store/PID 1/3); and unlock before pin/fixed point (ten consecutive transaction runs each failed 5/6 with two signal phases). The registered green therefore detects the four recorded mutants.

Two authoritative requirements remain missing:

1. Rev-32 I-W3, R30.2 T20, 4pa.71, and dependency-order item 18 require this same green to make `recoverOneUnderLock` and the gated/full startup bypass entries non-public, register the compile-fail caller, and show that a production re-export mutant makes that step fail. At `a2bc627`, `recoverOneUnderLock`, `recoverOneUnderLockP`, `recoverAllAtStartupGated`, `recoverAllAtStartupGatedH`, and `recoverAllAtStartupFull` remain public; no T20 step or re-export mutant exists. The commit message's statement that this is not done does not amend the plan.
2. Rev 32 requires a **deterministic** exact-result two-recoverer proof. The new test forks the children without a rendezvous and uses only a 300 ms sleep inside the first fixed point to make the second overlap. The early-unlock mutant was observed red in every review run, but a sufficiently late-scheduled second child can still miss that window. Passing repetitions do not make a scheduler-timing oracle deterministic.

The first exact minimum is: close I-W3 using a production module/API structure that exposes only the readiness-bound entry, register T20's compile-fail proof and re-export mutant; and replace the sleep-only race with a barrier/handshake (or register an equivalent deterministic production-transaction proof) that forces both recoverers to the relevant boundary and reliably makes the early-unlock mutant produce two signal phases. A plan erratum may replace the I-W3 requirement, but must land before a green is approved. The correct store/PID behavior and registrations may be retained unchanged.

## 2026-10-22 — Mac harness global-cache HOLD

The orchestrator reports that the released build-only run of exact commit `cbf58651298b5ee949c175a5fce05b1a29ef8027` completed on both Macs with rc 0 and PASS, both per-run directories were removed, and the observed `$HOME` snapshots changed only the home directory's own mtime. That successful build observation stands.

**Effective immediately, every further Mac run through `build-on-mac.sh` or any of its callers is ON HOLD.** New evidence shows the harness gives Zig no `--global-cache-dir`, so Zig may read or write its default `$HOME/.cache/zig` outside the reviewed per-run directory. The prior snapshots did not inspect that tree deeply enough to prove confinement. This is the new P0 `zigBrowser-3ui.5` and an R3 safety finding; it supersedes the earlier statement that this harness was fit for another Mac request.

No later Mac run may be approved until a reviewed fix: confines Zig's global cache to the exact fresh `$HOME/zb-gate-<sha>-<nonce>` directory; adds a registered hostless argv test that structurally binds `--global-cache-dir` to that exact run directory; and records a production mutant deleting the flag or redirecting it outside the run directory, with the registered test failing. The usual exact source commit, SHA-256 of every harness file, and orchestrator release remain additional requirements after this hold is cleared.

## 2026-10-22 — 4pa.76 duplicate Secrets symbol red

### `2470871` — Linux/macOS Secrets headers in one translation unit

**SAFE TO PUSH AS AN UNREGISTERED RED TRIPWIRE.** The commit adds only `tests/secrets_window_headers_test.c`; it changes no product or registered gate. The file includes the real Linux and macOS headers in one translation unit. At exact commit `2470871056fcebdb49602cddf60981056ee4da36`, a syntax-only compile exited 1 at the intended conflict: Linux declares `zb_secrets_window_open(void)` while macOS declares `zb_secrets_window_open(unsigned long long)`. In a clean scratch archive, changing only the macOS declaration to the plan's canonical `zb_secrets_window_mac_show` made the same syntax check exit 0.

This matches 4pa.76 Red 1 and is correctly labelled a tripwire, not behavioral proof. The future green may register it only with the rename. Closing MS7.5 still requires Red 2: the renamed production entry must open/focus the real Secrets window and keep it out of the automation registry, with a no-op production mutant failing on both Macs. That run is additionally blocked by the global-cache HOLD above.

`2470871` is safe in isolation as a red draft, but the current ancestry tip is **not push-safe as a whole** because it contains the blocked `a2bc627` complete-green claim.

## 2026-10-22 — 3ui.5 Zig-cache confinement red

### `642e4ed` — every remote Zig invocation names both in-run caches

**SAFE TO PUSH ONLY AS AN UNREGISTERED RED DRAFT; NOT ACCEPTED AS REGISTRATION-READY PROOF OF THE `c6c04b7` MINIMUM.** The test runs the real `build-on-mac.sh` and all eight callers through isolated stub SSH/SCP, discovers each host's exact extraction directory, requires a Zig invocation on every expected host, and checks both `--cache-dir` and `--global-cache-dir`. It is absent from `build.zig`, network-isolated, and changes no product code or registered gate.

From an exact clean archive of `642e4edb09e105ccc407523c25db658007a54c03`, the script exited 1 with the intended 32 Z2 failures: 16 remote Zig invocations, each missing both cache flags. A scratch production fix putting both cache paths beneath the exact `$HOME/zb-gate-<sha>-<nonce>` directory made all nine harness/caller checks pass. Removing the global-cache flag made the test exit 1 with 16 failures; redirecting it to `$HOME/.cache/zig` made it exit 1 with 32 failures.

The current oracle does not yet **structurally bind** the flags to the Zig argv. It searches the whole remote command/heredoc text. A production mutant that removed both real cache arguments but placed the expected strings only after shell `#`—so Zig receives neither—still exited 0 with `PASS mac-zig-cache-isolation-selftest` across all nine checks. This is the same irrelevant-token class the earlier path oracle had to reject.

Before the green registers this test or clears the Mac HOLD, constrain each check to the actual Zig command/argv before any comment or shell control boundary, and record a comment/echo-token mutant that fails. The deletion and outside-run-dir mutants must continue failing. Non-blocking residue: the commit message says 15 remote Zig invocations, but its enumeration and 32 failures correctly total 16. No Mac was contacted; the HOLD remains in force.

## 2026-10-22 — 4pa.76 Secrets symbol green

### `e825cc5` — canonical Mac entry name and registered header compilation

**APPROVED SCOPED; SAFE TO PUSH.** The macOS declaration is renamed to the plan's canonical `zb_secrets_window_mac_show`, while Linux retains `zb_secrets_window_open(void)`. Repository references confirm there is no macOS definition or caller of either the old or new entry yet. The real C compiler now compiles both production headers in one translation unit, and the object is attached to Linux `zig build test` through `check-secrets-window-headers`.

Exact clean-archive evidence at `e825cc54d21ba2daa3a29abefbe879b70355adee`: `zig build check-secrets-window-headers -j4 --summary all` exited 0, 3/3 steps. Restoring the old macOS declaration made that same registered step exit 1 with the intended conflicting-types diagnostic. `git diff --check` passed; the other edited test file changes only its stale symbol-name comment.

Under R1 this is **real compile evidence for the narrow compile contract**—the two production headers coexist and the old declaration breaks compilation—but it remains **only the R30.2 T16 tripwire for product behavior**. It cannot prove that `zb_secrets_window_mac_show` is defined, linked, called, opens/focuses a real Secrets window, or stays outside the automation registry. The commit labels that limit correctly. 4pa.76/MS7.5 therefore remains open for the released both-Mac Red 2 and its no-op production mutant; that run is also subject to the active Zig-cache HOLD.

`e825cc5` is safe in isolation as the name-clash green. The current ancestry tip is not push-safe as a whole because it still contains the blocked `a2bc627` complete-green claim; `642e4ed` also remains only a draft until its structural oracle is strengthened.

## 2026-10-22 — 3ui.5 Zig-cache confinement green

### `6aeee3e` — in-run local/global caches and registered hostless proof

**BLOCK; NOT SAFE TO PUSH AS THE 3ui.5 GREEN; THE `build-on-mac.sh` HOLD IS NOT CLEARED.** The production change itself has the right shape: the sole remote `$ZIG build` in `build-on-mac.sh` sets both `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` and passes both `--cache-dir` and `--global-cache-dir`, with all four values beneath that host's exact `$HOME/zb-gate-<sha>-<nonce>` run directory. From an exact clean archive of `6aeee3e6c4380418fa38e7a7a18f1ec86f0f58f0`, `zig build test-mac-build-script test-mac-reaper-gate-guard -j4 --summary all` exited 0 with 8/8 steps, and `git diff --check` passed.

The eight-caller closure is also correct. `tests/mac/{gate,ms1b_signed_gate,ms2a_gate,ms2b_gate,ms2c_gate,ms3_gate,ms4_gate}.sh` and `packaging/macos/build-dmg.sh` each call `mac_build`; `tests/mac/mac_gate_lib.sh` implements `mac_build` by calling `tests/mac/build-on-mac.sh`. No direct Zig compiler invocation appears in those eight callers, the helper, or the remote Python tests they name. Thus their 16 per-host builds reach Zig only through `build-on-mac.sh`.

The registered oracle still fails the structural minimum recorded for `642e4ed`. It searches the entire remote command/heredoc text for the expected cache strings rather than binding them to the actual Zig argv. In an independent mutant of the exact green, both cache environment assignments and both real flags were removed from the `$ZIG build` command, and the two expected flag strings were appended only after shell `#`; Zig therefore received neither cache path, yet `zig_cache_isolation_selftest.sh` exited 0 and printed PASS for the harness and all eight callers. This is an R3 proof-can-stay-green failure, not a cosmetic test weakness.

The exact fix-forward minimum is to parse or otherwise anchor both cache flags to the executable Zig command before comments and shell control boundaries; the comment/echo-token mutant above must make the registered step fail, while the deletion/env-only and outside-run-directory mutants must remain red. Re-run the registered `test-mac-build-script` step after that proof fix.

Because `6aeee3e` is blocked, **`build-on-mac.sh` and its eight callers may not take Mac run requests again yet**. Even after their proof is repaired, four independent direct-Zig harnesses remain separately held under 3ui.5: `tests/mac/mac_compile_only.sh`, `tests/mac/ms5_setup_e2e.sh`, `tests/mac/ms5_setup_refusal_gate.sh`, and `tests/mac/ms7_appkit_gate.sh`. No request using any of those four may be approved until each confines both caches beneath its own per-run directory and receives the required review. Any later request still needs the exact source commit, SHA-256 of every harness file, and the orchestrator's explicit release. No Mac was contacted during this review.

The current aggregate branch tip is additionally not push-safe because it still contains the independently blocked `a2bc627` complete-green claim.

## 2026-10-22 — 3ui.5 Zig-cache proof fix-forward

### `63721e2` — bind cache flags to the actual Zig argv

**APPROVED; SAFE TO PUSH; CLOSES THE `fe88498` BLOCK ON `6aeee3e`.** Judged only against that exact minimum, the registered oracle now parses the remote command and script with POSIX `shlex`, drops comments, stops each Zig argv at shell control/redirection tokens, and evaluates only the flags on that invocation. Both cache flags must occur in that argv, their separate-argument and `--flag=value` forms are recognized, and every supplied value must remain beneath the exact host run directory. The corrected total is 16 remote Zig invocations.

Independent exact-commit evidence from a clean archive of `63721e2b788a48971cc9b1fa7924026318f60db2`: `zig build test-mac-build-script -j4 --summary all` exited 0 with 5/5 steps, and all 16 invocations across `build-on-mac.sh` plus the eight callers passed. Four independent production mutants each exited 1 with 16 failures: remove the real cache environment and flags but leave both strings after shell `#`; move them after `; echo`; retain only the environment assignments; and move the global cache to `$HOME/.cache/zig`. `git diff --check` passed, and the only committed file change is the registered hostless selftest.

The scoped 3ui.5 HOLD is therefore cleared for **`build-on-mac.sh` and its eight callers**: they may submit Mac run requests again. This is readiness, not a release; every request still requires the exact source commit, SHA-256 of every harness file used, and the orchestrator's explicit release.

The independent direct-Zig harnesses remain held. Static tracing confirms the four already named, and additionally finds `tests/mac/ms5_gate.sh` invoking `zig test` without either cache flag. Thus the held set is now five: `mac_compile_only.sh`, `ms5_setup_e2e.sh`, `ms5_setup_refusal_gate.sh`, `ms7_appkit_gate.sh`, and `ms5_gate.sh`. No Mac was contacted.

## 2026-10-22 — 4pa.71/I-W3 recovery fix-forward

### `6ff2ccc` — production bypass closure, T20, and deterministic recoverer handshake

**APPROVED; SAFE TO PUSH; CLOSES THE `c6c04b7` BLOCK ON `a2bc627`.** Judged only against the three-part exact minimum:

1. `recoverOneUnderLock`, `recoverOneUnderLockP`, `recoverAllAtStartupGated`, `recoverAllAtStartupGatedH`, and `recoverAllAtStartupFull` are file-private in `agent_run_recovery.zig`; the ledger no longer exposes the transaction. Test access is confined to `test_support = if (builtin.is_test) ... else struct {}`. The sole public startup-recovery entry is `recoverAllAtStartup`, whose readiness argument is the immutable `reaper_ready`.
2. Registered Linux step `test-agent-run-recovery-bypass-closed`, also attached to `zig build test`, compiles 13 non-test objects: twelve exact compile-fail bypass probes and one positive control for `recoverAllAtStartup`. Independently changing `recoverAllAtStartupGated` back to `pub` made the step exit 1 because that direct probe compiled.
3. The two-recoverer test no longer uses scheduler sleep. Recoverer A reports arrival and blocks at its fixed point before B is forked; the parent probes the flock, and the free-lock branch waits for B's own arrival before releasing either child. The assertion counts fixed-point arrivals to EOF before checking the exact results. An independent early-unlock mutant failed five consecutive fresh-cache runs at the intended first assertion, each with `expected 1, found 2`.

Clean-archive `6ff2ccc6e3c31f9fd13ddb6227706003427eec26` evidence: the bypass-closed, transaction, store/PID, and startup steps exited 0 with 25/25 build steps and 20/20 tests; the registered transaction was 6/6. `git diff --check` passed. The earlier 4pa.65/4pa.68 findings remain unchanged. With `63721e2` also closing the harness block, the ancestry through `6ff2ccc` is push-safe as a whole.

## 2026-10-22 — direct-Zig Mac harness cache red

### `be883b3` — structural argv oracle for three noncompliant direct paths

**SAFE TO PUSH AS AN UNREGISTERED PARTIAL RED; NOT ACCEPTED AS COMPLETE COVERAGE OF THE FOUR-SCRIPT QUEUE.** The commit adds one unregistered hostless test and changes no product or registered step. It runs the real `ms5_setup_refusal_gate.sh`, `ms5_setup_e2e.sh`, and newly discovered `ms5_gate.sh` against isolated recording SSH/SCP stubs on both modeled hosts. For those six legs it derives the passed run directory, parses each Zig command's own argv with the same comment/control-token boundary as `63721e2`, requires both flags inside that run directory, and requires a non-vacuous Zig invocation. The test re-execs under a private network namespace.

From an exact clean archive of `be883b38f48de85cd0f09f964d6dcf1f5edb5a38`, the script exited 1 with exactly six intended missing-flag failures, one per leg. Adding in-run flags to all three real scripts made it exit 0; replacing the two real flags on `ms5_setup_e2e.sh` with identical strings only after shell `#` made it exit 1 on both of that script's legs. The structural oracle is sound for the paths it drives, and `git diff --check` passed.

The coverage claim is incomplete: the orchestrator named `mac_compile_only.sh` and `ms7_appkit_gate.sh`, but this red explicitly does not execute either. Static source inspection suggests both already pass in-run local/global cache flags, but that is not the required exercising proof and cannot protect them from regression. Before registration or any direct-harness HOLD is cleared, extend the proof to drive all five discovered direct-Zig paths, preserve per-leg non-vacuity, and record missing/outside/comment-or-echo mutants against their actual Zig argv. All five direct harnesses remain held. The aggregate tip through `be883b3` is nevertheless push-safe as an accurately unregistered partial red; no Mac run is approved.

## 2026-10-22 — direct-Zig Mac harness cache green

### `d574edc` — three MS5 paths fixed, but the registered proof still omits two direct paths

**BLOCK AS THE COMPLETE 3ui.5 DIRECT-HARNESS GREEN; THE ANCESTRY TIP IS NOT PUSH-SAFE UNTIL THE FIVE-PATH PROOF IS COMPLETE.** The production changes for the three MS5 paths are correct. `ms5_setup_refusal_gate.sh`, `ms5_setup_e2e.sh`, and `ms5_gate.sh` derive `d="$HOME/${ZB_RDIR:?}"`, set both Zig cache environment variables beneath `d`, and pass both `--cache-dir` and `--global-cache-dir` beneath `d` on the actual Zig argv. The hostless test is now registered under `test-mac-build-script` and `zig build test`; it executes both modeled Mac legs of all three scripts, parses each Zig argv structurally, and enforces non-vacuity.

Independent exact-commit evidence from a clean archive of `d574edc2a25949f12a64bfec02393e9877cc6952`: `zig build test-mac-build-script test-mac-compile-only -j4 --summary all` exited 0 with 8/8 steps. The direct-cache test observed one Zig invocation on each of six MS5 legs and printed PASS. Redirecting `ms5_gate.sh`'s global cache to `$HOME/.cache/zig` made that test exit 1 with the expected two D2 failures. `git diff --check` passed.

The registered test nevertheless explicitly excludes `mac_compile_only.sh` and `ms7_appkit_gate.sh`, contrary to the exact five-path minimum recorded for `be883b3`. Existing tests do not close the gap:

- In an exact-commit scratch tree, changing `mac_compile_only.sh` from `--global-cache-dir "$root/zgc"` to `$HOME/.cache/zig` left registered `zig build test-mac-compile-only` green, 3/3 steps. Its fake Zig parses `--cache-dir` but not `--global-cache-dir`.
- Changing `ms7_appkit_case.py`'s global cache from `d/zgc` to `$HOME/.cache/zig` left all six relevant offline MS7 checker/launcher tests green; the seventh test failed for the commit's pre-existing MS7-red findings, not the cache mutant. That offline file is itself unregistered at this commit and only source-inspects the spawn structure.

Thus static confirmation that both commands currently spell in-run flags is not R1/R3 exercising proof and cannot prevent a cache regression. The exact unblock remains: extend a registered structural-argv test to execute all five direct paths, with per-leg non-vacuity, and make missing, outside-run, and comment/echo-token mutants fail for `mac_compile_only` and MS7 as well as the three MS5 paths.

**3ui.5 HOLD status, harness by harness:**

- `build-on-mac.sh`: **CLEAR / request-eligible** through `6aeee3e` + `63721e2`.
- Its eight callers—`gate.sh`, `ms1b_signed_gate.sh`, `ms2a_gate.sh`, `ms2b_gate.sh`, `ms2c_gate.sh`, `ms3_gate.sh`, `ms4_gate.sh`, and `packaging/macos/build-dmg.sh`: **CLEAR / request-eligible**, because every Zig invocation goes through `build-on-mac.sh`.
- `ms5_setup_refusal_gate.sh`, `ms5_setup_e2e.sh`, and `ms5_gate.sh`: their 3ui.5 production confinement and individual driven rows are **technically green at `d574edc`**, but no run request is approved from the blocked ancestry until the five-path proof fix lands. `ms5_gate.sh` also remains independently non-run-ready because it still uses `StrictHostKeyChecking=no`; clearing the cache issue would not clear that separate safety defect.
- `mac_compile_only.sh`: **HELD**; current code appears compliant, but its registered selftest lets an outside-global-cache mutant survive.
- `ms7_appkit_gate.sh` / `ms7_appkit_case.py`: **HELD**; current code appears compliant, but no registered driven cache-argv proof catches an outside-global-cache mutant.

No Mac run is approved or was performed. Every later request still requires the exact source commit, SHA-256 of every harness file used, and the orchestrator's explicit release.

## 2026-10-22 — 4pa.66 Seatbelt readiness red

### `abf3d00` — cross-language one-fact invariant and readiness pin

**BLOCK AS THE GREEN'S ORACLE; SAFE TO PUSH ONLY AS AN UNREGISTERED RED DRAFT.** The commit changes only three new, unregistered test files. It correctly renders the five production profile shapes, labels the rendered-text check as a tripwire rather than kernel proof, checks comments and free whitespace around bare allows, and keeps the constant pin explicitly classified as T8. From an exact clean archive of `abf3d003e8bed450b542d3f8b4d59a30b1d1d6d3`, the invariant reproduced the intended red: 3/5 passed, with exact failures for missing `agent_setup.seatbelt_gate` and missing `sandbox_macos.PROFILE_CURATION`; the separate pin passed 1/1. No existing registered step is affected.

The central “one fact” oracle is only a one-point value comparison and admits a dishonest green. In an independent scratch mutant, Python defined `PROFILE_CURATION = BROAD` but made `LAUNCH_SPEC_CONSUMABLE` an independent constant-returning function (`return False`); Zig exposed `seatbelt_gate.accepted_commit = null` but kept `seatbelt_ready` independently set to `false`. All five invariant tests and the pin then passed. Both forbidden independent facts merely happened to agree at the current BROAD/unaccepted state, so the claimed state remained representable despite a green test.

Before registration, the minimum is to exercise the derivation in both states rather than inspect one value: temporarily evaluate the Python function with `PROFILE_CURATION` set to BROAD and CURATED and require false then true; compile/run the Zig derivation against both null and non-null accepted-commit fixtures (an injectable gate module or equivalent) and require false then true. Keep the production BROAD/null pin, the profile-text mutant, registration in `zig build test`, and the later released both-Mac kernel-denial proof. Until that fix-forward, `abf3d00` is a useful, inert red draft but does not yet enforce “readiness is one fact.” No Mac was contacted.

## 2026-10-22 — 4pa.66 production green and two-state proof fix-forward

### `57915c3` — production readiness derivations

**PRODUCTION CHANGE APPROVED IN ISOLATION.** `src/agent_setup.zig` no longer owns a hand-set readiness boolean: it imports the new `seatbelt_gate.zig` source fact and defines `seatbelt_ready` as `accepted_commit != null`. The macOS profile side replaces the independent consumability boolean with `PROFILE_CURATION: Curation` and derives `LAUNCH_SPEC_CONSUMABLE()` from equality with `Curation.CURATED`. Current production values remain null/BROAD, so the existing setup consumer continues to refuse macOS execution. Repository-wide reference tracing finds no stale boolean call site: the sole Python consumer is updated to invoke the function, while the sole Zig runtime consumer remains the existing `platformGate` call. The new `enum` import is live; no lower-level operation bypasses an existing readiness abstraction.

Exact clean-archive evidence at `57915c370e832aea16c3312c4d95afc34d0ab6fc`: `test-agent-seatbelt-readiness` plus `cross-check` exited 0 with 29/29 build steps and 6/6 tests; both macOS architectures compiled. `test-agent-setup-ms5` exited 0 with 34/34 steps and 14/14 Zig tests, and the focused production `test_sandbox_macos` suite passed 49/49. `git diff --check` passed. This approves the production mechanism, not the pre-fix-forward oracle that `57915c3` registered.

### `898880d` — exercise both derivation states

**APPROVED AGAINST THE `1915e0d` MINIMUM; CLOSES THE ORACLE BLOCK ON `57915c3`.** The Python facts driver temporarily sets the production module's `PROFILE_CURATION` to BROAD and CURATED, invokes the production `LAUNCH_SPEC_CONSUMABLE()` in each state, and restores the saved value in `finally`; the invariant requires false then true. The Zig test compiles copies of the real `src/agent_setup.zig` and its `xdg.zig` import beside two generated `seatbelt_gate.zig` fixtures, one null and one with a named accepted commit. It requires readiness false/true and the actual macOS platform gate to refuse with the fixed line/run respectively. This is execution of the derivations in both states, not a second one-point comparison.

From an exact clean archive of `898880d178a6f18424a37d872042faa125a29df3`, registered `zig build test-agent-seatbelt-readiness -j4 --summary all` exited 0 with 11/11 steps and 10/10 tests. Independently applying the previously surviving paired dishonest implementation—Python always returns false and Zig hand-sets readiness false—made the same registered step exit 1 with three intended failures: Python's CURATED result, Zig's accepted readiness, and the accepted macOS run gate. `git diff --check` and Python byte compilation passed.

The combined `abf3d00` + `57915c3` + `898880d` 4pa.66 slice is therefore safe to push in isolation. It remains correctly **UNPROVEN** for final D2/security closure until the generated-profile kernel-denial rows and setup-refusal row pass on both Macs under an exact-commit, exact-harness-digest, orchestrator-released run. No Mac was contacted. The aggregate branch tip remains not push-safe because the independent `d574edc` five-path direct-cache proof block is still open.

For queue reconciliation, `63721e2b788a48971cc9b1fa7924026318f60db2` and `6ff2ccc6e3c31f9fd13ddb6227706003427eec26` are **already APPROVED and SAFE TO PUSH** in their earlier sections: the former closes the 3ui.5 structural-argv block for `build-on-mac.sh` plus its eight callers, and the latter closes the 4pa.71 I-W3/T20 and deterministic-handshake block.

## 2026-10-22 — direct-Zig five-path proof and stale-base repair

### `68666db` — drive all five direct Zig paths

**APPROVED AGAINST THE `1915e0d` FIVE-PATH MINIMUM.** The proof need not live in one test file: both owning steps are registered individually and in `zig build test`. The existing structural test executes both modeled-host legs of `ms5_setup_refusal_gate.sh`, `ms5_setup_e2e.sh`, and `ms5_gate.sh`; each leg names its run directory, produces exactly one non-vacuous Zig invocation, and has that invocation's POSIX-shell argv checked before comments and control tokens. Its new MS7 row executes the committed `ms7_appkit_gate.sh` and `ms7_appkit_case.py` through isolated, executing SSH/SCP, `uname`, and Zig stubs; each leg reaches Zig exactly once, and the recorded argv must put both cache flags below that leg's exact `zb-ms7gate-*` directory. The separately registered `mac_compile_only_selftest.sh` executes the committed compile-only harness on both legs, records the argv received by its Zig stub, and requires both cache values beneath the same exact `zb-compile-*` root for that leg. The four MS7 dependencies are also declared as build-step inputs.

Exact clean-archive evidence at `68666dbf26709b8ac51ee8c2d2390822eaf630e9`: `zig build test-mac-build-script test-mac-compile-only test-agent-seatbelt-readiness -j4 --summary all` exited 0 with 14/14 steps and 7/7 tests. The direct-cache row observed one Zig call on each of the six MS5 legs and each of the two MS7 legs; compile-only printed the two intended per-leg cache assertions. Independent production mutants were red: moving compile-only's global cache to `$HOME/.cache/zig` made `test-mac-compile-only` exit 1 with both leg assertions failing; removing MS7's real cache flags while retaining their text only after Python `#` made `test-mac-build-script` exit 1 with both M2 assertions failing. That second mutant simultaneously proves missing flags and inert comment tokens do not satisfy the oracle. The unchanged MS5 parser stops at shell comments/control tokens; the previously recorded missing, outside-run, comment, and `; echo` mutants remain applicable. The commit's recorded missing/comment/outside mutants for both newly driven paths agree with the independently exercised branches of their actual-argv checks.

`68666db` **was not push-safe alone**: its stale `build.zig` deleted all 23 lines registering `898880d`'s two-state Zig seatbelt derivation. The exact-commit readiness step fell from 11/11 steps and 10/10 tests to 7/7 and 7/7; worse, independently hand-setting `seatbelt_ready = false` still exited 0. That unrelated R3 regression required the following fix-forward.

### `075658c` — restore the deleted two-state registration

**APPROVED; THE ANCESTRY THROUGH `075658c47473084dd5f663390e22d49d4b11b7ad` IS PUSH-SAFE AGAIN.** This commit restores the exact 23-line `seatbelt_derivation_module` fixture/import/run/dependency hunk from `898880d` and changes no other file. `git diff 898880d 075658c -- build.zig` contains only `68666db`'s intended four MS7 input additions. From a clean archive of the restored tip, `zig build test-agent-seatbelt-readiness test-mac-build-script test-mac-compile-only -j4 --summary all` exited 0 with 18/18 steps and 10/10 tests. Reapplying the dishonest `seatbelt_ready = false` mutant made the registered readiness step exit 1, 8/10 tests, at both accepted-state assertions. Thus `075658c` closes the stale-base regression without changing the approved cache proof.

**3ui.5 HOLD status after `63721e2` + `68666db` + `075658c`:**

- `build-on-mac.sh` and its eight callers (`gate.sh`, `ms1b_signed_gate.sh`, `ms2a_gate.sh`, `ms2b_gate.sh`, `ms2c_gate.sh`, `ms3_gate.sh`, `ms4_gate.sh`, and `packaging/macos/build-dmg.sh`): **cache HOLD CLEAR; request-eligible**.
- `ms5_setup_refusal_gate.sh` and `ms5_setup_e2e.sh`: **cache HOLD CLEAR; request-eligible**.
- `mac_compile_only.sh`: **cache HOLD CLEAR; request-eligible**.
- `ms7_appkit_gate.sh` / `ms7_appkit_case.py`: **cache HOLD CLEAR; request-eligible**.
- `ms5_gate.sh`: **3ui.5 cache HOLD CLEAR, but still HELD / not request-eligible** because its independent `StrictHostKeyChecking=no` / `UserKnownHostsFile=/dev/null` defect remains open.

“Request-eligible” is not a release. Every Mac run still requires the exact source commit, SHA-256 of every harness file used, and the orchestrator's explicit release. No Mac was contacted during this review.

## 2026-10-22 — MS5 pinned-transport red

### `f2ccdfd` — strict pinned host keys, BatchMode, and no display

**SAFE TO PUSH AS AN UNREGISTERED RED.** Exact commit `f2ccdfd05905403194f52f081f35b3db816fb3e7` adds only `tests/mac/ms5_gate_hostkey_selftest.sh`; it changes no product file, build registration, or existing test. The selftest launches the committed `ms5_gate.sh` from a scratch repository inside a private user/network namespace, with display variables deliberately set, and records every SSH/SCP argv and environment. It requires strict checking to be present and exclusively `yes`, exactly one `UserKnownHostsFile` naming the scratch repository's copied `tests/mac/known_hosts`, `BatchMode=yes`, `IdentitiesOnly=yes`, no `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY`, only the two configured hosts, and a non-vacuous SSH plus SCP on each host with the final both-arches PASS line.

From a clean archive of the exact commit, the script exited 1 after reaching the gate's end and all six transport calls. It produced exactly 18 intended failures: H1, H2, and H4 on each of three Intel and three arm64 SSH/SCP calls; H3, H5, and H6 already held. A scratch-only compliant change using `StrictHostKeyChecking=yes`, the exact repository pinned file, and `env -u` around both transport arrays made the same oracle exit 0 with PASS. `bash -n` and `git diff --check` passed. The test neither imports unused code nor substitutes a helper for the real gate.

This test deliberately proves transport argv/environment, not a real host-key handshake; the six reviewed fingerprints in `tests/mac/known_hosts` remain the separate content proof. The green must register this file, declare the gate and pinned file as inputs, and retain mutants for strict checking, the known-hosts path, BatchMode/IdentitiesOnly, display stripping, host scope, and per-leg non-vacuity. Until that green is reviewed, `ms5_gate.sh` remains held for its independent transport defect even though its 3ui.5 cache hold is clear. No Mac was contacted.

## 2026-10-22 — first runtime-reds two-Mac run request

### `d385bf79` — new `ms_runtime_rows_gate.sh` and exact run request

**BLOCK THE MAC RUN REQUEST; DO NOT CONTACT EITHER MAC.** The exact requested source is `d385bf79dafd15673f7dff5fb6a7592ad9db893d`. Its four submitted local harness hashes and ten submitted remote-file hashes match the exact commit, but the manifest is incomplete: `automation_core_test.py` imports `automation_fixture_server.py` and `slice2_common.py`, and the routed test imports the former directly. The omitted exact hashes are `b7d5a29aa57164737a803f3af026c6aa4a1ce9fbbecae13808bfb056ee5838f4` for `tests/e2e/automation_fixture_server.py` and `8248c9e5fb53ba8aeb72c72c59c4e4ccca07c631066ed04f86678b073588ac66` for `tests/e2e/slice2_common.py`. Both must be included in the corrected request.

The runner's transport/build shell is sound in isolation: it uses `mac_gate_lib.sh`, the exact archived commit, pinned SSH, per-run Zig caches, and final exact-run-directory cleanup. From a clean archive, `env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ... zig build test-mac-build-script -j4 --summary all` exited 0 with 6/6 steps and the new caller produced the expected two modeled-host legs. Replacing its remote `cd "$HOME/${1:?}"` with `cd "$HOME/shared-runtime-rows"` made the same registered step exit 1 with six C4 failures. Thus the caller selftest really executes the new runner even though `build.zig` does not list that runner as an explicit file input. `git diff --check` passed.

The requested live execution nevertheless violates two hard safety rules with zero exceptions:

- The runner does not set a private remote `HOME`/XDG root or an in-run `TMPDIR`. Every row uses `tempfile.TemporaryDirectory`, so on macOS those trees default to the account's `/var/folders/...`, outside `$HOME/$MAC_RDIR`. Worse, the two green controls launch zigBrowser with the inherited owner `HOME` and without any explicit `--profile-dir`, directly violating the private-HOME/profile rule.
- The profile-using rows do not confine WebKit state to their apparent profile paths. The exact shim maps `--profile-dir` to `+[WKWebsiteDataStore dataStoreForIdentifier:]`, whose persistent store is WebKit-managed outside the run tree; the request itself acknowledges that every fresh identifier leaves a store under the account Library. Accepting that write or deleting it afterward is not allowed by “write only under a fresh per-run directory.” The corrected harness must prevent the outside write, for example by a reviewed e2e-only `nonPersistentDataStore` selection while retaining the explicit profile path for application-owned pacing state; cleanup after writing outside is not sufficient.

Minimum before another request: export private `HOME`, `TMPDIR`, and XDG directories created beneath the exact remote run root; make every browser launch, including both controls, use that private environment and an explicit in-run `--profile-dir`; prevent the persistent WebKit store from writing outside the run root and cover that e2e-only choice plus its inert production state; include every imported harness file in the SHA-256 manifest; and make the runner reject a wrong-shaped red rather than treating any non-precondition `FAIL` as success. The corrected hostless proof must retain the existing wrong-directory mutant. No Mac was contacted.

For the corrected request, the accepted result on **each architecture** is:

- `mac_ms2a_routed_test.py`: rc 0 and exact `PASS\tms2a-routed-commands` control.
- `mac_ms2a_user_nav_failure_test.py`: rc 0 and exact `PASS\tms2a-user-nav-failure`; the page-initiated failed navigation must actually make the current red browser exit.
- `mac_ms2a_load_fail_no_quit_test.py`: rc 1 and exact `FAIL\tms2a-load-fail-no-quit`; rows 1 and 2 each record exactly one matching `LOAD_FAIL` then fail because the browser exited rc 5; row 3 must show `/attach` was requested, exactly one matching `/attach` `LOAD_FAIL`, and the same rc-5 exit; row 5 must print `PASS\trow5-initial-load-exits`. A row-3 result of `LOAD_FAIL rows = 0` is **not accepted**; it triggers the plan's fallback to a different failing response.
- `mac_ms2c_recover_slow_server_test.py`: rc 1 and exact `FAIL\tms2c-recover-slow-server`; every recovery precondition holds, at least one reload request is held, and the browser exits rc 8 about 15 seconds after the reload.
- `mac_ms2c_close_button_test.py`: rc 1 and exact `FAIL\tms2c-close-button`; the `NATIVE_CLOSE` seam fires and all five assertions run, with the current defect specifically leaving the popup listed, allowing `page.title` instead of `no_window`, and ending with `WINCOUNT` 2, while the live-job, opener, and browser-survival assertions pass.
- `mac_ms2b_dialog_popup_id_test.py`: rc 1 and exact `FAIL\tms2b-dialog-popup-id`; all popup/confirm preconditions and four assertions run, with the dialog listed under window-2 rather than stable window-3, window-3 reported closed, response to the listed id returning `no_window`, and the page confirm not returning true.
- `mac_cookie_timeout_test.py`: rc 1 and exact `FAIL\tms3-cookie-timeout`; hook 15 fires for getAll/set/delete and all seven assertions run, with each call returning success rather than `action_timeout` at about 12.5 seconds (at least 11.5 seconds), while jobs return to baseline and the browser survives.
- `mac_profile_pacing_persist_test.py`: rc 1 and exact `FAIL\tms3-profile-pacing-persist`; the default-cap precondition and both assertions run, run 1 has no pacing file and logs the save failure, and run 2 returns the default rather than 7.

Any `PRECONDITION`, missing-binary result, missing assertion count, different failure shape, or absent exact terminal tag is not an accepted red.

## 2026-10-22 — runtime-row confinement fix-forward and ephemeral WebKit store seam

### `4cf83b0` — hook 16 production seam is sound, but its inert proof is absent

**PRODUCTION SEAM APPROVED IN ISOLATION; BLOCK AS A COMPLETE `fe4542e` PROOF.** `src/wkwebview_shim.m` gates `ZB_DEBUG_EPHEMERAL_DATA_STORE` behind the existing `zb_auto_test_hooks_enabled()` predicate, which itself requires an active application with `e2eProtocol`. When both gates hold, the profile resolver selects one shared `+[WKWebsiteDataStore nonPersistentDataStore]` before creating windows and marks resolution complete. When the variable is unset—or when it is set without `--e2e-protocol`—the helper returns false. The reordered early returns then preserve the old behavior for all combinations of `g_profile_dir` and `g_profile_resolved`: no store is selected for a missing profile, while an explicit profile still takes the prior persistent-identifier path. The new active test is meaningful: two e2e launches use the same nominal profile, require the hook marker once per launch, write/read a cookie in the first launch, and require it absent in the second.

The requested inert row and guard-drop proof do not exist at either `4cf83b0` or the ancestry tip. `tests/e2e/mac_ms2a_hook_inert_test.py` still drives only the original four hook variables; neither it nor another registered test mentions hook 16. Independently deleting only `if (!zb_auto_test_hooks_enabled()) return NO;` from an exact `4eca1aa` scratch archive left registered `zig build test-mac-build-script -j4 --summary all` green, 7/7. Thus the current registered proof accepts the production guard-drop mutant. The narrow minimum is to drive `ZB_DEBUG_EPHEMERAL_DATA_STORE=1` without `--e2e-protocol`, require that no ephemeral-store behavior/marker occurs and that all resulting WebKit data remains confined, register that row in the eventual runner, and demonstrate that dropping only the guard makes the test red. Retain the active two-launch isolation test. No Mac was contacted.

### `4eca1aa` — confinement is corrected, but wrong-shaped reds still match

**BLOCK AGAINST `fe4542e`; THE ANCESTRY TIP IS NOT PUSH-SAFE AND IS NOT MAC-RUN-REQUEST-ELIGIBLE.** The confinement changes themselves meet the requested minimum: the exact remote run directory owns private `HOME`, `CFFIXED_USER_HOME`, `TMPDIR`, all XDG roots, the protocol socket directory, and every explicit profile path; every red launch now enables e2e protocol plus the non-persistent store hook. The gate retains pinned transport, exact archived source, per-run Zig caches, and exact-directory cleanup. Its hostless V1–V6 proof executes the extracted remote leg and rejects a missing expected line, precondition result, red that turns green, missing green control, skipped row, or environment path outside the run root. From an exact clean archive, the registered `test-mac-build-script` step passed 7/7; the submitted wrong-`cd`, `/tmp` environment/socket, missing-hook, and missing-required-line mutants exercise real branches. All changed Python files byte-compile, and both diffs pass `git diff --check`.

However, the row matcher still proves only selected substrings, not the full accepted failure vector required by `fe4542e`. Most decisively, the load-fail row requires row 1 rc 5, row 2 rc 5, and row 5 PASS, but requires nothing from row 3. In an independent direct run of the exact extracted leg, a fake result with `row3-undisplayable-response: LOAD_FAIL rows for the failing load = 0, want 1`, terminal `FAIL`, and rc 1 was reported as `MATCH` and made the leg exit 0. That is the exact wrong shape previously forbidden: row 3 zero must trigger the fallback, not qualify the red. The same subset-only defect lets the close row tolerate failures in assertions 3/4, the dialog row omit failure 4, and the cookie row tolerate an unexpected live-job/browser-survival failure.

Before a new run request, make every red matcher enforce the complete accepted vector and reject additional/missing assertion failures. A robust shape is a canonical per-test `RED_SHAPE\t<id>` emitted only after the test itself verifies every precondition, assertion count, expected failure, and expected pass; the runner must require it. At minimum, add hostless mutants for row 3 with zero matching `LOAD_FAIL` rows and for an extra unexpected assertion failure, and make both fail. The eventual request must also include the SHA-256 of every local runner/helper and every remotely executed or imported test file. The hook-16 inert/guard-drop minimum above remains open. No Mac was contacted.

## 2026-10-22 — MS5 pinned-transport green

### `9e66953` — pinned keys land, but `SSH_ASKPASS` is not unset

**BLOCK; `ms5_gate.sh` REMAINS HELD AND THE ANCESTRY TIP IS NOT PUSH-SAFE AS THE TRANSPORT CLOSURE.** The production change correctly replaces `StrictHostKeyChecking=no` and `/dev/null` with `StrictHostKeyChecking=yes`, the repository's pinned `tests/mac/known_hosts`, `BatchMode=yes`, and `IdentitiesOnly=yes` on every SSH/SCP call. It strips `DISPLAY`, `WAYLAND_DISPLAY`, and `XAUTHORITY`, remains fail-closed when the arm host is absent, and its registered selftest is non-vacuous on both modeled hosts. The `build.zig` hunk only adds the new registered step and declares the selftest, gate, and pinned file as inputs.

Exact clean-archive `zig build test-mac-build-script -j4 --summary all` exited 0 with 7/7 steps, including six recorded transport calls and the direct-Zig cache proof. The submitted strict-mode, known-hosts-path, BatchMode, display, and duplicate-option mutants are consistent with the exercised parser. `git diff --check` passed.

However, hard safety rule line 60 requires `SSH_ASKPASS` itself to be unset for every command. `9e66953` only exports `SSH_ASKPASS_REQUIRE=never`; both transport arrays use `env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY` and therefore pass any inherited `SSH_ASKPASS` through. The registered test neither poisons nor records that variable. In an independent scratch extension that launched the gate with a poison `SSH_ASKPASS`, recorded it, and required it absent, the exact production code exited 1 with six failures—one for every SSH/SCP call—while still reaching the gate's end.

Narrow fix-forward minimum: add `-u SSH_ASKPASS` to both the SSH and SCP command environments; extend the registered H4 row to launch with all four variables set, record all four, and require all four absent on every call; retain `SSH_ASKPASS_REQUIRE=never`, the existing six transport guarantees and mutants; and add a mutant dropping only `-u SSH_ASKPASS` that makes the registered step red. Judge the fix-forward only against this minimum. The 3ui.5 **cache** hold on `ms5_gate.sh` was already clear and remains clear; the separate transport hold remains, so the harness is still not request-eligible. The disclosed `ms5_setup_refusal_gate.sh` and `ms5_setup_e2e.sh` reliance on the operator's unversioned known-hosts file is also a separate reproducibility finding and is not cleared by this commit. No Mac was contacted.

## 2026-10-22 — MS5 SSH_ASKPASS fix-forward

### `30a7836` — complete the four-variable transport boundary

**APPROVED AGAINST `fe4542e`; `ms5_gate.sh` LEAVES EVERY KNOWN HOLD, AND `zigBrowser-3ui.5` MAY CLOSE.** Exact commit `30a7836555438b6fc09672335ce27360d56f6b8d` adds `-u SSH_ASKPASS` to the shared argv builders used by every SSH and SCP invocation while retaining `SSH_ASKPASS_REQUIRE=never`, pinned `known_hosts`, strict host checking, `BatchMode=yes`, and `IdentitiesOnly=yes`. The already registered H4 oracle now poisons all four environment variables, records all four in each transport stub, and requires all four absent. It still drives the real gate to its final both-architecture PASS and observes four SSH plus two SCP calls across both modeled hosts, so the check is not vacuous. The changed shell has no new import, unused helper, raw transport bypass, or wrong abstraction; it extends the existing centralized option builders.

From a clean archive of the exact commit with private HOME/TMPDIR/XDG roots, `zig build test-mac-build-script -j4 --summary all` exited 0 with 7/7 steps, including `PASS mac-ms5-gate-hostkey-selftest`; `bash -n` and `git diff --check` passed. Independently retaining `SSH_ASKPASS` in both option builders made that registered step exit 1 with six H4 failures and 5/7 steps. Retaining it only for SSH made the direct selftest exit 1 with four H4 failures; retaining it only for SCP exited 1 with two H4 failures. In every mutant the other three variables remained absent, which isolates the requested guard.

This clears both the prior 3ui.5 cache hold and the separate transport hold on `ms5_gate.sh`; that harness is request-eligible, subject to the normal exact-commit, complete SHA-256 manifest, reviewer approval, and orchestrator release rule. The parent cache issue `zigBrowser-3ui.5` has met its stated closure condition and may close. Its open child `zigBrowser-3ui.5.1` remains a separate reproducibility defect: `ms5_setup_refusal_gate.sh` and `ms5_setup_e2e.sh` remain held until they use reviewed pinned transport. That child does not re-hold `ms5_gate.sh` or the completed cache issue. The aggregate branch tip still has the unrelated `4cf83b0`/`4eca1aa` runtime-row proof blocks recorded above; this approval is intentionally limited to `fe4542e`. No Mac was contacted.

## 2026-10-22 — setup-harness pinned-transport red

### `dc0f3b4` — drive both MS5 setup scripts through H1–H6

**SAFE TO PUSH AS AN UNREGISTERED RED.** Exact commit `dc0f3b4634188944ae51b58715d20c4c4072f9df` adds only `tests/mac/ms5_setup_hostkey_selftest.sh`; `build.zig` and every existing source/test are unchanged, and repository search confirms that no registered step references the new file. The oracle copies and executes the two real setup scripts in a scratch repository inside a private user/network namespace, poisons `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, and `SSH_ASKPASS`, and records the argv/environment received by every SSH/SCP stub. For each script it enforces strict checking, exactly the repository's copied `known_hosts`, BatchMode/IdentitiesOnly, all four variables absent, the two configured hosts only, a non-vacuous SSH and SCP on each host, and the script's terminal both-architecture PASS control. The parser accepts both supported `-o Key=Value` forms and checks every supplied value, so an appended weaker option cannot hide behind an earlier secure one. The new shell has no imports, dead helper, product-operation bypass, or substitute source-text check.

From a clean archive with private HOME/TMPDIR/XDG roots, the new test exited 1 after both scripts reached their terminal controls and all twelve transport calls ran. It reported exactly 24 intended failures: H2 (no pinned `UserKnownHostsFile`) and H4 (inherited `SSH_ASKPASS`) on each call; H1, H3, H5, and H6 already held. A scratch-only compliant change adding the exact copied pinned file and `-u SSH_ASKPASS` to both SSH/SCP arrays made the same test exit 0 with PASS. The exact commit's registered `zig build test-mac-build-script -j4 --summary all` remained green, 7/7; `bash -n` and `git diff --check` passed.

The green must update both scripts' SSH and SCP arrays, retain `SSH_ASKPASS_REQUIRE=never`, register this test in `test-mac-build-script` and the main test step, and declare the selftest, both target scripts, `known_hosts`, and `lib_group_cleanup.sh` as inputs. Retain per-script mutants for a missing/wrong pinned path and retained askpass on each transport, plus the existing H1–H6 guarantees. Until that green is reviewed, `ms5_setup_refusal_gate.sh` and `ms5_setup_e2e.sh` remain held; `ms5_gate.sh` remains clear. No Mac was contacted.

## 2026-10-22 — setup-harness pinned-transport green

### `f5457bf` — close the two remaining setup transport holds

**APPROVED AGAINST `dc0f3b4`; SAFE TO PUSH FOR THIS SLICE, AND `zigBrowser-3ui.5.1` MAY CLOSE.** Exact commit `f5457bf22ff815066d8252f02f7f2dc9446fc256` updates both `ms5_setup_refusal_gate.sh` and `ms5_setup_e2e.sh` so every SSH/SCP argv unsets `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, and `SSH_ASKPASS`, retains BatchMode/IdentitiesOnly plus strict checking, and supplies `UserKnownHostsFile="$PWD/tests/mac/known_hosts"` after each script has changed to the repository root. `SSH_ASKPASS_REQUIRE=never` remains. This is the same appropriate transport abstraction as the reviewed Mac gate; no call bypasses either script's centralized arrays, and there are no imports or dead helpers.

The red selftest is registered under both `test-mac-build-script` and the main test step. Its declared inputs include the selftest, both target scripts, `known_hosts`, and the copied `lib_group_cleanup.sh`, so every relevant byte invalidates the step. From a clean archive with private HOME/TMPDIR/XDG roots, registered `zig build test-mac-build-script -j4 --summary all` exited 0 with 8/8 steps and both setup rows observed all twelve non-vacuous calls. Removing only the refusal script's pinned-file options made that registered step exit 1 with six H2 failures and 6/8 steps. Independent direct mutants produced six isolated failures apiece for refusal retaining askpass, e2e retaining askpass, and e2e using `/dev/null`; the other script remained green in every case. `bash -n` and `git diff --check` passed.

The 3ui.5.1 pinned-host/askpass transport hold is therefore clear for both setup scripts, and the issue may close. `ms5_setup_refusal_gate.sh` is request-eligible under the normal exact-commit, complete SHA-256 manifest, reviewer approval, and orchestrator release rule. `ms5_setup_e2e.sh` has the same transport clearance, but its own documented feature prerequisites still govern whether it is armed; this review does not turn a `NOT ARMED` run into a pass. The aggregate ancestry still carries the unrelated runtime-row proof blocks recorded above. No Mac was contacted.

## 2026-10-22 — MS1.4 two-host gate fail-closed green

### `d32d26b` — require recorded assertions and a passing build's run directory

**APPROVED AGAINST RED `8910fa8`; SAFE TO PUSH FOR THIS SLICE.** Exact commit `d32d26b83c331831c3bc06c7cca2bfc936b8f5e4` makes each host leg prove the remote M9 render, reply-channel, load-fail, and execution-architecture contracts by their own line-start records, and makes the universal test emit exactly `PASS<TAB>mac-universal<TAB><N >= 1> assertions`. Both captured commands retain their exit status through `pipefail`; therefore a PASS line followed by failure cannot qualify. `run_dir_of` admits only the fresh `zb-gate-<40-hex-sha>-<hex-nonce>` recorded after that host's successful `mac_build`, checks both hosts before universal assembly, and is required again before each verification leg. The callers selftest's SSH stub was updated only to model the newly required successful remote records.

The hostless proof is registered as `test-mac-gate-selftest`, also belongs to `zig build test`, and declares the real gate, shared builder/library, pinned host file, and exercised local oracles/manifest as inputs. Its healthy control requires two leg PASS lines followed by the final gate PASS. On each modeled host it drives no-GUI, missing-SDK, zero-M9, silent-universal, zero-count, M9-PASS-then-fail, and universal-PASS-then-fail cases; it also drives wrong architecture on arm and the missing-arm-host refusal. Every failure row requires the gate's own rc 1, rejects common shell-crash signatures, rejects a final gate PASS or failing-leg PASS, and cannot turn a SKIP into green.

Exact evidence: the unregistered red at `8910fa855e7d10bf09f4b6c53d6b82e3ad4176da` exited 1 with 18 intended failures. From a clean archive of the green with all display/askpass variables unset and private HOME/TMPDIR/XDG cache, `zig build -j4 test-mac-gate-selftest test-mac-build-script --summary all` exited 0, 10/10 steps. Independent production mutants removing the M9 line requirements, accepting a zero universal count, ignoring the M9 exit, and ignoring the universal exit each made the final selftest exit 1 with six failures. `git diff --check` passed.

The disclosed G4 variant—turn a failed build into a SKIP plus return 0 while retaining `run_dir_of`—is semantically acceptable to this requirement: the gate still exits 1 before assembly or either leg, so it is not SKIP-to-green. Its paired guard-removal mutant is red, which establishes that the new run-directory guard is the fail-closed boundary. This approval does not clear the unrelated `4cf83b0`/`4eca1aa` runtime-row proof blocks elsewhere in the ancestry. No Mac was contacted.
