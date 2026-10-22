---
date: 2026-10-22
author: orchestrator, through an independent fresh Opus subagent (owner order: fresh Opus subagents)
plan: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md (rev 29, a7df5e3)
code: HEAD d0f1841
bd: zigBrowser-4pa.12
method: validate_plan; tests run only in a scratch export under unshare
---

# Validation: macOS plan rev 29, range MS4-MS6 (validator ms4-6, 2026-10-22)

Worktree `/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59`, HEAD `d0f1841`. No file under `src/`,
`build.zig`, `agent/`, `packaging/` or `tests/` differs between `e4f705f` (the plan's re-baseline) and HEAD
(`git diff --stat e4f705f HEAD` is empty for those paths), so the plan's cites are valid at HEAD.

**Method.** A hook blocked my own `git archive`, so the coordinator made the scratch export (`…/validate-ms4-6/tree`,
HEAD `d0f1841`). I ran four named steps there, one at a time, each inside
`unshare --user --map-root-user --pid --fork --mount-proc` with its own `--cache-dir`:
`test-agent-run-ledger-darwin-build`, `test-agent-run-recovery-startup`, `test-agent-setup-ms5` and `test-mac-census`.
I also ran three mutants (F1, F3, F4), each edited only in the scratch copy and restored byte-identical afterwards
(checked with `diff`). Everything else comes from reading code and `build.zig`.

## 1. Verdict

**MS4-MS6: FIX-FORWARD, not done.** The code that exists is careful and mostly sound. It is almost entirely
unwired. Nothing in MS5.2, MS5.3 or MS6 is reachable from the shipped macOS binary. macOS `--agent-setup` refuses,
`launch.py` refuses on darwin, and the reaper/ledger/recovery code is linked only into tests. The rev-29
built-vs-not-built table is accurate for these slices, with two overclaims: MS4.4 "BUILT+REGISTERED" (true only for
Linux) and the R29-MS4 "card digest + options.guard" defence (not in the code). I found four MAJOR defects the plan
does not record, or records wrongly:
- a vacuous Darwin cross-compile guard that runs in `zig build test`;
- the broker dropping `options` (and so `guard`) on every carded call;
- the recovery transaction and its tests sharing the wrong store name;
- an unpinned `seatbelt_ready` sitting next to a broad profile.

Counts: CRITICAL 0, MAJOR 9, MINOR 11.

## 2. Table

| Slice / behaviour | Built (file:line) | Production caller | Test registered (build.zig) | Test can fail? | Verdict |
|---|---|---|---|---|---|
| MS4.1a load_serial (shim) | `src/wkwebview_shim.m:316,640-644,1845`; parse `src/automation_macos_port.zig:266,309` | yes: delegate -> snapshot -> `page.list` | Mac test `mac_ms4_load_serial_test.py` NOT registered (hand-run `tests/mac/ms4_gate.sh:39`); Linux twin `automation_load_serial_test.py` registered `:3348,3812` | Mac: only on a released Mac run. Non-current-commit skip (`:641`) is untested (A-W3) | KEEP; add the A-W3 red |
| MS4.1 in-ticket refusal | `src/automation/engine.zig:1226-1237` (`windowRefusal`), `:501-509` (`checkExpect`) | broker phaseA -> engine, Linux only (no drawer/broker on mac) | engine reds registered (`automation_expect_*_test.zig`); `mac_ms4_refusal_test.py` does not exist | Linux yes; macOS none | FIX-FORWARD (author the Mac refusal e2e; add the `recovering` red) |
| MS4 grant/card single-use | `src/agent_approval.zig:211-323` (`Cards`); `src/agent_broker.zig:614-660` (`awaitApproval`) | GTK drawer only (`agent_drawer.c:1218,1228`); on mac `server == null` | Linux registered | yes | KEEP the card; FIX-FORWARD the phaseA options overwrite (F2) |
| MS4.2 negatives / MS4.3 per-write | none on macOS | none | `agent_approval_negatives_test.py` Linux-only, unregistered | n/a | NOT STARTED (as the plan says) |
| MS4.4 login gate via cookie port | `src/automation_macos_cookie_port.zig` (wired `app.zig:627`) | yes | `ms4-4-login-gate-e2e` `build.zig:2047-2053,3799`, **Linux binary + GTK port only** | Linux yes; the WKHTTPCookieStore path only in hand-run `ms4_gate.sh:40` | FIX-FORWARD the status: BUILT-HANDRUN on macOS (F7) |
| MS5 item 2 `self_exe` | `src/self_exe.zig:11-28` | `app.zig:155` (unreachable on mac: gate refuses) | `agent_setup_ms5_wiring_test.zig:47` (Linux branch only) | Linux branch only | KEEP |
| MS5 item 3 `runtimeFor` | `src/agent_setup.zig:43-53` | `app.zig:156` (unreachable on mac) | `agent_setup_ms5{,_python,_devtree}_test.zig` `:3785-3787` | yes (pure) | KEEP |
| MS5 item 4 home lock | `src/agent_home_lock.c` | linked into mac exe (`build.zig:406-407`), called `app.zig:189` | existing Linux lock tests | yes | KEEP |
| MS5 item 5 setup group + parent watch | `app.zig:206-213`; `src/agent_spawn_posix.c:14-33`; `agent/host/zb_agent_host/parent_watch.py:17-46`; `setup.py:942-976` | unreachable (gate) | `test_parent_watch.py` registered (`:2481`,`:3856`), fake ops | fake ops: yes. Mac e2e `ms5_setup_e2e.sh` NOT ARMED, case (b) hard-FAIL (no barrier seam) | FIX-FORWARD (barrier seam, F11) |
| MS5 item 6 platformGate / `seatbelt_ready` | `src/agent_setup.zig:63-75`; `app.zig:72-78` | yes (`--agent-setup`) | `agent_setup_ms5_test.zig:52` pins `platformGate(.macos,false)` | the gate, yes; **the constant is not pinned** | FIX-FORWARD (F4) |
| MS5.1 / 5.1b hard-gate cases | `tests/mac/hard_gate/case_ms5_1*.py`; real `setup.provision` | n/a (pre-ready harness) | `ms5_1{,b}_hard_gate_case_unit` `:3693-3694` | yes (mutated setup.py fails the case) | KEEP |
| MS5.1c inventory/census/merge/relocate/stage | `packaging/macos/{ms5_inventory.py,merge_universal_tree.py,relocate_python_framework.py,stage_agent_runtime.sh}` | build tooling | `test-mac-census` units `:2993-3043`, in `test` `:3679-3686` | yes (mutant suites) | KEEP; FIX-FORWARD pin single source + sigstore pin (F10) |
| MS5.2 Keychain onboarding | raw store/lookup/clear `src/agent_secrets_mac.m`; Zig wrapper `src/agent_secrets_mac.zig` | **none: neither file is in `build.zig`; not linked into the app** | none (Mac `.m` tests hand-run) | n/a | NOT STARTED (as the plan says) |
| MS5.3 token -> fd 3 | `src/agent_token_fd_mac.c:17-59` | none; not in `build.zig` | none | n/a | NOT STARTED; fix the signature (I-W2) |
| MS6 profile generator | `agent/host/zb_agent_host/sandbox_macos.py:151-226` | setup's own runs via `setup_sandbox` (unreachable on mac) | `test_sandbox_macos.py` `:3205`,`:3880` (pins the broad text) | yes for text; none for kernel | FIX-FORWARD (MS6.7 curation, F4) |
| MS6 `MacSeatbeltBackend` | `sandbox_macos.py:355-462` | **none** (`launch.py:152-157` refuses darwin) | `test_backend_contract.py` `:3197`; no conformance test | partly | FIX-FORWARD (I1: fix the Protocol, F12) |
| MS6.1/6.2/6.3 probes | `tests/mac/ms6_1_*`, `ms6_generated_profile_test.sh`, `ms6_3_*` | n/a | hand-run only (`ms6_gate.sh`), one uses hand-written `agent_sandbox_ms6_1_token_isolation.sb` | Mac only | KEEP as probes; closure OPEN (MS6.8) |
| MS6.4 egress / netd Darwin | `agent/host/zb_agent_host/netd.py:780-813` (v4 listen + v6 V6ONLY reservation) | none (`spawnNetd` has no production importer) | `test_netd_darwin{,_v6}.py` `:3895-3896` | yes. v6 skip is `skipUnless(socket.has_ipv6)`, a build flag, not a loopback probe | KEEP; T-W2 as planned |
| MS6.5 reaper core (C) | `src/agent_run_reaper.c:129-185` (engine), `:399-493` (Apple wrappers) | **none: linked only into test modules** (`build.zig:872,1149,1184`) | engine/pin/fp tests `:3620-3629` | yes (injected fakes) | KEEP |
| MS6.5.1 ledger parse/publish/lock | `src/agent_run_ledger.zig:93-252` | none | `:3630-3646` | yes | KEEP; fix pid validation (F6) |
| MS6.5.1 recovery txn | `src/agent_run_ledger.zig:573-634` | none | `recovery_txn_test.zig` unregistered; `test-agent-run-recovery-txn` MANUAL (`:1131-1157`) | not in `test` | FIX-FORWARD (F3, register) |
| MS6.5.1 startup core + `reaper_ready` | `src/agent_run_recovery.zig:334-414` | none | `test-agent-run-recovery-startup` `:3639` | gate-off yes. The readiness proof is a source `indexOf` (`tests/agent_run_recovery_startup_test.zig:184-198`) plus a comptime `!= false` | FIX-FORWARD (I-W3 non-pub; T3 runtime red) |
| MS6 Darwin build guard for ledger/recovery | `build.zig:1043-1052` (in `test` `:3636-3637`), `:1159-1168` | n/a | yes | **no: vacuous** (F1) | FIX-FORWARD |
| MS6.5.2 warning/setting, MS6.5.3 Darwin probe, MS6.7, MS6.8 | absent (`readStatIo` off Linux -> `.open_error`, `agent_run_ledger.zig:332-334`; no reader of `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS`) | none | none | n/a | NOT STARTED (as the plan says) |
| VM-containment stub | `src/mac_vm_containment.zig`; `app.zig:60-71` | `--agent-setup` only, all OSes | `test-mac-vm-containment` `:3647-3648` | yes | KEEP; launch path is MS6.8 (WC-W6) |

## 3. Findings

**F1 MAJOR, CONFIRMED (ran it).** The Darwin cross-compile guards analyze none of the ledger/recovery Zig API.
I appended an unreferenced `pub fn` with a type error to the scratch copy of `src/agent_run_ledger.zig`, and
`zig build test-agent-run-ledger-darwin-build` still exited **0**. Unmutated, it also exits 0.
- Where: `build.zig:1043-1052` builds `src/agent_run_ledger.zig` as a macOS object for both arches. The comment at
  `:1044` says "every top-level decl in the root file is analyzed". The step runs in `zig build test`
  (`:3636-3637`). `build.zig:1159-1168` does the same for `agent_run_recovery.zig`.
- Why it fails: Zig analyzes lazily. Neither file has an `export` or a forcing `comptime` block (grep: none), so
  its `pub` functions are never analyzed for Darwin.
- Proof (Zig 0.16.0, `zig build-obj -target aarch64-macos`, self-written files in my scratch dir):
  - a type error inside an unreferenced `pub fn` built with **exit 0**;
  - the same function reached from one `export fn` failed with **exit 1**.
- Effect: the Darwin "behaves the same" claim is untested by `test`. Only the C reaper body is really compiled.
- Minimum fix: add a `comptime { std.testing.refAllDeclsRecursive(@This()); }`-style root, or a small export
  wrapper module that references every `pub` decl, as the Darwin object root.
- Red: a deliberate Darwin-only type error must fail the step.

**F2 MAJOR, CONFIRMED (code).** The approval phaseA replaces the call's whole `options` with `{expect}`.
- Where: `src/agent_broker.zig:709-714` builds a new `options` object holding only `expect` and `put`s it over
  `args.value.object["options"]`. Any `options.guard` (`router.zig` `Guard`, `:60+`) or other option the call
  carried is silently dropped for every carded call.
- The broker never adds a guard itself (grep: no `guard` in `agent_broker.zig`). Cards carry no digest
  (`agent_approval.zig:217`, `Card = {id, presented_ms, outcome}`).
- Effect: R29-MS4's claim is false for broker-dispatched raw DOM calls. It says "the account, recipient, document
  token and element token are bound into the card's digest (D10) and re-checked by `options.guard`". In fact a
  same-document target or account change is refused by nothing, because origin and `load_serial` do not change.
- This is platform-neutral (Linux today, macOS once MS7/MS8 land).
- Minimum fix:
  - merge `expect` into the existing `options` object instead of replacing it;
  - either attach the card's guard (target element mark) in phaseA, or amend R29-MS4 to say raw-DOM cards are
    bound only to origin + `load_serial`.
- Red: a carded `dom.click` with `options.guard` must still reach the engine with `guard` present.

**F3 MAJOR, CONFIRMED (ran it).** The recovery transaction hard-codes the store name `"runs.json"`, and every test
uses that same name. `test-agent-run-recovery-startup` passes as is (exit 0). With only the test's store name changed
to the plan's `zigbrowser-agent-runs.json`, four tests fail (exit 1): "expected 64, found 0" signalled, and
"signalled … expected 1, found 0".
- Where: `src/agent_run_ledger.zig:594,614,630` load and publish `"runs.json"`. The startup core loads the
  caller's `sub_path` (`agent_run_recovery.zig:389`), and the plan names `zigbrowser-agent-runs.json`.
- Every test passes `"runs.json"`: `agent_run_recovery_startup_test.zig:103,132,213,236`,
  `agent_run_ledger_recovery_txn_test.zig:223`, `agent_run_recovery_concrete_test.zig:101`. So no test can see the
  mismatch.
- Effect: with the real name, every entry ends `.fail_closed`. It fails safe, but recovery could never work.
- The plan records this as I-W5, but its proposed red would pass only if the tests stop using `runs.json`.
- Minimum fix: thread `sub_path` into `recoverOneUnderLock`, and switch one startup test to
  `zigbrowser-agent-runs.json`.

**F4 MAJOR, CONFIRMED (ran it).** `seatbelt_ready` is not pinned, and readiness is two independent booleans next to a
broad profile. With `seatbelt_ready = true` in the scratch copy, `test-agent-setup-ms5` still exits **0**. No test
in the tree reads the constant (grep).
- Where: `src/agent_setup.zig:67`. The only test (`agent_setup_ms5_test.zig:52`) checks `platformGate(.macos,
  false)`, not the constant, so flipping it to `true` passes every Linux test.
- Both profiles still emit `(allow file-read*)`, `(allow process-exec)` and `(allow mach-lookup)`
  (`sandbox_macos.py:169-182,216-226`). That lets a sandboxed process read every user file, including the
  browser's site cookies, and exec anything.
- `LAUNCH_SPEC_CONSUMABLE = False` (`:352`) is a third, unlinked flag.
- Minimum fix: the planned `agent_setup_seatbelt_ready_pin_test.zig` (a comptime `!seatbelt_ready`), plus the D2
  derivation, before any MS6.7 work.

**F5 MAJOR, CONFIRMED (code).** No production path exists for MS5.2, MS5.3 or MS6, and the Keychain code is not
even built.
- Not in any `build.zig` target, so not linked into the app: `src/agent_secrets_mac.m`,
  `src/agent_secrets_mac.zig` and `src/agent_token_fd_mac.c` (grep `build.zig`: none). They are compiled only by
  hand-run Mac scripts (`tests/mac/ms5_token_fd_gate.sh`, `keychain_*_test.m`).
- No production importer: `spawnNetd` and `appendEgressPort` (`src/agent_host_posix.zig:49,205`).
- `launch.py:152-157` refuses darwin. `agent_helper.zig` never sends `--egress-port`.
- The plan says the same (NOT STARTED). This is recorded so the owner reads "BUILT" in those rows as "compiles in a
  test only".
- Minimum fix: MS6.8 plus an `ms5-gate` build step. Until then, label these rows "seam, test-built only".

**F6 MAJOR, CONFIRMED (code).** Ledger `pid` is an unchecked `i32`, and the basename pid is not cross-checked.
- Where: `src/agent_run_ledger.zig:38`, and `parse` (`:105-150`) has no pid check.
- What happens: pid 0 or a negative pid reads `/proc/0/stat` or `/proc/-1/stat`, gets ENOENT, and becomes
  `.absent` -> `.dead` -> `.recover` (`:337-340`). A malformed entry is treated as a proved-dead owner and goes on
  to the destructive teardown path.
- The C engine still skips pid <= 1 for signals (`agent_run_reaper.c:146,162`), so this is not a kill(-1).
- Minimum fix (D-W1): reject `pid < 2` and require basename pid == entry pid in `parse`; add reds for 0, -1, 1 and a
  mismatch.

**F7 MAJOR, CONFIRMED (code).** MS4.4 is listed BUILT+REGISTERED, but the registered step drives only the Linux
binary.
- Where: `build.zig:2047-2053` (runs under `unshare` with Xvfb, GTK cookie port); `:3799` attaches it only when the
  target OS is Linux.
- The macOS `WKHTTPCookieStore` consumer runs only in hand-run `tests/mac/ms4_gate.sh:40`.
- Minimum fix: R29.2 row -> "BUILT+REGISTERED (Linux) / BUILT-HANDRUN (macOS)"; add the `ms4-gate` step.

**F8 MAJOR, CONFIRMED (code).** `tests/mac/ms6_5_reaper_gate.sh` still has only the `ZB_MAC_ARM_HOST` guard.
- Where: `:15-23`. It SIGKILLs real processes on the Macs. The plan's R29-SAFETY technical guard (approved-commit
  env + release token + stub-ssh red) is not implemented.
- Not run by me.
- Minimum fix: as R29-SAFETY specifies (exit 1 "DISABLED" by default) plus the hostless stub-ssh red.

**F9 MAJOR, CONFIRMED (code).** The production recovery transaction has no test in `zig build test`.
- `recoverOneUnderLockP` (`agent_run_ledger.zig:579-634`) is exercised only by:
  - the unregistered `tests/agent_run_ledger_recovery_txn_test.zig`;
  - the MANUAL step `test-agent-run-recovery-txn` (`build.zig:1131-1157`, its comment says it is deliberately not in
    the aggregate).
- The startup test drives it with fakes, under `recoverAllAtStartupGated(true, …)` (`startup_test.zig:236`), with
  the F3 name.
- The test file names the plan gives (`agent_run_ledger_concurrency_test.c`, `agent_run_recovery_test.c`) do not
  exist.
- Minimum fix: register the txn test in the green that fixes F3. Make `…Gated`, `…GatedH`, `…Full` and
  `recoverOneUnderLock` non-`pub` (I-W3).

**F10 MINOR, CONFIRMED.** The pin is duplicated, and sigstore is installed unpinned.
- `stage_agent_runtime.sh:26` hard-codes the pkg SHA-256. Four other files repeat it.
- `ms5_stage_gate.sh:42` runs `pip install sigstore` without hashes (T-W7).
- A test does check `uv_lock_sha256` against the real `uv.lock` (`ms6_hard_gate_entry_test.py:236`), and it matches
  (sha256 computed).
- Fix: make the stage tool read `agent_runtime_pins.json`, and use the hash-locked `sigstore_verifier.txt`.

**F11 MINOR, CONFIRMED.** MS5 item 5 has a Linux proof only.
- `setup.py` has no `--e2e-protocol` barrier between `arm()` steps 1 and 2.
- `ms5_setup_e2e.sh` case (b) cannot pass.
- The browser only waits (`app.zig:206-213`): no exit-path `killpg` (C-W6).
- `zb_agent_spawn_group` (`agent_spawn_posix.c:14-33`) does not set `POSIX_SPAWN_CLOEXEC_DEFAULT`, unlike `_io`
  (`:47-49`), so setup inherits every non-CLOEXEC browser fd.
- Fix: add the barrier seam, and set CLOEXEC_DEFAULT plus explicit stdio in `zb_agent_spawn_group`.

**F12 MINOR, CONFIRMED.** The I1 conformance gap points the wrong way in the plan.
- Both backends define `network(self, session=None)` (`sandbox.py:307`, `sandbox_macos.py:371`). The Protocol
  declares `network(self)` (`sandbox.py:213`).
- Mac `launch_spec` silently ignores `ro_paths`, `state_dirs`, `net_dir` and `seccomp_fd` (`sandbox_macos.py:413-442`),
  and defaults `state_dirs=()` where the Protocol says `STATE_DIRS`.
- Fix: correct the Protocol, and raise on ignored inputs as I1 says.

**F13 MINOR, SUSPECTED.** The profile lease may delete the profile before `sandbox-exec` reads it.
- `MacSeatbeltBackend.launch` removes the profile dir as soon as the `with` body returns (`sandbox_macos.py:449-462`).
- A caller that only `Popen`s (no wait) can race `sandbox-exec`'s own `-f` read, which happens after exec.
- No caller yet. The setup path waits (`setup.py:789-790`), so it is safe.
- Fix: document that the lease must outlive the run, or delete only after `sandbox-exec`'s child is up.

**F14 MINOR, CONFIRMED (probe).** `ledger.RealClock` is Linux-only, and it ignores clock read failure.
- `agent_run_ledger.zig:399-410` calls `std.os.linux.clock_gettime` with no target check and ignores its failure.
  It compiles for both macOS arches (probe exit 0) and emits Linux-ABI syscall instructions.
- `agent_run_recovery.zig:222-223`'s comment says it "mirrors" RealClock, but `realClockRead` is per-OS and fails
  closed.
- Today only tests use RealClock.
- Fix: route RealClock through `nowMsFrom(realClockRead)`.

**F15 MINOR, CONFIRMED.** `acquireRunLockBounded` takes the lock and releases it at once (`agent_run_ledger.zig:469-488`).
`acquired=true` therefore holds nothing (I-W4). Rename it to `probeRunLock`, or return the held fd.

**F16 MINOR, CONFIRMED.** The approval card list grows without bound. `Cards.cards` (`agent_approval.zig:215`) is
never pruned, so it grows by one entry per card for the session. Locking is a spin on `tryLock` from the GTK thread.
Fix: drop terminal cards once their outcome has been read.

**F17 MINOR, CONFIRMED.** macOS and Linux setup are duplicated, and the VM gate reaches Linux.
- `runAgentSetupMacos` (`app.zig:148-215`) repeats about 80% of the Linux body (`:85-141`).
- Linux still uses raw `readlink("/proc/self/exe")` (`:89`, `:229`) rather than `self_exe.path`.
- The macOS VM-containment gate also refuses Linux setup when `ZIGBROWSER_AGENT_VM_CONTAINMENT=on` (`:60-71`).
- Fix: one shared setup body over `self_exe` + `runtimeFor(builtin.os.tag, …)`.

**F18 MINOR, CONFIRMED.** Keychain lookup truncates at an embedded NUL. `zb_keychain_lookup` copies `data.length`
bytes (`agent_secrets_mac.m:~101-106`), but `zb_mac_token_to_fd` and `zb_keychain_free` use `strlen`, so a NUL
inside the token truncates the write and the wipe. Fix: return the length, or refuse a NUL at store time.

**F19 MINOR, CONFIRMED.** Two census units are weaker than their siblings. `mac_census_unit` and
`mac_ms5_census_unit` (`build.zig:2993-3007`) do not fail on `ResourceWarning`, unlike every sibling step. Add the
same check.

**F20 MINOR, CONFIRMED (ran it).** Some registered tests depend on the environment or never reach the Darwin path.
- `test-mac-census` failed under the brief's mandatory `--map-root-user` wrapper.
  `test_ms5_1b_skipped_link_bytes.test_the_census_fails_closed_on_an_unreadable_file_or_a_fifo` expects
  `hidden.bin` to be unreadable after a chmod. That does not hold for uid 0 inside the namespace.
- This is a wrapper artifact, not a product defect. But the test assumes it is not root and does not skip or assert
  that.
- The same run skipped 6 `ms6_hard_gate_harness_test.SpawnGroupWithoutWaitid` tests ("no kqueue here"). The Darwin
  no-waitid path never executes on Linux, so it is proven only on a Mac.
- Fix: guard the unreadable-file control with `os.geteuid() != 0` (fail "NOT RUN" rather than pass), and count the
  Darwin-only skips in the Mac tier.

**Plan statements found accurate** (spot-checked against code):
- R29.1(a): `reaper_ready` is false at `agent_run_recovery.zig:334`; nothing calls `recoverAllAtStartup`; there is
  no Darwin probe.
- `launch.py:152-157` refuses darwin; `_LINUX_BACKEND` is used at `launch.py:97`.
- The profile is broad.
- The hook Darwin branch (`hook_run.py:189-225`) is the real mechanism, with marker fd 5.
- netd has the dual-family reservation (`netd.py:798-800`).
- There is no `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS` reader.
- `tests/mac/ms4_gate.sh` runs only `load_serial` and the login gate.

**Unverified risk:** that `sandbox-exec` can apply the hook profile from inside the CLI's own Seatbelt sandbox
(`hook_run.py:207`) has no Mac evidence in the tree beyond a pending hard-gate case. If nested application is
refused, the P1 hook mechanism fails.

## 4. Commands run (all read-only; DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/SSH_ASKPASS unset for the zig runs)

| Command | Exit |
|---|---|
| `curl … localhost:51091/notify` (voice notice, per the user's global CLAUDE.md) | 0 |
| `git -C <wt> log/diff --stat/status/rev-parse` (read-only) | 0 |
| `git -C <wt> archive HEAD \| tar -x -C <scratch>/tree` | **BLOCKED by hook, not run** (the coordinator made the export) |
| `zig build test-agent-run-ledger-darwin-build -j4` (export, unshare, timeout 900) | 0 |
| same step with an unreferenced type-error `pub fn` appended to the scratch `agent_run_ledger.zig` (fresh cache) | **0** (F1) |
| `zig build test-agent-run-recovery-startup -j4` | 0 |
| same step with the test's `"runs.json"` changed to `"zigbrowser-agent-runs.json"` (fresh cache) | **1**, 4 tests fail (F3) |
| `zig build test-agent-setup-ms5 -j4` | 0 |
| same step with `seatbelt_ready = true` (fresh cache) | **0** (F4) |
| `zig build test-mac-census -j4` | 1 (one root-in-namespace artifact, F20; 6 Darwin skips) |
| `diff -q` of each mutated file against the worktree after restore | 0 (restored) |
| `grep`/`sed`/`cat`/`wc` over plan, `src/`, `agent/`, `tests/`, `build.zig`, `packaging/` | 0 (some greps 1 = no match) |
| `sha256sum agent/host/uv.lock packaging/macos/sigstore_verifier.txt` | 0 (both match `agent_runtime_pins.json`) |
| `timeout 120 unshare --user --map-root-user --pid --fork --mount-proc zig build-obj -target aarch64-macos` probe.zig (undeclared id) | 1 (AstGen error, as expected) |
| same, probe.zig (type error in unreferenced `pub fn`) | **0** (F1) |
| same, probe2.zig (same error reached from `export fn`) | 1 |
| same, probe3.zig (`RealClock` copy, exported), aarch64-macos and x86_64-macos | 0, 0 (F14) |
| `python3 -I -c` byte count of syscall opcodes in probe3 objects | 0 |
| `rm -rf -- "${DIR:?}"` of `<scratch>/validate-ms4-6` (export, caches, probes) | 0 |

No full `zig build test`, no Mac script and no ssh was run. `tests/mac/ms6_5_reaper_gate.sh` and
`hard_gate_driver.py` were read only.
