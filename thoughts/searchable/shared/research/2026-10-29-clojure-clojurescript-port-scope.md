---
date: 2026-10-29
researchers: pane 1 / CopperLynx (native and platform side, merge owner); pane 2 / TealCastle (product and UI side, reviewer)
git_commit: 14e0012f (base); parts at c3d0c7f2 (part 1) and 50e70a79 (part 2)
branch: zb-clojure-scope-2026-10-29-10-21
topic: "Scope of a zigBrowser port to Clojure and ClojureScript"
tags: [research, scope, clojure, clojurescript, port, graalvm, native-host, contracts]
status: merged, awaiting pane 2 review
---

# Scope: porting zigBrowser to Clojure and ClojureScript

This is research and writing only. No product code was changed or built.

**Sources and part files**
- Part 1: `thoughts/searchable/shared/research/2026-10-29-clojure-scope-part-1.md`. Native side, sections 1, 3, 6, 8.
- Part 2: `thoughts/searchable/shared/research/2026-10-29-clojure-scope-part-2.md`. Product side, sections 4, 5, 7, 9.
- Both part files stay in git as the working record.

**How to read the labels.** Part 1 uses short tags and part 2 uses words. They mean the same thing.

| Tag | Word | Meaning |
|---|---|---|
| [V] | verified | Read in the code at the cited line, or seen by a read-only command. |
| [I] | inferred | Follows from verified facts. Not tested. |
| [U] | unknown | Not found or not checked. |
| [W] | web | A web fact; the URL sits next to it. "web (helper)" means a research helper fetched it. |

- Paths are relative to the repo root at `14e0012f`.
- "(win branch)" means the paused branch `zb-windows-impl-2026-10-22-15-03`. It was read with `git show`, never checked out.
- A line count is `wc -l` unless it says cloc.

---

## 1. Summary

### What a port means

zigBrowser today has five layers [V].
1. **A Zig core.** The app, CLI, automation server, router and engine, the site flows, the agent broker, the policies and the on-disk stores.
2. **Three native web-engine shims behind one C header.** `src/webkit_shim.h` holds 79 `zb_*` declarations. The engines are WebKitGTK on Linux, WKWebView/AppKit on Mac and WebView2 on Windows.
3. **Native UI.** The agent drawer, the Secrets window and the auth window are native widgets, not HTML, on purpose (`src/agent_drawer.h:4-6`, `docs/agent-drawer.md:92-94`).
4. **An injected page script.** `src/automation_script/automation.js`, 1,567 lines of JavaScript.
5. **A Python agent host** around the Claude Agent SDK. It is 8,701 lines with 20,339 lines of tests.

A port cannot mean "everything in Clojure."
- **The engines must stay native.** The web engines and their shims are C, Objective-C and C++ against OS frameworks.
- **The Agent SDK exists only for Python and TypeScript** [W] (https://code.claude.com/docs/en/agent-sdk/overview).
- **So a realistic port replaces the Zig core with Clojure** and leaves the rest where it is.

**How much moves**
- About 17,100 lines of Zig move from pane 1's scope, and about 5,000 more from the flows (part 2).
- About 24,600 lines of C, Objective-C, C++ and headers stay native.
- These are `wc -l` sums [V].

**ClojureScript has a small role in the recommended plan.**
- The page script stays JavaScript.
- The drawer stays native.
- The SDKs stay Python and TypeScript.
- The dashboard is unused and is dropped.
- ClojureScript becomes useful only if the owner later chooses an HTML drawer, a new dashboard or a Clojure SDK (section 4, questions Q2, Q5, Q6).

### Recommended target architecture

The recommendation is **two processes per OS**, plus the unchanged Python helper.

```
 ┌──────────────── native host (signed main executable) ────────────────┐
 │ main thread + UI loop · web-engine shim · browser/drawer/Secrets/auth │
 │ windows · Keychain/libsecret/CredMan · spawn with fd 3/4 · reaper     │
 │ inline policies: zb_policy_decide, zb_load_failure_action,            │
 │ zb_ipc_dispatch · drawer geometry (24 zb_drawer_* exports)            │
 └───────────────▲──────────────────────────────────────────────────────┘
                 │ local socket, 4-byte length + JSON (same framing as today):
                 │ PagePort (21) + CookiePort (3) + windows, drawer events, spawn control
 ┌───────────────┴─────── Clojure core (GraalVM native image, no FFI) ───┐
 │ CLI · automation server (JSON-RPC, auth, queue, router, engine, errors,│
 │ telemetry) · cookie routes · site flows + pacing · agent broker, tools,│
 │ approval · helper frame codec · run ledger · JSON stores              │
 └───────▲─────────────────────────────────────────▲─────────────────────┘
         │ automation socket (unchanged)            │ NDJSON frames (unchanged)
   Python / Node SDKs, user scripts         Python agent host (unchanged)
```

**Why this shape and not one JVM process with Panama FFI** (section 3)
- **The UI loop must own the main thread.** That is a hard rule for AppKit on macOS [V/I].
- **The shims call back into the core inline.** They call the core's exports synchronously (`src/webkit_shim.h:435-443`) [V].
- **GraalVM's FFM support has a Mac Intel gap.** It documents FFM downcalls and upcalls for Linux x64, Windows x64, macOS AArch64 and Linux AArch64, but not macOS x64 [W] (https://www.graalvm.org/dev/reference-manual/native-image/native-code-interoperability/ffm-api/). The product ships a universal arm64 + x86_64 Mac build (`packaging/macos/build-dmg.sh:127-134`) [V].
- **A socket avoids all three problems.** It also keeps the Claude token out of the core process and lets the core crash without closing windows [I].
- **The seam already exists in shape.** It is the `PagePort` vtable (21 methods, `src/automation/page_port.zig:189-327`) and the `CookiePort` vtable (3 methods, `src/automation/cookie_port.zig:19-29`) [V].

### Top 5 risks

1. **Most of the hard code stays native, so the port moves less than it seems.**
   - About 24,600 native lines stay [V].
   - The hardest past bugs were in threading, WebKit and AppKit, and those stay where they are [I].
   - The gain is a Clojure core and Clojure flows, not fewer languages: Clojure, C/ObjC/C++, Python and JS all remain [I].
2. **Contract drift and lost behaviour break users silently.**
   - The automation wire bytes, the 15 automation error codes and the macOS WKWebsiteDataStore UUID derivation must be byte-equal (section 6). So must the Keychain item names, the run-ledger schema, and the many incident fixes in the flows (`src/flow_steps.zig:17-26`).
   - If any of these drift, SDK users break, or Mac users lose cookies and their saved token [I].
3. **Startup, memory and size.**
   - A plain JVM adds seconds of startup. A Clojure uberjar is "not under 2 seconds" in old community reports [W] (https://ask.clojure.org/index.php/8292/has-anyone-benchmarked-cold-start-times-for-clojure-lambda).
   - Native-image fixes startup but adds a build per OS and arch. GraalVM for macOS x64 is not confirmed [U].
   - The Mac bundle already carries about 632 MB of dependencies (`thoughts/searchable/shared/research/2026-10-20-ms5-deps-cli-macos-recommendation.md:90-91`) [V].
4. **Mac signing and notarization.**
   - Today the DMG is ad-hoc signed by default and not notarized (`packaging/macos/build-dmg.sh:9,28-29`) [V].
   - Every new Mach-O must be signed inside-out with hardened runtime.
   - A HotSpot JVM would likely need `com.apple.security.cs.allow-jit` [I]. The project deliberately holds that entitlement out (`packaging/macos/entitlements.plist:16-23`) [V].
5. **Test loss against a moving product.**
   - The repo has 2,964 commits since 2026-05-30 [V].
   - About 30,468 lines of top-level Zig unit tests do not carry over (part 2, section 7) [V count].
   - Some tests check source text, not behaviour (`tests/automation/js_contract_test.zig`) [V].
   - The Mac track is active and the Windows track is paused.
   - The port only stays safe behind the existing black-box tests as contract tests, one layer at a time, with both cores runnable side by side (sections 7 and 8).

**Risks the recommendation avoids (they return if the owner picks the other option)**
- **Drawer security.** A web drawer reverses `docs/agent-drawer.md:92-94` (Q2).
- **No JVM Agent SDK.** A Clojure agent host would have to own the CLI's stream-json protocol (Q4).
- **ClojureScript `:advanced` renaming.** It would break page-script wire field names (Q3).

### Merge reconciliation (pane 1 decided; pane 2 to confirm in review)

Three files had different targets in the two parts. They are listed once in section 2, as **stays native**, for these reasons.
- **`src/agent_drawer.zig`** (part 2 said `.cljc`). It exports 24 `zb_drawer_*` functions that the GTK, AppKit and Win32 drawer code calls inline (`build.zig:5506-5515`, `src/agent_drawer.zig:630-639`, `src/agent_drawer_mac_panel.m:26,485`) [V]. A socket hop inside a gesture or layout callback is not acceptable [I]. Part 2's phase P3 (drawer logic, 2-3 days) is therefore folded out of section 8.
- **`src/load_failure_policy.zig`** (part 2 said `.cljc`). `zb_load_failure_action` and `zb_load_exit_timer_armed` are exported and called inline by the shims (`load_failure_policy.zig:50-56`, `webkit_shim.h:437-440`) [V].
- **`src/profile_step.zig`** (part 2 said Clojure). It binds the store through the shim's `zb_app_set_profile_dir` before the first window (`profile_step.zig:21`) [V]. In the host design that happens before the core is up [I].

---

## 2. Inventory of every module

Subsections 2a-2e are pane 1's modules (native and platform side). Subsections 2f-2k are pane 2's modules (product and UI side). `src/profile_step.zig`, `src/load_failure_policy.zig` and `src/agent_drawer.zig` appear once, in 2a, 2b and 2d, as `stays native` (see the reconciliation in section 1).

`Lines` is `wc -l` at `14e0012f`. Targets are `Clojure (JVM)`, `ClojureScript`, `babashka/nbb`, `stays native`, `drop`, or `keep as is (<language>)` for code that should not move at all (added by pane 2 for the Python host, the JS page script and the SDKs). "Clojure (JVM)" here means Clojure source compiled to a native-image binary in the recommended design. The descriptions come from each file's header comment [V] unless marked otherwise.

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



Sizes are `wc -l` at 14e0012f [verified]. "Label" is the label of the
target choice, not of the size.

### 2f. Site flows, pacing and sequences

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/flow_steps.zig | Zig | 361 | Shared step helpers and the duck-typed runner contract for all site flows. | Clojure (JVM), as `.cljc` | inferred |
| src/linkedin.zig | Zig | 875 | LinkedIn flows (visit, connect, follow, message, like, comment, extract) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/instagram.zig | Zig | 452 | Instagram flows (follow, like, comment, dm, story view) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/x.zig | Zig | 401 | X flows (post, schedule post, login check, selfcheck) and their selector table. | Clojure (JVM), as `.cljc` data + steps | inferred |
| src/social.zig | Zig | 130 | social.* verbs: login check, rate status, pause, set pacing, with their wire shapes. | Clojure (JVM), as `.cljc` | inferred |
| src/automation/flow_runner.zig | Zig | 776 | Runs each flow step as a router command under one root span, with approvals and rate-limit scans. | Clojure (JVM) | inferred |
| src/automation/social_routes.zig | Zig | 389 | Routes social.* methods from the socket to src/social.zig with real ports. | Clojure (JVM) | inferred |
| src/automation/social_flow_routes.zig | Zig | 702 | Routes linkedin.* and instagram.*: strict params, login gate, pacing, then the flow. | Clojure (JVM) | inferred |
| src/automation/x_routes.zig | Zig | 295 | Routes x.* methods to src/x.zig. | Clojure (JVM) | inferred |
| src/automation/pacing.zig | Zig | 144 | The daily-cap and delay rate limiter. | Clojure (JVM), as `.cljc` | inferred |
| src/automation/pacing_store.zig | Zig | 115 | Saves and loads `<profile>/automation-pacing.json` atomically. | Clojure (JVM) | inferred |
| src/automation/bezier.zig | Zig | 87 | Cubic Bézier mouse paths. | Clojure (JVM), as `.cljc` pure math | inferred |
| src/automation/gaussian.zig | Zig | 51 | Normal-distribution samples for typing delays. | Clojure (JVM), as `.cljc` pure math | inferred |
| src/automation/stealth.zig | Zig | 255 | Behaviour-simulation telemetry events and their attributes. | Clojure (JVM) | inferred |
| src/sequences.zig | Zig | 939 | HMAC-signed HTTP client for an external "sequences" service (`/api/v1/automation`). Not used by the app. | drop (or Clojure (JVM) later, see Q5) | verified (not used), inferred (target) |

### 2g. Page script and dashboard

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/automation_script/automation.js | JavaScript | 1,567 | The injected page script: selectors, actionability checks, input acks, waits, rate-limit scan, exposed as `__zbAutomation`. | keep as is (JavaScript) | inferred |
| src/automation_script/js_embed.zig | Zig | 1 | Embeds automation.js into the binary (`@embedFile`). | Clojure (JVM): load as a classpath resource | inferred |
| src/dashboard/content/index.html | HTML + JS | 387 | A sequences dashboard page that calls `zbHost` message handlers. | drop (or ClojureScript later, see Q5) | verified (not used), inferred (target) |
| src/dashboard/ipc.zig | Zig | 468 | Mock IPC answers for the dashboard (all `mock*` functions). | drop | verified (mock only) |
| src/dashboard/embed.zig | Zig | 1 | Embeds the dashboard HTML. | drop | inferred |

### 2h. Drawer UI

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| src/agent_drawer.c / .h | C (GTK) | 1,832 / 32 | Linux drawer: icon, docked panel, message list, input row, all native GTK widgets. | stays native (see Q2) | verified (native), inferred (target) |
| src/agent_drawer_mac_host.m / src/agent_drawer_mac.h | Objective-C (AppKit) | 1,064 / 49 | Mac content view that owns the page WKWebView and the docked panel. | stays native | inferred |
| src/agent_drawer_mac_panel.m | Objective-C (AppKit) | 1,439 | Mac drawer panel with AppKit views. | stays native (see Q2) | inferred |
| Windows drawer, inside src/webview2_shim.cpp (branch zb-windows-impl-2026-10-22-15-03) | C++ (Win32) | part of 3,596 | Win32 drawer with a read-only plain-text RichEdit bubble (`webview2_shim.cpp:7,120,1990`). | stays native (see Q2) | verified (exists), inferred (target) |

### 2i. Python agent host (agent/host/zb_agent_host)

All rows: language Python. Target for every row: **keep as is (Python)**,
label inferred, for the reasons in section 5. The sandbox rows are listed
for completeness; pane 1 owns the sandbox interop choice.

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| __main__.py | Python | 35 | Command dispatcher (`contract-config`, `provision-runtime`, `launch`, `chat`, `setup`, `probe-r1`, `login`). | keep as is (Python) | inferred |
| __init__.py | Python | 3 | Package marker and version. | keep as is (Python) | inferred |
| chat.py | Python | 429 | The drawer's helper: one ClaudeSDKClient per drawer session, frames in and out. | keep as is (Python) | inferred |
| bridge.py | Python | 239 | Browser tools as an in-process MCP server; asks the app over stdout and waits on stdin. | keep as is (Python) | inferred |
| frames.py | Python | 53 | NDJSON frame encoder and emitter. | keep as is (Python) | inferred |
| contract.py | Python | 115 | P0 contract command: one real SDK turn with the token on route R1. | keep as is (Python) | inferred |
| options.py | Python | 144 | The single builder of the helper's environment and every ClaudeAgentOptions. | keep as is (Python) | inferred |
| token.py | Python | 174 | The token's two hops: app to helper (fd 3) and helper to CLI (route R1). | keep as is (Python) | inferred |
| redact.py | Python | 495 | Scrubs saved transcripts of echoed credentials. | keep as is (Python) | inferred |
| login.py | Python | 588 | One-shot sign-in helper (`claude setup-token` on a pty, token on fd 4). | keep as is (Python) | inferred |
| setup.py | Python | 1,027 | `--agent-setup`: builds the agent home and selects the token route. | keep as is (Python) | inferred |
| provision.py | Python | 77 | Runtime provisioning used by the contract tests. | keep as is (Python) | inferred |
| launch.py | Python | 348 | What the app spawns: builds the sandbox argv and execs it. | keep as is (Python) | inferred |
| launcher.py | Python | 35 | Portable launcher contract (Windows plan). | keep as is (Python) | inferred |
| files.py | Python | 150 | Atomic file writes and safe tree removal. | keep as is (Python) | inferred |
| hook_run.py | Python | 310 | Runs one hook in its own PID and network namespaces. | keep as is (Python) | inferred |
| netd.py | Python | 907 | The agent's only network (an allowlisting proxy daemon). | keep as is (Python) | inferred |
| relay.py | Python | 312 | TCP-to-Unix-socket relay to netd. | keep as is (Python) | inferred |
| route_probe.py | Python | 381 | Setup's R1 probe inside setup's sandbox. | keep as is (Python) | inferred |
| probe.py | Python | 118 | Contract-only probe for the outer seccomp filter. | keep as is (Python) | inferred |
| sandbox.py | Python | 504 | The Linux bwrap argv every helper, CLI and hook runs under. | keep as is (Python) | inferred |
| seccomp.py | Python | 62 | The outer seccomp filter. | keep as is (Python) | inferred |
| sandbox_macos.py | Python | 775 | macOS Seatbelt profile generator. | keep as is (Python) | inferred |
| seatbelt_rules.py | Python | 143 | Curated Seatbelt read and Mach-service rules. | keep as is (Python) | inferred |
| proc_darwin.py | Python | 198 | macOS process inspection (libproc, sysctl). | keep as is (Python) | inferred |
| parent_watch.py | Python | 329 | Makes setup die with the browser on macOS. | keep as is (Python) | inferred |
| owned_group.py | Python | 254 | Runs setup's sandboxed work as one owned process group. | keep as is (Python) | inferred |
| platforms.py | Python | 18 | Makes POSIX-only seams fail closed on Windows. | keep as is (Python) | inferred |
| wincontain.py | Python | 248 | Windows containment branches, pure and testable on Linux. | keep as is (Python) | inferred |
| wincontain_win32.py | Python | 211 | Live Windows Job Object launch backend. | keep as is (Python) | inferred |
| agent/host/pyproject.toml + uv.lock | TOML | 19 + lock | Pins `claude-agent-sdk==0.2.165` and, on macOS, `cryptography==48.0.1`. | keep as is | verified (pins) |

### 2j. SDKs

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| sdk/python/src/zigbrowser (client, errors, events, types, __init__) | Python | 818 | Python client for the automation socket (sync and async), 38 RPC methods. | keep as is (Python) | inferred |
| sdk/node/src (client, methods, errors, index) | TypeScript | 784 | Node client for the automation socket, 51 method names in methods.ts. | keep as is (TypeScript) | inferred |
| sdk/cli/src/zigbrowser_cli | Python (click) | 80 | `call` and `trace` commands on top of the Python SDK. | keep as is (Python); optional babashka copy later | inferred |
| (new) sdk/clojure | Clojure `.cljc` | 0 | Optional Clojure and ClojureScript client of the same socket. | Clojure (JVM) + ClojureScript, later (Q6) | inferred |

### 2k. Tests and test tooling

| Path | Language | Lines (wc -l) | What it does | Target | Label |
|---|---|---|---|---|---|
| tests/*.zig (top level, 134 files) | Zig | 30,468 | White-box unit tests of Zig modules. | rewrite as clojure.test for ported modules; keep for native code | inferred |
| tests/*.c (12 files) | C | 1,159 | Tests of the C run ledger, reaper and secrets dlopen. | stays native | inferred |
| tests/automation/ (9 files) | Zig | 1,775 | Fakes, math tests and source-grep tests of automation.js. | rewrite (math); drop (source-grep, see section 7) | inferred |
| tests/e2e/*.py (257 files) + 18 other | Python, sh, HTML | 61,268 (py) | Black-box tests that launch the binary and drive it, many over the socket. | keep as is (Python): contract tests | inferred |
| tests/mac/ (149 files) | sh, Python, ObjC, C | 33,459 | Mac build, bundle, DMG, Keychain and live tests over ssh. | keep, re-point at the new artifact | inferred |
| tests/windows/ (43 files) + Windows branch additions | Python, sh, PowerShell | 12,226 | Windows gate and live tests. | keep, re-point at the new artifact | inferred |
| tests/fixtures/ (59 files) | HTML, JSON, Python | 3,323 | Site fixtures (linkedin, instagram, x), automation pages, `sdk_wire_cases.json`. | keep as is: shared contract data | verified (contents) |
| tests/dashboard/, tests/sequences/ | Zig | 398 / 983 | Tests of the unused dashboard and sequences client. | drop with their modules | inferred |
| tests/guest, kill_group, manual, snapshots, spikes | mixed | 544 / 472 / 2,537 / 91 / 100 | VM build helper, process-group tests, manual scripts, one snapshot, one spike. | keep as is | inferred |
| agent/host/tests/ (92 files) | Python | 20,339 | Agent host unit and contract tests. | keep as is (Python) | inferred |
| sdk/python/tests, sdk/node/tests, sdk/cli/tests | Python, TypeScript | 747 / 676 / 118 | SDK tests against a mock Unix-socket server. | keep as is | inferred |
| e2e/*.spec.ts + playwright.config.ts + package.json | TypeScript | 381 + 79 + 26 | Playwright tests of automation.js on Chromium, Firefox and WebKit. | keep as is (TypeScript) | inferred |


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
- The `macOS x64` build of GraalVM itself must be confirmed for the Intel half of the universal binary [U]. If it is missing, either cross-build is impossible and Intel needs the JVM fallback, or Intel support ends. That is open question Q10.


---

## 4. ClojureScript targets

Build tool for everything below: **shadow-cljs**. npm shows 3.5.8,
published 2026-10-26 (web, checked:
https://registry.npmjs.org/shadow-cljs). Its guide documents the
`:browser`, `:esm`, `:node-script`, `:node-library`, `:npm-module`,
`:browser-test`, `:node-test` and `:karma` targets (web (helper):
https://shadow-cljs.github.io/docs/UsersGuide.html). ClojureScript itself
is 1.12.145 (web (helper): https://github.com/clojure/clojurescript/releases).

### 4.1 The page script (automation.js)

What it is today [verified]:

- One IIFE that defines `globalThis.__zbAutomation`, non-writable and
  non-enumerable (`src/automation_script/automation.js:1537-1567`).
- One entry point, `handle(json)`, that switches on `command.op`
  (`automation.js:112-125`, `235-275`). Ops: query, getText, getAttribute,
  click, fill, type, press, selectOption, chooseFiles, hover, scroll, locate,
  measure, waitFor, rateLimitScan, documentToken.
- Results are `{ok, value, telemetry}` or `{ok:false, error, retryable,
  data, telemetry}` (`automation.js:1376-1398`).
- It counts trusted input events so the native side knows when input has
  landed (`automation.js:21-62`), and it reports navigations to the shell
  through the `zbNavigation` message handler (`automation.js:83-104`).
- It is injected at document start into a named private world,
  `zigbrowser-automation` (`src/webkit_shim.h:140`): on Linux with
  `webkit_user_script_new_for_world` (`src/webkit_shim.c:1899-1908`), on Mac
  with a `WKUserScript` in a `WKContentWorld` (`src/wkwebview_shim.m:640-647`),
  on Windows with CDP `Page.addScriptToEvaluateOnNewDocument` and a
  `worldName` (Windows branch `src/webview2_shim.cpp:2558-2566`).
- The Zig side embeds it with `@embedFile` (`src/automation_script/js_embed.zig:1`)
  and hands it to the shim (`src/automation_gtk_port.zig:38`,
  `src/automation_macos_port.zig:43`).

Options:

| Option | Gain | Cost | Label |
|---|---|---|---|
| A. Keep plain JS (recommended) | Zero risk. Same file on all 3 engines. Playwright tests keep working. | One more language in the repo. | inferred |
| B. Full ClojureScript, shadow-cljs `:browser` target, one module, `:advanced` | Clojure syntax and shared `.cljc` selector parsing with the JVM core. | Adds the cljs.core runtime to every document at document start (size and parse time not measured: unknown). `:advanced` renames properties, so every wire field (`op`, `selector`, `ok`, `telemetry`...) must use string keys or `^js` hints, or the protocol breaks. Event-order details (submit before keyup, navigate before input) must be re-proven on 3 engines. | inferred |
| C. Squint (a light ClojureScript dialect that emits small JS and uses plain JS data) | Clojure syntax with small output and no persistent-data runtime. | Smaller community, a dialect with differences from ClojureScript. Version 0.14.207 on Clojars (web: https://www.clojars.org/io.github.squint-cljs/squint, https://github.com/squint-cljs). | inferred |

Recommendation: **A, keep JS**. If the owner wants Clojure syntax here,
choose C before B, and only with a size budget and the full Playwright
suite green on all three engines.

If B or C is chosen, how it is built, injected and tested [inferred]:

- Build: shadow-cljs `:browser` target (B) or the Squint CLI (C), one
  output file. shadow-cljs wraps a single-module release build in an
  anonymous function with no globals (shadow-cljs user guide, https://shadow-cljs.github.io/docs/UsersGuide.html).
  The code must still set `__zbAutomation` itself with
  `Object.defineProperty`, as today.
- Injection: no change in the shims. The JVM core reads the compiled file
  from the classpath and passes it to the same native calls
  (`zb_automation_set_script` today).
- Tests: point `e2e/automation_script.spec.ts:6` (`scriptPath`) at the
  compiled file. The spec loads it with `page.addScriptTag` and calls
  `__zbAutomation.handle` (`e2e/automation_script.spec.ts:20-28`), so it
  tests behaviour, not source. Pure helpers can also get
  `:browser-test` or `:node-test` unit tests.
- Delete the source-grep tests in `tests/automation/js_contract_test.zig`
  (for example lines 7-40 look for strings such as `'rateLimitScan'` and
  `outstandingWaits -= 1` in the source). Compiled output does not keep
  those strings.

### 4.2 The drawer UI

What it is today [verified]:

- Three native UIs: GTK (`src/agent_drawer.c`, header comment lines 1-8),
  AppKit (`src/agent_drawer_mac_panel.m`, `src/agent_drawer_mac_host.m:1-6`),
  and Win32 with a read-only plain-text RichEdit bubble (Windows branch
  `src/webview2_shim.cpp:7,120,1990`). One shared pure-logic file,
  `src/agent_drawer.zig`.
- The choice is deliberate: "The icon and drawer are native GTK widgets,
  with no web content and no JavaScript. Pages, iframes and popups cannot
  see, script or cover them, and the automation socket has no drawer,
  agent or secrets methods" (`docs/agent-drawer.md:92-94`). Model text is
  only set with `gtk_label_set_text`, so it stays inert
  (`src/agent_drawer.c` header).
- The drawer docks under the page, because a floating panel over the page
  blanked an NVIDIA screen (`docs/agent-drawer.md:49-52`).

Options:

| Option | Gain | Cost | Label |
|---|---|---|---|
| A. Keep the three native UIs; port only `agent_drawer.zig` to `.cljc` (recommended for the first release) | No security change. Owner already accepted these UIs on real screens. | Three UIs to keep in step. | inferred |
| B. One ClojureScript drawer in a second, privileged web view per window | One UI for 3 OSes. Long-line breaking, selection and copy become CSS and DOM work. | Reverses the "no web content" rule. Needs its own web view instance that pages cannot reach, no network, a strict CSP, and text set only with `textContent`. Adds a web content process per window (memory not measured: unknown). Every OS needs new native code to host and dock it. Needs owner sign-off on real screens again. | inferred |

Recommendation: **A first**. Revisit B after the core port ships (Q2).

If B is chosen [inferred]: shadow-cljs `:browser` target with `:advanced`.
UI library: **Replicant**, which needs no React (web (helper):
https://github.com/cjohansen/replicant). Reagent 2.0.1 and UIx 1.4.9 need
React (web (helper): https://clojars.org/reagent/reagent,
https://github.com/pitch-io/uix). The HTML is loaded from the app bundle,
not from a URL. The drawer talks to the core with a message handler
(the same `zbHost` pattern the dashboard uses,
`src/dashboard/content/index.html:132-140`), never with the page's
automation world. Tests: `:browser-test` for logic, Playwright TS for the
page itself, and the owner's real-screen check.

### 4.3 The SDKs

- Keep the Python and Node SDKs in their own languages. Their users write
  Python and TypeScript. The wire is plain JSON-RPC 2.0 over a Unix socket
  with a 4-byte big-endian length prefix (`sdk/python/src/zigbrowser/client.py:515-556`,
  server side `src/automation_server.zig:20,347-363` per pane 1) [verified
  on the SDK side]. The port does not change the wire, so the SDKs do not
  change.
- Optional new Clojure SDK as one `.cljc` library (Q6) [inferred]: JVM
  build with deps.edn; JVM Unix sockets through
  `java.nio.channels.SocketChannel` with `UnixDomainSocketAddress`
  (Java 16 and later, inferred, not checked here); ClojureScript build with
  shadow-cljs `:node-library` using `node:net`. It would reuse
  `tests/fixtures/automation/sdk_wire_cases.json` (82 cases [verified]) as
  its test data, like the other SDKs do
  (`sdk/python/tests/test_server_alignment.py:1-19`).
- sdk/cli (80 lines, click) could become a babashka script. babashka
  v1.13.229 has `babashka.process` and an HTTP client built in (web
  (helper): https://github.com/babashka/babashka/releases,
  https://book.babashka.org/). Whether babashka can open a Unix socket is
  unknown. Low value; keep the Python CLI.

### 4.4 The dashboard

- It is a 387-line HTML page with mock data from `src/dashboard/ipc.zig`
  (every command returns a `mock*` answer, `ipc.zig:8-40`). Nothing in the
  app loads it; only test modules in `build.zig:5268-5297` use it
  [verified].
- Recommendation: drop it from the port (Q5). If the sequences service
  becomes real, build a new dashboard in ClojureScript: shadow-cljs
  `:browser`, Replicant, `:browser-test` plus Playwright. It talks to the
  core with the `zbHost` handler, as it does today (`index.html:132-140`).


---

## 5. The agent host: keep Python or move to Clojure

### What it is [verified]

- 8,701 lines of Python in 31 files, with 20,339 lines of tests in 92 files.
- Pinned to `claude-agent-sdk==0.2.165` (`agent/host/pyproject.toml:6`).
  PyPI's latest is 0.2.174 (web, checked: https://pypi.org/pypi/claude-agent-sdk/json).
- The Python SDK bundles the Claude Code CLI binary. The host finds it at
  `claude_agent_sdk/_bundled/claude` (`agent/host/zb_agent_host/token.py:170-171`,
  `setup.py:843`). Each wheel is about 98 to 110 MB (`agent/host/uv.lock:156-160`).
- The host uses the SDK in six files: `chat.py:31`, `contract.py:13`,
  `bridge.py:24`, `options.py:11`, `token.py:170`, `route_probe.py:295`.
- App to host: NDJSON frames, one JSON object per line, each
  `{"v":1,"seq":n,"type":...}` (`frames.py:1`, `frames.py:26-32`). App frames:
  hello, open_session, prompt, interrupt, end_session, shutdown,
  tool_result (`chat.py:10-13`, `chat.py:243-267`). Helper frames: ready,
  session_opened, assistant_delta, assistant_message, tool_call, result,
  error, session_ended, reply_capped (`src/agent_frames.zig:34`). Error
  codes: auth, busy, overloaded, protocol, overflow, sdk, sandbox
  (`src/agent_protocol.zig:54`). End reasons: end, interrupt, crash,
  token_removed (`src/agent_protocol.zig:55`).
- Browser tools are an in-process MCP server: 14 tools in three groups,
  read, act and gated (`bridge.py:45-85`).
- About 4,770 of the 8,701 lines are OS containment: bwrap, seccomp,
  Seatbelt, netd, relay, Job Objects, libproc (sum of the sandbox rows
  above) [verified by wc].

### Agent SDK availability by language

- Official: **Python and TypeScript only**. The overview says the SDK is
  "programmable in Python and TypeScript". For other languages it says to
  "run the CLI as a subprocess with the `-p` flag" (web, checked:
  https://code.claude.com/docs/en/agent-sdk/overview).
- TypeScript: `@anthropic-ai/claude-agent-sdk` 0.3.312, with per-platform
  binary packages such as `-darwin-arm64`, `-win32-x64`, `-linux-x64`
  (web, checked: https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/latest).
- JVM: no official Agent SDK. A community Java SDK exists,
  `org.springaicommunity:claude-code-sdk` (web (helper), version unknown:
  https://central.sonatype.com/artifact/org.springaicommunity/claude-code-sdk).
  `com.anthropic:anthropic-java` covers only the Messages API (pane 1, web:
  https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/java).
- Clojure: none found (web (helper), unconfirmed).
- The CLI's `--input-format stream-json` and `--output-format stream-json`
  flags are documented, but only part of the event schema is
  (web (helper): https://code.claude.com/docs/en/headless,
  https://code.claude.com/docs/en/cli-reference). Driving the CLI directly
  means owning an undocumented protocol.

### Options

| Option | What moves | Gain | Cost | Effort | Label |
|---|---|---|---|---|---|
| A. Keep Python (recommended) | Nothing. The Clojure core speaks the same NDJSON frames. | Official SDK. 20k lines of tests stay valid. Sandbox code is untouched. | Two runtimes ship (the Clojure core binary and Python). Mac still needs the universal2 Python tree (`pyproject.toml:14-19`). | 1-2 agent-days | inferred |
| B. ClojureScript on Node with the TypeScript SDK (nbb or shadow-cljs `:node-script`) | chat, bridge, frames, options, token, redact (about 1,530 lines). | Official SDK. One Lisp across core and host. | Ships Node instead of Python. Sandbox code must still be Python or native. The host's tests must be rewritten. nbb 1.6.214 can require npm packages (web (helper): https://github.com/babashka/nbb); that it loads this SDK is untested. | 10-15 agent-days | inferred |
| C. Clojure on the JVM driving the CLI's stream-json directly | All of the host's SDK use. | One runtime for core and host. | No official SDK. The input schema is not documented. Every CLI update can break it. MCP tool server must be rebuilt. | 15-25 agent-days, high risk | inferred |
| D. Community Java SDK from Clojure | Same as C. | A library instead of a raw protocol. | Not official. Maturity unknown. | unknown | unknown |

Recommendation: **A**. The app-to-host boundary is already a clean
process boundary with a small, validated frame protocol. The Clojure core
(the section 1 design: a Clojure core with small native hosts over a local socket)
only needs a frame reader and writer, which is small [inferred]. Revisit B
only if shipping Python on Mac becomes the main pain.


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


### 6.6 Product-side contracts (from part 2)

All verified by reading the code at the cited lines.

1. **Page script API.** `__zbAutomation.handle(json)` with the ops listed
   in 4.1 (`automation.js:235-275`), the result shapes
   (`automation.js:1376-1398`), `inputAck()`, `navigationEnded(seq)` and
   `documentToken` (`automation.js:1537-1567`), the world name
   `zigbrowser-automation` (`src/webkit_shim.h:140`), and the message
   handlers `zbNavigation` and `zbFiles` (`src/webkit_shim.c:1910-1928`).
2. **SDK wire.** JSON-RPC 2.0 with a 4-byte big-endian length
   (`sdk/python/src/zigbrowser/client.py:550-556`). The per-session token
   sits next to the socket as `<socket>.token`, mode 0600
   (`client.py:476-485`), and is sent as `auth`
   (`sdk/node/src/client.ts:28`). The automation error range is -32015 to
   -32001 (`sdk/python/src/zigbrowser/errors.py:18`,
   `sdk/node/src/errors.ts:19-20`). The 82 shared wire cases live in
   `tests/fixtures/automation/sdk_wire_cases.json`.
3. **Flow request order.** Strict params, then the login cookie gate
   (`li_at` / `sessionid`, else -32011 logged_out), then pacing (default
   100 actions a day, 3-8 s pause; at the cap -32010 social_daily_cap),
   then the flow. Dry runs skip pacing
   (`src/automation/social_flow_routes.zig:7-29`).
4. **Owner action gates.** LinkedIn connect and follow may click; message
   may not (`src/linkedin.zig:147-152`).
5. **Telemetry privacy.** URLs, usernames and texts never reach the sink,
   only hashes, lengths and selector names
   (`social_flow_routes.zig:31-34`).
6. **On-disk: `<profile>/automation-pacing.json`.** Version 1, at most
   4096 bytes, fields `version, day, social{actions_today, daily_cap,
   min_delay_ms, max_delay_ms}, x{...}`, every field required, none
   unknown, written atomically with mode 0600
   (`src/automation/pacing_store.zig:1-8,20-43`).
7. **On-disk: `<profile>/agent-drawer.json`.** Version 1, `{version, x, y}`
   with x and y between 0 and 1 (`src/agent_drawer.zig:533-565`).
8. **Agent frames.** Listed in section 5 (`frames.py:1`,
   `src/agent_frames.zig:34`, `src/agent_protocol.zig:54-56`). Login
   error codes: cli, timeout, cancelled, shape, protocol, exchange
   (`src/agent_protocol.zig:431`).
9. **Agent tool names and schemas.** The 14 tools (`bridge.py:45-85`).


---

## 7. Test strategy

The rule: tests that drive the product from outside become the port's
contract tests and do not change. Tests that import Zig code are rewritten
or dropped.

### Tier 1: keep unchanged, run against the ported build (contract tests)

| Tests | Why they are contracts | Label |
|---|---|---|
| `tests/fixtures/automation/sdk_wire_cases.json` (82 cases) with `sdk/python/tests/test_server_alignment.py` and the Node SDK tests | Shared wire cases the real server must accept (`test_server_alignment.py:1-19`). | verified |
| `tests/e2e/*.py`: 115 files take a `--binary` path (default `zig-out/bin/zigBrowser`) and 98 talk to the socket. Key ones: `automation_core_test.py`, `automation_input_test.py`, `automation_guard_test.py`, `automation_pacing_persist_test.py`, `automation_profile_test.py`, `social_flows_test.py`, `x_flows_test.py`, `nav_allow_test.py`, `nav_block_test.py`, `page_health_test.py`, `sdk_python_live_test.py`, `node_live_group_test.py` | They launch a binary and talk to it. Point `--binary` at the new launcher. | verified (counts by grep), inferred (reuse) |
| `tests/fixtures/{linkedin,instagram,x}/*.html` | Offline copies of the sites the flows run against. | verified |
| `e2e/automation_script.spec.ts` (Playwright, 3 engines) | Tests the page script's behaviour through `handle`. | verified |
| `agent/host/tests/` (92 files), above all `test_contract.py`, `test_chat*.py`, `test_bridge*.py`, `test_launcher_contract.py` | Pin the frames and the helper's behaviour. Unchanged if the host stays Python. | inferred |
| `tests/mac/` and `tests/windows/` live and package tests | Test the installed app (DMG, MSI). Re-point them at the new artifact. | inferred |

Rules for running them (from team memory, not code): only under a private
Xvfb, with a private HOME, XDG dirs and `--profile-dir`, and a short socket
path under `/tmp` because of the 108-byte AF_UNIX limit.

### Tier 2: rewrite as clojure.test

- The 134 top-level `tests/*.zig` files (30,468 lines) that test modules
  which move to Clojure. Their test names and cases become the spec for the
  Clojure code. Examples on the product side: `tests/linkedin_test.zig`,
  `tests/instagram_test.zig`, `tests/x_test.zig`, `tests/social_test.zig`,
  the `tests/automation_expect*` and `tests/automation_guard*` families, and
  the 5 `tests/agent_drawer*` files (logic parts only) [verified names,
  inferred mapping].
- `tests/automation/bezier_test.zig`, `gaussian_test.zig`,
  `pacing_test.zig`, `stealth_test.zig`: pure math and logic, easy ports.
- Runner: Kaocha for the JVM (web (helper):
  https://clojars.org/lambdaisland/kaocha), shadow-cljs `:node-test` for
  `.cljc` code on the JS side.
- Malli schemas (0.20.3, web (helper): https://github.com/metosin/malli/releases)
  for the wire shapes, with generative tests from those schemas [inferred].

### Tier 3: drop or keep native

- Drop: `tests/automation/js_contract_test.zig` (it greps the JS source
  for strings), and `tests/dashboard/`, `tests/sequences/` if those
  modules are dropped.
- Keep native: the 12 `tests/*.c` files and any Zig or C tests of code that
  stays native (sections 2a-2e).

### New work the port needs

1. **Golden transcripts** [inferred]. Before porting, run the Tier 1 e2e
   suite against the current Zig build and record every socket request and
   response as JSONL. Replay them against the Clojure build and diff. This
   catches field-order, null and error-data drift that the tests do not
   assert on.
2. **One launcher seam** [inferred]. Make every e2e test read the binary
   path from one variable, so the same suite runs on both builds side by
   side.
3. **Frame recorder** [inferred]. Record app-to-helper frames in the
   current build and replay them against the Clojure core's frame code.


---

## 8. Phases, order and effort

**Effort scale.** One agent-day is one focused agent working one day, with review.

**Calibration**
- The current product took about 5 months and 2,964 commits with multi-agent teams [V].
- About 22,000 Zig lines move in total: about 17,100 in pane 1's scope and about 5,000 in the flows (section 2).
- The estimates are [I] and come from both panes: pane 1's phases plus part 2's "phase inputs".

| # | Phase | What ships | Agent-days | Confidence |
|---|---|---|---|---|
| 0 | **Spike and decision.** A host-protocol prototype on Linux for 3 PagePort methods (`evalJson`, `navigate`, `url`). A Clojure native-image core answers `page.url` through it. Measure start time, RSS, binary size and round-trip latency. Build and sign the core on both Macs (arm64 and x86_64) to confirm GraalVM availability. | A measured go/no-go memo. No user change. | 6-10 | Medium |
| 1 | **Contract harness.** One launcher seam so every e2e test can target either build. Golden transcripts of the automation socket and of the helper frames recorded on today's Zig build. Byte fixtures for section 6 (framing, errors, on-disk files). The tier-1 suite from section 7 runs against any core. | A suite green on today's Zig core. | 8-12 | Medium |
| 2 | **Native host protocol, Linux.** Put the existing GTK PagePort and CookiePort behind a socket server inside today's binary, behind a flag such as `--core=external`. Covers window lifecycle, dialogs, screenshots and native input. | A Linux dev build that an external process can drive through PagePort. | 10-15 | Medium |
| 3 | **Clojure automation core.** Transport, auth, framing, router, engine, queue, errors, telemetry, cookie routes, and the window, health, recover and dialog routes. | A Linux build where the Clojure core passes the tier-1 automation suite, behind a flag. | 25-35 | Low-medium |
| 4 | **Flows and pacing** (part 2 P1 + P4). LinkedIn, Instagram, X, social, flow runner and routes, pacing and pacing store, bezier, gaussian, stealth, as `.cljc`. The matching Zig unit tests are rewritten as clojure.test. | All 52 automation methods on the Clojure core, with flow e2e green. | 13-20 | Low-medium |
| 5 | **Agent core** (part 2 P2 included). Broker, tools, approval and selector store, the NDJSON frame codec for the unchanged Python host, the helper controller state machine, the login flow and the run ledger. The host keeps spawn, fd 3/4 and secrets. | The Linux drawer works end to end on the Clojure core. Agent-host tests and drawer e2e green. | 20-30 | Low-medium |
| 6 | **macOS host and release.** The Mac PagePort stub over the socket, a universal core binary (lipo), inside-out codesign with hardened runtime, and **notarization** (new work). A DMG upgrade test that keeps cookies (UUID store) and the Keychain token. | A signed, notarized Mac DMG on the Clojure core. | 12-20 | Low-medium |
| 7 | **Windows host.** Resume the paused Windows branch. The WebView2 PagePort stub over the socket, an MSI with the core binary, the Credential Manager path. | A Windows MSI on the Clojure core. | 12-20 | Low. The Windows PagePort is partial today: only routed commands are done (`src/automation_wv2_port.zig:10-12`, win branch) [V]. |
| 8 | **Remove the Zig core.** Delete the moved Zig modules and their Zig tests once the contract suite and the platform e2e tests are green on every shipping OS. | One core. | 4-6 | Medium |

**Totals**
- Required phases 0-8: about **110-168 agent-days**.
- Confidence: **low-medium**.
- Commit only to phases 0 and 1 before the phase 0 numbers exist.

**Order and parallel work** [I]
- Phase 0 comes first, and phase 1 must be green before any phase starts porting code.
- Phases 2 and 3 can run in parallel once the phase 0 host protocol is frozen.
- Phase 4 can start when phase 3's router and engine pass their contract tests.
- Phases 6 and 7 can run in parallel once phase 5 lands.

**What users see** [I]
- Nothing changes for users until phase 6, the first platform release on the new core.
- Linux is a development platform only. The owner's users are on Mac and Windows (team memory, not code). So phases 2-5 are internal.

**Optional phases** (only if the owner says yes in section 9; estimates from part 2)

| Optional work | Agent-days | Confidence | Question |
|---|---|---|---|
| Page script in Squint or ClojureScript, with a size budget and Playwright on 3 engines | 6-10 | Low | Q3 |
| ClojureScript drawer in a privileged web view, with real-screen sign-off | 15-25 | Low | Q2 |
| Clojure SDK (`.cljc`, JVM and Node) | 3-5 | Medium | Q6 |
| Agent host on Node with the TypeScript SDK | 10-15 | Low | Q4 |
| Dashboard in ClojureScript, only when the sequences service exists | 5-8 | Low | Q5 |
| Rewrite the host glue (about 4,400 Zig lines) in C/ObjC/C++ | not estimated | — | Q9 |

---

## 9. Open questions for the owner

Each question has a recommendation. Q1-Q8 come from pane 2 and Q9-Q13 from pane 1.

1. **Q1. Is the goal one language everywhere, or Clojure for the core?**
   - Recommendation: Clojure for the core and the flows.
   - Keep the page script in JS, the agent host in Python, the SDKs in Python and TypeScript, and the engine shims native.
   - "One language everywhere" is not reachable: the engines must stay native (section 3).
2. **Q2. Should the drawer stay native, or become one ClojureScript UI in a privileged web view?**
   - Today it is native on purpose (`docs/agent-drawer.md:92-94`).
   - Recommendation: stay native for the first release. Its geometry code also stays native, because the UI calls it inline (section 1, reconciliation).
   - Decide on a web drawer after the core ships, with the owner's real-screen check.
3. **Q3. Should automation.js be rewritten?**
   - Recommendation: no.
   - If the owner wants Clojure syntax there, use Squint, with a size budget and the Playwright suite on all three engines.
4. **Q4. Should the agent host stay in Python?**
   - Recommendation: yes. Only Python and TypeScript have an official Agent SDK.
   - Revisit a Node host (ClojureScript plus the TypeScript SDK) only if shipping Python on Mac becomes the main pain.
5. **Q5. Drop the dashboard and the sequences client from the port?**
   - The app does not use them today.
   - Recommendation: drop them; they stay in git history. Build a ClojureScript dashboard when the sequences service is real.
6. **Q6. Do you want a Clojure SDK for users?**
   - Recommendation: not in the first release. Add a small `.cljc` client later if users ask.
7. **Q7. Sign-in policy (not caused by the port).**
   - The Agent SDK overview says third-party apps should not offer claude.ai login unless approved, and should use API keys [W] (https://code.claude.com/docs/en/agent-sdk/overview).
   - The drawer uses a claude.ai setup-token (`docs/agent-drawer.md:29-32`).
   - Recommendation: confirm approval, or add an API-key path, before launch, whatever happens with the port.
8. **Q8. Upgrade the pinned Agent SDK?**
   - The repo pins 0.2.165 and PyPI has 0.2.174.
   - Recommendation: a separate task, not part of the port.
9. **Q9. Keep Zig for the native host glue, or rewrite it in C/ObjC/C++?**
   - The host keeps about 4,400 lines of Zig glue: PagePort adapters, inline policies, drawer geometry and config apply (section 2).
   - Recommendation: keep Zig in the host during the port. Rewriting working glue adds risk and no user value. Revisit after phase 8.
10. **Q10. If GraalVM native-image is not available for macOS x64, what happens to Intel Macs?**
    - Recommendation: confirm in phase 0.
    - If it is missing, ship a jlink'ed JVM core for Intel only, with a JDK 25 AOT cache and the `allow-jit` entitlement. Or set an end date for Intel support.
    - Do not block arm64 on it.
11. **Q11. Accept a second process (option C) instead of one JVM process (option A)?**
    - Recommendation: yes. It keeps first paint fast, keeps the token out of the core, avoids the FFM gaps, and a core crash does not close the user's windows.
12. **Q12. Notarization is missing today and is required for a public Mac release, with or without the port. Do it before the port?**
    - Recommendation: yes, on the Zig build first (MS9).
    - Then phase 6 only adds one binary to a notarized pipeline that already works.
13. **Q13. May the port change any wire or disk contract (for example, add a protocol version field)?**
    - Recommendation: no. Freeze section 6 byte for byte until phase 8 is done.
    - After that, version any change with a migration and a test.
