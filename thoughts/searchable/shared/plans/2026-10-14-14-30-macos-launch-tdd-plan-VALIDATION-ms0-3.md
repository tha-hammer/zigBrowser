---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent (owner order: fresh Opus subagents)
plan: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md (rev 29, a7df5e3)
code: HEAD d0f1841
bd: zigBrowser-4pa.12
method: validate_plan; tests run only in a scratch export under unshare
---

# Validation: macOS launch plan rev 29, slices MS0 / MS1 / MS1b / MS2 / MS3 (range "ms0-3")

Code read at worktree HEAD `d0f1841` (plan rev 29 baseline `e4f705f`; no src/tests/packaging drift relevant here).
Tests run only in the coordinator-made scratch export (`validate-ms0-3/tree`, HEAD d0f1841).
No Mac, VM or ssh host was contacted, so no Mac runtime test was run; every Mac finding below is from code.

## 1. Verdict

**ms0-3: FIX-FORWARD.** MS0 is sound (KEEP). MS1/MS1b are usable tooling but their gates are not
reproducible and partly tautological. MS2/MS3 are a real, wired WKWebView port with a careful job/phase
model, but four product defects are confirmed by code read: the browser QUITS on any failed page-initiated
or recovered load, `page.dialogs` reports the wrong window id after a popup closes, cookie calls ignore
their timeout, and the native close button leaves a live, still-registered window. None of the MS2/MS3
tests run anywhere on Linux, and three of the four Mac gates (MS2b, MS2c, MS3) have no build step.
No REWRITE is needed.

Counts: CRITICAL 1, MAJOR 7, MINOR 11.

## 2. Table

| slice / behaviour | built (file:line) | production caller | test registered (build.zig line) | test can fail? | verdict |
|---|---|---|---|---|---|
| MS0.1 SandboxBackend + LinuxBwrapBackend | `agent/host/zb_agent_host/sandbox.py:201,232-372` | yes: `launch.py:97,106` -> `helper_argv`/`_LINUX_BACKEND`; `setup.py:446-461`, `options.py:29`, `token.py:164` | `test_backend_contract` :3194, in `test` :3879 | YES: ran it 28/28 OK; mutant (swap `--die-with-parent`/`--new-session`) -> 16 failures | KEEP (minor fixes) |
| MS0 Lifetime -> C spawn policy | `sandbox.py:356-366` (Python mirror only) | NO: every C site hard-codes `zb_spawn_policy_linux(0)` (`app.zig:140`, `agent_helper.c:732`, `agent_login.c:324,427`, `agent_host.c:228`) | only a value-equality test (`test_backend_contract.py:534`) | only if someone edits the Python constant | FIX-FORWARD (C-W2 census) |
| MS1.1 fat census + resource_phase | `tests/e2e/mac_universal_test.py:146-231` | gate only (`tests/mac/gate.sh`) | pure unit `mac_universal_census_test` :2993, in `test` :3679 | unit YES (27 OK); Mac census cannot see an undeclared non-Mach-O file (ran a demo: 0 failures) | FIX-FORWARD (D-W3) |
| MS1.2 exec-arch readback | `src/automation/telemetry.zig:159,308`; `tests/mac/exec_arch_probe.py` | `build.exec_arch` is on every automation root span (production) | `mac-gate` :241-242, NOT in `test` | YES on a Mac (comptime slice arch; Rosetta runs the x86 slice -> mismatch) | KEEP |
| MS1.3 entitlements | `packaging/macos/entitlements.plist:29` (one key) | NOT used by `build-dmg.sh:92` (ad-hoc `--deep`, no entitlements) | static check in `mac-gate` only; `release_least_privilege` unit in `test` | Mac check is tautological (signs with the plist, compares to the same plist) | FIX-FORWARD |
| MS1.4 fail-closed runner | `tests/mac/gate.sh:47-51,117-120,177-183` | n/a | `mac-gate` only; no hermetic selftest (Windows gate has one) | arm-host-unset path yes; rest unproven off-Mac | FIX-FORWARD |
| MS1b signed run | `build.zig:4190-4237` (shim dylib, chained fixups); `tests/mac/ms1b_signed_gate.sh` | yes: every macOS build links the dylib | `ms1b-gate` :247-248, NOT in `test` | ad-hoc only, no hardened leg, pixel check skipped (`--no-uniform-check`) | FIX-FORWARD (P4/T-W3 as planned) |
| MS2a.1-3 routed cmds + job model | `src/automation_macos_port.zig:54-385`; `src/wkwebview_shim.m:1225-1740,2141-2365` | yes: `app.zig:464,626` | `ms2a-gate` :253-254 (Mac-only, NOT in `test`); 16 `mac_ms2a_*` | on a Mac yes (mutant-style reds exist); on Linux nothing runs; Zig side compiles in `cross-check` (`test` :3921) | FIX-FORWARD |
| MS2b.1 native click/key/text | `wkwebview_shim.m:2370-2766` | yes (vtable `:62-66`) | none: `tests/mac/ms2b_gate.sh` hand-run, no step | on a Mac only | FIX-FORWARD (register) |
| MS2b.2 dialogs | `wkwebview_shim.m:1744-1815` | yes | none (ms2b_gate.sh) | no test opens a dialog in a popup after another popup closed | FIX-FORWARD (bug F3) |
| MS2b.3/4 input files, screenshot | absent (link-time) | n/a | n/a | n/a | NOT STARTED (matches plan) |
| MS2c.1-4 windows/health/recover/crash | `wkwebview_shim.m:1821-1960,564-760` | yes | none: `tests/mac/ms2c_gate.sh` hand-run | Mac only; close-button path untested | FIX-FORWARD (F1, F4) |
| MS3.1 profile store | `wkwebview_shim.m:2771-2843`; `app.zig:497-507` | yes | none: `tests/mac/ms3_gate.sh` hand-run | Mac only | FIX-FORWARD (F6) |
| MS3.2 config flags | `src/webkit.zig:40-71`; `src/backend_flag.zig:31-44` | yes: `app.zig:435,573` | `backendFlagDecision` Zig tests in `test`; Mac e2e hand-run | `--renderer` refusal yes; hw-policy "unchanged" read absent (T-W4) | FIX-FORWARD |
| MS3.3 cookies | `wkwebview_shim.m:1963-2135`; `src/automation_macos_cookie_port.zig` | yes: `app.zig:627` | none on Linux (port's Zig tests `SkipZigTest` off-Mac); Mac e2e hand-run | Mac only; no timeout case | FIX-FORWARD (F5) |

## 3. Findings

**F1 CRITICAL — the macOS browser quits on any failed page-initiated or recovered load. CONFIRMED (code + the test oracle).**
`wkwebview_shim.m:781-790` exits the whole app (`requestExit:ZB_EXIT_LOAD_FAILED`, which closes every
window) for every load failure that is not a tagged automation navigation. That includes a link the user
clicks to a dead host, a page's own `location=` redirect, a response that policy cancels
(`decidePolicyForNavigationResponse` -> cancel, `:848`), and any policy-opened subwindow load. `loadURI:`
(`:515-532`) also arms a 15 s timer whose expiry exits the app (`:629`); `recoverByReplacingWebView`
reloads through `loadURI:` (`:753`), so a recovered window on a slow or down server ends the session.
`tests/e2e/mac_ms2a_user_nav_failure_test.py` asserts this exit as correct. Linux does not do this: its
`on_window_load_failed` (`webkit_shim.c:1065-1106`) records the error and keeps running.
Minimum fix: exit only for the primary window's initial load (the M9 single-load contract), and only
until its first finish. After that, record the failure and emit LOAD_FAIL without exiting. Recovery
reloads should use the tagged/routed path with no exit timer. Rewrite the user-nav-failure test to
assert that the browser stays alive.

**F2 MAJOR — cookie calls block forever if WebKit never answers. CONFIRMED (code).**
`zb_cookies_get_all`/`_add`/`_delete` claim the job (DISPATCHING) and then issue an async
`WKHTTPCookieStore` call (`:2021,2078,2102`), but they never call `zb_job_inflight`. While the job is in
DISPATCHING, `zb_job_wait` waits with no deadline (`:1615-1618`), so the caller's `timeout_ms` is
ignored for the whole cookie-store round trip. A wedged network process hangs the server thread. Every
other async op (eval `:2327`, nav `:2181`, click `:2410`) does call it.
Minimum fix: call `zb_job_inflight(job)` right after each async submit. Add a red that uses the
`zb_automation_debug_cookie_delay` seam (MS3 row), or a held callback, and asserts a Timeout.

**F3 MAJOR — `page.dialogs` reports the wrong window id after a popup closes. CONFIRMED (code).**
`zb_automation_list_dialogs` emits `"window": idx+1`, the position in the registry (`:1768`). But
`zb_automation_respond_dialog` looks windows up by their stable `windowId` (`:1200-1209`), as do
`list_windows` and GTK (`webkit_shim.c:4607-4608` uses `win->auto_id`). After popup 2 closes, a dialog
in popup 3 is listed as window 2, and answering it returns NO_DIALOG or answers the wrong window.
No test covers a dialog in a later popup.
Minimum fix: emit `@(h.windowId)`. Add a red: open two popups, close the first, raise a confirm in the
second, and assert the listed id equals its `page.list` id and that answering it works.

**F4 MAJOR — the native close button leaves a live, registered window. CONFIRMED (code).**
Windows are created with `NSWindowStyleMaskClosable` (`:473`), but `ZBWindowHost` is not an
`NSWindowDelegate`; nothing handles `windowWillClose:`. Clicking the red close button hides the NSWindow,
yet the WKWebView keeps running (audio, JS), stays in `app.windows`, still shows in `page.list`, and still
accepts automation. Closing the primary leaves a windowless process
(`applicationShouldTerminateAfterLastWindowClosed` returns NO, `:354-357`), and there is no main menu
(no Cmd-Q or Cmd-W; zero `NSMenu` uses). The plan's MS2c.5 "one shared destroy path" names this close
button. That slice was moved to MS7.9, but this half has no drawer dependency.
Minimum fix: set the host as the window delegate, and in `windowWillClose:` run the same `close` +
`removeWindow:` path that `webViewDidClose:` uses (`:878-888`). Decide what closing the primary should do.

**F5 MAJOR — Mac gates build from the shared, unpinned working tree into one shared remote dir. CONFIRMED (code).**
`tests/mac/build-on-mac.sh:32` tars the live working tree (uncommitted files and other agents' WIP
included, errors hidden by `2>/dev/null`) to the fixed path `/tmp/zb_worktree_mac.tar`. It then extracts
over `$HOME/zigBrowser` on the Mac without clearing it, so deleted files survive. Every gate
(`gate.sh`, `ms1b`, `ms2a`, `ms2b`, `ms2c`, `ms3`) shares that tar path and remote dir. A gate result is
not tied to a commit, two concurrent gates clobber each other, and a stale test or fixture can produce a
false green. All ssh/scp also use `StrictHostKeyChecking=no` and `UserKnownHostsFile=/dev/null`.
Minimum fix: build the tar from `git archive <sha>` into a `mktemp` file, extract into a fresh per-run
remote dir (`~/zb-gate-<sha>-<nonce>`), print the sha in the PASS line, and pin known_hosts.

**F6 MAJOR — on macOS, pacing (daily-cap) state never persists for a new `--profile-dir`. CONFIRMED (code).**
macOS `applyProfileDir` creates no directory (`app.zig:497-507`; the shim says "No directory is created",
`:2796`). The pacing store writes `<profile>/automation-pacing.json` with `atomic_file.replaceJson`,
which does not create parent directories (`src/atomic_file.zig:9-33`). So for a fresh `--profile-dir`,
every save fails and the social/X daily caps reset on each restart. Linux creates the dir.
Minimum fix: `makePath` the profile dir on macOS too (it is harmless next to the WebKit-managed store).
Add a red that restarts with the same fresh `--profile-dir` and asserts that `actions_today` survives.

**F7 MAJOR — the MS1.3 entitlement check cannot fail meaningfully, and the one key does nothing. CONFIRMED (code).**
`gate.sh:85` signs the copy with `packaging/macos/entitlements.plist`, and `mac_universal_test.py:327-330`
then asserts that the signature equals the same plist. That catches only codesign dropping a key.
`com.apple.security.network.client` is an App Sandbox entitlement, and the app has no
`com.apple.security.app-sandbox`, so the key has no effect. Its comment ("the CLI/helper reach the egress
proxy") is wrong, and the header still says "Verified on Mac: NOT YET". `build-dmg.sh` never uses the
manifest. The plan calls this "BUILT+REGISTERED (static)".
Minimum fix: either derive keys from a failing feature probe under `--options runtime`, or relabel MS1.3
as "placeholder, no derived keys". Drop or justify `network.client`.

**F8 MAJOR — none of the MS2/MS3 runtime is exercised by `zig build test`; three gates have no step. CONFIRMED (build.zig grep).**
None of the 50 `tests/e2e/mac_ms2*`/`mac_profile*`/`mac_cookie`/`mac_config_flags` files is referenced in
`build.zig`. Only `ms2a-gate` is a step (Mac-only). `ms2b_gate.sh`, `ms2c_gate.sh` and `ms3_gate.sh`
are hand-run. On Linux the `.m` file is never compiled; `cross-check` only compiles the Zig side and
text-checks symbol names. The pure Zig parsers in `automation_macos_port.zig` (`parseWindows` etc.)
could run on Linux but have no tests, and the cookie port's two Zig tests always `SkipZigTest` off-Mac
(`automation_macos_cookie_port.zig:131-145`). No approved-run manifest exists for any Mac gate (R29-REG).
Minimum fix: as the plan says, add `ms2b-gate`/`ms2c-gate`/`ms3-gate` steps plus last-run manifests.
Also either move the shared parsers into one module tested on Linux (see F14) or add Linux tests for them.

**F9 MINOR — the plan's "excluded from test by the unguarded list" is wrong.** `build.zig:4045` is the
display-guard skip list. The Mac gates are out of `test` only because `test` never depends on them.
Doc fix.

**F10 MINOR — `zb_version_line` prints the WebKit version as zigBrowser's version. CONFIRMED.**
`wkwebview_shim.m:2975` passes `version` twice: `zigBrowser 20621… (WKWebView 20621…)`. The ABI table's
claim that it "records executing arch" is false; the arch is in `telemetry.zig:159`. Fix the format
string and the table row.

**F11 MINOR — MS0 leftovers.** (a) There is no frozen golden for the login `build_argv` (T-W1; zero
"login" hits in `test_backend_contract.py`). (b) `launch.py:97` reaches the private `_LINUX_BACKEND`
(I-W9), and the relay/boot lines are duplicated between the chat and login branches (`:104` vs `:114`).
(c) The `SandboxBackend` Protocol (`sandbox.py:210-229`) is never checked: `launch_spec` lacks
`network=` and `network()` lacks `session` (I1).

**F12 MINOR — gate.sh comments and messages are stale.** "push the ONE universal signed binary"
(`gate.sh:107`) — it pushes the unsigned one. `ms1b_signed_gate.sh:148` prints "(expected RED today)" on
an intel-leg failure. The ms1b comment promises the green would route the PNG to the PIL host; it does not.
`mac_resource_compat.py` is called with the Linux `zig-out zig-out` (`gate.sh:96`); harmless at MS1 but
misleading.

**F13 MINOR — debug hooks inert test covers 4 of 13 `ZB_DEBUG_*` hooks.** `mac_ms2a_hook_inert_test.py`.
All 13 do share `zb_auto_test_hooks_enabled()` (checked by grep), but `--e2e-protocol` is a public flag
(R29-SAFETY, P-W4). Known; keep it tracked.

**F14 MINOR — ~150 lines duplicated between the GTK and macOS ports.** `parseRecovered` and `mapCode`
are identical; `parseWindows`/`parseDialogs` differ only in a comment (diffed). Both sit over the same C
ABI. Move them to one shared module (and test it on Linux, F8).

**F15 MINOR — `--media-source off` on macOS 14+ leaves `ManagedMediaSource`. SUSPECTED.** The user script
(`:504-511`) clears only `MediaSource`/`WebKitMediaSource`. Safari 17 exposes `ManagedMediaSource`, so the
Instagram-deadlock mitigation may be incomplete. `ZIGBROWSER_MEDIA_SOURCE` is also ignored on macOS
(`webkit.zig` `applyMediaSource` returns early off Linux).

**F16 MINOR — profile identity details.** The store lives under a path-derived UUID in WebKit's own
location; deleting the `--profile-dir` folder does not delete its logins, and nothing documents that
(D-W2 covers only the spelling). Also `pthread_cond_timedwait` uses CLOCK_REALTIME (`:1595-1598`), so a
wall-clock jump stretches or shortens every ABI timeout.

**F17 MINOR — stale comments.** The port header says windows, dialogs and native input "keep the
PagePort unsupported defaults" (`automation_macos_port.zig:10-14`), but they are wired. The shim says it
uses "a dispatch_semaphore" (`:1196`), but it uses pthread jobs. Test headers say "RED (unregistered)"
(`mac_config_flags_test.py:2`, `mac_cookie_test.py:2`, `mac_profile_persist_test.py:2`; T-W6).

**F18 MINOR — every popup steals focus.** `createWindowWithWebView` calls `makeKeyAndOrderFront` +
`activateIgnoringOtherApps:YES` (`:387-388`; the API is deprecated on macOS 14).

**F19 MINOR — NUL bytes truncate silently at the Zig->C boundary. SUSPECTED.** `dupeZ` of a URL or cookie
field that contains `\0` (allowed via JSON `\u0000`) truncates it at the C side
(`automation_macos_port.zig:103`, cookie port `:90-97`). Only `respondDialog` refuses NUL (`:236`). Refuse
embedded NUL before the ABI, as `respondDialog` does.

Checked and sound (no finding): the job state machine (`:1464-1645`), the loop-end drain (`:2855-2860`),
the lock-backed window snapshot with no main-queue marshal (`:1821-1880`), stable window ids
(`:369,1200`), the e2e gate on all 13 hooks, the routed-nav identity tagging (`:2141-2195`), and the
comptime slice arch as proof of the executing arch.

## 4. Commands run (all outside the shared worktree except read-only reads)

| command | exit |
|---|---|
| `git -C <worktree> archive HEAD \| tar -x -C …` (own export) | BLOCKED by hook; the coordinator made `validate-ms0-3/tree` instead |
| read-only `git log/rev-parse`, `grep`, `sed`, `diff` over the worktree | 0 |
| `cd tree/agent/host/tests && unshare --user --map-root-user --pid --fork --mount-proc $venv/python -m unittest test_backend_contract` | 0 (28 OK) |
| same, on a copy with the `--die-with-parent`/`--new-session` swap mutant (copy deleted after) | 1 (16 failures — mutant caught) |
| `cd tree/tests/e2e && unshare … python3 -m unittest mac_universal_census_test` | 0 (27 OK) |
| `python3 -I dw3.py tree/tests/e2e` (D-W3 demo: an undeclared non-Mach-O file is invisible to the census) | 0 (0 failures) |
| `unshare … zig build cross-check -j4 --cache-dir … --global-cache-dir …` (in tree) | 0 (both macOS objects compile; every zb_* they need is named in the .m — text check only, the .m is not compiled) |
| `rm -rf -- "${DIR:?}"` of the export tree, the Zig caches and the demo/log files under `validate-ms0-3/` | 0 |

Not run (by rule): any `tests/mac/*.sh`, any Mac/VM/ssh host, a full `zig build test`.
