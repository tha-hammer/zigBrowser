---
date: 2026-10-14T14:30:00-04:00
planner: cc_3 / JadeBeacon (Opus 4.8)
git_commit: e4f705f922f2059bb62782db5fdcca288709e3a2
original_plan_pin: ed13e5ef582d1256cbe92bf06bb0bb3526210ca1
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "macOS launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, macos, wkwebview, appkit, seatbelt, universal-build, automation, drawer, sandbox, launch-critical]
status: living plan, rev 32 - closed the 8 PARTLY gaps from the independent re-check (recheck-macos.md) on top of rev 31 (29 rule-audit gaps), rev 30 (exercise-the-code rule + MS0-9 code validation, bd zigBrowser-4pa.12, findings .55-.80); code validated at d0f1841, plan baseline e4f705f
rev: 32
rebaselined_to: e4f705f922f2059bb62782db5fdcca288709e3a2
code_unchanged_since: c07899f (the review's commit; no src/, build.zig, agent/, packaging/ or tests/ change between c07899f and e4f705f)
review: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan-REVIEW.md (BlueBeaver, Needs Major Revision, 26 critical + 52 warnings)
last_updated: 2026-10-22
last_updated_by: rev 31 - enhance_plan_with_review agent (Sonnet 5.5) closing the 29 gaps of 2026-10-14-14-30-macos-launch-tdd-plan-RULE-AUDIT.md (docs only); rev 30 - enhance_plan_with_review agent (Sonnet 5.5) for the owner exercise-the-code order and bd zigBrowser-4pa.12 findings 4pa.55-4pa.80, on behalf of the orchestrator; rev 29 - enhance_plan_with_review agent (Sonnet 5.5) for bd zigBrowser-4pa.7
last_updated_note: "HISTORICAL, NOT NORMATIVE changelog; current proof requirements are in the Verification rule + Rev 30 + Rev 31. Rev 31 (2026-10-22): closed the 29 gaps of the independent rule audit (RULE-AUDIT.md); see the section 'Audit gaps closed' at the end. Rev 30 (2026-10-22): applied the owner's exercise-the-code verification rule (new top section, verbatim) and the independent MS0-9 code validation (bd zigBrowser-4pa.12, three VALIDATION files, code HEAD d0f1841): findings bd zigBrowser-4pa.55 to .80 plus 34 minors. Read the section 'Rev 30' after the Rev 29 section and the 'Verification rule compliance' table at the end. In rev 30 the MS7.6/7.8 portable half is RED-UNREGISTERED and not built, MS4.4 is registered on Linux only, the Darwin cross-compile guard is a tripwire, and the macOS approval minters are inert. Rev 29 (2026-10-22): LIVING PLAN, RE-BASELINED TO HEAD e4f705f. Rev 28 was no longer a true description of the code. Rev 29 FIRST re-baselines (bd zigBrowser-4pa.19: K1, K2, W2 plan text) and THEN applies every finding of the independent review (K1-K6, I1-I2, P1-P4, D1-D2, W1-W7, T1-T5 and all 52 warnings). Read the section 'Rev 29' right after the revision history: it holds the HEAD facts, the Built-vs-Not-built table, the name/citation corrections, the finding map and the cross-cutting amendments; the 'Behavior specification ledger' before 'Dependency order' gives every listed behaviour a Given/When/Then, a named red with its exact failing assertion, a Property or a reasoned skip, and a BLOCKING/LEAF class. Where any older text below (revs 2-28, the frontmatter note, the MS6.5.1 body) conflicts with Rev 29, Rev 29 wins. Implementation freeze zigBrowser-4pa.1 still holds: this is a docs-only revision. Rev 28 (2026-10-22, JadeBeacon): the MS6.5.1 recovery row is ACCEPTED SCOPED (RoseCat c11bff8, commit ff7c699) as ONLY the Linux one-live-process liveness probe + portable fail-closed action-label mapping — the cumulatively-fixed probe (schema v2 platform-tagged start_kind, canonical per-kind shape, same-kind-only comparison that fails closed on a cross-kind identity, StartRead I/O outcome mapping) plus the bounded, cancellable flock acquire under one absolute monotonic deadline. It is NOT the whole-recovery transaction: NO two-browser / other-browser exclusion, NO startup-recovery pass, NO signals or retires, NO ledger-mutating transaction, NO Darwin same-kind probe, and NO UI result — every such earlier 'two-browser', 'startup recovery', 'signals/retires' and recovery-GREEN claim in this plan is SUPERSEDED by this scoped boundary. [REV 29 CORRECTION OF THIS REV-28 SENTENCE: it was false of HEAD. `RecoveryAction`, `publishWithout`/`publishWithoutCut`, `recoverOneUnderLock`/`recoverOneUnderLockP` ARE in production source at src/agent_run_ledger.zig:500-634 (added by 09dca89, 05ce038, cf1778e and later commits), and the startup core `recoverAllAtStartup*` plus `pub const reaper_ready: bool = false;` are in src/agent_run_recovery.zig:328-410. They are BUILT-UNARMED: no app-startup owner calls them and the gate ships false. The whole-recovery transaction PROTOTYPE is therefore not history-only; what is still OPEN is the production owner, the Darwin liveness probe, the registration of its tests and the full gate (bd zigBrowser-3gl).] The full whole-recovery transaction is the named OPEN blocker bd zigBrowser-3gl: production owner/call path, held-fd (dev,ino,uid,mode) provenance before teardown, typed fixed-point outcome, census/kill/fresh-census, marker unlink -> rmdir -> ledger retirement under the ONE flock, one absolute deadline over acquire AND held work, a deterministic exact-result two-recoverer red ({.signalled,.already_gone} pair + terminal child statuses + empty final ledger + two signal entries under the early-unlock mutant), registration, and a full gate. [REV 29 CORRECTION: the recovery transaction code EXISTS in HEAD but is NOT ARMED and has NO production owner: no production recovery pass or signal call is reachable because `pub const reaper_ready: bool = false;` exists at src/agent_run_recovery.zig:334 and nothing calls `recoverAllAtStartup`. The earlier sentence 'there is no `reaper_ready` constant yet' is withdrawn.] Rev 27 (2026-10-21): answers RoseCat mail 7362/7363 — the widened whole-recovery flock claim exposed a liveness gap: a BLOCKING flock(LOCK_EX) cannot be capped by the recovery deadline (that caps only work AFTER acquisition), so a frozen live holder would wedge the bounded startup queue and every new agent run indefinitely. Fix: acquisition is now BOUNDED/cancellable LOCK_EX|LOCK_NB + monotonic retry inside the SAME total recovery deadline (both the wait-to-acquire and the held work are capped). Acquire-failure/deadline/cancel => fail closed: zero liveness/census/signal/retire/unlink/ledger mutation, entry retained, a fixed recovery-busy/lock-unavailable incident surfaced, UI responsive, the first new agent run refused/deferred (never hung), later retry may recover. Owner-driven Stopping takes the same bounded acquisition before its terminal mutation; failure stays Survivors/authority-retained, never an uncoordinated clean. New red: two-process live-stalled-holder (A alive+holding stalls; B returns fail-closed within the deadline, zero signals/mutation), and a blocking-LOCK_EX mutant that must exceed the deadline/hang and be killed by the watchdog. Rev 26 (2026-10-21): answers RoseCat ec24db0's two remaining items. (1) A recoverer holds the one global ledger flock across the WHOLE recovery of an entry — liveness revalidation -> census/kill/fresh-census fixed point -> marker unlink -> rmdir -> ledger removal, releasing only at the end (bounded by the fixed-point deadline) — so exactly one recoverer enters the signal/kill phase; a second blocks then finds the entry gone. Revalidating liveness AFTER taking the flock closes the died-after-first-read window. Red: two independent recoverers + one real marked child, exactly one enters the signal phase; release-the-flock-early mutant lets BOTH in. (2) C4 crash cut sharpened: the ledger store is old-or-new complete, never torn, idempotent on both sides of the rename. Also fixed the startup ordering: mkdir -> openat+pin -> create run.marker -> publish 'active' -> ONLY THEN spawn any process (marker before any inheritor, 'active' before any marker-holder). Rev 25 (2026-10-21): orchestrator SIMPLIFICATION answering RoseCat 565e107's five blockers (all from the per-run owner.lock lease) by DROPPING the lease entirely. The ONE cross-process global ledger flock (<runtime_dir>/.zigbrowser-agent-runs.lock, O_CLOEXEC|O_NOFOLLOW, not inherited by children) is now the only claim and is held across the WHOLE terminal sequence: claim -> unlinkat(run_dir_fd, run.marker) -> unlinkat(runtime_fd, name, AT_REMOVEDIR) -> ledger removal -> release, so the destructive teardown is one atomic crash-released critical section and two recoverers can never race (no split-inode race, no owner.lock to mis-target). Startup liveness is proved from the entry's (pid,start) with ONE fail-closed rule: pid absent => recover; pid live + start match => leave untouched (live owner); pid live + different start (reuse) OR unreadable => fail closed. Fewer files => fewer crash cuts: a crash-cut table enumerates C1-C4, each with one signal-free idempotent recovery (C2 marker-less empty dir => openat ENOENT finish; C3 entry naming no dir => drop). Tests updated: two-process/two-recoverer ledger reds, two-instance (pid,start) recovery red, C1-C4 crash-cut reds. Rev 24 (2026-10-21): MS6.5.1 answers RoseCat ee626d0's three blockers on rev 23 — (1) the ledger transaction is guarded by an OS-visible cross-process flock on <runtime_dir>/.zigbrowser-agent-runs.lock (held from read through parent-dir fsync, released by process death), not a process-local mutex; two-PROCESS barrier red + remove-the-flock-loses-an-entry mutant. (2) startup recovery never touches a LIVE app's runs: it must take the per-run owner lease (flock on <run-dir>/owner.lock) non-blockingly — acquire FAILS => a live owner holds it => leave untouched; acquire SUCCEEDS + (pid,start) proved dead => recover; live/reused/unreadable liveness fails closed; two-BROWSER red. (3) the Clean teardown crash cut after marker unlink but before rmdir is specified: a provenance-valid empty marker-less dir recovers via openat(run.marker)=>ENOENT, finishes rmdir+entry-remove idempotently, never a permanent incident, never a signal; crash-cut red. Rev 23 (2026-10-21): MS6.5.1 answers RoseCat 3118838's three remaining blockers on rev 22 — (1) ONE app-global ledger actor wraps each read-validate-update-write-fsync-rename-dirfsync transaction so a concurrent run can never erase another (barrier reds for publish/publish and publish-or-remove/update); (2) Stopping is a bounded census->kill->fresh-census FIXED POINT reaching Clean only after a complete EMPTY final census (a marked process can fork after the single gather, agent_run_reaper.c:188-202; spawn-during-pass-one red + no-recensus mutant; a cap/deadline/incomplete census is Survivors); (3) reaper_ready is an IMMUTABLE source/build constant like agent_setup.zig:60-73's seatbelt_ready, never the env_switch pattern (env_switch.zig:1-27 is flag/env-driven and a hostile ambient value must not arm signalling; bypass mutant). Plus crash-after-marker/dir-removal-before-ledger-removal recovery (active entry naming no dir is dropped), normal stop/close sweeps off the UI thread under a total deadline, and revs 19-22 added to the revision-history list. Rev 22 (2026-10-21): MS6.5.1 Darwin lifecycle-owner section answers RoseCat 012e1bc (5 blockers) + 3c39b9f/7327 — the run marker is a dedicated non-token reserved descriptor inherited EXPLICITLY at every seam (browser→netd, browser→helper, sandbox-exec/CLI relay, nested hook, double-fork), each with a production-chain red + drop-the-pass-fd mutant and no collision with token fd 3 / egress fd 4 / census broker fd (agent_spawn_posix sets CLOEXEC_DEFAULT, child holds only 0-2); the owner record is a versioned, strictly-parsed, bounded schema published temp+fsync+rename+dir-fsync with named crash cuts and malformed/duplicate/truncated/swapped/symlinked handling (never signal until durably published); the state machine gains Clean unlink(marker,no-follow)→rmdir→record-remove order, [Leave] retires the entry to a terminal `left` state (never swept), window/session close ownership, SIGKILL→next-start-only, exactly-once races, and [Stop them now] DISABLED on an incomplete fresh census; the setting is a named app-owned atomic PERSISTED value with env>persisted>default precedence and a UI write path; a named `reaper_ready` hard gate keeps production signalling unreachable until the reviewed destructive gate passes; the stale 'Both-Mac gate GREEN' claim (7fa8906) is SUPERSEDED. Frontmatter bumped 17→22 (body had advanced through revs 19-22). Earlier: Rev 11 records MS1b GREEN (commit 3421428, option d): the WKWebView ObjC shim is built by the Apple toolchain as a chained-fixups dylib (xcrun clang -dynamiclib, -Wl,-fixup_chains + -undefined dynamic_lookup; -install_name @executable_path/../Frameworks; exe sets rdynamic macOS-only to export the two back-refs zb_ipc_dispatch/zb_policy_decide), so the SIGNED x86_64 binary runs (was SIGSEGV at [ZBAppHost init]; cause = zig 0.16 classic LC_DYLD_INFO_ONLY into signed __DATA_CONST). The MS1 bundle is now {browser + webview-shim dylib}; resource_phase accepts the empty-resources set only for that exact 2-component shape (6002 bypass protection kept). MS1.3 gains release_least_privilege (disable-library-validation forbidden in a release manifest/binary; ad-hoc dev/test only). ms1b_signed_gate.sh is registered as `zig build ms1b-gate`; validated rc 0 on both Macs (x86_64+arm64, ad-hoc+hardened). Linux/Windows build unchanged. (Frontmatter rev was stale at 6 while body sections advanced to rev 10; bumped to 11.) Shim surface confirmed by BlackRobin (6125)."
primary_research: thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md
---

# macOS Launch Support for zigBrowser — TDD Implementation Plan

> **LIVING PLAN, rev 32 (rev 29 re-baselined to HEAD `e4f705f`; rev 30 validated against code at `d0f1841`; rev 31 closed the 29 rule-audit gaps; rev 32 closed the 8 PARTLY gaps from the independent re-check `recheck-macos.md`, see "Audit gaps closed" at the end).** Rev 30 applies
> the owner's verification rule (the section "Verification rule: prove it by running it", below) and the MS0-9 code validation;
> the statuses and proofs in this plan are current as of rev 30. This revision is docs-only. The
> implementation freeze `zigBrowser-4pa.1` is in force: no product code, tests or build files
> change in this revision. **Mac execution rule (rev 29, review warning on protocol step 2):**
> agents do NOT ssh/scp to either Mac and do NOT execute any test binary there without
> (1) RoseCat exact-commit approval AND (2) an orchestrator release. The default evidence tier
> is the **compile-only R4 tier** (`tests/mac/mac_compile_only.sh`): a red is "recorded" as a
> compile/link result or a Linux-side result unless a released Mac run says otherwise. Never on
> the user's local `DISPLAY :0`, live profile, or live sockets. Every UI slice ends with a
> real-screen check judged by the user, coordinated by the orchestrator. Older text below that
> says "run on the remote Macs" is read through this rule.

## Verification rule: prove it by running it (owner, 2026-10-22)

The owner's order: agents check code by exercising it, not by reading or "checking" it. This rule overrides any looser wording elsewhere in this plan.

1. **A behavior is proven only by running the real code path.** The test calls the production function, C export, binary or script with real inputs. It asserts on the observable result: return value, output, persisted state, process state, or a UI row. A test that reimplements the logic, or drives a copy of it, proves nothing.
2. **Registered or it does not count.** The test must be in a build.zig step that `zig build test` or the named platform gate runs. An unregistered test is a draft.
3. **Red, green, then a mutant.**
   - The red must fail for the stated reason before the green exists.
   - After the green, at least one mutant of the PRODUCTION code (not the test) must make the test fail. Record the mutant, the command and the failing output in the commit message.
   - A test that stays green under its mutant is not proof.
4. **Platform code is proven on the platform.** AppKit/Objective-C, Keychain, Seatbelt, Win32/C++, WebView2 and Credential Manager are proven only by running them, under a release, on that platform: the two Macs (x86_64 and arm64), the Win11 VM, or the Win10 box. A Linux build or cross-compile proves only that the code compiles.
5. **Source-text checks are tripwires, never proof.** grep, regex, lexers, "the symbol exists", "the file contains", nm, strings and otool listings may guard against regressions. They never close a behavior, a slice, a review finding or a validation finding.
6. **Wired, not just present.** A behavior that a production caller never reaches is NOT BUILT, even if its unit test passes. Each behavior names its production entry point, such as a CLI flag, an app start path or a menu action. An end-to-end test proves that the entry point reaches the code.
7. **Skip is failure.** Under a gate, a skip, an exit 77, or zero real rows or asserts is a failure.
8. **Validators follow the same rule.**
   - validate_plan, reviews and code checks mark a claim VERIFIED only after running its test, or a mutant of it, and recording the command and exit code.
   - Reading code alone gives SUSPECTED.
   - "Passes" means the run was observed in this session, at a named commit.
9. **Every behavior states its proof.** Each behavior lists:
   - (a) the production entry point it exercises;
   - (b) the test file and its build.zig step;
   - (c) the mutant that must make it fail;
   - (d) for platform code, the platform run and its host or hosts.

   A behavior missing any of these is not ready for implementation.

## Revision history — HISTORICAL, NOT NORMATIVE

- **Rev 1** (`d857a03`): first plan, slices MS1–MS7.
- **Rev 2** (this): answers RoseCat's review `21625eb` ("BLOCKED", 9 blockers + 5
  open-question dispositions). Direction and user decisions were accepted; the plan was
  blocked for not being safe/specific enough to start. Rev 2 re-pins to HEAD `21625eb`,
  corrects the sandbox-interface layer, adds a pre-MS5 **Linux extraction slice (MS0)** and a
  **macOS setup/provisioning slice (MS5)**, splits MS2's single closure map into **three
  production chains**, gives native input a **capability spike contract**, makes the
  **Seatbelt security proofs hard launch gates that select the VM fallback**, specifies the
  **approval grant contract**, closes **Keychain + chat observability**, hardens the
  **two-arch/packaging gates against false-green**, and makes the **signing contract
  release-safe**. Slices are renumbered MS0–MS9.
- **Rev 3** (this): answers RoseCat's review `833767e` ("BLOCKED (docs)", 6 remaining
  blockers + a SHOULD list). Rev 2 "substantially closes the nine findings"; three contracts
  remained inconsistent and three more surfaced. Rev 3 re-pins to HEAD `833767e`, corrects
  MS5 to the final **"Hook commands only"** SAI rule (and inherits the S3a chain/alias/
  malformed-quote corrections), binds the **exact drawer grant schema**, moves the **positive
  approval closure to MS7** (where the only grant minter is built), makes the **ABI inventory
  the real production ABI** (adds `set_script`/`free`/`loop_mark`/`window_alive`/
  `native_pointer`/row-sanitization/cookie ABI + a debug-seam fail-closed decision), gives
  **every popup its own drawer bound to its `window_id` with one shared destroy path and a
  live-drawer-count-of-zero** proof, and adds the **crash-presentation parity** contract. The
  SHOULD items are folded into MS2/MS7.
- **Rev 4** (this): answers RoseCat's review `db02324` ("BLOCKED (docs)" for `a02f1ea`;
  `5bebd42` APPROVED only as the frontmost-application API-name fix), three remaining
  contracts. Rev 4 re-pins to HEAD `176782f`, **moves the positive end-to-end approval
  commit closure out of MS7 into MS8** (where the production CLI/helper/protocol-pump path
  that delivers `tool_use` actually exists, so the chain never injects inside the forbidden
  span or routes through the automation socket) and leaves MS7 owning only native-card
  mint/deny with a **native AppKit `sendEvent:` click** (not "X click"); replaces the prose
  ABI inventory with a **literal export-by-export table of all 75 `webkit_shim.h` exports**
  (every export assigned a slice, including `zb_main_invoke_sync`/`zb_automation_window_id_at`/
  `zb_automation_run_generation`), with a **link-time fail-closed** mechanism for every seam
  not implemented on macOS (an unsupported seam is absent from the macOS shim, so any test or
  caller referencing it fails to link — a build failure, not a silent zero); **moves the
  cookie ABI from MS2c to MS3** so it no longer depends on a slice ordered after it; and
  **splits in-process CGEvent→NSEvent delivery (`-[NSWindow sendEvent:]`, no system post, no
  TCC) from `CGEventPost`** (the former is the spiked-first primary, the latter stays out
  unless a separately approved capability is genuinely needed). It also updates the MS5
  dependency from the superseded `cab60a1` to the approved green `da5eb70`, and fixes the two
  SHOULD items (the stale `21625eb` pin prose and the Linux-idiom "real-X" crash control
  label).
- **Rev 5** (this): answers RoseCat's **one remaining rev-4 blocker** (mail `5501`), which
  confirmed three of the four db02324 blockers closed and left a narrow one: the rev-4 ABI
  table claimed the config flags' unsupported mechanism was `int<0 + out_err`, but the pinned
  ABI has **`void` setters, bare-`int` getters, and no setter at all for `--renderer`** — that
  error path is not executable. Rev 5 moves the unsupported decision to a **named fallible
  app-level Zig seam, `applyMacBackendFlag(flag, value) !void` in `src/webkit.zig` (called from
  `src/app.zig`)**, which validates each flag/value **before** any void C setter and, on an
  unsupported value, **refuses — the real binary exits nonzero with an exact message and never
  touches the C ABI**; a supported value is applied (void setter and/or `WKPreferences`).
  `--renderer` is handled entirely by this Zig seam (no C ABI). The impossible `out_err` claim is
  dropped from the table and MS3.2, and `mac_config_flags_test.py` is named for both the
  supported-applies and unsupported-exits-nonzero cases. Rev 5 also records the advisory **F2**
  finding (macOS has no per-sandbox loopback for the `127.0.0.1:3128` proxy hop) as an **open
  design item in MS6** that points at the shared sandbox interface, to be settled by BlackRobin
  and RoseCat in the drawer plan — not here. Re-pinned to HEAD `74413b0`.
- **Rev 6** (this): answers RoseCat's **one rev-5 blocker** (review `ed13e5e`): rev 5 left the
  MS6 egress transport as an explicitly unsettled open item, which is not implementation-ready.
  Rev 6 **pins it** as a shared `SandboxBackend` **egress capability** — the backend supplies
  both the loopback proxy *endpoint* and the *policy*. macOS: **host netd on an OS-selected
  per-session `127.0.0.1:<port>`**; the generated CLI/helper Seatbelt profile permits **only** that
  endpoint; `HTTPS_PROXY`/`HTTP_PROXY` name that exact port; netd keeps the exact CONNECT/SNI
  allowlist; **each hook's own profile permits only loopback 51091/31337, with no proxy endpoint
  and no API path**; and MS6.4 proves the endpoint, both bridge positives, every denial, and that a
  hook cannot reach the proxy. The **Unix-socket-proxy option is ruled out** (the bundled CLI
  rejects Unix-socket proxy URLs — BlueBeaver 5503), so a TCP `host:port` hop is mandatory. Linux
  realizes the same capability with private-netns fixed ports + relays. The capability is captured
  in the MS0 launch spec; MS6 realizes the macOS half. Re-pinned to HEAD `ed13e5e`.
- **Rev 7** (this): a docs-only scope correction after MS1's red landed and both Macs built
  (a universal fat binary was assembled with `lipo`, ad-hoc signed, and its entitlements
  verified on both hosts; JadeBeacon). The MS1.1 census required four fat Mach-O components
  (browser, Python runtime, Claude CLI, helper launcher), but the macOS MS1 build ships
  **only the browser** (`build.zig:168` installs `zigBrowser`; the agent runtime is a separate
  non-default step), and there is no universal2 Python (the Intel host has Xcode python 3.9,
  the arm host Homebrew 3.14). Rev 7 sets MS1's **fixed inventory to `{browser}`** — "complete"
  means every component the bundle **actually ships** — while keeping the census mechanism and
  its fail-closed tests unchanged, and moves the three agent-runtime roles (plus the two-tree
  resource-compat check) into **MS5's red**, where the macOS Python runtime/CLI/launcher are
  first installed and the Intel 3.9 vs arm 3.14 Python mismatch is exactly the incompatibility
  the `resource_compat` oracle exists to catch. Re-pinned to HEAD `f18a5f1`.
  (Orchestrator-directed; sent to RoseCat for review before the MS1 green is written against it.)
- **Rev 8** (this): answers RoseCat's two rev-7 representation blockers (mail `5989`, review
  `a15a66b`), both contract-shape — the `{browser}` scope itself was accepted. (1) The helper
  launcher `zb-claude` is a **generated Python shebang script** (`token.py:100-140`, written at
  `setup.py:492`) at `runtime/bin/zb-claude`, **not a Mach-O**, so MS5.1c cannot require it as a
  fat component. Rev 8 classifies the MS5 roles: the **Python interpreter and the bundled Claude
  CLI are native/fat Mach-O**; the **launcher is a generated script** whose bytes must be
  byte-compatible across arches — a **resource** the `resource_compat` oracle checks, not a fat
  Mach-O role (a universal2 runtime at one python path makes the wrapper identical; if it differs,
  the oracle fails closed). (2) A browser-only MS1 ships **no non-exec resource**, so MS1's
  inventory `resources` is **empty by design** and the two-tree oracle is **first exercised at
  MS5** (where the runtime's non-exec files exist in two per-arch trees) — not a silent drop:
  MS1.1 states it, and the oracle's fail-closed-on-empty stays an MS5 guard. Re-pinned to `99f11b1`.

- **Rev 9** (this): answers RoseCat's rev-8 blocker (mail `5995`, review `6a3980c`) — the MS5 role
  typing was accepted, but MS1's `resources: []` was still **prose that resolved the oracle conflict
  by not calling `resource_compat` at all**, which "is indistinguishable from accidentally deleting
  the check." Rev 9 makes it an **executable, mutation-resistant, shape-checked phase policy**:
  `resource_phase(milestone, inventory, …)` (`tests/e2e/mac_universal_test.py`) accepts an empty
  resource inventory **only for the EXACT browser-only MS1 bundle** — milestone `MS1` AND exactly
  one component at the fixed browser path `bin/zigBrowser` AND no resources — and **fails closed for
  any other empty shape** (MS5, unknown/"" label, an extra or non-browser component, or an MS5-shaped
  manifest relabeled MS1); otherwise it runs the two-tree oracle. `mac_resource_compat.py` gains a
  **required `--milestone`**, passes the **whole inventory**, and routes through the gate, so the
  green **calls** it at every milestone (MS1 included) rather than skipping it. The label alone was a
  bypass (RoseCat 6002): checking only `--milestone` let a python-runtime manifest relabeled MS1 pass.
  Tests (`58551bb`): MS1-browser-only-empty passes *and asserts*; MS5-empty, unqualified-empty,
  MS1-extra-component, MS1-non-browser-component, MS5-shaped-relabeled-MS1, and MS5-nonempty-mismatch
  all fail. The executable gate landed in `c53b580` then `58551bb`; re-pinned to HEAD `774ce31`.
- **Rev 10** (this): the MS1 green ran on both Macs and surfaced two macOS realities, split out per the
  user's "split it out, fix now". (1) The **ad-hoc-signed x86_64 binary segfaults at startup** in
  `-[ZBAppHost init]`'s `[super init]` (`0xf0000001`); the unsigned binary and the signed arm64 slice
  run fine — a zig-linker/codesign/ObjC interaction. So **MS1 runs the UNSIGNED universal binary** for
  MS1.1/MS1.2 and signs a **copy** only for the static MS1.3 `codesign -d` check; **MS1 does NOT prove
  a signed binary RUNS**, and the new slice **`MS1b`** does (well before MS9's Developer-ID signing).
  (2) zig 0.16's `fromPosixSignalContext` mis-aligns the x86_64 macOS signal `ucontext_t` and panics,
  hiding the real fault; `src/main.zig` **disables the segfault handler on macOS only** (Linux keeps
  the exact default). MS1 is GREEN on both Macs through `tests/mac/gate.sh` (universal fat binary,
  executing-arch readback x86_64 + arm64, MS1.3 entitlements on the signed copy, m9 render/reply/
  load-fail, the `--milestone MS1` resource gate). Cause write-up: `scratchpad/ms1/CRASH_CAUSE.md`.
- **Rev 14** (BlueBeaver, 2026-10-20): MS5's per-OS contracts for BlueBeaver's half (setup, fd-3 delivery,
  census), agreed with JadeBeacon (mail 6756): the runtime in `Contents/Frameworks/agent-host`, macOS setup refuses
  until MS6's Seatbelt backend is accepted, the home lock extracted to POSIX C, posix_spawn plus a process group
  and kqueue parent watch for dying with the browser, MS5.3 partial until MS6 and MS7, and the census `path_glob`s
  waiting on the user's universal2-Python decision. Rev 13 is JadeBeacon's MS2a ABI amendment (1df6df0).
- **Rev 16** (BlueBeaver, 2026-10-20): MS5.1c corrections found while pinning the census. On macOS the runtime is
  always `<exe>/../Frameworks/agent-host`, a dev tree included. `zb-claude` and the other runtime scripts are
  per-user setup output, never bundle resources. The bundle's own resources are `zb_agent_host/` and
  `runtime.json`. MS5 gets a separate inventory, and a staging tool brings the verified framework in.
- **Rev 17** (BlueBeaver, 2026-10-20; RoseCat 6865): rev 16's corrections folded into the authoritative text.
  Item 3, item 8's opening and Behavior MS5.1c are rewritten in place, and the rev 8 and rev 16 notes are marked
  history. `zb_agent_host/` is an exact generated file manifest (missing, extra or mismatched are each red).
  `runtime.json` is pinned. The staging tool takes the driver-verified `.pkg`. The final MS5 green stays blocked
  on the dependency and CLI layout decision. (Fix, RoseCat 6871: every symlink or special entry under
  `zb_agent_host/` is refused, with reds for a symlink to an outside canary and a FIFO.)
- **Rev 18.1** (BlueBeaver, 2026-10-21; RoseCat 7120): MS6.6 (B) is a **pre-`seatbelt_ready` harness** that calls the
  real `setup.probe_r1` directly under the staged pinned runtime. It is not a case of the armed `ms5_setup_e2e.sh`,
  which refuses to arm until `seatbelt_ready`; that would be a cycle, since (B) gates `seatbelt_ready`. The app stays
  fail closed. The rev 18 SIGILL blocker is marked resolved (`aa83b5f`).
- **Rev 18** (BlueBeaver, 2026-10-21; RoseCat 7019, 7041, 7050, 7053): a new hard gate, **MS6.6, R1 under
  Seatbelt**, with two named dependencies. **(A)** the census broker (unit) and the kernel-properties gate.
  **(B)** the real Mac production chain, run on the pinned runtime and dependency tree. (A) green lets the broker
  land, scoped as incomplete. Only (B) green may count toward `seatbelt_ready`, MS6 completion, or any launch
  slice that uses the Mac backend.
- **Rev 19** (JadeBeacon, 2026-10-21): MS6.5 accept-with-cleanup per the user's decision — public libproc/kill
  only, stop/start cleanup, survivor warning with [Stop them now]/[Leave them running]/[Show details], VM
  containment stubbed off by default; the earlier "no survivors / Failure ⇒ VM required" criterion withdrawn.
- **Rev 20** (JadeBeacon, 2026-10-21): the CLI/dependency-tree decision (the user's lipo universal2 + crypto
  48.0.1 both chips + python.org framework relocation) folded into MS5.1c.
- **Rev 21** (JadeBeacon, 2026-10-21; RoseCat 3c39b9f / 7327): first MS6.5.1 Darwin lifecycle-owner section —
  browser-owned run root, explicit marker, recorded provenance, fresh re-census before a user stop, fail-closed
  errors. BLOCKED (docs) in `012e1bc` before its red.
- **Rev 22** (JadeBeacon, 2026-10-21; RoseCat `012e1bc`, mail 7333): MS6.5.1's five `012e1bc` findings made
  executable — the marker becomes a dedicated non-token reserved descriptor inherited **explicitly at every spawn
  seam** (browser→netd, browser→helper, sandbox/relay/CLI, nested hook, double-fork), each with a production-chain
  red + a drop-the-pass-fd mutant, because `zb_agent_spawn_group_io` sets `CLOEXEC_DEFAULT` and the child holds
  only fds 0-2; the ledger gains a versioned/bounded/strictly-parsed schema published temp+fsync+rename+dir-fsync
  with named crash cuts; the state machine gains `Clean` unlink/rmdir ordering, `[Leave]`→terminal `left`, exact
  races; the setting becomes an app-owned atomic persisted value; `reaper_ready` and the superseded GREEN claim
  land. BLOCKED (docs) in `3118838` before its red (three remaining gaps). Frontmatter brought to rev 22.
- **Rev 23** (JadeBeacon, 2026-10-21; RoseCat `3118838`, mail 7338): the three remaining `3118838` gaps closed —
  one **app-global ledger actor** wraps each read-validate-update-write-fsync-rename-dirfsync transaction so a
  concurrent run can never erase another (barrier reds); `Stopping` becomes a bounded **census→kill→fresh-census
  fixed point** that reaches `Clean` only after a complete EMPTY final census (spawn-during-pass-one red +
  no-recensus mutant); `reaper_ready` becomes an **immutable source/build constant** like `seatbelt_ready`, never
  the env-switch pattern (bypass mutant); plus crash-after-removal recovery (an `active` entry naming no dir is
  dropped), normal stop/close sweeps off the UI thread under a total deadline, and revs 19-22 added here.
- **Rev 24** (JadeBeacon, 2026-10-21; RoseCat `ee626d0`, mail 7345): the three remaining `ee626d0` gaps closed —
  (1) the ledger transaction uses an **OS-visible cross-process `flock`** (not a process-local mutex), so two app
  instances cannot lose an entry (two-process barrier red); (2) **startup recovery excludes a live owner** via a
  per-run **owner lease** (`owner.lock` flock) plus a proved-dead `(pid,start)` — a held lease or a
  live/reused/unreadable identity leaves the run untouched and fails closed (two-browser red); (3) the **crash cut
  after marker unlink, before `rmdir`** gets an `ENOENT`-marker recovery that finishes teardown idempotently,
  never a permanent incident, never a signal (crash-cut red). Frontmatter to rev 24.
- **Rev 25** (JadeBeacon, 2026-10-21; orchestrator simplification answering RoseCat `565e107`, mail 7350): all
  five `565e107` blockers came from the per-run `owner.lock` lease, so the lease is **dropped entirely**. The ONE
  cross-process global ledger `flock` becomes the only claim, **held across the whole terminal sequence** (claim →
  `run_dir_fd`-relative marker unlink → `rmdir` → ledger removal), so teardown is one atomic crash-released
  critical section — no split-inode race, no mis-targeted unlink, two recoverers can never race. Startup liveness
  is proved from the entry's `(pid, start)` with one fail-closed rule (absent → recover; live+match → leave;
  reuse/unreadable → fail closed). A **crash-cut table** (C1–C4) gives each remaining cut one signal-free
  idempotent recovery. Frontmatter to rev 25.
- **Rev 26** (JadeBeacon, 2026-10-21; RoseCat `ec24db0`, mail 7352): the two remaining items. (1) a recoverer
  holds the one global ledger flock across the **whole recovery** (liveness revalidation → census/kill/fixed point
  → marker unlink → `rmdir` → ledger removal), so exactly one recoverer enters the signal phase (two-recoverer +
  real-marked-child red; release-early mutant lets both in). (2) C4 is **old-or-new complete, never torn,
  idempotent on both sides of the rename**. Also fixed the startup ordering: marker created before `active` is
  published, `active` published before any spawn. Frontmatter to rev 26.
- **Rev 27** (JadeBeacon, 2026-10-21; RoseCat mails 7362/7363): the widened whole-recovery flock claim exposed a
  liveness gap — a **blocking `flock(LOCK_EX)`** cannot be capped by the recovery deadline, so a frozen live holder
  would wedge the startup queue and every new agent run forever. Fix: **bounded/cancellable `LOCK_EX|LOCK_NB` +
  monotonic retry inside the same total recovery deadline** (caps the wait-to-acquire too); acquire-failure ⇒ fail
  closed (zero signal/mutation, entry retained, a recovery-busy incident, the first new run refused/deferred not
  hung, later retry may recover); owner-driven `Stopping` uses the same bound and stays `Survivors` on failure.
  New red: two-process live-stalled-holder (B returns fail-closed within the deadline) + a blocking-`LOCK_EX`
  mutant that must hang and be watchdog-killed. Frontmatter to rev 27.
- **Rev 28** (JadeBeacon, 2026-10-22; RoseCat `c11bff8`/`cdedf98`, mail 7657/7667): the MS6.5.1 recovery row is
  **ACCEPTED SCOPED** as ONLY the Linux one-live-process liveness probe + portable fail-closed action-label
  mapping (schema v2 platform-tagged `start_kind`, canonical per-kind shape, same-kind-only comparison, `StartRead`
  I/O mapping) plus the bounded `acquireRunLockBounded` flock-acquisition primitive under one monotonic deadline
  (commits `ff7c699`…). ~~`RecoveryAction`/`publishWithout`/`recoverOneUnderLock` and the two-recoverer prototype are
  removed from production source.~~ **[Rev 29: FALSE of HEAD — see Rev 29 §R29.1; they are in production source,
  built-unarmed.]** The whole-recovery transaction's production OWNER, two-browser/other-browser exclusion proof at
  the app level, the startup queue wiring, the Darwin liveness probe, registration of its tests and the full gate
  remain **NOT implemented and NOT armed** (no production recovery pass or signal is reachable; ~~no `reaper_ready`
  constant exists yet~~ **[Rev 29: `pub const reaper_ready: bool = false;` exists at src/agent_run_recovery.zig:334]**)
  and are the named **OPEN blocker bd `zigBrowser-3gl`**. See the authoritative SCOPED-ACCEPTANCE block at the head of
  the MS6.5.1 body as amended by Rev 29; every superseded whole-recovery claim there is subordinate to it. Frontmatter
  to rev 28.
- **Rev 29** (enhance_plan_with_review agent for bd `zigBrowser-4pa.7`, 2026-10-22; independent review
  `…-macos-launch-tdd-plan-REVIEW.md`, BlueBeaver, code at `c07899f`, status Needs Major Revision): the plan is
  **re-baselined to HEAD `e4f705f`** (code identical to `c07899f`) and made a LIVING PLAN. Order of work (owner
  instruction): (1) **re-baseline first** — stale recovery claims (K1), false ABI rows and counts (K2), wrong
  file/function/step names, stale line cites, the in-flight sub-slices MS7.0/MS7.1/MS7.4/MS7.6-7.8/MS8.0/MS8.2a/b
  added, every unbuilt behaviour marked NOT STARTED (bd `4pa.19`); (2) then every remaining finding: MS4 rewritten to
  the real card + in-ticket `options.expect` model with a typed grant spec (K3, D1, W5; `4pa.20`); MS6 hook mechanism,
  production launch connector and `MacSeatbeltBackend` conformance (P1, I1, I2, W1; `4pa.21`/`4pa.22`); Seatbelt
  read/mach-lookup curation item MS6.7 and a single readiness type (K4, D2; `4pa.23`); destructive-script guard (T4;
  `4pa.24`); MS6.5 split into reaper core and open UI/setting/caller slice MS6.5.2 (P2; `4pa.25`); packaging/hardened
  claims (K5, P4; `4pa.26`); MS7 gate/native-drawer/oracle fixes (K6, W3, T3; `4pa.27`); MS5.2/5.3 NOT STARTED and the
  kill-group closure seam (P3, W6; `4pa.28`); gate registration (W4, T5; `4pa.29`); and a Given/When/Then, named red +
  failing assertion, Property-or-reasoned-skip and BLOCKING/LEAF class for every listed behaviour (W7, T1, T2, T3;
  `4pa.30`). Every one of the 26 critical findings and 52 warnings maps to an amendment in the Rev 29 finding map.
  Frontmatter to rev 29.
- **Rev 30** (enhance_plan_with_review agent for the owner's exercise-the-code order and bd `zigBrowser-4pa.12`, 2026-10-22;
  validations `…-VALIDATION-ms0-3.md`, `…-ms4-6.md`, `…-ms7-9.md`, code `d0f1841`): (1) the owner's verification rule is inserted
  verbatim as the first top-level section; (2) every proof that rested on reading, grepping, symbol presence or source parsing
  is now a labelled tripwire beside an exercising proof, or the behaviour is marked UNPROVEN (R30.2, 20 conversions); (3) status
  corrections: the MS7.6/7.8 portable half is RED-UNREGISTERED (`4pa.72`), MS4.4 is registered on Linux only (`4pa.69`), the
  Darwin cross-compile guard is vacuous (`4pa.63`), the macOS minters are inert (`4pa.75`), plus every other BUILT claim the
  validations disprove (R30.1, 25 rows); (4) each critical and major finding `4pa.55` to `4pa.80` is a red or a fix-forward in
  its owning slice (R30-MS0 to R30-MS9) and the 34 minors are traced; (5) two open owner decisions with recommendations
  (R30.3); (6) a finding map (R30.4) and a "Verification rule compliance" table at the end of the plan. Frontmatter to rev 30.
- **Rev 31** (enhance_plan_with_review agent for the independent rule audit `…-macos-launch-tdd-plan-RULE-AUDIT.md`, VERDICT PASS WITH GAPS (29),
  2026-10-22; docs only): all 29 gaps closed in place and listed in the section "Audit gaps closed" at the end. Highlights: the
  false "reaper gate is disabled by default / enforced in code" sentence (G5.1, bd `4pa.70`) is rewritten as a REQUIRED fix-forward
  that is not in code; the live-only MS4 `load_serial` mutants and socket separation moved out of the historical rev-6 section
  (G5.7); remaining text-check closures relabelled TRIPWIRE with an exercise-form proof named (L1-L6); the compliance table
  recounted (BUILT+REGISTERED 9, UNPROVEN 38, NOT BUILT 28, Complete = yes 5); one Secrets-window symbol name
  (`zb_secrets_window_mac_show`); and a dependency order for the 26 Rev-30 fix-forwards (critical `4pa.55` first). Frontmatter to rev 31.

## Rev 29 — RE-BASELINE TO HEAD `e4f705f`, THEN EVERY REVIEW FINDING (AUTHORITATIVE)

Source: independent review `2026-10-14-14-30-macos-launch-tdd-plan-REVIEW.md` (BlueBeaver, code `c07899f`, "Needs
Major Revision": 26 critical + 52 warnings). **HEAD re-baselined against: `e4f705f922f2059bb62782db5fdcca288709e3a2`.**
No file under `src/`, `build.zig`, `agent/`, `packaging/` or `tests/` differs between `c07899f` and `e4f705f`, so
every review file:line cite is valid at this HEAD (verified by `git diff --stat c07899f HEAD`, empty, and by spot
checks in R29.1). This revision is **docs-only** (freeze `zigBrowser-4pa.1`). Order of work, per the owner:
**R29.1–R29.3 are the re-baseline (bd `zigBrowser-4pa.19`) and come first; R29.4 onward applies the rest.**
Corrections to older text are also marked in place with `[REV 29 …]` markers that point back here.

### R29.1 Re-baseline — what HEAD actually contains (bd `4pa.19`: K1, K2, W2 plan text)

**(a) Recovery code (K1) — the rev-28 claim "removed from production source / no `reaper_ready`" was FALSE.**
Verified at HEAD:
- `src/agent_run_ledger.zig:500` `pub const RecoveryAction`; `:547` `publishWithoutCut`; `:557` `publishWithout`;
  `:573` `pub fn recoverOneUnderLock`; `:579` `pub fn recoverOneUnderLockP` (injectable publish ops); `:469`
  `pub fn acquireRunLockBounded`. Added after the rev-28 edit by `09dca89`, `05ce038`, `cf1778e` and others.
- `src/agent_run_recovery.zig:334` `pub const reaper_ready: bool = false;`; `:365` `recoverAllAtStartup` (readiness
  is `reaper_ready` and nothing else); `:368` `recoverAllAtStartupGated(ready, …)`; `:371` `…GatedH`; `:382`
  `recoverAllAtStartupFull(…)` which calls `ledger.recoverOneUnderLock` (`:405`).
- **State:** BUILT-UNARMED. The transaction, the startup core and the immutable constant exist; **no app-startup
  owner calls them**, no code creates the run dir / publishes the `active` entry / creates `run.marker` / passes
  `ZB_AGENT_RUN_MARKER_FD` (that name appears only in `hook_run.py`), and there is **no Darwin liveness probe**
  (`readStatIo` returns `.open_error` off Linux, `agent_run_ledger.zig:332-334`, so every Mac entry fails closed even
  if `reaper_ready` were true). The OPEN blocker bd `zigBrowser-3gl` therefore owns: production owner/call path,
  Darwin probe, registration of the tests below, and a full gate. bd `zigBrowser-3gl`'s own description repeats the
  stale rev-28 text and must be corrected by its owner (not edited by this revision).
- **Registration at HEAD:** `tests/agent_run_recovery_startup_test.zig` is registered (`build.zig` ~`:1176`).
  `tests/agent_run_ledger_recovery_txn_test.zig` (covers production code), `tests/agent_startup_recovery_integration_test.zig`
  and `tests/agent_run_ledger_two_recoverer_proto_test.zig` are **UNREGISTERED**. The two C tests the plan names,
  `tests/agent_run_ledger_concurrency_test.c` and `tests/agent_run_recovery_test.c`, **do not exist** (see R29.5-T5).

**(b) ABI table (K2).** `src/webkit_shim.h` has **76** exports (**44 production + 32 debug**), not 75 (44 + 31). The
debug set is 31 `zb_automation_debug_*` (the 30 the plan counted plus the unlisted `zb_automation_debug_strings_live`)
plus `zb_drawer_debug_live_count`. Presence in `src/wkwebview_shim.m` at HEAD (checked symbol by symbol):
- **NOT STARTED on macOS (the plan said "impl"):** `zb_screenshot_png`, `zb_set_input_files`,
  `zb_app_set_agent_drawer`, `zb_app_get_agent_drawer`. The macOS port vtable (`src/automation_macos_port.zig:54-77`)
  has no entry for screenshot or input-files; `src/webkit.zig:131-134` says macOS has no drawer backend.
- **Absent by design:** the five SUPERSEDED rev-13 symbols; `zb_native_scroll`/`_move`/`_pointer` (synthetic-only,
  user decision 2026-10-20); `zb_ipc_dispatch`/`zb_policy_decide` live in Zig, not the shim.
- **Debug seams present on macOS:** exactly `zb_automation_debug_live_jobs`, `_waiter_grace`, `_strings_live`.
  Every other debug seam, and `zb_drawer_debug_live_count`, is absent at link time.
- The ABI table below is amended row by row (R29.3-ABI); the count line "44, all implemented" is withdrawn.

**(c) Sub-slices already in flight that rev 28 did not contain — now ADDED to the plan (finding WC-W5):**

| Sub-slice | What it is (HEAD) | Evidence | State |
|---|---|---|---|
| **MS7.0** | the portable drawer logic (`zb_drawer_*`) compiles and is exported by both macOS objects | `da37c1c`; `build.zig` step `cross-check-drawer-mac` (`:477`), in `cross-check` only [Rev 30, V79-m3: `test` runs only the `cross_check` command, not this step]; `src/agent_drawer.zig:633-636,671-728` | **NOT BUILT** (Rev 30, rule 6): a symbol-presence TRIPWIRE with no production caller on macOS (`applyAgentDrawer` returns false, `src/webkit.zig:134`); R30.1 #6 |
| **MS7.1 (portable half)** | AppKit dock geometry `zb_drawer_appkit_frame` | `build.zig` step `test-agent-drawer-appkit` (`:749`) | portable SEAM, driven but status NOT BUILT (R30.0, Rev 31 G4.1: no production caller) (driven, 7/7 observed at d0f1841); the behaviour is NOT BUILT (Rev 30, rule 6: no AppKit caller); AppKit dock view NOT STARTED |
| **MS7.4 (portable half)** | bubble text seam `zb_drawer_appkit_shown/_original_offset`, `bubbleLayoutContiguous` | step `test-agent-drawer-appkit-text` (`:780`), `tests/agent_drawer_appkit_text_test.zig` | portable SEAM, driven but status NOT BUILT (R30.0, Rev 31 G4.1: no production caller) (driven, 7/7 observed at d0f1841); the behaviour is NOT BUILT (Rev 30, rule 6); `ZbBubbleView`, Edit menu NOT STARTED |
| **MS7.6/7.8 (portable half)** | the card press decided in portable logic (claimed; not built); the card's one minter checked by relocation on both Darwin objects (TRIPWIRE — not proof; the proof is the compiled gate `grants` row, UNPROVEN: the card and gate do not exist) | steps `test-agent-drawer-card-press` (`:767`), `check-card-authority-mac` (`:534`); `tests/mac_card_authority_objects_test.py` | **RED-UNREGISTERED. NOT BUILT** (Rev 30, bd `4pa.72`; the rev-29 "portable BUILT + REGISTERED" was FALSE): `Approver`, `cardPress` and `zb_drawer_card_press` do not exist in `src/agent_drawer.zig`; `test-agent-drawer-card-press` exits 1 (5 compile errors) and `check-card-authority-mac` exits 1 on both arches (observed at d0f1841); neither step is in `test` or `cross-check`; AppKit card NOT STARTED |
| **MS7 compiled hard gate** | the two-Mac compiled authority gate for the AppKit drawer | `c63020d`: `tests/mac/ms7_appkit_{gate.sh,check.py,case.py,probe.m}`, `tests/e2e/ms7_appkit_gate_test.py` | RED, UNREGISTERED, not run (and cannot pass before MS8; see K6 below) |
| **MS7.5 (portable half)** | Secrets-window controller logic + C entry header | `5e71d67`: `src/agent_secrets_window_mac.h`, `tests/agent_secrets_window_mac_logic_test.zig` | RED, UNREGISTERED (imports a module that does not exist; Rev 30, `4pa.76`: the entry name `zb_secrets_window_open` clashes with `agent_secrets_window.h:56`); the AppKit window NOT STARTED |
| **MS8.0** | the approval cards' minters and window lifecycle defined in both macOS builds; the GTK-only tool call stays Linux-only | `29744db` (red `52d8f00`); `build.zig` step `cross-check-agent-tools-mac` (`:504`), in `cross-check`/`test` (`:3923`) | **NOT BUILT** (Rev 30, bd `4pa.75`; was BUILT + REGISTERED): the macOS minters always return 0 (`agent_tools.start` is Linux-only) and nothing calls them; the step is a symbol-presence TRIPWIRE that passes with the inert minter (observed) |
| **MS8.1 (portable core)** | macOS host spawner pure core + `spawnNetd` integration (`src/agent_host_posix.zig`, `agent_spawn_posix.c`) | `build.zig` `:822-840`, `tests/agent_host_posix_spawn_test.zig` | **NOT BUILT** per R30.0 (Rev 32): the portable seam is driven and registered (12/12 and 8 kill-group cases observed at d0f1841) but has no production importer of `spawnNetd`; production Mac launch NOT STARTED |
| **MS8.2a** | the portable helper core's chat path driven with recording ports (no GLib, no process) | `2a851b5`, `7a04182`: `tests/agent_helper_core_test.zig` | RED, UNREGISTERED |
| **MS8.2b** | the POSIX process transport under that core | `tests/agent_helper_posix_test.zig` (untracked in the worktree at HEAD) | RED, uncommitted, UNREGISTERED |
| **MS8.2c** | macOS production wiring of the core to the AppKit drawer and the broker | named in `tests/agent_helper_core_test.zig:6` | NOT STARTED |

**(d) Wrong names corrected (I-W1; full table in R29.3).** `automation_wk_port.zig` → `automation_macos_port.zig`;
`automation_wk_cookie_port.zig` → `automation_macos_cookie_port.zig`; `applyMacBackendFlag` → `webkit.applyBackendFlag`
(`src/webkit.zig:40`) deciding through `backend_flag.backendFlagDecision` (`src/backend_flag.zig:31`);
`agent_broker.mint`/`on_approve_clicked` → `zb_agent_tools_approve` (`src/agent_tools.zig:200`) → `Cards.approve`
(`src/agent_approval.zig:279`); `src/agent_drawer_mac.m` and `tests/e2e/mac_session.py` do not exist; the build steps
are `mac-gate` (`build.zig:241`), `ms1b-gate` (`:247`), `ms2a-gate` (`:254`), never `mac-universal`.

### R29.2 Built vs not built — per behaviour (one table; statuses are the only allowed words)

Status words: **BUILT+REGISTERED** (a production entry point reaches the code and a driven test of it runs in a `zig build` step that `test` depends on; a step that only compiles or lists symbols does not count),
**BUILT-HANDRUN** (the code is wired, but its tests run only from a hand-run script or an unregistered step; by rule 2 they are drafts, so the behaviour is UNPROVEN),
**BUILT-UNARMED** (code and a driven test exist but no production caller reaches it; by rule 6 the behaviour is NOT BUILT), **PARTIAL**, **RED-UNREGISTERED**, **NOT STARTED**, **NOT BUILT**, **UNPROVEN**. Mac-only gate steps (`mac-gate`, `ms1b-gate`,
`ms2a-gate`) are **outside `test`** only because `test` never depends on them [Rev 30, V03-F9: the earlier "excluded by design, `unguarded` list, `:4045`" was wrong; `:4045` is the display-guard skip list], so a green Linux
`zig build test` says nothing about the Mac runtime layer (W4).

| Behaviour | Status at `e4f705f` | Evidence / what is missing |
|---|---|---|
| MS0.1 backend seam | BUILT+REGISTERED | `sandbox.py` `SandboxBackend`; `test_backend_contract.py` (`build.zig:3194`) |
| MS1.1 census / `resource_phase` | BUILT+REGISTERED (unit); Mac census UNPROVEN; bundle == inventory **NOT BUILT** (Rev 30) | 27 census tests (`build.zig` ~`:3679`, 27 OK observed at d0f1841); does NOT require bundle == inventory (D-W3): a demo run found 0 failures with an undeclared non-Mach-O file |
| MS1.2 executing-arch readback | BUILT-HANDRUN | `exec_arch_probe.py` over `telemetry.query`; runs in `mac-gate` only |
| MS1.3 entitlements | **TRIPWIRE-ONLY / UNPROVEN** (Rev 30; was BUILT+REGISTERED (static)) | one key (`network.client`); launcher/helper/CLI keys NOT derived (C-W9); Rev 30: the Mac check signs with the plist and compares the result to the same plist (tautology) and the key does nothing without App Sandbox (`4pa.61`, `4pa.79`) |
| MS1.4 fail-closed runner | BUILT-HANDRUN | `tests/mac/gate.sh` |
| MS1 `build-dmg.sh` conversion | **NOT STARTED** | copies only the exe (`packaging/macos/build-dmg.sh:71`), no `libwkwebview_shim.dylib`, ad-hoc `--deep` (`:92`); a `.dmg` built today cannot load its shim (K5) |
| MS1b signed run | BUILT-HANDRUN (ad-hoc ONLY) | `ms1b_signed_gate.sh:80-81` signs ad-hoc, no `--options runtime`; non-uniform render check skipped (`:119`) (P4, T-W3) |
| MS2a.1-3 routed dom/page + ownership | BUILT-HANDRUN | `ms2a-gate` step (not in `test`); 16 `mac_ms2a_*_test.py` |
| MS2b.1 native click/key/text | BUILT-HANDRUN | `mac_ms2b_native_input_test.py` et al.; `ms2b_gate.sh` hand-run, no build step |
| MS2b.1 scroll / move / pointer | UNSUPPORTED by decision | synthetic-only; capability table unchanged |
| MS2b screenshot (`zb_screenshot_png`) / input files (`zb_set_input_files`) | **NOT STARTED** | not in the shim, not in the port vtable (K2) |
| MS2b.2 dialogs | BUILT-HANDRUN | alert/confirm/prompt; beforeunload UNSUPPORTED (documented divergence) |
| MS2c.1-4 windows / freeze / recover / crash | BUILT-HANDRUN | `ms2c_gate.sh` hand-run, no build step |
| MS2c.5 drawer ownership | **NOT STARTED** | no AppKit drawer exists; moved to MS7.9 |
| MS3.1 profile store | BUILT-HANDRUN | `mac_profile_persist_test.py` |
| MS3.2 config flags | BUILT-HANDRUN | `webkit.applyBackendFlag`; `--hardware-acceleration` is stored in `g_hw_policy` and never used |
| MS3.3 cookies | BUILT-HANDRUN | `automation_macos_cookie_port.zig` (`app.zig:627`), `mac_cookie_test.py` |
| MS4.1a `load_serial` | BUILT-HANDRUN | `mac_ms4_load_serial_test.py` |
| MS4.1 grant / in-ticket refusal | PARTIAL | engine side BUILT (platform-neutral `engine.windowRefusal`, Linux-tested); macOS-driven refusal e2e **NOT STARTED** |
| MS4.2 negative proofs | **NOT STARTED on macOS** | only real-binary form is Linux-only and unregistered (`agent_approval_negatives_test.py`) |
| MS4.3 per-write confirmation / dry-run inert | **NOT STARTED on macOS** | no macOS test is evidenced |
| MS4.4 login gate | BUILT+REGISTERED on **Linux ONLY**; the macOS `WKHTTPCookieStore` path is **BUILT-HANDRUN (UNPROVEN)** (Rev 30, bd `4pa.69`) | `ms4-4-login-gate-e2e` (`build.zig:2047-2053`, attached only for a Linux target, `:3799`) drives the Linux binary and the GTK cookie port; the macOS consumer runs only in hand-run `tests/mac/ms4_gate.sh:40` |
| MS5.1 setup refusal + `runtimeFor` + parent watch | PARTIAL (refusal + seam; S3a-links hard-gate case `case_ms5_1_s3a_links.py` + registered stand-in unit `ms5_1_hard_gate_case_test`) | `seatbelt_ready = false` (`agent_setup.zig:67`); `parent_watch.arm()` steps 1-4 + `test_parent_watch.py`; macOS `--agent-setup` runs nothing |
| MS5.1b skipped-link bytes | UNPROVEN (Rev 31 status word; the Linux stand-in unit is registered but is a seam with no production caller, so **NOT BUILT per R30.0** — Rev 32); production macOS setup still refuses | `tests/mac/hard_gate/case_ms5_1b_skipped_links.py` (MANIFEST entry), Linux stand-in unit `ms5_1b_hard_gate_case_test` registered in `test-mac-census`; the staged-Mac run waits on the MS5 pinned tree (UNPROVEN: needs a released Mac run) |
| MS5.1c census + staging + merge + relocate | BUILT-HANDRUN (UNPROVEN on the Macs; the pure parts are driven by registered unit tests) | `ms5_*_gate.sh`, `mac_merge_universal_test.py`; emits an `sdk-path` resource the plan did not name (D-W7) |
| MS5.2 Keychain onboarding | **NOT STARTED / NOT BUILT** (Rev 30: the Keychain files are in no `build.zig` target, `4pa.67`) | only raw store/lookup/clear (`agent_secrets_mac.m`); `configureAgentSecrets` returns on non-Linux (`app.zig:395`); `zb_agent_onboard_token` only in RED `24ef54c` (`keychain_onboard_test.m`, unregistered) |
| MS5.3 token only to fd 3 | **NOT STARTED / NOT BUILT (seam only; in no build target, `4pa.67`)** | `zb_mac_token_to_fd` has no production caller, is not in `build.zig`, and carries test-only args (I-W2) |
| MS6.1 token isolation | BUILT-HANDRUN as **profile-belt probes**; closure OPEN | scripts start at `sandbox-exec`, one uses a hand-written profile (`agent_sandbox_ms6_1_token_isolation.sb`); no production trigger (W1) |
| MS6.2 custom profile accepted | BUILT-HANDRUN (probe) | `ms6_generated_profile_test.sh` |
| MS6.3 fd-3 | lower layer BUILT-HANDRUN; real-CLI case in the pre-ready hard-gate harness, no profile-mutant row (P-W7) | `ms6_3_fd3_reopen_test.sh`, `ms6_hard_gate_fd3_cli_case_test.py` |
| MS6.4 egress | BUILT-HANDRUN | `ms6_4_egress_test.sh`; traversal of the PRODUCTION proxy with the fake API NOT STARTED (WC-W3) |
| MS6.5 reaper core | BUILT-HANDRUN (signal-free census gate); **NOT BUILT as a behaviour** (Rev 30, rule 6: linked only into test modules, `build.zig:872,1149,1184`) | `ms6_5_reaper_census_gate.sh`; `ms6_5_reaper_gate.sh` is destructive (T4) and its R29-SAFETY guard is not implemented (`4pa.70`) |
| MS6.5 survivor warning / setting | **NOT STARTED** | no UI, no setting, no reader of `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS` (P2) |
| MS6.5.1 ledger / lock / liveness / recovery | **BUILT-UNARMED = NOT BUILT** (Rev 30, rule 6: no production caller; the transaction test is unregistered; store-name mismatch `4pa.65`; pid unchecked `4pa.68`; Darwin build guard vacuous `4pa.63`), production owner **NOT STARTED** | R29.1(a), R30.1 #14-#15 |
| MS6.6 (A)/(B) R1 under Seatbelt | (A) BUILT-HANDRUN = UNPROVEN; (B) UNPROVEN (Rev 31 status word; a pre-ready hard-gate harness exists, not run in the production chain) | `ms6_r1_kernel_gate.sh`, `tests/mac/hard_gate` |
| MS6/MS8 hook Darwin branch (`zb-hook-run` under `sandbox-exec`, marker fd 5 inherited into the hook and a detached grandchild, hook env allowlist) | UNPROVEN (Rev 31 status word; was "BUILT as a pre-ready hard-gate case"); no released Mac run | `tests/mac/hard_gate/case_ms8_hook_sandbox.py`, `case_ms8_hook_launch_env`; **only the stand-in unit `ms8_hook_sandbox_case_unit` is in `test` (`build.zig:3133-3138`, attached `:3695`)**. `ms8_hook_launch_env_case_unit` (`build.zig:3141-3146`) hangs off `test-mac-census` ONLY (no `test` dependency, not a platform gate), so by rule 2 it is a DRAFT (G2.5); registering it in `test` is a required fix-forward. This is the REAL hook mechanism (P1) |
| MS6.7 read + mach-lookup curation | **NOT STARTED (NEW, K4)** | profile emits `(allow file-read*)` / `(allow mach-lookup)` (`sandbox_macos.py:173,183,216,226`) |
| MS6 production launch connector | **NOT STARTED (NEW, I2/P1)** | `launch.py:154-157` refuses on darwin; `agent_helper.zig:121-130` never passes `--egress-port`; `LAUNCH_SPEC_CONSUMABLE = False` |
| MS7.0 | **NOT BUILT** (Rev 30: a symbol tripwire in `cross-check` only; no production caller) | R29.1(c), R30.1 #6 |
| MS7.1 / 7.4 portable seams | NOT BUILT (driven seams, observed 7/7, but no production caller; Rev 31 G4.1); the behaviours are NOT BUILT | R29.1(c) |
| MS7.6 / 7.8 portable half | **RED-UNREGISTERED. NOT BUILT** (Rev 30, bd `4pa.72`) | R29.1(c), R30.1 #1-#2 |
| MS7.1-7.4 AppKit views, MS7.2 icon, MS7.3 fold | **NOT STARTED** | no `agent_drawer_mac.m`; no main menu in `wkwebview_shim.m` |
| MS7.5 Secrets window | portable RED-UNREGISTERED; AppKit **NOT STARTED** | `5e71d67` |
| MS7.7 chat observability census | **NOT STARTED** | |
| MS7.9 drawer ownership | **NOT STARTED** | |
| MS8.0 | **NOT BUILT** (Rev 30, bd `4pa.75`: the minters are inert on macOS; the step is a symbol tripwire) | R29.1(c), R30.1 #5 |
| MS8.1 helper under `MacSeatbeltBackend` | **NOT STARTED** (the portable spawner core is a driven SEAM, NOT BUILT: no production importer, Rev 31 G4.1) | |
| MS8.2a / 8.2b | RED-UNREGISTERED | R29.1(c) |
| MS8.2c, MS8.3 | **NOT STARTED** | blocked by MS6 + MS7 |
| MS9 | **NOT STARTED** | blocked on Developer ID |

**Rev 30 reading of this table (R30.0).** BUILT-HANDRUN means UNPROVEN (its tests are drafts under rule 2 until a registered
step and a released Mac run exist). BUILT-UNARMED means NOT BUILT (rule 6: no production caller). A BUILT+REGISTERED row whose
behaviour has no production caller is a seam, not a behaviour. The per-behaviour record, with the four rule-9 fields, is the
"Verification rule compliance" table at the end of the plan; this table carries the corrected statuses in place, and the compliance table adds the four rule-9 fields.

### R29.3 Name, citation and count corrections (finding I-W1, A-W4, K2, WC-W1; applied in place below)

| Plan said | HEAD reality | Applied at |
|---|---|---|
| `src/automation_wk_port.zig` | `src/automation_macos_port.zig` (wired `src/app.zig:626`) | MS2 design, Closure A, files lists |
| `src/automation_wk_cookie_port.zig` (MS3.3 line) vs `…macos_cookie_port.zig` (MS4.4 line) | `src/automation_macos_cookie_port.zig` (`app.zig:627`); the MS4.4 spelling was right | MS3.3 |
| `applyMacBackendFlag(flag, value) !void` | `webkit.applyBackendFlag(comptime os, flag, value) error{UnsupportedFlag}!void` (`src/webkit.zig:40`) deciding via `backend_flag.backendFlagDecision` (`src/backend_flag.zig:31`) | MS3.2, ABI rows |
| `agent_broker.mint` / `on_approve_clicked` | `zb_agent_tools_approve` (`src/agent_tools.zig:200`) → `Cards.approve` (`src/agent_approval.zig:279`) | MS4 |
| `src/agent_drawer_mac.m` | does not exist (MS7 creates it) | MS7 design |
| `tests/e2e/mac_session.py` | does not exist; the harness is `tests/mac/gate.sh` + per-test drivers | Testing Strategy, Closure MS6.1 |
| build step `mac-universal` | `mac-gate` (`build.zig:241`), `ms1b-gate` (`:247`), `ms2a-gate` (`:254`) | MS1 files |
| `automation_server.zig:412/480-487/686-691/942-1106/1123-1180/810-1106` | symbols `handleRequestWith` (`:467`), `handleWindows` (`:744`), `handleRecover` (`:995`), `handleDialogs` (`:1176`); **cite symbols, not lines** | Closures A/B/C, Current State |
| `build.zig:1107-1118/79-105/241-272/1702+`, `:168` | cite symbols `resolveBackend`, `configureMacosBackend`, `CheckMacosBackendStep`, steps `mac-gate`/`ms1b-gate`/`ms2a-gate` | Current State, References |
| "all 75 exports (44 + 31)" | 76 exports (44 + 32) | MS2 ABI |
| `tests/agent_run_ledger_concurrency_test.c`, `tests/agent_run_recovery_test.c` | do not exist (the real C/Zig tests are listed in R29.1(a)) | MS6.5.1 tests |
| ClosureMaps "pinned to HEAD ed13e5e" | regenerated at `e4f705f`; every module/read_path cites a symbol | Closures A/B/C |

### R29.4 Finding map (every finding → where it is amended; the long form is in the enhancer's traceability file)

**Critical.** K1/K2/W2-text → R29.1, R29.2, R29.3, frontmatter, rev-28 history entry, ABI table, MS6.5.1 SCOPED block.
K3/D1/W5 → MS4 rewrite (**R29-MS4**). K4/D2 → MS6.7 + **R29-MS6 readiness type**. K5/P4 → MS1/MS1b/MS9 amendments
(**R29-MS1**). K6/W3/T3(MS7) → **R29-MS7**. I1 → **R29-MS6 conformance**. I2/P1/W1 → **R29-MS6 launch connector + hook
mechanism**. P2 → **MS6.5.2**. P3/W6 → **R29-MS5**. T4 → **R29-SAFETY**. W4/T5 → **R29-REG**. W7/T1/T2/T3(reaper_ready) →
**Behavior specification ledger**.
**Warnings** (IDs C-W1…C-W9 Contracts, I-W1…I-W9 Interfaces, P-W1…P-W7 Promises, D-W1…D-W7 Data Models, A-W1…A-W5 APIs,
WC-W1…WC-W6 Workflow Closure, T-W1…T-W9 Test-Spec): each is amended or recorded as a required red / residual risk
in R29.5 (cross-cutting), R29.6 (code-only follow-ups) and the in-slice blocks below. None is dropped.

### R29.5 Cross-cutting amendments

**R29-REG — gate registration (W4, T5, T-W6, T-W9).**
- Every Mac slice gate gets a **named `zig build` step** and a committed **manifest of its last approved run**
  (commit, hosts, date, approver). Steps to add (in the slice that owns each, never in a red commit — see the
  repo rule that a red must not enter a registered step): `ms2b-gate`, `ms2c-gate`, `ms3-gate`, `ms4-gate`,
  `ms5-gate`, `ms6-gate`, `ms7-gate`, `ms8-gate`, each Mac-only and not depended on by `test` [Rev 30, V03-F9: not an `unguarded`-list entry].
  Until a step exists the slice is **BUILT-HANDRUN, not DONE**.
- A new **Linux-side registered aggregate** `mac-linux-tier` runs everything Mac-related that does NOT need a Mac
  (census tests, `test_sandbox_macos.py`, `test_netd_darwin*.py`, ledger/recovery Zig tests, the portable drawer
  tests) so `zig build test` covers them; the unregistered ones named in R29.1/R29.2 are registered **in the green
  that makes them pass**.
- **Register the production-code tests now in progress:** `agent_run_ledger_recovery_txn_test.zig` (covers code that
  is in production source) is registered with its slice (bd `3gl`/`4pa.29`); `tests/agent_run_ledger_concurrency_test.c`
  and `tests/agent_run_recovery_test.c` are either **authored** (they are the named two-process reds) or the plan
  stops naming them; this revision keeps the names as **TO BE AUTHORED** and says so.
- Stale test headers (T-W6): a test header that says "RED (unregistered)" or "not in test" is corrected in the commit
  that registers or de-registers it; `tests/mac_compile_only` selftest-style check: a Linux test greps every
  `tests/*` header for `UNREGISTERED` and fails when the file IS referenced from `build.zig`, and for the converse (TRIPWIRE — not proof; registration is proven by `zig build test` running the file, and an unregistered file is a draft by rule 2).
- `ms5_kill_group_gate.sh` (T-W9) is renamed in the plan's text to **"netd/`zb_agent_kill_group` backstop gate"**;
  it is NOT the item-5 e2e (see R29-MS5).

**R29-SAFETY — Mac execution safety (T4, T-W8, bd `4pa.24`).**
- `tests/mac/ms6_5_reaper_gate.sh` sends SIGKILL and its only guard is `ZB_MAC_ARM_HOST` being set. Required amendment:
  the script is **disabled by default** — it exits 1 with "DISABLED: destructive reaper gate" unless BOTH
  `ZB_REAPER_DESTRUCTIVE_APPROVED=<exact commit sha>` equals `git rev-parse HEAD` of the staged tree AND a
  release-token file written by the orchestrator exists; it also refuses to run when `$HOME`'s Mac host list matches
  a shared host. Red (Linux-only, hostless, in the `mac_compile_only_selftest.sh` style): run the script with only
  `ZB_MAC_ARM_HOST` set → **exit 1 and zero ssh/scp invocations** (a stub `ssh` on `PATH` records calls; assertion
  `ssh_calls == 0`); mutant: restore the old guard → the stub records an ssh call (must be caught).
- **Per-slice protocol step 2 is amended** (see the protocol section): reds are recorded **compile-only** or on a Mac
  **only with RoseCat exact-commit approval AND orchestrator release**.
- Debug hooks (P-W4, T-W5): `ZB_DEBUG_FORCE_PRE_MACOS14` and `ZB_DEBUG_SYNTH_CRASH` (and every other debug hook) are
  honoured only when the binary is started with `--e2e-protocol`, which is a public flag. Required: (1) the hooks are
  compiled behind a **build option** absent from the shipping build, or (2) at minimum a registered test that starts
  the binary **without** `--e2e-protocol` and proves each hook is inert, and one that proves the shipping build
  rejects them; until then, `ZB_DEBUG_FORCE_PRE_MACOS14` is documented as a known silent-isolation-removal risk.

**R29-DOCS — client documentation (C-W1, A-W5).** `docs/how-to-automate.md` gains a "macOS differences" section:
beforeunload (not surfaced; accept/dismiss unsupported; `.fail` just loads), native scroll/move (synthetic only),
the macOS 13 shared data store, screenshot/input-files NOT STARTED. The server returns a **distinct reason**
(`beforeunload_unsupported`) instead of the generic unsupported error (`engine.zig:1446`). Red: a client test
`navigate` with `beforeunload=accept` on macOS expects `reason == "beforeunload_unsupported"`; today it gets the
generic code.

**R29-CAP — capability source (A-W2).** The capability table entry (`automation_platform.zig:90-95`) is unchanged and
has no native flags; the real capability source on macOS is the PagePort vtable (`supportsNativeMove`/
`supportsNativeScroll` false, `nativeClick/Key/Text` true). The plan no longer says "the table changes after MS2b";
it says "the table is derived from the vtable and a registered test asserts the two agree".

**R29-CLASS — classification rule.** Every behaviour is BLOCKING or LEAF with a one-line reason; unclassified is
BLOCKING. The ledger below classifies all of them.

### R29.6 Residual code-only findings (recorded as required reds / risks; this revision changes no code)

| ID | Finding | Plan treatment (requirement for the owning slice) |
|---|---|---|
| I-W2 | `zb_mac_token_to_fd` has test-only `keychain_path`/`unlock_password` in the production signature (`agent_token_fd_mac.h:17`) | MS5.3: production signature is `(fd, service, account)`; test variant is a separate `…_for_test` symbol. Red (exercise form): a Mac test (`tests/mac/token_fd_test.m`, hand-run until the `ms5-gate` step exists) calls the production `zb_mac_token_to_fd(fd, service, account)` on a disposable keychain and reads the canary from the fd; mutant: restore the test-only arguments → the three-argument call does not link. The header arity check is a TRIPWIRE — not proof; UNPROVEN until a released Mac run |
| I-W3 | `recoverAllAtStartupGated(ready, …)` and `recoverOneUnderLock` are `pub` and take readiness/an actuator as an argument — `reaper_ready` can be bypassed | MS6.5.1: make them non-`pub` (file-private or in a `test_support` namespace); red (exercise form): a test file in the registered `test` family imports the ledger module and calls `recoverOneUnderLock`; it must fail to compile (compile-fail test); mutant: re-export it → the file compiles and the step fails. A declaration-scan assertion would be a TRIPWIRE — not proof |
| I-W4 | `acquireRunLockBounded` ignores `io` and acquires then releases (`agent_run_ledger.zig:470`); `acquired=true` holds no lock | rename to `probeRunLock` or return the held lock; red: caller that trusts `acquired` while a second process writes → the second write must be excluded |
| I-W5 | `recoverOneUnderLockP` hard-codes `"runs.json"` (`:594/614/630`); the store is `zigbrowser-agent-runs.json` | red: recover an entry in a store named `zigbrowser-agent-runs.json` → entry retired (today: stays); green: pass the store name through |
| I-W6 | debug seams are unconditional production-dylib exports; `zb_automation_debug_strings_live` unlisted | list it in the debug table (done below); build option, or an export-set census (TRIPWIRE — not proof; the proof is the 13 `ZB_DEBUG_*` hooks being inert in the shipping binary without `--e2e-protocol`, `mac_ms2a_hook_inert_test.py` extended, step `ms2a-gate`, mutant: make one hook unconditional; both Macs, UNPROVEN until released) (R29-MS2) |
| I-W7 | `rdynamic` exports every exe symbol on macOS (`build.zig:181`), not only the two back-refs | census: `nm -gU` of the exe lists exactly `zb_ipc_dispatch` and `zb_policy_decide` among `zb_*`, or an export list file replaces `rdynamic` **[Rev 30: the `nm` census is a TRIPWIRE; proof = R30.2 T11]** |
| I-W8 | `zb_secrets_window_open(unsigned long long)` (mac) vs Linux `zb_secrets_window_open(void)` | rename the mac symbol to `zb_secrets_window_mac_show` (the one name used everywhere in this plan; R30.2 T16, R30-MS7); red (exercise form): the renamed entry opens the real Secrets window on a Mac and the window is absent from the registry (MS7.5 compiled gate); mutant: make the entry a no-op → the window-open row fails. A C file including both headers is a TRIPWIRE — not proof; UNPROVEN until MS7.5 exists |
| I-W9 | `launch.build_argv` is Linux-only and reaches the private `sandbox._LINUX_BACKEND` (`launch.py:97,111`) | folded into the production launch connector (R29-MS6): one `launch.build_launch(spec)` over the backend protocol |
| D-W1 | ledger `pid` is an unchecked `i32` (`agent_run_ledger.zig:40`); 0/negative parses as proved-dead; not cross-checked with the basename pid | parse: reject `pid < 2`; require basename pid == entry pid. Reds: pid 0, -1, 1, mismatch → malformed read, no signal |
| D-W2 | profile identity is the lexical path (symlink/trailing-slash may differ) | MS3.1 Property: same spelling ⇒ same store UUID; a symlink spelling and its target, `/a/b` and `/a/b/`: **documented** behaviour (canonicalize via `realpath` before hashing, red for trailing slash) |
| D-W3 | census does not require bundle == inventory (extra undeclared file passes) | MS1.1: add "every Mach-O/file in the bundle is declared" check; red: add an undeclared regular file → census fails |
| D-W4 | pinned `.pkg` SHA-256 copied into six files; stage tool does not read `agent_runtime_pins.json` | MS5.1c: one source `agent_runtime_pins.json`; red (exercise form): `stage_agent_runtime.sh` run on a `.pkg` whose SHA-256 differs from `agent_runtime_pins.json` refuses (exit non-zero, pin named), in the registered `test-mac-census` family; mutant: restore a hard-coded literal → the mismatching package is accepted. Grepping the six files is a TRIPWIRE — not proof |
| D-W5 | a Linux-written ledger read on a Mac (or reverse) fails closed forever, no retire path | MS6.5.1: cross-kind entries get an explicit `retire_foreign` action under the held flock after an owner-confirmed prompt; until then documented as a known stuck state |
| D-W6 | window state spread over independent fields | MS2c: record as a risk; add a registered state-invariant test (crashed ⇒ not recovering; dialog ⇒ not crashed) over the shim census |
| D-W7 | `ms5_inventory.py` emits an `sdk-path` resource MS5.1c does not name | MS5.1c resource list names `sdk-path` (done in R29-MS5) |
| P-W1 | `zb_job_wait` has no deadline in DISPATCHING (`wkwebview_shim.m:1616-1618`) | MS2 promise reworded: "bounded EXCEPT in DISPATCHING, where completion is guaranteed by the main-queue block"; red: a main-queue hold (`ZB_DEBUG_DISPATCH_HOLD_MS`) longer than the deadline → waiter returns `timeout`, job state ABANDONED |
| P-W2 | recovery of a frozen window abandons the hung WebContent process; no test that it exits | MS2c.3: Property "abandoned process count returns to baseline within 10 s after window close"; red: `ps` census after recover+close |
| P-W3 | `--hardware-acceleration` stored in `g_hw_policy`, never used | MS3.2 reworded: "accepted, recorded, no effect" (see MS3.2) |

---

## Rev 30 — THE EXERCISE-THE-CODE RULE APPLIED, THEN THE MS0-9 CODE VALIDATION (AUTHORITATIVE)

**Sources.** (1) The owner's order of 2026-10-22: the section **"Verification rule: prove it by running it"** at the top of this
plan. (2) The independent code validation of the whole plan, bd `zigBrowser-4pa.12`, in three files next to this plan:
`…-VALIDATION-ms0-3.md`, `…-VALIDATION-ms4-6.md`, `…-VALIDATION-ms7-9.md`. The validators read and RAN the code at worktree
HEAD `d0f1841`. Rev 29 was written against `e4f705f`; the ms4-6 validator checked that no file under `src/`, `build.zig`,
`agent/`, `packaging/` or `tests/` differs between the two, and the other two found no drift that matters. Their findings are
bd `zigBrowser-4pa.55` to `zigBrowser-4pa.80` (26 findings: 3 critical (`4pa.55`, `4pa.72`, `4pa.73`) + 23 major) plus 34 minor findings that have no bd id.

**Scope.** Docs-only. The implementation freeze `zigBrowser-4pa.1` still holds: this revision changes no code, test or build
file, no bd record, and touches no Mac, VM or ssh host. Every red below is a specification for a later slice. None was run for
this revision.

**"Passes" means observed.** Per rule 8, a claim is VERIFIED only where a validator ran it and recorded the command and exit
code. Those claims say "(observed at d0f1841)". Everything a validator only read from code is SUSPECTED or CONFIRMED-BY-READING.
Every Mac and Windows claim stays UNPROVEN until a released platform run at a named commit (R29-SAFETY).

### R30.0 Status words after Rev 30 (these definitions apply throughout this plan, including R29.2)

| Word | Meaning under the verification rule |
|---|---|
| **BUILT+REGISTERED** | A production entry point reaches the code and a driven test is in a build.zig step that `zig build test` runs. It is VERIFIED only where a validator observed the run (rule 8); the compliance table says "observed" for those rows. Nothing else earns this word. |
| **BUILT-HANDRUN** | The code is wired, but every test of it runs only from a hand-run script or an unregistered step. By rule 2 those tests are drafts, so the behaviour is **UNPROVEN** for acceptance. Used for every Mac runtime behaviour whose gate has no build step or no released run. |
| **UNPROVEN** | No exercising proof exists yet. The row says exactly what is missing (a registered step, a mutant, a platform run, a production caller). |
| **NOT BUILT** | Rule 6: a production caller never reaches it, or its only test is source-text, unregistered or red. Includes everything R29 called **BUILT-UNARMED** (a seam with a driven test but no production owner). |
| **RED-UNREGISTERED** | A red test exists and is deliberately outside every registered step. The behaviour is NOT BUILT. |
| **NOT STARTED / UNSUPPORTED** | As in R29.2 (unsupported = a documented user decision). |
| **TRIPWIRE** | A grep, regex, lexer, symbol listing, `nm`/`otool`/`strings`/`lipo` listing, "the file contains" check, or a constant read. A tripwire guards against regressions. It never closes a behaviour, a slice, a review finding or a validation finding. A tripwire is never a status. |

### R30.1 Status corrections (every R29 BUILT or REGISTERED claim that the validations disprove)

Evidence marked "observed" was run at `d0f1841` by a validator; "read" means confirmed by reading code.

| # | Rev 29 said | Rev 30 says | Evidence | bd |
|---|---|---|---|---|
| 1 | MS7.6/MS7.8 "portable half" **BUILT+REGISTERED** (R29.1(c), R29.2, R29-MS7, ledger MS7.6 and MS7.8) | **RED-UNREGISTERED. NOT BUILT.** `Approver`, `cardPress` and `zb_drawer_card_press` do not exist in `src/agent_drawer.zig`. | `zig build test-agent-drawer-card-press` exits 1 with 5 compile errors ("root source file struct 'agent_drawer' has no member named 'Press'"); `zig build check-card-authority-mac` exits 1 on both arches (R1/R2 fail); neither step is in `test` or `cross-check`; every commit touching them is labelled RED/UNREGISTERED (observed) | `4pa.72` |
| 2 | `check-card-authority-mac` is "Registered Linux evidence that DOES count" (R29-MS7) | **Removed from the evidence list.** It is a symbol/relocation tripwire, it is red, and it is not registered. Even when green it never counts as proof. | same runs (observed) | `4pa.72` |
| 3 | MS4.4 login gate **BUILT+REGISTERED** | **BUILT+REGISTERED on Linux ONLY.** The macOS `WKHTTPCookieStore` path is **BUILT-HANDRUN (UNPROVEN)**. | `ms4-4-login-gate-e2e` (`build.zig:2047-2053`, attached only when the target is Linux, `:3799`) drives the Linux binary and the GTK cookie port. The macOS consumer runs only in hand-run `tests/mac/ms4_gate.sh:40` (read) | `4pa.69` |
| 4 | The Darwin cross-compile guards (`build.zig:1043-1052` and `:1159-1168`, in `test`) show the ledger and recovery code builds for Darwin | **Vacuous. A tripwire, not proof.** They analyse none of the ledger/recovery pub API. | A type error inside an unreferenced `pub fn` appended to `src/agent_run_ledger.zig` still exits 0; the same error reached from one `export fn` exits 1 (observed). Zig analyses lazily and neither file has an `export` or forcing `comptime` block. Only the C reaper body is really compiled for Darwin. | `4pa.63` |
| 5 | MS8.0 **BUILT+REGISTERED**: the approval minters are defined in both macOS builds | **NOT BUILT (rule 6).** `agent_tools.start` is Linux-only (`app.zig:477-479`), so on macOS `cards` is never initialised and `zb_agent_tools_approve/_deny` (`agent_tools.zig:200-210`) always return 0; nothing in the macOS build calls them. `cross-check-agent-tools-mac` only checks that the symbols exist: a TRIPWIRE. | `cross-check-agent-tools-mac` exits 0 with the inert minter; `check-card-authority-mac` reports "_agent_tools.zb_agent_tools_approve is referenced by {}" on both Darwin objects (observed) | `4pa.75` |
| 6 | MS7.0 `cross-check-drawer-mac` is "in `cross-check` and `test`" | In `cross-check` only (`test` uses only the `cross_check` command, `build.zig:3921`). It is symbol presence: a TRIPWIRE. MS7.0 has no production caller on macOS (`applyAgentDrawer` returns false off Linux/Windows, `src/webkit.zig:134`), so the behaviour is **NOT BUILT**; the export seam compiles. | read | V79-m3 |
| 7 | MS7.1 and MS7.4 portable halves **BUILT+REGISTERED** | The **seam** is driven and registered (status NOT BUILT, Rev 31 G4.1: a seam with no production caller; `test-agent-drawer-appkit` and `test-agent-drawer-appkit-text` exit 0, 7/7 each, observed). The **behaviour** (AppKit dock, bubble) is **NOT BUILT** by rule 6: no `.m` file calls the seam. | observed | — |
| 8 | MS1.3 entitlements **BUILT+REGISTERED (static)** | **Tripwire-only; UNPROVEN as least privilege.** The Mac check signs with the plist and then compares the signature to the same plist (a tautology); the one key `com.apple.security.network.client` is an App Sandbox entitlement and nothing sets `com.apple.security.app-sandbox`, so it does nothing; `build-dmg.sh` never uses the manifest. | read | `4pa.61`, `4pa.79` |
| 9 | MS1.1 census proves bundle completeness | The unit (`mac_universal_census_test`, 27 OK) is driven. The Mac census cannot see an undeclared non-Mach-O file (a demo run found 0 failures). So **bundle == inventory is NOT BUILT** (D-W3). | observed | — |
| 10 | "Mac-only gate steps are excluded from `test` by design (`unguarded` list, `build.zig:4045`)" | Wrong. `:4045` is the display-guard skip list. The Mac gates are outside `test` only because `test` never depends on them. | read | V03-F9 |
| 11 | MS2a, MS2b, MS2c, MS3 **BUILT-HANDRUN** | Same word, stated meaning: wired, but NONE of it runs under `zig build test` (the `.m` file is never compiled on Linux, `cross-check` only compiles the Zig side), `ms2b-gate`, `ms2c-gate` and `ms3-gate` do not exist as build steps, and no approved-run manifest exists. Treated as **UNPROVEN**. | none of the 50 `tests/e2e/mac_ms2*`, `mac_profile*`, `mac_cookie`, `mac_config_flags` files is referenced in `build.zig` (read) | `4pa.62` |
| 12 | `mac_ms2a_user_nav_failure_test.py` is a correct oracle | **It encodes the defect.** It asserts that the browser exits on a failed user navigation. It must be rewritten (R30-MS2). | read | `4pa.55` |
| 13 | R29-MS4: the account, recipient, document token and element token are "bound into the card's digest and re-checked by `options.guard`" | **Not in the code.** `Card = {id, presented_ms, outcome}` has no digest. Broker phaseA replaces the call's whole `options` with `{expect}` (`agent_broker.zig:709-714`), dropping any `guard`. Until fixed, raw-DOM cards are bound only to origin + `load_serial`. | read | `4pa.64` |
| 14 | MS6.5.1 recovery transaction **BUILT-UNARMED** | **NOT BUILT.** Its transaction test is unregistered (`test-agent-run-recovery-txn` is MANUAL), and it cannot work with the real store name: `recoverOneUnderLockP` hard-codes `"runs.json"`; with the plan's `zigbrowser-agent-runs.json` four tests fail. | observed | `4pa.65`, `4pa.71` |
| 15 | MS6.5 reaper core BUILT-HANDRUN; MS6.5.1 ledger parse/publish/lock and startup core BUILT/BUILT-UNARMED | **NOT BUILT as behaviours (rule 6).** They are linked only into test modules (`build.zig:872,1149,1184`) and have no production caller. Their driven tests are registered (seam proof only). | read | `4pa.67` |
| 16 | `seatbelt_ready` is pinned by the `platformGate` test | **Not pinned.** With `seatbelt_ready = true`, `test-agent-setup-ms5` still exits 0. The generated profiles still emit broad `file-read*`, `process-exec`, `mach-lookup`. | observed | `4pa.66` |
| 17 | MS5.2 Keychain and MS5.3 token fd are "seam only" | **NOT BUILT.** `agent_secrets_mac.m`, `agent_secrets_mac.zig` and `agent_token_fd_mac.c` are in no `build.zig` target, so they are not linked into the app. No production importer of `spawnNetd` or `appendEgressPort`. | read | `4pa.67` |
| 18 | `ms6_5_reaper_gate.sh` "must not run on the Macs" is enforced | **Not enforced.** Only `ZB_MAC_ARM_HOST` guards a script that sends SIGKILL. | read | `4pa.70` |
| 19 | The ledger parser rejects bad entries | `pid` is an unchecked `i32` (`agent_run_ledger.zig:38`); pid 0 or a negative pid reads `/proc/0/stat`, gets ENOENT, becomes `.absent` → `.dead` → `.recover`, and reaches the teardown path. | read | `4pa.68` |
| 20 | `build-dmg.sh` is the shipping path | It cannot produce a working or distributable app: it copies only the exe (`:71`, no shim dylib), builds an uncommitted working tree on one Intel host, signs ad-hoc with `--deep` and no entitlements (`:91`), and turns host-key checking off (`:21-24`). | read | `4pa.73`, `4pa.77` |
| 21 | K6 applied: the MS7 compiled gate is "driven through the fixture-card entry" | K6 is a plan decision and **is not in the code.** `ms7_appkit_check.py:198-200` still requires `source == "chain"`; there is no milestone argument and no `zb_drawer_present_fixture_card`. The gate can never pass at MS7. | read | `4pa.74` |
| 22 | MS7.5 portable RED needs only a rename-free green | Two C functions share the name `zb_secrets_window_open` with different signatures (`agent_secrets_window_mac.h:23` vs `agent_secrets_window.h:56`). | read | `4pa.76` |
| 23 | ABI table: `zb_version_line` "records executing arch in build info" | False. It prints the WebKit version twice (`wkwebview_shim.m:2975`); the arch is recorded in `src/automation/telemetry.zig:159`. | read | V03-F10 |
| 24 | `test-mac-compile-only` (R4 selftest) is a reliable registered test | Fails as namespace root (7 cases, exit 1, observed); passes as the real user under a PID 1 that reaps orphans (exit 0, observed). | observed | V79-m12 |
| 25 | `test-mac-census` is registered and green | Fails under `--map-root-user` (one root-in-namespace artifact) and skips 6 Darwin-only tests ("no kqueue here"). | observed | V46-F20 |

### R30.2 Source-check inventory — every proof that rested on reading, grepping, symbol presence or source parsing

Each row keeps the source check as a labelled **TRIPWIRE** and names the exercising proof in the rule-9 form: (a) production
entry point, (b) test file and its build.zig step, (c) the mutant of the PRODUCTION code that must fail it, (d) platform run and
hosts. "To be added" means the step does not exist yet and the slice that owns the behaviour adds it in its green (never in a
red commit).

| # | Where | The source or symbol check (TRIPWIRE) | Exercising proof required | Behaviour state until then |
|---|---|---|---|---|
| T1 | R29.1(b) and the ABI table: "census over the built dylib asserts exported `zb_*` equals the promoted set" (`mac_ms2a_abi_census_test.py`, `nm`) | Export-name listing | (a) every promoted export is called through the real macOS binary over the socket; (b) the MS2a, MS2b and MS2c e2e files named in the table, steps `ms2a-gate`, `ms2b-gate`, `ms2c-gate` (the last two TO BE ADDED); (c) stub one export to return -1 → the named e2e fails; (d) both Macs, released run | UNPROVEN |
| T2 | MS7.0 `cross-check-drawer-mac` | Symbol presence on both Darwin objects | (a) the AppKit drawer calling the export; (b) the MS7.1 compiled gate live frame census, step `ms7-gate` (TO BE ADDED); (c) drop the export → census fails; (d) both Macs | NOT BUILT |
| T3 | MS8.0 `cross-check-agent-tools-mac` | Symbol presence (passes with an always-0 minter) | See R30-MS8 `4pa.75`: a driven minter test plus the compiled gate `grants` row | NOT BUILT |
| T4 | `check-card-authority-mac` (relocation/symbol authority) | Relocation listing | The compiled gate drives a real Approve click and reads the `grants` row (MS7.6/7.8); the relocation check stays only as a tripwire | RED-UNREGISTERED |
| T5 | Darwin cross-compile guards for the ledger and recovery (`build.zig:1043-1052`, `:1159-1168`) | A compile that analyses nothing | (a) the ledger/recovery tests run on a Mac; (b) a hostless meta-test step (TO BE ADDED, `test-darwin-guard-selftest`) that builds a deliberate Darwin-only type error through the SAME guard root and expects a non-zero exit; (c) the old guard root fails the meta-test (exit 0); (d) both Macs for the real run | UNPROVEN (tripwire only today) |
| T6 | `tests/e2e/mac_drawer_card_authority_test.py`, `mac_drawer_bubble_inert_test.py` (~1,945 lines) | Lexers over `src/agent_drawer_mac.m`, a file that does not exist | The compiled two-Mac gate (`ms7_appkit_gate.sh`) drives a real card and a real bubble copy; the two files are deleted (V79-m8) | RETIRED |
| T7 | `reaper_ready` `indexOf` (`agent_run_recovery_startup_test.zig:184-194`) | Source text | (a) `recoverAllAtStartup`; (b) a runtime hostile-environment test in the registered startup step: set `ZIGBROWSER_REAPER_READY=1`, `ZB_REAPER_READY=1`, argv `--reaper-ready`, assert `actuator_calls == 0`; (c) read readiness from the environment → `actuator_calls > 0`; (d) none (portable) | UNPROVEN |
| T8 | `seatbelt_ready` constant pin (`expect(!seatbelt_ready)`) | A constant read | (a) `--agent-setup` on the real macOS binary exits 1 with the fixed line (`ms5_setup_refusal_gate.sh`, both Macs, released run); (b) the registered cross-language invariant test renders the REAL profile and asserts `seatbelt_ready ⇒ CURATED` beside the constant read — the `no bare allow` profile-text assertion is a **TRIPWIRE**, not proof (Rev 32, L3); the closing proof is the Mac kernel-denial rows of T9 (R29-MS6 D2); (c) flip the constant → the invariant fails; (d) both Macs | UNPROVEN |
| T9 | MS6.7 Linux red `"(allow file-read*)" not in profile` | Text of the generated profile | The Mac rows in `ms6_generated_profile_test.sh`: `cat <canary>` → EPERM, `bootstrap_look_up(windowserver)` → `kr != 0`, `CGEventPost` denied, `screencapture -x` no image, `exec /bin/sh` EPERM; (c) reinstate the bare allow → rows fail; (d) both Macs | NOT STARTED |
| T10 | I1 `inspect.signature(MacSeatbeltBackend.network) == …` | Reflection over class text | `launch.build_launch(backend, spec)` driven for BOTH backends with the same spec, results compared (MS6.8 red (a)); (c) rename a parameter → fails | NOT STARTED |
| T11 | I-W6 / I-W7 `nm -gU` export census of the dylib and exe (`rdynamic`) | Symbol listing | m9 render and reply workloads through the signed build drive both back-refs (`zb_policy_decide`, `zb_ipc_dispatch`); (b) `ms1b-gate`; (c) replace `rdynamic` with an export list missing one back-ref → the workload fails to start; (d) both Macs | UNPROVEN |
| T12 | D-W4 "a test greps the six files for the pin" | grep | (a) `stage_agent_runtime.sh` run on a `.pkg` whose SHA-256 differs from `agent_runtime_pins.json` → refuses; (b) registered `test-mac-census` family; (c) restore a hard-coded literal → a mismatching pkg is accepted → fails | UNPROVEN |
| T13 | R29-REG T-W6 "a Linux test greps `tests/*` headers for `UNREGISTERED`" | grep | Registration itself is exercised by `zig build test` running the file; the header scan stays a labelled tripwire | TRIPWIRE-ONLY |
| T14 | R29-SAFETY / MS6.5.1 "a source/build assertion proves production never defines a path that arms signalling from the environment" | Source/build assertion | Same hostile-environment runtime test as T7 (the production startup entry is called) | UNPROVEN |
| T15 | R29-SAFETY debug hooks: "census asserts the shipping dylib exports exactly the promoted set" | Export listing | (a) start the shipping binary WITHOUT `--e2e-protocol` and set each of the 13 `ZB_DEBUG_*` hooks → behaviour unchanged (`mac_ms2a_hook_inert_test.py` extended from 4 to all 13); (b) `ms2a-gate`; (c) make one hook unconditional → its row fails; (d) both Macs | UNPROVEN |
| T16 | I-W8 cross-target header test (two headers declaring `zb_secrets_window_open`) | A compile of two headers | The renamed entry (`zb_secrets_window_mac_show`) opens the real Secrets window on a Mac (MS7.5 compiled gate); the two-header compile stays a tripwire | NOT BUILT |
| T17 | MS1.3 `codesign -d --entitlements -` equals the plist | Listing compared with its own input | Feature probes under `--options runtime`: a probe that needs the claimed capability, run with and without the key (assertion: the outcome differs, or the key is deleted); (d) both Macs | UNPROVEN |
| T18 | MS1.1 `lipo -archs` / whole-bundle Mach-O fatness scan | Artifact listing | The MS1.2 executing-arch readback over the socket on both hosts (already driven in `mac-gate`), plus the staging tool producing the bundle the census scans | UNPROVEN on Mac |
| T19 | MS6.5.1 "the reserved marker number never equals fd 3 / fd 4 / the census fd (a static assertion in the shared header)" | `static_assert` | The per-seam production-chain reds (browser→netd, helper, relay, hook, double-fork) already listed under MS6.5.1 *Testing* | NOT BUILT (no owner) |
| T20 | R29.6 I-W3 "a build assertion that the only `pub` entry is `recoverAllAtStartup`" | Declaration scan | A test file that imports the ledger module and calls `recoverOneUnderLock` must fail to COMPILE (compile-fail test); mutant: re-export it → the test file compiles → the step fails | NOT BUILT |

### R30.3 Open owner decisions (OPEN; each carries a recommendation, and the recommendation is the default if the owner is silent)

1. **Should a failed page load ever quit the browser?** (bd `zigBrowser-4pa.55`; finding V03-F1)
   - Today macOS quits on every failed load that is not a tagged automation navigation, and also when a 15 s timer expires on a recovery reload. Linux records the failure and keeps running.
   - Options: (A) always quit, as macOS does now; (B) never quit; (C) quit only for the primary window's initial load, until its first finish.
   - **Recommendation: NO, except possibly the primary window's INITIAL load before its first finish (the M9 single-load contract, option C).** After the first finish, record the failure and emit `LOAD_FAIL` without exiting. Recovery reloads use the tagged/routed path with no exit timer. The red in R30-MS2 `4pa.55` is written to this recommendation, and its row 5 flips if the owner picks (B).
2. **Should Mac gates be pinned to a commit?** (bd `zigBrowser-4pa.59`, `zigBrowser-4pa.77`; findings V03-F5, V79-M4)
   - Today each gate tars the live working tree (uncommitted and other agents' work included) to one fixed path, extracts over one shared remote directory, and runs with host-key checking off.
   - **Recommendation: YES.** Build from `git archive <sha>` into a `mktemp` tar, extract into a fresh per-run remote directory (`~/zb-gate-<sha>-<nonce>`), print the sha in the PASS line, pin `known_hosts`, and use `StrictHostKeyChecking=yes`. The red is in R30-MS1.
3. **(Raised by V03-F4; additional.) What should closing the primary window do on macOS?** There is no main menu (no Cmd-Q, no Cmd-W) and `applicationShouldTerminateAfterLastWindowClosed` returns NO, so closing the primary leaves a windowless process. **Recommendation:** match the Linux behaviour (the implementer confirms it by running the Linux build before writing the red) and add the main menu in MS7.4's Edit-menu slice. Until decided, MS2c.6 specifies only popups and secondary windows.
4. **(Raised by V79-M6; additional.) Should MS9 re-sign Anthropic's bundled Claude CLI?** **Recommendation:** keep Anthropic's own signature if it is hardened-runtime valid and notarizable; re-sign only if the widened MS9.0 spike shows it is not. Re-signing replaces entitlements the CLI may need (JIT, unsigned executable memory).

### R30.4 Validation finding map (bd `4pa.55`–`4pa.80` and the 34 minors)

Ids: `V03-Fn` = ms0-3 file, finding Fn. `V46-Fn` = ms4-6 file, finding Fn. `V79-…` = ms7-9 file (C1, C2, M1-M7, m1-m12). Types: **red** = a named failing test is specified in the owning slice; **fix-forward** = the production change is specified, with its red; **status correction** = a BUILT or REGISTERED claim was changed; **NOT BUILT** / **UNPROVEN** = the behaviour was re-marked. The amended text is in the `R30-MSn` block named in the column (each block sits at the end of its slice) unless noted.

| Finding | bd id | Severity | Amended in | Amendment type |
|---|---|---|---|---|
| V03-F1 quit on failed or recovered load | `4pa.55` | CRITICAL | R30-MS2 (owning MS2c/MS3); R30.1 #12; decision R30.3 #1 | red (rewrite `mac_ms2a_user_nav_failure_test.py`) + fix-forward + status correction |
| V03-F2 cookie calls ignore their timeout | `4pa.56` | MAJOR | R30-MS3 (MS3.3) | red + fix-forward |
| V03-F3 `page.dialogs` wrong window id | `4pa.57` | MAJOR | R30-MS2 (MS2b.2) | red + fix-forward |
| V03-F4 native close leaves a live window | `4pa.58` | MAJOR | R30-MS2 (new MS2c.6); decision R30.3 #3 | red + fix-forward (new sub-slice) |
| V03-F5 gates build an unpinned working tree | `4pa.59` | MAJOR | R30-MS1; decision R30.3 #2 | red + fix-forward |
| V03-F6 pacing dir not created | `4pa.60` | MAJOR | R30-MS3 (MS3.1) | red + fix-forward |
| V03-F7 entitlement check tautological | `4pa.61` | MAJOR | R30-MS1 (MS1.3); R30.1 #8; R30.2 T17 | status correction + UNPROVEN + red |
| V03-F8 MS2/MS3 runtime not in `zig build test`, 3 gates no step | `4pa.62` | MAJOR | R30-MS2; R30.1 #11 | status correction (UNPROVEN) + fix-forward (steps + Linux parser tests) |
| V46-F1 vacuous Darwin build guard | `4pa.63` | MAJOR | R30-MS6; R30.1 #4; R30.2 T5 | status correction (tripwire) + red (meta-test) |
| V46-F2 phaseA drops `options.guard` | `4pa.64` | MAJOR | R30-MS4; R30.1 #13 | status correction + red + fix-forward |
| V46-F3 recovery store-name mismatch `runs.json` | `4pa.65` | MAJOR | R30-MS6 (MS6.5.1); R30.1 #14 | red + fix-forward + NOT BUILT |
| V46-F4 `seatbelt_ready` unpinned, two-boolean readiness | `4pa.66` | MAJOR | R30-MS6 (D2); R30.1 #16; R30.2 T8 | red + fix-forward + UNPROVEN |
| V46-F5 MS5.2/5.3/MS6 no production path; Keychain not built | `4pa.67` | MAJOR | R30-MS5; R30-MS6; R30.1 #15, #17 | NOT BUILT + fix-forward |
| V46-F6 ledger pid unchecked `i32` | `4pa.68` | MAJOR | R30-MS6 (MS6.5.1) | red + fix-forward |
| V46-F7 MS4.4 Linux-only | `4pa.69` | MAJOR | R30-MS4 (MS4.4); R30.1 #3 | status correction + fix-forward (`ms4-gate`) |
| V46-F8 `reaper_gate.sh` guarded only by `ZB_MAC_ARM_HOST` | `4pa.70` | MAJOR | R30-MS6 (R29-SAFETY); R30.1 #18 | red + fix-forward |
| V46-F9 recovery transaction not in `zig build test` | `4pa.71` | MAJOR | R30-MS6 (MS6.5.1) | red + fix-forward (register, non-pub) |
| V79-C1 MS7.6/7.8 card press falsely BUILT | `4pa.72` | CRITICAL | R30.1 #1, #2; R29.1(c); R29.2; R29-MS7; ledger MS7.6/7.8; R30-MS7 | status correction + NOT BUILT (RED-UNREGISTERED) |
| V79-C2 release script cannot make a working app | `4pa.73` | CRITICAL | R30-MS1 (new MS1c red); R30.1 #20 | fix-forward + red (MS1c) |
| V79-M1 K6 gate cannot pass at MS7 | `4pa.74` | MAJOR | R30-MS7; R30.1 #21 | red + fix-forward |
| V79-M2 macOS minters inert | `4pa.75` | MAJOR | R30-MS8 (MS8.0); R30.1 #5; R30.2 T3 | NOT BUILT + red + fix-forward |
| V79-M3 duplicate `zb_secrets_window_open` | `4pa.76` | MAJOR | R30-MS7 (MS7.5); R30.2 T16 | red + fix-forward |
| V79-M4 scripts disable host-key checking | `4pa.77` | MAJOR | R30-MS1 (shares the F5 red); decision R30.3 #2 | red + fix-forward |
| V79-M5 fixture-card seam ships a debug hook in release | `4pa.78` | MAJOR | R30-MS7 (R29-MS7 K6 seam) | red + fix-forward |
| V79-M6 MS9 entitlement manifest does nothing | `4pa.79` | MAJOR | R30-MS9 (MS9.0); R30.1 #8; decision R30.3 #4 | UNPROVEN + red (widened spike) |
| V79-M7 bundle layout may fail codesign/notarization | `4pa.80` | MAJOR | R30-MS9 (MS9.0); R30-MS1 (MS1c) | UNPROVEN + red (spike) |
| V03-F9 "excluded from test by the unguarded list" wrong | — | MINOR | R29.2 header; R30.1 #10 | status correction |
| V03-F10 `zb_version_line` prints WebKit version twice | — | MINOR | ABI table row; R30-MS1; R30.1 #23 | status correction + red |
| V03-F11 MS0 leftovers (login golden, private `_LINUX_BACKEND`, Protocol unchecked) | — | MINOR | R30-MS0 | red (already R29.6 T-W1, I-W9, I1) |
| V03-F12 stale gate comments and messages | — | MINOR | R30-MS1 | fix-forward |
| V03-F13 hook-inert test covers 4 of 13 hooks | — | MINOR | R30-MS2; R30.2 T15 | red |
| V03-F14 ~150 duplicated lines between the two ports | — | MINOR | R30-MS2 (with `4pa.62`) | fix-forward |
| V03-F15 `ManagedMediaSource` left on macOS 14+ | — | MINOR | R30-MS3 | UNPROVEN + red |
| V03-F16 profile identity undocumented; `CLOCK_REALTIME` timeouts | — | MINOR | R30-MS3 | fix-forward (doc + monotonic clock) |
| V03-F17 stale comments (port header, "dispatch_semaphore", test headers) | — | MINOR | R30-MS3; R29-REG T-W6 | fix-forward (doc) |
| V03-F18 every popup steals focus | — | MINOR | R30-MS2 | red |
| V03-F19 NUL bytes truncate at the Zig-to-C boundary | — | MINOR | R30-MS2 | red + fix-forward |
| V46-F10 pin duplicated; sigstore installed unpinned | — | MINOR | R30-MS5; R30.2 T12 | red (already D-W4, T-W7) |
| V46-F11 MS5 item 5 has a Linux proof only; setup spawn lacks CLOEXEC_DEFAULT | — | MINOR | R30-MS5 | red + fix-forward |
| V46-F12 I1 gap points the wrong way (Protocol is wrong, not the backends) | — | MINOR | R30-MS6 (I1) | status correction |
| V46-F13 profile lease may be deleted before `sandbox-exec` reads it | — | MINOR | R30-MS6 | UNPROVEN + red |
| V46-F14 `ledger.RealClock` Linux-only and ignores failure | — | MINOR | R30-MS6 | red + fix-forward |
| V46-F15 `acquireRunLockBounded` holds nothing | — | MINOR | R29.6 I-W4; R30-MS6 | red (already I-W4) |
| V46-F16 approval card list grows without bound | — | MINOR | R30-MS4 | red + fix-forward |
| V46-F17 macOS and Linux setup duplicated; VM gate reaches Linux | — | MINOR | R30-MS5 | fix-forward + red |
| V46-F18 Keychain lookup truncates at embedded NUL | — | MINOR | R30-MS5 (MS5.2) | red |
| V46-F19 two census units lack the ResourceWarning check | — | MINOR | R30-MS5 | red + fix-forward |
| V46-F20 root-in-namespace failure; Darwin-only skips | — | MINOR | R30-MS5 (rule 7) | red + fix-forward |
| V79-m1 stale test headers (RED / not in test) | — | MINOR | R30-MS7; R29-REG T-W6 | fix-forward (doc) |
| V79-m2 stale doc comment on `zb_drawer_bubble_layout_contiguous` | — | MINOR | R30-MS7 | fix-forward (doc) |
| V79-m3 MS7.0 "in test" claim wrong | — | MINOR | R30.1 #6; R29.1(c) | status correction |
| V79-m4 duplicated `appkitShown`/`breakRuns` loops | — | MINOR | R30-MS7 | fix-forward (refactor under green tests) |
| V79-m5 MS7.1 property narrower than the ledger says | — | MINOR | ledger MS7.1; R30-MS7 | status correction |
| V79-m6 stale header; no netd exit watch on macOS | — | MINOR | R30-MS8 | red + fix-forward |
| V79-m7 spawner EINTR, non-atomic CLOEXEC, no CLOEXEC_DEFAULT | — | MINOR | R30-MS8 | red + fix-forward |
| V79-m8 dead lexical oracles | — | MINOR | R30.2 T6; R30-MS7 | status correction (retired) |
| V79-m9 probe and gate limits (pasteboard, hardened runtime) | — | MINOR | R30-MS7; R30-MS9 | status correction + UNPROVEN |
| V79-m10 SBPL profile in `mac_compile_only.sh` untested; regex escape only `.` | — | MINOR | R30-MS9 | red |
| V79-m11 pin written twice; RECORD line not CSV-quoted | — | MINOR | R30-MS9 | red |
| V79-m12 R4 selftest fails as root / needs a reaping PID 1 | — | MINOR | R30-MS9; R30.1 #24 | red + fix-forward |

**All 26 bd ids `zigBrowser-4pa.55` to `zigBrowser-4pa.80` appear in this table, in the R30-MSn blocks and in the compliance
table at the end. The compliance table at the end of the plan lists every behaviour with its rule-9 fields.**

---

## Rev 9 — MS1 empty-resource state made an executable, fail-closed phase contract (RoseCat 5995) — HISTORICAL, NOT NORMATIVE

RoseCat accepted the rev-8 MS5 role/resource typing but BLOCKED on MS1's empty-resource exception
being prose-only (it "resolved the oracle conflict by not calling `resource_compat`"). A skip
conditional is indistinguishable from deleting the check, so rev 9 replaces it with a typed gate.

| # | Blocker (5995) | Resolution in rev 9 | Where |
|---|---|---|---|
| 1 | MS1's `resources: []` is enforced only by *not invoking* `resource_compat`; there is no typed MS1-only policy and no red proving empty is accepted only for MS1 while staying fail-closed at MS5. (Rev-9 first pass checked only the `--milestone` label — a bypass: an MS5-shaped manifest relabeled MS1 passed, RoseCat 6002.) | `resource_phase(milestone, inventory, tree_a, tree_b)` is the typed, **shape-checked** gate the green **calls at every milestone**, taking the whole inventory: an empty resource set passes **only for the EXACT browser-only MS1 bundle** (milestone `MS1` + exactly one component at `bin/zigBrowser` + no resources); **any other empty shape fails closed** (MS5, unknown/"" label, extra/non-browser component, MS5-shaped relabeled MS1); a nonempty set runs the two-tree `resource_compat` oracle. `mac_resource_compat.py` passes the inventory and a **required `--milestone`**. Tests pin MS1-browser-only-passes, MS5/unqualified-empty-fails, extra/non-browser-component-fails, MS5-shaped-relabeled-MS1-fails, MS5-nonempty-mismatch-fails; a mutant dropping the shape/milestone check is caught. | MS1.1, MS5.1c, `tests/e2e/mac_universal_test.py` (`resource_phase`, `MS1_BROWSER_GLOB`), `mac_resource_compat.py` |

Re-pinned to HEAD `774ce31` (the executable gate + tests are `c53b580`).

## Rev 8 — MS5 role classification + MS1 resource rule corrected (docs only; RoseCat 5989) — HISTORICAL, NOT NORMATIVE

> **History (rev 17):** row 1's `zb-claude` as a bundle `resource`, and MS5's roles going into
> `universal_components.json`, are **superseded** by Behavior MS5.1c as rewritten in rev 17: `zb-claude` is per-user
> setup output, and MS5 uses its own inventory. Row 2's MS1 "does not invoke `resource_compat`" rule was
> **superseded by Rev 9 and MS1.1** (the green calls the typed phase gate at every milestone); this whole section is history
> and carries no normative force (Rev 31, G5.8).

RoseCat approved the `{browser}` MS1 scope (`build.zig:163-173`) but BLOCKED rev 7 on two
representation contradictions in how components and resources are typed. Both are fixed in docs.

| # | Blocker (5989) | Resolution in rev 8 | Where |
|---|---|---|---|
| 1 | `zb-claude` is a generated Python shebang script (`token.py:100-140`, written at `setup.py:492`), real path `runtime/bin/zb-claude`, **not a Mach-O**; `component_census` resolves roles only from the Mach-O map, so MS5.1c's "all three roles are fat Mach-O" can never green. | Classify the MS5 roles by their real form: **`python-runtime` and `claude-cli` are native/fat Mach-O** (added as `components` with their real `path_glob`s at MS5); the **`helper-launcher` (`runtime/bin/zb-claude`) is a generated script**, verified as a **byte-compatible resource** by the `resource_compat` oracle (or re-classified if a native launcher is ever introduced) — NOT a fat-Mach-O role. The embedded python/CLI paths make the wrapper byte-identical only when MS5 ships one universal2 runtime at one path; otherwise the oracle fails closed. | MS5.1c |
| 2 | Browser-only MS1 has no declared non-exec resource; the sole current resource `runtime.json` is deferred, and `mac_resource_compat.py` fails closed on an empty list, so MS1 can neither keep nor drop it — and rev 7 wrongly folded the oracle into the MS1 census. | The MS1 universal browser is a **single fat Mach-O with no non-exec resource**, so MS1's inventory `resources` is **empty by design** and MS1 **does not invoke** the `resource_compat` oracle — stated explicitly in MS1.1 (not a silent skip). The **first production resource check is at MS5**, on the runtime's non-exec files (`runtime.json`, the generated `zb-claude`/`zb-hook-run`/`zb-net-relay` scripts, the `*.json` manifests) across the two per-arch trees. The oracle's **fail-closed-on-empty stays an MS5 guard** (a milestone that ships resources must declare them; MS1 ships none and never calls it). The per-host census still checks Mach-O fatness + role presence + any declared-resource presence. | MS1.1, MS5.1c, `mac_resource_compat.py` |

Re-pinned to HEAD `99f11b1`.

## Rev 7 — MS1.1 component scope corrected to what the bundle ships (docs only) — HISTORICAL, NOT NORMATIVE

MS1's red (`0e41ae1` → `ec434bc` → `d48b71c`, JadeBeacon) landed and both Macs built: a universal
fat Mach-O (x86_64 + arm64) assembled by `lipo`, ad-hoc signed, with its entitlements verified on
both hosts. Building it surfaced that the MS1.1 census over-specified for MS1 — it required four
fat components, but the macOS MS1 bundle ships **only the browser**.

| # | Finding | Resolution in rev 7 | Where |
|---|---|---|---|
| 1 | The MS1.1 census requires the Python runtime, Claude CLI and helper launcher as fat Mach-O, but `build.zig:168` installs only `zigBrowser`; the agent runtime is a separate non-default step, not in the macOS bundle at MS1. A green could never satisfy the four-component census, and there is no universal2 Python (Intel Xcode 3.9 vs arm Homebrew 3.14) to make one fat. | **MS1's fixed inventory is `{browser}`** — the only native component the MS1 bundle ships; "complete" = every component actually shipped, so the census stays honest and fail-closed. The census mechanism, the whole-bundle Mach-O scan, the fail-closed probe, the two-tree `resource_compat` oracle and all their tests are **unchanged** — only the MS1 inventory narrows. | MS1.1, `packaging/macos/universal_components.json` |
| 2 | The three agent-runtime roles still must be verified fat **somewhere**, with their cross-arch resources checked before `lipo`. | **MS5's red MUST add** the `python-runtime`, `claude-cli` and `helper-launcher` roles to the universal-components inventory and assert the two-tree `resource_compat` check, because MS5 is where macOS provisioning first installs the Python runtime + helper (MS5.1). The Intel 3.9 vs arm 3.14 Python is exactly the mismatch the oracle catches, so MS5's provisioning must produce a universal2 (or per-arch-reconciled) runtime or fail that check. | MS5.1, MS5 gate |

Re-pinned to HEAD `f18a5f1`.

## Rev 6 — RoseCat's one rev-5 blocker, answered (review ed13e5e) — HISTORICAL, NOT NORMATIVE

RoseCat's exact review of `c8b646a` confirmed the config-ABI blocker **closed** (the fallible
`applyMacBackendFlag` seam), but BLOCKED on one point: rev 5 made the load-bearing MS6 egress
transport an explicitly **unsettled open design item**, and BlueBeaver's measurement (mail `5503`)
ruled out the Unix-socket-proxy option, so an implementation-ready plan must **pin** the remaining
viable mapping before MS6.

| # | Blocker (ed13e5e) | Resolution in rev 6 | Where |
|---|---|---|---|
| 1 | MS6 egress is left open; the Linux-private `127.0.0.1:3128` listener can't be copied to a shared macOS loopback port, and the CLI rejects Unix-socket proxy URLs (5503) | **Pinned exactly** as a shared `SandboxBackend` egress capability (endpoint + policy supplied by the backend): (1) host netd on an **OS-selected per-session `127.0.0.1:<port>`**, CLI/helper profile permits **only** that loopback endpoint; (2) `HTTPS_PROXY`/`HTTP_PROXY` name that port, netd keeps the exact CONNECT/SNI allowlist (arbitrary host processes gain nothing — they already have host egress and the proxy grants only the same allowlist); (3) **each hook its own profile permitting only loopback 51091/31337**, no proxy endpoint, no API path; (4) the real-binary fake-API test proves the endpoint, both bridge positives, every MS6.4 denial, and that a hook cannot reach the proxy. **Linux** realizes it with private-netns fixed ports + relays; **macOS** with the ephemeral host-loopback proxy + per-process Seatbelt port rules. Unix-socket proxy ruled out (5503) | MS0 launch spec (egress capability + realization), MS6 "Egress mapping" §, MS6.4 |

## Rev 5 — RoseCat's one remaining rev-4 blocker, answered (review mail 5501) — HISTORICAL, NOT NORMATIVE

RoseCat's exact review of `74413b0` (mail `5501`) confirmed the MS8.3 approval-source move, the
in-process CGEvent/CGEventPost split, and the complete 75-export inventory + cookie-move as
**closed**, and left **one** narrow blocker.

| # | Blocker (5501) | Resolution in rev 5 | Where |
|---|---|---|---|
| 1 | The config-flag ABI names an impossible error path: the table/MS3.2 say flags return `int<0 + out_err`, but `zb_app_set_hw_policy`/`zb_app_set_media_source` are **`void`**, their getters are bare `int`, and `--renderer` has **no C setter** — so no such channel exists (same class as rev-3 #2) | Moved the unsupported decision to a **named fallible Zig seam `applyMacBackendFlag(flag, value) !void`** (`src/webkit.zig`, called from `src/app.zig`): it validates each flag/value **before** any void C setter; a supported value is applied (void setter and/or `WKPreferences`), an unsupported value is **refused** so the **real binary exits nonzero with an exact message** and the C ABI is never touched. `--renderer` is handled entirely by this Zig seam. The void setters/int getters are simply **always implemented** (no error channel claimed). Dropped the `out_err` claim from the ABI table and MS3.2; named `mac_config_flags_test.py` for the supported-applies and unsupported-exits-nonzero cases (with a before-validate / swallow-error mutant) | ABI table (config rows + uniform-mechanism note), MS3.2 |

**Also in rev 5 (advisory F2, orchestrator-directed):** rev 5 recorded the F2 egress-hop finding as
an MS6 open design item (macOS has no per-sandbox loopback for the rev-16.2 `127.0.0.1:3128` hop).
**Rev 6 closes that item** — it is no longer open: the egress capability is pinned in MS0 and MS6
(see the Rev 6 table and MS6 "Egress mapping" §), with the Unix-socket-proxy option ruled out by
BlueBeaver's CLI measurement (5503).

## Rev 4 — how each of RoseCat's 3 rev-3 blockers is answered (review db02324) — HISTORICAL, NOT NORMATIVE

RoseCat's `db02324` BLOCKS `a02f1ea` and APPROVES `5bebd42` only as the narrow
frontmost-application API-name correction. Rev-3 blockers #2/#5/#6 were confirmed closed, #1
semantically corrected but dependent on the then-unlanded S3a green (now landed at `da5eb70`),
and #3/#4 left open. Rev 4 answers all three remaining contracts.

| # | Blocker (db02324) | Resolution in rev 4 | Where |
|---|---|---|---|
| 1 | The MS7 positive approval chain starts from the forbidden automation-socket route before the production helper exists; and the Mac action says "X click" | **Moved the positive end-to-end commit closure from MS7.8 to MS8.3**, after MS8 wires the production CLI/helper/protocol-pump that actually delivers `tool_use` (drawer plan :1231-1232, 2013-2020). The `tool_use` now arrives from the fake Anthropic API **through the production proxy and the helper** (same source as MS8.2), not the automation socket, so the forbidden span is never injected and socket separation holds. **MS7.8 now closes only native-card mint/deny** (the native Approve handler mints a valid MS4 grant, Deny mints nothing), triggered by a **native AppKit `-[NSWindow sendEvent:]` click** (not "X click"), observed as grant-minted/not — no helper, no socket | MS7.8 (card mint/deny), MS8.3 (positive commit), MS4 closure pointer |
| 2 | The ABI inventory is neither complete nor executable in its stated order, and gives unsupported semantics to signatures with no error channel; cookie ABI gated on a later slice | Added a **literal export-by-export table of all 75 `webkit_shim.h` exports** with implementing slice + unsupported mechanism + named test. `zb_main_invoke_sync`, `zb_automation_window_id_at` and `zb_automation_run_generation` are now assigned; app/profile/render/drawer/version exports are cross-referenced to their slices. The unsupported mechanism is **link-time absence**: a seam not implemented on macOS is **not compiled into the macOS shim**, so any test or caller that references it **fails to link** (a build failure = fail-closed) — this resolves the `void`/count/`bool` "no error channel" problem, since a void seam cannot signal unsupported at runtime but *can* be absent. Production (non-debug) exports are all implemented; the **cookie ABI (`zb_cookies_*`) moved from MS2c to MS3** (which owns `WKWebsiteDataStore`/`WKHTTPCookieStore`), so it no longer depends on a slice ordered after it | ABI table (MS2 §), MS3, MS4.4 |
| 3 | The CGEvent native-input fallback still contradicts the accepted in-process, non-TCC delivery decision | **Split the two CGEvent uses.** In-process **CGEvent→NSEvent** construction delivered with `-[NSWindow sendEvent:]` (no system post, no TCC) is a **primary delivery path, spiked first** alongside responder-chain `NSEvent`. System-wide **`CGEventPost`** is the only TCC-gated, out-of-process posting, and it **stays out of scope unless a separately approved capability is genuinely needed**. The executable MS2b contract and disposition 1 now state this split explicitly, so no executable contract calls in-process delivery TCC-gated | MS2b.1, disposition 1, rev-2 blocker-3 row |

**Also corrected:** the MS5 dependency citation `cab60a1` → **`da5eb70`** (the approved green S3a
follow-up that actually contains the chain/internal-alias/malformed-quote corrections); the
stale testing-strategy pin prose `21625eb` → `176782f`; and the Linux-idiom crash control label
"real-X/no-input" → **"real-crash/no-input"** (macOS has no window-close "X").

## Rev 3 — how each of RoseCat's 6 rev-2 blockers is answered (review 833767e) — HISTORICAL, NOT NORMATIVE

| # | Blocker (833767e) | Resolution in rev 3 | Where |
|---|---|---|---|
| 1 | MS5 still names the superseded SAI rule ("executed-import-graph") | Corrected to the final **"Hook commands only"**: copy dependency/VCS/cache/build trees **unscanned**, HOME-rewrite other copied text, **validate only hook command lines**, warn/skip outbound links; and **inherit** the S3a chain/alias/malformed-quote corrections (da5eb70, BlackRobin — approved green; supersedes the earlier cab60a1 citation per rev 4) rather than port today's defects | MS5.1, MS5.1b, rev-2 table note |
| 2 | Grant tuple weaker than the threat contract | Reuse the drawer plan's **exact** schema: `sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`, 120 s expiry, pre-dispatch revalidation of origin/`load_serial`/`crashed`/`recovering`, `options.expect={account,target_fp}` checked **atomically in the same FIFO ticket** (error **−32015 expectation_mismatch**); add the navigation (`load_serial` change), selector-retarget and one-field-at-a-time mutants (drawer T5) | MS4.1 |
| 3 | Positive closure precedes the only grant minter | MS4 closes the **authority + all negative/refusal/dry-run** paths only; the positive commit closure moves out of MS4 — no test-only mint bypasses the forbidden span. _(Rev 4 note: rev 3 placed the positive closure in MS7.8 from a socket `tool_use`; rev 4 corrected this — MS7.8 proves only native-card mint/deny, and the full commit closure is **MS8.3**, driven by the real helper `tool_use`, since the socket route is forbidden.)_ | MS4 (closure), MS7.8, MS8.3 |
| 4 | "ABI inventory" is not the production ABI | Added `zb_automation_set_script` (private-world injection before first load), `zb_automation_free` (allocator paired with every returned C string), `zb_automation_loop_mark` (ENDED + queued-job cancellation + waiter wake-up on quit), `zb_automation_window_alive`, `zb_native_pointer`, protocol-row field sanitization, and the cookie ABI; **decided** which `zb_automation_debug_*` seams exist on macOS and required unsupported seams to **fail closed** (not silently return zero); added the private-world-install, allocator-pairing, immediate-quit-cancellation and late-completion tests | MS2 inventory, MS2a/b |
| 5 | Window destruction does not close drawer ownership | **Every popup gets its own drawer bound to its `window_id`**; **one shared destroy path** for `webViewDidClose:`, the NSWindow close button and automation close, which **detaches before** the automation notification/free; exact reuse of WebKit's supplied configuration; a **live-drawer count of zero** after all windows close (macOS analog of `zb_drawer_debug_live_count`) | MS2c.5, MS7.9 |
| 6 | Crash-presentation parity absent | Added the macOS crash contract: `webViewWebContentProcessDidTerminate:` + a **public simulated-request crash document** that reports per-window termination, shows a **static** crash document, **keeps the committed URL**, **excludes API-driven termination**, clears `crashed` **only on a real commit**, and **never auto-reloads** (parity with Linux `ddc892e`/`44d0d0f`); with **real-crash/no-input** (rev 4 label) and **clicked-Reload** controls | MS2c.4 |

### SHOULD items folded in (833767e)

No main-thread caller may synchronously wait on a main-queue marshal (MS2); dialogs **hold
completion handlers** rather than running a modal loop (MS2b); health/list snapshots are
**lock/atomic-backed** and never `dispatch_sync` to a hung main queue (MS2c.2); the public
recover spike **tries replacing the WKWebView while retaining its window id** rather than
private SPI (MS2c.3); scroll events were expected to be built from a CGEvent and delivered
**in-process** with `-[NSWindow sendEvent:]` without TCC — **but the MS2b spike disproved this for
scroll and repeated hover (see the 2026-10-20 user decision above): both need private API, so they are
synthetic-only on macOS for now** (MS2b);
icon/fold views **intentionally overlap** the page and need **exact hit-testing** even though
the dock does not (MS7); keyboard/fold-row and Secrets-exclusion parity need **named tests**
(MS7); the real-screen runner **fails closed** when Screen-Recording/window-order evidence is
unavailable (MS7, MS8).

## Rev 2 — how each of RoseCat's 9 blockers is answered — HISTORICAL, NOT NORMATIVE

| # | Blocker (21625eb) | Resolution in rev 2 | Where |
|---|---|---|---|
| 1 | MS2 closure map is not the full production topology (list/health/dialog/recover branch before the router and take no FIFO turn) | Split into **three** production chains + closure e2es: (a) ordinary routed command, (b) out-of-band `page.list`/`page.health` while a named window's FIFO is stuck, (c) two-phase `recover`; plus an explicit ABI/test inventory and an async-completion ownership contract (copied input, exactly-once, no-dispatch-after-abandon) | MS2, Closure Maps A/B/C |
| 2 | Multi-window / freeze / recovery contracts underspecified | New behaviors: two-hop related-popup chain, per-`window_id` FIFO independence, `page.close` **and** script `window.close()` with opener survival, popups use WebKit's supplied `WKWebViewConfiguration`; a **bounded responsiveness probe/watchdog** not behind the window FIFO; frozen window does not poison siblings; two-phase consent + blast-radius ack + exactly-once cancel + "recovering"; **if public WKWebView APIs can't recover a hung process, MS2c stops at a spike** | MS2b.*, MS2c.* |
| 3 | "native input" has no proven capability contract | MS2b is a **red-first capability spike** (`isTrusted`, focus, click, key, text, contenteditable/`beforeinput` cancel, scroll, pointer move, navigation-during-input, partial typing, deadline abandonment) on **both** Macs; the capability table is updated **only after** it passes; **in-process CGEvent→NSEvent** delivery (`-[NSWindow sendEvent:]`, no system post, no TCC) is a primary path spiked first, while system-wide **`CGEventPost`** is the only TCC-gated use and is out of scope unless a separately approved capability is genuinely needed — never a silent fallback (rev 4 split); the real-screen runner proves its window is frontmost before any native emit | MS2b, disposition 1 |
| 4 | Launch-critical setup / persistence / configuration have no owner | New **MS5 (macOS setup & provisioning)** ports `runAgentSetup` for macOS (immutable `dist-<n>/current/state`, Python runtime/helper, the final **"Hook commands only"** SAI rule — see rev 3 blocker 1, skipped linked skills, no real `~/.claude`/repos, FIFO→fd 3, Keychain onboarding); new **MS3 (config & persistence)** adds an isolated persistent `WKWebsiteDataStore` contract and a decided macOS mapping/explicit-unsupported for `--profile-dir`/`--hardware-acceleration`/`--renderer`/`--media-source` | MS3, MS5 |
| 5 | Shared sandbox interface asserted at the wrong layer ("Zig, platform-neutral") | Corrected: the real seam is **Python** (`agent/host/zb_agent_host/sandbox.py` + `launch.py`, policy/argv) and **C/GLib** (`src/agent_host.c:1-73`, spawn/lifetime/`prctl`). New **MS0** extracts a behavior-preserving `SandboxBackend` seam on **Linux** with its own Linux gate, naming exact files/methods/ownership/wire contract; Seatbelt then implements the same semantic launch spec. Proxy/bridges are rev-16 WIP: MS6 **owns them or depends on a named green landed revision** | MS0, MS6, Shared contract, disposition 4 |
| 6 | Seatbelt failure must block launch and select the VM fallback | The spike proofs (custom-profile acceptance, other-process-info denial, fd-3 reopen) are **hard gates before MS8**; **any failure disables Mac agent launch until the shared interface's VM backend is implemented**. The double-fork/`setsid` orphan escape is, by the user's rev-19 decision (2026-10-21), **accepted with public-API cleanup + a survivor warning** — not a hard gate, and it no longer forces the VM backend — with an **off-by-default VM-containment stub** that fails launch closed when enabled; the unapproved dedicated-user `kill(-1)` scheme stays **removed**. MS6 network tests traverse the **production proxy via an e2e-only allowlist seam** (removing the proxy → red); deterministic sacrificial canary | MS6, disposition 3 |
| 7 | Approval / Keychain / chat observability not closed | **Approval grant contract** specified before flows (action+site+account+window+payload binding, one-use, expiry, cancel/refuse, only the native Approve handler mints; negative proofs that page worlds/iframes/popups/socket clients/prompts/hooks cannot approve; per-write confirmation; dry-run no-commit). **Keychain** tests use a disposable service/account + canary, prove the token reaches **only** helper fd 3. **Chat observability** is a gated `--e2e-protocol` native census or screen capture — **never** a production socket drawer-read | MS4, MS5, MS7 |
| 8 | Two-arch and packaging gates can false-green | MS1 provisions **two distinct hosts**, asserts the Intel host is really `x86_64` and the Apple-Silicon host **executes the arm64 slice (not x86 under Rosetta)**, records the **executing arch in production build info**, covers **every bundled native component** (browser, helper, CLI, runtime) and compatible non-exec resources before `lipo`; the runner **fails closed** on no GUI session / wrong arch / missing runtime-SDK / zero assertions; every sub-slice gets a named red test + exact failing assertion + green files + refactor gate | MS1, Testing Strategy |
| 9 | Signing is last but its contract is not release-safe | MS1 **derives and tests a least-privilege entitlement manifest**; MS9 signs nested code **inside-out** then verifies the whole universal bundle **under hardened runtime on both arches before notarization**; until the Developer ID exists the result is called an **ad-hoc development build, not a distributable artifact**; the missing credential is tracked via **Agent Mail / plan status**, not a bead (beads DB is migration-locked) | MS1.3, MS9 |

## Open-question dispositions (accepted from the review)

1. **Native input (rev 4 split):** responder-chain `NSEvent` is a **spike result, not an
   assumption**; the trusted-event matrix (MS2b) decides it. Delivery has **two distinct CGEvent
   uses, not conflated**: (a) **in-process CGEvent→NSEvent** construction delivered via
   `-[NSWindow sendEvent:]` — **no system post, no TCC** — is a **primary path spiked first**
   alongside responder-chain `NSEvent`; (b) system-wide **`CGEventPost`** (out-of-process posting)
   is the **only** TCC-gated use and is **out of scope unless a separately approved capability is
   genuinely needed**. "In-process delivery" is never called TCC-gated.
2. **fd-3 reopen:** `/dev/fd/3` reopening is a **hard MS6 spike gate on both arches**.
3. **sandbox-exec:** custom profiles are a **hard gate**; failure **selects the VM backend and
   blocks MS8**.
4. **Linux extraction:** **yes** — extract the backend interface in its own pre-MS5 slice
   (**MS0**) and keep the Linux gate isolated.
5. **MS2 split:** keep **MS2a/MS2b/MS2c as separate reviewed gates**, and split the out-of-band
   health/recover closure from crash-page presentation if one commit cannot keep a single red
   seam.

## Overview

macOS is launch-critical (most users on Mac). Today zigBrowser has a working macOS
app/window/render/IPC seam only (`src/wkwebview_shim.m`, 6 of ~76 C-ABI functions; bead
`zigBrowser-8g7` proved render + ping/pong on a real Intel Mac). Everything a launch needs
beyond opening a window — automation, multi-window/freeze/recovery, native input, site
flows, approval, the AppKit drawer, setup/persistence/config, the OS-native sandbox, the
agent helper, and signed universal packaging — does not exist on macOS. This plan turns the
research map (`…/research/2026-10-14-14-19-macos-launch-support-surface.md`, 1df5dce) into
small, red-first, gated slices. House conventions follow the drawer plan: small slices, one
gate each, native work lands with its adapter in the same slice, a real-binary e2e ends every
slice, UI slices need a real-screen check on the user's hardware, and a slice is not done
until its closure e2e was **observed to execute** with nonzero assertions (a "SKIP" is
UNCLOSED).

## Current State Analysis

### Key discoveries (research 1df5dce + review 21625eb, verified file:line)

> **Rev 29:** this list was written at `ed13e5e`. Its line numbers are stale at HEAD `e4f705f`; **the symbol is the
> citation, the number is a hint** (`resolveBackend`, `configureMacosBackend`, `CheckMacosBackendStep`,
> `handleRequestWith`, `handleWindows`, `handleRecover`, `handleDialogs`). Statements about what is "unimplemented"
> are superseded by the Built-vs-not-built table in R29.2.

- One C ABI, three backends: `resolveBackend` (build.zig); `configureMacosBackend`
  (build.zig) (**since MS1b `3421428`**: builds `wkwebview_shim.m` as a separate
  Apple-toolchain dylib — `xcrun clang -dynamiclib -Wl,-fixup_chains` → `LC_DYLD_CHAINED_FIXUPS`,
  `-install_name @executable_path/../Frameworks/libwkwebview_shim.dylib` — which the exe links and
  installs to `Frameworks/`; the exe sets `rdynamic` macOS-only to export the two shim back-refs. It
  is **no longer compiled into the exe**); `CheckMacosBackendStep` build.zig:79-105.
- **[Rev 29 — HISTORICAL at `ed13e5e`; superseded by R29.1/R29.2]** macOS shim = 6 core fns + `zb_policy_decide`
  (nav_policy.zig) + `zb_ipc_dispatch` (ipc.zig). None of the ~70 `zb_automation_*`/`zb_native_*`. **At HEAD the
  macOS shim implements the automation, native-input (click/key/text), dialog, window, recover and cookie ABI
  (MS2a-MS2c, MS3); it does NOT implement `zb_screenshot_png`, `zb_set_input_files`, `zb_app_set/get_agent_drawer`,
  native scroll/move/pointer.**
- The `PagePort` impls are `automation_gtk_port.zig` (Linux-gated) and, at HEAD, **`automation_macos_port.zig`**
  (wired `src/app.zig:626`; cookie port `automation_macos_cookie_port.zig`, `:627`). `pagePort()`→null off a
  port-bearing OS. Server/router/engine/queue/recover/flows/token-sidecar are platform-neutral Zig.
- **Out-of-band server paths (review):** `page.list`/`page.health` branch **before** router
  parsing in `handleRequestWith` (automation_server.zig, `:467` at HEAD) into `handleWindows` (`:744`) and
  deliberately **take no FIFO turn**; dialog discovery and two-phase recover have their own
  server paths (`handleDialogs` `:1176`; `handleRecover` `:995`). The MS2 closure cannot
  be a single chain.
- Capability table models macOS: `.wkwebview = { js_synthetic, network unsupported
  (no_platform_api) }` (automation_platform.zig:90-95). **Rev 29 (A-W2):** the table entry has no native flags and is
  unchanged; the real capability source on macOS is the PagePort vtable. See R29-CAP.
- **USER DECISION (2026-10-20) — native scroll + pointer move are SYNTHETIC-ONLY on macOS, no private
  API; revisit later.** The MS2b spike proved that an in-process trusted wheel and repeated hover cannot
  be delivered to WKWebView with public API: a `CGEventCreateScrollWheelEvent2`→`eventWithCGEvent:` wheel
  carries no window number and WKWebView drops it (WebKit's own WebDriver uses the private
  `-[NSEvent _eventRelativeToWindow:]`), and only the FIRST synthetic `NSEventTypeMouseMoved` per session
  reaches the page (WebKit dedups later synthetic moves against the real cursor). Rather than adopt a
  private selector (App Store risk), the user chose: **`nativeScroll` and `nativeMove` stay UNSUPPORTED
  on macOS** — the capability table keeps them unset and the port returns a clear `unsupported` error —
  while `dom.scroll` and `dom.hover` keep working through the engine's synthetic path (no trusted wheel,
  no real `:hover`). `nativeClick`, `nativeKey`, `nativeText` are unaffected (trusted, shipped). The
  Windows WebView2 shim will face the analogous question.
- **beforeunload accept/dismiss — UNSUPPORTED on macOS, same no-private-API class (2026-10-20).** The
  MS2b.2 probe showed WKWebView does NOT surface the beforeunload "Leave site?" prompt to any public
  `WKUIDelegate` method — with OR without a trusted-click user gesture, a navigation away from a page
  with an active `beforeunload` handler raises no panel (there is no public `runBeforeUnloadConfirmPanel`;
  WebKit handles it internally). Surfacing it needs private WebKit SPI, which the 2026-10-20 user decision
  rules out. So `navigateWithPolicy` keeps **rejecting accept/dismiss** as `error.Unsupported`, AND `.fail`
  **cannot honor the shared contract either**: `page_port.zig:161-165` / `router.zig:29-31` /
  `webkit_shim.h:204-213` require `.fail` to return **DialogOpen and leave the prompt open**, but on macOS
  the prompt is never raised, so a navigate away from a page with a `beforeunload` handler simply **loads**
  (no DialogOpen). This is a real cross-platform **divergence**, not an "exact `.fail`" — stated honestly
  until the prompt is surfaceable. alert/confirm/prompt dialogs ARE captured and answerable (36d3065).
  Revisit with scroll/move if the private-API stance changes. **Rev 29 (C-W1, A-W5):** this divergence is currently
  SILENT to clients (accept/dismiss return the generic unsupported error at `engine.zig:1446`, `.fail` just loads,
  and `docs/how-to-automate.md` never mentions macOS). Required: the distinct reason `beforeunload_unsupported` and a
  "macOS differences" section in the client docs (R29-DOCS).
- Native input on Linux is toolkit-path (`gdk_event_new` + `gtk_main_do_event`
  webkit_shim.c:3373), not XTEST; the macOS NSEvent path is a **spike** (MS2b), not an assumed
  equivalent.
- **Config/persistence/setup are Linux-only (review):** `runAgentSetup` refuses every non-Linux
  OS (`app.zig:41-47`) and uses `/proc/self/exe`; `--profile-dir` is discarded off Linux
  (`app.zig:160-166`); render/media flags are silent no-ops (`webkit.zig:47-72`).
- **The sandbox seam's real layer (review):** policy/argv is **Python**
  (`agent/host/zb_agent_host/sandbox.py`, `launch.py`); the spawn/lifetime seam is **C/GLib**
  with `prctl` (`src/agent_host.c:1-73`). There is **no** existing Zig sandbox abstraction. The
  token route FIFO→socketpair→fd 3 is portable POSIX (token.py:63-134). `--unshare-net` + the
  host allowlist proxy + the two bridges are **rev-16 WIP**, not built.
- Packaging ships an ad-hoc `.dmg` (`codesign --force --sign - --deep`,
  packaging/macos/build-dmg.sh:92); `Info.plist` `LSMinimumSystemVersion 13.0`. **Rev 29 (K5):** `build-dmg.sh` was
  NEVER converted by MS1/MS1b: it copies only the exe (`:71`), never `libwkwebview_shim.dylib`, so a `.dmg` built
  today cannot load its shim (the exe's install name is `@executable_path/../Frameworks/…`). The universal/hardened
  work exists only in `tests/mac/gate.sh` and `ms1b_signed_gate.sh`. No Developer ID, hardened-runtime gate,
  notarization or shipping universal `.dmg`.
- Drawer is GTK3 widgets on Linux (agent_drawer.c; portable logic agent_drawer.zig) with **portable AppKit-facing
  logic already exported on macOS (MS7.0/7.1/7.4, R29.1(c); Rev 30: the MS7.6 card-press half is NOT built and MS7.0 is a symbol tripwire, R30.1)**; **no AppKit view exists** (no
  `agent_drawer_mac.m`, no main menu); secrets via libsecret `dlopen` on Linux and raw Keychain store/lookup/clear
  on macOS (`agent_secrets_mac.m`). The approval card state is the sum type `Outcome` (`agent_approval.zig:188`);
  the native approve/deny minters (`agent_tools.zig:200,206`) are compiled in both macOS builds (MS8.0) but called
  only by the GTK drawer [Rev 30, `4pa.75`: on macOS they always return 0 because `agent_tools.start` is Linux-only, so MS8.0 is NOT BUILT]. The NVIDIA real-screen lesson (drawer plan §7.1) applies to macOS GPU compositing too.
- e2e harness is Xvfb/X11-bound (xsession.py, xinput.py); macOS tests are the `m9_*` set plus ~53 `tests/e2e/mac_*.py`
  and ~30 `tests/mac/*` scripts run from hand-run gate scripts (tests/mac/gate.sh and `ms*_gate.sh`). The
  cross-target no-backend integrity test `713587b` is green (review line 135). Baseline for this plan: a clean
  archive of the pin before the plan passed **106/106 steps, 817/817 tests** under private Xvfb (review line 7200);
  **Rev 29: that baseline is NOT re-measured at `e4f705f` (no test was run in this docs-only revision)**.

## Desired End State

A Mac user installs a **Developer-ID-signed, hardened-runtime, notarized universal** zigBrowser
and can: open pages with an isolated persistent data store; drive the full automation API
(including multi-window, freeze/recovery, dialogs, popups) with the same client contract and
per-window FIFO semantics as Linux; use native input proven trusted by a capability matrix;
run site flows with a fully specified per-action approval grant; use a native AppKit drawer
(docked, movable "S" icon, fold animation, Keychain secrets) isolated from page worlds; and
run the Claude agent inside an **OS-native Seatbelt sandbox** (behind one shared backend
contract) whose security proofs are hard launch gates that select the VM backend on failure.
Verified by real-binary e2e on **both** remote Macs and by the user's eyes on screen. The
ad-hoc development build is explicitly **not** a distributable artifact; MS9 produces the
distributable one once the user has a Developer ID.

## What We're NOT Doing

- Not changing Linux GTK behavior; MS0's extraction is behavior-preserving and the Linux gate
  stays green.
- Not shipping the VM sandbox in this plan **as the primary path** — but MS6 **requires** the VM
  backend to exist behind the shared contract **before Mac agent launch** if any Seatbelt proof
  fails (it is not deferred to a later bead when it gates launch).
- Not shipping the unapproved dedicated-agent-user `kill(-1)` orphan scheme (removed from rev 1).
- Not exposing native drawer text through a production automation socket read (chat observation
  is `--e2e-protocol` native census / screen capture only).
- Not calling any ad-hoc build a distributable artifact; not obtaining the Apple Developer ID
  (user action); MS9 is gated on it and tracked via Agent Mail / plan status.
- Not running anything on the user's local `DISPLAY :0`, live profile, or live sockets.
- Not building a Windows drawer / Windows automation parity (separate track).

## Testing Strategy

- **Frameworks:** Zig `std.testing`; Python e2e driving the real binary via the Python SDK over
  the automation Unix socket; ObjC behavior asserted through the C ABI / e2e (no separate ObjC
  runner).
- **macOS harness:** ~~`tests/e2e/mac_session.py`~~ **[Rev 29: does not exist and is not planned; each
  `tests/e2e/mac_*.py` drives the real binary directly (real `NSWindow`, no Xvfb/DISPLAY; sets `ZIGBROWSER_SOCKET`)
  through the two-host, two-arch `tests/mac/gate.sh` and the per-slice `tests/mac/ms*_gate.sh` scripts. Rule: a Mac
  gate is DONE only when it is a registered `zig build` step with a manifest of its last approved run (R29-REG).]**
  Evidence tiers (Rev 29): (1) Linux-side registered tests (default `zig build test`); (2) the **compile-only R4
  Mac tier** (`tests/mac/mac_compile_only.sh`, one reviewed digest builds one exact clean commit on both Macs, no
  execution); (3) a Mac EXECUTION tier that needs RoseCat exact-commit approval AND orchestrator release.
- **Fail-closed runner (blocker 8):** the runner **exits nonzero** (never SKIP-to-green) when a
  host lacks an active GUI session, is not the expected native architecture (not Rosetta),
  lacks a required runtime/SDK, or when a test records zero assertions.
- **Arch-execution proof (blocker 8):** assert the Intel host reports `x86_64` and the
  Apple-Silicon host **executes the arm64 slice**; the running app records its **executing
  arch in production build info**; `lipo -archs`/`--version` alone are insufficient.
- **Native input (blocker 3):** a red-first trusted-event matrix on both Macs decides the
  capability; the table is updated only after it passes; any real-screen input script proves its
  own window is focused/viewable/topmost at the target and aborts under a server/grab-equivalent
  guard (drawer plan §7.1, `test_real_screen_input.py` model).
- **Network (blocker 6):** the fake Messages/Anthropic API is reached **through the production
  proxy** via an `--e2e-protocol` allowlist seam; removing/bypassing the proxy turns the test
  **red**. Direct loopback decoy, LAN, public IP, DNS, WindowServer/CGEvent/screen capture,
  non-allowlisted host and workspace write must **fail**; only the proxy, `:51091`, `:31337`
  succeed.
- **Keychain (blocker 7):** disposable `Security.framework` service/account + canary token,
  never a real credential; prove the token reaches **only** helper fd 3 — not env, argv, logs,
  telemetry, hook env, or model context.
- **Chat observability (blocker 7):** assert via a gated `--e2e-protocol` native drawer census
  or screen capture, never a production socket drawer-read API.
- **Real-screen (UI slices):** macOS cases in the real-screen check, run by the orchestrator on
  the user's Mac; a UI slice is not approved until it passes there.
- **Closure tests** are Tier-1 real-binary e2e; **ClosureMaps regenerated at HEAD `e4f705f` in rev 29** (all three
  JSON maps cite symbols, not line numbers; see Closures A/B/C). **Both arches every run** — through the evidence
  tiers above; "both arches every run" does not authorize an unreleased Mac execution.
- **Source-text oracles are tripwires, not authority (T3, T-W6).** A test that parses source text (the MS7
  `mac_drawer_card_authority_test.py` / `mac_drawer_bubble_inert_test.py`, the `reaper_ready` `indexOf` in
  `tests/agent_run_recovery_startup_test.zig:184-194`) can be satisfied by a stub or a comment. Policy (RoseCat
  `483cdf7`/`c6b2b32`, adopted): drive runtime behaviour; keep a source check only as a minimal, labelled
  tripwire; replace the `reaper_ready` `indexOf` proof with a runtime **hostile-environment test** (set
  `ZIGBROWSER_REAPER_READY=1`, `ZB_REAPER_READY=1`, argv `--reaper-ready`, then call the production startup entry
  and assert zero actuator calls — mutant: read the env → the actuator is called). **Rev 30:** the same rule now covers every symbol, `nm`, `lipo`, grep and constant check in this plan: R30.2 lists 20 of them, each kept as a labelled tripwire beside its exercising proof. A tripwire never closes a behaviour, a slice, a review finding or a validation finding.

## Shared sandbox backend contract (corrected layer — blocker 5)

The sandbox seam is **not** a Zig abstraction. Today it is:

- **Policy/argv (Python):** `agent/host/zb_agent_host/sandbox.py` (`helper_argv`, the bwrap argv,
  `STATE_DIRS`, binds) and `launch.py` (`build_argv`, `os.execv(bwrap, …)`); the per-hook nested
  profile is `hook_run.py`; seccomp is `seccomp.py`.
- **Spawn/lifetime (C/GLib):** `src/agent_host.c:1-73` (`g_spawn_sync` with the `die_with_browser`
  child-setup hook and `prctl(PR_SET_PDEATHSIG)`).

**MS0** defines a **`SandboxBackend` semantic launch spec** and refactors the Linux code behind
it **without behavior change**, naming the exact files, methods, ownership, and wire contract:

- Launch spec (the contract both Linux and macOS satisfy): the broker byte stream; the token
  channel (FIFO then fd 3, never env); **the egress capability (rev 6) — the backend supplies both
  the loopback proxy *endpoint* and the *policy*: the CLI/helper reach egress only at a
  backend-supplied `127.0.0.1:<proxy-port>`, and netd enforces the exact CONNECT/SNI allowlist
  (`api.anthropic.com` + census-proven CLI domains, fail-closed)**; the two bridge ports (51091,
  31337); the shares (agent home read-only, workspace read-only, scratchpad read-write); a per-hook
  confinement launcher (**each hook confined to only loopback 51091/31337, with no proxy endpoint
  and no API path**); and a lifetime contract (everything dies with the browser).
- **Egress capability realization (rev 6, pinned per RoseCat `ed13e5e`):** the *endpoint* is
  backend-chosen, the *policy* (allowlist + per-process reachability) is backend-enforced. **Linux**
  realizes it with a **private network namespace, fixed proxy/bridge ports and relays** (the hook's
  own netns seals it). **macOS** realizes it with an **ephemeral host-loopback proxy** — netd
  listens on an **OS-selected, per-session `127.0.0.1:<port>`** — plus **per-process Seatbelt port
  rules**: the generated CLI/helper profile permits **only** that one loopback endpoint, and each
  hook's profile permits **only** loopback 51091/31337 (no proxy endpoint, no API path). The
  bundled CLI rejects Unix-socket proxy URLs (BlueBeaver 5503), so a TCP `host:port` hop is
  mandatory on every backend; `HTTPS_PROXY`/`HTTP_PROXY` name that exact backend-supplied port.
- Ownership: the **Python** side owns policy/argv/profile generation; the **C** side owns spawn +
  parent-death; the **host** side (shared, Linux+macOS) owns the proxy, bridges, in-process
  broker, and approval logic.
- Implementations: **Linux** = bwrap (MS0 extraction, behavior-preserving); **macOS Seatbelt** =
  SBPL profile + app-side hook launcher (MS6); **VM** = the fallback behind the same spec,
  required before Mac agent launch if Seatbelt's proofs fail (MS6).
- Dependency note: the proxy/bridges are **rev-16 WIP**. MS6 either **owns** them or **depends on
  a named, green, landed Linux revision** that provides them; the plan does not treat them as an
  already-existing dependency.

**Rev 29 amendments to this contract (I1, I2, C-W2, I-W9; details in R29-MS6):**
- **Conformance is tested, not assumed (I1).** `MacSeatbeltBackend` and `LinuxBwrapBackend` must both conform to the
  `SandboxBackend` Protocol, proven by a registered test (`agent/host/tests/test_backend_conformance.py`). At HEAD they
  differ from the Protocol, not from each other (Rev 31, V46-F12: the earlier wording had the gap pointing the wrong way):
  BOTH backends already use `network(self, session=None)` (`sandbox_macos.py:371`, `sandbox.py:307`); only the Protocol
  declaration `network(self)` (`sandbox.py:213`) is wrong and gets `session=None`. Also: the
  Protocol `launch_spec` has no `network=` argument (`sandbox.py:210`); `egress_dir()` is typed `str` but the Mac
  backend returns `None` (`sandbox_macos.py:393`); the Mac `launch_spec` ignores `ro_paths`, `state_dirs`, `net_dir`
  and `seccomp_fd` (`:413-442`). Fix the Protocol types (`Optional[str]`, `session=None`, `network=`) and make every
  ignored input an explicit, tested refusal.
- **Spawn policy is data flow only once a backend supplies it (C-W2).** The Python `Lifetime` is a hand-copied mirror
  of the C `ZbSpawnPolicy`, and every native call site passes `zb_spawn_policy_linux(0)` (`app.zig:140`,
  `agent_helper.c:732`, `agent_login.c:324,427`). "The backend owns spawn policy" is therefore **intent, not data
  flow, at HEAD**. Required (exercise form): the driven spawn-policy flow test of R30-MS0 (`tests/agent_spawn_policy_flow_test.zig`, TO BE AUTHORED; mutant: restore the hard-coded `zb_spawn_policy_linux(0)`); a field-comparison census of the Python `Lifetime` against the C `ZbSpawnPolicy` is a TRIPWIRE — not proof; and the macOS launch connector (MS6.8) supplies the Darwin policy through the same
  seam instead of `zb_spawn_policy_linux(0)`.
- **There is no production caller of `MacSeatbeltBackend` at HEAD (I2)** — see MS6.8.

---

## MS0: Extract the Linux sandbox-backend seam (pre-MS5, behavior-preserving, Linux gate)

**Goal (blocker 5, disposition 4).** Factor the Linux sandbox policy/argv (Python) and
spawn/lifetime (C) behind the `SandboxBackend` launch spec with **no behavior change**, so
Seatbelt can implement the same spec. Its gate is the existing Linux gate — it must stay green.

### Behavior MS0.1: the Linux backend implements the spec with identical argv
**Given** the current bwrap argv (`sandbox.py helper_argv`) and spawn (`agent_host.c`),
**When** they are moved behind a `SandboxBackend` interface (a Python `LinuxBwrapBackend` +
the parameterized C spawn seam),
**Then** the generated argv, binds, seccomp fd, and spawn/parent-death behavior are **byte-for-
byte** what they are today (golden-argv test), and the full Linux gate stays **106/106,
817/817**.

- **Files touched:** `agent/host/zb_agent_host/sandbox.py` (extract `SandboxBackend`
  protocol + `LinuxBwrapBackend`), `launch.py`, `src/agent_host.c` (parameterize the spawn
  seam), new `agent/host/tests/test_backend_contract.py`.
- **Property:** oracle — for any `(home, workspace, route, extra_ro)` the new backend's argv
  equals the pre-refactor `helper_argv` output (compare against a captured golden). **Rev 29 (T-W1):** the golden at
  HEAD is a hand-written frozen reference, not argv captured before the refactor, and the login `build_argv` has no
  golden variant. Required: label it "frozen reference" (not "captured"); add a login-`build_argv` variant to the
  seven-variant matrix; red for the added variant: the login argv test asserts `launch.build_argv(login_spec) ==
  FROZEN_LOGIN_ARGV` and fails with `KeyError`/missing variant today. BUILT+REGISTERED otherwise (R29.2).
- 🔴 Red: `test_backend_contract.py` asserts the `SandboxBackend` type exists and that
  `LinuxBwrapBackend.launch_spec(...)` reproduces the golden argv; red today (no such type).
- 🟢 Green: introduce the protocol + adapter with no argv change.
- 🔵 Refactor: one argv builder, no duplication between `launch.py` and `sandbox.py`.
- **Closure:** LEAF (pure argv/spec construction, platform-neutral Python; the real spawn is
  already covered by the existing Linux contract e2es, unchanged).

**Gate (MS0):** the existing Linux gate (`agent-host-unit`, `agent-host-contract`, all e2es) +
the new golden-argv test. **No macOS work.** Coordinate with **BlueBeaver** (helper/sandbox).

### R30-MS0 — Rev 30: proof fields and findings (validation ms0-3)

- **MS0.1 rule-9 fields (VERIFIED, observed at d0f1841; status BUILT+REGISTERED).** (a) entry: `launch.py` (`helper_argv`,
  `_LINUX_BACKEND`, `launch.py:97,106`), `setup.py:446-461`, `options.py:29`, `token.py:164`. (b) `agent/host/tests/test_backend_contract.py`,
  registered as `test_backend_contract` (`build.zig:3194`) and in `test` (`:3879`); run: 28/28 OK. (c) mutant: swap
  `--die-with-parent` and `--new-session` in a scratch copy → 16 failures (a mutant of the production argv builder, caught).
  The golden remains a frozen reference (T-W1).
- **MS0.2 Lifetime → C spawn policy is NOT BUILT (rule 6).** The Python `Lifetime` is a mirror of the C `ZbSpawnPolicy`, but
  every C call site hard-codes `zb_spawn_policy_linux(0)` (`app.zig:140`, `agent_helper.c:732`, `agent_login.c:324,427`,
  `agent_host.c:228`). The only test compares two constants (`test_backend_contract.py:534`): a TRIPWIRE. Required red (also
  C-W2): (a) the production spawn seam called with a backend-supplied policy that differs from Linux's (for example
  `die_with_browser = false`); (b) `tests/agent_spawn_policy_flow_test.zig` (TO BE AUTHORED), registered in the
  `test-agent-spawn` family, Linux under `unshare`; assertion: the spawned child survives its parent's death only when the
  supplied policy says so; (c) mutant: restore the hard-coded `zb_spawn_policy_linux(0)` → the child dies with the parent →
  the assertion fails; (d) none (portable).
- **Minor amendment V03-F11.** (a) No frozen golden exists for the login `build_argv` (zero "login" hits in
  `test_backend_contract.py`): the seven-variant matrix gains a login variant (T-W1, already specified). (b) `launch.py:97`
  reaches the private `_LINUX_BACKEND` and the relay/boot lines are duplicated between the chat and login branches
  (`launch.py:104` vs `:114`): folded into MS6.8 (`launch.build_launch`, I-W9). (c) The `SandboxBackend` Protocol is never
  checked (I1): see R30-MS6 for the corrected direction.

---

## MS1: Universal build + two-arch remote gate (false-green-proof) + entitlement manifest

**Goal (blockers 8, 9-part).** A universal (arm64 + x86_64) build, a two-host two-arch gate that
cannot false-green, and a tested least-privilege entitlement manifest so MS9 is small.

### Behavior MS1.1: universal fat Mach-O covering every bundled native component
**Given** both Macs reachable,
**When** each arch builds natively and the slices are combined,
**Then** **every native Mach-O the MS1 bundle ships** is present per arch and the result is a fat
Mach-O with both slices. **At MS1 the bundle ships only the browser** (`build.zig:168` installs
`zigBrowser`; the agent runtime is a separate non-default step), so MS1's fixed inventory
(`packaging/macos/universal_components.json`) is **`{browser}` with an empty `resources` list** —
"complete" means every component actually shipped, and the universal browser is a **single fat
Mach-O with no non-executable resource**. The **per-host census mechanism is general and
unchanged** (it scans the whole bundle for every Mach-O and requires each fat, fails closed on an
unprobeable file, and checks that any declared resource is present); only the MS1 inventory is
narrow. The empty state is **not a skip**: the green **calls the typed phase gate**
`mac_resource_compat.py --milestone MS1` (rev 9), and `resource_phase` (`mac_universal_test.py`)
**accepts an empty inventory only for the EXACT browser-only MS1 bundle** — milestone `MS1` + exactly
one component at the fixed browser path `bin/zigBrowser` + no resources — and **fails closed for any
other empty shape**, so MS1's exception is asserted, shape-checked and mutation-resistant — the
`--milestone` label alone is not enough (RoseCat 5995/6002). The two-tree
`resource_compat` oracle (the nonempty branch of the gate) is **first exercised at MS5** (behavior
MS5.1c), where macOS provisioning installs the Python runtime, the Claude CLI and the generated
launcher, so the non-exec runtime files exist in two per-arch trees and the Intel-3.9-vs-arm-3.14
Python mismatch is exactly what it must catch.

**Updated by MS1b (`3421428`):** since the ObjC shim ships as a dylib the exe links, the MS1 bundle
is now **`{browser, webview-shim}`** — `bin/zigBrowser` + `Frameworks/libwkwebview_shim.dylib`, both
fat. `resource_phase` accepts the empty-resources set only for that **exact two-component** shape;
the 6002 bypass protection is kept (browser-alone, wrong-shim-path, MS5-shaped, non-browser all fail
closed). The census now requires both Mach-Os fat.

### Behavior MS1.2: real two-host identity + executing-arch proof (no Rosetta false-green)
**Given** two distinct hosts,
**When** the gate runs,
**Then** it asserts the Intel host is really `x86_64` and the Apple-Silicon host **executes the
arm64 slice** (not an x86 process under Rosetta — check `sysctl.proc_translated`/
`NSBundle`/`mach` arch at runtime), and the running app records its **executing architecture in
production build info** read back over the socket; `lipo -archs` + `--version` alone do not pass.

### Behavior MS1.3: tested least-privilege entitlement manifest (release-safe seed for MS9)
**Given** the features MS2–MS8 will need,
**When** the bundle is built ad-hoc,
**Then** `packaging/macos/entitlements.plist` holds an **exact least-privilege** manifest
(network client; the specific keys the Seatbelt launcher and helper need — derived, not "whatever
it needs"), `codesign -d --entitlements -` lists exactly those, and the ad-hoc build still
verifies. The manifest is the single source MS9 signs with.
**Rev 29 (C-W9):** at HEAD the manifest has ONE key (`com.apple.security.network.client`); the "derived launcher and helper keys" are NOT derived. The bundled Claude CLI is a separate executable that may need its own entitlements under the hardened runtime — unchecked; spiked first as MS9.0 (see MS9). Until derived, the sentence "the specific keys the Seatbelt launcher and helper need" reads "none beyond network client (unverified)". **Rev 30 (bd `4pa.61`, `4pa.79`):** the Mac check is a tautology (it signs with the plist and compares the signature to the same plist) and `network.client` is an App Sandbox entitlement that has no effect without `com.apple.security.app-sandbox`; MS1.3 is a **placeholder manifest with no derived keys** and a TRIPWIRE until the probe in R30-MS1 runs.

**Updated by MS1b (`3421428`): a release least-privilege rule.** `release_least_privilege`
(`mac_universal_test.py`) FAILS a release entitlements manifest OR signed binary that carries
`com.apple.security.cs.disable-library-validation`. That key is allowed ONLY in ad-hoc dev/test
builds (a hardened dev exe loading the ad-hoc shim dylib); MS9's real Developer ID signs exe+dylib
under one team, so library validation passes without it. Unit-tested in `mac_universal_census_test`.

**MS1 runs the UNSIGNED universal binary; the MS1.3 check is static (rev 10).** The ad-hoc-signed
x86_64 binary **segfaults at startup in ObjC `-[ZBAppHost init]` (`0xf0000001`)** — a
zig-linker/codesign interaction (see rev 10 and `MS1b`). So MS1.1 (fat) and MS1.2 (executing-arch
readback, which RUNS the binary) run the **unsigned** universal binary (it is fat and runs
natively on both arches), while MS1.3 signs a **copy** and reads it with `codesign -d` only
(static; never run). **MS1 therefore does NOT prove that a signed binary RUNS** — that is the job
of the new slice **`MS1b`**, and the real production signature (Developer ID + hardened runtime) is
MS9. `mac_universal_test.py` takes `--signed-binary` for the static MS1.3 check; `gate.sh` pushes
the unsigned universal to run and the signed copy (outside the bundle) for `codesign -d`.

### Behavior MS1.4: the runner fails closed
**Given** the fail-closed conditions,
**When** a host lacks a GUI session / the expected arch / a required runtime-SDK, or a test
records zero assertions,
**Then** the gate **exits nonzero** (never SKIP-to-green), per host and per arch.

- **Files touched (Rev 29 corrected):** `build.zig` (steps `mac-gate` and `ms1b-gate`; there is NO `mac-universal` step
  and none is planned), `tests/mac/build-on-mac.sh`, `packaging/macos/entitlements.plist`,
  `packaging/macos/Info.plist`, `tests/mac/gate.sh` (two-host matrix + fail-closed),
  `tests/e2e/mac_universal_test.py`, `src/*` build-info (record executing arch).
  **`packaging/macos/build-dmg.sh` is NOT converted (K5) and is REMOVED from MS1's touched list.** Decision
  (Rev 29): the shipping-path conversion is a new slice **MS1c "convert `build-dmg.sh`"**, ordered before MS9 and
  after MS5.1c: copy `libwkwebview_shim.dylib` to `Contents/Frameworks/`, `lipo`-verify every Mach-O fat, sign inside-out
  (dylib, then exe, then `.app`, never `--deep`), and `otool -L` the exe to prove its shim reference resolves inside
  the bundle. Red (the proof is the Mac run: the MS1b workload runs on the unpacked `.app` the script produced; mutant: a `.app` missing its dylib must fail with the dyld load error; both Macs, UNPROVEN until released). The hostless static form — the staged tree contains
  `Contents/Frameworks/libwkwebview_shim.dylib` (fails today: the script copies only the exe, `:71`) and `otool -L` of the bundled exe resolves `@executable_path/../Frameworks/libwkwebview_shim.dylib` to an existing fat file — is a TRIPWIRE — not proof.
  MS1c is **NOT STARTED**; until it lands, nothing may call the `.dmg` a launch artifact.
- **Bundle == inventory (D-W3).** The MS1.1 census must also fail when the bundle contains an undeclared file or
  Mach-O. Red: add an undeclared regular file to the staged tree → `mac_universal_test.py` asserts non-zero exit with
  the file named; today it passes (the census requires every Mach-O fat and the roles to exist, not bundle ==
  inventory). Mutant: drop the undeclared-file scan → the red does not fail (must be caught).
- 🔴 Red: `mac_universal_test.py` asserts both slices exist, each component is fat, the executing
  arch matches the host, and build info reports it — red today. **Rev 31 (L5): the earlier clause "and the entitlements
  file lists the exact keys" is RETIRED** — it is the tautology R30.1 #8 and R30.2 T17 retire (a listing compared with its own
  input). Entitlements are proven only by the feature probe in R30-MS1 (`ms1_entitlement_probe.sh`, TO BE AUTHORED); any
  `codesign -d --entitlements` listing is a TRIPWIRE — not proof. 🟢 Green: per-arch build + lipo + arch-record + entitlements. 🔵 Refactor: one
  per-arch build fn shared by `gate.sh`/`build-dmg.sh`; one signing fn (ad-hoc now, Developer ID
  in MS9) selected by flag.
- **Closure:** LEAF (packaging/build-info assertions; no cross-process product behavior).

**Gate (MS1):** two-host `mac-gate`, fail-closed; Linux gate untouched. Not a UI slice.
Coordinate with **BlueBeaver** (build/gate) and **BlackRobin** (version/build-info seam).

**Zig 0.16 segfault handler disabled on macOS (rev 10).** `std.debug.cpu_context.fromPosixSignalContext`
`@alignCast`es the x86_64 macOS signal `ucontext_t` and panics "incorrect alignment", so the first
signal the browser takes aborts via a misleading panic with a corrupted unwind (it hid the real
ObjC-init fault for a whole debugging cycle). `src/main.zig` sets `std_options.enable_segfault_handler
= (os.tag != .macos AND std.debug.default_enable_segfault_handler)` — OFF on macOS only; every other
target keeps the exact default, so **the Linux build is unchanged**. This is an upstream zig-0.16
issue; disabling the handler on macOS gives honest crash reports and is kept regardless of the signing
fix. (It does NOT by itself make a signed binary run — see `MS1b`.)

### R30-MS1 — Rev 30: MS1, MS1b and MS1c findings (validation ms0-3 F5, F7, F10, F12; ms7-9 C2, M4)

- **[bd `zigBrowser-4pa.59`, V03-F5, MAJOR] Mac gates build an unpinned working tree into one shared remote directory — RED +
  FIX-FORWARD (decision R30.3 #2).** `tests/mac/build-on-mac.sh:32` tars the live working tree (uncommitted files and other
  agents' work included, errors hidden by `2>/dev/null`) to the fixed `/tmp/zb_worktree_mac.tar` and extracts over
  `$HOME/zigBrowser` without clearing it, so deleted files survive. `gate.sh`, `ms1b`, `ms2a`, `ms2b`, `ms2c` and `ms3` all share
  that path and directory. A PASS is tied to no commit, two concurrent gates clobber each other, and a stale test can give a
  false green.
  - Fix: build the tar from `git archive <sha>` into a `mktemp` file; extract into a fresh per-run remote directory
    `~/zb-gate-<sha>-<nonce>`; print the sha in the PASS line; pin `known_hosts`.
  - Red (hostless, Linux, no ssh to any real host: a stub `ssh` and `scp` on `PATH` record argv and the tar they are handed, in
    the style of `mac_compile_only_selftest.sh`). Test: `tests/mac/build_on_mac_selftest.sh` (TO BE AUTHORED), step
    `test-mac-build-script` (TO BE ADDED to `test`). Assertions, on a scratch repo with one dirty tracked file and one untracked
    file: (1) `tar -tf` of the tar handed to the stub contains no untracked file, and the dirty file's bytes equal its committed
    blob; (2) the remote directory argument matches `^~/zb-gate-[0-9a-f]{40}-[0-9a-f]+$` and differs between two runs; (3) the
    PASS line contains the 40-hex sha; (4) a failing `git archive` makes the script exit non-zero (errors are no longer
    hidden).
  - Mutants: restore `tar` of the working tree → assertion 1 fails; restore the fixed `/tmp/zb_worktree_mac.tar` → assertion 2
    fails.
  - Platform: none for the selftest. The first real use is a released Mac run (R29-SAFETY).
- **[bd `zigBrowser-4pa.77`, V79-M4, MAJOR] Release and build scripts turn host-key checking off — RED + FIX-FORWARD.**
  `packaging/macos/build-dmg.sh:21-24` and `tests/mac/build-on-mac.sh:21` use `StrictHostKeyChecking=no` and
  `UserKnownHostsFile=/dev/null`, and the dmg is copied back over that channel (`build-dmg.sh:116`). The MS7 gate and
  `mac_compile_only.sh` already use `StrictHostKeyChecking=yes`. Same selftest, extra assertions: (5) every recorded `ssh` and
  `scp` argv contains `StrictHostKeyChecking=yes`, `BatchMode=yes` and `UserKnownHostsFile=<a pinned file under tests/mac/>`;
  (6) no argv contains `StrictHostKeyChecking=no` or `UserKnownHostsFile=/dev/null`. Mutant: restore either option → the
  assertion fails.
- **[bd `zigBrowser-4pa.73`, V79-C2, CRITICAL] The release script cannot make a working or distributable app — FIX-FORWARD as
  MS1c (still NOT STARTED).** `build-dmg.sh:71` copies only the executable, so `libwkwebview_shim.dylib` never reaches
  `Contents/Frameworks`; the build is native x86_64 on the Intel host only (not universal) from an uncommitted tree; it signs
  `codesign --force --sign - --deep` (`:91`) with no entitlements and no `--options runtime`; the header still says "Build a
  signed .dmg". Until MS1c lands the header reads "ad-hoc dev dmg, not a distributable artifact".
  - Red 1 (hostless, Linux; same stub style; step `test-mac-dmg-script`, TO BE ADDED to `test`): run `build-dmg.sh` with stub
    `ssh`, `scp`, `lipo`, `codesign`, `otool` recording argv. Assertions: the staged app tree contains
    `Contents/Frameworks/libwkwebview_shim.dylib`; the source tar comes from `git archive <sha>`; the recorded `codesign`
    calls sign the dylib first, then the exe, then the `.app`, and none uses `--deep`; a release build adds
    `--options runtime` and the manifest, an ad-hoc build does not. Mutant: copy only the exe → assertion 1 fails; add `--deep`
    → the signing-order assertion fails.
  - Red 2 (Mac run, released only; both arches): the bundled exe's `otool -L` shim reference
    `@executable_path/../Frameworks/libwkwebview_shim.dylib` resolves to an existing fat file, and the MS1b workload (m9
    render, `WINCOUNT/TITLE/NAV`) runs on that exact unpacked `.app` (WC-W4). Gate: `ms1b-gate`, extended. Mutant: a `.app`
    missing its dylib must FAIL with the dyld load error.
  - Layout question (V79-M7, `4pa.80`) is settled by the MS9.0 spike BEFORE MS1c fixes the layout (R30-MS9).
- **[bd `zigBrowser-4pa.61`, V03-F7, MAJOR] MS1.3: the entitlement check cannot fail meaningfully — STATUS CORRECTION +
  UNPROVEN + RED.** `gate.sh:85` signs the copy with `packaging/macos/entitlements.plist` and `mac_universal_test.py:327-330`
  then asserts the signature equals that same plist (tautology). The one key does nothing without App Sandbox, its comment ("the
  CLI/helper reach the egress proxy") is wrong, and the header still says "Verified on Mac: NOT YET". MS1.3 is relabelled
  **"placeholder manifest, no derived keys"**; the codesign comparison is a TRIPWIRE (R30.2 T17). Exercising proof required:
  (a) the real signing path (`build-dmg.sh`/MS1c) uses the manifest; (b) `tests/mac/ms1_entitlement_probe.sh` (TO BE AUTHORED),
  step `ms1b-gate`, builds a probe that makes an outbound loopback connect, signs it with `--options runtime` WITH the key and
  WITHOUT it, and asserts the two outcomes differ — if they do not differ, the key is deleted from the manifest (assertion
  `rc_with_key != rc_without_key or key_removed`); (c) mutant: leave a key whose removal changes nothing → the assertion fails;
  (d) both Macs, released run.
- **MS1.1 bundle == inventory (V03 demo; D-W3).** The unit is driven (27 OK, observed); the Mac census is blind to an undeclared
  non-Mach-O file (demo: 0 failures). Red as specified in MS1 above, now driven through `stage_agent_runtime.sh` output so the
  tree the census scans is the production staging result (not a hand-built one).
- **MS1.4 fail-closed runner has no hermetic selftest (the Windows gate has one).** Red: `tests/mac/gate_selftest.sh` (TO BE
  AUTHORED), step `test-mac-gate-selftest` (TO BE ADDED to `test`): with stub `ssh` reporting each of {no GUI session, wrong
  arch, missing runtime/SDK, zero recorded assertions}, `gate.sh` exits non-zero, and it never prints a SKIP-to-green line
  (rule 7). Mutant: turn one of the four paths into a skip → its row fails.
- **Minor amendments.** V03-F12: correct the stale text in `gate.sh` ("push the ONE universal signed binary" at `:107` — it
  pushes the unsigned one), remove "(expected RED today)" from `ms1b_signed_gate.sh:148`, state that the PIL-host PNG routing
  was never built (see the MS1b hardened leg), and stop calling `mac_resource_compat.py` with the Linux `zig-out zig-out`
  (`gate.sh:96`). V03-F10: `zb_version_line` (`wkwebview_shim.m:2975`) passes `version` twice; red: the reply of the version
  command starts with `zigBrowser <zb version>` and does NOT equal the WebKit version; test in the MS1.2 file, step `mac-gate`;
  mutant: pass `version` twice → fails. The ABI table row is corrected below.
- **Status words for MS1 behaviours** are in the compliance table at the end of this plan: MS1.1 unit BUILT+REGISTERED, Mac
  census UNPROVEN, bundle==inventory NOT BUILT; MS1.2 BUILT-HANDRUN (UNPROVEN); MS1.3 tripwire-only (UNPROVEN); MS1.4 UNPROVEN;
  MS1b BUILT-HANDRUN, ad-hoc only (UNPROVEN); MS1c NOT STARTED.

---

## MS1b: the signed x86_64 binary runs (zig-linker / codesign / ObjC-init crash) — fix committed `3421428`; UNPROVEN (C10)

**STATUS (Rev 31, G6.1): COMMITTED, NOT CLOSED. UNPROVEN.** The fix commit `3421428` (option d) exists, but the compliance
table row C10 is UNPROVEN: `ms1b-gate` is not in `test`, no hardened leg exists, the pixel check is skipped, and the only
recorded run could not be verified. The sentence below that an ad-hoc-signed x86_64 binary "ran the m9 workload rc 0 on both
Macs" is an agent report of a 2026-10-20 run, **not reproduced** by a released run at a named commit (rule 8: SUSPECTED). The
hardened-runtime leg is **UNPROVEN** and its cited run could not be verified (see Rev 29 below).
Earlier wording (history of what was reported): the ad-hoc-signed x86_64 binary ran the m9
workload rc 0 on both Macs. **Rev 29 (P4, T-W3):** the earlier wording "ad-hoc AND hardened-runtime" is **not
reproduced by any gate**: `tests/mac/ms1b_signed_gate.sh:80-81` signs ad-hoc only, with no `--options runtime`, and the
hardened evidence lives only in scratchpad notes; the gate also skips the non-uniform render check (`:119`,
`--no-uniform-check`), so a signed build that opens a blank window passes. Required (choose one, recorded as the
plan): **add a hardened leg to `ms1b-gate`** — sign exe+dylib with `--options runtime` under one team identity (or
ad-hoc + `disable-library-validation` for dev only) and run the same workload; red: the hardened leg's `codesign -d
--verbose` output contains `flags=0x10000(runtime)` and the workload prints `WINCOUNT/TITLE/NAV` → no such leg exists
today (assertion fails on "leg not found"); AND route the PNG to the PIL host so the non-uniform check runs (red: a
blank-window fixture must fail the signed gate). Until then MS1b is called **"ad-hoc, NOT hardened"** and "MS1b is a
HARD prerequisite of MS9" is restated as "MS9.2 re-proves hardened-runtime on both arches itself".

**Cause (confirmed).** zig 0.16's self-hosted Mach-O linker emits only the classic
`LC_DYLD_INFO_ONLY` rebase scheme, never `LC_DYLD_CHAINED_FIXUPS`. On a **code-signed x86_64** binary
the classic rebases into the signed `__DATA_CONST` (which holds the ObjC metadata) are left at their
raw on-disk values, so `-[ZBAppHost init]`'s `[super init]` dereferences a garbage class/superclass
pointer (`EXC_BAD_ACCESS 0xf0000001`). arm64 dyld handles the same scheme; unsigned works. Hardened
runtime (MS9 shape) hits it too — so MS1b is a HARD prerequisite of MS9 (dependency order).

**Fix (option d).** Build the WKWebView ObjC shim (`src/wkwebview_shim.m`) with the **Apple toolchain**
(`xcrun clang -dynamiclib` → ld64 → `LC_DYLD_CHAINED_FIXUPS`) as a separate dylib, NOT compiled into
the zig exe (`build.zig` `configureMacosBackend`). Key flags: `-Wl,-fixup_chains` (REQUIRED — the
shim's two exe back-references need `-undefined dynamic_lookup`, which otherwise forces classic
fixups) and `-install_name @executable_path/../Frameworks/libwkwebview_shim.dylib` (anchored, so a
hardened process loads it with no relative-rpath rejection). The exe links the dylib and sets
`rdynamic` **macOS-only** to export the two back-ref symbols — `zb_ipc_dispatch` (`src/ipc.zig`) and
`zb_policy_decide` (`src/nav_policy.zig`) — for the dylib's dynamic_lookup. Linux/Windows build and exe
exports are unchanged. Shim surface confirmed by BlackRobin (agent-mail 6125).

**MS1 bundle reshaped to {browser + shim dylib}.** Because the exe now links the dylib, even the
UNSIGNED MS1 run ships it: `gate.sh` lipos+ships the unsigned fat dylib into `Frameworks/`;
`universal_components.json` + `resource_phase` accept the empty-resources set **only for the exact
`{bin/zigBrowser, Frameworks/libwkwebview_shim.dylib}`** two-component shape (the 6002 bypass
protection is kept — browser-alone, wrong-shim-path, MS5-shaped, non-browser all still fail closed).
The census auto-requires the dylib fat (both slices).

### Behavior MS1b.1: a signed universal binary runs the m9 workload on x86_64 — reported green, UNPROVEN (Rev 31)
**Given** the universal exe + shim dylib, both ad-hoc signed (`codesign -s - --entitlements …`),
**When** they run the m9 workload on the Intel Mac,
**Then** the page loads and `WINCOUNT`/`TITLE`/`NAV` print with no crash. 🔴 Red (`bf0a66f` →
`2f6214f` → `41882ae`, unregistered): the signed x86_64 launch SIGSEGV'd at `0xf0000001`, 3×, right
reason. 🟢 Green (`3421428`), AS REPORTED, SUSPECTED / UNPROVEN: it ran — on x86_64 AND arm64 ad-hoc; the "and hardened" leg is **UNPROVEN** (no gate signs with `--options runtime`; the cited run could not be verified). m9 render drives
`zb_policy_decide` and m9 reply-channel drives `zb_ipc_dispatch`, so both dylib→exe back-refs are
exercised through the signed build.

### Durable root-cause evidence (a diagnosis record and quoted commands, not proof of the fix; the proof is `ms1b-gate`, UNPROVEN until a released run)
Concrete evidence behind the cause + fix (so the record does not depend on ephemeral scratch):
1. **Minimal zig+ObjC repro** (a tiny zig main calling an ObjC class's `[super init]`): classic
   `LC_DYLD_INFO_ONLY`; **unsigned → rc 0; ad-hoc signed → SIGSEGV in `[super init]`** — reproduces
   the browser crash in isolation, independent of our code.
2. **Fixup-scheme inspection** (`otool -l`, `dyld_info -fixups`): the zig-linked binary has
   `LC_DYLD_INFO_ONLY` only (no `LC_DYLD_CHAINED_FIXUPS`); signing appends only `LC_CODE_SIGNATURE`
   and leaves the rebase entries into `__DATA_CONST` (where the ObjC `__objc_classlist`/`classrefs`/
   `data` sections live) at raw on-disk values → garbage class/superclass pointers.
3. **arch split:** the arm64 slice uses the same classic scheme yet signed arm64 **runs** — the fault
   is x86_64 dyld's handling of classic rebases into a signed `__DATA_CONST`.
4. **signature kind:** ad-hoc AND hardened-runtime (`--options runtime`, the MS9 shape) both crash on
   x86_64 → MS9 would hit it; MS1b is a hard MS9 prerequisite.
5. **Fix validated:** the ObjC shim built by Apple ld64 with `-Wl,-fixup_chains` has
   `LC_DYLD_CHAINED_FIXUPS`; the signed universal exe+dylib then run the m9 workload **rc 0 on both
   Macs, ad-hoc AND hardened** [Rev 31: AS REPORTED; SUSPECTED / UNPROVEN, and the hardened leg is not reproduced by any gate] (hardened needs same-team signing — MS9's Developer ID — or, for
   ad-hoc dev only, `disable-library-validation`). Options (e)/(c) were not needed.
Working notes retained in `scratchpad/ms1/CRASH_CAUSE.md` + `MS1b_INVESTIGATION.md` while they exist;
the summary above is the durable record.

**Gate (MS1b):** `tests/mac/ms1b_signed_gate.sh` (registered as `zig build ms1b-gate`) SIGNS both the
universal exe and the universal shim dylib, installs the signed pair, and runs the m9 workload +
exec-arch probe on BOTH Macs, fail-closed. Reported rc 0 on both Macs (ad-hoc) [Rev 31: SUSPECTED / UNPROVEN until a released run at a named commit]. The MS1.3 least-privilege rule
(`release_least_privilege`) fails a release manifest/binary carrying `disable-library-validation`
(ad-hoc dev/test only). Coordinated with **BlueBeaver** (build/gate) and **BlackRobin** (shim).
**Rev 29 closure caveat (WC-W4):** the MS1b closure runs a pair the TEST SCRIPT places and signs
(`~/zigBrowser-universal-signed`, `~/libwkwebview_shim-signed.dylib`), not the artifact the shipping script
(`build-dmg.sh` / MS1c) produces. Required: after MS1c, the gate unpacks the `.app` the shipping script makes and runs
the workload on that exact bundle (red: gate fed a `.app` missing its dylib must FAIL with the dyld load error;
today it cannot even be pointed at one). Classification: **BLOCKING** (signed binary crosses the dyld/codesign process
boundary). The hardened leg and the render check are specified above.

---

## MS2: WKWebView PagePort adapter + automation ABI (three gated parts, three closure maps)

**Goal (blockers 1, 2, 3; dispositions 1, 5).** Implement the automation surface on macOS with
the **same client contract and per-window FIFO semantics** as Linux, proven by **three** distinct
production chains. Native work lands with its adapter in the same part. Three separate reviewed
gates: **MS2a** (routed dom/page + eval/readiness), **MS2b** (native-input capability spike +
dialogs), **MS2c** (multi-window/popups + freeze/recovery; split crash-page presentation off if a
single red seam can't hold).

### Design
- `src/automation_macos_port.zig` (**Rev 29: this is the real name; "automation_wk_port.zig" never existed**)
  implements `PagePort` (gated `os.tag == .macos`), wired at `src/app.zig:626` beside the GTK port; its vtable
  (`:54-77`) has `evalJson, navigate, navigateWithPolicy, reload, url, title, nativeClick/Key/Text, listDialogs,
  respondDialog, listWindows, forWindow, closeWindow, recoverWindows` and **no entry for screenshot or input files**.
- `wkwebview_shim.m` gains the `zb_automation_*`/`zb_native_*` functions against WKWebView, the
  automation script in a **private `WKContentWorld`** (not `pageWorld`), and a main-thread marshal
  mirroring Linux's `auto_queue_on_gtk`/`auto_job_wait` (webkit_shim.c):
  `dispatch_async(main)` + a wait that is **bounded everywhere except the DISPATCHING phase** (Rev 29, P-W1:
  `zb_job_wait` has no deadline in DISPATCHING, `wkwebview_shim.m:1616-1618`, because completion is guaranteed by the
  already-dispatched main-queue block; the old words "bounded, deadline-guarded" overclaimed). Required red: hold the
  main queue (`ZB_DEBUG_DISPATCH_HOLD_MS`) past the deadline with a job in DISPATCHING → the assertion "waiter returns
  `timeout` and the job is ABANDONED, `live_jobs` returns to baseline" fails today (the waiter blocks).
- **Async-completion ownership contract (blocker 1), asserted per function:** every asynchronous
  Objective-C completion **copies its inputs** (no borrowed Zig memory after return), fires
  **exactly once**, and a **no-dispatch / no-write guard** prevents any effect after the waiter
  abandons on deadline (the macOS analog of the GTK generation/`auto_job` guard).

### Explicit ABI / test inventory (blockers 1, 4; rev 4 — literal export-by-export table)

> **Rev 29 (K2) — READ THIS FIRST.** `src/webkit_shim.h` at HEAD `e4f705f` has **76 exports: 44 production + 32 debug**
> (31 `zb_automation_debug_*` + `zb_drawer_debug_live_count`), not 75 (44 + 31). The table below was written as if all
> 44 production exports were implemented on macOS; **that is false for four of them**, which are marked
> **NOT STARTED** in place: `zb_screenshot_png`, `zb_set_input_files`, `zb_app_set_agent_drawer`,
> `zb_app_get_agent_drawer`. A census over the built macOS dylib (`mac_ms2a_abi_census_test.py` extended, R29-MS2)
> must assert the exported `zb_*` set equals **exactly** the promoted set (this table's IMPL rows + the three promoted
> debug seams) so the table cannot drift again. Red for the census extension: add a fake export to the shim → the
> census fails on the extra symbol (today it only checks the five superseded symbols are absent). **[Rev 30: this census is an `nm` TRIPWIRE (R30.2 T1). The proof is each promoted export driven through the real binary by its named e2e, with a stub-the-export mutant; until the MS2b and MS2c gates are registered the exports are UNPROVEN.]**

This is the **complete production ABI** — **all 76 `webkit_shim.h` exports** at HEAD `e4f705f` (pin was `ed13e5e`
in rev 4; the header is unchanged in the relevant exports),
each assigned an implementing slice, an **on-macOS status / unsupported mechanism**, and a **named
test**. "Every `webkit_shim.h` export" is now literal, not a representative subset (rev 3
blocker 4; rev 4 completeness; rev 5 corrects the config-flag mechanism).

**Unsupported mechanism (uniform, rev 4):** a seam that is **not implemented on macOS is absent
from the macOS shim at link time** — it is simply not compiled into `wkwebview_shim.m`, so any
test or caller that references it **fails to link** (a build failure = fail-closed). This is the
*exact* mechanism, and it is what resolves the rev-3 "no error channel" objection: a `void`,
count- or `bool`-returning seam cannot carry a runtime "unsupported" sentinel, but it *can* be
absent, and absence fails the build louder than any sentinel.

**Config flags have no C-ABI error channel either (rev 5 — RoseCat 5501).** The flag setters
`zb_app_set_hw_policy`/`zb_app_set_media_source` are **`void`**, their getters are bare `int`, and
`--renderer` has **no C setter at all** — so there is no `int<0 + out_err` path to return (the
rev-4 claim was not executable). The unsupported decision therefore lives **one layer up**, in a
**fallible app-level Zig validate/apply seam** (MS3.2, `src/webkit.zig` + `src/app.zig`): it
validates each flag/value **before** any void C setter is called, and for an unsupported
flag/value it **refuses** — the real binary **exits nonzero with an exact message** and never
touches the C ABI. A supported value is simply applied (the void setter and/or `WKPreferences`).
No seam silently returns zero and no config export fakes an error channel it does not have.

#### Production (non-debug) exports — 44; at HEAD 40 are implemented/superseded/unsupported as marked and 4 are NOT STARTED (rev 29)

| Export | Ret | Slice | On macOS | Named test |
|---|---|---|---|---|
| `zb_run_open` | int | MS1 | impl (launch) | `mac_universal_test` |
| `zb_app_run` | int | MS1 | impl — the `[NSApp run]` closure driver | every e2e driver (Closure A/B/C) |
| `zb_run_screenshot` | int | MS2b | impl (the m9 render capture, not the automation screenshot) | `m9_render_test.py` (rev 29: `mac_screenshot_test` does not exist) |
| `zb_version_line` | void | MS1 | impl — prints the version line. **Rev 30 (V03-F10): it passes `version` twice, so it prints the WebKit version as zigBrowser's own (`wkwebview_shim.m:2975`), and it does NOT record the executing arch; the arch is recorded by `src/automation/telemetry.zig:159`** | `mac_universal_test` (MS1.2) reads the arch from telemetry, not from this export |
| `zb_window_new` | ptr | core + MS7 | impl — window create; drawer mount point | mac render e2e + MS7 drawer e2e |
| `zb_reload` | void | MS2a | impl | MS2a.1 |
| `zb_main_invoke_sync` | int | **MS2a** | **SUPERSEDED (rev 13)** — not exported; the heap-job phase model (`dispatch_async(main_queue)` + `ZBAutoJob` + `zb_job_wait`) is the marshal + ownership. See the rev-13 amendment above | MS2a.3 async-completion ownership tests |
| `zb_policy_decide` | int | exists; MS2a consumer | impl (`nav_policy.zig`) | mac nav-policy e2e |
| `zb_ipc_dispatch` | int | exists (core) | impl (`ipc.zig`) — ping/pong (bead 8g7) | existing `m9_*` e2e |
| `zb_app_set_profile_dir` | int+err | MS3.1 | impl | `mac_profile_persist_test` |
| `zb_app_set_hw_policy` / `zb_app_get_hw_policy` | void / int | MS3.2 | **always implemented** (void setter, int getter — no error channel) but **accepted, recorded in `g_hw_policy`, NO EFFECT** (rev 29, P-W3: `wkwebview_shim.m:54,2848`); the supported/unsupported decision is upstream in the fallible Zig `webkit.applyBackendFlag` seam (rev 29 name; was "applyMacBackendFlag"), which refuses an unsupported value **before** calling the void setter | `mac_config_flags_test` (supported value applies/records; unsupported value → binary exits nonzero, exact message, setter not called) |
| `zb_app_set_media_source` / `zb_app_get_media_source` | void / int | MS3.2 | **always implemented**; `--media-source off` maps to MSE-off via `WKPreferences`/user script; any unsupported value is refused by the Zig seam before the void setter | `mac_config_flags_test` |
| `zb_app_set_agent_drawer` / `zb_app_get_agent_drawer` | void / int | MS7 | **NOT STARTED on macOS (rev 29, K2)** — absent from the shim; `src/webkit.zig:131-134` returns false off Linux/Windows ("macOS has no drawer backend yet"). Unsupported mechanism = link-time absence (the Zig call sites are `comptime`-gated off macOS) | MS7.0 export gate covers only the portable `zb_drawer_*`; the on/off seam gets its red in MS7 |
| `zb_automation_set_script` | void | MS2a | impl — private `WKContentWorld`, before first load | MS2a.2 |
| `zb_automation_eval_json` | int+out | MS2a | impl | Closure A / MS2a.1 |
| `zb_automation_navigate` / `_navigate_guarded` / `_reload` | int | MS2a | impl — navigation + per-WKNavigation success/failure (navigation_failed, no app-exit). **beforeunload is UNSUPPORTED on macOS** (MS2b.2 probe: WKWebView surfaces no beforeunload prompt to any public API): the port rejects accept/dismiss as `error.Unsupported`, and `.fail` **cannot** honor the shared DialogOpen-and-leave-prompt-open contract — a navigate away from a page with a `beforeunload` handler simply loads. A documented cross-platform divergence, pending the private-API decision | MS2a.1 |
| `zb_automation_get_url` / `_get_title` | int+out | MS2a | impl | MS2a.1 |
| `zb_automation_free` | void | MS2a | impl — allocator paired with every returned C string | allocator-pairing test (MS2a) |
| `zb_automation_loop_mark` | void | MS2a | **SUPERSEDED (rev 13; part C corrected 2026-10-20)** — not exported; on loop end `zb_auto_on_loop_ended()` sets `zb_auto_loop_ended` then DRAINS the queued main-queue poll blocks (bounded `CFRunLoopRunInMode`), each completing its own job NO_LOOP + unref so the waiter wakes at once and `live_jobs`→0 (no leak, no double-unref) | immediate-quit-cancellation test (MS2a) |
| `zb_automation_window_alive` | int | MS2a | **SUPERSEDED (rev 13)** — subsumed by `zb_automation_list_windows` (id present in the list) | MS2a window test |
| `zb_automation_window_id_at` | uint32 | **MS2a** | **SUPERSEDED (rev 13)** — subsumed by `zb_automation_list_windows` enumeration | MS2a window-registry test |
| `zb_automation_run_generation` | uint32 | **MS2a** | **SUPERSEDED (rev 13)** — not exported; the per-job state machine (`zb_job_complete` records only while DISPATCHING/INFLIGHT; `zb_job_claim_dispatch` abandon guard) replaces the generation counter | MS2a.3 late-completion test |
| `zb_automation_list_dialogs` / `_respond_dialog` | int | MS2b | impl — `WKUIDelegate` captures **alert/confirm/prompt**, held until answered; cancel-aware list/respond + dialog_open fast-fail + eval dialog-watch (36d3065; "mutant-proven both arches" is an agent report, SUSPECTED / UNPROVEN: no released Mac run at a named commit — Rev 31, rule 8). **beforeunload is NOT surfaced** — see below | MS2b.2 |
| `zb_automation_list_windows` / `_close_window` | int | MS2c | impl — page.list + health watchdog (list_windows), page.close a popup (primary refused) + forWindow (d82da2e/03a6523/9870693) | MS2c.1 |
| `zb_automation_recover_windows` | int | MS2c | **Implemented via VIEW-REPLACEMENT** (public API; no process kill, no SPI). Consent (phase 1) server-side; phase 2 swaps a fresh WKWebView into each window keeping its stable id and reloads the committed URL, emitting `[{id,url,ended,reloaded}]` (`ended`=was crashed, `reloaded`=URL restored). Pinned by `mac_ms2c_recover_test.py` | MS2c.3 |
| `zb_cookies_get_all` / `_add` / `_delete` | int | **MS3** (moved from MS2c) | impl over `WKHTTPCookieStore` (the MS3 data-store owner); MS4.4 login gate consumes | `mac_cookie_test` (MS3) |
| `zb_set_input_files` | int | MS2b | **NOT STARTED on macOS (rev 29, K2)** — not in the shim, not in the port vtable; `src/webkit.zig:2569` calls it only on the GTK path. Unsupported mechanism = link-time absence + the port returns the documented `unsupported` data. Behaviour (incl. regular-file refusal) is a future sub-slice **MS2b.3**, red-first: `dom.setInputFiles` over the socket on macOS returns the exact unsupported error today; green asserts the file list lands in `input.files` | MS2b.3 input-files test (TO BE AUTHORED: `tests/e2e/mac_ms2b_input_files_test.py`) |
| `zb_screenshot_png` | int | MS2b | **NOT STARTED on macOS (rev 29, K2)** — same as above (`src/webkit.zig:3767` GTK path only); future sub-slice **MS2b.4**, red: `page.screenshot` on macOS returns the exact unsupported error; green asserts a non-uniform PNG of the right size | MS2b.4 screenshot test (TO BE AUTHORED: `tests/e2e/mac_ms2b_screenshot_test.py`) |
| `zb_native_click` / `_key` / `_text` | int | MS2b | impl — trusted in-process NSEvent via `-[NSWindow sendEvent:]` (no post, no TCC); key/text per-pair atomic ownership + documentToken recheck (shipped) | MS2b.1 |
| `zb_native_scroll` / `_move` / `_pointer` | int | MS2b | **NOT IMPLEMENTED on macOS — synthetic-only (user decision 2026-10-20).** A CGEvent-sourced wheel has no window (WKWebView drops it) and only the first synthetic move per session reaches the page; both need the private `-[NSEvent _eventRelativeToWindow:]`. The macOS port leaves `nativeScroll`/`nativeMove` unsupported (clear error); `dom.scroll`/`dom.hover` work synthetically. Revisit later | MS2b.1 (deferred) |

> **`zb_cookies_*` moved from MS2c to MS3 (rev 4 blocker 2):** the cookie ABI is implemented by
> the slice that owns the `WKWebsiteDataStore`/`WKHTTPCookieStore` (MS3), so the inventory no
> longer gates a cookie export "via MS3's port" while sitting in a slice (MS2c) ordered *before*
> MS3. MS2c no longer lists the cookie ABI; MS4.4 is the login-gate consumer.

> **MS2a ABI amendment (rev 13, JadeBeacon 2026-10-20; RoseCat 4981d66 bucket 2):** five rows above named
> GTK-era symbols the macOS shim intentionally does **NOT** export (`zb_main_invoke_sync`,
> `zb_automation_loop_mark`, `zb_automation_window_alive`, `zb_automation_window_id_at`,
> `zb_automation_run_generation` — all absent at link time). The heap-job **phase model** supersedes them;
> the table rows are kept for provenance but marked **SUPERSEDED (rev 13)**. Replacement lifecycle:
> - **`zb_main_invoke_sync`** → the main-thread marshal is `dispatch_async(main_queue)` + a heap
>   `ZBAutoJob` (PENDING→PREFLIGHT→DISPATCHING→INFLIGHT→DONE/CANCELLED/ABANDONED) with the calling thread
>   blocked in `zb_job_wait`. Marshal + ownership in one primitive; no standalone symbol.
> - **`zb_automation_run_generation`** → the late-completion-drop / no-dispatch-after-abandon guard is the
>   per-job state machine, not a generation counter: `zb_job_complete` records the outcome ONLY while
>   DISPATCHING/INFLIGHT and otherwise frees `result`/`err`, so a completion arriving after the waiter
>   abandoned (CANCELLED/ABANDONED) writes nothing and reports nothing; `zb_job_claim_dispatch` returning
>   0 is the "waiter abandoned → never submit" guard. Driven deterministically by
>   `zb_automation_debug_live_jobs` + `zb_automation_debug_waiter_grace`.
> - **`zb_automation_loop_mark`** → replaced by an app-ended **drain** (part C; corrected 2026-10-20): a
>   stopped `[NSApp run]` can no longer run the main-queue poll blocks a readiness wait leaves queued, so
>   leaving them to "just time out" would leak each queued block's job ref (`live_jobs` stuck > 0). Instead,
>   on loop end `zb_auto_on_loop_ended()` sets an atomic `zb_auto_loop_ended` flag, then **drains** the
>   pending main-queue blocks with a bounded `CFRunLoopRunInMode` loop (while `live_jobs > 0`). Each queued
>   poll block observes the flag and finishes its own job NOW — `zb_job_claim_dispatch` → `zb_job_complete(…
>   NO_LOOP …)` → `zb_job_unref` — so the blocked waiter wakes immediately with the no-loop code and the
>   ref is released (no force-unref from outside the block, so no double-unref). `live_jobs` reaches 0
>   because the queued blocks actually run, not because waiters expire. It is called both from the real
>   quit (after `[application run]` returns) and, in e2e, from the `ZB_DEBUG_QUIT_AFTER_MS` hook that ends
>   the loop with work in flight.
> - **`zb_automation_window_alive` / `zb_automation_window_id_at`** → subsumed by
>   `zb_automation_list_windows`, the real primary/popup registry (MS2c): "alive" = the id is present in
>   the list; enumeration = the list itself. No separate symbols.
>
> MS2a.3 tests for this bucket: late-completion drop + `live_jobs` baseline; result/error-string ownership
> (every `zb_automation_free` paired exactly once, via an alloc/free-counter oracle under the e2e gate);
> immediate-quit cancellation (waiter wakes with the no-loop/timeout code, no dispatch after, `live_jobs`→0);
> and an ABI/window census that the phase-model symbols link, the five superseded symbols are intentionally
> absent, and `list_windows` enumerates the real primary/popup registry (not constants).

#### Debug seams — 32 (`zb_automation_debug_*` ×31 + `zb_drawer_debug_live_count`) — rev 29: 32, not 31

**Rev 29 (I-W6, T-W5, P-W4).** The count was off by one: `zb_automation_debug_strings_live` is exported but was not
listed. **At HEAD exactly three debug seams exist on macOS:** `zb_automation_debug_live_jobs`, `_waiter_grace`
(MS2a, listed below) and `_strings_live` (MS2a string-ownership counter; add to the MS2a row). Every other seam is
absent at link time. Debug seams are unconditional exports of the shipping dylib; required hardening: either (a) a
build option removes them from the shipping dylib, or (b) a registered test proves the env-driven hooks (`ZB_DEBUG_SYNTH_CRASH`,
`ZB_DEBUG_FORCE_PRE_MACOS14`, `ZB_DEBUG_DISPATCH_HOLD_MS`, `ZB_DEBUG_QUIT_AFTER_MS`) are inert without
`--e2e-protocol` (R29-SAFETY). An export-set census of the shipping dylib and of `rdynamic` (I-W7, R29.6) is a TRIPWIRE — not proof; the proof is that test plus the m9 render and reply workloads through the signed build, which drive both back-references (UNPROVEN until a released Mac run).

Debug seams are **test-only**. Per rev 4, a debug seam is compiled into the macOS shim **only in
the slice whose named e2e actually drives it**; every debug seam **not** promoted is **absent at
link time** (fail-closed — a referencing test/caller fails to build). No debug seam carries a
runtime "unsupported" sentinel (most are `void`/count/`bool` and have no channel); **absence is
the mechanism**, and each slice's gate records exactly which seams it promoted.

| Debug seam(s) | Promoting slice (impl) — else absent at link time | Drives |
|---|---|---|
| `zb_drawer_debug_live_count` | MS2c.5 / MS7.9 | live-drawer-count-of-zero after all windows close |
| `zb_automation_debug_live_jobs`, `_waiter_grace`, `_strings_live` (rev 29: `_strings_live` added) | MS2a | late-completion-after-timeout / abandon window |
| `zb_automation_debug_next_window_id`, `_destroy_window`, `_window_work`, `_close_on_motion`, `_close_on_key` | MS2c | deterministic ids, synthesized destroy, per-window work, close-during-input |
| `zb_automation_debug_native_guard_hold`(`_hits`), `_native_preguard`, `_native_skipped`, `_pointer_lost` | MS2b | native-input guard / abandon / pointer-cache invalidation |
| `zb_automation_debug_png_write_hold`, `_png_stopped`, `_png_deadline_stops`, `_png_ignore_abandon`, `_shot_after_measure`, `_shot_postcapture_refusals` | MS2b (only if its screenshot-abandon e2e lands on macOS) | screenshot deadline/abandon/measure |
| `zb_automation_debug_files_hold`, `_files_unmatched`(`_hits`), `_files_late_cancels`, `_files_preclick` | MS2b (only if its input-files e2e lands) | input-files timing/cancel |
| `zb_automation_debug_dialog_policy_hold`, `_dialog_policy_scheduled` | MS2b | dialog policy timing |
| `zb_automation_debug_cookie_delay`(`_hits`) | MS3 | cookie-store race |
| `zb_automation_debug_hw_policy`, `_webkit_default_hw_policy`, `_media_source` | MS3.2 (only where the flag is supported on macOS) | config-effect read-back |

### MS2a behaviors (routed commands)
- **MS2a.1** `page.navigate` + `page.url`/`page.title` over the socket (same envelope/auth/errors
  as `handleRequestWith` in automation_server.zig).
- **MS2a.2** `dom.*` via the **private** WKContentWorld; the page world cannot see or spoof the
  automation globals (**property: metamorphic** — a page that redefines `window.__zbAutomation`
  does not change the result).
- **MS2a.3** startup readiness, late completion after timeout (the guard drops it), and
  result/error-string ownership (no use-after-free; strings owned by the caller side).

### MS2b behaviors (native-input capability spike + dialogs) — red-first, both Macs (blocker 3)
- **MS2b.1 (spike)** the trusted-event matrix: `event.isTrusted` true, focus, click, key, text,
  contenteditable + `beforeinput` cancellation honored, scroll, pointer movement, navigation
  during input, partial typing, and **deadline abandonment** (no dispatch after the waiter
  leaves). **The capability table entry (automation_platform.zig:90-95) is changed only after
  this passes.**
  - **Delivery contract (rev 4 — two CGEvent uses kept distinct, blocker 4):** the spiked-first
    primary delivery is **responder-chain `NSEvent`** and, where an event type needs it, an
    **in-process CGEvent→NSEvent** construction delivered with `-[NSWindow sendEvent:]` — both
    stay **in-process with no system post and no TCC**. These are what MS2b must prove first.
  - System-wide **`CGEventPost`** (posting to the window server out-of-process) is a **different
    thing**: it is the only TCC-gated use, and it is **out of scope unless a separately approved
    capability is genuinely needed** for an event type that neither in-process path can deliver.
    If such a need is documented, its real-screen runner obtains permission and verifies its app
    is frontmost before emitting — never a silent default, and never conflated with the in-process
    paths above.
- **MS2b.2** dialogs: **alert/confirm/prompt** captured by the `WKUIDelegate` and answered via the ABI
  (analog of webkit_shim.c:4523-4625) — shipped (36d3065), held until answered, with the dialog_open
  fast-fail and the eval dialog-watch. **beforeunload is NOT captured on macOS**: WKWebView surfaces no
  beforeunload prompt to any public `WKUIDelegate` method (probed with and without a user gesture), so it
  needs private WebKit SPI — ruled out by the 2026-10-20 user decision. Consequence (a real cross-platform
  DIVERGENCE, stated honestly): a routed `page.navigate` away from a page with a `beforeunload` handler
  **proceeds and loads** on macOS; it does NOT raise the shared contract's DialogOpen-and-leave-the-prompt-open
  for `.fail`, and accept/dismiss are `error.Unsupported`. On Linux/the shared contract
  (`page_port.zig:161-165`, `router.zig:29-31`, `webkit_shim.h:204-213`) `.fail` returns DialogOpen and
  leaves the prompt open. macOS cannot honor that until the prompt is surfaceable; revisit with the
  scroll/move private-API decision.

### MS2c behaviors (multi-window / freeze / recovery) — blocker 2
- **MS2c.1** a **two-hop related-popup chain**: `window.open` twice; the popups use **WebKit's
  supplied `WKWebViewConfiguration`** (process-pool/data-store/content-world intentional); each
  gets its own `window_id`; routing a command to each proves **per-window FIFO independence**;
  the opener's URL and DOM survive both `page.close` **and** script `window.close()`.
- **MS2c.2** a **bounded responsiveness probe/watchdog** updates per-window state **without
  waiting behind that window's FIFO**; one frozen window **does not poison siblings**
  (`webViewWebContentProcessDidTerminate:` reports termination, not liveness, so a separate
  bounded probe is named). **SHOULD:** the health/list snapshot is **lock/atomic-backed** and
  **never `dispatch_sync`** to a possibly-hung main queue; no main-thread caller synchronously
  waits on the main-queue marshal.
- **MS2c.3** recovery of a **hung** WKWebView via a **named public-API mechanism**, retaining the
  two-phase consent, blast-radius acknowledgement, exactly-once queued-job cancellation, and
  "recovering" errors (`handleRecover` in automation_server.zig); **no automatic kill**. **SHOULD:** the
  spike first tries **replacing the WKWebView while retaining its `window_id`** (new view, same
  id, re-mount its drawer per MS2c.5) rather than private SPI. **If no public WKWebView API can
  recover a hung content process, MS2c stops at a documented spike** and the plan does not assume
  a reload recovers it.
  - **SPIKE FINDING (2026-10-20, a769442 chain):** phase 1 (consent) **works** on macOS — the
    responsiveness watchdog (MS2c.2) reports the frozen window, and page.recover returns the incident,
    at-risk set and expiry server-side. Phase 2 (acknowledge → the actual recover via the port's
    `recoverWindows`) is **SUPPORTED via WKWebView VIEW-REPLACEMENT** (public API; no process kill, no
    private SPI — the 2026-10-20 decision stands). `recoverByReplacingWebView` swaps a fresh WKWebView into
    the SAME window keeping its stable `window_id`/opener/process group, re-wires the navigation/UI
    delegates and the automation script handler, restarts the health watchdog, clears the crash/dialog
    state, and reloads the committed URL. Per window it reports `ended` (the window was **crashed** — its
    web process already gone) and `reloaded` (a committed URL was restored); a **frozen** window's old hung
    process is **abandoned, not killed** (`ended=false`, `reloaded=true`), which is honest — there is still
    no public web-process terminate, and view-replacement does not need one. **Rev 29 (P-W2):** nothing yet proves
    the abandoned WebContent process actually exits; required Property + red: after recover and a later `page.close`,
    the count of this app's WebContent children (by `ps -o pid,ppid`) returns to its pre-freeze baseline within a
    bound (10 s) — assertion `leaked_webcontent == 0` — today unobserved, and a mutant that retains the old view
    leaves one process (must be caught). Pinned by
    `mac_ms2c_recover_test.py` (consent + recovery + the window answering again). The consent flow and the
    crash-presentation handler (MS2c.4) are also shipped.
- **MS2c.4 (crash-presentation parity — blocker 6):** on `webViewWebContentProcessDidTerminate:`,
  the macOS shim **reports per-window termination**, shows a **static crash document** via a
  **public simulated-request** load (not a private reload), **keeps the committed URL**,
  **excludes API-driven termination** (`terminated_by_api` is not a crash), clears the `crashed`
  flag **only on a real load commit**, and **never auto-reloads** — parity with the Linux product
  (`ddc892e`, `44d0d0f`; the about:blank crash-page follow-up). Controls: a **real-crash/no-input**
  case (a genuine content-process termination, then the crash DOM + list state persist with **no
  input** for a bounded hold — rev 4 renamed from the Linux idiom "real-X", since macOS has no
  window-close "X") and a **clicked-Reload** case (recovery only on the user's click). A 3-second
  automatic-reload mutant must be **killed** by the no-input control.
  - **Rev 5 accepted substitute for the crash TRIGGER (RoseCat 6508 #5).** WebKit exposes **no
    public, safe way to terminate a specific WebContent process** (killing by PID would hit shared /
    other apps' processes; `_killWebContentProcess` is private SPI, ruled out by the 2026-10-20 user
    decision; see the MS2c.3 note at :840 that no public kill exists). The **accepted substitute** is
    the e2e-gated one-shot `ZB_DEBUG_SYNTH_CRASH` seam, which synthesizes the **public, unchanged**
    `webViewWebContentProcessDidTerminate:` callback — the identical production crash path a real kill
    would run. The two controls are then driven **for real** off that trigger: the no-input hold is a
    genuine >3 s wait with no socket input (kills the 3 s auto-reload mutant), and clicked-Reload is
    driven by `page.reload` — the **same WebKit `reloadBypassingCache`** a user's Reload click
    invokes, **not** a fresh `page.navigate`. The handler also emits a **per-window stderr diagnostic**
    (`web content process terminated: window-<id>`). Covered by `mac_ms2c_crash_recovery_controls_test.py`
    (alongside the existing `mac_ms2c_crash_test.py` synthetic seam, which is kept).
- **MS2c.5 — [Rev 29: NOT STARTED; MOVED TO MS7.9 (W3). Nothing in MS2c can be proven here because no AppKit drawer
  exists. `zb_drawer_debug_live_count` is absent from the macOS shim. MS2c's gate no longer includes MS2c.5.]**
  (drawer ownership on window destruction — blocker 5): **every popup receives its own
  drawer bound to its `window_id`** (when the drawer is on), built on WebKit's **supplied**
  `WKWebViewConfiguration`. There is **one shared destroy path** for `webViewDidClose:`, the
  NSWindow close button, and an automation `page.close`, which **detaches the drawer and frees it
  before** the automation close notification/C-struct free (detach-before-notify/free ordering).
  After **all** windows close, a **live-drawer count of zero** is asserted (the macOS analog of
  `zb_drawer_debug_live_count`, per the MS2 debug-seam decision). The opener's URL and DOM survive
  a child's destruction (ties to MS2c.1).

### Workflow Closure (three chains — blocker 1)

> **Rev 29 (WC-W1, WC-W2, A-W4):** all three maps are regenerated against HEAD `e4f705f` and cite **symbols**, not
> line numbers (`handleRequestWith`, `handleWindows`, `handleRecover`; `automation_server.zig` lines :412/:480-487/
> :686-691/:942-1106 in the text below are the stale ed13e5e numbers, now `:467`, the `handleWindows` branch at `:744`,
> `:995`). The JSON `git_commit` fields below are re-pinned to `e4f705f`; every symbol resolves there (re-checked:
> `handleRequestWith`, `handleWindows`, `handleRecover`, `handleDialogs`, `automation_macos_port.zig`, `zb_app_run`,
> `zb_automation_eval_json`, `zb_automation_get_url`, `zb_automation_navigate_guarded`, `zb_automation_list_windows`,
> `zb_automation_recover_windows`). The Closure-A node that said `src/automation_wk_port.zig` now reads
> `src/automation_macos_port.zig`. All three closures are
> **BLOCKING** (async WK edge + Zig/ObjC boundary) and are BUILT-HANDRUN via `ms2a-gate` (A) and `ms2c_gate.sh` (B, C);
> they become DONE when registered as build steps (R29-REG).

#### Closure A — ordinary routed command   [BLOCKING: Zig→ObjC boundary + async WK completion edge]
- **Chain:** `socket -> handleRequestWith -> router.parse -> queue.acquire -> engine.executeWith -> PagePort(automation_macos_port) -> wk_shim zb_automation_eval_json (dispatch to WK main) -> WKWebView effect -> zb_automation_eval_json read -> JSON-RPC result`
- **SOURCE (seed):** the page loaded via `zb_automation_navigate_guarded` (macOS, MS2a). **TRIGGER:**
  `handleRequestWith` (automation_server.zig, outermost; above `highest_new_connector =
  automation_macos_port`). **DRIVER:** the real `[NSApp run]` loop (`zb_app_run`
  wkwebview_shim.m). **OBSERVE:** `zb_automation_eval_json`. **FORBIDDEN SPAN:** router,
  queue, engine, port, adapter, shim. **RED-AT-SEAM:** with the adapter absent, `pagePort()`→null
  returns the documented `unsupported` data; the DOM-change assertion is red until MS2a lands.

```json
{
  "behavior": "An ordinary routed automation command drives the live WKWebView page and its result is observable to the client.",
  "git_commit": "e4f705f922f2059bb62782db5fdcca288709e3a2",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "loaded_page",         "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_request",      "module": "src/automation_server.zig",    "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "router_command",      "module": "src/automation/router.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "engine_execute",      "module": "src/automation/engine.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "pageport_call",       "module": "src/automation/page_port.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "wk_port_adapter",     "module": "src/automation_macos_port.zig","is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": null },
    { "id": "wk_shim_effect",      "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": null },
    { "id": "observable_readback", "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_eval_json", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": true,  "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

#### Closure B — out-of-band `page.health`/`page.list` while a sibling window's FIFO is stuck   [BLOCKING: proves the no-FIFO-turn branch + sibling isolation]
- **Chain:** `socket -> handleRequestWith -> handleWindows branch (NO queue.acquire) -> ext.listWindows / responsiveness probe (MS2c bounded watchdog) -> wk_shim per-window state -> page.health JSON read`
- **Rev 29 (WC-W2) — what "stuck" means.** The existing closure's stuck sibling is a **pending selector wait** (the
  window's FIFO is occupied), which proves FIFO independence but NOT main-queue independence. Add a second case: the
  **main queue is held** (the existing `ZB_DEBUG_DISPATCH_HOLD_MS` hook) while `page.list`/`page.health` are called;
  they must still answer from the lock-backed snapshot (no `dispatch_sync`). Red: assertion
  `health_latency_ms < 500` while the main queue is held; mutant: make the snapshot `dispatch_sync` to main → the call
  exceeds the bound (must be caught).
- **SOURCE (seed):** two loaded windows **and** a long-running routed command in flight on
  window 1 (so window 1's FIFO is occupied). **TRIGGER:** `handleRequestWith`. **DRIVER:**
  the MS2c bounded probe/watchdog + the `[NSApp run]` loop (no sleep). **OBSERVE:** `page.health`/
  `page.list` JSON for **both** windows. **FORBIDDEN SPAN:** the stuck window's FIFO/queue —
  health/list must **not** wait behind it. **RED-AT-SEAM:** if health is implemented behind the
  per-window FIFO, the stuck window makes the sibling's health time out → red; correct = both
  return promptly.

```json
{
  "behavior": "page.health/page.list answer for all windows without waiting behind a sibling window's stuck FIFO.",
  "git_commit": "e4f705f922f2059bb62782db5fdcca288709e3a2",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "two_windows_one_stuck", "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,               "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_health_request", "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,               "seedable_store": null },
    { "id": "handle_windows_branch", "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,               "seedable_store": null },
    { "id": "wk_responsiveness",     "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,               "seedable_store": null },
    { "id": "health_json",           "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": "handleWindows",    "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

#### Closure C — two-phase recover of a hung window   [BLOCKING: cross-process terminate + reload, two-phase consent]
- **Chain:** `socket -> handleRecover (NO queue turn) -> phase1 issue incident token -> phase2 consume + beginRecovery (exactly-once cancel) + recoverWindows -> wk_shim VIEW-REPLACEMENT (recoverByReplacingWebView: a fresh WKWebView swapped into the same window id, hung process abandoned not killed — rev 29, WC-W1; NOT "terminate+reload") -> page.health/page.url read`
- **SOURCE (seed):** a frozen window + its process family. **TRIGGER:** `handleRecover`.
  **DRIVER:** the `[NSApp run]` loop + the bounded probe. **OBSERVE:** post-recover `page.url`/
  `page.health`. **FORBIDDEN SPAN:** the recover state machine, the terminate/reload. **RED-AT-
  SEAM:** a wrong incident token / stale blast-radius ack must return `unknown`/`mismatch`
  (`handleRecover`, unknown/mismatch branches); an automatic kill (no consent) must be **absent**. If no public
  API recovers a hung process, this closure is **not green** and MS2c stops at a spike.

```json
{
  "behavior": "A hung WKWebView window is recovered only via two-phase consent, with exactly-once job cancellation and no automatic kill.",
  "git_commit": "e4f705f922f2059bb62782db5fdcca288709e3a2",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "frozen_window",     "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                  "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_recover",    "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                  "seedable_store": null },
    { "id": "recover_statemach", "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                  "seedable_store": null },
    { "id": "wk_view_replacement","module": "src/wkwebview_shim.m",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                  "seedable_store": null },
    { "id": "post_recover_read", "module": "src/wkwebview_shim.m",      "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_get_url","seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" }
  ]
}
```

> Each map's `read_path`/`seedable_store`/`driver` resolves at ed13e5e (the macOS impls are
> added by MS2; `handleWindows`/`handleRecover`/`zb_app_run`/`zb_automation_*` resolve now). All
> three e2es start at the authenticated socket and observe through production reads; **none** call
> the WK port or shim directly (FORBIDDEN SPAN).

**Gate (MS2):** three gates (MS2a/b/c), each a real-binary macOS e2e on both arches. MS2b gets a
real-screen confirmation that a native click visibly actuates the page (orchestrator-run).
Coordinate with **BlackRobin** (shim/ABI) and **BlueBeaver** (port/engine).

**R29-MS2 amendments (K2, W4, T-W5, P-W1/P-W2, WC-W1/WC-W2, A-W2, A-W5, D-W6, I-W6/I-W7):**
- **Status:** MS2a.1-3 BUILT-HANDRUN (`ms2a-gate` is a build step but not in `test`); MS2b.1/2b.2 and MS2c.1-4
  BUILT-HANDRUN via hand-run `ms2b_gate.sh`/`ms2c_gate.sh` (no build step); MS2c.5 NOT STARTED (moved to MS7.9);
  screenshot and input-files NOT STARTED (new sub-slices MS2b.3/MS2b.4).
- **Registration:** add `ms2b-gate` and `ms2c-gate` build steps (Mac-only, not depended on by `test`; Rev 30 V03-F9) and a manifest of
  the last approved run each (R29-REG). A slice with no registered step is not DONE.
- **ABI census** extended to assert the exported `zb_*` set equals the promoted set (R29.1(b)) (TRIPWIRE — not proof; each promoted export is proven by its named e2e driving it through the real binary with a stub-the-export mutant, UNPROVEN until the `ms2b-gate`/`ms2c-gate` steps and a released Mac run exist).
- **Client contract on macOS:** "macOS differences" docs section and the distinct reason `beforeunload_unsupported`
  (R29-DOCS); the capability table is derived from the vtable (R29-CAP).
- **State invariants (D-W6):** window state is spread across `terminatedReason`, `pendingDialogKind` and the health
  fields. Add a registered invariant test over the shim census: `crashed ⇒ !recovering`, `pendingDialog ⇒ !crashed`,
  never two terminal reasons. Red: drive the debug crash seam during a held dialog and assert the invariant; record
  any violation as a defect. No defect found by the review; this is a tripwire.
- **Per-behaviour Given/When/Then, named red, Property and class:** see the Behavior specification ledger (MS2a.1-3,
  MS2b.1-2, MS2c.1-5).

### R30-MS2 — Rev 30: MS2a/b/c findings (validation ms0-3 F1, F3, F4, F8, F13, F14, F18, F19; AUTHORITATIVE)

All Mac reds below follow R29-SAFETY: recorded at the compile-only tier, or on a Mac only with RoseCat exact-commit approval
AND an orchestrator release. The production entry point of every one of them is the real macOS binary driven over the
authenticated automation socket (or the user-visible delegate/close path named in the row).

- **[bd `zigBrowser-4pa.55`, V03-F1, CRITICAL] The macOS browser QUITS on a failed page-initiated or recovered load — RED +
  FIX-FORWARD (owning slices MS2c and MS3; decision R30.3 #1).**
  - Cause (read): `wkwebview_shim.m:781-790` calls `requestExit:ZB_EXIT_LOAD_FAILED` (closing every window) for every load
    failure that is not a tagged automation navigation. That covers a link the user clicks to a dead host, a page's own
    `location=`, a response the navigation-response policy refuses to show (`decidePolicyForNavigationResponse` → cancel,
    `:848`; e.g. a `Content-Disposition: attachment` download response) and any policy-opened
    subwindow load. `loadURI:` (`:515-532`) arms a 15 s timer whose expiry also exits (`:629`), and
    `recoverByReplacingWebView` reloads through `loadURI:` (`:753`), so a recovered window on a slow or down server ends the
    session. Linux does not do this: its `on_window_load_failed` (`webkit_shim.c:1065-1106`) records the error and keeps
    running.
  - **`tests/e2e/mac_ms2a_user_nav_failure_test.py` asserts the exit as correct, so it encodes the defect.** It is REWRITTEN in
    the commit that fixes the shim. This does not weaken a gate: the old assertion is the bug, and "the browser stays alive" is
    the stronger, correct assertion.
  - (a) Entry points: the macOS binary; `page.evaluate` clicking a link or setting `location`; `page.navigate`; `page.recover`.
    (b) Tests: `tests/e2e/mac_ms2a_user_nav_failure_test.py` (rewritten) and `tests/e2e/mac_ms2c_recover_slow_server_test.py`
    (TO BE AUTHORED); steps `ms2a-gate` and `ms2c-gate` (the second TO BE ADDED, see `4pa.62` below).
  - Reds, exact failing assertions today: (1) after the primary window's first finish, a click on a link to a dead host:
    `assert proc.poll() is None and page_list_answers()` (today the process has exited with `ZB_EXIT_LOAD_FAILED`) and
    `assert load_fail_events == 1`; (2) a page script sets `location` to a dead host: the same assertion; (3) a response the
    policy refuses to show (an `attachment` response; erratum 2026-10-22: a literal "policy cancel" cannot be driven from a
    test, and the reviewer's cd515ce minimum requires exactly one `LOAD_FAIL` row for that load, so the row proves the
    failure handler ran): the same assertion; (4) `page.recover` on a window whose server stays down for 20 s (longer than the 15 s
    timer): `assert proc.poll() is None` at t = 20 s; (5) the kept contract: the primary window's INITIAL load of a dead host,
    before its first finish, still exits `assert rc == ZB_EXIT_LOAD_FAILED` (flips if the owner picks option B).
  - (c) Mutants, each must fail its row: restore `requestExit` on the post-first-finish failure path → rows 1-3 fail; leave the
    `loadURI:` exit timer armed for a recovery reload → row 4 fails; make the initial-load failure not exit → row 5 fails.
  - (d) Platform: both Macs. Fix: exit only for the primary window's initial load and only until its first finish; afterwards
    record the failure and emit `LOAD_FAIL` without exiting; recovery reloads use the tagged/routed path with no exit timer.
- **[bd `zigBrowser-4pa.57`, V03-F3, MAJOR] `page.dialogs` reports the wrong window id after a popup closes — RED +
  FIX-FORWARD (MS2b.2).** `zb_automation_list_dialogs` emits `"window": idx+1`, the registry position (`wkwebview_shim.m:1768`),
  but `zb_automation_respond_dialog` looks windows up by their stable `windowId` (`:1200-1209`), as `list_windows` and the GTK
  code do (`webkit_shim.c:4607-4608` uses `win->auto_id`). After popup 2 closes, a dialog in popup 3 is listed as window 2 and
  answering it returns NO_DIALOG or answers the wrong window. No test covers a dialog in a later popup.
  - Red: `tests/e2e/mac_ms2b_dialog_popup_id_test.py` (TO BE AUTHORED), step `ms2b-gate` (TO BE ADDED). Open two popups, close the
    first, raise a `confirm` in the second. Assertions: `listed["window"] == page_list_ids[1]` and
    `respond_dialog(listed["window"], accept) == ok` and the page's `confirm()` returns true. Fails today.
  - Mutant: restore `idx+1` → the first assertion fails. Platform: both Macs. Fix: emit `@(h.windowId)`.
- **[bd `zigBrowser-4pa.58`, V03-F4, MAJOR] The native close button leaves a live, registered window — RED + FIX-FORWARD as new
  sub-slice MS2c.6 (the half of MS2c.5 that needs no drawer; decision R30.3 #3).** Windows are created with
  `NSWindowStyleMaskClosable` (`wkwebview_shim.m:473`) but `ZBWindowHost` is not an `NSWindowDelegate` and nothing handles
  `windowWillClose:`. The red button hides the NSWindow; the WKWebView keeps running, stays in `app.windows`, still appears in
  `page.list` and still accepts automation. `applicationShouldTerminateAfterLastWindowClosed` returns NO (`:354-357`) and there
  is no main menu (zero `NSMenu` uses).
  - **MS2c.6 [BLOCKING — a native window event must reach the automation registry]:** Given a popup opened by `window.open`; When
    the NSWindow is closed through its close control; Then the window leaves `page.list`, a command routed to its id fails with
    the window-gone error, `live_jobs` returns to baseline, the opener's URL and DOM survive, and the same destroy path as
    `webViewDidClose:` ran (`:878-888`).
  - Red: `tests/e2e/mac_ms2c_close_button_test.py` (TO BE AUTHORED), step `ms2c-gate` (TO BE ADDED). The e2e-only seam calls
    `-[NSWindow performClose:]`, which goes through the same delegate path as the red button. Assertions: `popup_id not in
    page_list_ids()`, `routed_command_error == "no_window"` (erratum 2026-10-22: the code's window-gone reason is `no_window`,
    `automation_server.zig`), `live_jobs() == baseline`. Fails today (the id stays listed).
  - Mutant: remove the `windowWillClose:` handler → the id stays listed. Platform: both Macs. Primary-window behaviour waits on
    decision R30.3 #3.
- **[bd `zigBrowser-4pa.62`, V03-F8, MAJOR] MS2/MS3 runtime is not exercised by `zig build test`; three gates have no build
  step — STATUS CORRECTION (R30.1 #11) + FIX-FORWARD.** None of the 50 `tests/e2e/mac_ms2*`, `mac_profile*`, `mac_cookie`,
  `mac_config_flags` files is referenced in `build.zig`. Only `ms2a-gate` is a step (Mac-only). `ms2b_gate.sh`, `ms2c_gate.sh`
  and `ms3_gate.sh` are hand-run; the `.m` file is never compiled on Linux (`cross-check` compiles the Zig side only); the pure
  parsers in `automation_macos_port.zig` have no tests; the cookie port's two Zig tests always `SkipZigTest` off a Mac
  (`automation_macos_cookie_port.zig:131-145`); no approved-run manifest exists for any Mac gate.
  - Fix-forward: (i) add Mac-only build steps `ms2b-gate`, `ms2c-gate`, `ms3-gate` and a committed manifest of the last approved
    run for each (R29-REG); (ii) move `parseRecovered`, `mapCode`, `parseWindows`, `parseDialogs` (identical or comment-only
    differences between the GTK and macOS ports, V03-F14) into one shared module `src/automation_port_parse.zig`.
  - Red (Linux, registered in `test`): `tests/automation_port_parse_test.zig` (TO BE AUTHORED) feeds the exact JSON strings the C
    ABI emits (taken from the Mac e2e transcripts) to the shared parsers. Assertions: `parseWindows(sample).len == 2` with the
    stable ids; `parseDialogs(sample)[0].window == 7`; `mapCode(-3) == error.Timeout`; an embedded NUL in a URL is refused with
    `error.BadArgs` (V03-F19). Compile failure today (the module does not exist). Mutant: change one id field name in the
    parser → the assertions fail.
  - A slice with no registered step is BUILT-HANDRUN, not DONE; the status words in the compliance table already reflect that.
- **Minor amendments.**
  - V03-F13: `mac_ms2a_hook_inert_test.py` covers 4 of the 13 `ZB_DEBUG_*` hooks (all 13 share
    `zb_auto_test_hooks_enabled()`, but `--e2e-protocol` is a public flag). Red: extend it to all 13 (assertion per hook:
    behaviour unchanged without `--e2e-protocol`); mutant: make one hook unconditional → that row fails (R30.2 T15).
  - V03-F14: the duplicated port code is the shared module above.
  - V03-F18: every popup calls `makeKeyAndOrderFront` and `activateIgnoringOtherApps:YES` (`:387-388`, deprecated on macOS 14),
    stealing focus. Red: `tests/e2e/mac_ms2c_popup_no_focus_steal_test.py` (TO BE AUTHORED): with another app frontmost, an
    automation-opened popup leaves `NSWorkspace.frontmostApplication` unchanged; mutant: restore the activation → fails. Both Macs.
  - V03-F19: refuse an embedded NUL before the ABI (`automation_macos_port.zig:103`, cookie port `:90-97`), as `respondDialog`
    already does (`:236`); the red is in the shared-parser test above.
  - Checked and sound (no change): the job state machine (`:1464-1645`), the loop-end drain (`:2855-2860`), the lock-backed
    window snapshot (`:1821-1880`), stable window ids, the routed-nav identity tagging, the comptime-slice executing-arch proof.

---

## MS3: Config & persistence on macOS (blocker 4 — persistence/config half)

**Goal.** An isolated persistent data store and a decided meaning for the config flags, so logins
and cookies do not fall into an implicit global store and the flags are not silent no-ops.

### Behavior MS3.1: an isolated persistent `WKWebsiteDataStore` bound to the profile
**Given** `--profile-dir <dir>` (today discarded off Linux, app.zig:160-166),
**When** the WKWebView build launches,
**Then** cookies/localStorage/logins persist to a **profile-scoped** `WKWebsiteDataStore` (not the
default global store), isolated per profile, surviving restart — the macOS analog of the Linux
persistent context (verified by a login→restart→still-logged-in e2e over the socket).

- **USER DECISION (2026-10-20) — profile isolation mechanism + minimum.** The minimum stays **macOS 13**.
  WKWebView has **no public API** to persist a data store at an arbitrary `--profile-dir` filesystem path
  (the `WKWebsiteDataStoreConfiguration` directory properties are `_`-prefixed SPI, ruled out). So on
  **macOS 14+** `--profile-dir` maps to `+[WKWebsiteDataStore dataStoreForIdentifier:]` with a **UUID
  derived deterministically from the path** — isolated and persistent per profile (the path is the
  identity seed; the store lives in WebKit's managed location, not literally at the path). On **macOS 13**
  it **falls back to the default persistent store, shared by all profiles**, printing **one clear stderr
  line** that profile isolation needs macOS 14 and recorded in the capability table (below). Both paths are
  tested on the macOS-15 hosts via an **injectable availability seam** (`ZB_DEBUG_FORCE_PRE_MACOS14`,
  e2e-gated) so the 13 fallback is reachable, and mutant-proven **(SUSPECTED — no released Mac run is recorded in this plan; UNPROVEN until one is; Rev 32, G6.5)**. Implemented in `ddf29eb`'s successor:
  `zb_app_set_profile_dir` (wkwebview_shim.m) + `app.zig applyProfileDir` macOS branch;
  `mac_profile_persist_test.py`.

| Capability | macOS support |
|---|---|
| `--profile-dir` per-profile **isolated** persistence | macOS **14+** (dataStoreForIdentifier). On macOS **13**, `--profile-dir` is accepted but **shares the default store** (no isolation); a stderr line says so. |

### Behavior MS3.2: decided macOS semantics via a fallible Zig validate/apply seam (rev 5 — RoseCat 5501)
**Given** the Linux-only flag apply path (`webkit.zig:47-72`) and that the C setters are **`void`**
(`zb_app_set_hw_policy`/`zb_app_set_media_source`), their getters bare `int`, and `--renderer` has
**no C setter at all**,
**When** a flag is passed on macOS,
**Then** a **named fallible app-level Zig seam — [Rev 29: the real name is `webkit.applyBackendFlag(comptime os, flag,
value) error{UnsupportedFlag}!void` in `src/webkit.zig:40`, deciding through `backend_flag.backendFlagDecision`
(`src/backend_flag.zig:31`); "applyMacBackendFlag" never existed], called from the arg-apply path in `src/app.zig`** — decides each flag/value
**before** any void C setter runs:
- a **supported** value is **applied** (it calls the void C setter and/or sets `WKPreferences`),
  e.g. `--media-source off` → MSE off via `WKPreferences`/a user script (mirrors the
  Instagram-deadlock rationale, media_config.zig:6-12), and `--hardware-acceleration <v>` →
  `zb_app_set_hw_policy(policy)` **which only RECORDS the value in `g_hw_policy` — "accepted, recorded, NO EFFECT"
  (Rev 29, P-W3). The earlier promise of "a single observable effect" for this flag is withdrawn;** the single
  observable effect asserted for it is the read-back (`zb_app_get_hw_policy` / a debug read), not rendering behaviour;
- an **unsupported** flag/value makes the seam **return an error**; `app.zig` prints an **exact
  message** (e.g. `zigBrowser: --renderer=<v> is not supported on macOS`) and the **real binary
  exits nonzero**, **without** calling the void C setter — never a silent accept.

`--renderer` is handled **entirely** by this Zig seam (there is no C ABI to reach): a recognized
value maps to its documented WKWebView behavior, any other value is refused as above. This is the
rev-5 fix for RoseCat 5501: the error channel is the fallible Zig seam, not a non-existent
`out_err` on a void C setter.

- **Test (`mac_config_flags_test.py`, named in the ABI table):** (a) a **supported** value applies
  and the single observable effect is asserted over the socket; (b) an **unsupported** value makes
  the **real binary exit nonzero with the exact message** and apply nothing (the void C setter is
  not reached — proven by a debug read showing the policy unchanged). A mutant that applies before
  validating, or swallows the error to exit zero, turns (b) red. **Rev 29 (T-W4): `mac_config_flags_test.py` at HEAD
  lacks BOTH the before-validate mutant and the "policy unchanged" read the paragraph promises.** Required reds:
  (i) the "policy unchanged" read — `zb_automation_debug_hw_policy` is not promoted on macOS, so MS3.2 promotes
  `zb_automation_debug_hw_policy`/`_media_source` (they are on the debug-seam table "only where supported");
  assertion `get_hw_policy() == default` after the refused run — fails today with "no read-back seam"; (ii) the
  apply-before-validate mutant (swap the two calls) must turn (b) red.
- **Property (T2) — flag/value domain.** `backendFlagDecision(os, flag, value)` is total over
  `flag ∈ {--renderer, --hardware-acceleration, --media-source, --profile-dir}` × `value ∈ {accepted spellings ∪ random
  ASCII strings (length 0-64) ∪ embedded NUL/UTF-8}`: for all inputs the result is `apply` or `refuse`, never a panic,
  and `refuse ⇒ the void setter is not called` (model: a recording sink). Registered Zig test in `backend_flag.zig`.
- **Property (T2) — path → store UUID (D-W2).** For any path string `p`: `uuid(p)` is deterministic; identical spelling
  ⇒ identical UUID; the UUID is a v4-shaped value derived from `sha256(normalized p)[0..16]` with version/variant bits
  set; relative-vs-absolute spelling are the only tested distinct pair today. **Documented decision:** a trailing
  slash and `.`/`..` segments are normalized before hashing (red: `/a/b` and `/a/b/` map to the same UUID; today they
  may differ); a symlink and its target are **different identities** (documented, not canonicalized) with a test that
  pins it. Domain: random path strings of length 1-256 from a path alphabet.

### Behavior MS3.3: the cookie ABI + `CookiePort` over `WKHTTPCookieStore` (moved here in rev 4)
**Given** the profile-scoped `WKWebsiteDataStore` MS3.1 builds,
**When** `zb_cookies_get_all`/`_add`/`_delete` are called,
**Then** they operate on **that store's `WKHTTPCookieStore`** with the same contract as the GTK
cookie port. `src/automation_macos_cookie_port.zig` (Rev 29: the real name, wired `src/app.zig:627`; the
`automation_wk_cookie_port` spelling here and in the files list was wrong, and the MS4.4 spelling was right)
(gated `os.tag == .macos`) implements `CookiePort` over it. The cookie ABI lives **here** (the data-store owner), not in MS2c — this is
the rev-4 fix for the dependency-order contradiction (MS2c was ordered before MS3 yet claimed the
cookie ABI "via MS3's port"). MS4.4 is the login-gate **consumer** of this port, not its builder.

- **Files touched:** `src/webkit.zig` (macOS apply path), `src/wkwebview_shim.m` (data store +
  settings + `zb_cookies_*` over `WKHTTPCookieStore`), `src/automation_macos_cookie_port.zig` (built; moved from MS4), `src/app.zig` (`--profile-dir` on macOS), `tests/e2e/mac_profile_persist_test.py`,
  `tests/e2e/mac_config_flags_test.py`, `tests/e2e/mac_cookie_test.py`.
- **Closure:** MS3.1 is **BLOCKING** (persistence across a restart crosses the process-lifetime
  boundary) — SOURCE = a logged-in profile dir; TRIGGER = relaunch (production entrypoint); OBSERVE
  = cookie/login present via `page.evaluate` over the socket; driver = the real relaunch. MS3.2 is
  LEAF per flag (config apply + a single observable effect). MS3.3 is **BLOCKING** (the cookie
  value crosses the Zig↔WKHTTPCookieStore async boundary) — SOURCE = a cookie seeded through the
  port; OBSERVE = `document.cookie` via `page.evaluate` over the socket.

**Gate (MS3):** real-binary macOS persistence + config + cookie e2e, both arches. Not a UI slice. **Rev 29:** MS3 is BUILT-HANDRUN via `tests/mac/ms3_gate.sh` (no build step); it becomes DONE when an `ms3-gate` step with a last-approved-run manifest is registered (R29-REG). `ZB_DEBUG_FORCE_PRE_MACOS14` is honoured in the shipping binary whenever `--e2e-protocol` is passed and silently removes profile isolation: see R29-SAFETY (P-W4).
Coordinate with **BlueBeaver** (engine/config/cookie port) and **BlackRobin** (shim data store).

### R30-MS3 — Rev 30: MS3 findings (validation ms0-3 F2, F6, F15, F16, F17; AUTHORITATIVE)

- **[bd `zigBrowser-4pa.56`, V03-F2, MAJOR] Cookie calls block forever if WebKit never answers — RED + FIX-FORWARD (MS3.3).**
  `zb_cookies_get_all`, `_add` and `_delete` claim the job (DISPATCHING) and issue an async `WKHTTPCookieStore` call
  (`wkwebview_shim.m:2021,2078,2102`) but never call `zb_job_inflight`. In DISPATCHING `zb_job_wait` has no deadline
  (`:1615-1618`), so the caller's `timeout_ms` is ignored for the whole round trip and a wedged network process hangs the
  server thread. Every other async op (eval `:2327`, nav `:2181`, click `:2410`) does call it.
  - (a) Entry: `cookies.get_all` / `cookies.add` / `cookies.delete` over the socket. (b) `tests/e2e/mac_cookie_timeout_test.py`
    (TO BE AUTHORED), step `ms3-gate` (TO BE ADDED); it promotes the debug seam `zb_automation_debug_cookie_delay` listed in the
    MS3 row of the debug table. Assertions: with the seam delaying the store callback 3000 ms and `timeout_ms = 500`,
    `reply.error.reason == "timeout"` and `elapsed_ms < 1500`; afterwards `live_jobs() == baseline` and no late write is
    recorded. Fails today (the call returns after ~3000 ms with data).
  - (c) Mutant: delete the `zb_job_inflight(job)` call after one submit → that op blocks past 3000 ms → fails. (d) Both Macs.
    Fix: call `zb_job_inflight(job)` right after each async submit.
- **[bd `zigBrowser-4pa.60`, V03-F6, MAJOR] On macOS the daily-cap (pacing) state never persists for a new `--profile-dir` — RED +
  FIX-FORWARD (MS3.1).** macOS `applyProfileDir` creates no directory (`app.zig:497-507`; the shim says "No directory is
  created", `wkwebview_shim.m:2796`). The pacing store writes `<profile>/automation-pacing.json` with
  `atomic_file.replaceJson`, which does not create parents (`src/atomic_file.zig:9-33`), so for a fresh `--profile-dir` every save
  fails and the social/X daily caps reset on each restart. Linux creates the directory.
  - Red 1 (Linux, registered in `test`): `tests/app_profile_dir_macos_test.zig` (TO BE AUTHORED) calls the macOS branch of
    `applyProfileDir` with a not-yet-existing temp path; assertion: the directory exists afterwards. Fails today. Mutant: remove
    the `makePath` → fails. (d) none.
  - Red 2 (Mac, `ms3-gate`): start with a fresh `--profile-dir`, record one capped action, restart on the same directory;
    assertion `actions_today == 1`. Mutant: skip `makePath` → `actions_today == 0`. Both Macs, released run.
  - Fix: `makePath` the profile directory on macOS too (harmless beside the WebKit-managed store).
- **Minor amendments.** V03-F15 (SUSPECTED → UNPROVEN): `--media-source off` on macOS 14+ clears only `MediaSource` and
  `WebKitMediaSource` (`wkwebview_shim.m:504-511`) and may leave `ManagedMediaSource`; `ZIGBROWSER_MEDIA_SOURCE` is also ignored
  on macOS. Red: a row in `mac_config_flags_test.py`: with `--media-source off`, `typeof ManagedMediaSource === 'undefined'`;
  mutant: the current script → fails if the type exists. Both Macs. V03-F16: document that deleting the `--profile-dir` folder
  does not delete the WebKit-managed store (the UUID is derived from the path); replace `CLOCK_REALTIME` in
  `pthread_cond_timedwait` (`:1595-1598`) with a monotonic clock so a wall-clock jump cannot stretch or shorten every ABI
  timeout; proof stays UNPROVEN until a Mac run. V03-F17: correct the stale comments (the port header at
  `automation_macos_port.zig:10-14` says windows, dialogs and native input keep unsupported defaults, but they are wired; the shim
  says "a dispatch_semaphore" at `:1196` but uses pthread jobs) and the stale "RED (unregistered)" headers of
  `mac_config_flags_test.py:2`, `mac_cookie_test.py:2`, `mac_profile_persist_test.py:2` (T-W6).

---

## MS4: Site-flow parity + the approval grant contract (blocker 7 — approval half)

**Goal.** Flows behave as on Linux, and the **approval grant authority** is fully specified before
any committing flow, since no production approval exists at the pin.

### R29-MS4 — MS4 REWRITTEN TO THE REAL MODEL (Rev 29; K3, D1, W5, C-W3; bd `4pa.20`; AUTHORITATIVE over everything else in MS4)

**What HEAD actually has (the plan below it described a different design).**
- **Approval is a card, not a broker grant.** `src/agent_approval.zig`: `pub const Outcome = enum { waiting, approved,
  denied, expired, cancelled }` (`:188`), `card_ttl_ms = 120_000` (`:181`), `Cards.approve(id)` (`:279`) and
  `Cards.deny(id)` win **only while the card is `waiting` and its time is not up**. The only native minters are
  `zb_agent_tools_approve`/`_deny` (`src/agent_tools.zig:200,206`), compiled in both macOS builds by MS8.0 [Rev 30, `4pa.75`: inert there, they always return 0] and called
  today **only by the GTK drawer** (`agent_drawer.c:1218,1228`). There is **no** `agent_broker.mint` /
  `on_approve_clicked`, **no** sha256 tuple, `account` or `target_fp` in `src/agent_broker.zig`.
- **Revalidation is in-ticket, in the engine.** `engine.WindowWant { origin, url, load_serial }` and
  `engine.windowRefusal` (`src/automation/engine.zig`, ~`:1215-1236`) refuse **inside the run's own FIFO ticket**, in
  one fixed order: a dialog (-32013), then -32015 `expectation_mismatch` with reason `crashed`, `origin_changed`,
  `url_changed`, `load_serial_changed`. This is the drawer plan's D10 (`…drawer-tdd-plan.md` "D10. The approval
  invariant", S8 decisions 2, 9, 14). `options.expect` (`router.zig` `Expect`, `:54-58`, parser `~:560-575`) accepts
  **only** `{origin, load_serial}`; any other key is `BadArgs`.
- **`account` and the target are guarded elsewhere, and that is the decision.** The account, recipient, document token
  and element token are bound into the card's digest (D10) and re-checked by the platform-neutral `options.guard` in
  `automation.js` **before every page-visible step of every mutation, in the action's own task** (S8 decision 14),
  which on macOS runs in the private `WKContentWorld` (MS2a.2). So `options.expect` has **no `account` carrier by
  design** (C-W3 answered): "the main defence against a same-document account switch" is `options.guard`, not
  `options.expect`. The `options.expect = {account, target_fp}` text in the old MS4.1 is **withdrawn**. **[Rev 30, bd `4pa.64`: the digest and `options.guard` binding described in this paragraph is NOT in the code. Cards carry no digest, and broker phaseA replaces the call's `options` with `{expect}`, dropping `guard`. Until fixed, raw-DOM cards are bound only to origin and `load_serial`. See R30-MS4.]**
- **`recovering` is NOT checked by `windowRefusal`.** It is excluded elsewhere: `beginRecovery` cancels queued jobs
  exactly once and `handleRecover` returns "recovering" errors to commands for that window. Required (answers "state
  whether `recovering` is checked"): a named red that an approved card whose window enters `recovering` before its run
  dispatches commits **0** (assertion `commit_count == 0` and the error reason is `recovering`).

**The grant as a typed value (D1).** The plan's "grant" is specified as ONE tagged union whose states are the only
states; the forbidden combinations are unrepresentable. HEAD's `Outcome` is the card half; the plan states the full
type so MS4/MS7/MS8 test against it and so any gap in HEAD's type is a named red, not a surprise:

```
Tuple   = struct { tool, window_id, origin, account, card_load_serial, target, normalized_args, digest: [32]u8 }
Grant   = union(enum) {
    minted:  struct { tuple: Tuple, expires_at_ms: u64 },        // approved, unconsumed, before expiry
    used:    struct { tuple: Tuple, used_at_ms: u64 },           // consumed by exactly one dispatch
    revoked: struct { tuple: Tuple, reason: RevokeReason },      // navigation / crash / dialog / recover / window-close
    expired: struct { tuple: Tuple },                            // 120 s passed unused
}
// transitions (total function over (Grant, Event)):
//   minted --dispatch--> used ; minted --mismatch/close/crash--> revoked ; minted --clock>=expires--> expired
//   used, revoked, expired are terminal; every other (state, event) pair is a no-op that returns refuse.
// Mapping at HEAD: waiting=(pre-mint card), approved = minted (+ used when a dispatch consumed it), denied/cancelled
// = no grant minted, expired = expired. "used" is the one state HEAD's Outcome may not model: if the broker has no
// consumed marker, the single-use property is a RED (below) and the fix belongs to the drawer-plan owner, not macOS.
```

Forbidden states that this type makes unrepresentable (and that the property test below proves unreachable): *used and
expired at once*; *minted after a Deny*; *two dispatches from one mint*; *a grant whose tuple differs from its card's
digest*.

**Rewritten behaviours (all NOT STARTED on macOS unless stated; ledger rows carry Given/When/Then):**
- **MS4.1a `load_serial`** — BUILT-HANDRUN (unchanged; `mac_ms4_load_serial_test.py`). Added (A-W3): a load commit for
  a **non-current** navigation must NOT bump `load_serial`, and a **current** one must; untested today. Red: start
  navigation A, start navigation B, let A's late commit arrive → assertion `load_serial` unchanged until B commits; a
  mutant that bumps on every callback is caught.
  **Rev 31 (G5.7, G2.2): the base `load_serial` proof, moved here from the historical rev-6 section so no live proof sits
  in a non-normative section.** (a) Entry: the per-window counter that increments on load-commit (macOS
  `didCommitNavigation:` in the shim, stored on `ZBWindowHost`, carried in `page_port.WindowInfo`, published in the
  `page.list`/`page.health` JSON). (b) Linux twin: `tests/e2e/automation_load_serial_test.py`, step
  `automation_load_serial_e2e` (`build.zig:3348`, in `test` at `:3812`), driven and registered; Mac: `tests/e2e/mac_ms4_load_serial_test.py`,
  hand-run through `tests/mac/ms4_gate.sh` (UNPROVEN until the `ms4-gate` step exists and a released run happens). Assertion:
  `serial_after_commit == serial_before + 1` for a committed load and `serial_after_reload == serial_after_commit + 1`.
  (c) Mutants of the PRODUCTION counter, each of which must fail that assertion: (1) a counter that never increments;
  (2) a counter that resets to 0 on every commit. These mutants are NAMED for the Linux twin (C37) and the Mac twin (C38)
  but NEITHER is recorded as run in this plan (no cited run); C38's mutant column is `n` (Rev 32), and C37's naming is not a recorded run. (d) Mac twin: both Macs, released run.
- **MS4 socket separation (Rev 31, G5.7; moved from the historical rev-6 section).** The external automation socket must
  remain unable to reach the broker or the approval authority. Given an authenticated external socket client, when it
  calls `agent.*` or `broker.*` methods, then each returns -32601 (method not found); when it presents a broker grant id as
  the socket `auth`, then it gets -32000 (unauthorized). Exercising proof: (a) entry = the real socket
  (`handleRequestWith`); (b) Linux: the `agent.*`/`broker.*` → -32601 rows are driven and registered (`tests/automation_inprocess_test.zig:159`, `build.zig:1947` family; `tests/e2e/agent_tools_acceptance_test.py:416`, step `build.zig:2310`). The **grant-id-as-`auth` → -32000 case is UNPROVEN** (Rev 32, G5.7): no registered test presents a broker grant id as the socket `auth` (the only -32000 row, `agent_tools_acceptance_test.py:279`, sends an automation-token-shaped wrong auth), so the required red — present a broker grant id as `auth`, assert -32000 — is TO BE AUTHORED on Linux and macOS; macOS: `tests/e2e/mac_ms4_socket_separation_test.py` (TO BE AUTHORED), the same assertions through the macOS
  binary; (c) mutant: register one `agent.*` method on the external router, or accept a grant id as `auth` → the -32601 or
  -32000 row fails; (d) macOS row: both Macs, released run, UNPROVEN until then. MS8 re-asserts it with the real helper.
- **MS4.1 (macOS half) — in-ticket refusal over the real platform.** Given a card approved for window W at
  (origin O, load_serial N), when W navigates / crashes / opens a dialog / enters `recovering` before the run
  dispatches, then the run refuses inside its ticket with -32015 (or -32013 for a dialog) and the fixture records 0
  commits. Reds are macOS real-binary e2e (`tests/e2e/mac_ms4_refusal_test.py`, TO BE AUTHORED), one per reason
  (`origin_changed`, `url_changed`, `load_serial_changed`, `crashed`, `dialog`, `recovering`), each with a one-field
  mutant, and "telemetry root-span count unchanged" as the no-engine-call proof. Mac execution follows the
  approval/release rule (R29-SAFETY); until released, the red is recorded at the compile-only tier plus the Linux
  engine tests that already pin the order.
- **MS4.1b is WITHDRAWN.** There is no broker grant engine to "wire into"; the `agent_broker.mint` seam does not
  exist. What remains of it is exactly the macOS `WindowInfo` fields (`origin`, `load_serial`, `crashed`,
  `dialog_open`) being published truthfully (MS4.1a and MS2c), which the reds above prove end to end.
- **MS4.2 negative proofs / MS4.3 per-write confirmation + dry-run inert** — keep scope; see the ledger.
- **MS4.4** — consumer of the MS3 cookie port. **Rev 30 (bd `4pa.69`): BUILT+REGISTERED on Linux ONLY; the macOS `WKHTTPCookieStore` path is BUILT-HANDRUN (UNPROVEN).**

**Gate (MS4) — what it really runs (W5).** `tests/mac/ms4_gate.sh` runs **only** the `load_serial` test and the MS4.4
login-gate test. Nothing on macOS yet covers the -32015 mutants, the MS4.2 negatives or MS4.3; the only real-binary
MS4.2 negatives (`agent_approval_negatives_test.py`) are Linux-only and unregistered. The gate sentence is therefore
**"partial: load_serial + login gate"** until the macOS refusal e2es, the MS4.2 negatives and MS4.3 exist, are
registered as an `ms4-gate` build step, and pass at a recorded commit.

### Behavior MS4.1 [SUPERSEDED BY R29-MS4 ABOVE — HISTORICAL, NOT NORMATIVE; the broker/`account`/`target_fp` design in it is not what HEAD builds]: the grant contract (the drawer plan's exact schema — blocker 2)
**Given** a committing social action,
**When** the native Approve handler mints a grant,
**Then** the grant is **single-use**, expires after **120 s**, and is bound to the drawer plan's
**exact tuple**
`sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`
(drawer plan rev 16 :507-514), where:
- `origin` = the bound window's committed origin; `account` = the platform's logged-in identity
  (`x.login_check`/`linkedin.selfcheck`/`instagram.selfcheck`); `target_fp` = for a raw DOM tool
  the resolved element's tag/id/name/role/accessible-name/text-hash/frame-URL/rect, for a flow the
  dry-run trial target description + target URL/recipient; `load_serial` = a **per-window counter**
  that increments on load-commit, published through `WindowInfo`/the list JSON.
- **Before dispatch** the broker **revalidates** the window's `origin`, `load_serial`, `crashed`
  and `recovering`; any difference **revokes** the grant and dispatches nothing.
- The check is **atomic with the commit**, inside the same FIFO ticket: the real run carries
  `options.expect = {account, target_fp}`; a mismatch returns **−32015 `expectation_mismatch`**
  and commits nothing (so a same-document account switch or a selector that now resolves to a
  different element commits nothing even when `load_serial` is unchanged).
- **Mutants (reuse drawer T5):** a **navigation** that bumps `load_serial`, a **selector-retarget**
  to a different element, a **wrong-account** switch, and **one-field-at-a-time** tuple tampering
  — each must refuse (no engine call; telemetry root-span count unchanged).
- **Only** the native Approve button's handler mints; text from the model or a page can never
  approve. Deny/timeout/window-close/crash/navigation/session-end dispatch nothing and consume
  neither the grant nor pacing.

### Behavior MS4.2: nothing else can approve (negative proofs)
**Given** the grant authority,
**When** a page world, iframe, related popup, automation-socket client, model prompt, or hook
attempts to approve,
**Then** each **fails** — proven by real-binary tests.

### Behavior MS4.3: per-write confirmation + dry-run is inert
**Given** a flow,
**When** it reaches each `Send`/`Post`/`Follow`/`Connect`/`Like`/`Next` write,
**Then** **each** gets a separate confirmation; a **dry-run** performs no committing click, no
real-composer typing, and no pacing count (social_flow_routes.zig; flow_steps.zig:142-235).

### Behavior MS4.4: login gate consumes the MS3 cookie port (rev 4 — port moved to MS3)
The `CookiePort`/`WKHTTPCookieStore` implementation (`src/automation_wk_cookie_port.zig`) is built
in **MS3.3** (the data-store owner), **not** here — rev 4 moved it so the cookie ABI no longer
depends on a slice ordered after the one that uses it. MS4.4 is the **consumer**: the flow login
gate reads the session cookie **through the MS3 port** (same contract as the GTK cookie port), and
its test proves the gate opens only when the session cookie is present.

- **Closure (MS4) — authority + negatives only (blocker 3):** MS4 closes the **negative,
  refusal and dry-run** belts: without a valid grant the write is refused (no engine call,
  telemetry root-span count unchanged); the T5 mutants above all refuse; a dry-run performs no
  committing click, no real-composer typing, and no pacing count; page worlds/iframes/popups/
  socket clients/prompts/hooks cannot approve. **The positive end-to-end commit closure is NOT in
  MS4** — the only permitted native Approve minter is built in **MS7** (MS7.8 proves the native
  card mints/denies a grant), and the **full `tool_use`→approve→commit chain is MS8.3** (rev 4),
  after the production helper that delivers `tool_use` off the socket exists. A test-only mint
  would bypass the forbidden span, so neither MS4 nor MS7 runs the commit chain.
- **Why:** at the plan pin there is **no production approval authority** (the card is
  unimplemented). MS4 builds the grant **authority and its revalidation/`options.expect` seam**
  and proves everything **refuses** without a real grant; MS7 wires the native Approve handler and
  proves it mints/denies a grant (MS7.8); MS8.3 proves the one positive commit path once per
  approval, driven by the real helper `tool_use`.

**Gate (MS4):** real-binary macOS flow + approval-refusal e2e (dry-run against fixtures; no live
sites), both arches. Not a UI slice (the card is MS7; the positive commit closure is MS8.3).
Coordinate with **BlueBeaver** (flows/approval authority).

### MS4 TDD plan revision (rev 6 — JadeBeacon 2026-10-20) — HISTORICAL, NOT NORMATIVE — [Rev 29: MS4.1b and the `agent_broker` "single shared broker / mint" claims below are SUPERSEDED by R29-MS4. Rev 31: this whole section is history and carries NO normative force; the two live-only requirements it used to hold (the MS4.1a `load_serial` mutants and the socket separation) were MOVED into R29-MS4 above]

**The grant contract is the drawer plan's, verbatim — not invented here.** MS4 reuses the schema in
`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md` :516–533: a single-use
grant, 120 s expiry, bound to `sha256(tool, window_id, origin, account, target_fp, load_serial,
normalized_args)`; pre-dispatch revalidation of `origin`/`load_serial`/`crashed`/`recovering` (any
difference revokes, dispatches nothing); the commit carries `options.expect = {account, target_fp}` checked
**atomically in the same FIFO ticket**, a mismatch returning **−32015 `expectation_mismatch`**; and **only
the native Approve handler mints** — model/page text never approves. This plan does not restate or alter
those fields; it only names where the macOS build plugs them in. **The broker already exists** —
`src/agent_broker.zig` landed in `a7ff5db` (follow-ups under review), the drawer plan's component (rev 6
correction, RoseCat 6608 #2). It is a **single shared broker**: MS4.1b does **not** build a second one; it
**extends/consumes** that broker under coordinated ownership (the drawer-plan owner, BlackRobin, owns the
shared broker implementation — assign/confirm the owner before MS4.1b). The macOS work is the platform wiring
into it (revalidation against the macOS `WindowInfo`, the `options.expect` commit seam), not the grant
engine.

**IN SCOPE for MS4 (macOS):**
- **MS4.1a — `load_serial` groundwork (prerequisite; self-contained, no broker).** A per-window counter
  that increments on load-commit (the macOS analog of `WEBKIT_LOAD_COMMITTED` — `didCommitNavigation:` in
  the shim), stored on `ZBWindowHost`, carried in `page_port.WindowInfo`, and published in the list JSON
  (additive; also flows to page.list/page.health). This is the only MS4 field the shim owns; it is built
  **now** (red-first, both arches, mutant: counter that never increments / resets). Nothing else in MS4
  starts until RoseCat approves this revision.
- **MS4.1b — macOS wiring into the shared broker's revalidation + `options.expect` seam** (**gated on
  RoseCat approval of this revision AND coordinated ownership of the existing `agent_broker.zig`**). Does NOT
  reimplement the grant engine — it wires the shared broker's revalidation to the macOS `WindowInfo`
  (origin/`load_serial`/`crashed`/`recovering`) and the commit-seam `options.expect` check (−32015), with the
  drawer T5 mutants (navigation bumps `load_serial`, selector-retarget, wrong-account, one-field tuple
  tampering).
- **MS4.2 — negative proofs:** page world, iframe, related popup, automation-socket client, model prompt,
  hook each **cannot** approve (real-binary).
- **MS4.3 — per-write confirmation + dry-run inert:** each `Send`/`Post`/`Follow`/`Connect`/`Like`/`Next`
  gets a separate confirmation; a dry-run performs no committing click, no real-composer typing, no pacing.
- **MS4.4 — consumer only:** the flow login gate reads the session cookie **through the MS3 cookie port**
  (`automation_macos_cookie_port.zig`, already built in MS3/`befdbeb`); the gate opens only when the
  session cookie is present.

**OUT OF SCOPE for MS4 (explicit), with the seams they plug into:**
- **MS7 — the native Approve minter.** MS4 builds the authority but mints **nothing** in production. The
  seam (Rev 29 corrected): the single mint entry point is `zb_agent_tools_approve` → `Cards.approve`
  (`src/agent_tools.zig:200`, `src/agent_approval.zig:279`; NOT `agent_broker.mint`/`on_approve_clicked`, which do
  not exist) that **only MS7's native Approve-button handler** calls; MS4 proves everything refuses
  without a grant and a test-only mint would bypass the forbidden span, so MS4 never mints. MS7.8 proves
  the native card mints/denies.
- **MS8 — the positive `tool_use`→approve→commit chain.** The seam (rev 6 correction, RoseCat 6608 #2):
  `tool_use` arrives over the **supervised helper↔app NDJSON pipe** (not the automation socket); the broker
  then calls the **socket-free in-process automation core** to commit. The **external automation socket must
  remain unable to reach the broker** (`agent.*`/`broker.*` give -32601; a grant id as `auth` gives -32000,
  per the drawer plan). MS4 exercises only preview/dry-run + refusal, never a real commit; MS8 (when the
  helper exists) drives the positive path.
  MS8.3 proves the one positive commit per approval.

**Order:** MS4.1a now (groundwork); then, after RoseCat approves this revision, MS4.1b/4.2/4.3 (broker,
coordinated with BlackRobin), then MS4.4.

### R30-MS4 — Rev 30: MS4 findings (validation ms4-6 F2, F7, F16)

- **[bd `zigBrowser-4pa.64`, V46-F2, MAJOR] Broker phaseA drops the call's `options.guard` — STATUS CORRECTION + RED + FIX-FORWARD.**
  `src/agent_broker.zig:709-714` builds a new `options` object that holds only `expect` and `put`s it over
  `args.value.object["options"]`, so any `options.guard` (`router.zig` `Guard`, `:60+`) or other option on a carded call is
  silently dropped. The broker never adds a guard itself, and cards carry no digest (`agent_approval.zig:217`,
  `Card = {id, presented_ms, outcome}`). **The R29-MS4 sentence "the account, recipient, document token and element token are
  bound into the card's digest (D10) and re-checked by `options.guard`" is WITHDRAWN as a description of HEAD.** Until the fix
  lands, a raw-DOM card is bound only to origin and `load_serial`: a same-document account or target change is refused by
  nothing. The fault is platform-neutral (Linux today, macOS once MS7/MS8 land).
  - (a) Entry: a carded `dom.click` dispatched by `agent_broker` phaseA into the engine (the production path the helper uses).
    (b) `tests/automation_broker_phasea_options_test.zig` (TO BE AUTHORED), registered in `test` next to the other broker tests.
    Assertions: the engine receives `options.guard` unchanged AND `options.expect = {origin, load_serial}` merged into the same
    object (`args.options.guard != null and args.options.expect.load_serial == N`); a call with an extra option keeps it.
    Fails today.
  - (c) Mutant: restore the `put` that replaces the whole `options` → the guard assertion fails. (d) none (portable).
  - Fix: merge `expect` into the existing `options` object; then either attach the card's guard (the target element mark) in
    phaseA, or keep this sentence in the plan: "raw-DOM cards are bound only to origin + `load_serial`". The owner of the shared
    broker (BlackRobin) takes the production change.
- **[bd `zigBrowser-4pa.69`, V46-F7, MAJOR] MS4.4 is Linux-only evidence — STATUS CORRECTION + FIX-FORWARD.** The registered step
  `ms4-4-login-gate-e2e` (`build.zig:2047-2053`, attached only for a Linux target at `:3799`) runs the Linux binary under
  `unshare` with Xvfb and the GTK cookie port. R29.2 and the ledger now read **"BUILT+REGISTERED (Linux) / BUILT-HANDRUN
  (macOS, UNPROVEN)"**. The macOS `WKHTTPCookieStore` consumer runs only in hand-run `tests/mac/ms4_gate.sh:40`. Fix-forward: add
  the Mac-only `ms4-gate` build step (R29-REG) running `ms4_4_login_gate_test.py` and `mac_ms4_load_serial_test.py` on both
  arches. Red/mutant: the existing assertion `gate_open == has_session_cookie`; mutant: make the gate ignore the cookie store
  on macOS → the no-cookie row fails. Platform: both Macs, released run.
- **MS4.1a** keeps its Linux twin (`automation_load_serial_test.py`, `build.zig:3348,3812`, driven and registered) and its Mac test
  (`mac_ms4_load_serial_test.py`, hand-run: UNPROVEN on the Mac). Add the A-W3 red from R29-MS4 (a late commit of a
  non-current navigation must not bump `load_serial`).
- **MS4.1 (macOS half) and the `recovering` red** stay NOT STARTED (`tests/e2e/mac_ms4_refusal_test.py` does not exist); the
  engine order is proven on Linux only.
- **Minor amendment V46-F16 (SUSPECTED → red).** `Cards.cards` (`agent_approval.zig:215`) is never pruned, so it grows by one entry
  per card for the session; locking spins on `tryLock` from the GTK thread. Red (Linux, registered with the other approval
  tests): present, approve and read 1,000 cards; assertion `cards.len <= 1` after the outcomes are read; mutant: remove the
  prune → `cards.len == 1000`. Fix: drop terminal cards once their outcome has been read.

---

## MS5: macOS setup & provisioning + Keychain onboarding (blocker 4 setup half, blocker 7 Keychain half)

**Goal.** Port provisioning to macOS so the helper/runtime/SAI can be installed, and onboard the
Claude token into the Keychain. Today `runAgentSetup` refuses non-Linux (`app.zig:41-47`) and uses
`/proc/self/exe`.

### Rev 14: MS5 contracts, BlueBeaver's half (setup, fd-3 delivery, census)

The behaviours below stay as written; these are the per-OS contracts their reds pin. Agreed with JadeBeacon
(mail 6756): the runtime location (item 3), item 6 and the Keychain consumer in item 7. Item 4 is **pending BlackRobin's OK** on S3a's
`agent_host.c` and is not built until BlackRobin gives it. The partial-green status of items 6 and 7 is RoseCat's call.

1. **Home.** Unchanged: `agent_setup.defaultHomeDir` sits beside the profile, which macOS already resolves
   through the same XDG data subdirectory (MS3.1). No new red.
2. **Executable path.** A seam `selfExePath()`. Linux keeps `readlink("/proc/self/exe")`; macOS uses
   `_NSGetExecutablePath`, then `realpath`. The cross-check object proves it compiles, and the Macs prove it runs.
3. **Runtime location** (a pure function, red on Linux; rev 16/17):
   - `agent_setup.runtimeFor(os, exe)`: Linux is unchanged (`<prefix>/lib/zigbrowser/agent-host`, its `venv/bin/python`).
   - **macOS: always `<exe dir>/../Frameworks/agent-host`.** For an app that is `<X>.app/Contents/MacOS` to
     `<X>.app/Contents/Frameworks/agent-host`; for a dev or staging tree, `zig-out/bin` to
     `zig-out/Frameworks/agent-host`. Nested code (python, `.so`, `.dylib`) must live where it is signed as
     code (JadeBeacon, MS9), and this mirrors the shim (`@executable_path/../Frameworks`) and the `zig-out` tree
     the census scans. Never under Resources.
   - **The interpreter** (the user's universal2 decision, 6ea1064; RoseCat 6797): on macOS `runtimeFor` names
     `<runtime>/Python.framework/Versions/3.12/bin/python3.12`, the python.org framework's fat launcher. There is
     **no venv on macOS**: a venv records an absolute home, which breaks when the app moves.
   - Tests: `tests/agent_setup_ms5_test.zig`, `agent_setup_ms5_python_test.zig` and
     `agent_setup_ms5_devtree_test.zig` assert both `package_dir` and `python` (built in 890d52e and 9d55923).
4. **Home lock.** `zb_agent_home_lock` (flock) moves, unchanged, out of the GLib-only `agent_host.c` into a
   POSIX-only `src/agent_home_lock.c`, built on both OSes. It is a behaviour-preserving extraction; **no registered test calls `zb_agent_home_lock` on either OS** (Rev 32, G2.3), so it is UNPROVEN — a two-process flock test is the required red (C51).
5. **Spawn, and dying with the browser** (rev 14 fix, RoseCat 6771). macOS has no `PR_SET_PDEATHSIG`, and a
   SIGKILLed browser runs no exit path, so cleanup cannot rest on the browser.
   - The browser starts setup with `posix_spawn` (`POSIX_SPAWN_SETPGROUP`, pgid 0): the setup child **leads
     its own process group**, and every descendant setup starts stays in that group: on macOS setup starts
     no child with `setsid` or `setpgid`, and the e2e census below catches one that leaves.
   - **The group cleans itself up** (RoseCat 6771, 6773). On Darwin, `setup.py`'s first act, before any
     other work or child, is this sequence. It fails closed at every step, so no gap between a check and the
     watch can hide the browser's death:
     1. The browser passes its own pid to setup (`browser_pid`, an argument). Capturing `getppid()` at
        start would already read launchd's 1 if the browser died first, and comparing that with itself
        proves nothing. Then check `os.getppid() == browser_pid` and `os.getpgid(0) == os.getpid()`
        (setup leads its group), else kill the group.
     2. Open a kqueue and register `EVFILT_PROC`/`NOTE_EXIT` for `browser_pid`. **Any error** (the open, the
        `EV_ADD`, an `EV_ERROR` in the result, `ESRCH` because the pid is already gone) counts as the
        browser's death: kill the group.
     3. **Re-check after registering:** if `os.getppid() != browser_pid`, kill the group. A browser that died
        before the registration has had setup re-parented to launchd (ppid 1), so this also covers a reused
        pid: the watch may have landed on a stranger, but the parent check cannot.
     4. Only then start the watcher thread, which blocks in `kevent`. A `NOTE_EXIT`, or any `kevent` error,
        kills the group.

     "Kill the group" is always `os.killpg(own pgid, signal.SIGKILL)`, taking setup itself and every
     descendant; never a bare exit. **One exception:** a setup that does not lead its own group never
     `killpg`s the group it is in (that could be the browser's). Step 1 runs before any child exists, so it
     kills only itself (`os.kill(own pid, SIGKILL)`). Built in `zb_agent_host/parent_watch.py` (a351086).
   - ~~The browser's own exit paths (a normal quit, a signal it handles) still `killpg` the group and
     `waitpid` the child; that is the ordinary path, not the guarantee.~~ **[Rev 29, C-W6: FALSE of HEAD.]**
     `runAgentSetupMacos` (`src/app.zig:195-215`) spawns with `zb_agent_spawn_group`, then only `zb_agent_wait`s; no
     browser exit path `killpg`s the setup group. The guarantee is solely the setup child's kqueue self-watch
     (`parent_watch.arm`). Required (choose one): reword to "the browser waits only; the self-watch is the only
     cleanup", or add a `killpg` on the browser's exit paths. Red either way: SIGTERM the browser mid-setup (a handled
     signal) → census of setup's group and descendants is empty within 2 s (assertion `survivors == 0`); mutant: remove
     the self-watch → a descendant survives (must be caught).
   - **Mac e2e, both arches:**
     - SIGKILL the browser during setup (the e2e pause seam), and separately in the check-to-register
       window of step 2 (an e2e-only barrier in `setup.py`, honoured only with `--e2e-protocol`, that holds
       between step 1 and step 2 until the test has killed the browser);
     - then census every member of setup's process group and every descendant by `ps -o pid,pgid,ppid`;
     - none may survive past a bound of 2 s;
     - a mutant whose watcher only exits setup (no `killpg`) leaves a descendant and fails. At the barrier
       the browser's pid is gone, so step 2's `ESRCH` path is what kills the group there.
   - **Linux unit test of the sequence** (it runs on Linux, with the OS calls injected). Step 3 guards a reused
     pid, which no e2e can force, so the sequence is a pure function of injected calls:
     - `getppid`, `getpgid`, `register`, `start_watcher`, `killpg`;
     - it lives in `zb_agent_host/parent_watch.py` as `arm(browser_pid, ops)`, tested by
       `agent/host/tests/test_parent_watch.py`;
     - the cases: the parent already changed; not the group leader; `register` raising; `register` succeeding
       but `getppid` changed afterwards (the reused-pid case); all good, so the watcher starts and `killpg`
       is never called.
     - Mutants that drop step 3, or treat a registration error as success, fail it.
   - Linux keeps PDEATHSIG, unchanged.
   - **Rev 29 (W6, T-W9) — the Mac e2e above CANNOT PASS at HEAD, and its status is stated honestly.**
     `tests/mac/ms5_setup_e2e.sh` exits "NOT ARMED" while `seatbelt_ready` is false, and its case (b) (SIGKILL in the
     check-to-register window) is a hard-coded FAIL because `setup.py` has **no check-to-register barrier seam** (lines
     44-47, 66-68 of the script say so). Only the Linux fake-ops test (`test_parent_watch.py`) backs the guarantee.
     `ms5_kill_group_gate.sh` tests the **netd/`zb_agent_kill_group` backstop**, NOT the setup group, and must never be
     cited as the item-5 e2e (renamed "netd/`zb_agent_kill_group` backstop gate" everywhere). Required amendment
     (choose one, plan decision = **add the seam**): add an `--e2e-protocol`-only barrier in `setup.py` between step 1
     and step 2 of `arm()`; red: `ms5_setup_e2e.sh` case (b) — kill the browser while setup is held at the barrier,
     census setup's group within 2 s → assertion `survivors == 0` — fails today with "no barrier seam"; until the seam
     and `seatbelt_ready` allow arming, the item-5 closure is **UNCLOSED** and the plan says "Linux fake-ops proof only".
     Classification: **BLOCKING** (process-death crosses the browser/setup boundary).
6. **No sandbox, no setup.** `setup.py` sandboxes its probe and `--version` with bwrap on Linux. On macOS that
   must be the MS6 Seatbelt backend. **Until MS6 is accepted, macOS `--agent-setup` exits 1 with one fixed line
   and spawns nothing; it never runs unsandboxed.**
   - The line, exactly: `zigBrowser: agent-setup: the macOS sandbox is not ready; setup will not run unsandboxed`.
     Any other non-Linux OS keeps today's `zigBrowser: agent-setup: the Claude Agent is Linux-only`.
   - The gate is a pure decision, `agent_setup.platformGate(os, seatbelt_ready)`, with its red on Linux
     (`tests/agent_setup_ms5_test.zig`, which also pins item 3).
   - MS6's green flips `seatbelt_ready`. **Rev 29 (C-W7, D2):** `pub const seatbelt_ready = false;` is at
     `src/agent_setup.zig:67`, yet **no test pins it**: flipping it alone passes every Linux test. Required registered
     test `tests/agent_setup_seatbelt_ready_pin_test.zig` (TO BE AUTHORED): `seatbelt_ready == false` at every commit
     until the MS6 acceptance commit (the test names that commit; flipping it requires editing the test in the same
     reviewed commit, which makes the flip visible). Red assertion: `try std.testing.expect(!agent_setup.seatbelt_ready)`
     and `platformGate(.macos, agent_setup.seatbelt_ready) == .refuse`; mutant: set it true → both fail. These are constant reads: a TRIPWIRE — not proof. The proof is the real macOS binary's `--agent-setup` refusing with the fixed line (`ms5_setup_refusal_gate.sh`, both Macs, UNPROVEN until released) plus the readiness invariant test of R29-MS6 D2. The deeper fix
     (a readiness that cannot be true while the profile is broad) is in R29-MS6 (D2).
7. **MS5.3, partial until MS6 and MS7 [Rev 29 (P3): NOT STARTED / seam only].** The macOS helper supervisor belongs to the drawer (MS7) and needs MS6,
   so the full closure waits for both. Now:
   - a non-GLib seam, `zb_mac_token_to_fd(fd, service, account)`: `zb_keychain_lookup(NULL, NULL, …)`, then
     write all to `fd`, then `zb_keychain_free`. Errors are fixed text, and the token is in no message.
     **Rev 29 (P3, I-W2): the seam exists only in `src/agent_token_fd_mac.h`, has NO production caller, is not in
     `build.zig`, and its header signature carries test-only `keychain_path` and `unlock_password` arguments
     (`agent_token_fd_mac.h:17`) — the production signature must be `(fd, service, account)` and the test variant a
     separate `zb_mac_token_to_fd_for_test`.** Status: seam only / NOT STARTED as a production path.
   - A both-arch mac e2e on a disposable keychain: the canary reaches the fd's reader and appears in no env,
     argv or stderr. A mutant that routes it through env fails.
8. **MS5.1c census:** Behavior MS5.1c below (rewritten in rev 17) is the authority. The Python decision that
   pins its framework follows here.

   **USER DECISION 2026-10-20 — bundled universal2 Python.** The macOS app bundles the official
   **python.org CPython 3.12.10 universal2** framework (one fat build for Intel + Apple-chip, so the
   two-tree `resource_compat`/Mach-O census can pass with ONE runtime at one path). 3.12.10 is the newest
   3.12.x with a macOS binary installer — 3.12.11+ are security-only (source-only, no `.pkg`).
   - **Source:** `https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg` (43.6 MB, macOS 10.13+).
     Release listing: `https://www.python.org/downloads/release/python-31210/`.
     - **SHA-256** `8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4` — the **mandatory
       byte-integrity check** (rev 15). This is **independently measured and pinned here** (`shasum -a 256`
       of the downloaded `.pkg`), **not** taken from the release page: python.org publishes only the **MD5**
       `8f4989592c9412e51fcad70273442c22` next to the file (MD5 is informational only — not collision-resistant).
     - **Sigstore** — python.org signs each release artifact with a `.sigstore` bundle
       (`<file>.sigstore` beside the `.pkg`). The bundle's certificate identity must be the 3.12 release
       manager **`thomas@python.org`** with OIDC issuer **`https://accounts.google.com`**. This provenance
       check is **mandatory** (rev 15).
     - The `.pkg` installer is additionally **Developer-ID-signed + Apple-notarized** (the Apple package check).
   - **Acquire (build step, not at runtime):** fetch that exact `.pkg` (and its `.sigstore` bundle); then
     **verify, all mandatory and fail-closed:**
     1. **byte integrity** — recompute `shasum -a 256` and require it equals the pinned SHA-256 above (MD5 is
        logged for reference only, never the gate);
     2. **Sigstore provenance** — verify the `.sigstore` bundle against the `.pkg` with the pinned
        certificate identity `thomas@python.org` and issuer `https://accounts.google.com`
        (`python -m sigstore verify identity --cert-identity thomas@python.org
        --cert-oidc-issuer https://accounts.google.com python-3.12.10-macos11.pkg`, or an equivalent named
        seam `verify_pkg_provenance`);
     3. **Apple package signature** — `pkgutil --check-signature` (Developer-ID Python Software Foundation,
        notarized).
     Only then unpack its framework files with **`pkgutil --expand-full`**. **NEVER run the installer and
     NEVER install system-wide on either Mac** (laroncha gets no system install).
   - **Destination:** the unpacked `Python.framework` goes in **`Contents/Frameworks/agent-host/`** (rev 14),
     where nested code is signed/notarized (Resources would fail hardened-runtime).
   - **[Rev 31, rule 8: SUSPECTED / UNPROVEN. This is a 2026-10-20 agent report of a Mac run; it was not observed by a
     validator at a named commit under a release, so the word "VERIFIED" no longer applies.]** Reported 2026-10-20 (JadeBeacon): MD5 matches the real download; `pkgutil --check-signature` →
     *"signed by a developer certificate issued by Apple for distribution"*, *"Notarization: trusted by the
     Apple notary service"*, **Developer ID Installer: Python Software Foundation (BMM5U3QVKW)**; `pkgutil
     --expand-full` succeeds and the `lib-dynload` C extensions are fat (`lipo -info` → `x86_64 arm64`).
   - **Census path_globs (now pinnable, MS5.1c):** the `--expand-full` payload lives at
     `Python_Framework.pkg/Payload/Versions/3.12/…`; relocated into the bundle the anchor is
     `Contents/Frameworks/agent-host/Python.framework/Versions/3.12/`. Key universal2 Mach-O:
     `…/Versions/3.12/Python` (the framework dylib, `python-runtime` component),
     `…/Versions/3.12/Resources/Python.app/Contents/MacOS/Python` (the interpreter exe), and
     `…/Versions/3.12/lib/python3.12/lib-dynload/*.so` (C extensions). MS5.1c (BlueBeaver's half) pins the
     exact leaf `path_glob`s from the unpack; this decision fixes the version, source, verification and
     destination they resolve against.
   - **EXCLUDE the Intel-only launcher (rev 15):** the framework ships `…/Versions/3.12/bin/python3.12-intel64`
     (with a `…/bin/python3-intel64` symlink) — an **x86_64-only** Mach-O, **not** universal2. It must be
     **excluded from the bundle and from the census `path_glob`s**: an x86_64-only binary among universal2
     peers would fail the two-tree `resource_compat`/fat-Mach-O oracle on the arm64 tree. The bundled, pinned
     interpreter (MS5.1 §"interpreter, pinned") is the **fat** `…/bin/python3.12` (`x86_64 arm64`), launched
     directly with **no venv** on macOS — never the `-intel64` variant.
   - **Acquire/census oracles, failing-first (rev 15, RoseCat 6770/6823):** the MS5.1c acquire+census step is
     red-first against each of these, so a green proves every check actually runs:
     1. **wrong SHA-256** — a `.pkg` (or fixture) whose bytes hash to anything but the pinned SHA-256 is
        **rejected** (the step fails closed); a mutant that only checks MD5 passes the bad bytes → red.
     2. **wrong/missing Sigstore** — a missing `.sigstore` bundle, or one whose identity ≠ `thomas@python.org`
        or issuer ≠ `https://accounts.google.com`, is **rejected**; a mutant that skips provenance accepts it → red.
     3. **excluded `*-intel64`** — if `…/bin/python3.12-intel64` (or its `python3-intel64` symlink) is present in
        the bundled tree or matched by a census `path_glob`, the two-tree fat-Mach-O census **fails closed**
        (an x86_64-only Mach-O among universal2 peers); a mutant that includes it, or that globs it, reds.

### Rev 16: the MS5.1c census, corrected (BlueBeaver, 2026-10-20). History: folded into item 3 and Behavior MS5.1c in rev 17 — HISTORICAL, NOT NORMATIVE

Found while pinning the census `path_glob`s. These supersede the conflicting lines of rev 8 (MS5.1c's
helper-launcher) and rev 14 item 3 (a macOS dev tree).

1. **One runtime place on macOS:** `<exe dir>/../Frameworks/agent-host`. In an app that is `Contents/MacOS` to
   `Contents/Frameworks`; in a dev or staging tree, `zig-out/bin` to `zig-out/Frameworks`. This mirrors the shim
   (`@executable_path/../Frameworks`) and the tree the census scans (`zig-out`, with `bin/` and `Frameworks/`).
   Rev 14 item 3's "a macOS dev tree keeps the Linux rule" is withdrawn. The interpreter is 2812c97's
   `Python.framework/Versions/3.12/bin/python3.12` in both. Linux is unchanged.
2. **`zb-claude` is not a bundle resource.** `setup.py` writes `zb-claude`, `zb-hook-run`, `zb-net-relay` and the
   `runtime/*.json` files into each user's agent home (`setup.py:481-499`). They are never shipped in the bundle,
   so the census cannot check them, and MS5.1c's helper-launcher-as-resource (rev 8) is withdrawn. Their
   two-arch behaviour is the MS5 setup e2e's to prove, once MS6 lets setup run.
3. **What `Frameworks/agent-host` ships, and how the census sees it:**
   - `Python.framework` (rev 15): the `python-runtime` components are its two pinned files,
     `Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12` and
     `Frameworks/agent-host/Python.framework/Versions/3.12/Python`. Every other Mach-O there must be fat by the
     census's whole-tree scan, which is why the `-intel64` launchers are excluded.
   - `zb_agent_host/` (pure Python) and `runtime.json`: the `resources`, byte-identical across the two per-arch
     trees (the two-tree `resource_compat` oracle). This set is non-empty, as MS5 requires.
   - **Not pinned here, named open:**
     - the locked dependencies (`agent/host/uv.lock`): how they enter the bundle, and whether their native
       wheels exist as universal2;
     - how the Claude CLI ships for macOS (`claude-cli`).
     Until those are decided the MS5 census runs without them and says so. The whole-tree scan fails closed on
     any thin Mach-O once one is shipped.
4. **A separate inventory:** `packaging/macos/universal_components_ms5.json`. `universal_components.json` stays
   the exact MS1 shape the MS1 gate requires. MS5's gate runs `mac_universal_test.py` and
   `mac_resource_compat.py --milestone MS5` with it.
5. **Staging:** `packaging/macos/stage_agent_runtime.sh <prefix>`.
   - The driver checks SHA-256 and Sigstore on Linux (rev 15). On the Mac: the SHA-256 again, then
     `pkgutil --check-signature` must name `Developer ID Installer: Python Software Foundation (BMM5U3QVKW)` and
     notarization, then `pkgutil --expand-full` into a temporary directory. Never the installer, never a system
     path.
   - It copies `Python_Framework.pkg/Payload` to `<prefix>/Frameworks/agent-host/Python.framework`, without
     `Versions/3.12/bin/*-intel64`, then copies `zb_agent_host/` and writes `runtime.json`.
   - The red is the MS5 census on a tree without it. The mutants copy the `-intel64` launcher (the scan fails),
     skip the SHA-256 check (a tampered pkg is refused), or ship a `zb_agent_host` file that differs between the
     two trees (the resource oracle fails).

### Behavior MS5.1: macOS `runAgentSetup` builds the immutable home
**Given** a macOS build,
**When** `--agent-setup` runs,
**Then** it builds the accepted **immutable `dist-<n>/current/state`** layout, installs the Python
runtime + helper, applies the **final SAI rule — "Hook commands only"** (rev 3 blocker 1): copy
dependency/VCS/cache/build trees **unscanned**, HOME-rewrite other copied text, **validate only
hook command lines** (not a whole import graph), and warn/skip outbound links — and grants **no
access to the real `~/.claude` or user repositories** — the macOS analog of the **corrected**
Linux provisioning (setup.py), replacing `/proc/self/exe` with a macOS executable-path API. It
**inherits** the S3a corrections (**da5eb70**, BlackRobin — the approved green follow-up that
actually contains these fixes; the earlier `cab60a1` was still blocked and is superseded): a top-level link resolved through a
parent-component link **chain**, the global cycle set keeping **internal aliases**, and the
**malformed-hook-quote** refusal — the Mac port must reuse the corrected behavior, not port
today's defects.

### Behavior MS5.1b: skipped linked skills leave no bytes; dependency trees copy unscanned (RoseCat, linked-skills resolution)
**Given** the user's decision **"keep skipping"** outbound linked skills (RoseCat mail 5458),
**When** setup runs on macOS,
**Then** a symlink that resolves **outside** its item root is skipped and the test proves the
**target's bytes are absent** from the built home (not merely that the link is gone), while the
internal dependency/build trees (`node_modules`, `.venv`, `venv`, `site-packages` —
`setup.py DEPENDENCY_DIRS`) still copy **verbatim and unscanned** — matching the Linux
`_copy_tree` skip-link + verbatim-dependency behavior. Red-first: a fixture SAI with an
out-of-root linked skill whose target holds a canary string; the test asserts the canary is
**not present** anywhere in `dist-<n>/`.

### Behavior MS5.1c: the agent runtime joins the universal-components census (rewritten in rev 17)
*(The rev 7 and rev 8 text that put the roles into `universal_components.json`, and `zb-claude` and the generated
scripts in as bundle resources, is superseded and kept only in the Rev 8 history section above.)*

**Given** MS5 ships the agent runtime in the bundle at `Frameworks/agent-host` (item 3),
**When** the universal tree is assembled,
**Then** a **separate MS5 inventory**, `packaging/macos/universal_components_ms5.json`, drives the census. The MS1
inventory, `universal_components.json`, stays the exact browser-plus-shim shape the MS1 gate requires. The MS5
inventory holds:
- **components (fat Mach-O):** the MS1 two, plus the `python-runtime` pair from rev 15:
  - `Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12`;
  - `Frameworks/agent-host/Python.framework/Versions/3.12/Python`.
  The census's whole-tree scan requires every other shipped Mach-O to be fat as well, which is why
  `Versions/3.12/bin/*-intel64` is never staged.
- **resources (byte-identical across the two per-arch trees):**
  - **`Frameworks/agent-host/runtime.json`**: exactly `{"lock_sha256": "<sha256 of agent/host/uv.lock>"}` plus a
    newline, the bytes `tools/install_agent_runtime.sh` writes. Its digest is pinned against the repo's `uv.lock`.
  - **`zb_agent_host/` as an exact file manifest:** the inventory lists every regular file under
    `Frameworks/agent-host/zb_agent_host/`, each by its exact path. The list is generated from
    `agent/host/zb_agent_host/` (`__pycache__` excluded) by `packaging/macos/ms5_inventory.py`, and a Linux test
    fails when the committed list differs from the generated one. On each tree the census requires:
    - every listed file present, as a regular file (a missing one is red);
    - **every entry below `zb_agent_host/` is either a listed regular file or a directory implied by a listed
      file's path** (RoseCat 6871). Anything else is red: an unlisted regular file, an extra directory, and **any
      symlink or special file** (FIFO, socket, device), listed or not. The check walks with `lstat` and never
      opens or follows such an entry. This is new: the existing oracle checks exact paths only and skips
      symlinks;
    - each listed file byte-identical across the two trees (a mismatched one is red).
  - **`sdk-path` (Rev 29, D-W7):** `packaging/macos/ms5_inventory.py` also emits an `sdk-path` resource that this list
    did not name; it is part of the MS5 resource set (byte-identical across the two trees) and the inventory test
    asserts the committed list equals the generated list including `sdk-path`.
  - **Pin single-source (Rev 29, D-W4):** the pinned `.pkg` SHA-256 is copied into six files and `stage_agent_runtime.sh`
    does not read `agent_runtime_pins.json`. Required: `agent_runtime_pins.json` is the one source; a registered test
    runs `stage_agent_runtime.sh` on a `.pkg` whose SHA-256 differs from the pins file and asserts it refuses (mutant: restore a hard-coded literal → the bad package is accepted); a grep of the six files is a TRIPWIRE — not proof; the stage
    tool reads the pins file. Also (T-W7) `ms5_stage_gate.sh:42` installs an **unpinned** `sigstore` from pip: it must
    reuse the MS6 hard gate's hash-locked verifier (`packaging/macos/sigstore_verifier.txt`).
    **Rev 31 (L1): the unpinned-sigstore half is now an exercise-form red, not a lint.** A lint test that greps the script for
    `pip install sigstore` without `--require-hashes` is a TRIPWIRE — not proof. The proof: (a) entry = the real
    `tests/mac/ms5_stage_gate.sh` driver, run hostless (no ssh to any host) with stub `curl`, `ssh`, `scp` and a stub `pip`/`python3`
    on `PATH` that record argv; (b) `tests/mac/ms5_stage_gate_selftest.sh` (TO BE AUTHORED), step `test-mac-stage-gate-selftest`
    (TO BE ADDED to `test`, in the style of `mac_compile_only_selftest.sh`); assertions: (1) every recorded `pip` install
    argv contains `--require-hashes` and `-r packaging/macos/sigstore_verifier.txt` and no bare `sigstore` requirement;
    (2) with `sigstore_verifier.txt` replaced by a file lacking `--hash=` lines, the driver exits non-zero BEFORE any `scp`
    or `ssh` call (`ssh_calls == 0`); (c) mutant of the production script: restore the bare `pip -q install sigstore` → the
    stub records an unhashed install and assertion 1 fails; (d) none (hostless). UNPROVEN until this step exists.
  - **Not resources:** `zb-claude`, `zb-hook-run`, `zb-net-relay` and `runtime/*.json` are written by `setup.py`
    into each user's agent home (`setup.py:481-504`), never into the bundle. The MS5 setup e2e proves them, once
    MS6 lets setup run.
- **Staging:** `packaging/macos/stage_agent_runtime.sh <pkg> <expected_sha256> <prefix>`.
  - The Linux driver fetches the `.pkg` and its `.sigstore`, checks SHA-256 against rev 15's pin and the Sigstore
    identity (`thomas@python.org`, `https://accounts.google.com`), then copies **that same `.pkg`** to the Mac and
    passes its SHA-256.
  - On the Mac the tool refuses unless the file's SHA-256 equals the argument **and** rev 15's pin. Then
    `pkgutil --check-signature` must name `Developer ID Installer: Python Software Foundation (BMM5U3QVKW)` and
    Apple notarization. Then `pkgutil --expand-full` into a temporary directory: never the installer, never a
    system path.
  - It copies `Python_Framework.pkg/Payload` to `<prefix>/Frameworks/agent-host/Python.framework` without
    `Versions/3.12/bin/*-intel64`, copies `zb_agent_host/` without `__pycache__`, and writes `runtime.json` as above.
- **The dependency tree and the Claude CLI: DECIDED (rev 20, the user's decision 2026-10-21).** `agent/host/uv.lock`
  pins `claude-agent-sdk==0.2.165` with **separate arm64 and x86_64 macOS wheels** (`uv.lock:151-152`) that carry
  the bundled Claude CLI; cryptography is repinned to **48.0.1** (universal2) for Darwin (309acf7, 15470e4). The
  chosen layout is **(a), one fat tree**:
  - **Layout under `Frameworks/agent-host`:** the merged `site-packages`, so the CLI lands at
    `Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude` — exactly where `token.bundled_cli()`
    resolves it. The `claude-cli` inventory role pins that path (`packaging/macos/ms5_inventory.py`); the census
    mutants are a missing, single-arch/thin, wrong-location and wrong-depth CLI.
  - **Fatness / reconciliation:** two per-arch `site-packages` trees are built from the lock on Linux, then a
    strict merge (`packaging/macos/merge_universal_tree.py`, BlueBeaver) makes the one fat tree — each path in
    both trees, byte-identical copied once, thin+thin `lipo`'d (`_bundled/claude`, the cffi/pydantic_core/rpds
    `.so`s), an already-universal2 file (cryptography's) byte-identical, only WHEEL `Tag:` and a regenerated
    RECORD may differ, anything else fails named. `mac_resource_compat.py --milestone MS5` runs on the two
    per-arch trees **before** the merge.
  - **Framework relocation:** `packaging/macos/relocate_python_framework.py` (fb437ea) rewrites install names to
    `@loader_path`, requires an empty census, then an inside-out ad-hoc re-sign; the Developer-ID re-sign waits
    for the user's cert.
  The partial slice **MS5.1c-a** (framework + `zb_agent_host/` + `runtime.json` only) was the placeholder until
  this decision; the full MS5.1c census now also requires the staged dependencies and the universal CLI, so the
  staging (BlueBeaver) is the green that completes it.
- **Red-first (MS5.1c-a):**
  - The MS5 census on a tree without staging fails: the components are missing.
  - The mutants, each red:
    - copying the `-intel64` launcher (the scan finds a thin Mach-O);
    - a `.pkg` whose SHA-256 differs (the tool refuses);
    - a `zb_agent_host` file missing, extra, or different between the two trees;
    - an extra symlink under `zb_agent_host/` to an outside canary file (red without following it);
    - an extra FIFO under `zb_agent_host/` (red without opening it);
    - a `runtime.json` with a different `lock_sha256`.
  - Both Macs; `mac_resource_compat.py --milestone MS5` runs on the two per-arch trees before `lipo`.

### Behavior MS5.2: Keychain onboarding (disposable canary in tests) — [Rev 29 (P3): NOT STARTED]
> Only raw Keychain store, lookup and clear exist (`src/agent_secrets_mac.m`). `configureAgentSecrets` returns on
> non-Linux (`src/app.zig:395`). `zb_agent_onboard_token` exists only in the RED `24ef54c`
> (`tests/mac/keychain_onboard_test.m`, unregistered). MS7.5 (Secrets window) RED `5e71d67` is its UI half.
**Given** the Secrets flow,
**When** the user onboards via **claude.ai callback and/or `claude setup-token`** (the accepted
paths),
**Then** the token is validated and stored in the **Keychain** (`Security.framework SecItem*`),
and the test uses a **disposable service/account + canary**, never a real credential.

### Behavior MS5.3: the token reaches only helper fd 3 — [Rev 29 (P3): NOT STARTED; seam only (`zb_mac_token_to_fd`, no caller, not in `build.zig`)]
**Given** a stored token,
**When** a session starts,
**Then** the token reaches **only** helper fd 3 via FIFO→socketpair — **not** env, argv, logs,
telemetry, hook environment, or model context (canary-scan proof, analog of
agent_secrets_test.py:247-254).

- **Closure (MS5.3):** **BLOCKING** (token crosses the store→helper process boundary) — SOURCE =
  the Keychain-stored token; TRIGGER = session start (`zb_agent_run_sync`); OBSERVE = a canary scan
  of env/argv/logs/hook-env showing **absence** + the helper confirming receipt on fd 3; FORBIDDEN
  SPAN = the FIFO/socketpair plumbing; RED-AT-SEAM = route the token via env and the canary scan
  goes red.

**Gate (MS5) — Rev 29: PARTIAL = "refusal + staging + seam".** What is gated today: the macOS setup refusal
(`ms5_setup_refusal_gate.sh`), runtime staging/relocation/census (`ms5_stage_gate.sh`, `ms5_relocate_gate.sh`,
`ms5_deps_gate.sh`, `ms5_gate.sh`), the spawn seams, and the token-fd seam test. NOT gated: MS5.1/5.1b setup running
(refuses), MS5.2 onboarding, MS5.3, the item-5 kill-group e2e. Required: `mac_resource_compat.py --milestone MS5` runs
`package_problems` + `runtime_json_problem` as part of the gate (red: a tree with an extra undeclared file under
`zb_agent_host/` makes `mac_resource_compat.py --milestone MS5` exit nonzero — today `package_problems` and
`runtime_json_problem` are called from `tests/e2e/mac_ms5_census.py` / `ms5_stage_gate.sh`, not from the milestone
oracle the plan names);
register an `ms5-gate` build step (R29-REG). Original wording follows: real-binary macOS setup + Keychain e2e, both arches; `--agent-setup` needs no
display. Not a UI slice (the Secrets window is MS7). Coordinate with **BlueBeaver** (helper/setup)
and **BlackRobin** (Keychain/Secrets window later).

### R30-MS5 — Rev 30: MS5 findings (validation ms4-6 F5 (setup half), F10, F11, F17, F18, F19, F20; AUTHORITATIVE)

- **[bd `zigBrowser-4pa.67`, V46-F5, MAJOR] MS5.2 and MS5.3 have no production path and the Keychain code is not built —
  NOT BUILT + FIX-FORWARD (the MS6 half is in R30-MS6).** `src/agent_secrets_mac.m`, `src/agent_secrets_mac.zig` and
  `src/agent_token_fd_mac.c` appear in no `build.zig` target, so they are not linked into the app; they are compiled only by the
  hand-run Mac scripts (`tests/mac/ms5_token_fd_gate.sh`, `keychain_*_test.m`). Every "BUILT" in those rows reads "compiles in a
  hand-run test only". Fix-forward, in the MS5.2 green: add the three files to the macOS app target in `build.zig`, make
  onboarding reachable from the Secrets window or a CLI flag (the production entry point), and register an `ms5-gate` build step.
  Red (exact): `tests/mac/keychain_onboard_test.m` (RED `24ef54c`, unregistered) asserts `read_back == canary` and fails to link
  (`zb_agent_onboard_token` undefined). Mutant: store under a different account → the read-back assertion fails. Platform: both
  Macs, disposable keychain, released run. Until then MS5.2 and MS5.3 are NOT BUILT.
- **Minor amendments.**
  - V46-F10: the `.pkg` pin is written in `stage_agent_runtime.sh:26` and four more files, and `ms5_stage_gate.sh:42` runs
    `pip install sigstore` without hashes. The grep test of R29.6 D-W4 is a TRIPWIRE (R30.2 T12). Exercising red: run
    `stage_agent_runtime.sh` on a `.pkg` whose SHA-256 differs from `agent_runtime_pins.json` and assert it refuses (exit
    non-zero, the pin named); mutant: restore a hard-coded literal → a mismatching package is accepted. The script reads the
    pins file; sigstore comes from the hash-locked `packaging/macos/sigstore_verifier.txt`. **Rev 31 (L1): the unpinned-sigstore
    half is closed by the same kind of exercise, not a lint:** the stub-`pip` selftest `test-mac-stage-gate-selftest`
    (`tests/mac/ms5_stage_gate_selftest.sh`, TO BE AUTHORED) runs the real `ms5_stage_gate.sh` and asserts every recorded
    install carries `--require-hashes -r packaging/macos/sigstore_verifier.txt`; mutant: restore the bare `pip install sigstore`
    → fails. Any grep of the script for `pip install` is a TRIPWIRE — not proof.
  - V46-F11: MS5 item 5 has a Linux fake-ops proof only (`setup.py` has no `--e2e-protocol` barrier between `arm()` steps 1 and
    2, so `ms5_setup_e2e.sh` case (b) cannot pass). Add the barrier seam (already R29), AND set `POSIX_SPAWN_CLOEXEC_DEFAULT` plus
    explicit stdio in `zb_agent_spawn_group` (`agent_spawn_posix.c:14-33`; the `_io` variant sets it at `:47-49`). Red: a child
    started through `zb_agent_spawn_group` while the browser holds a non-`CLOEXEC` canary fd lists its open fds and
    `assert child_fds == {0, 1, 2}`; mutant: drop the flag → the canary fd is inherited. Both Macs, released run (the flag is an
    Apple extension).
  - V46-F17: `runAgentSetupMacos` (`app.zig:148-215`) repeats about 80% of the Linux body (`:85-141`), Linux still reads
    `/proc/self/exe` directly (`:89`, `:229`), and the VM-containment gate at `:60-71` also refuses Linux setup when
    `ZIGBROWSER_AGENT_VM_CONTAINMENT=on`. Fix: one setup body over `self_exe` + `runtimeFor(builtin.os.tag, …)`. Red (Linux,
    registered): `--agent-setup` on Linux with the VM-containment env set to `on` follows the documented decision (assertion on
    the exit status and the one fixed line); mutant: apply the gate to Linux → fails. The decision (Darwin-scoped) is recorded
    here.
  - V46-F18: `zb_keychain_lookup` copies `data.length` bytes (`agent_secrets_mac.m` ~`:101-106`) but `zb_mac_token_to_fd` and
    `zb_keychain_free` use `strlen`, so a NUL inside the token truncates the write and the wipe. Red (Mac, with MS5.2): storing a
    token with an embedded NUL is refused (`assert onboard(token_with_nul) == REFUSED`); or lookup returns the length and the fd
    write sends every byte. Mutant: remove the check → the read-back differs. Both Macs, disposable keychain.
  - V46-F19: `mac_census_unit` and `mac_ms5_census_unit` (`build.zig:2993-3007`) do not fail on `ResourceWarning`, unlike every
    sibling step. Red: a unit that deliberately leaks a file object must fail the step; mutant: the current runner → the leak
    passes. Registered in `test`.
  - V46-F20 (rule 7: skip is failure): `test-mac-census` fails under `--map-root-user`
    (`test_ms5_1b_skipped_link_bytes…unreadable_file_or_a_fifo` expects a `chmod`-ed file to be unreadable, which is false for
    uid 0) and 6 `SpawnGroupWithoutWaitid` tests skip ("no kqueue here"). Fix: guard the unreadable-file control with
    `os.geteuid() != 0` so it FAILS with "NOT RUN: root" instead of silently differing; count Darwin-only skips in the Mac tier
    and fail the Mac gate when any skip appears. Red: run the unit as uid 0 → assertion `rc != 0 and "NOT RUN" in stderr`.

---

## MS6: Seatbelt sandbox backend (hard launch gates; VM fallback blocks launch) — blocker 6, dispositions 2/3

**Goal.** Implement the macOS Seatbelt backend against the **MS0 launch spec**, and make the
spike proofs **hard launch gates**. **If any mandatory proof fails, Mac agent launch stays
disabled until the shared interface's VM backend is implemented** — Seatbelt-first is the choice,
"Seatbelt even when its proof fails" is not.

### Design (from `…/research/2026-10-14-macos-sandbox-option.md`)
- **[Rev 29 — TARGET design, NOT what HEAD generates (K4).]** `MacSeatbeltBackend` implements the MS0
  `SandboxBackend` spec: `(deny default)`, deny-default
  reads, **no `same-sandbox` task-port/process-info rights** (exact: `(allow process-info* (target self))` is
  permitted — added by `aa83b5f` so the real interpreter does not SIGILL; it is own-process only, and this bullet now
  says so, C-W5), allow only the backend's
  ephemeral loopback proxy port and `:51091`/`:31337` (see the egress mapping below), tiny
  mach-lookup (no WindowServer, no mDNSResponder), **profile file + `-D` params** (not inline),
  fixed `/usr/bin/sandbox-exec`. **At HEAD the generator emits `(allow file-read*)` and `(allow mach-lookup)`**
  (`agent/host/zb_agent_host/sandbox_macos.py:173,183,216,226`) and the Linux test pins that text, so the deny-default
  reads and tiny mach-lookup above are **NOT STARTED** — they are the new item **MS6.7** below. `LAUNCH_SPEC_CONSUMABLE =
  False` (`:352`) says exactly this.
- **Hooks (Rev 29, P1) — the REAL mechanism:** the hook is spawned by **`zb-hook-run` calling `sandbox-exec` from
  inside the CLI's own sandbox** (`agent/host/zb_agent_host/hook_run.py:189-208`), each hook in its own profile. There is
  **no app-side hook spawner and no `SCM_RIGHTS`/`sendmsg`/`recvmsg` anywhere in the tree**; the earlier "spawned
  app-side, stdio over `SCM_RIGHTS`" text is withdrawn (an app-side spawner remains an *option* only if the real
  mechanism cannot be justified). Seatbelt profiles do not nest (a sandboxed process can only further restrict), so the
  **CLI profile must grant exec rights that the deny-default design has to justify**: it permits `process-exec` of
  exactly `/usr/bin/sandbox-exec` and the hook launcher path, `process-fork`, and nothing wider. This is tested in
  MS6.7 (exec-rights rows). Existing evidence for this mechanism: the hard-gate case `tests/mac/hard_gate/case_ms8_hook_sandbox.py` (the real `zb-hook-run` Darwin branch under `sandbox-exec`, bridges reached, API/public denied, marker fd 5 inherited into the hook and its double-forked grandchild, env allowlist), whose Linux stand-in unit is registered; its Mac run is pending and it does not yet cover exec rights.
- Orphan cleanup via kqueue `NOTE_EXIT` + pipe EOF + PID tracking. **The dedicated-user `kill(-1)`
  scheme from rev 1 is removed** (unapproved).
- The proxy/bridges are owned here or depend on a named green Linux revision (per MS0/Shared
  contract).

### R29-MS6 — MS6 amendments from the review (Rev 29; K4, D2, I1, I2, P1, W1, P-W7, WC-W3, WC-W6, C-W4, T-W2; bd `4pa.21`/`.22`/`.23`)

**MS6 status at HEAD, in plain words.** The Seatbelt profile generator, the `MacSeatbeltBackend` class, netd on Darwin,
the R1/census harness and the reaper core exist and have Mac probes. **No production path launches the agent under
Seatbelt.** `launch.py:154-157` refuses on darwin before any backend; `src/agent_helper.zig:121-130` never passes
`--egress-port`; `spawnNetd` and `appendEgressPort` have only test callers; `LAUNCH_SPEC_CONSUMABLE = False`;
`seatbelt_ready = false`. So MS6.1's closure is **OPEN** (below) and the existing scripts are **profile-belt probes**.

**MS6.7 (NEW hard-gate item, K4) — read and mach-lookup curation, failing-first.**
- **Given** the generated CLI/helper/hook profiles, **when** a sandboxed process (a) reads a canary file outside
  `ro_paths` + the system allowlist (e.g. a planted `~/.ssh`-like canary in the user's home), (b) looks up the Mach
  services `com.apple.windowserver.active`, the CGEvent tap, screen capture and `mDNSResponder`, (c) execs `/bin/sh`
  from the CLI profile (exec-rights row, P1), **then** each is DENIED with the Seatbelt errno, **while** the allowed
  reads (workspace read-only share, agent home, system dylib paths the CLI needs) and the allowed lookups still work
  (positive controls).
- **Red (Linux, hostless — registered):** `agent/host/tests/test_sandbox_macos.py` is changed in the same red commit so
  its pin FLIPS: assertion `"(allow file-read*)" not in profile and "(allow mach-lookup)" not in profile` (today the
  test pins the broad text, so this fails); plus a Property: for any `ro_paths` set (domain: 0-8 absolute paths, no
  `..`, no NUL, no empty segment) every `file-read*` rule in the rendered profile is `subpath`/`literal`-scoped to a
  member of `ro_paths ∪ SYSTEM_READ_ALLOW ∪ {workspace}`. Mutant: reinstate the bare `(allow file-read*)` → both
  assertions fail (must be caught).
- **Red (Mac rows, failing-first, run only under the R29-SAFETY release rule, otherwise compile-only):** in
  `tests/mac/ms6_generated_profile_test.sh`: `cat <canary>` → `EPERM`; `bootstrap_look_up(windowserver)` → `kr != 0`;
  `CGEventPost` → denied; `screencapture -x` → no image; `exec /bin/sh` from the CLI profile → `EPERM`; `exec
  /usr/bin/sandbox-exec` → allowed. Each row is red against today's broad profile.
- **[Rev 30]** The Linux profile-text assertions above are TRIPWIRES (R30.2 T9). The proof of MS6.7 is the Mac rows, UNPROVEN until a released run on both Macs.
- Classification **BLOCKING** (kernel enforcement across a process boundary).

**D2 — readiness as ONE type (the forbidden state must be unrepresentable).** `seatbelt_ready`
(`src/agent_setup.zig:67`) and `LAUNCH_SPEC_CONSUMABLE` (`sandbox_macos.py:352`) are two independent booleans that
together can say "sandbox ready" while the profile still allows all reads. Rev 29 replaces them with a derivation
from one fact:
- Python: `PROFILE_CURATION = Curation.BROAD | Curation.CURATED` is the single source; `LAUNCH_SPEC_CONSUMABLE` is a
  *function* `lambda: PROFILE_CURATION is Curation.CURATED` (no independent boolean to flip).
- Zig: `seatbelt_ready` is `comptime`-derived from `@import("seatbelt_gate.zig").accepted_commit != null`, and
  `seatbelt_gate.zig` is changed only by the MS6 acceptance commit.
- **Registered cross-language invariant test** (`tests/agent_seatbelt_readiness_invariant_test.zig`, TO BE AUTHORED, run in
  `test`): `seatbelt_ready ⇒ PROFILE_CURATION == CURATED ∧ no bare allow in the rendered profile ∧ platformGate allows`.
  **Rev 31 (L3): "no bare allow in the rendered profile" is a profile-TEXT check, so it is a TRIPWIRE (the same check R30.2 T9
  labels a TRIPWIRE) — never the closing proof of D2.** The `seatbelt_ready` constant read is also a tripwire (T8). The closing
  proof is the kernel denial run beside them: the Mac rows of `tests/mac/ms6_generated_profile_test.sh` (canary `cat` → EPERM,
  windowserver lookup denied, `exec /bin/sh` EPERM) executed under the generated profile on both Macs, released run, with
  the bare-allow mutant making those rows fail. D2 stays UNPROVEN until then.
  Red assertion: with `PROFILE_CURATION = BROAD` the invariant holds vacuously only while `seatbelt_ready == false`;
  mutant 1: flip `seatbelt_ready = true` alone → the invariant fails; mutant 2: flip curation to CURATED without the
  profile change → the rendered-profile assertion fails. Both must be caught. **[Rev 30, bd `4pa.66`: observed at d0f1841, with `seatbelt_ready = true` `test-agent-setup-ms5` still exits 0, so no pin exists in the code; this registered invariant is the fix. The constant read itself is a TRIPWIRE, R30.2 T8.]**

**I1 — `MacSeatbeltBackend` conforms to `SandboxBackend`, tested.** New registered
`agent/host/tests/test_backend_conformance.py` (next to `test_backend_contract.py`, same venv-fail-closed pattern,
`build.zig` ~`:3194`) iterates `LinuxBwrapBackend` and `MacSeatbeltBackend` over the Protocol. Red assertion:
`inspect.signature(MacSeatbeltBackend.network) == inspect.signature(SandboxBackend.network)` — fails today
(Rev 31, V46-F12: the Protocol's `network(self)` at `sandbox.py:213` vs BOTH backends' `network(self, session=None)`; the Protocol is the wrong side); also asserts `launch_spec` accepts `network=`, `egress_dir()`
returns `Optional[str]` (Protocol typed `str`), and that every input the Mac `launch_spec` ignores (`ro_paths`,
`state_dirs`, `net_dir`, `seccomp_fd`, `sandbox_macos.py:413-442`) either is honoured or raises
`UnsupportedLaunchInput`. **Property:** for every Protocol member `m`, both classes expose `m` with identical parameter
names/kinds/defaults (domain = Protocol members × 2 classes). Mutant: rename a parameter → caught.
**[Rev 30, V46-F12, R30.2 T10: both backends define `network(self, session=None)`; the Protocol's `network(self)` is the wrong one, so the fix corrects the Protocol. The signature assertion is a TRIPWIRE; the proof is `launch.build_launch` driven for both backends.]**

**MS6.8 (NEW) — the production launch connector (I2, P1, W1, I-W9, A-W1, WC-W6): the named seam MS6 completes through.**
The connector is the launch/dispatch slice named in agent mail 7027/7035 (the macOS half of "run the helper under the
backend"; owner BlueBeaver, joint with MS8.1). It is **NOT STARTED** and MS6 cannot be called complete without it:
- one function over the backend protocol, `launch.build_launch(backend, spec)`, replaces the Linux-only `build_argv` +
  private `sandbox._LINUX_BACKEND` use (`launch.py:97,111`) so Mac and Linux share one composition (I-W9);
- `launch.py:154-157`'s unconditional darwin refusal becomes `if not (LAUNCH_SPEC_CONSUMABLE() and seatbelt_ready)
  refuse`, so the refusal is the readiness gate, not a platform ban;
- `src/agent_helper.zig` passes `--egress-port <n>` (the netd port) on Darwin (A-W1: `launch.py` accepts it, the Zig
  helper never sends it, so the only Mac launch route is dead today);
- the Darwin `ZbSpawnPolicy` is supplied by the backend (C-W2) rather than `zb_spawn_policy_linux(0)`;
- the VM-containment fail-closed check guards the LAUNCH path, not only `--agent-setup` (WC-W6).
- **Reds:** (a) Linux hostless, `launch.build_launch(MacSeatbeltBackend(51234), spec)` returns an argv that begins
  `["/usr/bin/sandbox-exec", "-f", <profile>, "-D", …]` and contains `--egress-port 51234` — today `launch.py` raises
  the darwin refusal (assertion fails on exception); (b) Zig, the Darwin helper argv contains `--egress-port` (assertion
  `std.mem.indexOf(argv, "--egress-port") != null`, today absent); (c) with the VM-containment setting ON the launch
  path itself refuses with "VM containment is not available yet" (today only `--agent-setup` consults it, `app.zig:62-71`);
  (d) **Rev 31 (L2): a Python import scan that "proves no production module imports `sandbox._LINUX_BACKEND` directly" is
  a TRIPWIRE (static import check) — not proof, and it does not close I-W9.** The closing red is an exercise: (a) entry =
  `launch.build_launch(backend, spec)`; (b) `agent/host/tests/test_backend_conformance.py` (same registered file as I1), a row
  that POISONS the private module global (`sandbox._LINUX_BACKEND` replaced by an object whose every attribute access raises),
  then calls `launch.build_launch(MacSeatbeltBackend(51234), spec)` and `launch.build_launch(LinuxBwrapBackend(), spec)` and
  asserts both return their argv with no exception; (c) mutant of the production code: restore the `launch.py:97,111` use of
  `_LINUX_BACKEND` inside `build_launch` → the poisoned global raises and the row fails; (d) none (portable).
- **Classification:** BLOCKING (spawn crosses Zig → Python → sandbox-exec → CLI).

**MS6.1 closure — relabel and keep OPEN (W1).** The current MS6.1 scripts (`ms6_1_token_isolation_test.sh`,
`ms6_1_procinfo_probe.c`) start at `sandbox-exec` with a probe, and one uses a hand-written profile
(`tests/mac/agent_sandbox_ms6_1_token_isolation.sb`) that differs from the generated one; they do not use the fixture
SAI with a malicious hook. They are therefore named **"profile-belt probes"** and **do not close MS6.1**. MS6.1's
closure stays **OPEN** until it runs through the MS6.8 connector: TRIGGER = the production launch
(`zb_agent_run_sync` → MS6.8 → `MacSeatbeltBackend`), SOURCE = stored token + fixture SAI with the malicious hook +
sacrificial canary target, OBSERVE = the hook's recorded attempt file (canary absent, syscall errnos denied),
RED-AT-SEAM = remove the task-port/process-info denies → the hook reads the canary. The sacrificial canary target
and the positive control in the existing probes are kept as written.

**MS6.3 profile-mutant row (P-W7).** The real-CLI hard-gate case `case_ms6_3_fd3_cli.py` has no profile-mutant row
though the plan promises a discriminating mutant. Required: add a row that runs the same real CLI under a profile
that DENIES `/dev/fd/3` (or the socket fd) → the case must FAIL (CLI cannot read the canary) while the real profile
passes. Red: the case runner asserts `mutant_profile_result == FAIL`; today no such row exists (assertion
"missing mutant row"). A discriminating mutant is part of the definition of the hard gate.

**MS6.4 production-proxy traversal (WC-W3).** The plan says the fake API is reached through the production proxy
(`--e2e-protocol` allowlist seam) and that removing the proxy turns the test red, but no test traverses the production
proxy with the fake API. Required: a Mac test that starts the production netd, points the CLI/helper at it via
`HTTPS_PROXY`, serves the fake API, and asserts the fake API saw a CONNECT for the allowlisted host through netd's
port (assertion `fake_api.connects_via_proxy == 1`); mutant: bypass the proxy (direct connect) → the profile denies it
and the test is red; mutant: widen the hook profile to admit the proxy port → red. Today only a loopback decoy and
connect probes (`ms6_4_connect_probe.c`) are exercised.

**Bridge ports `[::1]` (C-W4).** The dual-family ownership rule covers the egress and R1 ports only. The bridge rules
render as `localhost:51091` and `localhost:31337`, so `[::1]:51091` and `[::1]:31337` are ADMITTED and not reserved.
Required (choose one; plan decision = **reserve**): the bridge owner binds a non-listening `AF_INET6`, `IPV6_V6ONLY`
reservation on `[::1]:51091` and `[::1]:31337` for the bridge lifetime (as netd does for the egress port), failing
closed on `EADDRINUSE`; red: pre-plant a `[::1]:51091` listener → the bridge start fails closed with no ready line
(assertion exit code 2, no ready line); mutant: skip the reservation → the foreign listener is reachable from a hook
profile (must be caught). If a bridge is externally owned, a closure must show it is the app's own listener on both
families instead.

**No skip-to-green on the IPv6 reservation tests (T-W2).** `agent/host/tests/test_netd_darwin_v6.py:67` and
`test_setup_darwin_r1_v6.py:45` skip to green when `has_ipv6` is false, so the reservation property can go unchecked
on a green run. Required: when IPv6 loopback is unavailable the test **fails with "NOT RUN: no IPv6 loopback"** (exit
nonzero) in the Mac tier, and in the Linux tier it is a recorded "unchecked" count that the registered gate asserts is
zero on the gating host. Red: run with `has_ipv6` forced false → the assertion `exit_status != 0` fails today.

### Egress mapping — the `SandboxBackend` egress capability, pinned (rev 6; RoseCat `ed13e5e`)

The MS0 egress capability (endpoint **and** policy supplied by the backend) is realized on macOS
exactly as follows. This replaces rev 5's open design item: the "Unix-socket proxy" option is
**ruled out** because the bundled CLI rejects Unix-socket proxy URLs (BlueBeaver measured, mail
`5503`), so a TCP `127.0.0.1:<port>` hop is mandatory, and the remaining viable mapping is pinned:

1. **Host netd listens on an OS-selected, per-session `127.0.0.1:<port>`** (an ephemeral port the
   kernel assigns, recorded for the session), and the **generated CLI/helper Seatbelt profile
   permits only that one loopback endpoint** — no other outbound, no other loopback port.
2. **`HTTPS_PROXY`/`HTTP_PROXY` name that exact port**, and **netd keeps the exact CONNECT/SNI
   allowlist** (`api.anthropic.com` + census-proven CLI domains, fail-closed; §MS6.4). An arbitrary
   host process gains no meaningful capability from the port existing: it already has host egress,
   and the proxy grants only the same API allowlist.
3. **Each hook gets its own profile permitting only loopback ports `51091` and `31337`** — **no
   proxy endpoint and no API path**. (Hooks never reach the egress proxy; the per-process rule, not
   a shared loopback, is what isolates them on macOS, since macOS has no per-sandbox loopback.)
4. **The real-binary fake-API test (MS6.4) proves:** the chosen endpoint carries egress; **both
   bridge positives** (`:51091`, `:31337`); **every MS6.4 denial**; and that **a hook cannot reach
   the proxy** (a hook's attempt to the CLI/helper proxy port is refused by its profile).

#### Endpoint contract (rev 19; orchestrator ruling on 7046, subject to RoseCat)

Seatbelt's `remote` host token accepts only `*` or `localhost`; the IP literal `127.0.0.1` is a parse
error (reported measured both arches in JadeBeacon 70444e5; **SUSPECTED** — not re-observed as a run in this plan, Rev 32). `localhost` resolves to **both** loopback families,
so the generated rule `(allow network-outbound (remote tcp "localhost:<port>"))` unavoidably permits
`[::1]:<port>` as well as `127.0.0.1:<port>` — Seatbelt cannot express a v4-only grant. Rather than
leave the gate unmet, the **accepted contract is the `localhost:<port>` grant (loopback TCP, both
families)**, on the strict condition that **the app OWNS every endpoint the token admits** and the rule
is otherwise exact. "Nothing listens on `::1` today" is NOT the boundary (RoseCat 7071): a current
a connect to `::1` failing today only proves no listener happened to exist; an unrelated local process could
bind the same numeric port on IPv6 and then sandboxed code could reach it. The hole closes only by
**durable dual-family ownership** of the port.

The gate MUST prove, both arches:
1. **The app reserves BOTH families of the port, fail-closed** — the port owner (netd `serve_tcp` for
   egress; setup `probe_r1` for the R1 listener; BlueBeaver, bead zigBrowser-v9f) binds its
   `127.0.0.1:<port>` v4 proxy listener AND, for the session/probe lifetime, an `AF_INET6`,
   `IPV6_V6ONLY=1`, **non-listening, no-reuse** reservation on `[::1]:<same port>`. If either cannot be
   held (e.g. a pre-planted `::1:<port>` listener → `EADDRINUSE`), it **fails closed**: netd exits 2 with
   no ready line and the browser treats it as the existing network failure; `probe_r1` returns no R1; the
   profile is never published. **[Rev 31, rule 8: the "Proven in" claim below is an agent report of Mac runs, SUSPECTED / UNPROVEN until a released run at a named commit.]** Reported in `tests/mac/ms6_netd_darwin_gate.sh` / `test_netd_darwin` and
   `tests/mac/ms6_r1_kernel_gate.sh` / `test_setup_darwin_r1` (pre-planted-`::1` fail-closed; second bind
   EADDRINUSE; reservation lifetime == v4 listener; lsof shows `[::1]:<port>` not-LISTEN + no reuse flags).
2. **`[::1]:<port>` reaches nothing** — because (1) holds a **bound, non-listening** reservation there, a
   sandbox connect to `[::1]:<port>` has its SYN **dropped** by that socket: it is observed as a **TIMEOUT**,
   never a completed connection and never a foreign listener. A bound non-listening socket drops the SYN
   rather than sending a refusal (measured both Macs, RoseCat 9c68cc4), so the row expects the observed
   timeout, NOT `CONNECT-REFUSED` (`tests/mac/ms6_4_egress_test.sh`, the `::1` row, with the real reservation
   present via netd's `--test-port` seam). The reachable egress endpoint stays `127.0.0.1:<port>` and only that.
3. **every OTHER endpoint the token could be mistaken to admit is DENIED by policy** — another v4 port AND
   another v6 port, UDP v4 AND UDP v6 at the allowed port, the IPv4-mapped IPv6 form, and a public IP all
   `CONNECT-DENIED` (EPERM, not merely refused); the hook profile denies the egress port while keeping its
   two bridges (`tests/mac/ms6_4_egress_test.sh`).

If the dual-family reservation cannot be held (breaking (1)), or a connect to `[::1]:<port>` ever reached a
foreign listener (breaking (2)), or any other port/UDP were policy-permitted (breaking (3)), the contract
is violated and MS6's VM fallback applies. The durability lives in the app's reservation (1); the Seatbelt
token merely must admit nothing but the owned endpoints (2, 3).

**Shared capability framing:** the endpoint and policy are the backend's to supply. **Linux**
implements the capability with a **private network namespace, fixed proxy/bridge ports, and relays**
(the hook's own netns seals it). **macOS** implements it with the **ephemeral host-loopback proxy
above plus per-process Seatbelt port rules**. Either way MS0's launch spec is the single owner of
"which endpoint, which policy, who may reach it"; MS6 only realizes the macOS half.

### Hard-gate behaviors (all failing-first; failure ⇒ launch disabled + VM required)
- **MS6.1 (gate):** a malicious hook's `task_for_pid(cli)`, `sysctl KERN_PROCARGS2`,
  `proc_pidinfo`, and `lldb -p <cli>` **all fail**; the token-isolation mutant uses a
  **deterministic sacrificial target** so removing Seatbelt actually **exposes the canary** (a
  host/TCC denial that stays green does **not** prove the profile).
- **MS6.2 (gate):** custom `sandbox-exec` profile is **accepted** on both arches' OS versions
  (disposition 3; failure selects VM).
- **MS6.3 (gate):** the **fd-3 reopen** (`/dev/fd/3`) works with the macOS CLI on **both** arches
  (disposition 2). **Split (RoseCat 7038, mirroring the MS6.6 split in 7053):**
  - **lower layer — the Seatbelt fd-3-reopen probe** (`tests/mac/ms6_3_fd3_reopen_test.sh`, both arches,
    green): the generated CLI profile PERMITS `open("/dev/fd/3")` (a C stand-in does exactly that reopen),
    and a profile denying the token's dir DENIES it, so the pass is the `file-read*` grant's doing. This
    does NOT run the real CLI and does NOT prove the production channel.
  - **hard gate — the real pinned CLI over the production channel** (MS5-gated): production hands fd 3 a Unix
    **socketpair** endpoint (`token.py`), not a regular file, and the real pinned Claude CLI must consume the
    exact canary via `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` under the generated profile, both arches, with
    a discriminating mutant. This runs as a **case of the unified pre-`seatbelt_ready` hard-gate harness**
    (shared with MS6.6(B), rev 18.1): the harness imports production `zb_agent_host` from the **staged pinned
    runtime** and drives the real CLI directly, before `seatbelt_ready`. It is **NOT** a case of the armed
    `ms5_setup_e2e.sh` (that cannot arm until `seatbelt_ready` — the cycle RoseCat 7120 caught), and it does
    not weaken the app's fail-closed gate. It waits only on the **MS5 pinned-tree decision**, never on
    `seatbelt_ready`. Whether the CLI reopens `/dev/fd/3` or reads the socket fd directly (`token.py:3-8`) is
    settled by that measured real-CLI evidence; the contract is amended then if needed. Until that harness
    case passes on both arches, MS6.3's hard gate is unmet and does not contribute to `seatbelt_ready`.
- **MS6.4 (gate, egress mapping pinned — rev 6):** network — the CLI/helper reach egress **only at
  the backend's per-session `127.0.0.1:<port>`** (the generated profile permits only that endpoint);
  both bridges `:51091`/`:31337` carry bytes (positive controls); and the sandbox **fails** to
  reach a direct loopback decoy, LAN, public IP, DNS, WindowServer/CGEvent/screen capture, a
  non-allowlisted host, and a workspace write. **A hook (its own profile) cannot reach the proxy
  port at all** — its attempt is refused — while its two bridges still work. The fake
  Messages/Anthropic API is reached **through the production proxy** via an `--e2e-protocol`
  allowlist seam; **removing/bypassing the proxy, or widening the hook profile to admit the proxy
  port, turns the test red**.
- **MS6.5 (gate, rev 19 — the user's decision, 2026-10-21):** the double-fork + `setsid` detached-process
  escape is **accepted with cleanup**, not blocked; `sandbox_check` and every other private API are out. The
  gate is now **cleanup + a survivor warning** — no longer "no survivors". **[Rev 29 SPLIT (P2, bd `4pa.25`): the
  words "present and green on both Macs" were false for the warning.]** MS6.5 is split into:
  **MS6.5 (reaper core) — BUILT-HANDRUN:** `src/agent_run_reaper.c` and its signal-free census gate
  (`ms6_5_reaper_census_gate.sh`, both arches, zero kill) plus the Linux engine/pin/fixed-point tests; and
  **MS6.5.2 (survivor warning + setting + production caller) — NOT STARTED, OPEN:** there is no drawer warning, no
  [Stop them now]/[Leave them running]/[Show details] UI, no persisted "Automatically stop leftover agent processes"
  setting, and **no reader of `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS` anywhere in `src/`**; the VM-containment gate is
  wired only into `--agent-setup` via an env var (`src/app.zig:62-71`), not the launch path. MS6.5.2's reds are the
  setting-matrix and warning rows already specified under MS6.5.1 *Testing* plus a drawer-warning real-screen case; it
  depends on MS6.8 (the production caller) and MS7 (the drawer). The text below describes the **design** of both halves:
  - **Cleanup (public libproc only).** After every agent stop, and again at the next app start, the host
    enumerates processes (`proc_listallpids`) and kills (public `kill`, guarded: pid > 1, ownership re-checked
    immediately before the signal, ESRCH ⇒ skip — never `getpgid`-based, which gives ESRCH on a macOS zombie)
    every process whose **cwd, executable, or an open file is under that run's dir** (`proc_pidinfo`
    `PROC_PIDVNODEPATHINFO` / `proc_pidpath` / `PROC_PIDLISTFDS`). A process that scrubs every marker is the
    **accepted residual**; the VM stub below is the path to hard containment. Reaper: `src/agent_run_reaper.c`.
  - **Survivor warning (the user asked for "a warning with options").** Survivors the automatic pass could not
    stop surface a drawer warning whose **exact options** are: **[Stop them now]** (re-run the guarded kill over
    the listed pids) · **[Leave them running]** (dismiss, do nothing) · **[Show details]** (the pids, each
    command, and cwd). A default-on setting, **"Automatically stop leftover agent processes,"** governs the
    silent stop-time and start-time passes; the warning appears only for what those passes could not stop.
  - **VM containment stub (off by default).** `src/mac_vm_containment.zig`: a planned Apple
    Virtualization-framework seam whose `availability()` reports `.not_available_yet`; when the setting is on,
    launch **fails closed** ("VM containment is not available yet"), never pretending to contain. Landed 2523247.
  - **Both-Mac gate status (SUPERSEDED; the destructive gate must NOT be run — it is NOT guarded in code, only by `ZB_MAC_ARM_HOST`):** the standalone C gate
    `tests/mac/ms6_5_reaper_gate.sh` (reaper is C/browser-side) that SIGKILLs a detached escaper and spares a
    decoy/scrubber DID pass both arches once at 7fa8906, but that was BEFORE the kill-safety review hardened the
    reaper (fd-based creation pin, per-kill revalidation, recorded provenance). It has NOT been re-run since and
    **must not run on the Macs** until the signal paths are reviewed and the `reaper_ready` hard gate (MS6.5.1) is
    green; treat that prior PASS as **superseded, not current**. The current Mac evidence is the SIGNAL-FREE
    census gate `tests/mac/ms6_5_reaper_census_gate.sh` (reported both arches 18/18, zero kill [Rev 31, rule 8: agent-reported, SUSPECTED / UNPROVEN; no released run at a named commit]); the pure core + engine +
    pin are Linux-unit-tested under `unshare`. **MS6.5 no longer requires defeating the escape**, so it no longer
    forces the VM backend; the earlier "no survivors / Failure ⇒ VM required" criterion is withdrawn. The production lifecycle owner and the drawer
    survivor-warning are specified in **MS6.5.1** below.
    **Rev 31 SAFETY (T4, bd `4pa.24`, `4pa.70`; V46-F8; R30.1 #18): the disable-by-default guard for
    `tests/mac/ms6_5_reaper_gate.sh`, its red and its mutant are a REQUIRED fix-forward (R29-SAFETY, bd `4pa.70`), NOT yet in
    code.** At HEAD the script is guarded ONLY by `ZB_MAC_ARM_HOST` being set (script lines 15-23). It sends SIGKILL, and the
    repo already records an unreleased Mac test incident (`c07899f`). **The script must NOT be run on either Mac.** The
    guard (exit 1 with "DISABLED: destructive reaper gate" unless `ZB_REAPER_DESTRUCTIVE_APPROVED` equals the staged commit
    AND an orchestrator release-token file exists), its hostless red (`ssh_calls == 0` with a stub `ssh` on `PATH`) and its
    mutant are specified in R29-SAFETY and R30-MS6 but have NOT been written. Status: UNPROVEN (the behaviour is NOT BUILT,
    C80) until the guard lands in code, its hostless selftest is registered, and the orchestrator releases it. The earlier
    Rev 29 sentences "is DISABLED BY DEFAULT" and "now enforced in code, not only in prose" were FALSE and are withdrawn.
- **MS6.5.1 (the Darwin per-run dir, its run marker, lifecycle owner, and the census sweep + warning; rev 27 —
  orchestrator + RoseCat 3c39b9f / 012e1bc / 3118838 / ee626d0 / 565e107 / ec24db0 / 7362-7363, mails 7327/7333/7338/7345/7350/7352/7362, 2026-10-21).** The reaper library (`src/agent_run_reaper.c`) is
  reported complete and signal-free on both Macs [Rev 31: SUSPECTED / UNPROVEN, not a released observed run]; this is its **browser-owned** production owner (RoseCat agrees
  that is the right owner). **This signal path is unreachable in production until a named `reaper_ready` hard gate
  passes (see *Gating* below); `seatbelt_ready` is NOT approval of it.** ~~The owner is real launch-path code, not a
  test-only caller~~ **[Rev 29, W2 plan text: FALSE of HEAD. The owner is NOT built. `recoverAllAtStartup` is called only
  by tests; no code creates the run dir, publishes the `active` entry, creates `run.marker` or passes
  `ZB_AGENT_RUN_MARKER_FD` (that name appears only in `hook_run.py`); the module `src/agent_startup_recovery.zig`
  that "recovery completes before the first new agent run" needs DOES NOT EXIST (P-W6). The owner is tracked by bd
  `zigBrowser-3gl` and by MS6.8.]** It will be dormant on two independent gates: the macOS agent-run path
  (`seatbelt_ready`, MS6) and `reaper_ready`.
  - **SCOPED ACCEPTANCE (Rev 28, AUTHORITATIVE — RoseCat `c11bff8`/`cdedf98`; overrides the rest of this MS6.5.1
    body).** What is reviewed and registered (as seam tests only; NOT BUILT as a behaviour under rule 6, Rev 31) in `src/agent_run_ledger.zig` is ONLY: (a) the Linux
    one-live-process liveness probe keyed on the recorded owner `(pid, start)` — schema v2 platform-tagged
    `start_kind`, canonical per-kind shape, `StartRead` I/O outcome mapping, and a **same-kind-only** comparison
    that fails closed on a cross-kind identity — mapped by `recoveryFor` to an action LABEL only (`.recover` /
    `.leave` / `.fail_closed`); and (b) ~~the bounded, cancellable `acquireRunLockBounded` flock-acquisition
    primitive under one absolute monotonic deadline~~ **[Rev 31, V46-F15 / I-W4: STRUCK. `acquireRunLockBounded` is NOT a
    held-lock primitive. It ignores `io` and acquires then RELEASES at once (`agent_run_ledger.zig:470`), so `acquired=true`
    holds no lock. It is a lock PROBE with a deadline (fail-closed `lock_unavailable` on timeout), it is not "BUILT, reviewed
    and registered" as an acquisition, and the two-process exclusion it was said to give does not exist. Fix: rename to
    `probeRunLock` or return the held lock (R29.6 I-W4).]**. **Everything else
    described below in this MS6.5.1 body is NOT YET IMPLEMENTED and NOT ARMED** and is subordinate to this block:
    the startup queue / first-run refusal, the two-browser / other-browser exclusion, the signal / retirement /
    census-kill / marker-unlink / rmdir / ledger-mutating transaction under the held flock, and the `reaper_ready`
    hard gate. No production recovery pass or signal call is reachable, and ~~**there is no `reaper_ready` constant
    yet**~~ **[Rev 31, G6.2: STRUCK. `pub const reaper_ready: bool = false;` exists at `src/agent_run_recovery.zig:334`;
    it is BUILT-UNARMED = NOT BUILT (rule 6), as the next bullet says.]**. The whole-recovery transaction (every item: production owner/call path, held-fd `(dev,ino,uid,mode)`
    provenance before teardown, typed fixed-point outcome, census/kill/fresh-census, marker-unlink → rmdir →
    ledger-retirement under the one flock, one deadline over acquire AND held work, a deterministic exact-result
    two-recoverer red asserting `{.signalled,.already_gone}` + terminal child statuses + empty final ledger + two
    signal entries under the early-unlock mutant, registration, and a full gate) is tracked as the named **OPEN
    blocker bd `zigBrowser-3gl`**. ~~The `b5688e9` prototype is history-only, removed from production source.~~ Read the
    sub-bullets below as the DESIGN for that OPEN blocker, not as implemented behaviour.
  - **REV 29 UPDATE TO THE SCOPED-ACCEPTANCE BLOCK (K1, W2; AUTHORITATIVE).** The block above described the code at
    `ff7c699`. HEAD `e4f705f` contains MORE, all **BUILT-UNARMED**: `RecoveryAction` (`agent_run_ledger.zig:500`),
    `publishWithoutCut`/`publishWithout` (`:547/:557`), `recoverOneUnderLock`/`recoverOneUnderLockP` (`:573/:579`, the
    whole-recovery transaction under the held flock), `acquireRunLockBounded` (`:469`), the startup core
    `recoverAllAtStartup`/`…Gated`/`…GatedH`/`…Full` (`agent_run_recovery.zig:365-410`) and the immutable
    `pub const reaper_ready: bool = false;` (`:334`). What is STILL not built: (1) the production **owner** that creates
    the run dir, publishes `active`, creates `run.marker` and passes `ZB_AGENT_RUN_MARKER_FD`; (2) the **startup
    queue / first-run refusal** module (`src/agent_startup_recovery.zig` does not exist); (3) a **Darwin same-kind
    liveness probe** — `readStatIo` returns `.open_error` off Linux (`agent_run_ledger.zig:332-334`), so even with
    `reaper_ready` true every Mac entry fails closed (**NEW item MS6.5.3: the Darwin liveness probe**, red: a
    Darwin-shaped entry for a live pid is classified `.leave` and for an absent pid `.recover`; today
    `.fail_closed`/`open_error`); (4) the registered tests for the transaction
    (`agent_run_ledger_recovery_txn_test.zig`, `agent_startup_recovery_integration_test.zig` are unregistered);
    (5) the full destructive gate. The owner/call path remains the OPEN blocker bd `zigBrowser-3gl`.
  - **REV 30 UPDATE (rule 6).** BUILT-UNARMED = NOT BUILT: no production caller reaches the transaction, its test is unregistered, it cannot work with the real store name (`4pa.65`), the pid is unchecked (`4pa.68`), and the Darwin cross-compile guard analyses none of it (`4pa.63`). See R30-MS6.
  - **Rev 29 interface hardening of the built code (I-W3, I-W4, I-W5, D-W1, D-W5):** make the gated entry points
    non-`pub` (only `recoverAllAtStartup` is `pub`); rename `acquireRunLockBounded` (it ignores `io` and acquires then
    releases at `agent_run_ledger.zig:470`, so `acquired=true` holds no lock) to a probe name or return the held lock;
    pass the store name through (`recoverOneUnderLockP` hard-codes `"runs.json"` at `:594/614/630` while the plan and
    `recoverAllAtStartup` use `zigbrowser-agent-runs.json`); reject `pid < 2` at parse and require the basename pid ==
    the entry pid; give a cross-kind (Linux-written, Mac-read or the reverse) entry a retire path. Each has its red in R29.6.
  - **Composition of the two gates (C-W8):** a signal is sent **iff `reaper_ready && setting != off`**. `reaper_ready`
    (immutable source constant) and the "Automatically stop leftover agent processes" setting are different gates; the
    env override `ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS` **can only turn auto-stop OFF**, never on, and never overrides
    `reaper_ready`. Red matrix (Linux, injectable engine): `(reaper_ready=false, setting=on)` ⇒ 0 signals;
    `(true, off)` ⇒ 0 signals; `(true, on)` ⇒ signals; env `=on` with `reaper_ready=false` ⇒ 0 signals; env `=off` with
    `(true, on)` ⇒ 0 signals. Mutant: OR the two gates → the `(false, on)` row signals (must be caught). Property over
    the {reaper_ready} × {setting absent/on/off/malformed} × {env absent/on/off} domain: signals > 0 ⇒ reaper_ready ∧
    setting ∈ {absent, on} ∧ env ≠ off.
  - **Test reality (T5).** The tests this block names as `tests/agent_run_ledger_concurrency_test.c` and
    `tests/agent_run_recovery_test.c` DO NOT EXIST and are **TO BE AUTHORED** (the two-process reds below); the existing
    related files are `agent_run_ledger_{test,crashcut,boundary,marker_shape}_test.c`, the Zig
    `agent_run_ledger_{lock,recovery,recovery_busy,recovery_txn,deadline,watchdog}_test.zig` and
    `agent_run_recovery_{startup,concrete}_test.zig`. Registration rule: no production code without a registered test.
  - **The per-run dir, created with recorded provenance (RoseCat 7327 #2).** At run start the owner opens the
    app-owned runtime dir once (`O_DIRECTORY|O_NOFOLLOW`, held — this is the pinned 0700 parent), then creates the
    per-run dir RELATIVE to that held fd — `mkdirat(runtime_fd, "zigbrowser-agent-<pid>-<16 lowercase hex>", 0700)`
    then `openat(runtime_fd, name, O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` — so creation is not subject to a path race.
    It then **publishes a provenance ledger entry** recording the run dir's root identity (basename), its pinned
    `(dev, ino)` from `zb_reaper_pin_fd`, its `uid` and `mode`, the owning pid + start time, and a lifecycle state
    field. Grammar + 0700 + this-uid + the held-fd pin are necessary but NOT sufficient to signal: **a dir is
    swept ONLY if a published ledger entry exists whose no-follow REOPENED fd's `fstat` `(dev, ino, uid, mode)`
    matches the recorded tuple exactly.** Every other shape is census/quarantine/WARN, never signal:
    - *name-only* (grammar matches, no ledger entry) → unrecorded leftover, warned, never signalled;
    - *swapped* (ledger entry exists but the reopened `(dev, ino)` differs) → the dir was replaced under the name →
      never signalled (this is the fd-pin / old-path mutant the census probe already proves);
    - *symlinked* (the entry's path is not a real dir via `O_NOFOLLOW`) → refused, warned, never signalled;
    - *malformed/unreadable ledger row* → no auto signal, fixed warning;
    - *duplicate* (two entries claim the same basename) → neither signalled, both warned;
    - *stale* (recorded pid/start no longer live or reused) → the dir may still be rmdir-swept via the pin, but a
      PROCESS is signalled only through the marker+census guard below, never from the stale pid in the row.
    (macOS netd serves over loopback and makes no egress sockdir, so this run dir is the browser-owned run root,
    distinct from Linux's.)
  - **The ledger is versioned, strictly parsed, atomic, fsynced, and outside the sandbox (RoseCat 012e1bc #2).**
    The store is `<runtime_dir>/zigbrowser-agent-runs.json` (0600) with an explicit `schema_version` and a bounded,
    strictly-parsed shape: a capped array of entries, each `{basename, dev, ino, uid, mode, pid, start, state}`
    with fixed types and lengths; an unknown version, an over-cap array, a missing/extra/mistyped field, or a
    truncated/unparseable file is a **malformed read** → no automatic signal + a fixed warning, and the dirs it
    would have covered are censused + warned, never signalled. The agent runs with its cwd in the user's workspace
    and the Seatbelt profile does not grant write to `runtime_dir`, so **no sandboxed process can write the
    ledger** — it is app-owned.
    - *An OS-visible, cross-process ledger lock — no lost update between app instances (RoseCat ee626d0 #1).*
      `zigbrowser-agent-runs.json` is a **user-global** recovery ledger that a later — or concurrently running —
      zigBrowser PROCESS also reads, so a process-local mutex is NOT enough: two app instances would hold two
      separate mutexes and could each read revision N and publish different N+1 files. The transaction is therefore
      guarded by an **OS-visible advisory lock** on a dedicated lock file
      (`<runtime_dir>/.zigbrowser-agent-runs.lock`, opened `openat` relative to the pinned runtime-dir fd,
      `O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW`), **acquired with a BOUNDED, cancellable `LOCK_EX|LOCK_NB` + monotonic
      retry (never a blocking `flock(LOCK_EX)`)** — a blocking wait cannot be capped by any deadline, so a frozen
      live holder would wedge the bounded startup queue and every new agent run indefinitely (RoseCat 7362/7363).
      Acquisition shares the SAME total monotonic deadline as the work it guards; **acquire-failure / deadline /
      cancel ⇒ fail closed** — no liveness/census/signal/retire/unlink/ledger mutation, the entry is retained, a
      fixed **recovery-busy / lock-unavailable** incident is surfaced, the UI stays responsive, and the first new
      agent run is **refused or deferred rather than hung**; a later retry may succeed. Once held, it is **released
      by process death** (the kernel drops the flock when the holder dies, so a crashed instance never wedges the
      ledger). Under that lock each mutation is one indivisible transaction:
      **read-the-current-file → validate/parse → apply this run's delta → write sibling temp
      (`O_NOFOLLOW|O_CREAT|O_EXCL`) → `fsync` temp → `rename` over the store → `fsync` the parent dir fd → release**.
      No read-modify-write straddles two runs OR two processes, so no instance's publish/update/remove can drop
      another's entry. This **one global flock is the only cross-process claim** — there is no per-run lock file.
      It is also **held across the WHOLE terminal cleanup sequence** (claim → marker unlink → `rmdir` → ledger
      removal; see `Clean` below), so the destructive teardown is one atomic, crash-released critical section and
      two recoverers can never race it. The lock fd is `O_CLOEXEC`, so no agent child ever inherits the claim.
    **Startup ordering (fixed):** `mkdirat` the run dir → `openat`+`pin_fd` → **create `run.marker`** → **publish
    the `active` entry** → **ONLY THEN spawn any process** (netd/helper/…, which carry the marker). So the marker
    exists before any child could inherit it, and the entry is `active` before any marker-holder can exist — a
    leftover is therefore always recorded. An unpublished dir can be censused + warned but never authorizes a
    signal; a half-written temp is never renamed into place. Every crash cut and its single idempotent, signal-free
    recovery are enumerated in the **crash-cut table** below.
  - **The run marker — a dedicated non-token capability inherited EXPLICITLY at every seam (RoseCat 012e1bc #1).**
    The agent's cwd is the user's workspace, and a merely non-`O_CLOEXEC` fd is NOT enough: `zb_agent_spawn_group_io`
    enables `POSIX_SPAWN_CLOEXEC_DEFAULT` and its contract is that the child holds **exactly fds 0, 1 and 2**
    (`agent_spawn_posix.c:47-65`, `agent_spawn_posix.h:17-24`), and Python subprocesses close inherited descriptors
    by default too. So the marker travels only if each seam is made to carry it on purpose.
    - *The capability.* A per-run READ-ONLY, **non-token** marker file `<run-dir>/run.marker` (0400, empty — its
      presence is the whole signal, it carries no secret) opened `O_RDONLY`. The owner dups it onto a single
      **reserved descriptor number `ZB_AGENT_RUN_MARKER_FD`** at each spawn, chosen to NOT collide with the token
      (`fd 3`), the egress channel (`fd 4`), the census-broker `--census-fd`, or the hook's `>= 10` memfd range —
      the marker takes a fixed low number of its own (e.g. `fd 5`), asserted distinct in a shared header.
    - *The authority fd stays private.* The run-dir fd (`O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`) + its pin is the owner's
      sweeping handle; it is `O_CLOEXEC` and is **never passed to any child**, so it can never make a process
      classify. The marker and the authority are two distinct descriptors with opposite inheritance.
    - *Every real propagation seam carries the marker explicitly, and each gets its own production-chain red + a
      drop-the-pass-fd mutant:*
      - **browser → netd:** `zb_agent_spawn_group_io` names only 0/1/2, so netd needs the marker added as an
        explicitly-inherited action (a `posix_spawn_file_actions_addinherit_np`/`adddup2` of `ZB_AGENT_RUN_MARKER_FD`,
        the same mechanism the file already uses for fd 2) — a new named spawn parameter, not a non-CLOEXEC side door.
      - **browser → helper:** the backend passes the marker on `ZB_AGENT_RUN_MARKER_FD` alongside the token (helper
        gets 0-4 today; the marker is added as a distinct descriptor, never multiplexed onto fd 3/4).
      - **sandbox-exec / CLI relay:** `relay._close_inherited(keep)` (`relay.py:250-299`) must keep
        `ZB_AGENT_RUN_MARKER_FD` in its `keep` set (it already keeps the listener/token fds), so the relay does not
        drop it before exec.
      - **nested hook:** hooks get only 0-2 today (`relay.py:273`); the hook launcher must additionally inherit the
        marker (via the same memfd-style explicit inheritance `hook_run.py` uses for its `>= 10` descriptor), so a
        hook — the very process that double-forks + `setsid`s — still holds it.
      - **double-fork + setsid:** `fork` keeps fds and `setsid` closes none, so once the hook holds the marker the
        detached grandchild keeps it unless it explicitly closes it.
    Because the marker file sits under the 0700 run dir, the reaper's EXISTING open-file classifier
    (`zb_reaper_path_under` over each fd's vnode path) catches any process holding it — **no reaper code change**;
    the owner's whole job is to create the read-only marker and pass it at each seam. A sandboxed process cannot
    forge it or point it elsewhere (it cannot write the 0700 run dir). Two negatives are proven: an **unrelated**
    browser child (not part of a run) never receives the marker, and the marker number never collides with fd 3 or
    the census broker. **A process that closes/scrubs its inherited marker is the accepted residual** — the census
    cannot see it, it is never signalled, and any remaining leftover still raises the survivor warning from the
    dir-level ledger recovery. (This is the exact macOS libproc completeness gap the census probe documents.)
  - **The lifecycle owner + an exactly-once state machine (RoseCat 7327 #3).** The macOS agent-run state (the Zig
    host spawner's per-run struct — the macOS counterpart of `agent_host.c`'s `zb_net`) holds the runtime-dir fd,
    the authority fd + pin, the marker fd, and the ledger entry for the run's life, and owns:
    `Running -> Stopping` (sweep the run dir via the authority fd + pin + marker, after netd/CLI/helper teardown —
    both the quit path and the die-with-browser path reach it) `-> Clean` (proven no survivor) or `-> Survivors`
    (some could not be stopped). The ledger entry carries an explicit **lifecycle state** — `active`, `left`, or
    removed — so every terminal choice is durable across a crash. (There is **no per-run lease file**: the single
    global ledger flock is the only cross-process claim, and liveness is proved from the entry's `(pid, start)`.)
    - *A bounded census→kill→fresh-census FIXED POINT — one snapshot cannot prove clean (RoseCat 3118838 #2).* The
      production primitive gathers once and processes only that fixed list (`agent_run_reaper.c:188-202`), but a
      marked process can `fork` AFTER the gather and before its parent is killed, so the child is absent from the
      list and Unix would still allow unlink/rmdir while it holds the (now-unlinked) marker. `Stopping` is therefore
      an owner-level **loop**: census → kill the found set → re-census, repeated until a **complete, empty final
      census** (the fixed point). Only that empty-and-complete final census authorizes `Clean`. A cap on passes, a
      total deadline, or ANY incomplete/overflowed census on the way is **not** clean → `Survivors`, authority
      retained. Normal `Stopping` (window-close / quit) runs **off the UI thread under a total deadline**, like the
      startup sweep; it never blocks window teardown.
    - *Which owner reaches `Stopping`.* A run is owned by the **session/window that started it**; closing that
      window (or app quit) triggers that run's `Stopping`. If the run outlives its starting window (detached), the
      app-level owner reaches it on quit. Both paths converge on the run's single **in-process** state lock (not a
      lock file — the cross-process claim is the global ledger flock).
    - *`Clean` terminal sequence — one claim across the whole thing (RoseCat 565e107; orchestrator simplification).*
      Reached only after the empty-and-complete final census. The entire sequence runs **under the one global ledger
      flock** (the claim), each `unlinkat` relative to the pinned `run_dir_fd` with `O_CLOEXEC|O_NOFOLLOW` fds, in
      this order: **(1) claim** the flock → **(2)** `unlinkat(run_dir_fd, "run.marker", 0)` → **(3)**
      `unlinkat(runtime_fd, name, AT_REMOVEDIR)` (remove the now-empty run dir by name under its pinned parent) →
      **(4)** remove the entry from the ledger (the usual read/validate/update/temp/fsync/rename/parent-fsync) →
      release. No per-run lock file is created or unlinked, so there is no split-inode race. Because the single
      claim spans (2)-(4), a crash releases it (process death drops the flock) and the next recoverer re-claims and
      finishes idempotently; two recoverers can never both run the sequence. The two interior crash cuts, and all
      the others, are in the crash-cut table below — each recovery is signal-free and idempotent.
    - *The authority (fd + pin + marker + ledger entry) is retained until the incident is resolved;* `rmdir` of the
      run dir AND removal of the ledger entry happen ONLY after the fixed-point clean result — any scan error,
      overflow, invalid pin, cap/deadline hit, or non-empty final census is never "clean" and never authorizes
      unlink/rmdir/record removal.
    From `Survivors`:
    - **[Stop them now]** runs the FRESH census→kill→fresh-census fixed point through the retained fd+pin+marker
      (never the stale pid list the warning was built from — a pid may have exited and been reused); only an
      empty-and-complete final census then runs the `Clean` teardown above. **[Stop them now] is DISABLED** (not
      "act on what is known") whenever that fresh census is incomplete — overflow, `EIO`, an invalid pin, or a
      cap/deadline hit — because a partial census cannot authorize a signal; the warning then offers only
      [Show details] and [Leave].
    - **[Leave them running]** **retires** the run: it transitions the ledger entry to the terminal `left` state
      (NOT removed, NOT `active`) and dismisses the warning. A `left` entry is **never swept** — not this session,
      not at next start — so the app never auto-stops a run the user chose to leave; next start only *reconciles* it
      (drop the entry if its dir is gone, else census-only + warn, never signal). This stays safe while the process
      still holds the marker precisely because `left` forbids the signal.
    - **[Show details]** re-censuses read-only for display; it never signals.
    Stop / quit / window-close each fire the transition EXACTLY once (the machine refuses re-entry under the run's
    in-process state lock), so quit racing a warning action can neither double-kill nor skip cleanup: whichever
    reaches the lock first runs, the other is a no-op. A browser **SIGKILL cannot run any exit callback**, so the kill-by-browser
    case is covered solely by next-start recovery, not by the `Stopping` transition.
  - **At the next app START — never touch another LIVE app's runs (RoseCat ee626d0 #2 / 565e107 #5).** A second
    zigBrowser instance may be running while A and A's marked children are still live, so a valid `active` entry is
    NOT by itself a prior-SIGKILL leftover. Liveness is proved from the entry's recorded **owner `(pid, start)`**,
    under the global ledger flock, with ONE authoritative fail-closed rule:
    - **the pid is ABSENT** (no live process with it) ⇒ the owner is proved dead ⇒ recovery work: re-`pin_fd` and
      run the same `Stopping` transition (which re-censuses from scratch);
    - **the pid is LIVE and its start matches** ⇒ the owner (another instance) is alive ⇒ **leave the run entirely
      untouched** — never signal, never retire, never rmdir;
    - **the pid is LIVE but its start DIFFERS (PID reuse), or liveness is UNREADABLE** ⇒ **fail closed** —
      census-only + warn, never signal or retire. (Per `ee626d0`, reuse is never treated as "proved dead".)
    This is the only PID-reuse rule in the plan. **A recoverer holds the one global flock across the WHOLE recovery
    of an entry — liveness revalidation → census/kill/fresh-census fixed point → marker unlink → `rmdir` → ledger
    removal — releasing only at the end**, and it **acquires that flock with the bounded `LOCK_EX|LOCK_NB` + retry
    inside the same total recovery deadline** (the deadline caps BOTH the wait-to-acquire and the held work — a
    blocking acquire would be uncapped). So exactly one recoverer ever enters the signal (kill) phase for a given
    entry; a second recoverer that cannot acquire within the deadline **does nothing on disk** — zero
    signal/mutation, the entry retained, a recovery-busy incident surfaced, the first new agent run refused/deferred
    (never hung), and a later retry may recover once the holder releases. Revalidating liveness **after** taking the
    flock also closes the window where the owner was alive at the first read but died before the claim. The
    owner-driven `Stopping` path takes the flock with the **same bounded acquisition** before its terminal mutation;
    on acquire-failure/deadline it stays **`Survivors` with authority retained** — never a signal, never an
    uncoordinated clean.
    `left` entries are reconciled only (never swept); grammar dirs with no matching ledger entry, and entries that
    fail the fstat match, are censused
    + warned, never signalled. This runs on a bounded **startup queue** off the UI thread: it never blocks window
    creation, it completes before the first NEW agent run may create its dir (so a new run is never mistaken for a
    leftover), and because there may be **no main window yet**, it holds its incident on the queue until the drawer
    exists, then surfaces the warning (the no-main-window delivery path).
  - **Crash cuts vs. recovery (every cut signal-free + idempotent).** With no per-run lock file there are only four
    cuts; the `Clean` cuts (C2–C4) sit inside the single held global flock, so a crash releases the claim and the
    next recoverer re-claims and finishes.

    | # | Crash point | On-disk state | Recovery (always signal-free, idempotent) |
    |---|---|---|---|
    | C1 | after `mkdirat`+`openat`+`pin_fd`, before publishing `active` | run dir (+ marker) exists, **no ledger entry** | unrecorded dir → censused + **warned**, never signalled |
    | C2 | claim held, after `unlinkat(run.marker)`, before `rmdir` | provenance-valid, EMPTY, **marker-less** dir; `active` entry | `openat(run_dir_fd,"run.marker",O_RDONLY|O_NOFOLLOW)` ⇒ `ENOENT` = durable teardown phase ⇒ finish `rmdir` + entry-remove; no signal (final census was empty, no marker to classify by) |
    | C3 | claim held, after `rmdir`, before entry removal | `active` entry **naming no dir** | `openat` of the run dir ⇒ `ENOENT` ⇒ drop the entry (reconcile); no signal |
    | C4 | mid ledger mutation (temp-write / rename) | the store is **old-or-new, always a complete JSON, never torn**: a crash before the atomic `rename` leaves the old complete store, after it the new complete store; the half temp is never renamed | a reader always sees one complete store; recovery is idempotent on **both** sides of the rename (re-running the mutation under the flock converges to the same result) |

  - **Contracts (RoseCat 7327 #4).**
    - *Setting — a named app-owned persisted value, not only a startup override.* **"Automatically stop leftover
      agent processes"** lives in the app-owned persisted config (the same store the drawer config uses,
      `agent_config`), written atomically (temp+fsync+rename+dir-fsync) through the drawer toggle's **UI write
      path**. Precedence, highest first: an explicit env override (`ZIGBROWSER_AGENT_AUTO_STOP_LEFTOVERS`, the
      `env_switch` pattern) > the persisted setting > the default (**on**). Matrix: **absent (default) or on** ⇒
      sweep what it can, then warn only on survivors; **off** ⇒ census only, then always warn, never signal;
      **malformed persisted value / read failure** ⇒ no automatic signal + a fixed warning/error (treated as off,
      surfaced), never a guess.
    - *Atomic store:* the app-owned ledger `<runtime_dir>/zigbrowser-agent-runs.json` (0600), published by the
      temp+fsync+rename+parent-fsync protocol above; never writable from inside the sandbox.
    - *Error:* every failure fails CLOSED — a failed pin/validation, a `realpath`/`openat`/`fstat` mismatch, or an
      incomplete census (`EOVERFLOW`/`EIO`, overflow set) yields NO signal and a warning with what IS known; never
      a broad or wrong kill, and never an rmdir/record removal.
    - *Details collector:* `zb_reaper_census`/`zb_reaper_sweep` return **only pids**. A separate bounded,
      signal-free collector gathers `(pid, command, cwd)` for **[Show details]** via `proc_pidpath` +
      `proc_pidinfo`, capped at the reaper's 512 with the overflow flag surfaced, each field truncated to a fixed
      byte bound; an unreadable row is shown as a placeholder (pid only), never dropped and never signalled.
      **No command/cwd detail is written to logs or telemetry** — details exist only in the live drawer view.
    - *Startup queue:* a single run-at-start task, idempotent and bounded (a cap on recovered dirs per start), that
      drains the recorded leftovers before the first new run and reports completion to the drawer.
  - **Bounds (RoseCat 7327 SHOULD).** The startup scan recovers at most a fixed number of dirs per start; the
    details view shows at most a fixed number of pid rows; each `command`/`cwd` string is truncated to a fixed
    byte length. Exceeding any bound surfaces an "and N more" note, never an unbounded read.
  - **Gating (RoseCat 3118838 #3 — an immutable acceptance constant, NOT an env switch).** Readiness is a
    source/build acceptance constant, exactly like `agent_setup.zig:60-73`'s `pub const seatbelt_ready = false;` —
    `pub const reaper_ready: bool = false;` (**Rev 29: EXISTS at `src/agent_run_recovery.zig:334`**) flipped to `true`
    only by a reviewed source edit after the destructive Mac reaper gate passes. It is NOT the `env_switch` pattern (`env_switch.zig:1-27` is flag/environment-driven, so
    a hostile ambient environment or CLI value could arm it — forbidden here). It sits BETWEEN the owner and any
    real signal: production kill paths are **unreachable** — `zb_reaper_sweep`/`zb_reaper_run_full` are never called
    with a live `killsig` — while `reaper_ready` is false. Any test override is **e2e-only and absent from the
    production build** (a build/source assertion of that is a TRIPWIRE — not proof; the proof is the hostile-environment runtime test under *Testing*). `seatbelt_ready` gates the agent run; `reaper_ready` separately gates the reaper's signal
    path, and one does not imply the other. Until it is flipped, the owner's Mac behavior is census-only (warn,
    never signal), exactly as the gates below exercise. A **bypass mutant** — a build that reads readiness from the
    environment, or calls a live `killsig` while `reaper_ready` is false — must fail.
  - **Testing — the red matrix.** Mac tests/gates stay **census-only**; the destructive sweep (real SIGKILL) and
    its real-escape row stay **OFF the Macs** until `reaper_ready`'s destructive gate is reviewed and passes.
    - *Provenance (Linux, under `unshare`):* red `tests/agent_run_ledger_test.c` → green `zb_reaper_ledger_*` in
      `src/agent_run_reaper.c`. Assertions: a dir with a matching published entry sweeps; name-only / swapped
      `(dev,ino)` / symlinked / malformed-row / duplicate / stale → never signalled (kill intercepted, asserted
      zero calls). Mutants: drop the fstat match → the swapped-dir row fires a kill (must be caught); publish the
      ledger BEFORE pin → a crash-cut window signals an unrecorded dir (must be caught).
    - *Atomic ledger (Linux):* red in the same file → green publish helper. Assertions: a crash between temp-write
      and rename leaves the old store intact; the parent dir is fsynced; a half temp is never renamed. Mutant:
      write-in-place instead of temp+rename → a torn read is accepted (must be caught).
    - *Cross-process ledger lock + whole-recovery claim (Linux, TWO-PROCESS/TWO-RECOVERER reds):* red
      `tests/agent_run_ledger_concurrency_test.c` spawns **two independent processes** taking the one `flock` on
      `.zigbrowser-agent-runs.lock`. Assertions: (a) publish/publish and publish-or-remove/update interleaved at a
      barrier — BOTH entries survive; (b) with **one real marked child** of a proved-dead owner, two recoverers race
      the whole recovery (revalidate → fixed point → marker-unlink → rmdir → entry-remove) — **exactly one enters
      the signal (kill) phase**; the other, once it acquires within the deadline, re-reads and finds the entry gone
      and does nothing. Mutants: remove the inter-process `flock` → a lost update (a); **release the flock early
      (hold it only across the ledger write, not across revalidation + the fixed point) → BOTH recoverers enter the
      signal phase** (b) (both must be caught).
    - *Bounded flock acquisition — a live-stalled holder must not wedge recovery (Linux, TWO-PROCESS red):* red in
      `tests/agent_run_ledger_concurrency_test.c`. Process A acquires the global flock and **deliberately stalls
      while alive**; independent B's startup recovery returns the **fail-closed result within the total monotonic
      deadline** — zero signals, NO on-disk mutation, the entry retained, a recovery-busy incident surfaced, and the
      first new agent run refused/deferred (not hung). After A releases, a retry may recover. **Mutant: a blocking
      `flock(LOCK_EX)` acquire → B exceeds the deadline / hangs and is killed by the test watchdog (must be
      caught).**
    - *Startup recovery excludes a live owner, by `(pid, start)` (Linux, TWO-INSTANCE red):* red
      `tests/agent_run_recovery_test.c` models A (a live owner recorded with its `(pid, start)` + a live marked
      child) and B starting fresh. Assertions: B leaves A's run untouched while A's `(pid, start)` is live (no
      signal, no retire); B recovers only once A's pid is ABSENT; a pid LIVE-with-different-start (reuse) or an
      unreadable liveness result **fails closed** (census-only, no signal/retire). Mutant: recover on a valid
      `active` entry WITHOUT the liveness check → B signals the other live instance's child (must be caught).
    - *Clean fixed point — one gather cannot prove clean (Linux, injectable engine + a real fork):* red extending
      the engine test with a process that `fork`s AFTER pass-one's gather and before the parent's kill. Assertions:
      `Clean` (and its unlink/rmdir/record-remove) is reached ONLY after a complete, EMPTY final census; a
      cap/deadline/incomplete census holds `Survivors` and keeps the authority; the spawn-during-pass-one child is
      caught by the re-census before any unlink/rmdir. Mutant: no re-census (sweep once on the first gather's list)
      → the forked child survives while its dir is unlinked/rmdir'd (must be caught).
    - *Crash cuts C1–C4 (Linux) — one idempotent, signal-free recovery row EACH (the crash-cut table):* a red per
      cut stops teardown/publication at that exact point, then runs recovery. C2 (marker-less empty dir):
      `openat("run.marker")`⇒`ENOENT` ⇒ finish rmdir + entry-remove, NO signal, NOT a permanent incident; mutant:
      treat it as a fresh grammar leftover (warn-forever / re-census for a signal) → a permanent incident appears.
      C3 (entry naming no dir): `openat(run dir)`⇒`ENOENT` ⇒ drop the entry, NO signal. C1 (unpublished dir):
      censused + warned, never signalled. C4 (mid temp/rename): the store is old-or-new complete, never torn, and
      recovery is idempotent on BOTH sides of the rename (mutant: write-in-place → a reader sees a torn store).
    - *Marker propagation — one production-chain red + one drop-the-pass-fd mutant PER SEAM (a generic
      child-inherits-marker probe does NOT satisfy this; it bypasses the production chain).* Reds drive the real
      spawn/relay/hook code, each asserting the downstream process classifies (holds a marker whose vnode is under
      the run dir), then a mutant removes exactly that seam's pass:
      - **browser→netd:** red through the real `zb_agent_spawn_group_io` marker parameter (extend
        `tests/agent_spawn_posix_*`); mutant: drop the marker `addinherit_np`/`adddup2` → netd no longer classifies.
      - **browser→helper:** red through the backend's helper spawn; mutant: drop the marker from the helper's passed
        fds → the helper no longer classifies.
      - **sandbox-exec/CLI relay:** red through `relay.py` with the marker in `_close_inherited`'s `keep`; mutant:
        remove it from `keep` → the relayed CLI no longer classifies.
      - **nested hook + double-fork:** red through `hook_run.py` inheriting the marker into a hook that
        double-forks + `setsid`s; mutant: drop the hook's marker inheritance → the detached grandchild no longer
        classifies.
      - **negatives:** an unrelated browser child never receives the marker (no classify); the reserved marker
        number never equals the token `fd 3`, the egress `fd 4`, or the census-broker fd (a static assertion in the
        shared header is a TRIPWIRE — not proof; the per-seam production-chain reds above are the proof). The signal-free Mac leg of `tests/mac/ms6_5_reaper_census_probe.c` is extended to exercise
        the real reserved-fd inheritance end-to-end (still zero kill).
    - *Lifecycle cuts + exactly-once (Linux, injectable engine):* extend
      `tests/agent_run_reaper_engine_test.c`. Assertions: `Running→Stopping→Clean` rmdirs + removes the entry only
      on a proved-clean result; a scan error/overflow holds `Survivors`, keeps the authority, and does NOT rmdir;
      `[Leave]` preserves the entry + dir; Stop/quit/window-close re-entry fires the transition exactly once
      (second entry is a no-op). Mutant: rmdir on an overflowed (not-clean) census → caught; allow re-entry →
      a double-sweep is observed (must be caught).
    - *Setting matrix + startup queue (Linux):* red → green over `env_switch`. Assertions: absent/on sweeps then
      warns; off censuses then warns (zero kill); malformed → no signal + fixed warning; the startup queue is
      idempotent, bounded, drains before the first new run, and queues the incident until a drawer exists.
    - *`reaper_ready` gate (Linux/source):* red → green the immutable constant. **Rev 29 (T3): the proof at HEAD is a
      source `indexOf` (`tests/agent_run_recovery_startup_test.zig:184-194`), which a stub or a comment satisfies; it
      is demoted to a labelled tripwire and REPLACED by a runtime hostile-environment test** (set
      `ZIGBROWSER_REAPER_READY=1`, `ZB_REAPER_READY=1`, argv `--reaper-ready`, then call the production startup entry →
      assertion `actuator_calls == 0`; mutant: read readiness from the environment → `actuator_calls > 0`, must be
      caught). Assertions: with `reaper_ready`
      false, no owner path reaches a live `killsig` (census-only); a source/build assertion about where readiness is read from would be a TRIPWIRE — not proof; the runtime hostile-environment test above is the proof. Mutants: a build that sources readiness from the
      environment → caught; a live `killsig` call while `reaper_ready` is false → caught.
    - *The warning is UI* and gets the **user's real-screen acceptance** on the NVIDIA screen (per the per-slice
      real-screen rule), not an Xvfb pass.
- **MS6.6 (gate, rev 18): R1 under Seatbelt.** setup's R1 probe proves "the CLI takes the token from fd 3 and no
  CLI environment holds it" on macOS, without giving the code under test any introspection.
  - **Topology** (RoseCat 7019; BlueBeaver 7021; JadeBeacon 7023):
    - setup pre-binds the probe's one loopback listener outside the sandbox and passes it by `pass_fds`;
    - setup's profile permits exactly that port (`loopback_port`) and keeps the token-isolation belt (no
      process-info of others, no `kern.procargs2`);
    - the process census runs in **setup, outside Seatbelt**, over setup's own descendants
      (`proc_darwin.cli_env_clean`);
    - the probe only asks, over a socketpair end it receives as `--census-fd`;
    - R1 needs both the probe's verdict and setup's own clean census.
  - **Dependency (A), census broker plus kernel properties:**
    - the Linux unit reds `61776d9` and `7590369` (exact request and reply, bounded lifecycle, a forged-capability
      negative through the production wrapper, grammar);
    - `tests/mac/ms6_r1_kernel_gate.sh` (`cd38735`) on both arches. Inside the real setup profile: the R1 port is
      reachable, a decoy is denied (Seatbelt errno), and `procargs2`/`pidpath` of live targets are denied
      (Seatbelt errno). An unsandboxed control shows the same calls succeed. Outside, setup's census finds the
      canary, and a planted token is dirty, after that run's own positives hold.
    - **A green in (A) lets the broker implementation land, but scoped and incomplete.** It does not close
      `61776d9`/`7590369`, MS6 or `seatbelt_ready`, and Mac agent launch stays disabled.
  - **Dependency (B), the production chain:**
    - the real Mac `setup.probe_r1 -> sandbox-exec -> route_probe -> the inherited listener and census fds ->
      the wrapper -> a controlled CLI` chain, on **both** arches;
    - **driven by a pre-`seatbelt_ready` hard-gate harness** (rev 18.1; RoseCat 7120): it imports the production
      `zb_agent_host.setup` from the staged pinned runtime and calls the real `setup.probe_r1` directly. That spawns
      the generated setup profile, the socketpair and the listener exactly as production does. It does **not** go
      through the browser, and it is **not** a case of `ms5_setup_e2e.sh`, which refuses to arm until
      `seatbelt_ready` is true. Requiring that would be a cycle: (B) gates `seatbelt_ready`. The normal app stays
      fail closed, with `platformGate` unchanged;
    - run with the **pinned production runtime and dependency tree**; a scratch, unlocked wheel set is not
      evidence;
    - it keeps the exact `pass_fds`, the forged-capability negative, listener service, the census request and
      reply, the timeout/lifecycle cases and the planted-token control.
    - **(B) is a hard prerequisite of `seatbelt_ready`, MS6 completion, and any launch slice consuming the Mac
      backend.** It waits only on the MS5 dependency and CLI layout decision (rev 17), which pins the runtime and
      dependency tree it stages; it does not wait on `seatbelt_ready` or on the armed `ms5_setup_e2e.sh`.
  - **Resolved (rev 18.1):** the rev 18 blocker, HEAD's setup profile killing the real interpreter with SIGILL, is
    fixed by JadeBeacon's `aa83b5f`, `(allow process-info* (target self))`. (A) then reached its intended census
    seam and went green on both Macs (`47199d3`, `ac15dfd`) [Rev 31, rule 8: agent-reported, SUSPECTED / UNPROVEN; the plan
    cannot cite an observed released run].

### Workflow Closure (MS6.1 — token isolation; the load-bearing security belt)   [BLOCKING — Rev 29: OPEN, NOT implemented (W1); see R29-MS6 "MS6.1 closure — relabel and keep OPEN" and MS6.8. `mac_session.py` below does not exist; the trigger `zb_agent_run_sync` → `MacSeatbeltBackend` is not a production path.]
- **Chain:** `token stored -> helper reads fd 3 -> MacSeatbeltBackend spawns CLI under profile -> CLI holds token -> hook spawned app-side under its own profile -> hook attempts task_for_pid/KERN_PROCARGS2 -> kernel denies -> hook's recorded result = denied, no canary bytes`
- **SOURCE (seed):** the stored token (Keychain/file) + the fixture SAI with the malicious hook +
  a **deterministic sacrificial target**. **TRIGGER:** the browser launching the agent
  (`zb_agent_run_sync`), boundary = `highest_new_connector = MacSeatbeltBackend`. **DRIVER:** none
  async in the observed span (the read returns bytes or EPERM synchronously). **OBSERVE:** the
  hook's recorded attempt file scanned for the canary + the syscall return codes. **FORBIDDEN
  SPAN:** the launcher internals, the profile application, the CLI process. **RED-AT-SEAM:** remove
  the task-port/process-info denies → the hook reads the canary → **red**. **EXECUTION:** real
  binary on a Mac via the released `tests/mac` gate (no `mac_session.py` exists); needs `/usr/bin/sandbox-exec` + the bundled CLI; missing ⇒
  **exit nonzero**. (ClosureMap emitted at build time pinned to the then-current HEAD; its symbols
  — `MacSeatbeltBackend`, the app-side hook spawn — are created here.)

**Gate (MS6) — Rev 29:** real-binary macOS sandbox e2e (MS6.1–MS6.5, plus the new MS6.7 curation, MS6.8 launch
connector and the conformance test) on both arches. Today the MS6 evidence is a set of hand-run probes
(`ms6_gate.sh`, `ms6_1_*`, `ms6_3_*`, `ms6_4_*`, `ms6_5_*`, `ms6_generated_profile_test.sh`, `ms6_harness_mac_gate.sh`,
`ms6_hard_gate.sh`) with no registered `ms6-gate` step; MS6 is **not complete** until MS6.1 closes through MS6.8, MS6.7
lands, readiness is one type (D2), conformance (I1) is registered, and an `ms6-gate` step with a last-approved-run
manifest exists. Mac runs follow R29-SAFETY: the original wording "the one-day spike is
run on a Mac by an agent, results recorded as red→green" is read as "recorded at the compile-only tier, or on a Mac
only with RoseCat exact-commit approval and orchestrator release". **MS8 is blocked** until all MS6 gates are
green **or** the VM backend lands behind the shared contract. Not a UI slice. Coordinate with
**BlueBeaver** (sandbox/helper) and the orchestrator (spike scheduling).

### R30-MS6 — Rev 30: MS6 findings (validation ms4-6 F1, F3, F4, F5 (MS6 half), F6, F8, F9, F12-F15; AUTHORITATIVE)

Rule 6 applies to the whole slice: no production path launches the agent under Seatbelt. Rows below that say NOT BUILT mean
"present as a seam with a driven test, but no production caller". Mac execution follows R29-SAFETY.

- **[bd `zigBrowser-4pa.63`, V46-F1, MAJOR] The Darwin cross-compile guards are vacuous — STATUS CORRECTION (tripwire) + RED +
  FIX-FORWARD.** `build.zig:1043-1052` builds `src/agent_run_ledger.zig` as a macOS object for both arches (comment at `:1044`:
  "every top-level decl in the root file is analyzed") and runs in `zig build test` (`:3636-3637`); `build.zig:1159-1168` does
  the same for `agent_run_recovery.zig`. Zig analyses lazily and neither file has an `export` or a forcing `comptime` block, so
  its `pub` functions are never analysed for Darwin. Observed at d0f1841: an unreferenced `pub fn` with a type error appended
  to `agent_run_ledger.zig` still exits 0; the same error reached from one `export fn` exits 1. The guard is a **tripwire, not
  proof**; it compiles only the C reaper body.
  - Fix: build the Darwin object from a root that references every `pub` declaration (`comptime { std.testing.refAllDeclsRecursive(@This()); }`
    in a small wrapper root, or an export wrapper).
  - Red (Linux, hostless): a meta-test step `test-darwin-guard-selftest` (TO BE ADDED to `test`) writes a probe file with a
    Darwin-only type error in an unreferenced `pub fn`, builds it through the SAME guard-root helper `build.zig` uses, and
    asserts `rc != 0`. Fails today (rc 0). Mutant: the old guard root → rc 0 → the meta-test fails.
  - Exercising proof of "the ledger/recovery code behaves the same on Darwin": the ledger and recovery tests RUN on both Macs
    (needs the Darwin liveness probe MS6.5.3). Until then the Darwin behaviour is UNPROVEN.
- **[bd `zigBrowser-4pa.65`, V46-F3, MAJOR] The recovery transaction hard-codes the store name `"runs.json"` — RED + FIX-FORWARD
  (MS6.5.1).** `agent_run_ledger.zig:594,614,630` load and publish `"runs.json"`; the startup core loads the caller's `sub_path`
  (`agent_run_recovery.zig:389`); the plan and `recoverAllAtStartup` use `zigbrowser-agent-runs.json`. Every test passes
  `"runs.json"` (`agent_run_recovery_startup_test.zig:103,132,213,236`, `agent_run_ledger_recovery_txn_test.zig:223`,
  `agent_run_recovery_concrete_test.zig:101`), so none can see the mismatch. Observed: `test-agent-run-recovery-startup` passes
  as it is (exit 0); with only the test's store name changed to the real name, four tests fail (exit 1: "expected 64, found 0"
  signalled; "signalled … expected 1, found 0"). With the real name every entry ends `.fail_closed`: safe, but recovery could
  never work.
  - The R29.6 I-W5 red is corrected: it passes only if the tests stop using `runs.json`. Red (exact): switch the startup tests
    to `zigbrowser-agent-runs.json` (`tests/agent_run_recovery_startup_test.zig`, step `test-agent-run-recovery-startup`, in
    `test`); assertions: `signalled == 1`, entry retired, final ledger empty. Fails today with 4 failures.
  - Mutant: restore the literal `"runs.json"` in `recoverOneUnderLockP` → the red fails. Fix: thread `sub_path` into
    `recoverOneUnderLock`/`recoverOneUnderLockP`. Platform: none (the Darwin probe is MS6.5.3).
- **[bd `zigBrowser-4pa.66`, V46-F4, MAJOR] `seatbelt_ready` is not pinned and readiness is two independent booleans next to a
  broad profile — RED + FIX-FORWARD (D2).** Observed: with `seatbelt_ready = true`, `test-agent-setup-ms5` still exits 0; no test
  reads the constant. Both generated profiles still emit `(allow file-read*)`, `(allow process-exec)` and `(allow mach-lookup)`
  (`sandbox_macos.py:169-182,216-226`), so a sandboxed process could read every user file, including the browser's site cookies,
  and exec anything. `LAUNCH_SPEC_CONSUMABLE = False` (`:352`) is a third, unlinked flag.
  - Order: the registered pin test and the D2 derivation land BEFORE any MS6.7 work. The pin (`expect(!seatbelt_ready)`) is a
    TRIPWIRE (R30.2 T8). Exercising proof: (a) the real macOS binary's `--agent-setup` refuses with the fixed line
    (`ms5_setup_refusal_gate.sh`, both Macs, released run); (b) `tests/agent_seatbelt_readiness_invariant_test.zig` (TO BE
    AUTHORED, step `test-agent-seatbelt-readiness`, TO BE ADDED to `test`) renders the REAL profile from the production
    generator and asserts `seatbelt_ready ⇒ PROFILE_CURATION == CURATED ∧ no bare allow in the rendered profile`
    (**Rev 31, L3: the "no bare allow" clause is a profile-TEXT check, a TRIPWIRE exactly as R30.2 T9 labels it; it is a
    cross-language consistency guard, not the closing proof. The closing proof is the kernel/run denial beside the constant
    read: the Mac rows of `ms6_generated_profile_test.sh` (canary `cat` EPERM, windowserver lookup denied, `exec /bin/sh` EPERM)
    under the generated profile, both Macs, released run. `4pa.66` stays UNPROVEN until they run.**);
    (c) mutants: flip `seatbelt_ready = true` alone → the invariant fails (today nothing fails); flip curation to CURATED without
    the profile change → the rendered-profile assertion fails.
- **[bd `zigBrowser-4pa.67`, V46-F5, MAJOR] MS6 has no production path — NOT BUILT (MS6 half; the MS5 half is in R30-MS5).**
  `spawnNetd` and `appendEgressPort` (`src/agent_host_posix.zig:49,205`) have no production importer; `launch.py:152-157` refuses
  darwin; `agent_helper.zig` never sends `--egress-port`; the reaper, ledger and recovery are linked only into test modules
  (`build.zig:872,1149,1184`). Fix-forward: MS6.8 (the production launch connector) plus an `ms6-gate` build step. Until then
  every MS6 row reads "seam, test-built only" and the MS6.1 closure stays OPEN.
- **[bd `zigBrowser-4pa.68`, V46-F6, MAJOR] The ledger `pid` is an unchecked `i32` — RED + FIX-FORWARD (D-W1).**
  `agent_run_ledger.zig:38`; `parse` (`:105-150`) has no pid check. A pid of 0 or a negative pid reads `/proc/0/stat` or
  `/proc/-1/stat`, gets ENOENT, becomes `.absent` → `.dead` → `.recover` (`:337-340`), and reaches the destructive teardown path.
  The C engine still skips pid ≤ 1 (`agent_run_reaper.c:146,162`), so this is not a `kill(-1)`.
  - Red: extend `tests/agent_run_ledger_test.zig` family (registered, in `test`). Documents with pid 0, -1, 1, and a basename pid
    that differs from the entry pid; assertions: `parse(...)` returns the malformed error and `recoveryFor` yields
    `.fail_closed`; the kill intercept records 0 calls. Fails today (pid 0 reads as `.recover`).
  - Mutant: delete the `pid < 2` check → the pid-0 row classifies `.recover`. Fix: reject `pid < 2` and require basename pid ==
    entry pid in `parse`.
- **[bd `zigBrowser-4pa.70`, V46-F8, MAJOR] `ms6_5_reaper_gate.sh` is guarded only by `ZB_MAC_ARM_HOST` — RED + FIX-FORWARD
  (R29-SAFETY).** At `tests/mac/ms6_5_reaper_gate.sh:15-23` the only precondition is that `ZB_MAC_ARM_HOST` is set; the script
  SIGKILLs real processes on the Macs. The R29-SAFETY technical guard is not implemented. Red (Linux, hostless; step
  `test-mac-reaper-gate-guard`, TO BE ADDED to `test`): run the script with only `ZB_MAC_ARM_HOST` set, a stub `ssh` and `scp` on
  `PATH` recording calls; assertions: exit status 1, the output contains "DISABLED: destructive reaper gate", `ssh_calls == 0`.
  Fails today (the script reaches `ssh`). Mutant: restore the old guard → `ssh_calls > 0` → fails. A second row: with
  `ZB_REAPER_DESTRUCTIVE_APPROVED` equal to HEAD but no release-token file, the script still exits 1 with `ssh_calls == 0`.
- **[bd `zigBrowser-4pa.71`, V46-F9, MAJOR] The production recovery transaction has no test in `zig build test` — RED +
  FIX-FORWARD (register, make non-pub; with `4pa.65`).** `recoverOneUnderLockP` (`agent_run_ledger.zig:579-634`) is exercised
  only by the unregistered `tests/agent_run_ledger_recovery_txn_test.zig` and the MANUAL step `test-agent-run-recovery-txn`
  (`build.zig:1131-1157`, whose comment says it is deliberately outside the aggregate). The startup test drives it with fakes
  under `recoverAllAtStartupGated(true, …)` (`:236`) and with the wrong store name. The two test files the plan names
  (`agent_run_ledger_concurrency_test.c`, `agent_run_recovery_test.c`) do not exist.
  - Fix: in the green that fixes `4pa.65`, register the txn test in `test`, and make `…Gated`, `…GatedH`, `…Full` and
    `recoverOneUnderLock` non-`pub` (I-W3; the compile-fail test is R30.2 T20).
  - Red: the registered txn test must fail under this mutant of PRODUCTION code: `recoverOneUnderLockP` releases the flock
    before the fixed point → the two-recoverer assertion (`{.signalled, .already_gone}`, empty final ledger) fails. Until the test
    is registered, MS6.5.1's transaction is NOT BUILT.
- **MS6.5.1 and `reaper_ready` status.** BUILT-UNARMED rows read **NOT BUILT** (rule 6; R30.1 #14, #15). The `indexOf` proof of
  `reaper_ready` is a TRIPWIRE and the hostile-environment runtime test (R30.2 T7) is the proof; the readiness invariant of
  `4pa.66` covers `seatbelt_ready`.
- **Minor amendments.**
  - V46-F12 (status correction of I1): both backends define `network(self, session=None)` (`sandbox.py:307`,
    `sandbox_macos.py:371`); the **Protocol** declares `network(self)` (`sandbox.py:213`). The Mac `launch_spec` silently ignores
    `ro_paths`, `state_dirs`, `net_dir` and `seccomp_fd` and defaults `state_dirs=()` where the Protocol says `STATE_DIRS`
    (`sandbox_macos.py:413-442`). The R29-MS6 I1 text pointed the wrong way: the fix is to correct the Protocol, then raise
    `UnsupportedLaunchInput` for every ignored input. The reflection assertion is a TRIPWIRE (R30.2 T10); the proof is
    `launch.build_launch` driven for both backends.
  - V46-F13 (SUSPECTED → UNPROVEN): `MacSeatbeltBackend.launch` removes the profile directory as soon as the `with` body returns
    (`sandbox_macos.py:449-462`). A caller that only `Popen`s can race `sandbox-exec`'s own `-f` read, which happens after exec.
    No caller yet; the setup path waits (`setup.py:789-790`). Red (Mac, with MS6.8): `Popen` without waiting; the profile file
    exists when `sandbox-exec` opens it (`assert rc == 0`); mutant: delete on `with` exit → `sandbox-exec` fails to read it.
  - V46-F14: `ledger.RealClock` (`agent_run_ledger.zig:399-410`) calls `std.os.linux.clock_gettime` with no target check and
    ignores failure; it compiles for both macOS arches and emits Linux-ABI syscall instructions. Red (Linux, registered): inject
    a failing clock read into `RealClock`; assertion: the failure surfaces as an error, not `0`; mutant: ignore the failure →
    `now == 0`. Fix: route `RealClock` through `nowMsFrom(realClockRead)`.
  - V46-F15 (I-W4 again): `acquireRunLockBounded` (`agent_run_ledger.zig:469-488`) acquires and releases at once, so
    `acquired=true` holds nothing. Red: a caller that trusts `acquired` while a second process writes; the second write must be
    excluded; mutant: the current acquire-and-release → the second write lands. Rename it `probeRunLock` or return the held fd.
  - Not changed: the profile generator, `MacSeatbeltBackend`, the hook Darwin branch (`hook_run.py:189-225`), netd's dual-family
    reservation (`netd.py:798-800`) and the VM stub remain as R29.2 says; their statuses are in the compliance table.
  - **Unverified risk (recorded, not closed):** that `sandbox-exec` can apply the hook profile from inside the CLI's own
    Seatbelt sandbox (`hook_run.py:207`) has no Mac evidence beyond a pending hard-gate case. If nested application is refused,
    the P1 hook mechanism fails. The hard-gate case `case_ms8_hook_sandbox.py` must run on both Macs (released) before the P1
    text is called proven.

---

## MS7: AppKit drawer + Keychain Secrets window + approval card + chat observability

**Goal.** The native AppKit drawer matching the accepted Linux UX, the Secrets window, the approval
**card** (authority from MS4), and **drawer observability that does not violate the threat model**.
**UI slice** — real-screen check required.

### R29-MS7 — MS7 status and amendments (Rev 29; K6, W3, T3, bd `4pa.27`; AUTHORITATIVE)

**Status (Rev 30 corrected, bd `4pa.72`, `4pa.75`).** MS7.0 is a symbol-presence tripwire with no production caller (NOT BUILT); the portable *seams* of MS7.1 and MS7.4 are driven and registered (7/7 each, observed at d0f1841) but are NOT BUILT as behaviours or by status word (Rev 31 G4.1: no production caller); the MS7.6/7.8 portable half is **RED-UNREGISTERED and NOT BUILT** (`Approver`, `cardPress` and `zb_drawer_card_press` do not exist; `test-agent-drawer-card-press` and `check-card-authority-mac` both exit 1, observed, and neither is in `test`);
MS7.5's portable controller logic is a RED (unregistered). **No AppKit drawer exists**: `src/agent_drawer_mac.m` does not
exist (the planned file; creating it is MS7's green), `wkwebview_shim.m` builds no main menu, and `zb_app_set/get_agent_drawer`
are not in the shim. MS7.1/7.2/7.3 AppKit views, MS7.4 `ZbBubbleView`, MS7.5 window, MS7.7 census and MS7.9 ownership
are **NOT STARTED**. The native approve and deny minters (`agent_tools.zig:200,206`) are defined in both macOS builds
(MS8.0) but called only by the GTK drawer (`agent_drawer.c:1218,1228`).

**K6 — the MS7 gate contract no longer contradicts MS7.8.** MS7.8 says the MS7 card is built from fixture parameters
with no helper, but `tests/mac/ms7_appkit_check.py:187-190` requires a card "presented by the real chain", which its own
probe says does not exist until MS8 (`ms7_appkit_probe.m:11,321-324`). The gate could not pass at MS7. Resolution
(plan decision): **MS7 gets a fixture-card entry** — a *production* card constructor (the same `Cards` presentation
path the chain uses) invoked through the test seam `zb_drawer_present_fixture_card(window,
params)`, **built ONLY under a test-only build option (`-Dtest-seams`) and absent from the shipping binary — NOT merely
`--e2e-protocol`-gated, because `--e2e-protocol` is a public flag (Rev 31, bd `4pa.78`; R30-MS7)**; the **chain-sourced card stays MS8.3**. `ms7_appkit_check.py` is edited to require "presented by the fixture
entry" at MS7 and "presented by the real chain" at MS8.3 (a milestone argument, like `resource_phase`'s). Red: the
compiled gate at MS7 with the fixture entry present passes the card step; with the entry absent it fails with "no
fixture card entry" (today it fails on "no real chain" and can never pass). **[Rev 30, bd `4pa.74`, `4pa.78`: K6 is a plan decision only. `ms7_appkit_check.py:198-200` still requires `source == "chain"`, there is no milestone argument and no `zb_drawer_present_fixture_card`. Also `--e2e-protocol` is a public flag, so the fixture seam must be compiled only under a test-only build option and be absent from the release binary. See R30-MS7.]**

**Observer.** The MS7 observer is the **DYLD probe** (`ms7_appkit_probe.m`) — or, if the `--e2e-protocol` census is
built, the census; a real-screen case is listed separately as unbuilt, never conflated with the compiled gate.

**T3 — lexical oracles are retired as authority.** `tests/e2e/mac_drawer_card_authority_test.py` and
`mac_drawer_bubble_inert_test.py` (~2,000 lines) parse `src/agent_drawer_mac.m`, which does not exist, and neither is
registered. They are relabelled **offline tripwires** (RoseCat `c6b2b32`, docs `3f536a8`) and are **not** acceptance
evidence. The authority for MS7.4/7.6/7.8 is the **compiled two-Mac hard gate** (`c63020d`: live ObjC census, live Edit > Copy
with nil target, real bubble and page copies, the card's real Approve) driving a real native card through the fixture entry.
**Rev 31 (L6): two items that the gate also lists are NOT authority and are TRIPWIRES — "production argv and preprocessor
output" (compile-output text) and "no GTK-only card call" (a symbol/relocation check). Only the live items, above all the
live Approve that mints a `grants` row, close MS7.4/7.6/7.8, and they are UNPROVEN until a released two-Mac run.** Once that gate drives a real card
the lexical oracles are deleted from the plan's evidence list. **[Rev 30, bd `4pa.72`: the former sentence "Registered Linux evidence that DOES count: `check-card-authority-mac`" is WITHDRAWN. `check-card-authority-mac` is a red, unregistered relocation TRIPWIRE and counts as no evidence. What counts today is only the portable text and geometry seams (`test-agent-drawer-appkit`, `test-agent-drawer-appkit-text`: driven, registered, observed 7/7 each). The card-press tests count only after the green adds `cardPress` and registers them.]**

**W3 — drawer ownership closure (MS2c.5 → MS7.9)** has no code and no test; see MS7.9 and the ledger.

### Design
- `src/agent_drawer_mac.m` (**does not exist yet; MS7's green creates it**) (+ reuse portable `agent_drawer.zig`
  geometry/animation/persistence, already exported on macOS by MS7.0). Mounted from `zb_window_new`
  (`wkwebview_shim.m`) when the drawer is on.
- **Dock:** bottom `NSView`; the WKWebView frame is resized **above** it (no overlay over the
  GPU-composited layer — the NVIDIA lesson applies to macOS). **"S" icon:** borderless draggable
  view, hidden while open, click-vs-drag (6 px), keyboard move, `agent-drawer.json` persistence
  (reused). **Fold:** `-` animates the panel into the icon's last position over the shared 180 ms
  cubic ease-out via `NSAnimationContext`/`CVDisplayLink`. **Isolation:** native AppKit views, not
  a webview — structurally isolated from page worlds. **Secrets:** Keychain (MS5 backend) in the
  Secrets window.
- **Approval card:** the native row; **only the Approve handler mints** the MS4 grant.

### Behaviors
> **Rev 29 status per behaviour (details in R29.2 and the ledger):** MS7.1 portable driven SEAM, NOT BUILT (Rev 31 G4.1) / AppKit NOT
> STARTED; MS7.2 NOT STARTED; MS7.3 NOT STARTED; MS7.4 portable driven SEAM, NOT BUILT (Rev 31 G4.1) / `ZbBubbleView` NOT STARTED; MS7.5
> portable RED-UNREGISTERED / window NOT STARTED; MS7.6 portable half RED-UNREGISTERED (NOT BUILT, Rev 30 `4pa.72`) / AppKit card NOT STARTED; MS7.7
> NOT STARTED; MS7.8 portable half RED-UNREGISTERED (NOT BUILT, Rev 30 `4pa.72`) / compiled gate RED-UNREGISTERED; MS7.9 NOT STARTED.
- **MS7.1** dock resizes the page above it; **MS7.2** the "S" icon drags/persists/hides-while-open;
  **MS7.3** `-` folds into the icon's last position (180 ms ease-out); **MS7.4** conversation
  scrolls, input pinned at bottom, bubbles **inert text**; **MS7.5** the Secrets window stores to
  Keychain; **MS7.6** the approval card mints a one-use grant on Approve and nothing on Deny.
- **MS7.4 amendment (RoseCat 44ca58e; BlueBeaver, 2026-10-22): one bubble control on AppKit.** Every
  conversation bubble is ONE read-only `NSTextView` subclass (`ZbBubbleView`), not the GTK split (a label up to
  `label_text_max`, a text view past it). A selectable `NSTextField` copies through the window's shared field
  editor, so a label kind would need a second copy route through the window delegate
  (`windowWillReturnFieldEditor:toObject:`), shared with every other field in the window. An `NSTextView` is itself
  the first responder of its selection, so the bubble's own `copy:` is the one route. It writes the ORIGINAL bytes
  of the selection (`zb_drawer_appkit_original_offset`). Drag-out, Services and the context menu are closed,
  because they would carry the shown text.
  - `label_text_max` stays the responsiveness boundary, as the bubble's LAYOUT: contiguous up to it, non-contiguous
    past it. The portable seam is `bubbleLayoutContiguous` / `zb_drawer_bubble_layout_contiguous`, replacing
    `bubbleIsLabel` / `zb_drawer_bubble_is_label`. It is applied on every update, so a streaming bubble that crosses
    the boundary changes layout in place.
  - The input is one plain `NSTextView` (rich text, graphics and link detection off).
  - Cmd+C reaches `copy:` only through an Edit > Copy menu item targeting the first responder. `wkwebview_shim.m`
    builds no main menu yet, and the MS7.4 green needs one.
  - The real-Mac clipboard checks on both sides of `label_text_max` stay owner-run real-screen cases.
  - Oracles: `tests/agent_drawer_appkit_text_test.zig` (portable, registered) and `tests/e2e/mac_drawer_bubble_inert_test.py`
    (exact source shape — **Rev 29: an offline tripwire only, unregistered, parses a file that does not exist; the
    compiled two-Mac gate is the authority, R29-MS7**).
- **MS7.7 chat observability (blocker 7):** the chat round-trip and bubble text are asserted via a
  gated **`--e2e-protocol` native drawer census** (the macOS analog of the `DRAWER windows` row) or
  screen capture — **never** a production socket drawer-read API.
- **MS7.8 native approval-card mint/deny (rev 4 — not the end-to-end chain):** the native
  approval card is the **only** production grant minter. On a **native AppKit click** of Approve —
  a real `-[NSWindow sendEvent:]`-delivered `NSEvent` on the card's Approve control (never "X
  click"; MS7 is a real-screen slice, orchestrator-run) — `on_approve` [Rev 29: = `zb_agent_tools_approve` → `Cards.approve`] mints a **valid MS4 grant** [Rev 29: = the card reaches `approved`; see R29-MS4]
  (correct tuple, 120 s, single-use); a **Deny** click mints nothing. This closes the card's mint
  **authority and binding** at the native boundary **without** the helper or the automation socket:
  there is no `tool_use` source wired at MS7, so the full commit chain cannot and does not run
  here. The observable is the minted grant (present and well-formed on Approve, absent on Deny),
  read through MS4's grant seam — **not** a flow commit. **The positive end-to-end commit closure
  (socket-free `tool_use` → broker preview → this card → Approve → grant → revalidate → commit
  once) lives in MS8.3**, after MS8 wires the production CLI/helper/protocol-pump that actually
  delivers `tool_use` (rev 4 blocker 1).
- **MS7.9 drawer ownership / window-destroy parity (blocker 5):** the drawer honors MS2c.5 —
  every window (incl. popups) has its own drawer bound to its `window_id`, the shared destroy path
  detaches/frees the drawer before the automation close notification, and the live-drawer count is
  **zero** after all windows close. **SHOULD:** the icon/fold views **intentionally overlap** the
  page, so they need **exact hit-testing** (a click on the icon/`-` hits the drawer, a click
  elsewhere reaches the page) even though the docked panel does not overlap.

- **Property (MS7.2):** roundtrip — `parse(write(ratios)) == ratios` (reuse the platform-neutral
  `agent_drawer.zig` property).
- **SHOULD named tests (833767e):** keyboard/fold-row parity (Enter/Shift-Enter/Escape/
  Ctrl+Shift+Space-equivalent + arrow-key icon move) and **Secrets-exclusion** parity (the Secrets
  window is not in the window registry and is unreachable from the automation socket) each get a
  **named** macOS test.
- **Real-screen (blocker 8):** add macOS `drawer-open`, `secrets-window`, `approval-card` cases to
  the real-screen check; the orchestrator runs them on the user's Mac; **not approved until they
  pass**. The input guard proves its window is frontmost/topmost before emitting — via
  `NSWorkspace.sharedWorkspace.frontmostApplication` compared with
  `NSRunningApplication.currentApplication` (or `[NSApp isActive]` inside the app); there is no
  `NSRunningApplication.activeApplication` (BlackRobin 5477) — and aborts under a grab-equivalent
  guard, and the runner **fails closed when Screen-Recording / window-order evidence is
  unavailable**.

#### Workflow Closure (MS7.8 — native card mint/deny)   [BLOCKING: AppKit action → MS4 grant seam]
- **Chain:** `native AppKit Approve click (-[NSWindow sendEvent:]) -> on_approve (= zb_agent_tools_approve -> Cards.approve, Rev 29) -> MS4 grant minted (tuple/120s/single-use)`; a Deny click mints nothing.
- **SOURCE (seed):** a loaded bound window + a pending approval card (built from fixture
  parameters through the **MS7 fixture-card entry** — a production card constructor built ONLY under a test-only build
  option (`-Dtest-seams`), absent from the shipping binary (Rev 31, bd `4pa.78`; R29-MS7, R30-MS7), **not** merely behind
  the public `--e2e-protocol` flag — **no helper**; the chain-sourced card is MS8.3). **TRIGGER:** the native Approve/Deny click (the card is the entry
  point; there is no socket or helper at MS7). **DRIVER:** the real `[NSApp run]` loop + the real
  native click (real-screen case, orchestrator-run). **OBSERVE:** the MS4 grant seam — a valid
  grant exists after Approve, none after Deny. **FORBIDDEN SPAN:** the grant minter internals.
  **RED-AT-SEAM:** route the mint off the native handler (e.g. let page/model text mint) → the
  negative proofs (MS4.2) go red. **Scope:** this closure does **not** reach a flow commit — the
  committing chain is MS8.3.

**Gate (MS7) — Rev 29:** the compiled two-Mac drawer gate (`tests/mac/ms7_appkit_gate.sh`, RED `c63020d`, unregistered)
driven through the fixture-card entry, plus the registered Linux evidence listed in R29-MS7, registered as an `ms7-gate`
build step (R29-REG), on both arches **plus** the owner-run real-screen check (incl. the MS7.8 native Approve/Deny
click). Original wording: real-binary macOS drawer e2e (native census + snapshot) on both arches **plus** the
real-screen check (incl. the MS7.8 native Approve/Deny click). Coordinate with **BlackRobin**
(drawer owner) and **BlueBeaver** (grant authority from MS4).

### R30-MS7 — Rev 30: MS7 findings (validation ms7-9 C1, M1, M3, M5, m1-m5, m8, m9; AUTHORITATIVE)

- **[bd `zigBrowser-4pa.72`, V79-C1, CRITICAL] MS7.6/MS7.8 card press falsely BUILT — STATUS CORRECTION + NOT BUILT.** Done in
  place in R29.1(c), R29.2, R29-MS7 and the ledger (see R30.1 #1-#2). The behaviour is **RED-UNREGISTERED**.
  - Exercising proof for the green (so the next claim of BUILT is real): (a) entry: the native Approve control in the card
    reaching `zb_agent_tools_approve` → `Cards.approve`; (b) `tests/agent_drawer_card_press_test.zig`, step
    `test-agent-drawer-card-press` (registered in `test` in the green, never in the red) drives `drawer.Approver`, `cardPress`
    and `zb_drawer_card_press`; assertions `press(card_own_control) == .approve` and `press(elsewhere) == .none`; (c) mutant:
    make `press(elsewhere)` return `.approve` → the second assertion fails; (d) the compiled two-Mac gate drives a real Approve
    and reads the `grants` row.
  - `check-card-authority-mac` stays a relocation TRIPWIRE even when green (R30.2 T4). It is removed from the "counts as
    evidence" list.
- **[bd `zigBrowser-4pa.74`, V79-M1, MAJOR] Decision K6 is in the plan but not in the code, so the MS7 gate can never pass at MS7 —
  RED + FIX-FORWARD.** `tests/mac/ms7_appkit_check.py:198-200` still fails on "no card presented by the real chain"; there is no
  milestone argument, no fixture-entry branch and no `zb_drawer_present_fixture_card`; `ms7_appkit_probe.m:11` says the card is
  "absent until MS8". Red: `tests/e2e/ms7_appkit_gate_test.py`, step `ms7-gate` (TO BE ADDED, Mac-only): `ms7_appkit_check.py
  --milestone MS7` with the fixture entry present passes the card step (`assert card.source == "fixture"`), with the entry absent
  it fails with "no fixture card entry"; `--milestone MS8` requires `source == "chain"`. Fails today (it can only fail on "no
  real chain"). Mutant: accept any source at MS8 → the MS8 row fails. Both Macs, released run.
- **[bd `zigBrowser-4pa.78`, V79-M5, MAJOR] K6's fixture-card seam would ship a debug hook inside the release binary — RED +
  FIX-FORWARD.** The plan puts `zb_drawer_present_fixture_card` behind `--e2e-protocol`, a public flag; R29-SAFETY itself says
  such hooks must sit behind a build option absent from the shipping build; here the hook would show a production approval
  card built from caller-chosen parameters. Fix: compile the entry only under a test-only build option (`-Dtest-seams`).
  Red (driven, both builds): `tests/e2e/mac_ms7_fixture_seam_absent_test.py` (TO BE AUTHORED), step `ms7-gate`: start the RELEASE
  binary with `--e2e-protocol` and call the seam over the e2e route; assertion `reply.error == "unsupported"` and no card in the
  census; the same call on the TEST build returns a card. Mutant: compile the seam unconditionally → the release row fails. The
  `nm` listing is a TRIPWIRE only. Both Macs, released run.
- **[bd `zigBrowser-4pa.76`, V79-M3, MAJOR] Two different C functions share the name `zb_secrets_window_open` — RED + FIX-FORWARD
  (MS7.5).** `src/agent_secrets_window_mac.h:23` declares `int zb_secrets_window_open(unsigned long long window_id)` (open or
  focus the window); `src/agent_secrets_window.h:56` and `.c:188` already define `int zb_secrets_window_open(void)` ("is it
  open?"). A translation unit or Zig extern that sees both breaks, and callers get the wrong meaning; the mac header also points
  to a non-existent `agent_secrets_window_mac.zig`. Fix: rename the Mac entry to `zb_secrets_window_mac_show` (the single name used in R29.6 I-W8, R30.2 T16 and here) before
  the green. Red 1 (portable): a C translation unit including both headers must compile (`clang -fsyntax-only`); fails today
  with "conflicting types for 'zb_secrets_window_open'" — a TRIPWIRE (R30.2 T16). Red 2 (the proof): the renamed entry opens the
  real Secrets window on a Mac and the window is absent from the registry (MS7.5 compiled gate, `ms7-gate`); mutant: make the
  entry a no-op → the window-open row fails. Both Macs, released run.
- **MS7.8 and `4pa.75` (M2).** The MS7.8 fixture card needs the cards started on macOS; the "start the cards on macOS" step and
  its reds are specified once, in R30-MS8 `4pa.75`.
- **Minor amendments.**
  - V79-m1: `tests/agent_drawer_appkit_test.zig:23` and `agent_drawer_appkit_text_test.zig:23` say "RED … not in `test`" but both
    are in `test` (`build.zig:3614-3615`); fix the headers (T-W6).
  - V79-m2: `src/agent_drawer.zig:726` still documents `zb_drawer_bubble_layout_contiguous` as "a label / a read-only text view";
    the one-`NSTextView` amendment replaced that model. Fix the comment.
  - V79-m3: the MS7.0 "in `test`" claim is corrected (R30.1 #6).
  - V79-m4: `appkitShown` and `appkitOriginalOffset` (`agent_drawer.zig:421-472`) repeat the `breakRuns`/`originalOffset` loops
    (`:354-505`) with a different character model. Refactor to one character iterator under the existing green tests
    (`test-agent-drawer-appkit-text` must stay 7/7); no new red.
  - V79-m5: the MS7.1 ledger Property promises 1,000 random seeds with ratio in [0.1, 0.9], but the test uses a fixed 10x13 grid
    and `drawerRect` has a fixed 0.4 ratio with no ratio parameter. The ledger entry is corrected to the grid actually tested
    (below); widening it needs a ratio parameter on `drawerRect`.
  - V79-m8: `mac_drawer_bubble_inert_test.py` (1,012 lines) and `mac_drawer_card_authority_test.py` (933 lines) parse a file that
    does not exist and are unregistered. They are RETIRED as evidence and are to be deleted in the next implementation commit
    that touches them (R30.2 T6).
  - V79-m9: `ms7_appkit_probe.m:383`'s watchdog `_exit(70)` path may skip restoring the user's pasteboard (fix: restore in a
    signal-safe way or snapshot to a file first); and the `DYLD_INSERT_LIBRARIES` probe stops working once the app is
    hardened-runtime signed, so the compiled MS7 gate is **dev-build only** (MS9 needs a different observer, tracked in R30-MS9).

---

## MS8: Agent helper on macOS (blocked on MS6 green or the VM backend)

**Goal.** Run the Python helper + Claude Agent SDK **inside the Seatbelt sandbox** (MS6), wired to
the drawer, streaming replies. **Blocked until MS6's gates are all green or the VM backend lands.**

### R29-MS8 — sub-slices in flight, added to the plan (Rev 29; WC-W5, bd `4pa.19`/`4pa.27`)
The following are being built on this branch and were absent from rev 28 (evidence in R29.1(c)):
- **MS8.0 — NOT BUILT (Rev 30, bd `4pa.75`; was BUILT+REGISTERED)** (`29744db`): the approval cards' minters (`zb_agent_tools_approve/_deny`) and the card
  window lifecycle are *defined* in both macOS builds, but on macOS the minters always return 0 (`agent_tools.start` is Linux-only, so `cards` is never initialised) and nothing calls them; the GTK-only tool call stays Linux-only.
  `cross-check-agent-tools-mac` is a symbol-presence TRIPWIRE and passes with the inert minter (observed at d0f1841). The proof is the R30-MS8 reds: a driven minter test and the compiled gate `grants` row.
- **MS8.1 (portable core) — driven SEAM, status NOT BUILT (Rev 31 G4.1) (12/12 and 8 kill-group cases observed at d0f1841; no production importer of `spawnNetd`):** the macOS host spawner pure core and `spawnNetd` integration
  (`src/agent_host_posix.zig`, `agent_spawn_posix.c`). **MS8.1 proper (the helper launches under `MacSeatbeltBackend`)
  is NOT STARTED and needs MS6.8.**
- **MS8.2a — RED-UNREGISTERED** (`2a851b5`, `7a04182`): the portable helper core's chat path
  (`tests/agent_helper_core_test.zig`): the first Send takes the home lock, runs the config check, token fetch, one
  spawn; `ready` → `hello` → `open_session`; deltas to the drawer; `result` ends the prompt; Stop writes `interrupt`;
  window close writes `end_session`; a crash gives `crashed`/`exit-<n>` and restarts after 1 s; two windows are
  independent. Driven with recording fake ports (no process, display or signal).
- **MS8.2b — RED, uncommitted/UNREGISTERED** (`tests/agent_helper_posix_test.zig`): the POSIX process transport under
  that core.
- **MS8.2c — NOT STARTED:** macOS production wiring of the core to the AppKit drawer and the broker (needs MS7 views).
- MS8.2/8.3 *closures* below are **plan-only** while MS6/MS7 are incomplete — that is fine, and said so; they are not
  evidence. Sub-slices follow the same rules: named red + failing assertion, registered in the green that makes them
  pass (never in a red commit, per the red-commit rule).

### Behaviors
- **MS8.1** the helper launches under the `MacSeatbeltBackend`, reads the token on fd 3, and emits
  a `ready` frame validated by `agent_protocol.zig` (platform-neutral, already covered).
- **MS8.2** a chat round-trip streams `assistant_delta`/`assistant_message` to the AppKit drawer.
- **MS8.3 positive approved commit — the one end-to-end chain (rev 4, moved from MS7.8, blocker
  1):** a `tool_use` emitted by the fake Anthropic API arrives **through the production proxy and
  the helper/protocol-pump** (the same source as MS8.2, **never** the automation socket) → the
  broker renders a **dry-run preview** → the **MS7 native approval card** → a **native AppKit
  Approve click** → `on_approve` (= `zb_agent_tools_approve` → `Cards.approve`, Rev 29) mints the MS4 grant (card `approved`) → **revalidate** (origin/`load_serial`/
  `crashed`/`recovering`) → the **real flow commits exactly once** with `options.expect` checked
  in-ticket. This chain can only exist here because the production `tool_use` source (CLI →
  helper → protocol pump) is not wired until MS8 — at MS7 there is no non-socket `tool_use`
  source, so attempting it at MS7 would have to route through the forbidden automation socket or
  inject inside the span. Deny / an expired or retargeted grant commits **0**.

### Workflow Closure (MS8.3 — positive approved commit)   [BLOCKING: helper tool_use → native approve → single commit] [Rev 29: PLAN-ONLY, NOT STARTED; needs MS6.8, MS7 views, MS8.2c]
- **Chain:** `fake-Anthropic tool_use (through proxy) -> helper/protocol pump -> broker preview (dry run) -> MS7 native card -> native AppKit Approve click -> on_approve mints MS4 grant -> revalidate (origin/load_serial/crashed/recovering) -> real flow commit (options.expect in-ticket) -> fixture records exactly 1 commit`
- **SOURCE (seed):** a logged-in social fixture + a loaded bound window + the fake Anthropic API
  **reached through the production proxy** (`--e2e-protocol` seam, per MS6.4) emitting the
  `tool_use`. **TRIGGER:** the helper delivering the `tool_use` to the broker (the production
  entrypoint; **not** the automation socket). **DRIVER:** the real helper stdin/stdout pump
  (`chat.py _pump`) + the real `[NSApp run]` loop + the real native Approve click (real-screen
  case, orchestrator-run). **OBSERVE:** the social fixture's commit log = **exactly 1**.
  **FORBIDDEN SPAN:** the helper Session/SDK client, the broker, the grant minter, the flow engine.
  **RED-AT-SEAM:** Deny, or an expired/navigation-retargeted/wrong-account grant → commit **0**;
  routing the `tool_use` over the automation socket must be **impossible** (socket separation, per
  the drawer architecture). **EXECUTION:** real binary + helper venv + a Mac with a GUI session;
  missing venv or no real-screen operator ⇒ exit nonzero (never SKIP-to-green).

### Workflow Closure (MS8.2 — drawer↔helper↔broker chat)   [BLOCKING]
- **Chain:** `drawer Send (AppKit) -> app frame on helper stdin -> chat.py Session -> ClaudeSDKClient (CLI under Seatbelt) -> assistant frames on stdout -> agent_protocol.zig validate -> drawer bubble`
- **SOURCE (seed):** the prompt + a fake Anthropic API **reached through the production proxy**
  (`--e2e-protocol` seam, per MS6.4). **TRIGGER:** the drawer Send handler (MS7), boundary =
  highest_new_connector (the drawer→helper wiring, MS8). **DRIVER:** the real helper stdin/stdout
  pump (`chat.py _pump`) + the 50 ms coalescer. **OBSERVE:** the rendered bubble via the
  `--e2e-protocol` **native census** (not a production socket read). **FORBIDDEN SPAN:** the
  Session, SDK client, frame validator. **RED-AT-SEAM:** disconnect the drawer→helper wiring → no
  bubble → red. **EXECUTION:** real binary + helper venv on a Mac; missing venv ⇒ exit nonzero.

**Gate (MS8):** real-binary macOS chat e2e (MS8.1/8.2) **and the positive approved-commit e2e
(MS8.3)** on both arches **plus** a real-screen check of a streamed reply and of the MS8.3 native
Approve click (orchestrator-run). Coordinate with **BlueBeaver** (helper + grant authority from
MS4) and **BlackRobin** (drawer/native card from MS7).

### R30-MS8 — Rev 30: MS8 findings (validation ms7-9 M2, m6, m7; AUTHORITATIVE)

- **[bd `zigBrowser-4pa.75`, V79-M2, MAJOR] The macOS approval minters do nothing and MS8.0's test cannot see it — NOT BUILT + RED +
  FIX-FORWARD.** `agent_tools.start` runs only on Linux (`app.zig:477-479`). On macOS `server` stays null and `cards` is never
  initialised, so `zb_agent_tools_approve` and `_deny` (`agent_tools.zig:200-210`) always return 0, and nothing in the macOS
  build calls them. `cross-check-agent-tools-mac` exits 0 on HEAD with the always-0 minter (observed): a TRIPWIRE. No plan slice
  (MS7.8 fixture card, MS8.2c) names "start the cards on macOS".
  - Fix-forward: a named step in MS8.0's green, "start the cards on macOS" (the macOS start path initialises `Cards` and the minter
    table), called from the macOS app start.
  - Red 1 (Linux, driven, registered in `test`): `tests/agent_tools_minters_test.zig` (TO BE AUTHORED): initialise `Cards` through
    the macOS start path (the shared init function, not the GTK one), present a card, call `zb_agent_tools_approve(id)`;
    assertions: the return is 1 and `cards.outcome(id) == .approved`; a second call returns 0 (single use); `_deny` yields
    `.denied` and mints nothing. Fails today (the always-0 minter). Mutant: make the minter always return 0 → fails.
  - Red 2 (Mac, the proof, `ms7-gate` `grants` row): a native Approve click on the fixture card yields `grant_after_approve ==
    "minted"`; Deny yields none. Both Macs, released run.
- **Minor amendments.**
  - V79-m6: `agent_host_posix.zig:15-18` still says the orchestration is "pending" though `spawnNetd` exists; `spawnNetd` closes
    netd's stdout read end and keeps no exit watch, so on macOS a netd that dies after start is never noticed (Linux has a
    `g_child_watch`). MS8.1 proper adds an exit watch. Red (Linux, `test-agent-spawn` family, real child in a private pidns):
    kill netd after start; assertion: the host observes the exit within 2 s (`netd_exit_observed`); mutant: remove the watch →
    never observed.
  - V79-m7: (i) `readFirstPort` treats a poll `EINTR` (`ready <= 0`) as a network failure; red: deliver a signal during the poll,
    assertion `port == N`; mutant: current code → network failure. (ii) `pipe()` then `setCloexec` is not atomic; use
    `pipe2(O_CLOEXEC)` where it exists and a spawn-lock elsewhere; red: concurrent spawn does not leak the read end into the other
    child (`child_fds` assertion). (iii) `zb_agent_spawn_group` (the non-`_io` variant) lacks `POSIX_SPAWN_CLOEXEC_DEFAULT`;
    the red is in R30-MS5 V46-F11.
  - Unchanged and sound: MS8.1 portable spawner core (`test-agent-spawn`: 12/12 spawnNetd tests and the kill-group C test, 8
    cases, observed at d0f1841; status NOT BUILT (a driven seam; Rev 31 G4.1), behaviour NOT BUILT: no production importer of `spawnNetd`).

---

## MS9: Developer-ID signing + hardened runtime + notarization (gated on the Apple Developer ID)

**Goal (blocker 9).** Turn the ad-hoc **development** build into a Developer-ID-signed,
hardened-runtime, notarized, stapled **universal** `.dmg`. **Blocked on the user obtaining the
Developer ID**, tracked via **Agent Mail / plan status** (the beads DB is migration-locked).

### Behaviors
- **MS9.1 inside-out nested signing:** sign nested code in explicit **inside-out order** (helper,
  CLI, embedded frameworks/runtimes, then the `.app`) with the **MS1.3 least-privilege entitlement
  manifest** and `--options runtime`, per arch.
- **MS9.2 whole-bundle hardened-runtime verify on both arches, then notarize** (**Rev 31, L4: every `codesign`, `spctl` and
  `stapler` check named here is a TRIPWIRE; the proof is launching the notarized app, see Closure below**): `codesign --verify
  --strict` passes on the universal bundle on **both** arches; then `xcrun notarytool submit
  --wait` returns `Accepted`, `xcrun stapler staple` + `stapler validate` succeed, and `spctl
  --assess --type execute` accepts the `.app`.
- Until the Developer ID exists, the artifact is explicitly an **ad-hoc development build, not a
  distributable launch artifact**.
- **Rev 29 (C-W9, K5, P4) — MS9 preconditions and a spike.** (1) **MS1c** (convert `build-dmg.sh`: ship the shim
  dylib, lipo-verify, inside-out sign, `otool -L`) must land first; at HEAD the script cannot produce a loadable
  bundle. (2) The entitlement manifest has ONE key (`com.apple.security.network.client`); the plan promised derived
  launcher/helper keys and MS9.1 signs all nested code with that one manifest. The **bundled Claude CLI
  (`site-packages/claude_agent_sdk/_bundled/claude`) is a separate executable that may need its own entitlements
  under the hardened runtime** (e.g. JIT/unsigned-executable-memory for a Node/Bun runtime). **NOT VERIFIED by the
  review — SPIKE FIRST (MS9.0):** sign the bundled CLI with the hardened runtime and the one-key manifest and run it;
  red: `codesign --verify --strict` passes but the CLI exits with a code-signing kill (SIGKILL / `Code Signature
  Invalid`) → the manifest is insufficient and a per-binary entitlements file is derived (assertion: the CLI prints its
  `--version` under `--options runtime`). (3) The hardened-runtime leg of MS1b (Rev 29, P4) exists, or MS9.2 itself
  proves hardened-runtime on both arches.

- **Closure (Rev 31, L4 — corrected):** `codesign --verify --strict`, `spctl --assess` and `stapler validate` (each per arch)
  are **artifact verifiers: TRIPWIRES — not proof** (they list and check a signature; nothing in them launches the app). They
  guard against regressions and never close MS9 or MS9.1/MS9.2. **The closing proof is LAUNCHING the notarized, stapled
  universal `.app` (from the distributable `.dmg`, after Gatekeeper quarantine) on a Mac of each arch, and running the MS1b
  workload on it** (m9 render and `WINCOUNT/TITLE/NAV`, the exec-arch readback, and the bundled CLI's `--version` from MS9.0):
  (a) entry = the stapled `.app` launched as a user would; (b) a new `ms9-gate` step (TO BE ADDED, Mac-only) running that
  launch; (c) mutant: ship a `.app` signed with the wrong entitlement or missing a nested signature → the launch row fails
  (Gatekeeper kill or the dyld load error); (d) both Macs, released run. MS9 stays **UNPROVEN** until that launch is observed;
  it is also blocked on the Developer ID.

**Gate (MS9):** release gate on both arches producing a distributable `.dmg`. Not a UI slice.
**Blocked on:** the Apple Developer ID (Agent Mail / plan status).

### R30-MS9 — Rev 30: MS9, packaging and compile-only harness findings (validation ms7-9 M6, M7, m9-m12; AUTHORITATIVE)

- **[bd `zigBrowser-4pa.79`, V79-M6, MAJOR] MS9 would sign with an entitlement manifest that does nothing — UNPROVEN + RED (widened
  MS9.0 spike; decision R30.3 #4).** `packaging/macos/entitlements.plist` holds one key, `com.apple.security.network.client`. It
  only matters under App Sandbox and nothing sets `com.apple.security.app-sandbox`, so under the hardened runtime alone it has no
  effect (SUSPECTED; not run on a Mac). MS9.1 would also re-sign the bundled Claude CLI and the PSF Python with this manifest,
  discarding their own entitlements, and a Bun-based CLI very likely needs JIT entitlements.
  - MS9.0 is widened to cover the CLI (`site-packages/claude_agent_sdk/_bundled/claude`), `python3.12` and the lipo'd `.so`
    files. (a) Entry: the signed bundle's helper launch. (b) `tests/mac/ms9_0_spike.sh` (TO BE AUTHORED), step `ms9-gate`
    (TO BE ADDED, Mac-only). Assertions for each binary signed with `--options runtime` and the one-key manifest:
    `<binary> --version` exits 0 (today UNPROVEN; a code-signing kill, SIGKILL or "Code Signature Invalid" fails the row); the
    same with Anthropic's original signature retained. (c) Mutant: remove the JIT entitlement from a binary known to need it
    → the row fails (proves the probe can fail). (d) Both Macs, released run.
- **[bd `zigBrowser-4pa.80`, V79-M7, MAJOR] The bundle layout may fail strict codesign verification and notarization — UNPROVEN +
  RED (spike).** `ms5_inventory.py` and `stage_agent_runtime.sh` put `agent-host/` under `Contents/Frameworks`, which would hold
  `zb_agent_host/*.py`, `runtime.json`, a `.pth` and site-packages data. Apple expects only code under `Contents/Frameworks`, with
  data under `Contents/Resources`; `codesign --verify --strict` (MS9.2) can reject this. MS9.1's order (helper, CLI, frameworks,
  then the `.app`) also omits the site-packages extension modules. Spike BEFORE MS1c fixes the layout: stage the real bundle and
  run `codesign --verify --strict --deep` and `xcrun notarytool submit --dry-run`-equivalent checks (Developer ID needed for the
  notarization leg, so that leg stays blocked). Assertion: the strict verify exits 0 on the staged bundle; fails (UNPROVEN)
  if "unsealed contents present" or "code object is not signed at all" appears. Mutant: move a data file under `Frameworks` →
  the row fails. Both Macs, released run.
- **Minor amendments.**
  - V79-m9 (probe limit): the DYLD observer of the MS7 gate cannot run against a hardened-runtime-signed app; MS9 needs the
    `--e2e-protocol` census or screen capture as its observer. Recorded; UNPROVEN until built.
  - V79-m10: `mac_compile_only.sh`'s SBPL profile runs only on a Mac (the selftest stubs `sandbox-exec`), and its regex escape `rx`
    (~line 205) escapes only `.`. Red (Linux, in `test-mac-compile-only`): paths containing `+ ( ) [ ] { } ^ $ | ?` are escaped
    so the generated regex matches only the literal path (assertion with a table of 10 paths); mutant: the current escape → a
    path like `a+b` also matches `aab`. The profile itself stays UNPROVEN until a released Mac run.
  - V79-m11: the Python pkg pin is written twice (`stage_agent_runtime.sh:25` and `agent_runtime_pins.json:4`; see V46-F10 in
    R30-MS5); `merge_universal_tree.py` `_record_line` does not CSV-quote a path that contains a comma. Red (Linux, in
    `test-mac-census`): a merged RECORD with a path containing a comma parses back to that path (`csv.reader` assertion);
    mutant: the unquoted writer → the parsed path splits in two.
  - V79-m12: `test-mac-compile-only` fails as namespace root (7 cases: "an undeletable root fails: exit 0, want a failure" because
    `chmod 500` does not stop root, and 6 "stub process N outlived its 5 s" because the orphans are unreaped zombies under the
    namespace's PID 1). It exits 0 as the real user under a reaping PID 1 (observed). Fix: the selftest refuses to run as root
    with "NOT RUN: root" (exit non-zero, one clear line) and treats `Z` in `/proc/$p/stat` field 3 as gone, or runs its stubs
    under a reaping wrapper. Red: run it as uid 0 → `assert rc != 0 and "NOT RUN" in output`; mutant: the current script → 7
    spurious failures. The harness itself is otherwise sound (the honest both-arch case passed in both runs).

---

## Behavior specification ledger (Rev 29; W7, T1, T2, T3 — every listed behaviour, one contract each)

Format per entry: **ID [CLASS — reason] [status]** · **G/W/T** (Given/When/Then) · **Red** = the named test and the
exact assertion that fails before the green (for BUILT behaviours: the assertion that fails under the named mutant, or
that failed at the recorded red; "TO BE AUTHORED" = the file does not exist at HEAD) · **Property** (named shape +
domain) or **Skip** with the reason. CLASS: **BLOCKING** = the observable is reached through an async edge or a
cross-module/registration boundary (a passing Closure Test is required); **LEAF** = same module, no async, no
registration (a unit test suffices). Unclassified = BLOCKING. All Mac execution follows R29-SAFETY.

**Rev 30 reading of the ledger.** A ledger status of BUILT-HANDRUN means UNPROVEN, and BUILT-UNARMED means NOT BUILT (R30.0). Every
`Red` below is an exercising test unless it is labelled TRIPWIRE; the source-text, symbol and constant checks named anywhere in
this plan are the 20 tripwires T1-T20 in R30.2. The four rule-9 fields of every behaviour are in the compliance table at the end.

### MS2a
- **MS2a.1 [BLOCKING — Zig→ObjC boundary + async WK completion, Closure A] [BUILT-HANDRUN]**
  G a macOS page loaded via `zb_automation_navigate_guarded`; W `page.navigate(fixture)` then `page.url`/`page.title` over
  the authenticated socket; T `url == fixture`, `title == fixture title`, with the same envelope/auth/errors as Linux.
  Red: `mac_ms2a_routed_test.py` — `assert reply["result"]["url"] == fixture_url` (fails while `pagePort()` is null: the
  reply is the documented `unsupported` data). Property: **Skip** — the input domain is one URL and the envelope is the
  shared, already-property-tested Linux router; a property here would re-test the router.
- **MS2a.2 [BLOCKING — the private world is a cross-process-boundary isolation claim] [BUILT-HANDRUN]**
  G a page that redefines/freezes `window.__zbAutomation` and built-ins; W `dom.getText`/`dom.click`; T the result is
  unchanged. Red: `mac_ms2a_private_world_test.py` — `assert dom_text == "expected"` (fails if the script is installed in
  `pageWorld`). **Property (metamorphic):** for every page script S drawn from {assign, delete, defineProperty, freeze,
  Proxy-wrap} × names {`__zbAutomation`, `JSON`, `Promise`, `Object.prototype.hasOwnProperty`}, `result(page+S) ==
  result(page)`; domain = those 20 combinations (exhaustive).
- **MS2a.3 [BLOCKING — async completion ownership across the main-queue boundary] [BUILT-HANDRUN]**
  G a job whose waiter abandoned (deadline or loop end); W the WK completion arrives late / the app quits with work in
  flight / a string is returned; T nothing is recorded after abandon, each returned string is freed exactly once, and
  `live_jobs` returns to baseline. Red: `mac_ms2a_late_completion_test.py` — `assert live_jobs() == baseline`;
  `mac_ms2a_str_accounting_test.py` — `assert allocs == frees`; `mac_ms2a_immediate_quit_test.py` — `assert waiter_code
  == NO_LOOP and live_jobs() == 0`. **Property (state machine):** for every ordering of the events {complete, abandon,
  timeout, quit} over one job (all permutations of 1-4 events), at most one outcome is recorded and the job ref count
  ends at 0; domain = 64 sequences. P-W1 addition: the DISPATCHING-phase main-queue-hold red (MS2 amendments).

### MS2b
- **MS2b.1 [BLOCKING — trusted NSEvent delivery on the main thread, async] [BUILT-HANDRUN; scroll/move UNSUPPORTED by decision]**
  G a focused page with an input, a contenteditable and a click target; W `nativeClick`/`nativeKey`/`nativeText`; T
  `event.isTrusted === true`, the effect is observed, `beforeinput` cancellation is honoured, a navigation during input
  is refused (DOC_CHANGED), and a deadline-abandoned input dispatches nothing. Red: `mac_ms2b_native_input_test.py` —
  `assert evt["isTrusted"] is True`; `mac_ms2b_doc_changed_test.py`; `mac_ms2b_pair_race_test.py`. **Property
  (exhaustive table):** `mac_ms2b_key_table_parity_test.py` — for every key in the shared key table the macOS event
  yields the expected `key`/`code`; domain = the table. Native scroll/move/pointer: capability stays unset and the port
  returns `unsupported` (user decision 2026-10-20).
- **MS2b.2 [BLOCKING — WKUIDelegate completion handler held across calls] [BUILT-HANDRUN; beforeunload UNSUPPORTED]**
  G a page raising alert/confirm/prompt; W the page script runs and the client lists/answers; T the dialog is captured,
  held until answered, `dialog_open` fast-fails other commands, and the eval dialog-watch returns. For `beforeunload`:
  G a page with a handler; W `page.navigate` away with `.fail`/accept/dismiss; T the page LOADS and the client sees
  reason `beforeunload_unsupported` (accept/dismiss) — never the generic error. Red: `mac_ms2b_dialogs_test.py` —
  `assert dialogs[0]["type"] == "confirm"`; new row in the same file — `assert
  reply["error"]["data"]["reason"] == "beforeunload_unsupported"` (fails today: generic unsupported code). Property:
  **Skip** — 3 dialog kinds × 3 answers is an enumerated table, covered exhaustively by the example rows.
- **MS2b.3 input files [BLOCKING] [NOT STARTED]** / **MS2b.4 screenshot [BLOCKING] [NOT STARTED]** — G/W/T and reds are
  in the ABI-table rows (`zb_set_input_files`, `zb_screenshot_png`); Property: **Skip** until built (no behaviour yet).

### MS2c
- **MS2c.1 [BLOCKING — popup creation crosses the WK delegate boundary] [BUILT-HANDRUN]**
  G a page that `window.open`s twice (a two-hop chain); W routed commands to each popup and `page.close` / script
  `window.close()`; T each popup has its own `window_id` and FIFO, and the opener's URL and DOM survive. Red:
  `mac_ms2c_popup_chain_test.py` — `assert opener_text == before`; `mac_ms2c_window_fifo_test.py` — `assert
  completion_order[w] == submission_order[w]`. **Property (FIFO order):** for k ∈ {1,2,3} windows and any interleaving of
  ≤ 8 commands, per-window completion order equals per-window submission order; domain = all interleavings of 2
  commands × 3 windows (exhaustive) plus 200 random seeds.
- **MS2c.2 [BLOCKING — out-of-band watchdog vs a stuck FIFO, Closure B] [BUILT-HANDRUN]**
  G two windows with window 1's FIFO occupied (and, Rev 29, the main queue held); W `page.list`/`page.health`; T both
  windows are reported within the bound and no `dispatch_sync` is used. Red: `mac_ms2c_oob_during_stuck_test.py` — `assert
  health_latency_ms < 500`; plus the Rev 29 main-queue-hold row (Closure B amendment). Property: **Skip** — a latency
  bound under a held queue is a scenario, not an input domain; the mutant (snapshot via `dispatch_sync`) discriminates.
- **MS2c.3 [BLOCKING — two-phase consent + view replacement, Closure C] [BUILT-HANDRUN]**
  G a frozen window; W `page.recover` phase 1 then phase 2 with the incident token and acknowledgement; T the window is
  re-created under the same `window_id` at its committed URL, queued jobs were cancelled exactly once, no automatic kill
  occurred, and the abandoned process exits (P-W2). Red: `mac_ms2c_recover_test.py` — `assert url_after ==
  committed_url and id_after == id_before`; wrong/stale token → `assert error == "unknown"`. **Property:** for every
  token string t ≠ the issued token (domain: random 0-64-byte strings + the previous token), phase 2 returns `unknown`/
  `mismatch` and mutates nothing.
- **MS2c.4 [BLOCKING — crash callback + no-input hold] [BUILT-HANDRUN]**
  G a window whose content process terminated (`ZB_DEBUG_SYNTH_CRASH`, e2e-only); W no input for > 3 s, then
  `page.reload`; T the static crash document persists (no auto-reload) and clears only on a real commit. Red:
  `mac_ms2c_crash_recovery_controls_test.py` — `assert crash_dom_present_after(4.0)`; the 3 s auto-reload mutant is
  killed. Property: **Skip** — time-gated scenario; the 4 s hold plus the mutant discriminate it.
- **MS2c.5 [BLOCKING — drawer lifecycle across window destruction] [NOT STARTED → MS7.9]** — see MS7.9.

### MS3
- **MS3.1 [BLOCKING — persistence crosses the process-lifetime boundary] [BUILT-HANDRUN]** G `--profile-dir P`, a logged-in
  page; W the browser restarts with the same P; T the cookie/login persists, and a different P is isolated. Red:
  `mac_profile_persist_test.py` — `assert cookie_after_restart == "v"`. **Property:** path→UUID (MS3.2 text).
- **MS3.2 [LEAF — one flag decision plus one observable effect, same module] [BUILT-HANDRUN]** Red:
  `mac_config_flags_test.py` — `assert exit_code != 0 and stderr == "<exact message>"` for an unsupported value; and
  `assert get_hw_policy() == default` (the "policy unchanged" read, T-W4). **Property:** flag/value domain (MS3.2 text).
- **MS3.3 [BLOCKING — Zig↔WKHTTPCookieStore async] [BUILT-HANDRUN]** G a cookie seeded via the port; W `document.cookie`
  via `page.evaluate`; T it contains the cookie. Red: `mac_cookie_test.py` — `assert "k=v" in document_cookie`.
  **Property (round-trip):** for every valid cookie (name = RFC 6265 token, value = cookie-octets, 0-64 chars),
  `get_all(add(c))` contains c; domain = generated cookies, 200 seeds.

### MS4 (see R29-MS4 for the grant type)
- **MS4.1 [BLOCKING — in-ticket refusal across the card / engine / platform boundary] [PARTIAL]** G a card `approved` for
  window W at (O, N); W W navigates / crashes / opens a dialog / enters `recovering` before dispatch; T the run refuses
  inside its ticket (-32015 with the reason, or -32013) and the fixture records 0 commits. Red:
  `tests/e2e/mac_ms4_refusal_test.py` (TO BE AUTHORED) — `assert commits == 0 and error.reason in {"origin_changed",
  "url_changed", "load_serial_changed", "crashed", "recovering"}`; the Linux engine tests already pin the order.
  **Property (grant state machine, D1):** over all (state, event) pairs of `Grant` × {dispatch, mismatch, close, crash,
  clock-tick, second-dispatch}, the state is always one of the four variants; `used ∧ expired` and a second dispatch
  from one mint are unreachable; domain = exhaustive (4 states × 6 events) plus sequences ≤ 6.
- **MS4.2 [BLOCKING — six actors cross into the native card authority] [NOT STARTED on macOS]** G the grant authority; W a
  page world, an iframe, a related popup, an automation-socket client, a model prompt, a hook each try to approve; T every
  attempt fails and commits 0. Red: `tests/e2e/mac_ms4_negatives_test.py` (TO BE AUTHORED; Linux analog
  `agent_approval_negatives_test.py`, unregistered) — `assert outcome == "refused" and commits == 0` for each actor.
  Property: **Skip** — the actor set is an enumerated six; each is a distinct production entry and the table is exhaustive.
- **MS4.3 [BLOCKING — a card per write across the card boundary] [NOT STARTED on macOS]** G a flow with k ≥ 1 write steps; W
  it runs; T each write gets its own card and a dry-run does no committing click, no real-composer typing, no pacing.
  Red: `tests/e2e/mac_ms4_per_write_test.py` (TO BE AUTHORED) — `assert cards_presented == k`, and for dry-run `assert
  committing_clicks == 0 and pacing_count == 0`. **Property:** `cards_presented == k` for k ∈ 1..6.
- **MS4.4 [BLOCKING — cookie port consumer] [BUILT+REGISTERED on Linux ONLY; macOS WKHTTPCookieStore BUILT-HANDRUN (UNPROVEN), Rev 30 `4pa.69`]** `ms4_4_login_gate_test.py` — `assert gate_open ==
  has_session_cookie`; Property: **Skip** — two-valued gate.

### MS5
- **MS5.1 [LEAF for the refusal decision; BLOCKING for a running setup] [PARTIAL]** Refusal: `tests/agent_setup_ms5_test.zig` —
  `assert platformGate(.macos, false) == .refuse` with the exact line. Running setup: the hard-gate cases in R29.2.
- **MS5.1b [BLOCKING — filesystem census of a built home] [UNPROVEN; Linux stand-in unit registered but a seam with no production caller = NOT BUILT per R30.0 (Rev 32), Mac run pending]** `ms5_1b_hard_gate_case_test.py` —
  `assert canary_bytes_in_home == 0`; Property: **Skip** — four enumerated link shapes, exhaustive.
- **MS5.1c [BLOCKING — a two-tree oracle across arches] [BUILT-HANDRUN = UNPROVEN on the Macs; the pure parts are driven by registered unit tests (C56 is UNPROVEN: its step fails as root and skips)]** Red: `mac_universal_census_test.py` /
  `mac_ms5_census_test.py` mutants. **Properties (T2):** (a) `resource_phase(milestone, inventory)` is total and
  **accepts an empty resource set iff (milestone == "MS1" ∧ exactly the {browser, shim} components)**; domain =
  milestone ∈ {MS1, MS5, "", other} × component sets {browser, browser+shim, +extra, non-browser, MS5-shaped} × resources
  {empty, nonempty} (exhaustive 4×5×2); (b) `merge_universal_tree(a, b)` — **commutativity and idempotence:** `merge(a,b)
  == merge(b,a)` and `merge(merge(a,b), merge(a,b)) == merge(a,b)` for generated trees of ≤ 6 paths with leaf kinds
  {identical, thin+thin, universal2, mismatched}, where a mismatched leaf must fail named (domain: all kind pairs per
  path); (c) the ledger-parser property is under MS6.5.1.
- **MS5.2 [BLOCKING — token crosses the validator→Keychain boundary] [NOT STARTED]** G a `setup-token` value; W
  `zb_agent_onboard_token(service, account, token)` on a disposable keychain; T it is validated, stored, and the canary
  reads back only through the Keychain API. Red: `tests/mac/keychain_onboard_test.m` (RED `24ef54c`, unregistered) —
  `assert read_back == canary` (fails: `zb_agent_onboard_token` is undefined). **Property (round-trip):**
  `lookup(store(t)) == t` for t ∈ printable ASCII 1-256 incl. `=`/`-`/`_`; negative: an invalid token is not stored.
- **MS5.3 [BLOCKING — store→helper fd boundary] [NOT STARTED / seam only]** G a stored token; W a session starts; T the
  token is readable only on helper fd 3 and absent from env/argv/logs/telemetry/hook-env/model context. Red:
  `tests/mac/token_fd_test.m` — `assert canary_in_env == false and fd3_read == canary`; mutant: route via env → red.
  Property: **Skip** — the canary scan is the discriminator; the domain is one secret.

### MS6
- **MS6.1 [BLOCKING — kernel denial across a process boundary; closure OPEN] [profile-belt probes BUILT-HANDRUN]** Red:
  `ms6_1_token_isolation_test.sh` — `assert hook_result == denied and canary_bytes == 0`; removing the process-info
  denies → `canary_bytes > 0`. The production-chain closure is MS6.8. Property: **Skip** — four syscalls, enumerated.
- **MS6.2 [LEAF — pure profile-acceptance probe] [BUILT-HANDRUN]** G a generated profile; W `sandbox-exec -f` on each OS
  version; T accepted (exit 0). Red: `ms6_generated_profile_test.sh` — `assert rc == 0`. **Property (well-formedness):**
  over generated `(ro_paths, workspace, ports)` every profile parses under `sandbox-exec`.
- **MS6.3 [BLOCKING — real CLI across the fd boundary] [lower layer BUILT-HANDRUN; real-CLI hard-gate case UNPROVEN (stand-in unit only, no released Mac run)]** Red:
  `case_ms6_3_fd3_cli.py` — `assert cli_read == canary`; profile-mutant row (R29-MS6) `assert mutant_profile_result ==
  FAIL`. Property: **Skip** — one channel.
- **MS6.4 [BLOCKING — egress through the production proxy] [BUILT-HANDRUN; production-proxy traversal NOT STARTED]** Red:
  `ms6_4_egress_test.sh` rows; Rev 29 `assert fake_api.connects_via_proxy == 1`. **Property (port policy):** for every
  (family ∈ {v4, v6, mapped} × proto ∈ {tcp, udp} × port ∈ {allowed, other}) exactly (v4, tcp, allowed) connects
  (domain: 12 combinations, exhaustive).
- **MS6.5 [BLOCKING — reaper across processes; core only] [core BUILT-HANDRUN, warning NOT STARTED]** Red:
  `ms6_5_reaper_census_gate.sh` (signal-free) — `assert census_pids ⊇ escaper and kill_calls == 0`; the destructive gate is
  REQUIRED to be disabled by default (R29-SAFETY, bd `4pa.70`; NOT yet in code, Rev 31 G5.1).
- **MS6.5.1 [BLOCKING — cross-process ledger/flock] [BUILT-UNARMED = NOT BUILT (Rev 30); owner NOT STARTED]** Reds and mutants as listed in its
  Testing section. **Property (ledger parser, T2):** `parse` is total over arbitrary byte strings of length 0-70 000 — it
  returns a valid ledger or a typed error, never panics, and accepts a document iff it satisfies the strict grammar (closed
  `State {active, left}`, ≤ 256 entries, ≤ 64 KiB, unique basenames, canonical `start_usec`, `pid ≥ 2`, basename pid ==
  entry pid); round-trip `parse(write(l)) == l` for generated valid ledgers; domain = random bytes + mutated valid
  documents (field removed/duplicated/retyped).
- **MS6.6 [BLOCKING — R1 under Seatbelt across processes] [(A) BUILT-HANDRUN = UNPROVEN, (B) UNPROVEN: a pre-ready hard-gate harness exists but has not run in the production chain]** Red:
  `ms6_hard_gate_r1_case_test.py` — `assert verdict == "R1" and census_clean`; the forged-capability mutant → red.
- **MS6.7 [BLOCKING] [NOT STARTED]** and **MS6.8 [BLOCKING] [NOT STARTED]** — specified in R29-MS6 with reds and mutants.
- **`reaper_ready` arming [LEAF — one constant read] [BUILT-UNARMED = NOT BUILT (Rev 30)]** Red: the runtime hostile-environment test
  (`assert actuator_calls == 0`); Property: the (reaper_ready × setting × env) truth table (C-W8, in MS6.5.1).

### MS7
- **MS7.1 [BLOCKING — dock geometry vs the real WKWebView frame, AppKit boundary] [portable driven SEAM (observed 7/7), status NOT BUILT (Rev 31 G4.1); behaviour NOT BUILT; view NOT STARTED]**
  G a window of size (w, h) and the drawer open/folded; W the dock is laid out; T the page rect is above the dock and
  no overlay covers the GPU-composited layer. Red: `agent_drawer_appkit_test.zig` — `assert pageRect.h == h - dock.h`
  (portable); compiled gate: live frame census `assert webview.frame.maxY <= dock.frame.minY` (fails with no view).
  **Mutant (Rev 31, G2.1; named, NOT yet run or recorded):** of the PRODUCTION `zb_drawer_appkit_frame` in
  `src/agent_drawer.zig` — return the page rect with the full window height (do not subtract `dock.h`) → `assert pageRect.h ==
  h - dock.h` in `test-agent-drawer-appkit` fails. Command and failing output go in the commit message when it is run (rule 3).
  **Property (geometry):** for every (w, h, dock ratio) with w, h ∈ [200, 4000], ratio ∈ [0.1, 0.9], `pageRect ∪
  dockRect == windowRect` and they do not overlap; domain = 1 000 random seeds. **[Rev 30, V79-m5: the registered test uses a fixed 10x13 (w, h) grid and `drawerRect` has a fixed 0.4 ratio with no ratio parameter, so this property (1,000 seeds, ratio in [0.1, 0.9]) is NOT what runs. Today's property is the grid; widening it needs a ratio parameter on `drawerRect`.]**
- **MS7.2 [LEAF — one view's drag/persist logic, same module] [NOT STARTED]** G the "S" icon; W it is dragged, clicked
  (< 6 px) or moved by key; T the position persists, the click-vs-drag threshold holds, and it hides while open. Red:
  portable drag-threshold test (TO BE AUTHORED in `tests/agent_drawer_appkit_test.zig` if absent) — `assert dragged ==
  (distance >= 6)`. **Property (roundtrip, existing):** `parse(write(ratios)) == ratios` (`agent_drawer.zig`).
- **MS7.3 [LEAF — one animation curve] [NOT STARTED]** G the panel open; W `-` is pressed; T it folds to the icon's last
  position over 180 ms cubic ease-out. Red: portable curve test (TO BE AUTHORED if absent) — `assert ease(0) == 0 and
  ease(1) == 1 and monotone`; **Property:** monotonicity over t ∈ [0, 1] (1 000 samples).
- **MS7.4 [BLOCKING — NSTextView first-responder copy route] [portable driven SEAM (observed 7/7), status NOT BUILT (Rev 31 G4.1); behaviour NOT BUILT; `ZbBubbleView` NOT STARTED]** Red:
  `agent_drawer_appkit_text_test.zig` — `assert original_offset(shown(t), i) <= len(t)`; compiled gate: live Edit > Copy
  with a nil target copies the ORIGINAL bytes. **Mutant (Rev 31, G2.1; named, NOT yet run or recorded):** of the PRODUCTION
  `zb_drawer_appkit_original_offset` in `src/agent_drawer.zig` — drop the clamp to `len(t)` (return the shown offset plus the
  run expansion unbounded) → `assert original_offset(shown(t), i) <= len(t)` in `test-agent-drawer-appkit-text` fails. **Property:** for every UTF-8/invalid/NUL text t (length 0-2 000), `shown(t)`
  is a valid UTF-16 mapping and `original_offset` is monotone and inverts `shown` on valid prefixes.
- **MS7.5 [BLOCKING — Secrets window → Keychain across the AppKit/Keychain boundary] [portable RED-UNREGISTERED; window NOT STARTED]**
  G the Secrets window and a disposable keychain; W the user saves a token; T it is stored via MS5.2 and the window is
  excluded from the registry. Red: `agent_secrets_window_mac_logic_test.zig` (`5e71d67`) — fails on the undefined
  controller entry point. Property: **Skip** — UI state with two actions.
- **MS7.6 [BLOCKING — native click → card authority] [portable half RED-UNREGISTERED — NOT BUILT (Rev 30 `4pa.72`; the test exits 1 with 5 compile errors); AppKit card NOT STARTED]** G a pending card;
  W Approve / Deny; T Approve reaches `approved` exactly once, Deny and expiry never mint. Red:
  `agent_drawer_card_press_test.zig` — `assert press(card_own_control) == .approve and press(elsewhere) == .none`; the
  compiled gate drives a real Approve. **Property:** the `Outcome` machine is monotone (`waiting` → one terminal;
  terminals absorbing) over all event sequences ≤ 5.
- **MS7.7 [BLOCKING — native census vs production socket separation] [NOT STARTED]** G a chat round-trip; W the census is
  requested under `--e2e-protocol`; T the bubble text is observed there and a production socket read of drawer text is
  impossible. Red: `tests/e2e/mac_ms7_census_test.py` (TO BE AUTHORED) — `assert "bubble" in census and
  socket_drawer_read == "method_not_found"`. Property: **Skip** — one census row type.
- **MS7.8 [BLOCKING — AppKit action → grant seam] [portable half RED-UNREGISTERED — NOT BUILT (Rev 30 `4pa.72`); compiled gate RED-UNREGISTERED]** closure in its
  section. Red: `ms7_appkit_gate_test.py` — `assert grant_after_approve == "minted" and grant_after_deny is None` through
  the fixture-card entry (K6).
- **MS7.9 [BLOCKING — drawer lifecycle across window destruction] [NOT STARTED]** G a primary window and a popup, each with
  its drawer; W `webViewDidClose:`, the close button and `page.close`; T the drawer detaches before the automation close
  notification, the opener survives, and the live-drawer count is 0 after all windows close. Red:
  `tests/e2e/mac_ms7_drawer_ownership_test.py` (TO BE AUTHORED) — `assert zb_drawer_debug_live_count() == 0` (the symbol
  is undefined today → link failure). **Property:** for any create/close sequence of ≤ 6 windows, live drawers == live
  windows after each step.

### MS8
- **MS8.1 [BLOCKING — helper under the backend, spawn chain] [NOT STARTED; portable core is a driven SEAM, NOT BUILT (Rev 31 G4.1)]** G the token on
  fd 3 and `MacSeatbeltBackend`; W the browser starts the helper via MS6.8; T `ready` arrives and validates. Red:
  `tests/e2e/mac_ms8_helper_ready_test.py` (TO BE AUTHORED) — `assert ready_frame_valid`. Property: **Skip** — frame
  validation is the shared, registered `agent_protocol.zig`.
- **MS8.2 [BLOCKING — drawer↔helper↔broker async pump] [8.2a/8.2b RED-UNREGISTERED; 8.2c NOT STARTED]** Red:
  `tests/agent_helper_core_test.zig` — `assert calls == expected_ordered_port_calls` (fails: the core is not yet green);
  **Property (isolation):** for any window set ≤ 3 and event interleaving, a window's frames never reach another window.
- **MS8.3 [BLOCKING — helper tool_use → native approve → single commit] [NOT STARTED]** closure in its section. Red:
  `assert fixture_commits == 1` on Approve and `== 0` on Deny/expired/retargeted.

---

## Dependency order

`MS0 (Linux) → MS1 → MS2a → MS2b → MS2c → MS3 → MS4 → MS5 → MS6 (hard gates) → MS7 → MS8 (blocked
on MS6) → MS9 (blocked on Developer ID)`. **Rev 29 additions to the order:** `MS5.1c → MS1c (convert build-dmg.sh) →
MS9`; `MS6.7 (curation) and MS6.8 (production launch connector) are part of MS6 and precede MS8.1`; `MS6.5.2` needs
MS6.8 + MS7; `MS7 AppKit views → MS7.9 → MS8.2c`; MS7.1/7.4 portable seams are driven (seam tests only, no production caller); MS7.0, the MS7.6/7.8 portable half and MS8.0 are NOT BUILT (Rev 30: R30.1 #1, #5, #6). MS3/MS4/MS5 may proceed in parallel after MS2a; MS7
needs MS4 (grant) + MS5 (Keychain); MS8 needs MS5 (setup) + MS6 (sandbox) + MS7 (drawer).

### Rev 31 — dependency order of the 26 Rev-30 fix-forwards (bd `4pa.55` to `4pa.80`; G6.3)

This is the order in which the 26 fix-forwards are implemented once the freeze `zigBrowser-4pa.1` lifts. It orders WORK, not
slices; the slice order above still governs everything else. Each item names its owning R30-MSn block. Every item follows the
per-slice protocol (red first, registered in the green, mutant recorded). **No item below authorises a Mac run**: Mac steps
need RoseCat exact-commit approval AND an orchestrator release (R29-SAFETY).

**Phase A — the three CRITICAL findings, in this order.**
1. **`4pa.55` (CRITICAL, R30-MS2): a failed or recovered page load must not quit the browser.** FIRST. Take the owner decision
   R30.3 #1 (default: option C, quit only for the primary window's initial load). Rewrite `mac_ms2a_user_nav_failure_test.py`
   (the oracle that encodes the defect), then the fix. Red is Linux-parsed or compile-only until a Mac release.
2. **`4pa.72` (CRITICAL, R30-MS7): MS7.6/7.8 card press.** Author `Approver`, `cardPress`, `zb_drawer_card_press` in
   `src/agent_drawer.zig`; the red `test-agent-drawer-card-press` is registered in `test` only in the green. Portable, no Mac.
3. **`4pa.73` (CRITICAL, R30-MS1): the release script cannot make a working app (MS1c).** Hostless Red 1 (`test-mac-dmg-script`)
   first; the Mac Red 2 and the bundle layout wait for item 24 (`4pa.80` spike).

**Phase B — the HOSTLESS selftests that need no Mac. Do these early; they are independent and may run beside Phase A.**
Each is a Linux step with stub `ssh`/`scp`/`lipo`/`codesign`, added to `test` in its green, and none touches a host.
4. **`4pa.70` (R30-MS6 / R29-SAFETY): `test-mac-reaper-gate-guard`.** Land the disable-by-default guard for
   `ms6_5_reaper_gate.sh` BEFORE anyone is tempted to run it. Until it lands the script must not be run (G5.1).
5. **`4pa.59` + `4pa.77` (R30-MS1): `test-mac-build-script`.** Build from `git archive <sha>` into a fresh per-run remote
   directory, pinned `known_hosts`, `StrictHostKeyChecking=yes`. Takes owner decision R30.3 #2 (default YES). Every later Mac
   gate depends on it, so it precedes any Mac step.
6. **`test-mac-dmg-script`** (the hostless half of item 3, `4pa.73`), if not already done in item 3.
7. **MS1.4 fail-closed runner: `test-mac-gate-selftest`** (R30-MS1; no bd id, a rule-7 requirement).
8. **`4pa.63` (R30-MS6): `test-darwin-guard-selftest`.** The meta-test that proves the Darwin cross-compile guard analyses the
   ledger and recovery code. It precedes any claim that ledger/recovery "builds for Darwin" (items 15-16).
9. **Rev 31 L1: `test-mac-stage-gate-selftest`** (R30-MS5; hash-locked sigstore install of `ms5_stage_gate.sh`).

**Phase C — MS2 and MS3 majors (the Mac runtime is UNPROVEN until these exist).**
10. **`4pa.62` (R30-MS2): give `ms2b-gate`, `ms2c-gate` and `ms3-gate` real build steps, and add the Linux parser tests.** Without
    it nothing in MS2/MS3 can be called registered.
11. **`4pa.58` (R30-MS2): new sub-slice MS2c.6, the native close button must reach the registry.** After item 1 (same window
    lifecycle code) and the owner decision R30.3 #3 (default: match Linux). MS2c.6 specifies popups and secondary windows only.
12. **`4pa.57` (R30-MS2): `page.dialogs` window id.**
13. **`4pa.56` (R30-MS3): cookie calls honour `timeout_ms`.**
14. **`4pa.60` (R30-MS3): pacing dir created for a new `--profile-dir`.**

**Phase D — MS4 majors.**
15. **`4pa.64` (R30-MS4): broker phaseA keeps `options.guard`.** Portable, Linux-registered.
16. **`4pa.69` (R30-MS4): the Mac-only `ms4-gate` step** (MS4.4 login gate over `WKHTTPCookieStore`; `load_serial` on a Mac).

**Phase E — MS5 and MS6 majors, in this order.**
17. **`4pa.66` (R30-MS6, D2): the registered readiness pin and the one-type derivation BEFORE ANY MS6.7 WORK.** The `4pa.66`
    rule "before any MS6.7 work" (R30-MS6, the Order bullet) is a hard gate on MS6.7 and on every item after it in this phase.
18. **`4pa.65` + `4pa.71` + `4pa.68` (R30-MS6, MS6.5.1) in ONE green:** thread the real store name (`zigbrowser-agent-runs.json`)
    into `recoverOneUnderLock`/`…P`, register the transaction test in `test` and make the gated entries non-`pub`, and reject
    `pid < 2` at parse. Needs item 8 (`4pa.63`) first so the Darwin compile claim is real.
19. **`4pa.67` (R30-MS5 and R30-MS6): production paths.** Put the Keychain and token-fd files in the macOS build target (MS5.2,
    MS5.3), and build the launch connector MS6.8 with an `ms6-gate` and `ms5-gate` step. Until then those rows are NOT BUILT.
20. **MS6.7 curation** (R29-MS6; no bd id of its own, owned by `4pa.66`'s derivation): after items 17-19.

**Phase F — MS7 and MS8 majors.**
21. **`4pa.76` (R30-MS7): rename the Mac Secrets entry to `zb_secrets_window_mac_show`** before the MS7.5 green.
22. **`4pa.75` (R30-MS8): the macOS approval minters must start and work (MS8.0).** After item 2 (card press).
23. **`4pa.74` + `4pa.78` (R30-MS7): the K6 fixture-card entry and the gate that can pass at MS7, built ONLY under the test-only
    build option `-Dtest-seams`, absent from the release binary.** After items 2 and 22.

**Phase G — MS9 and packaging majors (all need a Mac; blocked on release, and the notarization leg on the Developer ID).**
24. **`4pa.80` (R30-MS9): the bundle-layout spike.** Runs BEFORE MS1c fixes the layout (item 3, Red 2).
25. **`4pa.79` (R30-MS9): the widened MS9.0 entitlement and CLI spike.** Before MS9.1.
26. **`4pa.61` (R30-MS1): the MS1.3 entitlement probe (`ms1_entitlement_probe.sh`).** Shares the MS9.0 spike (item 25), so it
    runs with it.

All 26 bd ids appear above, each ordered once (`4pa.59` and `4pa.77` share item 5; `4pa.65`, `4pa.71`, `4pa.68` share item 18;
`4pa.74` and `4pa.78` share item 23). `4pa.73` and `4pa.66` are additionally cross-referenced in items 6 and 20 (Rev 32, G6.3 wording). The Linux-side or hostless reds of items 4-16 can proceed while the owner decides R30.3 (each uses the stated default); their Mac proofs stay UNPROVEN until a released run.

**MS1b (the signed x86_64 binary runs) — split out, NOT a universal blocker** (user decision
"split it out, fix now", over "fix it before MS1"; orchestrator). Its binding edges:
- **`MS1 → MS1b`, scheduled immediately** — MS1b is the next Mac slice JadeBeacon works on.
- **MS1b is a HARD prerequisite of MS9** (release signing + notarization) **and of any slice, gate,
  documentation claim, or real-screen check that claims a SIGNED binary runs** — no such claim may
  be marked done until Gate(MS1b) is green.
- **MS2a and every later development slice MAY proceed IN PARALLEL with MS1b, running the UNSIGNED
  universal build** (MS1 reports the unsigned universal runs on both arches; **SUSPECTED** — no released run recorded here, Rev 32). Those slices **must
  NOT claim a signed-run result** until MS1b is green; MS1 itself does not prove a signed binary runs.

## Per-slice gate protocol (all slices)

1. Mail "taking the gate slot" only for the gate run (docs-only commits exempt). 2. Write the
slice's red tests; **record the red runs [Rev 29: AT THE COMPILE-ONLY R4 TIER (`tests/mac/mac_compile_only.sh`) or on
Linux; a red may be recorded on a Mac ONLY with RoseCat exact-commit approval AND an orchestrator release — the
earlier wording "(on a remote Mac for e2e)" conflicted with the owner's rule and with the 24ef54c incident]**. A red
test file is created UNREGISTERED and registered in the green that makes it pass (never add a failing test to a
registered step in a red commit). 3. Green. 4. Refactor (remove
duplication). 5. Quiet gate from a clean `git archive HEAD` + the slice's files. 6. Commit only the
slice's files (stage only your own). 7. Mail RoseCat. 8. UI slice (MS7, MS8 reply render): add the
macOS real-screen case; the orchestrator runs it on the user's Mac; **not approved until it passes
there**. A slice is not done until its closure e2e was **observed to execute** with nonzero
assertions; "SKIP" counts as UNCLOSED. Every MS2–MS8 sub-slice carries a **named red test, an exact
failing assertion, named green production files, and a refactor gate**.

## References

- Reviews answered: `thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
  — §"macOS launch plan review (d857a03)" (rev-1 blockers, commit 21625eb), §"macOS launch
  plan rev 2 and 2.1 (c3d7217, 9c2b2c3)" (rev-2 blockers, commit 833767e), §"macOS launch plan
  rev 3 (a02f1ea, with 5bebd42 follow-up)" and §"S3a follow-up and prefix audit at da5eb70"
  (rev-3 blockers, commit db02324)
- Drawer grant schema reused (rev 3 blocker 2): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:503-519` (grant tuple, `load_serial`, `options.expect`, −32015, T5 mutants)
- Production `tool_use` source (rev 4 blocker 1 — why the positive commit closure is MS8.3, not from the socket): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md:1231-1232, 2013-2020` (CLI → helper → protocol pump; the broker is unreachable from the automation socket)
- S3a corrections inherited by MS5 (rev 3 blocker 1, dependency corrected in rev 4): **da5eb70** (chain / internal-alias / malformed-quote — approved green per review db02324 §"S3a follow-up and prefix audit"), owned by BlackRobin. Supersedes the earlier `cab60a1`, which was still blocked.
- Research: `…/research/2026-10-14-14-19-macos-launch-support-surface.md` (1df5dce) + its `.closure-adapter.py`
- Sandbox: `…/research/2026-10-14-macos-sandbox-option.md`, `…/2026-10-14-agent-sandbox-redteam.md`
- Drawer plan (conventions, real-screen §7.1): `…/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`
- Prior WKWebView backend plan: `…/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md`
- Bead `zigBrowser-8g7` (M9 render + ping/pong DONE on Intel Mac)
- Code anchors (**Rev 29: re-baselined to `e4f705f`; symbols are the citation, numbers are hints**):
  build.zig `resolveBackend`, `CheckMacosBackendStep`, `configureMacosBackend` (MS1b dylib), steps `mac-gate`
  (`:241-242`; symbol-presence tripwires, not evidence: `cross-check-drawer-mac`, `cross-check-agent-tools-mac`, `check-card-authority-mac`), `ms1b-gate` (`:247-248`), `ms2a-gate` (`:254`), `cross-check-drawer-mac` (`:477`),
  `cross-check-agent-tools-mac` (`:504`), `check-card-authority-mac` (`:534`), `test-agent-drawer-appkit` (`:749`),
  `…-card-press` (`:767`), `…-appkit-text` (`:780`); src/wkwebview_shim.m (`zb_app_run`, `zb_automation_*`);
  src/automation_server.zig `handleRequestWith` (`:467`), `handleWindows` (`:744`), `handleRecover` (`:995`),
  `handleDialogs` (`:1176`); src/automation_macos_port.zig (wired `src/app.zig:626`),
  src/automation_macos_cookie_port.zig (`app.zig:627`); src/automation_gtk_port.zig;
  src/automation_platform.zig:90-95; src/app.zig `runAgentSetupMacos` (`:195-215`); src/webkit.zig
  `applyBackendFlag` (`:40`), `applyAgentDrawer` (`:131-134`); src/backend_flag.zig `backendFlagDecision` (`:31`);
  src/agent_approval.zig `Outcome` (`:188`), `Cards.approve` (`:279`); src/agent_tools.zig (`:200,206`);
  src/automation/engine.zig `WindowWant`/`windowRefusal` (~`:1215-1236`); src/automation/router.zig `Expect` (`:54`);
  src/agent_setup.zig `seatbelt_ready` (`:67`); src/agent_run_ledger.zig (`:469,500,547,557,573,579`);
  src/agent_run_recovery.zig `reaper_ready` (`:334`), `recoverAllAtStartup` (`:365`);
  agent/host/zb_agent_host/sandbox.py, sandbox_macos.py (`:173,183,216,226,352,371,393,413-442`), hook_run.py
  (`:189-208`), launch.py (`:97,111,154-157`); src/agent_host.c; packaging/macos/build-dmg.sh (`:71,92`);
  packaging/macos/Info.plist:21-22

## Blocker status (process note — RESOLVED 2026-10-20)

**HISTORICAL:** earlier the shared bd DB had pending schema migrations (v49→v53) and refused
auto-apply on the remote-backed clone, so tracking beads could not be filed (`bd migrate`/`bd
bootstrap` are destructive/coordination actions not taken unilaterally). **This is resolved:** the
orchestrator migrated the local bd DB (with the user's approval) on 2026-10-20, and `bd create`
works again (no `dolt push`). Beads are now filed normally (e.g. the gate parallelism/load finding
is `zigBrowser-tka`). Status is still cross-referenced via Agent Mail + this plan.

---

## Verification rule compliance (Rev 30; one row per behaviour; the rule is the section "Verification rule: prove it by running it" at the top of this plan)

How to read it. Columns **a, b, c, d** are the four rule-9 fields: (a) production entry point exercised, (b) test file and its
build.zig step (registered, or a named platform gate), (c) the mutant of the PRODUCTION code that must fail the test, (d) for
platform code the platform run and its hosts (**n/a** for portable code). A field is **y** only when the plan names it AND it
exists today; **n** means missing or not yet recorded. **Complete** is **yes** only when all applicable fields are y.
**Proof type** is **driven** (a registered test calls the production code), **platform run** (a run on the real platform under a
release), or **tripwire-only** (the only check is a grep, symbol, listing, constant or text check). A claim marked "observed" was
run by a validator at `d0f1841` (rule 8); every other y is the plan's own statement and has not been re-run, so this table
never says VERIFIED without "observed".
The status words are those of R30.0. Every row with status other than BUILT+REGISTERED names what is missing in its proof-type
cell or in the R30 block cited there.

| ID | Behaviour | a | b | c | d | Complete | Proof type and what is missing | Status |
|---|---|---|---|---|---|---|---|---|
| C01 | MS0.1 Linux backend, identical argv | y | y | y | n/a | yes | driven; observed 28/28 and the swap mutant 16 failures | BUILT+REGISTERED |
| C02 | MS0.2 Lifetime → C spawn policy as data flow | n | n | n | n/a | no | tripwire-only (a constant-equality test); no production caller; R30-MS0 | NOT BUILT |
| C03 | MS1.1 census / `resource_phase` unit logic | y | y | y | n/a | yes | driven; observed 27 OK | BUILT+REGISTERED |
| C04 | MS1.1 Mac census of the built bundle | y | y | n | n | no | `mac-gate` is not in `test`; no recorded released run; census is a listing (T18) | UNPROVEN |
| C05 | MS1.1 bundle == inventory (undeclared file) | n | n | n | n | no | observed demo: an undeclared non-Mach-O file passes | NOT BUILT |
| C06 | MS1.2 executing-arch readback | y | y | n | n | no | `mac-gate` only; no mutant recorded; no released run | UNPROVEN |
| C07 | MS1.3 least-privilege entitlement manifest | n | n | n | n | no | tripwire-only (signs with the plist, compares to it); key does nothing; the exercising proof `tests/mac/ms1_entitlement_probe.sh` is TO BE AUTHORED, so b=n (Rev 31, G2.6: y means "exists today"); R30-MS1 `4pa.61`, R30-MS9 `4pa.79` | UNPROVEN |
| C08 | MS1.3 `release_least_privilege` rule | n | y | y | n/a | no | tripwire-only (manifest/binary text scan) | UNPROVEN |
| C09 | MS1.4 fail-closed gate runner | y | n | n | n | no | no hermetic selftest; R30-MS1 | UNPROVEN |
| C10 | MS1b signed binary runs (ad-hoc) | y | y | n | n | no | `ms1b-gate` not in `test`; no hardened leg; pixel check skipped | UNPROVEN |
| C11 | MS1c convert `build-dmg.sh` | n | n | n | n | no | not started; R30-MS1 `4pa.73` | NOT STARTED |
| C12 | Gate builds a pinned commit, fresh remote dir (D-R30-2) | n | n | n | n/a | no | not built; R30-MS1 `4pa.59` | NOT BUILT |
| C13 | Gate and release scripts use pinned host keys | n | n | n | n/a | no | not built; R30-MS1 `4pa.77` | NOT BUILT |
| C14 | MS2a.1 routed commands | y | y | n | n | no | `ms2a-gate` not in `test`; no recorded released run | UNPROVEN |
| C15 | MS2a.2 private content world | y | y | y | n | no | `ms2a-gate`; plan names the pageWorld mutant; no released run | UNPROVEN |
| C16 | MS2a.3 job state machine and string ownership | y | y | y | n | no | `ms2a-gate`; debug seams; no released run | UNPROVEN |
| C17 | MS2b.1 native click, key, text | y | n | n | n | no | `ms2b_gate.sh` hand-run, no step | UNPROVEN |
| C18 | MS2b.1 native scroll, move, pointer | n/a | n/a | n/a | n/a | n/a | user decision 2026-10-20 | UNSUPPORTED |
| C19 | MS2b.2 alert/confirm/prompt dialogs | y | n | y | n | no | hand-run; no dialog-in-later-popup test | UNPROVEN |
| C20 | MS2b.2 `page.dialogs` window id | n | n | n | n | no | wrong id after a popup closes; R30-MS2 `4pa.57` | NOT BUILT |
| C21 | MS2b.3 input files; MS2b.4 screenshot | n | n | n | n | no | absent from shim and port vtable | NOT STARTED |
| C22 | MS2c.1 popups, per-window FIFO | y | n | n | n | no | `ms2c_gate.sh` hand-run, no step | UNPROVEN |
| C23 | MS2c.2 out-of-band health and list | y | n | y | n | no | hand-run; mutant planned (`dispatch_sync` snapshot) | UNPROVEN |
| C24 | MS2c.3 two-phase recover by view replacement | y | n | n | n | no | hand-run; abandoned-process exit unobserved (P-W2) | UNPROVEN |
| C25 | MS2c.4 crash presentation | y | n | y | n | no | hand-run; 3 s auto-reload mutant planned | UNPROVEN |
| C26 | MS2c.5 drawer ownership on destroy | n | n | n | n | no | moved to MS7.9 | NOT STARTED |
| C27 | MS2c.6 native close button destroy path | n | n | n | n | no | window stays registered; R30-MS2 `4pa.58` | NOT BUILT |
| C28 | A failed page load does not quit the browser | n | n | n | n | no | macOS exits; existing test asserts the exit; R30-MS2 `4pa.55` | NOT BUILT |
| C29 | ABI export set equals the promoted set | n | y | n | n | no | tripwire-only (`nm` listing); T1 | UNPROVEN |
| C30 | MS2 Closures A, B, C (e2e through the socket) | y | y | n | n | no | hand-run or `ms2a-gate`; no registered Mac step for B and C (`4pa.62`: ms2b, ms2c, ms3 gates have no step) | UNPROVEN |
| C31 | MS3.1 profile store persistence | y | n | y | n | no | `ms3_gate.sh` hand-run, no step | UNPROVEN |
| C32 | MS3.1 pacing state persists for a new `--profile-dir` | n | n | n | n | no | profile dir not created; R30-MS3 `4pa.60` | NOT BUILT |
| C33 | MS3.2 flag decision (`backendFlagDecision`) | y | y | n | n/a | no | driven (Zig tests in `test`); before-validate mutant missing (T-W4) | BUILT+REGISTERED |
| C34 | MS3.2 flag effect on macOS | y | n | n | n | no | Mac e2e hand-run; no read-back seam | UNPROVEN |
| C35 | MS3.3 cookie ABI and port | y | n | n | n | no | Zig tests skip off a Mac; e2e hand-run | UNPROVEN |
| C36 | MS3.3 cookie calls honour `timeout_ms` | n | n | n | n | no | `zb_job_inflight` missing; R30-MS3 `4pa.56` | NOT BUILT |
| C37 | MS4.1a `load_serial` (Linux twin) | y | y | y | n/a | yes | driven (`build.zig:3348,3812`); mutants (counter never increments / resets on commit) are named in the LIVE R29-MS4 text (Rev 31, G2.2), not only in the historical rev-6 section | BUILT+REGISTERED |
| C38 | MS4.1a `load_serial` (macOS) | y | n | n | n | no | `ms4_gate.sh` hand-run; mutants named in the live R29-MS4 text (Rev 31, G2.2) but NOT recorded as run (Rev 32: c=n) | UNPROVEN |
| C39 | MS4.1 in-ticket refusal (engine, Linux) | y | y | y | n/a | yes | driven (`automation_expect_*_test.zig`) | BUILT+REGISTERED |
| C40 | MS4.1 in-ticket refusal over macOS | n | n | n | n | no | `mac_ms4_refusal_test.py` does not exist | NOT STARTED |
| C41 | MS4 card single use (`Cards`, Linux) | y | y | y | n/a | yes | driven; the only caller is the GTK drawer | BUILT+REGISTERED |
| C42 | MS4 card on macOS (a caller exists) | n | n | n | n | no | no macOS caller; see C93 | NOT BUILT |
| C43 | MS4 card bound to account and target (`options.guard`) | n | n | n | n/a | no | no digest; phaseA drops `guard`; R30-MS4 `4pa.64` | NOT BUILT |
| C44 | MS4.2 negative proofs on macOS | n | n | n | n | no | Linux analog unregistered | NOT STARTED |
| C45 | MS4.3 per-write confirmation, dry-run inert on macOS | n | n | n | n | no | no macOS test | NOT STARTED |
| C46 | MS4.4 login gate (Linux binary, GTK port) | y | y | n | n/a | no | driven (`ms4-4-login-gate-e2e`); mutant not named | BUILT+REGISTERED |
| C47 | MS4.4 login gate over `WKHTTPCookieStore` | y | n | n | n | no | `ms4_gate.sh:40` hand-run; R30-MS4 `4pa.69` | UNPROVEN |
| C48 | MS5 `platformGate` decision (macOS refuses) | y | y | n | n/a | no | driven (`agent_setup_ms5_test.zig`); decision mutant not named | BUILT+REGISTERED |
| C49 | MS5 `seatbelt_ready` stays false | y | n | n | n | no | observed: flipping the constant leaves the step at exit 0; R30-MS6 `4pa.66` | UNPROVEN |
| C50 | MS5 `runtimeFor`, `selfExe` on macOS | n | y | n | n/a | no | Linux branch driven; macOS branch unreachable (gate refuses) | NOT BUILT |
| C51 | MS5 home lock | y | n | n | n/a | no | Rev 31 (G2.3): the plan cannot name a test file and step that call `zb_agent_home_lock` (callers: `app.zig:127,191`, `agent_helper.c:813,952`; `tests/e2e/agent_login_locks_test.py`, `build.zig:2866`, is about Secrets-window control locks, NOT this flock); "existing lock tests" is unnamed, so b=n; a named flock exclusion test (two processes, one holder) is required; macOS only compiles | UNPROVEN |
| C52 | MS5 item 5 setup group dies with the browser (macOS) | n | y | y | n | no | Linux fake-ops only; Mac e2e case (b) hard-fails; unreachable | NOT BUILT |
| C53 | MS5.1 setup runs on macOS | n | n | n | n | no | `--agent-setup` refuses | NOT BUILT |
| C54 | MS5.1 hard-gate case S3a links | y | y | y | n | no | stand-in unit registered; Mac run pending | UNPROVEN |
| C55 | MS5.1b skipped-link bytes | y | y | y | n | no | stand-in unit registered; Mac run pending | UNPROVEN |
| C56 | MS5.1c census, merge, relocate, stage (pure parts) | y | n | y | n/a | no | Rev 31 (G2.4, G4.2): `test-mac-census` exits 1 under `--map-root-user` (`test_ms5_1b…unreadable_file_or_a_fifo` fails as root) and reports "OK (skipped=6)" (6 Darwin-only "no kqueue" skips). Rule 7: a skip or a failing step is a failure, so it is NOT Complete and NOT BUILT+REGISTERED until the skips fail the Mac tier and the root guard lands (R30-MS5 V46-F20); observed | UNPROVEN |
| C57 | MS5.1c staging on the Macs | y | n | y | n | no | `ms5_*_gate.sh` hand-run | UNPROVEN |
| C58 | MS5.2 Keychain onboarding | n | n | n | n | no | Keychain files in no build target; R30-MS5 `4pa.67` | NOT BUILT |
| C59 | MS5.3 token only to fd 3 | n | n | n | n | no | seam, no caller, not in `build.zig`; R30-MS5 `4pa.67` | NOT BUILT |
| C60 | MS6.1 token isolation | n | n | y | n | no | profile-belt probes only; closure OPEN; no production trigger | UNPROVEN |
| C61 | MS6.2 generated profile accepted | y | n | n | n | no | `ms6_generated_profile_test.sh` hand-run | UNPROVEN |
| C62 | MS6.3 fd 3 reopen and real CLI | n | n | n | n | no | probes and a hard-gate case; no profile-mutant row | UNPROVEN |
| C63 | MS6.4 egress and denials | n | n | n | n | no | hand-run probes | UNPROVEN |
| C64 | MS6.4 traversal of the production proxy | n | n | n | n | no | not started | NOT STARTED |
| C65 | MS6.4 netd Darwin (Python tests, Linux) | n | y | n | n | no | no production importer of `spawnNetd` | NOT BUILT |
| C66 | MS6.5 reaper core | n | y | y | n | no | engine tests registered; linked only into tests; census gate hand-run | NOT BUILT |
| C67 | MS6.5.1 ledger parse, publish, lock | n | y | y | n | no | registered; no production caller; pid unchecked (`4pa.68`) | NOT BUILT |
| C68 | MS6.5.1 recovery transaction | n | n | n | n | no | test unregistered or MANUAL; wrong store name (`4pa.65`, `4pa.71`) | NOT BUILT |
| C69 | MS6.5.1 startup core and `reaper_ready` | n | y | n | n | no | registered test uses `runs.json`; readiness proof is `indexOf` (T7) | NOT BUILT |
| C70 | Darwin cross-compile guards (ledger, recovery) | n/a | y | n | n | no | tripwire-only and vacuous (observed); `4pa.63` | UNPROVEN |
| C71 | MS6.5.1 production owner (run dir, marker, states) | n | n | n | n | no | not started; bd `zigBrowser-3gl` | NOT STARTED |
| C72 | MS6.5.2 warning and setting; MS6.5.3 Darwin probe | n | n | n | n | no | not started | NOT STARTED |
| C73 | MS6.6 R1 under Seatbelt (A) kernel gate and (B) harness | y | y | y | n | no | hand-run; (B) built, not run | UNPROVEN |
| C74 | MS6/MS8 hook Darwin branch | y | n | y | n | no | Rev 31 (G2.5, G4.4): only `ms8_hook_sandbox_case_unit` is in `test` (`build.zig:3695`); `ms8_hook_launch_env_case_unit` hangs off `test-mac-census` only (`build.zig:3146`), a draft by rule 2, so b=n until it is added to `test`; Mac run pending; nested `sandbox-exec` unverified | UNPROVEN |
| C75 | MS6 profile generator output | y | y | n | n | no | tripwire-only (pins broad text); kernel enforcement unproven | UNPROVEN |
| C76 | MS6.7 read and mach-lookup curation | n | n | n | n | no | not started | NOT STARTED |
| C77 | MS6.8 production launch connector | n | n | n | n | no | not started | NOT STARTED |
| C78 | `MacSeatbeltBackend` conforms and is called | n | n | n | n | no | no production caller; no conformance test | NOT BUILT |
| C79 | VM-containment stub (setup path) | y | y | n | n/a | no | driven (`test-mac-vm-containment`); launch path not covered | BUILT+REGISTERED |
| C80 | Reaper destructive gate disabled by default | n | n | n | n/a | no | only `ZB_MAC_ARM_HOST` guards it; `4pa.70` | NOT BUILT |
| C81 | Debug hooks inert without `--e2e-protocol` | y | y | n | n | no | covers 4 of 13 hooks | UNPROVEN |
| C82 | MS7.0 portable drawer exports on macOS | n | n | n | n | no | tripwire-only (symbols); not in `test`; no caller | NOT BUILT |
| C83 | MS7.1 portable dock geometry seam | n | y | n | n/a | no | Rev 31 (G4.1, G2.1): driven, observed 7/7, but no `.m` file calls the seam (R30.1 #7), so a=n and the status word is NOT BUILT (R30.0: BUILT+REGISTERED needs a production caller). The mutant (full-height page rect) is NAMED in the ledger MS7.1 entry but not yet run, so c=n | NOT BUILT |
| C84 | MS7.1 AppKit dock view | n | n | n | n | no | `agent_drawer_mac.m` does not exist | NOT STARTED |
| C85 | MS7.2 icon, MS7.3 fold | n | n | n | n | no | not started | NOT STARTED |
| C86 | MS7.4 portable bubble text seam | n | y | n | n/a | no | Rev 31 (G4.1, G2.1): driven, observed 7/7, but no `.m` file calls the seam (R30.1 #7), so a=n and the status word is NOT BUILT. The mutant (unclamped `original_offset`) is NAMED in the ledger MS7.4 entry but not yet run, so c=n | NOT BUILT |
| C87 | MS7.4 `ZbBubbleView`, Edit menu | n | n | n | n | no | not started | NOT STARTED |
| C88 | MS7.5 Secrets window controller | n | n | n | n | no | red, unregistered, imports a missing module; name clash `4pa.76` | RED-UNREGISTERED |
| C89 | MS7.6/7.8 portable card press | n | n | n | n | no | observed exit 1 (5 compile errors); `4pa.72` | RED-UNREGISTERED |
| C90 | MS7.8 native Approve/Deny mint over AppKit | n | n | n | n | no | no AppKit card; minters inert | NOT STARTED |
| C91 | MS7 compiled two-Mac gate | n | n | n | n | no | red, unregistered; cannot pass at MS7 (`4pa.74`) | RED-UNREGISTERED |
| C92 | Lexical card/bubble oracles | n | n | n | n/a | no | tripwire-only; parse a missing file | RETIRED |
| C93 | MS8.0 approval minters on macOS | n | n | n | n | no | always return 0; symbol check passes (observed); `4pa.75` | NOT BUILT |
| C94 | MS7.7 chat census; MS7.9 drawer ownership | n | n | n | n | no | not started | NOT STARTED |
| C95 | Fixture-card entry (K6) and its absence from release | n | n | n | n | no | plan only; `4pa.74`, `4pa.78` | NOT STARTED |
| C96 | MS8.1 portable spawner core seam | n | y | y | n/a | no | driven; observed 12/12 and 8 kill-group cases; no `spawnNetd` importer, so a=n and (Rev 31, G4.1) the status word is NOT BUILT (a seam with a driven test, no production caller) | NOT BUILT |
| C97 | MS8.1 helper under `MacSeatbeltBackend` | n | n | n | n | no | not started | NOT STARTED |
| C98 | MS8.2a helper core | n | n | n | n | no | red, unregistered | RED-UNREGISTERED |
| C99 | MS8.2b POSIX transport | n | n | n | n | no | red, uncommitted | RED-UNREGISTERED |
| C100 | MS8.2c wiring; MS8.3 approved commit | n | n | n | n | no | not started | NOT STARTED |
| C101 | MS9.0 spike, MS9.1 signing, MS9.2 notarization | n | n | n | n | no | not started; blocked on Developer ID; `4pa.79`, `4pa.80` | NOT STARTED |
| C102 | R4 compile-only harness selftest | y | n | n | n/a | no | driven; observed exit 1 as root (7 cases), exit 0 as a real user under a reaping PID 1 (V79-m12). Rev 31 (G4.3): it fails under the plan's own standard wrapper (R30.1 #24), so b=n and it is not BUILT+REGISTERED until the root guard lands | UNPROVEN |

**Counts of record at Rev 31 (102 behaviours; recounted from the 102 rows above by script after the Rev 31 status changes):**
BUILT+REGISTERED 9 (C01, C03, C33, C37, C39, C41, C46, C48, C79; C01 and C03 were observed at d0f1841, the rest rest on the plan's own statement);
UNPROVEN 38; NOT BUILT 28; RED-UNREGISTERED 5; NOT STARTED 20; UNSUPPORTED 1; RETIRED 1 (9 + 38 + 28 + 5 + 20 + 1 + 1 = 102).
Rows with all applicable rule-9 fields complete (Complete = yes): 5 (C01, C03, C37, C39, C41). Every other row names what is
missing. A BUILT+REGISTERED row with Complete = no (for example C33, C46, C48, C79) is registered and driven but lacks a recorded
mutant, so it is not proof until the mutant is recorded in the commit message (rule 3).
**Changes from the Rev 30 counts (15 / 35 / 25 / 5 / 20 / 1 / 1 and 8 complete):** C83, C86 and C96 moved from BUILT+REGISTERED to
NOT BUILT (seams with a driven test and no production caller, R30.0; G4.1); C56, C102 and C51 moved from BUILT+REGISTERED to
UNPROVEN (C56 and C102 fail under the plan's standard wrapper and skip, rules 2 and 7; C51 names no test, G2.3); C56, C83 and C86
left Complete = yes (G2.4, G2.1). The C07 and C74 rows changed field b only (G2.6, G2.5); their status stays UNPROVEN.

## Audit gaps closed (Rev 31 closed the 29 `RULE-AUDIT.md` gaps; Rev 32 closed the 8 PARTLY gaps the independent re-check `recheck-macos.md` found — G1/3006, G2.2/C38+2121, G2.3/2339, L3/621, G4.1/360+4178, G5.7/2123-2131, G6.4/405+4065, G6.5/1939+2905+4255+4245)

Section names are used instead of line numbers because the file moved. "Fix" says where the corrected text now sits.

| Gap | What was wrong (rev 30) | The fix (Rev 31) |
|---|---|---|
| G2.1 | C83, C86 were Complete = yes with c = y but no mutant was named for the MS7.1 and MS7.4 seams | The ledger entries MS7.1 and MS7.4 now name a production mutant each (full-height page rect; unclamped `original_offset`). They are NOT yet run, so C83 and C86 are Complete = no, c = n (and a = n, G4.1) |
| G2.2 | C37, C38 relied on a `load_serial` mutant that lived only in the HISTORICAL MS4 rev-6 section | The mutants (counter never increments; resets on commit) and the full (a)-(d) proof were moved into the live R29-MS4 text (MS4.1a bullet); the rev-6 heading now says it carries no normative force; C37 and C38 rows point at the live text |
| G2.3 | C51 (home lock) was b = y "Linux lock tests" with no named file or step | No test calls `zb_agent_home_lock`; `agent_login_locks_test.py` is about Secrets controls, not this flock. C51 is now b = n, UNPROVEN, and the row says a two-process flock test is required |
| G2.4 | C56 was Complete = yes and BUILT+REGISTERED but its step fails as root and skips 6 Darwin tests (rule 7) | C56 is b = n, Complete = no, UNPROVEN; the row records the root failure and "OK (skipped=6)" |
| G2.5 | C74 and R29.2 row for the hook branch called both stand-in units registered; `ms8_hook_launch_env_case_unit` is only on `test-mac-census` (`build.zig:3146`) | R29.2 row and C74 now say only `ms8_hook_sandbox_case_unit` is in `test`; the other is a draft by rule 2 and registering it is a required fix-forward; C74 b = n |
| G2.6 | C07 was b = y though `ms1_entitlement_probe.sh` is TO BE AUTHORED | C07 b = n with the reason (header: y means "exists today") |
| L1 | The only red for the unpinned-sigstore half of V46-F10 was a lint test | MS5.1c (T-W7) and R30-MS5 V46-F10 now use an exercise-form red: stub-`pip` selftest `test-mac-stage-gate-selftest` runs the real `ms5_stage_gate.sh` and asserts `--require-hashes -r sigstore_verifier.txt`, with a restore-bare-install mutant; the lint is labelled a TRIPWIRE |
| L2 | MS6.8 red (d), an import scan for `sandbox._LINUX_BACKEND`, closed I-W9 unlabelled | Labelled a TRIPWIRE; the real red poisons `sandbox._LINUX_BACKEND` and calls `launch.build_launch` for both backends, mutant restores the private use |
| L3 | D2 and `4pa.66`/T8(b) promoted "no bare allow in the rendered profile" (profile text) to proof, though T9 calls it a TRIPWIRE | Both places (R29-MS6 D2, R30-MS6 `4pa.66`) now label it a TRIPWIRE and name the closing proof: the Mac kernel-denial rows of `ms6_generated_profile_test.sh` beside the constant read |
| L4 | MS9 closure asserted via `codesign --verify --strict`, `spctl --assess`, `stapler validate` (artifact verifiers) | MS9.2 and the Closure bullet label them TRIPWIRES; the proof is launching the notarized, stapled app on each Mac (new `ms9-gate` launch row, mutant, UNPROVEN until released and Developer ID) |
| L5 | MS1 red still asserted "the entitlements file lists the exact keys" (the retired tautology) | Clause removed and labelled retired (R30.1 #8, T17); proof is the `ms1_entitlement_probe.sh` feature probe |
| L6 | R29-MS7 T3 listed "production argv and preprocessor output" first among the authority items | Marked TRIPWIRES (with "no GTK-only card call"); only the live items, above all the live Approve minting a `grants` row, are authority |
| G4.1 | C96 (a = n), C83, C86 (no caller) were BUILT+REGISTERED, against R30.0 | C83, C86, C96 are NOT BUILT (driven seams, no production caller); totals recomputed |
| G4.2 | = G2.4 (C56 observed rc 1 and 6 skips) | See G2.4 |
| G4.3 | C102 was BUILT+REGISTERED but fails under the plan's own wrapper (R30.1 #24) | C102 is UNPROVEN, b = n |
| G4.4 | = G2.5 | See G2.5 |
| G5.1 | MS6.5 body said `ms6_5_reaper_gate.sh` "is DISABLED BY DEFAULT" and "now enforced in code" (false; V46-F8, R30.1 #18) | Rewritten: the guard, red and mutant are a REQUIRED fix-forward (R29-SAFETY, bd `4pa.70`), NOT in code; at HEAD only `ZB_MAC_ARM_HOST` guards the SIGKILL script, which must not be run; UNPROVEN until the guard lands and is released (exact wording in MS6.5, "Rev 31 SAFETY") |
| G5.2 | The AUTHORITATIVE SCOPED ACCEPTANCE block listed `acquireRunLockBounded` as "BUILT, reviewed and registered" (it holds no lock) | The block itself now strikes it: it acquires then releases, it is a probe, and the whole block's "BUILT" is reduced to "reviewed and registered as seam tests only, NOT BUILT (rule 6)" |
| G5.3 | The Shared contract amendment (I1) pointed the gap the wrong way (`network(self)` on the Mac backend) | Corrected: both backends use `network(self, session=None)`; only the Protocol (`sandbox.py:213`) is wrong; same fix in R29-MS6 I1 |
| G5.4 | MS7.8 Workflow Closure (and K6) still put the fixture-card entry "behind an `--e2e-protocol` test seam" | Both now say it is built ONLY under a test-only build option (`-Dtest-seams`), absent from the shipping binary (`4pa.78`, R30-MS7) |
| G5.5 | Two renames for the Secrets window symbol: `zb_secrets_window_open_for` (I-W8) and `zb_secrets_window_mac_show` (T16, R30-MS7) | Standardised on `zb_secrets_window_mac_show` in R29.6 I-W8 and R30-MS7 (T16 already used it) |
| G5.6 | R30 sources paragraph said "1 critical, 25 major" | Corrected to 3 critical (`4pa.55`, `4pa.72`, `4pa.73`) + 23 major |
| G5.7 | Two live-only requirements lived only in the HISTORICAL MS4 rev-6 section: the `load_serial` mutant and socket separation (`agent.*`/`broker.*` -32601, grant id as auth -32000) | Both moved into R29-MS4 with an (a)-(d) proof each (Linux step names, macOS test TO BE AUTHORED, mutants); the rev-6 heading is history only |
| G5.8 | Rev 8 history note said "Row 2's MS1 rule still stands" though Rev 9 and MS1.1 superseded it | The "still stands" claim removed; the note says the rule was superseded and the section is history |
| G6.1 | MS1b heading said "LANDED `3421428`" and the behaviour "GREEN ... ad-hoc and hardened", while C10 is UNPROVEN | Heading now "fix committed `3421428`; UNPROVEN (C10)"; STATUS block says COMMITTED, NOT CLOSED; the hardened leg is UNPROVEN and the cited run could not be verified; "validated"/"GREEN" replaced by "reported ... SUSPECTED / UNPROVEN" |
| G6.2 | The SCOPED ACCEPTANCE block still said "there is no `reaper_ready` constant yet" | Struck; says `reaper_ready` exists at `agent_run_recovery.zig:334`, BUILT-UNARMED = NOT BUILT |
| G6.3 | No order for the Rev 30 fix-forwards | New subsection "Rev 31 - dependency order of the 26 Rev-30 fix-forwards" under Dependency order: 3 criticals first (`4pa.55`, `4pa.72`, `4pa.73`), then the hostless selftests (including MS2c.6 placement and the `4pa.66` "before any MS6.7" rule), then the majors by slice |
| G6.4 | Status words outside R30.0 ("BUILT as a pre-ready hard-gate case", "[BUILT as a hard-gate case]", "[BUILT]", "hard-gate case built, run pending", "(B) harness built") | All six normalised to UNPROVEN, BUILT-HANDRUN = UNPROVEN, or BUILT+REGISTERED-as-a-seam, in R29.2 and the ledger |
| G6.5 | Mac runtime claims (MS2b.2 mutant-proven, PSF pkg VERIFIED, MS6.3 netd/R1 "Proven in", MS6.5 census 18/18 and "verified signal-free", MS6.6 (A) green) stated as fact | Each now carries "SUSPECTED / UNPROVEN" (rule 8) in the slice text |
