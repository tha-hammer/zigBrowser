---
date: 2026-10-19T15:57:00-04:00
researcher: Claude (Opus 5.5) subagent for the orchestrator
git_commit: 032a2c95e200db2e59d56147cb9c74afed50b727
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "Windows (10 and 11) support surface for a zigBrowser launch: the codebase as it is today, plus the external facts a Windows plan needs"
tags: [research, codebase, windows, webview2, win32, msvc, mingw, automation, drawer, sandbox, appcontainer, wfp, credential-manager, msi, authenticode, e2e, launch-critical]
status: complete
last_updated: 2026-10-19
last_updated_by: Claude (Opus 5.5) subagent
---

# Research: Windows support surface for a zigBrowser launch

**Date**: 2026-10-19T15:57:00-04:00
**Git Commit**: 032a2c95e200db2e59d56147cb9c74afed50b727 (the worktree is shared by four agents; HEAD moved from 302344e to 032a2c9 while this was written, and none of the moves touched a file cited here)
**Branch**: zb-automation-integration-2026-10-10-11-59
**Repository**: zigBrowser

## Research Question

The user said: "Mac and Windows are the 2 main target systems, Linux is my environment, not
the primary target for users," and "Plan windows now. I'll have a Win11 VM and windows 10
physical machine available." This document maps what exists for Windows today and gathers
the external facts a Windows launch plan needs, in eight areas:

1. What exists for Windows today: the WebView2 shim against the shared C ABI, the build
   (MinGW vs MSVC, Linux cross-compile vs in-guest build), the WebView2 SDK and loader, and
   the existing Windows guest tooling.
2. The drawer UI options on Windows (Win32, a WebView2-hosted HTML drawer, other toolkits).
3. The agent host on Windows: Python runtime, the Claude CLI, sandbox options, and how they
   fit the existing `SandboxBackend` seam.
4. The network proxy (netd) on Windows and allowlist enforcement.
5. Secrets: Credential Manager / DPAPI as the libsecret equivalent.
6. Packaging and signing: MSI / MSIX / EXE, Authenticode, SmartScreen, the WebView2 runtime,
   installer size with the bundled whisper model, and auto-update.
7. Testing: a fail-closed two-host gate (Win11 VM + physical Win10) driven from Linux.
8. arm64 Windows.

The codebase sections describe what exists. The web sections report external facts with
links. Anything not confirmed from a primary source is marked **unverified**. This document
does not recommend; the plan (`thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md`)
does.

## Summary

- **The Windows backend today is a render-and-IPC shell.** `src/webview2_shim.cpp` (771
  lines) defines 3 of the 73 shim functions in `src/webkit_shim.h`: `zb_app_run`
  (webview2_shim.cpp:707), a stub `zb_run_screenshot` that returns
  `ZB_EXIT_SNAPSHOT_FAILED` (:751-757), and `zb_version_line` (:759). macOS defines 6 and
  GTK all 73 (counts re-verified at HEAD 032a2c9 on 2026-10-19: 75 declarations in `webkit_shim.h` = 73 shim functions + `zb_policy_decide` :427 + `zb_ipc_dispatch` :428; `webview2_shim.cpp` has exactly three `extern "C"` definitions, at :707, :751 and :759; `wkwebview_shim.m` has six: `zb_app_run`, `zb_run_open` :834, `zb_run_screenshot`, `zb_version_line`, `zb_reload` :872, `zb_window_new` :880). None of the ~70 automation and native-input functions exist on Windows. The
  shim creates one 1024x768 window, the default WebView2 environment (no user data folder,
  :692), a document-created marker script, and the `chrome.webview` IPC reply channel into
  the shared Zig `zb_ipc_dispatch` (:412-463). It does not call `zb_policy_decide`, and it has
  no `NewWindowRequested` or `NavigationStarting` handling.
- **The real Windows build is native MSVC in a Win11 KVM guest.** `tests/guest/build-in-guest.sh`
  tars the tree to the guest over Tailscale SSH and runs `zig build -Dtarget=x86_64-windows-msvc`
  with WebView2 SDK 1.0.3967.48 and Windows SDK 10.0.26100 paths. `build.zig` links the
  MSVC-only `WebView2LoaderStatic.lib` (build.zig:1551) and needs `wrl.h` (build.zig:67).
  From Linux, `zig build cross-check` only compiles `src/main.zig` for `x86_64-windows-gnu` as
  an object (no shim, no link) and checks symbols (build.zig:243-280). MinGW-w64's `wrl.h`
  lacks `event.h`, so `Microsoft::WRL::Callback`, which the shim uses (webview2_shim.cpp:18),
  is not available on a MinGW build (web, likely; see §2).
- **The guest exists.** `qemu:///session` has a domain `win11-m8` (shut off when first written; **`running` when re-checked read-only on 2026-10-19**, with no snapshots and a working `127.0.0.1:2222 -> 22` passt forward, see §1.4) (UEFI Secure Boot,
  swtpm TPM 2.0, 4 vCPU, 12 GiB, host-passthrough CPU on an AMD Ryzen 7 5800X with
  `kvm_amd nested=1`), disk `/home/maceo/ntm_Dev/vms/win11-m8/win11-m8.qcow2` (51 GB, last
  modified 2026-07-06), SSH key `/home/maceo/vms/win11-m8/zb_guest_key`, guest address
  `maceo@100.103.8.90` (Tailscale). `tests/guest/setup.ps1` provisions OpenSSH Server, Zig
  0.16.0, nuget, the WebView2 SDK, and MSVC Build Tools + Windows SDK. There is no Windows 10
  host tooling and no two-host gate.
- **GUI tests already run in the interactive session through a scheduled task.**
  `tests/e2e/slice2_common.py:447-548` (`run_windows_interactive_until`) and
  `packaging/windows/gate.ps1:88-150` create a `schtasks /create ... /it /rl highest` task and
  `/run` it, because an SSH-started process is not on the user's desktop. They capture with
  `CopyFromScreen` over `GetWindowRect`. Neither checks that an interactive session exists,
  the OS build, or an assertion count before passing.
- **Packaging is an unsigned per-user WiX v3 MSI** (`packaging/windows/zigBrowser.wxs`,
  `InstallScope="perUser"`), which bundles and silently runs the Evergreen bootstrapper
  `MicrosoftEdgeWebview2Setup.exe` (1.6 MB in the repo). No signing, no update channel.
- **The agent stack is Linux-only by construction.** `--agent-setup` prints "the Claude
  Agent is Linux-only" off Linux (app.zig:52-55); the drawer, secrets, helper and login C
  files compile only in `configureGtkBackend` (build.zig:1503-1533); the Python host has no
  Windows branch at all. The `SandboxBackend` / `LaunchSpec` seam (MS0) **exists in code**
  (sandbox.py:71-108, 201-229) with one implementation, `LinuxBwrapBackend` (:232-374). netd
  (the allowlist CONNECT proxy) **is built** (`netd.py`), Unix-socket based, sandboxed by
  bwrap. The token route (pipe on fd 3, then FIFO, then socketpair on fd 3) is POSIX.
- **Portable pieces that Windows can reuse as-is:** the automation server/router/engine/queue/
  recover/flows (Zig), `agent_protocol.zig` (frame validation), `agent_helper.zig` (frame
  builders), `agent_drawer.zig` (geometry, 6 px click-vs-drag, 180 ms cubic ease-out,
  `agent-drawer.json`), `agent_secrets.zig` token-shape check, the approval grant contract
  (drawer plan D10), and the `SandboxBackend` protocol and egress-capability contract.
- **External facts that shape the plan** (details and links in §3-§8):
  Windows 10 consumer ESU now runs to 2027-10-12; WebView2 keeps updating on Windows 10 22H2
  until at least October 2028; the Claude CLI supports Windows 10 1809+ x64/ARM64 natively
  and the Agent SDK Windows wheel bundles `claude.exe`; Claude Code's own `/sandbox` does not
  sandbox native Windows; Anthropic's sandbox-runtime (srt) has an **alpha** Windows mode
  (dedicated local user + restricted token + job object + WFP filters, one UAC prompt); Codex
  uses dedicated sandbox users + ACLs + firewall/WFP; Windows Sandbox is not available on
  Home; WSL2 is available on Home but needs virtualization (nested in a VM) and is NAT-only
  on Windows 10; EV certificates no longer bypass SmartScreen; Azure Artifact Signing
  (formerly Trusted Signing) is about $9.99/month and open to individuals only in the US and
  Canada; Credential Manager blobs cap at 2560 bytes; WiX v6+ binaries carry the Open Source
  Maintenance Fee EULA; an MSI cabinet is limited to 2 GB.

## Detailed Findings

### 1. What exists for Windows today (codebase)

#### 1.1 The WebView2 shim against the shared C ABI

`src/webkit_shim.h` (435 lines) declares 75 functions: 73 implemented by a shim and 2 Zig
exports (`zb_policy_decide`, `zb_ipc_dispatch`).

| Backend | Shim functions defined | Which |
|---|---|---|
| WebView2 (`src/webview2_shim.cpp`, 771 lines) | 3 of 73 | `zb_app_run` (:707), `zb_run_screenshot` (:751, stub returns `ZB_EXIT_SNAPSHOT_FAILED`), `zb_version_line` (:759) |
| WKWebView (`src/wkwebview_shim.m`, 888 lines) | 6 of 73 | the 3 above plus `zb_run_open`, `zb_reload`, `zb_window_new` |
| GTK (`src/webkit_shim.c` + `src/agent_drawer.c`) | 73 of 73 | all, including the `zb_automation_debug_*` hooks (**correction, review 2026-10-19: the header declares 30 of them, not 27**: 27 test seams from `zb_automation_debug_live_jobs` (header :364) to `_native_skipped` (:424), plus `_hw_policy` (:97), `_webkit_default_hw_policy` (:100) and `_media_source` (:131), which belong with the WS3 config flags) |

Missing on Windows (all defined in GTK only): `zb_run_open`, `zb_reload`, `zb_window_new`,
`zb_main_invoke_sync`, `zb_automation_loop_mark`, `zb_app_set_profile_dir`, the
hw-policy/media-source/agent-drawer setters and getters, `zb_automation_set_script`,
`_window_id_at`, `_run_generation`, `_window_alive`, `_list_windows`, `_close_window`,
`_recover_windows`, `_eval_json`, `_navigate`, `_navigate_guarded`, `_reload`,
`_list_dialogs`, `_respond_dialog`, `_get_url`, `_get_title`, `_free`, `zb_cookies_get_all`/
`_add`/`_delete`, `zb_set_input_files`, `zb_screenshot_png`, the six `zb_native_*`
(scroll/move/pointer/click/key/text), `zb_drawer_debug_live_count`, and every
`zb_automation_debug_*` seam.

What `zb_app_run` does on Windows (webview2_shim.cpp:707-749):
- Checks the runtime with `GetAvailableCoreWebView2BrowserVersionString` (:314-333); missing
  runtime returns `ZB_EXIT_RUNTIME_MISSING` (9).
- `CoInitializeEx(COINIT_APARTMENTTHREADED)`, a `WS_OVERLAPPEDWINDOW` 1024x768 host window
  (:507-539), `CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, ...)`
  (:692) — the default user data folder, no browser arguments.
- Controller, `IsScriptEnabled`/`AreDefaultScriptDialogsEnabled` true (:606-610), injects
  `window.__zigBrowserBackend = 'webview2';` with `AddScriptToExecuteOnDocumentCreated`
  (:561-577), then navigates with a 15 s `WM_TIMER` (:26, :483-495, `ZB_EXIT_TIMEOUT` 8).
- `NavigationCompleted` failure emits `LOAD_FAIL <uri> 2 <status>` and exits 5 (:613-638).
- `WebMessageReceived` parses `id`/`cmd`/`args` with a hand-rolled scanner, calls
  `zb_ipc_dispatch` (:444), replies with `PostWebMessageAsString` (:412-463).
- One window only; no multi-window registry, no popups, no `ProcessFailed`, no CDP use.

Zig side for Windows:
- `resolveBackend` maps `.windows` to `.webview2_backend` (build.zig:1481-1488).
- `automation_gtk_port.zig:22` and `automation_gtk_cookie_port.zig:21` gate on
  `os.tag == .linux`; on Windows `pagePort()` returns null and the server answers page
  methods with the documented `-32011` path (`docs/how-to-build.md:75-77`).
- `automation_platform.zig:77-98`: `adapterCapabilities(.webview2)` is `input = .cdp_input`,
  `network = .supported`. The WebView2 CDP dispatcher and network interceptor exist only as
  in-memory fakes (`FakeWebView2Cdp`, `WebView2InputDispatcher`, `FakeWebView2NetworkAdapter`,
  `WebView2NetworkInterceptor`, automation_platform.zig:167-205, 284-430); nothing real is
  wired to the shim.
- `ipc.zig:124-148` (`osInfoJson`) has a `.windows` branch using `RtlGetVersion`.
- `root.zig:50-52` `isVersionLine` accepts `"WebView2 <ver>"`.
- `main.zig:18` disables the segfault handler on macOS only.

#### 1.2 Automation transport on Windows

- `src/automation_transport.zig:5-35` plans a filesystem AF_UNIX path for Windows,
  `{base}\zigbrowser\zigbrowser-automation-{nonce:x}.sock` (test at :49-62 checks it fits
  `UnixAddress.max_len`). It is not a named pipe.
- `src/app.zig:453-460` (`automationSocketPath`) picks `ZIGBROWSER_SOCKET`, else
  `XDG_RUNTIME_DIR`, else `/tmp`; there is no `%LOCALAPPDATA%` lookup.
- `src/automation_server.zig:167` returns `AddressFamilyUnsupported` when
  `!net.has_unix_sockets`; `restrictSocketMode` calls `std.c.chmod(path, 0o600)`
  unconditionally (:1513-1517); the token sidecar is created with mode `0o600`
  (:1496-1511). There is no Windows ACL code. Whether these compile for Windows is
  **unverified**.
- `tests/spikes/af_unix_roundtrip.zig` + build step `automation-afunix-spike-win`
  (build.zig:282-291) is the ADR-1 spike for AF_UNIX on Windows (plan
  `2026-07-09-phase2-3-external-api-platform-input-tdd-plan.md:171-201`). No recorded run
  result was found in `thoughts/` (**unverified** whether it was ever run).

#### 1.3 Build wiring

- `WebView2Paths` (build.zig:10-14) is filled from `-Dwebview2_include`/`WEBVIEW2_INCLUDE`,
  `-Dwebview2_lib`/`WEBVIEW2_LIB`, `-Dwinrt_include`/`WINRT_INCLUDE` (:111-130). No NuGet or
  registry discovery.
- `CheckWebView2SdkStep` (build.zig:16-77) fails the build unless all three dirs exist,
  `WebView2.h`, `WebView2LoaderStatic.lib` and `wrl.h` are present. It is the Windows
  `pkg_guard` (:148).
- `configureWebView2Backend` (build.zig:1535-1558) compiles `webview2_shim.cpp` with
  `-std=c++17` and links `WebView2LoaderStatic`, `ole32`, `oleaut32`, `user32`, `gdi32`,
  `shell32`, `advapi32`. No `agent_*.c` file is compiled on Windows.
- Linux checks: `cross-check` (build.zig:243-280) builds `src/main.zig` as an object for
  `x86_64-windows-gnu`, `aarch64-macos`, `x86_64-macos` and runs
  `tools/check_cross_symbols.py`; `ipc-test-win` (:224-235) compiles the backend-free IPC
  module for x86_64 Windows. `docs/how-to-build.md:52-77` states the shim compile, the link
  and the automation socket are "Not checked on Linux".
- Name trap: `automation-windows-e2e` (build.zig:1072-1078) runs
  `tests/e2e/automation_windows_test.py`, the GTK **browser-windows** (popup) test, not a
  Windows-OS test.

#### 1.4 Existing Windows guest tooling (does it still look usable?)

| File | What it does | State |
|---|---|---|
| `tests/guest/setup.ps1` (431 lines) | Elevated: OpenSSH Server + firewall rule (**created only when missing, with no `RemoteAddress` scope, so port 22 is open on every network profile; do NOT run this script on the Windows 10 file server**, it also installs Zig, nuget, MSVC Build Tools through winget and sets user env vars); Zig 0.16.0 zip into `%LOCALAPPDATA%\zigBrowser-tools`; nuget + `Microsoft.Web.WebView2`; MSVC Build Tools + Windows 11 SDK 22621 via winget; sets `WEBVIEW2_*`/`WINRT_INCLUDE` user env vars; prints a summary incl. the WebView2 runtime `pv` | Usable as the Win11 base; no Python, WiX, Autologon, power settings, or Win10 handling |
| `tests/guest/build-in-guest.sh` (28 lines) | Tars `src build.zig build.zig.zon tests`, scp to `maceo@100.103.8.90` with `zb_guest_key`, extracts under `%USERPROFILE%\zigBrowser`, runs `zig build <step> -Dtarget=x86_64-windows-msvc` with hardcoded SDK paths (WebView2 1.0.3967.48, Windows SDK 10.0.26100.0) | Usable if the guest's paths are unchanged; uses `StrictHostKeyChecking=no`; single host only. **Review 2026-10-19 findings:** the tarball is `src build.zig build.zig.zon tests` only, so `agent/`, `packaging/`, `tools/` (needed by `cross-check`, `tools/check_cross_symbols.py`), `docs/` and `sdk/` never reach the guest (later slices WS7, WS8 and WS13 need `agent/` and `packaging/`); the tar goes to a fixed shared `/tmp/zb_worktree.tar` (collides across agents) and `2>/dev/null` hides a failed `tar`; the default `HOST` `maceo@100.103.8.90` is **offline on the tailnet** (see below) |
| `tests/guest/ssh.sh` (50 lines) | Older wrapper for a passt forward `127.0.0.1:2222 -> guest 22` | **Correction (review 2026-10-19): not superseded; it is the working path.** The live domain XML has `<portForward proto='tcp'><range start='2222' to='22'/>` on its passt interface, while the Tailscale node `linuxwin` (`100.103.8.90`) shows `offline, last seen 105d ago` in `tailscale status` |
| `packaging/windows/build-msi.ps1` (152 lines) | ReleaseSafe MSVC build, WiX 3.14 `candle`/`light` from `C:\Users\maceo\WiX314`, checks ProductVersion and File table | Usable on the provisioned guest |
| `packaging/windows/gate.ps1` (240 lines) | Uninstall/install the MSI per-user, check `--version`, shortcuts, interactive capture via a `/IT` scheduled task with a fixed 16 s sleep, non-uniform PNG check, uninstall | Usable; no session/OS/assertion fail-closed checks |
| `tests/e2e/m8_render_test.py`, `m8_reply_channel_test.py`, `m8_load_fail_test.py` | Real-window render, IPC reply channel, load-fail exit codes; require `ZB_ENABLE_M8_E2E=1` and `platform.system()=="Windows"`; **exit 77 (skip) otherwise** | Not registered in `build.zig`; skip-to-pass off-host |
| `tests/e2e/msi_install_test.py` | Runs from Linux over SSH to the guest: build MSI, run `gate.ps1` | SKIPs (77) when key/guest/WiX missing |
| libvirt domain `win11-m8` (`qemu:///session`) | **Re-checked read-only on 2026-10-19 with `virsh`: the domain is `running`** (Id 1, 4 vCPU, 12 GiB, autostart disabled, CPU time 555 s) and `snapshot-list` is **empty** (no clean-state snapshot exists). Interface: libvirt `user` type with the `passt` backend and a `2222 -> 22` TCP forward. Display: SPICE on `127.0.0.1:5900`. Sound: an `ich9` device with a SPICE audio backend is already defined (so STT VS10's "virtual sound card" exists in the definition; whether Windows sees a capture endpoint, and whether the SPICE client passes the microphone through, is **unverified**). NVRAM is a raw file (`~/.config/libvirt/qemu/nvram/win11-m8_VARS.fd`) and the TPM is `tpm-crb` with a swtpm emulator, so a snapshot must capture disk, NVRAM and TPM state together (internal snapshots of a UEFI guest with raw NVRAM: **unverified**, spike needed). Two ISOs (Win11, virtio-win) are still attached. Earlier note: `provision-win11.sh` built it with UEFI Secure Boot (`OVMF_CODE_4M.ms.fd`), TPM 2.0 CRB, SPICE + QXL video, virtio disk/net, user-mode NAT; Tailscale gives `100.103.8.90` | Present; current Windows state, Tailscale login, and installed tools are **unverified** (not booted, per the no-SSH rule) |

The STT and TTS plans both mark the guest's current state and its audio-input device as
unknown (TTS plan :152; STT plan VS10.2).

**Host facts from the orchestrator (2026-10-19, not checked by this research, no SSH):**
- **Physical Windows 10 machine:** Tailscale IP `100.123.34.15`, tailnet name
  `file-server-win-mac`. It answers Tailscale ping directly (about 0 ms, LAN path
  `10.0.0.163`), but **TCP port 22 refuses connections**, so OpenSSH Server is not installed
  or not running. Its name says it is **also used as a file server**, so test runs there must
  be isolated from its existing use. Edition and build are unknown.
- **Win11 VM:** address **to be provided**. The old `win11-m8` tooling defaults to
  `maceo@100.103.8.90`; whether the user's Win11 VM is that same domain is not known.
- **Added by review (2026-10-19, read-only `tailscale status` and `virsh`):** the tailnet lists
  `100.123.34.15 file-server-win-mac` (windows, not marked offline) and `100.103.8.90 linuxwin`
  (windows, `offline, last seen 105d ago`). The running `win11-m8` domain is reachable from the
  Linux host only through the passt forward `127.0.0.1:2222` unless its Tailscale client is
  brought back. Nothing was started, stopped or connected to in this review.

#### 1.5 Packaging

- `packaging/windows/zigBrowser.wxs`: WiX v3 schema, `InstallScope="perUser"`,
  `InstallPrivileges="limited"`, installs to `%LOCALAPPDATA%\Programs\zigBrowser`, Start Menu +
  Desktop shortcuts, HKCU registry keys, `MediaTemplate EmbedCab="yes"`, and a deferred
  impersonated custom action running `MicrosoftEdgeWebview2Setup.exe /silent /install`
  (`Return="ignore"`, so a failed runtime install does not fail the MSI).
- ENG-0007 (`plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md:37`):
  "Code signing / notarization (follow-up; MSI unsigned for now)"; auto-update a separate
  slice.
- `packaging/release-build.sh` builds Linux only; Windows is a help-text note.

### 2. Build toolchain facts (web)

- Zig `-msvc` needs the proprietary MSVC + Windows SDK, so in practice a Windows host;
  `-gnu` uses Zig's bundled MinGW-w64 and works from any host; Zig's default Windows ABI is
  `gnu` ([ziggit](https://ziggit.dev/t/cross-compiling-for-windows-what-is-the-difference-between-gnu-and-msvc/6692),
  [zig#6565](https://github.com/ziglang/zig/issues/6565)). Linking a GUI C++ exe for
  `windows-gnu` from Linux: **unverified** (likely works).
- MinGW-w64's `wrl.h` comments out `implements.h` and `event.h`; `wrl/event.h` is absent on
  master, so `Callback<>` is not available ([wrl.h](https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/wrl.h)).
  Hand-written COM handler classes (IUnknown + `Invoke`) are the documented alternative
  ([handler reference](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2createcorewebview2environmentcompletedhandler)).
- webview/webview: static linking of the official loader "is possible with Visual C++ but not
  MinGW-w64"; it loads `WebView2Loader.dll` if present, else a built-in minimal loader
  ([webview/webview](https://github.com/webview/webview)). OpenWebView2Loader is ISC
  ([jchv](https://github.com/jchv/OpenWebView2Loader); MinGW support **unverified**).
- WebView2 SDK latest stable 1.0.4258.31 (2026-09-28) ([NuGet](https://www.nuget.org/packages/Microsoft.Web.WebView2));
  the guest pins 1.0.3967.48. WebView2 supports Windows 10 1709+ and Windows 11
  ([intro](https://learn.microsoft.com/en-us/microsoft-edge/webview2/)).
- APIs that exist for automation parity: `ExecuteScript`, `ExecuteScriptWithResult`,
  `AddScriptToExecuteOnDocumentCreated`, frame-level `ExecuteScript`, `ScriptDialogOpening`,
  `CapturePreview`, `CookieManager`, `ProcessFailed`, `CallDevToolsProtocolMethod`
  ([APIs overview](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/overview-features-apis),
  [process model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model),
  [CDP](https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/chromium-devtools-protocol)).
  `NewWindowRequested`/`WebResourceRequested` are known events but were not re-read
  (**unverified** here). One user data folder per environment; two environments with
  different options on one folder fail.
- **No WebView2 content-world (isolated world) API was found**; `ExecuteScript` runs in the
  page's main world ([howto/js](https://learn.microsoft.com/en-us/microsoft-edge/webview2/howto/js)).
  The CDP route `Page.createIsolatedWorld` / `Page.addScriptToEvaluateOnNewDocument
  {worldName}` + `Runtime.evaluate {contextId}` is standard Chromium protocol but
  **unverified** inside WebView2.
- CDP `Input.dispatchMouseEvent` producing `isTrusted: true`: only thin sources
  ([V2EX](https://v2ex.com/t/1236297), [zylos](https://zylos.ai/research/cdp-istrusted-research));
  **unverified** for WebView2.
- Browser flags (`disable-gpu`, `remote-debugging-port`, …) via `AdditionalBrowserArguments`
  are "not for production" ([flags](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/webview-features-flags)).

### 3. Drawer UI options on Windows

Codebase: the drawer is GTK3 native widgets (`src/agent_drawer.c`) over portable Zig logic
(`src/agent_drawer.zig`: `classifyGesture` 6 px at :18-29, `drawerRect` 40%/220/70% at
:76-82, `anim_ms = 180` with cubic ease at :86-103, `agent-drawer.json` at :244-277; C
exports gated `.linux` at :338-358). The spec (drawer plan D1-D5, :210-271): windowless host
(not an overlay, after the NVIDIA blank-window bug), "S" button "Open Claude Agent", header
with status, account button and "-" ("Minimize Claude Agent", agent_drawer.c:1223), bottom
dock, keyboard (Enter/Space opens, arrows 16/64 px, Ctrl+Shift+Space toggles, Escape
minimizes), 180 ms fold. The approval card (D10) is a native row whose Approve handler is the
only grant minter. macOS chose a native AppKit drawer for the same structural isolation
(macOS plan MS7).

| Option | Copyable text | Floating draggable "S" over the page | 180 ms fold animation | Isolation from page JS | Cost / risk |
|---|---|---|---|---|---|
| Plain Win32 (child HWNDs, read-only RichEdit bubbles, owned layered popup for the icon) | Read-only RichEdit gives native select + copy (standard Win32) | Docked panel is a sibling below the page HWND (no overlap). The icon overlaps the page: either an owned top-level `WS_EX_LAYERED \| WS_EX_TOOLWINDOW` no-activate popup (known pattern) or a sibling child HWND above the WebView2 child (airspace **unverified**); circular via `SetWindowRgn`; `WS_EX_LAYERED` on child windows needs Windows 8+ ([styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles)) | Timer- or vsync-driven `SetWindowPos`/`DeferWindowPos` using `agent_drawer.zig` lerp/ease; or DirectComposition | Structural (native, no web world), same as Linux/macOS | Most code; DPI, IME and accessibility must be handled by hand |
| Second WebView2 controller with a local HTML drawer | Free (Chromium) | Same icon problem unless page uses visual hosting | CSS | Separate WebView = separate renderer context (follows from Chromium, no explicit doc); separate user data folder gives separate processes ([process model](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/process-model)) | Extra renderer (memory **unverified**); drawer becomes a web context that renders model text and holds the Approve button; needs local virtual host, no remote navigation, strict CSP, text-only rendering |
| Visual hosting (`CreateCoreWebView2CompositionController` + DirectComposition) for the page, native or composition drawer | Depends on drawer tech | Clean overlay of a composition visual over the page | DirectComposition animation | Native | Manual input routing, DPI, accessibility; needs a `DispatcherQueueController` (gist) ([hosting modes](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/windowed-vs-visual-hosting)) |
| WinUI 3 / XAML Islands | Yes | Yes | XAML | Native | Windows App SDK 1809+; self-contained deploy + hybrid CRT; C++/WinRT MSVC-oriented; a reported silent launch failure unpackaged ([WinAppSDK](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/), [Q&A](https://learn.microsoft.com/en-us/answers/questions/1425927/how-can-i-deploy-an-unpackaged-self-contained-c-wi)) |
| Dear ImGui / Qt / Sciter | ImGui: no built-in cross-bubble selection, no accessibility tree (**unverified**); Qt LGPL/legal; Sciter paid | — | — | Native | Poor fit for a Zig/MinGW-or-MSVC C ABI build |

### 4. Agent host on Windows

#### 4.1 The seam as built (codebase)

- `SandboxBackend` Protocol (sandbox.py:201-229): `launch_spec`, `network`, `login_network`,
  `login_launch_spec`, `lifetime`, `channel`, `egress_endpoint`, `egress_dir`,
  `bridge_policy`, `hook_launch_spec`. Only `LinuxBwrapBackend` (:232-374) implements it;
  production goes through the singleton `_LINUX_BACKEND` (:380-432). No Seatbelt or Windows
  class exists. Contract test: `agent/host/tests/test_backend_contract.py`.
- `LaunchSpec` (sandbox.py:71-108): `argv`, `unshare`, `mounts`, `workdir`, `seccomp_fd`,
  `network` (`Egress` endpoint `127.0.0.1:3128`, allow `("api.anthropic.com",)` at :51;
  `BridgePolicy` ports 51091/31337, `hooks_get_egress=False`), `lifetime` (SIGKILL, parent
  race check), `channel` (fd 3, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`).
- Login network: `LOGIN_EGRESS_ALLOW = ("api.anthropic.com", "platform.claude.com")`
  (sandbox.py:56), no bridges. `setup.py:433-463` writes `runtime/net.json` and
  `runtime/net-login.json` from the backend values.
- The broker byte stream is the helper's stdin/stdout NDJSON, not a `LaunchSpec` field.
- POSIX-only parts (abridged; full list in the agent report this was built from):
  `/usr/bin/bwrap` and bind mounts (sandbox.py:27-300), `os.execve` (launch.py:99-111),
  `memfd_create` + x86_64 seccomp (seccomp.py:51-58), `os.mkfifo` + socketpair + `dup2` +
  `execv` in the `zb-claude` wrapper (token.py:61-129), AF_UNIX + `fork` + `pidfd_open` in
  `relay.py` (:38, 182-287), AF_UNIX + `fork` + bwrap in `netd.py` (:470-498, 709-795),
  bwrap per hook (`hook_run.py`), `pty`/`termios`/`killpg` in `login.py` (:31-139),
  `prctl(PR_SET_PDEATHSIG)`/`flock`/`waitpid` in `src/agent_host.c`, `pipe2`/`setpgid`/
  `kill(-pid)` in `src/agent_helper.c`, `/proc/self/exe` in `src/app.zig:130`.
- `CLAUDE_CODE_PROCESS_WRAPPER` is ignored on Windows because "the launcher contract depends
  on exec, which Windows doesn't support"
  ([corporate-launcher](https://code.claude.com/docs/en/corporate-launcher)); Python's
  `os.execv` on Windows spawns a new process rather than replacing the current one (standard
  CPython behavior), which affects the `zb-claude` wrapper's exec chain.

#### 4.2 Claude CLI and Agent SDK on Windows (web)

- Claude Code supports Windows 10 1809+ / Server 2019+, x64 and ARM64; install with
  `irm https://claude.ai/install.ps1 | iex` or winget; no admin; native binary (no Node);
  Git for Windows optional (PowerShell tool otherwise); binaries signed "Anthropic, PBC"
  ([setup](https://code.claude.com/docs/en/setup)).
- Credentials file `%USERPROFILE%\.claude\.credentials.json`; `CLAUDE_CONFIG_DIR` relocates
  ([authentication](https://code.claude.com/docs/en/authentication)).
- `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` is **not** in the official env-var page;
  whether it works on Windows (handle inheritance) is **unverified**.
- HTTPS_PROXY/HTTP_PROXY/NO_PROXY honored, no SOCKS; the CLI also contacts Datadog hosts and
  `downloads.claude.ai` unless disabled; required hosts include `api.anthropic.com`,
  `claude.ai`, `platform.claude.com` ([network-config](https://code.claude.com/docs/en/network-config)).
- Agent SDK Python: the Windows x64 wheel bundles `claude.exe`; `.bat`/`.cmd` shims are
  refused; ARM64 needs a native `claude.exe` via `cli_path`; Windows command line is capped
  near 32 KB, so large system prompts must use the file form
  ([troubleshooting](https://code.claude.com/docs/en/agent-sdk/troubleshooting),
  [python](https://code.claude.com/docs/en/agent-sdk/python)). An 80 s Windows startup issue
  was reported ([issue](https://claudeissues.com/issue/16005-claude-agent-sdk-80-second-startup-time-on-windows);
  status **unverified**).
- Python bundling: 3.15.0 embeddable zips about 13.7 MB (amd64) / 13.0 MB (arm64), no pip,
  `._pth` semantics ([python.org](https://www.python.org/downloads/windows/),
  [docs](https://docs.python.org/3/using/windows.html)); python-build-standalone 3.11 Windows
  install_only about 48 MB x64 / 45 MB aarch64
  ([releases](https://github.com/astral-sh/python-build-standalone/releases/latest)).

#### 4.3 Sandbox options (web)

| Option | Windows 10 | Home edition | Admin needed | Network allowlist path | Process/memory isolation | Lifetime | Notes |
|---|---|---|---|---|---|---|---|
| **Dedicated local user + restricted token + job object + WFP** (srt alpha, Codex elevated) | yes (srt version support **unverified**; Codex: 1809 minimum, Win11 recommended) | srt: **unverified**; Codex: yes | one-time elevated install (create user, WFP filters, DPAPI-stored password in HKLM) | WFP block-connect for the sandbox user's SID with a loopback permit only to the proxy ports; "a process that strips its proxy environment and connects directly is blocked at the kernel" (srt) | different user: default DACLs stop cross-user `OpenProcess` (inference) | job object `KILL_ON_JOB_CLOSE`, nested jobs since Windows 8 ([job objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)) | srt limits: per-user tool installs unreachable, DNS not fenced, proxy token in the runner's argv ([srt](https://github.com/anthropic-experimental/sandbox-runtime), [Codex](https://github.com/openai/codex/tree/main/codex-rs/windows-sandbox-rs/src), [Codex docs](https://learn.chatgpt.com/docs/windows/windows-sandbox)) |
| **AppContainer / LPAC** | yes (Windows 8+; LPAC minimum build **unverified**) | yes | profile creation no; **loopback exemption** (`CheckNetIsolation LoopbackExempt`) admin requirement **unverified** (Chromium note says admin) | no capability = no network; loopback blocked by default ([UWP firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/troubleshooting-uwp-firewall)) | Low IL + package SID; "isolated from accessing processes and windows belonging to other applications" ([isolation](https://learn.microsoft.com/en-us/windows/win32/secauthz/appcontainer-isolation)) | job object | Node/Bun CLI under (LP)AC is undocumented; WebView2 renderers run in an AppContainer on Windows 10 since v120 ([distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution)) |
| Restricted token + low IL only (Codex unelevated) | yes | yes | no | weak: firewall cannot match restricted-token SIDs (secondary source) | Low IL; process objects default to no-read-up (inference, **unverified**) | job object | Codex calls its network isolation here "weaker" |
| WSL2 (Linux backend inside) | 1903 build 18362.1049+ x64; NAT only, `networkingMode` is Windows 11 only | yes | enabling the features | Linux netns inside; mirrored mode Win11 22H2+ | full Linux guarantees in the distro | `wsl --terminate` (**unverified** dies-with-app) | needs virtualization; inside a VM needs nested virt (KVM nested Hyper-V "works sometimes, kernel-sensitive", forum sources); user hooks become Linux; interop can launch Windows processes unless disabled ([WSL FAQ](https://learn.microsoft.com/en-us/windows/wsl/faq), [wsl-config](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)) |
| Windows Sandbox | 18342+ | **no** (Pro/Enterprise/Education only) | — | on/off | full VM | one instance only | whole desktop; poor fit ([overview](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview)) |
| Hyper-V VM / HCS | yes | **no** (summary, **unverified**) | yes | — | full | — | — |

Prior project position: the red-team doc recommended "Windows: run the Linux design inside
WSL2 rather than AppContainer" and "Do not build an AppContainer backend for Bun hooks
unless a spike proves it works" (`research/2026-10-14-agent-sandbox-redteam.md:53, 322`).
Claude Code itself: "On native Windows, Claude Code runs commands unsandboxed"
([sandboxing](https://code.claude.com/docs/en/sandboxing)).

### 5. Network proxy (netd) on Windows

- netd today (`netd.py:1-40`): spawned by the browser before the helper
  (`src/agent_host.c:241-271`, 5 s "netd ready" wait), sandboxed by its own bwrap, creates
  `DIR/egress/proxy.sock` (CONNECT only to the manifest hosts) and
  `DIR/bridges/port-51091.sock` / `port-31337.sock`. It accepts only `CONNECT host:443`, no IP
  literals, no IDNA, all resolved addresses global, ClientHello SNI must equal the host, at
  most 16 tunnels (`netd.py:107-179, 414-416, 75`). Inside the sandbox `relay.py` maps
  `127.0.0.1:3128` to the egress socket; the CLI's `HTTPS_PROXY` comes from
  `sandbox.egress_endpoint()` (`options.py:26-33, 104`).
- macOS rev 6 pinned the shared egress capability as "backend supplies endpoint and policy";
  the CLI rejects Unix-socket proxy URLs (BlueBeaver 5503), so a TCP `host:port` hop is
  mandatory (macOS plan :82-93, :418-446).
- Windows enforcement facts: opening a WFP engine session needs `FWPM_ACTRL_OPEN`, admin in
  practice (**unverified** for non-admin); dynamic sessions delete their filters on close
  ([FwpmEngineOpen0](https://learn.microsoft.com/en-us/windows/win32/api/fwpmu/nf-fwpmu-fwpmengineopen0));
  WFP filters keyed on an AppContainer package SID **unverified**; srt's working pattern is a
  one-time elevated install of WFP filters for its sandbox user's SID with a loopback permit
  for ports 60080-60089.
- AF_UNIX exists on Windows 10 1803+ (the ADR-1 spike targets "Windows 10 RS4+"); its use for
  netd's internal sockets on Windows is **unverified** (spike result not recorded).

### 6. Secrets on Windows

- Linux today: libsecret via `dlopen` (`agent_secrets.c:32-88`, schema
  `dev.zigbrowser.ClaudeAgentToken`, `account=default`), or a private file store
  (`agent_secrets.zig:98-225`, `std.os.linux` only). Token shape `sk-ant-oat01-` + 22..512
  (`agent_secrets.zig:14-19`, portable). Secrets window: native GtkWindow with Paste/Save/
  Remove, "Save to a private file instead", Sign in / code entry / Copy link / Cancel
  (`agent_secrets_window.c:341-472`). Login runs `claude setup-token` on a pty and takes a
  pasted `code#state` (`login.py:128-225`); the auth window (S6b2) is not built.
- Credential Manager: `CredentialBlobSize` at most 2560 bytes; persistence SESSION /
  LOCAL_MACHINE (all of that user's sessions on this computer) / ENTERPRISE (roams); target
  names case-insensitive, free-form ([CREDENTIAL](https://learn.microsoft.com/en-us/windows/win32/api/wincred/ns-wincred-credentiala)).
  A 512-char token fits.
- DPAPI: user-scoped by default; `CRYPTPROTECT_UI_FORBIDDEN`; prompt-struct flow "will be
  removed in February 2027" ([CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)).
- Threat: any same-user process can call `CredRead`/`CryptUnprotectData` (Electron says
  safeStorage protects against other users, not other same-user apps,
  [Electron](https://www.electronjs.org/docs/latest/api/safe-storage)); Chrome added
  App-Bound Encryption in 127 for this reason ([Google](https://security.googleblog.com/2024/07/improving-security-of-chrome-cookies-on.html)).
  Git Credential Manager cannot persist to Credential Manager over a network logon such as
  SSH ([GCM](https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/credstores.md))
  — relevant to tests run over SSH.

### 7. Packaging, signing, update (web)

- **WiX licensing:** v6.0.0 introduced the Open Source Maintenance Fee; v7.0.0 (2026-04-06)
  binary "requires adherence to the OSMF EULA"; v4/v5 entries carry no OSMF text
  (**unverified** status) ([releases](https://github.com/wixtoolset/wix/releases)). The repo
  uses WiX 3.14.
- **MSIX:** must be signed with a trusted chain; sideloading on by default from Windows 10
  2004; `ms-appinstaller:` disabled by default since Dec 2023; AppData writes are virtualized
  per package (Windows 10 1903+), which matters for a browser profile read by a separate
  helper ([choose path](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/choose-distribution-path),
  [behind the scenes](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)).
  Store MSIX is re-signed by Microsoft; Store MSI/EXE needs your own trusted signature.
- **Signing:** "EV certificates no longer bypass SmartScreen"; signed files still warn until
  reputation builds (weeks, hundreds of clean installs); Smart App Control on Windows 11 can
  block unsigned files ([SmartScreen](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)).
  OV about $150-500/year (two Microsoft pages conflict). Keys on HSM/tokens since June 2023
  (vendor sources, **unverified**). **Azure Artifact Signing**: about $9.99/month Basic
  (5,000 signatures), needs a paid Azure subscription; Public Trust for organizations in the
  US, Canada, EU, UK, AU, NZ, JP, KR, SG, CH, NO, IL; **individuals only in the US or
  Canada**; certificates live about 3 days so timestamping is required; no EV
  ([quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart),
  [FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)). jsign signs exe/msi/
  msix from Linux, including Artifact Signing ([jsign](https://ebourg.github.io/jsign/)).
- **WebView2 runtime:** Evergreen bootstrapper about 2 MB; standalone offline installers for
  x86/x64/ARM64; Fixed Version "over 250 MB", app-updated, and on Windows 10 needs `icacls`
  grants to `S-1-15-2-1`/`S-1-15-2-2`; Windows 11 includes the runtime; the "vast majority"
  of Windows 10 devices have it; detect via `pv` under
  `...\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` or
  `GetAvailableCoreWebView2BrowserVersionString`
  ([distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution),
  [evergreen vs fixed](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/evergreen-vs-fixed-version)).
  Edge and WebView2 "will continue to receive updates on Windows 10 22H2 until at least
  October 2028... The ESU program won't be required"
  ([supported OS](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-supported-operating-systems)).
- **Large payloads:** single CAB 2 GB, MSI with embedded resources about 2 GB
  ([Advanced Installer](https://www.advancedinstaller.com/user-guide/qa-installer-large-resources.html),
  vendor source); Inno Setup disk-spans above 4.2 GB
  ([Inno](https://jrsoftware.org/ishelp/topic_setup_diskspanning.htm)); no official MSIX cap
  found. The STT plan's chosen model file (q8_0 multilingual medium) is 823,369,779 bytes
  (STT plan :40-60), under the 2 GB cabinet limit.
- **Auto-update:** MSIX + `.appinstaller`; Velopack (MIT, per-user, delta, signature
  verification) ([docs](https://docs.velopack.io/)); WinSparkle (MIT, Ed25519-signed
  appcasts, x86/x64/arm64, checks only) ([repo](https://github.com/vslavik/winsparkle)).

### 8. Testing facts (web) and arm64

- OpenSSH Server: Windows 10 1809+; `Add-WindowsCapability -Online -Name
  OpenSSH.Server~~~~0.0.1.0`; admin users' keys go in
  `C:\ProgramData\ssh\administrators_authorized_keys` with an ACL of Administrators + SYSTEM
  only; standard users use `%USERPROFILE%\.ssh\authorized_keys`; key-auth sessions hold no
  user credentials (no outbound auth)
  ([install](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse),
  [keys](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)).
- GUI from SSH: `schtasks /it` runs only when the user is logged on
  ([schtasks](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create));
  PsExec `-i` targets a session ([PsExec](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec));
  Autologon stores credentials as an LSA secret ([Autologon](https://learn.microsoft.com/en-us/sysinternals/downloads/autologon));
  an RDP disconnect leaves the logon screen unless `tscon <id> /dest:console` is run first
  (vendor docs); a locked desktop stops GUI drawing. `Windows.Graphics.Capture` per window
  needs 1903+ ([CreateForWindow](https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow));
  WebView2 `CapturePreview` captures page content without the desktop.
- WebView2 under a VM's basic display adapter / WARP: **unverified**; test with and without
  `--disable-gpu`.
- **arm64:** Windows on Arm is about 4-6% (TrendForce, May 2026; **unverified** share);
  "Windows 10 on Arm also supports emulation, but only for x86 apps" (no x64 emulation on
  Win10 Arm) while Windows 11 Arm emulates x86 and x64 (Prism)
  ([Microsoft](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation));
  Zig 0.16 lists `aarch64-windows` Tier 2 with partial CI
  ([release notes](https://ziglang.org/download/0.16.0/release-notes.html)); the WebView2
  ARM64 runtime and `win-arm64` loader exist; the Claude CLI ships win32-arm64; the SDK
  wheel's bundled `claude.exe` is x64 only (ARM64 needs `cli_path`).
- **Windows 10 lifecycle:** support ended 2025-10-14; consumer ESU enrollment open until
  **2027-10-12** for Win10 22H2 Home/Pro ([Microsoft](https://www.microsoft.com/en-us/windows/extended-security-updates)).

## Code References

- `src/webview2_shim.cpp:707-749` — `zb_app_run` (runtime check, window, environment, loop)
- `src/webview2_shim.cpp:751-757` — `zb_run_screenshot` stub
- `src/webview2_shim.cpp:412-463` — `chrome.webview` IPC to `zb_ipc_dispatch`
- `src/webview2_shim.cpp:692` — default environment (no user data folder)
- `src/webkit_shim.h` — the shared C ABI (75 declarations)
- `build.zig:10-77, 111-148` — `WebView2Paths`, `CheckWebView2SdkStep`
- `build.zig:1481-1488, 1535-1558` — `resolveBackend`, `configureWebView2Backend`
- `build.zig:224-291` — `ipc-test-win`, `cross-check`, `automation-afunix-spike-win`
- `src/automation_transport.zig:17-35` — `planSocketPath` (Windows AF_UNIX path)
- `src/app.zig:453-460` — `automationSocketPath` (no `%LOCALAPPDATA%`)
- `src/automation_server.zig:167, 1496-1517` — unix-socket gate, `0o600` token, `chmod`
- `src/automation_platform.zig:77-98, 167-430` — `.webview2` capability + CDP fakes
- `src/app.zig:52-55` — agent setup refuses non-Linux
- `agent/host/zb_agent_host/sandbox.py:51, 56, 71-108, 201-229, 232-374` — allowlists, `LaunchSpec`, `SandboxBackend`, `LinuxBwrapBackend`
- `agent/host/zb_agent_host/netd.py:1-40, 58` — netd design, `API_HOST`
- `agent/host/zb_agent_host/relay.py:39-40` — `EGRESS = {3128: ...}`, `BRIDGES`
- `agent/host/zb_agent_host/options.py:104` — `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`
- `src/agent_drawer.zig:18-29, 76-82, 86-103, 244-277` — portable drawer logic
- `src/agent_secrets.zig:14-19` — token shape
- `tests/e2e/slice2_common.py:447-548` — `run_windows_interactive_until` (`schtasks /it`)
- `packaging/windows/gate.ps1:88-150` — interactive capture via scheduled task
- `packaging/windows/zigBrowser.wxs` — per-user WiX v3 MSI + bootstrapper custom action
- `tests/guest/setup.ps1`, `tests/guest/build-in-guest.sh` — guest provisioning and build

## Architecture Documentation

One C ABI header, three per-OS translation units chosen by `resolveBackend`; one page-access
vtable (`PagePort`) with one GTK implementation; one Python `SandboxBackend` protocol with one
bwrap implementation; one shared egress capability (endpoint + policy from the backend) whose
macOS realization is an ephemeral host-loopback proxy plus per-process kernel rules. Windows
today realizes only the app/window/render/IPC seam. The Windows CDP input and network
capabilities are declared in the capability table and modeled by fakes, but not wired. Tests
reach Windows only over SSH to one guest, launching GUI processes through interactive
scheduled tasks.

## Workflow Closure Map

Behavior mapped: **"an automation command sent over the local socket drives the live page,
and the result is observable to the client"** — the same launch-critical chain the macOS
research mapped, read here for Windows. On Windows the chain is intact through the
platform-neutral nodes (socket server, router, engine, `PagePort`) except that the socket
listener itself is unproven (AF_UNIX spike unrecorded, `chmod` POSIX-only), and it is
**absent from the platform adapter onward**: `automation_gtk_port.supported` is false off
Linux, so `pagePort()` returns null (automation_gtk_port.zig:39-41), and
`webview2_shim.cpp` implements none of `zb_automation_*`.

| # | Node | Evidence | Label (Windows) | Depth | Adds/changes |
|---|---|---|---|---|---|
| 0 | loaded_page (SOURCE) | GTK `zb_automation_navigate_guarded` (webkit_shim.c:3076); Windows has only the startup `Navigate` (webview2_shim.cpp:541-553) | not-found on Windows | 0 | yes |
| 1 | socket_request (ENTRYPOINT) | `handleRequestWith` (automation_server.zig:412); bind at :165-204; `chmod` :1513-1517 | production-called on Linux; unproven on Windows | 1 | yes (transport ACLs) |
| 2 | router_command | `automation/router.zig` parse (automation_server.zig:503) | production-called | 2 | no |
| 3 | engine_execute | `queue.acquire` + `engine.executeWith` (automation_server.zig:518-526) | production-called | 3 | no |
| 4 | pageport_call | `automation/page_port.zig:185-205` | production-called (interface) | 4 | no |
| 5 | platform_adapter | `automation_gtk_port.zig:22, 39-78`; Windows: none | unmounted on Windows | 5 | yes — **highest_new_connector** |
| 6 | native_shim_effect | GTK marshal `auto_queue_on_gtk` (webkit_shim.c:1692); Windows: none | not-found on Windows | 6 | yes |
| 7 | observable_readback (OBSERVABLE) | `zb_automation_eval_json` (webkit_shim.c:3060) | not-found on Windows | 7 | yes |

Edges: 0→1, 1→2, 2→3, 3→4 synchronous in-process; 4→5 crosses the Zig→adapter boundary;
5→6 is async (marshal onto the UI thread; on Windows the driver would be the Win32 message
loop inside `zb_app_run`, webview2_shim.cpp:696-703); 6→7 synchronous read. Registration:
`buildAutomationConfig` passes the port (app.zig, macOS plan cites :220-237). Error behavior:
null port answers `-32011`; unix sockets missing returns `AddressFamilyUnsupported` at start.
No test exercises this chain on Windows.

### ClosureMap (structured — derive() input)

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

Symbol resolvability at the pin: `handleRequestWith`, `zb_app_run` (webview2_shim.cpp:707)
and `zb_automation_eval_json` / `zb_automation_navigate_guarded` (declared in
`webkit_shim.h`, defined in `webkit_shim.c`) resolve today. `src/automation_wv2_port.zig`
does not exist yet; it is the node the Windows slice adds (the macOS map used the same
convention for `automation_wk_port.zig`). On Windows the read and seed symbols resolve only
after the slice adds them to `webview2_shim.cpp`, so a map run before then fails safe to
BLOCKING.

### Closure adapter (staged proposal — inline only)

The research skill normally stages this as a sibling
`2026-10-19-windows-launch-support-surface.closure-adapter.py`. The task's hard rule allowed
exactly two files, so the scaffold is recorded here inline only and was **not** written to
disk.

```python
"""Closure adapter (STAGED PROPOSAL — not wired into the repo, not written to disk).
Derived from the ClosureMap for: an automation command drives the live WebView2 page.
Pin: 032a2c95e200db2e59d56147cb9c74afed50b727.
Promote into /home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59 and complete each TODO(promote).
Speaks the 7-op contract apps/closure-oracle already talks to (mock_adapter.py).
"""
import http.server, json, sys
ASYNC_EDGES = ["e5_adapter_to_shim"]              # Zig -> C ABI -> Win32 UI-thread marshal
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []

def handle(op, p):
    if op == "/reset":        SINK.clear(); CONNECTOR.update({e: True for e in ASYNC_EDGES}); return {"ok": True}
    if op == "/set_connector": CONNECTOR[p["edge"]] = p["enabled"]; return {"ok": True}
    if op == "/seed_sink":     SINK.append(p["value"]); return {"ok": True}
    if op == "/seed":
        # TODO(promote): load a fixture via zb_automation_navigate_guarded(p["data"])  (src/webkit_shim.h; Windows impl added by the slice in src/webview2_shim.cpp)
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): send the JSON-RPC command over the automation socket -> handleRequestWith(p["args"])  (src/automation_server.zig:412)
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True): return {"ok": True}
        # TODO(promote): the running Win32 message loop inside zb_app_run drains the marshalled job  (src/webview2_shim.cpp:696-703)
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return json.dumps(zb_automation_eval_json(<probe>))  (src/webkit_shim.h; Windows impl added by the slice)
        return {"ok": True, "value": json.dumps(SINK)}
    return {"ok": False, "error": "unknown op"}

class Hn(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        out = json.dumps(handle(self.path, json.loads(self.rfile.read(n) or "{}"))).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Hn).serve_forever()
```

Sibling behavior not mapped separately: "drawer Send → helper → CLI → drawer bubble" on
Windows has no node beyond the platform-neutral `agent_protocol.zig`; every Windows node is
`not-found`.

## Historical Context (from thoughts/)

- `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md` — M8: real WebView2 window in the Win11 KVM guest renders a fixture and answers `ping`/`echo`/`os.info`; in-guest build only ("No cross-compile-from-Linux build path", :52); guest `os.info` release `10.0.22631` (:80).
- `thoughts/searchable/shared/plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md` — per-user WiX MSI, bundled bootstrapper, unsigned.
- `thoughts/searchable/shared/plans/2026-07-09-phase2-3-external-api-platform-input-tdd-plan.md:171-201, 633` — ADR-1 AF_UNIX Windows spike; "If Windows AF_UNIX fails, stop and update ADR-1".
- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md:53, 86, 234-239, 322` — Windows via WSL2; srt Windows alpha; Claude Code unsandboxed on native Windows.
- `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md:263-285` — one shared backend interface covering bwrap, Seatbelt/VM, and WSL2.
- `thoughts/searchable/shared/plans/2026-10-14-14-30-macos-launch-tdd-plan.md` — the structure the Windows plan mirrors (MS0-MS9, fail-closed two-host gate, egress capability rev 6).
- `thoughts/searchable/shared/plans/2026-10-19-voice-output-tts-tdd-plan.md` — W0 (compile-only, Linux), W1 (WinRT `SpeechSynthesizer` + SAPI fallback at run time, "NOT RUN: there is no Windows test host"), W2 (spoken replies, blocked on a Windows drawer/helper plan); `tests/windows/speech_win_test.py` "run over SSH like the Mac tests". OD11 asks for a Windows drawer/helper plan and a Win11 host.
- `thoughts/searchable/shared/plans/2026-10-19-voice-input-stt-tdd-plan.md` — whisper.cpp v1.9.5 CPU, built `-Dtarget=x86_64-windows-msvc` in the guest; miniaudio WASAPI capture; VS10 (engine + capture, no UI, Win11 guest), VS11 (drawer dictation, blocked on a Windows drawer and a physical host with a microphone); VSP bundles the model in every installer; it expects the "Windows launch plan (WLP)" to provide the hosts, the drawer port, the helper and the MSI work.

## Related Research

- `thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md`
- `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md`
- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md`
- `thoughts/searchable/shared/research/2026-10-19-voice-output-tts.md`
- `thoughts/searchable/shared/research/2026-10-19-voice-input-stt.md`

## Open Questions

1. Does the `win11-m8` guest still boot with its tools, Tailscale login and SDK paths intact?
2. Did the ADR-1 AF_UNIX spike ever run on Windows; does the automation server compile for
   Windows (the unconditional `chmod`)?
3. Does a MinGW (`windows-gnu`) build of the shim link from Linux once `Callback<>` is
   replaced by hand-written handlers, and with which loader?
4. Does WebView2 accept CDP isolated worlds and produce `isTrusted` events from CDP input?
5. Does `claude.exe` honor `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` with an inherited
   handle on Windows?
6. Can a hook confined below the CLI (different user or Low IL) read the CLI's memory, argv,
   environment or credentials file?
7. Does the loopback exemption for an AppContainer need admin; can WFP filters be scoped per
   sandbox principal without admin?
8. What edition (Home or Pro) and build is the physical Windows 10 machine, and does it have
   the WebView2 runtime preinstalled?
9. Does WebView2 render correctly on the VM's QXL / basic display adapter?
10. Does nested virtualization (WSL2) work inside the KVM guest on this AMD host?
