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

## WS0.9 review — `ea4ccaa49ea354b23e4005bd14ca9a6504175a87` red

**Verdict: APPROVED as an unregistered red.** No Windows host run or later green commit is approved by this verdict.

The commit adds only `gate_product_run_red_test.py` and `live_step_skip_test.py`, both outside every build step. The first drives the real `gate.sh` against isolated fake hosts and fake live tests. The second uses a labelled source lookup only to locate each registered command, then executes all ten commands with and without `ZB_WIN_GATE=1`; the executions, not the lookup, are the proof. Imports are live and the tests leave the registered suite green.

I reproduced both reds in a clean archive of the exact commit with display/askpass variables unset and no host variables. The product-run script ran 11 cases and exited 1 with ten intended failures (`--product` absent/no-argument product mode absent); its existing unset-host guard passed. The live-step script exited 1 because all ten gate-mode commands returned 0 with unittest skips; its standalone clean-skip guard passed.

The four proposed green design choices are accepted: one phase list consumed by product mode and the `windows-live` construction; a shared unittest helper that turns skip/zero assertions into gate failures; `slice2_common.gate_skip_exit` returning 1 under the gate and 77 standalone; and distinct gate variants while plain `zig build test` remains hostless-green. These approvals are conditional on the helper counting executed assertions rather than source text, and on the green refreshing coverage for every live step that exists at that commit, including concurrently added steps.

### WS0.9 green review contract

The green review will require the red cases moved into the plan-named registered steps; no-argument and `--product` execution of the real gate; readiness before any live test; named failure for nonzero, exit 77, reported skip, absent/malformed/zero `ASSERTS`, zero phase rows, and missing hosts; every then-current live command failing hostless under `ZB_WIN_GATE=1` while retaining standalone clean-skip; and the three plan mutants (treat 77 as pass, accept `ASSERTS 0`, restore one gate clean-skip) recorded against registered tests. The commit message must report the test:production ratio. If it exceeds 3:1, D.5 requires an accepted live row before the slice can be accepted.

WS0.9 closure still requires separately approved, bounded exact-commit/harness runs on the Win11 VM and the Win10 box. This red review grants neither host release.

## WS1.2 review — `ec568b6` red and `0f2486b` pre-run harness

**Verdict: APPROVED red and pre-run harness; registration remains pending. APPROVED for one bounded Win11 VM run at exact commit `0f2486b65ee4d1844292fb403a2a82e6c4116107`. VM queue position: 1 (run before WS2b.0).** This is not WS1.2 acceptance or closure, and it does not authorize Win10 or any later source/harness bytes.

I audited every file changed by the two commits for dead imports, wrong-level calls, raw-helper bypasses and generated residue; no R3 defect was found. The raw SSH/SCP operations are appropriate for this Linux-side staging driver and use pinned host keys, `BatchMode=yes`, `IdentitiesOnly=yes`, strict host-key checking and scrubbed display/askpass variables. The three m8 tests still use the known unhardened WS0.4 scheduled-task runner; the driver supplies an outer 600-second subprocess bound, and this approval does not close WS0.4.

In clean exact-commit scratch exports with all display/askpass and host variables unset, `ec568b6e911dd6d642c2d2bef9d03e17258b903c` reproduced five intended failures (three gate skips incorrectly returned 77 and the driver was absent), while `0f2486b` passed all six hostless harness cases with the live leg skipped. The reviewed SHA-256 is:

- `tests/windows/m8_live_test.py`: `b584509022131e74f86d26d3098e6dd4af81a53b087709b1b3e682818db0173c`

The approved run is one bounded session in a scratch shared clone checked out at `0f2486b`, never the shared worktree:

1. With `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY` and `SSH_ASKPASS` unset, run `ZB_WIN11_HOST=127.0.0.1 ZB_BUILD_COMMIT=0f2486b ZB_BUILD_MODE=ReleaseSafe bash tests/windows/build-on-windows.sh` with **no positional build step**. Verify the fetched executable's `.sha` provenance is the full approved commit.
2. Run `m8_live_test.py` with `ZB_WIN_GATE=1`, `ZB_WIN11_HOST=127.0.0.1`, `ZB_WIN11_MARKER=zb-win11-m8-ws0-2026-10-20`, and `ZB_WIN_EXE` set to that scratch clone's fetched executable. All three Win11 rows must say PASS with `ASSERTS n>0`; the driver must then exit 1 with `INCOMPLETE: both hosts are required` because Win10 is intentionally absent.
3. Run `m8_gate_red_test.py` with the same environment. It must accept the honest one-host result and exit 0. Both invocations must record commands and exit codes, report cleanup, leave no `zb_m8_*` scheduled task, and remove/check the remote `C:\Users\zbtext\zb\runs\m8-*` directory.

If the console user is not signed in and unlocked, the run must fail closed without retry and proves no platform behavior. The orchestrator's release and the free VM slot remain required. After the run, WS1.2 is still “green, registration pending” until the plan-named build steps and registered gate case land and receive review.

## WS2b.0 review — `8438086` and `f310b4d` complete red harness

**Verdict: APPROVED as unregistered reds and APPROVED for one bounded Win11 VM red session at exact commit `f310b4dbbd7887702f929f6cd49f047721e46017`. VM queue position: 2, only after the approved WS1.2 session releases the slot.** This approval covers no green implementation, Win10 run, registration claim, or later bytes.

I audited all changed Python and Zig files for dead imports, wrong abstractions, raw-helper bypasses and generated residue; no R3 defect was found. `win_capabilities_test.py` reuses the existing transport test's launch, pinned SSH/SCP, probe and cleanup machinery rather than creating a second path. The transport probe keeps the token secret, frames bounded requests/replies, and compiled for `x86_64-windows-gnu` at the exact commit.

In a clean exact-commit scratch export, I reproduced: the Linux real-binary authenticated-socket red (missing/wrong token accepted as auth failures, correct token reached `capabilities` and got `-32601 Method not found`); the Zig red (one guard passed, input `cdp_input`, network `supported`, and `CapabilitiesJsonMissing` failed); hostless standalone clean-skip; gated hostless failure; and the Windows probe compile. Independently verified harness digests include:

- `tests/e2e/win_capabilities_test.py`: `24dbf6f8b45dccdd122ca646a9ccaed521dc58da946fb27b2110714e1ac87a57`
- `tests/e2e/win_transport_test.py`: `309a48cc2009bcecbf0aa9ea3cba545cccae22f740a760c82760154cbf669a03`
- `tests/windows/transport_probe.zig`: `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`

The approved red session is:

1. In a scratch clone checked out at `f310b4d`, with display and askpass variables unset, build with `ZB_WIN11_HOST=127.0.0.1 ZB_BUILD_COMMIT=f310b4d ZB_BUILD_MODE=ReleaseSafe bash tests/windows/build-on-windows.sh` and **no positional build step**. Verify the fetched `.sha` names the full approved commit and record the expected Win11 identity marker before executing tests.
2. With that executable, run `ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<scratch fetched exe> python3 -I tests/e2e/win_capabilities_test.py -v`. It must exit 1 for the intended red only: missing and wrong token checks pass, the correct-token request reaches the method and returns `-32601`, and the script prints a nonzero `ASSERTS` count. Any earlier launch, auth, transport, identity or cleanup failure is not an accepted red.
3. Run `win_transport_test.py` once with the same executable as the probe-refactor regression; both transport tests must pass. Record commands/exit codes and explicitly verify that no remote `C:\Users\zbtext\zb\ws20-*` directory survives, because the borrowed cleanup helper does not itself assert after its final retry.

The orchestrator's release and a free VM slot remain required. The network-row red is tracked under `zigBrowser-ong.7`; this review accepts it only as an unproven-row red, not as platform proof. A later product commit may be described as “green, registration pending,” but WS2b.0 cannot be accepted until `test-wv2-capabilities` and `windows-capabilities-live` are both registered as required by the existing R2 minimum.
