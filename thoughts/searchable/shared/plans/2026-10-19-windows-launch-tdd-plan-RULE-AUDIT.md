---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent
audits: rev 2.19 (d964bd2) of the Windows plan, against the owner verification rule
---

VERDICT: PASS WITH GAPS (15)

# Independent audit: Windows launch TDD plan rev 2.19 (d964bd2), "prove it by running it" pass

Plan: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md (3651 lines). Line numbers below are in that file.
The worktree HEAD is d964bd2, and its plan file is byte-identical to the scratch export (checked with cmp).
Gap counts: check 1: 0, check 2: 4, check 3: 5, check 4: 3, check 5: 0, check 6: 3.
The compliance table's totals are correct. I recounted the 107 rows at 3539-3647 by script: 61 NOT BUILT, 32 UNPROVEN,
13 PROVEN-PARTIAL, 1 TRIPWIRE ONLY, 27 marked "no", 18 marked "rewritten". Every number matches the plan's stated totals.

## 1. VERBATIM (0 gaps)

- The section "## Verification rule: prove it by running it (owner, 2026-10-22)" is at 1048-1072. It appears once as a heading.
  The other five mentions of its title (14, 35, 67, 270, 3537) only point to it.
- It comes before the first slice: WS0 starts at 1076.
- I diffed rule lines 1-27 of exercise_rule.md (between the two `---` lines) against plan lines 1048-1075.
  The only differences are the blank line and closing `---` that my extraction cut off. The body is word for word identical.

## 2. COVERAGE (30 behaviors sampled across WS0-WS13 and D.3; 16 random, 14 chosen; 4 gaps)

Random sample (shuf, fixed seed): WS3.2b 1908, WS0.2 1308, WS1.3 1414, WS0.1d 1307, WS13.2 3328, Closure B 1800, D.3 1318,
WS2a.3 1787, WS13.4 3330, WS1.5 1416, WS2c.5 1798, WS0.3 1309, WS5.1 2220, WS2.ABI 1802, WS4.3 2094, WS2c.3 1796.
Chosen sample: WS0.1b 1305, WS0.1c 1306, WS0.5 1311, WS1.1 1411, WS2b.0 1788, WS3.4 1910, WS5.5 2225, WS5.6 2226,
WS6.1b 2327, WS6.S 2332, WS7.5 2419, WS8.1 2812, WS9.2 3016, WS10.2 3074, WS11.3 3141, WS12.1 3207.

What is good: every block has all four labels, (a) to (d). Every proof is now stated as running the real exe, script or
function. Source checks appear only as named TRIPWIREs (for example WS0.1c, WS0.5, WS1.1, WS2.ABI, WS6.1b, WS13.1).
None of the 30 sampled proofs is still "the file contains", "census lists" or "nm shows" in disguise.
WS1.1, WS6.1c, WS6.4, WS7.2 and all of WS8-WS11 are honestly marked as not ready for implementation.

Gaps:
- G2.1 (systemic). Rule 9(b) asks for "the test file AND its build.zig step". About 46 of the 80 rows marked "yes"
  name only a NEW test file, with no build.zig step to register it in. Examples: WS1.5 1416 (ws1_run_test.py "UNREGISTERED"),
  WS2a.3 1787, WS2c.5 1798, Closure B 1800, WS2.ABI 1802, D.3 1318, WS3.1 1906, WS3.3 1909, WS4.1-4.3 2092-2094,
  WS6.1 2325, WS6.2 2329, WS12.1 3207, WS13.2 3328, WS13.4 3330. These rows should say "no", or name the target step
  (for example `windows-live`).
- G2.2. WS8.1-WS8.8 (2812-2819): field (c) "mutant" holds the expected result, not a mutant. Examples: "netd denies every
  endpoint", "agent OFF plus the fixed message". The rows are already marked "no", but (c) should name the defense that is removed.
- G2.3. WS7.5 (2419): "imports on Windows" is proven by "(d) none (Linux run with blocked modules)". That is a Windows
  claim proven only on Linux, which breaks rule 4. Either mark (d) as a Win11 VM run or narrow the behavior.
- G2.4. WS4.1-4.3 (2092-2094) share one boilerplate entry point. WS4.3's mutant ("skip the pre-dispatch load_serial
  revalidation") does not exercise the behavior it proves, which is the login gate reading the cookie through the WS3 cookie port.
  A fitting mutant would be "read the cookie through the GTK port" or "skip the cookie read".

## 3. CLOSURE LEAKS (5 gaps)

I grepped the whole plan for grep, regex, lexer, AST, oracle, symbol, nm, strings, otool, contains, census, manifest,
"check that" and "verify that": 135 hits outside lines labelled tripwire. Most are harmless:
- runtime DRAWER or WSL census rows (2191, 2198, 2443-2470, 2834);
- the WS3.2 flag-table oracle that drives the real backendFlagDecision (1829, 1937);
- `.manifest` file names (2112, 2119, 2154).
"check that" and "verify that" never occur. These five places still let a source check close or gate something:
- L3.1. 1085-1086, the WS0 status box: "CLOSED: ... WS0.5 (removed fence)". WS0.5's only proof is
  RemotePathFenceRemovedTests, an absence-of-names text check (gate_selftest.py:470-471 asserts `assertNotIn` over gate.sh text).
  The proof block at 1311 says NOT BUILT, but the status line still says CLOSED.
- L3.2. 1368, WS1.5's Then clause: "and `pe_census.py`'s arch matches". This is a PE listing inside the behavior's
  success condition, with no tripwire label.
- L3.3. 1419, the WS1 Gate: "+ [L] `cross-check` unchanged". A symbol check is a gate conjunct with no tripwire label.
  WS2.0 at 1781 labels the same check as a build guard; WS1 does not.
- L3.4. 3288 and 3305: the 🔴 Red for WS13.1 / msi_install_test.py is still `assert census.unlisted == [] and census.missing == []`.
  Only the proof block (3327) moves the proof to "install and run".
- L3.5. 3373, Dependency order: "WS13.1's census fails on any missing component, so the final packaging gate cannot pass".
  This is an unlabelled census used as a gate. The same sentence at 3345-3346 is labelled.

## 4. TRUTH (14 behaviors checked at d964bd2; 3 gaps)

How I ran things: each step ran alone in the scratch export, under
`unshare --user --map-root-user --pid --fork --mount-proc --net`, with DISPLAY, WAYLAND_DISPLAY, XAUTHORITY and SSH_ASKPASS unset,
per-tree caches, -j4 and timeout 900. I added `--net` so nothing could reach the network.
One deviation: for the single-test mutant run M1 I left DISPLAY unset only by omission. That test sets DISPLAY=:0 itself into a
fake ssh, and no display client runs.
Production mutants were applied to a separate copy of the tree, mut/, never to the export.

| Behavior | File/function exists | Production caller | build.zig step in `test` | Result |
|---|---|---|---|---|
| WS0.1a probe validation | gate_twohost_selftest.py | gate.sh --probe-only | windows-twohost-selftest (270, 3598) | VERIFIED (run): 116 tests, 94 ok, 22 skipped (all live-host or VM-env). The live half (host_live_test.py) is unregistered. |
| WS0.2 fails closed | gate_selftest.py | gate.sh | windows-gate-selftest (261, 3597) | VERIFIED (run): 16 OK |
| WS0.3 no display | WS0TwoHostReds.test_no_display_var_reaches_any_child (1026) | gate.sh:24, :53 | same | VERIFIED + MUTANT: removing `unset`/`env -u DISPLAY` makes it FAIL (failures=1; ssh saw DISPLAY=:0) |
| WS0.6 VM identity | class WS06VmIdentity (182) | gate.sh | same | VERIFIED (run, 4 ok). The VM run is SUSPECTED (review records 992b124/012e1bc). |
| WS0.7 Win10 fence | WS07FileServerFence (214), WS07ListenerPidChurn (1041) | gate.sh | same | VERIFIED (run, Linux half). Win10 live probe SUSPECTED. |
| WS1.3 screenshot | tests/windows/screenshot_live_test.py | exe --screenshot | windows-screenshot-live (311, 3606) | SUSPECTED. Hostless it skips with exit 0 (file :14, :67). The review records the 8f36ee7 VM PNG; that commit was BLOCKED there for failure reporting. |
| WS2.0 transport | owner_only.restrictToOwner | automation_server.zig:213 to :1579-1581; app.zig:646 | test-owner-only (1872, 3784, 3790) | VERIFIED (run, Linux): 13/13. VM SUSPECTED (review f29e490/3cb8722 records the zbother run). |
| WS3.2 flag seam | backend_flag.backendFlagDecision | app.zig:573 to webkit.applyBackendFlag (webkit.zig:41) | test-backend-flag (1396, 3703) | VERIFIED + MUTANT: allowing `renderer` on Windows makes it FAIL ("every row of the table"). VM SUSPECTED. The review records an empty-arm mutant and a no-print mutant (66060b0, e1e9264). |
| WS5.1 dock | --agent-drawer (cli.zig:220) to app.zig:445 to applyAgentDrawer | wired | windows-drawer-live (3552) | SUSPECTED. The step strips the host vars (3549), so live rows always skip. The 8/8 Win11 run is recorded in review line 33849-33852; b2c4f25's own message says "Verified offline". |
| WS5.2P props | agent_drawer.zig clampRect etc. | — | drawer-props-test (3539-3540) | VERIFIED (run): 20/20 |
| WS5.5 lifecycle | drawerLiveInc/Dec, retireExtraWindow | shim :213, :1390, :1449, :1528, :1792 | drawer-props-test | VERIFIED + MUTANT: `live -= 0` makes the lifecycle test FAIL (19/20). Win11 a5745b9 run recorded in review commit 18b32b4. But see G4.1. |
| WS6.S token shape | agent_secrets_shape.validToken | agent_secrets_store.zig:84, :103; app imports agent_secrets | test-agent-secrets (3650, 3657) | VERIFIED (run): 31/31 |
| WS7.3 launcher | agent/host/tests/test_launcher_contract.py; launcher.py is 35 lines | — | test-launcher-contract (2466, 3854) | SUSPECTED (read). Registered as the plan says; not run. |
| D.1 "eight live steps exit 0 hostless" | build.zig:290-336 | — | — | VERIFIED by read only: 8 addSystemCommand. The plan's count is right. |

Logs: /tmp/claude-1000/-home-maceo-ntm-Dev-zigBrowser/2f282cd0-68cc-4a77-9345-4747f7fc7145/scratchpad/aw_log_*.txt
(mutant runs: aw_log_mut1.txt, aw_log_mut2.txt, aw_log_mut3.txt).

Gaps:
- G4.1. WS5.5 (2225) is PROVEN-PARTIAL, but rule 6 says it is NOT BUILT for its "per-window" part. The only way to get a
  second drawer window is the e2e-only seam ZIGBROWSER_AGENT_DRAWER_WINDOWS, read only under `--e2e-protocol`
  (webview2_shim.cpp:95-97, 2205-2232, 2045-2060 spawn_extra_drawer_windows).
  The production "popup close path" that the plan names as the entry point does not exist: WS2c.1 popups are zero code.
  All four a5745b9 live methods use that seam. What really runs is the primary window's inc/dec plus the portable counter.
- G4.2. WS0.1b (1305) is PROVEN-PARTIAL, and WS0.1a's live half (1304) is counted too, but both rest on
  tests/windows/host_live_test.py, which is in no build.zig step. Rule 2 says an unregistered test "is a draft".
  The plan itself says "NOT part of any automatic gate".
- G4.3. The WS1 body (1371-1377, 1404) names `tests/e2e/win_screenshot_test.py` as "the real row". That file does not exist.
  The real file is tests/windows/screenshot_live_test.py, which the proof block at 1414 cites correctly.
  Also missing: win_runtime_missing_test.py and win_version_test.py; the proof blocks admit this.

## 5. FINDINGS CARRIED (15 sampled from table E, 223-266; 0 gaps)

Each of these is in its owning slice body, not only in the table:
- C2: WS0.9 at 1227 and D.1/D.2.
- C3: WS0.4's six-item OPEN list at 1152-1162.
- C5: WS2b.0 at 1788.
- C6: WS3.4 at 1874.
- C7: WS4.0 at 2058.
- C13: WS6.4 at 2274 and the WS6.1 consumer at 2268.
- C16: WS5.6 at 2193-2200.
- C18: Property register at 1007.
- C19: typed probe record at 1307 and `parseToken` at 2252.
- W3: runSafety at 2262-2267 and 2330.
- W4: 19041/19045, INCOMPLETE message and the 15 s step at 1214-1216.
- W11: INFINITE wait at 1442-1449 and 1787.
- W12: cross-check-ws3-win wiring at 2036-2039.
- W19: token-only mutant at 1508 and 1781.
- W22: toy inputs at 2402-2418.
"Rejections: none" (220) holds for the sample.

## 6. PLAN SHAPE (3 gaps)

The order is stated and binding (3354-3363). Every NOT BUILT and UNPROVEN block names what is missing
(for example "needs WS2a.1", "a host recorded without the redistributable", "blocker 5").
Rule 3's commit-message evidence is required in D.2 (180-182) and in the per-slice protocol (3394-3396).

- G6.1. Old rev-2.17 status text still says CLOSED or green for items that rev 2.19 marks PROVEN-PARTIAL, NOT BUILT or UNPROVEN:
  - B table, 119-121: "WS1.1, 1.3, 1.4, 1.5 green on the VM" and "WS2.0 ... closed";
  - WS0 box, 1085-1086;
  - WS1 status, 1401-1402: "WS1.1, 1.4, 1.5 green", which conflicts with UNPROVEN / NOT BUILT at 1411, 1415 and 1416;
  - WS2 header, 1427: "WS2.0 CLOSED";
  - WS3, 1866: "CLOSED and real: the flag seam";
  - WS5, 2128-2129: "WS5.1 ... CLOSED; WS5.5 lifecycle CLOSED".
  Rule text at 1050 and F at 270 say looser wording is overridden. Only WS0's proof blocks (1302) say so locally.
  An implementer reading a slice from the top meets the stale claim first.
- G6.2. 1913: "Closed today: WS3.2 only". WS3.2 is PROVEN-PARTIAL, two of its three named mutants are "not recorded as run",
  and WS3.2b is open. That calls a behavior closed without the recorded mutant that rule 3 requires.
- G6.3. 2220 and 2225 say "PROVEN by the recorded platform run" and "PROVEN by the a5745b9 Win11 run" in rows whose status
  is PROVEN-PARTIAL. 2225 also says the run output is not in the commit. It is only in review commit 18b32b4.

## Top 5 gaps

1. WS5.5 is shown as partly proven, but the second-drawer windows it tests exist only behind an e2e-only test seam. The
   "popup close path" it names as the production entry point does not exist yet. Under rule 6 that part is NOT BUILT.
2. About 46 compliance rows say rule-9 fields are complete, but they name only a new test file and no build.zig step to
   register it in. Rule 9(b) requires both.
3. Old status text in sections B, WS0, WS1, WS2, WS3 and WS5 still says CLOSED or green for items the new proof blocks
   mark NOT BUILT, UNPROVEN or PROVEN-PARTIAL. Example: WS1.1, WS1.4 and WS1.5 "green on the VM" at 120 and 1401.
4. WS0.5 is still listed as CLOSED at 1085 on a source check that a name is absent. WS1's gate (1419) and WS1.5's success
   condition (1368) still include unlabelled symbol and PE-listing checks.
5. WS0.1b, and the live half of WS0.1a, count as partly proven although their test file is in no build.zig step.
   The WS1 body also names a screenshot test file that does not exist (1404).
