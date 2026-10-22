---
date: 2026-10-22
reviewer: NavyCanyon (cod_1)
role: Windows implementation reviewer; no product-code authoring
plan: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md
plan_rev: 2.21
status: active
standards:
  - R1 — behavior proof versus source tripwires
  - R2 — one exact minimum
  - R3 — blocking threshold
  - R4 — lightweight compile-only Mac feedback
  - Verification rule — prove it by running it (owner, 2026-10-22)
---

# Windows Implementation Review Log

## Review standards: R1–R4 and the plan verification rule

This log applies RoseCat's owner-approved R1–R4 review policy and the plan's binding top-level section, **“Verification rule: prove it by running it (owner, 2026-10-22).”** The latter overrides looser wording elsewhere in the plan.

- **R1 — behavior proof versus source tripwires.** Runtime behavior is accepted only from a driven test of the production seam or a bounded real-platform run. Source checks may pin architecture but are tripwires only.
- **R2 — one exact minimum.** The first BLOCK states the complete minimum. Later rounds are judged only against that minimum unless new evidence establishes an R3-class defect.
- **R3 — blocking threshold.** BLOCK only for a product defect, a safety/security risk, a red registered gate, or purported proof that cannot fail when the claimed behavior is broken. Other strengthening ideas are SHOULDs.
- **R4 — lightweight compile-only Mac feedback.** This is a separate, non-runtime tier: exact clean source commit, unchanged reviewed harness digest, both Mac architectures, compile/link only, bounded non-persistent scratch, and complete commit/host/compiler/artifact reporting. It cannot prove runtime, containment, Keychain, UI, or owner-visible behavior. It is not a substitute for any Windows platform run.
- **Plan verification rule.** Each behavior must exercise the real production entry point; use a registered test; show red, green, and a production-code mutant; run platform code on the named platform; treat source checks as tripwires; prove production wiring; fail on skip/exit 77/zero asserts; record commands, exit codes, and exact commits; and name the entry point, test plus `build.zig` step, mutant, and platform run.

For Windows host evidence, approval is bound to one exact source commit and the reviewed harness digest. A host run also requires the orchestrator's release and the host's free gate slot. This reviewer will name the exact SHAs safe to push; approval of one commit does not extend to later bytes.

## Session initialization

- Read the reviewer brief in full.
- Read plan rev 2.21, its REVIEW, and its RULE-AUDIT in full.
- Registered with Agent Mail as `NavyCanyon` for `/home/maceo/ntm_Dev/zb-windows-impl-2026-10-22-15-03`.
- No product code written and no Windows host contacted.
- Awaiting review requests.

## WS2b.0 review — `179a08c76f5fbb9e95fdce1b7dd597767ad687f9` red

**Verdict: APPROVED as the first, portable red; BLOCK transition to WS2b.0 green until the complete minimum below is present.** This approval does not call the WS2b.0 red complete and does not approve a host run or a later source commit.

The commit adds only the unregistered `tests/wv2_capabilities_test.zig`. It drives the production `adapterCapabilities(.webview2)` entry point, expects `input.mode` to be `unproven`, and guards the existing WebKitGTK/WKWebView modes. It has no dead import or source-text oracle. In a clean scratch export of the exact commit, with display and askpass variables unset, the documented command exited 1 for the intended reason: one guard passed; the WebView2 assertion expected `unproven` and found `cdp_input`. Because it is unregistered, it does not make a green gate red.

The orchestrator has ruled that the plan's named `capabilities` RPC is implementation scope for WS2b.0, not a prerequisite owned by another slice. The RPC must be token-checked and must read the production capability table. The unsupported assertion that `network = supported` is a separate correction under `bd zigBrowser-ong.7`; this review does not accept it as proven and does not add its correction to WS2b.0.

### First BLOCK: complete exact minimum for WS2b.0

1. Add the still-unregistered Windows e2e red named by the plan. It must start the real executable with `--automation-api`, use the real socket/token sidecar, and show that a missing or wrong token is rejected before method dispatch while the correct token reaches `capabilities` and currently receives `-32601 Method not found`. The portable red above is only one half of rule 9(b).
2. Green must add the `capabilities` dispatch only behind the existing socket envelope/authentication path. With the correct token it must serialize `input.mode` from the production `adapterCapabilities` result for the executable's actual backend; it may not duplicate or hard-code `unproven`. Missing and wrong tokens must remain authentication failures. The response's network field, if exposed, remains unproven here and cannot be claimed by this slice.
3. Register the Zig test as `test-wv2-capabilities` in `zig build test` and the real-executable e2e as `windows-capabilities-live` in the fail-on-skip `windows-live` aggregate. A hostless product-gate invocation must fail rather than return skip/77/zero assertions.
4. Record green and production-mutant evidence: restoring WebView2 input to `cdp_input` must fail both registered halves, which proves the RPC reads the table; an auth-bypass mutant must fail the missing/wrong-token case. Updating the existing fake-backed P3.1 assertion is only a tripwire and cannot substitute for either driven half.
5. The RPC half remains unproven until a bounded Win11 VM run at a reviewer-approved exact source commit and unchanged reviewed harness digest records the command, exit code, nonzero assertions, host identity, and cleanup. No host approval is granted by this entry.

This is the complete R2 minimum. Later review rounds will not add preferences unless new evidence establishes an R3 defect.
