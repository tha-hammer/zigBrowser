---
date: 2026-10-19T16:20:00-04:00
planner: Claude (Opus 5.5) subagent for the orchestrator
git_commit: 032a2c95e200db2e59d56147cb9c74afed50b727
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "Windows 10 + Windows 11 launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, windows, win10, win11, webview2, win32, msvc, automation, drawer, credential-manager, sandbox, wfp, netd, msi, authenticode, launch-critical]
status: "DRAFT — NOT IMPLEMENTATION-APPROVED (rev 2.20); the WS8/WS9 WSL2 topology is a DRAFT only; re-baselined to HEAD e4f705f (code state of c07899f) and amended with every finding of the independent review (19 critical C1-C19 + 23 warnings W1-W23); see 'Review amendments (rev 2.17)'"
rev: 2.20
rebaselined_at: e4f705f
rebaselined_code_state: c07899f
review_input: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan-REVIEW.md
rev_2_20_note: "Rev 2.20 (2026-10-22; closes the 15 gaps of the independent audit thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan-RULE-AUDIT.md of rev 2.19, verdict PASS WITH GAPS (15); owner order: the plan is COMPLETE before a new session implements it; freeze zigBrowser-4pa.1 holds). PLAN-ONLY revision: only this plan file changed; no source, test, build or host file was touched, no Windows host was contacted, and nothing was built or run. Every change tightens proof honesty; no gate or safety rule was weakened. (1) G2.1: every rule-9 'yes' row that named only a NEW test file now names the build.zig step it registers in (the 'windows-live' aggregate and its per-test steps, defined once in D.1 and in 'Registration map (rev 2.20)' at the end); rows that cannot name a step stay 'no'. (2) G2.2: WS8.1-WS8.8 field (c) now names the production defense that is REMOVED (the mutant), not the expected result. (3) G2.3: WS7.5 is split into the Linux-run half (what a blocked-module Linux import really proves) and the Windows claim (a Win11 VM run, still NOT BUILT). (4) G2.4: WS4.1-WS4.3 have distinct entry points and tests; WS4.3's mutant now reads the cookie through the GTK port. (5) L3.1-L3.5: WS0.5, WS1.5's arch match, WS1's cross-check, WS13.1's census and the dependency-order census are labelled TRIPWIRE and no longer close or gate anything; the WS0 status box no longer says CLOSED for WS0.5. (6) G4.1: WS5.5 is split: the primary window's inc/dec plus the portable counter stay PROVEN-PARTIAL; the per-window and popup-close path (WS5.5b) is NOT BUILT because the second drawer window exists only behind the e2e-only ZIGBROWSER_AGENT_DRAWER_WINDOWS seam and the production popup close path does not exist (WS2c.1 is zero code). (7) G4.2: host_live_test.py is in no build.zig step, so WS0.1b is NOT BUILT and the live half of WS0.1a is not counted; registration is WORK. (8) G4.3: the WS1 body now points at the real tests/windows/screenshot_live_test.py; win_screenshot_test.py, win_runtime_missing_test.py and win_version_test.py are WORK to create, not evidence. (9) G6.1-G6.3: every stale rev-2.17 CLOSED or green line (B table, WS0 box, WS1, WS2, WS3, WS5, 'Closed today') was reconciled to its proof block; WS5.1 and WS5.5 say PROVEN-PARTIAL, and WS5.5's run output is only in review commit 18b32b4 and must be pasted into the implementing commit. The table 'Audit gaps closed (rev 2.20)' at the end lists one row per gap. Compliance totals are recomputed (108 rows: 63 NOT BUILT, 32 UNPROVEN, 12 PROVEN-PARTIAL, 1 TRIPWIRE ONLY, 0 PROVEN)."
rev_2_19_note: "Rev 2.19 (2026-10-22; OWNER ORDER on verification, tracked as zigBrowser-4pa.44 and zigBrowser-4pa.46). PLAN-ONLY revision: only this plan file changed; no source, test, build or host file was touched, no Windows host was contacted, and nothing was built or run. OWNER ORDER (verbatim, 2026-10-22): 'Make sure the plan is actually updated to reflect the proper plan and be sure the plan text instructs the agents to check code by exercising the code, not just checking it.' (1) The owner's section 'Verification rule: prove it by running it (owner, 2026-10-22)' is inserted VERBATIM as a top-level section before WS0, the first slice; it overrides any looser wording elsewhere. (2) SWEEP: the rule was applied to every behavior, success criterion, verification command and gate: 107 behavior rows were swept. 18 rows had a read/grep/regex/lexer/symbol/census/manifest/constant proof REWRITTEN into the exercise form of rule 9 (the source check is kept only as a labelled tripwire); 61 rows are marked NOT BUILT (of which 18 were re-marked from a green, closed, registered or source-only claim; 12 of the NOT BUILT rows were also rewritten); 32 rows are marked UNPROVEN (no exercising proof is possible yet; 3 of them were also rewritten). The remaining rows are 0 PROVEN (none is fully proven: every driven test still lacks a located production-mutant run record or a platform leg), 13 PROVEN-PARTIAL (a driven test or a recorded platform run exists; the open items are listed) and 1 tripwire-only suite row. The counts overlap as stated; the table at the end of the plan is the authority. (3) 4pa.44: the WS5 drawer behaviors had been proven by SOURCE ORACLES (grep, lexer, AST and model tests over the shim and the runner). Those suites are now labelled TRIPWIRES and never close a drawer behavior. Only two drawer behaviors have an exercising proof: WS5.1 (entry run b2c4f25, 8/8 on the Win11 VM) and WS5.5 (driven Zig lifecycle test plus the four live methods run on the Win11 VM at a5745b9: peak, intermediate and final counts, NoKillNeeded, zero survivors) [CORRECTED in rev 2.20, G4.1/G6.3: both are only PROVEN-PARTIAL, and the a5745b9 live methods drive a SECOND drawer window only through the e2e-only seam ZIGBROWSER_AGENT_DRAWER_WINDOWS, so WS5.5 proves only the primary window's inc/dec plus the portable counter; the per-window and popup-close part (WS5.5b) is NOT BUILT]. WS5.2, WS5.3, WS5.4 and WS5.7 are re-marked NOT BUILT; WS5.8-WS5.10 stay NOT BUILT. (4) 4pa.46: WS5.6 closure was offline only (Linux in-process tests, a Python row over helpers defined in the test, a live row that never ran); it is re-marked NOT BUILT and the exercising proof is named (the real exe on the Win11 VM, page JavaScript and the authenticated socket, census unchanged, two production mutants). (5) A 'Verification rule compliance' table is added at the end of the plan. (6) No existing driven test or gate was weakened; every change tightens a proof standard. Statuses are documentary: recorded runs are as the plan and the orchestrator state them and were not re-run here (rule 8: reading alone gives SUSPECTED). This revision closes no blocker, approves no security claim and leaves C4 as ratified."
rev_2_18_note: "Rev 2.18 (2026-10-22; OWNER RULING on decision C1, tracked as zigBrowser-4pa.31 and zigBrowser-4pa.41). PLAN-ONLY revision: only this plan file changed; no source, test, build or host file was touched, no Windows host was contacted, and nothing was built or run. OWNER RULING (verbatim): 'the windows 10 machine should not be read-only it is a standard Win10 box, not some production file server.' The Windows 10 machine is zbtest@100.123.34.15, a standard, WRITABLE Win10 test box. The rev 2.10 premise (a read-only file server on which no browser may run) was WRONG and is corrected everywhere it appeared. (1) DECISION C1 default REPLACED: the physical Win10 box (zbtest@100.123.34.15) is a WRITABLE test host; a [W] both-hosts gate means the Win11 VM PLUS the Win10 box. Win10 release rule: RoseCat exact-commit approval PLUS an orchestrator release (the same rule as the Win11 VM); all work confined to C:/Users/zbtest/zb; ask the owner before ANY system-wide install. (2) Every read-only-file-server / Win10-leg-withdrawn / Win10-dropped / Win10-untested statement from rev 2.10 onward was removed or rewritten (rev-2.10 and rev-2.11 notes, rev-2.17 note item 4, Why-this-plan, markers table, State-at-HEAD table, section C, Desired End State, behaviors 1-2 and 7, host provisioning and the confinement requirements, WS0.1/0.2/0.7/0.8, the Testing Strategy real-screen and closure rules, the what-runs-where note, WS1.2, WS2.0 and the AF_UNIX stop rule, WS2a.0, WS2b.1, the WS2/WS3/WS6 gates, WS13, the real-screen table, unverified item 3). (3) The Win10 legs that rev 2.10 and rev 2.17 had removed are RESTORED, each with its OWN test and its OWN evidence line, none of them run yet: WS0 product-run Win10 leg (WS0.9), WS1.2-W10, WS2.0-W10, WS2a.0-W10, WS2b.1-W10, WS13.4-W10 and the win-render / install-smartscreen Win10 real-screen legs. (4) Honest caveats recorded, not hidden: the as-built --probe-only code still treats the Win10 box as zero-write (root/free_gb/interactive_session not_applicable) because it was written on the wrong premise; the 2026-10-20 reading of C: on that box was about 0 GB free, a capacity precondition to clear with the owner before any Win10 product leg; the WebView2 runtime, if missing there, is a system-wide install and needs the owner. (5) C4 (build-order question) is UNCHANGED and STILL PENDING OWNER RATIFICATION. This revision closes no blocker and approves no security claim."
rev_2_17_note: "Rev 2.17 (2026-10-22; enhance_plan_with_review of the independent review by BlackRobin, bead zigBrowser-4pa.4; amendments tracked as zigBrowser-4pa.31..49). PLAN-ONLY revision: no source, test, build or host file was changed and no command was run against any host. (1) RE-BASELINE: the plan's assumptions are brought to HEAD e4f705f (git diff c07899f..e4f705f is three REVIEW .md files only, so the CODE state is c07899f); the stale 'Current State Analysis' is superseded by a dated 'State at HEAD' table (W2). (2) OD-W4 CONTRACT stated exactly once, normatively, in 'OD-W4 contract (rev 2.17, normative)': WSL2 now / own VM later; the Claude agent, its CLI, bubblewrap and netd run INSIDE our own imported WSL2 distro on Windows 11 ONLY; the agent is OFF on Windows 10; no dedicated users, no AppContainer, no WFP, no Job-Object user isolation, no Windows python.exe or claude.exe for the agent. (3) EVERY review finding is mapped in 'Review amendments (rev 2.17) — traceability' (C1-C19, W1-W23) to a plan location or to an explicit rejection. (4) [AMENDED in rev 2.18] C1 (Win10 test host) had been adopted here as 'every gate Win11-only; Windows 10 browser untested' on the mistaken read-only-file-server premise; the OWNER has since ruled that the Win10 box is a standard WRITABLE test host, so that default is REPLACED (see rev_2_18_note and section C). The C4 order question remains an OWNER decision, still pending ratification. (5) The WS8/WS9 DRAFT gate is unchanged in force except that it now names the ONE sanctioned blocker-1 live rerun (C17) and the WS8/WS9 proposals now carry concrete numbers/wire formats (still PROPOSALS, not contracts). This revision closes no blocker and approves no security claim."
rev_2_16_note: "Rev 2.16 (2026-10-21, AzureRidge; RoseCat 9134b8b/7558 + draft-state route 7561). DOCUMENTATION-HONESTY ONLY — this revision does NOT close affd577/9134b8b, does NOT authorize any WS8/WS9 implementation, and approves NO security claim. It marks the WS8/WS9 WSL2 topology a DRAFT: (1) status/rev/WS8/WS9 headings say DRAFT — NOT IMPLEMENTATION-APPROVED; withdrew every 'causal/implementation-ready/grounded/proven' closure claim that exceeds the discovery observations. (2) one authoritative gate before WS8 forbids any WS8/WS9 red/green/production-edit/installer-change/further live-or-destructive WSL run (and WS10/WS11/agent-WS12/WS13 agent work) until a later reviewed revision closes every blocker. (3) the six 9134b8b findings are listed OPEN with exact required closure + the eight-finding status table. (4) measured facts narrowed to what the committed run actually observed (explicit -u zbagent uid/caps/userns/bwrap; exact IPv4/IPv6 canary+ACK; co-tenant reach) with an explicit NOT-proven list (default-user selection, causal reverse firewall denial, fail-closed cleanup/final census, the C1 pipe/fd bootstrap, production bwrap/netd, any product security boundary). (5) wsl_live_test.py marked DISCOVERY-ONLY / DO NOT RERUN until its ignored rc/ready-proof/staged-cleanup/final-census are repaired + reviewed; its header/result are not gate evidence. (6) an authoritative scope banner marks every dedicated-user/WFP/WindowsSandboxUserBackend/host-netd/both-host-agent/Win10-agent statement HISTORICAL and non-normative — present scope = browser on Win10+Win11, agent/WSL on Win11 only, agent OFF on Win10. (7) C1-C5 kept as PROPOSALS/TBD, not contracts, naming the later evidence required; OAuth fd-3 stays a hard-red unverified. Live evidence is required before any later implementation-approved revision."
rev_2_15_note: "Rev 2.15 (2026-10-21, AzureRidge; RoseCat affd577 — 8 blockers on 770848b/7ca6897). [HISTORICAL — its 'causal'/'implementation-ready' claims were WITHDRAWN in rev 2.16; the topology is a DRAFT.] It aimed to correct the live spike and the WSL2 contracts: (1) the spike now creates a dedicated NON-ROOT Linux uid (zbagent 1000), launches with it, and proves id!=0, no sudo/doas, CapEff=0, 0 setuid, /etc denied, and userns+bwrap AS that user (C6). (2) transport re-probed EXACTLY on 127.0.0.1:0 (and ::1:0) with an ACK + moved canary, IPv4+IPv6, a hostile co-tenant row (a second distro reaches the 127.0.0.1 listener ⇒ auth mandatory), and WSL→Windows + TEST-NET fail-closed with every rc checked; the spike pins distros alive with keepalives, rc-checks the whole lifecycle, asserts final census==baseline, refuses a missing rootfs on an opted-in host, and cleans its local scratch. (3) C1 bootstrap de-circularised: the control capability is delivered on a one-shot inherited pipe at launch (never env/argv/file/TCP), kept DISTINCT from the OAuth fd-3 token; WS8.3 reconciled; same-Windows-user boundary stated plainly (the WSL VM is NOT a boundary against the owning Windows user). (4) C5 reverse relay specified for hook-initiated 51091/31337 (Windows dials in, in-distro broker multiplexes, framing/backpressure/cancellation/lifetime). (5) C2 file broker made concrete (Windows broker + in-distro client, server-held handle capabilities, a real held-handle check-and-use primitive replacing the removed WS0.5 Option B, bounds, immutable snapshot, atomic copy-back, session ownership, crash cleanup). (6) C3 setup/update state machine (versioned distro names + current-pointer commit/rollback, active-session-aware retire, unprivileged reboot-resume with SID binding) + honest uninstall (cannot un-enable global WSL/VMP) + C4 marker-based teardown with detached/double-fork and browser-crash recovery. (7) the old Windows-user/WFP WS9 block, the dependency-graph WFP coupling, and the unverified dedicated-user/CreateProcessWithLogonW/nested-virt-fallback items are REMOVED/reconciled to WSL. (8) Win10 ships BROWSER-ONLY agent-OFF; WS8/WS9/WS11/WS12-agent/WS13-agent-census gate win11-only, reconciled in the OD-W4 scope + the WS10/WS11/WS13 gates. The spike stays UNREGISTERED; WS8/WS9 reds remain gated on RoseCat approval."
rev_2_14_note: "[HISTORICAL — C8: the claim 'WSL→Windows is firewall-blocked' below is WITHDRAWN as a measured fact (rev 2.16 / plan 'Loopback TCP directionality'): one reverse attempt failed WITHOUT proving the Windows listener was live, so it is an unproven observation, and the C1/C5 direction is a PROPOSAL.] Rev 2.14 (2026-10-21, AzureRidge; RoseCat 119108c WSL2 re-plan + owner 'WSL done'). The WS8/WS9 WSL2 topology is now grounded in LIVE MEASUREMENTS on win11-m8 (WSL 3.0.3.0, kernel 6.18.54.1, build 26200) by the new `tests/windows/wsl_live_test.py` (standard-user `zbtext`, no admin; Alpine minirootfs 3.21.9 pinned by in-repo SHA-256; imports two distros, probes, tears down with a guarded delete; exit 77 off-host; UNREGISTERED until the WS8/WS9 greens). Measured + folded in: `wsl --import` and the full per-user lifecycle need NO admin; automount-off works (Windows drive unmounted, `/mnt/c` not a mountpoint); appendWindowsPath-false works; interop-off is PARTIAL (the WSLInterop binfmt handler stays registered — WS8.1 must hard-disable it at boot); two distros share ONE utility VM + ONE net namespace (separate mount/PID ns); loopback TCP is one-directional by default — **Windows→WSL works (localhostForwarding), WSL→Windows is firewall-blocked**, so C1/C5 are INVERTED to agent-listens-in-distro / browser-connects-from-Windows; AF_VSOCK creatable by a standard user but host side needs AF_HYPERV (rejected); unprivileged userns + bubblewrap work inside the distro; per-run process-group kill is safe while `wsl --terminate` is distro-wide. The four WS8 contracts (C1-C4) + the new WS9 C5 bridge-topology contract answer 119108c and are re-anchored to this evidence. Still owner-only/elevated: the one-time feature-enable + reboot (the owner did it; benign 'nested virtualization not supported' notice prints, not needed). Added the **WS8/WS9 acceptance matrix (RoseCat 7516's 12 inputs)** as the production-backend closure spec and labelled `wsl_live_test.py` a DISCOVERY SPIKE (security/product claims proven later through `WslBackend`/`LinuxBwrapBackend`); measured that wsl.conf applies via a **per-distro `wsl --terminate`** so no global `wsl --shutdown` is used (pinned forbidden, #10); the spike now takes a baseline/postflight census + refuses name collisions; recorded honestly that the WSL VM is **not** an isolation boundary against the owning Windows user (#3). WS8/WS9 reds remain gated on RoseCat approving this re-plan."
rev_2_13_note: "Rev 2.13 (2026-10-21, AzureRidge; RoseCat b3d255b-chain). Owner DECISIONS recorded + reconciled throughout: OD-W1 = per-user WiX 3.14 MSI; OD-W3 = NO code signing for launch (DEFERRED, not a launch gate, WS13.6 stays OPEN, nothing may claim signed/distributable); OD-W6 = native Win32 drawer (not WebView2/WinUI); OD-W4 = WSL2 now / own VM later (our own `wsl --import` distro, automount+interop off, appendWindowsPath=false, agent inside it under the existing bubblewrap+netd Linux sandbox, browser<->agent over loopback TCP/hvsocket since AF_UNIX does not cross WSL2, agent OFF + fixed explanation if virt/WSL absent; dedicated-users/AppContainer/WFP DROPPED for launch and marked SUPERSEDED in WS8/WS9; own-small-VM containment is a later MS6.5-stub milestone). WS13 signing reworded deferred/non-gating; the Open-decisions intro + sharpening mark W1/W3/W4/W6 decided (history, not pending); WS5 no longer offers a WebView2 drawer. UNVERIFIED (owner, elevated): reboot need for VMP/WSL; the later shared utility VM; loopback-vs-hvsocket transport + auth; win11-m8 feature-state/nested-virt (read-only non-admin probe: WSL NOT installed, feature/nested-virt queries elevation-refused). No WSL install on the VM until the owner relays OK; WS8/WS9 WSL2 reds only after RoseCat approves the re-plan."
rev_2_12_note: "Rev 2.12 (2026-10-21, AzureRidge; RoseCat 88852d9). Lock detection no longer uses OpenInputDesktop for the verdict: on the win11-m8 LOCKED VM console OpenInputDesktop returned input desktop 'Default' and the probe mis-reported unlocked. session_probe.ps1 now derives `locked` from the WTS session-lock flag — WTSQuerySessionInformation(WTSSessionInfoEx) -> WTSINFOEX_LEVEL1.SessionFlags (WTS_SESSIONSTATE_LOCK(0)=locked, WTS_SESSIONSTATE_UNLOCK(1)=unlocked), byte offset +12 after the DWORD Level tag — with a LogonUI-in-console fallback, and it FAILS CLOSED: the ONLY unlocked verdict is the WTS flag explicitly reporting UNLOCK(1); any unknown/unreadable signal counts as locked so gate.sh refuses it as an active unlocked session. input_desktop is a DIAGNOSTIC field only. The verdict is a pure extractable Get-ZbLockVerdict (ZB_LOCK_FN markers); the watched LockedDesktopLive requires wts_lock_ok=true and session_flags==0 (LogonUI fallback tested separately in LockVerdictFixturesLive)."
rev_2_11_note: "Rev 2.11 (2026-10-20, WS0 live-readiness closure, AzureRidge; RoseCat 5e48424/6867/6882/6889). WS0 closure is the two-host readiness `--probe-only` gate ONLY; the no-argument full product gate still exits 'not implemented' and is NOT claimed complete. Win10 box (zbtest@100.123.34.15): the --probe-only probe itself is zero-write with host-key-only identity, so root and free_gb are not_applicable in THAT readiness mode only [rev 2.18: the Win10 box is a writable test host, so the product-run mode enforces root/free_gb/interactive_session there]; no fixed listener baseline (WS0.7 = listeners/firewall-hash/shares unchanged pre vs post); sshd ListenAddress and AllowUsers pinned exactly. VM free-space floor 10 GB; current pinned clean snapshot `pre-4dr-toolchain-2026-10-20`. zbtest_write_paths uses the real Win32 AccessCheck (zero-disk Reflection.Emit) not a hand SID walk; the Win10 probe is streamed on stdin and compiles nothing (no Add-Type/CodeDOM) and writes nothing. The in-console session helper (session_probe.ps1) is an EXTERNALLY provisioned scheduled task (provision_session_task.ps1); gate.sh pin-verifies it with verify_task.ps1 (exact canonical System32 powershell.exe, no WorkingDirectory node, exact argument tuple, one Exec, one Principal with nonempty id == Actions Context, UserId == the exact current-user SID, InteractiveToken, RunLevel absent-or-LeastPrivilege, Enabled absent-or-true, staged-script SHA-256) and only then writes a per-run nonce, triggers it, and awaits a nonce-matching fresh (non-future) session.json. Lock state comes from the WTS session-lock flag (WTSSessionInfoEx -> WTSINFOEX_LEVEL1.SessionFlags; LOCK(0)/UNLOCK(1)) with a LogonUI-in-console fallback and FAILS CLOSED (unknown => locked); the input-desktop name (OpenInputDesktop) is a diagnostic only (see rev_2_12_note). The owner-gated locked-console test (host_live_test.py LockedDesktopLive, ZB_EXPECT_LOCKED) runs with the VM console deliberately locked and is unlocked before the normal two-host run. gate_twohost_selftest.py is registered/green (windows-twohost-selftest) and load_tests also registers host_live_test.py (live cases skip without the VM env/lock opt-in)."
rev_2_10_note: "Rev 2.10 (2026-10-20, WS2.0 scope, BlueBeaver; RoseCat 6860, 41a296a, 6870 — WS2.0 is labelled [W11], and the register names its exception): WS2.0's live production evidence COLLECTED SO FAR is the Win11 VM only (a fact about which runs exist, not a limit on the plan). [CORRECTED in rev 2.18 per the owner ruling: this note originally asserted that the physical Windows 10 machine is a read-only file server on which the browser may not be run, set aside the physical-Win10 leg (the owner-side DACL check and the different-integrity connect) and left Windows 10 AF_UNIX unverified. That premise was WRONG: zbtest@100.123.34.15 is a standard, WRITABLE Win10 test box. The Win10 leg is RESTORED as WS2.0-W10 (own test, own evidence line; see the WS2.0 section) and is NOT yet run; Windows 10 AF_UNIX stays UNVERIFIED only until that leg runs under the Win10 release rule (RoseCat exact-commit approval + orchestrator release, work confined to C:/Users/zbtest/zb).]"
rev_2_9_note: "Rev 2.9 (2026-10-20; WS0-completion / Route A, RoseCat 6769) [W5: frontmatter now carries this note; full text in the WS2.0 section body]: snapshot readiness moved from an in-VM probe field to a host-side read-only virsh check; console_user read network-safe; interactive_session/locked VM-only."
rev_2_8_note: "Rev 2.8 (2026-10-20; WS13.4 uninstall census, RoseCat 6731 / 2cc125c) [W5: frontmatter now carries this note; full text in the WS2.0 section body] [HISTORICAL — the six-kind sandbox-user/WFP census it describes is the DROPPED dedicated-user design; see WS13.4 (rev 2.17, WSL-era uninstall)]."
rev_2_7_note: "Rev 2.7 (2026-10-20, WS2.0, BlueBeaver; RoseCat 6647, 6668): the Windows automation server never started — std.Io.net enables AF_UNIX on Windows only when the target minimum is win10_rs4 (Windows 10 1803) or later, and the default x86_64-windows-msvc range starts lower, so server.start returned AddressFamilyUnsupported (exit 7) and its whole start path was dead code. build.zig windowsAfUnixFloor now gives every Windows target without an explicit minimum the win10_rs4 floor (the cross-check object uses it too); the newly reachable start path got Windows fixes (wallClockMs via RtlGetSystemTimePrecise, the token file without .fromMode, cookies.import refused on Windows until WS3). The ADR-1 spike no longer compiles on Zig 0.16 and is superseded: the production e2e tests/e2e/win_transport_test.py (red 970969f, green f29e490) is the AF_UNIX proof. Rev 2.6's claim that .fromMode compiles for Windows is withdrawn: it compiled only because the path was unreachable."
rev_2_6_note: "(fix, RoseCat 6607: the check and the apply name one object, a handle opened without following a link or reparse point; O_PATH + /proc/self/fd on Linux, O_NOFOLLOW + fchmod on macOS, FILE_FLAG_OPEN_REPARSE_POINT + SetSecurityInfo on Windows, the AF_UNIX reparse tag accepted; swap reds; the readback contract is P + only AI/AR + the one ACE) Rev 2.6 (2026-10-20): WS2.0 owned by BlueBeaver (orchestrator; AzureRidge 6591 keeps the VM, host tooling, wincontain and the Job Object). One owner-only seam src/owner_only.zig: restrictToOwner(path, file|dir) — POSIX 0600/0700 with symlinks refused; Windows a PROTECTED DACL with exactly one allow ACE for the current user SID (no SYSTEM/Administrators/Everyone/Users/Authenticated Users, nothing inherited; OICI on a directory), built as SDDL by the pure ownerOnlySddl and applied with SetNamedSecurityInfoW; C form zb_restrict_to_owner for WS3.1. socketBaseDir: Windows %LOCALAPPDATA% only (NoLocalAppData, never /tmp or XDG); planSocketPath returns SocketPathTooLong instead of a cut path. The compile check is not the red (MinGW chmod compiles and sets no DACL); the reds are Linux-provable (owner_only_test, automation_transport_ws20_test) plus the VM e2e win_transport_test.py (zbother negative control after the user creates zbother)."
rev_2_5_note: "Rev 2.5 (2026-10-20): WS3 flag table made literal from production (RoseCat 6405, 6415). Exact present-flag rows from media_config.parse (on|off), render_config.parseHwPolicy (never|always|webkit — no auto), render_config.parseRenderer (default|shm|mesa-egl, Linux only; refused on macOS/Windows); empty value is an explicit invalid value and is refused. backendFlagDecision decides a PRESENT flag only; absence makes no call and no apply and is resolved by the config defaults (media-source=on, hardware-acceleration=webkit, Linux renderer=shm; no renderer decision on macOS/Windows) via a separate absent-default oracle at the config/app boundary, never value=''. WS3.2's flag-decision property is now the registered, all-OS, anti-drift tests/backend_flag_test.zig (step test-backend-flag, BlueBeaver); the standalone src/ws3_backend_flag_table_test.zig (88e16cd) is removed so one literal oracle cannot drift."
rev_2_4_note: "Rev 2.4 (2026-10-20): fix-forward of the WS3 coordination section per RoseCat's block of 311e682. (1) The full flag×value decision matrix (Linux/macOS/Windows columns, defaults + exact unsupported outcomes) is documented in the plan and the [L] test is literal from it. (2) The seam is split: a pure all-OS backendFlagDecision(os,flag,value) (runtime-testable, no C ABI) and a target-only applyBackendFlag(comptime os,…) compiled for the current target — the Linux property never calls a non-host target ABI. (3) CookiePort names corrected to getAll/set/delete (src/automation/cookie_port.zig). (4) One owner per file/hunk with an ordered handoff: BlackRobin's shim setters land before the Zig apply arms that call them; WS3/MS3 each edit only their own webkit.zig branch + their own new cookie-port file; no file has two simultaneous editors. SHOULD: the --profile-dir persistence closure uses a local localStorage/cookie fixture, not a live-site login."
rev_2_3_note: "Rev 2.3 (2026-10-20): added the WS3 cross-plan coordination proposal (section 'WS3 cross-plan coordination') — the shared config-flag seam applyBackendFlag(os,flag,value), the CookiePort interface with three backend impls, and the --profile-dir contract: which plan owns what, the pinned shared contracts, and the binding order (BlueBeaver lands the backend-flag seam pre-slice first; WS3 and MS3 add their os-arms in parallel; JadeBeacon adopts the shared name; BlackRobin owns the native setters). Mailed to BlackRobin, BlueBeaver, JadeBeacon and RoseCat. WS3's first Linux-only reds (the flag-decision-table property + the windows cookie-port cross-check) are written unregistered."
rev_2_2_note: "Rev 2.2 (bead zigBrowser-126): WS0.6 VM identity no longer uses the SMBIOS UUID (a standard user cannot read Win32_ComputerSystemProduct.UUID — WMI Access-denied 0x80041003, wmic absent; verified on win11-m8). Identity = pinned SSH host key + a provisioning marker nonce (ZB_WIN11_MARKER / C:\\Users\\<user>\\zb\\.gate-identity, probe field identity_marker); virsh stays read-only (domstate, snapshot-list). Updated the reach-VM identity section, the WS0.1 probe fields, the fail-closed list and WS0.6."
rev_2_1_note: "Rev 2.1 (RoseCat 6146): WS8.7 folded into WS8's own gate (WS8.1-WS8.7); WS12 reconciled with the committed TTS Windows cloning leg (CW) and the committed STT live-mic = physical Windows 10 only (VM = WAV seam); WS13.4 uninstall must not report success while any sandbox user / WFP filter / task survives; WS13's final gate depends on every release component + the voice packaging, not merely starting after WS7."
last_updated: 2026-10-22
last_updated_by: "audit-gap closure (rev 2.20, 15 gaps of the independent rule audit, 2026-10-22); earlier: verification-rule sweep (rev 2.19, owner order 2026-10-22); earlier: enhance_plan_with_review (rev 2.17 — re-baseline to HEAD e4f705f, OD-W4 contract restated, all 19 criticals + 23 warnings of the independent review amended or explicitly rejected) [W5: previously said 'rev 2.13']"
last_updated_note: "Rev 2.20 (2026-10-22): see rev_2_20_note and the table 'Audit gaps closed (rev 2.20)' at the end of the plan (15 audit gaps closed; statuses reconciled to the proof blocks). Rev 2.19 (2026-10-22): see rev_2_19_note and the top-level section 'Verification rule: prove it by running it' (inserted verbatim before WS0); every behavior now states its proof and the compliance table is at the end. Rev 2.18 (2026-10-22): see rev_2_18_note and section C (C1 REPLACED by the owner ruling: the Win10 box is writable and both-hosts gates include it; C4 still pending ratification). Rev 2.17 (2026-10-22): see rev_2_17_note and 'Review amendments (rev 2.17)'. Rev 2.16 (2026-10-21, AzureRidge; RoseCat 9134b8b/7558 + draft-state route 7561): DOCUMENTATION HONESTY ONLY — marked the WS8/WS9 WSL2 topology a DRAFT (NOT implementation-approved), added the authoritative no-WS8/WS9-work gate, listed the six 9134b8b blockers OPEN, narrowed the measured facts to the explicit-user discovery observations with an explicit NOT-proven list, marked wsl_live_test.py DISCOVERY-ONLY/DO-NOT-RERUN, added an authoritative scope banner making every dedicated-user/WFP/both-host-agent statement historical/non-normative, and relabelled C1-C5 as proposals/TBD. Does not close affd577 or approve any implementation/security claim. Rev 2.15 (2026-10-21, AzureRidge; RoseCat affd577): corrected the discovery spike + WSL2 contract DRAFTS from the live run — observed (explicit `-u zbagent` only) uid 1000 + userns/bwrap, exact 127.0.0.1:0/::1:0 ACK+canary, IPv6, a hostile co-tenant row; drafted C1 bootstrap, C5 relay, C2 broker, C3/C4 state machines; began removing the old Windows-user/WFP text and the Win10 agent-OFF scope (completed as non-normative marking in rev 2.16). Rev 2.14 (2026-10-21): folded the LIVE WSL2 measurements on win11-m8 (new `tests/windows/wsl_live_test.py`) into the WS8/WS9 re-plan for RoseCat 119108c — C1/C5 transport INVERTED to agent-listens-in-distro / browser-connects-from-Windows (WSL→Windows is firewall-blocked, Windows→WSL works via localhostForwarding); automount-off and appendWindowsPath-false confirmed working, interop-off partial (binfmt handler hard-disabled at boot); two distros share one utility VM + net namespace; per-run process-group kill proven vs distro-wide `wsl --terminate`; import + full lifecycle need no admin. Rev 2.13 (2026-10-21): recorded the owner's decisions — OD-W1 = per-user WiX 3.14 MSI; OD-W3 = code signing DEFERRED (no signing for launch, WS13.6 open/non-gating, nothing may claim signed/distributable); OD-W4 = WSL2 now (our own `wsl --import` distro under the existing bubblewrap+netd sandbox) with our own VM later; OD-W6 = native Win32 drawer. OD-W2/W5/W7/W8/W9 remain open. (Rev 2 review-pass history: verified file:line anchors at HEAD 032a2c9, added the WS0-WS13 red/green/refactor/closure/real-screen cases, the Win11 VM + file-server design and WS0.6-WS0.8, and reconciled the voice/macOS plans.)"
primary_research: thoughts/searchable/shared/research/2026-10-19-windows-launch-support-surface.md
counterpart: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md
---

# Windows Launch Support for zigBrowser — TDD Implementation Plan

> ⚠️ **AUTHORITATIVE SCOPE (OD-W4; rev 2.16 DRAFT).** The present **normative** scope is:
> **the browser ships on Windows 10 AND Windows 11; the agent + its WSL2 sandbox run on Windows 11
> ONLY; the agent is OFF on Windows 10 (browser-only).** Anywhere in this plan that still requires
> **dedicated local Windows users, WFP filters, a `WindowsSandboxUserBackend`, host-side netd,
> `CreateProcessWithLogonW`/Secondary Logon, the agent/sandbox/WFP on the Windows 10 test
> box, or "the agent on both hosts"** is **HISTORICAL and NON-NORMATIVE** — superseded by this scope
> and by OD-W4 (WSL2), and retained only as history pending the implementation-approved revision that
> will excise it. Where such text conflicts with this banner, **this banner wins.**
>
> ⚠️ **DRAFT — WS8/WS9 WSL2 TOPOLOGY IS NOT IMPLEMENTATION-APPROVED.** See the **"WS8/WS9 DRAFT gate"**
> block immediately before WS8: no WS8/WS9 red, green, production edit, installer change, or further
> live/destructive WSL run may begin — and WS10/WS11/agent-dependent WS12/WS13 work stays blocked —
> until a later reviewed revision closes every blocker listed there. The C1-C5 mechanics are
> **proposals/TBD, not contracts**. `tests/windows/wsl_live_test.py` is a **DISCOVERY-ONLY** spike and
> **must not be rerun** or cited as gate evidence until repaired and reviewed. Accepting this revision is
> **documentation honesty only**; it closes nothing and approves no security claim.

> ⚠️ **REV 2.17 (2026-10-22) RE-BASELINE + REVIEW AMENDMENTS.** This revision brings the plan to HEAD `e4f705f`
> (code state `c07899f`), restates the OD-W4 contract exactly (section A below), and maps all 19 critical and 23
> warning findings of the independent review to amendments (section E). Where an older paragraph elsewhere in this
> plan disagrees with section A, B, C or D below, **sections A-D win**. Status is still DRAFT / NOT
> implementation-approved.

> ⚠️ **REV 2.19 (2026-10-22) VERIFICATION RULE — OWNER ORDER.** "Make sure the plan is actually updated to reflect the proper
> plan and be sure the plan text instructs the agents to check code by exercising the code, not just checking it." The
> top-level section **"Verification rule: prove it by running it (owner, 2026-10-22)"** (placed before WS0, the first slice)
> is binding and **overrides any looser wording in this plan**. A behavior is proven only by running the real code path;
> grep, regex, lexer, symbol-exists, "file contains", nm, strings and otool checks are **tripwires, never proof**. Every
> behavior states (a) its production entry point, (b) its test file and build.zig step, (c) its mutant and (d) its platform run.
> Markers: **PROVEN**, **PROVEN-PARTIAL**, **NOT BUILT**, **UNPROVEN**, **TRIPWIRE** (legend in section F; table at the end of the plan).

> ⚠️ **REV 2.20 (2026-10-22) AUDIT GAPS CLOSED.** The 15 gaps of the independent audit of rev 2.19 are closed (table "Audit gaps closed
> (rev 2.20)" at the end). Where any older status line in this plan says CLOSED, "green" or "PROVEN" for an item whose proof block
> says NOT BUILT, UNPROVEN or PROVEN-PARTIAL, **the proof block wins**. A step named as "WORK" is not evidence.

## Review amendments (rev 2.17)

### A. OD-W4 contract (rev 2.17, normative) — WSL2, agent on Windows 11 ONLY   [C8, C9, C10, C11, C13]

This block is the one place the owner's OD-W4 decision is stated exactly. Every other mention (Desired End
State, observable behaviors, NOT-doing, WS6, WS7, WS8-WS13, packaging, gates) is reconciled to it.

1. **Technology.** "WSL2 now, own VM later." The Windows launch agent sandbox is **WSL2 running our OWN minimal
   distro** imported with `wsl --import` (no Microsoft Store). The distro's `/etc/wsl.conf` sets automount OFF,
   interop OFF (and the `WSLInterop` binfmt handler hard-disabled at boot) and `appendWindowsPath=false`; we touch
   **no global `.wslconfig`**. Our own small VM ("VM containment mode", the MS6.5 stub shared with macOS) is a
   LATER milestone, not WS8.
2. **Where the agent runs.** The Claude agent, the Claude CLI, bubblewrap and netd all run **INSIDE the imported
   distro** as a dedicated non-root Linux uid (WS8.4/C6), under our existing Linux sandbox. **No Windows-native
   agent process exists**: there is no Windows `python.exe`, no Windows `claude.exe`, no Windows-side `zb-claude.exe`
   launcher, no Windows agent-helper pipe pump and no Job Object around an agent.
3. **Which hosts.** The **agent runs on Windows 11 ONLY.** On **Windows 10 the agent is OFF** (browser-only): no
   WSL, no distro, no sandbox, no helper, no agent sign-in, no agent voice; the drawer "S" affordance shows the
   fixed agent-OFF explanation. WS8, WS9, WS10 (agent OAuth/fd-3 legs), WS11, the agent legs of WS12 and the
   agent/WSL part of WS13 run and gate on **Win11 only**.
4. **Fail-closed.** If virtualization or WSL is unavailable, or any mandatory WS8 proof fails, **the agent stays
   OFF and the app shows a fixed explanation.** There is no dedicated-users, AppContainer, restricted-token or
   native-Windows fallback.
5. **DROPPED for launch (history only, non-normative):** dedicated local sandbox users, `CreateProcessWithLogonW` /
   Secondary Logon, AppContainer/LPAC, WFP filters/providers/sublayers, host-side netd, a `WindowsSandboxUserBackend`,
   the separate sandbox desktop, and **Job-Object user isolation** (so `wincontain*.py` has no launch role; see D.6).
6. **Windows-host pieces that SURVIVE** (and only these): the browser; the native Win32 drawer; the Secrets window
   and Credential Manager store (the token source); the elevated one-time WSL/VMP enable + the unprivileged per-user
   `wsl --import` setup (C3); the **launcher = `wsl.exe -d <distro> -u <nonroot> …` plus the C1 bootstrap** (the
   control capability on a one-shot inherited pipe, the OAuth token on a separate inherited fd, never env/argv/file);
   the Windows-side C2 file broker and the C5 relay endpoints; and `ShellExecuteW` to open the authorize URL.
7. **Transport / topology** (browser↔agent over loopback TCP, agent listens in the distro, browser connects from
   Windows) remains a **PROPOSAL**, not a contract, until the WS8/WS9 DRAFT-gate blockers close with live evidence.
   "WSL→Windows is firewall-blocked" is **withdrawn as a measured fact** (see `rev_2_14_note`, W-withdrawal in C8).

### B. State at HEAD `e4f705f` (code state of `c07899f`) — replaces "Current State Analysis"   [C2, C4, C5, C6, C12, C13, C14, C15, W2]

Re-baselined 2026-10-22 against the live tree (read-only; nothing built or run). `git diff c07899f e4f705f` is three
`*-REVIEW.md` files, so every code fact below holds at both. The older "Current State Analysis" section is
**HISTORICAL at pin `032a2c9`**; where it disagrees with this table, this table wins. Corrected stale facts:
"3 of 73 shim functions" is now **15 of 73** (the shim is 2,591 lines; `webkit_shim.h` is 441 lines); "stub
`zb_run_screenshot`" is now a real `CapturePreview` (`webview2_shim.cpp:1976-2019`); `automationSocketPath` now
uses `%LOCALAPPDATA%`; the `0o600` chmod is replaced by `restrictToOwner`.

| Milestone | State at HEAD | Live Win11 evidence | Win10 evidence | Plan consequence |
|---|---|---|---|---|
| WS0 gate | **Readiness only** (`gate.sh --probe-only`). No-arg full gate exits 2 "not implemented" (`gate.sh:578-581`); WS0.4 runner NOT hardened; WS0.8 staging not done | probe 992b124 (review 012e1bc) | `--probe-only` readiness probe only (product-run Win10 leg OPEN, WS0.9) | WS0 = "readiness-only PROVEN-PARTIAL (WS0.1a driven half, 0.2, 0.3, 0.6, 0.7); WS0.1b and WS0.5 NOT BUILT; WS0.4/0.8/0.9 OPEN" (C2, C3; rev 2.20: not "closed") |
| WS1 | The exe built and ran on the VM at 7463139, 8f36ee7, 6c771ff, dcd33ae, but per the WS1 proof blocks only WS1.3 is PROVEN-PARTIAL; **WS1.1 UNPROVEN; WS1.4 and WS1.5 NOT BUILT** (their test `ws1_run_test.py` is unregistered); **WS1.2 not started**; most WS1 exe tests unregistered | recorded runs only (see the WS1 proof blocks) | none | WS1.2 precedes WS2a (C3); register WS1 exe tests (W18) (rev 2.20: no longer "green on the VM") |
| WS2.0 | Real on the Win11 VM (970969f, f29e490, 3cb8722) but **PROVEN-PARTIAL**: the token-only mutant is unrecorded (W19) and the Win10 leg WS2.0-W10 is restored and NOT yet run | yes | none yet (leg OPEN, WS2.0-W10) | PROVEN-PARTIAL, not closed (rev 2.20); token-only mutant still unrecorded (W19) |
| WS2a / 2b / 2c | **Zero code**: no `automation_wv2_port.zig`; `app.zig:626-627` wires the GTK ports (`supported = builtin.os.tag == .linux`, `automation_gtk_port.zig:22`) so every page/dom/input/dialog/window command returns -32011 on Windows | none | none | next Windows work (C4) |
| `automation_platform.zig:79-82` | declares `.webview2 => cdp_input, network supported` **before any spike ran** | — | — | PLACEHOLDER / UNPROVEN until WS2b.1 passes (C5) |
| WS3 | flag seam real (`backend_flag.zig`, refusal proven on the real exe); cookie port + profile code exist but are **unwired** (no caller at `app.zig:627`); no `win_cookie_test.py`, no `win_profile_persist_test.py`; no default `%LOCALAPPDATA%` profile (`app.zig:513` `spec.profile_dir orelse return null`); profile folder made with default ACLs (`webview2_shim.cpp:2387`); `zb_restrict_to_owner` (`owner_only.zig:243`) has no caller | partial (15fb6ee, 66060b0, e1e9264) | none | WS3.4 wiring slice (C6) |
| WS4 | not started; the grant TUPLE does not exist in `src/` (`grep target_fp\|normalized_args src` is empty); as-built = approval card (`agent_approval.zig:182` `card_ttl_ms = 120_000`, one-shot Approve), `WindowWant{origin,url,load_serial}` (`automation/engine.zig:1216`), flow `expect{url,recipient}` (`social_flow_routes.zig:209-214`) | none | none | WS4 reconciled to as-built (C7) |
| WS5 | ~125 commits; offline source/model oracles dominate; only the entry run (b2c4f25, 8/8; WS5.1 PROVEN-PARTIAL) and the four lifecycle methods (a5745b9; WS5.5 PROVEN-PARTIAL for the primary window and portable counter only, the second window comes from the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS`, so per-window/popup close WS5.5b is NOT BUILT) have a recorded live run (rev 2.20); as-built is a `WS_CHILD` STATIC icon, no `agent_drawer_win.cpp`, no `.rc`, no manifest, no approval card, no Send box | b2c4f25, a5745b9 | none | WS5 amended to as-built + open tasks (C14, C15, C16) |
| WS6 | portable shape + `TokenStore` real (test-only consumer); Windows CredMan store is a skeleton with no caller (`agent_secrets_win.cpp:26-67`, symbol-checked only at `build.zig:564-567`); `tests/windows/agent_secrets_win_logic_test.cpp:11` includes a header that does not exist | none | none | WS6 consumer + route (C13) |
| WS7 | Python launcher contract test passes against the SUPERSEDED design, but WS7.3 is NOT BUILT per the WS7 proof blocks (rev 2.20) (35-line `launcher.py`: no `wsl.exe`, no `pass_fds`, no fd-3); built 2026-10-22 against the SUPERSEDED native-Windows design (ab86a92, ea8940e, 1a06bb0, b9ff6da); WS7.1/7.2/7.4 unregistered reds, no production functions | none | none | WS7 rewritten for WSL2 (C9) |
| WS8 / WS9 | DRAFT; no production code; discovery spike only (`wsl_live_test.py`, header still says "NOT RUN") | spike 2026-10-21 | none | blockers 1-6 OPEN (C17) |
| WS10 / WS11 | not started; specified for the dropped design | — | — | rewritten for WSL2 (C10) |
| WS12 | WS12.1 hooks + `gate.sh --phase voice` not started | — | — | unchanged |
| WS13 | not started; MSI unchanged since the pin (`Return="ignore"` at `zigBrowser.wxs:80`; `MediaTemplate EmbedCab="yes"` at `:19`) | — | — | WS13 rewritten (C11, W13) |
| Dead Job Object code | `wincontain.py` (248) + `wincontain_win32.py` (211) built 2026-10-20 for the dropped design, still registered (`build.zig:293-306`, `:2471-2474`) and listed as macOS bundle components (`packaging/macos/universal_components_ms5.json:155,159`) | — | — | retire (C12, D.6) |

Volume since the pin: Windows path set +16,773 lines in 45 files, of which about 2,200 are production and about
12,500 test code (about 5.7 : 1); commits per tag WS0 87, WS1 18, WS2 17, WS3 17, WS5 118, WS6 15, WS7 21, WS8 8,
WS9 6, WS12 1, WS13 2, WS4/WS10/WS11 0 (W23: see D.5).

### C. Owner-decision defaults adopted in this revision (pending owner ratification)   [C1, C4]

- **C1 — Windows 10 test host (RESOLVED by the owner ruling, rev 2.18).** Owner ruling (verbatim): "the windows 10 machine
  should not be read-only it is a standard Win10 box, not some production file server." The rev 2.10 premise (a
  read-only file server on which no browser may run, so every "[W] both hosts" gate was unsatisfiable) was WRONG and is
  corrected throughout the plan. **Decision-C1 default (replaces the Win11-only default of rev 2.17): the physical Win10
  box (`zbtest@100.123.34.15`) is a WRITABLE test host; a [W] "both-hosts" gate means the Win11 VM PLUS the Win10
  box.** Win10 rules: (a) **release rule, the same as the Win11 VM:** no live run on the Win10 box without RoseCat's
  exact-commit approval PLUS an orchestrator release; (b) **work confinement:** all work (staging, binaries, run
  artifacts, per-user install directory) stays under `C:\Users\zbtest\zb`, as the standard user `zbtest`; (c) **ask the
  owner before any system-wide install or machine-wide change** (the WebView2 runtime if the box lacks it, the
  certificate store, firewall, services, Defender exclusions, power settings, a second local account). Win10 ships
  BROWSER-ONLY with the agent OFF (OD-W4); its legs are the browser legs only. Reading rule: wherever this plan says
  "[W] both hosts", "on both hosts" or "both screens", read **"[W11] the Win11 VM (and the owner's Win11 console)" AND
  "[W10] the Win10 box (and its monitor)"**. The launch claim may say "Windows 10 browser tested" only for a Win10 leg
  that has actually run under rule (a); a leg that has not run is stated as OPEN/not yet run, never as withdrawn.
  **Caveats recorded, not hidden:** (1) the as-built `--probe-only` code still treats the box as zero-write
  (`root`/`free_gb`/`interactive_session` not_applicable) because it was written on the wrong premise; WS0.9 must
  enforce them there; (2) the 2026-10-20 reading of `C:` on that box was about 0 GB free, so free space must be
  cleared with the owner before any Win10 product leg runs; The Win10 legs that rev 2.10 and rev 2.17 had removed are restored as: WS0.9
  (product-run, both hosts), WS1.2-W10, WS2.0-W10, WS2a.0-W10, WS2b.1-W10, WS13.4-W10, and the Win10 monitor legs of
  `win-render` and `win-install-smartscreen` (tracked as zigBrowser-4pa.31 and zigBrowser-4pa.41).
- **C4 — order question.** WS3, WS5, WS6, WS7 (about 170 commits) were built before WS2a-c, against the order in
  "Dependency order". **Adopted default:** the next Windows work is the WS2a.0 and WS2b.1 spikes, then the WS2a port,
  then wiring the WS3 cookie port/profile (WS3.4) with their e2e; WS4 cannot start before WS2. No further WS5/WS6/WS7
  feature work is scheduled until WS2a.1 is green, except the amendments in C14-C16 and C9. **RATIFIED by the owner (2026-10-22):** this is the decided sequence — the WS2a.0 and WS2b.1 spikes, then the WS2a port, then WS3.4 wiring; WS4 not before WS2; no new WS5/WS6/WS7 feature work until WS2a.1 is green. (Freeze zigBrowser-4pa.1 still holds — nothing is built yet.)

### D. Cross-cutting rules added by the review   [C2, C12, C14, C18, W8, W9, W6, W16, W23]

**D.1 Skip is a failure under a gate (C2).** A registered live step run under a gate with no host configured
**FAILS (nonzero), never exits 0**. Test exit 77 (skip) is a failure whenever `ZB_WIN_GATE=1`. A registered step may
only skip cleanly when run standalone by a human (no `ZB_WIN_GATE`), and such a step is then NOT counted as a Windows
row. The drawer suites must stop force-unsetting the host variables (`build.zig:3549, 3559`) in the gate path.
**Rev 2.19 (rule 7, "skip is failure"):** the proof of this rule is exercised, not read: run each live step's real command with `ZB_WIN_GATE=1` and no host and assert it exits nonzero (WS0.9, `live_step_skip_test.py`). Reading `build.zig` to see that a step exists is a tripwire.
Eight registered live steps currently exit 0 when `ZB_WIN11_HOST` is unset (`build.zig:294-334`); each must be changed
to fail under the gate or be moved out of the aggregate `test` into a `windows-live` aggregate that requires a host.
**Rev 2.20 (G2.1) the registration target is concrete.** `windows-live` is a NEW `build.zig` aggregate step (it does NOT exist at HEAD: a read-only search of `build.zig` finds no such step). It is created by the WS0.9 green commit. Every NEW live Windows test that this plan names registers in it through its OWN per-test step `windows-<test stem without win_/_test>-live`, which runs the real command with `ZB_WIN_GATE=1` and fails on skip (rule 7). Pure Linux selftests join the existing steps `windows-gate-selftest`, `windows-twohost-selftest` or `windows-build-selftest`, or a NEW step named in the row. The full file-to-step list is the "Registration map (rev 2.20)" at the end of the plan; each slice's proof-block header repeats its own entries. A test whose step is not yet in `build.zig` is a DRAFT (rule 2), and the row says so.

**D.2 The real per-slice gate command until the product-run mode exists (C2).** `gate.sh` with no argument exits 2.
Until WS0.9 lands, the per-slice protocol step 5 means exactly: (a) `tests/windows/gate.sh --probe-only` (readiness,
Win11); (b) for each of the slice's live tests, `ZB_WIN_GATE=1 python3 -I <test>` against the Win11 VM and, for a slice with a Win10 leg, against the Win10 box (after its release, section C), each required
to print `ASSERTS <n>` with `n > 0` and to exit 0, with the output pasted in the commit message; a skip or an exit 77
is recorded as UNCLOSED. Nothing may call a slice closed on a bare `zig build test` green.
**Rev 2.19 (rules 3 and 8):** the pasted commit-message output also records, for each behavior, the production mutant that was applied, the command, and the failing output; "passes" means the run was observed in the session, at a named commit, with the command and exit code recorded. A claim not backed by such a run is SUSPECTED, not VERIFIED.

**D.3 `--e2e-protocol` contract (W16).** The ~12 `ZIGBROWSER_AGENT_DRAWER_*` e2e seams in the shim
(`webview2_shim.cpp:2210-2232`: OPEN, FAIL, DRAG, FOLD, FOLD_FAIL, DPI, RTF, DPICHANGE_IGNORE, HITTEST_FAIL, WINDOWS,
EXTRA_FAIL, EXTRA_CLOSE_ONE), the second window class `zigBrowserDrawerExtra` (`:40, 1481-1495`), WS6.3's
disposable-credential override and WS1.4's runtime-folder override all hang on the one flag `--e2e-protocol`. Contract:
(i) the flag is read **only from the process command line at launch** (never from the environment, a page, a socket
client, a shortcut or a runtime message); (ii) **packaged (MSI) builds refuse it** with a nonzero exit and a fixed
message, OR the plan records why it is safe — default is refuse; (iii) the full list of seams it unlocks is one
inventory file `tests/windows/e2e_seams.json`; (iv) WS2's "absent at link time" rule applies to the drawer seams too.
Reds (unregistered until green): `tests/windows/e2e_protocol_contract_test.py` — packaged-flavor build refuses the flag;
for EVERY seam in the inventory, launch the real exe WITHOUT `--e2e-protocol` and with that seam's variable set in the environment and assert the seam is inert, then WITH the flag and assert it takes effect (mutant: honour a seam from the environment ⇒ red); a page
`postMessage` and every socket method cannot set it (mutant: honour it from a runtime message ⇒ red). **Rev 2.19 (rule 5):** a comparison of the inventory file against the seams read in the shim source is kept only as a labelled TRIPWIRE (mutant: add an undeclared `ZIGBROWSER_*` seam ⇒ the tripwire is red); it never closes D.3.

**D.4 A behavior closes only on a real-binary row (C14, W23).** Offline oracles (source greps, AST parses, models) are
**tripwires**, not proof. A behavior is CLOSED only when one accepted run of its live row on the Win11 VM exists, with
`ASSERTS n>0`, at a named commit. Until then the plan marks it OPEN. **No new offline oracle may be added without a
paired live row in the same slice.** An AST parse of a Python test file is explicitly not a control-flow proof.
**Rev 2.19 (owner order; rule 5):** this is now binding for every kind of source check: grep, regex, lexer, AST, "the symbol exists", "the file contains", nm, strings and otool listings, PE import listings, SDDL or flag-constant comparisons and file censuses are TRIPWIRES. They may guard against regressions and must be labelled so; they never close a behavior, a slice, a review finding or a validation finding. The 4pa.44 and 4pa.46 findings are re-marked on this basis (WS5).

**D.5 Test-to-production budget (W23).** The review measured about 5.7 test lines per production line on Windows with
the review loop centred on oracle precision. Rule: each slice reports its test:production line ratio in its commit
message; a slice above 3 : 1 that has no accepted live row is not accepted. Review effort goes to product behavior
(a real-binary row, a mutant that flips it), not oracle wording.

**D.6 Retirements (C12, W6, W9, W8).** Decided here, executed by their owners as separate commits (this revision edits
only the plan): (a) **retire** `wincontain.py`, `wincontain_win32.py`, their live steps (`build.zig:293-306`), unit
tests (`:2471-2474`) and the macOS manifest rows (`universal_components_ms5.json:155,159`) — the Job Object model is
dropped (OD-W4) and C4 owns teardown inside the distro; none has a production caller; (b) **retire**
`tests/guest/build-in-guest.sh` (insecure builder: `StrictHostKeyChecking=no` :14, `2>/dev/null` :23, fixed `/tmp`
tar) in favour of `build-on-windows.sh`; (c) **retire** `src/webview2_config.zig` (`applyWindowsFlag`/`applyProfileDir`
duplicate the real arm at `webkit.zig:63-70`) and point `ws3_win_cross_root.zig` at the real arm; (d) `gate.sh
--fence-string` stays a lexical diagnostic only: its test-only hooks `ZB_SELFTEST_RAN_LOG`/`ENV_LOG` move out of
the production script into the selftest wrapper.

### E. Traceability — every review finding → plan amendment (19 critical + 23 warnings)

Review IDs: C1-C19 are the review's own numbering (bd `zigBrowser-4pa.31..49`). The review's 23 warnings are
numbered W1-W23 here in review order (Contracts W1-W5, Interfaces W6-W10, Promises W11-W14, Data Models W15, APIs W16,
Test-Spec W17-W23). **Rejections: none.** Every finding is amended; C4-order is amended with the review's
recommended default and flagged for owner ratification (section C, STILL PENDING); C1 was REPLACED in rev 2.18 by the owner's ruling (the Win10 box is writable).

| ID | bd | Finding (short) | Amended in |
|---|---|---|---|
| C1 | 4pa.31 | No Win10 browser test host (rev 2.18: owner ruling — the Win10 box IS a writable test host; the read-only-file-server premise was wrong) | A.3; C; reading rule in markers table, Why-this-plan, Desired End State, behaviors 1-2 and 7, WS0.2, WS0.7, Testing Strategy, Dependency order, per-slice protocol, real-screen table, WS13 gate. **Rev 2.18 (owner ruling): C1 default replaced (Win10 box writable; [W] = Win11 VM + Win10 box; Win10 release rule = RoseCat exact-commit approval + orchestrator release; confined to C:\Users\zbtest\zb; owner asked before any system-wide install); Win10 legs restored in WS0.9, WS1.2-W10, WS2.0-W10, WS2a.0-W10, WS2b.1-W10, WS13.4-W10 and the real-screen table** |
| C2 | 4pa.32 | No product gate; live steps green with zero Windows rows | D.1, D.2; new **WS0.9**; Testing Strategy fail-closed rules; per-slice gate protocol |
| C3 | 4pa.33 | WS0.4 runner never hardened; m8 tests skip 77 | WS0 header status; **WS0.4 OPEN list**; WS1.2 before WS2a; Dependency order |
| C4 | 4pa.34 | WS2a/b/c zero code; built out of order | B; C; Dependency order; WS2 header status |
| C5 | 4pa.35 | Spikes never run; capability table already claims cdp_input | B; WS2a.0 / WS2b.1 spike files; **WS2b.0 capability honesty** |
| C6 | 4pa.36 | WS3 cookie/profile unwired | new **WS3.4 wiring slice** |
| C7 | 4pa.37 | WS4 grant tuple not in code | WS4 rewritten to as-built + **WS4.0** tuple decision |
| C8 | 4pa.38 | Top-level contract contradicts OD-W4 | A; Desired End State; behaviors 5-7; NOT-doing; `rev_2_14_note` withdrawal |
| C9 | 4pa.39 | WS7 built vs native-Windows design | A.2/A.6; WS7 rewritten |
| C10 | 4pa.40 | WS10/WS11 for the dropped design | WS10, WS11 rewritten |
| C11 | 4pa.41 | WS13 uninstall/gate describe sandbox users/WFP (dropped model); rev 2.18: the Win10 box is writable, so WS13 gets a Win10 leg | WS13.1, WS13.4, WS13 gate rewritten. **Rev 2.18 (owner ruling): the 'no install and no probe on Win10' text is removed; WS13.4-W10 (own test, own evidence line) and the Win10 `win-install-smartscreen` leg are restored** |
| C12 | 4pa.42 | 459 lines dead Job Object code registered | D.6(a); rev 2.6 bullet in WS2.0; B table row |
| C13 | 4pa.43 | WS6 store no consumer / no route to in-distro CLI | WS6 **WS6.4 token route**, WS6.2 consumer |
| C14 | 4pa.44 | WS5 proven by oracles; live rows never ran | D.4; WS5 **status table** and closure rule |
| C15 | 4pa.45 | WS5 as-built diverges | WS5 Design rewritten to as-built + **WS5.8-WS5.10 open tasks**; WS12.1 note |
| C16 | 4pa.46 | WS5.6 isolation offline only | WS5.6 real-binary red |
| C17 | 4pa.47 | WS8/WS9 not implementable; gate conflicts with blocker 1 | DRAFT gate (sanctioned rerun); WS8.3/8.4/8.5; C1/C4 numbers |
| C18 | 4pa.48 | Real input domains with no Property | **Property register** at end of Testing Strategy |
| C19 | 4pa.49 | Boundary values checked, not parsed | WS0.1 typed record; WS6.1 `Token` type |
| W1 | — | WS0.1 defers `webview2_pv`, WS0.2 doesn't qualify | WS0.2 |
| W2 | — | Current State stale | B; Current State heading |
| W3 | — | `runSafety` unused; nullptr target reaches real credential | WS6.3 |
| W4 | — | hosts.env 19041 vs 19045; INCOMPLETE msg; 15 s TCP step | WS0.2 / WS0.6 gap list |
| W5 | — | Frontmatter + bd-locked process note | frontmatter; Process note |
| W6 | — | build-in-guest.sh insecure; SDK paths hardcoded; key var mismatch | D.6(b); WS0.8 |
| W7 | — | WS0.8 staging not done | WS0.8 open list |
| W8 | — | `--fence-string` no caller + test hooks | D.6(d); WS0.5 |
| W9 | — | `webview2_config.zig` duplicate arm | D.6(c); WS3 cross-check |
| W10 | — | Path/header drift (tests/windows vs tests/e2e) | WS3 / WS5 "Files touched" |
| W11 | — | WS2 async contract names no numbers; INFINITE wait | WS2 Design deadlines; WS2a.3 |
| W12 | — | `cross-check-ws3-win` not wired | WS3 cross-plan coordination |
| W13 | — | Bootstrapper failure swallowed; no cabinet cap | WS13.2, WS13.3 |
| W14 | — | WS0.4 120 s bound not implemented | WS0.4 OPEN list |
| W15 | — | WS8/WS9 data models untyped | WS8 C5/C3/C4 typed models |
| W16 | — | e2e seams uncontracted | D.3 |
| W17 | — | WS0 mutants only comments; regex zero-write guarantee | WS0 mutant rule |
| W18 | — | WS1 exe tests unregistered | WS1 registration |
| W19 | — | WS2.0 token-only mutant unrecorded | WS2.0 |
| W20 | — | WS3.2 tests don't match plan | WS3.2 |
| W21 | — | `agent_secrets_win.cpp` gated by compile only | WS6.1 |
| W22 | — | WS7 reds use toy inputs | WS7 |
| W23 | — | 5.7:1 test:production, oracle-centred loop | D.4, D.5 |

### F. Verification-rule overlay (rev 2.19; owner order 2026-10-22)   [4pa.44, 4pa.46]

The owner ordered that agents check code by **exercising** it. The binding text is the top-level section **"Verification rule: prove it by running it (owner, 2026-10-22)"** placed before WS0, the first slice; it overrides any looser wording elsewhere in this plan. This section only records how the plan was swept.

**F.1 Markers used in the slice "proof blocks" and in the table at the end of the plan.**
- **PROVEN** = the production code path is driven by a registered test that asserts an observable result, and (platform code) a run on the platform is recorded at a named commit. **PROVEN-PARTIAL** = the same, with the open items listed (a missing production mutant record, a missing leg, a clean-skip registration).
- **NOT BUILT** = the code is absent, or the only proof is source-only, unregistered or unreachable from a production caller (rules 2, 5, 6). A behavior listed earlier as green or closed whose test is a tripwire or unregistered is **re-marked** NOT BUILT.
- **UNPROVEN** = no exercising proof is possible yet; the proof block states exactly what is missing.
- **TRIPWIRE** = a source-text check (grep, regex, lexer, AST, symbol, file-contains, nm, strings, otool, PE import listing, constant or SDDL comparison, file census). It may guard a regression and is always labelled; it never closes a behavior, slice, review finding or validation finding.
- Statuses are documentary. Runs are cited as the plan and the orchestrator record them; this revision ran nothing (rule 8). A run claim without a named commit is SUSPECTED.

**F.2 Source checks kept ONLY as tripwires (they no longer close anything).** `RemotePathFenceRemovedTests`; the `WS0ZeroWrite` class (`host_probe.ps1` regex, `session_probe.ps1` lexers, `*_extractable_and_used`); `pe_census.py` and its selftest; `screenshot_diag_selftest.py`; `cross-check`, `cross-check-ws3-win` and `ws3_win_cross_root.zig` symbol checks; `automation_platform.zig:885-886` (fake-backed); the `agent_secrets_win.cpp` export check at `build.zig:564-567`; the planned `win_abi_absence_test.py` symbol listing; the e2e-seam inventory comparison; the WS5 offline oracle and model suites (`windows-drawer-settle`, `windows-drawer-lifecycle`, the offline halves of `windows-drawer-live` and `windows-drawer-behaviors`); the WS13.1 component census.

**F.3 What changed in the plan text.** (i) The rule section is inserted verbatim. (ii) D.1, D.2, D.3 and D.4 are tightened. (iii) Each slice (WS0-WS13) gains a "proof blocks" subsection stating, for every behavior, (a) entry point, (b) test and step, (c) mutant, (d) platform run, plus its status. (iv) In-place source-check proofs were rewritten: WS0.5, WS0.9, D.3, WS1.1, the WS2 absence assertion, WS2b.0, WS3 cross-check, WS6.1 constants and WS13.1 census. (v) The compliance table is at the end. D.6 retirements are not behaviors: each is closed by running the full registered `zig build test` and `cross-check` after the retirement commit; a grep for residual names is a tripwire.

**F.4 Nothing was weakened.** Every existing driven test, mutant requirement, fail-closed rule and release gate remains in force; the rule only tightens what counts as proof.

> **PLAN ONLY.** No implementation and no live runs were done to write it. Agents prepare
> scripts and run them on the **two Windows hosts over SSH** (a Windows 11 VM and the
> user's physical Windows 10 machine), **never** on the user's Linux `DISPLAY :0`, live
> profile or live sockets. Every UI slice names a real-screen check that the orchestrator
> runs **with the user**. Decisions that belong to the user are listed in **Open decisions
> for the user** and are not taken here.

## Why this plan exists

The user: "Mac and Windows are the 2 main target systems, Linux is my environment, not the
primary target for users," and "Plan windows now. I'll have a Win11 VM and windows 10
physical machine available." So this plan supports **both Windows 10 and Windows 11** as launch targets, but
(rev 2.18, C1) the Windows 10 machine is a standard WRITABLE test box, so **every [W] gate runs on the Win11 VM AND the Win10 box**
(Win10 release rule and confinement: section C). It is the counterpart of the macOS launch plan and
mirrors its shape: milestones WS0…WS13, a fail-closed two-host gate, a shared sandbox
backend seam, signing last, and named red tests for every slice. The voice-output (TTS) and
voice-input (STT) plans have Windows steps that wait on this plan (section **Voice plans**).

## Host markers used in this plan

| Marker | Meaning |
|---|---|
| **[L]** | Built and tested on Linux. No Windows host, no display (never `DISPLAY`, never Xvfb unless an existing Linux gate already does it under a private Xvfb). |
| **[W11]** | Needs the Windows 11 VM (the build host: MSVC, Windows SDK, WebView2 SDK). |
| **[W10]** | Needs the physical Windows 10 box (a standard writable test host, no toolchain; it receives binaries built on the VM; work confined to `C:\Users\zbtest\zb`). |
| **[W]** | "Both Windows hosts in the same gate run". **Rev 2.18 (C1, owner ruling): [W] = [W11] the Win11 VM PLUS [W10] the Win10 box** (a standard, writable test host, `zbtest@100.123.34.15`; release rule = RoseCat exact-commit approval + orchestrator release; work confined to `C:\Users\zbtest\zb`; ask the owner before any system-wide install). Every Windows milestone gate is [W] unless it says otherwise. |
| **[U]** | UI slice: needs a real-screen check run by the orchestrator with the user. |

## Current State Analysis

> **SUPERSEDED (rev 2.17, W2): read "Review amendments → B. State at HEAD e4f705f" instead.** This section is
> **HISTORICAL at the pin (`git_commit` 032a2c9, 2026-10-19)**: it records the code as it was when the plan was
> written. Known-stale statements in it: "3 of 73 shim functions" (now 15), "stub `zb_run_screenshot`" (now
> `CapturePreview`), "`automationSocketPath` never reads `%LOCALAPPDATA%`" and "chmods `0o600`" (both fixed by WS2.0),
> `tests/guest/build-in-guest.sh` as the build path (retired, D.6), and every "dedicated user / WFP / job object"
> sandbox statement (dropped by OD-W4). For current behaviour read section B and the WS sections, not these file:line facts.

### Key discoveries (research `2026-10-19-windows-launch-support-surface.md`, verified file:line)

- **The Windows shim is a render-and-IPC shell.** `src/webview2_shim.cpp` (771 lines) defines 3 of
  the 73 shim functions in `src/webkit_shim.h` (verified at HEAD: the header declares 75 functions =
  73 shim functions + the two Zig-owned exports `zb_policy_decide` :427 and `zb_ipc_dispatch` :428;
  the shim has exactly three `extern "C"` definitions; WKWebView has six; GTK all 73): `zb_app_run` (:707), a stub `zb_run_screenshot`
  returning `ZB_EXIT_SNAPSHOT_FAILED` (:751-757), and `zb_version_line` (:759). No automation,
  native-input, cookie, dialog, multi-window or drawer function exists. One window, the
  default WebView2 environment with **no user data folder** (:692), a marker script
  (:561-577), and the `chrome.webview` reply channel into the Zig `zb_ipc_dispatch`
  (:412-463). No `zb_policy_decide`, `NewWindowRequested` or `ProcessFailed` handling.
- **The shipping build is native MSVC inside a Win11 KVM guest.**
  `tests/guest/build-in-guest.sh` (28 lines) runs `zig build -Dtarget=x86_64-windows-msvc` over Tailscale
  SSH with WebView2 SDK 1.0.3967.48 and Windows SDK 10.0.26100; `build.zig` links the
  MSVC-only `WebView2LoaderStatic.lib` (:1551) and checks `wrl.h` (:67). The shim uses
  `Microsoft::WRL::Callback` (:18 is the `using` line; the `#include`s are above it), which MinGW-w64 does not ship (`wrl/event.h` absent), so a
  Linux `windows-gnu` build of the shim does not compile today. Linux runs only the no-link
  `cross-check` (build.zig:243-280) and `ipc-test-win` (:224-235). `cross-check` compiles `src/main.zig` as an object for `x86_64-windows-gnu`
  (an ABI the shim itself cannot build for), so it proves the Zig side's symbol needs only.
- **How WebView2 is wired in `build.zig` (verified):** `Backend` enum `webview2_backend` (:6);
  `WebView2Paths` (:10-14) is filled from `-Dwebview2_include`/`WEBVIEW2_INCLUDE`,
  `-Dwebview2_lib`/`WEBVIEW2_LIB`, `-Dwinrt_include`/`WINRT_INCLUDE` (:111-130), with **no NuGet or
  registry discovery**; `CheckWebView2SdkStep` (:16-77) is the Windows `pkg_guard` (:148) and fails the
  build unless the three dirs, `WebView2.h` (:55), `WebView2LoaderStatic.lib` (:61) and `wrl.h` (:67)
  exist; `resolveBackend` maps `.windows` to `webview2_backend` (:1481-1488); `configureWebView2Backend`
  (:1535-1558) compiles `src/webview2_shim.cpp` with `-std=c++17` and links `WebView2LoaderStatic`,
  `ole32`, `oleaut32`, `user32`, `gdi32`, `shell32`, `advapi32`. **No `agent_*.c` file, no `.rc`, no manifest
  and no `crypt32`/`wtsapi32`/`userenv`/`advapi32`-security helper are linked on Windows**; WS5-WS11 add
  link libraries (`comctl32`, `dwmapi`, `msftedit`, `crypt32`, `wtsapi32`, `userenv`, `netapi32`, `fwpuclnt`, `secur32`).
- **Windows guest tooling in `tests/guest/` (verified, 3 files):** `setup.ps1` (431 lines; elevated:
  OpenSSH Server + a firewall rule created only if missing and **with no `RemoteAddress` scope**, Zig 0.16.0
  zip, nuget + WebView2 SDK, MSVC Build Tools + Windows 11 SDK 22621 through winget, user env vars
  `WEBVIEW2_*`/`WINRT_INCLUDE`; no Python, WiX, Autologon, power settings, test users or Windows 10
  handling), `build-in-guest.sh` (28 lines; hardcoded key `/home/maceo/vms/win11-m8/zb_guest_key`, host
  `maceo@100.103.8.90`, `StrictHostKeyChecking=no`; tars only `src build.zig build.zig.zon tests` to the
  fixed path `/tmp/zb_worktree.tar` with `2>/dev/null`, so `agent/`, `packaging/`, `tools/`, `docs/` never
  reach the guest), and `ssh.sh` (50 lines; `127.0.0.1:2222`). **Corrections to rev 1:** `ssh.sh` is not
  superseded: the live `win11-m8` domain has a passt `2222 -> 22` forward, while the Tailscale node
  `100.103.8.90` was offline for 105 days when checked; and `setup.ps1` must not run on the Win10 box without the owner's OK (it opens port 22 with no address scope and installs a toolchain, a system-wide change).
- **Automation transport on Windows is planned but unproven.** `planSocketPath` gives a
  filesystem AF_UNIX path for Windows (automation_transport.zig:17-35); `automationSocketPath`
  never reads `%LOCALAPPDATA%` (app.zig:453-460); the server `chmod`s `0o600`
  unconditionally (automation_server.zig:1513-1517) and writes a `0o600` token sidecar
  (:1496-1511). The ADR-1 AF_UNIX spike step `automation-afunix-spike-win` exists
  (build.zig:282-291) with no recorded result.
- **The capability table already says Windows uses CDP.** `adapterCapabilities(.webview2)` is
  `input = .cdp_input`, `network = .supported` (automation_platform.zig:77-98), backed today
  only by in-memory fakes (:167-430).
- **The agent stack refuses Windows.** `--agent-setup` prints "the Claude Agent is
  Linux-only" (app.zig:52-55); drawer/secrets/helper/login C files compile only in
  `configureGtkBackend` (build.zig:1503-1533); the Python host has no Windows branch.
- **The sandbox seam exists in code.** `SandboxBackend` (sandbox.py:201-229) with one
  implementation `LinuxBwrapBackend` (:232-374); `LaunchSpec` carries argv, unshare, mounts,
  workdir, seccomp fd, `network` (egress endpoint `127.0.0.1:3128`, allow
  `("api.anthropic.com",)` :51, bridges 51091/31337, `hooks_get_egress=False`), `lifetime`,
  `channel` (fd 3) (:71-108). Login allowlist adds `platform.claude.com` (:56). netd is built
  (`netd.py`), Unix-socket based, sandboxed by its own bwrap. No macOS backend exists yet;
  the macOS plan's MS2+ has not landed in `src/` (no `automation_wk_port.zig`, no
  `applyMacBackendFlag`).
- **GUI tests already reach the desktop through interactive scheduled tasks**
  (`tests/e2e/slice2_common.py:447-548`, `packaging/windows/gate.ps1:88-150`) but nothing
  checks that the session exists and is unlocked, the OS build, or a nonzero assertion count;
  the `m8_*` tests exit 77 (skip) off-host or without `ZB_ENABLE_M8_E2E=1`.
- **Packaging is an unsigned per-user WiX 3.14 MSI** that silently runs the Evergreen
  bootstrapper with `Return="ignore"` (`packaging/windows/zigBrowser.wxs`). No manifest,
  no `.rc`, no signing, no update channel.
- **Hosts.** The physical Windows 10 machine is `100.123.34.15` (tailnet name
  `file-server-win-mac`; it answers Tailscale ping on the LAN path `10.0.0.163`, but **port 22
  refuses**: OpenSSH Server is not running). Rev 2.18 (owner ruling): it is a standard, WRITABLE Win10 test box, NOT a read-only or production file server (the tailnet name `file-server-win-mac` is a legacy label only). The Win11 VM's
  address is **to be provided**. The old `win11-m8` libvirt domain (`qemu:///session`, key
  `/home/maceo/vms/win11-m8/zb_guest_key`, old Tailscale address `maceo@100.103.8.90`) may be reused if
  the user says it is the same VM. **Read-only re-check on 2026-10-19 (`virsh`, `tailscale status`):**
  the domain is `running` (not shut off as rev 1 said), has **no snapshots**, a passt interface with
  `127.0.0.1:2222 -> guest 22`, SPICE on `127.0.0.1:5900`, an `ich9` sound device with a SPICE audio
  backend, UEFI Secure Boot with a raw NVRAM file and a `tpm-crb` swtpm, UUID
  `f6e88ab5-3481-463e-b19b-e793b695f02c`; its Tailscale node `linuxwin` (`100.103.8.90`) is offline.
  Nothing was started or contacted.

### External facts that shape the plan (research §2-§8, links there)

- Windows 10 consumer ESU runs to **2027-10-12**; WebView2 keeps updating on Windows 10 22H2
  until **at least October 2028**. Windows 11 ships the WebView2 runtime; "the vast majority"
  of Windows 10 devices have it.
- The Claude CLI runs natively on Windows 10 1809+ x64/ARM64; the Agent SDK's Windows x64
  wheel bundles `claude.exe` and refuses `.bat`/`.cmd` shims; Windows ignores
  `CLAUDE_CODE_PROCESS_WRAPPER` because there is no `exec`; whether
  `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` works on Windows is **unverified**.
- Claude Code's own `/sandbox` does **not** sandbox native Windows. Anthropic's
  sandbox-runtime has an **alpha** Windows mode (dedicated local user, restricted token, job
  object, WFP filters, one UAC prompt). Codex uses dedicated sandbox users + ACLs + WFP.
  Windows Sandbox is not on Home. WSL2 is on Home but needs virtualization and is NAT-only on
  Windows 10.
- EV certificates **no longer bypass SmartScreen**. Azure Artifact Signing is about
  $9.99/month and is open to **individuals only in the US or Canada**. jsign can sign
  exe/msi from Linux. WiX 6+ binaries carry the OSMF EULA (the repo uses 3.14). A single MSI
  cabinet is limited to 2 GB.

## Desired End State

A Windows 11 user (and, **browser-only and tested on the writable Win10 box (C1)**, a Windows 10 22H2
user) installs an **unsigned per-user** zigBrowser (code signing is
DEFERRED — OD-W3 decided no signing for launch; it is not a launch requirement) and can: browse with an
isolated persistent profile; drive the full automation API (multi-window, freeze and
recovery, dialogs, popups, native input proven trusted) with the same client contract and
per-window FIFO semantics as Linux; run site flows behind the same approval model; use a
native drawer (docked panel, movable "S" icon that hides while open, conversation with
copyable text, "-" fold animation into the icon) isolated from page JavaScript; store the
Claude token in Credential Manager through a Secrets window; sign in; and — **on Windows 11 only** — run the
Claude agent **inside our own imported WSL2 distro under the existing bubblewrap + netd Linux sandbox** behind the
same `SandboxBackend` contract (`WslBackend`, section A), whose security proofs are hard launch gates; on Windows 10
the agent is OFF with a fixed explanation. Verified by real-binary e2e on the **Win11 VM** (a behavior counts only when
a live row ran — D.4) and by the user's eyes on the Win11 console. Until a code-signing identity exists, every artifact
is called an **unsigned development build, not a distributable artifact**.

### Observable behaviors (top level)

1. Given the Win11 VM and the Win10 box provisioned, when `tests/windows/gate.sh` runs in its
   product-run mode (WS0.9), then it passes only if the hosts it requires are reachable, on the expected OS builds,
   with an unlocked interactive test session on the VM, a WebView2 runtime, and every test reporting nonzero
   assertions with no skip — and fails in every other case. (Until WS0.9 exists the no-argument gate exits 2.)
2. Given a release build from the VM, when it runs on the Win11 VM and on the Win10 box, then a real visible window
   renders the fixture and answers IPC.
3. Given an authenticated socket client, when it sends any automation command, then the live
   WebView2 page is driven and the result is read back with the Linux contract.
4. Given the drawer is on, when the user clicks the "S" icon, then a docked drawer opens, the
   icon hides, text is copyable, and "-" folds the drawer into the icon over 180 ms.
5. Given a token in the Secrets window, when a Windows 11 agent session starts, then the token reaches only the
   CLI's own inherited token channel **inside the WSL2 distro** (kept distinct from the control capability, C1) and
   nothing a hook, page, log or environment can read.
6. Given the agent runs inside the WSL2 distro on Windows 11, when a hook or the CLI tries any network other than
   the allowlisted in-distro netd proxy and the two bridges, then it fails — enforced by the in-distro bubblewrap
   network namespace + netd (NOT a Windows kernel/WFP filter; OD-W4). (Proof is a WS9 hard gate; DRAFT.)
7. Given the installer, when a user downloads and runs it on Windows 11 and on Windows 10 (browser-only), then it installs per
   user and an uninstall removes everything it added: the files, shortcuts and HKCU keys, and **only
   zigBrowser's own WSL distro, import dir and state** — it cannot un-enable global WSL/VMP (WS13.4). (The build is
   unsigned — signing is deferred, OD-W3 — so no signature-verification is claimed at launch; only "nothing may claim signed/distributable".)

**Rev 2.19 (verification rule):** each top-level behavior above closes only through the rule-9 rows of its slices (the compliance table at the end of the plan). A green `zig build test` never closes one; a behavior is closed by an exercised run, at a named commit, on the platform that runs the code.

## What We're NOT Doing

- Not changing Linux GTK behavior or the macOS plan's slices; shared seams are extracted
  behavior-preserving, with the Linux gate staying green.
- Not shipping Windows on arm64 unless the user decides to (open decision **OD-W5**).
- Not shipping an AppContainer, Windows Sandbox, Hyper-V, dedicated-local-users or WFP backend: **OD-W4 is
  DECIDED — WSL2 IS the launch sandbox, not a fallback** (C8; section A). There is no "build WSL2 only if another
  backend's gate fails". Our own small VM is a later milestone, not WS8.
- Not running the agent on Windows 10 (agent OFF there); Windows 10 browser test coverage comes from the writable Win10 box (C1) and is claimed only for legs that actually ran.
- Not obtaining or paying for a code-signing identity (user action, OD-W3).
- Not exposing drawer text through a production automation-socket read (observation is the
  `--e2e-protocol` native census or screen capture only, as on Linux and macOS).
- Not running anything on the user's Linux display, live profile or live sockets; not touching
  the Windows 10 machine's shares, drives, existing accounts or the owner's profile.
- Not rewriting git history (fix-forward only); not committing red tests into gate-registered
  steps.

## Open decisions for the user

**OD-W1, OD-W3, OD-W4 and OD-W6 are DECIDED (owner, 2026-10-21) — see the OWNER DECISIONS block below;
their rows and sharpening are retained for context but are no longer open.** The remaining items give a
recommendation and its trade-offs; the plan proceeds on the recommendation only where a slice can start
without the decision, and slices that depend on a still-open decision say so.

| ID | Decision | Recommendation | Trade-offs | Blocks |
|---|---|---|---|---|
| **OD-W1** | Installer format | **DECIDED 2026-10-21: keep the per-user MSI** (WiX 3.14; see OWNER DECISIONS). WS13 targets the MSI; Velopack/MSIX/Inno are not pursued. | MSI: per-user, no admin, mature, 2 GB cab limit (fine for the 0.82 GB model), no built-in updates. **Velopack EXE**: per-user, delta auto-update, MIT, but replaces the existing MSI work. **MSIX**: built-in updates and Store path, but signing is mandatory, and AppData writes are virtualized per package (risk for a profile the agent helper also reads); `ms-appinstaller:` one-click is disabled. Inno/NSIS: fine, no advantage here. | WS13 |
| **OD-W2** | Auto-update | **WinSparkle** (Ed25519-signed appcast, works with an MSI) after launch; ship 1.0 with an in-app "new version" notice only. | WinSparkle: checks only, you supply the installer. Velopack: full updater, implies OD-W1 = Velopack. MSIX App Installer: implies OD-W1 = MSIX. None: users must reinstall. | WS13.5 |
| **OD-W3** | Code signing | **DECIDED 2026-10-21: NO code signing for launch — DEFERRED** (see OWNER DECISIONS). Launch ships an unsigned per-user build; agents hold no key and buy no certificate; nothing may claim "signed"/"distributable"; WS13.6 stays OPEN and is not a launch gate. | If signing is ever adopted later: Azure Artifact Signing (~$9.99/mo, Microsoft HSM, jsign from Linux) or an OV cert on a hardware token/cloud HSM; **not EV**. All show a SmartScreen warning until reputation builds. Retained as history only. | WS13.6 (deferred; not a launch gate) |
| **OD-W4** | Sandbox technology | **DECIDED 2026-10-21: WSL2 now, own VM later** (see OWNER DECISIONS). Launch sandbox = WSL2 + our own `wsl --import` distro (interop/automount off), agent under bubblewrap+netd inside it, browser↔agent over loopback TCP (PROPOSED direction, unproven: one reverse attempt failed without proving listener readiness; the transport direction and the direct-dial denial remain proposals pending reviewed live evidence); agent OFF + fixed explanation if virt/WSL absent. The dedicated-local-users / AppContainer paths below are **SUPERSEDED (dropped for launch)** and kept only as history. | Dedicated users: native Windows hooks, kernel-enforced network, strong cross-user process isolation; costs one admin prompt, creates two local accounts, and an orphan created through WMI/Task Scheduler may need a SYSTEM sweeper (sub-decision OD-W4c). **AppContainer/LPAC**: no extra accounts, Low IL, but the loopback exemption to reach a local proxy likely needs admin anyway, and Node/Bun/`claude.exe` under AppContainer is undocumented. **WSL2**: keeps every Linux guarantee and test, but needs virtualization (nested inside the VM, kernel-sensitive on KVM), is NAT-only on Windows 10, turns the user's hooks into Linux hooks, and adds a distro image. **Windows Sandbox**: not on Home; rejected. **Restricted token only (no admin)**: weakest network isolation; not recommended. | WS8, WS9, WS11 |
| **OD-W4b** | Token channel if `claude.exe` ignores `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` on Windows | **Credentials file in a directory readable only by `zb-agent`** (`CLAUDE_CONFIG_DIR`), written by the launcher just before start and deleted on exit. | The project rule is "never env". Cross-user isolation makes the CLI's environment unreadable to hooks, but env leaks into logs and children; the ACL'd file is narrower. Both are weaker than the Linux fd route. Decided only if spike WS8.3 fails. | WS8.3 |
| **OD-W4c** *(HISTORICAL / NON-NORMATIVE, OD-W4)* | Orphan sweeper | ~~If WS8.5 shows a hook can escape the job, install a tiny SYSTEM sweeper task that kills every process owned by the two sandbox users.~~ **DROPPED with the dedicated-user model (OD-W4):** there are no sandbox users; under WSL2 per-run teardown is the C4 marker/lock inside the distro (no SYSTEM sweeper). | — | — |
| **OD-W5** | arm64 scope | **x64 only at launch.** Windows 11 on Arm runs x64 apps under Prism; **Windows 10 on Arm cannot run x64 at all** (x86-only emulation), so Win10-Arm is unsupported. Native arm64 is a follow-up milestone. | Native arm64 needs an arm64 Python runtime, an arm64 `claude.exe` (the SDK wheel bundles x64 only), arm64 whisper, and an arm64 test host (none exists). Share is about 4-6% (unverified). | WS1, WS13 |
| **OD-W6** | Drawer UI technology | **DECIDED 2026-10-21: native Win32** (docked sibling panel, read-only RichEdit bubbles, an owned layered no-activate popup for the "S" icon, fold animation driven by `agent_drawer.zig`; see OWNER DECISIONS). NOT a second WebView2 and NOT WinUI/XAML Islands — those alternatives are not pursued. | Native: same structural isolation and native approval-card authority as Linux (GTK) and macOS (AppKit), reuses the portable Zig drawer logic; costs the most code (DPI, IME, accessibility by hand). **Second WebView2 with a local HTML drawer**: fast styling, free selection/IME/accessibility/CSS animation, but an extra renderer process, the drawer becomes a web context that renders model text and hosts the Approve button (needs strict CSP, text-only rendering, no remote navigation), and the floating icon still needs a native popup. WinUI 3 / XAML Islands: heavy runtime and MSVC-only toolchain. | WS5 |
| **OD-W7** | Minimum supported Windows | **Windows 10 22H2 (build 19045) and Windows 11 22H2+ (22621+), x64, Home and Pro.** | Older Windows 10 builds are out of support; Home lacks Hyper-V/Windows Sandbox (matters only for OD-W4 alternatives). | WS0 probe thresholds |
| **OD-W8** | WebView2 runtime distribution | **Evergreen bootstrapper** (current, ~2 MB) with a fail-closed launch-time check (WS1.4) and the **Evergreen standalone x64 installer** as a downloadable fallback. | Bootstrapper needs network at install. Standalone: offline, larger. Fixed Version: >250 MB, the app must update it, and Windows 10 needs `icacls` grants for the AppContainer SIDs. | WS13.2 |
| **OD-W9** | SSH key for the Windows hosts | **A new dedicated ed25519 key** (`/home/maceo/vms/win-hosts/zb_win_key`) for both Windows hosts, not the Mac key `zb_mac_key`. | A dedicated key can be revoked per host family without touching the Macs; reusing the Mac key is one less file but widens the blast radius. | WS0 |

### OWNER DECISIONS (2026-10-21)

- **OD-W1 — DECIDED: keep the per-user MSI** (WiX 3.14, already built and gated). WS13 installer work targets the MSI; no Velopack/MSIX rewrite.
- **OD-W3 — DECIDED: NO code signing for now.** Signing is **deferred**; agents hold no key and buy no certificate. **Nothing may claim "distributable" or "signed"** — WS13.6 (the signed/distributable claim) **stays OPEN** and is not a launch gate. WS13 may build and gate the UNSIGNED per-user MSI; it just can't assert distributability. SmartScreen/unsigned warnings are expected and must not be hidden or claimed away.
- **OD-W6 — DECIDED: native Win32 drawer controls** (docked sibling panel, read-only RichEdit bubbles, an owned layered no-activate popup for the "S" icon, fold animation driven by `agent_drawer.zig`) — NOT a second WebView2 and NOT WinUI/XAML Islands. This unblocks WS5's green files; the reds and portable `agent_drawer.zig` logic are backend-agnostic.
- **OD-W4 — DECIDED (2026-10-21): "WSL2 now, own VM later."** The Windows launch agent sandbox is **WSL2**, and the dedicated-local-users / AppContainer paths are **DROPPED for launch**.
  - **WSL2 + our OWN minimal distro.** Our setup enables WSL with **ONE admin step** and imports our own minimal distro via `wsl --import` (**no Microsoft Store**). The distro's `wsl.conf` sets **automount OFF, interop OFF, `appendWindowsPath=false`**. We touch **no global `.wslconfig`**.
  - **Agent inside WSL2 under our existing Linux sandbox.** The Claude agent runs in the imported distro confined by our **existing Linux sandbox (bubblewrap + netd)** — reusing the Linux guarantees/tests rather than inventing Windows-host user/WFP isolation.
  - **Transport change (DRAFT PROPOSAL; observed in the discovery spike, not proven):** the browser↔agent link moves off AF_UNIX (which does not cross the WSL2 boundary) to **loopback TCP**; the **proposed** direction (agent listens in the distro, browser connects from Windows) is motivated by a discovery observation that a Windows→WSL connect reached an in-distro listener while a WSL→Windows connect did not — **not a causal firewall proof** (the reverse listener's readiness was not established). The auth (per-session token + nonce/HMAC) is a proposal too. See WS8 C1 (proposal/TBD).
  - **Fail-closed:** if virtualization or WSL is unavailable, **the agent stays OFF** and the app shows a **fixed explanation** (no silent fallback, no dedicated-users path).
  - **Later milestone (not launch):** our **own small VM** as the shared **Mac+Windows "VM containment mode"** (the MS6.5 stub) — a follow-up, not WS8.
  - **Windows 10 product scope (affd577 #8): Win10 ships BROWSER-ONLY, agent OFF.** The Windows 10 test
    box (and Win10 generally, where WSL2 is unsupported/NAT-only) ships the **browser with the agent
    drawer DISABLED** — no WSL, no agent, no sandbox, no sign-in-to-agent, no helper/chat/commit, no voice
    agent. The **browser-level** milestones (WS0-WS4: render, automation, config, cookies) still run and gate
    on both hosts; the **agent-level** milestones — **WS8 (sandbox), WS9 (egress), WS11 (helper/chat/commit),
    the WS12 agent-voice legs, and the WS13 agent/sandbox packaging census** — run and gate on **win11 only**.
    WS10 sign-in: the browser sign-in UI is both-hosts, but the agent OAuth/sandbox path is win11-only. On
    Win10 the drawer's "S" affordance shows the fixed agent-OFF explanation. The launch claim, UX, packaging
    census and downstream gates are reconciled to this split; no milestone requires the agent on Win10.
  - **Re-plan:** WS8 (sandbox) and WS9 (egress) are rewritten below for this model; WS11 stays blocked until WS8 (WSL2) passes.
  - **Observations from the discovery spike on win11-m8 (2026-10-21, owner installed WSL; DISCOVERY-ONLY `tests/windows/wsl_live_test.py`, standard-user `zbtext`; NOT a closure or security claim — see the WS8 observed/not-proven block + DRAFT-gate blockers):** (a) the owner's `wsl --install --no-distribution` DID need a reboot — the elevated setup must be reboot-resumable; (b) the later **shared utility VM** design remains TBD (a follow-up milestone); (c) transport **PROPOSAL** = loopback TCP with agent-listens/browser-connects (AF_UNIX does not cross; AF_VSOCK creatable by a standard user but needs host AF_HYPERV plumbing — rejected) — the direction is **UNPROVEN** (one reverse attempt failed without proving listener readiness; direction + direct-dial denial remain proposals pending reviewed live evidence); (d) WSL is now **installed** (3.0.3.0, kernel 6.18.54.1, default version 2); `wsl --import` + the full per-user distro lifecycle ran **with no admin**; automount-off and appendWindowsPath-false worked, interop-off is partial (binfmt handler must be hard-disabled at boot); two distros shared one utility VM + one net namespace; a per-run process-group kill left a co-tenant session alive while `wsl --terminate` is distro-wide. **Still owner-only/elevated:** the one-time feature-enable + reboot, and nested virtualization (a benign "not supported" notice prints; not needed).

### Decision sharpening (rev 2 review): costs, risks and what each choice commits us to

For the still-open items (OD-W2/W5/W7/W8/W9), the "Recommendation" column is the planner's lean, not a
decision, and the plan proceeds on it only where a slice can start without the answer. **OD-W1/W3/W4/W6
are already DECIDED (OWNER DECISIONS, 2026-10-21); their sharpening below is history, not a pending
choice.** For each item: what each option costs, what can go wrong, and what it locks in. "Early" means
work that must start before the milestone that needs the answer.

**OD-W1 Installer format** — **DECIDED 2026-10-21: the per-user MSI (see OWNER DECISIONS); the analysis below is history.** (touches WS8 uninstall, WS13.4, the voice plans' installer slot).
- *Per-user MSI (WiX 3.14).* Cost: none new; `build-msi.ps1`, `gate.ps1`, `msi_install_test.py` exist.
  Commits us to: WiX 3.14 (the last v3 release, no further updates), a 2 GB-per-cabinet ceiling
  (WS13.3; split cabs through `MediaTemplate` limits), and **no way to run an elevated action from a
  per-user package**: the `.wxs` has `InstallPrivileges="limited"` and `InstallScope="perUser"`, so the
  WS13.4 sandbox-user cleanup cannot be a deferred elevated custom action. It must be a ShellExecute
  `runas` of `zb-agent-sandbox-setup.exe --uninstall` from an immediate action, or an in-app
  "Remove agent sandbox" step the user runs before uninstalling; both leave a window where the uninstall
  is complete but the users and WFP filters survive (WS13.4's probe must cover that case). Risk: no updater.
- *Velopack EXE.* Cost: rewrite WS13.1-WS13.4 and every MSI assertion; keep a build path for the
  file census. Delta updates help a payload dominated by rarely-changing model files. Unverified: the
  SDK languages Velopack supports (C#, Rust, C++, JS) versus calling it from Zig, and its hook behaviour
  with an elevated step. Commits us to Velopack's install layout and update feed; switching later means a
  second migration for users already installed.
- *MSIX.* Cost: signing is mandatory even for the test hosts, so each host must trust a test
  certificate (a machine-wide certificate-store change, **needs the owner's OK on the Win10 box** under the
  confinement rules; the VM unless the owner agrees). Per-package file-system virtualization of AppData writes breaks the
  assumption in WS5-WS8 that the browser, the helper and the two sandbox users see the same real paths
  (profile, agent home, scratchpad); needs a spike before it can be chosen. Gains: built-in updates, a
  Store path. Commits us to full-trust packaging and to the App Installer constraints.
- *Inno/NSIS.* A lateral move from MSI: costs a rewrite of WS13 for no capability this plan needs.

**OD-W2 Auto-update** (WS13.5; an update must re-apply the sandbox ACLs).
- *WinSparkle after launch, notice only at 1.0.* Until it ships, a security fix reaches users only if they
  reinstall; the 0.8 GB model makes a full reinstall heavy. Costs a DLL, an appcast host and an **Ed25519
  private key the user must custody** (loss strands installed users; theft allows a malicious update, so
  the key must sit apart from the Authenticode identity). It checks and downloads only, so the MSI/EXE
  silent-install flow and its elevation (see OD-W1) are still ours.
- *Velopack / MSIX App Installer.* Updates come with the OD-W1 choice; the cost is the OD-W1 cost.
- *None.* Cheapest, riskiest for security patches.
- Cross-decision effect (add whichever is chosen): every update creates a new `dist-<n>` agent-home
  directory. Either the elevated setup grants the sandbox users an **inheritable ACE on the `agent home`
  parent once** (an update then needs no UAC), or every update needs a UAC prompt to re-grant. WS8.2 is
  written so the first is testable.

**OD-W3 Signing identity and who buys it** — **DECIDED 2026-10-21: DEFERRED, no signing for launch, not a
launch gate (see OWNER DECISIONS); the analysis below is retained only for if/when signing is later
adopted.** (WS13.6 and every "distributable" claim; **long lead time, so
start early**).
- *Azure Artifact Signing (about $9.99/month).* Identity validation can take 1-20 business days; open
  to individuals only in the US or Canada, otherwise an organization with a verifiable history; needs an
  Azure subscription; certificates are short-lived, so the RFC 3161 timestamp is mandatory; signing from
  Linux with jsign needs an **Azure access token on the Linux dev machine** (the private key stays in
  Microsoft's HSM, but the credential that can ask for signatures is still a secret: say who holds it and
  whether CI may). Publisher name shown to users is the validated legal name (an individual's name or a
  company), a brand decision.
- *OV certificate.* $150-500 a year; since the 2023 CA/Browser Forum rule the key must be on a hardware
  token or cloud HSM, so unattended signing from Linux needs the token attached to that machine or the
  vendor's cloud-signing API; PIN handling is a secret to place. Same SmartScreen reputation ramp.
- *EV.* Buys nothing for SmartScreen now; higher cost; still hardware-bound.
- Any option: SmartScreen warns until reputation accrues (weeks, hundreds of installs). Until one exists the
  build is "unverified development build" (stated in the plan). Smart App Control may block the unsigned
  build on a clean Windows 11 install; WS13.6 tests that on the VM only (SAC cannot be turned back on
  without a reset, so the VM snapshot matters).

**OD-W4 Sandbox technology** (blocks WS8, WS9, WS11 and the voice plans' `zb-speech` sandbox).
- *Dedicated local users + restricted token + job object + separate desktop + WFP (srt/Codex model).*
  Costs: one UAC prompt; two local accounts created on the user's machine (they can show on the sign-in
  screen unless hidden through the `SpecialAccounts\UserList` registry value, a second decision); stored
  passwords; antivirus heuristics that dislike a program creating users, installing WFP filters and calling
  `CreateProcessWithLogonW`, so signing and reputation matter; a dependency on the **Secondary Logon
  service** (`seclogon`), which hardened machines disable (unverified: whether a standard-user launcher can
  create a suspended process for another user and assign it to a job; the alternative `LogonUser` +
  `CreateProcessAsUser` needs privileges a standard user lacks). Domain-joined or managed PCs may override
  logon rights or firewall policy by Group Policy. Gains: native hooks, kernel-enforced network, the
  `OpenProcess` boundary between users. It commits us to owning a privileged installer component and an
  uninstall path for system state. On the Win10 box this would create local accounts and **machine-wide**
  filters, so it would need the owner's OK and the proofs in "Win10 test-box confinement requirements".
- *AppContainer/LPAC.* No new accounts. Unverified: Node/Bun `claude.exe` under AppContainer; the loopback
  exemption needed to reach netd; a hook that must run user tools cannot be in an AppContainer. Network
  isolation depends on capability SIDs and a loopback exemption that is per-package and machine-wide.
- *WSL2.* Reuses `LinuxBwrapBackend` and its tests and the token fd route. Costs: hardware virtualization
  (nested KVM on the VM, unverified; a physical Windows 10 machine must have it enabled in firmware, which we
  cannot assume for the Win10 box), a distro image to ship or download, NAT-only networking on Windows 10, a
  second filesystem view of the profile, and the user's hooks run as Linux programs (a behavior change from
  the Linux/macOS agents). Commits us to shipping and patching a Linux distro.
- *Restricted token only.* Cheapest and weakest; cannot meet WS8.1 or WS9.2.
- Whatever is chosen also has to give the voice plans a **no-network child** (WS8.7).

**OD-W4b Token channel if the inherited handle is ignored** (decided only if spike WS8.3 fails).
- *ACL'd credentials file readable only by `zb-agent`.* Narrower than env; a file that exists on disk
  during the session (crash leaves it; the launcher must delete on every exit path, the job's kill-on-close
  must trigger the delete from a watcher). Weaker than the Linux fd route. Security reviewers must accept it.
- *Environment variable.* Violates the project rule; the plan keeps it excluded.
- *Stay unlaunched until upstream honors a handle.* Zero risk, no Windows agent; blocks WS11 and the voice
  plans' reply features.

**OD-W4c Orphan sweeper** (decided only if WS8.5 shows an escape).
- *SYSTEM scheduled task or service.* A second privileged component that must be installed, updated,
  uninstalled and signed; a bug there is a privilege-escalation surface. Gains: killing escaped processes.
- *No sweeper.* Escaped processes survive the browser but stay network-blocked and token-less; they can
  still consume CPU and write to the scratchpad. The decision is whether that residual risk is acceptable.

**OD-W5 arm64 scope.**
- *x64 only.* Windows 11 on Arm runs x64 under Prism; Windows 10 on Arm cannot. Risk for the STT plan: its
  AVX2 baseline may not run under Prism on older Windows 11 builds (unverified: emulated AVX/AVX2 support
  depends on the Windows 11 version), so Arm users could be unable to dictate. Nothing to build or test now.
- *Native arm64 later.* Needs an arm64 test machine (none exists), an arm64 Python runtime, an arm64
  `claude.exe` (the SDK wheel bundles x64 only), arm64 whisper and ONNX Runtime, and a `-Dtarget` row in
  every gate. Doubling the Windows matrix is a launch-schedule cost, not just code.
- *Native arm64 at launch.* Blocks launch on hardware we do not have.

**OD-W6 Drawer technology** — **DECIDED 2026-10-21: native Win32 (see OWNER DECISIONS); the analysis below is history.** (sets WS5's green files; the reds and behaviors are backend-agnostic).
- *Native Win32.* Most code: DPI, IME, high-contrast, screen-reader names and keyboard navigation by hand
  (the project's Linux and macOS drawers are also native). Gains: structural isolation from any web
  context, the approval card has the same authority story on all three OSes, and `--e2e-protocol` rows are
  emitted directly. Risk: RichEdit and layered-window quirks (focus, z-order with a GPU-composited
  WebView2, DWM animation timing) that only the real-screen checks catch.
- *Second WebView2 drawer.* Fast to style, free selection/IME/accessibility, but: a separate user data
  folder is needed to keep it out of the page's renderer and profile (another browser process tree and
  memory), it renders model text in a web context that also hosts Approve (strict CSP, text-only rendering,
  no navigation, message-channel hygiene), observation for tests becomes DOM-based (a different census
  path than the other platforms), and the floating "S" icon is still a native popup.
- *WinUI 3 / XAML Islands.* Heavy runtime and toolchain; no advantage found here.

**OD-W7 Minimum supported Windows.**
- Choosing 19045 and 22621+ **claims** builds the two hosts may not cover: the test matrix is exactly one
  Windows 10 build (the physical machine) and one Windows 11 build (the VM). Every extra build is a claim
  without a test. Raising the floor shrinks the audience; lowering it adds untested promises (and Windows
  11 21H2/22000 is out of Microsoft servicing). Home versus Pro is tested only for the editions the hosts
  have. This decision also fixes the thresholds in the WS0 probe.

**OD-W8 WebView2 runtime distribution.**
- *Evergreen bootstrapper.* Needs network at install; failure is currently swallowed (`Return="ignore"`),
  so the install can complete without a runtime (WS13.2 changes that). Per-user versus per-machine runtime:
  the version value can live in `HKLM` (both views) or in `HKCU` for the installing user, so every probe and
  the WS1.4 check must read all three places that `tests/guest/setup.ps1` reads.
- *Evergreen standalone installer.* Works offline; adds roughly 170 MB (unverified) to the payload and to
  the 2 GB budget in WS13.3.
- *Fixed Version.* The app owns Chromium security updates; more than 250 MB; Windows 10 needs `icacls`
  grants for AppContainer SIDs. Highest control, highest maintenance.

**OD-W9 SSH key for the Windows hosts.**
- *One dedicated key for both hosts.* One file to protect, but a stolen key reaches both machines; on the
  Win10 box it lands in `zbtest`, a standard user confined to its own `zb` directory.
- *One key per host.* Independent revocation; two files, two `known_hosts` entries.
- *Unattended (no passphrase) versus agent-held.* The gate needs unattended runs; an unencrypted private
  key on disk is the cost. Either way restrict it in `authorized_keys` with `from="<linux tailnet IP>"` and
  `restrict` where Windows OpenSSH honors them (standard-user keys do; `administrators_authorized_keys`
  keys follow the same options but are a larger privilege), and pin host keys (WS0.8) instead of the Mac
  gate's `StrictHostKeyChecking=no`.

## Host provisioning (what the user sets up)

Agents never SSH to a host before the user finishes that host's list. Each item has a probe in
`tests/windows/host_probe.ps1` (WS0) so the gate can check it.

### Physical Windows 10 machine — `100.123.34.15` (legacy tailnet name `file-server-win-mac`), standard WRITABLE test box, run host

> **Rev 2.18 (owner ruling):** this is a standard Win10 box, NOT read-only and NOT a production file server. Release rule: RoseCat
> exact-commit approval PLUS an orchestrator release before any live run (same as the Win11 VM). All work is confined to
> `C:\Users\zbtest\zb`; ask the owner before any system-wide install or machine-wide change.

1. **Enable OpenSSH Server first** (port 22 refuses today): Settings → Apps → Optional
   features → OpenSSH Server, or elevated
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then
   `Set-Service sshd -StartupType Automatic` and `Start-Service sshd`. Restrict the inbound
   rule to Tailscale: `Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress 100.64.0.0/10`
   (do not expose SSH to the LAN). **Also, in `C:\ProgramData\ssh\sshd_config`
   (rev 2):** `ListenAddress 100.123.34.15` (the tailnet address only, so port 22 does not answer on
   `10.0.0.163`), `AllowUsers zbtest` (no other account can log in over SSH, including the owner's),
   `PasswordAuthentication no`, `PubkeyAuthentication yes`, `AllowTcpForwarding no`, `X11Forwarding no`,
   `PermitTunnel no`, `MaxAuthTries 3`; then `Restart-Service sshd`. Set the `OpenSSH-Server-In-TCP`
   rule's profile to `Private` only if the network is a private profile, and record the profile of the
   Tailscale interface. If a tailnet ACL exists, restrict `tcp:22` on this node to the Linux dev machine's
   tailnet IP. **Do not run `tests/guest/setup.ps1` on this machine** (it opens port 22 with no address
   scope and installs a toolchain).
2. **SSH key (OD-W9):** generate the dedicated key on Linux; put the public key in
   `C:\Users\zbtest\.ssh\authorized_keys` (owner-only ACL). Do not put it in
   `administrators_authorized_keys` (tests do not log in as an admin).
3. **Dedicated standard (non-admin) local user `zbtest`.** Every test runs as `zbtest`, only
   under `C:\Users\zbtest\zb\`. Tests never touch existing shares, other drives, other
   accounts or the owner's profile. This root policy is enforced by CONVENTION and review —
   the gate does NOT enforce it through a remote-path verdict fence (WS0.5: that fence was
   removed; a name-based check/use boundary cannot close the junction-swap TOCTOU). A future
   remote file operation needing junction safety uses the held-handle check-and-use milestone
   (Option B), not a path pre-check.
4. **Record, before installing anything:** edition (Home/Pro), build (`winver`; must be
   19045 per OD-W7), arch (x64), GPU vendor, ESU state, and **whether the WebView2 runtime is
   already present: read `pv` under `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` in **all three** places
   `tests/guest/setup.ps1` (`Get-WebView2RuntimeVersion`) reads: `HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\…`,
   `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\…` and, for `zbtest`, `HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\…`
   (rev 1 named only the WOW6432Node key; a per-user runtime would have been missed and WS0.2 would
   have failed a healthy host). Do not install the runtime by hand; the installer's bootstrapper is the
   tested path.
5. **Interactive session.** Before a gate window the user signs `zbtest` in on the console
   (fast user switching is fine) and leaves it **unlocked**; or enables Sysinternals
   Autologon for `zbtest` if the owner accepts that (it stores the password as an LSA
   secret, and it also logs `zbtest` in after every reboot, so prefer the manual
   sign-in). The gate fails closed when no active, unlocked `zbtest` console session exists. **The gate
   never switches users, unlocks, or signs in by itself** (WS0.7): if the owner is using the console,
   the run reports `NOT RUN: console session belongs to <user>` and exits nonzero, and the run is
   rescheduled with the owner.
6. **Stay awake during gate windows:** no sleep and display on while plugged in
   (`powercfg /change standby-timeout-ac 0`, `powercfg /change monitor-timeout-ac 0`); screen
   saver and "lock on resume" off for `zbtest`. Power settings are machine-wide, so agree the
   window with the machine's owner.
7. **Python 3.12+ x64 for `zbtest` only** (per-user install, no admin). No compiler.
8. **Defender:** record whether it quarantines the unsigned dev build. Do not add exclusions on
   the Win10 box unless the owner agrees.
9. **Admin presence only for:** steps 1-3, and the one WS8 UAC prompt (the user clicks it in
   person on the real screen).
10. **Later, for STT VS10/VS11:** a microphone, and "Let desktop apps access your microphone"
    on for `zbtest`.

### Win10 test-box confinement requirements (rev 2; reframed in rev 2.18; hard, fail-closed; physical Windows 10 box only)

Rev 2.18 (owner ruling): this is a standard writable Win10 test box, NOT a production file server and NOT read-only; these rules
are confinement hygiene, not a no-write rule. A test run stays inside `C:\Users\zbtest\zb` and must not read, write, slow down or
disconnect anything it does not own (any shares that happen to exist, other accounts, other drives). Every item is checked by `host_probe.ps1` or by WS0.7, and a failed check
stops the gate before any product test runs.

1. **One identity, one root.** Everything runs as the standard local user `zbtest` under
   `C:\Users\zbtest\zb\`. `zbtest` is **not** a member of Administrators, Backup Operators, Remote Desktop
   Users, Remote Management Users, Network Configuration Operators, or any group that appears in a share
   or NTFS ACL of a served path. The probe prints `whoami /groups` and the gate fails on an unexpected
   group. No gate step touches another account's profile, the owner's files, other drives or volumes
   (`D:\`, `E:\`, mapped drives, `\\server\share` paths), the Recycle Bin of another user, or `C:\ProgramData`
   outside the sshd configuration done once by the owner.
2. **Shares are read-only evidence, never a target.** The probe lists SMB shares (`Get-SmbShare`,
   `Get-SmbShareAccess`) and their root paths and records them in the gate log, then **evaluates**
   `zbtest`'s effective access to each root path from ACLs and group SIDs with no write attempt (a write
   canary on a share would itself be the damage). If `zbtest` has Modify, Write or Full on any served path,
   the gate fails with `file-server: zbtest can write to <path>` (as-built message text, a legacy label) and the owner must remove it (for example
   an explicit deny for `zbtest` on the shares, or removal of `Users`/`Authenticated Users` write access;
   changing those ACLs is the **owner's** decision, never the gate's). If `zbtest` can only read, the run
   proceeds but WS9.2 uses loopback and TEST-NET targets only and never a UNC path.
3. **Network boundary.** sshd listens on the tailnet address only (`ListenAddress`), allows only `zbtest`,
   accepts only keys (provisioning item 1). The gate opens no listener except loopback listeners inside the
   product's own tests. No test sends traffic to the LAN, to `10.0.0.0/8`, to an SMB peer or to any address
   except loopback, TEST-NET `192.0.2.1`, and the fake API fixtures on loopback.
4. **Machine-wide state is off limits unless the owner agrees in writing for that run.** This covers power
   settings (`powercfg`), Windows Update pause, Defender exclusions, the firewall (apart from provisioning
   item 1), SMB configuration, the certificate store, Group Policy, scheduled tasks outside
   `\zigBrowser-test\`, services, other users' sessions. The plan's earlier steps that change machine
   state are therefore **owner-gated items**: power settings (item 6), Autologon (item 5), the WS8 setup
   (creates two local users and persistent filters), and any benchmark that loads the CPU for more than a
   minute (STT `voice-bench`, VS10.3). Each is recorded with its revert command in
   the Linux-side gate log (not a repo file), and the gate prints the list at the end of the run.
5. **WS8 on the Win10 box would be the highest-risk step.** *(⚠️ HISTORICAL / NON-NORMATIVE, OD-W4 — see the
   scope banner: there is **no agent/WS8/WSL on the Windows 10 box**; Win10 ships
   browser-only with the agent OFF, and the dedicated-user/WFP machinery below is dropped. Retained only as
   history.)* Required before the first setup run there: (a) the
   elevated setup takes the **target user's SID as an argument and verifies it equals the signed-in console
   session's user** (a standard user's UAC prompt elevates a *different* admin account, whose profile must
   not receive the agent home, the DPAPI-protected passwords or the ACLs); (b) every WFP filter it installs
   carries an `FWPM_CONDITION_ALE_USER_ID` condition naming one of the two sandbox users, and a filter
   census (`netsh wfp show filters` or the WFP API) finds **zero** zigBrowser filters without that
   condition; (c) a before/after census shows the set of listening ports (445, 139, 135, 3389, 22) and the
   inbound firewall rules unchanged, and the SMB server service state unchanged; (d) `--uninstall` leaves
   no user, profile folder, filter, provider, sublayer or scheduled task behind (WS13.4's probe); (e) the
   sandbox users are denied interactive and network logon (`SeDenyInteractiveLogonRight`,
   `SeDenyNetworkLogonRight`) **only after a spike shows the launcher still works**, and are hidden from
   the sign-in screen (`SpecialAccounts\UserList`) so the owner never sees them.
6. **Resources.** The probe records free space on `C:`. The bar is **10 GB on the Win11 VM**
   (orchestrator decision 2026-10-20): the KVM host disk is ~97% full so the VM image cannot grow, and a
   zigBrowser build plus the WebView2 runtime fit comfortably in the VM's ~13 GB. On the **physical Win10
   box** the orchestrator real-FS check of 2026-10-20 read `C:` at ~0 GB free: that is a capacity PRECONDITION for every Win10
   product leg (the exe and `zb\runs\<id>\` artifacts need room), to be cleared with the owner (no system-wide change without
   asking). In `--probe-only` readiness mode `free_gb` is reported for visibility and not judged (as built); in the product-run
   mode (WS0.9) it is gate-enforced on Win10 like the VM, with the Win10 floor chosen by the owner.
   The gate keeps run artifacts
   under `zb\runs\<id>\`, deletes them at the end, and caps a run at 30 minutes of wall time; benchmarks
   (item 4) are scheduled with the owner. No test runs while another user is signed in on the console
   (WS0.7).
7. **Antivirus.** Record whether Defender quarantines the unsigned build; do **not** add exclusions on this
   machine without the owner (item 8). A quarantined binary is a failed gate, not a reason to loosen.
8. **Audit trail.** Every gate run writes a log on the Linux side with the host, user, session id, probe
   JSON, every remote command (not secrets) and the final cleanup census (processes owned by `zbtest`
   started by the gate, scheduled tasks under `\zigBrowser-test\`, files under `zb\runs\`). The owner can ask
   to see it.

### Windows 11 VM — `win11-m8`, reached at `127.0.0.1:2222`, build host + run host

**Verified live, read-only, 2026-10-19 (cc_4), as the test user over SSH:**
- **Test user is `zbtext`** (the account the user created; the name is kept exactly as typed). The gate
  takes the SSH user from `ZB_GUEST_USER` (as `tests/guest/ssh.sh` does) and never hard-codes it; the
  physical Windows 10 box uses `zbtest`. Key: `/home/maceo/vms/win11-m8/zb_win_key`
  (`IdentitiesOnly=yes`; pinned `known_hosts` at `/home/maceo/vms/win11-m8/known_hosts`). `zbtext` is a
  standard user (Medium integrity, only `BUILTIN\Users`; not an administrator).
- **OS:** Windows 11 **25H2, build 26200**; native arch **AMD64 / x64** (no WOW). Satisfies OD-W7's ≥22621.
- **WebView2 Evergreen runtime 155.0.4283.62** present, read from
  `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}\pv`
  (the non-WOW HKLM and HKCU keys are absent, as expected on x64 — the probe reads all three and takes
  the first present).
- **Python** `C:\Python314\python.exe` (3.14; `python3` resolves only to the WindowsApps stub).
- **Zig / MSVC not yet installed** (`setup.ps1`, item 4, not yet run; `where zig` is empty) — WS1 work.
- **Computer name is `linuxwin`** — so the Tailscale node "linuxwin" offline for 105 days is THIS VM with
  Tailscale stopped, not a separate old device.

**Session/lock detection constraint (feeds WS0.1 green).** As a standard user over SSH, WMI/CIM is
access-denied (`0x80041003`), `tasklist /v` for other sessions is denied, and `query`/`qwinsta`/`quser`
are **not present** on this image; the SSH logon is `NT AUTHORITY\NETWORK`, not the console session.
So `host_probe.ps1` cannot read `interactive_session`/`locked` from any CLI here — WS0.1 gets them from the
in-console `session_probe.ps1`, which determines the lock state from the **WTS session-lock flag**
(`WTSQuerySessionInformation(WTSSessionInfoEx)` -> `WTSINFOEX_LEVEL1.SessionFlags`: `WTS_SESSIONSTATE_LOCK(0)`
= locked, `WTS_SESSIONSTATE_UNLOCK(1)` = unlocked) with a LogonUI-in-console fallback, and it **fails closed**
— the only unlocked verdict is the flag explicitly reporting UNLOCK(1); any unknown/unreadable signal counts
as locked. The `input_desktop` name (`OpenInputDesktop`/`GetUserObjectInformation`) is a **diagnostic only**:
on the win11-m8 locked VM console it reads `Default`, so it is never trusted for the verdict. `interactive_session
= in_console AND NOT locked`. (It also reports `console_session_id`/`in_console` via `WTSGetActiveConsoleSessionId` +
`ProcessIdToSessionId`.) `console_user` is read network-safe by `host_probe.ps1` directly (WTSUserName).
`whoami /groups` works as a standard user and is the source for WS0.7's `groups`/SID checks.

**Session helper = externally-provisioned console task, gate pin-verifies + triggers (VM only).**
`session_probe.ps1` runs in the console session as a scheduled task provisioned EXTERNALLY on the VM (as
the test user, post-snapshot, by `tests/windows/provision_session_task.ps1`) — the gate does NOT create it.
**EXACT pinned task contract** (enforced by `tests/windows/verify_task.ps1`, the single source of truth the
gate prepends to its trigger; `host_live_test.py` tests it against crafted XML + real registered tasks):
- name `zb-session-probe`;
- exactly ONE action, an `Exec`, whose `Command` is the canonical `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
  (no bare name, no attacker path, no leaf trick) with NO `WorkingDirectory`, and whose `Arguments` are the
  exact tuple `-NoProfile -NonInteractive -ExecutionPolicy Bypass -File <staged session_probe.ps1>`;
- exactly ONE `Principal`; `Actions Context` equals its `id`; its `UserId` resolves to the test user's EXACT
  SID (no leaf/username fallback); `LogonType` is `InteractiveToken`; `RunLevel` is LeastPrivilege (absent =
  the Task Scheduler default, or explicit `LeastPrivilege`; `HighestAvailable` is rejected);
- `Settings/Enabled` absent (the enabled default — Task Scheduler omits it) or exactly `true`; explicit
  `false` or any malformed value is rejected;
- the staged `session_probe.ps1` SHA-256 equals the committed script's.
Any mismatch fails closed (`VERIFY=TASK_*` / `RESULT=TASK_*`). After a clean verify the gate writes a per-run
nonce to `%USERPROFILE%\zb\runs\session\nonce.txt`, runs the task, and awaits a `session.json` whose `nonce`
matches and whose `ts` is within the last 15 min and NOT in the future; `host_probe.ps1` trusts
`interactive_session`/`locked` only under that nonce+freshness correlation. In the as-built `--probe-only` mode the Win10 box runs no
helper (not_applicable); rev 2.18: the product-run mode (WS0.9) provisions the same pin-verified session task on the Win10 box
(owner-gated; no system-wide change without asking).

**Win10 `--probe-only` not_applicable fields (orchestrator real-FS check, 2026-10-20; as built).** In the readiness mode, verified as
`zbtest`: `root` (the probe does not create `C:\Users\zbtest\zb` — it is zero-write) and `free_gb` (C: read ~0 GB free) are
**not_applicable** and the readiness gate does not judge them (VM-only enforcement as built). Rev 2.18: the Win10 box is writable, so
the product-run mode (WS0.9) creates `zb` and enforces `root`/`free_gb`/`interactive_session` there like the VM; the ~0 GB reading is a
capacity precondition to clear with the owner. There is **no fixed listener baseline**: the real listeners are 135/445/5040/5357, dynamic
RPC 49664+, 139, 22 and high service ports with no 3389, so WS0.7 enforces only that the listener set is
UNCHANGED pre vs post. sshd `ListenAddress` is pinned to exactly the tailnet IP (100.123.34.15) and
`AllowUsers` to exactly `zbtest` (`LogLevel DEBUG3` is a known user to-do and is not gated).

1. Boot the VM (the user or orchestrator starts it; agents do not). If it is the existing
   `win11-m8` domain: `virsh -c qemu:///session start win11-m8`. (Read-only check on 2026-10-19: that
   domain was already `running`, so the gate must treat "state at gate time" as the only truth.)
2. Windows 11 x64 (Pro recommended), fully updated; record the build (≥22621 per OD-W7).
3. Tailscale installed and signed in **if the user wants the tailnet path**; record the address in
   `tests/windows/hosts.env`. The default local path is the libvirt passt forward on the Linux host:
   `ZB_WIN11_HOST=127.0.0.1`, `ZB_WIN11_PORT=2222` (the domain XML has `portForward 2222 -> 22`; the old
   Tailscale node `100.103.8.90` was offline for 105 days). See "How the gate reaches the Win11 VM".
4. Run `tests/guest/setup.ps1` elevated (OpenSSH Server, Zig 0.16.0, nuget + WebView2 SDK,
   MSVC Build Tools + Windows SDK). Also install WiX 3.14 at `C:\Users\maceo\WiX314` and
   Python 3.12+ x64.
5. SSH key: the same dedicated key in the test user's `authorized_keys` (if the test user is
   an admin, `C:\ProgramData\ssh\administrators_authorized_keys` with
   `icacls ... /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`).
6. Autologon (Sysinternals) for the test user, so a reboot returns to an unlocked desktop;
   lock screen, screen saver and sleep off; pause Windows Update during gate windows.
7. **Smart App Control off** (it blocks unsigned dev builds) — record the state; WS13 tests it
   separately.
8. A second local standard account `zbother` for cross-user negative tests (WS2.0, WS6).
9. 1920x1080 display in the SPICE console; the user views it with `virt-viewer` for real-screen
   checks.
10. Snapshot the VM after provisioning so a broken run can be rolled back (strategy below; none exists
    today).
11. Only if OD-W4 falls back to WSL2: nested virtualization (the host is AMD with
    `kvm_amd nested=1`; CPU mode is already host-passthrough) and the WSL features.
12. Optional, for STT VS10: the domain already defines an `ich9` sound device with a SPICE audio backend;
    whether Windows shows a capture endpoint and whether `virt-viewer` forwards a microphone is
    **unverified**. Until proven, VS10/VS11 on the VM use the WAV seam and `win-voice-live` is
    Windows 10 only.
13. **Identity marker (rev 2.2, WS0.6).** The user writes a random nonce to
    `C:\Users\<user>\zb\.gate-identity` (e.g. `[guid]::NewGuid().Guid`) and records the same value as
    `ZB_WIN11_MARKER` in the private `tests/windows/hosts.env` (never committed). The probe reads the file into
    `identity_marker`; the gate fails `wrong host` on any mismatch, missing or empty value. This replaces the
    SMBIOS-UUID identity check (unreadable by a standard user, bead zigBrowser-126). The same applies to the
    Windows 10 host via `ZB_WIN10_MARKER` and its own `.gate-identity`.

### How the gate reaches the Win11 VM, snapshot strategy, and how a down VM fails closed (rev 2)

**Reaching it.** The VM runs locally under `qemu:///session` (no root). The gate uses
`ZB_WIN11_HOST`/`ZB_WIN11_PORT` from `tests/windows/hosts.env`, default `127.0.0.1:2222` (the passt
forward), or the tailnet address if the user restored Tailscale in the guest. Host keys are pinned in
`tests/windows/known_hosts` (captured once by the user at provisioning, `StrictHostKeyChecking=yes`,
`UserKnownHostsFile` set to that file) because a loopback port can be answered by anything that binds it.
**Identity check (rev 2.2, bead zigBrowser-126):** the SMBIOS UUID cannot be used — a standard user cannot read
`Win32_ComputerSystemProduct.UUID` (WMI is Access-denied 0x80041003 for `zbtext`, `wmic` is absent, and the
registry exposes `ComputerHardwareId` but not the SMBIOS UUID; verified on win11-m8 2026-10-20). Identity is
instead proven by (a) the **pinned SSH host key** (`tests/windows/known_hosts`, unique to that VM's sshd — a
loopback port answered by something else presents a different key and fails `StrictHostKeyChecking=yes`), and
(b) a **provisioning marker nonce**: at provisioning the user writes a random nonce to
`C:\Users\<user>\zb\.gate-identity` and records the same value in `tests/windows/hosts.env` (`ZB_WIN11_MARKER`);
the probe prints `identity_marker` and the gate fails `wrong host` if it differs. `virsh` is read-only in the
gate (`domstate`, `snapshot-list`); **the gate never starts, stops, reverts or snapshots the VM** unless run
with an explicit `--vm-revert <name>` that only the orchestrator or the user passes.

**Down VM fails closed.** In order: (1) `virsh domstate` not `running` → `NOT RUN: Win11 VM <domain> is
<state>`; (2) the TCP connect to the SSH port fails or times out in 15 s → `NOT RUN: Win11 VM unreachable at
<host>:<port>`; (3) the host key differs → `FAIL: host key mismatch`; (4) the probe times out or returns a
bad JSON → `FAIL: probe`; (5) no active unlocked console session (the VM sits at the lock screen after a
reboot without Autologon) → `FAIL: no interactive session`. Every one exits nonzero and the run summary
says the gate is incomplete; a VM that is up but stuck mid-update is caught by (4) or (5). There is no
"skip the VM" flag; a Windows 10-only run is reported as `INCOMPLETE: both hosts are required` (exit 1),
exactly like the Mac gate's missing arm64 host.

**Snapshots (none exist today; spike first).** The domain is UEFI Secure Boot with a raw NVRAM file and a
`tpm-crb` swtpm, so a snapshot must keep disk, NVRAM and TPM state consistent; whether libvirt 11.3 can
take an internal snapshot of this configuration is **unverified**. The plan requires, in priority order:
(a) a shut-off, named snapshot **`zb-clean-provisioned`** taken by the user after provisioning items 1-9
(external `qcow2` overlay, or `qemu-img snapshot -c` on the shut-off disk plus copies of the NVRAM and swtpm
directories; the spike picks the working method and records it in the gate log); (b)
**`zb-clean-with-tools`** after the toolchain is verified, to avoid repeating the 30-60 minute MSVC install;
(c) `zb-pre-ws8` before the first sandbox setup, because WS8 creates users and filters that are painful to
remove if a run dies midway; (d) the snapshot names and creation dates are listed in the gate log; (e) after
any revert the probe must find the registry marker `HKLM\SOFTWARE\zigBrowserTest\Snapshot` equal to the
requested name (written by the user at snapshot time), else `FAIL: snapshot state unknown`. Reverts change
the guest clock, Tailscale/SSH state and Windows Update state, so the gate re-probes from scratch after one.

## Testing Strategy

- **Frameworks:** Zig `std.testing` for Zig units; Python (`unittest`-style scripts like the
  existing e2e) for real-binary e2e on Windows and for the Linux-side gate selftests;
  PowerShell for host probes and interactive-session launch; the Python SDK client over the
  AF_UNIX automation socket.
- **One runner:** `tests/windows/gate.sh` (new, driven from Linux, mirrors
  `tests/mac/gate.sh`). It builds on the VM, fetches the exe, pushes it to the hosts a run requires, runs each
  slice's tests on each such host, and exits nonzero on any failure. Never `DISPLAY`, never Xvfb.
  **Status at HEAD (C2): only `--probe-only` exists; the no-argument run exits 2 "not implemented". WS0.9 builds the
  product-run mode; until then use the real per-slice command in D.2.**
- **Fail-closed rules (WS0.2):** no host configured → `NOT RUN` + exit 1; host unreachable;
  wrong OS build or arch; no active unlocked interactive test session; missing WebView2
  runtime; test exit 77 (skip) → **fail**; a test that does not print `ASSERTS <n>` with
  `n > 0` → **fail**; a GUI test whose launched PID is not in the active console session →
  **fail**. **Rev 2.17 (C2, D.1): a registered live step run under a gate with no host configured FAILS, it never
  exits 0; `ZB_WIN_GATE` must exist and be honoured by every live step (today it exists nowhere); skipped rows are
  never counted as Windows rows.** Rev 2 adds: SSH host key not the pinned one; the Win11 VM's `identity_marker` not the configured
  `ZB_WIN11_MARKER` nonce (rev 2.2 — the SMBIOS UUID is unreadable by a standard user, bead zigBrowser-126);
  the Win11 VM not `running` per `virsh`; the console session owned by someone other than the
  test user; `zbtest` in a forbidden group, or able to write a served path on the Win10 box (WS0.7); a
  probe whose `schema` field is not the gate's expected version; remote output files left after the run;
  and `NOT RUN` messages that always include the sentence `no Windows host configured` when either host
  variable is unset (the TTS plan W1 and the STT plan VS10 already quote that sentence).
- **GUI on Windows:** launched only through the interactive scheduled-task runner
  (`slice2_common.run_windows_interactive_until`), which WS0.4 hardens with a session check, a
  visibility check, readiness rows instead of fixed sleeps, a hard time bound, and job-object
  cleanup.
- **Native input:** CDP `Input.dispatch*` inside WebView2 (the capability table's
  `cdp_input`), proven by a red-first trusted-event matrix on both hosts (WS2b) before the
  table is trusted. System-wide `SendInput` is used **only** by real-screen scripts, which first
  prove the zigBrowser window is foreground.
- **Network:** the fake Anthropic API is reached **through the production proxy** via the
  existing `--e2e-protocol` allowlist seam; bypassing the proxy turns the test red. Denial
  probes use TEST-NET `192.0.2.1` and loopback decoys, **never** the Win10 box's LAN or any
  SMB shares it exposes.
- **Secrets:** a disposable Credential Manager target name and a canary token in every test;
  never the user's real credential. Credential tests run inside the interactive session task
  (Credential Manager may not persist over an SSH network logon).
- **Chat observability:** `--e2e-protocol` native drawer census or capture, never a socket read.
- **Real-screen (UI slices):** each names its cases; the orchestrator runs them with the user on
  the VM console (Win11). **Rev 2.18 (C1/C14):** the Windows 10 monitor leg is RESTORED (the Win10 box is a writable test host and runs the browser; it is
  watched by the orchestrator with the user after the Win10 release), and `tests/manual/real_screen_check.py` is X11-only today — a
  Windows capture + foreground-proof backend is a required task before any `win-*` case can be scheduled. A UI slice
  is not approved until its cases pass on the Win11 console and the Win10 monitor.
- **Closure tests** are Tier-1 real-binary e2e. A slice is done only when its closure e2e was
  **observed to execute** with nonzero assertions on the Win11 VM AND on the Win10 box (each its own evidence line);
  a skip is UNCLOSED (D.1, D.4).

### What runs where

| Work | [L] Linux | [W11] VM | [W10] physical |
|---|---|---|---|
| Gate runner + selftests with fake hosts (WS0) | yes | — | — |
| Host probes (WS0) | — | yes | yes |
| `cross-check`, `ipc-test-win`, pure-Zig units (drawer geometry, protocol, grant, config seam) | yes | — | — |
| Python backend contract tests for the Windows backend's spec projection (WS8.0) | yes | — | — |
| Windows build (MSVC) | — | yes | — |
| PE import census of the built exe (WS1.1; a TRIPWIRE listing, rev 2.19: WS1.1 is closed only by running the exe) | yes (on the fetched exe) | — | — |
| Any real-binary e2e, GUI, socket, sandbox, network, secrets test | — | yes | yes |
| Real-screen checks | — | yes (console via virt-viewer) | yes (its monitor) |
| Signing (OD-W3 Artifact Signing via jsign) | **DEFERRED, not built for launch (OD-W3)** | — | — |

> Rev 2.18 (C1, owner ruling): the `[W10]` column is a full product-test column (the Win10 box is writable), subject to the Win10
> release rule; "Any real-binary e2e…" rows run on the Win11 VM AND the Win10 box. WSL2/agent rows are Win11 only (section A).

### Property register (rev 2.17, C18) — behaviors with real input domains

Each behavior below with a real input domain has a Property, or a reasoned skip. Red-first, unregistered until green,
with a mutant; [L] unless stated.

| Behavior | Property (kind) | Generated domain | Mutant that must flip it |
|---|---|---|---|
| WS3.3 cookie JSON | roundtrip: `set(c)` then `getAll` returns `c`; **unknown `sameSite` is REFUSED (-32602), never silently "unset"** | name/value/domain/path/expires/secure/httpOnly × `sameSite ∈ {Strict, Lax, None, absent, junk}` | map unknown `sameSite` to unset ⇒ red |
| WS4 grant fields | metamorphic: changing any ONE as-built grant field (window id, origin, url/`load_serial`, account/recipient) refuses; identical fields accept exactly once | one-field-at-a-time over generated values | drop one field from the check ⇒ red |
| WS2c window/popup ids | invariant: ids are unique, never reused after close, stable across recovery | generated open/close/recover sequences | reuse a freed id ⇒ red |
| WS7.1 pointer swap | model-based: a reader never sees a missing `current` while a writer swaps (in-distro POSIX `rename` property [L]; the Windows-side C3 current-pointer file via `MoveFileExW` as a VM row — see WS7) | interleavings of N readers × M swaps | delete-then-create ⇒ red |
| WS10.3 error codes | closed-map: every forced failure maps to exactly one of `{cli,timeout,cancelled,shape,protocol}`, equal to Linux | the five failure modes + junk frames | collapse `cancelled` into `cli` ⇒ red |
| WS13.3 payload sizes | invariant: the cabinet splitter keeps every cabinet `< 2^31` and the byte sum preserved | generated payload-size multisets incl. `2^31-1`, `2^31`, `2^31+1` | cap at `<=` instead of `<` ⇒ red |
| WS2.0 / WS1 / WS3.2 | existing properties or reasoned skips stand (fixed inputs, nothing to generate over) | — | — |

## Shared code with macOS and Linux — exact reuse points

> ⚠️ **HISTORICAL / NON-NORMATIVE rows (OD-W4 — see the scope banner).** The `WindowsSandboxUserBackend`,
> the host-side netd on a Windows `127.0.0.1` port, and the Windows WFP filters named in this table are the
> DROPPED dedicated-user model. Under OD-W4 the Windows agent sandbox is **WSL2** (`WslBackend`, DRAFT) with
> netd running **inside the distro** (WS9) — no `WindowsSandboxUserBackend`, no host-side Windows netd, no WFP.
> These rows are kept only as history pending the implementation-approved revision that will rewrite them.

| Shared piece | Where it lives | Windows use | Owner of the shared change |
|---|---|---|---|
| `SandboxBackend` protocol + `LaunchSpec` | `agent/host/zb_agent_host/sandbox.py:71-229` | *(HISTORICAL, OD-W4)* a dedicated-user `WindowsSandboxUserBackend` was proposed; the launch backend is now `WslBackend` (WSL2, DRAFT) implementing the same protocol | WS8 adds the class; protocol unchanged |
| Egress capability (backend supplies endpoint + policy) | macOS plan MS0/Shared sandbox backend contract (:408-448; egress pinned in MS6 :1115-1140; the plan header says rev 6 but its revision history now runs to rev 9, none of which changes this contract) | *(HISTORICAL, OD-W4: the host-netd-on-Windows + WFP shape below is dropped.)* Under WSL2, netd runs INSIDE the distro (WS9) as on Linux; there is no Windows-host netd and no WFP | Whichever of MS6/WS9 lands first adds **netd TCP-listener mode** (today netd binds only `AF_UNIX`, netd.py:470-471, and forks bwrap, :782-793); the Windows realization runs netd inside the distro |
| netd allowlist parser, SNI check, global-address vetting | `netd.py:107-179, 414-416` | Unchanged; only the listener transport and its own confinement differ | WS9 |
| App-side hook spawn (profiles do not nest) | macOS MS6 design: "Hooks spawned app-side, each in its own profile; stdio over `SCM_RIGHTS`" (macOS plan :1108). The plan does **not** yet name a `hook_broker.py` module or a `zb-hook-run` client protocol (`zb-hook-run` is only listed as an existing agent-home script, :1059) | Same idea: the Windows server spawns as `zb-hook`; stdio crosses as duplicated handles | Shared protocol module `agent/host/zb_agent_host/hook_broker.py` (new). **Open cross-plan item:** the macOS plan must adopt this module name and a transport-neutral frame format (fd passing vs handle duplication are the two transports) or this plan builds it first; flagged, not edited here |
| Drawer logic | `src/agent_drawer.zig` (geometry :14-82, gesture :27, fold :86-103, persistence :244-277) | Exports enabled for `.windows` (today `.linux` only at :338-358) | WS5 widens the gate; logic unchanged |
| Helper frames + validation | `src/agent_helper.zig:123-153`, `src/agent_protocol.zig` | Unchanged | — |
| Token shape | `src/agent_secrets.zig:14-19` | Unchanged; split the portable checks from the `std.os.linux` file store | WS6 |
| Approval grant contract | drawer plan D10 (:507-533), macOS MS4 | **As-built (rev 2.17, C7):** approval card, 120 s (`card_ttl_ms`), one-shot Approve, `WindowWant{origin,url,load_serial}`, flow `expect{url,recipient}`, −32015. The `sha256(tool,…,target_fp,…,normalized_args)` tuple is NOT in `src/` (WS4.0 decision) | Platform-neutral Zig; WS4 only runs it on Windows |
| Automation server/router/engine/queue/recover/flows | `src/automation_server.zig`, `src/automation/*` | Unchanged; new `PagePort` impl | — |
| Fallible backend-flag seam | macOS MS3.2 names `applyMacBackendFlag(flag, value) !void` in `src/webkit.zig` (macOS plan :886-912; not landed; a repo-wide search at HEAD finds neither that name nor `applyBackendFlag`) | Land as **one** `applyBackendFlag(os, flag, value) !void` in `src/webkit.zig` used by both | **Naming divergence:** the macOS plan fixes a macOS-only name with no `os` parameter. First of MS3/WS3 to land builds the shared function; the macOS plan's name becomes a thin alias or the plan is amended (flagged, not edited here) |
| Async-completion ownership contract + ABI-absence rule | macOS MS2 | Same rules: copied inputs, exactly once, no effect after abandon; an unsupported seam is absent at link time | — |
| Real-screen runner | `tests/manual/real_screen_check.py` | New Windows backend for capture + foreground proof | WS5 |
| Two-host fail-closed gate pattern | `tests/mac/gate.sh` | `tests/windows/gate.sh` copies its structure and its `|| return 1` discipline | WS0 |

---

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

---

## WS0: Test hosts + fail-closed two-host gate   [L] then [W]

**Goal.** A gate that cannot false-green, driven from Linux, that proves each host is the host it
claims to be — and that the **GUI host (the Win11 VM)** has an unlocked, active interactive session —
before any product test runs. (In the as-built `--probe-only` readiness mode the Win10 box is probed zero-write with no in-console helper, so its
interactive-session state is **`not_applicable`** there: it is pinned by its SSH host key and fenced as undisturbed instead.
Rev 2.18: the Win10 box is a writable test host, so the product-run mode (WS0.9) requires its unlocked `zbtest` console session
the same way as the VM; a Win10 product test fails closed without it.)

> **WS0 status at HEAD (rev 2.20; reconciled to the WS0 proof blocks; C2, C3, W7, W14): NOTHING IN WS0 IS CLOSED.**
> **PROVEN-PARTIAL** (driven selftests run the real gate against fake hosts; open items are in the proof blocks): WS0.1a (the
> driven half only), WS0.2 (readiness), WS0.3, WS0.6, WS0.7, as the `--probe-only` readiness gate (probe 992b124, review 012e1bc).
> **NOT BUILT:** WS0.1b (its only test, `host_live_test.py`, is in no `build.zig` step, so it is a draft, rule 2), WS0.1c, WS0.1d,
> **WS0.5 (the removed fence: a TRIPWIRE only today; its exercising proof, a driven refused-flag case in `gate_selftest.py`, is NOT BUILT)**,
> WS0.4 (runner hardening), WS0.6b, WS0.8 (transport hygiene), and WS0.9 (product-run mode). The full
> product gate is "not implemented" (`gate.sh:578-581`).

### Behavior WS0.1: the host probe reports identity and readiness
**Given** a provisioned host, **when** `host_probe.ps1` runs over SSH, **then** it prints one JSON
object: `os_build`, `edition`, `native_arch` (from `RuntimeInformation.OSArchitecture` — a managed
property needing no P/Invoke, so the zero-write Win10 probe needs no `Add-Type`; not
`PROCESSOR_ARCHITECTURE`, which a WOW shell can misreport), `test_user`, `interactive_session`
(the in-console helper's `in_console AND NOT locked`), `locked` (from the **WTS session-lock flag**
`WTSSessionInfoEx` -> `WTSINFOEX_LEVEL1.SessionFlags`, LOCK(0)/UNLOCK(1), with a LogonUI fallback and
**fail-closed** on unknown — the `input_desktop` name is diagnostic only), `webview2_pv` (read from the three registry places in provisioning item 4), `python`, `zig` (VM only),
`free_gb`, `root` (the allowed remote root), plus (rev 2) `schema` (an integer the gate pins), `identity_marker`
(rev 2.2: the provisioning nonce from `C:\Users\<user>\zb\.gate-identity`, replacing the unreadable SMBIOS UUID),
`console_user`, `groups`, `shares`, `zbtest_write_paths`, `listeners`, `fw_rules_hash`, `sshd_listen`
and `sshd_allowusers` (the physical host). **Snapshot readiness is NOT an in-VM probe field (rev 2.9):**
the gate proves it host-side with read-only `virsh` — the pinned expected clean baseline
(`ZB_WIN11_SNAPSHOT`, e.g. `zb-clean-provisioned`) must exist and have State `shutoff`; the physical
Win10 box has no VM snapshot and is `not_applicable`. The current pinned clean baseline is
**`pre-4dr-toolchain-2026-10-20`** (shut-off). **`console_user`** is read network-safe
(`WTSUserName`, via a zero-write Reflection.Emit P/Invoke — no `Add-Type`/CodeDOM temp files), so the
read-only probe emits it directly on both hosts; **`interactive_session`/`locked`** need the console's
WTS session-lock flag, so they come from the in-console session helper and are required on the VM only
(`not_applicable` for the Win10 box in the as-built `--probe-only` mode; enforced there in the product-run mode, WS0.9, rev 2.18).
**Deferred (WS0 records but does not gate on these):** `python` and `zig` (VM only) and `webview2_pv`
on the Win10 box are reported for visibility but NOT enforced by the WS0 `--probe-only` readiness gate — the toolchain is
proven by the build itself in a later WS; rev 2.18: the Win10 box DOES run the browser in its product legs, so the product-run mode
(WS0.9) also enforces `webview2_pv` there (open code task). `native_arch` and
`os_build` are gate-enforced on both hosts; `free_gb` and `root` are gate-enforced on the **VM only** in the
as-built `--probe-only` mode (not_applicable for the Win10 box there: the probe writes nothing; the product-run mode enforces them
on the Win10 box too, rev 2.18); the SSH fence (exact `ListenAddress` + `AllowUsers`) and the Win10 confinement fields remain
gate-enforced.

**Typed probe record (rev 2.17, C19).** The probe JSON is **parsed once into a typed record**, not checked field by
field. Each field has an explicit state `ok(value) | not_applicable | unknown` — today "not_applicable" is JSON `null`,
the same value as unknown or failed-to-read (`host_probe.ps1:196, 331-332`), so a failed read can masquerade as
"does not apply". `interactive_session` is **derived** (`in_console AND NOT locked`) in the parser, never stored beside
`locked` (`session_probe.ps1:142-143` stores both, so they can disagree). One shared JSON schema (pinned `schema`
integer) is used by the selftest and the gate; the 235-line field-by-field heredoc validation in `gate.sh:215-451` is
replaced by it. Red (unregistered until green): `assert parse(null_for_unknown).state == "unknown"` and
`assert parse(stored_interactive_session_true_but_locked_true)` is refused; mutant: parse `null` as `not_applicable`
on the VM ⇒ red.

### Behavior WS0.2: the gate fails closed
**Given** any of: `ZB_WIN10_HOST` or `ZB_WIN11_HOST` unset (rev 2.18, C1: BOTH `ZB_WIN10_HOST` and `ZB_WIN11_HOST` are required for the
`--probe-only` readiness run AND for the product-run mode of WS0.9, because the Win10 box is a writable test host); a host unreachable; build below OD-W7;
`native_arch` not `x64`; the **Win11 VM** without an active interactive session, or its session locked
(`not_applicable` for the Win10 box in the as-built `--probe-only` mode, pinned by its SSH host key; in product-run mode it needs an
active unlocked `zbtest` session too); `webview2_pv` empty
**on the Win11 VM (rev 2.17, W1: `gate.sh:265-266` enforces it on the VM only as built; rev 2.18: the Win10 box runs the browser, so the product-run mode also enforces it there, an open code task)**;
`test_user` not the configured user; a test exiting 77; a test printing no `ASSERTS <n>` or
`n == 0`, **when** the gate runs, **then** it exits nonzero naming the host and the reason; with
both hosts healthy and all tests passing, it exits 0.

### Behavior WS0.3: the gate never reaches the Linux display
**Given** the Linux driver has `DISPLAY=:0` in its environment, **when** the gate runs, **then**
every child it starts has no `DISPLAY`, `WAYLAND_DISPLAY` or `XAUTHORITY`, and it starts no X
server.

### Behavior WS0.4: interactive launches are real, bounded and clean
**Given** a GUI test, **when** it starts the browser through the scheduled-task runner, **then**
the runner confirms `ProcessIdToSessionId(pid) == WTSGetActiveConsoleSessionId()` and
`IsWindowVisible(main_window)` before any capture, waits on readiness rows (not a fixed sleep),
kills its job after at most 120 s, and deletes its scheduled task; the selftest proves a leftover
task or process fails the run.

**WS0.4 is OPEN at HEAD (rev 2.17; C3, W14).** `tests/e2e/slice2_common.py:492-593` (`run_windows_interactive_until`)
implements none of the following, cleanup results are ignored, the task runs `/rl highest`, and the runner takes any
caller `timeout_sec` (`:497`), so the "120 s" bound does not exist. The m8 tests still `return SKIP_EXIT`
(`m8_render_test.py:322-333`) and `ZB_WIN_GATE` exists nowhere. Required, each a red with a mutant, in this order:
1. `ProcessIdToSessionId(pid) == WTSGetActiveConsoleSessionId()` and `IsWindowVisible(main_window)` before any capture;
2. readiness rows instead of fixed sleeps;
3. a **hard bound of 120 s** the caller cannot raise (clamp, not trust `timeout_sec`) — mutant: pass `timeout_sec=600` ⇒ red;
4. job cleanup and `schtasks /delete` whose failures **fail the run** (no ignored results), `RunLevel` least privilege
   (not `/rl highest`) — mutant: ignore the delete rc ⇒ red;
5. the leftover-task/process selftest (`tasks_left == 0 and procs_left == 0`; a fake host with one leftover ⇒ gate rc != 0);
6. `ZB_WIN_GATE=1` makes a missing precondition exit 1, not 77 (also WS1.2).

### Behavior WS0.5: there is NO remote-path authorization fence (removed)
**Given** the gate, **when** it operates on remote paths, **then** it does so WITHOUT a name-based
remote-path authorization fence — there is no such boundary, because a name-only check/use design cannot
close the junction-swap time-of-use race (RoseCat security review of aebb07b/9dbad76/7ea3c95; bead
zigBrowser-q92). The reparse-resolving fence (`gate.sh --allowed-path` / `allowed_path` /
`resolve_path.sh`) and its live test have been **deleted**. No gate step consumes an authorization
verdict for a remote path, and the fence's absence is proven by EXERCISE (rev 2.19, rule 1): a driven case in `gate_selftest.py` runs the real `gate.sh --allowed-path <p>` and asserts a nonzero exit with an unknown-option message (mutant: re-add an `--allowed-path` branch to a scratch copy ⇒ the case is red). `gate_selftest.py::RemotePathFenceRemovedTests` (no `allowed_path`, no `--allowed-path`, no resolver files) checks that names and files are absent; it is a labelled TRIPWIRE only (rev 2.20, L3.1: **WS0.5 is a TRIPWIRE today; its exercising proof is the driven refused-flag case above, step `windows-gate-selftest`, and it is NOT BUILT**). The driven case is NOT BUILT yet.

**A lexical-only shape check remains** (rev 2.17, W8: it has no production caller and `gate.sh:69-103` carries test-only
log hooks `ZB_SELFTEST_RAN_LOG`/`ENV_LOG` — those hooks move into the selftest wrapper, D.6(d); it stays a diagnostic
only) as `gate.sh --fence-string`: pure string normalization (strict
sub-path of `C:\Users\<user>\zb`, no `..`, drive-absolute), with NO filesystem access, NO reparse
resolution, and therefore NO time-of-use race and NO authorization claim. It exists only as the WS0.3
display-scrub observation point and as a sanity diagnostic; nothing may use it to authorize access.

**Future work (its own milestone — "Option B"):** any remote file operation that must be safe against a
malicious junction MUST perform a single held-handle **check-and-use** in one remote operation — open
every path component with `FILE_FLAG_OPEN_REPARSE_POINT` and no `FILE_SHARE_DELETE`, keep the handles
open through the operation, deny on any reparse point or attribute read failure, and act ONLY through
the held final handle. It must NEVER do a name-based pre-check and then reuse the name.

### Behavior WS0.6: the Win11 VM is the VM it claims to be, and a down VM fails the gate
**Given** `ZB_WIN11_HOST`/`ZB_WIN11_PORT`/`ZB_WIN11_DOMAIN`, **when** the gate starts, **then** it checks, in
this order, `virsh` state `running`, TCP reachability within 15 s, the pinned host key, the probe JSON, and
that the probe's `identity_marker` equals the pinned `ZB_WIN11_MARKER` nonce (rev 2.2: the SMBIOS-UUID check is
dropped — a standard user cannot read it, bead zigBrowser-126); each failure exits nonzero with the exact messages
under "How the gate reaches the Win11 VM". The gate has no flag that starts, reverts or skips the VM.

### Behavior WS0.7: the Win10 test host stays confined and undisturbed
**Given** the Windows 10 host, **when** the probe runs, **then** it reports `groups` of `zbtest`,
`console_user`, `shares` (names + absolute root paths), `zbtest_write_paths` (served paths the real Win32
**AccessCheck** says `zbtest` can mutate), `listeners` (whatever set this host has — no fixed baseline; the
real FS has e.g. 135/445/5040/5357, dynamic RPC 49664+, 139, 22 and no 3389) and `fw_rules_hash`; the gate
fails if `groups` has a forbidden group, `zbtest_write_paths` is non-empty, `console_user` is not `zbtest`
(it never switches users), the sshd `ListenAddress`/`AllowUsers` are not exactly the pinned values, or
`listeners`/`fw_rules_hash`/`shares` differ between the pre-run and post-run probes (any difference means the
run changed the machine). `free_gb`/`root` are not_applicable here in the as-built `--probe-only` mode (the probe writes nothing); rev 2.18: the product-run mode enforces them on the Win10 box.

### Behavior WS0.8: transport hygiene
**Given** any remote copy, **when** the gate stages files, **then** it uses `mktemp -d` staging on Linux (never
a fixed `/tmp` name), `StrictHostKeyChecking=yes` against `tests/windows/known_hosts`, `BatchMode=yes`,
`ConnectTimeout=15`, tars **without** `2>/dev/null` and checks the tar exit status, includes every directory
the slice needs (`src build.zig build.zig.zon tests tools agent packaging docs/how-to-build.md` as the slice
requires, listed in one manifest file), and deletes the remote staging under `zb\runs\<id>\` at the end.

**WS0.8 is OPEN at HEAD (rev 2.17; W6, W7, W4).** Not done: there is no `mktemp -d` and no `zb\runs\<id>` dir
(`gate.sh:127` extracts into the fixed `zb` and nothing cleans it up); `tests/windows/known_hosts` is an empty template
and the gate defaults to `/home/maceo/vms/...`; `tests/guest/build-in-guest.sh` is still the old insecure builder
(`StrictHostKeyChecking=no` :14, `2>/dev/null` :23, fixed `/tmp` tar) and is **retired** (D.6(b)), not wrapped;
`build-on-windows.sh:109-112` hardcodes SDK paths instead of reading the probe; it reads `ZB_WIN_KEY` while the gate
reads `ZB_WIN11_KEY` (one name, `ZB_WIN11_KEY`); `tests/windows/hosts.env.example:30` says build 19041 where OD-W7
says 19045 (fix to 19045); the "INCOMPLETE: both hosts are required" message (rev 2.18: stays "INCOMPLETE: both hosts are required" — product-run needs the Win11 VM AND the
Win10 box) and the separate 15 s TCP step
of WS0.6 are not in `gate.sh`. Each is a red with a mutant (`StrictHostKeyChecking=no` ⇒ red; ignore tar rc ⇒ red;
fixed `zb` extract dir ⇒ red; unreachable port must fail within 15 s ⇒ red).

**WS0 mutant rule (rev 2.17, W17).** Every mutant named in WS0 is an **executable selftest case that flips a named
assertion**, not a comment: `gate_twohost_selftest.py` runs the production script with the mutation applied (a
patched copy in a scratch dir) and asserts the case fails. The Win10 `--probe-only` **zero-write guarantee** (a property of the probe, not of the host) is proven
by a behavioral case — a fake `ssh`/`powershell` transcript recorder that fails the run if the probe stream contains
any write verb (`Set-`, `New-`, `Add-Type`, `Out-File`, redirection) **and** the real read-only probe still passing — not
by a regex over source text alone (`gate_twohost_selftest.py:864-996` is a tripwire only, D.4).

### Behavior WS0.9 (NEW, rev 2.17; C2): the product-run mode with fail-on-skip
**Given** `gate.sh` is run with no argument (or `--product`), **when** the Win11 VM is healthy and every phase's live
tests are run, **then** it exits 0 only if every test exited 0, printed `ASSERTS <n>` with `n > 0`, and none exited 77
or was skipped; **given** any test exits 77, prints no `ASSERTS`, or the host variables are unset, **then** the gate
exits nonzero naming the test. It replaces today's exit 2 "two-host run not implemented yet" (`gate.sh:578-581`).
- 🔴 Red `tests/windows/gate_twohost_selftest.py` case `product_run_fails_on_skip`: a fake host whose test exits 77 ⇒
  `assert rc != 0 and "skipped" in err`; a fake test with no `ASSERTS` ⇒ `rc != 0`; unset `ZB_WIN11_HOST` ⇒ `rc != 0`
  and the sentence `no Windows host configured`. Mutants: treat 77 as pass ⇒ red; accept `ASSERTS 0` ⇒ red.
- 🔴 Red `tests/windows/live_step_skip_test.py` (rev 2.19, rule 7; REWRITTEN from a Python read of `build.zig`): run the real command of each of the eight live steps at `build.zig:294-334`
  and of the two drawer suites (`:3549, 3559`) with `ZB_WIN_GATE=1` and every host variable unset, and assert each exits NONZERO — never 0 (D.1).
  Mutant: restore a clean-skip in one step ⇒ that step exits 0 ⇒ red. (Reading `build.zig` to check that the steps exist is only a tripwire.)
- 🟢 Green: the product-run mode in `gate.sh` + `ZB_WIN_GATE` handling in the live steps. 🔵 Refactor: one phase list
  shared by `--probe-only`, `--product` and `--phase voice` (WS12.2). **Closure:** LEAF (gate infrastructure).

- **Property (WS0.5, LEXICAL only):** invariant on the pure string-shape check (`gate.sh
  --fence-string`) — for any generated path string (relative segments, `..`, UNC `\\server\share`,
  drive letters, mixed slashes, junction NAMES as plain strings), the lexical verdict is ALLOW only if
  the normalized form is a strict sub-path of the root. This is string normalization only (no filesystem
  access, no reparse resolution) and makes NO authorization claim; the reparse-resolving fence was
  removed. Cross-product generator vs. an independent oracle in the selftest.
- **Files touched:** `tests/windows/gate.sh` (new), `tests/windows/host_probe.ps1` (new),
  `tests/windows/hosts.env.example` (new), `tests/windows/build-on-windows.sh` (new; the
  generalized `build-in-guest.sh` with SDK paths read from the probe instead of hardcoded),
  `tests/windows/gate_selftest.py` (new, Linux), `tests/e2e/slice2_common.py`
  (`run_windows_interactive_until`: session/visibility checks, time bound, job cleanup),
  `tests/guest/build-in-guest.sh` (rev 2.17, W6: RETIRED per D.6(b), no longer "a thin wrapper").
- 🔴 **Red** `tests/windows/gate_selftest.py` [L]: runs `gate.sh` against a fake `ssh`/`virsh` on `PATH`
  that replay canned probe JSON. Failing assertion today:
  `assert proc.returncode != 0 and "NOT RUN: no Windows host configured" in proc.stderr and "ZB_WIN10_HOST" in proc.stderr`
  — red because `tests/windows/gate.sh` does not exist (`FileNotFoundError`). Each WS0.2 condition is
  one case; the "healthy" case asserts `returncode == 0` and that `ASSERTS` totals are > 0. Named
  assertions for the other behaviors (each case also has a **mutant** that must flip it, run before the
  green commit is accepted):
  - WS0.1 `assert set(json.loads(probe_out)) >= REQUIRED_KEYS and probe["schema"] == 2` — red: no
    `host_probe.ps1`. Mutant: drop `native_arch` from the script ⇒ the case fails. A second, **real-host**
    red (`tests/windows/host_probe_live.py`, runs only through the gate, unregistered until green) asserts
    `probe["native_arch"] == "x64"` from `RuntimeInformation.OSArchitecture` (the true OS architecture,
    which a WOW/x86 shell cannot misreport the way `PROCESSOR_ARCHITECTURE` can).
  - WS0.3 `assert not (set(child_env) & {"DISPLAY","WAYLAND_DISPLAY","XAUTHORITY"})` for every child the
    fake `ssh` records, with `DISPLAY=:0` exported to the driver. Mutant: remove `env -u` ⇒ red.
  - WS0.4 `assert selftest_cleanup["tasks_left"] == 0 and selftest_cleanup["procs_left"] == 0`, and the
    inverse case `assert gate_rc != 0` when the fake host reports one leftover task. Mutant: skip
    `schtasks /delete` ⇒ red.
  - WS0.5 (lexical only) `assert lexical(p) is False` for the generated bad path STRINGS plus
    `assert lexical(r"C:\Users\zbtest\zb\x") is True` via `--fence-string`. Mutant: normalize with a naive
    `startswith` (no `..` handling) ⇒ the property fails. There is no reparse/`allowed()` assertion — that
    fence was removed (a lexical string check cannot and does not claim to be an authorization boundary).
  - WS0.6 `assert rc != 0 and "Win11 VM win11-m8 is shut off" in err` (fake `virsh domstate`); the unreachable
    and host-key cases likewise; and three explicit **identity-marker** cases (rev 2.2, bead zigBrowser-126) —
    the probe's `identity_marker` **missing**, **empty**, or **different** from the pinned `ZB_WIN11_MARKER` each
    gives `rc != 0 and "wrong host" in err`, while the **healthy** fake carries `identity_marker == ZB_WIN11_MARKER`
    and passes. Mutant: treat a marker mismatch, or a missing/empty marker, as a warning or skip ⇒ red. (The
    SMBIOS-UUID case is removed — a standard user cannot read it.)
  - WS0.7 `assert rc != 0 and "zbtest can write to" in err` with a canned `zbtest_write_paths`, and the
    changed-listeners case. Mutant: compare only the pre-run probe ⇒ red.
  - WS0.8 `assert "StrictHostKeyChecking=yes" in recorded_ssh_argv and "2>/dev/null" not in tar_cmd`; a
    partial tar (fake `tar` exits 2) must fail the gate. Mutant: the Mac gate's `StrictHostKeyChecking=no` ⇒ red.
  The red file is **not** registered in `build.zig` (red commits stay outside gate-registered steps).
- 🟢 **Green:** the gate, the probe, the hardened runner; register `gate_selftest.py` as a
  `build.zig` step `windows-gate-selftest` in the green commit only. Also new:
  `tests/windows/known_hosts` (empty template with a `README` line; the user fills it), `tests/windows/stage_manifest.txt`.
- 🔵 **Refactor:** one `ssh_opts`/`scp_opts` pair and one `run_remote` with `|| return 1` on every
  step (the `set -e`-inside-`if` trap from `tests/mac/gate.sh`); one JSON schema for the probe
  shared by the selftest and the gate.
- **Closure:** LEAF (test infrastructure; no product behavior crosses a seam).

- **WS0.9-W10 (restored Win10 product-run leg, rev 2.18; NOT yet run):** own test: `gate_twohost_selftest.py` cases with a fake Win10 transcript
  assert that product-run mode (a) REQUIRES `ZB_WIN10_HOST` and exits nonzero naming the Win10 box when it is unset or unreachable,
  (b) enforces `root`, `free_gb`, `webview2_pv` and the unlocked `zbtest` console session on the Win10 box like the VM, and (c) keeps the
  work under `C:\Users\zbtest\zb\runs\<id>\`. Mutant: treat the Win10 box as `not_applicable` in product-run mode ⇒ red. Own evidence
  line: the Win10 live run's `ASSERTS n>0` output with its `identity_marker`, pasted in the commit message, only after the Win10
  release (RoseCat exact-commit approval + orchestrator release).

### WS0 proof blocks (rule 9, rev 2.19)

> These blocks override any looser proof wording above. A source regex or lexer over a script is a TRIPWIRE; the gate is proven by running it against fake and real hosts.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `gate_selftest.py` -> `windows-gate-selftest`; `gate_twohost_selftest.py` -> `windows-twohost-selftest`; `build_on_windows_selftest.py` -> `windows-build-selftest`. To register (WORK, each a draft until its step exists): `host_live_test.py` -> NEW step `windows-host-live` (in the `windows-live` aggregate, D.1; it is in NO `build.zig` step today); NEW `live_step_skip_test.py` -> NEW step `windows-live-step-skip` (in `zig build test`: it runs each live step's command hostless with `ZB_WIN_GATE=1`); NEW `e2e_protocol_contract_test.py` -> NEW step `windows-e2e-protocol-contract-live` (in `windows-live`). All new selftest CASES inside the two registered selftest files ride their existing steps.

- **WS0.1a — probe fields and fail-closed validation (readiness)** — status **PROVEN-PARTIAL**. (a) entry point: `tests/windows/gate.sh --probe-only` (streams `host_probe.ps1` to each host). (b) test and step: `tests/windows/gate_twohost_selftest.py` (step `windows-twohost-selftest`, in `zig build test`) runs the real gate script against a fake ssh/virsh; the live half in `tests/windows/host_live_test.py` is in NO `build.zig` step, so it is a draft (rule 2) and is NOT counted here (rev 2.20, G4.2); registering it as the NEW step `windows-host-live` (in `windows-live`) is WORK, not evidence. (c) mutant: drop `native_arch` from the script; compare only the pre-run probe (WS0.7). (d) platform run: Win11 VM and Win10 box `--probe-only` runs (probe 992b124, review 012e1bc), recorded by hand and counted only as the readiness record, not as a registered live half. Proof type: driven (the registered selftest). Readiness only. Product-run enforcement of `root`, `free_gb`, `webview2_pv` and the unlocked session on the Win10 box is WS0.9-W10 (NOT BUILT).
- **WS0.1b — lock verdict comes from the WTS session-lock flag** — status **NOT BUILT** (rev 2.20, G4.2: re-marked from PROVEN-PARTIAL; its only test is in no `build.zig` step, so it is a draft under rule 2 and is not proof). (a) entry point: `gate.sh --probe-only` -> the console task running `session_probe.ps1`. (b) test and step: `tests/windows/host_live_test.py` `LockedDesktopLive` (owner-gated, `ZB_EXPECT_LOCKED`) and `LockVerdictFixturesLive`; it is in NO `build.zig` step and NOT part of any automatic gate. WORK to do: register it as the NEW step `windows-host-live` (an owner-gated step inside the `windows-live` aggregate, D.1; the locked-console case needs the owner's opt-in `ZB_EXPECT_LOCKED`, and with it unset that case is reported as NOT RUN, never green). The recorded hand run below is history, not evidence. (c) mutant: trust the `OpenInputDesktop` name for the verdict: the locked-console run must go red (it read `Default` on the locked VM console, rev 2.12, 88852d9). (d) platform run: Win11 VM console deliberately locked, then unlocked (a hand run, 88852d9; not a registered run). Proof type: platform run by hand only (unregistered). REWRITTEN: the source tests `test_session_probe_lock_verdict_uses_wts_flag`, `test_session_probe_wts_flag_offset_is_16_not_12`, `test_acl_function_is_extractable_and_used`, `test_verify_task_fn_extractable_and_used` and `test_share_verdict_fn_and_emitted_fields` (class `WS0ZeroWrite`) are TRIPWIRES; the closing proof is the locked-console live run. Open: it is owner-gated, so no gate runs it.
- **WS0.1c — the Win10 `--probe-only` probe writes nothing (zero-write)** — status **NOT BUILT**. (a) entry point: `gate.sh --probe-only` against the Win10 host. (b) test and step: NEW case in `gate_twohost_selftest.py` (step `windows-twohost-selftest`) with a recording fake ssh/powershell that captures the exact stream sent to the Win10 box and fails on any write verb while the real probe still returns the full schema; plus a live before/after census of `C:\Users\zbtest` on the Win10 box (zero new files). (c) mutant: add `Out-File` to a scratch copy of `host_probe.ps1`: the recorder case must fail. (d) platform run: Win10 box, after its release. Proof type: tripwire-only today (a regex over `host_probe.ps1`). REWRITTEN + NOT BUILT: `WS0ZeroWrite.test_host_probe_is_zero_write_no_dynamic_compilation` and `gate_twohost_selftest.py:864-996` lex the script text. They stay as a labelled TRIPWIRE. The behavioral recorder case does not exist yet.
- **WS0.1d — typed probe record (ok / not_applicable / unknown)** — status **NOT BUILT**. (a) entry point: `gate.sh --probe-only` (the parser that replaces the heredoc validation at `gate.sh:215-451`). (b) test and step: NEW cases in `gate_twohost_selftest.py` (step `windows-twohost-selftest`): `parse(null_for_unknown).state == "unknown"`, a stored `interactive_session=true` with `locked=true` is refused. (c) mutant: parse JSON `null` as `not_applicable` on the VM. (d) platform run: the real probe JSON from the Win11 VM and the Win10 box must parse into the record. Proof type: none yet. Unregistered red; no typed record in `gate.sh` today (C19).
- **WS0.2 — the gate fails closed** — status **PROVEN-PARTIAL**. (a) entry point: `tests/windows/gate.sh` (readiness mode today; product-run mode is WS0.9). (b) test and step: `gate_twohost_selftest.py` and `gate_selftest.py` (steps `windows-twohost-selftest`, `windows-gate-selftest`). (c) mutant: treat exit 77 as pass; accept `ASSERTS 0` (product-run cases); soften a marker/host-key failure to a warning. (d) platform run: Win11 VM and Win10 box probes. Proof type: driven + platform run. Readiness cases are driven. The product-run cases (exit 77, no `ASSERTS`) are WS0.9 (NOT BUILT).
- **WS0.3 — the gate never reaches the Linux display** — status **PROVEN-PARTIAL**. (a) entry point: `tests/windows/gate.sh` with `DISPLAY=:0` exported to the driver. (b) test and step: `gate_twohost_selftest.py` `WS0TwoHostReds.test_no_display_var_reaches_any_child` (records the env of every child the fake ssh sees). (c) mutant: remove `env -u DISPLAY` from the gate: the recorded child env contains `DISPLAY` and the test fails. (d) platform run: none: the driver is Linux; the property is about the Linux driver's children. Proof type: driven (L). Open: no production-mutant run record was located in this audit; record it in the commit message (rule 3).
- **WS0.4 — interactive launches are real, bounded and clean** — status **NOT BUILT**. (a) entry point: any GUI test started through `slice2_common.run_windows_interactive_until` (`tests/e2e/slice2_common.py:492-593`). (b) test and step: NEW selftest cases (fake host with a leftover task or process) in `gate_selftest.py` (step `windows-gate-selftest`), plus live `m8_*` rows through the steps `windows-m8-render-live`, `windows-m8-reply-live`, `windows-m8-load-fail-live` (NEW, in `windows-live`, see WS1.2), per the six-item OPEN list in WS0.4. (c) mutant: pass `timeout_sec=600` (must be clamped to 120); ignore the `schtasks /delete` result; leave one task behind. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Runner is not hardened at HEAD (C3, W14).
- **WS0.5 — no remote-path authorization fence** — status **NOT BUILT**. (a) entry point: `gate.sh --allowed-path <p>` (must be refused) and `gate.sh --fence-string <p>` (lexical diagnostic). (b) test and step: NEW driven case in `gate_selftest.py` (step `windows-gate-selftest`): run the real script with the removed flag and assert nonzero with an unknown-option message; the existing lexical property over `--fence-string` is driven through the CLI. (c) mutant: re-add an `--allowed-path` branch to a scratch copy of `gate.sh`: the case must fail. (d) platform run: none: Linux-side script. Proof type: tripwire-only today (`RemotePathFenceRemovedTests` checks that names and files are absent). REWRITTEN + NOT BUILT: the absence-of-names pin is a TRIPWIRE; the driven refused-flag case is not written.
- **WS0.6 — the Win11 VM is the VM it claims to be; a down VM fails the gate** — status **PROVEN-PARTIAL**. (a) entry point: `gate.sh` (virsh state, pinned host key, `identity_marker` vs `ZB_WIN11_MARKER`). (b) test and step: `gate_twohost_selftest.py` class `WS06VmIdentity` (missing, empty and wrong marker; shut-off VM). (c) mutant: treat a marker mismatch, or a missing or empty marker, as a warning. (d) platform run: Win11 VM (pinned SSH host key plus provisioning marker). Proof type: driven + platform run. The 15 s TCP step is WS0.6b.
- **WS0.6b — unreachable VM port fails within 15 s** — status **NOT BUILT**. (a) entry point: `gate.sh` TCP reachability step. (b) test and step: NEW case in `gate_twohost_selftest.py` (step `windows-twohost-selftest`): a fake host that accepts no connection must make the gate exit nonzero inside 15 s. (c) mutant: remove the 15 s bound (the case then hangs to its own watchdog and fails). (d) platform run: Win11 VM (one real unreachable-port run). Proof type: none yet. Not in `gate.sh` (listed in the WS0.8 OPEN list).
- **WS0.7 — the Win10 test host stays confined and undisturbed** — status **PROVEN-PARTIAL**. (a) entry point: `gate.sh --probe-only` pre-run and post-run probes of the Win10 box. (b) test and step: `gate_twohost_selftest.py` classes `WS07FileServerFence` and `WS07ListenerPidChurn`. (c) mutant: compare only the pre-run probe; ignore a changed listener set. (d) platform run: Win10 box live probe, pre and post. Proof type: driven + platform run. Win10 product legs are open (WS0.9-W10).
- **WS0.8 — transport hygiene (staging, pinned host keys, tar status)** — status **NOT BUILT**. (a) entry point: `gate.sh` staging and `tests/windows/build-on-windows.sh`. (b) test and step: NEW cases in `gate_twohost_selftest.py` (step `windows-twohost-selftest`) and `build_on_windows_selftest.py` (step `windows-build-selftest`), plus one real staged run to the VM that must leave no `zb\runs\<id>` behind. (c) mutant: `StrictHostKeyChecking=no`; ignore the tar exit code; extract into the fixed `zb` directory. (d) platform run: Win11 VM staging run. Proof type: none yet. OPEN at HEAD (W4, W6, W7).
- **WS0.9 — product-run mode with fail-on-skip** — status **NOT BUILT**. (a) entry point: `tests/windows/gate.sh` with no argument or `--product`; and each registered live step run with `ZB_WIN_GATE=1`. (b) test and step: `gate_twohost_selftest.py` case `product_run_fails_on_skip` (step `windows-twohost-selftest`); NEW `tests/windows/live_step_skip_test.py` (NEW step `windows-live-step-skip`, in `zig build test`) runs every registered live step's real command with `ZB_WIN_GATE=1` and no host and asserts a nonzero exit. (c) mutant: treat 77 as pass; accept `ASSERTS 0`; restore a clean-skip in one live step. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. REWRITTEN + NOT BUILT: the old red read the `build.zig` manifest (a source check). It is now an exercised run of each step's command; reading `build.zig` is only a tripwire.
- **WS0.9-W10 — Win10 product-run leg** — status **NOT BUILT**. (a) entry point: `gate.sh` product-run mode against the Win10 box. (b) test and step: `gate_twohost_selftest.py` cases with a fake Win10 transcript (step `windows-twohost-selftest`), plus the live run. (c) mutant: treat the Win10 box as `not_applicable` in product-run mode. (d) platform run: Win10 box, after the Win10 release. Proof type: none yet. Not run.
- **D.3 — `--e2e-protocol` is a command-line-only flag; seams are inert without it** — status **NOT BUILT**. (a) entry point: launch the real exe with and without `--e2e-protocol`, and with each seam variable set in the environment. (b) test and step: NEW `tests/windows/e2e_protocol_contract_test.py` (unregistered until green; registers in the NEW step `windows-e2e-protocol-contract-live`, inside `windows-live`, in the green commit). (c) mutant: honour a seam from the environment; add an undeclared `ZIGBROWSER_*` seam; let a packaged flavor accept the flag. (d) platform run: Win11 VM (and the Win10 box). Proof type: none yet. REWRITTEN + NOT BUILT: for EVERY seam in the inventory the test launches the exe WITHOUT the flag and asserts the seam is inert (no seam row), then WITH the flag and asserts it takes effect. The inventory-equals-shim-source comparison is a TRIPWIRE only.

**Gate (WS0):** [L] `windows-gate-selftest` green; then [W] `gate.sh --probe-only` green on both
hosts after provisioning (the pre/post probe pair of WS0.7 included) — this is the **readiness-only** gate (PROVEN-PARTIAL, not a closure, rev 2.20); WS0
closure additionally needs WS0.1b, WS0.5 (driven case), WS0.4, WS0.8 and WS0.9 above. Not a UI slice, so no
real-screen case; but the first `--probe-only` run on each host is watched by the orchestrator once, to
confirm that the "interactive session" it reports is the one on the monitor (the only human check this
slice has).

---

## WS1: Native build that runs and renders on both hosts   [W11] build, [W] run, [U]

**Goal.** A reproducible MSVC build on the VM whose exe runs on both hosts in a real, visible
window, with honest exit codes and build info.

### Behavior WS1.1: the release exe is a clean x64 PE with a known import set
**Given** `build-on-windows.sh ReleaseSafe` on the VM, **when** the exe is fetched to Linux,
**then** the exe RUNS (rev 2.19, rules 1 and 4: `--version` and `--screenshot` exit 0 on a host recorded as having no VC++ redistributable; a host with that state is not yet recorded, so this is UNPROVEN) and, as a labelled TRIPWIRE only (a listing never proves behavior), `tests/windows/pe_census.py` [L] finds machine `0x8664`, subsystem GUI or console as
designed, and an import table within an allowlist (system DLLs + `api-ms-win-crt-*`; any
`vcruntime*.dll` or `msvcp*.dll` is a failure unless the installer ships it), and records the
pinned WebView2 SDK version.

### Behavior WS1.2: M8 render, reply channel and load-fail pass on the Win11 VM and on the Win10 box
> **Rev 2.17 (C3): WS1.2 is NOT STARTED and now PRECEDES WS2a** (it is the m8 harness every later e2e reuses, and it
> depends on WS0.4). Its status is "open", not "done with WS1".
**Given** the exe on each host, **when** the gate runs `m8_render_test.py`,
`m8_reply_channel_test.py`, `m8_load_fail_test.py` with `ZB_WIN_GATE=1`, **then** each prints
`PASS` and `ASSERTS n>0` on each host; with `ZB_WIN_GATE=1` a missing precondition exits 1, not 77.
- **WS1.2-W10 (restored Win10 leg, rev 2.18; NOT yet run):** own test: the same three `m8_*` tests run as `zbtest` against the Win10 box,
  with the exe staged under `C:\Users\zbtest\zb\runs\<id>\`. Mutant: skip the Win10 invocation ⇒ the gate's both-hosts check is red.
  Own evidence line: the Win10 host's `PASS` + `ASSERTS n>0` output with its `identity_marker`, recorded in the commit message,
  after the Win10 release; the Win11 result never stands in for it. If the WebView2 runtime is missing on the box, installing it is
  system-wide: ask the owner first.

### Behavior WS1.3: `--screenshot` produces a real PNG
**Given** a fixture URL, **when** `zigBrowser.exe <url> --screenshot out.png` runs, **then** the
PNG is written via `ICoreWebView2::CapturePreview`, is non-uniform, and the exit code is 0
(today: `ZB_EXIT_SNAPSHOT_FAILED`).

### Behavior WS1.4: a missing runtime fails with the documented code and message
**Given** `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` pointing at an empty directory (spike-first:
**unverified** that the loader honors it for `GetAvailableCoreWebView2BrowserVersionString`),
**when** the browser starts, **then** it exits `ZB_EXIT_RUNTIME_MISSING` (9) and prints
`zigBrowser: the Microsoft Edge WebView2 Runtime is not installed`. If the env seam does not
work, the test uses an e2e-only `--e2e-protocol` runtime-folder override and says so.

### Behavior WS1.5: build info reports what actually ran
**Given** the exe, **when** `--version` runs, **then** it prints the WebView2 runtime version,
the OS build and the **executing** architecture (from `IsWow64Process2`; `x86_64` natively;
`x86_64-on-arm64` if run under emulation). **Rev 2.20 (L3.2): the executing architecture is proven by RUNNING the exe** (`--version` output on the host, compared with the architecture the host reports for the process; mutant: report `PROCESSOR_ARCHITECTURE` ⇒ red). That `pe_census.py`'s listed machine matches is only a **TRIPWIRE** (a PE listing, rule 5) and is NOT part of this behavior's success condition. Status: see the WS1 proof blocks (the exercising proof is NOT BUILT / UNPROVEN until `ws1_run_test.py` is registered and run).

- **Property:** no property — fixed inputs (one exe, fixed fixtures), nothing to generate over.
- **Files touched:** `src/webview2_shim.cpp` (CapturePreview screenshot, runtime-missing message,
  version line arch/build), `tests/windows/pe_census.py` + `pe_census_selftest.py` (new), `tests/windows/gate.sh`
  (WS1 phase), `tests/e2e/m8_*.py` (honor `ZB_WIN_GATE=1` → fail instead of skip; print
  `ASSERTS`), `tests/windows/screenshot_live_test.py` (EXISTS; the real screenshot row, step `windows-screenshot-live`),
  `tests/e2e/win_runtime_missing_test.py` and `tests/e2e/win_version_test.py` (WORK to create: **neither file exists at HEAD**,
  rev 2.20, G4.3; the existing `tests/windows/ws1_run_test.py` is an unregistered draft that covers WS1.4/WS1.5 meanwhile),
  `tests/windows/build-on-windows.sh`.
- 🔴 Red `tests/windows/screenshot_live_test.py` [W] (rev 2.20, G4.3: this body had named `tests/e2e/win_screenshot_test.py`, which DOES NOT EXIST; the real file is `tests/windows/screenshot_live_test.py`): failing assertion
  `assert rc == 0, f"--screenshot exit {rc}"` (today 11 / `ZB_EXIT_SNAPSHOT_FAILED`) and
  `assert nonuniform(png)` (a stub that writes a blank PNG must fail). Mutant: write a 1x1 white PNG ⇒ red.
  The other WS1 reds (each with a mutant, run on both hosts before green):
  - WS1.1 `tests/windows/pe_census_selftest.py` [L] (rev 2.19: a TRIPWIRE-tool test over fixture PEs; it does not close WS1.1, see the WS1 proof blocks): `assert census(fixture_vcruntime_pe).verdict == "FAIL: vcruntime140.dll"`
    and `assert census(fixture_clean_pe).machine == 0x8664`. Mutant: an allowlist that matches by prefix
    `vc*` ⇒ the clean-but-for-`vcruntime` fixture passes ⇒ red.
  - WS1.2 `tests/windows/gate_selftest.py` case `m8_precondition_missing`: `assert rc == 1 and "ZB_WIN_GATE" in err`
    (today the m8 tests return `SKIP_EXIT` = 77: `slice2_common.py:20`, `m8_render_test.py:204-206, 322-333`).
    Mutant: leave `SKIP_EXIT` ⇒ red. Plus on both hosts `assert asserts_printed > 0` for each of the three m8 tests.
  - WS1.4 `tests/e2e/win_runtime_missing_test.py` (WORK to create; does not exist): `assert rc == 9 and "the Microsoft Edge WebView2 Runtime is not installed" in err`
    (today `zb_app_run` returns `ZB_EXIT_RUNTIME_MISSING` at webview2_shim.cpp:709 but **no source file prints
    that message**, so the message half is red; the exit-code half may already be green and the spike decides
    whether the env seam works). Mutant: print the message but exit 1 ⇒ red; exit 9 without the message ⇒ red.
  - WS1.5 `tests/e2e/win_version_test.py` (WORK to create; does not exist): `assert re.fullmatch(r"zigBrowser \(WebView2 [\d.]+; Windows 10\.0\.\d+; x86_64\)", out.strip())`
    (today `zigBrowser (WebView2 <ver>)`, webview2_shim.cpp:759-771) and `assert root_is_version_line(out)`.
    `src/root.zig:50-52` already accepts any non-empty suffix after `WebView2 `, so no `root.zig` change is
    needed, but the assertion pins it. Mutant: report `PROCESSOR_ARCHITECTURE` instead of `IsWow64Process2`
    and run the test from an x86 shell on the x64 host ⇒ red.
- 🟢 **Green:** CapturePreview into an `IStream` → PNG file; version line; message.
- 🔵 **Refactor:** one COM-callback helper used by every async WebView2 call (prepares WS2's
  async-completion contract); no duplicated UTF-8/UTF-16 conversions.
- **Real-screen check `win-render`** (orchestrator with the user): the fixture page is visible,
  sharp at 100% and 150% scaling, on the Windows 10 monitor and the VM console.
- **Closure:** LEAF per behavior (single process, single module, observed through the real exe).
- **Status and registration at HEAD (rev 2.20, reconciled to the WS1 proof blocks; W18):** the exe was built and run on the Win11 VM
  at 7463139, 8f36ee7, 6c771ff and dcd33ae, but those runs are NOT closure: **WS1.3 is PROVEN-PARTIAL; WS1.1 is UNPROVEN; WS1.4 and
  WS1.5 are NOT BUILT** (their test `ws1_run_test.py` is unregistered); WS1.2 is open. The exe-level tests `tests/windows/pe_census_test.py`,
  `png_census_test.py` and `ws1_run_test.py` are **unregistered and not in `gate.sh`** — register them as `gate.sh`
  WS1 phase rows (and in `build.zig` behind the `windows-live` aggregate, D.1; `ws1_run_test.py` -> NEW step `windows-ws1-run-live`) so a run actually executes them.
  `screenshot_diag_selftest.py` greps shim text: it is a tripwire only (D.4); the real row is `tests/windows/screenshot_live_test.py` (rev 2.20, G4.3).

### WS1 proof blocks (rule 9, rev 2.19)

> The PE import census is a listing and a TRIPWIRE. WS1 is proven by running the exe.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `screenshot_live_test.py` -> `windows-screenshot-live`; `png_census_selftest.py` -> `windows-png-census-selftest`; `pe_census_selftest.py` -> `windows-pe-census-selftest` (tripwire tool). To register (WORK; each is a draft until its step exists, and each is a member of the `windows-live` aggregate, D.1, failing on skip): `ws1_run_test.py` -> NEW step `windows-ws1-run-live` (covers WS1.1, WS1.4, WS1.5 until their own files exist); `m8_render_test.py` -> NEW step `windows-m8-render-live`; `m8_reply_channel_test.py` -> NEW step `windows-m8-reply-live`; `m8_load_fail_test.py` -> NEW step `windows-m8-load-fail-live`. WORK to create (files do not exist at HEAD, G4.3): `tests/e2e/win_runtime_missing_test.py`, `tests/e2e/win_version_test.py`; `tests/e2e/win_screenshot_test.py` is NOT a file to create: the real screenshot row is `tests/windows/screenshot_live_test.py`.

- **WS1.1 — the release exe has no hidden runtime dependency** — status **UNPROVEN**. (a) entry point: `zigBrowser.exe --version` and `--screenshot` from `build-on-windows.sh ReleaseSafe`. (b) test and step: `tests/windows/ws1_run_test.py` (UNREGISTERED draft; register as the NEW step `windows-ws1-run-live` in `windows-live` and in the `gate.sh` WS1 phase) run on a host recorded as having NO VC++ redistributable. (c) mutant: link the CRT dynamically in a scratch build: the exe fails to start on that host. (d) platform run: a host without the VC++ redistributable (Win10 box if it lacks it, or a VM snapshot): NOT RECORDED on either host. Proof type: tripwire-only today (PE import listing). REWRITTEN + UNPROVEN: the PE import census (`pe_census.py`, `pe_census_selftest.py`, `pe_census_test.py`) is a listing, so a TRIPWIRE (rule 5). Missing for the exercising proof: a host recorded without the redistributable. **Rule-9 fields incomplete: not ready for implementation.**
- **WS1.2 — M8 render, reply channel and load-fail on both hosts** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe` window start, IPC reply channel, load failure. (b) test and step: `tests/e2e/m8_render_test.py`, `m8_reply_channel_test.py`, `m8_load_fail_test.py`, run by a `gate.sh` WS1 phase and by the NEW steps `windows-m8-render-live`, `windows-m8-reply-live`, `windows-m8-load-fail-live` in `windows-live` (today they `return SKIP_EXIT`). (c) mutant: leave `SKIP_EXIT` in place; skip the Win10 invocation. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. NOT STARTED; precedes WS2a.
- **WS1.2-W10 — M8 tests on the Win10 box** — status **NOT BUILT**. (a) entry point: same three `m8_*` tests as `zbtest` on the Win10 box. (b) test and step: as WS1.2, exe staged under `C:\Users\zbtest\zb\runs\<id>\`. (c) mutant: skip the Win10 invocation: the both-hosts check goes red. (d) platform run: Win10 box, after the Win10 release. Proof type: none yet. Not run.
- **WS1.3 — `--screenshot` produces a real PNG** — status **PROVEN-PARTIAL**. (a) entry point: `zigBrowser.exe <url> --screenshot out.png`. (b) test and step: `tests/windows/screenshot_live_test.py` (step `windows-screenshot-live`, in `zig build test`, clean-skips hostless) plus `png_census.py` over the output (selftest step `windows-png-census-selftest`). (c) mutant: write a 1x1 white PNG (named; the run record was not located in this audit). (d) platform run: Win11 VM run at 8f36ee7; Win10 box not run. Proof type: driven + platform run. Open: fail-on-skip registration under the gate (D.1), a recorded production mutant, the Win10 leg. `screenshot_diag_selftest.py` greps shim text: TRIPWIRE.
- **WS1.4 — a missing runtime fails with exit 9 and the documented message** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe` start with `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` at an empty directory. (b) test and step: `tests/windows/ws1_run_test.py` (UNREGISTERED draft; NEW step `windows-ws1-run-live`, WORK; the plan-named `win_runtime_missing_test.py` does not exist and is WORK to create). (c) mutant: print the message but exit 1; exit 9 without the message. (d) platform run: Win11 VM; the env seam is itself an unverified spike. Proof type: none yet. RE-MARKED NOT BUILT: listed green (6c771ff) but the test is unregistered and not in `gate.sh`.
- **WS1.5 — build info reports what actually ran** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe --version`. (b) test and step: `tests/windows/ws1_run_test.py` (UNREGISTERED draft; NEW step `windows-ws1-run-live`, WORK; plan-named `win_version_test.py` does not exist and is WORK to create). (c) mutant: report `PROCESSOR_ARCHITECTURE` instead of `IsWow64Process2` and run from an x86 shell. (d) platform run: Win11 VM; Win10 box. Proof type: none yet. The architecture is proven by RUNNING `--version`; a `pe_census.py` machine match is a TRIPWIRE only (L3.2). RE-MARKED NOT BUILT: listed green (dcd33ae) but the test is unregistered and not in `gate.sh`.

**Gate (WS1):** [W] WS1.1-WS1.5 on the Win11 VM, plus the Win10 box for WS1.2-W10 (each its own evidence line) + `win-render`. Build guard, NOT a closing conjunct (rev 2.20, L3.3; the same label WS2.0 gives it): [L] `cross-check` unchanged is a symbol/compile check, a **TRIPWIRE / build guard** that may block a regression and never counts toward closing WS1 (rule 4, rule 5).

---

## WS2: WebView2 PagePort adapter + automation ABI (WS2.0, WS2a, WS2b, WS2c)   [W]

**Goal.** The full automation surface on Windows with the same client contract and per-window
FIFO semantics as Linux, proven by three production chains (the macOS plan's Closures A/B/C).

> **WS2 status at HEAD (rev 2.20, reconciled to the WS2 proof blocks; C4, C5): WS2.0 is PROVEN-PARTIAL on the Win11 VM (token-only mutant unrecorded, W19; Win10 leg WS2.0-W10 NOT BUILT), not closed; WS2a, WS2b, WS2c have ZERO code.** There is no
> `src/automation_wv2_port.zig`; `app.zig:626-627` wires the GTK ports (`supported = builtin.os.tag == .linux`,
> `automation_gtk_port.zig:22`), so every page, dom, input, dialog and window command returns -32011 on Windows. The
> shim defines 15 of the 73 ABI functions and none are WS2a-c's. Closures A, B and C have no e2e. **The next Windows
> work is the WS2a.0 and WS2b.1 spikes, then the WS2a port, then WS3.4 wiring** (section C, Dependency order).

### Design
- New `src/automation_wv2_port.zig` implements `PagePort` (gated `os.tag == .windows`), wired in
  `buildAutomationConfig` beside the GTK port.
- `webview2_shim.cpp` gains the `zb_automation_*`/`zb_native_*` functions. The UI-thread marshal
  is a `WM_APP` message posted to the host window + a bounded, deadline-guarded wait (the analog
  of `auto_queue_on_gtk`/`auto_job_wait`, webkit_shim.c:1692-1812). Async-completion ownership
  contract as macOS MS2: copied inputs, exactly-once completion, a generation guard so nothing
  dispatches after the waiter abandons.
- **Deadlines, in numbers (rev 2.17, W11).** The cookie marshal's deadline-guarded wait with CAS abandon exists
  (`webview2_shim.cpp:728-776`) but keeps one **unbounded** `WaitForSingleObject(job->done, INFINITE)` at `:769` (after
  the `left`-bounded wait at `:762`), and the WS2a.3 `waiter_grace` seam and its test do not exist. Required: every
  UI-thread marshal has a per-command deadline (**default 10 s, caller-lowerable, never unbounded**); the `page.health`
  responsiveness probe is bounded at **2 s** and never takes the window's FIFO; a late completion after abandon is
  bounded by a **`waiter_grace` of 250 ms** after which the shim frees its own copy; **no `INFINITE` wait remains in
  the marshal** (a completing job's answer is read under the job's own lock, not by waiting forever). Red: a source-free
  behavioral test that stalls the UI thread and asserts the socket answers `-32015`/timeout within `deadline + grace`
  (mutant: restore `INFINITE` ⇒ the test hangs ⇒ red at its own 30 s watchdog).
- **Private world:** the automation script must not run in the page's main world. WebView2 has
  no content-world API; the plan's route is CDP `Page.addScriptToEvaluateOnNewDocument` with
  `worldName` + `Runtime.evaluate` with that context id, through `CallDevToolsProtocolMethod`.
  This is a **spike first** (WS2a.0). If WebView2 refuses CDP isolated worlds, WS2a **stops**
  and the orchestrator brings the result to the user (main-world automation is a security
  regression and is not accepted silently).
- **Unsupported mechanism:** link-time absence (macOS MS2 rule). Debug seams are compiled only in
  the slice whose e2e drives them.

### ABI assignment (every `webkit_shim.h` export)

| Exports | Slice | Windows mechanism | Named test |
|---|---|---|---|
| `zb_app_run`, `zb_version_line`, `zb_run_screenshot` | WS1 | exist; screenshot real in WS1.3 | m8_*, `screenshot_live_test` (rev 2.20, G4.3: `win_screenshot_test` does not exist) |
| `zb_run_open`, `zb_window_new`, `zb_reload` | WS2a | host window + controller factory (drawer mount point for WS5) | `win_window_test` |
| `zb_main_invoke_sync`, `zb_automation_loop_mark`, `_run_generation`, `_window_id_at`, `_window_alive`, `_free`, `_set_script` | WS2a | `WM_APP` marshal; generation guard; CDP private world | `win_async_ownership_test`, `win_private_world_test` |
| `zb_automation_eval_json`, `_navigate`, `_navigate_guarded`, `_reload`, `_get_url`, `_get_title` | WS2a | CDP `Runtime.evaluate` in the private world; `Navigate`; `NavigationStarting` + `zb_policy_decide` | Closure A |
| `zb_native_scroll/_move/_pointer/_click/_key/_text` | WS2b | CDP `Input.dispatchMouseEvent/KeyEvent/insertText` + pointer cache | `win_trusted_input_matrix` |
| `zb_automation_list_dialogs`, `_respond_dialog` | WS2b | `ScriptDialogOpening` + `GetDeferral` (no modal loop) | `win_dialog_test` |
| `zb_screenshot_png` | WS2b | CDP `Page.captureScreenshot {captureBeyondViewport}` | `win_screenshot_full_test` |
| `zb_set_input_files` | WS2b | CDP `DOM.setFileInputFiles` + regular-file refusal | `win_input_files_test` |
| `zb_automation_list_windows`, `_close_window`, `_recover_windows` | WS2c | `NewWindowRequested` + deferral + new controller; `WindowCloseRequested`; `ProcessFailed` | Closures B, C |
| `zb_cookies_get_all/_add/_delete` | WS3 | `ICoreWebView2CookieManager` | `win_cookie_test` |
| `zb_app_set_profile_dir`, hw-policy / media-source set+get | WS3 | user data folder; `applyBackendFlag` | `win_profile_persist_test`, `win_config_flags_test` |
| `zb_app_set_agent_drawer`/`_get_agent_drawer`, `zb_drawer_debug_live_count` | WS5 | Win32 drawer | `win_drawer_test` |
| 27 `zb_automation_debug_*` test seams (header :364-424; the header declares 30 `_debug_` functions, the other three, `_hw_policy`, `_webkit_default_hw_policy`, `_media_source` at :97/:100/:131, ship with the WS3 flags) | the slice whose e2e drives each (as macOS table) | else absent at link time | per slice |

### WS2.0: the transport is local-only and owner-only   [W11]
**Live production evidence so far is the Win11 VM only (rev 2.10, a fact about which runs exist).** Rev 2.18 (owner ruling): the physical
Windows 10 machine is a standard WRITABLE test box, so the Win10 leg is RESTORED as **WS2.0-W10** below (own test, own evidence line;
not yet run).
**Given** the browser with `--automation-api`, **when** it starts, **then** exactly one AF_UNIX
listener exists at `%LOCALAPPDATA%\zigbrowser\zigbrowser-automation-<nonce>.sock` (no TCP), the
directory, socket and `<socket>.token` have a **protected DACL granting only the current user**
(no inherited ACEs), and from the `zbother` account (VM) connecting or reading the token fails.
- ~~First run the existing ADR-1 spike `automation-afunix-spike-win` on both hosts~~ (rev 2.7: the
  spike no longer compiles on Zig 0.16; superseded). **AF_UNIX is proven by the production e2e**
  `tests/e2e/win_transport_test.py` (the real browser binds and accepts on the Win11 VM, rev 2.10). It needs the
  **`win10_rs4` target floor** (build.zig `windowsAfUnixFloor`): below it std's `has_unix_sockets`
  is false. **If AF_UNIX fails on the Win11 VM OR on the Win10 box, stop and
  update ADR-1**: no silent TCP fallback. The Win10 run happens only under the Win10 release rule (RoseCat exact-commit approval +
  orchestrator release) and only inside `C:\Users\zbtest\zb`.
- Replace the POSIX-only `restrictSocketMode` (`chmod`, automation_server.zig:1513-1517) and the
  `0o600` sidecar mode (:1496-1511) with one platform seam `restrictToOwner(path)`
  (rev 2.6 fix: one handle, never the path twice; POSIX `0600`/`0700` through the opened descriptor;
  Windows `SetSecurityInfo` on a `FILE_FLAG_OPEN_REPARSE_POINT` handle with a protected DACL, see below);
  `automationSocketPath` uses `%LOCALAPPDATA%` on Windows (app.zig:453-460).
- 🔴 Red `tests/e2e/win_transport_test.py` (970969f): the directory, socket and token each read back a protected
  DACL with exactly the current user's ACE (rev 2.7: the pre-fix browser exited 7 before any token or socket,
  because std's AF_UNIX was off below the `win10_rs4` floor).
- Property: invariant — for generated nonces, `planSocketPath(.windows, base, n)` stays under
  `base\zigbrowser\` and below `UnixAddress.max_len` (extends automation_transport.zig:49-62) [L].
- **Host scope (rev 2.18, superseding rev 2.10 and rev 2's host difference):** WS2.0 has TWO live legs. **Win11 VM leg (run):** all live
  evidence so far, the cross-user negative included (`zbother`). **Win10 box leg, WS2.0-W10 (restored, NOT yet run):** see the next bullet.
  Mutant (the VM): leave the default
  inherited DACL from `%LOCALAPPDATA%` ⇒ the principals assertion is red (it contains `Administrators`/`SYSTEM`
  inherited ACEs). Rev 2.6 decided those are **not** acceptable; on the VM the base is hostile (Everyone, inheritable),
  and the unrestricted-directory and unrestricted-socket mutants both fail (f29e490).
  **Rev 2.17 (W19):** the **token-only mutant is NOT recorded** — only the full no-op `restrictToOwner` flips the
  cross-user test (89c166b). Required before WS2.0 is called fully mutant-proven: run and record the mutant that
  restricts the directory and socket but leaves the `<socket>.token` file with the inherited DACL (the zbother token read
  must then succeed ⇒ `win_transport_test.py` red), on the Win11 VM, with the run output in the commit message.
- **WS2.0-W10 (restored Win10 leg, rev 2.18; its OWN test and its OWN evidence line; NOT yet run).** Test: `tests/e2e/win_transport_test.py`
  run as `zbtest` against the Win10 box (the test selects its host from `ZB_WIN11_HOST`/`ZB_WIN11_USER` today, so pointing it at the Win10
  box needs a small host-selector generalization, an open task), with `LOCALAPPDATA` at a hostile base under `C:\Users\zbtest\zb\`
  that grants Everyone full control inheritably. It asserts, on Win10: exactly one AF_UNIX listener and no TCP; `acl_principals` of the
  directory, the socket and the token is exactly `{zbtest's SID}`, protected, with no inherited ACE; and a **different-integrity
  connect** (a Low-integrity token for `zbtest`) is refused. The cross-user negative from a second account is run on Win10 only if
  the owner approves creating that local account (a system-wide change); otherwise the different-integrity connect is the negative.
  Mutant (the Win10 box): leave the inherited `%LOCALAPPDATA%` DACL ⇒ the principals assertion is red. Own evidence line: the Win10
  run's output (host `identity_marker`, `ASSERTS n>0`, DACL read-back) in the commit message, after the Win10 release (RoseCat
  exact-commit approval + orchestrator release); the Win11 run is never accepted in its place. Windows 10 AF_UNIX stays UNVERIFIED
  until this leg runs.
- **Compile coverage (rev 2.7; replaces the rev 2 "compile check first"):** the `cross-check` step's
  x86_64-windows-gnu object is built at the shipped `win10_rs4` floor, so it compiles the automation server's
  start path, token and socket included. It is a build guard, not the WS2.0 red: the red is the production e2e
  `tests/e2e/win_transport_test.py` (970969f) plus the Linux-provable reds.

- **Rev 2.9 (2026-10-20; WS0-completion / Route A, RoseCat 6769).** Snapshot readiness moved from an
  in-VM `snapshot_marker` probe field to a host-side read-only `virsh` check in the gate: the pinned
  expected clean baseline (`ZB_WIN11_SNAPSHOT`) must exist and be `shutoff`; the gate never creates or
  reverts. `console_user` is read network-safe (WTSUserName) directly by the probe; `interactive_session`
  /`locked` come from the in-console session helper and are VM-only (`not_applicable` for the Win10 box in the
  as-built `--probe-only` mode). The WS0.1 field list and WS0.6 updated to match; the gate validates the full schema-2
  readiness fail-closed with a red per field (gate_twohost_selftest).
- **Rev 2.8 (2026-10-20; WS13.4 uninstall census, RoseCat 6731 / commit `2cc125c`).** The WS13.4 red
  observed only sandbox users, WFP filters and scheduled tasks, while the uninstall normative (§3 item
  (d)) requires **no user, profile folder, filter, provider, sublayer or scheduled task** behind. The
  red now censuses and asserts all six kinds, and adds a surviving-success mutant for the profile
  folder, the WFP provider and the WFP sublayer (each: report uninstall success while one survives ⇒ red).

- **Rev 2.6 (WS2.0 owner: BlueBeaver, the orchestrator 2026-10-20; VM and host tooling stay AzureRidge's; ~~wincontain and the Job Object~~ — rev 2.17, C12: `wincontain.py`/`wincontain_win32.py` are RETIRED per D.6(a), the Job Object model being dropped by OD-W4, so that ownership assignment is void).**
  - **The compile check is not the red.** ~~`restrictSocketMode`'s `std.c.chmod` and the token's `.fromMode(0o600)` compile for `x86_64-windows-gnu`~~ **Withdrawn in rev 2.7:** that "compile" proved nothing. Without the `win10_rs4` floor, `server.start` returns `AddressFamilyUnsupported` before `startSocket`, so the token and socket code was never analyzed for Windows. At the floor, `.fromMode` does not exist on Windows (fixed in f29e490). The red is behavioural (the VM e2e below), plus the Linux-provable reds; the cross-check object now uses the floor, so it reaches the server's start.
  - **One seam, `src/owner_only.zig`:** `restrictToOwner(path, kind)`, kind `file` or `dir`.
    - **One object, never the path twice (rev 2.6 fix, RoseCat 6607).** The check and the apply name the same object, so a leaf swapped for a symlink or a junction between them cannot redirect the change:
      - Linux: `open(O_PATH|O_NOFOLLOW)`, the type from `statx` on that descriptor, the `chmod` through `/proc/self/fd/<fd>` (the opened inode). Mode `0600` for a file or a socket, `0700` for a directory; a symlink is refused.
      - macOS and the BSDs: `open(O_NOFOLLOW)` + `fstat` + `fchmod` for a file or a directory. A socket cannot be opened there, so it is checked and chmod'ed by path: safe only under the caller invariant that every socket this restricts was just bound by this process in a directory only its owner can write.
      - Windows: `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT` (+ `FILE_FLAG_BACKUP_SEMANTICS`), the kind and reparse tag from that handle (`FileAttributeTagInfo`), then `SetSecurityInfo` on the same handle. Every reparse point is refused except `IO_REPARSE_TAG_AF_UNIX` for a file: on Windows an AF_UNIX socket is itself a reparse point.
      - The DACL: **protected**, exactly one allow ACE, full access, for the current user's SID (from the process token: `TokenUser`, `ConvertSidToStringSidW`). Nothing inherited, and no SYSTEM, Administrators, Everyone, Users or Authenticated Users: **this pins the rule's decision**, inherited `Administrators`/`SYSTEM` ACEs are *not* acceptable. On a directory the ACE is inheritable (`OICI`), so a socket or token created inside never exists with a looser DACL. Built as SDDL by the pure `ownerOnlySddl(buf, sid, kind)` (`D:P(A;;FA;;;<sid>)`, or `D:P(A;OICI;FA;;;<sid>)` for a directory) and turned into a DACL by `ConvertStringSecurityDescriptorToSecurityDescriptorW`. `validSid` admits only `S-1-` followed by two or more decimal fields, so no ACE can be smuggled in through the SID.
      - **The readback contract is semantic, not a spelling:** Windows reports its own `AI`/`AR` control flags (the VM read the directory back as `D:PAI(A;OICI;FA;;;<SID>)`), so a check requires `P`, allows only `AI`/`AR` beside it, and the one exact ACE.
      - A test-only hook, `owner_only.after_check` (compiled out of every other build), runs between the check and the apply, so the swap reds can replace the leaf there.
    - A C form, `int zb_restrict_to_owner(const wchar_t *path, int is_dir)`, for WS3.1's `<profile>\WebView2` (`zb_app_set_profile_dir`, BlackRobin).
  - **The socket's place:** `automation_transport.socketBaseDir(platform, xdg_runtime_dir, local_app_data)`. Windows uses `%LOCALAPPDATA%` only: missing or empty is `error.NoLocalAppData`, never a `/tmp` or `XDG_RUNTIME_DIR` fallback. Linux and macOS keep `XDG_RUNTIME_DIR`, else `/tmp`. `planSocketPath` returns `error.SocketPathTooLong` for a path the bind could not hold (`UnixAddress.max_len`), on every OS, instead of a path the bind would cut.
  - **Wiring:** on Windows the server creates `%LOCALAPPDATA%\zigbrowser\`, restricts it (`dir`) **before** it writes the token or binds the socket, then restricts the token and the socket (`file`) as well. On POSIX the token keeps its exclusive `0600` create, and the socket's `chmod` becomes `restrictToOwner(socket, .file)`.
  - **Reds:**
    - Linux, outside the gate until the green registers them: `tests/owner_only_test.zig` (the swap reds: the leaf replaced by a symlink after the check, so the checked file or directory is restricted and the victim keeps its mode; the exact SDDL; no other principal; malformed SIDs, including ones that try to inject an ACE, are refused; a too-small buffer is an error, never a cut DACL; POSIX file `0600`, directory `0700`, a symlink refused with its target untouched, the wrong kind or a missing path refused) and `tests/automation_transport_ws20_test.zig` (the `planSocketPath` property over 1000 generated nonces plus 0 and the maximum; a too-long base is `SocketPathTooLong` on Windows and Linux; `socketBaseDir` on all three OSes).
    - VM: `tests/e2e/win_transport_test.py`, as `zbtext` through `build-on-windows.sh`:
      0. `build-on-windows.sh owner-only-test-win` (Windows builds only, no display guard): the DACLs read back from the file system, a junction refused with its target untouched, a leaf swapped for a junction after the check never redirecting the DACL, and a real AF_UNIX socket accepted and made owner-only. This is the seam on synthetic paths; it is **partial** (RoseCat 6607 #3), and `win_transport_test.py` must drive the production call sites;
      1. ~~the ADR-1 spike first~~ (rev 2.7: superseded; it no longer compiles on Zig 0.16). The browser runs with LOCALAPPDATA at a hostile base under `C:\Users\zbtext\zb\` that grants Everyone full control inheritably, so a missing restriction cannot hide; the red was HEAD caf51b5 exiting 7 before any token or socket (970969f);
      2. then the browser with `--automation-api`: exactly one AF_UNIX listener, no TCP;
      3. `acl_principals` of the directory, the socket and the token is exactly `{zbtext's SID}`, protected, with no inherited ACE;
      4. from `zbother`, the connection and the token read both fail.
    - On the physical Windows 10 box: the DACL assertion and a different-integrity connect (rev 2); rev 2.18 restores this as the
      separate leg **WS2.0-W10** above, with its own test and evidence line.
    - Mutant (the VM): leave the inherited `%LOCALAPPDATA%` DACL, and the principals assertion fails.

### WS2a: routed commands, private world, readiness   [W]
- **WS2a.0 (spike, Win11 VM):** CDP isolated world exists, its globals are invisible to the page,
  and it survives navigation. Result recorded red→green before WS2a.1. **Rev 2.17 (C5): NOT RUN — no file and no
  result exist at HEAD.** The spike file is `tests/e2e/win_private_world_spike.py` (named in the WS2 register) and its
  recorded result lives in the commit message; until then no code may assert the answer (see WS2b.0).
- **WS2a.0-W10 (restored Win10 leg, rev 2.18; NOT yet run):** own test: the same `win_private_world_spike.py` run as `zbtest` on the Win10
  box (work under `C:\Users\zbtest\zb`), the three claims (world exists, globals invisible to the page, survives navigation) asserted
  there. Own evidence line: its red→green result with the Win10 `identity_marker` in its own commit-message line, after the Win10
  release; the Win11 result does not stand in for it.
- **WS2a.1** `page.navigate`, `page.url`, `page.title`, `page.evaluate` over the socket with the
  Linux envelope/auth/errors.
- **WS2a.2** `dom.*` run in the private world. **Property (metamorphic):** a page that defines
  `window.__zbAutomation`, overrides `Element.prototype.click`, or freezes `document.querySelector`
  yields the same `dom.*` results as a clean page.
- **WS2a.3** late completion after a timeout is dropped by the generation guard; returned strings
  are freed only with `zb_automation_free`; an immediate quit wakes waiters and cancels queued
  jobs (`loop_mark`).
- 🔴 Red `tests/e2e/win_routed_test.py`: `assert rpc("page.evaluate", {"expression":"1+1"})["result"] == 2`
  (today `-32011` because `pagePort()` is null on Windows).

### WS2b: native input capability spike + dialogs + screenshots + files   [W], [U]
- **WS2b.0 (NEW, rev 2.17; C5) capability-table honesty.** `src/automation_platform.zig:79-82` already declares
  `.webview2 => input = .cdp_input, network = .supported` although neither spike (WS2a.0 isolated world, WS2b.1
  `isTrusted`) has ever run; the plan says that row may change only after WS2b.1 passes. Until then the row is a
  **PLACEHOLDER / UNPROVEN**: either change it to an `unproven` mode in the owner's slice, or keep it and have this plan
  and every WS2 gate treat it as unproven (no client or doc may rely on it). Red (unregistered until green):
  a driven Zig test that calls the production `adapterCapabilities(.webview2)` and asserts `input.mode == .unproven`, plus a Windows e2e that starts the real exe with `--automation-api` and asserts the `capabilities` RPC over the authenticated socket reports `unproven` for input until a WS2b.1 platform run exists (rev 2.19, REWRITTEN from a file-exists check, which is a tripwire); mutant:
  leave `cdp_input` with no recorded WS2b.1 result ⇒ both red. The flip to `cdp_input` is allowed only by a recorded WS2b.1 run on both hosts. The test `automation_platform.zig:885-886`
  (`expectEqual(InputMode.cdp_input, webview2.input.mode)`) is a fake-backed tripwire only (D.4), not evidence.
- **WS2b.1 (spike, Win11 VM) trusted-event matrix:** (**NOT RUN at HEAD — no file, no result**) `isTrusted` true, focus, click, key, text,
  contenteditable + `beforeinput` cancel honored, scroll, pointer move, navigation during input,
  partial typing, deadline abandonment (no dispatch after the waiter leaves). CDP input is
  **unverified** to produce `isTrusted: true` in WebView2; the capability table
  (automation_platform.zig:77-98) is changed only after this passes. If CDP input is not trusted,
  WS2b stops at the spike and the orchestrator brings it to the user (no silent fallback to
  `SendInput`, which is system-wide).
- **WS2b.1-W10 (restored Win10 leg, rev 2.18; NOT yet run):** own test: the same `win_trusted_input_matrix.py`, asserting
  `ack["isTrusted"] is True` per row, run as `zbtest` on the Win10 box (the Win10 WebView2 runtime can differ from the VM's, so its result
  can differ). Own evidence line: its per-row result with the Win10 `identity_marker` and the Win10 WebView2 `pv` in its own
  commit-message line, after the Win10 release. If CDP input is trusted on one host only, WS2b stops at the spike and the
  orchestrator brings it to the user.
- **WS2b.2** alert/confirm/prompt/beforeunload captured by `ScriptDialogOpening` with a held
  deferral, answered through the ABI.
- **WS2b.3** full-page `zb_screenshot_png`; **WS2b.4** input files with regular-file refusal.
- 🔴 Red `tests/e2e/win_trusted_input_matrix.py`: `assert ack["isTrusted"] is True` per row.
- **Real-screen check `win-native-click`:** a native click visibly actuates the fixture button on
  both screens.

### WS2c: multi-window, freeze, crash, recovery   [W]
- **WS2c.1** two-hop popup chain via `NewWindowRequested` (deferral + new controller in its own
  top-level window + `put_NewWindow`), each with its own `window_id`; per-window FIFO
  independence; opener survives `page.close` and script `window.close()` (`WindowCloseRequested`).
- **WS2c.2** a bounded responsiveness probe updates per-window health **without** taking that
  window's FIFO; `ProcessFailed` with `RENDER_PROCESS_UNRESPONSIVE` feeds it; a frozen window does
  not poison siblings; health/list snapshots are lock/atomic-backed and never block on the UI
  thread.
- **WS2c.3** recovery of a hung renderer through a named public mechanism, keeping two-phase
  consent, blast-radius acknowledgement, exactly-once cancellation and "recovering" errors
  (automation_server.zig:810-1106). Spike order: (1) close and recreate the controller in the same
  HWND, keeping the `window_id`; (2) `GetProcessInfos` + terminate only that renderer PID, then
  reload. **If neither recovers a hung renderer, WS2c.3 stops at a documented spike.**
- **WS2c.4 crash parity:** `ProcessFailed` (`RENDER_PROCESS_EXITED`) reports per-window
  termination, shows the static crash document, keeps the committed URL, excludes API-driven
  termination, clears `crashed` only on a real commit, never auto-reloads; controls: real-crash
  with no input (a 3-second auto-reload mutant must be killed) and clicked-Reload.
- **WS2c.5** every popup gets its own drawer slot bound to its `window_id`; one shared destroy path
  for `WindowCloseRequested`, the window's close button, and `page.close`, which detaches before
  the automation notification/free; live-drawer count zero after all windows close.

### WS2 red/green/mutant register (rev 2; fills the gaps in the sub-slices above)

Every test below is written first in an **unregistered** file, run red on both hosts (**except WS2.0, which is
[W11]: run on the Win11 VM only, rev 2.10**) (the red run is
recorded), registered in the green commit, and has a named mutant that must turn it red again before the
green commit is accepted.

| Behavior | Red test (unregistered until green) | Exact failing assertion (today's reason) | Mutant that must flip it | Green files |
|---|---|---|---|---|
| WS2.0 transport | `tests/e2e/win_transport_test.py` | protected owner-only DACL on the directory, socket and token; zbother denied (pre-fix: exit 7, no socket below the `win10_rs4` floor) | default inherited DACL (run on the Win11 VM; the restored WS2.0-W10 leg repeats it on the Win10 box with its own evidence line) | `automation_server.zig` `restrictToOwner`, `app.zig` socket base |
| WS2a.0 world spike | `tests/e2e/win_private_world_spike.py` | `assert page_eval("typeof window.__zbAutomation") == "undefined" and world_eval("typeof window.__zbAutomation") == "object"` (no CDP route exists) | run the script in the main world | `webview2_shim.cpp` CDP wrapper |
| WS2a.1 routed | `tests/e2e/win_routed_test.py` | `assert rpc("page.evaluate", {"expression":"1+1"})["result"] == 2` (-32011: `pagePort()` null) | return `0` from the shim | `automation_wv2_port.zig`, `app.zig` |
| WS2a.2 private world | `tests/e2e/win_private_world_test.py` | `assert rpc("dom.text", sel)["result"] == "real"` on a page that overrides `Element.prototype.click`, `document.querySelector`, defines `window.__zbAutomation` | evaluate in the main world | shim script install |
| WS2a.3 async ownership | `tests/e2e/win_async_ownership_test.py` | `assert late_result_dispatches == 0 and freed_strings == issued_strings` using the `zb_automation_debug_waiter_grace` seam compiled only here | drop the generation guard | shim marshal |
| WS2b.1 input matrix | `tests/e2e/win_trusted_input_matrix.py` | `assert ack["isTrusted"] is True` per row (no `zb_native_*` on Windows ⇒ -32011) | dispatch through `SendInput`-less synthetic `dispatchEvent` ⇒ `isTrusted` false | shim CDP `Input.dispatch*` |
| WS2b.2 dialogs | `tests/e2e/win_dialog_test.py` | `assert rpc("dialog.get")["result"][0]["type"] == "confirm"` then `respond` yields `true` in the page | auto-accept in the handler without the deferral | `ScriptDialogOpening` |
| WS2b.3 screenshot | `tests/e2e/win_screenshot_full_test.py` | `assert png_height(rpc("page.screenshot", {"fullPage": True})) > viewport_height` | omit `captureBeyondViewport` | shim CDP capture |
| WS2b.4 files | `tests/e2e/win_input_files_test.py` | `assert rpc("input.setFiles", {"paths":[dir_path]})["error"]["code"] == -32602` and a regular file arrives in the page's `input.files[0].name` | accept directories | shim `DOM.setFileInputFiles` |
| WS2c.1 popups | `tests/e2e/win_popup_chain_test.py` | `assert len(rpc("page.list")["result"]["pages"]) == 3 and ids_distinct` after a two-hop `window.open` | open popups in the opener's window | `NewWindowRequested` + controller factory |
| WS2c.2 / Closure B | `tests/e2e/win_health_sibling_test.py` | `assert health_latency_ms < 500` while window 1's command is stuck (queue turn held) | route `page.health` through the FIFO ⇒ times out | per-window state in shim |
| WS2c.3 / Closure C | `tests/e2e/win_recover_test.py` | `assert rpc("page.recover", wrong_token)["error"]["data"]["reason"] in {"unknown","mismatch"}` and, after consent, `assert rpc("page.url")["result"] == committed_url` | kill the renderer without consent | recreate-controller or `GetProcessInfos` |
| WS2c.4 crash | `tests/e2e/win_crash_parity_test.py` | `assert page_state["crashed"] is True and no_auto_reload_for_3s` | auto-reload after 3 s | `ProcessFailed` handler |
| WS2c.5 drawer slots | `tests/e2e/win_window_lifecycle_test.py` | `assert drawer_live_count == 0` after closing three windows by three paths | skip detach in one path | shared destroy path |

- **Refactor gate (WS2, as stated):** one marshal helper, one CDP wrapper with one error table; the port
  has no Windows types. Add: no `zb_automation_debug_*` is compiled outside the slice whose e2e drives it
  (rev 2.19, rule 5: `cross-check` and a link-time symbol listing are TRIPWIRES only; the closing proof is `win_abi_absence_test.py`, which starts the release-flavor exe without `--e2e-protocol` and drives every entry that would use a debug seam, asserting it is refused; mutant: expose an undriven debug seam ⇒ red).
- **Closure criteria:** Closures A, B, C below, each observed to execute with nonzero assertions on the Win11 VM
  (rev 2.18, C1: on the Win11 VM AND the Win10 box, each its own evidence line). Closure B and C now name their e2e files above.
  **At HEAD none of Closures A, B, C has an e2e (C4).**
- **Real-screen checks (UI parts of WS2):** `win-native-click` (WS2b, as written), plus **`win-popups`**
  (WS2c.1/WS2c.5: the orchestrator watches two popups open as real top-level windows, each closable by its
  close button, and the opener survives) and **`win-crash-page`** (WS2c.4: the static crash document is
  visible, and Reload recovers) on both screens.

### Workflow Closure (WS2: three chains, re-pinned from the research map)

#### Closure A — ordinary routed command   [BLOCKING: Zig→C++ boundary + async UI-thread edge]
- **Chain:** `socket -> handleRequestWith (automation_server.zig:412) -> router.parse -> queue.acquire -> engine.executeWith -> PagePort(automation_wv2_port) -> zb_automation_eval_json (WM_APP marshal) -> CDP Runtime.evaluate -> JSON-RPC result`
- **SOURCE:** a page loaded with `zb_automation_navigate_guarded`. **TRIGGER:** `handleRequestWith`
  (outermost; above `highest_new_connector = automation_wv2_port`). **DRIVER:** the Win32 message
  loop in `zb_app_run` (webview2_shim.cpp:696-703). **OBSERVE:** `zb_automation_eval_json`.
  **FORBIDDEN SPAN:** router, queue, engine, port, shim. **RED-AT-SEAM:** with the adapter absent,
  `pagePort()` is null and the DOM-change assertion is red. **DRIVABILITY:** the real binary's own
  loop drives the edge; no injected clock needed. **EXECUTION:** real exe on both hosts through
  the gate; missing host ⇒ exit nonzero.

```json
{
  "behavior": "An automation command sent over the local socket drives the live WebView2 page and its result is observable to the client.",
  "git_commit": "032a2c95e200db2e59d56147cb9c74afed50b727",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "loaded_page",         "module": "src/webview2_shim.cpp",        "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                      "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_request",      "module": "src/automation_server.zig",    "is_entrypoint": true,  "adds_or_changes": true,  "read_path": null,                      "seedable_store": null },
    { "id": "router_command",      "module": "src/automation/router.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                      "seedable_store": null },
    { "id": "engine_execute",      "module": "src/automation/engine.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                      "seedable_store": null },
    { "id": "pageport_call",       "module": "src/automation/page_port.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                      "seedable_store": null },
    { "id": "platform_adapter",    "module": "src/automation_wv2_port.zig",  "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                      "seedable_store": null },
    { "id": "native_shim_effect",  "module": "src/webview2_shim.cpp",        "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                      "seedable_store": null },
    { "id": "observable_readback", "module": "src/webview2_shim.cpp",        "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_eval_json", "seedable_store": null }
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

#### Closure B — `page.health`/`page.list` while a sibling's FIFO is stuck   [BLOCKING]
- **Chain:** `socket -> handleRequestWith -> handleWindows branch (automation_server.zig:480-487, no queue turn :686-691) -> responsiveness probe (WS2c.2) -> shim per-window state -> health JSON`
- **SOURCE:** two windows, a long command in flight on window 1. **TRIGGER:** `handleRequestWith`.
  **DRIVER:** the probe + `zb_app_run`. **OBSERVE:** `handleWindows` JSON for both windows.
  **RED-AT-SEAM:** implementing health behind the FIFO makes the sibling time out.

```json
{
  "behavior": "page.health/page.list answer for all WebView2 windows without waiting behind a sibling window's stuck FIFO.",
  "git_commit": "032a2c95e200db2e59d56147cb9c74afed50b727",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "two_windows_one_stuck", "module": "src/webview2_shim.cpp",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,            "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_health_request", "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,            "seedable_store": null },
    { "id": "handle_windows_branch", "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,            "seedable_store": null },
    { "id": "wv2_responsiveness",    "module": "src/webview2_shim.cpp",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,            "seedable_store": null },
    { "id": "health_json",           "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": "handleWindows", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

#### Closure C — two-phase recover of a hung window   [BLOCKING]
- **Chain:** `socket -> handleRecover (automation_server.zig:942-1106) -> incident token -> consume + beginRecovery -> recoverWindows -> shim recreate-controller or terminate-renderer + reload -> page.url read`
- **RED-AT-SEAM:** a wrong incident token or stale acknowledgement returns `unknown`/`mismatch`
  (automation_server.zig:872-902); an automatic kill without consent must be absent. Not green if
  WS2c.3 stops at a spike.

```json
{
  "behavior": "A hung WebView2 window is recovered only via two-phase consent, with exactly-once job cancellation and no automatic kill.",
  "git_commit": "032a2c95e200db2e59d56147cb9c74afed50b727",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "frozen_window",       "module": "src/webview2_shim.cpp",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                    "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_recover",      "module": "src/automation_server.zig", "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "recover_statemach",   "module": "src/automation_server.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "wv2_recreate_reload", "module": "src/webview2_shim.cpp",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                    "seedable_store": null },
    { "id": "post_recover_read",   "module": "src/webview2_shim.cpp",     "is_entrypoint": false, "adds_or_changes": true,  "read_path": "zb_automation_get_url", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_app_run" }
  ]
}
```

> `handleRequestWith`, `handleWindows`, `handleRecover` and `zb_app_run` resolve at the pin; the
> Windows `zb_automation_*` definitions and `automation_wv2_port.zig` are created by WS2, so a map
> evaluated before WS2 fails safe to BLOCKING. All three e2es start at the authenticated socket and
> read through production reads; none calls the port or shim directly.

- **Files touched (WS2):** `src/automation_wv2_port.zig` (new), `src/webview2_shim.cpp`,
  `src/webkit_shim.h` (no signature change), `src/app.zig` (`buildAutomationConfig` wiring;
  `%LOCALAPPDATA%` socket base), `src/automation_server.zig` (`restrictToOwner` seam),
  `src/automation_platform.zig` (capability flip after WS2b.1), `build.zig` (no new link libs
  expected), `tests/e2e/win_*_test.py` (new, named above).
- 🔵 **Refactor gate (each part):** one marshal helper for every shim entry point; one CDP call
  wrapper with one error-mapping table (the `mapCode` analog, automation_gtk_port.zig:337-350);
  the port contains no Windows types (only the C ABI).

### WS2 proof blocks (rule 9, rev 2.19)

> WS2.0 is the only WS2 behavior with a run; WS2a, WS2b and WS2c have zero code, so their rows are NOT BUILT or UNPROVEN until the port exists and the spikes have run.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `win_transport_test.py` -> `windows-transport-live`; `owner_only_test.zig` -> `test-owner-only`. Every file below is NEW (no file exists at HEAD) and registers in the green commit as a member of the `windows-live` aggregate (D.1), failing on skip, under its own NEW step: `win_private_world_spike.py` -> `windows-private-world-spike-live` (WS2a.0, WS2a.0-W10); `win_routed_test.py` -> `windows-routed-live` (WS2a.1, Closure A); `win_private_world_test.py` -> `windows-private-world-live` (WS2a.2); `win_async_ownership_test.py` -> `windows-async-ownership-live` (WS2a.3); the WS2b.0 Zig test -> NEW step `test-wv2-capabilities` (in `zig build test`) plus its e2e half -> `windows-capabilities-live`; `win_trusted_input_matrix.py` -> `windows-trusted-input-matrix-live` (WS2b.1, WS2b.1-W10); `win_dialog_test.py` -> `windows-dialog-live` (WS2b.2); `win_screenshot_full_test.py` -> `windows-screenshot-full-live` (WS2b.3); `win_input_files_test.py` -> `windows-input-files-live` (WS2b.4); `win_popup_chain_test.py` -> `windows-popup-chain-live` (WS2c.1); `win_health_sibling_test.py` -> `windows-health-sibling-live` (WS2c.2, Closure B); `win_recover_test.py` -> `windows-recover-live` (WS2c.3, Closure C); `win_crash_parity_test.py` -> `windows-crash-parity-live` (WS2c.4); `win_window_lifecycle_test.py` -> `windows-window-lifecycle-live` (WS2c.5); `win_abi_absence_test.py` -> `windows-abi-absence-live` (WS2.ABI). Until its step exists, each row's test is a draft (rule 2).

- **WS2.0 — transport is local-only and owner-only** — status **PROVEN-PARTIAL**. (a) entry point: `zigBrowser.exe --automation-api` start path (`restrictToOwner`, `%LOCALAPPDATA%` socket base). (b) test and step: `tests/e2e/win_transport_test.py` (step `windows-transport-live`, in `zig build test`, clean-skips hostless); Linux `tests/owner_only_test.zig` and `tests/automation_transport_ws20_test.zig` (registered, driven). (c) mutant: leave the inherited DACL (recorded); unrestricted directory and socket mutants (f29e490); the TOKEN-ONLY mutant is NOT recorded (W19). (d) platform run: Win11 VM, including the `zbother` cross-user negative (970969f, f29e490, 3cb8722). Proof type: driven + platform run. The `cross-check` compile of the Windows object is a build guard (compiles only, rule 4), not proof.
- **WS2.0-W10 — transport on the Win10 box** — status **NOT BUILT**. (a) entry point: same start path on the Win10 box as `zbtest`. (b) test and step: `tests/e2e/win_transport_test.py` with a host-selector generalization (open task). (c) mutant: leave the inherited `%LOCALAPPDATA%` DACL. (d) platform run: Win10 box, after the Win10 release. Proof type: none yet. Not run; Windows 10 AF_UNIX stays UNVERIFIED.
- **WS2a.0 — CDP isolated-world spike** — status **NOT BUILT**. (a) entry point: the WebView2 shim's CDP wrapper on the Win11 VM. (b) test and step: NEW `tests/e2e/win_private_world_spike.py` (no file at HEAD). (c) mutant: run the script in the main world: the page can then see the global. (d) platform run: Win11 VM. Proof type: none yet. NOT RUN (C5).
- **WS2a.0-W10 — isolated-world spike on the Win10 box** — status **NOT BUILT**. (a) entry point: same spike as `zbtest`. (b) test and step: `win_private_world_spike.py`. (c) mutant: run in the main world. (d) platform run: Win10 box, after the Win10 release. Proof type: none yet. Not run.
- **WS2a.1 — routed `page.*` commands over the socket** — status **NOT BUILT**. (a) entry point: the authenticated automation socket -> router -> `automation_wv2_port.zig` (does not exist). (b) test and step: NEW `tests/e2e/win_routed_test.py`. (c) mutant: return `0` from the shim. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code: `pagePort()` is the GTK port, so every command returns -32011.
- **WS2a.2 — `dom.*` runs in a private world** — status **UNPROVEN**. (a) entry point: `dom.*` RPC through the socket. (b) test and step: NEW `tests/e2e/win_private_world_test.py` (metamorphic page that overrides `Element.prototype.click`). (c) mutant: evaluate in the main world. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. UNPROVEN: the isolated-world mechanism has never been shown to exist in WebView2 (WS2a.0 not run). If it does not, WS2a stops.
- **WS2a.3 — async completion ownership and bounded waits** — status **NOT BUILT**. (a) entry point: a UI-thread marshal driven through any `zb_automation_*` call. (b) test and step: NEW `tests/e2e/win_async_ownership_test.py` using the `zb_automation_debug_waiter_grace` seam (compiled only here); a stalled-UI-thread test asserting `-32015` within deadline plus grace. (c) mutant: drop the generation guard; restore the `INFINITE` wait (`webview2_shim.cpp:769`): the test hangs to its watchdog. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. The seam and the test do not exist.
- **WS2b.0 — capability table honesty (`cdp_input` placeholder)** — status **UNPROVEN**. (a) entry point: the production `adapterCapabilities(.webview2)` and the `capabilities` RPC over the real socket. (b) test and step: NEW driven Zig test plus a Windows e2e on the real exe (see the in-place rewrite in WS2b.0). (c) mutant: leave `cdp_input` with no recorded WS2b.1 result: both fail. (d) platform run: Win11 VM (the RPC half). Proof type: tripwire-only today (`automation_platform.zig:885-886` is fake-backed). REWRITTEN + UNPROVEN: the capability claim `cdp_input` is UNPROVEN until WS2b.1 runs on both hosts.
- **WS2b.1 — trusted-event matrix (isTrusted)** — status **NOT BUILT**. (a) entry point: CDP `Input.dispatch*` through `zb_native_*` (do not exist). (b) test and step: NEW `tests/e2e/win_trusted_input_matrix.py`. (c) mutant: dispatch synthetic `dispatchEvent`: `isTrusted` is false. (d) platform run: Win11 VM. Proof type: none yet. NOT RUN; if CDP input is not trusted WS2b stops.
- **WS2b.1-W10 — trusted-event matrix on the Win10 box** — status **NOT BUILT**. (a) entry point: same matrix as `zbtest`. (b) test and step: `win_trusted_input_matrix.py`. (c) mutant: synthetic `dispatchEvent`. (d) platform run: Win10 box with its own WebView2 `pv`. Proof type: none yet. Not run.
- **WS2b.2 — dialogs (alert/confirm/prompt/beforeunload)** — status **NOT BUILT**. (a) entry point: `dialog.get` and `dialog.respond` RPCs. (b) test and step: NEW `tests/e2e/win_dialog_test.py`. (c) mutant: auto-accept in the handler without the deferral. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2b.3 — full-page screenshot over the socket** — status **NOT BUILT**. (a) entry point: `page.screenshot {fullPage:true}` RPC. (b) test and step: NEW `tests/e2e/win_screenshot_full_test.py`. (c) mutant: omit `captureBeyondViewport`. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2b.4 — input files with regular-file refusal** — status **NOT BUILT**. (a) entry point: `input.setFiles` RPC. (b) test and step: NEW `tests/e2e/win_input_files_test.py`. (c) mutant: accept directories. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2c.1 — popups and per-window ids** — status **NOT BUILT**. (a) entry point: a page's `window.open` chain, `page.list` RPC. (b) test and step: NEW `tests/e2e/win_popup_chain_test.py`. (c) mutant: open popups in the opener's window. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2c.2 — health answers while a sibling's FIFO is stuck** — status **NOT BUILT**. (a) entry point: `page.health` RPC with window 1 stuck. (b) test and step: NEW `tests/e2e/win_health_sibling_test.py`. (c) mutant: route `page.health` through the FIFO. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2c.3 — two-phase recovery of a hung renderer** — status **UNPROVEN**. (a) entry point: `page.recover` RPC. (b) test and step: NEW `tests/e2e/win_recover_test.py`. (c) mutant: kill the renderer without consent. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. UNPROVEN: no public mechanism that recovers a hung WebView2 renderer has been shown (unverified item 5). If neither spike route works WS2c.3 stops.
- **WS2c.4 — crash parity (`ProcessFailed`)** — status **NOT BUILT**. (a) entry point: a real renderer crash in the real exe. (b) test and step: NEW `tests/e2e/win_crash_parity_test.py`. (c) mutant: auto-reload after 3 s. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **WS2c.5 — popup drawer slots and one destroy path** — status **NOT BUILT**. (a) entry point: closing three windows by three paths. (b) test and step: NEW `tests/e2e/win_window_lifecycle_test.py`. (c) mutant: skip the detach in one path. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Zero code.
- **Closure A — ordinary routed command (socket to live page)** — status **NOT BUILT**. (a) entry point: authenticated socket -> `handleRequestWith` -> wv2 port -> CDP. (b) test and step: `win_routed_test.py`. (c) mutant: adapter absent: `pagePort()` null. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. No e2e at HEAD.
- **Closure B — health while a sibling is stuck** — status **NOT BUILT**. (a) entry point: socket `page.health`. (b) test and step: `win_health_sibling_test.py`. (c) mutant: health behind the FIFO. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. No e2e at HEAD.
- **Closure C — two-phase recover** — status **NOT BUILT**. (a) entry point: socket `page.recover`. (b) test and step: `win_recover_test.py`. (c) mutant: kill without consent. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. No e2e at HEAD.
- **WS2.ABI — unsupported seams are absent from the shipped exe** — status **NOT BUILT**. (a) entry point: the release-flavor exe started with `--automation-api` and WITHOUT `--e2e-protocol`. (b) test and step: NEW `tests/e2e/win_abi_absence_test.py`: drive every entry that would use a debug seam (socket RPC or environment variable) and assert it is refused; the debug-seam-only entries are driven only in the slice whose e2e owns them. (c) mutant: compile an undriven `zb_automation_debug_*` seam into the release flavor and expose its entry: the test must fail. (d) platform run: Win11 VM. Proof type: none yet (a link-time symbol listing is a tripwire). REWRITTEN + NOT BUILT: the link-time symbol-absence assertion is now a TRIPWIRE; the closing proof drives the release exe.

**Gate (WS2):** three gates (WS2a, WS2b, WS2c), each [W] on the Win11 VM AND the Win10 box (each its own evidence line; WS2.0-W10, WS2a.0-W10, WS2b.1-W10 are the named Win10 legs
so far), plus `win-native-click`,
`win-popups` and `win-crash-page` on the Win11 console and the Win10 monitor. WS2a/b/c are NOT started (see the WS2 status block).

---

## WS3: Config, persistence, cookies   [W]

### Behavior WS3.1: an isolated persistent profile
**Given** `--profile-dir <dir>` (default `%LOCALAPPDATA%\zigBrowser\profile\default`), **when** the
browser runs, **then** the WebView2 user data folder is `<dir>\WebView2`, no
`zigBrowser.exe.WebView2` folder appears next to the exe, and cookies/localStorage survive a
restart (login→restart→still logged in over the socket).

### Behavior WS3.2: flags decided by one fallible seam
**Given** a flag, **when** it is passed on Windows, **then** `applyBackendFlag(.windows, flag, value)`
(shared with macOS MS3.2; `src/webkit.zig`, called from `src/app.zig`) either applies it —
`--media-source off` = the document-start user script that deletes `MediaSource`/`SourceBuffer`
(the same approach as GTK, webkit_shim.c:4952-4970), `--hardware-acceleration never` =
`AdditionalBrowserArguments "--disable-gpu"` — or the binary **exits nonzero** with
`zigBrowser: --renderer=<v> is not supported on Windows` without touching the C ABI.

### Behavior WS3.3: cookie ABI + `CookiePort` over `ICoreWebView2CookieManager`
New `src/automation_wv2_cookie_port.zig` (gated `.windows`) with the GTK cookie-port contract.

- **Property (WS3.2):** oracle — for every `(flag, value)` in the generated product of known flags
  × known and unknown values, the Windows seam's accept/refuse matches the documented table in
  `src/webkit.zig`. [L] as a Zig unit through the seam (no C ABI).
- **Files touched:** `src/webkit.zig`, `src/app.zig`, `src/webview2_shim.cpp`,
  `src/automation_wv2_cookie_port.zig` (new), `tests/windows/win_profile_persist_test.py`,
  `tests/windows/win_config_flags_test.py`, `tests/windows/win_cookie_test.py` (new; rev 2.17, W10: the as-built
  location is `tests/windows/`, not `tests/e2e/`).
- 🔴 Red `win_profile_persist_test.py`: `assert not (exe_dir / "zigBrowser.exe.WebView2").exists()`
  (today the default environment creates it).
- 🔴 Red `win_profile_persist_test.py` (second assertion): `assert rpc("page.evaluate", {"expression":"localStorage.getItem('k')"})["result"] == "v"`
  after a relaunch with the same `--profile-dir` (today the default folder is shared and `--profile-dir` is
  ignored, so a second profile dir sees the first's value: also `assert other_profile_value is None`).
  Mutant: ignore `--profile-dir` ⇒ red.
- 🔴 Red `win_config_flags_test.py`: `assert proc.returncode != 0 and "--renderer=bogus is not supported on Windows" in proc.stderr`
  and `assert rpc("page.evaluate", {"expression":"typeof MediaSource"})["result"] == "undefined"` under
  `--media-source off` (today the flags are not applied on Windows: no `applyBackendFlag`; the second assertion
  is red because `MediaSource` exists). Mutant: apply before validating, or swallow the error and exit 0 ⇒ red.
- 🔴 Red `win_cookie_test.py`: `assert rpc("cookies.set", c)["result"]["ok"] is True and rpc("page.evaluate", {"expression":"document.cookie"})["result"] == "a=1"`
  (today `cookie_port` is null ⇒ -32011). Mutant: write the cookie to a second `CookieManager` of another
  profile ⇒ red.
- 🟢 Green: `CreateCoreWebView2EnvironmentWithOptions(nullptr, userDataFolder, options, …)` with the folder
  `<dir>\WebView2`; `applyBackendFlag(.windows, …)` in `src/webkit.zig`/`src/app.zig` (shared with macOS
  MS3.2); `zb_app_set_profile_dir`, `zb_app_set_hw_policy`/`get`, `zb_app_set_media_source`/`get` and their
  `zb_automation_debug_*` seams in the shim; `automation_wv2_cookie_port.zig` + `zb_cookies_*`.
- 🔵 Refactor: one options builder for the environment (user data folder + browser args); one place that
  maps flag → `AdditionalBrowserArguments`, so WS2's CDP use and WS3's flags cannot disagree about the
  environment (two environments with different options on one folder fail). The profile directory is created
  with the owner-only DACL helper from WS2.0.
- **Real-screen check:** none; not a UI slice (the profile folder and the cookie behavior are observable
  through the socket and the filesystem). The WS13 install check separately confirms no folder appears
  next to the installed exe.
- **Closure:** WS3.1 BLOCKING (crosses a process restart; SOURCE = profile dir; TRIGGER = relaunch;
  OBSERVE = `page.evaluate` over the socket). WS3.2 LEAF per flag. WS3.3 BLOCKING (async cookie
  manager boundary; OBSERVE = `document.cookie` through the socket).

### WS3 status at HEAD and the amendments (rev 2.17; C6, W20, W10, W9, C18)

**Built vs wired.** BUILT, REAL and PROVEN-PARTIAL (rev 2.20: not "closed"; two of the three named WS3.2 mutants are not recorded as run and WS3.2b is open, see the WS3 proof blocks): the flag seam (`backend_flag.Decision`, refusal before any C call at
`webkit.zig:41`, refusal proven on the real exe by the registered `refusal_stderr_live_test.py`). BUILT BUT UNWIRED and
unproven live: `automation_wv2_cookie_port.zig` (no production caller — `app.zig:627` wires the GTK cookie port; no
test block; an unknown `sameSite` silently becomes "unset"), `zb_app_set_profile_dir`, and the profile folder. Not
existing: `tests/windows/win_cookie_test.py`, `tests/windows/win_profile_persist_test.py` (the plan's earlier
`tests/e2e/…` paths are corrected to `tests/windows/…`, **W10**: the WS3/WS5 tests live in `tests/windows/`, and
`win_drawer_test.py:3-9`'s stale "UNREGISTERED" header and its `agent_drawer_win.cpp` citation are fixed with WS5).

### Behavior WS3.4 (NEW, rev 2.17; C6): the cookie port and the profile are WIRED and proven live   [BLOCKING]
**Given** the Win11 VM browser with `--automation-api`, **when** a client calls `cookies.set` then reads
`document.cookie`, and **when** the browser is relaunched with the same default profile, **then** the cookie and a
`localStorage` value survive, no `zigBrowser.exe.WebView2` folder exists next to the exe, and the profile folder's DACL
is owner-only.
1. **Wire the cookie port:** `buildAutomationConfig` (`app.zig:626-627`) selects `automation_wv2_cookie_port.cookiePort()`
   when `builtin.os.tag == .windows` (today the GTK port). Red: `win_cookie_test.py` `assert rpc("cookies.set", c)["result"]["ok"] is True and rpc("page.evaluate", {"expression":"document.cookie"})["result"] == "a=1"`; mutant: leave the GTK port wired ⇒ -32011 ⇒ red; a second `CookieManager` of another profile ⇒ red.
2. **Default profile:** `%LOCALAPPDATA%\zigBrowser\profile\default` when `--profile-dir` is absent (`app.zig:513`
   `spec.profile_dir orelse return null` today). Red: with no flag, `assert not (exe_dir / "zigBrowser.exe.WebView2").exists()`.
3. **Owner-only profile folder:** the shim creates `<dir>\WebView2` with default ACLs (`webview2_shim.cpp:2387`
   `SHCreateDirectoryExW(nullptr, …)`); the plan's own refactor says it must use the WS2.0 helper — call
   `zb_restrict_to_owner` (`owner_only.zig:243`, currently no caller) on `<dir>\WebView2`. Red: read back the protected
   single-ACE DACL (same readback contract as WS2.0). Mutant: skip the restrict ⇒ red.
4. **Relaunch e2e:** `win_profile_persist_test.py` as written in WS3.1 (relaunch ⇒ `localStorage` survives; a second
   `--profile-dir` sees none of it).
5. **Registration:** all three tests are registered in the green commit **behind the `windows-live` aggregate with
   fail-on-skip (D.1)**. WS3.1 and WS3.3 are BLOCKING closures with an e2e only once these pass.

**WS3.2 test alignment (W20).** The as-built tests differ from this plan: they use `--renderer shm` (not `bogus`), read
media-source from a NAV title (not `page.evaluate` over the socket), have no `--disable-gpu` proof, and neither planned
mutant was run. Required: `--renderer=bogus` is refused with the exact message (the table row, via the real exe);
`typeof MediaSource` is read through `page.evaluate` over the authenticated socket (needs WS2a.1); an observable
`--disable-gpu` proof (the `AdditionalBrowserArguments` actually passed, read via the debug seam or the process command
line); and BOTH mutants run and recorded (apply-before-validate; swallow-error-exit-0). Until WS2a.1 exists the
`page.evaluate` half is explicitly OPEN.

**Property:** the cookie-JSON roundtrip incl. `sameSite` domain is in the Property register (C18).

### WS3 proof blocks (rule 9, rev 2.19)

> A symbol or cross-compile check proves only that code links (rule 4).
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `backend_flag_test.zig` -> `test-backend-flag`; `refusal_stderr_live_test.py` -> `windows-refusal-live`; `win_config_flags_test.py` -> `windows-config-flags-live` (WS3.2b extends this file and step). NEW files, each a member of the `windows-live` aggregate (D.1) under its own NEW step, failing on skip: `tests/windows/win_profile_persist_test.py` -> `windows-profile-persist-live` (WS3.1, WS3.4); `tests/windows/win_cookie_test.py` -> `windows-cookie-live` (WS3.3, WS3.4, and WS4.3). `cross-check-ws3-win` is an existing build step (`build.zig:603`) that is wired into neither `cross-check` nor `test`.

- **WS3.1 — isolated persistent profile** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe --profile-dir <dir>` and the default `%LOCALAPPDATA%\zigBrowser\profile\default`. (b) test and step: NEW `tests/windows/win_profile_persist_test.py` (does not exist). (c) mutant: ignore `--profile-dir`. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Needs WS2a.1 for the `page.evaluate` read; no default profile at `app.zig:513`.
- **WS3.2 — flags decided by one fallible seam** — status **PROVEN-PARTIAL**. (a) entry point: `zigBrowser.exe --media-source`, `--hardware-acceleration`, `--renderer` on Windows. (b) test and step: `tests/backend_flag_test.zig` (step `test-backend-flag`, in `zig build test`, driven over the real `backendFlagDecision`); live `tests/windows/refusal_stderr_live_test.py` and `win_config_flags_test.py` (steps `windows-refusal-live`, `windows-config-flags-live`). (c) mutant: accept an unknown or empty value; apply before validating; swallow the error and exit 0 (the last two named, not recorded as run). (d) platform run: Win11 VM (refusal on the real exe; media-source read from a NAV title). Proof type: driven + platform run. REWRITTEN to exercise form (W20): the real exe is run for refusal and application. Sub-proofs still missing are WS3.2b.
- **WS3.2b — `--disable-gpu` is actually passed; `typeof MediaSource` read over the socket** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe --hardware-acceleration never` and `--media-source off`. (b) test and step: extend `win_config_flags_test.py`: read the `AdditionalBrowserArguments` actually passed through the slice's debug seam, and `typeof MediaSource` through `page.evaluate`. (c) mutant: apply before validating; swallow the error and exit 0; drop `--disable-gpu`. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. The `page.evaluate` half needs WS2a.1.
- **WS3.3 — cookie ABI and `CookiePort` over `ICoreWebView2CookieManager`** — status **NOT BUILT**. (a) entry point: `cookies.set` and `cookies.get` RPCs, then `document.cookie`. (b) test and step: NEW `tests/windows/win_cookie_test.py` (does not exist); Property: cookie JSON roundtrip with `sameSite` in {Strict, Lax, None, absent, junk} (unknown value must be refused). (c) mutant: write to a second `CookieManager` of another profile; map an unknown `sameSite` to unset. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Port is unwired (no production caller at `app.zig:627`).
- **WS3.4 — cookie port and profile are WIRED and proven live** — status **NOT BUILT**. (a) entry point: `buildAutomationConfig` (`app.zig:626-627`) on `builtin.os.tag == .windows`; the relaunch path. (b) test and step: `win_cookie_test.py` and `win_profile_persist_test.py` (NEW), registered behind the `windows-live` aggregate with fail-on-skip. (c) mutant: leave the GTK port wired; skip `zb_restrict_to_owner` on the profile folder; second `CookieManager`. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. NOT BUILT.
- **WS3.X — `cross-check-ws3-win` symbol check** — status **NOT BUILT**. (a) entry point: the `x86_64-windows-gnu` object built from `src/ws3_win_cross_root.zig`. (b) test and step: `cross-check-ws3-win` (`build.zig:580-604`; never wired into `cross-check` or `test`). (c) mutant: drop `zb_cookies_add` from the Zig cookie path (a symbol-need mutant). (d) platform run: none: compile and link-need check only (rule 4). Proof type: tripwire-only. REWRITTEN + NOT BUILT: it is a TRIPWIRE and never proves any cookie or flag behavior; it is also not registered in `cross-check` or `test`.

**Gate (WS3):** [W] the Win11 VM AND the Win10 box (its own evidence line: the cookie/profile e2e run as `zbtest` under `C:\Users\zbtest\zb`). Not a UI slice. **Closed today: NOTHING in WS3 (rev 2.20, G6.2). WS3.2 is PROVEN-PARTIAL, not closed: two of its three named mutants (apply-before-validate, swallow-error-exit-0) are not recorded as run, the `--disable-gpu` proof and the socket read of `typeof MediaSource` are the open sub-behavior WS3.2b (NOT BUILT, needs WS2a.1), and there is no Win10 leg. NOT BUILT: WS3.1, WS3.2b, WS3.3, WS3.4.**

---

## WS3 cross-plan coordination (`applyBackendFlag` seam, `CookiePort`, profile store)   [coordination]

WS3 (Windows config/persistence/cookies) shares three artifacts with **macOS MS3** (JadeBeacon) and
the existing **GTK** backend. This section pins who owns what, the shared contracts, and the order, so
the three backends cannot diverge. It was mailed to BlackRobin, BlueBeaver, JadeBeacon and RoseCat.

### Shared artifacts
1. **The config-flag seam, split in two** (RoseCat 311e682 #2): a **pure, all-OS, runtime-testable
   decision** `backendFlagDecision(os, flag, value) -> Decision` (no C ABI), and a **target-only apply**
   `applyBackendFlag(comptime os, flag, value) !void` that is compiled for the **current target only** and
   calls that target's C setters. The Linux [L] property tests `backendFlagDecision` for all three `os`
   values; it never calls `applyBackendFlag` for a non-host target (whose C symbols do not exist in a
   Linux binary). Today only the Linux apply path exists (`webkit.zig:47-72`); macOS MS3.2's
   `applyMacBackendFlag(flag,value)` becomes `applyBackendFlag(.macos, …)`.
2. **The `CookiePort` interface** — the stable vtable in `src/automation/cookie_port.zig:13-31`:
   **`getAll(url, timeout) -> json`, `set(cookie_json, timeout)`, `delete(name, domain, timeout)`**
   (NOT `get_all`/`add`/`delete`). The GTK impl `automation_gtk_cookie_port.zig` already satisfies it;
   one impl per backend.
3. **The `--profile-dir` behavioral contract** — an isolated, persistent, per-profile store.

### The documented flag×value table (the single oracle; the [L] test is literal from this)

`backendFlagDecision(os, flag, value)` decides a flag that is **PRESENT** on the command line, only
(RoseCat 6415): it returns `apply` or `refuse`. `refuse` ⇒ `app.zig` prints
`zigBrowser: --<flag>=<value> is not supported on <os>` and exits nonzero, touching no C ABI. The
values are **production's own parsers, verbatim** — `media_config.parse` (`on`/`off`),
`render_config.parseHwPolicy` (`never`/`always`/`webkit`), `render_config.parseRenderer`
(`default`/`shm`/`mesa-egl`), `src/render_config.zig:18-26,33-35,48-65`, CLI help `src/main.zig:46,51`.
An **empty value is an explicit, invalid value** and is refused (it is NOT "absent").

| flag | value (present) | Linux | macOS | Windows | apply = backend action |
|---|---|---|---|---|---|
| `media-source` | `on` | apply | apply | apply | MSE left enabled |
| `media-source` | `off` | apply | apply | apply | document-start user script deletes `MediaSource`/`SourceBuffer` |
| `media-source` | `""` (empty) / any other | refuse | refuse | refuse | — |
| `hardware-acceleration` | `never` | apply | apply | apply | GTK: disable; macOS: `WKPreferences`; Windows: `AdditionalBrowserArguments "--disable-gpu"` |
| `hardware-acceleration` | `always` | apply | apply | apply | force GPU on |
| `hardware-acceleration` | `webkit` | apply | apply | apply | backend's own policy |
| `hardware-acceleration` | `""` (empty) / `auto` / any other | refuse | refuse | refuse | — (there is **no `auto`**) |
| `renderer` | `default` | apply | refuse | refuse | Linux renderer; macOS/Windows have no renderer choice |
| `renderer` | `shm` | apply | refuse | refuse | Linux: shared-memory frames |
| `renderer` | `mesa-egl` | apply | refuse | refuse | Linux: Mesa EGL |
| `renderer` | `""` (empty) / `mesa_egl` / any other | refuse | refuse | refuse | — |
| any unknown flag | any | refuse | refuse | refuse | — |

**Absence is not a decision (RoseCat 6415).** An absent flag makes **no** `backendFlagDecision` call and
**no** backend apply; the existing config **defaults** resolve it at the config/app boundary —
`media-source` = `on`, `hardware-acceleration` = `webkit`, Linux `renderer` = `shm`, and **no renderer
decision on macOS/Windows**. The absent/default behaviour is asserted by a separate **absent-default
oracle** at the config boundary (`render_config`/`media_config` defaults + `app.zig`'s arg-apply path
not calling the seam when the flag is unset), distinct from the present-flag table above. Absence is
never encoded as `value = ""`.

### Which plan owns what — one owner per file/hunk, with an ordered handoff (RoseCat #4)

The native shim files are **BlackRobin's alone**; the per-OS **apply** lives in the **Zig** arm of
`applyBackendFlag` (which only *calls* BlackRobin's C setters), so no file has two simultaneous editors.

| Artifact | Owner | File (sole owner of the hunk) |
|---|---|---|
| `backendFlagDecision` (all-OS pure) + `applyBackendFlag(comptime os,…)` skeleton + the table above + the GTK arm (refactored from `webkit.zig:47-72`, behaviour byte-identical) | **BlueBeaver** | `src/webkit.zig` (a "backend-flag seam" pre-slice, [L]) |
| The `.windows` **apply arm** (calls `zb_app_set_media_source`/`_hw_policy`, installs the user script) | **AzureRidge (WS3.2)** | `src/webkit.zig` (.windows branch only) |
| The `.macos` **apply arm** | **JadeBeacon (MS3.2)** | `src/webkit.zig` (.macos branch only) |
| Native C setters (`zb_app_set_profile_dir`, `zb_app_set_hw_policy`/`_media_source` + getters, kept `void`) **and** the cookie manager/store — landed **before** the arms that call them | **BlackRobin** | `src/webview2_shim.cpp` (Win), `src/wkwebview_shim.m` (mac) — his files only |
| `CookiePort` interface (stable) | **BlueBeaver** | `src/automation/cookie_port.zig` (unchanged) |
| `automation_wv2_cookie_port.zig` (Windows impl) | **AzureRidge (WS3.3)** | new file |
| `automation_wk_cookie_port.zig` (macOS impl) | **JadeBeacon (MS3.3)** | new file |
| Profile store | per-backend (sole file each) | GTK context (exists); `wkwebview_shim.m` WKWebsiteDataStore (BlackRobin, for JadeBeacon's `--profile-dir`); `webview2_shim.cpp` user-data folder (BlackRobin, for my `--profile-dir`) |

### Shared contracts (pinned)
- **`applyBackendFlag(comptime os, flag, value) !void`** validates via `backendFlagDecision(os, …)`
  **before** any `void` C setter; supported ⇒ apply; unsupported ⇒ `error.UnsupportedFlag`; `app.zig`
  prints the exact message and exits nonzero, **never touching the C ABI**. `--renderer` is entirely in
  the seam. The table above is the one oracle; the [L] test exercises `backendFlagDecision` only.
- **`CookiePort`:** `getAll`/`set`/`delete` (`src/automation/cookie_port.zig`); async store boundary;
  OBSERVE via `document.cookie` over the socket. One interface, three impl files.
- **`--profile-dir`:** isolated, persistent, per-profile; **no** store folder next to the exe; a second
  `--profile-dir` sees none of the first's data. **The persistence closure uses a local fixture** — set
  `localStorage`/a local cookie via `page.evaluate`, relaunch, read it back over the socket — **not** a
  live-site login (no credential gate in the test).

### Order (binding)
1. **BlueBeaver** lands the **backend-flag seam pre-slice** (`backendFlagDecision` + the table +
   `applyBackendFlag(comptime os,…)` with only the GTK arm, behaviour byte-identical) — [L], red-first.
   Unblocks WS3.2 and MS3.2.
2. **BlackRobin** lands the per-OS **native C setters + cookie manager/store** in his shim files (a shim
   pre-slice) — **before** the arms that call them.
3. In parallel after (1)+(2): **WS3** adds the `.windows` apply branch + `automation_wv2_cookie_port.zig`
   + the WS3 e2es; **MS3** adds the `.macos` branch + `automation_wk_cookie_port.zig` + the MS3 e2es.
   Each edits only its own branch of `webkit.zig` and its own new file — never the other's branch, never
   BlackRobin's shim.
4. **JadeBeacon** renames MS3.2's `applyMacBackendFlag` to `applyBackendFlag(.macos, …)` (one function).

### WS3's Linux-only reds (writable now, before the seam lands)
- **Flag-decision-table property** — now the **registered** `tests/backend_flag_test.zig` (step
  `test-backend-flag`, in the aggregate `test`; BlueBeaver owns `src/backend_flag.zig` + the test). Every
  row of the table above is asserted literally for **all three** `os` columns (`.linux`/`.macos`/
  `.windows`) against the **pure, all-OS** `backendFlagDecision(os, flag, value)` — the [L] test never
  calls the target-only `applyBackendFlag`; it also enumerates every other `std.Target.Os.Tag` (all
  refuse) and cross-checks the Linux column against production's own `media_config.parse` /
  `render_config.parseHwPolicy` / `parseRenderer` so the table and the CLI cannot drift. **Green today**
  (the seam exists). Mutant: accept an unknown/empty value ⇒ red. This supersedes AzureRidge's earlier
  standalone `src/ws3_backend_flag_table_test.zig` (`.windows`-only, 88e16cd), which is **removed** to
  keep a single literal oracle (no duplicated table to drift).
- **Windows cookie-port cross-check — TRIPWIRE ONLY (rev 2.19, rule 5: a compile and symbol-need check, never proof of any cookie or flag behavior; the closing proofs are `win_cookie_test.py` and `win_config_flags_test.py` run on the VM)** (`cross-check-ws3-win`, unregistered — a dedicated
  `x86_64-windows-gnu` object from `src/ws3_win_cross_root.zig`): the object compiles and references
  `automation_wv2_cookie_port.zig`'s `getAll`/`set`/`delete` and ~~`webview2_config.zig`'s
  `applyWindowsFlag`/`applyProfileDir`~~ (rev 2.17, W9: `webview2_config.zig` duplicates the real arm at
  `webkit.zig:63-70`, is referenced only by `ws3_win_cross_root.zig`, and is RETIRED per D.6(c); the root references the
  real `webkit.zig` arm instead), so `check_cross_symbols.py` must find every `zb_*` they need
  defined by `src/webview2_shim.cpp`. The step `--require`s **all seven** symbols explicitly —
  `zb_cookies_get_all`, `zb_cookies_add`, `zb_cookies_delete`, `zb_app_set_media_source`,
  `zb_app_set_hw_policy`, `zb_app_set_profile_dir`, `zb_automation_free` (RoseCat 6429: requiring only a
  subset lets a mutant that drops an unrequired symbol from the Zig side still pass, because the symbol
  then vanishes from the object's `needed` set). **Red today** — the shim defines none yet; the check
  reports all seven MISSING. Mutants (each flips the step red once the shim exists): drop
  `zb_cookies_add` from the Zig cookie path (a cookie op) ⇒ `--require zb_cookies_add` fails; drop
  `zb_automation_free` from the port's teardown (a config/ownership op) ⇒ `--require zb_automation_free`
  fails. Green when BlackRobin's `webview2_shim.cpp` defines all seven; then wire the step into
  `cross-check` and `test`.
  **Rev 2.17 (W12):** the step (`build.zig:580-604`) compiled per 15fb6ee (a compile and symbol-need check, a TRIPWIRE: WS3.X is NOT BUILT, rev 2.20) **but was never wired into `cross-check` or
  `test`**, and "red until the shim lands" comments remain in four files, so a dropped symbol would go unseen. Required:
  add `cross-check-ws3-win` as a dependency of `cross-check` and of the aggregate `test`, delete the four stale
  comments, and add the mutant (drop `zb_cookies_add` from the Zig cookie path ⇒ the aggregate `test` goes red).

---

## WS4: Site flows + approval grant authority on Windows   [W]

**Goal.** The platform-neutral flows and the approval model behave on Windows exactly as on
Linux. **Rev 2.17 (C7): this section is reconciled to the AS-BUILT model.** The earlier text said "no new grant code:
the tuple `sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`" — **that tuple does not
exist in `src/`** (`grep target_fp\|normalized_args src` is empty at HEAD). What IS built and what WS4 tests on Windows:
- the **approval card** (`src/agent_approval.zig`): `card_ttl_ms = 120_000` (`:182`, expiry at `:275`), one-shot
  Approve (`:279-286`), minted only by the native card handler;
- **window binding**: `WindowWant{origin, url, load_serial}` (`automation/engine.zig:1216`) and `windowRefusal`
  (`:1226`) revalidated pre-dispatch against origin/`load_serial`/`crashed`/`recovering`;
- **flow `expect{url, recipient}`** (`automation/social_flow_routes.zig:209-214`) checked in the same FIFO ticket (−32015);
- and the T5-style mutants rewritten to those fields (navigation retarget ⇒ `load_serial`; wrong account/recipient ⇒
  `expect.recipient`; replay ⇒ the one-shot Approve; expiry ⇒ `card_ttl_ms`).

**WS4.0 (NEW, rev 2.17): the strong grant tuple is a SEPARATE decision, not "already there".** Adding a
`sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)` grant is **new platform-neutral
work** (it would change Linux and macOS too). It is scheduled only if the owner/reviewers want it; until then no
Windows test may assert `target_fp` or `normalized_args`. **OWNER: decide (a) keep the as-built card/expect model for
launch, or (b) schedule the tuple as its own cross-platform slice.** Default adopted: (a).

- **WS4.1** page worlds, iframes, related popups, socket clients, model text and hooks cannot
  approve (negative proofs on Windows).
- **WS4.2** per-write confirmation; a dry run performs no committing click, no composer typing, no
  pacing count.
- **WS4.3** the login gate reads the session cookie through the WS3 cookie port.
- 🔴 Red `tests/e2e/win_flow_refusal_test.py` (rev 2.20, G2.4: WS4.1-WS4.3 have DISTINCT entry points and test classes in this file, not one shared boilerplate):
  - WS4.1 class `ForgedApprovalRefused`, entry point = each forged-approval CALLER CLASS reaching the approve path (a page `postMessage`, an iframe, a related popup world, a socket client, model text, a hook): `assert telemetry_root_spans_after == telemetry_root_spans_before`
    for each forged approval (today `-32011`: no port).
  - WS4.2 class `PerWriteConfirmationAndDryRun`, entry point = the write-flow RPC with `options.expect {url, recipient}` and the dry-run option: `assert wrong_account_result.code == -32015 and dry_run_commit_count == 0 and pacing_count == 0`.
  - WS4.3 class `LoginGateReadsWv2Cookie` (plus `win_cookie_test.py`), entry point = the login gate of a flow reading the session cookie that `cookies.set` placed on a fixture origin, through the CookiePort that `buildAutomationConfig` (`app.zig:626-627`) selects on Windows: `assert gate_verdict(logged_in_fixture) == "logged_in" and gate_verdict(logged_out_fixture) == "logged_out"`; mutants: read the cookie through the GTK cookie port (leave `app.zig:627` wiring the GTK port ⇒ -32011 ⇒ red), and skip the cookie read (the gate then treats a logged-out fixture as logged in ⇒ red).
- **Characterization note (rev 2; rev 2.17: mutants bound to the AS-BUILT fields, C7):** WS2 lands before WS4, so
  these tests would pass on arrival and a test that never failed proves nothing. Each is therefore proven by **a mutant
  run on Windows** (rev 2.20, G2.4: mutants (1)-(4) belong to WS4.1/WS4.2; the WS4.3 mutant is (5)): (1) skip the pre-dispatch `load_serial` revalidation (`WindowWant`) ⇒ the navigation-retarget test must fail; (2) skip the
  `options.expect` check (`{url, recipient}`) ⇒ the wrong-account test must fail with a commit instead of -32015; (3) let a
  popup-world caller approve ⇒ the related-popup test must fail; (4) mint without the single-use mark ⇒ the
  replay test must fail; (5) **(WS4.3)** read the session cookie through the GTK cookie port, or skip the cookie read ⇒ the login-gate test must fail. The first red run is a run **before the WS2 port is wired** (`pagePort()` null ⇒
  `-32011`, as stated), recorded as the red evidence; the mutants prove the assertions after wiring.
- 🟢 Green: no new source; any Windows-specific wiring the port needs (`automation_wv2_port.zig` returning
  the origin and `load_serial` the flows read) is part of WS2. 🔵 Refactor: the fixtures and the
  forged-approval helper are shared with `tests/e2e/` Linux flow tests (one helper module, not a copy).
- **Real-screen check:** none; not a UI slice (the native Approve click is WS11.3's check).
- **Closure:** BLOCKING for the refusal belts (socket → broker → engine); the positive commit
  closure is WS11.3 (the only native minter is WS5's card — **which does not exist yet on Windows, WS5.8**; the only
  real `tool_use` source is WS11's helper). **Files touched:** tests only, plus any Windows-specific wiring the WS2 port
  needs. **Gate (WS4):** [W11] fixtures only, no live sites. Not a UI slice. **WS4 cannot start until WS2a.1 is green
  (C4).** Grant-field property: see the Property register (C18).

### WS4 proof blocks (rule 9, rev 2.19)

> WS4 is characterization on top of WS2: no proof exists until the WS2a.1 port exists.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** `tests/e2e/win_flow_refusal_test.py` is NEW (does not exist at HEAD). It registers in the green commit as the NEW step `windows-flow-refusal-live`, a member of the `windows-live` aggregate (D.1), failing on skip. WS4.3 also needs `windows-cookie-live` (WS3). WS4.1, WS4.2 and WS4.3 are three test classes with three entry points (see the WS4 body), not one boilerplate.

- **WS4.1 — page worlds, iframes, popups, socket clients, model text and hooks cannot approve** — status **UNPROVEN**. (a) entry point: the approve path of the write flow, reached over the authenticated socket -> router -> broker -> engine on Windows from each forged CALLER CLASS (page world, iframe, related popup, socket client, model text, hook). (b) test and step: NEW `tests/e2e/win_flow_refusal_test.py` class `ForgedApprovalRefused` (telemetry root spans unchanged after each forged approval), registered as the NEW step `windows-flow-refusal-live` in `windows-live`. (c) mutant: let a popup-world caller approve. (d) platform run: Win11 VM and Win10 box (fixtures only). Proof type: none yet. UNPROVEN: there is no exercising proof until the WS2a.1 port exists (`pagePort()` is null, every call returns -32011) and, for WS4.3, until WS3.4 wires the cookie port.
- **WS4.2 — per-write confirmation; a dry run commits nothing** — status **UNPROVEN**. (a) entry point: the write-flow RPC carrying `options.expect {url, recipient}` and the dry-run option, over the authenticated socket -> router -> broker -> engine on Windows. (b) test and step: same file, class `PerWriteConfirmationAndDryRun` (dry-run and wrong-account assertions), step `windows-flow-refusal-live`. (c) mutant: skip the `options.expect` check; mint without the single-use mark. (d) platform run: Win11 VM and Win10 box (fixtures only). Proof type: none yet. UNPROVEN: there is no exercising proof until the WS2a.1 port exists (`pagePort()` is null, every call returns -32011) and, for WS4.3, until WS3.4 wires the cookie port.
- **WS4.3 — the login gate reads the session cookie through the WS3 cookie port** — status **UNPROVEN**. (a) entry point: the login gate of a flow, reading the session cookie through the WS3 cookie port that `buildAutomationConfig` (`app.zig:626-627`) selects on Windows, reached over the authenticated socket on a fixture origin whose cookie `cookies.set` placed. (b) test and step: same file, class `LoginGateReadsWv2Cookie` (step `windows-flow-refusal-live`), plus `win_cookie_test.py` (step `windows-cookie-live`). (c) mutant: read the session cookie through the GTK cookie port (leave `app.zig:627` wiring the GTK port) so the logged-in fixture is refused, and a second mutant that skips the cookie read so a logged-out fixture passes; the pre-dispatch `load_serial` revalidation mutant belongs to WS4.1/WS4.2 and does not exercise this behavior (rev 2.20, G2.4). (d) platform run: Win11 VM and Win10 box (fixtures only). Proof type: none yet. UNPROVEN: there is no exercising proof until the WS2a.1 port exists (`pagePort()` is null, every call returns -32011) and, for WS4.3, until WS3.4 wires the cookie port.

---

## WS5: Native Win32 drawer (per OD-W6)   [L] logic, [W], [U]

**Goal.** The accepted drawer UX on Windows: bottom dock, movable "S" icon that hides while open,
conversation with copyable text, "-" fold animation, structural isolation from page JavaScript.
Not wired to an agent yet (Send shows "Agent not available yet", like Linux S1/S2). OD-W6 is DECIDED:
**native Win32** (not a WebView2-hosted or WinUI drawer). **Rev 2.17 (C15): the as-built backend lives in
`src/webview2_shim.cpp`, not in `src/agent_drawer_win.cpp` (which does not exist) — see the status block below.**

### WS5 status at HEAD, as-built design, and open tasks (rev 2.17; C14, C15, C16, W10, W23)

**As built (HEAD `c07899f` code):** a docked panel and a `WS_CHILD` **STATIC** "S" icon inside the browser window,
implemented in `webview2_shim.cpp` (geometry, easing, hit-test and live counts stay in Zig `agent_drawer.zig`; the C++
only computes the elapsed ratio, `webview2_shim.cpp:1676-1686`); a second window class `zigBrowserDrawerExtra` and ~12
`ZIGBROWSER_AGENT_DRAWER_*` e2e seams (D.3). **Does not exist:** `src/agent_drawer_win.cpp`, `src/zigBrowser.rc`,
`packaging/windows/zigBrowser.manifest`; any DPI-awareness manifest or call (`GetDpiForWindow`, `webview2_shim.cpp:922`,
in a DPI-unaware process normally reads 96, so the 150% path has only an env-seam proof); the owned layered popup with
`SetWindowRgn`; the approval card; the Send box and "Agent not available yet"; WS12.1's `zb_drawer_set_draft` /
`zb_drawer_speaker_toggled`. So **WS11.3's "the only native minter is WS5's card" is FALSE today.**

**Decision (the review's "either/or" resolved):** the Design below is the *target*; the as-built child-control drawer is
accepted as the **interim** implementation, and the differences are explicit open tasks, not silently equivalent:
- **WS5.8 DPI:** add `packaging/windows/zigBrowser.manifest` (PerMonitorV2, Common Controls v6, `supportedOS` 10/11) +
  `src/zigBrowser.rc`, embed via `build.zig`; **no 150% acceptance (WS5.7, `win-drawer-dpi`) before this lands.** Red:
  `assert dpi_for_window == 144 and icon_px == 84` at 150% on the VM.
- **WS5.9 icon:** replace the `WS_CHILD` STATIC by the owned layered no-activate popup with circular `SetWindowRgn`,
  or amend the Design to the child control with an explicit statement that it cannot hover above the GPU-composited page.
- **WS5.10 card + Send:** the native approval card row (only its Approve handler calls the grant minter) and the Send box
  with "Agent not available yet" as explicit WS5 items (prerequisites of WS11.3 and WS12.1).

**Closure rule (C14, D.4): a drawer behavior closes only on an accepted live row on the Win11 VM.** Status by behavior
(offline oracles do not count; rev 2.20 reconciled to the WS5 proof blocks, G6.1): WS5.1 (entry/dock) is **PROVEN-PARTIAL** (the entry run b2c4f25, 8/8, is recorded; open: a production mutant, fail-on-skip registration, the Win10 leg), not CLOSED; WS5.5 is **PROVEN-PARTIAL for the primary window's inc/dec and the portable counter only** (the driven Zig test plus the four live methods at a5745b9, whose SECOND drawer window exists only behind the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS`, read only under `--e2e-protocol`), and the per-window / popup-close part **WS5.5b is NOT BUILT** because the production popup close path does not exist (WS2c.1 popups are zero code); **WS5.2 drag, WS5.3 fold, WS5.4 copy, WS5.6 isolation (page-JS
half), WS5.7 DPI: OPEN** — about 116 offline oracle/model tests exist against 27 live rows, and the 19 rows for drag,
fold, copy, DPI and isolation (`win_drawer_behaviors_test.py:857-1056`) skip in the gate. For each OPEN behavior either
record one accepted Win11 run of its live row or leave it OPEN. The settle proof (an AST parse of a Python test file) is
a tripwire, not a control-flow proof. No new offline oracle without a paired live row (D.4). The five `win-drawer-*`
real-screen cases are scheduled **with the owner**, and `tests/manual/real_screen_check.py` (X11-only) first gains a
Windows capture + foreground-proof backend (Testing Strategy, real-screen bullet).

### Design (target)
- `src/agent_drawer_win.cpp` + `.h` (target; **not built**, see status above), compiled in `configureWebView2Backend`; mounted from
  `zb_window_new` when the drawer is on. Geometry, gesture, fold timing/easing and persistence come
  from `src/agent_drawer.zig` (exports widened from `.linux` to `.linux or .windows`).
- **Dock:** a sibling child panel below the page; the controller's bounds are the client area
  minus the panel (no overlap with the GPU-composited page; the NVIDIA lesson).
- **"S" icon:** an owned top-level `WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE` popup with a
  circular `SetWindowRgn`, 56 px at 100% (scaled by DPI), `#d97757`, click-vs-drag at 6 px
  (`classifyGesture`), arrow keys 16/64 px, ratios persisted to `agent-drawer.json`; it follows the
  browser window on move/resize/minimize and hides while the drawer is open.
- **Fold:** "-" animates the panel rect into the icon's last position over 180 ms cubic ease-out
  (`lerpRect`/`ease`), stepped on vsync (`DwmFlush`) with `ZIGBROWSER_AGENT_ANIM_MS` honored.
- **Conversation:** bubbles are read-only RichEdit (`MSFTEDIT_CLASS`) set with **plain text only**
  (`EM_SETTEXTEX` without RTF, auto-URL detection off, no OLE objects), so text is selectable and
  copyable but inert; input is a multi-line EDIT pinned at the bottom (Enter sends, Shift+Enter
  newline); the list sticks to the bottom unless the user scrolled up.
- **Keyboard:** Ctrl+Shift+Space toggles, Escape minimizes, Enter/Space on the icon opens.
- **DPI:** new `packaging/windows/zigBrowser.manifest` (PerMonitorV2, Common Controls v6,
  `supportedOS` Windows 10/11) embedded via a new `src/zigBrowser.rc`.
- **Approval card (for WS11):** a native row; only its Approve handler calls the grant minter.

### Behaviors
- **WS5.1** the dock resizes the page above it (page bounds + panel bounds = client area; no
  overlap). **WS5.2** the icon drags (6 px threshold), moves by keys, persists, and hides while open.
  **WS5.3** "-" folds into the icon's last position over 180 ms (a mid-fold capture with
  `ZIGBROWSER_AGENT_ANIM_MS=3000` shows an intermediate rect). **WS5.4** bubble text is selectable and
  copyable (select-all + `WM_COPY` puts the exact text on the clipboard) and inert (a bubble whose
  text is `{\rtf1 …}` or a URL renders literally, no link, no object). **WS5.5** per-window drawers,
  one destroy path, live count zero after all windows close. **WS5.6** the drawer is unreachable from
  page JavaScript and the automation socket (no window id, no DOM). **WS5.7** at 150% scaling the icon
  is 84 px and hit-testing is exact.
- **Observation:** `--e2e-protocol` `DRAWER …` rows (the same row names as GTK) + window captures.
- **Property (WS5.2):** roundtrip — `parse(write(ratios)) == ratios` (reuse the `agent_drawer.zig`
  property) [L]; invariant — `clampRect` keeps the icon fully inside the client area for generated
  window sizes and DPI scales [L].
- **Files touched (rev 2.17: as-built vs target, C15/W10):** AS BUILT `src/webview2_shim.cpp` (drawer in the shim),
  `src/agent_drawer.zig` (export gate), `tests/windows/win_drawer_test.py` and `win_drawer_behaviors_test.py` (the
  as-built location is `tests/windows/`, not `tests/e2e/`; the `win_drawer_test.py:3-9` header is stale — it still says
  UNREGISTERED and cites `agent_drawer_win.cpp`). TARGET/OPEN (WS5.8-WS5.10): `src/agent_drawer_win.cpp/.h`,
  `src/zigBrowser.rc`, `packaging/windows/zigBrowser.manifest`, `build.zig` (compile + rc),
  `tests/manual/real_screen_check.py` (Windows capture + foreground proof backend).
- 🔴 Red `win_drawer_test.py`: `assert "DRAWER\topen" in rows and page_h + panel_h == client_h`
  (today no drawer exists on Windows; `zb_app_set_agent_drawer` is absent at link time, so the red is
  the e2e, not a link failure in a registered step).
- **Reds for the other behaviors (unregistered until green; each with a mutant):**
  - WS5.2 `assert icon_rect_after_drag == expected_rect_from_ratios and moved_px >= 6` and, for a 5 px move,
    `assert "DRAWER\topen" in rows` (a click, not a drag). Mutant: threshold 0 ⇒ red.
  - WS5.3 `assert 0 < fold_rect_mid.w < drawer_rect.w` with `ZIGBROWSER_AGENT_ANIM_MS=3000` and
    `assert fold_total_ms in range(150, 260)` at the default 180 ms. Mutant: snap with no animation ⇒ red.
  - WS5.4 `assert clipboard_text == bubble_text` after select-all + `WM_COPY`, and
    `assert "DRAWER\tbubble\tassistant\t{\rtf1" in rows and no_link_created` for a bubble whose text is RTF.
    Mutant: set the text as RTF (`EM_STREAMIN` with `SF_RTF`) ⇒ red.
  - WS5.5 `assert live_count == 0` after closing every window (`zb_drawer_debug_live_count`). Mutant: skip
    the destroy in the popup close path ⇒ red. **Rev 2.20 (G4.1): the "popup close path" named here does NOT exist in production
    (WS2c.1 popups are zero code); a second drawer window exists today only behind the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS`
    (read only under `--e2e-protocol`, `spawn_extra_drawer_windows`). That seam is NOT a production proof. The mutant above is therefore NOT BUILT
    (WS5.5b) until WS2c.1 lands a real popup window; see the WS5 proof blocks.**
  - WS5.6 `assert census_before == census_after` after `page.evaluate` tries `postMessage`/DOM reach and a
    socket client tries every method name containing `drawer` (all `-32601`/`-32011`). Mutant: expose a
    `drawer.state` method ⇒ red. **Rev 2.17 (C16): the as-built proof is OFFLINE only** — 4cb740d is a Linux in-process
    test that three drawer method names return -32601, the page-JavaScript half has no test, the Python row
    (`win_drawer_behaviors_test.py:321-333`) exercises helpers defined in the test itself, and the live row (`:1018`)
    never ran. Required: a **real-binary Win11 row** — the real exe with `--automation-api` and the drawer on; from
    page JS (`page.evaluate`: `postMessage`, `window.chrome.webview`, DOM walk) AND from the authenticated socket (every
    method containing `drawer`), the `DRAWER` census is unchanged and no drawer window id/DOM node is reachable; it
    needs WS2a.1 for the `page.evaluate` half (WS5.6 stays OPEN until WS2a.1 exists). Mutant: expose `drawer.state`
    over the socket ⇒ red; mutant: reply to the page's `chrome.webview` message with drawer state ⇒ red.
  - WS5.7 `assert icon_px == 84 and hit_test_edges_exact` at 150%. Mutant: ignore DPI ⇒ red.
- 🟢 Green: the Win32 drawer (`agent_drawer_win.cpp/.h`, manifest, `.rc`, the `agent_drawer.zig` export
  widening, the `zb_app_set_agent_drawer`/`_get_agent_drawer`/`zb_drawer_debug_live_count` shim functions).
  🔵 Refactor: no geometry or easing math in C++ (all from Zig); one
  window-proc dispatcher per control type; no duplicated DPI scaling.
- **Closure:** WS5.1-WS5.5 LEAF (one process, native UI, observed via census rows and captures);
  WS5.6 BLOCKING (negative: page JS and socket clients must not reach drawer state; OBSERVE = the
  census shows no change after the attempts).
- **Real-screen checks (orchestrator with the user, both screens):** `win-drawer-open` (icon visible,
  click opens, icon hides, page shrinks), `win-drawer-fold` (the "-" animation visibly folds into the
  icon), `win-drawer-drag` (icon drags and stays put after restart), `win-drawer-copy` (select a
  bubble, Ctrl+C, paste into Notepad), `win-drawer-dpi` (150% scaling). The input guard proves the
  zigBrowser window is foreground (`GetForegroundWindow`) before any `SendInput`, and the runner
  fails closed if the capture is unavailable or the desktop is locked.

### WS5 proof blocks (rule 9, rev 2.19; 4pa.44 and 4pa.46)

> **4pa.44 — source oracles are tripwires, never proof.** The WS5 drawer behaviors had been closed by about 116 offline oracle and model tests (grep, lexer, AST and extract tests over the shim and the C# runner text, and Python models of the lifecycle) against 27 live rows. Those suites are TRIPWIRES. A drawer behavior is proven only by the registered live run on the Win11 VM or the Win10 box. Two drawer behaviors have a RECORDED run: **WS5.1** (entry run b2c4f25, 8/8) and **WS5.5** (the four live lifecycle methods run on the Win11 VM at **a5745b9**: peak, intermediate and final counts, NoKillNeeded, zero survivors; the live count is driven in portable Zig by `agent_drawer_props_test.zig`). Both are only PROVEN-PARTIAL until a production mutant is recorded and the run is registered under fail-on-skip. **Rev 2.20 (G4.1): WS5.5's per-window part is NOT BUILT.** All four a5745b9 live methods obtain their second drawer window through the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS` (`webview2_shim.cpp:95-97`, `2205-2232`, `spawn_extra_drawer_windows` `2045-2060`), which is read only under `--e2e-protocol`; the production "popup close path" does not exist (WS2c.1 popups are zero code). That test-only path is NOT counted as a production proof (rule 6). What is really proven is the PRIMARY window's inc/dec plus the portable counter.

> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `agent_drawer_props_test.zig` -> `drawer-props-test`; `win_drawer_test.py` -> `windows-drawer-live`; `win_drawer_behaviors_test.py` -> `windows-drawer-behaviors` (both steps scrub the host variables and skip in `zig build test`, so they join `windows-live` with fail-on-skip as WORK, D.1). NEW: the WS5.6 real-binary row `tests/windows/win_drawer_isolation_live_test.py` -> `windows-drawer-isolation-live` (in `windows-live`); the WS5.8/WS5.9/WS5.10 live rows are NEW rows in `win_drawer_test.py` / `win_drawer_behaviors_test.py` and ride `windows-drawer-live` / `windows-drawer-behaviors`; WS5.5b rides `windows-window-lifecycle-live` (WS2c.5). **4pa.46 — WS5.6 closure was offline only**; it is re-marked NOT BUILT below with the exercising proof named. WS5.2, WS5.3, WS5.4 and WS5.7 are re-marked NOT BUILT; WS5.8, WS5.9 and WS5.10 do not exist.

- **WS5.1 — the dock resizes the page above it (entry run)** — status **PROVEN-PARTIAL**. (a) entry point: `zigBrowser.exe` start with the drawer on (`zb_app_set_agent_drawer`): `DRAWER open` rows and native child visibility. (b) test and step: `tests/windows/win_drawer_test.py` `WinDrawerLive` (step `windows-drawer-live`: in `zig build test` it scrubs the host variables and skips, so the live run is by hand with the host set). (c) mutant: NONE recorded on production (the b2c4f25 negatives mutate the oracle's observations). Required: skip the icon `SW_HIDE` in `resize_controller`: `icon_visible == 0` must go red. (d) platform run: Win11 VM entry run b2c4f25, 8/8; Win10 box not run. Proof type: platform run. PROVEN-PARTIAL: the recorded platform run (b2c4f25) is the only evidence, and it is not a registered gate run (rev 2.20, G6.3: this line had said "PROVEN by the recorded platform run"). Open: production mutant, fail-on-skip gate registration, Win10 leg.
- **WS5.2 — the icon drags, moves by keys, persists** — status **NOT BUILT**. (a) entry point: real icon input on the real exe. (b) test and step: `win_drawer_behaviors_test.py` live rows `test_ws5_2_icon_drag_moves_to_persisted_ratio` and `test_ws5_2_small_move_from_closed_is_click_that_opens` (skip in the gate; never run). (c) mutant: drag threshold 0. (d) platform run: Win11 VM. Proof type: tripwire-only today (offline oracles and models). RE-MARKED NOT BUILT (4pa.44): proven only by source oracles and models; the live rows have never run.
- **WS5.2P — drawer geometry properties (ratio roundtrip, `clampRect`)** — status **PROVEN-PARTIAL**. (a) entry point: the production `agent_drawer.zig` functions. (b) test and step: `tests/windows/agent_drawer_props_test.zig` (step `drawer-props-test`, in `zig build test`, driven). (c) mutant: let `clampRect` leave the icon outside the client area. (d) platform run: none: pure Zig (hit-testing on the platform is WS5.7). Proof type: driven (L). Open: no production-mutant run record was located in this audit; record it in the commit message (rule 3).
- **WS5.3 — `-` folds into the icon over 180 ms** — status **NOT BUILT**. (a) entry point: the fold on the real exe with `ZIGBROWSER_AGENT_ANIM_MS=3000`. (b) test and step: live rows `test_ws5_3_fold_intermediate_default_duration`, `..._honors_anim_ms_override` (never run). (c) mutant: snap with no animation. (d) platform run: Win11 VM. Proof type: tripwire-only today. RE-MARKED NOT BUILT (4pa.44): the fold-failure rows are source/model oracles; no accepted live run.
- **WS5.4 — bubble text is selectable, copyable and inert** — status **NOT BUILT**. (a) entry point: select-all and `WM_COPY` on a real bubble. (b) test and step: live row `test_ws5_4_bubble_copy_and_inert` (never run). (c) mutant: set the text as RTF (`EM_STREAMIN`). (d) platform run: Win11 VM. Proof type: tripwire-only today. RE-MARKED NOT BUILT (4pa.44).
- **WS5.5 — primary-window drawer inc/dec and the portable live counter (the PROVEN-PARTIAL part of "per-window drawers, one destroy path, live count back to zero")** — status **PROVEN-PARTIAL** (rev 2.20, G4.1: narrowed to what is really exercised). (a) entry point: closing the PRIMARY window through `WM_DESTROY`, which calls `zb_drawer_live_inc` and `zb_drawer_live_dec` in Zig. (b) test and step: DRIVEN Zig `tests/windows/agent_drawer_props_test.zig` over the real `DrawerLive` and `retireExtraWindow` (step `drawer-props-test`, in `zig build test`); live methods `test_ws5_5_live_count_peak_then_zero`, `test_ws5_5b2_closing_one_extra_drops_the_live_count_by_exactly_one`, `test_ws5_5b2_extra_fail_panel_drives_partial_cleanup`, `test_ws5_5b2_extra_fail_icon_drives_partial_cleanup` (step `windows-drawer-behaviors` / `windows-drawer-live`; they scrub the host variables and skip in `zig build test`). (c) mutant: `live -= 0` in the portable counter makes the lifecycle test fail (19/20, recorded by the audit run); skip the primary-window `live_dec` on `WM_DESTROY`: the count stays above zero (named; run record not located: record it). (d) platform run: Win11 VM live run at a5745b9. **What the a5745b9 run exercised honestly:** all four live methods get their second drawer window through the e2e-only test seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS` (read only under `--e2e-protocol`, `webview2_shim.cpp:95-97`, `2205-2232`, `spawn_extra_drawer_windows` `2045-2060`). The run proves the seam and the primary window's inc/dec plus the portable counter, and it is NOT a production proof of popups. Proof type: driven + platform run (primary window and counter only). PROVEN-PARTIAL, not "PROVEN by the a5745b9 Win11 run" (rev 2.20, G6.3). The run output is NOT in a5745b9's own commit message (it says the run was pending); the output is recorded only in review commit 18b32b4, so paste it into the implementing commit message. Open: recorded production mutant, fail-on-skip registration, Win10 leg.
- **WS5.5b — per-window drawers on production popup windows, one destroy path through the popup close path** — status **NOT BUILT** (rev 2.20, G4.1; new row). (a) entry point: a real popup window opened by a page's `window.open` chain, then closed through the popup close path and `WM_DESTROY`; **this entry point does not exist** (WS2c.1 popups are zero code, and the only second drawer window is behind the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS`, which rule 6 does not count as a production caller). (b) test and step: WS2c.5 `tests/e2e/win_window_lifecycle_test.py` (NEW; step `windows-window-lifecycle-live`, in `windows-live`) closing three windows by three production paths and reading `zb_drawer_debug_live_count`; the seam-driven live methods above stay as the seam's own tripwire. (c) mutant: skip the detach (`zb_drawer_live_dec`) in the popup close path: the live count stays above zero. (d) platform run: Win11 VM and Win10 box, after WS2c.1. Proof type: none yet. NOT BUILT: depends on WS2c.1.
- **WS5.6 — the drawer is unreachable from page JavaScript and the socket** — status **NOT BUILT**. (a) entry point: the real exe with `--automation-api` and the drawer on; page `postMessage`, `window.chrome.webview` and a DOM walk; every socket method containing `drawer`. (b) test and step: live row `test_ws5_6_isolation_denied_and_census_unchanged` (`win_drawer_behaviors_test.py:1018`, never run; step `windows-drawer-behaviors`) plus the NEW real-binary row `tests/windows/win_drawer_isolation_live_test.py` (NEW step `windows-drawer-isolation-live`, in `windows-live`) whose page-JS half needs WS2a.1. (c) mutant: expose `drawer.state` over the socket; reply to a `chrome.webview` message with drawer state. (d) platform run: Win11 VM; Win10 box for the same row. Proof type: tripwire-only today (4cb740d and 33bde9a are offline Linux in-process tests; the Python row exercises helpers defined in the test itself). REWRITTEN + NOT BUILT (4pa.46): offline closure does not prove WS5.6. Exercising proof needed: the Win11 real-binary row above. The socket half can run now; the page-JS half is blocked by WS2a.1.
- **WS5.7 — 150% DPI: icon is 84 px and hit-testing is exact** — status **NOT BUILT**. (a) entry point: the real exe at 150% scaling. (b) test and step: live rows `test_ws5_7_dpi_scaled_rect_and_hit_test`, `..._dpichanged_resizes_the_icon` (never run). (c) mutant: ignore DPI. (d) platform run: Win11 VM. Proof type: tripwire-only today (env-seam proof only; the process is not DPI-aware). RE-MARKED NOT BUILT (4pa.44): no manifest, so no 150% acceptance until WS5.8.
- **WS5.8 — DPI manifest and resource file** — status **NOT BUILT**. (a) entry point: the exe started at 150%: `GetDpiForWindow`. (b) test and step: NEW live row in `win_drawer_test.py` (step `windows-drawer-live`): `dpi_for_window == 144 and icon_px == 84`. (c) mutant: drop the manifest from the link. (d) platform run: Win11 VM. Proof type: none yet. Nothing exists.
- **WS5.9 — owned layered popup for the icon** — status **NOT BUILT**. (a) entry point: the real exe: icon above the GPU-composited page. (b) test and step: NEW live row with window capture in `win_drawer_behaviors_test.py` (step `windows-drawer-behaviors`). (c) mutant: revert to the child STATIC. (d) platform run: Win11 VM. Proof type: none yet. Nothing exists.
- **WS5.10 — approval card and Send box** — status **NOT BUILT**. (a) entry point: the real drawer's Approve handler and Send control. (b) test and step: NEW live rows in `win_drawer_behaviors_test.py` (step `windows-drawer-behaviors`; also prerequisites of WS11.3 and WS12.1). (c) mutant: mint a grant before the click. (d) platform run: Win11 VM. Proof type: none yet. Nothing exists.
- **WS5.O — WS5 offline oracle and model suites** — status **TRIPWIRE ONLY**. (a) entry point: (none: these suites do not reach production). (b) test and step: `windows-drawer-behaviors` (offline half), `windows-drawer-live` (offline half), `windows-drawer-settle` (`ws5_5b2_settle_ast_test.py`, an AST parse of a Python test file), `windows-drawer-lifecycle` (`ws5_5b2_lifecycle_seam_test.py`, a Python model plus a call-site tripwire bound to the runner text), `ws5_5b2_clean_quit_red_test.py`. (c) mutant: n/a (they are guards). (d) platform run: n/a. Proof type: tripwire-only. REWRITTEN (4pa.44): source oracles are tripwires and never close a drawer behavior. The only drawer proofs are the driven Zig test and the registered live run on the Win11 VM or Win10 box. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS5):** [L] Zig properties; [W11] `win_drawer_test.py` and the live rows of `win_drawer_behaviors_test.py` on the
Win11 VM under fail-on-skip (D.1; the drawer suites must stop force-unsetting the host vars, `build.zig:3549, 3559`);
all five real-screen cases on the Win11 console. A behavior counts only when its live row is accepted (D.4).

---

## WS6: Secrets window + Credential Manager store   [W], [U]

### Behavior WS6.1: the token store
**Given** a valid token shape (`agent_secrets.zig:14-19`), **when** Save runs, **then** it is written
with `CredWriteW` (`CRED_TYPE_GENERIC`, target `zigBrowser/ClaudeAgentToken/default`,
`CRED_PERSIST_LOCAL_MACHINE`; a 512-char token fits the 2560-byte blob) and read back with
`CredReadW`; Remove deletes it. The "Save to a private file instead" path writes
`<agent_home>\secrets\claude-token` with a protected owner-only DACL, DPAPI-wrapped
(`CryptProtectData`, `CRYPTPROTECT_UI_FORBIDDEN`).

**Rev 2.17 amendments to WS6.1 (C19, W21, W3, C13).**
- **`Token` is parsed once (C19).** `validToken` returns `bool` (`agent_secrets_shape.zig:23`) and is re-checked at
  `agent_secrets.zig:128,169,345` and `agent_secrets_store.zig:84,103`, while the C ABI `zb_secret_cred_save` accepts any
  bytes. Required: one `Token` type returned by a single `parseToken(bytes) !Token` (no public constructor), the C ABI
  and every store take **only** a `Token` (the C wrapper parses at the boundary and refuses otherwise). Red:
  `assert zb_secret_cred_save(bad_bytes) == ERR_SHAPE and cred_read(target) is None` (mutant: let the C ABI accept raw
  bytes ⇒ red); the 10k-string shape property (`agent_secrets_shape_test.zig:114`) stays.
- **The Windows store is tested for its security-relevant constants, not just "compiles" (W21).**
  `agent_secrets_win.cpp` is gated today only by "compiles and exports four names" (`build.zig:564-567`); dropping
  `CRYPTPROTECT_UI_FORBIDDEN` (`:75`) or changing the SDDL (`:95`) would pass every registered step. Create the missing
  `agent_secrets_win_logic.h` (`tests/windows/agent_secrets_win_logic_test.cpp:11` includes it; it does not exist) with
  the flag/SDDL constants as testable values **for a compile-level TRIPWIRE only (rev 2.19, rule 5: asserting a constant or comparing an SDDL string is a source check)**. The proofs are exercised: a live `acl_principals(p) == {current_sid}` read-back of the file the real store writes, on the VM, and a real `zb_secret_dpapi_protect` / `dpapi_unprotect` round trip. Mutant: widen the SDDL ⇒ the read-back is red.
  `CRYPTPROTECT_UI_FORBIDDEN` has no known exercising proof (its effect shows only when DPAPI would prompt): **UNPROVEN** (WS6.1c) until a scenario that provokes the prompt is found.
- **`runSafety` gets a consumer and a non-null target (W3).** `runSafety` (`agent_secrets_store.zig:33-67`) has no
  consumer, and `agent_secrets_win.cpp:30,43,60` accept `nullptr` (the real production target) and any target string,
  so a credential test could reach `zigBrowser/ClaudeAgentToken/default`. Required: every Windows credential **test**
  entry point calls `runSafety` first and refuses a null or non-`zigBrowser-test-*` target; the production default
  target is selected only when `--e2e-protocol` is absent. Red: a test that passes `nullptr` is refused (mutant: skip
  `runSafety` ⇒ the test can touch the real target ⇒ red).
- **Consumer (C13).** `zb_secret_cred_save/read/delete` and `zb_secret_dpapi_protect` are referenced only by symbol
  checks and `TokenStore` (`agent_secrets_store.zig:71`) only by its own test; no Windows Secrets window exists and no
  real Win32 run has happened. The consumer is the WS6.2 Secrets window; until it exists WS6.1 is OPEN ("skeleton, no
  caller"), and a real Win32 CredWrite/Read/Delete run on the Win11 VM inside the interactive-session task is required
  to close it.

### Behavior WS6.4 (NEW, rev 2.17; C13, A.6): the token's route from the Windows store to the in-distro CLI's fd 3   [BLOCKING; DRAFT — depends on C1]
The DPAPI private-file fallback (`<agent_home>\secrets\claude-token`, WS6.1) is **unreadable from inside the distro**
(automount OFF), and nothing previously said how the token reaches the CLI. Route (PROPOSAL, gated by the WS8/WS9 DRAFT
gate blocker 3): the **Windows browser process** reads the token from Credential Manager (or DPAPI file), starts the
agent with `wsl.exe -d <distro> -u <nonroot> …` and passes the token on a **dedicated one-shot inherited pipe**
(distinct from the C1 control-capability pipe), which the in-distro supervisor reads once and hands to the CLI as
inherited **fd 3** (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`); it never appears in env, argv, a file, the control TCP
channel, a log or the census. Red (written only after the DRAFT gate closes): `assert canary not in (argv + env +
files + control_frames + logs)` and `assert cli_fd3_bytes == canary`; mutant: pass it in argv ⇒ red. Windows 10: not
applicable (agent OFF).

### Behavior WS6.2: the Secrets window
A native Win32 window (not a browser window, absent from the window registry and the socket): a
password-style EDIT, Save, Remove, "Save to a private file instead", Sign in, code entry, Copy link,
Cancel — the GTK window's controls (`agent_secrets_window.c:341-472`); `SECRETS …` rows under
`--e2e-protocol`.

### Behavior WS6.3: tests never touch a real credential
Tests use a disposable target `zigBrowser-test-<random>` through an `--e2e-protocol`-only override
and a canary token; teardown deletes it; a test that finds a non-test `zigBrowser/*` target refuses
to run. Credential tests run inside the interactive session task.

- **Files touched:** `src/agent_secrets_win.cpp` (new), `src/agent_secrets_window_win.cpp` (new),
  `src/agent_secrets.zig` (split portable shape checks from the `std.os.linux` file store),
  `build.zig`, `tests/e2e/win_secrets_test.py` (new).
- 🔴 Red `win_secrets_test.py`: `assert cred_read(target) == canary` after the window's Save (today no
  Secrets window on Windows). More reds, each with a mutant:
  - WS6.1 shape: `assert save(bad_token).error == "shape" and cred_read(target) is None` (mutant: skip the
    shape check ⇒ a malformed token is stored ⇒ red). The shape rule is the one at `agent_secrets.zig:14-19`
    (prefix `sk-ant-oat01-`, 22-499 suffix characters, 512 maximum), tested on the portable Zig side [L].
  - WS6.1 file fallback: `assert dpapi_unprotect(read_file(p)) == canary and acl_principals(p) == {current_sid}`
    and `assert canary not in raw_file_bytes` (mutant: write plaintext ⇒ red).
  - WS6.1 Remove: `assert cred_read(target) is None` after Remove.
  - WS6.2 isolation: `assert window_registry_count_unchanged and rpc("page.list") has no secrets window`.
  - WS6.3 safety: `assert refuses_to_run_when(existing_target("zigBrowser/ClaudeAgentToken/default"))`
    (mutant: let the test run against a non-test target ⇒ red).
  - Absence: `assert canary not in (stdout + stderr + census_rows + telemetry_dump)` (mutant: log the token ⇒ red).
- 🟢 Green: `agent_secrets_win.cpp` (`CredWriteW`/`CredReadW`/`CredDeleteW`, `CryptProtectData`),
  `agent_secrets_window_win.cpp`, the Zig `TokenStore` split in `agent_secrets.zig`, `build.zig` link
  (`advapi32`, `crypt32`, `comctl32`).
- 🔵 Refactor: one `TokenStore` interface in Zig with Linux (libsecret/file) and Windows
  (CredMan/DPAPI-file) implementations; no duplicated shape validation.
- **Closure (WS6.1→helper):** the token→helper route is closed in WS8.3/WS11.1 (it needs the
  launcher). Here LEAF (store round-trip, single process).
- **Real-screen check `win-secrets-window`:** paste, save, remove, and the private-file choice, on
  both screens; the window never shows the token in clear text.

### WS6 proof blocks (rule 9, rev 2.19)

> The Windows Credential Manager code is a skeleton with no caller; a symbol check does not prove a credential round trip.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today: `agent_secrets_shape_test.zig` and `agent_secrets_store_test.zig` -> `test-agent-secrets` (WS6.S); `cross-check-secrets-win` (`build.zig:572`) is a compile guard only. NEW: `tests/e2e/win_secrets_test.py` (WS6.1, WS6.1b, WS6.2, WS6.3) -> NEW step `windows-secrets-live`, a member of `windows-live`, failing on skip; the WS6.1a Zig test joins the existing step `test-agent-secrets`.

- **WS6.1 — Credential Manager token store (`CredWriteW/ReadW/DeleteW`)** — status **NOT BUILT**. (a) entry point: the Secrets window's Save, Remove and read-back (the consumer; does not exist). (b) test and step: NEW `tests/e2e/win_secrets_test.py` (NEW step `windows-secrets-live`) run inside the interactive-session task. (c) mutant: skip the shape check; write plaintext. (d) platform run: Win11 VM and Win10 box. Proof type: tripwire-only today (the `agent_secrets_win.cpp` exports are symbol-checked at `build.zig:564-567`). REWRITTEN + NOT BUILT: a symbol check is a TRIPWIRE; the closing proof is a real CredWrite, CredRead, CredDelete round trip. Skeleton with no caller.
- **WS6.1a — `Token` is parsed once** — status **NOT BUILT**. (a) entry point: `zb_secret_cred_save(bad_bytes)` through the C ABI. (b) test and step: NEW Zig test (step `test-agent-secrets`) plus the `win_secrets_test.py` shape row (step `windows-secrets-live`). (c) mutant: let the C ABI accept raw bytes. (d) platform run: Win11 VM. Proof type: none yet. `validToken` returns a bool and is re-checked in five places (C19).
- **WS6.1b — private-file fallback ACL and DPAPI wrap** — status **NOT BUILT**. (a) entry point: the real `zb_secret_dpapi_protect` and the owner-only file writer. (b) test and step: NEW live row in `win_secrets_test.py` (step `windows-secrets-live`): `acl_principals(p) == {current_sid}` read back on the VM and `dpapi_unprotect(read_file(p)) == canary`; replaces the plan's earlier `sddl == owner_only_sddl(...)` string comparison. (c) mutant: widen the SDDL; write plaintext. (d) platform run: Win11 VM. Proof type: none yet. REWRITTEN + NOT BUILT: comparing an SDDL constant is a source check (TRIPWIRE only). The test header `agent_secrets_win_logic.h` also does not exist.
- **WS6.1c — `CRYPTPROTECT_UI_FORBIDDEN` is honored** — status **UNPROVEN**. (a) entry point: `zb_secret_dpapi_protect`. (b) test and step: none known. (c) mutant: drop the flag. (d) platform run: Win11 VM. Proof type: none yet. REWRITTEN + UNPROVEN: asserting that a flag bit is set is a source check. The flag's effect is observable only when DPAPI would prompt; no way to provoke that prompt is known. Missing: a provoking scenario. **Rule-9 fields incomplete: not ready for implementation.**
- **WS6.2 — the Secrets window** — status **NOT BUILT**. (a) entry point: the real Win32 Secrets window. (b) test and step: NEW `win_secrets_test.py` rows (`page.list` shows no secrets window; registry count unchanged). (c) mutant: register the window in the registry. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. No window exists.
- **WS6.3 — tests never touch a real credential** — status **NOT BUILT**. (a) entry point: every Windows credential test entry point. (b) test and step: NEW row in `win_secrets_test.py` (step `windows-secrets-live`): a test that passes `nullptr` or a non-`zigBrowser-test-*` target is refused. (c) mutant: skip `runSafety`. (d) platform run: Win11 VM. Proof type: none yet. `runSafety` has no consumer (W3).
- **WS6.4 — token route from the Windows store to the in-distro CLI's fd 3** — status **UNPROVEN**. (a) entry point: browser process -> `wsl.exe` one-shot pipe -> CLI fd 3. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: pass the token in argv. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: needs the C1 bootstrap (DRAFT gate blocker 3) and a distro. **Rule-9 fields incomplete: not ready for implementation.**
- **WS6.S — portable token shape check** — status **PROVEN-PARTIAL**. (a) entry point: `agent_secrets.zig` shape rules. (b) test and step: `agent_secrets_shape_test.zig` (registered; 10k-string property). (c) mutant: accept a 21-character suffix. (d) platform run: none: pure Zig. Proof type: driven (L). Open: no production-mutant run record was located in this audit; record it in the commit message (rule 3).

**Gate (WS6):** [W] the Win11 VM AND the Win10 box (the Secrets window exists on Win10 too, so its own Win10 leg runs there with its own evidence line; its agent route does not, agent OFF) + `win-secrets-window` on the Win11 console and the Win10 monitor.

---

## WS7: Agent setup and provisioning on Windows   [L] partly, [W]

**Goal.** `--agent-setup` builds the immutable agent home on Windows (today refused, app.zig:52-55).

> **REV 2.17 REWRITE FOR OD-W4 / WSL2 (C9, W22). WS7 was built on 2026-10-22 against the SUPERSEDED native-Windows
> agent design** (commits ab86a92, ea8940e, 1a06bb0, b9ff6da, one day after OD-W4, none mentioning WSL;
> `agent/host/zb_agent_host/launcher.py` is 35 lines with no `wsl.exe` argv, no `pass_fds`, no fd-3 token). Under OD-W4
> (section A) **the agent home, the Python runtime, the Agent SDK wheel and `claude` live INSIDE the imported distro**:
> there is **no Windows `python.exe`, no Windows `claude.exe` and no native `zb-claude.exe` launcher**. **Stop further
> work on the native-Windows WS7.2/WS7.3 reds**; they are retired history. What survives on the Windows host (and is
> WS7's real scope): the agent-home *layout and copy rules* (now built and verified **in the distro**), the
> `wsl.exe -d <distro> -u <nonroot>` launcher argv + C1 bootstrap (DRAFT), and the Windows-side C3 current-pointer file.
> Win11 only; on Windows 10 `--agent-setup` reports "agent not available on this Windows" and exits 0/1 per the fixed
> explanation, creating nothing. WS7 stays behind the WS8/WS9 DRAFT gate for everything that touches WSL.

### Behaviors
- **WS7.1** the home layout `dist-<n>\…` with an atomic `current` switch that needs no privilege. **Rev 2.17:**
  *inside the distro* this is a POSIX `rename` of a symlink/pointer on the distro's ext4 (testable [L] with real
  `os.rename` semantics — the model property in the Property register); *on the Windows side* the C3 current-pointer
  state file (which distro is active) is swapped by create-new-then-`MoveFileExW(MOVEFILE_REPLACE_EXISTING)` and that
  atomicity **must be proven on the Win11 VM** (W22: the current reds use threads with POSIX `os.rename`, so
  `MoveFileExW` atomicity, which the plan says the red decides, is untested). The Windows executable path comes from
  `GetModuleFileNameW` (not `/proc/self/exe`, app.zig:130).
- **WS7.2 (REWRITTEN, C9)** the bundled runtime is the **distro's** Linux Python + the pinned Agent SDK wheel + the
  Linux `claude` + the `zb_agent_host` package, installed into the imported rootfs/agent home inside the distro and
  verified by SHA-256 pins. ~~A pinned Windows x64 Python with the wheel's `claude.exe`~~ is **retired** (no native
  Windows agent process, section A.2).
- **WS7.3 (REWRITTEN, C9)** the **launcher is `wsl.exe -d <distro> -u <nonroot> -- <supervisor>`** plus the C1 bootstrap
  (control capability on a one-shot inherited pipe; OAuth token on a separate inherited fd, WS6.4), implemented in the
  Windows browser process — **not** a native `zb-claude.exe` that "starts `claude.exe` in the session's job".
  ~~Windows has no `exec`; the SDK refuses `.bat`/`.cmd`~~ is moot inside the distro (Linux `exec` exists). Red
  (DRAFT-gated): `assert argv[:5] == ["wsl.exe","-d",DISTRO,"-u",NONROOT] and no_secret_in_argv_env` and `launcher.py`
  gains the `wsl.exe` argv, `pass_fds` and fd-3 contract.
- **WS7.4** the SAI copy follows the final "Hook commands only" rule and inherits the S3a
  corrections (da5eb70): dependency trees copied unscanned, links resolving outside an item root
  skipped with **no target bytes** in the home (Windows: symlinks and junctions both), only hook
  command lines validated, no access to the real `%USERPROFILE%\.claude` or repositories.
- **Files touched (rev 2.17):** `agent/host/zb_agent_host/setup.py`, `provision.py`, `files.py` (in-distro layout/copy
  helpers + the Windows C3 pointer helper), `agent/host/zb_agent_host/launcher.py` (`wsl.exe` argv, `pass_fds`, fd-3),
  `src/app.zig` (Windows setup path), `tests/windows/win_agent_setup_test.py` (new; the as-built test dir),
  `agent/host/tests/test_setup_windows_layout.py` (new, [L] for the pure layout/copy rules). ~~`src/zb_claude_launcher.zig`
  (new), `build.zig` (launcher exe)~~ — **retired (C9)**: no native Windows launcher.
- 🔴 Red `win_agent_setup_test.py`: `assert rc == 0 and (home / "current").exists()` (today exit 1,
  "the Claude Agent is Linux-only"); and the canary skill target is absent from `dist-<n>`. More reds:
  - WS7.1 `assert reader_never_sees_missing_current` while a second `--agent-setup` swaps `current` in a loop
    (the reader polls 1000 times; mutant: delete-then-create ⇒ a miss ⇒ red).
  - WS7.2 (rev 2.17) `assert (distro_home / "current" / "runtime" / "bin" / "python3").exists() and pinned_wheel_sha256 == EXPECTED`
    **run inside the distro** (mutant: an unpinned `pip install` ⇒ red). ~~`python.exe`~~ retired.
  - WS7.3 (rev 2.17) `agent/host/tests/test_launcher_contract.py` [L]: `assert argv[:5] == ["wsl.exe","-d",D,"-u",U]`, the
    secret is on `pass_fds`/stdin only, `assert child_exit_code == launcher_exit_code and orphan_count == 0`;
    ~~`tests/e2e/win_launcher_test.py` with `[claude_exe, *args]`, no `.bat`/`.cmd`~~ retired (mutant: launcher returns 0
    always ⇒ red). The live `wsl.exe` leg is DRAFT-gated (WS8).
  - WS7.4 `assert canary_target_bytes not in tree_bytes(home)` for a skill symlink and a junction (mutant:
    follow links ⇒ red).
  - WS7.5 (new) `agent/host/tests/test_windows_import.py` [L]: import every `zb_agent_host` module with
    `sys.platform = "win32"` and `fcntl`, `pty`, `termios`, `resource` blocked; `assert not failures`.
    Red today for `login.py` (`import fcntl` :28, `import pty` :31, `import termios` :38), `hook_run.py:26`
    and `seccomp.py:13` (both `fcntl`), and the POSIX-only `os.fork`/`os.execv` paths (`netd.py:782-793`,
    `relay.py:267`, `launch.py:111`, `token.py:119-129`) must be unreachable on Windows or replaced. Mutant:
    re-add a top-level `import fcntl` ⇒ red.
- 🟢 Green: `setup.py`/`provision.py`/`files.py` helpers (in-distro layout/copy + Windows pointer), the `launcher.py`
  `wsl.exe` contract, the Windows path in `app.zig` (`GetModuleFileNameW`, `LOCALAPPDATA`), platform-guarded imports in
  the Python modules. (~~`zb_claude_launcher.zig`~~ retired.)
- 🔵 Refactor: one copy-rule engine shared by Linux and the in-distro setup; only the Windows pointer primitive differs.
- **Toy-input reds are upgraded (W22).** The WS7.1/7.2/7.4 reds that use toy inputs (threads with POSIX `os.rename`,
  fake bytes, an in-memory filesystem) are tripwires only (D.4); each needs one real row: `MoveFileExW` pointer
  atomicity on the Win11 VM (a reader polls 1000× while a writer swaps; mutant: delete-then-create ⇒ a miss ⇒ red), the
  pinned wheel/rootfs bytes verified by SHA-256 against the real artifact, and the junction/symlink copy-skip run on a
  real NTFS junction on the VM (the in-distro copy-skip on a real ext4 symlink).
- **Closure:** WS7.1 BLOCKING (setup process → home on disk → helper launch reads it; OBSERVE =
  WS11.1's `ready` frame); WS7.4 LEAF (copy rules).

### WS7 proof blocks (rule 9, rev 2.19)

> WS7 was built against the superseded native-Windows design; toy-input reds are tripwires.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** Registered today (read from `build.zig`, not run): `test_launcher_contract.py` -> `test-launcher-contract` (WS7.3); `test_windows_import.py`, `test_windows_import_deep.py`, `test_windows_entry.py` -> `agent-host-win-import` (`build.zig:2794-2799`, in `test` at `:3709`; WS7.5 Linux half). NEW (draft until the step exists; all in `windows-live`, Win11 only): `tests/windows/win_agent_setup_test.py` -> NEW step `windows-agent-setup-live` (WS7.0, and the WS7.1 `MoveFileExW` pointer row, and the WS7.4 real-link rows); the in-distro WS7.1 POSIX-rename property -> NEW step `test-agent-current-switch-property` (in `zig build test`, Linux).

- **WS7.0 — `--agent-setup` on Windows 11 builds the agent home in the distro** — status **NOT BUILT**. (a) entry point: `zigBrowser.exe --agent-setup`. (b) test and step: NEW `tests/windows/win_agent_setup_test.py` (NEW step `windows-agent-setup-live`, in `windows-live`). (c) mutant: unpinned `pip install`. (d) platform run: Win11 VM only. Proof type: none yet. Behind the WS8/WS9 DRAFT gate for anything touching WSL; built so far against the superseded native-Windows design.
- **WS7.1 — atomic `current` switch** — status **NOT BUILT**. (a) entry point: `--agent-setup` run twice (second run swaps `current`). (b) test and step: in-distro POSIX `rename` property [L] (NEW step `test-agent-current-switch-property`); the Windows C3 pointer via `MoveFileExW`: a VM row where a reader polls 1000 times while a writer swaps (in `win_agent_setup_test.py`, step `windows-agent-setup-live`). (c) mutant: delete-then-create. (d) platform run: Win11 VM. Proof type: tripwire-only today (threads with POSIX `os.rename`, a toy). REWRITTEN + NOT BUILT: the toy-input red is a TRIPWIRE; `MoveFileExW` atomicity must be exercised on the VM.
- **WS7.2 — bundled runtime inside the distro, pinned by SHA-256** — status **UNPROVEN**. (a) entry point: the distro's Python and the Agent SDK wheel launched inside the imported distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: unpinned `pip install`. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: needs the imported distro (WS8 DRAFT gate). A SHA-256 match of a file is an integrity check, not proof the runtime works. **Rule-9 fields incomplete: not ready for implementation.**
- **WS7.3 — launcher is `wsl.exe -d <distro> -u <nonroot>` plus the C1 bootstrap** — status **NOT BUILT**. (a) entry point: the production launcher in the Windows browser process (`agent/host/zb_agent_host/launcher.py` is 35 lines with no `wsl.exe`, no `pass_fds`, no fd 3). (b) test and step: `agent/host/tests/test_launcher_contract.py` [L] (driven over the real launcher function); the live `wsl.exe` leg is DRAFT-gated. (c) mutant: launcher returns 0 always. (d) platform run: Win11 VM (DRAFT-gated). Proof type: none yet. Nothing built for WSL2.
- **WS7.4 — SAI copy rules skip links and junctions** — status **NOT BUILT**. (a) entry point: the setup copy path. (b) test and step: a real ext4 symlink inside the distro and a real NTFS junction on the VM, as rows of `win_agent_setup_test.py` (step `windows-agent-setup-live`); today's reds use an in-memory filesystem. (c) mutant: follow links. (d) platform run: Win11 VM. Proof type: tripwire-only today (toy inputs). REWRITTEN + NOT BUILT: toy-input reds are TRIPWIRES; the real-link rows do not exist.
- **WS7.5 — Windows-host Python modules import on Windows** — status **NOT BUILT** for the Windows claim (rev 2.20, G2.3). It is split in two so that no Windows claim rests on a Linux run (rule 4). **(i) Linux half, narrowed claim: "no module the Windows host imports has a top-level import of a POSIX-only module"**: (a) entry point: import of every module the Windows host still imports, with the POSIX-only modules (for example `fcntl`) blocked in a Linux interpreter. (b) test and step: `agent/host/tests/test_windows_import.py`, `test_windows_import_deep.py`, `test_windows_entry.py`, registered in the existing step `agent-host-win-import` (`build.zig:2794-2799`, in `test` at `:3709`; the files and the step were read, not run: SUSPECTED, rule 8). (c) mutant: re-add a top-level `import fcntl` to a scratch copy of a Windows-host module: the blocked-module import fails. (d) platform run: none, a Linux run with blocked modules; this proves ONLY the narrowed claim above and NEVER "imports on Windows". **(ii) Windows claim, "imports on Windows"**: (a) entry point: the same import list run by the Win11 VM's provisioned Python (no Windows Python ships for the agent, OD-W4), started as the VM test user. (b) test and step: NEW leg `test_windows_import.py --on-windows`, run through the NEW step `windows-agent-import-live` (in `windows-live`, fail on skip). (c) mutant: re-add a top-level `import fcntl`: the VM import raises `ModuleNotFoundError`. (d) platform run: **Win11 VM**. Proof type: none yet for (ii). NOT BUILT: the Win11 VM leg does not exist.

**Gate (WS7):** [L] layout/copy tests; [W11] setup e2e on the Win11 VM only (agent is Win11-only; Win10 asserts the
agent-OFF explanation). Not a UI slice. WS7.5 (Windows-importability of the Python modules) is retained only for the
modules the *Windows host* still imports; the agent modules run in Linux inside the distro. The Linux-run import check
proves only "no top-level POSIX-only import"; the claim "imports on Windows" needs the Win11 VM leg (rev 2.20, G2.3).

---

## WS8/WS9 DRAFT gate (RoseCat 9134b8b / 7558 / 7561 — authoritative; read before WS8 and WS9)

> ⚠️ **WS8 and WS9 below are a DRAFT, NOT IMPLEMENTATION-APPROVED.** **No WS8 or WS9 red, green,
> production source edit, installer change, or any further live/destructive WSL run may begin — and
> WS10, WS11, the agent-dependent parts of WS12, and the agent/sandbox parts of WS13 stay blocked —
> until a later reviewed plan revision closes EVERY blocker below.** The C1-C5 mechanics are
> **proposals/TBD, not contracts**. Accepting this revision is **documentation honesty only**: it does
> not close `affd577`, does not authorize implementation, and approves no security claim.

**The ONE sanctioned exception to the "no further live WSL run" rule (rev 2.17, C17).** The gate above forbids any
further live or destructive WSL run until every blocker closes, but blocker 1 can only be closed by a live rerun of the
*repaired* spike. That rerun was authorized only in review `ecd290a`, not in the plan, and it then failed before reaching
the VM on an ssh-config issue (fixed by 6f2188d → 1006b1e → bd92f4a, reviewed 13de146 and 7233d06); the spike header
(`wsl_live_test.py:3`) still says "NOT RUN". **This plan now states it explicitly: after (a) the six blocker-1 defects are
fixed in a separate reviewed repair commit AND (b) RoseCat approves the repaired spike, exactly ONE non-destructive-to-others
live rerun of `tests/windows/wsl_live_test.py` is permitted on win11-m8 (standard user `zbtext`, no admin, the
app-owned `zb-test-*` names, `-F none`/127.0.0.1 per the WSL ssh note), with a final census equal to baseline.** Any
second run, any other WSL command, and every WS8/WS9 red/green remains forbidden until a later reviewed revision.
Before then the spike is not run and its header is corrected from "NOT RUN" only by that rerun's commit.

**The six OPEN blockers from `9134b8b` (each must be closed, with live evidence, in the later revision):**
1. **OPEN — the spike oracle (`tests/windows/wsl_live_test.py`) is not safe to run.** Current defects (from
   the 6e9f989 review; the spike is DISCOVERY-ONLY / DO-NOT-RERUN / NOT-REPAIRED): (a) cleanup can **abort
   part-way** — an exception in one cleanup op skips the rest instead of completing best-effort then failing;
   (b) distro/artifact **ownership is recorded too late**, so a partial import before a failing assertion is
   not tracked or cleaned; (c) the Windows listener is stopped by a **raw PID that can be reused** (not
   PID-reuse-safe); (d) a local terminate/kill **lacks the PID-namespace safety contract** (it must run inside
   a PID namespace); (e) the **C1 secret is interpolated into the PowerShell/ssh argv** (it must be kept out
   of argv entirely, not merely off disk); (f) the **`::1` readiness check does not prove the exact
   `::1:<port>` row**. **Close:** fix all six in a separate reviewed repair commit (cleanup that always
   completes best-effort then fails; ownership recorded before/at the attempt; PID-reuse-safe listener stop;
   local kills inside a PID namespace; the secret off argv; exact `::1:<port>` readiness) with a final
   distro/import/process/listener/staged-file census == baseline and failed-launch/failed-unregister/leftover
   mutants — then, only after RoseCat approves the repaired spike, rerun live.
2. **OPEN — default non-root unproven.** The committed oracle only ran explicit `-u zbagent`; a
   no-`-u` default-user launch and an admin-group census are required.
3. **OPEN — C1 bootstrap not implementable/proven.** The exact Windows-handle→WSL-fd mechanism (only
   the stdio bridge is known) and the reverse channel that returns the in-distro ephemeral port to the
   browser are unspecified. **Close:** specify the exact bidirectional stdio/pipe protocol + closure/
   timeout and prove it live with canaries. OAuth fd-3 stays a hard-red unverified.
4. **OPEN (proposal drafted) — destructive distro ops have a check/use race.** Retire-after-census (C3)
   and terminate-after-last-owner (C4) had no cross-process claim held across census→action. **Proposal
   drafted in C4:** one bounded cross-process lock/lease (named mutex + lease file, TBD) shared by session
   admission, update/retire, recovery and uninstall, held exclusively across census AND action. **Still
   OPEN:** the concurrent-starter, crash-cut and stale-lease reds and their live proof.
5. **OPEN (proposal drafted) — C5 namespaces do not compose.** A Windows-reachable listener must live in
   the distro host netns; a broker "inside the agent's bwrap tree" cannot also appear at
   `127.0.0.1:51091/31337` to hooks in their own private net namespaces. **Proposal drafted in C5:** a
   trusted OUTER broker in the distro host netns terminates the Windows connection (C1-authed, co-tenant/
   port-squat fail-closed), and each hook (private netns) receives a HANDED socket endpoint (inherited fd /
   bind-mounted AF_UNIX), not a listener. **Still OPEN:** the co-tenant/port-squat/namespace-boundary
   acceptance reds and their live proof.
6. **OPEN — whole-plan reconciliation.** Old dedicated-user/WFP and both-host-agent contracts remain
   in authoritative sections (see the scope banner at the top). **Close:** rewrite every such section
   for browser-on-both / agent-on-Win11-only / WSL `WslBackend`, leaving historical alternatives only
   when unmistakably labelled non-normative. (Rev 2.16 marks them non-normative via the top banner;
   the excision itself is part of the implementation-approved revision.)

**Status of the earlier `affd577` eight findings** (what rev 2.15 did vs. what remains): #1 non-root —
explicit-user observed, **default-user + groups still OPEN** (blocker 2); #2 transport — exact bind +
bytes observed, **reverse-ready proof + rc enforcement OPEN** (blocker 1); #3 C1 bootstrap — separation
stated, **exact fd/port mechanism OPEN** (blocker 3); #4 C5 relay — described, **namespace composition
OPEN** (blocker 5); #5 C2 broker — drafted at plan level, **hardlink no-shared-inode rule OPEN**; #6
setup/update — versioned+pointer drafted, **lock/lease race OPEN** (blocker 4); #7 WFP removal — WS9
block replaced, **rest of plan OPEN** (blocker 6); #8 Win10 scope — banner added, **section rewrites
OPEN** (blocker 6).

---

## WS8: Agent sandbox = WSL2 + our own distro (per OD-W4; hard launch gates — **DRAFT, NOT IMPLEMENTATION-APPROVED**)   [L] spec, [W]

> ⚠️ **DRAFT.** This section is not implementation-approved; see the WS8/WS9 DRAFT gate above. C1-C6
> are **proposals/TBD**, not contracts.

**Goal.** The Windows launch agent sandbox is **WSL2 running our own minimal imported distro**, with
the agent confined INSIDE it by our **existing Linux sandbox (bubblewrap + netd)**. Its isolation
proofs are **hard launch gates**. If virtualization/WSL is unavailable, or any mandatory proof fails,
**Windows agent launch stays OFF and the app shows a fixed explanation** — there is no dedicated-users
or AppContainer fallback (those are dropped for launch, OD-W4).

### Design (WSL2 backend, per OD-W4)
- `WslBackend` in `agent/host/zb_agent_host/sandbox.py` implements the `SandboxBackend` protocol:
  `launch_spec` runs the agent as `wsl.exe -d <ourDistro> -- <the existing bubblewrap+netd launcher>`;
  the `Mount` list maps into the distro's own filesystem (agent home ro, workspace ro, scratchpad rw,
  state rw); `network` = the WS9 egress (netd runs **inside** the distro); `lifetime` = the wsl process
  tree / distro terminate; `channel` = the token over the browser↔agent transport (below).
- **One-time elevated setup = the single admin step** (one UAC prompt at first agent use): enables the
  `VirtualMachinePlatform` + WSL optional features (**may require a reboot — flagged unverified**), then
  `wsl --import`s our minimal distro from a bundled rootfs tarball to a per-user path (**not the Store**).
  It writes the distro's `/etc/wsl.conf` — `[automount] enabled=false`, `[interop] enabled=false`,
  `appendWindowsPath=false` — and leaves the global `%USERPROFILE%\.wslconfig` untouched. `--uninstall`
  (WS13.4) unregisters the distro and leaves no global WSL change.
- **Agent confinement is the EXISTING Linux sandbox** (bubblewrap + netd) run inside the distro — the
  same code and policy as Linux, so WS8's isolation is largely the Linux guarantees re-established under
  WSL2, not new Windows-host user/WFP machinery.
- **Transport (browser↔agent / browser↔netd):** AF_UNIX does **not** cross the WSL2 boundary, so the
  link is **loopback TCP with the agent listening inside the distro and the browser connecting from
  Windows** (a PROPOSED direction, unproven: one reverse attempt failed without proving listener readiness; transport direction and direct-dial denial remain proposals pending reviewed live evidence — see C1),
  carrying the **same owner-only auth** as the Linux AF_UNIX path (per-session token + nonce/HMAC, an
  endpoint reachable only with the live-session token). WS2.0's owner-only proof is re-expressed for this
  transport.
- **No dedicated local users, no WFP, no separate desktop, no job-object user isolation** — the WSL2
  VM boundary plus the in-distro Linux sandbox provide isolation.

### Hard-gate behaviors (WSL2; all red first; failure or absent virt ⇒ launch OFF + fixed explanation)
- **WS8.1 isolation:** the agent in the distro cannot read the Windows host user's profile, processes
  or the browser's memory (automount OFF so the Windows drive is not mounted — observed in the discovery spike: `/mnt/c` is not
  a mountpoint; no Windows PATH; and the `WSLInterop` binfmt handler hard-disabled at boot, since
  `interop.enabled=false` alone leaves it registered — observed in the discovery spike), and inside the distro the bubblewrap
  confinement holds (agent home ro, real credentials unreachable) — a canary in the host profile and one
  outside the bwrap mounts both stay unreadable.
- **WS8.2 setup:** one UAC prompt enables the features + imports the distro; idempotent (a second run
  changes nothing); a failed setup leaves no distro and no global WSL/`.wslconfig` change; it records
  whether a reboot was required. If virt/WSL cannot be enabled, setup reports it and the agent stays OFF.
- **WS8.3 token channels (TWO, distinct — see C1; rev 2.17 reconciled, C17):** the **control capability** reaches the
  agent via a one-shot inherited bootstrap fd at launch (never env/argv/file/TCP), and the **OAuth token** reaches the
  CLI via its own inherited fd-3 (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`); neither crosses the control
  TCP channel, and the two are never conflated. The later "WS8.3 the OAuth token reaches only the CLI channel" bullet
  in the Behaviors list is the OAuth half of this same item (not a different count): **WS8.3 = two channels throughout.**
- **WS8.4 non-root identity (RESTORED, rev 2.17, C17 — it was cited at the Unverified-items list and the acceptance matrix
  but missing from this list):** the agent runs as a dedicated unprivileged Linux uid (C6), never WSL's default root;
  `wsl.conf [user] default` pinned AND an explicit `-u <nonroot>` at launch; no sudo/doas/admin group, `CapEff=0`, no
  setuid, no writable rootfs; negatives `mount`, `ptrace`/`process_vm_readv`, host-exe launch, writing system dirs.
  (Default-user selection and group membership are blocker 2, OPEN.)
- **WS8.5 no survivors:** terminating the browser tears down the wsl agent tree (the distro's agent
  processes gone **within the C4 bound — a single number, 5 s, proposed below; the earlier "1 s" is withdrawn so WS8.5,
  C4 and matrix item 9 all say "the bound"**); nothing escapes the distro to the Windows host.
- **WS8.6 file scope:** workspace ro, scratchpad rw, agent home ro, the host `%USERPROFILE%\.claude`
  unreachable (no `/mnt/c`, interop off).
- **WS8.7 no-network child (TTS/STT):** the backend can run a no-network command inside the distro
  (netd denies it every endpoint) with only its read-only model/engine dir — the Linux `zb-speech`
  confinement, unchanged.
- **WS8.8 fail-closed:** with virt/WSL off, the agent never starts and the app shows the fixed
  explanation (tested on a host with the features disabled: agent-OFF + the message, not a crash).

### WSL2 contracts (C1-C6) — **DRAFT PROPOSALS / TBD, NOT pinned contracts**

> ⚠️ C1-C6 below are **proposals**, not approved contracts. Several mechanics are unresolved (see the
> WS8/WS9 DRAFT gate blockers 1-6) and are marked TBD. They may not be implemented until a later
> reviewed revision closes those blockers with live evidence.

These four DRAFT proposals (+ WS9's bridge topology) sketch the WSL2 topology; they are **NOT
implementation-ready** (see the WS8/WS9 DRAFT gate blockers above). The dropped
dedicated-local-users / job-object / separate-desktop / WFP design and its reds are **REMOVED** (not merely
prefaced); their isolation intent is re-expressed below as the WSL2 model.

**OBSERVED in the DISCOVERY SPIKE (narrow — do NOT read as a closure or security claim)** on win11-m8 (WSL
3.0.3.0, kernel 6.18.54.1-microsoft-standard-WSL2, build 26200), 2026-10-21, by the DISCOVERY-ONLY
`tests/windows/wsl_live_test.py` (standard **Windows** user `zbtext`, no admin; Alpine minirootfs 3.21.9
pinned in-repo by SHA-256). The committed oracle does not enforce several of its own rows (DRAFT-gate blocker
1), so these are observations to motivate the proposals below, **not** grounds for implementation:

> **What the committed run actually observed:** with an **explicit `-u zbagent`** launch, uid 1000 with no
> sudo/doas, `CapEff=0`, 0 setuid binaries, `/etc` write denied, and unprivileged user namespaces +
> bubblewrap working as that user; `wsl --import`/configure/run/terminate/unregister as the standard Windows
> user (no admin); `automount=false` leaves `/mnt/c` unmounted; `appendWindowsPath=false` keeps `/mnt` off
> PATH (`interop=false` is PARTIAL — the `WSLInterop` binfmt handler stays registered); two distros share one
> utility VM + one net namespace (separate mount/PID ns); an **exact** `127.0.0.1:0`/`::1:0` listener is
> reachable Windows→WSL with an ACK + moved canary (IPv4 and IPv6); a hostile co-tenant distro reached that
> `127.0.0.1` listener; a per-run process-group kill left a co-tenant session alive.
>
> **What it did NOT prove (OPEN):** default-user (no-`-u`) selection and group membership; a **causal**
> reverse firewall denial (the Windows listener readiness was not proven, so the "firewall-blocked" row is
> not yet causal); fail-closed lifecycle cleanup + a final census equal to baseline; the **C1 Windows-handle
> → WSL-fd + ephemeral-port-return bootstrap**; the production bubblewrap/netd argv; and **any product
> security boundary**. The paragraphs below are DRAFT PROPOSALS motivated by the observations, not verified
> contracts.
- `automount.enabled=false` **works** — the Windows drive is not mounted (`/mnt/c` is not a mountpoint; only
  WSLg's own `/mnt/wsl` + `/mnt/wslg` tmpfs remain), so the Windows filesystem — and any Windows AF_UNIX
  socket path — is unreachable from the distro.
- `appendWindowsPath=false` **works** (no `/mnt` on PATH). `interop.enabled=false` is **PARTIAL**: the
  `binfmt_misc/WSLInterop` handler stays registered/enabled, so WS8.1 must ALSO hard-disable it at boot
  (`echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop`, observed in the discovery spike to block exec) and never bind `/mnt` into the
  agent's bwrap tree. wsl.conf itself IS honored (hostname / `generateResolvConf` / `user.default` all applied).
- Two distros **share one utility VM** (identical `boot_id`) and **share one network namespace** (same net-ns
  inode, same `eth0`/gateway) while keeping **separate mount + PID namespaces**. So loopback is NOT isolated
  across distros; per-session network isolation must come from the agent's own bwrap netns + netd + C1 auth.
- **Loopback TCP directionality (observed; reverse NOT yet causal):** a listener bound EXACTLY `127.0.0.1:0`
  (and `::1:0`) inside the distro was reachable from **Windows→WSL** via localhostForwarding (IPv4 and IPv6),
  with an ACK and the canary bytes moved; the **WSL→Windows attempt failed** (timed out), but the committed
  oracle did not prove the Windows listener was live, so this is **not yet a causal "firewall-blocked" result**
  (DRAFT-gate blocker 1). A **hostile co-tenant distro reached the `127.0.0.1` listener** (shared net ns),
  indicating the loopback is not a boundary between distros and that **app-layer auth is mandatory** (C1
  proposal). A per-run process-group kill left a co-tenant session alive; `wsl --terminate` killed the whole
  distro.

**C1 — ONE transport + full auth contract (browser↔agent/netd control channel) — PROPOSAL / TBD, UNPROVEN.**
Transport = **loopback TCP** (proposed over hvsocket — simpler, portable — and over AF_UNIX, which does not
cross WSL2, and AF_VSOCK, whose host side needs AF_HYPERV + the VM GUID). **PROPOSED direction (unproven):
the agent LISTENS inside the distro and the browser CONNECTS from Windows.** A discovery observation showed a
Windows→WSL connect reaching an in-distro listener while a WSL→Windows connect did not; the reverse listener's
readiness was NOT established, so this is **not yet a causal "firewall-blocked" result** (DRAFT-gate blocker 1,
to be proven live). IF confirmed, browser-as-listener would be rejected (it would need an admin firewall rule).
The discovery run also showed a forwarded loopback listener reachable by a co-tenant distro (shared net
namespace), which — if the topology is confirmed — would make app-layer auth mandatory. The auth below is a
proposal:
- **Listener:** the **agent** binds `127.0.0.1:0` (ephemeral) **inside the distro**, never `0.0.0.0`
  (localhostForwarding still forwards a `127.0.0.1` listener); the browser connects to `127.0.0.1:<port>` on
  Windows. The port is handed to the browser by the launcher, never published. Each session uses a distinct port.
- **Per-session capability + non-circular bootstrap (affd577 #3):** a fresh 256-bit random **control
  capability** is generated by the browser per session. It is delivered to the agent's listener **before any
  TCP connect**, over a **one-shot inherited pipe at `wsl` launch** — the launcher spawns the agent with the
  capability on an inherited fd (a read-once bootstrap descriptor the agent reads at start then closes), never
  via the environment, argv, a file, or the TCP channel itself (which is why the bootstrap is not circular).
  The browser holds the same capability in memory and presents it on connect. The agent compares the
  presented value against the one it read at bootstrap.
- **Constant-time compare** of the presented capability (no early-exit); **no application byte is read or
  served before the handshake completes.**
- **Replay/session binding:** a per-connection server nonce + `HMAC(capability, nonce)` handshake binds each
  connection to the live session; a prior-session capability is rejected; the capability is invalidated when
  the session ends.
- **Framing/bounds:** length-prefixed frames; the handshake frame has a fixed max size; an oversize or
  partial pre-auth frame is dropped and the connection closed.
- **Endpoint lifetime:** the listener exists only for the session; close + capability-invalidate on exit.
- **Honest threat boundary (affd577 #3):** the control capability defends against page content/hooks, other
  Windows users, and co-tenant distros (observed in the discovery spike: a co-tenant distro CAN reach the `127.0.0.1` listener).
  It does **not** defend against another process running as the **same Windows user**, which can read the
  owner-DACL files, inject the bootstrap, or run `wsl -d <app> -u root`; the WSL VM is explicitly **not** an
  isolation boundary against the owning Windows user. The claim is "reachable only with the live-session
  capability," not "owner-only TCP."
- **Concrete wire format and numbers (rev 2.17, C17, W15) — PROPOSED values, still TBD until the blockers close:**

  | Item | Proposed value |
  |---|---|
  | control capability | 32 random bytes (256 bit) per session, never reused |
  | server nonce | 16 random bytes, fresh per connection |
  | HMAC | `HMAC-SHA256(capability, server_nonce \|\| client_nonce \|\| "zb-c1-v1")`, 32 bytes; compare constant-time |
  | frame header | `u32 big-endian length`, then payload; length counts payload only |
  | max handshake size | 256 bytes total pre-auth (oversize or partial ⇒ drop + close) |
  | max post-auth frame | 64 KiB; max concurrent streams 16 (C5) |
  | handshake timeout | 5 s to complete; idle pre-auth connection closed at 5 s |
  | **Windows-handle → WSL-fd bootstrap** | the launcher creates an anonymous pipe, passes the read end as the child's **stdin** of `wsl.exe` (the only stdio bridge known to cross; the in-distro supervisor reads exactly 32 bytes then closes fd 0) — to be proven live, blocker 3 |
  | **port-return channel** | the in-distro agent writes one line `ZBPORT <port>\n` (≤ 16 bytes) on **its stdout, which wsl.exe bridges back to the launcher**; the launcher parses it with a 10 s deadline and refuses anything else; the port is never logged or published |
  | OAuth token channel | a second, separate pipe → inherited fd 3 of the CLI; never on the stdin bootstrap pipe |

  These are *proposals with numbers*, so the blockers are concrete and testable; none is a contract (DRAFT gate).
- **OAuth-token separation (reconciles WS8.3):** the Anthropic OAuth token is a **separate** credential from
  the control capability. It NEVER crosses the control TCP channel; it reaches only the CLI's own fd-3 token
  channel (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`), delivered by the launcher to the CLI inside the distro
  on its own inherited fd. "The token reaches the agent over the transport" wording elsewhere refers to the
  control capability bootstrap, not the OAuth token.

**C2 — Mount crossing with automount off (no `/mnt/c`).** The semantic `Mount` list does NOT become a WSL
automount. Files cross via a **host-side broker over the control channel**:
- The agent's workspace/scratch/state live in the distro's own ext4 (inside the VHDX); the agent never
  touches the Windows filesystem directly. (Observed in the discovery spike: with automount off the Windows drive is genuinely
  unmounted; only WSLg's own `/mnt/wsl` + `/mnt/wslg` tmpfs remain, which carry no Windows data and are not
  bound into the agent's bwrap tree.)
- **Two named components (affd577 #5):** a **Windows broker service** (part of the browser process, holding
  OS handles to the approved roots) and an **in-distro broker client** (inside the agent's bwrap tree). They
  speak a small request/response protocol multiplexed over the C1 control channel (or a dedicated authed
  stream with the same handshake).
- **Capability representation:** the agent never names a Windows path. Each approved root is a **server-held
  capability** — an opaque per-session handle id the Windows broker mints; broker ops take `(root_handle,
  relative_subpath)` and the relative subpath is validated, never an absolute or agent-chosen Windows string.
- **Held-handle check-and-use primitive (replaces the removed WS0.5 "Option B"):** the broker opens the root
  directory ONCE with a kept `HANDLE` (backup-semantics, no-reparse open), then resolves each `relative_subpath`
  component-by-component **relative to that held handle** (`NtCreateFile` with `OBJ_DONTREPARSE` /
  `FILE_OPEN_REPARSE_POINT` rejecting reparse points, no `..`, verifying each component's parent is the held
  dir), and performs the read/write **through the resolved handle it just validated** — so there is no
  path re-resolution window (TOCTOU-safe). A component that is a symlink/junction/reparse, a `..`, a hardlink
  out of root, a FIFO/special entry, or a parent/file swapped mid-walk is refused.
- **RO workspace:** the broker exposes the workspace as an **immutable snapshot** (copied in once at session
  start, or a read-only handle); the broker refuses every write op against the workspace handle.
- **RW scratch/state:** written inside the distro's ext4; on request / session end the broker copies named
  outputs BACK **only** into the approved scratch/state roots via **temp file + flush + atomic rename**, each
  through the held-handle primitive; partial writes never replace a good file.
- **Bounds:** per-op size, per-session file count, and deadline limits; oversize/over-count/timeout ⇒ refused.
- **Sessions/conflicts/crash cleanup:** each session gets its own staging dir keyed by the session id;
  concurrent sessions cannot see or write each other's staging; on crash, next startup reclaims orphaned
  staging dirs owned by dead sessions (census by the lifetime marker, C4) and deletes them.

**C3 — Crash/reboot-safe, truly one-admin-step setup.** Admin is needed ONLY for the one-time feature enable
(`wsl --install --no-distribution` → VirtualMachinePlatform + WSL), which needs a reboot. *Observed in the discovery spike:* once
WSL is present, `wsl --import` and the whole per-user distro lifecycle run with NO admin, so the setup splits
cleanly into an elevated one-shot and an unprivileged per-user import:
- **Resumable:** the elevated setup records a durable state marker (features-enabled / reboot-pending /
  imported); after the reboot it RESUMES at the (unprivileged) import step with no second admin prompt.
- **Identity binding:** the elevated action takes the target user SID from its caller and refuses if it
  differs from the interactive console user's SID.
- **Rootfs pin + authentication:** the bundled rootfs tarball is verified against a **reviewed, in-repo
  pinned SHA-256** (NOT a hash file fetched from the same server, which catches only corruption, not
  tampering; and, when a signing identity exists, a signature) BEFORE `wsl --import`; a mismatch aborts. The
  tarball is treated as untrusted data (`wsl_live_test.py` already enforces the in-repo pin).
- **Import-dir protection:** the per-user import dir under `C:\Users\<user>\` gets an owner-only DACL.
- **Versioned registration + current pointer (affd577 #6):** each distro is registered under a **versioned
  name** `zigbrowser-<version>-<nonce>` imported into its own dir; a durable **current-pointer** state file
  (owner-DACL) names the active distro. Install/update is: import the new versioned distro → verify →
  **atomically flip the current-pointer (the commit point)** → retire the old one. The pointer flip is the
  single commit; a crash before it leaves the old distro current (new one is orphaned and reaped), a crash
  after it leaves the new one current (old one is retired on next run).
- **Active old sessions on update:** the retire step **never** unregisters a distro that still has live
  sessions. It acquires the **C4 cross-process lock** in exclusive mode and holds it across the live-session
  census (by the C4 marker/lease) AND the unregister, so no new session can be admitted between census and
  action; the old distro lingers until its last session's lease ends, then is reaped under the same lock.
- **Reboot-resume actor/authorization:** the resumable marker records which elevated action is pending and
  the target user SID; the post-reboot resume runs **unprivileged** (import needs no admin) and refuses if the
  console user SID differs, so no second UAC prompt and no cross-user resume.
- **Idempotent + rollback:** a second setup with the same version is a no-op; a failed import unregisters the
  partial distro and removes its dir, leaving the current-pointer unchanged; a failed update rolls back by
  leaving the pointer on the old distro.
- **Uninstall honesty (affd577 #6):** uninstall removes **only** zigBrowser's distro(s), import dirs, and
  state. Because enabling WSL/VMP is a **global** change this product may have made, uninstall does **not**
  claim to "leave no global WSL change": pre-existing features are preserved, and features this product
  enabled are **left enabled** (other software may now depend on WSL) — the uninstaller states this to the
  user rather than silently disabling WSL/VMP or removing another distro/global config.
- **Win10 box:** NO WSL and NO agent on the Windows 10 box (agent OFF, OD-W4) — WSL/agent is
  **win11-only**; any two-host agent-install claim is removed.

**C4 — Per-run lifetime + a cross-process lock/lease (PROPOSAL / TBD).** Each browser session runs its agent
under a **per-session supervisor inside the distro** that owns the whole session subtree. *Observed in the
discovery spike:* background trees persist across `wsl` invocations, a `kill -TERM -<pgid>` removes exactly one
session's tree while a co-tenant session stays alive, and `wsl --terminate <distro>` kills every process in the
distro.
- **One bounded cross-process lock/lease over admission + destructive actions (PROPOSAL, affd577/9134b8b #4 —
  closes the census→act race):** a single named, owner-DACL **lock/lease** (e.g. a Windows named mutex +
  lease file under `C:\Users\<user>\zb`, or an advisory lock on the current-pointer state file) is the one
  serialization point shared by **session admission, update/retire, crash-recovery reaping, and uninstall**.
  The rule: a destructive distro action (unregister/terminate of the app distro, retire of an old versioned
  distro) acquires the lock in **exclusive** mode and HOLDS it across BOTH the live-session census AND the
  action, so no new session can be admitted in between (session admission takes the lock in **shared** mode,
  registers its marker under it, then downgrades). A session is "live" iff it holds a current lease (renewed
  on a bound); a crashed session's lease expires, so recovery reaps its marker only after the lease is
  provably dead. **Reds (later, implementation-approved revision):** a concurrent-starter red (a session that
  tries to admit during a retire must either block until the retire completes or be refused — never slip
  between census and unregister); a crash-cut red (the destructive holder is killed mid-action → the lock is
  released by the OS/lease timeout and the next run completes or rolls back, never leaving a half-retired
  distro); and a stale-lease red (an expired lease must not keep a dead session's distro alive). The exact
  lock primitive (named mutex vs. lease file vs. both) and its timeout are **TBD** pending the implementation
  revision. **Proposed numbers and typed models (rev 2.17, C17, W15; still PROPOSALS):** primitive = a named Windows
  mutex `Local\zigbrowser-wsl-<SID>` (exclusive for destructive actions, shared for admission) **plus** a lease file
  under `C:\Users\<user>\zb\wsl\lease.json`; **lease period 5 s, expiry 15 s (3 missed renewals)**; lock acquire timeout
  10 s (then refuse, never spin); **"the bound" for teardown = 5 s** (WS8.5, matrix item 9). Typed models:
  `Lease = { session_id: [16]u8, owner_sid: string, pid: u32, started_ms: u64, renewed_ms: u64, state: enum{admitting, live, retiring, dead} }` (no other states);
  `CurrentPointer = { schema: u8 = 1, distro_name: string "zigbrowser-<version>-<nonce>", import_dir: string, state: enum{importing, verified, current, retired}, owner_sid: string }`
  (written by temp-file + flush + atomic `MoveFileExW`); C5 frame = `{ stream_id: u32, op: enum(u8){open=1, data=2, window=3, rst=4, close=5}, len: u32 ≤ 65536, bytes[len] }`
  with a per-stream receive window of 65536 bytes and ≤ 16 streams; any unknown `op` or `len` over the max ⇒ drop +
  close. Reds for these types are written only after the DRAFT gate closes (a typed parse test per model; mutant: accept
  an unknown enum value ⇒ red).
- **Ownership marker, not a raw pgid (affd577 #6):** every process in the session is tagged with a durable
  **session marker** (a session-id env/credential the supervisor sets, plus a session cgroup/ pgid). Teardown
  and recovery act on the MARKER (reap every process carrying it), so a detached/double-fork/`setsid` child
  that left the original process group is still reaped; a bare pgid would miss it.
- **Supervisor + browser-crash recovery:** the in-distro supervisor is the session's subreaper; if the
  browser (Windows) dies, the supervisor sees its control channel close and tears the subtree down within the
  bound. If the supervisor ITSELF is lost (e.g. the whole `wsl.exe` launcher is killed), **next startup
  censuses by the marker and reaps any orphaned prior-run survivors** before starting a new session (the spike
  already plants/kills such survivors to shape this test).
- **Forbidden distro-wide teardown:** normal teardown NEVER calls `wsl --terminate <distro>` or
  `wsl --shutdown` — both would kill co-tenant sessions / every distro. `wsl --terminate <app distro>` is
  reserved for uninstall or a **census-proven last owner under the C4 lock** (the lock is held across the
  census AND the terminate, so no session can be admitted in between — no other session's marked processes or
  live lease remain); `wsl --shutdown` is forbidden in production entirely.

**C6 — Dedicated non-root Linux identity (PROPOSAL, affd577 #1).** The **proposal** is that the agent
launches as a **dedicated non-root Linux uid** inside the distro, never WSL's default root, with `wsl.conf
[user] default` pinned to that user AND the launcher passing an explicit `-u <nonroot>` (defence in depth).
*Observed in the discovery spike with an **explicit `-u zbagent`** launch only:* that user is uid 1000, no
`sudo`/`doas`, `CapEff=0000000000000000`, zero setuid binaries on the rootfs, cannot write `/etc`, and
unprivileged user namespaces AND bubblewrap both work as that user. **Still UNPROVEN (see the observed/
not-proven block above and DRAFT-gate blocker 2):** that the **default** (no-`-u`) launch selects that uid,
and the agent user's **group membership** (no admin group) — the committed oracle observed only the explicit
`-u` case. The rootfs would ship read-only to the agent (bwrap RO-binds it); production negatives (proposed,
for the implementation-approved revision) cover `mount`, `ptrace`/`process_vm_readv`, launching a host
executable, and writing system dirs.

### Behaviors (WSL2; all red first; written only after this re-plan is approved)
- **WS8.1** isolation: the host profile/processes/browser memory are unreachable from the distro
  (automount off + no Windows PATH + the `WSLInterop` binfmt handler hard-disabled at boot, since
  `interop.enabled=false` alone leaves it registered — observed in the discovery spike), and bwrap holds inside the distro.
- **WS8.2** one-admin resumable setup (C3): one prompt, reboot-resume, idempotent, rollback, records whether
  a reboot was needed.
- **WS8.3** (the OAuth half of the two-channel item above) the OAuth token reaches only the CLI channel (C1 separation), never the control channel/env.
- **WS8.4** (restored, rev 2.17) dedicated non-root uid, default-user selection, no admin group, negatives (C6 / blocker 2).
- **WS8.5** per-run teardown kills only this session's agent group (C4), never the shared distro, within the C4 bound (5 s).
- **WS8.6** file scope via the broker (C2): workspace ro, scratch/state rw, host `%USERPROFILE%\.claude`
  unreachable.
- **WS8.7** no-network child (TTS/STT) inside the distro (netd denies every endpoint; model dir ro).
- **WS8.8** fail-closed: virt/WSL off ⇒ agent OFF + the fixed explanation.
Each with the mutant that flips it; all [W]/[U] on **win11-m8 only** (never the Win10 box — agent OFF there).

### WS8 proof blocks (rule 9, rev 2.19; DRAFT)

> DRAFT. No row is ready for implementation; the test names are TBD until the DRAFT gate closes. `wsl_live_test.py` is a discovery spike and never proof.

- **WS8.1 — isolation: host profile, processes and browser memory unreachable from the distro** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): re-enable the distro automount (or drop the bwrap mount namespace) so the host-profile canary and the canary outside the bwrap mounts become readable from the distro; the isolation test must go red. (Expected result: both canaries stay unreadable.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.2 — one-admin resumable setup (idempotent, rollback, reboot flag)** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): drop the rollback step (no `wsl --unregister` of the half-imported distro when a later setup step fails) and write a global `.wslconfig`; a forced mid-setup failure then leaves a distro and a global WSL change and the setup test must go red. (Expected result: a failed setup leaves no distro and no global WSL change.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.3 — two token channels (control capability, OAuth fd 3)** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): deliver the control capability in argv (or the OAuth token in the environment or a file) instead of the one-shot inherited pipe/fd; the canary then appears in argv, env, a file, a control frame or a log and the channel test must go red. (Expected result: the canary never appears there.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.4 — dedicated non-root uid, default-user selection, no admin group** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): launch as root (omit `-u <nonroot>`) or put the agent uid in an admin/sudo group; the negatives (mount, ptrace, host-exe launch, system-dir write) then succeed and the test must go red. (Expected result: all four negatives are refused.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.5 — per-run teardown within 5 s, never the shared distro** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): replace the per-run process-group kill by a plain SIGTERM of the leader only (or by a distro-wide `wsl --terminate`); a SIGTERM-ignoring child and a `setsid` child then survive, or the second session dies, and the teardown test must go red. (Expected result: those children are gone within 5 s and the second session survives.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.6 — file scope via the broker** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): remove the broker's per-component reparse-point and handle-based check (a name-only prefix test); `..`, a symlink, a junction, a hardlink or a parent swap then escapes the file scope and the broker test must go red. (Expected result: each of those is refused.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.7 — no-network child inside the distro** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): launch the child without its network isolation (skip the network-namespace unshare / share the distro's netns); the child then reaches the loopback decoy listener and an external address and the no-network test must go red. (Expected result: netd denies every endpoint for the child.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.8 — fail-closed: virtualization or WSL off** — status **UNPROVEN**. (a) entry point: `WslBackend` launched by the real browser/helper into the staged distro. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant (the defense REMOVED, rev 2.20 G2.2): remove the pre-launch virtualization/WSL availability check, so the launcher runs `wsl.exe` anyway on a host with virtualization or WSL off; the browser then crashes or hangs instead of showing the fixed explanation and the fail-closed test must go red. (Expected result: agent OFF plus the fixed message, not a crash.) (d) platform run: Win11 VM only (never the Win10 box). Proof type: none yet. UNPROVEN: DRAFT, no production `WslBackend` exists; `wsl_live_test.py` is a DISCOVERY-ONLY spike and is never proof. Missing: the production backend, a repaired and approved spike (blocker 1), and the named test and step. **Rule-9 fields incomplete: not ready for implementation.**
- **WS8.M — WS8/WS9 acceptance matrix (12 items)** — status **UNPROVEN**. (a) entry point: the real browser/helper -> production backend -> staged distro, bwrap and netd. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: one omit-defense mutant per item. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN until each item is a named driven test against the production backend. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS8):** [L] the `WslBackend` contract projection + the C1 auth / C2 broker / C3 setup units that are
Linux-testable; [W] WS8.1-8.8 on **win11-m8 only**. One UAC prompt (the C3 admin step), clicked by the owner
in person (`win-sandbox-uac`). WS11 stays blocked until all pass. (No Win10 leg — agent OFF on Win10; no WSL/agent there.)

### WS8/WS9 acceptance matrix (RoseCat 7516 — the closure spec)

The live discovery spike (`tests/windows/wsl_live_test.py`) establishes the TOPOLOGY facts above; it is a
spike, not closure. **WS8/WS9 close only when each item below is a named red→green test driving the
PRODUCTION backend** (`WslBackend` + the existing `LinuxBwrapBackend`/netd argv under the staged distro),
each with the mutant that defeats it, each a bounded machine-readable PASS/FAIL row preserving stderr on
failure, all `[W]`/`[U]` on **win11-m8 only** (never the Win10 box), as the standard user with no admin:

1. **Test hygiene / zero host mutation.** Preflight census (distros, default distro/version, `.wslconfig`
   absent+hash, feature state, import dirs, listeners, processes); app-owned `zb-test-*` names + ownership
   markers, refuse collisions; import only the hash-pinned rootfs into a per-run dir; unregister only the
   marked distros; **never `wsl --shutdown`, never change default distro/version/features, never touch
   another distro**; final census == baseline, no VHDX/import/process/listener leftover.
2. **Transport matrix (both directions, exact exposure).** MOVE a canary (not just connect) over AF_UNIX,
   IPv4/IPv6 TCP, AF_VSOCK/hvsocket for Windows→WSL and WSL→Windows; record NAT/mirrored mode and exact
   bind/connect addrs (`127.0.0.1`, `0.0.0.0`, `::1`, gateway, LAN decoy) under default WSL 3.0.3 with NO
   global `.wslconfig`. The plan picks ONE transport from the facts. **Observed so far (discovery spike):** Windows→WSL
   one reverse attempt failed without proving listener readiness; the transport direction (the C1/C5 proposal of agent-listens-in-distro / browser-connects) and the direct-dial denial remain PROPOSALS pending reviewed live evidence.
3. **Honest hostile reachability.** From a second throwaway distro and `zbother`, attempt the chosen
   endpoint and the app distro/import tree. Record honestly that a same-Windows-user native process or
   `wsl.exe -d <app> -u root` CAN enter the distro — **the WSL VM is NOT an isolation boundary against the
   owning Windows user**; the intended boundary is page content/hooks and OTHER Windows users/distros.
4. **Linux identity inside the distro.** Production launch = a dedicated **unprivileged Linux UID** (never
   WSL default root), no sudo/admin group, no dangerous caps/setuid, no writable rootfs, no ambient interop;
   pin `wsl.conf [user] default` AND pass an explicit user at launch. Negatives: `mount`, ptrace/
   `process_vm_readv`, host-exe launch, writing system dirs.
5. **Control-channel auth + token delivery.** An owner-only Windows file does NOT protect a capability from
   the same Windows user: deliver the secret by a non-env/non-argv path (prefer a one-shot inherited
   stdin/pipe bootstrap); prove it never appears in argv/env/logs/fs/control-frames/OAuth channel. Tests:
   wrong/missing token, stale-session replay, reused nonce, partial/oversized handshake, squatted port,
   pre-auth payload, session close, another user/distro, two simultaneous sessions; constant-time compare;
   no application byte before auth. State the achievable threat claim (not "owner-only TCP").
6. **Exact production bwrap launch** (not `bwrap --version`): the real `LinuxBwrapBackend` argv under the
   staged distro proving user/mount/pid/net ns, RO agent/runtime/workspace, RW scratch/state only, private
   `/proc`, existing seccomp/hook policy; inventory + DENY the WSL surfaces (`/mnt/c`, `/mnt/wsl`,
   `/mnt/wslg`, WSLg/Pulse/Wayland sockets, Windows PATH/binfmt interop + `/init` exec, host creds). An
   omit-bwrap/omit-netns/omit-RO mutant exposes a canary.
7. **Egress + bridges end to end** (WS9): through the real staged launcher, the CLI reaches only a fake
   `api.anthropic.com` via netd; sign-in adds only `platform.claude.com`; each hook has no API/proxy and
   carries bytes only to 51091/31337; speech has no network; direct IPv4/IPv6, UDP/TCP DNS, Windows
   loopback other ports, gateway, LAN/SMB, other distro, TEST-NET, non-allowlisted CONNECT all fail. No
   real API/site/credentials.
8. **Filesystem crossing (automount off).** The real broker/data path: host paths are **server-held
   capabilities, never agent-supplied strings**, resolved by a real held-handle check-and-use primitive
   (defined concretely in C2, replacing the removed WS0.5 "Option B"). Tests: `..`, symlink, junction/reparse,
   hardlink, parent swap, file swap, FIFO/special, concurrent replace, bounds, crash cleanup; workspace
   snapshot immutable; scratch/state returned only to approved roots via temp+flush+atomic replace;
   concurrent sessions can't see each other's staging.
9. **Per-run lifetime under concurrency.** Two marked sessions in one app distro: stop/crash one browser;
   its normal, SIGTERM-ignoring, setsid/double-fork, and closed-stdio children are gone within the bound
   while the second still answers; killing only `wsl.exe` shows whether Linux descendants survive; normal
   teardown NEVER calls `wsl --terminate <app>`/`--shutdown`; next startup censuses + reaps a planted
   prior-run survivor.
10. **Shared-utility-VM blast radius.** With a second marked distro doing work, app-session teardown /
    app-distro terminate / update / unregister do not alter it; `wsl --shutdown` affects ALL distros and is
    **pinned forbidden for production**; one app session cannot observe another's process/mount/token ns.
11. **Setup/update/uninstall state machine.** Live-measurable (rootfs bytes, distro-name ownership,
    import-dir DACL, exact `wsl.conf`, effective settings after the required per-distro restart) split from
    reboot/crash-cut UNIT tests (resume-after-reboot needs an explicit authenticated state machine, not a
    happy import). Idempotent second setup, partial import/name collision, update rollback, default-distro
    preserved. WSL is owner-installed/shared ⇒ uninstall removes ONLY zigBrowser's distro/import/state and
    never disables WSL/VMP or removes another distro/global config.
12. **Fail-closed + closure quality.** Wrong WSL version/mode, WSL1 distro, missing bwrap/kernel feature,
    userns/netns/seccomp failure, wrong UID, malformed `wsl.conf`, transport bind/connect/auth failure,
    netd failure, cleanup/census failure ⇒ agent OFF with fixed reason codes, never unsandboxed fallback.
    Final closure starts the real browser/helper → production backend → staged distro/bwrap/netd and
    observes the fake API/bridge/cleanup, mutants at each seam; record cold/warm start, import time,
    disk/memory cost, and concurrent-session behavior.

---

## WS9: netd egress INSIDE WSL2 (per OD-W4 — **DRAFT, NOT IMPLEMENTATION-APPROVED**)   [W]

> ⚠️ **DRAFT.** Not implementation-approved; see the WS8/WS9 DRAFT gate. C5 and the egress mechanics are
> **proposals/TBD** (blocker 5: the outer-broker/per-hook-netns topology is unresolved), not contracts.

**Goal.** The agent's egress is the **existing Linux netd running INSIDE the WSL2 distro** — the same
CONNECT/SNI allowlist (`api.anthropic.com`; plus `platform.claude.com` for sign-in) and the same
bubblewrap confinement as Linux. There is **no Windows-host WFP**: the WSL2 boundary + the in-distro
netd/bwrap confine the agent. The browser reaches netd/the agent across the WSL2 boundary over **loopback
TCP in the proposed direction — the agent LISTENS in the distro, the browser CONNECTS from Windows via
localhostForwarding** (a PROPOSED direction, unproven — one reverse attempt failed without proving listener readiness; see C1) — with the owner-only auth from WS8; that
control link is not the agent's egress path.

**C5 — Bridge topology across the WSL2 boundary (PROPOSAL / TBD; RoseCat 119108c + 9134b8b/7558 #5).** The
browser↔agent control link and the two hook bridges (`51091` TTS/notify, `31337` agent control) cross the
Windows↔distro boundary through **ONE trusted outer broker in the distro HOST netns** that the Windows side
dials into (a PROPOSED direction, unproven: one reverse attempt failed without proving listener readiness; direction + direct-dial denial remain proposals pending reviewed live evidence). The broker's host-netns control
listener is bound `127.0.0.1:<ephemeral>` (never `0.0.0.0`, never published) and — because co-tenant distros
share that host netns (observed in the discovery spike) — carries the **C1 per-session token + nonce/HMAC +
constant-time compare** before any byte, with a squatted port failing closed. **The hook keeps its existing
TCP contract** (`127.0.0.1:51091`/`:31337`): the broker hands a **per-hook capability** into each hook's
private netns and an **inner per-hook relay** binds those loopback ports there and forwards over the
capability (preserving `hook_run.py`/`relay.py`; no hook API changes), and the broker multiplexes it over the
held Windows connection (see the "C5 reverse relay" detail below for the exact namespace composition, inner
relay, framing and acceptance reds). The `zb-agent` control and `zb-hook` bridge capabilities are distinct;
the Windows relay forwards only to the fixed app-owned `127.0.0.1:51091`/`:31337`, never an agent-supplied
address; the Anthropic OAuth token never crosses any bridge (C1 separation); per-run teardown (C4) closes the
held connection and every handed capability.

### Egress mapping (WSL2 realization, per OD-W4)
1. **netd runs inside the distro** (Unix-socket or loopback as on Linux), confined by its own bwrap; the
   agent's `HTTPS_PROXY`/`HTTP_PROXY` name netd exactly as on Linux. No host-side listener or reserved
   port range.
2. The agent, inside the distro with **interop/automount off and no Windows PATH**, can reach **only**
   netd (and through it only the allowlist) via the distro's own netns/netd confinement — **not** a
   Windows WFP filter.
3. The browser↔netd/agent control link crosses the WSL2 boundary via loopback TCP (WS8 C1/C5: the agent
   listens in the distro, the browser connects from Windows); the sign-in netd (`net-login.json`) still
   allows exactly `api.anthropic.com` + `platform.claude.com`.
4. **Fail-closed:** no virt/WSL ⇒ no distro ⇒ no netd ⇒ agent OFF + the fixed explanation (WS8.8).

### Behaviors (hard gates; the Linux netd denials re-exercised in WSL2)
- **WS9.1** the CLI reaches the fake Anthropic API **only** through the in-distro netd (removing netd ⇒ red).
- **WS9.2** denials from the agent inside the distro: `1.1.1.1:443`, TEST-NET `192.0.2.1:443`, a loopback
  decoy, DNS to the resolver, and any non-allowlisted CONNECT host (403 from netd).
- **WS9.3** a hook reaches only the two bridges; both carry bytes.
- **WS9.4** the sign-in netd allows exactly `api.anthropic.com` + `platform.claude.com`, no bridges.

### C5 reverse relay for hook-initiated bridges (RoseCat affd577 #4)

Hooks run INSIDE the distro and initiate calls to the Windows loopback services `51091` (TTS/notify) and
`31337` (agent control). One reverse attempt failed without proving the Windows listener was ready, so — IF the proposed transport direction holds — a hook could not dial Windows directly; the transport direction and this direct-dial denial remain PROPOSALS pending reviewed live evidence.
The relay inverts the dial while keeping the allowed direction. **Namespace composition (RoseCat 9134b8b/7558
#5) — a PROPOSAL/TBD:** the broker that terminates the Windows connection and the endpoints the hooks use live
in **different** namespaces, and must not be conflated:
- **Trusted OUTER broker in the distro HOST netns** (NOT inside any agent/hook bwrap tree): a per-session
  component — part of the session supervisor / netd side, running as the non-root agent uid in the distro's
  default (host) network namespace. It owns the Windows-facing side.
- **Windows dials in once per session** to that OUTER broker's listener on `127.0.0.1:<control port>` in the
  host netns (the allowed Windows→WSL direction, C1) and holds the connection for the session; it
  authenticates with the C1 session token (nonce/HMAC, constant-time) before any byte. **Because the distro
  host netns is shared across co-tenant distros (observed in the discovery spike), this listener is reachable
  by a co-tenant, so the token auth is mandatory and a squatted `<control port>` fails closed** (the broker
  verifies it owns the port before "ready", and a session uses an ephemeral control port handed to Windows
  via C1, not a fixed one).
- **Per-hook endpoint handoff + an INNER per-hook relay that preserves the existing hook TCP contract
  (RoseCat 7594):** each hook runs in its OWN private network namespace (`bwrap --unshare-net`), so it has no
  route to the host-netns broker and the broker cannot "appear at `127.0.0.1:51091/31337`" inside it. The
  existing Linux contract already runs a **per-hook relay inside that hook's private netns** that binds
  loopback `127.0.0.1:51091` + `127.0.0.1:31337` and forwards to the bridge sockets (`hook_run.py:138-147`,
  `relay.py:4-8`; drawer plan §3c.8b) — and **every hook API must keep that TCP contract unchanged** (hooks
  are NOT re-pointed at a raw fd). So the topology is: the outer host-netns broker hands a **per-hook
  capability** into the private netns (an inherited fd / bind-mounted `AF_UNIX` socketpair), and the **inner
  per-hook relay binds only loopback `51091`/`31337` there and forwards over that capability** to the broker,
  which multiplexes it onto the held Windows connection. The hook keeps connecting to `127.0.0.1:51091/31337`
  exactly as today; only the relay's upstream changes.
- **Framing/backpressure/cancellation:** length-prefixed frames carry `(stream_id, op, bytes)`; each stream
  has an independent receive window (backpressure); either side sends `RST(stream_id)` to cancel; the broker
  bounds concurrent streams and frame size and drops oversize/pre-auth frames.
- **Windows relay side** forwards each stream to the **exact app-owned Windows loopback `127.0.0.1:51091` /
  `127.0.0.1:31337` services** — a fixed destination the relay owns, **never an agent-supplied address/port**;
  it never forwards anywhere else. The `zb-agent` control stream and the `zb-hook` bridge streams are
  **distinct capabilities** (distinct handed endpoints); a hook stream can reach only the two bridge ports,
  never the agent control op.
- **Lifetime:** the tunnel is bound to the session; teardown (C4) closes the held Windows connection, which
  resets every open stream and closes every handed hook endpoint.
- **Acceptance reds (later, implementation-approved revision):** the existing **bytes-through-both-ports
  positives** — a hook connecting to `127.0.0.1:51091` and to `127.0.0.1:31337` carries bytes end to end
  through the inner relay → capability → broker → Windows services — plus the **no-API / no-other-port
  negatives**: no hook API changes; a hook reaches ONLY those two loopback ports (never the agent-control op,
  never any other host/LAN address, never the Windows relay's destination directly); a co-tenant distro and a
  `zbother` process against the host-netns control port fail auth; a squatted control port fails closed; and
  the namespace boundary (hook private netns ↔ host-netns broker) is driven exactly, not assumed.

### Files / Green / Gate (WSL2 WS9)

- **Files touched:** `agent/host/zb_agent_host/netd.py` (unchanged allowlist/parse; runs inside the distro),
  the in-distro bridge broker + the Windows relay side (new, with the C1 auth), `tests/e2e/win_egress_test.py`
  and `tests/e2e/win_bridge_relay_test.py` (new, win11-only, VM-gated).
- 🔴 Red [L] the netd denial/allow units re-run under the distro's netns (no Windows-host dependency).
  🔴 Red [W] on win11-m8: the agent inside the distro reaches the fake `api.anthropic.com` **only** through
  the in-distro netd; `1.1.1.1:443`, TEST-NET `192.0.2.1:443`, UDP/TCP DNS, a loopback decoy, the WSL
  gateway, LAN/SMB, another distro and any non-allowlisted CONNECT all fail; a hook reaches **only** the two
  bridge streams and carries bytes; the sign-in netd allows exactly `api.anthropic.com` + `platform.claude.com`.
- 🟢 Green: netd runs inside the distro (reusing the Linux allowlist/parse verbatim), plus the C5
  reverse relay. 🔵 Refactor: the allowlist/ports/policy stay single-sourced in `sandbox.py`; netd's
  request parser is not forked. Mutants (each ⇒ red): drop netd ⇒ the bypass probe reaches the API;
  widen the allowlist ⇒ a denied host connects; give a hook stream the agent-control op ⇒ red; add a third
  sign-in host ⇒ red; let the relay forward to a non-bridge port ⇒ red; omit the pre-auth frame drop ⇒ a
  pre-auth frame is served.
- **Closure (WS9.1):** BLOCKING — SOURCE = the fake API behind the `--e2e-protocol` seam; TRIGGER = the
  helper's first SDK request; DRIVER = the real in-distro netd accept loop; OBSERVE = the fake API log +
  netd's census; RED-AT-SEAM = bypass netd ⇒ the distro netns denies ⇒ the request never lands.

### WS9 proof blocks (rule 9, rev 2.19; DRAFT)

> DRAFT, as WS8.

- **WS9.1 — the CLI reaches the fake API only through the in-distro netd** — status **UNPROVEN**. (a) entry point: the in-distro netd driven by the real helper's first SDK request. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: remove netd: the bypass probe must reach the API and the test goes red. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: DRAFT; needs the WS8 backend and the C5 topology (blocker 5). **Rule-9 fields incomplete: not ready for implementation.**
- **WS9.2 — denials: 1.1.1.1, TEST-NET, loopback decoy, DNS, non-allowlisted CONNECT** — status **UNPROVEN**. (a) entry point: the in-distro netd driven by the real helper's first SDK request. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: widen the allowlist: a denied host connects. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: DRAFT; needs the WS8 backend and the C5 topology (blocker 5). **Rule-9 fields incomplete: not ready for implementation.**
- **WS9.3 — a hook reaches only the two bridges, both carry bytes** — status **UNPROVEN**. (a) entry point: the in-distro netd driven by the real helper's first SDK request. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: give a hook stream the agent-control op. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: DRAFT; needs the WS8 backend and the C5 topology (blocker 5). **Rule-9 fields incomplete: not ready for implementation.**
- **WS9.4 — the sign-in netd allows exactly two hosts and no bridges** — status **UNPROVEN**. (a) entry point: the in-distro netd driven by the real helper's first SDK request. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: add a third sign-in host. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: DRAFT; needs the WS8 backend and the C5 topology (blocker 5). **Rule-9 fields incomplete: not ready for implementation.**
- **WS9.R — C5 reverse relay acceptance (bytes through both ports; co-tenant, squat and namespace negatives)** — status **UNPROVEN**. (a) entry point: a hook inside a private netns connecting to `127.0.0.1:51091` and `:31337`. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: let the relay forward to a non-bridge port; omit the pre-auth frame drop. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocker 5. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS9):** [L] netd units under the distro netns; [W] WS9.1-WS9.4 + the relay bypass/denial rows on
**win11-m8 only** (never the Win10 box — it ships browser-only with the agent OFF, WS9 does not run there).
Not a UI slice, so no real-screen case.

*(The former Windows-host WFP-filter egress — persistent WFP filters keyed on `zb-agent`/`zb-hook` SIDs,
a fixed reserved loopback port range, netd on the host — is REMOVED, not merely superseded, per OD-W4. netd
runs inside the distro and the C5 relay replaces the host-side filters.)*

---

## WS10: Sign-in on Windows   [W11], [U] — DRAFT, blocked on the WS8/WS9 DRAFT gate

> **REV 2.17 REWRITE FOR OD-W4 / WSL2 (C10).** WS10 was specified for the dropped native-Windows agent (ConPTY, a
> Windows `login.py` branch, `agent_login_win.c`). Under OD-W4, **`claude setup-token` runs in Linux inside the distro**
> under the login launch spec and the in-distro netd, with the Linux `pty` that `login.py` already uses — so there is
> **no ConPTY helper, no Windows `login.py` branch and no `agent_login_win.c`** (retired). The Windows side's real job
> is exactly three things: (1) **open the authorize URL** in the user's default browser with `ShellExecuteW` only when
> the user clicks Sign in (Copy link always works); (2) **carry the pasted `code#state` into the distro over the C1
> authenticated control channel** (never argv/env/file); (3) **receive the minted token over the login helper's one-shot
> channel and store it in the WS6 store** (Credential Manager). Win11 only; on Win10 the Sign-in affordance shows the
> agent-OFF explanation. Everything that touches WSL is behind the WS8/WS9 DRAFT gate.

- **WS10.1** `claude setup-token` runs **in the distro** under the login launch spec and netd (WS9.4) using the Linux pty
  (`login.py:31-38, 128-139`). The authorize URL frame reaches the Windows side; it is opened in the user's default
  browser with `ShellExecuteW` only when the user clicks Sign in.
- **WS10.2** the pasted `code#state` reaches the in-distro CLI over the C1 control channel; the token comes back over
  the login helper's one-shot channel (fd 4 as on Linux, bridged to a one-shot frame over C1) to the Windows side,
  which writes it to the WS6 store (`CredWriteW`) and nowhere else.
- **WS10.3** cancel and timeout end with the same codes as Linux (`cli`, `timeout`, `cancelled`,
  `shape`, `protocol`; agent_protocol.zig:292-307) — the closed map is in the Property register (C18).
- **Files touched (rev 2.17):** the Windows Secrets-window Sign-in controls (shared with WS6), a thin Windows-side
  login relay in the browser process, `tests/windows/win_login_test.py` (new; fake CLI in e2e). ~~`login.py` Windows
  branch, `src/agent_login_win.c`~~ retired (C10).
- 🔴 Red `win_login_test.py`: `assert frames[-1]["type"] == "done" and cred_read(test_target) == canary`
  (today there is no Windows login helper; `login.py` cannot even be imported on Windows: `fcntl` :28,
  `pty` :31, `termios` :38). More reds, each with a mutant: WS10.1 `assert auth_url_frame.url.startswith("https://") and shell_execute_calls == 0`
  until the user clicks Sign in (mutant: open the browser at start ⇒ red); WS10.2 `assert canary not in
  (stdout + stderr + helper_env)` and the token only on the one-shot handle (mutant: pass it in argv ⇒
  red); WS10.3 `assert error_codes == {"cli","timeout","cancelled","shape","protocol"}` for the five forced
  failures, same codes as Linux (`agent_protocol.zig:306`), (mutant: collapse `cancelled` into `cli` ⇒ red).
- 🟢 Green (rev 2.17): the Windows-side login relay + the Secrets-window Sign-in controls (shared with WS6); the
  in-distro login is the existing Linux `login.py`. ~~`login.py` Windows branch (ConPTY), `agent_login_win.c`~~ retired.
  🔵 Refactor: one `LoginSession` state machine (the Linux one) — no second Windows implementation.
- **Closure:** BLOCKING (Secrets window → login helper → CLI → store; OBSERVE = the store through
  `CredReadW` + the `SECRETS` census row).
- **Real-screen check `win-signin`:** Sign in opens the default browser, pasting the code saves the
  token, on the Win11 console.

### WS10 proof blocks (rule 9, rev 2.19; DRAFT)

> DRAFT, blocked on the WS8/WS9 DRAFT gate.

- **WS10.1 — `claude setup-token` runs in the distro; authorize URL opened only on click** — status **UNPROVEN**. (a) entry point: the Secrets window's Sign-in and the login relay. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: open the browser at start. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on the WS8/WS9 DRAFT gate; no code. **Rule-9 fields incomplete: not ready for implementation.**
- **WS10.2 — pasted code reaches the CLI over C1; the token returns on a one-shot channel into the store** — status **UNPROVEN**. (a) entry point: the Secrets window's Sign-in and the login relay. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: pass the token in argv. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on the WS8/WS9 DRAFT gate; no code. **Rule-9 fields incomplete: not ready for implementation.**
- **WS10.3 — cancel and timeout map to the same codes as Linux** — status **UNPROVEN**. (a) entry point: the Secrets window's Sign-in and the login relay. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: collapse `cancelled` into `cli`. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on the WS8/WS9 DRAFT gate; no code. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS10):** [W11] the Win11 VM + `win-signin` (the whole agent sign-in path is Win11-only: Win10 ships agent-OFF,
OD-W4 scope; Win10 shows only the agent-OFF explanation). Blocked on the WS8/WS9 DRAFT gate.

---

## WS11: Agent helper, chat and the approved commit on Windows   [W11], [U] — blocked on WS8 + WS9 (DRAFT gate) + WS5.10 (native card)

> **REV 2.17 REWRITE FOR OD-W4 / WSL2 (C10).** WS11 planned `agent_helper_win.c` with Windows pipes, restart backoff and
> a "stop ladder via the job". The job model is dropped (OD-W4): **C4 owns teardown** (per-session supervisor, marker
> reaping, the 5 s bound inside the distro), and the helper/chat engine (`chat.py`, `ClaudeSDKClient`, the Linux
> `agent_helper`) runs **in the distro**. The Windows side's job is: spawn `wsl.exe -d … -u …` with the C1 bootstrap,
> pump framed helper frames over the C1 channel into `agent_protocol.zig` validation and the Win32 drawer, restart with
> the 1/2/4/8 s backoff on supervisor loss, and on exit close the held connection so C4 tears the subtree down. No
> job-object stop ladder. Win11 only (Win10: agent OFF). **WS11.3's native Approve click requires the WS5.10 card, which
> does not exist yet** ("the only native minter is WS5's card" is false until WS5.10 lands).

- **WS11.1** the helper starts under the backend, receives the token on its channel, and emits a
  `ready` frame validated by `agent_protocol.zig`.
- **WS11.2** a chat round-trip streams `assistant_delta`/`assistant_message` into the Win32 drawer.
- **WS11.3** the positive approved commit: a `tool_use` from the fake Anthropic API arrives **through
  netd and the helper** (never the automation socket) → dry-run preview → the WS5 native card → a
  native Approve click → grant minted → revalidated → the real flow commits **exactly once** with
  `options.expect` in-ticket. Deny, an expired grant, a navigation retarget or a wrong account
  commits 0.
- **Files touched (rev 2.17):** a Windows-side helper relay (the Windows half of `agent_helper.c`: the `wsl.exe` spawn,
  the C1-channel frame pump, restart backoff 1/2/4/8 s; ~~stop ladder via the job~~ — teardown is C4's), `src/app.zig`
  (wire on Windows), the drawer's Send, bubbles and card (WS5.10; in `webview2_shim.cpp` as-built or the target
  `agent_drawer_win.cpp`), `tests/windows/win_chat_test.py`, `tests/windows/win_approved_commit_test.py` (new; as-built
  test dir).
- 🔴 Red `win_chat_test.py`: `assert "DRAWER\tbubble\tassistant\t" + expected in rows`. More reds: WS11.1
  `win_helper_ready_test.py`: `assert ready_frame["type"] == "ready" and token_on_channel == canary and canary not in helper_env`
  (mutant: pass the token in env ⇒ red); WS11.3 `win_approved_commit_test.py`:
  `assert fixture_commit_log == [one_commit]` after Approve and `assert fixture_commit_log == []` after Deny,
  expiry, retarget and wrong account (mutants: Approve handler minting before the click; grant not
  single-use; skipping `options.expect` ⇒ each flips one case); restart: `assert helper_restarts == [1,2,4,8]`
  seconds under repeated kills (mutant: constant 1 s ⇒ red).
- 🟢 Green (rev 2.17): the Windows-side helper relay, the drawer's Send/bubble/card code, `app.zig` wiring; teardown via
  C4 (no job stop ladder). 🔵 Refactor: one frame pump shared by the drawer and the e2e census writer; no second
  protocol-validation path outside `agent_protocol.zig`.
- **Closure criteria:** WS11.1 BLOCKING (setup → helper → `ready`; OBSERVE = the validated `ready` frame
  and the census row); the two chains below for WS11.2/WS11.3.

### Workflow Closure (WS11.2 chat)   [BLOCKING]
- **Chain:** `drawer Send (Win32) -> prompt frame on helper stdin -> chat.py Session -> ClaudeSDKClient -> the Linux `claude` CLI in the distro under the backend (rev 2.17: no `claude.exe`) -> netd -> fake API -> assistant frames on stdout -> agent_protocol.zig validate -> drawer bubble`
- **SOURCE:** the prompt + the fake API through netd. **TRIGGER:** the drawer Send handler
  (`highest_new_connector` = the Windows drawer→helper wiring). **DRIVERS:** the helper stdin/stdout
  pump (`chat.py _pump`) + the 50 ms coalescer + the Win32 message loop. **OBSERVE:** the bubble via
  the `--e2e-protocol` census. **RED-AT-SEAM:** disconnect the drawer→helper wiring ⇒ no bubble.

### Workflow Closure (WS11.3 approved commit)   [BLOCKING]
- **Chain:** `fake tool_use (through netd) -> helper pump -> broker preview -> WS5 card -> native Approve click -> grant minted -> revalidate -> flow commit (options.expect) -> fixture records exactly 1 commit`
- **OBSERVE:** the social fixture's commit log == 1. **RED-AT-SEAM:** Deny / expired / retargeted /
  wrong account ⇒ 0; routing `tool_use` over the socket must be impossible.

- **Real-screen checks:** `win-chat-reply` (a streamed reply appears in the drawer, text copyable)
  and `win-approval-card` (the user clicks Approve and sees one commit; Deny commits nothing), on the Win11
  console (rev 2.17: agent is Win11-only).

### WS11 proof blocks (rule 9, rev 2.19; DRAFT)

> DRAFT, blocked on WS8, WS9 and WS5.10.

- **WS11.1 — helper starts under the backend and emits a validated `ready` frame** — status **UNPROVEN**. (a) entry point: the Windows helper relay, drawer Send and native card. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: pass the token in env. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on WS8, WS9 and (WS11.3) WS5.10. **Rule-9 fields incomplete: not ready for implementation.**
- **WS11.2 — chat round trip streams into the Win32 drawer** — status **UNPROVEN**. (a) entry point: the Windows helper relay, drawer Send and native card. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: disconnect the drawer to helper wiring. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on WS8, WS9 and (WS11.3) WS5.10. **Rule-9 fields incomplete: not ready for implementation.**
- **WS11.3 — approved commit exactly once; Deny, expiry, retarget and wrong account commit zero** — status **UNPROVEN**. (a) entry point: the Windows helper relay, drawer Send and native card. (b) test and step: TBD: named only after the WS8/WS9 DRAFT gate closes. (c) mutant: mint the grant before the click. (d) platform run: Win11 VM only. Proof type: none yet. UNPROVEN: blocked on WS8, WS9 and (WS11.3) WS5.10. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS11):** [W] WS11.1-WS11.3 on **win11 only** (WS11 is the agent helper/chat/commit, which needs
WS8+WS9; Win10 ships agent-OFF per the OD-W4 scope, so WS11 does not run there) + both real-screen cases.

---

## WS12: Voice hooks on Windows (what the voice plans need from this plan)   [W], [U]

This plan does **not** build the speech engines; the TTS and STT plans own them. It provides the
hosts, the gate, the drawer hook points and the installer slot they wait on.

### Milestone role map used by the other plans (rev 2)

The voice plans name this plan's milestones by role, not number. This is the mapping they should adopt
once this plan is accepted (they own the edit; this plan does not edit them).

| Role named by TTS / STT / macOS plans | Milestone here | Notes |
|---|---|---|
| "test hosts", "the Windows launch plan's runner" | **WS0** (gate, probe, hosts) | runner is `tests/windows/gate.sh` |
| "build setup", "guest build" | **WS1** (`build-on-windows.sh`, `-Dtarget=x86_64-windows-msvc`) | replaces calling `build-in-guest.sh` directly |
| "drawer-port milestone" | **WS5** (Win32 drawer); voice hook points **WS12.1** | exports widen at `agent_drawer.zig:338-358` |
| "helper milestone" | **WS11** (needs WS7 setup, WS8 sandbox, WS9 egress, WS10 sign-in) | the TTS plan's frame pump hangs off WS11 |
| "sandbox milestone" | **WS8** (+ **WS9** egress); the no-network child is **WS8.7** | TTS W1.2 needs WS8.7 specifically |
| "packaging / installer slot" | **WS13** (WS13.1 census, WS13.3 size budget) | engine, ORT DLL, `models\stt\`, `models\tts\` |

| Voice-plan step | What it needs from this plan | Where |
|---|---|---|
| TTS **W0** (compile-only, Linux, `speech-win-compile -Dtarget=x86_64-windows-gnu`) | nothing (already [L]); its `cross-check` call is the `x86_64-windows-gnu` object check at build.zig:243-280 | — |
| TTS **W1** (the **bundled `zb-speech` engine + WASAPI audio** at run time, sandboxed with no network; *rev 1 of this plan wrongly described W1 as the WinRT/SAPI voices: those are TTS S3*; "NOT RUN: no Windows host configured") | the two hosts and `tests/windows/gate.sh`; `tests/windows/speech_win_test.py` runs as a gate phase on both hosts (x64; arm64 per OD-W5); the **no-network child (WS8.7)**; the MSI slot for engine, ONNX Runtime and model (WS13) | WS0, WS1, WS8.7, WS13 |
| TTS **W2** (spoken replies) | the Windows drawer + helper (speaker toggle in the drawer header, reply text from WS11) | WS5, WS11 |
| TTS **S3** (WinRT `SpeechSynthesizer` with SAPI 5 fallback; secondary system voices) | the hosts and the gate; the `winrt` SDK headers (`-Dwinrt_include` already exists) | WS0, WS1 |
| TTS **CW** (Windows voice cloning — the committed TTS plan rev 2 adds C1-C3 on Linux/macOS and **CW on Windows**) | the consent UI in the Win32 drawer (WS5/WS12.1), the WAV/mic capture path (provisioning item 12 on the VM, item 10 on the physical host), the **no-network sandbox child (WS8.7)** for the local clone, and the MSI slot for the cloning engine and the cloned-voice storage under the per-user data dir (WS13) | WS5, WS8.7, WS13 |
| STT **VS10** (whisper.cpp engine + WASAPI capture + permission mapping, no UI) | the VM build (`-Dtarget=x86_64-windows-msvc`), both hosts in the gate; the **WAV seam** on the VM (recorded-file tests only — no proven capture device, provisioning item 12) and **live microphone capture on the physical Windows 10 machine only** (item 10); the microphone-permission switch change is **per user (`zbtest`)**, never machine-wide | WS0, WS1 |
| STT **VS11** (drawer dictation) | a mic button and a draft-text API in the Win32 drawer; the physical host with a microphone; real-screen case `win-voice-live` | WS5, WS11 |
| STT **VSP** (model bundled in every installer) | the MSI slot `<INSTALLDIR>\models\stt\<file>` and the size check (WS13.3 now budgets the **sum** of all bundled payloads, not only the STT model) | WS13.3 |

- **WS12.1** (**NOT STARTED at HEAD; neither export exists** — C15; depends on the as-built drawer in
  `webview2_shim.cpp` or the target `agent_drawer_win.cpp`, WS5.9/WS5.10) the drawer exposes the two hook points the
  voice plans call (`zb_drawer_set_draft`, `zb_drawer_speaker_toggled`), stubbed until the voice plans land; 🔴 Red
  `win_drawer_voice_hooks_test.py`: `assert "DRAWER\tdraft\t" + text in rows` and
  `assert "DRAWER\tspeaker\ton" in rows` after the toggle (today neither export exists). Mutant: make
  `zb_drawer_set_draft` a no-op ⇒ red; a second mutant lets page JavaScript or a socket client call it
  (WS5.6 isolation) ⇒ red. 🟢 Green: the two exports in `agent_drawer_win.cpp` plus the census rows.
  🔵 Refactor: the same export names and row names as the GTK drawer (one spec for the three platforms).
- **WS12.2** `tests/windows/gate.sh --phase voice` runs the voice plans' Windows tests and applies the
  same fail-closed rules (no device ⇒ the test must report `NOT RUN: no capture device` and the gate
  fails, never passes).
- The voice plans' stale lines ("no Windows host", "no plan builds a Windows drawer") become stale
  once this plan is accepted; their owners update them (this plan does not edit them).

- **Closure:** WS12.1 LEAF (drawer exports, one process). WS12.2 BLOCKING for the gate path (`gate.sh
  --phase voice` → host → test → ASSERTS), with a [L] selftest case where the fake host reports
  `NOT RUN: no capture device` and the gate must exit nonzero (mutant: treat it as skip ⇒ red).
- **Real-screen checks:** none of the hook-point test's own (it is plumbing). The voice plans' UI cases run
  through this plan's real-screen runner on the hosts named here: `win-drawer-speech-default`,
  `win-drawer-speech-minimized`, `win-voice-window` (TTS W2, both hosts), `win-voice-permission` (STT VS10,
  Windows 10 with the microphone) and `win-voice-live` (STT VS11): the committed STT plan runs
  **live-microphone checks on the physical Windows 10 machine only**; the VM runs the WAV-seam
  (recorded-file) tests only — it has no proven capture device (STT D8 / provisioning item 12), so
  `win-voice-live` runs on Windows 10 only.

### WS12 proof blocks (rule 9, rev 2.19)

> Not started.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** `win_drawer_voice_hooks_test.py` is NEW (no file at HEAD): NEW step `windows-drawer-voice-hooks-live`, a member of `windows-live`, failing on skip. The WS12.2 case rides the registered step `windows-twohost-selftest` (a new case in `gate_twohost_selftest.py`).

- **WS12.1 — drawer voice hook points (`zb_drawer_set_draft`, `zb_drawer_speaker_toggled`)** — status **NOT BUILT**. (a) entry point: the two exports on the real drawer. (b) test and step: NEW `win_drawer_voice_hooks_test.py` (NEW step `windows-drawer-voice-hooks-live`, in `windows-live`). (c) mutant: make `zb_drawer_set_draft` a no-op; let page JavaScript call it. (d) platform run: Win11 VM and Win10 box. Proof type: none yet. Neither export exists.
- **WS12.2 — `gate.sh --phase voice` fails closed** — status **NOT BUILT**. (a) entry point: `gate.sh --phase voice`. (b) test and step: NEW case in `gate_twohost_selftest.py` (step `windows-twohost-selftest`): a fake host reporting `NOT RUN: no capture device` must make the gate exit nonzero. (c) mutant: treat it as skip. (d) platform run: none: Linux selftest. Proof type: none yet. Not started.

**Gate (WS12):** [W] the hook-point test; the voice tests run under the voice plans' own gates.

---

## WS13: Packaging, update, uninstall (signing DEFERRED — OD-W3, NOT a launch gate)   [W11] build, [W], [U]

### Behaviors
- **WS13.1 the MSI ships every component** the release needs, per user under
  `%LOCALAPPDATA%\Programs\zigBrowser` (OD-W1); a census lists every PE/file and fails on an unlisted one (rev 2.19: the census is a TRIPWIRE, rule 5; WS13.1 closes only when the installed product is installed and run from its install directory, see the WS13 proof blocks).
  **Rev 2.17 (C11, OD-W4) component list:** browser, manifest/`.rc` (WS5.8), the drawer, the Secrets/CredMan code, the
  voice engines/models (voice plans), and — **Win11 build only** — the WSL2 agent payload: the **distro rootfs tarball
  (pinned SHA-256) and the in-distro agent home/`zb_agent_host`/Linux `claude` as data inside it**, plus the
  `wsl.exe` launcher/setup code (no separate Windows exe required). **Explicitly NOT shipped under WSL2:** a
  `zb-agent-sandbox-setup.exe` sandbox-user installer, a Windows Python runtime, a Windows `claude.exe`, a native
  `zb-claude.exe`, any WFP/sandbox-user component. The census **asserts those are ABSENT**. On a Windows 10 (agent-OFF)
  build the census asserts the whole WSL2 payload is absent.
- **WS13.2 WebView2 runtime handling (OD-W8):** the bootstrapper custom action's failure is surfaced
  (not `Return="ignore"` silently): the installer records the result, and the app's WS1.4 check shows
  the exact message with the standalone-installer link. **Unchanged at HEAD (W13): `Return="ignore"` is still at
  `zigBrowser.wxs:80`**, so a failed bootstrapper is still swallowed — OPEN.
- **WS13.3 size:** the build computes the **sum** of every bundled payload (browser, the distro rootfs + agent payload,
  WebView2 standalone installer if OD-W8 picks it, the STT model, the TTS model and
  ONNX Runtime) and fails if any cabinet exceeds 2 GB. **Rev 2.17 (W13): `MediaTemplate EmbedCab="yes"`
  (`zigBrowser.wxs:19`) has no cabinet cap, so the 0.8-1.5 GB speech model plus the rootfs will break the 2 GB limit
  — the `.wxs` must set `MediaTemplate MaximumUncompressedMediaSize` (split cabinets) before any model is added.**
  The splitter's size invariant is in the Property register (C18). Known inputs: STT q8_0 823,369,779 bytes (f16 would be
  1,533,763,059, q5_0 539,212,467; STT plan O1 is still open), TTS about 0.1-0.13 GB (unverified), so the
  choice of the STT file moves the total from about 1.0 to 1.7 GB before the Python runtime and `claude.exe`
  are added. The MSI uses split cabinets (`MediaTemplate MaximumUncompressedMediaSize`) and the test asserts the
  number of cabinets and each one's size.
- **WS13.4 uninstall (NORMATIVE, rev 2.17, C11 — the WSL-era uninstall, Win11 only).** The uninstall removes the files,
  shortcuts and HKCU keys, and **only zigBrowser's own WSL state: our versioned distro(s) `zigbrowser-<version>-<nonce>`
  (unregistered), their import dirs, the C3 current-pointer/lease/state files and the staging dirs — and nothing else.**
  It **never** disables WSL/VMP, removes another distro, touches `.wslconfig`, runs `wsl --shutdown`, or unregisters a
  distro that still has a live session (it takes the C4 lock exclusively and holds it across the census and the
  unregister). Because enabling WSL/VMP is a global change that other software may now depend on, the uninstaller
  **states** that those features are left enabled (C3 "uninstall honesty"). The uninstall must never report success
  while any zigBrowser distro, import dir, state/lease file or pointer survives. The MSI is `perUser`/`limited`, so the
  WSL unregister is an unprivileged per-user action (no UAC; `wsl --unregister` of our own distro needs none) run by an
  immediate custom action or an in-app "Remove agent" step, and the probe is also run in the state where the MSI
  uninstall finished but a distro survived (the product then shows "finish removing the agent" on next launch).
  **The WSL post-uninstall probe runs on the Win11 VM; the Win10 box (writable, browser-only) runs its OWN browser
  post-uninstall probe, WS13.4-W10 below, which also asserts that a Win10 (agent-OFF) build has no WSL payload to remove.** The
  historical sandbox-user/WFP census text below is retained only as history and gates nothing.
  *(⚠️ HISTORICAL /
  NON-NORMATIVE, OD-W4 — see the scope banner. The sandbox-user/WFP cleanup described in the rest of this
  bullet and its SIX-kinds census below are the DROPPED dedicated-user model. Under WSL2 (C3, DRAFT) uninstall
  removes only zigBrowser's distro/import/state, cannot un-enable global WSL/VMP, and there are no sandbox
  users/profiles/WFP filters/providers/sublayers to census. The text below is kept only as history.)* It was
  to run (via the elevated `zb-agent-sandbox-setup.exe --uninstall`, one UAC prompt) a removal of the two
  sandbox users, their profiles and the WFP filters; a post-uninstall probe finds none. **Rev 2 constraint:**
  the current `.wxs` is
  `InstallScope="perUser"` with `InstallPrivileges="limited"`, so an MSI deferred custom action **cannot**
  elevate. Two designs only: an immediate custom action that `ShellExecute`s `runas` (a UAC prompt in the
  middle of Add/Remove Programs, may be declined), or an in-app "Remove agent sandbox" step before
  uninstall. Either way the MSI uninstall can finish while the users and filters remain, so the probe is
  also run in that state and the product shows a "finish removing the sandbox" action on the next launch of
  any surviving component. **The uninstall must never report success while any sandbox user, WFP
  filter/provider/sublayer, profile folder or scheduled task survives:** WS13.4 fails if the uninstaller
  returns success (exit 0 / "Removed") while the post-uninstall probe still finds a survivor, and a clean
  result is asserted only once that probe is empty. Per OD-W1 (DECIDED: per-user WiX 3.14 MSI), the
  uninstaller is the MSI's per-user uninstall plus the sandbox `--uninstall` it invokes; the census covers
  exactly what that MSI + sandbox setup created.
- **WS13.5 update (OD-W2):** the chosen updater verifies the update's signature before running it; a
  tampered update is refused.
- **WS13.6 signing — DEFERRED (OD-W3 decided: no signing for launch); NOT a launch gate; stays OPEN.**
  If/when a code-signing identity is later adopted, this slice would Authenticode-sign every PE then the
  MSI inside-out with an RFC 3161 timestamp (jsign from Linux for Artifact Signing, or signtool on the
  VM), `Get-AuthenticodeSignature` `Valid` on both hosts, publisher shown in SmartScreen, Smart App
  Control not blocking. **None of this is built or gated for launch.** The ONLY hard rule now: **the
  artifact is an unsigned development build and NOTHING may claim it is "signed" or "distributable".**
  Status tracked via Agent Mail / plan status and the beads epic zigBrowser-4pa (rev 2.17, W5: `bd` is NOT
  migration-locked — the review filed issues 4pa.31-49 with it).
- 🔴 **WS13.4 red (NORMATIVE, rev 2.17, C11; replaces the six-kind sandbox/WFP assertion below)** on the Win11 VM:
  `assert distros_after == [] and import_dirs_after == [] and state_files_after == [] and global_wsl_features_unchanged and other_distros_unchanged and not (uninstall_reported_success and (distros_after or import_dirs_after or state_files_after))`.
  Mutants, each ⇒ red: leave a distro registered; leave an import dir; leave the lease/pointer file; **disable WSL/VMP
  (forbidden)**; unregister a co-tenant distro (forbidden); report success while any zigBrowser distro survives; run
  `wsl --shutdown`.
- 🔴 More reds (each with a mutant): WS13.1 CLOSING proof (rev 2.20, L3.4): `assert installed_exe_runs and m8_render_from_install_dir_passes` after a per-user install (mutant: remove a listed binary from the payload ⇒ the installed run fails ⇒ red); the census `assert census.unlisted == [] and census.missing == []` is a labelled **TRIPWIRE** (a file listing, rule 5) that may fail a build but never closes WS13.1 (mutant: add an unlisted DLL ⇒ the tripwire is red); WS13.2 `assert install_log.bootstrapper_result is not None and (rc == 0 or app_shows_runtime_message)`
  (mutant: keep `Return="ignore"` and drop the log ⇒ red); WS13.3 `assert all(c.size < 2**31 for c in cabinets)`
  (mutant: one 2.1 GB payload ⇒ red); ~~WS13.4 `assert users_after == [] and profiles_after == [] and wfp_filters_after == [] and wfp_providers_after == [] and wfp_sublayers_after == [] and tasks_after == [] and not (uninstall_reported_success and (users_after or profiles_after or wfp_filters_after or wfp_providers_after or wfp_sublayers_after or tasks_after))`
  (the probe censuses all SIX kinds the uninstall normative names in §3 item (d) — sandbox **users**, **profile folders**, WFP **filters**, WFP **providers**, WFP **sublayers** and scheduled **tasks** — "no user, profile folder, filter, provider, sublayer or scheduled task behind"; mutants, each ⇒ red: skip the filter removal; leave a profile folder; leave a WFP provider; leave a WFP sublayer; skip a scheduled task; and report uninstall success while ANY of a user/profile/filter/provider/sublayer/task survives)~~ (HISTORICAL, dropped design — superseded by the normative WS13.4 red above); WS13.5 `assert tampered_update_refused` (mutant: skip the signature
  check ⇒ red). WS13.6 (signing) is **DEFERRED and not a launch red** — no `sig.Status == "Valid"`
  assertion gates launch; if signing is ever adopted it would add those checks (+ a `HashMismatch`
  negative), but they are explicitly out of the launch gate.
- 🟢 Green: the `.wxs` components for every release PE, `build-msi.ps1` cabinet split and census,
  `components.json`, the uninstall wiring above. (`sign.sh`/`sign.ps1` is DEFERRED — OD-W3; not built
  for launch.)
  🔵 Refactor: one component manifest feeds the MSI, the census and the macOS-style "every shipped binary is
  listed" check; the installer stays free of policy literals (ports, allowlists).
- **Files touched:** `packaging/windows/zigBrowser.wxs`, `packaging/windows/build-msi.ps1`,
  `packaging/windows/gate.ps1`, `packaging/windows/components.json` (new census),
  `packaging/windows/sign.sh` (new, jsign) or `sign.ps1`, `tests/e2e/msi_install_test.py`,
  `tests/windows/gate.sh` (package phase).
- 🔴 Red `msi_install_test.py` (rev 2.20, L3.4; step `windows-msi-install-live`, in `windows-live`): the closing assertion is `assert installed_exe_runs and m8_render_from_install_dir_passes` (install the per-user MSI, then launch the installed exe and run the m8 render from the install directory; today the
  MSI ships only `zigBrowser.exe` + the bootstrapper). The census assertion `assert census.unlisted == [] and census.missing == []` is kept ONLY as a labelled **TRIPWIRE** and never closes WS13.1. (No signature assertion — signing is deferred,
  OD-W3, and is not a launch red.)
- **Closure:** LEAF (packaging assertions), except WS13.4 BLOCKING (installer → per-user WSL unregister →
  distro/state; OBSERVE = the post-uninstall probe of distros, import dirs and state files on the Win11 VM).
- **Real-screen check `win-install-smartscreen`:** the user downloads the installer in Edge on the Win11 console and
  records what SmartScreen shows; the same case is repeated on the Win10 box console (restored Win10 leg, own record).

- **WS13.4-W10 (restored Win10 leg, rev 2.18; its OWN test and its OWN evidence line; NOT yet run).** Test: the `msi_install_test.py` Win10 leg:
  `zbtest` installs the per-user browser MSI on the Win10 box with the install directory pinned inside `C:\Users\zbtest\zb\` (the `.wxs` must
  expose an install-directory override, an open task; if it cannot, ask the owner before installing to the default
  `...\AppData\Local\Programs\zigBrowser`), asserts the WS13.1 census, runs the uninstall, and asserts
  `assert files_after == [] and shortcuts_after == [] and hkcu_keys_after == [] and wsl_payload_present is False and not (uninstall_reported_success and (files_after or shortcuts_after or hkcu_keys_after))`.
  Mutants, each ⇒ red: leave a file; leave a shortcut; leave an HKCU key; report success while any survives. The agent/WSL part of
  the census asserts those components are ABSENT on this agent-OFF build. Own evidence line: the Win10 run's census and probe output
  with the host `identity_marker`, in the commit message, after the Win10 release (RoseCat exact-commit approval + orchestrator
  release). A WebView2 runtime install on that box, if the runtime is missing, is system-wide: ask the owner first.

### WS13 proof blocks (rule 9, rev 2.19)

> A file census is a listing and a TRIPWIRE; packaging is proven by installing and running the product.
>
> **Registration (rev 2.20, G2.1; rule 9(b)).** `tests/e2e/msi_install_test.py` (WS13.1, WS13.2, WS13.4, WS13.4-W10) -> NEW step `windows-msi-install-live`, a member of `windows-live`, failing on skip (WORK: it is a draft until the step exists). WS13.3 -> NEW step `windows-msi-cabinet-selftest` (Linux property test over the splitter, in `zig build test`) plus the real MSI build on the VM inside `windows-msi-install-live`. `components.json` is a data file for the census TRIPWIRE.

- **WS13.1 — the MSI ships every component** — status **NOT BUILT**. (a) entry point: the per-user MSI installed on a host, then the installed exe launched and the m8 render run from the install directory. (b) test and step: `tests/e2e/msi_install_test.py` (NEW step `windows-msi-install-live`) plus NEW `components.json`; the census (a file listing) is a TRIPWIRE and never the closing proof. (c) mutant: add an unlisted DLL to the payload: the census tripwire fails; remove a listed binary: the installed run fails. (d) platform run: Win11 VM and Win10 box. Proof type: tripwire-only today. REWRITTEN + NOT BUILT: the census lists files, so it cannot close WS13.1; the closing proof installs and runs the installed product.
- **WS13.2 — WebView2 bootstrapper failure is surfaced** — status **NOT BUILT**. (a) entry point: an MSI install with the bootstrapper forced to fail. (b) test and step: `msi_install_test.py` (install log and the app's runtime-missing message). (c) mutant: keep `Return="ignore"` and drop the log. (d) platform run: Win11 VM. Proof type: none yet. `Return="ignore"` unchanged at `zigBrowser.wxs:80`.
- **WS13.3 — cabinet sizes stay below 2 GB** — status **NOT BUILT**. (a) entry point: `build-msi.ps1` with generated payload sizes. (b) test and step: NEW property test over the splitter (NEW step `windows-msi-cabinet-selftest`) plus a real MSI build on the VM (`windows-msi-install-live`). (c) mutant: cap at `<=` instead of `<`. (d) platform run: Win11 VM. Proof type: none yet. `MediaTemplate` has no cabinet cap.
- **WS13.4 — uninstall removes only zigBrowser's WSL state (Win11)** — status **NOT BUILT**. (a) entry point: the real uninstall. (b) test and step: NEW `msi_install_test.py` leg with the post-uninstall probe. (c) mutant: leave a distro, import dir, or lease; disable WSL or VMP; report success while any survives. (d) platform run: Win11 VM only. Proof type: none yet. Nothing built.
- **WS13.4-W10 — Win10 browser uninstall** — status **NOT BUILT**. (a) entry point: per-user MSI install and uninstall as `zbtest`. (b) test and step: `msi_install_test.py` Win10 leg. (c) mutant: leave a file, shortcut or HKCU key; report success while any survives. (d) platform run: Win10 box, after the Win10 release. Proof type: none yet. Not run; needs an install-directory override.
- **WS13.5 — update verifies the signature** — status **UNPROVEN**. (a) entry point: the chosen updater (OD-W2 not decided). (b) test and step: none. (c) mutant: skip the signature check. (d) platform run: Win11 VM. Proof type: none yet. UNPROVEN: no updater exists and OD-W2 is open; post-launch. **Rule-9 fields incomplete: not ready for implementation.**
- **WS13.6 — signing (DEFERRED, OD-W3)** — status **UNPROVEN**. (a) entry point: none (deferred). (b) test and step: none. (c) mutant: none. (d) platform run: none. Proof type: none yet. UNPROVEN and not a launch gate: nothing may claim signed or distributable. **Rule-9 fields incomplete: not ready for implementation.**

**Gate (WS13) — rev 2.18 (C11, C1): [W] on the Win11 VM AND the Win10 box.** The browser MSI install/uninstall/census runs on the Win11 VM and,
as the separate leg WS13.4-W10, on the Win10 box (writable, standard user `zbtest`, work confined to `C:\Users\zbtest\zb`; the earlier text
that said the Win10 machine receives no install and no post-uninstall probe is removed). The **agent/sandbox/WSL
packaging census (distro rootfs, import dir, the sandbox/voice-agent components) is win11 only** — on Win10
the census asserts those components are ABSENT (agent-OFF build), per the OD-W4 scope. Signing is DEFERRED (OD-W3) and is **NOT part
of the WS13 launch gate** — the gate asserts only the unsigned MSI's contents/install/uninstall/census,
never a signature. The **final
packaging gate depends on every release component, not merely on WS7 having started**: WS13.1's census must
find each component owner's artifact — browser (WS1), drawer (WS5), setup (WS7), sandbox setup (WS8), egress
helper (WS9), sign-in (WS10), agent host/helper (WS11) — **and the voice packaging the voice plans own** (the
TTS engine + model and the STT engine + model via their VSP/W1 slices); a missing component fails the census,
so WS13's gate cannot pass until every component owner and the voice-packaging owners have landed (rev 2.19: the census is a TRIPWIRE; the gate also requires the installed product to be installed and run from its install directory, WS13.1). The
`win-install-smartscreen` case is a UI/real-screen case for both hosts (the Win11 console and the Win10 monitor); on the Win10 box the
install is by `zbtest` (install directory inside `C:\Users\zbtest\zb`) and the browser post-uninstall probe is WS13.4-W10 above.

---

## Dependency order

> **Re-baselined order (rev 2.17; C4, C3, C6; section C default pending owner ratification).** At HEAD the code was
> built OUT OF ORDER: WS3, WS5, WS6 and WS7 (about 170 commits) landed before WS2a-c, and WS4 cannot start at all. The
> order from here is: **(1)** finish WS0.4/WS0.8/WS0.9 (the gate and runner) and WS1.2 (the m8 harness every later e2e
> reuses); **(2)** the **WS2a.0** isolated-world spike and the **WS2b.1** `isTrusted` spike (and WS2b.0 capability
> honesty); **(3)** the WS2a port (`automation_wv2_port.zig`, Closure A) then WS2b, WS2c; **(4)** **WS3.4** — wire the
> cookie port and the default/owner-only profile with their e2e; **(5)** WS4 (needs WS2a.1); **(6)** the WS5/WS6
> amendments (WS5.8-WS5.10, the WS6 consumer); **(7)** WS7-WS11 only after the WS8/WS9 DRAFT gate closes, and WS7/WS10/
> WS11 rewritten for WSL2 first. **No new WS5/WS6/WS7 feature work until WS2a.1 is green** except the named amendments.
> Retirements (D.6) are independent and may land any time.

`WS0 → WS1 → WS2.0 → WS2a → WS2b → WS2c → WS3 → WS4`, and in parallel after WS1 (original order, history; superseded by the box above):
`WS5 (drawer) → WS6 (Secrets) → WS7 (setup) → WS8 (sandbox, hard gates) → WS9 (egress) → WS10
(sign-in) → WS11 (helper, chat, approved commit; needs WS4 + WS5 + WS8 + WS9)`. (WS8 and WS9 are coupled by
the WSL2 topology, not WFP: WS8 stands up the distro + the in-distro bubblewrap/netns and the C1/C5 control
and relay plumbing; WS9 proves the in-distro netd egress/denials and the hook-bridge relay over that
plumbing. WS8.1-WS8.6 land first, then WS9 proves egress through them. There are no Windows-host WFP filters.)
`WS12` follows WS5
(hook points) and WS11 (W2/VS11); **TTS W1 additionally waits on WS8.7**. `WS13` packaging can START after WS7,
but its **final gate depends on every release component** (WS1, WS5, WS7, WS8, WS9, WS10, WS11) and the
**voice packaging** the voice plans own (TTS engine+model, STT engine+model via VSP/W1): WS13.1's census is a TRIPWIRE (rev 2.20, L3.5) that fails
on any missing component, and the final packaging gate also requires the INSTALLED product to run from its install directory (WS13.1), so the gate cannot pass until every component owner has landed. Its
signing is DEFERRED (OD-W3) and is not a launch gate. Decision status: OD-W1/W3/W4/W6 are all DECIDED
(2026-10-21) — WS5's green files are native Win32 (OD-W6), WS8 is WSL2 (OD-W4), WS13 targets the per-user
MSI (OD-W1) and signing is deferred (OD-W3). WS13's remaining launch dependency is OD-W8 (the WebView2
runtime distribution); OD-W2 (update) is post-launch. The still-open items are OD-W2/W5/W7/W8/W9.

## Per-slice gate protocol (all slices)

1. Mail "taking the gate slot" for gate runs only (trust only "slot FREE" mails). 2. Write the
slice's red tests in **unregistered** files (not wired into any `build.zig` step or the gate
phase list); record the red runs on the Win11 VM. 3. Green, and register the tests in the same
green commit (live steps behind the `windows-live` aggregate with fail-on-skip, D.1). 4. Refactor (the checklist in each slice). 5. Quiet gate from a clean `git archive
HEAD` plus the slice's files: the Linux gate under a private Xvfb as it does today, then **the real command in D.2**
(`gate.sh --probe-only` + `ZB_WIN_GATE=1 python3 -I <test>` per live test with `ASSERTS n>0`, no skip) until WS0.9's
product-run mode exists, and `tests/windows/gate.sh --product` after (rev 2.17, C2; the earlier "`gate.sh` on both
hosts" referred to a mode that does not exist — the no-argument gate exits 2). 6. Commit only the slice's own hunks (the worktree is shared;
never stage another agent's work). 7. Mail RoseCat for review. 8. UI slices: the orchestrator runs
the named real-screen cases with the user on the Win11 console (C1); not approved until they pass.
**Never** rewrite history: no reset, rebase or amend of committed work, even unpushed; fix forward
with a new green commit. A slice is done only when its closure e2e was observed to execute with
nonzero assertions on the Win11 VM AND on the Win10 box (C1) **and its live row is accepted
(D.4); a registered live step run with no host FAILS (D.1)**. **Rev 2.19 (rules 3 and 9):** a behavior is not ready for implementation until it states its entry point, test and step, mutant and platform run; and it is not accepted until the commit message records the red failure, the green, and the production mutant with its command and failing output.

## Real-screen checks (all, by slice)

> **Rev 2.18 (C1, C14):** "both" below reads **"the Win11 console AND the Win10 monitor"**; the Windows 10 monitor leg is restored (the Win10 box is a
> writable test host, run after its release). `tests/manual/real_screen_check.py` is X11-only today, so a Windows capture +
> foreground-proof backend is a prerequisite for scheduling any `win-*` case. `win-sandbox-uac` is Win11-only
> (clicked by the owner). The agent cases (`win-sandbox-uac`, `win-signin`, `win-chat-reply`, `win-approval-card`) never
> run on Win10 (agent OFF). `win-voice-live`/`win-voice-permission` need a microphone host and stay as the voice plans
> define them (the Win10 box is writable, so they are schedulable there once a microphone is attached and the per-user microphone permission for `zbtest` is on, item 10).

| Case | Slice | Where |
|---|---|---|
| `win-render` | WS1 | Windows 10 monitor + VM console |
| `win-native-click` | WS2b | both |
| `win-popups`, `win-crash-page` | WS2c | both |
| `win-drawer-open`, `win-drawer-fold`, `win-drawer-drag`, `win-drawer-copy`, `win-drawer-dpi` | WS5 | both |
| `win-secrets-window` | WS6 | both |
| `win-sandbox-uac` | WS8 | both (the user clicks the UAC prompt) |
| `win-signin` | WS10 | both |
| `win-chat-reply`, `win-approval-card` | WS11 | both |
| `win-voice-live` | WS12 / STT VS11 | Windows 10 (microphone); VM only if item 12 is proven (STT plan says both) |
| `win-voice-permission` | STT VS10 | Windows 10 (microphone), `zbtest` session |
| `win-drawer-speech-default`, `win-drawer-speech-minimized`, `win-voice-window` | TTS W2 | both |
| `win-install-smartscreen` | WS13 | both |

## Unverified items this plan depends on (each is a spike or a red test first)

1. CDP isolated worlds inside WebView2 (WS2a.0).
2. CDP input producing `isTrusted: true` in WebView2 (WS2b.1).
3. AF_UNIX with the Zig 0.16 std (WS2.0). **Win11 VM: proven** by the production e2e at the `win10_rs4` floor (f29e490;
   the zbother run 3cb8722). **Windows 10: unverified until the restored leg WS2.0-W10 runs on the Win10 box** (a writable test host, rev 2.18; Win10 release rule
   applies). The `win10_rs4` floor requires 1803 or later there.
4. `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` as a runtime-missing seam (WS1.4).
5. A public mechanism that recovers a hung WebView2 renderer (WS2c.3).
6. OAuth fd-3 delivery (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`) to the CLI **inside the distro** via an
   inherited fd (Linux semantics; the Windows launcher passes it through `wsl` into the agent's stdio
   bootstrap), kept distinct from the C1 control capability (WS8.3).
7. ~~Cross-user `OpenProcess` denial, desktop separation, and job-escape paths for the dedicated-user
   backend.~~ **Removed (OD-W4):** there is no Windows dedicated-user backend; isolation is the WSL2
   distro + the in-distro non-root uid under bubblewrap/netns (WS8.1, WS8.4, WS8.5).
8. Whether `claude setup-token` works without a terminal on Windows (WS10.1).
9. WebView2 rendering on the VM's QXL / basic display adapter (WS1).
10. ~~Nested virtualization for the WSL2 fallback inside the KVM guest.~~ **Measured (2026-10-21):** WSL2
    runs on win11-m8 and a benign "nested virtualization is not supported" notice prints; the agent needs no
    nested virt, so this is not a blocker (WS8).
11. The Windows 10 machine's edition, build and preinstalled WebView2 runtime (provisioning item 4).
12. Whether the Win11 VM the user provides is the existing `win11-m8` domain (rev 2: that domain is
    currently running with no snapshots; the user's VM may still be a different one).
13. ~~Whether a standard-user launcher can create a suspended process as another user with
    `CreateProcessWithLogonW` and assign it to a job.~~ **Removed (OD-W4):** no `CreateProcessWithLogonW`,
    no Secondary Logon, no job-object user isolation — the agent launches as a non-root uid inside the
    imported distro (measured: `wsl --import` + launch need no admin) (WS8).
14. Whether libvirt 11.3 can snapshot this UEFI + raw NVRAM + swtpm guest, and by which method (VM snapshots).
15. Whether the `ich9` SPICE-audio device gives Windows a capture endpoint and `virt-viewer` forwards a microphone.
16. ~~Whether `.fromMode`/`chmod` in `automation_server.zig` compile for Windows~~ **Resolved (rev 2.7):** at the
    `win10_rs4` floor `.fromMode` does not exist on Windows and was replaced (f29e490); the floored cross-check
    object compiles the whole start path.
17. Whether emulated AVX2 (the STT baseline) runs under Prism on the Windows 11 on Arm builds users have (OD-W5 only).
18. Whether Windows OpenSSH on the physical machine honors `from=`/`restrict` and `AllowUsers` as assumed (check
    when sshd is first enabled, by the owner).
19. Whether MSIX file-system virtualization breaks the shared profile and agent-home paths (OD-W1 only).
20. Whether the UAC prompt for a standard user on the physical machine can run the setup with the right target SID (WS8.2a).

## Review log (rev 2, 2026-10-19)

**Verified true at HEAD 032a2c9** (read-only; no builds, no SSH, nothing started): `webkit_shim.h` is 435
lines with 75 declarations = 73 shim functions + `zb_policy_decide` :427 + `zb_ipc_dispatch` :428;
`webview2_shim.cpp` is 771 lines with exactly three `extern "C"` definitions (`zb_app_run` :707,
`zb_run_screenshot` :751-757 returning `ZB_EXIT_SNAPSHOT_FAILED`, `zb_version_line` :759-771), so **3 of 73 are
implemented and 0 of the other 70 exist** (the one "stub" is `zb_run_screenshot`); `wkwebview_shim.m` defines six;
the default environment call is :692; the run loop :696-703; WRL `using` :18-19; IPC :412-463; marker script
:561-577; `build.zig` `CheckWebView2SdkStep` :16-77 (`wrl.h` :67, `WebView2LoaderStatic.lib` :61), `resolveBackend`
:1481-1488, `configureWebView2Backend` :1535-1558 (`WebView2LoaderStatic` :1551), `ipc-test-win` :234,
`cross-check` :243-280, `automation-afunix-spike-win` :282-291; `tests/guest/` contains exactly
`build-in-guest.sh` (28), `setup.ps1` (431), `ssh.sh` (50); `planSocketPath` :17-35;
`automationSocketPath` app.zig:453-460; `runAgentSetup` refusal app.zig:52-55 and `/proc/self/exe` :130;
`restrictSocketMode` automation_server.zig:1513-1517 and the `0o600` token file :1496-1511;
`adapterCapabilities(.webview2)` automation_platform.zig:77-98; `FakeWebView2Cdp` :167; `SandboxBackend` sandbox.py:201,
`LinuxBwrapBackend` :232, `EGRESS_ALLOW` :51, `LOGIN_EGRESS_ALLOW` :56; `options.py:104`; `slice2_common.py`
`SKIP_EXIT = 77` :20 and `run_windows_interactive_until` :447; `gate.ps1` `Invoke-InteractiveCapture` :88;
`tests/windows/` does not exist yet; no `automation_wk_port.zig`, `applyMacBackendFlag` or `applyBackendFlag`
exists in `src/`.

**Corrected in this rev (rev 1 said otherwise or omitted it):**
1. `win11-m8` is `running` (not shut off), has no snapshots, a passt `2222 -> 22` forward, an `ich9` SPICE-audio device; its Tailscale node is offline (105 days).
2. `tests/guest/ssh.sh` is the working path, not "superseded"; `build-in-guest.sh` omits `agent/ packaging/ tools/ docs/` and uses a fixed `/tmp` file.
3. `tests/guest/setup.ps1` must not run on the Win10 box without the owner's OK (unscoped port 22 rule, toolchain installs: system-wide changes).
4. Provisioning item 4 looked only at `HKLM\…\WOW6432Node`; the runtime version can be in `HKLM` (two views) or `HKCU`.
5. The debug-seam count is 30 declared (27 listed in the ABI table + 3 config seams under WS3).
6. WS12: TTS W1 is the bundled engine + WASAPI (not WinRT/SAPI, which is S3); TTS has no "N1"; W1 depends on the sandbox milestone (new WS8.7); STT's `win-voice-live` host claim conflicts with the VM's unproven capture device.
7. WS0.2's `NOT RUN` text now contains the sentence both voice plans already quote.
8. The macOS plan header says rev 6 but its history runs to rev 9; its flag seam is `applyMacBackendFlag` (macOS-only name); its egress port is OS-selected while Windows needs a fixed range; the hook-broker module is not in that plan. The shared table now states each.
9. WS13.4: a per-user MSI cannot run an elevated custom action.
10. `agent_drawer.zig` export gate is `comptime { if (builtin.os.tag == .linux)` at :338-339, closing :358.

**Added:** WS0.6 (VM identity and down-VM), WS0.7 (Win10 test-host fence), WS0.8 (transport hygiene), WS7.5 (Windows
import-ability), WS8.7 (no-network child), the WS2 register, per-milestone reds/mutants/greens/refactors/closures/real-screen
cases for WS1-WS13, `win-popups`, `win-crash-page`, the role map, the Win10 test-box confinement requirements, and the decision
sharpening for OD-W1..OD-W9. (Rev 2.13, 2026-10-21: OD-W1/W3/W4/W6 are now DECIDED per the OWNER DECISIONS
block — the sharpening for those is retained as history; OD-W2/W5/W7/W8/W9 remain open.)

**Flagged, not fixed here (other plans, not editable by this review):** the macOS plan's flag-seam name and rev header;
the hook-broker module; the TTS plan's missing Windows cloning leg; the STT plan's `win-voice-live` on both hosts; the
voice plans' "being written" sentences; `docs/how-to-build.md:66-67` still says each non-GTK target needs only three symbols
(true today, false after WS2).

## References

- Research: `thoughts/searchable/shared/research/2026-10-19-windows-launch-support-surface.md`
- macOS plan (structure, MS0 egress capability rev 6, MS2 ABI rules, MS6 app-side hooks):
  `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md`
- Drawer plan (D1-D5 UX :210-271, D10 grant :507-533, D11/S4 secrets :535-576/:1922-1975, S6
  login :2300-2386, netd §3c :828-1033): `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`
- Sandbox research: `…/research/2026-10-14-agent-sandbox-redteam.md`, `…/research/2026-10-14-macos-sandbox-option.md`
- Voice plans: `…/plans/2026-10-19-voice-output-tts-tdd-plan.md` (W0-W2, OD11),
  `…/plans/2026-10-19-voice-input-stt-tdd-plan.md` (VS10, VS11, VSP)
- Earlier Windows plans: `…/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`,
  `…/plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md`,
  `…/plans/2026-07-09-phase2-3-external-api-platform-input-tdd-plan.md` (ADR-1 AF_UNIX spike)
- Code anchors: `src/webview2_shim.cpp:18, 412-463, 541-577, 692, 696-703, 707-771`;
  `build.zig:10-77, 224-291, 1481-1488, 1535-1558`; `src/automation_transport.zig:17-35`;
  `src/app.zig:52-55, 130, 453-460`; `src/automation_server.zig:167, 412, 480-487, 686-691, 942-1106, 1496-1517`;
  `src/automation_platform.zig:77-98`; `agent/host/zb_agent_host/sandbox.py:41-56, 71-229, 232-374`;
  `agent/host/zb_agent_host/netd.py:1-40, 107-179`; `agent/host/zb_agent_host/options.py:104`;
  `src/agent_drawer.zig:14-103, 244-277, 338-358`; `src/agent_secrets.zig:14-19`;
  `tests/e2e/slice2_common.py:447-548`; `packaging/windows/gate.ps1:88-150`;
  `packaging/windows/zigBrowser.wxs`; `tests/guest/setup.ps1`; `tests/guest/build-in-guest.sh`;
  `tests/mac/gate.sh`.

## Process note (beads)

**Corrected in rev 2.17 (W5).** The earlier claim here — that no bead was filed because the shared bd DB is
migration-locked — is **withdrawn**: `bd` works today and the independent review filed its findings under the epic
`zigBrowser-4pa` (`4pa.31` through `4pa.49`, discovered-from `4pa.4`; the enhancement task is `4pa.9`). `bd migrate` and
`bootstrap` are still never run unilaterally on the remote-backed clone. Track status with `bd` (epic `zigBrowser-4pa`)
and Agent Mail; this plan is the source of the amendments, not the tracker.

---

## Verification rule compliance (rev 2.19)

Added by the owner's order of 2026-10-22 (section "Verification rule: prove it by running it", before WS0). One row per behavior, sub-slice, closure chain and gate item. "Rule-9 fields complete" means the plan now states all four of (a) entry point, (b) test and build.zig step, (c) mutant, (d) platform run; a row marked no is not ready for implementation. **Rev 2.20 (G2.1): a row marked "yes" names the concrete `build.zig` step its test registers in, in parentheses (`NEW step` = the step does not exist yet and is created in the green commit as WORK; see "Registration map (rev 2.20)" below); a "yes" row without a step is not allowed.** Proof type is driven, platform run, or tripwire-only. Status uses the legend in section F. The Win10 legs are separate rows (suffix -W10) and none has run. Statuses are documentary (this revision ran nothing).

| ID | Behavior | Rule-9 fields complete | Proof type | Status | Sweep action |
|---|---|---|---|---|---|
| WS0.1a | probe fields and fail-closed validation (readiness) | yes (step `windows-twohost-selftest`) | driven (the registered selftest); the live half `host_live_test.py` is unregistered and NOT counted | PROVEN-PARTIAL | kept; proof fields added; live half uncounted (rev 2.20, G4.2) |
| WS0.1b | lock verdict comes from the WTS session-lock flag | yes (step `windows-host-live`, NEW, WORK; `host_live_test.py` is in no step today) | hand run only; its test is unregistered (a draft, rule 2) | NOT BUILT | rewritten + NOT BUILT (rev 2.20, G4.2) |
| WS0.1c | the Win10 `--probe-only` probe writes nothing (zero-write) | yes (step `windows-twohost-selftest`) | tripwire-only today (a regex over `host_probe.ps1`) | NOT BUILT | rewritten + NOT BUILT |
| WS0.1d | typed probe record (ok / not_applicable / unknown) | yes (step `windows-twohost-selftest`) | none yet | NOT BUILT | NOT BUILT |
| WS0.2 | the gate fails closed | yes (steps `windows-gate-selftest`, `windows-twohost-selftest`) | driven + platform run | PROVEN-PARTIAL | kept; proof fields added |
| WS0.3 | the gate never reaches the Linux display | yes (step `windows-twohost-selftest`) | driven (L) | PROVEN-PARTIAL | kept; proof fields added |
| WS0.4 | interactive launches are real, bounded and clean | yes (steps `windows-gate-selftest`; `windows-m8-render-live`, `windows-m8-reply-live`, `windows-m8-load-fail-live`) | none yet | NOT BUILT | NOT BUILT |
| WS0.5 | no remote-path authorization fence | yes (step `windows-gate-selftest`) | TRIPWIRE today (`RemotePathFenceRemovedTests` checks that names and files are absent); the driven refused-flag case is not written | NOT BUILT | rewritten + NOT BUILT |
| WS0.6 | the Win11 VM is the VM it claims to be; a down VM fails the gate | yes (step `windows-twohost-selftest`) | driven + platform run | PROVEN-PARTIAL | kept; proof fields added |
| WS0.6b | unreachable VM port fails within 15 s | yes (step `windows-twohost-selftest`) | none yet | NOT BUILT | NOT BUILT |
| WS0.7 | the Win10 test host stays confined and undisturbed | yes (step `windows-twohost-selftest`) | driven + platform run | PROVEN-PARTIAL | kept; proof fields added |
| WS0.8 | transport hygiene (staging, pinned host keys, tar status) | yes (steps `windows-twohost-selftest`, `windows-build-selftest`) | none yet | NOT BUILT | NOT BUILT |
| WS0.9 | product-run mode with fail-on-skip | yes (steps `windows-twohost-selftest`; NEW `windows-live-step-skip`) | none yet | NOT BUILT | rewritten + NOT BUILT |
| WS0.9-W10 | Win10 product-run leg | yes (step `windows-twohost-selftest`) | none yet | NOT BUILT | NOT BUILT |
| D.3 | `--e2e-protocol` is a command-line-only flag; seams are inert without it | yes (NEW step `windows-e2e-protocol-contract-live`) | none yet | NOT BUILT | rewritten + NOT BUILT |
| WS1.1 | the release exe has no hidden runtime dependency | no | tripwire-only today (PE import listing) | UNPROVEN | rewritten + UNPROVEN |
| WS1.2 | M8 render, reply channel and load-fail on both hosts | yes (NEW steps `windows-m8-render-live`, `windows-m8-reply-live`, `windows-m8-load-fail-live`) | none yet | NOT BUILT | NOT BUILT |
| WS1.2-W10 | M8 tests on the Win10 box | yes (same three NEW steps, Win10 host) | none yet | NOT BUILT | NOT BUILT |
| WS1.3 | `--screenshot` produces a real PNG | yes (step `windows-screenshot-live`) | driven + platform run | PROVEN-PARTIAL | kept; proof fields added |
| WS1.4 | a missing runtime fails with exit 9 and the documented message | yes (NEW step `windows-ws1-run-live`; `win_runtime_missing_test.py` is WORK to create) | none yet | NOT BUILT | NOT BUILT |
| WS1.5 | build info reports what actually ran | yes (NEW step `windows-ws1-run-live`; `win_version_test.py` is WORK to create) | none yet | NOT BUILT | NOT BUILT |
| WS2.0 | transport is local-only and owner-only | yes (steps `windows-transport-live`, `test-owner-only`) | driven + platform run | PROVEN-PARTIAL | kept; proof fields added |
| WS2.0-W10 | transport on the Win10 box | yes (step `windows-transport-live`, Win10 host selector is WORK) | none yet | NOT BUILT | NOT BUILT |
| WS2a.0 | CDP isolated-world spike | yes (NEW step `windows-private-world-spike-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2a.0-W10 | isolated-world spike on the Win10 box | yes (same NEW step, Win10 host) | none yet | NOT BUILT | NOT BUILT |
| WS2a.1 | routed `page.*` commands over the socket | yes (NEW step `windows-routed-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2a.2 | `dom.*` runs in a private world | yes (NEW step `windows-private-world-live`) | none yet | UNPROVEN | UNPROVEN |
| WS2a.3 | async completion ownership and bounded waits | yes (NEW step `windows-async-ownership-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2b.0 | capability table honesty (`cdp_input` placeholder) | yes (NEW steps `test-wv2-capabilities`, `windows-capabilities-live`) | tripwire-only today (`automation_platform.zig:885-886` is fake-backed) | UNPROVEN | rewritten + UNPROVEN |
| WS2b.1 | trusted-event matrix (isTrusted) | yes (NEW step `windows-trusted-input-matrix-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2b.1-W10 | trusted-event matrix on the Win10 box | yes (same NEW step, Win10 host) | none yet | NOT BUILT | NOT BUILT |
| WS2b.2 | dialogs (alert/confirm/prompt/beforeunload) | yes (NEW step `windows-dialog-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2b.3 | full-page screenshot over the socket | yes (NEW step `windows-screenshot-full-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2b.4 | input files with regular-file refusal | yes (NEW step `windows-input-files-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2c.1 | popups and per-window ids | yes (NEW step `windows-popup-chain-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2c.2 | health answers while a sibling's FIFO is stuck | yes (NEW step `windows-health-sibling-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2c.3 | two-phase recovery of a hung renderer | yes (NEW step `windows-recover-live`) | none yet | UNPROVEN | UNPROVEN |
| WS2c.4 | crash parity (`ProcessFailed`) | yes (NEW step `windows-crash-parity-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2c.5 | popup drawer slots and one destroy path | yes (NEW step `windows-window-lifecycle-live`) | none yet | NOT BUILT | NOT BUILT |
| Closure A | ordinary routed command (socket to live page) | yes (NEW step `windows-routed-live`) | none yet | NOT BUILT | NOT BUILT |
| Closure B | health while a sibling is stuck | yes (NEW step `windows-health-sibling-live`) | none yet | NOT BUILT | NOT BUILT |
| Closure C | two-phase recover | yes (NEW step `windows-recover-live`) | none yet | NOT BUILT | NOT BUILT |
| WS2.ABI | unsupported seams are absent from the shipped exe | yes (NEW step `windows-abi-absence-live`) | none yet (a link-time symbol listing is a tripwire) | NOT BUILT | rewritten + NOT BUILT |
| WS3.1 | isolated persistent profile | yes (NEW step `windows-profile-persist-live`) | none yet | NOT BUILT | NOT BUILT |
| WS3.2 | flags decided by one fallible seam | yes (steps `test-backend-flag`, `windows-refusal-live`, `windows-config-flags-live`) | driven + platform run | PROVEN-PARTIAL | rewritten |
| WS3.2b | `--disable-gpu` is actually passed; `typeof MediaSource` read over the socket | yes (step `windows-config-flags-live`, extended) | none yet | NOT BUILT | NOT BUILT |
| WS3.3 | cookie ABI and `CookiePort` over `ICoreWebView2CookieManager` | yes (NEW step `windows-cookie-live`) | none yet | NOT BUILT | NOT BUILT |
| WS3.4 | cookie port and profile are WIRED and proven live | yes (NEW steps `windows-cookie-live`, `windows-profile-persist-live`) | none yet | NOT BUILT | NOT BUILT |
| WS3.X | `cross-check-ws3-win` symbol check | yes (step `cross-check-ws3-win`, `build.zig:603`, wired into neither `cross-check` nor `test`) | tripwire-only | NOT BUILT | rewritten + NOT BUILT |
| WS4.1 | page worlds, iframes, popups, socket clients, model text and hooks cannot approve | yes (NEW step `windows-flow-refusal-live`, class `ForgedApprovalRefused`) | none yet | UNPROVEN | UNPROVEN |
| WS4.2 | per-write confirmation; a dry run commits nothing | yes (NEW step `windows-flow-refusal-live`, class `PerWriteConfirmationAndDryRun`) | none yet | UNPROVEN | UNPROVEN |
| WS4.3 | the login gate reads the session cookie through the WS3 cookie port | yes (NEW steps `windows-flow-refusal-live`, class `LoginGateReadsWv2Cookie`, and `windows-cookie-live`; mutant: read the cookie through the GTK port) | none yet | UNPROVEN | UNPROVEN (mutant replaced, rev 2.20, G2.4) |
| WS5.1 | the dock resizes the page above it (entry run) | yes (step `windows-drawer-live`) | platform run (recorded by hand, b2c4f25; not a registered gate run) | PROVEN-PARTIAL | kept; proof fields added; wording fixed (rev 2.20, G6.3) |
| WS5.2 | the icon drags, moves by keys, persists | yes (step `windows-drawer-behaviors`) | tripwire-only today (offline oracles and models) | NOT BUILT | NOT BUILT |
| WS5.2P | drawer geometry properties (ratio roundtrip, `clampRect`) | yes (step `drawer-props-test`) | driven (L) | PROVEN-PARTIAL | kept; proof fields added |
| WS5.3 | `-` folds into the icon over 180 ms | yes (step `windows-drawer-behaviors`) | tripwire-only today | NOT BUILT | NOT BUILT |
| WS5.4 | bubble text is selectable, copyable and inert | yes (step `windows-drawer-behaviors`) | tripwire-only today | NOT BUILT | NOT BUILT |
| WS5.5 | primary-window drawer inc/dec and the portable live counter | yes (steps `drawer-props-test`, `windows-drawer-behaviors`) | driven + platform run (primary window and counter only; the second window comes from the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS`, not a production proof) | PROVEN-PARTIAL | narrowed (rev 2.20, G4.1); run output only in review commit 18b32b4 |
| WS5.5b | per-window drawers on production popup windows, one destroy path through the popup close path | yes (NEW step `windows-window-lifecycle-live`, shared with WS2c.5) | none yet (the production popup close path does not exist; WS2c.1 is zero code) | NOT BUILT | NOT BUILT (new row, rev 2.20, G4.1) |
| WS5.6 | the drawer is unreachable from page JavaScript and the socket | yes (steps `windows-drawer-behaviors`, NEW `windows-drawer-isolation-live`) | tripwire-only today (4cb740d and 33bde9a are offline Linux in-process tests; the Python row exercises helpers defined in the test itself) | NOT BUILT | rewritten + NOT BUILT |
| WS5.7 | 150% DPI: icon is 84 px and hit-testing is exact | yes (step `windows-drawer-behaviors`) | tripwire-only today (env-seam proof only; the process is not DPI-aware) | NOT BUILT | NOT BUILT |
| WS5.8 | DPI manifest and resource file | yes (step `windows-drawer-live`) | none yet | NOT BUILT | NOT BUILT |
| WS5.9 | owned layered popup for the icon | yes (step `windows-drawer-behaviors`) | none yet | NOT BUILT | NOT BUILT |
| WS5.10 | approval card and Send box | yes (step `windows-drawer-behaviors`) | none yet | NOT BUILT | NOT BUILT |
| WS5.O | WS5 offline oracle and model suites | no | tripwire-only | TRIPWIRE ONLY | rewritten |
| WS6.1 | Credential Manager token store (`CredWriteW/ReadW/DeleteW`) | yes (NEW step `windows-secrets-live`) | tripwire-only today (the `agent_secrets_win.cpp` exports are symbol-checked at `build.zig:564-567`) | NOT BUILT | rewritten + NOT BUILT |
| WS6.1a | `Token` is parsed once | yes (steps `test-agent-secrets`, `windows-secrets-live`) | none yet | NOT BUILT | NOT BUILT |
| WS6.1b | private-file fallback ACL and DPAPI wrap | yes (NEW step `windows-secrets-live`) | none yet | NOT BUILT | rewritten + NOT BUILT |
| WS6.1c | `CRYPTPROTECT_UI_FORBIDDEN` is honored | no | none yet | UNPROVEN | rewritten + UNPROVEN |
| WS6.2 | the Secrets window | yes (NEW step `windows-secrets-live`) | none yet | NOT BUILT | NOT BUILT |
| WS6.3 | tests never touch a real credential | yes (NEW step `windows-secrets-live`) | none yet | NOT BUILT | NOT BUILT |
| WS6.4 | token route from the Windows store to the in-distro CLI's fd 3 | no | none yet | UNPROVEN | UNPROVEN |
| WS6.S | portable token shape check | yes (step `test-agent-secrets`) | driven (L) | PROVEN-PARTIAL | kept; proof fields added |
| WS7.0 | `--agent-setup` on Windows 11 builds the agent home in the distro | yes (NEW step `windows-agent-setup-live`) | none yet | NOT BUILT | NOT BUILT |
| WS7.1 | atomic `current` switch | yes (NEW steps `test-agent-current-switch-property`, `windows-agent-setup-live`) | tripwire-only today (threads with POSIX `os.rename`, a toy) | NOT BUILT | rewritten + NOT BUILT |
| WS7.2 | bundled runtime inside the distro, pinned by SHA-256 | no | none yet | UNPROVEN | UNPROVEN |
| WS7.3 | launcher is `wsl.exe -d <distro> -u <nonroot>` plus the C1 bootstrap | yes (step `test-launcher-contract`) | none yet | NOT BUILT | NOT BUILT |
| WS7.4 | SAI copy rules skip links and junctions | yes (NEW step `windows-agent-setup-live`) | tripwire-only today (toy inputs) | NOT BUILT | rewritten + NOT BUILT |
| WS7.5 | Windows-host Python modules import on Windows (Linux blocked-module half: no top-level POSIX-only import) | yes (Linux half: step `agent-host-win-import`; Windows claim: NEW step `windows-agent-import-live`, Win11 VM) | Linux half driven (SUSPECTED: read, not run); the Windows claim has no run | NOT BUILT | split (rev 2.20, G2.3) |
| WS8.1 | isolation: host profile, processes and browser memory unreachable from the distro | no | none yet | UNPROVEN | UNPROVEN |
| WS8.2 | one-admin resumable setup (idempotent, rollback, reboot flag) | no | none yet | UNPROVEN | UNPROVEN |
| WS8.3 | two token channels (control capability, OAuth fd 3) | no | none yet | UNPROVEN | UNPROVEN |
| WS8.4 | dedicated non-root uid, default-user selection, no admin group | no | none yet | UNPROVEN | UNPROVEN |
| WS8.5 | per-run teardown within 5 s, never the shared distro | no | none yet | UNPROVEN | UNPROVEN |
| WS8.6 | file scope via the broker | no | none yet | UNPROVEN | UNPROVEN |
| WS8.7 | no-network child inside the distro | no | none yet | UNPROVEN | UNPROVEN |
| WS8.8 | fail-closed: virtualization or WSL off | no | none yet | UNPROVEN | UNPROVEN |
| WS8.M | WS8/WS9 acceptance matrix (12 items) | no | none yet | UNPROVEN | UNPROVEN |
| WS9.1 | the CLI reaches the fake API only through the in-distro netd | no | none yet | UNPROVEN | UNPROVEN |
| WS9.2 | denials: 1.1.1.1, TEST-NET, loopback decoy, DNS, non-allowlisted CONNECT | no | none yet | UNPROVEN | UNPROVEN |
| WS9.3 | a hook reaches only the two bridges, both carry bytes | no | none yet | UNPROVEN | UNPROVEN |
| WS9.4 | the sign-in netd allows exactly two hosts and no bridges | no | none yet | UNPROVEN | UNPROVEN |
| WS9.R | C5 reverse relay acceptance (bytes through both ports; co-tenant, squat and namespace negatives) | no | none yet | UNPROVEN | UNPROVEN |
| WS10.1 | `claude setup-token` runs in the distro; authorize URL opened only on click | no | none yet | UNPROVEN | UNPROVEN |
| WS10.2 | pasted code reaches the CLI over C1; the token returns on a one-shot channel into the store | no | none yet | UNPROVEN | UNPROVEN |
| WS10.3 | cancel and timeout map to the same codes as Linux | no | none yet | UNPROVEN | UNPROVEN |
| WS11.1 | helper starts under the backend and emits a validated `ready` frame | no | none yet | UNPROVEN | UNPROVEN |
| WS11.2 | chat round trip streams into the Win32 drawer | no | none yet | UNPROVEN | UNPROVEN |
| WS11.3 | approved commit exactly once; Deny, expiry, retarget and wrong account commit zero | no | none yet | UNPROVEN | UNPROVEN |
| WS12.1 | drawer voice hook points (`zb_drawer_set_draft`, `zb_drawer_speaker_toggled`) | yes (NEW step `windows-drawer-voice-hooks-live`) | none yet | NOT BUILT | NOT BUILT |
| WS12.2 | `gate.sh --phase voice` fails closed | yes (step `windows-twohost-selftest`) | none yet | NOT BUILT | NOT BUILT |
| WS13.1 | the MSI ships every component (closing proof: install and run; the census is a TRIPWIRE) | yes (NEW step `windows-msi-install-live`) | tripwire-only today | NOT BUILT | rewritten + NOT BUILT |
| WS13.2 | WebView2 bootstrapper failure is surfaced | yes (NEW step `windows-msi-install-live`) | none yet | NOT BUILT | NOT BUILT |
| WS13.3 | cabinet sizes stay below 2 GB | yes (NEW steps `windows-msi-cabinet-selftest`, `windows-msi-install-live`) | none yet | NOT BUILT | NOT BUILT |
| WS13.4 | uninstall removes only zigBrowser's WSL state (Win11) | yes (NEW step `windows-msi-install-live`) | none yet | NOT BUILT | NOT BUILT |
| WS13.4-W10 | Win10 browser uninstall | yes (NEW step `windows-msi-install-live`, Win10 host) | none yet | NOT BUILT | NOT BUILT |
| WS13.5 | update verifies the signature | no | none yet | UNPROVEN | UNPROVEN |
| WS13.6 | signing (DEFERRED, OD-W3) | no | none yet | UNPROVEN | UNPROVEN |

**Totals (rev 2.20; the rev 2.19 totals were 107 rows, 61 NOT BUILT, 13 PROVEN-PARTIAL).** Rows: 108. Rewritten into exercise form: 18. NOT BUILT: 63 (of which 18 re-marked at rev 2.19 from a green, closed, registered or source-only claim; plus 2 re-marked at rev 2.20: WS0.1b, re-marked from PROVEN-PARTIAL, and the new row WS5.5b; 13 also rewritten, counting WS0.1b). UNPROVEN: 32 (3 also rewritten). PROVEN: 0. PROVEN-PARTIAL: 12. Tripwire-only suite row: 1. Rows with incomplete rule-9 fields: 27. 63 + 32 + 12 + 1 + 0 = 108. A row counts once per status; "rewritten" overlaps with NOT BUILT and UNPROVEN where a proof was both rewritten and found missing.

**How 4pa.44 and 4pa.46 are closed in this table.** 4pa.44: WS5.O is TRIPWIRE ONLY; WS5.1 is PROVEN-PARTIAL on the recorded Win11 run b2c4f25; WS5.5 is PROVEN-PARTIAL for the primary window's inc/dec and the portable counter only (a5745b9 reached its second window through the e2e-only seam, rev 2.20, G4.1) and its per-window / popup-close part WS5.5b is NOT BUILT; WS5.2, WS5.3, WS5.4, WS5.7 are NOT BUILT; WS5.8-WS5.10 are NOT BUILT. 4pa.46: WS5.6 is NOT BUILT until the real-binary row runs on the Win11 VM (the page-JavaScript half also needs WS2a.1).

## Registration map (rev 2.20, G2.1)

Added to close audit gap G2.1 (rule 9(b): "the test file AND its build.zig step"). `windows-live` is a NEW aggregate `build.zig` step created by the WS0.9 green commit (it does not exist at HEAD); it depends on every per-test `windows-*-live` step below, each of which runs the real command with `ZB_WIN_GATE=1`, requires a host and FAILS on skip (rule 7, D.1). It is NOT part of the plain `zig build test`. A test not yet in a step is a draft (rule 2). "Existing" means the step is in `build.zig` at HEAD (read, not run); "NEW" means WORK to create it in the green commit.

| Test file (or file group) | build.zig step | State |
|---|---|---|
| `tests/windows/gate_selftest.py` | `windows-gate-selftest` | existing |
| `tests/windows/gate_twohost_selftest.py` (WS0.1c/0.1d/0.6b/0.8/0.9/0.9-W10, WS12.2 cases) | `windows-twohost-selftest` | existing |
| `tests/windows/build_on_windows_selftest.py` | `windows-build-selftest` | existing |
| `tests/windows/host_live_test.py` (WS0.1b) | `windows-host-live` (in `windows-live`) | NEW (WORK; unregistered today) |
| `tests/windows/live_step_skip_test.py` (WS0.9) | `windows-live-step-skip` | NEW |
| `tests/windows/e2e_protocol_contract_test.py` (D.3) | `windows-e2e-protocol-contract-live` | NEW |
| `tests/e2e/m8_render_test.py`, `m8_reply_channel_test.py`, `m8_load_fail_test.py` (WS1.2, WS0.4) | `windows-m8-render-live`, `windows-m8-reply-live`, `windows-m8-load-fail-live` | NEW |
| `tests/windows/screenshot_live_test.py` (WS1.3) | `windows-screenshot-live` | existing |
| `tests/windows/ws1_run_test.py` (WS1.1, WS1.4, WS1.5) | `windows-ws1-run-live` | NEW (file exists, unregistered) |
| `tests/e2e/win_runtime_missing_test.py`, `win_version_test.py` | folded into `windows-ws1-run-live` when created | WORK to create (files do not exist) |
| `tests/e2e/win_transport_test.py` (WS2.0, WS2.0-W10) | `windows-transport-live` | existing |
| `tests/owner_only_test.zig` | `test-owner-only` | existing |
| `tests/e2e/win_private_world_spike.py` | `windows-private-world-spike-live` | NEW |
| `tests/e2e/win_routed_test.py` (WS2a.1, Closure A) | `windows-routed-live` | NEW |
| `tests/e2e/win_private_world_test.py` (WS2a.2) | `windows-private-world-live` | NEW |
| `tests/e2e/win_async_ownership_test.py` (WS2a.3) | `windows-async-ownership-live` | NEW |
| WS2b.0 Zig test and e2e half | `test-wv2-capabilities`, `windows-capabilities-live` | NEW |
| `tests/e2e/win_trusted_input_matrix.py` (WS2b.1, -W10) | `windows-trusted-input-matrix-live` | NEW |
| `tests/e2e/win_dialog_test.py`, `win_screenshot_full_test.py`, `win_input_files_test.py` | `windows-dialog-live`, `windows-screenshot-full-live`, `windows-input-files-live` | NEW |
| `tests/e2e/win_popup_chain_test.py`, `win_health_sibling_test.py`, `win_recover_test.py`, `win_crash_parity_test.py`, `win_window_lifecycle_test.py` (WS2c.1-2c.5, Closures B and C, WS5.5b) | `windows-popup-chain-live`, `windows-health-sibling-live`, `windows-recover-live`, `windows-crash-parity-live`, `windows-window-lifecycle-live` | NEW |
| `tests/e2e/win_abi_absence_test.py` (WS2.ABI) | `windows-abi-absence-live` | NEW |
| `tests/backend_flag_test.zig`; `tests/windows/refusal_stderr_live_test.py`; `tests/windows/win_config_flags_test.py` (WS3.2, WS3.2b) | `test-backend-flag`; `windows-refusal-live`; `windows-config-flags-live` | existing |
| `tests/windows/win_profile_persist_test.py` (WS3.1, WS3.4) | `windows-profile-persist-live` | NEW |
| `tests/windows/win_cookie_test.py` (WS3.3, WS3.4, WS4.3) | `windows-cookie-live` | NEW |
| `src/ws3_win_cross_root.zig` symbol check (WS3.X, tripwire) | `cross-check-ws3-win` | existing, wired into neither `cross-check` nor `test` |
| `tests/e2e/win_flow_refusal_test.py` (WS4.1, WS4.2, WS4.3) | `windows-flow-refusal-live` | NEW |
| `tests/windows/win_drawer_test.py` (WS5.1, WS5.8) | `windows-drawer-live` | existing (scrubs host variables, skips; fail-on-skip is WORK) |
| `tests/windows/win_drawer_behaviors_test.py` (WS5.2-5.5, 5.7, 5.9, 5.10) | `windows-drawer-behaviors` | existing (same caveat) |
| `tests/windows/agent_drawer_props_test.zig` (WS5.2P, WS5.5) | `drawer-props-test` | existing |
| `tests/windows/win_drawer_isolation_live_test.py` (WS5.6) | `windows-drawer-isolation-live` | NEW |
| `tests/e2e/win_secrets_test.py` (WS6.1, 6.1b, 6.2, 6.3) | `windows-secrets-live` | NEW |
| `tests/windows/agent_secrets_shape_portable_test.zig`, `agent_secrets_store_test.zig`, WS6.1a Zig test (WS6.S, WS6.1a) | `test-agent-secrets` | existing |
| `tests/windows/win_agent_setup_test.py` (WS7.0, 7.1, 7.4) | `windows-agent-setup-live` | NEW |
| WS7.1 in-distro rename property | `test-agent-current-switch-property` | NEW |
| `agent/host/tests/test_launcher_contract.py` (WS7.3) | `test-launcher-contract` | existing |
| `agent/host/tests/test_windows_import.py`, `test_windows_import_deep.py`, `test_windows_entry.py` (WS7.5 Linux half) | `agent-host-win-import` | existing |
| WS7.5 Windows leg on the Win11 VM | `windows-agent-import-live` | NEW |
| `tests/windows/win_drawer_voice_hooks_test.py` (WS12.1) | `windows-drawer-voice-hooks-live` | NEW |
| `tests/e2e/msi_install_test.py` (WS13.1, 13.2, 13.4, 13.4-W10) | `windows-msi-install-live` | NEW |
| WS13.3 splitter property test | `windows-msi-cabinet-selftest` | NEW |

Rows with no concrete step are marked "no" in the compliance table (WS1.1 lacks its recorded host; WS5.O; WS6.1c; WS6.4; WS7.2; WS8.1-WS8.M; WS9.1-WS9.R; WS10.1-WS10.3; WS11.1-WS11.3; WS13.5; WS13.6).

## Audit gaps closed (rev 2.20)

One row per gap of the independent audit of rev 2.19 (`2026-10-19-windows-launch-tdd-plan-RULE-AUDIT.md`, verdict PASS WITH GAPS (15)). Plan-only revision; nothing was built or run.

| Gap | What it was | Where and how it is now fixed |
|---|---|---|
| G2.1 | About 46 rows marked rule-9 "yes" named only a NEW test file and no `build.zig` step. | Every such compliance-table row now names its step in parentheses; the "Registration map (rev 2.20)" above lists every file and step; each slice proof-block header (WS0, WS1, WS2, WS3, WS4, WS5, WS6, WS7, WS12, WS13) repeats its own file-to-step list; D.1 defines the NEW `windows-live` aggregate (absent from `build.zig` at HEAD). No "yes" row lacks a step. |
| G2.2 | WS8.1-WS8.8 field (c) "mutant" held the expected result, not a mutant. | WS8 proof blocks: each (c) now names the production defense that is REMOVED (automount re-enabled, rollback dropped, token passed in argv, run as root, leader-only kill, name-only broker check, no network isolation, availability check dropped) and keeps the expected result in parentheses. The rows stay "no" / UNPROVEN. |
| G2.3 | WS7.5 "imports on Windows" was proven only by a Linux run with blocked modules. | WS7 proof block WS7.5 is split: (i) the Linux blocked-module half is narrowed to "no top-level POSIX-only import" (existing step `agent-host-win-import`); (ii) the Windows claim needs a Win11 VM leg (NEW step `windows-agent-import-live`), still NOT BUILT. WS7 gate paragraph and the table row say so. |
| G2.4 | WS4.1-WS4.3 shared one boilerplate entry point; WS4.3's mutant did not exercise the cookie-port behavior. | WS4 body Red and WS4 proof blocks: three distinct entry points and test classes (`ForgedApprovalRefused`, `PerWriteConfirmationAndDryRun`, `LoginGateReadsWv2Cookie`); WS4.3's mutant is now "read the cookie through the GTK port" plus "skip the cookie read"; the characterization note gains mutant (5) for WS4.3. |
| L3.1 | WS0 status box said "CLOSED: ... WS0.5 (removed fence)" on an absence-of-names text check. | WS0 status box rewritten: nothing in WS0 is closed; WS0.5 is a TRIPWIRE today and its driven refused-flag case is NOT BUILT; the WS0.5 body and the WS0 Gate paragraph say the same; the table row says TRIPWIRE. |
| L3.2 | WS1.5's Then clause included "`pe_census.py`'s arch matches" (a PE listing) unlabelled. | WS1.5 behavior text: the executing architecture is proven by running `--version`; the `pe_census.py` match is a labelled TRIPWIRE outside the success condition; the WS1.5 proof block repeats it. |
| L3.3 | The WS1 Gate had "+ [L] `cross-check` unchanged" as an unlabelled conjunct. | WS1 Gate (WS1) paragraph: `cross-check` is relabelled a TRIPWIRE / build guard that never counts toward closing WS1, matching WS2.0. |
| L3.4 | WS13.1 / `msi_install_test.py` Red was the census assertion. | WS13 "More reds" and the `msi_install_test.py` Red: the closing assertion is now install-and-run (`installed_exe_runs and m8_render_from_install_dir_passes`); the census assertion is kept only as a labelled TRIPWIRE. |
| L3.5 | The Dependency-order line used the WS13.1 census as the packaging gate, unlabelled. | Dependency order: the census is labelled a TRIPWIRE and the final gate also requires the installed product to run from its install directory. |
| G4.1 | WS5.5 was PROVEN-PARTIAL although its per-window part runs only on the e2e-only seam `ZIGBROWSER_AGENT_DRAWER_WINDOWS` and the production popup close path does not exist. | WS5 proof block: WS5.5 narrowed to the primary window's inc/dec plus the portable counter (PROVEN-PARTIAL, a5745b9 cited for what it exercised, the seam); new row WS5.5b (per-window / popup close path) NOT BUILT; WS5 red text, WS5 status block, B table row, rev 2.19 note, table rows and totals updated. |
| G4.2 | WS0.1b (and WS0.1a's live half) counted as proven on `host_live_test.py`, which is in no `build.zig` step. | WS0 proof blocks: WS0.1b re-marked NOT BUILT; WS0.1a counts only the registered selftest; registering `host_live_test.py` as the NEW step `windows-host-live` is named as WORK, not evidence; table rows and totals updated. |
| G4.3 | The WS1 body named `tests/e2e/win_screenshot_test.py` (does not exist) as the real row; `win_runtime_missing_test.py` and `win_version_test.py` also do not exist. | WS1 body: the Red and Files-touched now name the real `tests/windows/screenshot_live_test.py`; the other two files are named as WORK to create; the WS1 status paragraph and the WS1 proof blocks say the same. |
| G6.1 | Stale rev-2.17 CLOSED / green text contradicted the rev-2.19 proof blocks. | Reconciled to each proof block: B table rows WS0, WS1, WS2.0, WS5; WS0 status box; WS1 "Status and registration"; WS2 status header; WS3 "Built vs wired"; WS5 closure-rule paragraph. A rev 2.20 banner at the top says the proof block wins over any older status line. |
| G6.2 | "Closed today: WS3.2 only" although WS3.2 is PROVEN-PARTIAL with open mutants and WS3.2b. | WS3 Gate paragraph: "Closed today: NOTHING in WS3"; WS3.2 is PROVEN-PARTIAL with two of three named mutants not recorded as run and WS3.2b open; the WS3 "Built vs wired" line agrees. |
| G6.3 | WS5.1 and WS5.5 rows said "PROVEN by the recorded platform run" / "PROVEN by the a5745b9 Win11 run" while PROVEN-PARTIAL. | WS5 proof blocks: both lines now say PROVEN-PARTIAL; WS5.5 also says the run output is only in review commit 18b32b4 and must be pasted into the implementing commit. |
