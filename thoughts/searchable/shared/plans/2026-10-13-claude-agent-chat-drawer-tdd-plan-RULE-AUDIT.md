---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent
audits: rev 16.20.60 (4074bc6) of the drawer plan, against the owner verification rule
---

VERDICT: PASS WITH GAPS (9)

# Audit: chat-drawer TDD plan rev 16.20.60 (commit 4074bc6), "prove it by running it" pass

Plan read from `git show 4074bc6:<plan>`. It is byte-identical to the worktree copy. Line numbers below are plan lines at 4074bc6.
The code was checked in the export at HEAD 4074bc6: `.../scratchpad/audit-drawer/tree`.
Gap counts: check 1: 0, check 2: 4, check 3: 2, check 4: 1, check 5: 0, check 6: 2.

The spot-check's points are now stated in the slice bodies, not only in tables:
- most of S8 unbuilt: the S8 status box at 3250-3262 and the per-part proofs at 3490-3505;
- all of S9 unbuilt except the navigate-card part of S9.3: 3625-3629, and the proofs at 3632-3649;
- agent-no-orphans unbuilt: SX-orphans at 3794-3812, section 11 at 3880-3883, 2.0a at 106;
- D7b flow control unbuilt: the D7 status table at 418-431 (the queue is retracted under OD-1) and S5e at 2831-2871.
I confirmed each absence in code: "grant" appears 0 times in agent_broker/approval/tools.zig; there is no `account` in engine.zig or flow_runner.zig; there is no `trimCount` and no "earlier messages hidden"; there is no `APPROVAL_TTL_MS` reader; there is no `zb-agent-gate` or `agent-no-orphans` anywhere; no fs_* files exist.

## 1. VERBATIM: 0 gaps
- I diffed the text between the two `---` lines of exercise_rule.md against plan lines 1565-1589. The diff is empty: the text matches exactly, blank lines included.
- The heading appears once, at 1565. The other 3 hits of the phrase are references to it (13, 26, 3986).
- It sits before section 10, which starts at 1591; the first slice, P0, is at 1599.

## 2. COVERAGE: 4 gaps
The sample is 34 behaviors. 21 were picked at random (`shuf`, seed 20261022, from the compliance table's behavior column):
S6.4 S6.3 S7.0.2 S7.0.7 S7.0.3 P0.5 P0.7 P0.4 S7.1 S3.2 S7.3 S7.2 S7.5 S2.1 S7b.detach S7.7 S2.3 S7b.window_info S3.1 S7b.screenshot-fit S4.1.
13 were chosen by hand to reach the slices the random draw missed:
S1.4 S1.6 S2.5 S3.8 S5.1 S5.6 S5e.1 S8.2 S8.6 S8a-engine S9.3 S10.3 SXO.1.

What the sample shows:
- All 81 `#### Behavior` headings have a Proof (rule 9) block. I checked this with an awk scan; S7.0.2 to S7.0.7 use the group block at 3168.
- All 34 sampled blocks label (a) the entry point, (b) the test plus build.zig step, (c) the mutant and (d) the platform.
- When the mutant is missing, the block says "not named; proposed: ..." and the status is UNPROVEN. That is 12 of the 34. This is honest, not a defect.
- No sampled proof is a disguised read. Where a test reads a file or a row, it reads runtime state, which is allowed:
  - `agent-drawer.json` and `token-route.json` as persisted state;
  - the `DRAWER tree` and `SECRETS` rows;
  - the inotify and exec oracles, which watch the running process, not source text.
- Status split in the sample: 22 BUILT-DRIVEN (run pending), 12 UNPROVEN, 6 NOT BUILT, and partial-built splits for S8.2 and S9.3.

Gaps:
- 1775 (and table row 4011), S2.1: field (c) is "the commit that built the dock records three". The commit has no hash, so the mutant record cannot be traced as rule 3 requires.
- 2147, S4.1: field (b) names `tests/agent_secrets_test.zig` as "the validToken oracle over 10k strings". No such test is in that file. The oracle is `tests/agent_secrets_shape_test.zig` (`run_agent_secrets_shape_tests`, build.zig:1306, test :3650). My mutant run (check 4) failed in that file.
- 2205, S5.1: the block says green commit `905e5a3` "records mutants" for streaming. 905e5a3's mutants are "no second-error guard" and "no stopping reset". Those belong to S5.3 and S5.2. Streaming's own mutant (do not route `assistant_delta`) is named in the plan but recorded nowhere.
- 2022, S3.7: field (a) says "the stale-CLI refusal on Send is in src/agent_helper.c/agent_helper.zig". No such code exists. The same block's status, and row S3.7b, say NOT BUILT. In code, `chat.py:394-418` checks only `route`, never `cli_version`. Field (a) contradicts the status.

## 3. CLOSURE LEAKS: 2 gaps
I grepped the whole plan for each word. "Not labelled" means the line does not carry the word "tripwire".

| Word | Hits | Not labelled |
|---|---|---|
| grep or rg | 19 | 10 |
| regex | 3 | 2 |
| lexer | 1 | 0 |
| AST | 0 | 0 |
| oracle | 51 | 50 |
| symbol | 2 | 1 |
| nm | 1 | 0 |
| strings | 8 | 7 |
| otool | 2 | 1 |
| contains | 25 | 23 |
| census | 77 | 76 |
| manifest | 15 | 15 |
| check that | 5 | 3 |
| verify that | 1 | 1 |
| source text | 6 | 3 |

I read every unlabelled hit. Almost all are runtime observations, not source checks:
- the inotify, exec and persisted-state oracles;
- the P0 exec census, which records execs at run time;
- the `config-manifest.json` re-hash and netd's manifests, which are runtime inputs;
- "contains" in Then-clauses about fake-API bodies, env dumps or rows.

The source checks that remain are labelled tripwires:
- 1689 and 1768: the step counts;
- 2838 and 2852: the `rg gtk_container_remove` check;
- 2999: the S7.1 `tokensEqual` source test (`automation_server_test.zig:578`);
- 3855: the refactor `rg -n` and jscpd checks;
- 1544 and 4107: the registration `grep -c`;
- 2715: the S5.7 coverage audit;
- 3769: SXM's absence grep;
- 3799: SXO's static parse of build.zig.

Gaps:
- 1524-1530, section 8.4 "Closure status": the S1 to S7 closure tests are marked plain "BUILT". The only evidence is a build.zig step line, such as `agent-drawer-icon-e2e build.zig:2192`. There is no "run pending" and no recorded run. Under rules 5 and 8, a step's presence is a registration listing, not proof. This table is the one place a reader would treat a slice's closure as done. It needs the same "BUILT-DRIVEN (run pending)" qualifier the compliance table uses.
- 84-109 (section 2.0a) and 418-428 (the D7 status table): rows say BUILT on reading evidence alone:
  - P0, line 90: "files exist", plus `p0_census.json` "pins `cli_version`";
  - S1/S2: function line numbers;
  - "Drawer default BUILT": the constant at `agent_config.zig:17`, although compliance row S5.5 says UNPROVEN;
  - D7: per-bubble cap BUILT from source lines.
  The 2.0a header (84-86) says these are static, SUSPECTED, and overridden by the compliance table. So this is mitigated, but the word BUILT still closes rows on reading.

## 4. TRUTH: 1 gap
Runs were in the export only, under `unshare --user --map-root-user --pid --fork --mount-proc`, with DISPLAY, WAYLAND_DISPLAY, XAUTHORITY and SSH_ASKPASS unset, per-tree caches, -j4, `timeout 900`, one step at a time. Script: `scratchpad/ad/run_step.sh`. Mutants ran in separate copies of the export (`ad/mut1`, `ad/mut2`).

VERIFIED (run):
- S4.1, the token shape (`validToken`, `src/agent_secrets_shape.zig:18`):
  - Clean run: `zig build test-agent-secrets` exited 0, "14/14 steps; 31/31 tests passed".
  - Mutant: allow ' ' in the suffix. The step exited 1 with 3 failures, including "property (oracle): validToken matches ^sk-ant-oat01-... over 10k strings: expected false, found true".
- S1.4, the clamp unit leg (`clampRect`, `src/agent_drawer.zig:33`):
  - Clean run: `zig build drawer-props-test` exited 0, 20/20 tests.
  - Mutant: return the rect unclamped, which is the plan's own proposed S1.4 mutant. The step exited 1 with 2 failures ("clampRect keeps the icon fully inside ...", "rectFromRatios matches ...").
  - So the proposed mutant is already caught by a registered step (test :3540). The plan does not cite that step for S1.4 and still says UNPROVEN.
- S6.2 (`agent_auth.callbackCode`): `zig build test-agent-auth` passed all 45/45 of its Zig tests, `src/agent_auth.zig` included. I ran no mutant.
- INCONCLUSIVE: the same step's 7 Python login legs failed with "the Claude CLI could not start" (`login.py:500`). The cause is the mandated namespace, not the code:
  - `ensure_private_tmp`'s owner-chain check accepts only root or our own uid;
  - inside `--map-root-user`, `/` and `/tmp` show as uid 65534, which I confirmed with `stat`.
  So S6.1 and S6.4's helper units are neither confirmed nor refuted.

SUSPECTED (read). Each file:line exists at HEAD, and each production caller and test_step line was checked:
- P0.7: `test_unit.py:98`; test :3853.
- S1.2: `webkit_shim.c:1304` (attach) and `:996` (detach); test :3824.
- S1.3: `agent_drawer.c:1541` and `:1756`.
- S2.1: `drawer_open` at `:1030`; test :3825.
- S3.2: `zb_agent_helper_send` at `agent_drawer.c:1002`. Commit c320f97 does record "launch passes os.environ (2 failures)".
- S5.6: `zb_drawer_break_runs` at `:623`; test :3613.
- S7.0.1 to S7.0.7: `chat.py:109` builds the Bridge. Commit ecbc246 lists every mutant the plan quotes. build.zig:2738 runs `test_bridge`, `_result`, `_endings` and `_envelope`.
- S7.0.3: the producer's stdout feeds `@embedFile("bridge_frames")` (build.zig:664-680).
- S7.2: `agent_helper.c:476` calls `zb_agent_tools_call`, and `agent_broker.zig:471` calls `callInProcess`.
- S7.5: `bridge.py` `TOOLS` holds the 10 tools.
- S7.1: `app.zig:473` calls `startCore`.
- S8e.1: `ActKind` at `agent_broker.zig:145-147`. Commit e099fd1 records six mutants.
- S8d: `agent_drawer.c:1218` and `:1228` call approve and deny.
- S4.1: commit d47ae67's mutant list matches the plan.

Also confirmed by reading:
- 29 `= 77 ]` mappings, none on an `agent_` step;
- `test_login_boundary.py`, `agent_approval_negatives_test.py` and the three S8e.2 preview files are named nowhere in build.zig.

Gap:
- 4104, compliance row "7.1 real-screen checks", says `test_real_screen_check.py` and `test_real_screen_longrun.py` are unregistered. That is false: build.zig:2927 and :2941 run them, and test_step depends on them at :3911 and :3913. The row's status rests on a wrong fact.

## 5. FINDINGS CARRIED: 0 gaps
15 traceability rows sampled. Each finding sits in its owning section of the body, not only in the table:
- R-N1: D11 R3 refusal evidence, 648.
- R-N2: 2.0a C-exports row, 93.
- R-N3: section 11, 3868.
- R-N4: uv.lock pins the SDK only, 232.
- R-C2: SX-memlimit at 3761-3793; D7 resource limit.
- R-C3: S5.7 coverage audit rule, 2713-2717.
- R-C4: section 5 scope table, 1214-1216.
- R-W1: consumer rule in decision 15, 3465-3470.
- R-N6: reading guide, 857.
- C1: S8 box, 3250-3262.
- C2: S9 status, 3625-3629.
- C3: SX-orphans at 3794-3812; section 11 at 3883.
- C4: D7 table at 418-431; S5e at 2831.
- C5: registration debt, 1539-1541.
- W6: approvalend row plus the enum mapping unit test, 526.
- S-4: S8.3 marked "specified, not written", 3291-3292.
Precedence is stated: the spot-check wins (3942).

## 6. PLAN SHAPE: 2 gaps
What holds:
- The order is stated: OD-4 at 3918 is DECIDED (SX-memlimit, SX-orphans, S5e, S8a account, S8b, S8c, S8d, S8e part 2, S9, S10). The S8 order rule (no committing tool before S8b and S8d) is at 3264.
- Every slice's step list requires an observed closure run, and treats a skip as UNCLOSED (1595).
- Every UNPROVEN and NOT BUILT row names what is missing.
- No behavior is VERIFIED. All 43 BUILT-DRIVEN rows say "run pending". The compliance totals recount correctly: 43 / 34 / 31 / 2, 110 rows.

Gaps:
- 3921 vs 108, 3900 and 4100, SX-standin: OD-7 is DECIDED, "scheduled before S8 acts on real accounts". But 2.0a (108), the section 12 table (3900) and the compliance row (4100) still say "deferred". There is no SX-standin slice in section 10, and it is missing from OD-4's decided order. S8 comes next in that order, so the next implementer has no slice to build first.
- 3905: section 12's order sentence still says the order of S5e, SX-memlimit and SX-orphans is "the owner's (OD-4)", and it does not give the decided order recorded in 3918. The implementer has to reconcile two places. (Minor; the 8.4 closure-BUILT issue from check 3 also bears on this check.)
