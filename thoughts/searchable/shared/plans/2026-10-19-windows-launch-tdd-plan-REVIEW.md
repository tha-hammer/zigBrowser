---
date: 2026-10-22
reviewer: BlackRobin (Claude Opus 5.5, independent review_plan; not the plan's author)
plan: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md
plan_rev: 2.16 (last plan commit 29683b9, 2026-10-21)
plan_pin: 032a2c9 (2026-10-19)
code_reviewed_at: c07899f (HEAD, 2026-10-22)
bead: zigBrowser-4pa.4 (epic zigBrowser-4pa)
verdict: NEEDS MAJOR REVISION
---

# Plan Review Report: Windows Launch TDD Plan — REVIEW

## How this review was done

- I read the whole plan (2,623 lines, rev 2.16).
- Seven read-only subagents compared each workstream with the code committed at HEAD c07899f. They did not build or run anything, and did not contact the VM or Macs.
- I re-checked the key claims myself with `grep`/`sed` before writing them here: `gate.sh:578-581`, `app.zig:626-627`, `automation_gtk_port.zig:22`, `automation_platform.zig:79-82`, `build.zig:3549/3559/564-567`, `launcher.py`, `webview2_shim.cpp:922/2387`, `zigBrowser.wxs:19/80`, `owner_only.zig:243`, `agent_secrets_win_logic_test.cpp:11`, `universal_components_ms5.json:155/159`, and the missing-file checks.
- I did not run any test, so I make no claim about whether a registered test passes today.
- **Disclosure.** The plan's WS3 owner table names "BlackRobin" as the owner of the native C setters in `webview2_shim.cpp` and `wkwebview_shim.m` (plan:1429, 1433, 1451). I am registered under that agent-mail name for this review only. I did not write this plan or the code it describes.

## Review Summary

| Category | Status | Critical | Warning |
|----------|--------|----------|---------|
| Contracts | ❌ | 5 | 5 |
| Interfaces | ❌ | 3 | 5 |
| Promises | ❌ | 1 | 4 |
| Data Models | ❌ | 1 | 1 |
| APIs | ⚠️ | 0 | 1 |
| Workflow Closure | ❌ | 7 | 0 |
| Test-Spec Quality | ❌ | 2 | 7 |
| **Total** | | **19** | **23** |

**Verdict: Needs Major Revision.** The plan is honest about many of its own gaps, especially WS8/WS9. But three problems block implementation from resuming:
- Its normative text still contradicts the owner's decisions.
- Its gates cannot be satisfied as written.
- Much of the committed Windows code was built out of order, against superseded design, or without the real-binary proof the plan requires.

## What the code actually contains (status at HEAD c07899f)

| Milestone | State at HEAD | Live Win11 evidence | Win10 evidence |
|---|---|---|---|
| WS0 gate | Readiness only (`--probe-only`). The full product gate is "not implemented" (`gate.sh:578-581`). The WS0.4 runner is not hardened. | probe 992b124 (review 012e1bc) | read-only probe only |
| WS1 build/render | WS1.1, 1.3, 1.4, 1.5 green on the VM (7463139, 8f36ee7, 6c771ff, dcd33ae). WS1.2 not started. Most WS1 exe tests are unregistered. | yes | none |
| WS2.0 transport | Done and real (970969f → f29e490 → 3cb8722) | yes | none (forbidden) |
| WS2a / WS2b / WS2c | **Zero code.** No `automation_wv2_port.zig`; `pagePort()` is null on Windows. | none | none |
| WS3 config/cookies | Flag seam real and correct. Cookie port and profile built but **unwired**. | partial (15fb6ee, 66060b0, e1e9264) | none |
| WS4 flows/grant | Not started. Cannot start without WS2. | none | none |
| WS5 drawer | 125 commits. Proofs are mostly offline source/model oracles. Only the entry and lifecycle runs are green live. | b2c4f25, a5745b9 | none |
| WS6 secrets | Portable shape + `TokenStore` real. The Windows CredMan store is a skeleton with no caller. | none | none |
| WS7 setup | Python launcher contract green. WS7.1/7.2/7.4 are unregistered reds with no production functions. | none | none |
| WS8 / WS9 | DRAFT. No production code. Discovery spike repairs only (allowed by blocker 1). | spike 2026-10-21 only | none |
| WS10 / WS11 | Not started | — | — |
| WS12 | WS12.1 hooks and `gate.sh --phase voice` not started | — | — |
| WS13 | Not started. The MSI is unchanged since the pin (`Return="ignore"` at `zigBrowser.wxs:80`). | — | — |

**Volume since the pin (032a2c9):**
- Windows path set (shim, `tests/windows`, `packaging/windows`, `build.zig`): +16,773 lines in 45 files.
- Of that, roughly 2,200 lines are production code and about 12,500 are test code (about 5.7 : 1). Most of the test code is offline oracles and harness.
- Commits per tag: WS0 87, WS1 18, WS2 17, WS3 17, WS5 118, WS6 15, WS7 21, WS8 8, WS9 6, WS12 1, WS13 2, WS4/WS10/WS11 0.
- About 140 RoseCat review commits touch Windows.

---

### Contract Review

#### Well-Defined
- ✅ WS2.0 owner-only transport. `restrictToOwner` / `ownerOnlySddl` / `validSid` (`src/owner_only.zig:37-62`) and `socketBaseDir` / `SocketPathTooLong` (`src/automation_transport.zig:19-52`) have production callers (`app.zig:638,646`; `automation_server.zig:1569,1581`) and a real cross-user negative on the VM (3cb8722: WSAEACCES 10013 and ERROR_ACCESS_DENIED 5).
- ✅ WS3.2 flag seam. `Decision` is a real sum type (`src/backend_flag.zig:28`). The table is literal from the plan (`tests/backend_flag_test.zig:29-58`). It refuses before any C call (`webkit.zig:41`), and the refusal is proven on the real exe (`refusal_stderr_live_test.py`, registered).
- ✅ The WS0 Win10 probe is zero-write: Reflection.Emit, no Add-Type, streamed on stdin (`host_probe.ps1:16-53`). Writability uses the real Win32 AccessCheck (`:64-80`).

#### Missing or Unclear
- ❌ **C3: the WS0.4 runner contract is unmet.**
  - The plan requires these runner checks (plan:817-823):
    - `ProcessIdToSessionId == WTSGetActiveConsoleSessionId`
    - `IsWindowVisible`
    - readiness rows
    - a 120 s bound
    - job cleanup
    - a leftover-task selftest
  - `tests/e2e/slice2_common.py:492-593` has none of these. Cleanup results are ignored and the task runs `/rl highest`.
  - The m8 tests still `return SKIP_EXIT` (`m8_render_test.py:322-333`), and `ZB_WIN_GATE` does not exist anywhere.
- ❌ **C5: the WS2 spikes were never run, but the code already asserts their answer.**
  - The CDP isolated-world spike (plan:1113-1114) and the isTrusted spike (plan:1127-1133) have no file and no result.
  - `src/automation_platform.zig:79-82` already declares `.webview2 => input = .cdp_input, network = .supported`. The plan says that row may change only after WS2b.1 passes.
- ❌ **C7: the WS4 grant contract does not exist in the code.**
  - Plan:1490-1494 says "no new grant code" and quotes `sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`.
  - `src/` has no `target_fp` or `normalized_args`.
  - What exists instead is:
    - an approval card with `card_ttl_ms = 120_000` (`src/agent_approval.zig:182`) and one-shot Approve (`:279-286`);
    - `WindowWant{origin,url,load_serial}` (`automation/engine.zig:1214-1221`);
    - flow `expect{url,recipient}` (`automation/social_flow_routes.zig:241`).
  - So the WS4 account and `target_fp` mutants (plan:1504-1507) have nothing to test.
- ❌ **C8: the top-level contract contradicts OD-W4.** Blocker 6 (plan:1745-1749) only marks these "non-normative" through the banner; the sections themselves still say:
  - Desired End State (plan:181-194): "run the Claude agent inside an OS-native sandbox … verified by real-binary e2e on both hosts".
  - Observable behavior 6 (plan:210-211): "fails at the kernel".
  - What We're NOT Doing (plan:221-222): "the WSL2 fallback is built only if a hard gate of the chosen backend fails".
  - `rev_2_14_note` (plan:13): "WSL→Windows is firewall-blocked" as a measured fact, which plan:1863-1867 withdraws.
  - A reader of the first 230 lines gets a contract the owner has overruled.
- ❌ **C11: WS13 uninstall still describes the dropped design, and on the read-only host.**
  - The WS13.4 red asserts sandbox users, profiles, WFP filters, providers, sublayers and tasks (plan:2427-2428).
  - The WS13 gate runs a post-uninstall probe "(users, filters, tasks, folders)" on the physical Win10 machine (plan:2459-2461). That machine is read-only by the plan's own rule (plan:1038-1039).
  - No normative WSL-era uninstall behavior or red exists. C3 is a DRAFT.
- ⚠️ WS0.1 (plan:796-798) defers `webview2_pv`, but WS0.2 (plan:806) lists "`webview2_pv` empty" as fail-closed with no host qualifier. The code follows WS0.1: VM-only, `gate.sh:265-266`.
- ⚠️ The "Current State" section (plan:84-160) is stale and the one-line "historical" disclaimer (plan:80-82) is easy to miss. Examples:
  - "3 of 73" shim functions: it is 15 now.
  - "stub `zb_run_screenshot`": it is CapturePreview now (`webview2_shim.cpp:1976-2019`).
  - "never reads `%LOCALAPPDATA%`" and "chmods 0o600": both are fixed.
- ⚠️ `runSafety` (`agent_secrets_store.zig:33-67`) has no consumer. `agent_secrets_win.cpp:30,43,60` accept `nullptr` (the real production target) and any target string, so a Windows credential test could reach `zigBrowser/ClaudeAgentToken/default`.
- ⚠️ `tests/windows/hosts.env.example:30` says build 19041, but OD-W7 says 19045. The plan's "INCOMPLETE: both hosts are required" message (plan:669) and its separate 15 s TCP step (plan:845) are not in `gate.sh`.
- ⚠️ The frontmatter has three problems:
  - `last_updated_by` says rev 2.13 while `rev` is 2.16.
  - The rev 2.8/2.9 notes exist only in the body.
  - The process note (plan:2619-2622) says bd is migration-locked. bd works today; this review filed issues with it.

#### Recommendations
- Rewrite plan:181-230 and the real-screen table for: browser on Win11 (and on Win10 only if C1 is resolved), agent on Win11 under WSL2.
- Replace "Current State" with a dated state-at-HEAD table (the status table above is a start).
- Change `automation_platform.zig:79` to "unproven" until WS2b.1 passes, or note in the plan that it is a placeholder.
- Reconcile WS4 with the card/expect model that is actually in the code.

---

### Interface Review

#### Well-Defined
- ✅ The `CookiePort` interface names are pinned and match `src/automation/cookie_port.zig` (`getAll` / `set` / `delete`).
- ✅ The WS3 binding order was honoured: the seam 3aa7ccf, then the shim setters 15fb6ee, then the `.windows` arm 66060b0.
- ✅ Drawer geometry, easing, hit-test and live counts stay in Zig (`agent_drawer.zig`). The C++ only computes the elapsed ratio (`webview2_shim.cpp:1676-1686`).

#### Missing or Unclear
- ❌ **C9: WS7 was built on 2026-10-22 against the superseded native-Windows agent design.**
  - WS7.2 bundles a Windows `python.exe` plus the wheel's `claude.exe`, and WS7.3 a native launcher that "starts `claude.exe` in the session's job" (plan:1661-1667).
  - OD-W4 (plan:257-259) runs the agent and CLI inside the WSL2 distro.
  - Commits ab86a92, ea8940e, 1a06bb0 and b9ff6da came a day after OD-W4 and never mention WSL.
  - `agent/host/zb_agent_host/launcher.py` (35 lines) has no `wsl.exe` argv, no `pass_fds` and no fd-3 token.
- ❌ **C10: WS10 and WS11 are specified for the dropped design.**
  - WS10 plans ConPTY, a Windows `login.py` branch and `agent_login_win.c` (plan:2243-2263). Under WSL2, `setup-token` runs in Linux.
  - WS11 plans `agent_helper_win.c` with a "stop ladder via the job" (plan:2284-2296). The job model is dropped; C4 owns teardown.
  - The Windows side's real job (open the URL, carry the pasted code over C1, store the token) is not specified.
- ❌ **C15: the built WS5 drawer differs from the plan, and the plan was never amended.**
  - `src/agent_drawer_win.cpp`, `src/zigBrowser.rc` and `packaging/windows/zigBrowser.manifest` do not exist.
  - There is no DPI-awareness manifest or call. `GetDpiForWindow` (`webview2_shim.cpp:922`) in an unaware process normally reads 96, so the 150% path has only an env-seam proof.
  - The "S" icon is a `WS_CHILD` STATIC, not the planned owned layered popup with `SetWindowRgn`.
  - There is no approval card, no Send box and no "Agent not available yet" (plan:1525, 1547). So WS11.3's "the only native minter is WS5's card" is false today.
  - WS12.1 (`zb_drawer_set_draft` / `zb_drawer_speaker_toggled`) does not exist.
- ⚠️ `tests/guest/build-in-guest.sh` is still the old insecure builder: `StrictHostKeyChecking=no` at :14, `2>/dev/null` at :23, and a fixed `/tmp` tar. It was meant to become a thin wrapper (plan:878).
  - `build-on-windows.sh:109-112` hardcodes SDK paths instead of reading the probe.
  - It reads `ZB_WIN_KEY` while the gate reads `ZB_WIN11_KEY`.
- ⚠️ WS0.8 staging is not done:
  - There is no `mktemp -d` and no `zb\runs\<id>` dir; `gate.sh:127` extracts into the fixed `zb`, and nothing cleans it up.
  - `tests/windows/known_hosts` is an empty template, and the gate defaults to `/home/maceo/vms/...`.
- ⚠️ `gate.sh --fence-string` (`gate.sh:69-103`) has no production caller and carries test-only log hooks (`ZB_SELFTEST_RAN_LOG` / `ENV_LOG`).
- ⚠️ `src/webview2_config.zig:27-49` (`applyWindowsFlag`, `applyProfileDir`) duplicates the real arm at `webkit.zig:63-70` and is referenced only by `ws3_win_cross_root.zig`.
- ⚠️ Paths and headers have drifted:
  - The WS3/WS5 tests live in `tests/windows/`, not the planned `tests/e2e/`.
  - `win_drawer_test.py:3-9` still says UNREGISTERED and cites `agent_drawer_win.cpp`.

#### Recommendations
- Rewrite WS7, WS10 and WS11 for the WSL2 topology before any more work on them. List which Windows-host pieces survive: the launcher becomes `wsl.exe -d … -u …` plus the C1 bootstrap; no Windows Python or `claude.exe`.
- Amend WS5 to the as-built design, or open tasks for the manifest, `.rc`, layered icon, card and Send. Add the DPI manifest before any 150% acceptance.
- Retire `build-in-guest.sh` and `webview2_config.zig`.

---

### Promise Review

#### Well-Defined
- ✅ The UI-thread marshal exists, but only for cookies:
  - `WM_ZB_JOB = WM_APP + 1` (`webview2_shim.cpp:48`)
  - a deadline-guarded wait with CAS abandon (`:728-776`)
  - exactly-once completion (`:621`)
  - a loop-end answer `ZB_AUTO_ERR_NO_LOOP` (`:710-727`)
- ✅ The WS7.4 cycle tests that spawn and kill a worker gate on a proven PID namespace (`pidns_guard.py:26-60`).

#### Missing or Unclear
- ❌ **C17: WS8/WS9 cannot be implemented, and the DRAFT gate contradicts its own blocker 1.**
  - All six blockers (plan:1713-1749) are open at HEAD; no plan revision follows 2.16.
  - C1 lacks the byte format for the Windows-handle→WSL-fd bootstrap, the port-return channel, the HMAC hash, nonce length, max handshake size and timeouts.
  - C4's lock primitive, lease period and "the bound" are TBD (plan:1998).
  - WS8.5 says "within 1 s" (plan:1815), but C4 and matrix item 9 say "within the bound".
  - WS8.4 is missing but cited (plan:2529). WS8.3 is "two channels" at plan:1807 but one at plan:2033.
  - The gate forbids "any further live/destructive WSL run" until every blocker closes (plan:1706-1708). Blocker 1 needs a live rerun to close (plan:1722-1726).
  - That rerun was authorized only in review ecd290a, not in the plan. It then failed before reaching the VM on an ssh-config issue (fixed by 6f2188d → 1006b1e → bd92f4a, reviewed 13de146 and 7233d06). The spike header (`wsl_live_test.py:3`) still says "NOT RUN".
- ⚠️ The WS2 async contract names no numbers: no per-command deadline, and "bounded" health probe. The shim keeps one unbounded `WaitForSingleObject(job->done, INFINITE)` (`webview2_shim.cpp:768`). WS2a.3's `waiter_grace` seam and its test do not exist.
- ⚠️ `cross-check-ws3-win` (`build.zig:580-604`) is green per 15fb6ee but was never wired into `cross-check` or `test` (plan:1514-1517 says to). Stale "red until the shim lands" comments remain in four files, so a dropped symbol would go unseen.
- ⚠️ The WebView2 bootstrapper failure is still swallowed (`Return="ignore"`, `zigBrowser.wxs:80`). `MediaTemplate EmbedCab="yes"` (`:19`) has no cabinet cap, so the 0.8-1.5 GB speech model will break the 2 GB limit (WS13.3).
- ⚠️ WS0.4's 120 s bound is not implemented; the runner takes any caller `timeout_sec` (`slice2_common.py:497`).

#### Recommendations
- In the next WS8 revision, give C1 and C4 concrete numbers and wire formats.
- Fix the gate so the one sanctioned spike rerun is written in the plan, not only in a review doc.
- Pin per-command deadlines for WS2a, and remove the `INFINITE` wait.

---

### Data Model Review

#### Well-Defined
- ✅ `backend_flag.Decision` is an `enum { apply, refuse }`, not two bools.
- ✅ The probe carries a pinned integer `schema` (`host_probe.ps1:306`, `gate.sh:248`).

#### Missing or Unclear
- ❌ **C19: boundary values are checked, not parsed.**
  - **Probe JSON:**
    - "not_applicable" is JSON `null`, the same value as unknown or failed-to-read (`host_probe.ps1:196, 331-332`).
    - `interactive_session` is stored beside `locked` even though it derives from `locked` and `in_console` (`session_probe.ps1:142-143`), so the two can disagree.
    - `gate.sh:215-451` validates field by field in a 235-line heredoc. The plan's "one JSON schema shared by selftest and gate" refactor (plan:914-916) is not done.
  - **Token:**
    - `validToken` returns `bool` (`agent_secrets_shape.zig:23`) and is re-checked at `agent_secrets.zig:128,169,345` and `agent_secrets_store.zig:84,103`.
    - The C ABI `zb_secret_cred_save` accepts any bytes.
- ⚠️ The WS8/WS9 draft data models are named but untyped:
  - The C5 frame `(stream_id, op, bytes)` has no widths, `op` enum, max frame size or window limits (plan:2193-2195).
  - The lease file and the C3 current-pointer file have no schema or state enum.

#### Recommendations
- Parse each probe once into a typed record with an explicit `ok | not_applicable | unknown` state, and derive `interactive_session` instead of storing it.
- Introduce a `Token` type returned by one parse function, and make the C ABI take only that.

---

### API Review

#### Well-Defined
- ✅ The automation API keeps the Linux JSON-RPC envelope and error codes on Windows. -32011 (no port), -32015 (`automation_rpc.zig:450`) and -32602 are reused, and the WS2.0 transport keeps the same token-file auth.
- ✅ The refusal message for an unsupported flag is exact, and proven on the real exe.

#### Missing or Unclear
- ⚠️ About 12 e2e environment seams were added to the production shim with no plan coverage (`webview2_shim.cpp:2210-2232`):
  - `ZIGBROWSER_AGENT_DRAWER_*`: OPEN, FAIL, DRAG, FOLD, FOLD_FAIL, DPI, RTF, DPICHANGE_IGNORE, HITTEST_FAIL, WINDOWS, EXTRA_FAIL, EXTRA_CLOSE_ONE
  - a second window class, `zigBrowserDrawerExtra` (`:40, 1481-1495`)

  These seams have three problems:
  - They are gated only by `--e2e-protocol` (`:2210-2214`).
  - The plan's WS6.3 disposable-credential override and WS1.4 runtime-folder override depend on the same flag.
  - The plan gives no contract that `--e2e-protocol` cannot be set by a page, an automation client or a shortcut on a user machine.

  I found no reach from page or socket, but the security property is unstated.

#### Recommendations
- Add one plan contract for `--e2e-protocol`:
  - who can set it;
  - that it is refused in packaged builds, or why it is safe;
  - the full list of seams it unlocks, with WS2's "absent at link time" rule applied to drawer seams too.

---

### Workflow Closure Review

#### Well-Defined
- ✅ WS2.0 transport closure: the real browser on the VM binds, restricts and refuses a second user (970969f / f29e490 / 3cb8722).
- ✅ WS1.3 screenshot and WS1.5 version: real exe on the VM, a stub or mutant shown failing, and independent cross-checks (8f36ee7, 6c771ff, dcd33ae).
- ✅ WS5.5 lifecycle: four live methods at the exact commit a5745b9, with the count driven by Zig.

#### Missing or Unclear
- ❌ **C1: no Windows 10 browser test host exists.**
  - The plan ships the browser on Win10 and gates WS0-WS4, plus every UI case, on both hosts (plan:34-41, 263-267, 2489-2512).
  - Rev 2.10 makes the only Win10 host read-only, so "no browser runs there" (plan:1038-1066, 2518-2521).
  - The only Win10 evidence is the read-only `--probe-only` (992b124, review 012e1bc).
  - Every "[W] both hosts" gate is therefore unsatisfiable, and the Win10 launch claim is untested.
- ❌ **C2: there is no product gate, and registered live steps go green with zero Windows rows.**
  - `gate.sh` with no args exits 2: "two-host run not implemented yet" (`gate.sh:578-581`). It has no exit-77 or `ASSERTS <n>` handling.
  - Eight registered live steps exit 0 when `ZB_WIN11_HOST` is unset (`build.zig:294-334`; `win_transport_test.py:7` "Skips cleanly (exit 0)").
  - The drawer suites force-unset the host vars (`build.zig:3549, 3559`), so their VM rows can never run in the gate.
  - The plan bans this: "test exit 77 (skip) → fail" (plan:696), and "a skip is UNCLOSED" (plan:725).
- ❌ **C4: the Windows automation surface (WS2a/b/c) has zero code, and later slices were built out of order.**
  - `src/automation_wv2_port.zig` does not exist.
  - `app.zig:626-627` uses the GTK ports, which are `supported = builtin.os.tag == .linux` (`automation_gtk_port.zig:22`), so on Windows every page, dom, input, dialog and window command returns -32011.
  - The shim defines 15 of the 73 ABI functions, and none of them are WS2a-c's.
  - The BLOCKING Closures A, B and C (plan:1197-1293) have no e2e.
  - WS3, WS5, WS6 and WS7 (about 170 commits) were built first, against the order at plan:2465-2472. WS4 cannot start at all.
- ❌ **C6: WS3 cookie and profile work is built but unwired.**
  - `automation_wv2_cookie_port.zig` has no production caller (`app.zig:627`).
  - `win_cookie_test.py` and `win_profile_persist_test.py` do not exist.
  - There is no default `%LOCALAPPDATA%` profile (`app.zig:513` returns null), so the exe-adjacent folder still appears by default.
  - The profile folder is created with default ACLs (`webview2_shim.cpp:2387`), and `zb_restrict_to_owner` (`owner_only.zig:243`) has no caller.
  - WS3.1 and WS3.3 are BLOCKING closures with no e2e.
- ❌ **C12: 459 lines of dead Job Object code are still registered.**
  - `wincontain.py` (248 lines) and `wincontain_win32.py` (211 lines, `CreateJobObjectW`) were built 2026-10-20 for the dropped design and have no production caller.
  - They are still registered: live steps at `build.zig:293-306`, unit tests at `:2471-2474`.
  - They are listed as macOS bundle components (`packaging/macos/universal_components_ms5.json:155,159`).
  - Plan:1087 still assigns "wincontain and the Job Object" to an owner.
- ❌ **C13: the WS6 token store has no consumer and no route to the CLI.**
  - `zb_secret_cred_save/read/delete` and `zb_secret_dpapi_protect` (`agent_secrets_win.cpp:26-67`) are referenced only by symbol checks (`build.zig:564-567`). `TokenStore` (`agent_secrets_store.zig:71`) is used only by its test.
  - No Windows Secrets window exists, and no real Win32 run has happened.
  - `tests/windows/agent_secrets_win_logic_test.cpp:11` includes `agent_secrets_win_logic.h`, which does not exist.
  - The DPAPI private file (plan:1608-1611) is unreadable from inside the distro, and nothing says how the token reaches the in-distro CLI's fd 3.
- ❌ **C16: the WS5.6 BLOCKING isolation closure is offline only.**
  - 4cb740d is a Linux in-process test that three drawer method names return -32601.
  - The page-JavaScript half has no test.
  - The Python row (`win_drawer_behaviors_test.py:321-333`) exercises helpers defined in the test itself, and the live row (`:1018`) never ran.

#### Recommendations
- **C1 is an owner decision:** authorize a writable Win10 host, which plan:1063-1066 already describes, or make every gate Win11-only and qualify the Win10 launch claim.
- Build the gate's product-run mode with fail-on-skip, or rewrite the per-slice protocol to name the real commands. Make registered live steps fail when run under a gate without a host.
- Re-baseline the dependency order. WS2a.0 and WS2b.1 spikes first, then the WS2a port, then wire the WS3 cookie port and profile with their e2e.
- Decide whether `wincontain` is reused by the C2 broker. If not, retire it with its steps and manifest rows.

---

### Test-Spec-Quality Review

#### Well-Defined
- ✅ WS0.6 has three separate identity-marker cases (`gate_twohost_selftest.py:188-205`). The lock verdict fails closed with an explicit WTS offset fix.
- ✅ WS2.0 has a 1,000-nonce property (`tests/automation_transport_ws20_test.zig:15`). WS3.2 is a literal table oracle cross-checked against production parsers. WS6.1 has a 10k-string shape property (`tests/agent_secrets_shape_test.zig:114`).
- ✅ WS1 has a reasoned property skip ("fixed inputs … nothing to generate over", plan:961).

#### Missing or Unclear
- ❌ **C14: the WS5 drawer is proven by source oracles, and its live behavior rows never ran.**
  - There are about 116 offline oracle or model tests against 27 live rows.
  - Only the entry run (b2c4f25, 8/8) and the four lifecycle methods (a5745b9) have an accepted green.
  - The 19 rows for drag, fold, copy, DPI and isolation (`win_drawer_behaviors_test.py:857-1056`) skip in the gate.
  - The settle proof is an AST parse of a Python test file; RoseCat itself ruled such a parser is not a control-flow proof.
  - No `win-drawer-*` real-screen case exists in `tests/manual/real_screen_check.py`, which is X11 only.
  - The churn behind this: 125 WS5 commits, 24 marked "NOT run", about 46 blocked verdict sections, and a 14-commit fix-forward chain on test oracles (918cb09 … cd2323c).
- ❌ **C18: behaviors with real input domains have no Property and no stated reason.**
  - WS3.3 cookie JSON: `automation_wv2_cookie_port.zig` has no test block, and an unknown `sameSite` silently becomes "unset".
  - WS4 grant fields.
  - WS2c window and popup ids.
  - WS7.1 pointer swap.
  - WS10.3 error codes.
  - WS13.3 payload sizes.
- ⚠️ WS0 mutants exist only as comments. The file-server zero-write guarantee is a regex over source (`gate_twohost_selftest.py:864-996`).
- ⚠️ The WS1 exe-level tests (`pe_census_test.py`, `png_census_test.py`, `ws1_run_test.py`) are unregistered and not in `gate.sh`. `screenshot_diag_selftest.py` greps shim text.
- ⚠️ WS2.0's token-only mutant is not recorded; only the full no-op flips the cross-user test (89c166b).
- ⚠️ The WS3.2 tests do not match the plan:
  - They use `--renderer shm`, not `bogus`.
  - Media-source is read from a NAV title, not `page.evaluate` over the socket.
  - There is no `--disable-gpu` proof.
  - Neither planned mutant was run.
- ⚠️ The Windows store `agent_secrets_win.cpp` is gated only by "compiles and exports four names". Dropping `CRYPTPROTECT_UI_FORBIDDEN` (`:75`) or changing the SDDL (`:95`) would pass every registered step.
- ⚠️ The WS7.1, 7.2 and 7.4 reds use toy inputs: threads with POSIX `os.rename`, fake bytes, an in-memory filesystem. `MoveFileExW` atomicity on Windows, which the plan says the red decides (plan:1658-1659), is untested.
- ⚠️ The overall shape is about 5.7 test lines per production line on Windows, with the review loop centred on oracle precision rather than product behavior.

#### Recommendations
- For each WS5 behavior, either record one accepted Win11 run of the live row, or mark the behavior open in the plan.
- Schedule the five `win-drawer-*` real-screen cases with the owner. Add a Windows backend to `real_screen_check.py`.
- Limit oracles to tripwires. A behavior counts as closed only when a real-binary row ran.
- Add properties, or reasoned skips, for the domains listed in C18.

---

## Critical Issues (Must Address Before Implementation)

Each is filed under epic zigBrowser-4pa with `discovered-from: zigBrowser-4pa.4`.

| # | bd | Category | Issue |
|---|---|---|---|
| C1 | zigBrowser-4pa.31 (P0) | Workflow Closure | Win10 browser launch has no test host; every both-hosts gate is unsatisfiable |
| C2 | zigBrowser-4pa.32 (P0) | Workflow Closure | No product gate; registered live steps pass green with zero Windows rows |
| C3 | zigBrowser-4pa.33 | Contracts | WS0.4 runner never hardened; m8 tests still skip with 77 |
| C4 | zigBrowser-4pa.34 (P0) | Workflow Closure | WS2a/b/c automation surface has zero code; later slices built out of order |
| C5 | zigBrowser-4pa.35 (P0) | Contracts | Gating spikes never run; capability table already claims `cdp_input` |
| C6 | zigBrowser-4pa.36 | Workflow Closure | WS3 cookie port and profile built but unwired and unproven |
| C7 | zigBrowser-4pa.37 | Contracts | WS4 grant tuple the plan says exists is not in the code |
| C8 | zigBrowser-4pa.38 (P0) | Contracts | Top-level contract (End State, behavior 6, NOT-doing, rev 2.14 note) contradicts OD-W4 |
| C9 | zigBrowser-4pa.39 (P0) | Interfaces | WS7 built after OD-W4 against the native-Windows agent design |
| C10 | zigBrowser-4pa.40 | Interfaces | WS10/WS11 specified for the dropped design |
| C11 | zigBrowser-4pa.41 | Contracts | WS13 uninstall/gate describes sandbox users/WFP on the read-only Win10 host |
| C12 | zigBrowser-4pa.42 | Workflow Closure | 459 lines of dead Job Object code still registered and in the macOS manifest |
| C13 | zigBrowser-4pa.43 | Workflow Closure | WS6 CredMan store has no caller and no path to the in-distro CLI |
| C14 | zigBrowser-4pa.44 (P0) | Test-Spec Quality | WS5 proven by source oracles; live behavior rows never ran; no real-screen check |
| C15 | zigBrowser-4pa.45 | Interfaces | WS5 as-built diverges (no DPI manifest, child icon, no card/Send) without amendment |
| C16 | zigBrowser-4pa.46 | Workflow Closure | WS5.6 BLOCKING isolation proven offline only |
| C17 | zigBrowser-4pa.47 | Promises | WS8/WS9 contracts not implementable; DRAFT gate conflicts with blocker 1 |
| C18 | zigBrowser-4pa.48 | Test-Spec Quality | Real input domains with no Property and no reason |
| C19 | zigBrowser-4pa.49 | Data Models | Boundary values checked, not parsed (probe JSON, token shape) |

**Impact if not addressed:**
- The plan cannot gate a launch: no product gate exists, and Win10 has no host.
- The core automation feature on Windows does not exist.
- Work continues on designs the owner has dropped.
- "Green" in `zig build test` does not mean any Windows behavior ran.

## Suggested Plan Amendments

```diff
# Top of plan (frontmatter, banners, Desired End State, NOT doing)
~ Modify: Desired End State + observable behaviors 5-7 to WSL2 / agent Win11-only (C8)
~ Modify: "What We're NOT Doing" — WSL2 is the launch sandbox, not a fallback (C8)
~ Modify: rev_2_14_note — withdraw "WSL→Windows is firewall-blocked" as measured (C8)
- Remove: process-note claim that bd is migration-locked; fix last_updated_by (warning)
+ Add: dated "state at HEAD" table replacing "Current State Analysis" (warning)
+ Add: owner decision on Windows 10 test coverage — writable Win10 host OR Win11-only gates (C1)

# Testing strategy / per-slice gate protocol
+ Add: the real per-slice gate command until gate.sh has a product-run mode (C2)
+ Add: rule — a registered live step run under a gate with no host FAILS, never exits 0 (C2)
+ Add: contract for --e2e-protocol (who can set it, packaged-build refusal, seam inventory) (API warning)

# WS0
~ Modify: WS0 status to "readiness-only closed"; WS0.4 open (C3)
~ Modify: WS0.2 — webview2_pv enforced on the VM only (warning)
+ Add: typed probe record with ok / not_applicable / unknown; derive interactive_session (C19)

# WS1 / WS2
+ Add: WS1.2 before WS2a (m8 harness reuse) (C3)
~ Modify: automation_platform.zig .webview2 row is UNPROVEN until WS2b.1 (C5)
+ Add: per-command deadlines; no INFINITE waits in the marshal (warning)
~ Modify: dependency order — WS2a.0/WS2b.1 spikes are the next Windows work (C4)

# WS3 / WS4
+ Add: wire automation_wv2_cookie_port in buildAutomationConfig + win_cookie_test (C6)
+ Add: %LOCALAPPDATA% default profile + zb_restrict_to_owner on <dir>\WebView2 + relaunch e2e (C6)
~ Modify: WS4 grant contract to the as-built card/expect model, or schedule the tuple as new work (C7)
+ Add: cookie-JSON roundtrip property incl. sameSite domain (C18)

# WS5 / WS12
~ Modify: WS5 design to the as-built child-control drawer, or open tasks for layered icon, .rc, manifest (C15)
+ Add: PerMonitorV2 manifest before any 150% acceptance (C15)
+ Add: approval card + Send/"Agent not available yet" as explicit WS5 items (C15)
+ Add: real-binary WS5.6 isolation (page JS + socket) on Win11 (C16)
~ Modify: WS5 closure rule — a behavior closes only on an accepted live row (C14)

# WS6 / WS7 / WS10 / WS11
~ Modify: WS7.2/7.3 for WSL2 (no Windows python.exe/claude.exe; launcher = wsl.exe + C1 bootstrap) (C9)
~ Modify: WS10 (setup-token runs in-distro) and WS11 (no job stop ladder; C4 teardown) (C10)
+ Add: the Windows-store → in-distro fd-3 token route (C13)
+ Add: Token type parsed once; C ABI accepts only it (C19)
- Remove or re-justify: wincontain + Job Object modules, their gate steps and mac manifest rows (C12)

# WS8 / WS9
+ Add: concrete C1 wire format, port-return channel, HMAC/nonce/frame numbers; C4 lock + timeout (C17)
~ Modify: DRAFT gate text to permit the one sanctioned blocker-1 live rerun explicitly (C17)
~ Modify: WS8.5 "1 s" vs C4 "the bound"; restore or renumber WS8.4 (C17)

# WS13
~ Modify: WS13.4 + WS13 gate to the WSL-era uninstall (distro/import/state only), Win11 only (C11)
~ Modify: WS13.1 component list (no sandbox-setup exe / Windows Python / claude.exe under WSL2) (C11)
```

## Approval Status

- [ ] **Ready for Implementation** — No critical issues
- [ ] **Needs Minor Revision** — Address warnings before proceeding
- [x] **Needs Major Revision** — 19 critical issues must be resolved first

**Next step in the pipeline:** zigBrowser-4pa.9 (`enhance_plan_with_review`) should take this report as input. C1 (Win10 coverage) and the order question in C4 are owner decisions. They are written here with a recommendation, not decided.

**Recommendation for C1:** make every gate Win11-only for now, and state the Win10 browser launch as "untested on Win10" until the owner authorizes a writable Win10 host.
