---
date: 2026-10-19T16:20:00-04:00
planner: Claude (Opus 5.5) subagent for the orchestrator
git_commit: 032a2c95e200db2e59d56147cb9c74afed50b727
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "Windows 10 + Windows 11 launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, windows, win10, win11, webview2, win32, msvc, automation, drawer, credential-manager, sandbox, wfp, netd, msi, authenticode, launch-critical]
status: plan for review (rev 2.2)
rev: 2.2
rev_2_2_note: "Rev 2.2 (bead zigBrowser-126): WS0.6 VM identity no longer uses the SMBIOS UUID (a standard user cannot read Win32_ComputerSystemProduct.UUID — WMI Access-denied 0x80041003, wmic absent; verified on win11-m8). Identity = pinned SSH host key + a provisioning marker nonce (ZB_WIN11_MARKER / C:\\Users\\<user>\\zb\\.gate-identity, probe field identity_marker); virsh stays read-only (domstate, snapshot-list). Updated the reach-VM identity section, the WS0.1 probe fields, the fail-closed list and WS0.6."
rev_2_1_note: "Rev 2.1 (RoseCat 6146): WS8.7 folded into WS8's own gate (WS8.1-WS8.7); WS12 reconciled with the committed TTS Windows cloning leg (CW) and the committed STT live-mic = physical Windows 10 only (VM = WAV seam); WS13.4 uninstall must not report success while any sandbox user / WFP filter / task survives; WS13's final gate depends on every release component + the voice packaging, not merely starting after WS7."
last_updated: 2026-10-19
last_updated_by: Claude (Sonnet 5.5) review subagent
last_updated_note: "Rev 2 (review pass): verified every file:line anchor at HEAD 032a2c9 and corrected the ones that drifted or were wrong (see 'Review log (rev 2)' at the end); added the missing red assertions, green files, refactor gates, closures and real-screen cases for WS0-WS13; added the Win11 VM reachability/snapshot design, the file-server isolation requirements and WS0.6-WS0.8; reconciled the voice and macOS plans (WS12 table, milestone role map, netd listener port, backend-flag seam name); sharpened OD-W1..OD-W9 trade-offs without choosing."
primary_research: thoughts/searchable/shared/research/2026-10-19-windows-launch-support-surface.md
counterpart: thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md
---

# Windows Launch Support for zigBrowser — TDD Implementation Plan

> **PLAN ONLY.** No implementation and no live runs were done to write it. Agents prepare
> scripts and run them on the **two Windows hosts over SSH** (a Windows 11 VM and the
> user's physical Windows 10 machine), **never** on the user's Linux `DISPLAY :0`, live
> profile or live sockets. Every UI slice names a real-screen check that the orchestrator
> runs **with the user**. Decisions that belong to the user are listed in **Open decisions
> for the user** and are not taken here.

## Why this plan exists

The user: "Mac and Windows are the 2 main target systems, Linux is my environment, not the
primary target for users," and "Plan windows now. I'll have a Win11 VM and windows 10
physical machine available." So this plan supports **both Windows 10 and Windows 11** and
gates every milestone on **both** hosts. It is the counterpart of the macOS launch plan and
mirrors its shape: milestones WS0…WS13, a fail-closed two-host gate, a shared sandbox
backend seam, signing last, and named red tests for every slice. The voice-output (TTS) and
voice-input (STT) plans have Windows steps that wait on this plan (section **Voice plans**).

## Host markers used in this plan

| Marker | Meaning |
|---|---|
| **[L]** | Built and tested on Linux. No Windows host, no display (never `DISPLAY`, never Xvfb unless an existing Linux gate already does it under a private Xvfb). |
| **[W11]** | Needs the Windows 11 VM (the build host: MSVC, Windows SDK, WebView2 SDK). |
| **[W10]** | Needs the physical Windows 10 machine (run-only host: no toolchain; it receives binaries built on the VM). |
| **[W]** | Needs **both** Windows hosts in the same gate run. Every Windows milestone gate is [W] unless it says otherwise. |
| **[U]** | UI slice: needs a real-screen check run by the orchestrator with the user. |

## Current State Analysis

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
  `100.103.8.90` was offline for 105 days when checked; and `setup.ps1` must never run on the file server.
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
  refuses**: OpenSSH Server is not running). It is **also a file server**. The Win11 VM's
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

A Windows 10 (22H2) or Windows 11 user installs a **signed** zigBrowser and can: browse with an
isolated persistent profile; drive the full automation API (multi-window, freeze and
recovery, dialogs, popups, native input proven trusted) with the same client contract and
per-window FIFO semantics as Linux; run site flows behind the same approval grant; use a
native drawer (docked panel, movable "S" icon that hides while open, conversation with
copyable text, "-" fold animation into the icon) isolated from page JavaScript; store the
Claude token in Credential Manager through a Secrets window; sign in; and run the Claude agent
**inside an OS-native sandbox** behind the same `SandboxBackend` contract, whose security
proofs are hard launch gates. Verified by real-binary e2e on **both** hosts and by the user's
eyes on both screens. Until a code-signing identity exists, every artifact is called an
**unsigned development build, not a distributable artifact**.

### Observable behaviors (top level)

1. Given both hosts provisioned, when `tests/windows/gate.sh` runs, then it passes only if both
   hosts are reachable, on the expected OS builds, with an unlocked interactive test session,
   a WebView2 runtime, and every test reporting nonzero assertions — and fails in every other
   case.
2. Given a release build from the VM, when it runs on both hosts, then a real visible window
   renders the fixture and answers IPC.
3. Given an authenticated socket client, when it sends any automation command, then the live
   WebView2 page is driven and the result is read back with the Linux contract.
4. Given the drawer is on, when the user clicks the "S" icon, then a docked drawer opens, the
   icon hides, text is copyable, and "-" folds the drawer into the icon over 180 ms.
5. Given a token in the Secrets window, when a session starts, then the token reaches only the
   CLI's token channel and nothing a hook, page, log or environment can read.
6. Given the agent runs, when a hook or the CLI tries any network other than the allowlisted
   proxy and the two bridges, then it fails at the kernel.
7. Given the installer, when a user downloads and runs it on either OS, then it installs per
   user, its signatures verify, and an uninstall removes everything it added.

## What We're NOT Doing

- Not changing Linux GTK behavior or the macOS plan's slices; shared seams are extracted
  behavior-preserving, with the Linux gate staying green.
- Not shipping Windows on arm64 unless the user decides to (open decision **OD-W5**).
- Not shipping an AppContainer, Windows Sandbox or Hyper-V backend unless the user picks one
  (OD-W4); the WSL2 fallback is built **only** if a hard gate of the chosen backend fails.
- Not obtaining or paying for a code-signing identity (user action, OD-W3).
- Not exposing drawer text through a production automation-socket read (observation is the
  `--e2e-protocol` native census or screen capture only, as on Linux and macOS).
- Not running anything on the user's Linux display, live profile or live sockets; not touching
  the Windows 10 machine's shares, drives, existing accounts or the owner's profile.
- Not rewriting git history (fix-forward only); not committing red tests into gate-registered
  steps.

## Open decisions for the user

Each item gives a recommendation and its trade-offs. The plan proceeds on the recommendation
only where a slice can start without the decision; slices that depend on a decision say so.

| ID | Decision | Recommendation | Trade-offs | Blocks |
|---|---|---|---|---|
| **OD-W1** | Installer format | **Keep the per-user MSI** (WiX 3.14, already built and gated, no OSMF fee) for launch. | MSI: per-user, no admin, mature, 2 GB cab limit (fine for the 0.82 GB model), no built-in updates. **Velopack EXE**: per-user, delta auto-update, MIT, but replaces the existing MSI work. **MSIX**: built-in updates and Store path, but signing is mandatory, and AppData writes are virtualized per package (risk for a profile the agent helper also reads); `ms-appinstaller:` one-click is disabled. Inno/NSIS: fine, no advantage here. | WS13 |
| **OD-W2** | Auto-update | **WinSparkle** (Ed25519-signed appcast, works with an MSI) after launch; ship 1.0 with an in-app "new version" notice only. | WinSparkle: checks only, you supply the installer. Velopack: full updater, implies OD-W1 = Velopack. MSIX App Installer: implies OD-W1 = MSIX. None: users must reinstall. | WS13.5 |
| **OD-W3** | Code-signing certificate type and who buys it | **Azure Artifact Signing** if the user (as an individual in the US or Canada) or the user's organization qualifies: about $9.99/month, keys in Microsoft's HSM, signs from Linux with jsign. Otherwise an **OV** certificate on a hardware token or cloud HSM. **Not EV.** The user buys it; agents never hold a private key. | Artifact Signing: cheapest, short-lived certs (timestamping mandatory), identity validation can take 1-20 business days, needs a paid Azure subscription. OV: $150-500/year, hardware token makes CI signing awkward. EV: no longer bypasses SmartScreen, so the extra cost buys nothing. Any choice still shows a SmartScreen warning until reputation builds (weeks, hundreds of installs). | WS13 (distributable claim) |
| **OD-W4** | Sandbox technology | **Dedicated local sandbox users** (`zb-agent` for the CLI, `zb-hook` for hooks) + restricted tokens + a job object + a separate desktop + persistent WFP filters keyed on those users, installed by **one UAC prompt** at first agent use (the srt / Codex model). Hard gates WS8.1-WS8.6; **WSL2 is the fallback** and Windows agent launch stays disabled until one backend passes every gate. | Dedicated users: native Windows hooks, kernel-enforced network, strong cross-user process isolation; costs one admin prompt, creates two local accounts, and an orphan created through WMI/Task Scheduler may need a SYSTEM sweeper (sub-decision OD-W4c). **AppContainer/LPAC**: no extra accounts, Low IL, but the loopback exemption to reach a local proxy likely needs admin anyway, and Node/Bun/`claude.exe` under AppContainer is undocumented. **WSL2**: keeps every Linux guarantee and test, but needs virtualization (nested inside the VM, kernel-sensitive on KVM), is NAT-only on Windows 10, turns the user's hooks into Linux hooks, and adds a distro image. **Windows Sandbox**: not on Home; rejected. **Restricted token only (no admin)**: weakest network isolation; not recommended. | WS8, WS9, WS11 |
| **OD-W4b** | Token channel if `claude.exe` ignores `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` on Windows | **Credentials file in a directory readable only by `zb-agent`** (`CLAUDE_CONFIG_DIR`), written by the launcher just before start and deleted on exit. | The project rule is "never env". Cross-user isolation makes the CLI's environment unreadable to hooks, but env leaks into logs and children; the ACL'd file is narrower. Both are weaker than the Linux fd route. Decided only if spike WS8.3 fails. | WS8.3 |
| **OD-W4c** | Orphan sweeper | If WS8.5 shows a hook can escape the job (WMI `Win32_Process.Create`, a scheduled task), **install a tiny SYSTEM sweeper task** at the same UAC prompt that kills every process owned by the two sandbox users on request. | Adds a privileged component; without it an escaped process survives the browser (still network-blocked and token-less). | WS8.5 |
| **OD-W5** | arm64 scope | **x64 only at launch.** Windows 11 on Arm runs x64 apps under Prism; **Windows 10 on Arm cannot run x64 at all** (x86-only emulation), so Win10-Arm is unsupported. Native arm64 is a follow-up milestone. | Native arm64 needs an arm64 Python runtime, an arm64 `claude.exe` (the SDK wheel bundles x64 only), arm64 whisper, and an arm64 test host (none exists). Share is about 4-6% (unverified). | WS1, WS13 |
| **OD-W6** | Drawer UI technology | **Native Win32** (docked sibling panel, read-only RichEdit bubbles for copyable text, an owned layered no-activate popup for the "S" icon, fold animation driven by `agent_drawer.zig`). | Native: same structural isolation and native approval-card authority as Linux (GTK) and macOS (AppKit), reuses the portable Zig drawer logic; costs the most code (DPI, IME, accessibility by hand). **Second WebView2 with a local HTML drawer**: fast styling, free selection/IME/accessibility/CSS animation, but an extra renderer process, the drawer becomes a web context that renders model text and hosts the Approve button (needs strict CSP, text-only rendering, no remote navigation), and the floating icon still needs a native popup. WinUI 3 / XAML Islands: heavy runtime and MSVC-only toolchain. | WS5 |
| **OD-W7** | Minimum supported Windows | **Windows 10 22H2 (build 19045) and Windows 11 22H2+ (22621+), x64, Home and Pro.** | Older Windows 10 builds are out of support; Home lacks Hyper-V/Windows Sandbox (matters only for OD-W4 alternatives). | WS0 probe thresholds |
| **OD-W8** | WebView2 runtime distribution | **Evergreen bootstrapper** (current, ~2 MB) with a fail-closed launch-time check (WS1.4) and the **Evergreen standalone x64 installer** as a downloadable fallback. | Bootstrapper needs network at install. Standalone: offline, larger. Fixed Version: >250 MB, the app must update it, and Windows 10 needs `icacls` grants for the AppContainer SIDs. | WS13.2 |
| **OD-W9** | SSH key for the Windows hosts | **A new dedicated ed25519 key** (`/home/maceo/vms/win-hosts/zb_win_key`) for both Windows hosts, not the Mac key `zb_mac_key`. | A dedicated key can be revoked per host family without touching the Macs; reusing the Mac key is one less file but widens the blast radius. | WS0 |

### Decision sharpening (rev 2 review): costs, risks and what each choice commits us to

The "Recommendation" column above is the planner's lean, **not** a decision; nothing below picks
for the user. For each item: what each option costs, what can go wrong, and what it locks in.
"Early" means work that must start before the milestone that needs the answer.

**OD-W1 Installer format** (blocks WS13; touches WS8 uninstall, WS13.4, the voice plans' installer slot).
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
  certificate (a machine-wide certificate-store change, **not allowed on the file server** under the
  isolation rules; the VM only). Per-package file-system virtualization of AppData writes breaks the
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

**OD-W3 Signing identity and who buys it** (WS13.6 and every "distributable" claim; **long lead time, so
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
  uninstall path for system state. On the file server this creates local accounts and **machine-wide**
  filters, so it needs the isolation proofs in "File-server isolation requirements".
- *AppContainer/LPAC.* No new accounts. Unverified: Node/Bun `claude.exe` under AppContainer; the loopback
  exemption needed to reach netd; a hook that must run user tools cannot be in an AppContainer. Network
  isolation depends on capability SIDs and a loopback exemption that is per-package and machine-wide.
- *WSL2.* Reuses `LinuxBwrapBackend` and its tests and the token fd route. Costs: hardware virtualization
  (nested KVM on the VM, unverified; a physical Windows 10 machine must have it enabled in firmware, which we
  cannot assume for a file server), a distro image to ship or download, NAT-only networking on Windows 10, a
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

**OD-W6 Drawer technology** (blocks the green files of WS5 only; the reds and behaviors stay).
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
  file server it lands in `zbtest`, which can read whatever the share ACLs let ordinary users read.
- *One key per host.* Independent revocation; two files, two `known_hosts` entries.
- *Unattended (no passphrase) versus agent-held.* The gate needs unattended runs; an unencrypted private
  key on disk is the cost. Either way restrict it in `authorized_keys` with `from="<linux tailnet IP>"` and
  `restrict` where Windows OpenSSH honors them (standard-user keys do; `administrators_authorized_keys`
  keys follow the same options but are a larger privilege), and pin host keys (WS0.8) instead of the Mac
  gate's `StrictHostKeyChecking=no`.

## Host provisioning (what the user sets up)

Agents never SSH to a host before the user finishes that host's list. Each item has a probe in
`tests/windows/host_probe.ps1` (WS0) so the gate can check it.

### Physical Windows 10 machine — `100.123.34.15` (`file-server-win-mac`), run-only host

1. **Enable OpenSSH Server first** (port 22 refuses today): Settings → Apps → Optional
   features → OpenSSH Server, or elevated
   `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`, then
   `Set-Service sshd -StartupType Automatic` and `Start-Service sshd`. Restrict the inbound
   rule to Tailscale: `Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -RemoteAddress 100.64.0.0/10`
   (it is a file server; do not expose SSH to the LAN). **Also, in `C:\ProgramData\ssh\sshd_config`
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
   accounts or the owner's profile; the gate refuses any remote path outside that root
   (WS0.5).
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
   secret, and on a file server it also logs `zbtest` in after every reboot, so prefer the manual
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
   the file server unless the owner agrees.
9. **Admin presence only for:** steps 1-3, and the one WS8 UAC prompt (the user clicks it in
   person on the real screen).
10. **Later, for STT VS10/VS11:** a microphone, and "Let desktop apps access your microphone"
    on for `zbtest`.

### File-server isolation requirements (rev 2; hard, fail-closed; physical Windows 10 machine only)

The machine serves files to other people. A test run must be unable to read, write, slow down or
disconnect anything it serves. Every item is checked by `host_probe.ps1` or by WS0.7, and a failed check
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
   the gate fails with `file-server: zbtest can write to <path>` and the owner must remove it (for example
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
5. **WS8 on the file server is the highest-risk step.** Required before the first setup run there: (a) the
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
6. **Resources.** The probe records free space on `C:` and fails below 20 GB; the gate keeps run artifacts
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
  physical Windows 10 file server uses `zbtest`. Key: `/home/maceo/vms/win11-m8/zb_win_key`
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
So `host_probe.ps1` cannot read `interactive_session`/`locked` from any CLI here — WS0.1 must get them
from a small WTS-API helper (`WTSGetActiveConsoleSessionId` + `WTSQuerySessionInformation` for
`WTSConnectState`, plus LogonUI detection in that session), which also serves WS0.4's console check.
`whoami /groups` does work as a standard user and is the source for WS0.7's `groups`/SID checks.

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
  `tests/mac/gate.sh`). It builds on the VM, fetches the exe, pushes it to both hosts, runs each
  slice's tests on each host, and exits nonzero on any failure. Never `DISPLAY`, never Xvfb.
- **Fail-closed rules (WS0.2):** no host configured → `NOT RUN` + exit 1; host unreachable;
  wrong OS build or arch; no active unlocked interactive test session; missing WebView2
  runtime; test exit 77 (skip) → **fail**; a test that does not print `ASSERTS <n>` with
  `n > 0` → **fail**; a GUI test whose launched PID is not in the active console session →
  **fail**. Rev 2 adds: SSH host key not the pinned one; the Win11 VM's `identity_marker` not the configured
  `ZB_WIN11_MARKER` nonce (rev 2.2 — the SMBIOS UUID is unreadable by a standard user, bead zigBrowser-126);
  the Win11 VM not `running` per `virsh`; the console session owned by someone other than the
  test user; `zbtest` in a forbidden group, or able to write a served path on the file server (WS0.7); a
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
  probes use TEST-NET `192.0.2.1` and loopback decoys, **never** the file server's LAN or its
  SMB shares.
- **Secrets:** a disposable Credential Manager target name and a canary token in every test;
  never the user's real credential. Credential tests run inside the interactive session task
  (Credential Manager may not persist over an SSH network logon).
- **Chat observability:** `--e2e-protocol` native drawer census or capture, never a socket read.
- **Real-screen (UI slices):** each names its cases; the orchestrator runs them with the user on
  the Windows 10 machine's monitor and on the VM console; a UI slice is not approved until both
  pass.
- **Closure tests** are Tier-1 real-binary e2e. A slice is done only when its closure e2e was
  **observed to execute** with nonzero assertions on both hosts; a skip is UNCLOSED.

### What runs where

| Work | [L] Linux | [W11] VM | [W10] physical |
|---|---|---|---|
| Gate runner + selftests with fake hosts (WS0) | yes | — | — |
| Host probes (WS0) | — | yes | yes |
| `cross-check`, `ipc-test-win`, pure-Zig units (drawer geometry, protocol, grant, config seam) | yes | — | — |
| Python backend contract tests for the Windows backend's spec projection (WS8.0) | yes | — | — |
| Windows build (MSVC) | — | yes | — |
| PE import census of the built exe (WS1.1) | yes (on the fetched exe) | — | — |
| Any real-binary e2e, GUI, socket, sandbox, network, secrets test | — | yes | yes |
| Real-screen checks | — | yes (console via virt-viewer) | yes (its monitor) |
| Signing (OD-W3 Artifact Signing via jsign) | yes | or here (signtool) | — |

## Shared code with macOS and Linux — exact reuse points

| Shared piece | Where it lives | Windows use | Owner of the shared change |
|---|---|---|---|
| `SandboxBackend` protocol + `LaunchSpec` | `agent/host/zb_agent_host/sandbox.py:71-229` | New `WindowsSandboxUserBackend` implements every method; `LaunchSpec.argv` becomes the launcher argv; `unshare`/`mounts` project to ACL grants | WS8 adds the class; protocol unchanged |
| Egress capability (backend supplies endpoint + policy) | macOS plan MS0/Shared sandbox backend contract (:408-448; egress pinned in MS6 :1115-1140; the plan header says rev 6 but its revision history now runs to rev 9, none of which changes this contract) | Same shape as macOS (host netd on a `127.0.0.1` TCP port + per-principal kernel rules; WFP instead of Seatbelt), **but the port policy differs**: macOS uses an OS-selected ephemeral per-session port (MS6 egress item 1); Windows must use a **fixed range reserved at setup** because persistent WFP filters cannot name a port chosen later | Whichever of MS6/WS9 lands first adds **netd TCP-listener mode** (today netd binds only `AF_UNIX`, netd.py:470-471, and forks bwrap, :782-793). The listener takes its port policy **from the backend** (`0` = ephemeral for macOS, a `lo..hi` range for Windows) so neither plan has to change the other's contract |
| netd allowlist parser, SNI check, global-address vetting | `netd.py:107-179, 414-416` | Unchanged; only the listener transport and its own confinement differ | WS9 |
| App-side hook spawn (profiles do not nest) | macOS MS6 design: "Hooks spawned app-side, each in its own profile; stdio over `SCM_RIGHTS`" (macOS plan :1108). The plan does **not** yet name a `hook_broker.py` module or a `zb-hook-run` client protocol (`zb-hook-run` is only listed as an existing agent-home script, :1059) | Same idea: the Windows server spawns as `zb-hook`; stdio crosses as duplicated handles | Shared protocol module `agent/host/zb_agent_host/hook_broker.py` (new). **Open cross-plan item:** the macOS plan must adopt this module name and a transport-neutral frame format (fd passing vs handle duplication are the two transports) or this plan builds it first; flagged, not edited here |
| Drawer logic | `src/agent_drawer.zig` (geometry :14-82, gesture :27, fold :86-103, persistence :244-277) | Exports enabled for `.windows` (today `.linux` only at :338-358) | WS5 widens the gate; logic unchanged |
| Helper frames + validation | `src/agent_helper.zig:123-153`, `src/agent_protocol.zig` | Unchanged | — |
| Token shape | `src/agent_secrets.zig:14-19` | Unchanged; split the portable checks from the `std.os.linux` file store | WS6 |
| Approval grant contract | drawer plan D10 (:507-533), macOS MS4 | Same tuple, 120 s, single-use, `options.expect`, −32015 | Platform-neutral Zig; WS4 only runs it on Windows |
| Automation server/router/engine/queue/recover/flows | `src/automation_server.zig`, `src/automation/*` | Unchanged; new `PagePort` impl | — |
| Fallible backend-flag seam | macOS MS3.2 names `applyMacBackendFlag(flag, value) !void` in `src/webkit.zig` (macOS plan :886-912; not landed; a repo-wide search at HEAD finds neither that name nor `applyBackendFlag`) | Land as **one** `applyBackendFlag(os, flag, value) !void` in `src/webkit.zig` used by both | **Naming divergence:** the macOS plan fixes a macOS-only name with no `os` parameter. First of MS3/WS3 to land builds the shared function; the macOS plan's name becomes a thin alias or the plan is amended (flagged, not edited here) |
| Async-completion ownership contract + ABI-absence rule | macOS MS2 | Same rules: copied inputs, exactly once, no effect after abandon; an unsupported seam is absent at link time | — |
| Real-screen runner | `tests/manual/real_screen_check.py` | New Windows backend for capture + foreground proof | WS5 |
| Two-host fail-closed gate pattern | `tests/mac/gate.sh` | `tests/windows/gate.sh` copies its structure and its `|| return 1` discipline | WS0 |

---

## WS0: Test hosts + fail-closed two-host gate   [L] then [W]

**Goal.** A gate that cannot false-green, driven from Linux, that proves each host is the host it
claims to be, with an unlocked interactive session, before any product test runs.

### Behavior WS0.1: the host probe reports identity and readiness
**Given** a provisioned host, **when** `host_probe.ps1` runs over SSH, **then** it prints one JSON
object: `os_build`, `edition`, `native_arch` (from `IsWow64Process2`'s native machine, not
`PROCESSOR_ARCHITECTURE`), `test_user`, `interactive_session` (id, state `Active`, connected to
the console or an RDP session that was moved to the console), `locked` (LogonUI running in that
session), `webview2_pv` (read from the three registry places in provisioning item 4), `python`, `zig` (VM only),
`free_gb`, `root` (the allowed remote root), plus (rev 2) `schema` (an integer the gate pins), `identity_marker`
(rev 2.2: the provisioning nonce from `C:\Users\<user>\zb\.gate-identity`, replacing the unreadable SMBIOS UUID),
`console_user`, `groups`, `shares`, `zbtest_write_paths`, `listeners`, `fw_rules_hash`, `snapshot_marker`
(the VM), `sshd_listen` and `sshd_allowusers` (the physical host).

### Behavior WS0.2: the gate fails closed
**Given** any of: `ZB_WIN10_HOST` or `ZB_WIN11_HOST` unset; a host unreachable; build below OD-W7;
`native_arch` not `x64`; no active interactive session; session locked; `webview2_pv` empty;
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

### Behavior WS0.5: the file-server host is fenced
**Given** the Windows 10 host, **when** any gate step names a remote path, **then** the path must be
under `C:\Users\zbtest\zb\` (resolved, no `..`, no junction out) or the gate refuses before
running anything.

### Behavior WS0.6: the Win11 VM is the VM it claims to be, and a down VM fails the gate
**Given** `ZB_WIN11_HOST`/`ZB_WIN11_PORT`/`ZB_WIN11_DOMAIN`, **when** the gate starts, **then** it checks, in
this order, `virsh` state `running`, TCP reachability within 15 s, the pinned host key, the probe JSON, and
that the probe's `identity_marker` equals the pinned `ZB_WIN11_MARKER` nonce (rev 2.2: the SMBIOS-UUID check is
dropped — a standard user cannot read it, bead zigBrowser-126); each failure exits nonzero with the exact messages
under "How the gate reaches the Win11 VM". The gate has no flag that starts, reverts or skips the VM.

### Behavior WS0.7: the file-server host is not disturbed
**Given** the Windows 10 host, **when** the probe runs, **then** it reports `groups` of `zbtest`,
`console_user`, `shares` (names and root paths), `zbtest_write_paths` (served paths where the ACL math says
`zbtest` has Modify/Write/Full), `free_gb`, `listeners` (22, 135, 139, 445, 3389) and `fw_rules_hash`; the gate
fails if `groups` has a forbidden group, `zbtest_write_paths` is non-empty, `console_user` is not `zbtest`
(it never switches users), or `listeners`/`fw_rules_hash` differ between the pre-run and post-run probes
(any difference means the run changed the machine).

### Behavior WS0.8: transport hygiene
**Given** any remote copy, **when** the gate stages files, **then** it uses `mktemp -d` staging on Linux (never
a fixed `/tmp` name), `StrictHostKeyChecking=yes` against `tests/windows/known_hosts`, `BatchMode=yes`,
`ConnectTimeout=15`, tars **without** `2>/dev/null` and checks the tar exit status, includes every directory
the slice needs (`src build.zig build.zig.zon tests tools agent packaging docs/how-to-build.md` as the slice
requires, listed in one manifest file), and deletes the remote staging under `zb\runs\<id>\` at the end.

- **Property (WS0.5):** invariant — for any generated path string (relative segments, `..`,
  UNC `\\server\share`, drive letters, mixed slashes, junction names), `allowed(path)` is true
  only if its normalized form starts with the root. Hypothesis-style generator in the selftest.
- **Files touched:** `tests/windows/gate.sh` (new), `tests/windows/host_probe.ps1` (new),
  `tests/windows/hosts.env.example` (new), `tests/windows/build-on-windows.sh` (new; the
  generalized `build-in-guest.sh` with SDK paths read from the probe instead of hardcoded),
  `tests/windows/gate_selftest.py` (new, Linux), `tests/e2e/slice2_common.py`
  (`run_windows_interactive_until`: session/visibility checks, time bound, job cleanup),
  `tests/guest/build-in-guest.sh` (becomes a thin wrapper).
- 🔴 **Red** `tests/windows/gate_selftest.py` [L]: runs `gate.sh` against a fake `ssh`/`virsh` on `PATH`
  that replay canned probe JSON. Failing assertion today:
  `assert proc.returncode != 0 and "NOT RUN: no Windows host configured" in proc.stderr and "ZB_WIN10_HOST" in proc.stderr`
  — red because `tests/windows/gate.sh` does not exist (`FileNotFoundError`). Each WS0.2 condition is
  one case; the "healthy" case asserts `returncode == 0` and that `ASSERTS` totals are > 0. Named
  assertions for the other behaviors (each case also has a **mutant** that must flip it, run before the
  green commit is accepted):
  - WS0.1 `assert set(json.loads(probe_out)) >= REQUIRED_KEYS and probe["schema"] == 1` — red: no
    `host_probe.ps1`. Mutant: drop `native_arch` from the script ⇒ the case fails. A second, **real-host**
    red (`tests/windows/host_probe_live.py`, runs only through the gate, unregistered until green) asserts
    `probe["native_arch"] == "x64"` on a host whose `PROCESSOR_ARCHITECTURE` lies (an x86 shell on x64).
  - WS0.3 `assert not (set(child_env) & {"DISPLAY","WAYLAND_DISPLAY","XAUTHORITY"})` for every child the
    fake `ssh` records, with `DISPLAY=:0` exported to the driver. Mutant: remove `env -u` ⇒ red.
  - WS0.4 `assert selftest_cleanup["tasks_left"] == 0 and selftest_cleanup["procs_left"] == 0`, and the
    inverse case `assert gate_rc != 0` when the fake host reports one leftover task. Mutant: skip
    `schtasks /delete` ⇒ red.
  - WS0.5 `assert allowed(p) is False` for the generated bad paths plus `assert allowed(r"C:\Users\zbtest\zb\x") is True`.
    Mutant: normalize with a naive `startswith` (no `..`/junction handling) ⇒ the property fails.
  - WS0.6 `assert rc != 0 and "Win11 VM win11-m8 is shut off" in err` (fake `virsh domstate`), the unreachable,
    host-key and UUID cases likewise. Mutant: treat a UUID mismatch as a warning ⇒ red.
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

**Gate (WS0):** [L] `windows-gate-selftest` green; then [W] `gate.sh --probe-only` green on both
hosts after provisioning (the pre/post probe pair of WS0.7 included). Not a UI slice, so no
real-screen case; but the first `--probe-only` run on each host is watched by the orchestrator once, to
confirm that the "interactive session" it reports is the one on the monitor (the only human check this
slice has).

---

## WS1: Native build that runs and renders on both hosts   [W11] build, [W] run, [U]

**Goal.** A reproducible MSVC build on the VM whose exe runs on both hosts in a real, visible
window, with honest exit codes and build info.

### Behavior WS1.1: the release exe is a clean x64 PE with a known import set
**Given** `build-on-windows.sh ReleaseSafe` on the VM, **when** the exe is fetched to Linux,
**then** `tests/windows/pe_census.py` [L] finds machine `0x8664`, subsystem GUI or console as
designed, and an import table within an allowlist (system DLLs + `api-ms-win-crt-*`; any
`vcruntime*.dll` or `msvcp*.dll` is a failure unless the installer ships it), and records the
pinned WebView2 SDK version.

### Behavior WS1.2: M8 render, reply channel and load-fail pass on both hosts
**Given** the exe on each host, **when** the gate runs `m8_render_test.py`,
`m8_reply_channel_test.py`, `m8_load_fail_test.py` with `ZB_WIN_GATE=1`, **then** each prints
`PASS` and `ASSERTS n>0` on each host; with `ZB_WIN_GATE=1` a missing precondition exits 1, not 77.

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
`x86_64-on-arm64` if run under emulation), and `pe_census.py`'s arch matches.

- **Property:** no property — fixed inputs (one exe, fixed fixtures), nothing to generate over.
- **Files touched:** `src/webview2_shim.cpp` (CapturePreview screenshot, runtime-missing message,
  version line arch/build), `tests/windows/pe_census.py` + `pe_census_selftest.py` (new), `tests/windows/gate.sh`
  (WS1 phase), `tests/e2e/m8_*.py` (honor `ZB_WIN_GATE=1` → fail instead of skip; print
  `ASSERTS`), `tests/e2e/win_screenshot_test.py`, `win_runtime_missing_test.py`, `win_version_test.py`
  (new), `tests/windows/build-on-windows.sh`.
- 🔴 Red `tests/e2e/win_screenshot_test.py` [W]: failing assertion
  `assert rc == 0, f"--screenshot exit {rc}"` (today 11 / `ZB_EXIT_SNAPSHOT_FAILED`) and
  `assert nonuniform(png)` (a stub that writes a blank PNG must fail). Mutant: write a 1x1 white PNG ⇒ red.
  The other WS1 reds (each with a mutant, run on both hosts before green):
  - WS1.1 `tests/windows/pe_census_selftest.py` [L]: `assert census(fixture_vcruntime_pe).verdict == "FAIL: vcruntime140.dll"`
    and `assert census(fixture_clean_pe).machine == 0x8664`. Mutant: an allowlist that matches by prefix
    `vc*` ⇒ the clean-but-for-`vcruntime` fixture passes ⇒ red.
  - WS1.2 `tests/windows/gate_selftest.py` case `m8_precondition_missing`: `assert rc == 1 and "ZB_WIN_GATE" in err`
    (today the m8 tests return `SKIP_EXIT` = 77: `slice2_common.py:20`, `m8_render_test.py:204-206, 322-333`).
    Mutant: leave `SKIP_EXIT` ⇒ red. Plus on both hosts `assert asserts_printed > 0` for each of the three m8 tests.
  - WS1.4 `tests/e2e/win_runtime_missing_test.py`: `assert rc == 9 and "the Microsoft Edge WebView2 Runtime is not installed" in err`
    (today `zb_app_run` returns `ZB_EXIT_RUNTIME_MISSING` at webview2_shim.cpp:709 but **no source file prints
    that message**, so the message half is red; the exit-code half may already be green and the spike decides
    whether the env seam works). Mutant: print the message but exit 1 ⇒ red; exit 9 without the message ⇒ red.
  - WS1.5 `tests/e2e/win_version_test.py`: `assert re.fullmatch(r"zigBrowser \(WebView2 [\d.]+; Windows 10\.0\.\d+; x86_64\)", out.strip())`
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

**Gate (WS1):** [W] WS1.1-WS1.5 on both hosts + [L] `cross-check` unchanged + `win-render`.

---

## WS2: WebView2 PagePort adapter + automation ABI (WS2.0, WS2a, WS2b, WS2c)   [W]

**Goal.** The full automation surface on Windows with the same client contract and per-window
FIFO semantics as Linux, proven by three production chains (the macOS plan's Closures A/B/C).

### Design
- New `src/automation_wv2_port.zig` implements `PagePort` (gated `os.tag == .windows`), wired in
  `buildAutomationConfig` beside the GTK port.
- `webview2_shim.cpp` gains the `zb_automation_*`/`zb_native_*` functions. The UI-thread marshal
  is a `WM_APP` message posted to the host window + a bounded, deadline-guarded wait (the analog
  of `auto_queue_on_gtk`/`auto_job_wait`, webkit_shim.c:1692-1812). Async-completion ownership
  contract as macOS MS2: copied inputs, exactly-once completion, a generation guard so nothing
  dispatches after the waiter abandons.
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
| `zb_app_run`, `zb_version_line`, `zb_run_screenshot` | WS1 | exist; screenshot real in WS1.3 | m8_*, `win_screenshot_test` |
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

### WS2.0: the transport is local-only and owner-only   [W]
**Given** the browser with `--automation-api`, **when** it starts, **then** exactly one AF_UNIX
listener exists at `%LOCALAPPDATA%\zigbrowser\zigbrowser-automation-<nonce>.sock` (no TCP), the
directory, socket and `<socket>.token` have a **protected DACL granting only the current user**
(no inherited ACEs), and from the `zbother` account (VM) connecting or reading the token fails.
- First run the existing ADR-1 spike `automation-afunix-spike-win` on both hosts; **if AF_UNIX
  fails, stop and update ADR-1** (as that plan requires) — no silent TCP fallback.
- Replace the POSIX-only `restrictSocketMode` (`chmod`, automation_server.zig:1513-1517) and the
  `0o600` sidecar mode (:1496-1511) with one platform seam `restrictToOwner(path)`
  (POSIX `chmod 0600`; Windows `SetNamedSecurityInfoW` with `PROTECTED_DACL_SECURITY_INFORMATION`);
  `automationSocketPath` uses `%LOCALAPPDATA%` on Windows (app.zig:453-460).
- 🔴 Red `tests/e2e/win_transport_test.py`: `assert acl_principals(sock_dir) == {current_sid}`
  (today the server fails to start or `chmod` errors).
- Property: invariant — for generated nonces, `planSocketPath(.windows, base, n)` stays under
  `base\zigbrowser\` and below `UnixAddress.max_len` (extends automation_transport.zig:49-62) [L].
- **Host difference (rev 2):** the cross-user negative (`zbother` cannot connect or read the token) runs on
  the **VM only**. The physical Windows 10 machine must not get a second local account (isolation rule 1),
  so there the test asserts the DACL itself (`acl_principals(...) == {zbtest_sid}` with no inherited ACE and
  no `Everyone`/`Users`/`Authenticated Users`) and that a connection from a *different-integrity* process of
  the same user is allowed (the socket is per-user, not per-process). Mutant (both hosts): leave the default
  inherited DACL from `%LOCALAPPDATA%` ⇒ the principals assertion is red (it contains `Administrators`/`SYSTEM`
  inherited ACEs; the rule decides whether those are acceptable and the test pins that decision).
- **Compile check first [L]:** `restrictSocketMode`'s `std.c.chmod` and `createFile(... .permissions = .fromMode(0o600))`
  (automation_server.zig:1496-1517) may not compile for Windows (**unverified**; research §1.2). The first
  step of WS2.0 is `zig build -Dtarget=x86_64-windows-gnu` of `src/automation_server.zig` under
  `zig build test-compile`-style object output; a compile error is the legitimate red for the `restrictToOwner` seam.

### WS2a: routed commands, private world, readiness   [W]
- **WS2a.0 (spike, both hosts):** CDP isolated world exists, its globals are invisible to the page,
  and it survives navigation. Result recorded red→green before WS2a.1.
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
- **WS2b.1 (spike, both hosts) trusted-event matrix:** `isTrusted` true, focus, click, key, text,
  contenteditable + `beforeinput` cancel honored, scroll, pointer move, navigation during input,
  partial typing, deadline abandonment (no dispatch after the waiter leaves). CDP input is
  **unverified** to produce `isTrusted: true` in WebView2; the capability table
  (automation_platform.zig:77-98) is changed only after this passes. If CDP input is not trusted,
  WS2b stops at the spike and the orchestrator brings it to the user (no silent fallback to
  `SendInput`, which is system-wide).
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

Every test below is written first in an **unregistered** file, run red on both hosts (the red run is
recorded), registered in the green commit, and has a named mutant that must turn it red again before the
green commit is accepted.

| Behavior | Red test (unregistered until green) | Exact failing assertion (today's reason) | Mutant that must flip it | Green files |
|---|---|---|---|---|
| WS2.0 transport | `tests/e2e/win_transport_test.py` | `assert acl_principals(sock_dir) == {current_sid}` (server fails to start or `chmod` errors) | default inherited DACL | `automation_server.zig` `restrictToOwner`, `app.zig` socket base |
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
  (`cross-check` plus a link-time absence assertion in `win_abi_absence_test.py`, which fails if an
  undriven debug seam is present).
- **Closure criteria:** Closures A, B, C below, each observed to execute with nonzero assertions on both
  hosts. Closure B and C now name their e2e files above.
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

**Gate (WS2):** three gates (WS2a, WS2b, WS2c), each [W] on both hosts, plus `win-native-click`,
`win-popups` and `win-crash-page`.

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
  `src/automation_wv2_cookie_port.zig` (new), `tests/e2e/win_profile_persist_test.py`,
  `tests/e2e/win_config_flags_test.py`, `tests/e2e/win_cookie_test.py` (new).
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

**Gate (WS3):** [W] both hosts. Not a UI slice.

---

## WS4: Site flows + approval grant authority on Windows   [W]

**Goal.** The platform-neutral flows and the grant authority behave on Windows exactly as on
Linux. No new grant code: the tuple
`sha256(tool, window_id, origin, account, target_fp, load_serial, normalized_args)`, 120 s,
single-use, pre-dispatch revalidation of origin/`load_serial`/`crashed`/`recovering`,
`options.expect={account,target_fp}` checked in the same FIFO ticket (−32015), and the T5 mutants
(navigation, selector-retarget, wrong account, one-field-at-a-time) all refuse.

- **WS4.1** page worlds, iframes, related popups, socket clients, model text and hooks cannot
  approve (negative proofs on Windows).
- **WS4.2** per-write confirmation; a dry run performs no committing click, no composer typing, no
  pacing count.
- **WS4.3** the login gate reads the session cookie through the WS3 cookie port.
- 🔴 Red `tests/e2e/win_flow_refusal_test.py`: `assert telemetry_root_spans_after == telemetry_root_spans_before`
  for each forged approval (today `-32011`: no port).
- **Characterization note (rev 2):** WS2 lands before WS4, so these tests would pass on arrival and a test
  that never failed proves nothing. Each is therefore proven by **a mutant run on Windows**: (1) skip the
  pre-dispatch `load_serial` revalidation ⇒ the navigation-retarget test must fail; (2) skip the
  `options.expect` check ⇒ the wrong-account test must fail with a commit instead of -32015; (3) let a
  popup-world caller approve ⇒ the related-popup test must fail; (4) mint without the single-use mark ⇒ the
  replay test must fail. The first red run is a run **before the WS2 port is wired** (`pagePort()` null ⇒
  `-32011`, as stated), recorded as the red evidence; the mutants prove the assertions after wiring.
- 🟢 Green: no new source; any Windows-specific wiring the port needs (`automation_wv2_port.zig` returning
  the origin and `load_serial` the flows read) is part of WS2. 🔵 Refactor: the fixtures and the
  forged-approval helper are shared with `tests/e2e/` Linux flow tests (one helper module, not a copy).
- **Real-screen check:** none; not a UI slice (the native Approve click is WS11.3's check).
- **Closure:** BLOCKING for the refusal belts (socket → broker → engine); the positive commit
  closure is WS11.3 (the only native minter is WS5's card, the only real `tool_use` source is
  WS11's helper). **Files touched:** tests only, plus any Windows-specific wiring the WS2 port
  needs. **Gate (WS4):** [W] fixtures only, no live sites. Not a UI slice.

---

## WS5: Native Win32 drawer (per OD-W6)   [L] logic, [W], [U]

**Goal.** The accepted drawer UX on Windows: bottom dock, movable "S" icon that hides while open,
conversation with copyable text, "-" fold animation, structural isolation from page JavaScript.
Not wired to an agent yet (Send shows "Agent not available yet", like Linux S1/S2). If the user
picks the WebView2-hosted drawer in OD-W6, the behaviors and tests below stay; only the green files
change.

### Design
- `src/agent_drawer_win.cpp` + `.h` (new), compiled in `configureWebView2Backend`; mounted from
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
- **Files touched:** `src/agent_drawer_win.cpp/.h` (new), `src/agent_drawer.zig` (export gate),
  `src/webview2_shim.cpp` (mount, bounds), `build.zig` (compile + rc), `src/zigBrowser.rc` (new),
  `packaging/windows/zigBrowser.manifest` (new), `tests/e2e/win_drawer_test.py` (new),
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
    the destroy in the popup close path ⇒ red.
  - WS5.6 `assert census_before == census_after` after `page.evaluate` tries `postMessage`/DOM reach and a
    socket client tries every method name containing `drawer` (all `-32601`/`-32011`). Mutant: expose a
    `drawer.state` method ⇒ red.
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

**Gate (WS5):** [L] Zig properties; [W] `win_drawer_test.py` both hosts; all five real-screen cases.

---

## WS6: Secrets window + Credential Manager store   [W], [U]

### Behavior WS6.1: the token store
**Given** a valid token shape (`agent_secrets.zig:14-19`), **when** Save runs, **then** it is written
with `CredWriteW` (`CRED_TYPE_GENERIC`, target `zigBrowser/ClaudeAgentToken/default`,
`CRED_PERSIST_LOCAL_MACHINE`; a 512-char token fits the 2560-byte blob) and read back with
`CredReadW`; Remove deletes it. The "Save to a private file instead" path writes
`<agent_home>\secrets\claude-token` with a protected owner-only DACL, DPAPI-wrapped
(`CryptProtectData`, `CRYPTPROTECT_UI_FORBIDDEN`).

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

**Gate (WS6):** [W] both hosts + `win-secrets-window`.

---

## WS7: Agent setup and provisioning on Windows   [L] partly, [W]

**Goal.** `--agent-setup` builds the immutable agent home on Windows (today refused, app.zig:52-55).

### Behaviors
- **WS7.1** the home layout `dist-<n>\…` with an atomic `current` switch that needs no privilege:
  a **directory junction** swapped by create-new-then-`MoveFileExW(MOVEFILE_REPLACE_EXISTING)` of a
  pointer, or a `current.json` pointer file (whichever the red proves atomic); the executable path
  comes from `GetModuleFileNameW` (not `/proc/self/exe`, app.zig:130).
- **WS7.2** the bundled runtime: a pinned x64 Python (python-build-standalone `install_only` or the
  embeddable zip; decided by the red on both hosts), the pinned Agent SDK wheel with its bundled
  `claude.exe`, the `zb_agent_host` package.
- **WS7.3** a **native launcher `zb-claude.exe`** (Zig) replaces the Python `zb-claude` wrapper on
  Windows: Windows has no `exec` (`os.execv` spawns and exits, which would make the SDK think the CLI
  ended), and the SDK refuses `.bat`/`.cmd` shims. The launcher sets up the token channel, starts
  `claude.exe` in the session's job, waits, and returns its exit code.
- **WS7.4** the SAI copy follows the final "Hook commands only" rule and inherits the S3a
  corrections (da5eb70): dependency trees copied unscanned, links resolving outside an item root
  skipped with **no target bytes** in the home (Windows: symlinks and junctions both), only hook
  command lines validated, no access to the real `%USERPROFILE%\.claude` or repositories.
- **Files touched:** `agent/host/zb_agent_host/setup.py`, `provision.py`, `files.py` (Windows
  atomic/ACL helpers), `src/app.zig` (Windows setup path), `src/zb_claude_launcher.zig` (new),
  `build.zig` (launcher exe), `tests/e2e/win_agent_setup_test.py` (new),
  `agent/host/tests/test_setup_windows_layout.py` (new, [L] for the pure layout/copy rules with a
  fake filesystem).
- 🔴 Red `win_agent_setup_test.py`: `assert rc == 0 and (home / "current").exists()` (today exit 1,
  "the Claude Agent is Linux-only"); and the canary skill target is absent from `dist-<n>`. More reds:
  - WS7.1 `assert reader_never_sees_missing_current` while a second `--agent-setup` swaps `current` in a loop
    (the reader polls 1000 times; mutant: delete-then-create ⇒ a miss ⇒ red).
  - WS7.2 `assert (home / "current" / "runtime" / "python.exe").exists() and pinned_wheel_sha256 == EXPECTED`
    (mutant: an unpinned `pip install` ⇒ red).
  - WS7.3 `agent/host/tests/test_launcher_contract.py` [L] plus `tests/e2e/win_launcher_test.py` [W]:
    `assert child_exit_code == launcher_exit_code and orphan_count == 0` and `assert argv == [claude_exe, *args]`
    with no `.bat`/`.cmd` (mutant: launcher returns 0 always ⇒ red).
  - WS7.4 `assert canary_target_bytes not in tree_bytes(home)` for a skill symlink and a junction (mutant:
    follow links ⇒ red).
  - WS7.5 (new) `agent/host/tests/test_windows_import.py` [L]: import every `zb_agent_host` module with
    `sys.platform = "win32"` and `fcntl`, `pty`, `termios`, `resource` blocked; `assert not failures`.
    Red today for `login.py` (`import fcntl` :28, `import pty` :31, `import termios` :38), `hook_run.py:26`
    and `seccomp.py:13` (both `fcntl`), and the POSIX-only `os.fork`/`os.execv` paths (`netd.py:782-793`,
    `relay.py:267`, `launch.py:111`, `token.py:119-129`) must be unreachable on Windows or replaced. Mutant:
    re-add a top-level `import fcntl` ⇒ red.
- 🟢 Green: `setup.py`/`provision.py`/`files.py` Windows helpers, `zb_claude_launcher.zig`, the Windows path
  in `app.zig` (`GetModuleFileNameW`, `LOCALAPPDATA`), platform-guarded imports in the Python modules.
- 🔵 Refactor: one copy-rule engine shared by Linux and Windows; only path/ACL primitives differ.
- **Closure:** WS7.1 BLOCKING (setup process → home on disk → helper launch reads it; OBSERVE =
  WS11.1's `ready` frame); WS7.4 LEAF (copy rules).

**Gate (WS7):** [L] layout/copy tests; [W] setup e2e on both hosts. Not a UI slice.

---

## WS8: Sandbox backend (hard launch gates; fallback blocks launch)   [L] spec, [W]

**Goal.** Implement the chosen backend (OD-W4; recommended: dedicated sandbox users) against the
`SandboxBackend` protocol, and make its security proofs **hard launch gates**. If any mandatory
proof fails, **Windows agent launch stays disabled** until a backend (the WSL2 fallback, or another
the user picks) passes every gate.

### Design (recommended backend)
- `WindowsSandboxUserBackend` in `agent/host/zb_agent_host/sandbox.py` implementing every protocol
  method; `launch_spec` returns the launcher argv, the ACL grants derived from the same `Mount`
  list (agent home read-only, workspace read-only, scratchpad read-write, state dirs read-write),
  `network` (egress endpoint from WS9), `lifetime` (job object), `channel` (WS8.3).
- **One-time elevated setup** `zb-agent-sandbox-setup.exe` (new, Zig; the only admin step, one UAC
  prompt at first agent use): creates local users `zb-agent-<id>` and `zb-hook-<id>` (no interactive
  logon right), stores their random passwords DPAPI machine-protected, installs persistent WFP
  filters (WS9), grants ACLs on the agent home tree. It also has an `--uninstall` used by the
  installer (WS13.4).
- **Launcher** `zb-sandbox-launch.exe` (new): runs as the real user; starts the helper/CLI as
  `zb-agent` (`CreateProcessWithLogonW`, suspended), assigns it to a job with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and **no breakaway**, UI limits (no clipboard read, no global
  atoms, no handles to other users' windows), on a **separate desktop** (`CreateDesktop`) so agent
  processes cannot see, capture or send input to the user's windows (the Approve button), then
  resumes it. The browser holds the job handle; its death kills the tree.
- **Hooks** are spawned **app-side** (the macOS pattern): the hook command in the CLI's settings is
  the `zb-hook-run.exe` client, which asks the host broker (outside the sandbox) to spawn the hook
  as `zb-hook` in its own job; stdio crosses as duplicated handles. A hook and the CLI are different
  users, so default process DACLs stop `OpenProcess` across them.

### Hard-gate behaviors (all red first; failure ⇒ launch disabled + fallback required)
- **WS8.1 token isolation:** from a malicious hook, `OpenProcess(PROCESS_VM_READ |
  PROCESS_QUERY_INFORMATION)` on the CLI, reading its command line or environment
  (`NtQueryInformationProcess`), reading the CLI's config/credential directory, reading the real
  user's profile, and reading the browser's memory all fail; a **deterministic sacrificial target**
  holds a canary so removing the user separation exposes it (a denial that stays green without the
  separation does not count).
- **WS8.2 setup works on both editions present** (the Windows 10 machine's edition as recorded, and
  Windows 11 Pro) with exactly one UAC prompt, and is idempotent. Rev 2 adds: (a) the elevated process takes
  the **target user SID** from its caller and refuses to run if it differs from the SID of the interactive
  console session's user (a standard user's UAC elevates a *different* admin account; nothing may bind to
  that admin's profile); (b) the agent home **parent** receives one inheritable ACE for each sandbox user, so
  later `dist-<n>` directories (OD-W2 updates) need no second prompt; (c) a second run changes nothing (user
  count, filter count, ACL hashes); (d) the sandbox users are hidden from the sign-in screen and cannot log
  on interactively or over the network (rights set only after the launcher spike passes); (e) a failed
  setup leaves nothing behind (rollback census).
- **WS8.3 token channel:** spike whether `claude.exe` honors `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`
  with an inherited pipe handle (**unverified**). Pass ⇒ the Linux route semantics (the token only
  on that handle). Fail ⇒ stop and bring **OD-W4b** to the user.
- **WS8.4 no input, capture or clipboard reach:** from a hook and from the CLI's process,
  `SendInput`/`PostMessage` to the drawer's Approve button, a desktop capture (`BitBlt` of the
  user's desktop, `Windows.Graphics.Capture`), and clipboard reads all fail.
- **WS8.5 no survivors:** after `TerminateProcess` of the browser, every agent process is gone within
  1 s, including a hook that tries `CREATE_BREAKAWAY_FROM_JOB`, one that starts a process through WMI
  `Win32_Process.Create`, and one that registers a scheduled task. Any survivor ⇒ **OD-W4c**.
- **WS8.6 file scope:** workspace writes fail, scratchpad writes work, the agent home is read-only,
  and the user's real `%USERPROFILE%\.claude` is unreadable.
- **WS8.7 (new, rev 2) a no-network child for other components:** the backend can launch a command as a third
  confinement class, `zb-speech`, that has no loopback port and no file access beyond its own read-only
  model/engine directory and a pipe to the browser. The TTS plan (W0.2/W1.2: "`zb-speech` runs in the Windows
  launch plan's sandbox with no network") and the STT plan depend on this; the TTS plan's stub "refuses to
  start until the Windows sandbox backend exists" stays until WS8.7 is green. Realization options (do not
  pick in code until OD-W4 is decided): a third local user with an all-deny WFP filter keyed on its SID, or
  `zb-hook` launched with an empty port list. Test: `assert probe("127.0.0.1", 51091, as_user="zb-speech") == "WSAEACCES"`
  and every WS9.2 denial for that principal; the model directory is readable and nothing else is.
- **Reds for WS8.2-WS8.7 (all [W], unregistered until green; each with the mutant that must flip it):**
  - WS8.2 `assert uac_prompts == 1 and second_run_diff == {} and target_sid == console_user_sid` / mutant:
    default to the admin SID ⇒ red; mutant: a non-idempotent user create ⇒ second run diff non-empty ⇒ red.
  - WS8.3 `assert token_seen_on_handle == canary and canary not in cli_environment_block` (spike result
    recorded red→green; failing today because no launcher exists).
  - WS8.4 `assert hook_result["send_input"] in {"ERROR_ACCESS_DENIED","ERROR_INVALID_WINDOW_HANDLE"} and hook_result["bitblt_pixels_nonblack"] == 0 and hook_result["clipboard"] == ""`
    / mutant: put the hook on the interactive desktop ⇒ red.
  - WS8.5 `assert survivors_after_kill == [] within 1.0 s` for the three escape hooks / mutant: omit
    `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` ⇒ red.
  - WS8.6 `assert write_workspace == "ERROR_ACCESS_DENIED" and write_scratch == "OK" and read_real_claude_dir == "ERROR_ACCESS_DENIED"`
    / mutant: grant `zb-agent` Modify on the workspace ⇒ red.
  - WS8.7 as above / mutant: run `zb-speech` as `zb-hook` with the bridge ports ⇒ red.
- 🟢 Green (summary): the class, the three Zig executables (`zb_sandbox_setup`, `zb_sandbox_launch`,
  `zb_hook_run`), `agent_host_win.c`, `hook_broker.py`, the WFP filters from WS9, uninstall hooks from WS13.4.
- **Closure criteria:** WS8.1 (chain below) is the load-bearing closure. WS8.3 closes in WS11.1 (the token
  arrives on the helper's channel); WS8.4 and WS8.6 are LEAF (kernel denial observed from a hook's result
  file); WS8.5 is BLOCKING (browser death → job → no process left; OBSERVE = a process census by owner SID
  after `TerminateProcess`); WS8.7 is LEAF here and BLOCKING in the TTS plan's W1.2.
- **Files touched:** `agent/host/zb_agent_host/sandbox.py` (new class), `launch.py`,
  `agent/host/zb_agent_host/hook_broker.py` (new, shared with macOS), `src/zb_sandbox_setup.zig`
  (new), `src/zb_sandbox_launch.zig` (new), `src/zb_hook_run.zig` (new), `src/agent_host_win.c`
  (spawn/lifetime seam; the Windows half of `agent_host.c`), `build.zig`,
  `agent/host/tests/test_backend_contract.py` (Windows spec projection, [L]),
  `tests/e2e/win_sandbox_gate_test.py` (new).
- 🔴 Red [L] `test_backend_contract.py`: `assert isinstance(WindowsSandboxUserBackend(), SandboxBackend)`
  and that its `network()` equals the Linux backend's allowlist and bridge ports (same policy,
  different realization). 🔴 Red [W] `win_sandbox_gate_test.py`: `assert hook_result["open_process"] == "ERROR_ACCESS_DENIED" and canary not in hook_output`.
- 🔵 Refactor: no policy literal duplicated between backends (allowlist, ports, state dirs come from
  the shared constants at sandbox.py:41-56); the Python side owns policy, the Zig executables own
  spawn/lifetime.

### Workflow Closure (WS8.1 — token isolation)   [BLOCKING]
- **Chain:** `token stored (WS6) -> launcher passes it on the CLI's token channel -> CLI (zb-agent) holds it -> hook client -> host broker spawns hook as zb-hook -> hook attempts OpenProcess/command-line/credential reads -> kernel denies -> hook's recorded result has no canary`
- **SOURCE:** the stored canary token + a fixture SAI with the malicious hook + the sacrificial
  target. **TRIGGER:** the browser starting the agent (`highest_new_connector =
  WindowsSandboxUserBackend`). **DRIVER:** none async in the observed span. **OBSERVE:** the hook's
  result file scanned for the canary + the Win32 error codes. **FORBIDDEN SPAN:** launcher internals,
  ACL/WFP application, the CLI process. **RED-AT-SEAM:** run the hook as `zb-agent` (same user) ⇒ the
  hook reads the canary ⇒ red. **EXECUTION:** real binary on both hosts; missing sandbox setup ⇒
  exit nonzero. (ClosureMap emitted at build time, pinned to the then-current HEAD; its symbols are
  created here.)

### Fallback (only if a hard gate fails, or the user picks it in OD-W4)
`WslBackend`: the unchanged `LinuxBwrapBackend` inside a WSL2 distro started by `wsl.exe` with the
helper's stdio as the broker stream, `interop` disabled, `networkingMode=none` where supported
(Windows 11) or the distro's own netns (Windows 10, NAT); gates WS8.1-WS8.6 re-run against it.

**Gate (WS8):** [L] contract; [W] WS8.1-**WS8.7** on both hosts — WS8.7 (the no-network child the TTS and
STT plans depend on) is part of WS8's own gate, not deferred to the voice plans. **WS11 is blocked** until all pass.
Not a UI slice, except the one UAC prompt, which the user clicks in person (`win-sandbox-uac`); on the
physical Windows 10 machine the prompt asks for an administrator credential (the account is a standard
user) and only the owner types it. **On the file server, the isolation checks in "File-server isolation
requirements" item 5 run before and after, and are part of this gate.**

---

## WS9: netd egress on Windows   [W]

**Goal.** Realize the shared egress capability on Windows: the backend supplies the endpoint and the
policy, netd keeps the exact CONNECT/SNI allowlist (`api.anthropic.com`; plus `platform.claude.com`
for sign-in), hooks reach only the two bridges.

### Egress mapping (Windows realization)
1. **netd runs on the host** as the real user and listens on `127.0.0.1:<port>` chosen from a small
   fixed range reserved at setup (WFP filters are installed once, with admin, so the permitted ports
   cannot change per session). netd confirms it owns the port before printing `netd ready`.
2. **WFP filters** (persistent, installed by WS8 setup): `zb-agent` may connect **only** to
   `127.0.0.1:<range>`; `zb-hook` **only** to `127.0.0.1:51091` and `127.0.0.1:31337`; both users are
   blocked from everything else, including DNS (UDP/TCP 53), `::1`, LAN, and SMB to any address.
3. `HTTPS_PROXY`/`HTTP_PROXY` name netd's port (`options.py:104`); `relay.py` is not used (no netns).
4. **netd TCP-listener mode** is the shared change with macOS MS6 (whichever lands first); the
   Unix-socket listener stays for Linux.
5. **Port squatting:** if another host process holds a port in the range, netd picks another or
   fails closed; a CLI that connects to a squatter only sends a CONNECT line and TLS ciphertext to
   `api.anthropic.com` (certificate verification fails), so the test asserts the CLI **fails
   closed** and no token byte appears in the squatter's capture.

### Behaviors (hard gates, both hosts)
- **WS9.1** the CLI reaches the fake Anthropic API **only** through netd (removing netd or widening
  the WFP filter turns the test red).
- **WS9.2** denials from `zb-agent` and `zb-hook`: `1.1.1.1:443`, TEST-NET `192.0.2.1:443`, a
  loopback decoy port, DNS to the configured resolver, `\\127.0.0.1\c$`, a non-allowlisted CONNECT
  host (403 from netd). On the Windows 10 file server the probes **never** target its LAN or its
  shares other than the loopback admin-share probe.
- **WS9.3** a hook cannot reach netd's port; both bridges carry bytes.
- **WS9.4** the sign-in netd (`net-login.json`) allows exactly `api.anthropic.com` and
  `platform.claude.com`, with no bridges.
- **Files touched:** `agent/host/zb_agent_host/netd.py` (TCP listener mode, Windows confinement
  notes), `sandbox.py` (`egress_endpoint` for Windows), `src/agent_host_win.c` (start/ready wait),
  `src/zb_sandbox_setup.zig` (WFP filters), `agent/host/tests/test_netd.py` (TCP mode, [L]),
  `tests/e2e/win_egress_test.py` (new).
- 🔴 Red [L] `test_netd.py::test_tcp_listener_refuses_non_allowlisted`:
  `assert reply.startswith(b"HTTP/1.1 403")` (today netd has no TCP listener). 🔴 Red [W]
  `win_egress_test.py`: `assert probe("1.1.1.1", 443, as_user="zb-agent") == "WSAEACCES"`.
- 🟢 Green: netd TCP-listener mode with a **backend-supplied port policy** (a fixed `lo..hi` range on
  Windows, `0`/ephemeral for macOS), the WFP filters in `zb_sandbox_setup.zig`, `egress_endpoint` for the
  Windows backend. 🔵 Refactor: the allowlist, the ports and the policy literals stay single-sourced in
  `sandbox.py:41-56` (no duplicate list in the Zig setup tool: it receives the ports as arguments); the
  netd request-parsing code is not forked for TCP mode. Each red above has a mutant: (WS9.1) delete the WFP
  filter ⇒ the bypass probe succeeds ⇒ red; (WS9.2) widen the filter to `0.0.0.0/0` ⇒ red; (WS9.3) give
  `zb-hook` the netd port ⇒ red; (WS9.4) add a third host to the login allowlist ⇒ red; (port squatting)
  let netd fall back to any port ⇒ the CLI connects to the squatter ⇒ red.
- **Closure (WS9.1):** BLOCKING — SOURCE = the fake API fixture behind the `--e2e-protocol`
  allowlist seam; TRIGGER = the helper's first SDK request; DRIVER = the real netd accept loop;
  OBSERVE = the fake API's request log + netd's census line; RED-AT-SEAM = bypass netd (direct
  `HTTPS_PROXY` to the fake) ⇒ WFP denies ⇒ the request never lands; a test that passes with netd
  removed is a failure.

**Gate (WS9):** [L] netd units; [W] WS9.1-WS9.4 both hosts. Not a UI slice, so no real-screen case.
Both hosts: the WFP filter census and the listener census of "File-server isolation requirements" item 5
run after this gate as well.

---

## WS10: Sign-in on Windows   [W], [U]

- **WS10.1** `claude setup-token` runs under the login launch spec and netd (WS9.4). Linux uses a pty
  (`login.py:31-38, 128-139`); Windows has no `pty`, so the spike decides between ConPTY (via a small
  native helper) and plain pipes (if `setup-token` prints the authorize URL without a terminal,
  **unverified**). The authorize URL is opened in the user's default browser with `ShellExecuteW`
  only when the user clicks Sign in, and Copy link always works.
- **WS10.2** the pasted `code#state` reaches the CLI; the token is written to the WS6 store only
  through the login helper's one-shot channel (fd 4 on Linux; an inherited pipe handle on Windows).
- **WS10.3** cancel and timeout end with the same codes as Linux (`cli`, `timeout`, `cancelled`,
  `shape`, `protocol`; agent_protocol.zig:292-307).
- **Files touched:** `agent/host/zb_agent_host/login.py` (Windows branch), `src/agent_login_win.c`
  (new), `tests/e2e/win_login_test.py` (new; fake CLI in e2e).
- 🔴 Red `win_login_test.py`: `assert frames[-1]["type"] == "done" and cred_read(test_target) == canary`
  (today there is no Windows login helper; `login.py` cannot even be imported on Windows: `fcntl` :28,
  `pty` :31, `termios` :38). More reds, each with a mutant: WS10.1 `assert auth_url_frame.url.startswith("https://") and shell_execute_calls == 0`
  until the user clicks Sign in (mutant: open the browser at start ⇒ red); WS10.2 `assert canary not in
  (stdout + stderr + helper_env)` and the token only on the one-shot handle (mutant: pass it in argv ⇒
  red); WS10.3 `assert error_codes == {"cli","timeout","cancelled","shape","protocol"}` for the five forced
  failures, same codes as Linux (`agent_protocol.zig:306`), (mutant: collapse `cancelled` into `cli` ⇒ red).
- 🟢 Green: `login.py` Windows branch (ConPTY helper or pipes per the spike), `agent_login_win.c`, the
  Secrets-window Sign-in controls (shared with WS6). 🔵 Refactor: one `LoginSession` state machine used by
  the Linux and Windows branches; only the process/terminal primitive differs.
- **Closure:** BLOCKING (Secrets window → login helper → CLI → store; OBSERVE = the store through
  `CredReadW` + the `SECRETS` census row).
- **Real-screen check `win-signin`:** Sign in opens the default browser, pasting the code saves the
  token, on both screens.

**Gate (WS10):** [W] both hosts + `win-signin`.

---

## WS11: Agent helper, chat and the approved commit on Windows   [W], [U] — blocked on WS8 + WS9

- **WS11.1** the helper starts under the backend, receives the token on its channel, and emits a
  `ready` frame validated by `agent_protocol.zig`.
- **WS11.2** a chat round-trip streams `assistant_delta`/`assistant_message` into the Win32 drawer.
- **WS11.3** the positive approved commit: a `tool_use` from the fake Anthropic API arrives **through
  netd and the helper** (never the automation socket) → dry-run preview → the WS5 native card → a
  native Approve click → grant minted → revalidated → the real flow commits **exactly once** with
  `options.expect` in-ticket. Deny, an expired grant, a navigation retarget or a wrong account
  commits 0.
- **Files touched:** `src/agent_helper_win.c` (new; the Windows half of `agent_helper.c`: pipes,
  restart backoff 1/2/4/8 s, stop ladder via the job), `src/app.zig` (wire on Windows),
  `src/agent_drawer_win.cpp` (Send, bubbles, card), `tests/e2e/win_chat_test.py`,
  `tests/e2e/win_approved_commit_test.py` (new).
- 🔴 Red `win_chat_test.py`: `assert "DRAWER\tbubble\tassistant\t" + expected in rows`. More reds: WS11.1
  `win_helper_ready_test.py`: `assert ready_frame["type"] == "ready" and token_on_channel == canary and canary not in helper_env`
  (mutant: pass the token in env ⇒ red); WS11.3 `win_approved_commit_test.py`:
  `assert fixture_commit_log == [one_commit]` after Approve and `assert fixture_commit_log == []` after Deny,
  expiry, retarget and wrong account (mutants: Approve handler minting before the click; grant not
  single-use; skipping `options.expect` ⇒ each flips one case); restart: `assert helper_restarts == [1,2,4,8]`
  seconds under repeated kills (mutant: constant 1 s ⇒ red).
- 🟢 Green: `agent_helper_win.c`, the drawer's Send/bubble/card code, `app.zig` wiring, the stop ladder via
  the job. 🔵 Refactor: one frame pump shared by the drawer and the e2e census writer; no second
  protocol-validation path outside `agent_protocol.zig`.
- **Closure criteria:** WS11.1 BLOCKING (setup → helper → `ready`; OBSERVE = the validated `ready` frame
  and the census row); the two chains below for WS11.2/WS11.3.

### Workflow Closure (WS11.2 chat)   [BLOCKING]
- **Chain:** `drawer Send (Win32) -> prompt frame on helper stdin -> chat.py Session -> ClaudeSDKClient -> claude.exe under the backend -> netd -> fake API -> assistant frames on stdout -> agent_protocol.zig validate -> drawer bubble`
- **SOURCE:** the prompt + the fake API through netd. **TRIGGER:** the drawer Send handler
  (`highest_new_connector` = the Windows drawer→helper wiring). **DRIVERS:** the helper stdin/stdout
  pump (`chat.py _pump`) + the 50 ms coalescer + the Win32 message loop. **OBSERVE:** the bubble via
  the `--e2e-protocol` census. **RED-AT-SEAM:** disconnect the drawer→helper wiring ⇒ no bubble.

### Workflow Closure (WS11.3 approved commit)   [BLOCKING]
- **Chain:** `fake tool_use (through netd) -> helper pump -> broker preview -> WS5 card -> native Approve click -> grant minted -> revalidate -> flow commit (options.expect) -> fixture records exactly 1 commit`
- **OBSERVE:** the social fixture's commit log == 1. **RED-AT-SEAM:** Deny / expired / retargeted /
  wrong account ⇒ 0; routing `tool_use` over the socket must be impossible.

- **Real-screen checks:** `win-chat-reply` (a streamed reply appears in the drawer, text copyable)
  and `win-approval-card` (the user clicks Approve and sees one commit; Deny commits nothing), both
  screens.

**Gate (WS11):** [W] WS11.1-WS11.3 both hosts + both real-screen cases.

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

- **WS12.1** the drawer exposes the two hook points the voice plans call (`zb_drawer_set_draft`,
  `zb_drawer_speaker_toggled`), stubbed until the voice plans land; 🔴 Red
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

**Gate (WS12):** [W] the hook-point test; the voice tests run under the voice plans' own gates.

---

## WS13: Packaging, signing, update, uninstall   [W11] build, [L]/[W11] sign, [W], [U]

### Behaviors
- **WS13.1 the MSI ships every component** the release needs (browser, manifest, launcher, sandbox
  setup, hook client, Python runtime, `claude.exe`, agent host, models), per user under
  `%LOCALAPPDATA%\Programs\zigBrowser` (OD-W1); a census lists every PE and fails on an unlisted one.
- **WS13.2 WebView2 runtime handling (OD-W8):** the bootstrapper custom action's failure is surfaced
  (not `Return="ignore"` silently): the installer records the result, and the app's WS1.4 check shows
  the exact message with the standalone-installer link.
- **WS13.3 size:** the build computes the **sum** of every bundled payload (browser, Python runtime,
  `claude.exe`, agent host, WebView2 standalone installer if OD-W8 picks it, the STT model, the TTS model and
  ONNX Runtime) and fails if any cabinet exceeds 2 GB. Known inputs: STT q8_0 823,369,779 bytes (f16 would be
  1,533,763,059, q5_0 539,212,467; STT plan O1 is still open), TTS about 0.1-0.13 GB (unverified), so the
  choice of the STT file moves the total from about 1.0 to 1.7 GB before the Python runtime and `claude.exe`
  are added. The MSI uses split cabinets (`MediaTemplate MaximumUncompressedMediaSize`) and the test asserts the
  number of cabinets and each one's size.
- **WS13.4 uninstall** removes the files, shortcuts, HKCU keys, and (via the elevated
  `zb-agent-sandbox-setup.exe --uninstall`, one UAC prompt) the two sandbox users, their profiles and
  the WFP filters; a post-uninstall probe finds none. **Rev 2 constraint:** the current `.wxs` is
  `InstallScope="perUser"` with `InstallPrivileges="limited"`, so an MSI deferred custom action **cannot**
  elevate. Two designs only: an immediate custom action that `ShellExecute`s `runas` (a UAC prompt in the
  middle of Add/Remove Programs, may be declined), or an in-app "Remove agent sandbox" step before
  uninstall. Either way the MSI uninstall can finish while the users and filters remain, so the probe is
  also run in that state and the product shows a "finish removing the sandbox" action on the next launch of
  any surviving component. **The uninstall must never report success while any sandbox user, WFP
  filter/provider/sublayer, profile folder or scheduled task survives:** WS13.4 fails if the uninstaller
  returns success (exit 0 / "Removed") while the post-uninstall probe still finds a survivor, and a clean
  result is asserted only once that probe is empty. OD-W1 may change this.
- **WS13.5 update (OD-W2):** the chosen updater verifies the update's signature before running it; a
  tampered update is refused.
- **WS13.6 signing (gated on OD-W3):** every PE then the MSI is Authenticode-signed inside-out with
  an RFC 3161 timestamp (jsign from Linux for Artifact Signing, or signtool on the VM);
  `Get-AuthenticodeSignature` is `Valid` for every file on both hosts; a downloaded copy (with a
  `Zone.Identifier` stream, ZoneId=3) shows the publisher name in SmartScreen, and Smart App Control
  on the VM does not block it. **Until a certificate exists, the artifact is an unsigned development
  build, not a distributable artifact**; status is tracked via Agent Mail / plan status (the beads DB
  is migration-locked).
- 🔴 More reds (each with a mutant): WS13.1 `assert census.unlisted == [] and census.missing == []`
  (mutant: add an unlisted DLL ⇒ red); WS13.2 `assert install_log.bootstrapper_result is not None and (rc == 0 or app_shows_runtime_message)`
  (mutant: keep `Return="ignore"` and drop the log ⇒ red); WS13.3 `assert all(c.size < 2**31 for c in cabinets)`
  (mutant: one 2.1 GB payload ⇒ red); WS13.4 `assert users_after == [] and wfp_filters_after == [] and tasks_after == [] and not (uninstall_reported_success and (users_after or wfp_filters_after or tasks_after))`
  (mutants: skip the filter removal ⇒ red; report uninstall success while a user/filter/task survives ⇒ red); WS13.5 `assert tampered_update_refused` (mutant: skip the signature
  check ⇒ red); WS13.6 `assert all(sig.Status == "Valid" for sig in signatures)` on both hosts, red until
  OD-W3, and a **negative** test that a modified file after signing is `HashMismatch`.
- 🟢 Green: the `.wxs` components for every release PE, `build-msi.ps1` cabinet split and census,
  `components.json`, `sign.sh`/`sign.ps1` (blocked on OD-W3), the uninstall wiring above.
  🔵 Refactor: one component manifest feeds the MSI, the census and the macOS-style "every shipped binary is
  listed" check; the installer stays free of policy literals (ports, allowlists).
- **Files touched:** `packaging/windows/zigBrowser.wxs`, `packaging/windows/build-msi.ps1`,
  `packaging/windows/gate.ps1`, `packaging/windows/components.json` (new census),
  `packaging/windows/sign.sh` (new, jsign) or `sign.ps1`, `tests/e2e/msi_install_test.py`,
  `tests/windows/gate.sh` (package phase).
- 🔴 Red `msi_install_test.py`: `assert census.unlisted == [] and census.missing == []` (today the
  MSI ships only `zigBrowser.exe` + the bootstrapper); and `assert sig.Status == "Valid"` (fails until
  OD-W3).
- **Closure:** LEAF (packaging assertions), except WS13.4 BLOCKING (installer → elevated helper →
  system state; OBSERVE = the post-uninstall probe of users and WFP filters).
- **Real-screen check `win-install-smartscreen`:** the user downloads the installer in Edge on each
  host and records what SmartScreen shows.

**Gate (WS13):** [W] install/uninstall/census both hosts; signing part blocked on OD-W3. The **final
packaging gate depends on every release component, not merely on WS7 having started**: WS13.1's census must
find each component owner's artifact — browser (WS1), drawer (WS5), setup (WS7), sandbox setup (WS8), egress
helper (WS9), sign-in (WS10), agent host/helper (WS11) — **and the voice packaging the voice plans own** (the
TTS engine + model and the STT engine + model via their VSP/W1 slices); a missing component fails the census,
so WS13's gate cannot pass until every component owner and the voice-packaging owners have landed. The
`win-install-smartscreen` case is a UI/real-screen case for both hosts; on the physical machine the install
is by `zbtest` into `C:\Users\zbtest\AppData\Local\Programs\zigBrowser`, and the post-uninstall probe
(users, filters, tasks, folders) also runs there.

---

## Dependency order

`WS0 → WS1 → WS2.0 → WS2a → WS2b → WS2c → WS3 → WS4`, and in parallel after WS1:
`WS5 (drawer) → WS6 (Secrets) → WS7 (setup) → WS8 (sandbox, hard gates) → WS9 (egress) → WS10
(sign-in) → WS11 (helper, chat, approved commit; needs WS4 + WS5 + WS8 + WS9)`. (WS8 and WS9 are mutually
dependent at the test level: the WFP filters of WS9.2 are installed by WS8's setup, so WS8.1-WS8.6 land
first with filters stubbed to "deny all", and WS9 replaces the stub with the real range.) `WS12` follows WS5
(hook points) and WS11 (W2/VS11); **TTS W1 additionally waits on WS8.7**. `WS13` packaging can START after WS7,
but its **final gate depends on every release component** (WS1, WS5, WS7, WS8, WS9, WS10, WS11) and the
**voice packaging** the voice plans own (TTS engine+model, STT engine+model via VSP/W1): WS13.1's census fails
on any missing component, so the final packaging gate cannot pass until every component owner has landed. Its
signing half waits on OD-W3. Decision gates: WS5 waits on OD-W6 only for its green files; WS8 waits
on OD-W4; WS13 on OD-W1/W2/W3/W8.

## Per-slice gate protocol (all slices)

1. Mail "taking the gate slot" for gate runs only (trust only "slot FREE" mails). 2. Write the
slice's red tests in **unregistered** files (not wired into any `build.zig` step or the gate
phase list); record the red runs on the Windows hosts. 3. Green, and register the tests in the same
green commit. 4. Refactor (the checklist in each slice). 5. Quiet gate from a clean `git archive
HEAD` plus the slice's files: the Linux gate under a private Xvfb as it does today, then
`tests/windows/gate.sh` on both hosts. 6. Commit only the slice's own hunks (the worktree is shared;
never stage another agent's work). 7. Mail RoseCat for review. 8. UI slices: the orchestrator runs
the named real-screen cases with the user on both screens; not approved until they pass.
**Never** rewrite history: no reset, rebase or amend of committed work, even unpushed; fix forward
with a new green commit. A slice is done only when its closure e2e was observed to execute with
nonzero assertions on both hosts.

## Real-screen checks (all, by slice)

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
3. AF_UNIX on both hosts with the Zig 0.16 std (WS2.0; the ADR-1 spike has no recorded run).
4. `WEBVIEW2_BROWSER_EXECUTABLE_FOLDER` as a runtime-missing seam (WS1.4).
5. A public mechanism that recovers a hung WebView2 renderer (WS2c.3).
6. `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` with an inherited handle on Windows (WS8.3).
7. Cross-user `OpenProcess` denial, desktop separation, and job-escape paths for the dedicated-user
   backend (WS8.1, WS8.4, WS8.5).
8. Whether `claude setup-token` works without a terminal on Windows (WS10.1).
9. WebView2 rendering on the VM's QXL / basic display adapter (WS1).
10. Nested virtualization for the WSL2 fallback inside the KVM guest (WS8 fallback only).
11. The Windows 10 machine's edition, build and preinstalled WebView2 runtime (provisioning item 4).
12. Whether the Win11 VM the user provides is the existing `win11-m8` domain (rev 2: that domain is
    currently running with no snapshots; the user's VM may still be a different one).
13. Whether a standard-user launcher can create a suspended process as another user with
    `CreateProcessWithLogonW` (needs the Secondary Logon service, `seclogon`) and assign it to a job (WS8).
14. Whether libvirt 11.3 can snapshot this UEFI + raw NVRAM + swtpm guest, and by which method (VM snapshots).
15. Whether the `ich9` SPICE-audio device gives Windows a capture endpoint and `virt-viewer` forwards a microphone.
16. Whether `std.c.chmod` and `.permissions = .fromMode(0o600)` in `automation_server.zig:1496-1517` compile for
    Windows (WS2.0 compile check).
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
3. `tests/guest/setup.ps1` must not run on the file server (unscoped port 22 rule, toolchain installs).
4. Provisioning item 4 looked only at `HKLM\…\WOW6432Node`; the runtime version can be in `HKLM` (two views) or `HKCU`.
5. The debug-seam count is 30 declared (27 listed in the ABI table + 3 config seams under WS3).
6. WS12: TTS W1 is the bundled engine + WASAPI (not WinRT/SAPI, which is S3); TTS has no "N1"; W1 depends on the sandbox milestone (new WS8.7); STT's `win-voice-live` host claim conflicts with the VM's unproven capture device.
7. WS0.2's `NOT RUN` text now contains the sentence both voice plans already quote.
8. The macOS plan header says rev 6 but its history runs to rev 9; its flag seam is `applyMacBackendFlag` (macOS-only name); its egress port is OS-selected while Windows needs a fixed range; the hook-broker module is not in that plan. The shared table now states each.
9. WS13.4: a per-user MSI cannot run an elevated custom action.
10. `agent_drawer.zig` export gate is `comptime { if (builtin.os.tag == .linux)` at :338-339, closing :358.

**Added:** WS0.6 (VM identity and down-VM), WS0.7 (file-server fence), WS0.8 (transport hygiene), WS7.5 (Windows
import-ability), WS8.7 (no-network child), the WS2 register, per-milestone reds/mutants/greens/refactors/closures/real-screen
cases for WS1-WS13, `win-popups`, `win-crash-page`, the role map, the file-server isolation requirements, and the decision
sharpening for OD-W1..OD-W9. No open decision was decided.

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

No bead was filed for this plan: the shared bd DB is migration-locked on the remote-backed clone,
and `bd migrate`/`bootstrap` are not run unilaterally. Status is tracked via Agent Mail and this plan.
