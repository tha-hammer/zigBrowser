---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent
audits: rev 30 (b331bbb) of the macOS plan, against the owner verification rule
---

VERDICT: PASS WITH GAPS (29)

# Independent audit: macOS launch TDD plan rev 30 (b331bbb), "prove it by running it" pass + MS0-9 validation carry-over

Plan: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md (4279 lines). Line numbers below are in that file.
The scratch export (HEAD 5a5d7ca, which contains b331bbb) has a plan file byte-identical to the worktree's at 5a5d7ca (diff, empty).
Gap counts: check 1: 0, check 2: 6, check 3: 6, check 4: 4, check 5: 8, check 6: 5.
The compliance table's totals are correct. I recounted the 102 rows (4172-4273) by script: BUILT+REGISTERED 15, UNPROVEN 35,
NOT BUILT 25, RED-UNREGISTERED 5, NOT STARTED 20, UNSUPPORTED 1, RETIRED 1; Complete=yes 8 (C01 C03 C37 C39 C41 C56 C83 C86).
Every number matches 4275-4277. The R30.4 map lists all 26 bd ids and 34 minors (11 + 11 + 12), matching the three validation files.
One git lookup was blocked by a hook (see the final reply), so no Mac run could be checked against git history. Every Mac
runtime claim below is therefore SUSPECTED.

## 1. VERBATIM (0 gaps)

- The section "## Verification rule: prove it by running it (owner, 2026-10-22)" is at 36-60. It is the only heading with that
  title. The other three mentions (24, 539, 4157) only point to it.
- It comes before the first slice. MS0 starts at 1090.
- I extracted the 27 lines between the two `---` lines of exercise_rule.md and diffed them against plan lines 35-61. The diff is
  empty, so the text is word for word identical.

## 2. COVERAGE (29 behaviours sampled; 15 random, 14 chosen; 6 gaps)

Random sample (python random.seed(30), 15 of C01-C102): C04, C07, C11, C18, C27, C33, C38, C49, C51, C60, C70, C79, C80, C83, C84.
Chosen sample: C01, C06, C20, C28, C36, C43, C56, C66, C68, C74, C89, C93, C96, C102.

What is good. Every Rev 30 finding block states the four fields as (a) to (d), with a named file, a step (often "TO BE ADDED")
and a production mutant. Examples: C20 at 1846-1854, C27 at 1855-1869, C28 at 1821-1845, C36 at 1999-2010, C43 at 2236-2252,
C68 at 3402-3414 and 3448-3458, C80 at 3441-3447, C89 at 3626-3633, C93 at 3754-3766. These proofs run the real binary, the
production function or the real script with stubs. None of them is "the file contains" in disguise. Rows that lack a field say
"no" in Complete, and 4277-4279 admits that a registered row without a recorded mutant is not proof.

Gaps:
- G2.1. C83 and C86 (4254, 4257) are marked Complete=yes with c=y, but the plan names no mutant for the MS7.1 or MS7.4 seams.
  The ledger entries at 4027-4032 and 4040-4043 give only the assertion. I grepped every "mutant" line and none mentions them.
- G2.2. C37 and C38 (4208-4209) mark c=y for MS4.1a `load_serial`. The only place the plan names that mutant ("counter that never
  increments / resets") is line 2200, inside the HISTORICAL, NOT NORMATIVE MS4 rev-6 section. The live R29-MS4 text at 2091-2094
  names a mutant only for the new A-W3 red.
- G2.3. C51, the home lock (4222), is marked b=y "driven (Linux lock tests)", but the plan never names the test file or step.
  The candidate I found is tests/e2e/agent_login_locks_test.py (build.zig:2866), and the plan does not cite it.
- G2.4. C56, MS5.1c (4227), is Complete=yes and BUILT+REGISTERED. But its step skips 6 Darwin tests and fails as namespace root
  (R30.1 #25, 596). Rule 7 says a skip under a gate is a failure. Those skipped units are in `test` (build.zig:3699).
- G2.5. C74, the hook Darwin branch (4245), and R29.2 row 410 say "registered stand-in units ms8_hook_sandbox_case_test,
  ms8_hook_launch_env_case_test". Only the first is in `test`. `ms8_hook_launch_env_case_unit` hangs only off `test-mac-census`
  (build.zig:3146). It is not in `test` and not a platform gate, so by rule 2 it is a draft.
- G2.6. C07 (4178) marks b=y, but the exercising proof (tests/mac/ms1_entitlement_probe.sh, 1300) is TO BE AUTHORED. The table
  header (4161) says y means "exists today". The only test that exists is the tautological check.

## 3. CLOSURE LEAKS (6 gaps)

I grepped the whole plan for grep|regex|lexer|AST|oracle|symbol|nm|strings|otool|contains|census|manifest|check that|verify that|
indexOf|lint|lipo|static_assert (298 hits) and read each hit in context. Most hits are runtime process censuses, data manifests, or
checks already labelled TRIPWIRE in R30.2 (T1-T20). These six still close something:
- L1. 2550-2553 (MS5.1c, T-W7): "a `pip install sigstore` without `--require-hashes` in the script fails a lint test". That lint
  is the only red for the unpinned-sigstore half of V46-F10. R30-MS5 (2645-2649) converts only the SHA-pin half to an exercise.
- L2. 2778 (MS6.8 red (d)): "a Python conformance row proves no production module imports `sandbox._LINUX_BACKEND` directly". This
  import scan is the closing red for I-W9 and is not labelled a tripwire.
- L3. 2745-2749 and 3421-3426 (D2 / 4pa.66, R30.2 T8 (b)): the named exercising proof asserts "no bare allow in the rendered
  profile". T9 (615) labels that same profile-text check a TRIPWIRE. Here it is promoted to proof beside a constant read.
- L4. 3811-3812 (MS9 closure): "assert via `codesign --verify --strict`, `spctl --assess`, `stapler validate`". These are artifact
  listings and verifiers, and nothing launches the notarized app. MS9 is not in R30.2. Only the MS9.0 spike (3827) runs a binary.
- L5. 1233-1235 (MS1 red): the red still asserts "the entitlements file lists the exact keys". That is the tautology that R30.1 #8
  and T17 retire, and this line is not relabelled.
- L6. 3520-3521 (R29-MS7 T3): the "authority" list of the compiled MS7 gate starts with "production argv and preprocessor output".
  Those are compile-output text checks, and the paragraph does not mark them as tripwires next to the live Approve.

## 4. TRUTH (18 claims checked; 4 gaps)

Steps were run in the export, one at a time, under `env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS timeout 1500
unshare --user --map-root-user --pid --fork --mount-proc zig build <step> -j4 --summary all`, with per-tree caches.
| Claim (row) | Result | Mark |
|---|---|---|
| C01 MS0.1 `test_backend_contract` (in `test` at build.zig:3879; no named step) | 28 tests OK (python -m unittest, same unshare); caller launch.py:97 (read) | VERIFIED |
| C03 MS1.1 census unit (`test` :3679) | 27 tests OK | VERIFIED |
| C33 `test-backend-flag` (`test` :3703-3704) | rc 0, 10/10 | VERIFIED |
| C48 `test-agent-setup-ms5` (`test` :3785-3788) | rc 0, 34/34 steps, 14/14 tests | VERIFIED |
| C79 `test-mac-vm-containment` (`test` :3647-3648) | rc 0, 5/5, "PASS mac-vm-containment-e2e" | VERIFIED |
| C83 `test-agent-drawer-appkit` (`test` :3614) | rc 0, 7/7 | VERIFIED |
| C86 `test-agent-drawer-appkit-text` (`test` :3615) | rc 0, 7/7 | VERIFIED |
| C96 `test-agent-spawn` (`test` :3619) | rc 0, 12/12 + kill-group 8 cases | VERIFIED |
| C89 `test-agent-drawer-card-press` is red | rc 1, "error: 5 compilation errors" | VERIFIED |
| C93 `cross-check-agent-tools-mac` passes with an inert minter | rc 0; agent_tools.zig:200-209 returns 0 when `server == null`; app.zig:477-478 starts it on Linux only | VERIFIED |
| C56 `test-mac-census` | rc 1: test_ms5_1b...unreadable_file_or_a_fifo FAIL as root; "OK (skipped=6)" no-kqueue | VERIFIED (contradicts Complete=yes) |
| C74 hook stand-in units registered | ms8_hook_launch_env_case_unit only in test-mac-census (build.zig:3146) | SUSPECTED (read) |
| C46 MS4.4 Linux only | build.zig:2051, attached at :3799 under `os.tag == .linux` | SUSPECTED (read) |
| C37 load_serial Linux twin | build.zig:3348-3354, :3812 | SUSPECTED (read) |
| C41 Cards (Linux) | approval tests in `test` :3750-3752 | SUSPECTED (read) |
| C68/C69 store-name defect | agent_run_ledger.zig:594,614,630 hard-code "runs.json" | SUSPECTED (read) |
| reaper_ready / seatbelt_ready false | agent_run_recovery.zig:334; agent_setup.zig:67; no caller of recoverAllAtStartup outside the module and tests | SUSPECTED (read) |
| C102 R4 selftest | not run (its selftest stubs ssh; left alone under the hard rules) | SUSPECTED |
Gaps:
- G4.1. C96 (4267) is BUILT+REGISTERED with a=n ("no `spawnNetd` importer"). R30.0 (558) says BUILT+REGISTERED requires "a
  production entry point reaches the code" and that "nothing else earns this word". C83 and C86 (a=y) have no caller either
  (R30.1 #7, 578: "no .m file calls the seam"). The tests are real, but the status word breaks the plan's own definition. They
  should be marked as seams or NOT BUILT.
- G4.2. C56 is BUILT+REGISTERED and Complete=yes, but I observed rc 1 and 6 skips (see G2.4).
- G4.3. C102 (4273) is BUILT+REGISTERED although it is in `test` (:3596) and fails under the plan's own standard wrapper (R30.1 #24).
- G4.4. R29.2 row 410 and C74 overstate registration (see G2.5).
Mac runtime claims (all SUSPECTED; the git-history check was blocked): MS1b "rc 0 on both Macs, ad-hoc and hardened" (1367, 1386);
MS2b.2 "mutant-proven both arches" (1492); MS6.5 census gate "both arches 18/18" (2951) and "verified signal-free on both Macs"
(2961); MS6.6 (A) "green on both Macs (47199d3, ac15dfd)" (3357); netd and R1 dual-family "Proven in ..." (2861-2863); pkg
"VERIFIED 2026-10-20" (2422-2425).

## 5. FINDINGS CARRIED (all 26 bd findings and 9 minors sampled; 8 gaps)

Each of the 26 bd ids 4pa.55-.80 has an R30-MSn block in its owning slice: MS1 at 1252-1320, MS2 at 1815-1896, MS3 at 1997-2031,
MS4 at 2234-2268, MS5 at 2633-2673, MS6 at 3383-3485, MS7 at 3624-3679, MS8 at 3752-3779 and MS9 at 3817-3855. MS7.6/7.8 (4pa.72)
is corrected everywhere it was claimed: 349, 415, 3497, 3523, 3543-3544, 4048, 4057, 4085, 948, C89. The other BUILT corrections
are in place too: MS4.4 at 396, 2107, 3971; MS8.0 at 352, 3690; MS7.0 at 346, 577; MS1.3 at 378, 1194. Minors checked: V03-F10 at
1473, V03-F11 at 1138, V46-F12 at 3463, V46-F15 at 3477, V46-F19 at 2666, V79-m3 at 346, V79-m5 at 4032, V79-m12 at 3850, V03-F19
at 1893.

The 12 HISTORICAL, NOT NORMATIVE sections are at 62, 712, 724, 740, 754, 766, 782, 800, 826, 2115, 2178 and 2450. Ten of them are
pure history. Two are not (G5.7, G5.8).

Gaps:
- G5.1 (4pa.70, safety). The MS6.5 body at 2955-2958 still says `ms6_5_reaper_gate.sh` "is DISABLED BY DEFAULT" and that "must not
  run on the Macs" is "now enforced in code, not only in prose". The validation (V46-F8) and R30.1 #18 (589) say it is not
  enforced. This live, safety-relevant sentence was not corrected.
- G5.2 (V46-F15). The AUTHORITATIVE SCOPED ACCEPTANCE block at 2971-2976 still lists `acquireRunLockBounded` as "BUILT, reviewed
  and registered". The validation shows it holds no lock. Only the minor note at 3477 records this, and the authoritative block
  overrides the rest of MS6.5.1.
- G5.3 (V46-F12). The Shared contract amendment at 1075-1077 still points the I1 gap the wrong way: "`network(self)`
  (`sandbox_macos.py:371`) vs `network(self, session=None)`". The validation found both backends use `session=None` and only the
  Protocol is wrong. 2760 and 3463 have the correction, but 1075-1077 does not.
- G5.4 (4pa.78). The MS7.8 Workflow Closure at 3607-3609 still puts the fixture-card entry "behind an `--e2e-protocol` test seam".
  R30-MS7 (3643-3650) says it must be built only under a test build option.
- G5.5 (4pa.76). There are two different renames. R29.6 I-W8 (522) says `zb_secrets_window_open_for`. R30.2 T16 (622) and R30-MS7
  (3655) say `zb_secrets_window_mac_show`.
- G5.6. Line 544 says the 26 findings are "1 critical, 25 major". The map (646, 663, 664) has 3 critical (4pa.55, .72, .73) and 23
  major, which matches the validation files.
- G5.7 (hidden live content in history). The heading of the HISTORICAL MS4 rev-6 section (2178) says "MS4.1a, MS4.2-MS4.4 scope
  stands". Two requirements exist only inside it: the MS4.1a mutant (2200, which C37 and C38 rely on) and socket separation, where
  `agent.*`/`broker.*` give -32601 and a grant id as auth gives -32000 (2225-2227). grep finds neither anywhere else. Both are live
  proofs hidden in a non-normative section.
- G5.8. The Rev 8 history note (726-728) says "Row 2's MS1 rule still stands". Row 2 (736) says MS1 "does not invoke" the
  resource_compat oracle, which Rev 9 (720) and MS1.1 (1162-1166) replaced with "calls the typed phase gate at every milestone". A
  historical section still claims normative force for a superseded rule.

## 6. PLAN SHAPE (5 gaps)

What is good. The slice order is at 4080-4096. NOT BUILT, UNPROVEN and NOT STARTED rows name what is missing, either in the
compliance table or in the cited R30 block. The R30.0 status words are defined once (554-564). The owner decisions have defaults
(628-638).
Gaps:
- G6.1. MS1b is still headed "LANDED `3421428`" (1324), and its behaviour is headed "— GREEN" with "ad-hoc and hardened" (1362,
  1367, 1386). Yet C10 (4181) says UNPROVEN, and Rev 29 at 1327-1336 says the hardened leg is not reproduced. The slice looks closed,
  and the only recorded run it cites could not be checked.
- G6.2. The SCOPED ACCEPTANCE block (2970-2987) is labelled AUTHORITATIVE and "overrides the rest", but it still says "there is no
  `reaper_ready` constant yet" (2980-2981). It is not struck through. The next bullet (2988-3001) says the opposite.
- G6.3. No order is given for the Rev 30 fix-forwards. Dependency order (4080-4086) gained only a status sentence. It does not place
  the critical 4pa.55 fix, the new MS2c.6, or the hostless selftests that need no Mac (test-mac-build-script, test-mac-dmg-script,
  test-mac-gate-selftest, test-darwin-guard-selftest, test-mac-reaper-gate-guard). It also does not place the 4pa.66 rule "before
  any MS6.7 work" (3420). The next implementer has to rebuild this order from scattered blocks.
- G6.4. Some status words are outside R30.0. R29.2 rows 398 and 410 use "BUILT as a pre-ready hard-gate case". The ledger uses
  "[BUILT as a hard-gate case]" (3977), "[BUILT]" (3979), "hard-gate case built, run pending" (4004) and "(B) harness built" (4020).
- G6.5. Mac runtime claims in the body are stated as fact ("verified", "proven", "green", "VERIFIED") without the UNPROVEN or
  SUSPECTED marker that rule 8 and the frontmatter's rule require: 1492, 2422, 2861-2863, 2951, 2961, 3357. The compliance table
  marks them UNPROVEN, but the slice text does not.

Commands: diff of the rule; awk counts of the compliance table; grep and sed over the plan and build.zig; 9 named zig build steps plus
2 python unittest runs, as listed in check 4. No ssh, no display, no full `zig build test`, and no tests/mac script was run.
The scratch export, its caches and the logs were deleted with a guarded `rm -rf -- "${DIR:?}"` after this file was written.
