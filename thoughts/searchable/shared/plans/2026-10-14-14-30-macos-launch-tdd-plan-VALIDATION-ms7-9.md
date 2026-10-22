---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent (owner order: fresh Opus subagents)
plan: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md (rev 29, a7df5e3)
code: HEAD d0f1841
bd: zigBrowser-4pa.12
method: validate_plan; tests run only in a scratch export under unshare
---

# Validation: macOS plan MS7, MS8, MS9 + packaging/macos + tests/mac/mac_compile_only.sh

Worktree HEAD d0f1841 (judged HEAD only; untracked tests/agent_helper_posix_test.zig and
packaging/macos/install-and-run.sh ignored). Plan rev 29 (a7df5e3) sections MS7 (line 2882), MS8 (3020), MS9 (3091),
status tables R29.1(c) (306) and R29.2 (377-388), ledger (3290-3343).

## 1. Verdict

**MS7-9: FIX-FORWARD.** Almost nothing in this range is built. What is built (portable dock geometry, bubble text map,
the macOS netd spawner core, the C spawn/kill seam, the R4 compile-only harness, the runtime-staging scripts) is sound
and mostly well tested. But the plan's status is wrong in one important place: the MS7.6/7.8 "portable half" is marked
BUILT+REGISTERED, and the code does not exist. Its two build steps are red and are not in `test`. The only shipping
script (build-dmg.sh) cannot make a working app. MS9 has no code.

**Update after the test runs.** The coordinator supplied a scratch export at HEAD d0f1841, and I ran the seven named
steps (section 4). The results confirm C1 and the evidence behind M2. The verdict is unchanged. One surprise: the R4
selftest failed when run as namespace root, and passed when run as the real user with bash as PID 1 (m12).

## 2. Table

| Slice / behavior | Built (file:line) | Production caller | Test registered (build.zig) | Test can fail? | Verdict |
|---|---|---|---|---|---|
| MS7.0 portable drawer exports on macOS | src/agent_drawer.zig:602-636 (export gate includes .macos) | None on macOS. `applyAgentDrawer` returns false off Linux/Windows (src/webkit.zig:134) | `cross-check-drawer-mac` :477-495, in `cross-check` (:494) but NOT in `test` (test uses only the `cross_check` command, :3921) | Yes, a dropped export fails. Symbol presence only | KEEP (fix the plan's "in test" claim) |
| MS7.1 dock geometry (portable) | pageRect :87, appKitFrame :98, C exports :666-673 | None (no .m file) | `test-agent-drawer-appkit` :749, in `test` :3614 | Yes, real assertions over a 10x13 grid. RUN: exit 0, 7/7 tests | KEEP |
| MS7.1 AppKit dock view | none (no src/agent_drawer_mac.m) | - | - | - | NOT STARTED (plan correct) |
| MS7.2 icon / MS7.3 fold | only the shared GTK helpers (classifyGesture :27, ease :122); no AppKit code | - | - | - | NOT STARTED (plan correct) |
| MS7.4 bubble text (portable) | appkitCharAt :387, appkitShown :421, appkitOriginalOffset :448, bubbleLayoutContiguous :474, exports :713-729 | None | `test-agent-drawer-appkit-text` :780, in `test` :3615 | Yes. Fixed rows plus a 400-case seeded property, 200 KiB rows, C-export parity. RUN: exit 0, 7/7 tests | KEEP (doc fix) |
| MS7.4 ZbBubbleView + Edit menu | none. No NSMenu anywhere in src/wkwebview_shim.m | - | - | - | NOT STARTED (plan correct) |
| MS7.5 Secrets window (portable) | header only: src/agent_secrets_window_mac.h:23. No agent_secrets_window_mac.zig | - | unregistered. tests/agent_secrets_window_mac_logic_test.zig imports a missing module | It is a compile-error red | FIX-FORWARD (rename the symbol, M3) |
| **MS7.6/7.8 card press (portable)** | **NOT BUILT.** agent_drawer.zig has no `Approver`, `cardPress` or `zb_drawer_card_press` | - | `test-agent-drawer-card-press` :767 and `check-card-authority-mac` :534 exist, but neither is in `test` or `cross-check` | Both fail now. Their headers say "RED ... not in test". RUN: card-press exit 1 (5 compile errors); card-authority exit 1 (R1/R2, both arches) | **Plan status FALSE → FIX-FORWARD (C1)** |
| MS7 compiled two-Mac gate | tests/mac/ms7_appkit_{gate.sh,case.py,check.py,probe.m}, tests/e2e/ms7_appkit_gate_test.py | n/a | unregistered | Cannot pass at MS7: check.py:198 still needs `source == "chain"` | FIX-FORWARD (K6 not applied, M1) |
| Lexical oracles | tests/e2e/mac_drawer_bubble_inert_test.py (1012 lines), mac_drawer_card_authority_test.py (933) | n/a | unregistered | They parse a file that does not exist | REWRITE → delete (m8) |
| MS7.7 census, MS7.9 ownership | none. `zb_drawer_debug_live_count` is not in the macOS shim | - | - | - | NOT STARTED (plan correct) |
| MS8.0 minters in the macOS build | src/agent_tools.zig:200-210, `_ = agent_tools` on every OS (src/app.zig:386) | None on macOS. `agent_tools.start` is Linux-only (app.zig:477-479), so on macOS the minters always return 0 | `cross-check-agent-tools-mac` :504-528, in `test` :3923 | Symbol presence only. A minter that always returns 0 (today's macOS behaviour) passes. RUN: exit 0 | FIX-FORWARD (M2) |
| MS8.1 spawner core | src/agent_host_posix.zig (spawnNetd :206, stopWith :144); src/agent_spawn_posix.c | spawnNetd: none. agent_spawn_posix.c: app.zig:205 (MS5 setup) | inline tests :825-831 and `test-agent-spawn` :854 (unshare user+pid), both in `test` :3618-3619 | Yes. Real child processes inside a private PID namespace. RUN: exit 0, 12/12 tests + kill-group 8 cases | KEEP |
| MS8.1 helper under MacSeatbeltBackend | none | - | - | - | NOT STARTED (plan correct) |
| MS8.2a helper core | tests/agent_helper_core_test.zig only; no src/agent_helper_core.zig | - | unregistered (honest red) | It is a compile-error red | KEEP as red |
| MS8.2b / 8.2c / 8.3 | not in HEAD / none / none | - | - | - | NOT STARTED (plan correct) |
| MS9.0 spike, 9.1, 9.2 | none. No `notarytool`, `stapler` or `--options runtime` in tests/, packaging/, tools/ or build.zig | - | - | - | NOT STARTED. Preconditions open (M6, M7) |
| packaging/macos/build-dmg.sh | build-dmg.sh:71-91 | the only release path | none | - | REWRITE as MS1c (C2, M4) |
| stage_agent_runtime.sh, merge_universal_tree.py, relocate_python_framework.py, sdk_pth.py, build_site_packages.sh, ms5_inventory.py | packaging/macos/* | hand-run staging (MS5.1c) | mac_relocate_test :3022, mac_sdk_pth_test :3028 and mac_merge_universal_test :3038 are in `test` (:3683-3684); staging itself is hand-run on the Macs | Pure parts yes; the Mac parts run only by hand | KEEP |
| tests/mac/mac_compile_only.sh (R4) | 321 lines, read only | n/a | the selftest is `test-mac-compile-only` :3595, in `test` :3596 | Hostless selftest with stubs; the real SBPL profile never runs off a Mac. RUN: exit 1 as namespace root, exit 0 as the real user with bash as PID 1 (m12) | KEEP (fix the selftest) |

## 3. Findings

### CRITICAL

**C1. The plan says MS7.6/7.8's portable half is BUILT+REGISTERED. It is not built, and its tests are red and
unregistered.** CONFIRMED (code read).
- `grep 'Approver\|cardPress\|card' src/agent_drawer.zig` finds nothing. tests/agent_drawer_card_press_test.zig needs
  `drawer.Approver`, `drawer.cardPress` and `drawer.zb_drawer_card_press`. Its own header (line 15) says "RED until the
  green adds them; build step `test-agent-drawer-card-press`, not in `test`".
- `check-card-authority-mac` (build.zig:530-549) has the comment "RED until the macOS build defines the minters and
  the bridge; not in `test` until the green". Its R1 needs `toolsApprove`/`toolsDeny`/`zb_drawer_card_press`, which are
  absent. Every commit that touched these files is labelled "RED ... UNREGISTERED" (7472674, 46b910f, 2102ae3,
  44e061e).
- **CONFIRMED by run:**
  - `zig build test-agent-drawer-card-press` exits 1 with 5 compile errors: "root source file struct 'agent_drawer' has
    no member named 'Press'".
  - `zig build check-card-authority-mac` exits 1 on both arches: "R1 aarch64/x86_64: _agent_drawer.toolsApprove /
    toolsDeny / zb_drawer_card_press is not defined in the object", plus the R2 rows.
- Wrong plan text: R29.1(c) row "MS7.6/7.8 (portable half)", R29.2 line 378, R29-MS7 "Registered Linux evidence that
  DOES count: `check-card-authority-mac`", and ledger MS7.6 and MS7.8 "[portable BUILT+REGISTERED]".
- Minimum fix: change these entries to RED-UNREGISTERED and remove `check-card-authority-mac` from the "counts"
  evidence until its green lands.

**C2. The release script cannot make a working or distributable app.** CONFIRMED (static). The plan admits this (K5,
MS1c NOT STARTED), but it is still the only path to an artifact.
- build-dmg.sh:71 copies only the executable. libwkwebview_shim.dylib never reaches Contents/Frameworks.
- It builds through tests/mac/build-on-mac.sh, which tars the uncommitted WORKING TREE (build-on-mac.sh:32). The build
  is native x86_64 on the Intel host only: not universal, and not tied to a commit.
- It signs with `codesign --force --sign - --deep` (:91): ad hoc, `--deep`, with no entitlements and no
  `--options runtime`. The header still says "Build a signed .dmg".
- Minimum fix: do MS1c as the plan says (export a commit, ship the dylib, lipo-verify, sign inside-out, check with
  `otool -L`). Until then, rename the header to "ad-hoc dev dmg".

### MAJOR

**M1. Decision K6 is in the plan but not in the code, so the MS7 compiled gate can never pass at MS7.** CONFIRMED.
- tests/mac/ms7_appkit_check.py:198-200 still fails on "no card presented by the real chain". There is no milestone
  argument, no fixture-entry branch, and no `zb_drawer_present_fixture_card` anywhere.
- ms7_appkit_probe.m:11 says the card is "absent until MS8".
- Fix: add the milestone argument (`fixture` at MS7, `chain` at MS8.3) and a red row for "no fixture card entry".

**M2. The macOS minters do nothing, and MS8.0's test cannot see that.** CONFIRMED.
- `agent_tools.start` runs only on Linux (app.zig:477-479). On macOS `server` stays null and `cards` is never
  initialised. `zb_agent_tools_approve`/`_deny` (agent_tools.zig:200-210) always return 0.
- `cross-check-agent-tools-mac` only checks that the symbols exist, so this always-0 minter passes.
- CONFIRMED by run:
  - `zig build cross-check-agent-tools-mac` exits 0 on HEAD, the always-0 minter included.
  - The `check-card-authority-mac` run shows `_agent_tools.zb_agent_tools_approve is referenced by {}` on both Darwin
    objects. Nothing in the macOS build calls the minters.
- No plan slice (MS7.8 fixture card, MS8.2c) names "start the cards on macOS", and the MS7.8 fixture card needs it.
- Fix: add that wiring step and a runtime row (a macOS-target unit, or the compiled gate's `grants` row) that fails
  while the minter returns 0.

**M3. Two different C functions share one name.** CONFIRMED.
- src/agent_secrets_window_mac.h:23 declares `int zb_secrets_window_open(unsigned long long window_id)`: open or focus
  the window.
- src/agent_secrets_window.h:56 and .c:188 already define `int zb_secrets_window_open(void)`: "is the window open?".
- Any translation unit or Zig extern that sees both headers breaks, and callers get the wrong meaning. The mac header
  also points to a non-existent agent_secrets_window_mac.zig.
- Fix: rename the mac entry (for example `zb_secrets_window_mac_show`) before the green.

**M4. The release and build scripts turn off host-key checking.** CONFIRMED.
- build-dmg.sh:21-24 and tests/mac/build-on-mac.sh:21 use `StrictHostKeyChecking=no` with `UserKnownHostsFile=/dev/null`.
- These scripts send source to the Mac and copy the .dmg back (build-dmg.sh:116). Anyone who can sit between the two
  machines could swap the artifact.
- The MS7 gate and mac_compile_only.sh already use `StrictHostKeyChecking=yes`.
- Fix: use strict host keys with a pinned known_hosts file.

**M5. K6's fixture-card seam would ship a debug hook inside the release binary.** SUSPECTED (plan design).
- The plan puts `zb_drawer_present_fixture_card` behind `--e2e-protocol`, which is a public flag.
- R29-SAFETY itself says such hooks must sit behind a build option that is absent from the shipping build.
- Here the hook would show a production approval card built from caller-chosen parameters.
- Fix: compile the entry only in a test build option, and add a red that proves the release build lacks the symbol.

**M6. MS9 would sign with an entitlement manifest that does nothing.** SUSPECTED (Apple semantics; not run on a Mac).
- packaging/macos/entitlements.plist holds one key, `com.apple.security.network.client`. That key only matters under
  App Sandbox, and nothing sets `com.apple.security.app-sandbox`. Under the hardened runtime alone it has no effect.
- So the file's comment ("derived ... justified by a concrete feature") is wrong.
- MS9.1 would also re-sign the bundled Claude CLI and the PSF Python with this manifest. That throws away their own
  entitlements, and a Bun-based CLI very likely needs JIT entitlements.
- Fix: widen the MS9.0 spike to cover the CLI, python3.12 and the lipo'd .so files. Consider keeping Anthropic's own
  signature on the CLI instead of re-signing it.

**M7. The bundle layout may fail strict codesign verification and notarization.** SUSPECTED.
- ms5_inventory.py and stage_agent_runtime.sh put agent-host/ under Contents/Frameworks.
- That folder would hold zb_agent_host/*.py, runtime.json, a .pth and site-packages data.
- Apple expects only code under Contents/Frameworks, with data in Contents/Resources. `codesign --verify --strict`
  (MS9.2) can reject this.
- MS9.1's signing order (helper, CLI, frameworks, .app) also does not list the site-packages extension modules.
- Fix: add this to the MS9.0 spike before MS1c fixes the layout.

### MINOR

- **m1. Stale test headers.** CONFIRMED. tests/agent_drawer_appkit_test.zig:23 and agent_drawer_appkit_text_test.zig:23
  say "RED ... not in `test`", but both are in `test` (build.zig:3614-3615). This is the R29-REG T-W6 stale-header case.
- **m2. Stale doc comment.** CONFIRMED. src/agent_drawer.zig:726 says `zb_drawer_bubble_layout_contiguous` returns
  "1 when a bubble ... is a label, 0 when a read-only text view". The AppKit amendment (one NSTextView per bubble)
  replaced that model.
- **m3. Wrong "in test" claim for MS7.0.** CONFIRMED. The plan (R29.1(c) MS7.0) says `cross-check-drawer-mac` is "in
  `cross-check` and `test`". It is in `cross-check` only.
- **m4. Duplicated logic.** CONFIRMED. appkitShown/appkitOriginalOffset (agent_drawer.zig:421-472) repeat the
  breakRuns/originalOffset loops (:354-505) with a different character model. One char-iterator would remove the
  duplication.
- **m5. The MS7.1 property is narrower than the plan says.** CONFIRMED. The ledger promises 1,000 random (w, h, ratio)
  seeds with ratio in [0.1, 0.9]. The test uses a fixed grid, and `drawerRect` has a fixed 0.4 ratio with no ratio
  parameter. Amend the plan or the test.
- **m6. Stale header, and no exit watch after start.** CONFIRMED.
  - agent_host_posix.zig:15-18 still says the orchestration is "pending", but spawnNetd exists.
  - spawnNetd closes netd's stdout read end and keeps no exit watch. On Linux a `g_child_watch` notices a netd that
    dies after start; on macOS nothing would. MS8.1 proper should add an exit watch.
- **m7. Three small spawner issues.** CONFIRMED.
  - agent_host_posix.zig `readFirstPort` treats a poll EINTR (`ready <= 0`) as a network failure.
  - `pipe()` then `setCloexec` is not atomic.
  - `zb_agent_spawn_group` (the non-io variant) has no POSIX_SPAWN_CLOEXEC_DEFAULT on Darwin.
- **m8. Dead test code.** CONFIRMED. The two lexical oracles (1,945 lines) are unregistered and parse a missing file.
  The plan already says they are not evidence. Delete them now rather than carry them.
- **m9. Probe and gate limits.** SUSPECTED.
  - ms7_appkit_probe.m:383's watchdog `_exit(70)` path may skip restoring the user's pasteboard.
  - The DYLD_INSERT_LIBRARIES probe stops working once the app is hardened-runtime signed (MS9), so this gate is
    dev-build only. Say so in the plan.
- **m10. Untested sandbox profile.** CONFIRMED. mac_compile_only.sh's SBPL profile only runs on a Mac (the selftest
  stubs sandbox-exec). The regex escape `rx` (line ~205) escapes only `.`. Otherwise the harness is careful: exact-commit
  export, blob check, one ssh session per leg, strict host keys, BatchMode, no signals, validated `find -delete`. KEEP.
- **m12. The R4 selftest fails unless it runs as a normal user under a PID 1 that reaps orphans.** CONFIRMED by run.
  This was the surprise.
  - Under `unshare --user --map-root-user --pid --fork --mount-proc zig build test-mac-compile-only`, it exited 1 with
    7 failed cases:
    - "an undeletable root fails: exit 0, want a failure". As namespace root, the `chmod 500` lock does not stop the
      delete.
    - 6 rows of "stub process N outlived its 5 s". The selftest checks `/proc/$p`, and the orphans it waits for are
      left as unreaped zombies under the namespace's PID 1 (the zig build runner).
  - The same script under `unshare --user --map-current-user --pid --fork --mount-proc bash ...` (real uid, bash as
    PID 1) exits 0.
  - The harness itself is fine (the honest both-arch case passed in both runs).
  - Minimum fix: make the selftest refuse to run as root, and treat zombie state (`/proc/$p/stat` field 3 = Z) as
    gone, or run its stubs under a reaping wrapper.
- **m11. Small packaging issues.** CONFIRMED.
  - The Python pkg pin is written twice (stage_agent_runtime.sh:25 and agent_runtime_pins.json:4).
  - merge_universal_tree.py `_record_line` does not CSV-quote a path that contains a comma.

### Checked and correct in the plan

- No src/agent_drawer_mac.m.
- No main menu in the shim.
- `zb_app_set/get_agent_drawer` not on macOS.
- The minters are called only from agent_drawer.c:1218,1228.
- MS8.1 core is registered.
- MS8.2a is an unregistered red.
- MS9 is not started.
- build-dmg.sh copies only the executable.
- The cited build.zig lines (:477, :504, :534, :749, :767, :780, :3923) match HEAD.

## 4. Commands run (all read-only)

| Command | Exit |
|---|---|
| `cat` of the brief and `/home/maceo/.claude/commands/validate_plan.md`; `sed -n` of plan sections | 0 |
| `git -C <worktree> log --oneline -1`, `git status --short`, `git ls-files` (to a scratch list) | 0 |
| `git -C <worktree> archive HEAD \| tar -x -C <scratch>/validate-ms7-9/tree` | BLOCKED by the subagent hook, not run |
| `git -C <worktree> log --oneline -6 -- tests/agent_drawer_card_press_test.zig tests/e2e/mac_card_authority_objects_test.py` | 0 |
| `grep -n` / `sed -n` over build.zig, src/agent_drawer.zig, agent_tools.zig, app.zig, webkit.zig, agent_host_posix.zig, agent_spawn_posix.c, agent_secrets_window*.h/.c, tests/*, tests/mac/*, packaging/macos/* | 0 (an empty grep returned 1) |
| `curl` localhost voice notify | 0 |

### Test runs, after the coordinator made the export

The coordinator made the export at validate-ms7-9/tree. I checked that it is HEAD d0f1841: build.zig and
src/agent_drawer.zig have the same sha256 as the worktree, and the untracked files are absent.

Each step ran as `cd tree && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS timeout 1500 unshare --user
--map-root-user --pid --fork --mount-proc -- zig build <step> -j4 --cache-dir validate-ms7-9/zc --global-cache-dir
validate-ms7-9/zgc`. Steps ran one at a time, with no display.

| Step | Exit | Result |
|---|---|---|
| `test-agent-drawer-appkit` | 0 | 7/7 tests pass |
| `test-agent-drawer-appkit-text` | 0 | 7/7 tests pass |
| `test-agent-spawn` | 0 | 12/12 spawnNetd tests and the kill-group C test (8 cases) pass |
| `test-mac-compile-only` | **1** | 7 selftest cases fail as namespace root (m12) |
| selftest rerun: `unshare --user --map-current-user --pid --fork --mount-proc -- bash tests/mac/mac_compile_only_selftest.sh` (TMPDIR in validate-ms7-9) | 0 | PASS, all cases |
| `cross-check-agent-tools-mac` | 0 | both arches define the 4 symbols (M2: passes with an inert minter) |
| `test-agent-drawer-card-press` | **1** | 5 compile errors, `agent_drawer` has no `Press` / `cardPress` (C1) |
| `check-card-authority-mac` | **1** | R1/R2 fail on aarch64 and x86_64: no toolsApprove/toolsDeny/zb_drawer_card_press, and the minters have no referrer (C1, M2) |

The tree, both zig caches, the logs and the runner script were then deleted with guarded `rm -rf -- "${DIR:?}"`.
