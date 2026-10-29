---
date: 2026-10-29
researcher: pane 1 / CopperLynx (Claude Opus 5.5)
git_commit: 14e0012f
branch: zb-clojure-scope-2026-10-29-10-21
topic: "Clojure / ClojureScript port scope, part 1: native and platform side"
status: draft for merge
---

# Clojure port scope, part 1: native and platform side

> **Coordination note (pane 1 → pane 2).** We agreed the split by Agent Mail on 2026-10-29.
> - Pane 2 (TealCastle) owns the site flows, sequences, `automation.js`, the dashboard, the drawer UI content, the Python agent host, the SDKs and the test tree. Pane 2 also owns sections 4, 5, 7 and 9.
> - Pane 1 (this file) owns the Zig core, the shims, the RPC, the broker, policy, secrets, sandbox spawn, packaging and signing. Pane 1 also owns sections 1, 3, 6 and 8.
> - Section 2 is split by those same lines.
> - `nav_policy.zig` and `load_failure_policy.zig` are cited in section 6 here. They also appear in my section 2 table, because they must stay native in my recommended design.
> - The inventory table columns match pane 2's columns so the merge is mechanical.

**Labels.** Every claim carries one label.
- **[V] verified**: I or a reader agent read the code at that line.
- **[I] inferred**: it follows from the code but was not run.
- **[U] unknown**: not found or not checked.
- **[W] web fact**: carries a source URL.

All paths are relative to the repo root at commit `14e0012f`. The paused Windows work was read with `git show zb-windows-impl-2026-10-22-15-03:<path>` and is marked "(win branch)".

---

## 1. Summary (draft; the merged version will fold in pane 2's findings)

### What a port means

zigBrowser has the following layers today.
1. A Zig core: the app, CLI, automation server, router and engine, the agent broker, the policies and the on-disk stores.
2. Three native web-engine shims behind one C header, `src/webkit_shim.h` (79 `zb_*` declarations [V]). The engines are WebKitGTK on Linux, WKWebView/AppKit on Mac and WebView2 on Windows.
3. Native UI: the agent drawer, the Secrets window and the auth window are native widgets, not HTML [V] (`src/agent_drawer.h:4-6`).
4. An injected page script, `src/automation_script/automation.js`.
5. A Python agent host around the Claude Agent SDK.

"Porting to Clojure" cannot mean porting everything. The web engines and their shims are C, Objective-C and C++ that talk to OS frameworks. They must stay native.

The realistic port replaces the **Zig core** with **Clojure**, keeps a **small native host per OS**, and compiles the **page script and web UIs** from **ClojureScript**.

### Recommended target architecture

The recommendation is **two processes per OS**.

**A native host** stays native. It is the app's main executable.
- It owns the main thread, the web engine, the native windows (browser, drawer, Secrets, auth), the Keychain / libsecret / Credential Manager calls, and the child-process spawn with fd 3 token handoff.
- It keeps three tiny synchronous policies the shims call inline: `zb_policy_decide`, `zb_load_failure_action` and `zb_ipc_dispatch` (`src/webkit_shim.h:435-443` [V]).
- It exposes the existing `PagePort` (21 methods) and `CookiePort` (3 methods) seam over a local socket (`src/automation/page_port.zig:189-327`, `src/automation/cookie_port.zig:19-29` [V]).

**A Clojure core** is new. It is compiled ahead of time with GraalVM native-image.
- It owns the CLI, the automation server (JSON-RPC, auth, framing, queue, engine, router, errors, telemetry), the cookie routes, the site flows and sequences, the agent broker and tools, the approval policy, frame validation, the run ledger and the on-disk JSON stores.
- It talks to the host over the socket. It never calls native code directly.

**The page script and any web UI** become ClojureScript compiled by shadow-cljs (pane 2, section 4).

**The Python agent host stays Python** (pane 2, section 5). The Agent SDK exists only for Python and TypeScript [W] (https://code.claude.com/docs/en/agent-sdk/overview).

Why this design and not Panama FFI in one JVM process:
- **macOS main thread.** The UI loop must own the process main thread. On macOS that is a hard rule for AppKit.
- **Native code calls back in.** The shims call back into the core through hard-linked exports (`src/webkit_shim.h:435`; macOS resolves them by flat-namespace lookup, `build.zig:5547-5555` [V]).
- **GraalVM FFM gap.** GraalVM native-image documents FFM downcalls and upcalls for Linux x64, Windows x64, macOS AArch64 and Linux AArch64, but not macOS x64 (Intel) [W] (https://www.graalvm.org/dev/reference-manual/native-image/native-code-interoperability/ffm-api/). The product ships a universal arm64 + x86_64 Mac build (`packaging/macos/build-dmg.sh:127-134` [V]).
- **A socket avoids all three problems.** It also keeps the core free of FFI, so native-image works without FFM.

### Top 5 risks

1. **Most hard code stays native, so the port moves less than it seems.**
   - About 24,600 lines of C, Objective-C, C++ and headers stay native: shims, drawer, Secrets and auth windows, spawn, reaper, Keychain.
   - About 17,100 lines of Zig product code move to Clojure.
   - These are `wc -l` sums over `src/` [V].
   - The hardest past bugs were in threading, WebKit and AppKit, and those stay where they are [I].
2. **Contract drift breaks users silently.** The automation wire format, 15 automation error codes, the WKWebsiteDataStore UUID derivation, Keychain item names and the run ledger schema must be byte-for-byte equal. If they drift, SDK users break, or Mac users lose cookies and their saved token (section 6).
3. **Startup, memory and size.** A plain JVM adds seconds of startup. Old community reports say a Clojure uberjar is "not under 2 seconds" [W] (https://ask.clojure.org/index.php/8292/has-anyone-benchmarked-cold-start-times-for-clojure-lambda). Native-image fixes startup but adds build complexity per OS and arch. GraalVM's macOS x64 support is not confirmed [U]. The Mac bundle is already about 632 MB of dependencies before any JVM (`thoughts/searchable/shared/research/2026-10-20-ms5-deps-cli-macos-recommendation.md:90-91` [V]).
4. **Mac signing and notarization get harder.**
   - Today the DMG is ad-hoc signed by default and not notarized (`packaging/macos/build-dmg.sh:9,28-29` [V]).
   - Every new Mach-O (the core binary, or a JVM runtime with many dylibs) must be signed inside-out with hardened runtime.
   - A HotSpot JVM would likely need `com.apple.security.cs.allow-jit` [I]. The project deliberately holds that entitlement out today (`packaging/macos/entitlements.plist:16-23` [V]).
5. **A big rewrite against a moving product.**
   - The repo has 2,964 commits since 2026-05-30 [V] (`git rev-list --count HEAD`).
   - It has about 115,000 lines of code under `tests/`, in all languages: 61,481 Python, 28,758 Zig, 16,071 shell and others (cloc [V]).
   - Three platform tracks are in flight (Mac active, Windows paused).
   - A port only stays safe if it runs behind the existing tests as contract tests, one layer at a time, with both cores runnable side by side (sections 7 and 8).

---

## 2. Inventory: pane 1 modules

Columns match pane 2. `Lines` is `wc -l` at `14e0012f`. Targets are `Clojure (JVM)`, `ClojureScript`, `babashka/nbb`, `stays native` or `drop`. "Clojure (JVM)" here means Clojure source compiled to a native-image binary in the recommended design. The descriptions come from each file's header comment [V] unless marked otherwise.

### 2a. Process entry, CLI, config

| Path | Language | Lines | What it does | Target | Label |
|---|---|---|---|---|---|
| src/main.zig | Zig | 127 | Process entry. Primes the environment, parses args, calls `app.runWithIo` (`main.zig:27-77`). | stays native (host `main`) | V |
| src/app.zig | Zig | 734 | Startup order: validates the URL, applies flags, binds the profile, starts netd, helper, login and the automation server, then runs the native loop (`app.zig:433-509`). | Clojure (JVM), with native-loop start in host | V |
| src/cli.zig | Zig | 560 | Parses commands and flags (`--screenshot`, `--agent-setup`, `--automation-api`, `--profile-dir`, render and media flags). | Clojure (JVM); the host parses its own startup flags | V |
| src/config.zig | Zig | 13 | Facade over build-time `build_options` (default URL). | Clojure (JVM) (build-time constant) | V |
| src/config_schema.zig | Zig | 41 | Validates `zigbrowser.json` (`url` only, max 2048). | Clojure (JVM) / build script | V |
| src/uri.zig | Zig | 79 | Start-URL scheme check (http/https/about/file). | Clojure (JVM) | V |
| src/errors.zig | Zig | 37 | CLI exit codes 1-10, 130. | Clojure (JVM) (contract) | V |
| src/env_switch.zig | Zig | 29 | Flag > env var > default resolver. | Clojure (JVM) | V |
| src/environ_guard.zig | Zig | 24 | Works around Zig 0.16 lazy-environ scan corruption. | drop | V |
| src/backend_flag.zig | Zig | 102 | Per-OS accept/refuse for `--media-source`, `--hardware-acceleration`, `--renderer`. | Clojure (JVM) decision; host applies | V |
| src/render_config.zig | Zig | 161 | Hardware-accel policy and renderer env vars (`WEBKIT_DMABUF_RENDERER_FORCE_SHM`). | stays native (must apply before engine init) | V |
| src/media_config.zig | Zig | 64 | MSE on/off. | stays native (applied at window create) | V |
| src/webview2_config.zig | Zig | 49 | Windows arm of the backend flags. | stays native | V |
| src/self_exe.zig | Zig | 27 | Real path of the running binary. | stays native (host) | V |
| src/xdg.zig | Zig | 14 | XDG data-dir lookup. | Clojure (JVM) | V |
| src/atomic_file.zig | Zig | 52 | Temp + fsync + rename + dir fsync for small JSON files. | Clojure (JVM) (`java.nio` `ATOMIC_MOVE`; dir fsync needs care) | V / I |
| src/profile_step.zig | Zig | 64 | Binds `--profile-dir` per OS; Mac only for explicit dirs. | stays native (host binds the store) | V |
| src/root.zig | Zig | 81 | Test root importing modules. | drop | V |
| src/darwin_guard_root.zig, src/ws3_win_cross_root.zig, src/agent_secrets_win_crosscheck.zig | Zig | 31 / 10 / 5 | Cross-compile check roots only. | drop | V |
| build.zig | Zig | 5,595 (4,695 win branch) | Build graph: 128 `addTest`, 120 `b.step` [V]; links per-OS libs (`build.zig:5473-5500,5586-5590`). | Host part stays (zig build or CMake/Xcode); core moves to `deps.edn` + shadow-cljs | V |
| build.zig.zon | Zig | 82 | Package manifest (version 0.2.0, Zig 0.16.0). | stays (host) or drop | V |

### 2b. Automation core

| Path | Language | Lines | What it does | Target | Label |
|---|---|---|---|---|---|
| src/automation_server.zig | Zig | 1,718 | Socket server: 4-byte length framing, auth, dispatch, window/health/recover/dialog routes, in-process call for the drawer. | Clojure (JVM) | V |
| src/automation_transport.zig | Zig | 144 | Socket path and base dir per OS. | Clojure (JVM) (Java 16+ has `UnixDomainSocketAddress`) | V / I |
| src/automation_websocket.zig | Zig | 140 | WebSocket upgrade and one `automation.ready` frame. | Clojure (JVM) | V |
| src/automation_otlp.zig | Zig | 149 | OTLP telemetry export config. | Clojure (JVM) | V |
| src/automation_platform.zig | Zig | 1,254 (1,285 win) | Backend capability table (input mode, network support) per engine (`:77-98`). | Clojure (JVM) (data) | V |
| src/automation_port_parse.zig | Zig | 143 | Parses shim window/dialog/recovery JSON. | Clojure (JVM) | V |
| src/automation_rpc.zig | Zig | 527 | Older newline-framed JSON-RPC helpers; only `root.zig:8` imports it. | drop (do not port: wrong framing) | V |
| src/automation.zig | Zig | 41 | Module facade, verb list. | Clojure (JVM) | V |
| src/automation/engine.zig | Zig | 1,970 | Runs one command against a PagePort, retry loop, error mapping. | Clojure (JVM) | V |
| src/automation/router.zig | Zig | 727 | Method → verb, param and option validation. | Clojure (JVM) | V |
| src/automation/queue.zig | Zig | 216 | Per-page FIFO queue. | Clojure (JVM) (core.async or a lock per page) | V / I |
| src/automation/error.zig | Zig | 76 | Automation error enum -32001..-32015. | Clojure (JVM) (contract) | V |
| src/automation/page_port.zig | Zig | 531 | PagePort vtable (21 methods) and PortError (15). | Clojure (JVM) protocol + host socket stub | V |
| src/automation/cookie_port.zig | Zig | 42 | CookiePort vtable (3 methods). | Clojure (JVM) protocol | V |
| src/automation/cookie_routes.zig | Zig | 606 | `cookies.getAll/set/delete/import`. | Clojure (JVM) | V |
| src/automation/script_command.zig | Zig | 231 | Builds `{op,...}` JS calls for automation.js and parses answers. | Clojure (JVM) | V |
| src/automation/telemetry.zig | Zig | 637 | Spans, redaction, `telemetry.query`. | Clojure (JVM) | V |
| src/automation/session.zig | Zig | 58 | Session pacing simulator config. | Clojure (JVM) | V |
| src/automation_gtk_port.zig | Zig | 1,307 | GTK PagePort over the `zb_automation_*` C ABI. | stays native (becomes the host's socket stub on Linux) | V |
| src/automation_macos_port.zig | Zig | 268 | macOS PagePort over the same C ABI. | stays native (host stub) | V |
| src/automation_wv2_port.zig (win branch) | Zig | 152 | Windows PagePort; routed commands only so far. | stays native (host stub) | V |
| src/automation_{gtk,macos,wv2}_cookie_port.zig | Zig | 149 / 145 / 130 | CookiePort per OS. | stays native (host stub) | V |
| src/ipc.zig | Zig | 198 | Page→host `zb_ipc_dispatch` (`ping`, `add`, `echo`, `os.info`). | stays native (called inline by the shims) | V |
| src/nav_policy.zig | Zig | 144 | `zb_policy_decide`: file-base containment, popups. | stays native (inline callback); port as C or keep Zig | V |
| src/load_failure_policy.zig | Zig | 56 | `zb_load_failure_action` / exit timer. | stays native (inline callback) | V |

### 2c. Agent side (broker, protocol, secrets, spawn)

| Path | Language | Lines | What it does | Target | Label |
|---|---|---|---|---|---|
| src/agent_broker.zig | Zig | 951 | Per-window broker: tool → engine call, approval cards, deadlines, redaction. | Clojure (JVM) | V |
| src/agent_tools.zig | Zig | 288 | Routes a drawer's tool calls to its broker. | Clojure (JVM) | V |
| src/agent_approval.zig | Zig | 331 | Approval policy, selector store, card lifecycle. | Clojure (JVM) | V |
| src/agent_protocol.zig | Zig | 524 | Validates helper→app NDJSON frames and login frames. | Clojure (JVM) | V |
| src/agent_frames.zig | Zig | 296 | C face of frame validation; builds `tool_result`. | Clojure (JVM) | V |
| src/agent_helper.zig | Zig | 291 | Helper launch argv and environment; restart backoff. | Clojure (JVM) (argv) + host (spawn) | V |
| src/agent_helper.c / .h | C | 1,060 / 79 | Linux helper controller: GSubprocess spawn, fd 3 token pipe, state machine, frame relay. | split: spawn stays native; state machine → Clojure | V / I |
| src/agent_host.c / .h | C | 277 / 101 | Linux PDEATHSIG, netd spawn and stop. | stays native | V |
| src/agent_host_posix.zig | Zig | 312 | Mac netd spawn, reads its ready port. | stays native (host) | V |
| src/agent_spawn_posix.c / .h | C | 208 / 60 | `posix_spawn` with its own process group and CLOEXEC_DEFAULT, keeps only fd 3/4. | stays native | V |
| src/agent_helper_mac.c / .h | C | 29 / 59 | Keychain → fd 3 spawn wrapper. | stays native | V |
| src/agent_helper_mac_runtime.m | ObjC | 922 | Mac owner of netd and the helper; NDJSON flow. | split: process side native; flow → Clojure | V / I |
| src/agent_token_fd_mac.c / .h | C | 172 / 63 | Token goes to exactly one fd via socketpair. | stays native | V |
| src/agent_net.zig | Zig | 188 | netd socket dir and argv; e2e seams. | Clojure (JVM) (argv) + host (spawn) | V |
| src/agent_setup.zig | Zig | 341 | `--agent-setup`: agent home path, setup argv and env. | Clojure (JVM) | V |
| src/agent_config.zig | Zig | 122 | Drawer on/off, secret-store switch. | Clojure (JVM) | V |
| src/agent_config_check.zig | Zig | 84 | Re-hashes `.claude` against `config-manifest.json` per session. | Clojure (JVM) | V |
| src/agent_run_ledger.zig | Zig | 528 | Run ledger parse, lock and publish. | Clojure (JVM) (flock via `FileChannel.lock` [I]) | V |
| src/agent_run_recovery.zig | Zig | 546 | Recovery lease; unreachable in production (`reaper_ready` false). | Clojure (JVM) later, or drop until armed | V |
| src/agent_run_reaper.c / .h | C | 493 / 186 | Mac libproc survivor sweep, kill by identity. | stays native | V |
| src/agent_login.zig | Zig | 245 | Login helper argv. | Clojure (JVM) | V |
| src/agent_login.c / .h | C | 495 / 42 | One-shot sign-in process side. | split: spawn native; flow → Clojure | V / I |
| src/agent_auth.zig | Zig | 320 | Auth window callback and authorize-URL check. | Clojure (JVM) (check) + host (window) | V |
| src/agent_auth_seam.zig | Zig | 81 | e2e auth proxy seam. | Clojure (JVM) | V |
| src/agent_auth_window.c / .h | C | 272 / 22 | GTK auth window body. | stays native | V |
| src/agent_secrets.zig | Zig | 419 | Token shape and explicit file store. | Clojure (JVM) (file store); shape rule shared | V |
| src/agent_secrets_shape.zig | Zig | 35 | Token regex. | Clojure (JVM) | V |
| src/agent_secrets_store.zig | Zig | 115 | Portable TokenStore interface. | Clojure (JVM) protocol; host backs it | V |
| src/agent_secrets.c / .h | C | 380 / 70 | libsecret backend via dlopen. | stays native | V |
| src/agent_secrets_mac.zig | Zig | 152 | Zig wrapper over Keychain C seam. | stays native (host) | V |
| src/agent_secrets_mac.m / .h | ObjC | 601 / 80 | Keychain SecItem backend. | stays native (Keychain ACL binds to the signed caller [I]) | V / I |
| src/agent_secrets_win.cpp | C++ | 104 | Credential Manager + DPAPI. | stays native | V |
| src/agent_secrets_window.c / .h | C | 954 / 58 | GTK Secrets window. | stays native | V |
| src/agent_secrets_window_mac.m / .h | ObjC | 1,149 / 30 | AppKit Secrets window. | stays native | V |
| src/agent_image.c / .h | C | 100 / 29 | Fits a screenshot PNG under 1 MiB (GdkPixbuf). | Clojure (JVM) (`javax.imageio`) or stays native | V / I |
| src/agent_home_lock.c / .h | C | 72 / 19 | `flock` owner lock on the agent home. | Clojure (JVM) (`FileChannel.tryLock`) | V / I |
| src/agent_launch_bridge.zig | Zig | 109 | Test-only bridge for launch builders. | drop (replace with Clojure test) | V |
| src/seatbelt_gate.zig | Zig | 6 | `accepted_commit = null` → seatbelt not ready. | Clojure (JVM) (constant) | V |
| src/mac_vm_containment.zig | Zig | 55 | Stub for a future VM sandbox; always unavailable. | Clojure (JVM) (stub) | V |
| src/owner_only.zig | Zig | 244 | Owner-only perms: POSIX 0600/0700, Windows protected DACL. | split: POSIX → Clojure (`PosixFilePermissions`); Windows DACL stays native | V / I |
| src/zb_test_hook_gate.h | C | 28 | Pure decisions for Mac e2e hooks. | stays native | V |

### 2d. Shims and native UI (all stay native)

| Path | Language | Lines | What it does | Target | Label |
|---|---|---|---|---|---|
| src/webkit_shim.h | C | 449 | The one cross-backend C ABI (79 decls). | stays native; becomes the host-protocol spec | V |
| src/webkit_shim.c | C | 5,718 | WebKitGTK/GTK3 backend: windows, eval, input, cookies, screenshots, dialogs. 76 non-static `zb_*` fns. | stays native | V |
| src/wkwebview_shim.m | ObjC | 3,249 | WKWebView/AppKit backend. 36 non-static `zb_*` fns. | stays native | V |
| src/webview2_shim.cpp | C++ | 2,591 (3,596 win) | WebView2/Win32 backend. 40 non-static `zb_*` fns (60 on win branch, now with eval and native input). | stays native | V |
| src/cdp_json.hpp (win branch) | C++ | 280 | CDP JSON helpers for WebView2. | stays native | V |
| src/webkit.zig | Zig | 3,862 | About 185 lines of flag/startup glue (`:10-184`) plus about 3,680 lines of live shim tests (`:185-3828`). | glue → host; tests stay as native host tests | V |
| src/agent_drawer.c / .h | C | 1,832 / 32 | GTK drawer host and widgets. | stays native (UI content owned by pane 2) | V |
| src/agent_drawer.zig | Zig | 866 | Drawer geometry and gestures, `zb_drawer_*` exports used by Mac and Windows. | stays native (called inline by UI code) | V |
| src/agent_drawer_mac_host.m, _panel.m, _mac.h | ObjC | 1,064 / 1,439 / 49 | AppKit drawer. | stays native | V |

### 2e. Packaging and tools

| Path | Language | Lines | What it does | Target | Label |
|---|---|---|---|---|---|
| packaging/macos/build-dmg.sh | sh | 238 | Two-Mac build, lipo merge, inside-out codesign, DMG. | stays (shell); add the core binary and notarization | V |
| packaging/macos/stage_agent_runtime.sh, build_site_packages.sh | sh | 90 / 23 | Python 3.12.10 framework + universal site-packages. | stays | V |
| packaging/macos/*.py (relocate, merge, sdk_pth, ms5_inventory) | Python | 795 total | Mach-O relocation, universal tree merge, inventory. | stays, or babashka/nbb | V / I |
| packaging/macos/entitlements.plist, Info.plist | XML | 32 / 38 | One entitlement (`network.client`); bundle id `com.cosmichq.zigBrowser`, macOS 13.0+. | stays; review for the new binary | V |
| packaging/macos/agent_runtime_pins.json, universal_components*.json, sigstore_verifier.txt | JSON/txt | 13 / 187 / 562 | Pins and hashes. | stays | V |
| packaging/linux/* | sh | 151 | `.deb`, depends on libwebkit2gtk-4.1-0 and libgtk-3-0; no agent runtime. | stays; add the core binary | V |
| packaging/windows/build-msi.ps1, zigBrowser.wxs, gate.ps1 | PowerShell/WiX | 152 / 94 / 240 | Per-user MSI with WebView2 bootstrapper (1.6 MB). | stays; add the core binary | V |
| packaging/release-build.sh | sh | 39 | Release driver. | stays or babashka | V |
| tools/*.py, *.sh, *.mjs, sequences_live_smoke.zig | mixed | 510 | Env helpers, cross-symbol check, display guard, smoke. | babashka/nbb or drop per tool | I |

**Size by target (pane 1 scope only) [V, `wc -l` sums]**
- Zig that moves to Clojure: about 17,100 lines.
- C, ObjC, C++ and headers that stay native: about 24,600 lines.
- About 3,680 lines of `webkit.zig` are live shim tests, which stay as host tests.
- Zig glue that stays in the host (ports, policies, drawer geometry, configs): about 4,400 lines [V, `wc -l` sum of the "stays native" Zig rows, counting only the 185 glue lines of `webkit.zig`].

---

## 3. Native interop choice

### What the native side must do [V]

- **Own the main thread.** `zb_app_run` takes the thread with `gtk_main` (`webkit_shim.c:5252`), `[NSApp run]` on Mac, or a Win32 `GetMessageW` loop (`webview2_shim.cpp:2170`).
- **Accept blocking calls from another thread.** Almost every `zb_automation_*`, `zb_cookies_*`, `zb_native_*` and `zb_screenshot_png` call blocks a non-UI caller for up to `timeout_ms`. The work runs on the UI thread (`webkit_shim.h:42-76`; Mac uses `dispatch_async` to main, `wkwebview_shim.m:1702-1885`; Windows uses `PostMessageW` + event, `webview2_shim.cpp:740-769`).
- **Call back synchronously into the core.** The shims call `zb_policy_decide`, `zb_load_failure_action`, `zb_load_exit_timer_armed` and `zb_ipc_dispatch` inline (`webkit_shim.h:435-443`).
- **Inject JS** at document start into an isolated world named `zigbrowser-automation` (GTK `webkit_shim.c:1905-1909`; Mac `WKContentWorld`, `wkwebview_shim.m:636-650`; Windows `AddScriptToExecuteOnDocumentCreated`, `webview2_shim.cpp:1893`).
- **Pass the token on exactly one fd** to a child: fd 3 for chat, fd 4 for sign-in (`agent_spawn_posix.c:35-88`, `agent_token_fd_mac.c:94-132`, `agent_helper.c:730`).
  - Java's `ProcessBuilder` cannot pass extra fds [I].
- **Read the Keychain.** It uses `kSecClassGenericPassword`, service `dev.zigbrowser.ClaudeAgentToken`, from the signed app (`agent_secrets_mac.m:265-272`, `agent_helper_mac.h:14-15`).

### Options compared

The figures below carry [W] sources or are marked [U].

| Option | How it works | Startup | Memory | App size | Mac signing | GraalVM | Verdict |
|---|---|---|---|---|---|---|---|
| **A. Panama FFM in one JVM** | Clojure (coffi) calls the shim C ABI in-process. The shims become shared libs. Upcall stubs supply `zb_policy_decide` etc. | JVM boot on the critical path before first window [I]. JDK 24 AOT cache cut one app from 4.5 s to 2.6 s [W] (https://openjdk.org/jeps/483). | One process. JVM heap plus engine [U, measure]. | + jlink runtime [U, measure] | JVM needs `allow-jit` under hardened runtime [I]. More dylibs to sign. | FFM in native-image is on by default from GraalVM 25 [W] (https://docs.oracle.com/en/graalvm/jdk/25/docs/reference-manual/native-image/native-code-interoperability/ffm-api). Listed platforms omit macOS x64 [W] (https://www.graalvm.org/dev/reference-manual/native-image/native-code-interoperability/ffm-api/). Descriptors must be known at build time [W] (same source). | Possible, but the riskiest for Mac Intel and main-thread rules. |
| **B. JNI** | Same as A, with hand-written JNI C glue. | Same as A. | Same as A. | Same as A. | Same as A. | JNI works in native-image but needs config [I]. | Strictly worse than A. No reason to pick it. |
| **C. Small native host over a socket (recommended)** | Keep the shims plus a thin native `main` as the app executable. It serves PagePort, CookiePort, window lifecycle, drawer events and spawn over a local socket using the same 4-byte length + JSON framing as today. The Clojure core is a separate native-image process. | Window paints with no wait on the core [I]. A Clojure native image starts in tens of ms; babashka starts in about 8 ms [W] (https://clojurians-log.clojureverse.org/babashka/2023-05-28). | Two processes. The core's native-image RSS is small [U, measure]. | Core binary tens of MB; babashka is about 73 MB uncompressed [W] (same source). | The core is one more Mach-O, AOT-compiled, so no JIT entitlement [I]. Two arches → build both and `lipo` like today. | No FFM, no AWT, so native-image is the easy case. graal-build-time handles Clojure init [W] (https://github.com/clj-easy/graal-build-time). Mac x64 GraalVM availability is not confirmed [U]. | **Recommended.** |
| **D. JCEF (Chromium in the JVM)** | Replace all three engines with Chromium via JCEF. Automation over CDP. | JVM + Chromium boot [U]. | Chromium multi-process [U]. | +100 MB or more per OS [U]. | Many Chromium helpers to sign [I]. | No [I]. | Reject. It changes the engine users and sites see. It drops the WKWebsiteDataStore and WebView2 stores, so users lose cookies (section 6.4). It discards three working shims. |
| **E. JavaFX WebView** | JavaFX's own WebKit 620.1 [W] (https://openjfx.io/highlights/25/). | JVM boot. | JVM. | JavaFX modules. | JIT entitlement [I]. | WebView is not supported in native-image [W] (https://bell-sw.com/blog/how-to-create-javafx-native-images/). | Reject. It has no isolated worlds, no profile store control and no native input equal to today's. |
| **F. Electron + ClojureScript** | Rewrite the shell as Electron. Core in CLJS on Node. | Electron boot. | Chromium. | Real Electron builds of 201-290 MB [W] (https://hackernoon.com/six-months-with-tauri-the-benefits-and-the-bill). | Electron signing is well known. | n/a | Reject for the browser itself, for the same engine and data-loss reasons as D. Logseq shows CLJS on Electron works [W] (https://github.com/GQAdonis/logseq/blob/master/CODEBASE_OVERVIEW.md). |
| **G. SWT Browser** (extra) | Eclipse SWT wraps WebKitGTK, WebKit (Mac) and Edge WebView2 (`SWT.EDGE`, since 4.19) [W] (https://bugs.openjdk.org/browse/JMC-7118). | JVM boot. | JVM. | SWT jars + JVM. | Needs `-XstartOnFirstThread` on Mac [I]. | Not tested [U]. | Reject. Same engines, but no access to isolated worlds, reply-capable script handlers, native trusted input or the Mac store identifier. |

### Recommendation: option C, a small native host over a socket

1. **The host is the signed main executable.** It starts first, opens the window and owns the main thread. That keeps today's start-to-first-paint, and the macOS main-thread rule is met for free [I].
2. **The socket seam already exists in shape.**
   - `PagePort` (21 methods, `page_port.zig:189-327`) and `CookiePort` (3, `cookie_port.zig:19-29`) are the exact boundary between the core and the engine [V].
   - The host-side stubs are today's `automation_*_port.zig` adapters with a socket in front.
   - The calls are already blocking, timeout-bounded and off the UI thread, so a socket hop changes no threading rule [V / I].
3. **The inline callbacks stay in the host.** `zb_policy_decide` (144 lines), `zb_load_failure_action` (56) and `zb_ipc_dispatch` (198) are pure and tiny. Keeping them native avoids synchronous IPC inside WebKit policy callbacks [V sizes; I design].
4. **Secrets and spawn stay in the host.**
   - Keychain, libsecret and Credential Manager stay in the host [I].
   - posix_spawn with fd 3, GSubprocess, the reaper and netd spawn stay in the host [I].
   - The core asks the host to "start helper with argv X and env Y". The token never enters the core process [I].
5. **The core is a Clojure native-image binary with no FFI.** That avoids GraalVM's FFM platform gaps and the JVM JIT entitlement.
   - Fallback: if native-image blocks a release, ship a jlink'ed JVM with a JDK 25 AOT cache [W] (https://softwaremill.com/whats-new-in-project-leyden-jep-514-and-jep-515-explained/). That costs startup and an `allow-jit` entitlement.
6. **The core can crash and restart without killing the window** [I].

**Costs of option C**
- There is a new host protocol to design and test, about 30 messages: 21 PagePort + 3 CookiePort + window lifecycle + drawer events + spawn control [I].
- Each automation call pays one extra local socket round trip [I]. That is small next to page work, but measure it in phase 0.
- Two binaries per arch to build, sign and ship [I].

**Mac signing and notarization under option C** [I unless marked]
- **Sign order.** Sign the core binary inside-out with `--options runtime`, like the other Mach-Os (`build-dmg.sh:192-210` [V]).
- **Entitlements.** A native-image binary does not JIT, so it should need no `allow-jit`. Confirm on a Mac.
- **Notarization is not built today.** `build-dmg.sh:9` says "Not notarized (MS9)" [V]. It is needed for any public Mac release, ported or not.
- **jpackage, only if we fall back to a JVM.** It supports `--mac-sign` and `--mac-entitlements` [W] (https://docs.oracle.com/en/java/javase/25/docs/specs/man/jpackage.html). It does not document notarization [W, same source], so notarize with `notarytool` ourselves [I].

**GraalVM native-image limits that matter here**
- Reflection must be removed or declared. Run the native-image agent on the uberjar [W] (https://github.com/lread/clj-graal-docs).
- graal-build-time is incompatible with single-segment namespaces [W] (same source).
- There is no AWT/Swing/JavaFX. Not needed under option C.
- The `macOS x64` build of GraalVM itself must be confirmed for the Intel half of the universal binary [U]. If it is missing, either cross-build is impossible and Intel needs the JVM fallback, or Intel support ends. That is open question Q-P1-2.

---

## 6. Data and contracts that must survive unchanged

Everything here is a test-before-port item: the port must pass a byte-level or behavior-level check for each one.

### 6.1 Automation RPC protocol [V]

**Framing**
- Every message is a 4-byte big-endian length, then the JSON bytes. The maximum is 64 KiB (`automation_server.zig:20,345-363,1634-1640`).
- An oversized frame gets a `-32700` reply, then the connection closes (`:354-359`).
- Both SDKs use this form: Python `struct.pack(">I", ...)` (`sdk/python/src/zigbrowser/client.py:598`) and Node `writeUInt32BE` (`sdk/node/src/client.ts:97`).
- Do **not** port `src/automation_rpc.zig`. It writes newline-terminated responses (`automation_rpc.zig:181,199`) and only the test root imports it (`root.zig:8`).

**Socket path and permissions**
- POSIX: `<XDG_RUNTIME_DIR or /tmp>/zigbrowser-automation-<hex>.sock`. Windows: `%LOCALAPPDATA%\zigbrowser\zigbrowser-automation-<hex>.sock` (`automation_transport.zig:20-53`).
- The socket is owner-only (`automation_server.zig:218,1584`; `owner_only.zig:51-58,88-121`).
- A stale socket file is deleted before bind (`:214`).

**Auth**
- Every frame carries a top-level `"auth"` string. It is compared in constant time through SHA-256 digests (`automation_server.zig:495,1533-1551`).
- The default token is 64 hex characters, written to `<socket>.token` with mode 0600 (`app.zig:683-712`; `automation_server.zig:1562-1580`).
- An empty configured token skips auth (`:495`).

**Envelope**
- Request: `{"jsonrpc":"2.0","method","params"(object),"id"(string|number|null),"auth"}`.
- Batches and bad ids get `-32600`. A missing `id` still gets a reply with `id:null` (`:472-511`).
- Success: `{"jsonrpc":"2.0","result","id"}` (`:594-598`).
- Error: `{"jsonrpc":"2.0","error":{"code","message","data"?},"id"}` (`:1612-1632`).
- Automation error `data` is `{reason?, last_error?, attempts?, sent_chars?, sent?, trace_id(32 hex), command_id("cmd-<n>")}` (`engine.zig:1187-1198,1497-1509`).
- Ids: windows are `"window-N"` and pages are `"page-N"`. The primary window is `window-1` / `page-1` (`automation_server.zig:18,610-616`).

**WebSocket**
- The server detects `GET ` in the first 4 bytes and requires `Authorization: Bearer <token>` (`:347-350,1642-1695`).
- On success it sends one `automation.ready` text frame.
- Payloads over 125 bytes are refused (`automation_websocket.zig:45-52`).

**Methods: 52 in total.** Section numbers below refer to this file.

| Group | Methods | Source |
|---|---|---|
| Telemetry | `telemetry.query` | `automation_server.zig:434-456` |
| DOM (12) | `dom.query`, `click`, `fill`, `type`, `getText`, `getAttribute`, `waitFor`, `press`, `selectOption`, `setInputFiles`, `hover`, `scroll` | `router.zig:6-25,352-372` |
| Page (6) | `page.navigate`, `reload`, `url`, `title`, `evaluate`, `screenshot` | `router.zig:6-25,352-372` |
| Windows (3) | `page.list`, `page.health`, `page.close` | `automation_server.zig:749-863` |
| Recovery | `page.recover` (two-phase, 32-hex incident, 60 s TTL) | `:994-1168` |
| Dialogs (2) | `dialog.get`, `dialog.respond` | `:1175-1279` |
| Cookies (4) | `cookies.getAll`, `set`, `delete`, `import` (4 MiB / 5000 cookies) | `cookie_routes.zig:19-37` |
| Social (4) | `social.login_check`, `rate_status`, `pause`, `set_pacing` | `social.zig:83-96` |
| X (4) | `x.post`, `schedule_post`, `login_check`, `selfcheck` | `x.zig:83-91` |
| LinkedIn (9) | `linkedin.visit`, `connect`, `message`, `like`, `comment`, `follow`, `search`, `extract`, `selfcheck` | `linkedin.zig:276` |
| Instagram (6) | `instagram.follow`, `like`, `comment`, `dm`, `story_view`, `selfcheck` | `instagram.zig:123` |

Pane 2 owns the flow param schemas.

**Queueing**
- Commands queue FIFO per page (`automation/queue.zig:1-8,64-94`).
- `page.list`, `page.health`, `page.recover`, `dialog.*` and `cookies.*` skip the queue (`automation_server.zig:742-747,994-999,1175-1179,1290`).

**Versioning**
- There is no protocol version field beyond `"jsonrpc":"2.0"` [V] (`automation_server.zig:491`).
- Telemetry stamps `api.version = "phase1"` (`telemetry.zig:146-160,304`).
- Recommendation: add no version field during the port, so the bytes stay identical.

### 6.2 Error codes [V]

**JSON-RPC standard codes**
- `-32700` Parse error
- `-32600` Invalid Request
- `-32601` Method not found
- `-32602` Invalid params
- `-32603` Internal error
- `-32000` Authentication failed

Sources: `automation_server.zig`; `engine.zig:26`.

**Automation codes**
- The code is `-32001 - ordinal` and the message is the enum name (`automation/error.zig:3-39`).
- Retryable flags are in `automation/error.zig:47-67`.

| Code | Name | Retryable |
|---|---|---|
| -32001 | element_not_found | yes |
| -32002 | element_not_visible | yes |
| -32003 | element_not_stable | yes |
| -32004 | element_obscured | yes |
| -32005 | element_disabled | yes |
| -32006 | element_not_editable | yes |
| -32007 | navigation_timeout | no |
| -32008 | navigation_failed | no |
| -32009 | action_timeout | no |
| -32010 | platform_rate_limited | yes |
| -32011 | session_invalid | no |
| -32012 | cancelled | no |
| -32013 | dialog_open | no |
| -32014 | recovering | no |
| -32015 | expectation_mismatch | no |

**PortError → RPC mapping** (`engine.zig:1441-1470`)
- `Unsupported` → `session_invalid` with reason `unsupported`.
- `DocumentChanged` / `DocumentReplaced` → `element_not_found` with reason `document_changed`.
- `BadFile` → `-32602` with reason `bad_file`.
- `Timeout` → `action_timeout` or `navigation_timeout`, by command type.
- The other members are listed in that range.

**PagePort errors (15)**: NoPage, Timeout, NavigationFailed, EvalFailed, Cancelled, OutOfMemory, Unsupported, DocumentChanged, DocumentReplaced, BadFile, FilesUnconfirmed, TooLarge, DialogOpen, NoDialog, BeforeUnloadDismissed (`page_port.zig:31-73`). These become host-protocol error names.

**CLI exit codes**: 1 usage, 2 URI/scheme, 3 display, 4 GTK, 5 load failed, 6 snapshot, 7 write, 8 timeout, 9 runtime missing, 10 webview init, 130 cancelled (`errors.zig:22-37`).

**Helper exit reason**: exit code 3 means "sandbox" (`agent_helper.zig:286-291`).

### 6.3 Policy decisions [V]

**Navigation** (`nav_policy.zig:3-38`)
- `Decision {use=0, ignore=1, open_in_subwindow=2}` and `DecisionType {navigation_action=0, new_window_action=1, response=2}`. The numbers are mirrored in the shims (`webkit_shim.c:20-24`, `wkwebview_shim.m:20-25`).
- Rules:
  - New windows → `open_in_subwindow`.
  - Responses → `use`.
  - A navigation from a non-`file:` base → `use`.
  - From a `file:` base, only `file:` URLs inside the base directory are allowed. Paths are normalized and `..` cannot climb (`:71-144`).
- Unknown dtype → `ignore` (`:41`).

**Start URL**: http/https (host required), about and file are allowed. Relative input → `RelativeUri` (`uri.zig:5-23`).

**Load failure** (`load_failure_policy.zig:11-56`)
- `Action {report_routed=0, record=1, exit=2}`.
- Only the primary window's first, non-routed, non-recovery load exits, after a 15 s timer.

**Agent approval** (`agent_approval.zig`)
- **Verbs** (`:20-31`)
  - `click`, `type_text`, `press_key` and `select_option` always need a card.
  - `navigate` and `reload` follow the selector `{yes,no,conditional}` (default `conditional`, `:12-15`).
  - `hover` and `scroll` never need a card (`agent_broker.zig:177-183`).
- **Mode** (`:42-46`): `{interactive, headless, full_automation}`.
- **Selector store** (`:49-179`)
  - Path: `<agent_home>/settings/navigate_approval`.
  - Content is exactly `yes\n`, `no\n` or `conditional\n`. The file is 0600, the directory 0700, owner-checked, opened with no symlink following.
  - An unreadable store means `yes` (fail closed).
- **Cards**: TTL is 120,000 ms (`:182`). Outcomes are `waiting, approved, denied, expired, cancelled` (`:188`).
- **Card endings** (`agent_broker.zig:102`): `done, failed, changed, crashed, denied, expired, cancelled, revoked`. The fixed user texts are in `agent_broker.zig:66-70,104,106`.
- **Broker deadline**: `B = H - min(5, H/4)` with H = 120 s (`agent_broker.zig:61-64`).

**Agent tools**
- The prefix is `mcp__zigbrowser__`. There are 14 tools.
  - Read-only: `window_info`, `query`, `get_text`, `get_attribute`, `wait_for`, `screenshot`.
  - Gated: `click`, `type_text`, `press_key`, `select_option`, `navigate`, `reload`.
  - Act with no card: `hover`, `scroll`.
- Strict argument shapes are in `agent_broker.zig:41-48,113-120,129-218`.
- A model-supplied `window_id` is refused (`:444`).
- Engine errors are redacted to `the browser could not do that (<name>, <code>)` (`:935-951`).

**Owner-only rule**
- POSIX: files and sockets 0600, directories 0700, no symlink following.
- Windows: protected DACL `D:P(A;;FA;;;<sid>)` (`owner_only.zig:51-58,88-121`).

**Network egress** (Python side; pane 2 owns it)
- Chat egress allows only `api.anthropic.com` (`agent/host/zb_agent_host/sandbox.py:56`).
- Login egress adds `platform.claude.com` (`:61`).

### 6.4 On-disk formats [V unless marked]

**Profile directory**
- Default (Linux only): `$XDG_DATA_HOME/zigbrowser/profile`, else `~/.local/share/zigbrowser/profile` (`cli.zig:259-265`, `xdg.zig:7-14`, `profile_step.zig:40-48`).
- Mac and Windows bind only an explicit `--profile-dir` (`profile_step.zig:33-37,56-57`). Their default path is [U].
- **Linux engine files**: `<profile>/data`, `<profile>/cache`, `<profile>/cookies.sqlite`, directory mode 0700 (`webkit_shim.c:5108-5138`).
- **Mac — critical.**
  - The store is `WKWebsiteDataStore dataStoreForIdentifier:` with a UUID.
  - The UUID is the first 16 bytes of SHA-256 over the normalized absolute profile path, with RFC 4122 v4 bits set (`wkwebview_shim.m:3013-3023,3040-3092`).
  - It needs macOS 14 or later. On 13 it falls back to the default store (`:3085-3091`).
  - Any change to path normalization loses the user's cookies and site data.
- **Windows engine store**: `<abs profile>\WebView2` (`webview2_shim.cpp:2386`).
- **Our JSON files**
  - `<profile>/automation-pacing.json`: `{"version":1,"day","social":P,"x":P}`, where P is `{actions_today,daily_cap,min_delay_ms,max_delay_ms}`. The schema is strict and the file is at most 4096 bytes (`automation/pacing_store.zig:22-43`).
  - `<profile>/agent-drawer.json`: `{"version":1,"x","y"}` with values in [0,1], at most 1024 bytes (`agent_drawer.zig:533-565`).
- **Atomic write**: `<path>.tmp-<16hex>`, created exclusive with mode 0600, then fsync, rename, then fsync of the directory. Windows skips the directory fsync (`atomic_file.zig:16-41`).

**Agent home**
- Path: `<XDG_DATA_HOME or ~/.local/share>/zigbrowser/agent-home` (`agent_setup.zig:14,339-341`; Mac builds the same path in `agent_secrets_window_mac.m:426-428`). The Windows path is [U].
- **Owner lock**: `<home>/.zb-owner.lock`, opened `O_NOFOLLOW` with mode 0600, then `flock(LOCK_EX|LOCK_NB)` (`agent_home_lock.c:15-72`).
- **Layout** (Python writes it; pane 2 owns it)
  - The marker `.zb-agent-home` holds `{"layout": 2}` (`agent/host/zb_agent_host/setup.py:66,529`).
  - `current` is a symlink to `dist-<n>` (`setup.py:664-674`).
  - `.claude` → `current/.claude` and `runtime` → `current/runtime` (`setup.py:70`).
  - The state dirs are in `setup.py:72-73` and `sandbox.py:46`.
- **Runtime check**: `runtime/host.json` vs `runtime.json` on `lock_sha256` and `host_sha256` (`agent_helper.zig:243-262`).
- **Config manifest**: `runtime/config-manifest.json` is re-hashed per session (`agent_config_check.zig`).

**Token storage.** The identifiers must match exactly.

| Store | Identifier | Source |
|---|---|---|
| Token shape | `^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$`, trimmed | `agent_secrets_shape.zig:9-35` |
| Linux Secret Service | schema `dev.zigbrowser.ClaudeAgentToken`, attr `account=default`, label `zigBrowser Claude Agent token` | `agent_secrets.c:33-39` |
| Linux file | `<agent-home>/secrets/claude-token` (hyphen); dir 0700, file 0600, owner-checked | `agent_secrets.zig:75-128,176-206` |
| macOS Keychain | generic password, service `dev.zigbrowser.ClaudeAgentToken`, account `default`, login keychain | `agent_helper_mac.h:14-15`, `agent_secrets_mac.m:265-272` |
| macOS dev file | `<agent-home>/secrets/claude_token` (underscore), only in `mac_unsandboxed_dev` builds | `agent_secrets_mac.m:23-31` |
| Windows | Credential Manager GENERIC, target `zigBrowser/ClaudeAgentToken/default`, persist LOCAL_MACHINE; optional DPAPI file (path [U]) | `agent_secrets_win.cpp:22-36,74,95` |

**Token delivery**
- The app writes the token once to the helper's fd 3, then closes and wipes it (`agent_helper.c:730,746-759`; Mac socketpair, `agent_token_fd_mac.c:94-132`).
- The sign-in helper returns the new token on fd 4 (`agent/host/zb_agent_host/login.py:59,496`).

**Run ledger**
- Path: `<runtime_dir>/zigbrowser-agent-runs.json`, lock `.zigbrowser-agent-runs.lock` (`agent_run_ledger.zig:1,224-261`). What `runtime_dir` resolves to is [U].
- Format: `{"schema_version":2,"runs":[{basename,dev,ino,uid,mode,pid,start_kind,start_sec,start_usec,state}]}`.
- Limits: at most 256 entries and 64 KiB. Strict schema (`:13-49`).
- Recovery is unarmed in production (`agent_run_recovery.zig:328-334`).

**Build-time config**: `zigbrowser.json` holds only `{"url": ...}` and is baked in at build time (`config_schema.zig:4-40`, `build.zig:142-155`).

### 6.5 Agent helper wire protocol [V]

- **Framing**: NDJSON over stdin/stdout. Every frame is `{"v":1,"seq":N,"type":...}`. Helper→app lines are capped at 256 KiB (`agent_protocol.zig:11,157-161`).
- **App→helper frames**: `hello`, `open_session`, `prompt` (≤64 KiB text), `interrupt`, `end_session`, `shutdown`, `tool_result` (`agent_helper.zig:190-226`, `agent_frames.zig:177-197`).
- **Helper→app frames**: `ready` (`tool_deadline_s` must be 120, `route` "R1"), `session_opened`, `assistant_delta` (≤16 KiB), `assistant_message` (≤256 KiB), `tool_call`, `result`, `error`, `session_ended`, `reply_capped` (`agent_protocol.zig:35-45,228-302`).
- **Error codes**: `auth, busy, overloaded, protocol, overflow, sdk, sandbox`.
- **Strict validation order**: envelope, type, schema (exact keys), session, seq, prompt, cap, tool id (`:152-193`).
- **Rejections**: three rejected frames restart the helper (`agent_helper.c:73-74,491-505`).
- **Login frames**: `auth_url`, `need_code`, `done`, `error` / `start`, `code`, `cancel`, each at most 8 KiB (`agent_protocol.zig:408-524`).
- **Authorize URLs**: exactly two are accepted (`agent_auth.zig:36-94`).
- **Auth window host allowlist**: `agent_auth.zig:208-218`.

---

## 8. Phases, order and effort

**Effort scale.** One agent-day is one focused agent working one day with review.

**Calibration.**
- The current product took about 5 months and 2,964 commits with multi-agent teams [V].
- About 17,100 Zig lines move (section 2).
- Pane 2 adds flows, page script, drawer UI and SDK effort in their sections. The estimates for phases 4 and 5 below will be reconciled with theirs in the merge.

| # | Phase | What ships | Agent-days | Confidence |
|---|---|---|---|---|
| 0 | **Spike and decision.** Host-protocol prototype on Linux for 3 PagePort methods (`evalJson`, `navigate`, `url`). A Clojure core native image answers `page.url` through it. Measure start time, RSS, binary size and round-trip latency. Build and sign the core on both Macs (arm64 + x86_64) to confirm GraalVM availability. | A measured go/no-go memo. No user change. | 6-10 | Medium |
| 1 | **Contract harness.** Turn the SDK tests and the automation e2e tests into a black-box suite that runs against any core over the socket. Add golden byte fixtures for framing, errors and on-disk files (section 6). Pane 2's section 7 picks the tests. | A suite green on today's Zig core. | 6-10 | Medium |
| 2 | **Native host protocol, Linux.** Put the existing GTK PagePort and CookiePort behind a socket server inside today's binary, behind a flag such as `--core=external`. Window lifecycle, dialogs, screenshots, native input. | Linux dev build where an external process can drive the page through PagePort. | 10-15 | Medium |
| 3 | **Clojure automation core.** Transport, auth, framing, router, engine, queue, errors, telemetry, cookie routes, window/health/recover/dialog routes. | Linux build where the Clojure core passes the phase-1 suite, behind a flag. | 25-35 | Low-medium |
| 4 | **Flows and sequences** (pane 2 scope). Pacing store, social, X, LinkedIn, Instagram, sequences client; automation.js from CLJS. | All 52 methods on the Clojure core. | per pane 2 (placeholder 15-25) | Low |
| 5 | **Agent core.** Broker, tools, approval and selector store, frame validator, helper controller state machine, login flow, run ledger. The host keeps spawn, fd 3/4 and secrets. | Linux drawer works end-to-end on the Clojure core. | 20-30 | Low-medium |
| 6 | **macOS host and release.** Mac PagePort stub over the socket, universal core binary (lipo), inside-out codesign with hardened runtime, **notarization** (new work), DMG upgrade test that keeps cookies (UUID store) and Keychain token. | Signed, notarized Mac DMG on the Clojure core. | 12-20 | Low-medium |
| 7 | **Windows host.** Resume from the paused Windows branch. WebView2 PagePort stub over the socket, MSI with core binary, Credential Manager path. | Windows MSI on the Clojure core. | 12-20 | Low (Windows PagePort is partial today: `automation_wv2_port.zig` win branch header says only routed commands are done) |
| 8 | **Remove the Zig core.** Delete the moved Zig modules and their Zig tests once the contract suite and the platform e2e tests are green on all shipping OSes. | One core. | 4-6 | Medium |

**Totals (pane 1 view)**
- Total: about 110-190 agent-days, including the phase 4 placeholder.
- Confidence: low-medium.
- Phases 0-1 are the only ones I would commit to before the phase 0 numbers exist.

**What can run in parallel** [I]
- Phase 2 (host) and phase 3 (core) can run in parallel once the phase 0 protocol is frozen.
- Phases 6 and 7 can run in parallel once phase 5 lands.

**What ships to users** [I]
- Nothing changes for users until phase 6, the first platform release on the new core.
- Linux is dev-only per the owner (project memory "Platform targets and voice"), so phases 2-5 are internal.

---

## Pane 1 open questions (for merge into section 9)

1. **Q-P1-1. Keep Zig for the native host glue, or rewrite it in C/ObjC/C++?**
   - The host keeps about 4,400 lines of Zig glue: PagePort adapters, policies, drawer geometry and config apply.
   - Recommendation: keep Zig for the host during the port. Rewriting working glue adds risk and no user value. Revisit after phase 8.
2. **Q-P1-2. If GraalVM native-image is not available for macOS x64, what happens to Intel Macs?**
   - Recommendation: confirm in phase 0.
   - If it is missing, ship a jlink'ed JVM core for Intel only, with a JDK 25 AOT cache and `allow-jit`.
   - Or set an end date for Intel support.
   - Do not block arm64 on it.
3. **Q-P1-3. Accept a second process (option C) instead of one JVM process (option A)?**
   - Recommendation: yes. It keeps first paint fast and keeps the token out of the core.
   - It also avoids the FFM gaps, and a core crash does not close the user's windows.
4. **Q-P1-4. Notarization is missing today and is required for a public Mac release with or without the port. Do it before the port?**
   - Recommendation: yes, do it first on the Zig build (MS9).
   - Then the port's phase 6 only adds one more binary to an already working notarized pipeline.
5. **Q-P1-5. May the port change any wire or disk contract (for example, add a protocol version field)?**
   - Recommendation: no. Freeze section 6 byte-for-byte until phase 8 is done.
   - Then version any change with a migration and a test.
