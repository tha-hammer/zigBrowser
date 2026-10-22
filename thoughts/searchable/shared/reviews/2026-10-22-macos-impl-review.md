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
