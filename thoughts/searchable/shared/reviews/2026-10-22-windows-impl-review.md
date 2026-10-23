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

## WS2b.0 review — `90d2214` green, registration pending

**Verdict: APPROVED as the WS2b.0 green implementation and APPROVED for one bounded Win11 VM green session at exact commit `90d2214a5553595c8c3df062567d4e36dd38886f`; BLOCK full WS2b.0 acceptance/closure until `windows-capabilities-live` is registered in the fail-on-skip `windows-live` aggregate and the approved green run passes.** This is the same registration/platform-proof requirement stated in the first R2 minimum, not a later preference. The VM slot is available after PinkOwl's completed attempt; the orchestrator's release is still required.

The production path satisfies the substantive minimum. The real socket enters `handleRequestWith`, checks the envelope and token, and only then reaches `dispatchParsed` and `capabilitiesResult`. That method serializes `automation_platform.capabilitiesJson(running_backend)`, which in turn reads the production `adapterCapabilities` row; it does not hard-code the reported mode. The WebView2 row reports both input and network as `unproven`, with network ownership retained by `zigBrowser-ong.7`. The portable Zig plus real-executable socket test is registered as `test-wv2-capabilities` and is also a dependency of `zig build test`. The commit deliberately does not yet register the Windows test as `windows-capabilities-live`, so it cannot receive full acceptance under R2 item 3 or the plan's verification rule.

I audited the three changed files and the exact-commit harnesses for dead imports, wrong-level calls, raw-helper bypasses and generated residue; no R3 defect was found. In a clean archive of the exact commit, with display/askpass variables unset and the signal-capable e2e inside an unshared PID namespace, `zig build -j4 test-wv2-capabilities` exited 0 with `runner=xvfb`, `ASSERTS 6`, and `PASS capabilities-rpc`; `zig test src/automation_platform.zig` exited 0 with 15/15 tests. I independently replayed all five production mutants against the registered step. WebView2 input=`cdp_input`, network=`supported`, disabled RPC dispatch, wrong running backend, and bypassed authentication each made the step exit 1 for the intended assertion. This proves the gate observes both production table fields, dispatch/wiring, actual-backend selection, and token enforcement.

FoggyReef's completed red host session at `f310b4dbbd7887702f929f6cd49f047721e46017` is accepted as the planned Windows red: the build exited 0 with matching full-commit provenance; the Win11 marker was `zb-win11-m8-ws0-2026-10-20`; missing and wrong tokens produced `-32000`; the correct-token request produced the intended `-32601` with `ASSERTS 3`; the transport regression passed 2/2; and post-run checks found neither `ws20-*` directories nor a surviving browser/probe process.

Reviewed SHA-256 values at `90d2214a5553595c8c3df062567d4e36dd38886f` are:

- `tests/e2e/win_capabilities_test.py`: `24dbf6f8b45dccdd122ca646a9ccaed521dc58da946fb27b2110714e1ac87a57`
- `tests/e2e/win_transport_test.py`: `309a48cc2009bcecbf0aa9ea3cba545cccae22f740a760c82760154cbf669a03`
- `tests/windows/transport_probe.zig`: `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`
- `tests/windows/build-on-windows.sh`: `1082b5fc44fae026fc4bc98eab411d87f8c3f8f12d8f70dad63e008fcf7ee1b8`

The approved green session is one bounded run in a scratch clone checked out at exact `90d2214a5553595c8c3df062567d4e36dd38886f`, never the shared worktree:

1. Unset `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY` and `SSH_ASKPASS`; record the marker `zb-win11-m8-ws0-2026-10-20`; run `ZB_WIN11_HOST=127.0.0.1 ZB_BUILD_COMMIT=90d2214 ZB_BUILD_MODE=ReleaseSafe bash tests/windows/build-on-windows.sh` with no positional build step; and verify the fetched executable's `.sha` is the full approved commit.
2. With that executable, run `ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<scratch fetched exe> python3 -I tests/e2e/win_capabilities_test.py -v`. It must exit 0, print `ASSERTS 6`, retain `-32000` for missing/wrong tokens, return exactly the WebView2 row with both fields `unproven`, echo the id, and reject nonempty params with `-32602`.
3. Run `win_transport_test.py` once with the same executable; both transport tests must pass. Record commands and exit codes, confirm the exact harness hashes above, and explicitly verify that no remote `C:\Users\zbtext\zb\ws20-*` or `C:\Users\zbother\zb\ws20-*` directory and no browser/probe process from this run survives.

Any identity, provenance, hash, launch, authentication, transport, assertion-count, or cleanup mismatch is not an accepted green. Passing this session supplies the required real-platform row (and the D.5 live evidence), but the slice remains “green, registration pending” until the plan-named live step is registered and reviewed.

## WS1.2 Win11 outcome — approved `0f2486b` session

**Finding: the approved Win11 attempt is evidence against the WS0.4 scheduled-task runner, not a WS1.2 product defect. No WS1.2 platform behavior was reached or proved.**

PinkOwl ran the previously approved exact commit `0f2486b65ee4d1844292fb403a2a82e6c4116107`. The build exited 0 and the fetched executable's `.sha` matched the full commit. `m8_live_test.py` then exited 1: all three intended Win11 rows failed at `schtasks /create` with `ERROR: Access is denied.`, before a task or browser existed, so it correctly printed zero successful assertions. `m8_gate_red_test.py` also exited 1 because only its live case failed; its five hostless cases passed. Cleanup removed the scratch and remote run directories and left no `zb_m8_*` task.

This is a fail-closed harness result. It neither implicates nor validates WS1.2 behavior because the runner never launched the executable. The concrete evidence is that WS0.4's standard-user task-creation path cannot currently establish the interactive runner on this host. The runner's `/rl highest` option is a plausible cause, especially because the provisioned least-privilege task works, but remains a suspicion rather than a proven root cause. The one-run approval at `0f2486b` is consumed; any retry requires the WS0.4 runner issue to be addressed and a fresh exact-commit/harness review and release.

## WS2b.0 Win11 green outcome — `90d2214`

**Verdict: ACCEPTED as the required WS2b.0 Win11 green platform row. Full WS2b.0 acceptance/closure still waits only for registration of `windows-capabilities-live` in the fail-on-skip `windows-live` aggregate and review of that registration.** The honest WebView2 input and network values remain `unproven`; WS2b.1 and `zigBrowser-ong.7` own proving and changing them, not WS2b.0.

FoggyReef used the one approved session at exact `90d2214a5553595c8c3df062567d4e36dd38886f`, after the orchestrator's release, without retry. All four reviewed hashes matched and the pre-run marker was `zb-win11-m8-ws0-2026-10-20`. The exact build exited 0 with full-commit provenance. `win_capabilities_test.py -v` exited 0 with `ASSERTS 6`: missing and wrong tokens returned `-32000`, the authenticated call returned exactly the WebView2 row with both fields `unproven`, the id was echoed, and nonempty params returned `-32602`. The same executable then passed `win_transport_test.py` 2/2.

Post-run evidence is clean: neither user's `ws20-*` directory survived; no `zigBrowser.exe` or `probe.exe` from the run remained; and the six pre-existing console-session WebView2 processes had unchanged start times and were left alone. This closes the platform-run and D.5 portions of the existing R2 minimum. It does not waive the named live-step registration requirement.

## WS2a.0 review — `4af1a3c` through `34f0fa2`, pre-run

**Verdict: APPROVED implementation chain and APPROVED the exact red and green Win11 legs below; HOLD the proposed third, production-mutant leg—and therefore do not treat the requested three-leg session as fully released—until its scratch-only commit has a full SHA recorded before host contact.** Approval cannot cover future source bytes. No substantive code change is requested: the described one-hunk main-world mutant is the plan's correct mutant, but its commit does not yet exist.

The reviewed linear chain is:

- `4af1a3c18b39647925002f27c723039b9a689aab`: honest unregistered Windows spike red. It links a C driver with the real WebView2 shim and calls only the production `zb_automation_set_script`, `zb_automation_eval_json`, `zb_app_run`, and `zb_automation_free` ABI. At this commit the WebView2 shim defines neither required automation symbol, so the accepted red is a Windows link failure naming both unresolved symbols, before any executable runs.
- `4ec22cdc99e28373601f1d6f39b9e829df0fce1a`: unregistered portable `cdp_json` red. I reproduced its compile failure because `cdp_json.hpp` did not exist.
- `a63c1d0a6da5fa6ea4c0b5ff711a5100514e5a17`: strict portable CDP-result reader green, registered as `test-cdp-json` and in `zig build test`.
- `a6e1be099a0dc0f1e5824e93185a9b11d15ea733`: strict request-string quoting green, including every control byte and embedded NUL.
- `34f0fa2e772b52bc48d99a9e489bc9ae14782e63`: Win11 green candidate. It adds the single CDP wrapper/error mapping, reuses the existing job marshal, installs the script with `Page.addScriptToEvaluateOnNewDocument` plus `worldName`, evaluates the named main-frame world through `Page.createIsolatedWorld`, and registers the fail-on-missing-host standalone step `windows-private-world-spike-live`.

The production chain is at the correct abstraction: one raw `CallDevToolsProtocolMethod` wrapper owns CDP transport and mapping, chained calls reuse `job_hold`/`callback_done`, and the spike enters through the production C ABI rather than calling a test-only seam. I found no wrong-level call, helper bypass, or generated residue. The changed production imports are live. Two test-only includes are dead (`<cstdint>` in `cdp_json_test.cpp` and `<stdlib.h>` in `ws2a0_world_spike.c`); this is nonblocking hygiene under R3 and does not justify changing the reviewed harness before the platform run.

In exact clean archives, `zig build -j4 test-cdp-json --summary all` passed 4/4 steps; the direct C++ test reported `ASSERTS 32`; `windows-private-world-spike-live` failed hostless with exit 1 and the explicit gate precondition; standalone execution exited 77; and `cross-check` passed as a compile-only tripwire. I independently replayed the three portable production mutants: broken surrogate-pair combination, searching a key at the wrong object depth, and emitting raw control characters. Each turned `test-cdp-json` red. The whole slice has about 454 test lines to 478 production lines, below D.5's 3:1 threshold. The Windows mechanism remains unproved until the approved platform legs run.

Reviewed SHA-256 values are:

| Exact commit | File | SHA-256 |
|---|---|---|
| `4af1a3c18b39647925002f27c723039b9a689aab` | `tests/e2e/win_private_world_spike.py` | `cabf866020298b0c8dc60e7781e81026a498a9f4a4ec1abd01fae3f7bee4fd0d` |
| `4af1a3c18b39647925002f27c723039b9a689aab` | `tests/windows/ws2a0_world_spike.c` | `8cfd9cfb8889e093a2ca0c9bc0b1578b092d0f12d4ab3838a4e596ccd0421b03` |
| `4af1a3c18b39647925002f27c723039b9a689aab` | `tests/windows/build-on-windows.sh` | `1082b5fc44fae026fc4bc98eab411d87f8c3f8f12d8f70dad63e008fcf7ee1b8` |
| `34f0fa2e772b52bc48d99a9e489bc9ae14782e63` | `tests/e2e/win_private_world_spike.py` | `cabf866020298b0c8dc60e7781e81026a498a9f4a4ec1abd01fae3f7bee4fd0d` |
| `34f0fa2e772b52bc48d99a9e489bc9ae14782e63` | `tests/windows/ws2a0_world_spike.c` | `7b9189f99e4b01bba30b168d72afd4df90f9a8c278f34adffb5124ab8f532d13` |
| `34f0fa2e772b52bc48d99a9e489bc9ae14782e63` | `tests/windows/build-on-windows.sh` | `1082b5fc44fae026fc4bc98eab411d87f8c3f8f12d8f70dad63e008fcf7ee1b8` |
| `34f0fa2e772b52bc48d99a9e489bc9ae14782e63` | `src/webview2_shim.cpp` | `de44ade6a88cf5dc511d13177ac16b36b8afdfb44f933e72c1174e62bcd327b9` |
| `34f0fa2e772b52bc48d99a9e489bc9ae14782e63` | `src/cdp_json.hpp` | `4afb62ebd6403a6e0d9f69b32acda669b99106d34e963182e8af6db7b04c5473` |

The approved exact legs use separate scratch shared clones, with `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `SSH_ASKPASS`, and `SSH_ASKPASS_REQUIRE` unset; `ZB_WIN_GATE=1`, `ZB_WIN11_HOST=127.0.0.1`, and marker `zb-win11-m8-ws0-2026-10-20`; no retry; and the full SHA in `ZB_BUILD_COMMIT`:

1. **Red, exact `4af1a3c18b39647925002f27c723039b9a689aab`:** run `python3 -I tests/e2e/win_private_world_spike.py`. Accept only exit 1 from the expected Windows link failure naming unresolved `zb_automation_set_script` and `zb_automation_eval_json`, followed by `ASSERTS 0`. An identity, staging, SDK, compile, timeout, or unrelated link failure is not the red.
2. **Green, exact `34f0fa2e772b52bc48d99a9e489bc9ae14782e63`:** run the same command. Accept only exit 0 with every required `ok` row, `ASSERTS n>0`, and `PASS\tws2a0-private-world-spike`. The page world must not see the automation global; the named world must see the injected marker and shared DOM but not the page-only global; all properties must hold again after navigation; and the window/executable must close cleanly. If the named world is unusable, stop without a main-world fallback and report the result.

Before either leg, confirm no session-0 spike or zigBrowser process/window exists. After each attempted executable run, confirm the spike and browser exited and report the exact `zb\\build\\run-<full-sha>` directory plus remaining disk space. The existing build driver intentionally retains that bounded staging directory.

The held third leg becomes approvable without another design review when PinkOwl supplies: a full local commit SHA whose parent is exact `34f0fa2e772b52bc48d99a9e489bc9ae14782e63`; a diff containing only deletion of the `worldName` field from `install_automation_world_then_navigate`; and the same three green harness hashes above. Its accepted result is exit 1 because the `page world cannot see the automation global` checks fail. No host run of that commit is approved before the SHA is added to this log.

Even after red, green, and mutant platform evidence pass, WS2a.0 remains “green, aggregate registration pending” until `windows-private-world-spike-live` is included in the fail-on-skip `windows-live` aggregate. The separately named WS2a.0-W10 leg also remains NOT BUILT and is not replaced by this Win11 session.

## WS0.9 review — `64fcea0` green

**Verdict: APPROVED as the WS0.9 green implementation against the complete contract recorded at `9fe4382`; the submitted two-stage full-gate record meets that green contract. This is not WS0.9 closure and grants no Windows host run.** Closure still requires separately approved exact-commit product runs on the Win11 VM and Win10 box; the plan's Win10 product requirements remain open, including the work tracked as `zigBrowser-ong.8`, and automatic executable build/fetch remains `zigBrowser-ong.9`.

The real no-argument and `--product` path now performs readiness before any live test, runs the one phase list with `ZB_WIN_GATE=1`, and fails by test name for exit 77, a reported skip, any other nonzero exit, missing/duplicated/malformed `ASSERTS`, `ASSERTS 0`, an empty phase list, or a missing host. The red cases moved into the registered `windows-twohost-selftest`; `windows-live-step-skip` is registered in `zig build test`; `live_gate.main()` counts executed outermost unittest assertions rather than source text; and `slice2_common.gate_skip_exit` keeps standalone exit 77 while making the gate return 1. The runtime discovery covers every `windows-*-live` command plus `windows-drawer-behaviors`; on the later integrated HEAD it also found and exercised all 12 then-present commands, including `windows-private-world-spike-live` and `windows-capabilities-live`, without changing this commit's reviewed files.

In a clean archive of exact `64fcea08fae672190d54a67eb610a3dfad5119af`, with display, askpass and host variables absent, the three registered checks passed: `windows-twohost-selftest` ran 128 cases OK with 22 existing host rows skipped, `windows-live-step-skip` ran 10 cases OK, and `windows-gate-selftest` ran 16 cases OK. The hostless `windows-live` aggregate exited 1 with every one of its seven phase entries failing on the gate precondition, as required. `git diff --check`, `bash -n` and Python compilation of every changed script were clean. The reported test:production ratio is about 1.7:1, below D.5's 3:1 threshold. I found no dead import, wrong-abstraction call, shared-helper bypass or generated residue that reaches the R3 threshold.

I independently replayed the three contract mutants in separate exact-commit scratch exports against their registered tests. Treating exit 77 as pass made `test_product_run_fails_on_skip` fail because the product gate false-greened; accepting `ASSERTS 0` made `test_asserts_zero_fails` fail for the same reason; and restoring `screenshot_live_test.py` to a clean skip made both the discovered `windows-screenshot-live` step and its phase entry fail `live_step_skip_test.py`. These are causal production mutations, not source tripwires.

The full-gate evidence is accepted as a two-stage environmental disposition. With no display, `zig build test -j4` exited 1 only because 14 `webkit.test.*` cases require a display; the run otherwise reached 488/490 steps. Under a private Xvfb, the affected exact-commit test execution exited 0 (154 passed, 2 skipped, 0 failed; the second unit binary passed 55/55). A display-free invocation is therefore not being mislabeled green, but its only failures were isolated and passed under the required private display. That meets the WS0.9 green review contract because all modified registered steps passed and the environmental failure was resolved without changing product bytes. An additional reviewer full-suite attempt under a map-root user namespace was stopped with exit 130 after unrelated identity-sensitive tests resolved Bun under `/root`, could read a permission canary as namespace root, and lacked `/run/user/0`; it is neither counted as a green run nor as contrary WS0.9 evidence.

## WS2a.0 queue outcome — old red consumed, green not run

The orchestrator released PinkOwl's previously approved exact Win11 red leg at `4af1a3c18b39647925002f27c723039b9a689aab` and green leg at `34f0fa2e772b52bc48d99a9e489bc9ae14782e63`. PinkOwl consumed the red leg once, but it is **not accepted**: the Windows link failed first on six unrelated `zb_drawer_*` symbols, so it never demonstrated the approved unresolved `zb_automation_set_script` / `zb_automation_eval_json` red. The executable did not run, cleanup found no new process, and the green leg was correctly not attempted. The slot is free and both old one-run approvals are consumed.

PinkOwl has proposed a link-fix green at `505216ca6c9001636ee8a140470e6e32b3281efe`, scratch red `d3d3c3ce72d6408ce3a19c9c1e040a63e24e08fc`, and scratch main-world mutant `98bec286d3644db5d0083f682a628ee4a02ee590`. They are a new review request and **no host run is approved by this entry**. The orchestrator must issue a new release only after a later exact-commit review records the applicable hashes and accepted outcomes.

## WS2b.0 registration — `4f9cac2`

**Verdict: APPROVED; WS2b.0 Win11 is ACCEPTED. Win10 remains open.** Exact `4f9cac2a1cd39010452e87ce26d2263bfb2c082b` adds the named `windows-capabilities-live` step and the unchanged harness to `live_phases.txt`, so both `windows-live` and `gate.sh --product` consume it fail-on-skip. In a clean archive, standalone hostless execution exited 0 with a skip, gated execution exited 1 with `ASSERTS 0`, `windows-live` exited 1 and named the capabilities test, and `windows-live-step-skip` passed. This satisfies the last condition of the R2 minimum; the already accepted exact-`90d2214` Win11 run covers the unchanged `win_capabilities_test.py` bytes (`24dbf6f8b45dccdd122ca646a9ccaed521dc58da946fb27b2110714e1ac87a57`).

## WS0.4 item 4 red — `bf0e6b5`

**Verdict: APPROVED as an unregistered red.** Exact `bf0e6b52b51f250c0fa88e50b30bf1c465195f38` adds only `runner_ws04_red_test.py` and is absent from `build.zig`. It drives both real scheduled-task runners through recording `schtasks`/`taskkill` fakes. A clean exact-commit run exited 1 with the intended six failures: both runners request `/rl highest`, both fail as a standard user with `Access is denied`, and both false-green a failed `/delete`. Green must move these cases into the plan-named registered selftest, use least privilege for both runners, and make named task cleanup failures fail the run; live runner proof remains separate.

## WS2a.0 revised exact Win11 legs — `505216c`, `d3d3c3c`, `98bec28`

**Verdict: APPROVED for one bounded, no-retry Win11 run of each exact leg, in order red, green, mutant; each still requires the orchestrator's release and slot.** The red and mutant refs are present and both have exact `505216ca6c9001636ee8a140470e6e32b3281efe` as parent. The link fix uses the real `src/agent_drawer.zig` object, not a stub; a local Windows-object build exported the drawer symbols that caused the old unrelated failure, and `test-cdp-json` passed.

Common SHA-256 values at all three commits are: `win_private_world_spike.py` `cabf866020298b0c8dc60e7781e81026a498a9f4a4ec1abd01fae3f7bee4fd0d`; `ws2a0_world_spike.c` `7b9189f99e4b01bba30b168d72afd4df90f9a8c278f34adffb5124ab8f532d13`; `build-on-windows.sh` `1082b5fc44fae026fc4bc98eab411d87f8c3f8f12d8f70dad63e008fcf7ee1b8`; `build.zig` `958c7337fc068abaa569209acca03f22213968c396dd003521d4dd640bde51fa`; `agent_drawer.zig` `fc19ad3edd0ad90597c00aa449ca753e067d65e1c35d9396598be2b95b29adac`; and `cdp_json.hpp` `4afb62ebd6403a6e0d9f69b32acda669b99106d34e963182e8af6db7b04c5473`. Per-leg `webview2_shim.cpp` values are green `de44ade6a88cf5dc511d13177ac16b36b8afdfb44f933e72c1174e62bcd327b9`, red `e23145ffe452be99b0e40be7822bfe0fad9d5bd98d8dd9f08e2d09147ee2f2ec`, and mutant `447c4f4c97edc46cb7569f11cc39c07ff583861d127945e7139825b62536586b`.

- **Red `d3d3c3ce72d6408ce3a19c9c1e040a63e24e08fc`:** accept only exit 1 with unresolved `zb_automation_set_script` and `zb_automation_eval_json`, no unresolved `zb_drawer_*`, and `ASSERTS 0`.
- **Green `505216ca6c9001636ee8a140470e6e32b3281efe`:** accept only exit 0, every REQUIRED row `ok`, `ASSERTS n>0`, and `PASS\tws2a0-private-world-spike`.
- **Mutant `98bec286d3644db5d0083f682a628ee4a02ee590`:** its only change deletes `worldName`; accept only exit 1 because `page world cannot see the automation global` fails.

All three use `python3 -I tests/e2e/win_private_world_spike.py` under the previously recorded scrubbed-display, identity, full-commit provenance, pre/post process and cleanup contract. Stop after any unexpected result; do not substitute a main-world fallback.

## WS2b.0 local-profile isolation — `bb13b2d`

**Verdict: APPROVED; exact `bb13b2dcae41e7e699ac0e6efcf86671e3864086` is safe to push.** Only `capabilities_rpc_test.py` changed (SHA-256 `8822adfa672fe56a508bdc107c4b7c36fdf0fd04eb0ac1970afb9802c6078878`). All imports are live; the real binary receives a private HOME, all XDG dirs, and explicit `--profile-dir`, while its socket uses a short mode-private `/tmp` directory. In an exact scratch export inside the required user/PID namespace, `test-wv2-capabilities` exited 0 with `ASSERTS 7`; deleting the `--profile-dir` arguments made the registered step exit 1 on the new profile assertion. No product code changed.

## WS2b.0 Win10 run approval — exact `90d2214`

**Verdict: APPROVED for one bounded, no-retry Win11 build-only step followed by one Win10 capabilities run at exact `90d2214a5553595c8c3df062567d4e36dd38886f`; this is not a release.** The Win11 build must wait for PinkOwl to release that host's slot. Win10 preflight must match `C:\Users\zbtest`, the pinned ED25519 fingerprint `SHA256:AhusOW2s/1hKVAOhriqN38c1Hn8hSiNMBrdbcRGAnF4`, at least 1 GB free, a present WebView2 `pv`, no prior `ws20-*`, and a process baseline; otherwise stop without writes or install/change.

Reviewed SHA-256 values are `win_capabilities_test.py` `24dbf6f8b45dccdd122ca646a9ccaed521dc58da946fb27b2110714e1ac87a57`, borrowed `win_transport_test.py` `309a48cc2009bcecbf0aa9ea3cba545cccae22f740a760c82760154cbf669a03`, `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`, and `build-on-windows.sh` `1082b5fc44fae026fc4bc98eab411d87f8c3f8f12d8f70dad63e008fcf7ee1b8`. Accept only full build provenance plus Win10 exit 0 and `ASSERTS 6` with the exact token, row, id and params outcomes already accepted on Win11. Post-check must show no staged directory or run-created browser/probe/WebView2 process. Writes are limited to the disposable `C:\Users\zbtest\zb\ws20-*`; no system-wide change or Win10 transport claim is approved.

## WS2a.0 Win11 outcome — revised legs

**Verdict: ACCEPTED as the WS2a.0 Win11 platform row.** At the exact approved SHAs and hashes, red `d3d3c3ce72d6408ce3a19c9c1e040a63e24e08fc` exited 1 with only the two expected unresolved automation symbols and `ASSERTS 0`; green `505216ca6c9001636ee8a140470e6e32b3281efe` exited 0 with `ASSERTS 20`, 20/20 required rows and PASS; main-world mutant `98bec286d3644db5d0083f682a628ee4a02ee590` exited 1 with six causal failures, including page-world visibility. Identity, process cleanup and run-directory cleanup matched the approval. PinkOwl may now add the existing driver to `live_phases.txt`; full acceptance still awaits review of that registration, and the separately required Win10 leg remains open.

## Host-build safety hold — `zigBrowser-ong.11`

**Verdict: BLOCK every further host workflow that invokes the current `build-on-windows.sh`; the earlier `90d2214` Win10 approval is suspended and FoggyReef's released build/Win10 chain must not start.** Zig writes its global cache to `%LOCALAPPDATA%\zig`, outside the brief's zero-exception `%USERPROFILE%\zb` boundary. Calling this a known exception cannot waive a hard safety rule. The completed WS2a.0 run's behavior remains valid evidence, but its session was safety-noncompliant. Unblock requires an exact reviewed fix that confines Zig global and local caches under `zb\`, a registered hostless command/env test, and a mutant that drops confinement and turns that test red. Existing `AppData\Local\zig` cleanup is an owner decision; agents must not remove it. Host runs that do not invoke this driver are not automatically blocked, but FoggyReef's approved chain depends on it and therefore is held pending fresh approval/release.

## WS2b.1 hostless red — `ed0868d`

**Verdict: APPROVED as an unregistered, hostless red harness only.** Exact `ed0868dd0c54e9b13eff4fffd84de72da9fad7ba` adds the trusted-input C spike and Linux driver; hostless compilation succeeded and its undefined production ABI contains exactly the six planned `zb_native_*` operations. Standalone no-host exits 77, gated no-host and missing-marker cases fail before SSH, the 37 required rows are unique, and the unchanged live-step selftest passes. The intended Windows link red remains unrun and unaccepted; no host run is approved before `zigBrowser-ong.11` is fixed and reviewed.

The `build.zig` diff is exactly one 18-line WS2b.1 hunk and contains only FoggyReef's task-specific module, C source, reused drawer object, executable/run arguments, and named step. `ws2b1-input-spike-win` exists only in the WebView2/Windows-target branch; it has no dependency edge to `test` or `windows-live`, is absent from `tests/windows/live_phases.txt` and `gate.sh`, and is absent from the Linux step list. Therefore it joins none of `zig build test`, the fail-on-skip `windows-live` aggregate, or `gate.sh --product`, and this red cannot make a registered gate red.

## Host-build safety unblock — `9c5f796`

**Verdict: APPROVED against the exact `7b0c8e4` minimum; the `zigBrowser-ong.11` host-build block is lifted for fresh exact-commit requests carrying this fix.** Exact `9c5f796271010a393e53ef09b18f3ca08b04cec4` sets `ZIG_GLOBAL_CACHE_DIR` to `%USERPROFILE%\zb\zig-global-cache` and `ZIG_LOCAL_CACHE_DIR` to the exact run folder's `.zig-cache`, before `zig build`. The three red cases moved unchanged into `build_on_windows_selftest.py`; `windows-build-selftest` is named and is also in `zig build test`. In an exact private scratch export, all 38 cases and the registered 3/3-step command passed. Deleting both production assignments made that registered command exit 1 with the expected three failures. No host was contacted.

FoggyReef may newly request the Win10 WS2b.0 leg and WS2b.1 runs; PinkOwl may request the WS2a.0 Win10 leg; GrayHarbor may request WS1.2. This is eligibility to request, not host approval: every run needs a fresh exact descendant commit and approval with new harness digests, including the changed `build-on-windows.sh`; old approvals remain consumed or suspended.

## WS2a.0 Win11 registration — `516b5b1`

**Verdict: APPROVED; the WS2a.0 Win11 row is CLOSED. Win10 remains open, so the cross-version workstream is not yet complete.** Exact `516b5b13db0ac1214df26b32fbb1f059861d6085` changes only `tests/windows/live_phases.txt`, adding `tests/e2e/win_private_world_spike.py`. `windows-live` reads that phase list and now invokes the file under `ZB_WIN_GATE=1`. In an exact private scratch export, standalone hostless execution exited 77 naming no configured host; gated execution exited 1 with the same reason and the skip-is-failure diagnostic; and `zig build windows-live` exited 1 with a failed command naming the newly registered file. This registration completes the already accepted `7b0c8e4` Win11 platform proof. No host was contacted.

## WS2b.0 Win10 and WS2b.1 Win11-red run approvals — `516b5b1`

**WS2b.0 Win10 verdict: APPROVED for one bounded, no-retry chain at exact `516b5b13db0ac1214df26b32fbb1f059861d6085`, subject to orchestrator release.** Run the read-only Win10 preflight, then one Win11 build, then the Win10 capabilities test. Stop on any preflight mismatch. Accept only Win10 exit 0 with `ASSERTS 6` and the six previously accepted auth/row/id/params outcomes; this grants no Win10 transport claim. Require exact build provenance, removal of the literal Win11 run folder, and the stated Win10 process/folder cleanup. `zb\zig-global-cache` may persist because it is inside `zb\`; report its post-run size. Compare `%LOCALAPPDATA%\zig` before/after and report its snapshot unchanged.

WS2b.0 reviewed hashes: `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`; `win_capabilities_test.py` `24dbf6f8b45dccdd122ca646a9ccaed521dc58da946fb27b2110714e1ac87a57`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`.

**WS2b.1 Win11-red verdict: APPROVED for one bounded, no-retry run at the same exact commit, after the WS2b.0 chain and subject to orchestrator release.** Accept only matching host identity, exit 1, `ASSERTS 0`, and a link failure whose undefined production symbols are exactly `zb_native_click`, `zb_native_key`, `zb_native_text`, `zb_native_move`, `zb_native_scroll`, and `zb_native_pointer`; any other failure is not the red. Remove the exact run folder, confirm no spike/browser process, report the persistent global-cache size, and prove the `%LOCALAPPDATA%\zig` snapshot unchanged. The exact object cross-compiled cleanly and its `zb_native_*` undefined set is those six.

WS2b.1 reviewed hashes: `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`; `win_trusted_input_matrix.py` `178a0d853a5d919b58af71ac3c1e521f82093685106e09e27891853a2cb1a190`; `spike_driver.py` `6a268ed410d23b6f868b1c240c1e7c70e2ea8c3f51dc19b845dd86d76092cdea`; `ws2b1_input_spike.c` `f979476aecc0bc2614e33c88f20acccf98aca72b3314e81b30167d86d36aa779`; `spike_common.h` `c656bd45d2dff35210c7c7e16b8917b8540322b79aa06c070ecd456da5c54679`; `input.html` `18cbe8a6bbdb6b1dd71c1847fe2ea2fe8cc92f1c98782c173828e77c400d6f98`; `scroll.html` `d99071f37a709e8c066fc1e6fece9971a5239a1d7d4d9725bfe524b875d4e488`; `automation.js` `64199f28fbfd58da5f2b179b418a35dc6f7a5e53d441dd008b23f0cf2e9c8bbd`; `build.zig` `8a4a9267cd023eef0039b1f83f442cd8f7741d24216a58d723d7e8a986422a23`.

## WS2a.1 unregistered red — `80fdd3c`

**Verdict: BLOCK the requested Win11 red at exact `80fdd3cd019581cd335c0fad7fa7decd40865153`; no host run is approved.** The one-file, unregistered harness is otherwise structurally sound and reaches the real authenticated socket, but its readiness loop calls `page.title` before the plan's rule-9 exact red, `page.evaluate("1+1") == 2`. Today's null Windows page port therefore returns `-32011` at `page.title`, so the requested outcome would never exercise the plan-named failing assertion (R2). Minimum: make the authenticated `page.evaluate` assertion the first page-port behavior after the auth/envelope checks, then submit a new exact commit and digest for review. The eventual host request must also retain marker preflight, bounded/no-retry execution, exact run-folder cleanup, persistent `zb\zig-global-cache` size reporting, and an unchanged `%LOCALAPPDATA%\zig` snapshot.

Exact hostless checks: standalone exit 0 with one skip and `ASSERTS 0`; `ZB_WIN_GATE=1` exit 1 naming the absent host; no `live_phases.txt` or `build.zig` registration. Reviewed hashes: `win_routed_test.py` `35ddbcb145a0405946f487517aa1449918014ea3180e7f2848d5ecf90875cbbf`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`.

The orchestrator reports that FoggyReef's already approved Win11/Win10 work at exact `516b5b13db0ac1214df26b32fbb1f059861d6085` was released after all 13 supplied digests were verified; this changes no acceptance result by itself.

## WS2a.1 red fix-forward — `4140546`

**Verdict: APPROVED against the `5224a9f` minimum, and APPROVED for one bounded, no-retry Win11 red at exact `41405469b948dd01e9c45eb1dcb62cae561911aa`, subject to a later orchestrator release after FoggyReef gives up the slot.** The only changed file is the still-unregistered harness. After the auth (`-32000`) and envelope (`-32602`) checks, its first page-port call is authenticated `page.evaluate("1+1")`; today's null Windows port must make that exact assertion fail with `-32011`/`session_invalid`. Any earlier, build, identity, transport, `page.title`, or other failure is not the accepted red. Require marker preflight, exact build provenance, no retry, literal run-folder cleanup, no surviving run process, persistent `zb\zig-global-cache` size reporting, and an unchanged `%LOCALAPPDATA%\zig` snapshot.

Exact-archive evidence: standalone hostless exit 0 with one skip and `ASSERTS 0`; gated hostless exit 1 naming the absent host; a driven `-32011` replay confirmed the first three calls are unauthenticated evaluate, invalid-params evaluate, then authenticated evaluate, and the failure names `page.evaluate 1+1`. Reviewed hashes: `win_routed_test.py` `72f39b616f96a21ad2aeccea76fce4fcf2f325e02acdda7359f40f437f563a73`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`.

## WS0.4 item 4 green — `2df192b`

**Green verdict: APPROVED as the item-4 implementation; this alone does not close WS0.4.** Exact `2df192bf4b020f13a9f13edcac289e09267dd158` moves all four `bf0e6b5` test methods and their helper logic into `gate_selftest.py` unchanged except for collision-safe names, deletes the unregistered red file, uses `/rl limited` for both scheduled-task runners, and makes a failed `/delete` set a nonzero result, add the named diagnostic, and clear `matched`. `windows-gate-selftest` runs that file and remains a dependency of `zig build test`. No dead import, wrong-level call, helper bypass, or material residue was found.

In an exact private archive, the direct suite passed 20/20 and the scrubbed registered step passed 3/3. Both recorded production mutants reproduced: restoring `TASK_RUN_LEVEL = "highest"` failed four assertions across both runners; ignoring the delete result failed the two runner subcases. The commit records those mutant outcomes. The earlier access-denied cause remains SUSPECTED until the m8 harness passes through this runner on Windows.

**Win11 run verdict: APPROVED for one bounded, no-retry m8 run at the same exact commit, queued after FoggyReef and PinkOwl and subject to orchestrator release.** Build with full `ZB_BUILD_COMMIT=2df192bf4b020f13a9f13edcac289e09267dd158`, `ZB_BUILD_MODE=ReleaseSafe`, and **no positional argument** (`ReleaseSafe` in argv would incorrectly name a Zig build step). Require the pinned marker and unlocked `zbtext` console. Accept the item-4 platform result only if all three Win11 rows reach the browser and report PASS with `ASSERTS n>0`, no `Access is denied` occurs, and the driver then exits 1 solely with `INCOMPLETE: both hosts are required`. Any other failure is not evidence. Remove the literal build run folder; require no `zb_m8_*` task, m8 run folder, or run-created process; report the persistent `zb\zig-global-cache` size and an unchanged `%LOCALAPPDATA%\zig` snapshot.

Reviewed run hashes: `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`; `m8_live_test.py` `b584509022131e74f86d26d3098e6dd4af81a53b087709b1b3e682818db0173c`; `m8_render_test.py` `8c48e80796102eca79973a3c77d29ec34c4c4db1e0b11b4f404832bb78c7a211`; `m8_reply_channel_test.py` `b213959e034bd7350aaaaad91d55e7b925f186ddb89df2075586e574611d48c3`; `m8_load_fail_test.py` `a97f19ce81e07e5215a216c691136ef2edc05c65574ca86004c983fe977f5d17`; `slice2_common.py` `5d160851fb53a8edbf5cabbe0dd26bf86f6f9efbbf08ce8b75ddff350f3207ee`.

## Win10 staging disposition after `e160df8`

FoggyReef's exact-`516b5b1` Win10 capabilities leg is **not accepted**: SFTP-based `scp` staging failed before product execution; WS2b.1 was not run in that session. Per the orchestrator, Win10 legs wait for the reviewed `scp -O` harness fix. The separate Win11-only WS2b.1 red was re-released under `e160df8`; that release does not change its exact accepted outcome.

## WS2a.1 unused red release; green and mutant review

**Win11 outcome: ACCEPTED as the WS2a.1 Win11 platform row.** At the exact approved SHAs and 5/5 reviewed harness hashes, red `41405469b948dd01e9c45eb1dcb62cae561911aa` exited 1 with `ASSERTS 29` when the first page-port call, authenticated `page.evaluate("1+1")`, returned `-32011`; green `3076208ec5005cb515eb688df461da79a0762e58` exited 0 with `ASSERTS 76` across evaluate, URL, title, DOM, navigation and script-error behavior; mutant `f20ec367897f75557a9c7d8145aa9916c388b02d` exited 1 with `ASSERTS 29` at the same assertion because its no-work shim produced `-32603`, not `{"result":2}`. Marker, provenance, exact-folder cleanup and process census matched the approval; `%LOCALAPPDATA%\\zig` stayed at 977 files / 98,934,749 bytes, and `zb\\zig-global-cache` stayed at 67.6 MB.

The disclosed hidden-CR marker mismatch was a read-only local pre-check with no staging, VM execution or write; it is not a consumed/retried leg. PinkOwl may add the single `tests/e2e/win_routed_test.py` entry to `tests/windows/live_phases.txt` in a descendant registration commit; do not rewrite the accepted green SHA. Review of that registration may close the Win11 side. WS2a.1 Win10 remains open.

**Registration `e24991bd9995318011a00d77acbbae0e116691f9`: APPROVED; WS2a.1 Win11 is CLOSED.** It is a direct child of acceptance review `5362253`, changes only `tests/windows/live_phases.txt`, and adds exactly one `tests/e2e/win_routed_test.py` entry. Exact hostless verification: standalone routed test exited 0 with one skip; gated routed test exited 1 naming the missing host; `live_step_skip_test.py` passed 10/10; `windows-live-step-skip` passed 3/3; and `windows-live` exited 1 with the registered routed command among its fail-on-skip failures. The already accepted exact Win11 red/green/mutant evidence now rides both `windows-live` and `gate.sh --product`. WS2a.1 Win10 remains open.

**Red-release ruling: the one exact-`41405469b948dd01e9c45eb1dcb62cae561911aa` host run approved in `749b2b2` remains unused.** The released command failed locally because its build invocation omitted `ZB_WIN11_HOST`; nothing was staged and no VM was contacted. The orchestrator may re-release the same SHA and reviewed hashes without a fresh request. This remains one bounded, no-retry host attempt. Put `ZB_WIN11_HOST=127.0.0.1`, marker `zb-win11-m8-ws0-2026-10-20`, and the full per-leg `ZB_BUILD_COMMIT` on both the build and test command lines; the build also uses `ZB_BUILD_MODE=ReleaseSafe` with no positional build step, and the test uses `ZB_WIN_GATE=1` plus the fetched exact executable.

**Green `3076208ec5005cb515eb688df461da79a0762e58`: APPROVED as the WS2a.1 implementation and for one bounded, no-retry Win11 green leg, subject to orchestrator release. Mutant `f20ec367897f75557a9c7d8145aa9916c388b02d`: APPROVED for one bounded, no-retry Win11 mutant leg after green.** The green adds the Windows PagePort and wires the real authenticated `page.evaluate`, URL, title, navigate and reload path; the shim correlates routed completion to its own navigation ID. The new `windows-routed-live` step is standalone and is not yet in `windows-live`, as expected pending platform acceptance. No dead import, wrong-abstraction call, helper bypass, or material residue was found. Navigation-policy enforcement and stopping a timed-out load remain explicitly deferred to WS2a.3 and are not accepted here.

Exact private-export evidence: green `cross-check` passed 23/23; `cross-check-ws3-win`/`cross-check-drawer-win` passed 8/8; Linux build passed 5/5; standalone `windows-routed-live` skipped successfully, while `ZB_WIN_GATE=1` failed naming the missing host; `live_step_skip_test.py` passed 10/10. The mutant is a one-hunk child of green that returns successful no-work from `zb_automation_eval_json`; its 23/23 cross-check passes, so the requested live assertion is its necessary discriminator.

Reviewed SHA-256 values, identical at red, green and mutant: `win_routed_test.py` `72f39b616f96a21ad2aeccea76fce4fcf2f325e02acdda7359f40f437f563a73`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`.

Run red, green, mutant in that order and stop at the first unexpected result. The red acceptance remains exit 1 at the first authenticated `page.evaluate("1+1")` with `-32011`; green requires exit 0 with every routed assertion passing and `ASSERTS n>0`; mutant requires exit 1 causally at that same evaluate assertion because the reply is not `{"result":2}`. Each leg must meet the existing identity, exact-provenance, `%USERPROFILE%\\zb` confinement, process census, exact-folder cleanup, persistent global-cache size, and unchanged `%LOCALAPPDATA%\\zig` checks. This approval can establish the Win11 platform row only; Win10 and `windows-live` registration remain open.

## WS2a.2 draft test and mutant — `e512018`, `8576cb2`

**Verdict: BLOCK both requested Win11 legs; the pair does not satisfy binding verification rule 3, so no host run is approved.** Exact test `e512018381db9ca43ed66b12d07a8d725a1a42da` is structurally sound and remains an unregistered draft: its first `dom.*` call is the hostile-page `dom.getText #heading == {"text":"real"}` assertion, followed by the stated hostile/clean metamorphic sequence. Exact mutant `8576cb23584ac21008c6f955755d247ecf9ebb03` is its one-generation child and changes only the two production world-selection sites to install and evaluate in the main world. No dead import, wrong abstraction, helper bypass, or material residue was found.

The proposed pass at `e512018` plus causal failure at `8576cb2` would establish green-plus-mutant only. Rule 3 separately requires a red that fails for the stated reason before the green exists, and the WS2 register repeats that ordering; PinkOwl explicitly reports no such production red. A post-green mutant cannot serve as both the red and the mutant. Minimum: submit a three-ref chain whose red ancestor contains this unchanged test and main-world production behavior, whose green child restores the private-world production behavior, and whose post-green mutant child reintroduces main-world behavior; or obtain an explicit owner plan waiver/revision. Each exact ref then needs review and a bounded red/green/mutant platform request. `zigBrowser-ong.13` and `.14` appropriately track the separately deferred navigation-policy and timeout-load-stop gaps but do not cure this proof gap.

Exact hostless evidence: test standalone exited 0 with one skip and gated exited 1 naming the missing host; mutant `cross-check` passed 23/23. Reviewed SHA-256 values, identical at both refs: `win_private_world_test.py` `1cde3152fd1e9486002b0f2640cdbd9acd8e859bd669993a6f2203be1705cfd2`; `win_routed_test.py` `72f39b616f96a21ad2aeccea76fce4fcf2f325e02acdda7359f40f437f563a73`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`.

## WS2a.2 R2 fix-forward chain — `7c5699a`, `6afa847`, `75055bc`

**Verdict: APPROVED against the `cf1f5b4` R2 minimum, and APPROVED for one bounded, no-retry Win11 run of each exact ref in red, green, mutant order, subject to orchestrator release.** Red `7c5699a181cea5f5b95964aabb25da3e88bcab6f` has parent `e512018381db9ca43ed66b12d07a8d725a1a42da` and changes only the two production selectors to install and evaluate automation in the main world. Green `6afa8476aed2b2f0eccf900e1dbc60106acd3bae` is its child and restores the private world; its complete tree is byte-identical to `e512018`. Mutant `75055bc4ecbf619ffef2dc5350b21efa617ca8cf` is the green's child and restores the red behavior; red and mutant production code differs only in comment labels. The superseded `8576cb2` is not approved.

All three exact refs passed `cross-check` 23/23 in private exports. Run once each and stop at the first unexpected result. Accept red only if it exits 1 at the first `dom.*` call, hostile-page `dom.getText #heading`, because main-world page interference prevents `{"text":"real"}`; accept green only if it exits 0 with the complete hostile/clean metamorphic sequence and `ASSERTS n>0`; accept mutant only if it exits 1 causally at that same first call. Any earlier identity, build, staging, transport, readiness or other failure is not evidence.

Reviewed SHA-256 values, identical at all three refs: `win_private_world_test.py` `1cde3152fd1e9486002b0f2640cdbd9acd8e859bd669993a6f2203be1705cfd2`; `win_routed_test.py` `72f39b616f96a21ad2aeccea76fce4fcf2f325e02acdda7359f40f437f563a73`; `win_transport_test.py` `38bad95fec35fb3cc351b6d40743634df0077a3e29faabaebfa3741f39a4221d`; `transport_probe.zig` `d17f8f5de9c5e2b9310985120400142918bf442e1b5730b24c8855f1e3f6d1a6`; `live_gate.py` `27f1edb26c4c5d3efdabe4d8351a94aff3f80f55d3dc16aebc71c427e499a677`; `build-on-windows.sh` `831f5967c4c460ce08438f9a568521734d3449ef264fa643f21a17d374e13eff`.

Each leg puts `ZB_WIN11_HOST=127.0.0.1`, marker `zb-win11-m8-ws0-2026-10-20`, and its full `ZB_BUILD_COMMIT` on both command lines; build uses `ZB_BUILD_MODE=ReleaseSafe` with no positional step and test uses `ZB_WIN_GATE=1` plus the fetched exact executable. Require the approved marker/provenance, `%USERPROFILE%\\zb` confinement, before/after process census, exact run-folder and `ws20-*` cleanup, persistent global-cache size report, and unchanged `%LOCALAPPDATA%\\zig` snapshot. Registration remains for later review; all Win10 legs remain held for the accepted `ong.12` `scp -O` fix.

## `ong.12` legacy-scp fix — `4625141`, `ad1ea28`

**Verdict: APPROVED only as the narrow `WinTransport._scp` green; BLOCKED as closure of `ong.12` or as evidence that every Win10 leg is unblocked. No host run is approved here.** Exact red `46251419c1e937adf3efea1c75190f1b2d9ca550` adds only the unregistered hermetic test; exact green `ad1ea28e4dec1a002f4cec139fc602c2cc200172` changes only `build.zig` and `win_transport_test.py`, passes `-O` before the operands, registers `windows-transport-scp-selftest`, and wires it into `zig build test`. Exact-archive runs: red exit 1 with both tests failing for missing `-O`; green direct and registered step exit 0 (2/2); drop-`-O` mutant makes the registered step exit 1 with both tests failing. Hostless transport skip/gated-fail and live-step-skip behavior stayed intact. SHA-256: `transport_scp_legacy_test.py` `2333f65d8e15714011a78d90f0aa6863626daf972df0664496e4f053e75bde98`; changed `win_transport_test.py` `c2e544f45906c54513a9a49ba6f63c5b16bd888af07d7260bed9cb7045552601`.

The fix reaches WS2.0/WS2b.0 and the routed/private-world harnesses because they use or borrow `WinTransport._scp`; each later exact host request still needs fresh review with the new hash, and the first Win10 run must prove that host accepts legacy scp. It does **not** reach the explicit WS1.2-W10 path: `m8_live_test.py::Host.scp_into` invokes its own default-protocol `scp`. The other listed direct callers also remain unchanged: `screenshot_live_test.py` is needed by the plan's open WS1.3 Win10 proof; `refusal_stderr_live_test.py` and `win_config_flags_test.py` feed the both-host WS3 gate; and `ws1_run_test.py` has a Win10 WS1.5 platform row. `wincontain_*` is retired, `wsl_live_test.py` is Win11-only, and `build-on-windows.sh` fetches only from the Win11 builder, so those three do not block a Win10 leg. The broader audit also found direct default-protocol scp in `msi_install_test.py` (explicit WS13.4-W10) and `win_drawer_test.py` (open WS5 Win10 evidence).

Minimum to close `ong.12` as stated: put `-O` on every concrete Win10 staging/fetch path, beginning with the active `m8_live_test.py` WS1.2-W10 path, and cover each shared/direct path with a registered argv-level test plus a drop-`-O` mutant. WS2a.0-W10 and WS2b.1-W10 are not unblocked yet because their current drivers run/build on Win11 only and their copy-to-Win10 paths do not exist. Alternatively, narrow `ong.12` explicitly to `WinTransport` and track each remaining direct caller before approving its Win10 leg.

## WS2a.2 Win11 outcome — `7c5699a`, `6afa847`, `75055bc`

**Verdict: ACCEPTED as the WS2a.2 Win11 platform proof against `9dc9639`; registration remains open.** At the exact approved SHAs and matching 6/6 harness digests, red `7c5699a181cea5f5b95964aabb25da3e88bcab6f` exited 1 with `ASSERTS 21` at the first `dom.*` call: hostile-page `dom.getText #heading` returned `-32001`/`element_not_found` because the main-world script saw the page's locked empty `querySelectorAll`. Green `6afa8476aed2b2f0eccf900e1dbc60106acd3bae` exited 0 with `ASSERTS 101` and identical hostile/clean answers. Mutant `75055bc4ecbf619ffef2dc5350b21efa617ca8cf` exited 1 with `ASSERTS 21` at the same first call for the same causal reason. This is the approved red→green→post-green-mutant discriminator, not an earlier transport/readiness failure.

All legs ran once in order with matching marker, full commit on both commands, ReleaseSafe build, and exact provenance. After each leg the exact build folder and every `ws20-*` folder were absent, the process census returned to the same six pre-existing WebView2 processes with no browser/probe survivor, `%LOCALAPPDATA%\\zig` remained exactly 977 files / 98,934,749 bytes with the same listing hash, and `zb\\zig-global-cache` remained 916 files / 67,594,985 bytes. PinkOwl may submit one descendant shared commit adding the `windows-private-world-live` step and `tests/e2e/win_private_world_test.py` to `live_phases.txt`; it needs separate review before the Win11 row is closed. Win10 remains open.

## WS2a.2 Win11 registration — `ac45953`

**Verdict: APPROVED; WS2a.2 Win11 is CLOSED. Win10 remains open.** Exact `ac45953bfa0d2d73915173ca0b0f409257b335e5` is the direct child of acceptance review `1f2d5b6`, changes only `build.zig` (+7) and `tests/windows/live_phases.txt` (+1), removes no line, and makes no production change. The new side-effectful step `windows-private-world-live` runs exactly `python3 -I tests/e2e/win_private_world_test.py`, stays out of `zig build test`, and the identical phase-list entry makes `windows-live` and `gate.sh --product` execute it under fail-on-skip.

Exact-archive verification: `live_step_skip_test.py` passed 13/13; the named step exited 0 with one standalone skip and exited 1 under `ZB_WIN_GATE=1` naming the absent host; `windows-live-step-skip` passed 3/3; and hostless `windows-live` exited 1 with `win_private_world_test.py` among its failures. Removing only its phase-list line made `PhaseListMembership` fail specifically because `windows-private-world-live` would otherwise be absent from `windows-live`/`gate.sh --product`. This registration binds the already accepted `7c5699a` → `6afa847` → `75055bc` Win11 proof to the required gate.
