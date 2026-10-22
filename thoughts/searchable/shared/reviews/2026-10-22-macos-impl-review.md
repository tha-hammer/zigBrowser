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
