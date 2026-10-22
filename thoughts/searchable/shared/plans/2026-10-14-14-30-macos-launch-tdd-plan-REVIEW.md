---
date: 2026-10-22
reviewer: BlueBeaver (cc, Opus 5.5) — independent reviewer; not the plan author (JadeBeacon)
plan: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md (rev 28, last edited d8978b6)
code_reviewed_at: c07899f (branch zb-automation-integration-2026-10-10-11-59)
bead: zigBrowser-4pa.2 (epic zigBrowser-4pa)
status: Needs Major Revision
---

# Plan Review Report: macOS Launch TDD Plan — REVIEW

## How this review was done

- I read the whole plan (2,386 lines, rev 28).
- Eight read-only checkers each took one part of the plan (MS0, MS1/MS1b, MS2, MS3+MS4, MS5, MS6, MS6.5.1,
  MS7–MS9 plus test registration). Each one checked the plan's claims against the committed code at
  `c07899f` and recorded file:line evidence. About 255 claims were checked in total.
- I re-checked the most serious findings myself before writing them here (the recovery code in HEAD,
  the Seatbelt profile text, `build-dmg.sh`, `ms1b_signed_gate.sh`, `ms6_5_reaper_gate.sh`,
  `agent_broker.zig`, `launch.py`).
- Nothing was built, run or changed. No Mac or VM was contacted. The implementation freeze
  (zigBrowser-4pa.1) was respected.
- The plan was written as a plan, but about 230k lines were added on this branch since 2026-10-10.
  Mac production code is about 4.5k lines. Mac tests and harness are about 23k lines. So this review
  judges two things: the plan as written, and whether its claims are true of the code.

## Review Summary

| Category | Status | Critical | Warnings |
|----------|--------|----------|----------|
| Contracts | ❌ | 6 | 9 |
| Interfaces | ❌ | 2 | 9 |
| Promises | ❌ | 4 | 7 |
| Data Models | ❌ | 2 | 7 |
| APIs | ⚠️ | 0 | 5 |
| Workflow Closure | ❌ | 7 | 6 |
| Test-Spec Quality | ❌ | 5 | 9 |
| **Total** | | **26** | **52** |

The 26 critical findings are grouped into 12 bd issues (zigBrowser-4pa.19 to .30). Some issues cover
findings from more than one category. The table under "Critical Issues" maps them.

**The short version.** The plan's direction is sound and several parts are well built: the MS1 census,
the MS2 async job model, the load_serial counter, the MS5 staging tools and the netd `::1` reservation.
But the plan is no longer a true description of the code. Several parts it describes as done are not
built: the grant engine, the AppKit drawer, Keychain onboarding, the survivor warning, and any
production launch of the Mac sandbox. One part it says was removed is back in production source. Most
Mac tests never run in the registered gate. The plan cannot be used as the source of truth for
`validate_plan` (zigBrowser-4pa.12) until it is re-baselined.

---

## Contract Review

### Well-Defined
- ✅ MS1 `resource_phase` takes the whole inventory and checks its exact shape, so the 6002 relabel bypass
  is closed (`tests/e2e/mac_universal_test.py`, 27 census tests registered at `build.zig:3679`).
- ✅ The config-flag error channel lives in Zig, not in the void C setters, as rev 5 promised. The
  `--renderer` refusal prints the exact message and exits nonzero (`src/webkit.zig:36-41`).
- ✅ The MS5 setup refusal is a tagged union (`.run` or `.refuse`) with a fixed message
  (`src/agent_setup.zig`, `seatbelt_ready = false` at line 67).
- ✅ The netd and `probe_r1` dual-family reservation (v4 listener plus a non-listening `IPV6_V6ONLY`
  reservation on `[::1]`, exit 2 with no ready line on failure) matches plan lines 1687-1702.

### Missing or Unclear
- ❌ **K1. Rev 28 contradicts HEAD.** Plan lines 13, 222-231 and 1786-1803 say `RecoveryAction`,
  `publishWithout` and `recoverOneUnderLock` were removed from production source, and that no
  `reaper_ready` constant exists. HEAD has all of them: `src/agent_run_ledger.zig:500-634` and
  `src/agent_run_recovery.zig:334` (`pub const reaper_ready: bool = false;`). They were added by
  09dca89, 05ce038, cf1778e and others after the plan's last edit. bd zigBrowser-3gl repeats the stale
  text. A reviewer who trusts the plan would miss about 130 lines of signal-adjacent production code.
  → zigBrowser-4pa.19
- ❌ **K2. The ABI table marks missing exports as implemented.** The table (plan 807-840) says all 44
  production exports are implemented on macOS. `zb_screenshot_png`, `zb_set_input_files` and
  `zb_app_set/get_agent_drawer` are not defined on macOS. The macOS port has no vtable entry for the
  first two (`src/automation_macos_port.zig:54-77`), and `src/webkit.zig:131-134` says macOS has no
  drawer backend. The header has 76 exports (44 production + 32 debug), not 75 (44 + 31).
  → zigBrowser-4pa.19
- ❌ **K3. The MS4 grant contract is not in the code, and it contradicts the drawer plan.** Plan
  1197-1221 specifies a sha256 tuple grant, a mint entry `agent_broker.mint`/`on_approve_clicked`,
  broker revalidation before dispatch, and `options.expect = {account, target_fp}` with -32015.
  `src/agent_broker.zig` contains no sha256, mint, account or target_fp. Approval is a card with an
  `Outcome` enum (`src/agent_approval.zig:188`). `options.expect` accepts only `{origin, load_serial}`
  (`src/automation/router.zig:565`). The check runs inside the engine ticket (`engine.zig:1224`), which
  is what drawer plan D10 says. → zigBrowser-4pa.20
- ❌ **K4. The Seatbelt profile design is contradicted by the code.** Plan 1641-1645 says deny-default
  reads and a tiny mach-lookup with no WindowServer or mDNSResponder. The generator emits
  `(allow file-read*)` and `(allow mach-lookup)` (`agent/host/zb_agent_host/sandbox_macos.py:173,183,216,226`),
  and the Linux test pins that text. → zigBrowser-4pa.23
- ❌ **K5. The shipping packaging path was never converted.** MS1 lists `build-dmg.sh` (lipo and
  resource verify) as touched. The script copies only the exe (`packaging/macos/build-dmg.sh:71`), never
  `libwkwebview_shim.dylib`, and signs ad-hoc with `--deep` (line 92). The exe's install name points to
  `../Frameworks`, so a `.dmg` built today cannot load its shim. → zigBrowser-4pa.26
- ❌ **K6. The MS7 gate contract contradicts MS7.8.** Plan MS7.8 (2202-2213) says the MS7 card is built
  from fixture parameters with no helper. `tests/mac/ms7_appkit_check.py:187-190` requires a card
  "presented by the real chain", which its own probe says does not exist until MS8
  (`ms7_appkit_probe.m:11,321-324`). The gate cannot pass at MS7. → zigBrowser-4pa.27
- ⚠️ The beforeunload divergence is silent to clients. accept/dismiss return a generic unsupported
  error (`engine.zig:1446`), `.fail` just loads, and `docs/how-to-automate.md` never mentions macOS.
- ⚠️ The Python `Lifetime` is a hand-copied mirror of the C `ZbSpawnPolicy`. Every native call site
  passes `zb_spawn_policy_linux(0)` (`app.zig:140`, `agent_helper.c:732`, `agent_login.c:324,427`), so
  "the backend owns spawn policy" is intent, not data flow.
- ⚠️ `options.expect` has no carrier for `account`, which the plan calls the main defence against a
  same-document account switch.
- ⚠️ The dual-family ownership rule covers the egress and R1 ports only. The bridge rules render as
  `localhost:51091` and `localhost:31337`, so `[::1]` on those ports is admitted and not reserved.
- ⚠️ `(allow process-info* (target self))` (aa83b5f) is mentioned only in the rev 18.1 history, not in
  the MS6 design bullet that says "no process-info rights".
- ⚠️ Plan 1373-1374 says the browser's exit paths `killpg` the setup group. `runAgentSetupMacos`
  (`src/app.zig:199-215`) only waits.
- ⚠️ No test pins `seatbelt_ready == false`. Flipping it passes every Linux test.
- ⚠️ The plan never says that signalling needs `reaper_ready` AND the auto-stop setting not off. They are
  different gates, but the composition is unstated.
- ⚠️ The entitlement manifest has one key (`network.client`). The plan promises derived launcher and
  helper keys. MS9.1 signs all nested code with that one manifest. The bundled Claude CLI is a separate
  executable that may need its own entitlements under the hardened runtime. This was not checked; it
  should be spiked before MS9.

### Recommendations
- Publish rev 29 that describes what HEAD actually contains and marks every unbuilt behaviour NOT STARTED.
- Rewrite MS4.1 to the real card + in-ticket `options.expect` model, or specify the missing grant type
  with its own reds. Do not let MS4.1b "wire into" a broker that has no grant.
- Add a read and mach-lookup curation item to MS6 with failing-first Mac rows.
- Convert `build-dmg.sh` or move packaging explicitly to MS9.

---

## Interface Review

### Well-Defined
- ✅ The MS0 `SandboxBackend` protocol, `LinuxBwrapBackend` and the `helper_argv` facade exist
  (`agent/host/zb_agent_host/sandbox.py`). `test_backend_contract.py` is registered (`build.zig:3194`) and
  fails closed without its venv.
- ✅ The exec-arch readback is a real runtime channel: `build.exec_arch` through `telemetry.query` over
  the automation socket (`telemetry.zig:159`, `tests/mac/exec_arch_probe.py`).
- ✅ The five GTK-era symbols superseded in rev 13 are absent from the macOS shim, and an `nm -gU` census
  checks that.

### Missing or Unclear
- ❌ **I1. Nothing checks that `MacSeatbeltBackend` conforms to `SandboxBackend`, and they already
  differ.** `network(self)` vs `network(self, session=None)` (`sandbox.py:213/307`,
  `sandbox_macos.py:371`). The protocol `launch_spec` has no `network=` argument (`sandbox.py:210`).
  `egress_dir()` is typed `str` but the Mac backend returns None (`sandbox_macos.py:393`). The Mac
  `launch_spec` ignores `ro_paths`, `state_dirs`, `net_dir` and `seccomp_fd` (`sandbox_macos.py:413-442`).
  → zigBrowser-4pa.22
- ❌ **I2. `MacSeatbeltBackend` has no production caller.** `launch.py:154-157` refuses on darwin before
  any backend. `src/agent_helper.zig:121-130` never passes `--egress-port`. `spawnNetd` and
  `appendEgressPort` have only test callers. `LAUNCH_SPEC_CONSUMABLE = False` (`sandbox_macos.py:352`).
  → zigBrowser-4pa.21
- ⚠️ Names in the plan that do not exist: `src/automation_wk_port.zig` (real: `automation_macos_port.zig`,
  wired at `src/app.zig:626`), `automation_wk_cookie_port.zig` (real: `automation_macos_cookie_port.zig`,
  `app.zig:627`), `applyMacBackendFlag` (real: `webkit.applyBackendFlag` + `backend_flag.backendFlagDecision`),
  `agent_broker.mint`/`on_approve_clicked` (real: `zb_agent_tools_approve` → `Cards.approve`),
  `src/agent_drawer_mac.m`, `tests/e2e/mac_session.py`, and a `mac-universal` build step (real:
  `mac-gate` `build.zig:241`, `ms1b-gate` :247). Plan line 1235 and line 1295 disagree on the cookie port
  name; 1295 is right.
- ⚠️ `zb_mac_token_to_fd` carries test-only `keychain_path` and `unlock_password` arguments in the
  production signature (`src/agent_token_fd_mac.h:17`). The plan signature is `(fd, service, account)`.
- ⚠️ `reaper_ready` can be bypassed through the API. `recoverAllAtStartupGated(ready: bool, …)`
  (`agent_run_recovery.zig:368`) and `ledger.recoverOneUnderLock` (`agent_run_ledger.zig:573`) are `pub`
  and take readiness or any actuator as an argument.
- ⚠️ `acquireRunLockBounded` ignores `io` and acquires then releases (`agent_run_ledger.zig:470`). A
  caller that sees `acquired=true` holds no lock. The name is a trap.
- ⚠️ `recoverOneUnderLockP` hard-codes `"runs.json"` (`agent_run_ledger.zig:594/614/630`). The plan and
  `recoverAllAtStartup` use `zigbrowser-agent-runs.json`.
- ⚠️ Debug seams are unconditional exports of the production dylib, and `zb_automation_debug_strings_live`
  is exported but not listed in the plan.
- ⚠️ `rdynamic` exports every exe symbol on macOS, not only the two back-refs the plan names
  (`build.zig:181`).
- ⚠️ `zb_secrets_window_open(unsigned long long)` on macOS (`agent_secrets_window_mac.h:23`) shares a name
  with Linux `zb_secrets_window_open(void)` with a different signature.
- ⚠️ `launch.build_argv` is Linux-only and reaches the private `sandbox._LINUX_BACKEND` (`launch.py:97,111`),
  so the Mac launch composition will fork again.

### Recommendations
- Fix the protocol types and add a registered conformance test over both backend classes.
- Name the launch/dispatch slice (mail 7027/7035) as the real production connector for MS6.
- Make the gated recovery entry points non-`pub`, and rename `acquireRunLockBounded` to a probe name or
  make it return the held lock.

---

## Promise Review

### Well-Defined
- ✅ The MS2 async job model matches the plan. One mutex-guarded state moves PENDING → PREFLIGHT →
  DISPATCHING → INFLIGHT → DONE/CANCELLED/ABANDONED. `zb_job_complete` records only in
  DISPATCHING/INFLIGHT and frees otherwise (`wkwebview_shim.m:1578-1592`). The loop-end drain is bounded
  (200 × 10 ms).
- ✅ The health snapshot is lock-backed and `wkwebview_shim.m` has zero `dispatch_sync` uses.
- ✅ The MS5 parent watch `arm()` steps 1-4 exist, and `setup.py` calls it first on Darwin.
- ✅ The macOS 13 profile fallback prints exactly one stderr line.

### Missing or Unclear
- ❌ **P1. The hook spawn mechanism in the plan is not the one in the code.** Plan 1646-1647 promises
  app-side hook spawn with stdio over `SCM_RIGHTS`, and the MS6.1 closure chain (2139) relies on it. No
  `SCM_RIGHTS`, `sendmsg` or `recvmsg` exists. The hook is `zb-hook-run` calling `sandbox-exec` from
  inside the CLI (`hook_run.py:189-208`). Seatbelt profiles do not nest, so the CLI profile needs exec
  rights that the deny-default design must justify. → zigBrowser-4pa.21
- ❌ **P2. The MS6.5 survivor warning and setting do not exist.** Plan 1752-1778 says the gate is cleanup
  plus a warning with [Stop them now]/[Leave them running]/[Show details] and a default-on setting,
  "present and green on both Macs". There is no UI, no setting, and no reader of
  `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS`. The VM-containment gate is wired only into `--agent-setup` via
  an env var (`src/app.zig:62-71`). → zigBrowser-4pa.25
- ❌ **P3. MS5.2 and MS5.3 are not implemented.** Only raw Keychain store, lookup and clear exist
  (`src/agent_secrets_mac.m`). `configureAgentSecrets` returns on non-Linux (`src/app.zig:395`).
  `zb_agent_onboard_token` exists only in an unregistered red. `zb_mac_token_to_fd` has no production
  caller and is not in `build.zig`. → zigBrowser-4pa.28
- ❌ **P4. The hardened-runtime claim is not reproduced by any gate.** MS1b says signed binaries ran
  "ad-hoc AND hardened", and that this makes MS1b a hard prerequisite of MS9.
  `tests/mac/ms1b_signed_gate.sh:80-81` signs ad-hoc only, with no `--options runtime`. The hardened
  evidence lives only in scratchpad notes. → zigBrowser-4pa.26
- ⚠️ `zb_job_wait` has no deadline in DISPATCHING (`wkwebview_shim.m:1616-1618`). The plan says
  "bounded, deadline-guarded".
- ⚠️ Recovery of a frozen window abandons the hung WebContent process. No test checks that it exits.
- ⚠️ `--hardware-acceleration` is stored in `g_hw_policy` and never used, but the plan promises "a single
  observable effect".
- ⚠️ `ZB_DEBUG_FORCE_PRE_MACOS14` and `ZB_DEBUG_SYNTH_CRASH` are honoured in the shipping binary whenever
  `--e2e-protocol` is passed, which is a public flag. The first one silently removes profile isolation.
- ⚠️ There is no Darwin liveness probe. `readStatIo` returns `.open_error` off Linux
  (`agent_run_ledger.zig:332-334`), so even with `reaper_ready` true every Mac entry fails closed. The
  feature is Mac-only, but no slice or bead names the Darwin probe.
- ⚠️ "Recovery completes before the first new agent run" has no owner module
  (`src/agent_startup_recovery.zig` does not exist).
- ⚠️ The MS6.3 real-CLI hard-gate case (`case_ms6_3_fd3_cli.py`) has no profile-mutant row. The plan
  promises a discriminating mutant.

### Recommendations
- Rewrite the MS6 hook design to the real mechanism, or build the app-side spawner.
- Split MS6.5 into the finished reaper core and an open UI/setting/production-caller slice.
- Mark MS5.2 and MS5.3 NOT STARTED or "seam only".
- Add a hardened leg to `ms1b-gate`, or reword the claim to "ad-hoc, not hardened".

---

## Data Model Review

### Well-Defined
- ✅ The ledger parser is strict. `State` is a closed enum `{active, left}`. Unknown fields and kinds,
  duplicates, oversize (64 KiB), over-cap (256), bad basename grammar and non-canonical `start_usec`
  are rejected (`agent_run_ledger.zig:105-150`).
- ✅ The approval card state is a sum type (`Outcome = {waiting, approved, denied, expired, cancelled}`,
  `agent_approval.zig:188`), so "used and expired" cannot coexist.
- ✅ The profile store id is SHA-256 of the normalized path, first 16 bytes, with v4 bits set.
- ✅ The sandbox launch types (`LaunchSpec`, `Network`, `Egress`, `Lifetime`, …) are immutable NamedTuples.
- ✅ `runtime.json`, the `uv.lock` digest and `agent_runtime_pins.json` agree.

### Missing or Unclear
- ❌ **D1. The grant has no data model.** The plan's grant (tuple, 120 s expiry, single use, revoke) has
  no type in the code, so its forbidden states cannot be judged. Specify it as a tagged union (for
  example Minted/Used/Revoked/Expired carrying the tuple) before any MS4.1b code. → zigBrowser-4pa.20
- ❌ **D2. `seatbelt_ready` and `LAUNCH_SPEC_CONSUMABLE` are two independent booleans.** Together they can
  express a forbidden state: "sandbox ready" while the profile still allows all reads. Flipping
  `seatbelt_ready` alone would ship the broad profile. Make the forbidden combination unrepresentable,
  or add a registered test that fails on it. → zigBrowser-4pa.23
- ⚠️ The ledger `pid` is an unchecked `i32` (`agent_run_ledger.zig:40`). A pid of 0 or a negative pid
  parses and classifies the owner as proved dead. It is also not cross-checked against the pid in the
  basename.
- ⚠️ Profile identity is the lexical path. A symlink and its target, or `/a/b` and `/a/b/`, may get
  different stores. Only the relative-vs-absolute case is tested.
- ⚠️ The MS1 census requires every Mach-O to be fat and the two roles to exist. It does not require the
  bundle to equal the inventory, so an extra undeclared file passes. That is weaker than "complete".
- ⚠️ The pinned `.pkg` SHA-256 is copied into six files. The stage tool does not read
  `agent_runtime_pins.json`.
- ⚠️ A Linux-written ledger read on a Mac (or the reverse) fails closed forever, with no retire path.
- ⚠️ Window state is spread over independent fields (`terminatedReason`, `pendingDialogKind`, health
  fields). No defect was found, but crashed/dialog/recovering is not one state.
- ⚠️ `ms5_inventory.py` emits an `sdk-path` resource that the plan's MS5.1c list does not name.

### Recommendations
- Model the grant and the sandbox readiness as single sum types.
- Reject `pid < 2` at parse time and require the basename pid to equal the entry pid.
- Document how path spellings map to profile stores, or canonicalize them.

---

## API Review

### Well-Defined
- ✅ `page.list`, `page.health`, `page.close`, `page.recover` and `dialog.*` branch before router parsing,
  and list/health take no FIFO turn (`automation_server.zig:528-535, 843-844`).
- ✅ `load_serial` is published the same way in `page.list` and `page.health`, and the test checks they
  are equal (`mac_ms4_load_serial_test.py:93-99`).
- ✅ Untrusted paths reach the Seatbelt profile only through `-D` parameters. The profile file is created
  `O_EXCL`, mode 0400.

### Missing or Unclear
- ⚠️ `--egress-port` is accepted by `launch.py` on Darwin, but the Zig helper never passes it. The only
  Mac launch route is a dead path today.
- ⚠️ The capability table entry (`automation_platform.zig:90-95`) is unchanged and has no native flags.
  The real capability source is the PagePort vtable (`supportsNativeMove`/`supportsNativeScroll`). The
  plan says the table changes after MS2b.
- ⚠️ A load commit for a non-current navigation does not bump `load_serial` (`wkwebview_shim.m:641`). This
  is reasonable but untested, and a missed bump would weaken revocation.
- ⚠️ All `automation_server.zig` line cites in the closure maps are stale. `handleRequestWith` is now :467,
  `handleWindows` :744, `handleRecover` :995 and `handleDialogs` :1176.
- ⚠️ The client docs have no "macOS differences" section (beforeunload, native scroll/move, macOS 13
  shared store).

### Recommendations
- Cite symbols instead of line numbers in the closure maps, or regenerate them against HEAD.
- Add a macOS capability/differences section to `docs/how-to-automate.md`, and return distinct reasons
  such as `beforeunload_unsupported`.

---

## Workflow Closure Review

### Well-Defined
- ✅ Closures A and C start at the authenticated socket and observe through production reads
  (`page.url`, `page.health`, `dom.getText`).
- ✅ The MS6.6(B) closure starts at the real `setup.probe_r1` and goes through `sandbox-exec`,
  `route_probe`, the wrapper and a controlled CLI, with a forged-capability mutant and a planted-token
  control.
- ✅ The MS4.4 login-gate closure runs through the real binary and fixtures and is registered
  (`build.zig:2047`).
- ✅ The hard-gate driver fails closed on zero cases, missing checks, an edited case or leftover scratch.

### Missing or Unclear
- ❌ **W1. The MS6.1 token-isolation closure is not implemented.** Its trigger (`zb_agent_run_sync` →
  `MacSeatbeltBackend`) does not exist on any production path. The MS6.1 scripts start at `sandbox-exec`
  with a probe. One uses a hand-written profile (`agent_sandbox_ms6_1_token_isolation.sb`) that differs
  from the generated one. They do not use the fixture SAI with a malicious hook. The sacrificial canary
  target and the positive control are good. → zigBrowser-4pa.21
- ❌ **W2. The MS6.5.1 recovery chain has no production owner.** `recoverAllAtStartup` is called only by
  tests. No code creates the run dir, publishes the `active` entry, creates `run.marker`, or passes
  `ZB_AGENT_RUN_MARKER_FD`; that name appears only in `hook_run.py`. The plan body still says "The owner
  is real launch-path code, not a test-only caller" (1781-1784). The owner is tracked by zigBrowser-3gl.
  The plan text is fixed under → zigBrowser-4pa.19
- ❌ **W3. The AppKit drawer and its ownership closure do not exist.** MS2c.5/MS7.9 (a drawer per popup, a
  shared destroy path, a live-drawer count of zero) has no code and no test. The native approve and deny
  minters (`agent_tools.zig:200,206`) are called only by the GTK drawer (`agent_drawer.c:1218,1228`).
  → zigBrowser-4pa.27
- ❌ **W4. Most Mac gates are not registered.** Only `mac-gate`, `ms1b-gate` and `ms2a-gate` have build
  steps, and none is in `test`. About 53 `tests/e2e/mac_*.py` files and about 30 `tests/mac` scripts run
  only from hand-run scripts (`ms2b_gate.sh`, `ms2c_gate.sh`, `ms3_gate.sh`, `ms4_gate.sh`, `ms5_*`,
  `ms6_*`, `ms7_*`). Linux `zig build test` is green while the Mac runtime layer never runs.
  → zigBrowser-4pa.29
- ❌ **W5. The MS4 gate overclaims.** `tests/mac/ms4_gate.sh` runs only the load_serial and login-gate
  tests. Nothing on macOS covers the -32015 mutants, the MS4.2 negatives or MS4.3. The only real-binary
  MS4.2 negatives (`agent_approval_negatives_test.py`) are Linux-only and unregistered.
  → zigBrowser-4pa.20
- ❌ **W6. The MS5 kill-group closure cannot pass.** `tests/mac/ms5_setup_e2e.sh` exits "NOT ARMED" while
  `seatbelt_ready` is false, and its case (b) is a hard-coded FAIL, because `setup.py` has no
  check-to-register barrier seam (lines 44-47, 66-68). Only the Linux fake-ops test backs the guarantee.
  `ms5_kill_group_gate.sh` tests the netd backstop, not the setup group. → zigBrowser-4pa.28
- ❌ **W7. Many workflow behaviours are unclassified.** MS2b, MS2c.4-5, MS4.3, MS5.1/5.1b/5.2, MS6.2-6.6
  and MS7.1-7.7 have no BLOCKING or LEAF label. Unclassified behaviours default to BLOCKING, and they
  have no closure test. → zigBrowser-4pa.30
- ⚠️ Closure C's JSON still says "terminate+reload". The real mechanism is view-replacement that abandons
  the hung process.
- ⚠️ Closure B's stuck sibling is a pending selector wait, not a wedged main queue. No test holds the main
  queue and still gets list/health. The existing `ZB_DEBUG_DISPATCH_HOLD_MS` hook could do it.
- ⚠️ MS6.4 has no traversal of the production proxy with the fake API. The plan calls this part of the
  gate (1748-1751).
- ⚠️ The MS1b closure runs a pair placed by the test script, not the artifact the shipping script makes.
- ⚠️ The MS8.2 and MS8.3 closures are plan-only. That is fine while MS8 is blocked, but the sub-slices
  being built (MS8.0, MS8.2a) are not in the plan.
- ⚠️ The VM-containment fail-closed check guards only `--agent-setup`, not the launch path.

### Recommendations
- Keep MS6.1 open until its closure runs through the real launch chain. Label the current scripts
  "profile-belt probes".
- Register each slice gate as a named build step with a manifest of its last approved run.
- Classify every behaviour as BLOCKING or LEAF, and derive each BLOCKING closure from a map that matches
  HEAD.

---

## Test-Spec-Quality Review

### Well-Defined
- ✅ The MS1 census suite (27 tests) uses real behavioural mutants and is registered on Linux.
- ✅ `package_problems` (MS5) is a real lstat/scandir oracle with symlink, FIFO and extra-file cases.
- ✅ The MS0 golden-argv test has an anti-tautology guard and a seven-variant matrix.
- ✅ The MS2c crash controls hold for 4 s, which kills the plan's 3 s auto-reload mutant.
- ✅ The reaper kill path is guarded (pid > 1, not self, same uid, double inspection, pinned-dir recheck).
  The current Mac evidence is the signal-free census gate.

### Missing or Unclear
- ❌ **T1. Most behaviours have no Given/When/Then and no named red.** The plan's own protocol (2353)
  requires a named red test, an exact failing assertion, named green files and a refactor gate for
  every MS2-MS8 sub-slice. MS2a.1-3, MS2b.1-2, MS2c.1-5, MS4.2, MS6.2, MS7.1-7.7 and MS8.1-8.2 are
  one-line bullets without them. → zigBrowser-4pa.30
- ❌ **T2. Property fields are missing with no reason given.** The whole plan has three properties
  (MS0.1, MS2a.2, MS7.2). Behaviours with a real input domain have none: MS3.1 (path to store UUID),
  MS3.2 (flag values), MS4.1 (grant tuple), the ledger strict parser, the `resource_phase` shapes and
  `merge_universal_tree`. → zigBrowser-4pa.30
- ❌ **T3. Safety properties rest on source-text oracles.** The MS7 card authority and bubble inertness are
  covered by about 2,000 lines of lexical oracles (`mac_drawer_card_authority_test.py`,
  `mac_drawer_bubble_inert_test.py`) that parse `src/agent_drawer_mac.m`, a file that does not exist.
  Neither is registered. The `reaper_ready` "no environment arming" property is proved by a source
  `indexOf` (`tests/agent_run_recovery_startup_test.zig:184-194`). A stub or a comment could satisfy
  either. → zigBrowser-4pa.27, zigBrowser-4pa.30
- ❌ **T4. A destructive Mac script has no technical guard.** `tests/mac/ms6_5_reaper_gate.sh` sends
  SIGKILL. Its only precondition is that `ZB_MAC_ARM_HOST` is set (lines 15-23). The plan says it must
  not run on the Macs (1769-1777), and the repo already records an unreleased Mac test incident
  (c07899f). → zigBrowser-4pa.24
- ❌ **T5. Reds the plan names do not exist, and some code has no registered test.**
  `tests/agent_run_ledger_concurrency_test.c` and `tests/agent_run_recovery_test.c` do not exist.
  `agent_run_ledger_recovery_txn_test.zig` is unregistered, but the code it covers is in production
  source. Six MS7/MS8 reds are unregistered. → zigBrowser-4pa.29
- ⚠️ The MS0 "captured golden" is a hand-written frozen reference, not argv captured before the refactor.
  The login `build_argv` has no golden variant.
- ⚠️ `test_netd_darwin_v6.py:67` and `test_setup_darwin_r1_v6.py:45` skip to green when `has_ipv6` is
  false, so the reservation property can go unchecked on a green run.
- ⚠️ `ms1b_signed_gate.sh:119` skips the non-uniform render check, so a signed build that opens a blank
  window passes.
- ⚠️ `mac_config_flags_test.py` lacks the before-validate mutant and the "policy unchanged" read that
  plan 1161-1165 promises.
- ⚠️ No test proves `ZB_DEBUG_SYNTH_CRASH` (and the other debug hooks) is inert without `--e2e-protocol`.
- ⚠️ Several test headers still say "RED (unregistered)" for tests that are now in a gate script, and one
  says "not in test" for a test that is registered (`build.zig:3615`).
- ⚠️ `ms5_stage_gate.sh:42` installs an unpinned `sigstore` from pip. The MS6 hard gate already has a
  hash-locked verifier it could reuse.
- ⚠️ The per-slice protocol (2347-2348) tells agents to "record the red runs (on a remote Mac)". That
  conflicts with the owner's rule that Mac runs need RoseCat exact-commit approval and an orchestrator
  release, and with the compile-only R4 tier.
- ⚠️ `ms5_kill_group_gate.sh` could be misread as the item-5 e2e. It only tests `zb_agent_kill_group`.

### Recommendations
- Give each listed behaviour Given/When/Then, a named red with its exact failing assertion, a Property
  or a reasoned skip, and a classification.
- Replace the MS7 lexical oracles with the compiled gate driving a real native card. Replace the
  `indexOf` proof with a runtime hostile-environment test.
- Disable the destructive reaper script by default.
- Amend the protocol so reds are recorded compile-only or under an approved, released Mac run.

---

## Critical Issues (Must Address Before Implementation)

| bd | Findings | Title |
|---|---|---|
| zigBrowser-4pa.19 | K1, K2, W2 (plan text) | Re-baseline rev 28 against HEAD (stale recovery claims, false ABI rows, wrong names, sub-slices not in the plan) |
| zigBrowser-4pa.20 | K3, D1, W5 | The MS4 approval grant contract does not match the code or the drawer plan |
| zigBrowser-4pa.21 | I2, P1, W1 | The Seatbelt backend has no production caller, so the MS6.1 closure is untested; hook mechanism differs |
| zigBrowser-4pa.22 | I1 | Nothing checks that MacSeatbeltBackend conforms to SandboxBackend |
| zigBrowser-4pa.23 | K4, D2 | The Seatbelt profile allows all file reads and all mach-lookup; `seatbelt_ready` is not tied to it |
| zigBrowser-4pa.24 | T4 | `ms6_5_reaper_gate.sh` can SIGKILL on a real Mac with no technical guard |
| zigBrowser-4pa.25 | P2 | The MS6.5 survivor warning, its three options and the auto-stop setting do not exist |
| zigBrowser-4pa.26 | K5, P4 | The shipping `.dmg` path was never converted; the hardened-runtime claim is not gated |
| zigBrowser-4pa.27 | K6, W3, T3 (MS7) | No native drawer; the MS7 gate cannot pass; card safety rests on source-text oracles |
| zigBrowser-4pa.28 | P3, W6 | Keychain onboarding missing; token-to-fd has no caller; the kill-group e2e cannot pass |
| zigBrowser-4pa.29 | W4, T5 | Linux `zig build test` is green while the Mac runtime layer never runs; reds unregistered |
| zigBrowser-4pa.30 | W7, T1, T2, T3 (reaper_ready) | Most behaviours lack Given/When/Then, a named red, a Property and a classification |

Existing beads that overlap and were not duplicated: zigBrowser-3gl (the whole-recovery transaction and
its production owner), zigBrowser-pj8 (netd runs unconfined on Darwin), zigBrowser-ryn (setsid +
double-fork escapes the setup group kill).

### Top five, in plain words

1. **The plan says things the code does not do, and does not say things the code does.** Rev 28 says the
   recovery transaction was removed and `reaper_ready` does not exist; both are in HEAD. The ABI table
   says four missing exports are implemented. Many file and function names are wrong.
   - Impact: `validate_plan` and every reviewer will judge the code against a false description.
   - Fix: rev 29 written from HEAD (zigBrowser-4pa.19).
2. **The Mac sandbox never launches the agent in production, and the token-isolation proof does not use
   the production chain.**
   - Impact: the main security belt (MS6.1) is proved only for a probe run by hand under `sandbox-exec`.
   - Fix: name and build the launch connector, and run the closure through it (zigBrowser-4pa.21).
3. **The generated Seatbelt profile allows every file read and every mach-lookup.** The plan says it
   denies them, and `seatbelt_ready` can be flipped without fixing that.
   - Impact: flipping one constant would ship a much weaker sandbox than the plan promises.
   - Fix: curation item plus a single readiness type (zigBrowser-4pa.23).
4. **The MS4 grant contract is not in the code.** There is no sha256 tuple, account, target_fp or mint
   entry. Revalidation sits in a different place than the plan says. The MS4 gate runs two tests.
   - Impact: MS7 and MS8 would be built on an authority model that does not exist.
   - Fix: rewrite MS4.1 to the real model, or specify the grant type and its reds (zigBrowser-4pa.20).
5. **A SIGKILL test script for the Macs has no technical guard.** The plan says it must not run.
   - Impact: one mistaken run kills processes on a shared Mac. There is already a recorded incident.
   - Fix: disabled by default (zigBrowser-4pa.24).

## Suggested Plan Amendments

```diff
# Frontmatter / header
~ Modify: status "plan for review (rev 28)" and "PLAN ONLY" -> rev 29 "living plan, re-baselined to <HEAD>"
+ Add: a "Built vs not built" table per behaviour (BUILT+REGISTERED / BUILT-UNREGISTERED / NOT STARTED)

# MS1 / MS1b
~ Modify: build-dmg.sh is NOT converted; either convert it (dylib copy, lipo, inside-out sign, otool -L) or move to MS9
~ Modify: MS1b gate proves ad-hoc non-hardened only, OR add a hardened leg to ms1b-gate
- Remove: tests/e2e/mac_session.py and the mac-universal step (never built); cite mac-gate / ms1b-gate

# MS2
~ Modify: ABI table rows for zb_screenshot_png, zb_set_input_files, zb_app_*_agent_drawer -> NOT STARTED; counts 76 = 44 + 32
+ Add: zb_automation_debug_strings_live to the debug-seam list; a census that the dylib exports exactly the promoted set
~ Modify: Closure C node "wk_terminate_reload" -> view-replacement; regenerate all three maps at HEAD (cite symbols)
+ Add: register ms2b-gate / ms2c-gate as build steps; a macOS differences section for clients (beforeunload)
~ Modify: MS2c.5 -> moved to MS7 and marked NOT STARTED

# MS3
~ Modify: applyMacBackendFlag -> webkit.applyBackendFlag; --hardware-acceleration "accepted, recorded, no effect"
+ Add: Property for path -> store UUID (same spelling => same store; documented behaviour for symlink / trailing slash)

# MS4
~ Modify: MS4.1 to the real card + in-ticket options.expect model, or
+ Add: a Grant tagged union (Minted/Used/Revoked/Expired + tuple) with reds, and an account carrier in options.expect
~ Modify: "broker revalidates before dispatch" -> "engine refuses in ticket" (drawer plan D10); state whether `recovering` is checked
~ Modify: MS4 gate claim -> what ms4_gate.sh runs (load_serial + login gate) until macOS refusal e2es exist

# MS5
~ Modify: MS5.2, MS5.3 -> NOT STARTED / seam only; MS5 gate sentence -> "partial: refusal + staging + seam"
+ Add: the setup.py barrier seam, or reword item 5 so the Linux fake-ops test is not called the e2e
+ Add: mac_resource_compat.py --milestone MS5 runs package_problems + runtime_json_problem
+ Add: a registered test that seatbelt_ready is false until the MS6 acceptance commit

# MS6
~ Modify: hook design to "zb-hook-run -> sandbox-exec" (or build the app-side SCM_RIGHTS spawner); justify CLI exec rights
+ Add: MS6.7 read + mach-lookup curation with failing-first Mac rows (WindowServer, CGEvent, screen capture denied)
+ Add: seatbelt_ready cannot be true while the profile is not consumable (one type, or a registered test)
+ Add: [::1] reservation for the bridge ports 51091/31337, or a closure for externally owned bridges
+ Add: MS6.4 production-proxy traversal with the fake API; MS6.3 profile-mutant row
~ Modify: MS6.1 closure trigger -> the named launch/dispatch connector; current scripts relabelled "profile-belt probes"
~ Modify: MS6.5 -> split into reaper core (done) + MS6.5.2 UI/setting/production caller (open)
~ Modify: MS6.5.1 body -> describe the code that is in HEAD (recoverOneUnderLock, reaper_ready) and its gaps
+ Add: "signal iff reaper_ready && setting != off; the env override can only turn auto-stop off"
+ Add: a named Darwin liveness probe item; reject pid < 2 and require basename pid == entry pid
+ Add: ms6_5_reaper_gate.sh disabled by default

# MS7 / MS8
+ Add: a fixture-card entry for MS7 (a production card constructor called by a test seam); chain-sourced card stays MS8.3
~ Modify: observer = the DYLD probe (or build the --e2e-protocol census); real-screen case listed separately as unbuilt
+ Add: MS7.0 / MS8.0 / MS8.2a-c sub-slices to the plan, or stop them while MS8 is blocked
- Remove: reliance on lexical oracles for card authority once the compiled gate drives a real card

# All slices
+ Add: Given/When/Then, a named red + exact failing assertion, Property or reasoned skip, BLOCKING/LEAF for each behaviour listed in T1/T2/W7
~ Modify: per-slice protocol step 2 -> reds are compile-only or run on a Mac only with RoseCat exact-commit approval + orchestrator release
```

## Approval Status

- [ ] **Ready for Implementation** - No critical issues
- [ ] **Needs Minor Revision** - Address warnings before proceeding
- [x] **Needs Major Revision** - Critical issues must be resolved first

The next pipeline step is enhance_plan_with_review (zigBrowser-4pa.7), done by someone other than this
reviewer. The re-baseline (zigBrowser-4pa.19) should come first, because validate_plan
(zigBrowser-4pa.12) needs a plan that matches HEAD. zigBrowser-4pa.24 is a small safety fix that the
owner may want released from the freeze on its own.

## Limits of this review

- No test, build or gate was run, so this review does not say whether any test currently passes.
- The two-arch claims and the mutant runs recorded in commit messages were not re-observed.
- Not every one of the ~46 MS2 tests and ~53 Mac e2e files was read in full. Findings cite the ones that
  were read.
- The MS9 entitlement point about the bundled CLI is a risk to check, not a verified defect.
- Per-slice evidence tables (about 255 claim checks with file:line) were kept in the reviewer's scratchpad
  and summarized here.
