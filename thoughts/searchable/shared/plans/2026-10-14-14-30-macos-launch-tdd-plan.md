---
date: 2026-10-14T14:30:00-04:00
planner: cc_3 / JadeBeacon (Opus 4.8)
git_commit: 1df5dce502ae9a1433573e8ba5ba2e0506fbafcb
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "macOS launch support for zigBrowser — TDD implementation plan"
tags: [plan, tdd, macos, wkwebview, appkit, seatbelt, universal-build, automation, drawer, launch-critical]
status: plan for review
primary_research: thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md
---

# macOS Launch Support for zigBrowser — TDD Implementation Plan

> **PLAN ONLY.** No implementation, no live runs this turn. Every slice below is
> red-first; agents prepare the e2e scripts and may run them on the **remote Macs**
> over Tailscale SSH, never on the user's local `DISPLAY :0`, live profile, or live
> sockets. Every UI slice ends with a real-screen check judged by the user's eyes,
> coordinated by the orchestrator.

## Overview

macOS is launch-critical: most of the userbase is on Mac. Today zigBrowser has a
working macOS **app/window/render/IPC seam** only — `src/wkwebview_shim.m` (888 lines)
implements 6 of ~76 C-ABI functions, and bead `zigBrowser-8g7` already proved
render + ping/pong on a real Intel Mac. Everything a Mac *launch* needs beyond opening
a window — automation (page/dom/input/dialogs/popups/crash/health/recover), site flows,
the AppKit agent drawer, the OS-native sandbox, the agent helper, and signed/universal
packaging — does not exist on macOS. See the research doc
(`thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md`,
commit 1df5dce) for the full as-is map; this plan turns that map into small,
red-first, gated slices.

This plan follows the house conventions of the drawer plan
(`thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`):
small slices, **one gate each**, native work lands with its adapter in the same slice,
every slice ends with a real-binary e2e, a UI slice is not approved until a real-screen
check passes on the user's hardware, and a slice is not done until its closure e2e was
**observed to execute** with nonzero assertions (a "SKIP" counts as UNCLOSED).

## Current State Analysis

### Key Discoveries (all from research 1df5dce, verified file:line)

- **One C ABI, three backends by OS.** `resolveBackend` (build.zig:1107-1114):
  `.linux → gtk_backend`, `.windows → webview2_backend`, `.macos → macos_backend`.
  `configureMacosBackend` (build.zig:1174-1184) compiles `src/wkwebview_shim.m`
  `-fobjc-arc` and links `WebKit`/`Cocoa`/`Foundation`. `CheckMacosBackendStep`
  (build.zig:79-105) fails the build if the shim is missing.
- **macOS shim = 6 core fns only.** `zb_app_run` (wkwebview_shim.m:788), `zb_run_open`
  (:834), `zb_run_screenshot` (:838), `zb_version_line` (:853), `zb_reload` (:872),
  `zb_window_new` (:880); plus `zb_policy_decide` (nav_policy.zig:40) and
  `zb_ipc_dispatch` (ipc.zig:41). **None** of the ~70 `zb_automation_*`/`zb_native_*`
  functions.
- **The single `PagePort` impl is Linux-gated.** `automation_gtk_port.supported =
  builtin.os.tag == .linux` (automation_gtk_port.zig:22); `pagePort()` → null off Linux
  (:39-41). The server/router/engine/queue/recover/flows/token-sidecar are
  platform-neutral Zig.
- **Capability table already models macOS.** `.wkwebview = { input: js_synthetic,
  network: unsupported(no_platform_api) }` (automation_platform.zig:90-95).
- **Native input on Linux is toolkit-path, not X11.** Events are built with `gdk_event_new`
  and delivered via `gtk_main_do_event` (webkit_shim.c:3373) — no XTEST/uinput. This is
  the pattern the macOS NSEvent path mirrors (in-app delivery, no TCC).
- **Config apply is Linux-only.** `webkit.applyRender/applyMediaSource/applyProfileDir`
  are `comptime os.tag != .linux` no-ops (webkit.zig:48/72/91; app.zig:166).
- **Build is remote-native over Tailscale SSH**, not cross-compiled
  (tests/mac/build-on-mac.sh:25-34; comments :29-33 — no `-Dtarget`). Linux only does a
  no-link symbol cross-check (build.zig:241-272; `tools/check_cross_symbols.py`). The
  cross-target no-backend integrity test `713587b` is green (review log line 135).
- **Packaging ships an ad-hoc `.dmg`.** `codesign --force --sign - --deep`
  (packaging/macos/build-dmg.sh:90); `Info.plist` `LSMinimumSystemVersion 13.0`
  (Info.plist:21-22). No Developer ID, hardened runtime, entitlements, notarization, or
  universal binary; M9 validation was Intel-only.
- **Drawer is 100% GTK3 widgets** (`ZbDrawerHost` custom no-window container,
  agent_drawer.c:277-415; fold driver via `gtk_widget_add_tick_callback` :628-695;
  portable geometry/animation/persistence in agent_drawer.zig:16-181). Out of scope for
  macOS in its own plan (drawer plan :804). Secrets use libsecret via `dlopen`
  (agent_secrets.c). Drawer is isolated from page JS structurally (native widgets).
- **The NVIDIA real-screen lesson.** An output window over the accelerated page blanked
  the user's NVIDIA screen; the GTK fix was a windowless host that paints floats into the
  page's window (drawer plan §7.1, review log R15.3c). **Every UI slice now needs a
  real-hardware check on the user's screen** (drawer plan §7.1 lines 905-993).
- **Sandbox is Linux-kernel-only** (bwrap, nested PID ns, seccomp-bpf, `/proc`,
  `--die-with-parent`, `memfd_create`; sandbox.py/seccomp.py/hook_run.py). The token
  route FIFO→socketpair→fd 3 is portable POSIX (token.py:63-134). No `--unshare-net`
  yet (planned Linux rev 16). The macOS replacement is researched (Seatbelt first, VM
  fallback) but not built: `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md`
  and `2026-10-14-agent-sandbox-redteam.md`.
- **e2e harness is Xvfb/X11-bound** (tests/e2e/xsession.py, xinput.py). macOS tests are
  the three `m9_*` run remotely by `tests/mac/gate.sh:24-44`. Only
  `tests/agent_protocol_test.zig` is platform-neutral.

## Desired End State

A Mac user can install a universal (arm64 + x86_64) zigBrowser, open pages, drive the
full automation API over the socket, run the site flows with per-action approval, use the
AppKit agent drawer (docked, movable "S" icon, fold animation, Keychain secrets), and run
the Claude agent inside an OS-native Seatbelt sandbox behind the shared backend interface
— verified by real-binary e2e on **both** remote Macs and by the user's eyes on screen.
Developer-ID signing, hardened runtime, and notarization land as the final, small slice
once the user has an Apple Developer ID; entitlement/hardened-runtime compatibility is
designed in from MS1 so that last slice is small.

### Observable end-state behaviors (one per slice, expanded below)

- MS1: Given both Macs reachable, when the gate builds a **universal** binary and runs the
  `m9_*` suite on each arch, then both pass and the artifact is a fat Mach-O.
- MS2: Given a page loaded in the WKWebView build, when a client sends `dom.*`/`page.*`/
  native-input/dialog/popup/health/recover over the socket, then the live page changes and
  the result is observable through the production read — identical client contract to Linux.
- MS3: Given a logged-in fixture, when a LinkedIn/Instagram/X flow runs on macOS, then it
  behaves exactly as on Linux, including per-action approval and dry-run.
- MS4: Given `--agent-drawer on` on macOS, when the user opens the drawer, then a native
  AppKit drawer docks at the bottom (page resized above), the floating "S" icon hides while
  open, the conversation scrolls with input at the bottom, and `-` animates into the icon's
  last position; secrets store in Keychain; isolated from page worlds.
- MS5: Given the Seatbelt backend behind the shared interface, when a malicious hook tries to
  read the CLI's memory/args, reach a non-allowlisted host, or survive a browser `kill -9`,
  then each attempt fails — proven by failing-first e2e on a Mac.
- MS6: Given the agent helper on macOS, when the drawer opens a session, then the Claude CLI
  runs inside the Seatbelt sandbox with the FIFO→fd-3 token route and streams replies.
- MS7: Given an Apple Developer ID, when the release gate builds, then the `.dmg` is
  Developer-ID-signed, hardened-runtime-enabled, and notarized/stapled — a small diff over
  the ad-hoc path designed in MS1.

## What We're NOT Doing

- Not changing the Linux GTK behavior or its gate (except where the shared backend interface
  is factored out of existing Linux code — behavior-preserving, Linux gate stays green).
- Not building the VM sandbox fallback in this plan (kept as a researched pluggable backend
  behind the same interface; a MS5 follow-up bead if the Seatbelt spike fails).
- Not building a Windows drawer or Windows automation parity (separate track).
- Not adding the token-swap proxy (keep the FIFO→fd-3 route; the host allowlist proxy is
  shared infra carried over from the Linux rev-16 design).
- Not running anything on the user's local `DISPLAY :0`, live profile, or live sockets.
- Not obtaining the Apple Developer ID (user action); MS7 is gated on it.

## Testing Strategy

- **Frameworks:** Zig `std.testing` (unit, platform-neutral where possible); Python e2e
  driving the real binary via the Python SDK over the automation Unix socket
  (`sdk/python/src/zigbrowser/client.py`); ObjC behavior asserted through the C ABI from
  the Zig/e2e side (no separate ObjC test runner).
- **macOS harness (new):** extend `tests/mac/gate.sh` into a per-arch gate that (1) rsyncs
  the tree to each remote Mac, (2) builds, (3) runs the macOS e2e suite, (4) copies back
  artifacts (render PNGs, logs). A new `tests/e2e/mac_session.py` is the macOS analog of
  `xsession.py`: it launches the real binary (a real `NSWindow`; **no Xvfb/DISPLAY on
  macOS**), sets `ZIGBROWSER_SOCKET`, guards the process tree, and tears down. Agents run
  this on the remote Macs; the user's local screen is never touched.
- **Native input:** mirror the Linux toolkit-path approach — construct `NSEvent`s and deliver
  through the responder chain (`[NSWindow sendEvent:]` / WKWebView), **not** `CGEventPost`
  (which needs Accessibility TCC). `CGEvent` is a documented, TCC-gated fallback only; the
  capability table entry `.wkwebview = js_synthetic` governs the default path.
- **Real-screen check (UI slices):** add a macOS case to `tests/manual/real_screen_check.py`
  (or a `mac_real_screen_check.py` sibling) per UI slice; the orchestrator runs it on the
  user's Mac screen with permission. A UI slice is not approved until it passes there; a Xvfb-
  equivalent/offscreen pass is necessary but not sufficient.
- **Closure tests** are Tier-1 real-binary e2e over the socket; a skipped closure test is
  UNVERIFIED (framework §4). Each ClosureMap below is pinned to HEAD 1df5dce.
- **Both arches:** every e2e runs on the Intel Mac and the Apple Silicon Mac; MS1 makes that
  the default matrix.

## Shared Backend Interface (design spine, defined in MS5, referenced throughout)

One `SandboxBackend` interface (Zig, platform-neutral) with a launch spec: broker byte
stream; token channel (FIFO then fd 3, never env); host allowlist-proxy endpoint
(`api.anthropic.com` + census-proven CLI domains, fail-closed); bridge ports 51091 (voice)
and 31337 only; shares (agent home read-only, workspace read-only, scratchpad read-write);
a hook-launch hook (how one hook gets its own confinement); and a lifetime contract
(everything dies with the browser). Implementations: Linux bwrap (existing pieces refactored
behind the interface, behavior-preserving), macOS Seatbelt (new, MS5), VM fallback (later
bead). The host proxy, port bridges, in-process broker, and approval logic are **shared
code** across OSes. Carried-over decisions: SAI copy rule (a); every social write needs
per-action user approval; token route FIFO→socketpair fd 3.

---

## MS1: Universal build + Mac CI/remote gate

**Goal.** A reproducible universal (arm64 + x86_64) macOS build and a two-arch remote gate,
with the ad-hoc-signed `.dmg` designed so hardened-runtime/entitlements drop in later (MS7).

### Behavior MS1.1: universal fat Mach-O build on a Mac
**Given** both remote Macs reachable over Tailscale SSH (one Intel, one Apple Silicon),
**When** the build runs natively on each and the results are combined,
**Then** `zig-out/bin/zigBrowser` (or the `.app` executable) is a fat Mach-O containing
both `arm64` and `x86_64` slices (`lipo -info` lists both), each slice runs, and
`zb_version_line` returns the WKWebView version on each arch.

- **Files touched:** `build.zig` (a `mac-universal` step; no `-Dtarget`, per
  build-on-mac.sh:29-33), `tests/mac/build-on-mac.sh` (per-arch build), `packaging/macos/build-dmg.sh`
  (lipo the two slices before signing), `tests/mac/gate.sh` (two-arch matrix).
- **Property:** none — fixed build artifact, nothing to generate over.
- 🔴 Red: `tests/e2e/mac_universal_test.py` asserts `lipo -archs` lists `x86_64 arm64`
  and that each extracted slice executes `--version`. Fails today (single-arch, no lipo).
- 🟢 Green: build each arch on its native Mac, `lipo -create` the two executables, stamp the
  bundle.
- 🔵 Refactor: factor the per-arch build into one function reused by `gate.sh`; no duplicated
  ssh/scp blocks.

### Behavior MS1.2: the two-arch remote gate runs the macOS suite and fails closed
**Given** the `m9_*` suite (render, reply-channel, load-fail) and `mac_session.py`,
**When** `tests/mac/gate.sh` runs on each Mac,
**Then** all `m9_*` pass on both arches, the gate returns nonzero if any Mac is unreachable or
any test is skipped (no silent green), and a render PNG is copied back per arch.

- **Files touched:** `tests/mac/gate.sh`, `tests/e2e/mac_session.py` (new), `build.zig`
  (macOS gate aggregation step).
- 🔴 Red: `gate.sh` run with one Mac unreachable must exit nonzero (today it has no two-arch
  matrix). A `m9_*` that prints SKIP must fail the gate.
- 🟢 Green: the matrix loop + fail-closed reachability check.
- 🔵 Refactor: share the artifact-copyback and teardown with `build-on-mac.sh`.

### Behavior MS1.3: the ad-hoc bundle is hardened-runtime-ready
**Given** the current ad-hoc `codesign --sign -` path,
**When** the bundle is built,
**Then** an `entitlements.plist` and the `Info.plist` already carry the keys the agent
features will need (so MS7 only swaps the signing identity and adds `--options runtime` +
notarization), and the ad-hoc build still verifies (`codesign --verify`).

- **Files touched:** `packaging/macos/entitlements.plist` (new, inert under ad-hoc),
  `packaging/macos/Info.plist`, `packaging/macos/build-dmg.sh`.
- **Design note (carry-over):** entitlements anticipated — network client, and (MS5) whatever
  the Seatbelt launcher needs; `LSMinimumSystemVersion` stays 13.0 (WKContentWorld/
  WKScriptMessageHandlerWithReply are macOS 11+/12+). No hardened runtime yet (would block
  the ad-hoc agent paths during development); MS7 enables it.
- 🔴 Red: a gate assertion that `entitlements.plist` exists and `codesign -d --entitlements -`
  on the signed bundle lists the expected keys. Fails today (no entitlements file).
- 🟢 Green: add the file, pass it to `codesign` (ad-hoc still works).
- 🔵 Refactor: single source of the key list, referenced by MS7.

**Gate (MS1):** the existing Linux gate is untouched; a new `mac-gate` runs MS1.1–MS1.3 on
both Macs and fails closed. **Not a UI slice** (no real-screen check). Coordinate with
BlueBeaver (build/gate) and BlackRobin (shim/version seam).

---

## MS2: WKWebView PagePort adapter + automation ABI

**Goal.** Implement the automation surface on macOS so the **same client contract** as Linux
works over the socket: `page.*`, `dom.*`, native input, dialogs, popups, crash/health/recover.
Native work (`wkwebview_shim.m` functions) lands with its `PagePort` adapter in this slice.

This is the launch-critical core and the largest slice; it lands in **three gated parts**
(MS2a dom/page + eval, MS2b native input + dialogs + popups, MS2c health/recover + crash),
each with its own red/green/refactor/gate/review, mirroring the drawer plan's S3 split.

### Design
- New `src/automation_wk_port.zig` implements `PagePort` (page_port.zig:181-205), gated
  `supported = builtin.os.tag == .macos`, wired in `buildAutomationConfig` (app.zig:220-237)
  alongside the GTK port. `pagePort()` returns a real port on macOS.
- `wkwebview_shim.m` gains the `zb_automation_*`/`zb_native_*` functions declared in
  `webkit_shim.h`, implemented against WKWebView: `evaluateJavaScript:inContentWorld:` in a
  **private `WKContentWorld`** (not `pageWorld`) for the automation script, `loadRequest:`/
  `reload`, `URL`/`title`, `takeSnapshot` for screenshots, `WKUIDelegate` dialog callbacks,
  `createWebViewWithConfiguration` popups, `webViewWebContentProcessDidTerminate:` for crash.
- A macOS main-thread marshal mirrors Linux's `auto_queue_on_gtk`/`auto_job_wait`
  (webkit_shim.c:1692-1812): `dispatch_async(dispatch_get_main_queue())` + a blocking wait on
  a semaphore with a deadline; the automation server thread blocks like on Linux.
- The automation script injection mirrors Linux's `zb_automation_set_script`
  (automation_gtk_port.zig:30-33) into the private content world; the backend-marker script
  (wkwebview_shim.m:387-391) stays.

### Behavior MS2a.1: `page.navigate` + `page.url`/`page.title` over the socket
**Given** the WKWebView build running with `--automation-api`,
**When** a client sends `page.navigate {url}` then `page.url`,
**Then** the WKWebView loads the URL and `page.url` returns it — same JSON-RPC envelope,
auth, and error codes as Linux (automation_server.zig:412-530).

### Behavior MS2a.2: `dom.query`/`dom.get_text`/`dom.click`(synthetic) via the private world
**Given** a fixture page,
**When** a client sends `dom.*` commands,
**Then** the injected `automation.js` (js_embed.zig) runs in the **private** WKContentWorld and
returns DOM results; the page world cannot see or spoof the automation globals.

- **Property (isolation):** metamorphic — for any page that defines `window.__zbAutomation`
  itself, the automation calls still resolve against the private-world copy (page cannot
  shadow it). Domain: fixture pages that redefine the global. Driven through the socket.

### Behavior MS2b.1: native input via NSEvent responder-chain delivery
**Given** `dom.click`/`dom.press`/`dom.type` with `input:"native"`,
**When** the engine runs the native path (engine.zig:642 `runNative`, gated on
`supportsNativeInput()`),
**Then** `zb_native_click`/`_key`/`_text`/`_move`/`_scroll` build `NSEvent`s and deliver them
through the window's responder chain (no `CGEventPost`, no TCC), the page observes the event,
and the ack counters confirm it (mirroring automation_gtk_port.zig:450 `inputAck`).

- **Design note:** if responder-chain delivery proves insufficient for a given event type,
  document the gap and fall back to `CGEventPost` gated on Accessibility TCC (a real-screen,
  user-granted permission) — recorded as a MS2b risk, not a silent default.

### Behavior MS2b.2: dialogs (alert/confirm/prompt/beforeunload) and popups
**Given** a page that opens a JS dialog or a popup,
**When** `dialog.get`/`dialog.respond` or a `window.open` fires,
**Then** the `WKUIDelegate` captures the dialog (held, answered via the ABI like
webkit_shim.c:4523-4625) and popups open as new `ZBWindowHost`s tracked in the window list,
with `page.list`/`page.close` working (automation_server.zig:554-664).

### Behavior MS2c.1: `page.health` + `page.recover` + crash page on WKWebView
**Given** a WKWebView whose web content process is hung or killed,
**When** the client polls `page.health` and runs the two-phase `page.recover`
(automation_server.zig:810-1106),
**Then** health reports `responsive`/`crashed` from
`webViewWebContentProcessDidTerminate:`/responsiveness, and recover reloads the view and
shows a crash page via `loadAlternateHTML`-equivalent — same state machine, incident token,
and 60 s TTL as Linux (all platform-neutral Zig; only the shim action is new).

### Workflow Closure (MS2 — the launch-critical behavior)

#### Production Operation Chain
`client socket frame -> automation_server.handleRequestWith -> router.parse -> queue.acquire -> engine.executeWith -> PagePort(automation_wk_port) -> wkwebview_shim zb_automation_*/zb_native_* (dispatch to WK main thread) -> WKWebView effect on live page -> production read (zb_automation_eval_json / zb_automation_get_url) -> JSON-RPC result to client`

#### Closure Test: "An automation command drives the live WKWebView page and its result is observable to the client."   [BLOCKING: crosses the Zig→ObjC ABI boundary and an async WK main-thread/`evaluateJavaScript` completion edge]
- **SOURCE (seed only):** the page loaded into window 1 via `zb_automation_navigate_guarded`
  (the macOS impl added in MS2a) — seed = navigate to a fixture over the socket.
- **TRIGGER (start):** `automation_server.handleRequestWith` (automation_server.zig:412) — the
  outermost production entrypoint. (boundary = outermost; it is above the
  highest_new_connector, which is `automation_wk_port.pagePort()`, so starting at the socket
  crosses every new seam.)
- **DRIVERS (async edges):** the WK main-thread marshal + `evaluateJavaScript` completion →
  the real `[NSApp run]` / main `NSRunLoop` (entered by `zb_app_run`, wkwebview_shim.m:823).
  In the running browser the run loop runs continuously, so the edge self-drains before the
  observe read; the test must not sleep or mock it.
- **OBSERVE (assert via):** the production read `zb_automation_eval_json` (the macOS impl) or
  `zb_automation_get_url`, returned as the JSON-RPC result and read by the Python SDK.
- **FORBIDDEN SPAN:** `router.parse`, `queue.acquire`, `engine.executeWith`, `PagePort`
  vtable, `automation_wk_port`, the shim marshal — the test calls/seeds/mocks none of them.
- **RED-AT-SEAM proof:** before MS2a lands the adapter, `pagePort()` returns null on macOS and
  the command returns the documented `unsupported` data (automation_platform.zig:90-95); the
  closure e2e asserting a real DOM change is **red** until the adapter + shim fns exist.
- **DRIVABILITY:** store seam = the socket navigate seeds the page (always available); the
  async edge is driven by the real run loop (no injected clock needed — the loop is the
  driver). No required seam missing.
- **EXECUTION (must run):** `tests/e2e/mac_session.py` launches the real universal binary on a
  remote Mac with `--automation-api`; the SDK connects over `ZIGBROWSER_SOCKET` and reads the
  `<socket>.token` sidecar. If the binary or Mac is absent the test **exits nonzero** (fails
  closed), never SKIP-to-green.

#### ClosureMap (structured — derive() input), pinned to HEAD 1df5dce

```json
{
  "behavior": "An automation command drives the live WKWebView page and its result is observable to the client.",
  "git_commit": "1df5dce502ae9a1433573e8ba5ba2e0506fbafcb",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "loaded_page",         "module": "src/wkwebview_shim.m",         "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_request",      "module": "src/automation_server.zig",    "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "router_command",      "module": "src/automation/router.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "engine_execute",      "module": "src/automation/engine.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "pageport_call",       "module": "src/automation/page_port.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                     "seedable_store": null },
    { "id": "wk_port_adapter",     "module": "src/automation_wk_port.zig",   "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                     "seedable_store": null },
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

> `highest_new_connector` = `wk_port_adapter` (node 5). `zb_app_run` is the resolvable symbol
> that enters the macOS main run loop (the real driver for the async WK edge); it resolves at
> 1df5dce (wkwebview_shim.m:788). `seedable_store`/`read_path` name functions MS2 *adds* on
> macOS — honest, since the whole chain below the socket is new on this platform; derive() runs
> in build-time, and the adapter staged in the research doc is promoted here.

**Gate (MS2a/b/c):** three gates, each a real-binary macOS e2e on both arches. **MS2 is not a
UI slice** (no visible chrome beyond the page), but MS2b native input should get a real-screen
confirmation that a native click visibly actuates the page, coordinated by the orchestrator.
Coordinate closely with **BlackRobin** (shim/ABI owner) and **BlueBeaver** (engine/router/port).

---

## MS3: Site-flow parity on macOS

**Goal.** LinkedIn/Instagram/X flows behave identically on macOS, including per-action approval
and dry-run, now that MS2 provides the automation primitives.

### Behavior MS3.1: a committing flow runs end-to-end on macOS
**Given** a logged-in fixture (session cookie present via the cookie port) and MS2 landed,
**When** a client runs `linkedin.*`/`instagram.*`/`x.*` (social_flow_routes.zig:100-104),
**Then** each step runs as an ordinary router command through the WK port, pacing/dry-run work
(social_routes.zig, pacing_store.zig), and the login gate reads the session cookie via the
macOS cookie port.

### Behavior MS3.2: cookie port on macOS (WKHTTPCookieStore)
**Given** the flows need cookie reads/writes,
**When** `cookie.*` runs,
**Then** a new `src/automation_wk_cookie_port.zig` (gated `os.tag == .macos`) implements
`CookiePort` (cookie_port.zig) over `WKHTTPCookieStore` — same contract as
`automation_gtk_cookie_port.zig`.

### Behavior MS3.3: every social write still requires per-action approval
**Given** the carried-over decision (per-action approval for all social writes),
**When** a flow reaches a committing action,
**Then** it is gated by the same approval path as Linux (the broker/approval logic is shared
code) — no macOS-specific bypass. (Approval UI lands in MS4; MS3 asserts the gate exists and
refuses un-approved writes.)

- **Files touched:** `src/automation_wk_cookie_port.zig` (new), `src/app.zig` (wire the mac
  cookie port), flow code unchanged (platform-neutral).
- **Closure (MS3):** LEAF for most flow-step logic (platform-neutral Zig already covered by
  Linux closure tests); **BLOCKING** for the cookie-gated login read → reuse the MS2 closure
  pattern with the cookie store as SOURCE and the flow result as OBSERVABLE. ClosureMap
  analogous to MS2 with `automation_wk_cookie_port` as the new connector; pinned to the then-
  current HEAD at build time.

**Gate (MS3):** real-binary macOS flow e2e (dry-run against a fixture; no live sites), both
arches. Not a UI slice. Coordinate with **BlueBeaver** (flows owner).

---

## MS4: AppKit agent drawer + Keychain + approval card

**Goal.** A native AppKit drawer matching the Linux UX the user accepted, isolated from page
worlds, with Keychain-backed secrets and the approval card. **UI slice** — real-screen check on
the user's Mac required.

### Design
- New `src/agent_drawer_mac.m` (+ a thin `src/agent_drawer_mac.zig` for the portable geometry/
  animation/persistence already in `agent_drawer.zig:16-181`, reused verbatim). Mounted from
  `zb_window_new` (wkwebview_shim.m:880) when `zb_app_get_agent_drawer()` is true — the macOS
  analog of `zb_drawer_attach`.
- **Dock:** the drawer is a bottom `NSView` and the WKWebView's frame is resized **above** it
  (the macOS analog of the `ZbDrawerHost` size-allocate; no overlay over the accelerated layer,
  honoring the NVIDIA lesson — on macOS WKWebView is also GPU-composited).
- **Floating "S" icon:** a borderless draggable `NSView`/child `NSWindow` button, hidden while
  the drawer is open, with click-vs-drag (6 px, agent_drawer.zig:27-29), keyboard move, and
  `agent-drawer.json` position persistence (agent_drawer.zig:148-181, reused).
- **Fold:** the `-` button top-right animates the panel into the icon's last position over the
  shared 180 ms cubic ease-out (agent_drawer.zig:86-103, reused), using `NSAnimationContext`/a
  `CVDisplayLink`/timer as the macOS analog of the GTK frame-clock tick.
- **Isolation:** the drawer is native AppKit views — structurally isolated from page JS worlds,
  like the GTK drawer (no webview, no shared content world).
- **Secrets:** a new macOS backend in `src/agent_secrets.zig`'s abstraction storing the token in
  the **Keychain** (`Security.framework` `SecItem*`) instead of libsecret; token shape
  validation (agent_secrets.zig:12-22) reused; token still reaches the helper only on fd 3.
- **Approval card:** the native row specified in the drawer plan §D10 — only the Approve handler
  mints grants (shared logic); AppKit presentation.

### Behavior MS4.1: the drawer docks and resizes the page above it
**Given** `--agent-drawer on`,
**When** the user opens the drawer,
**Then** a bottom AppKit panel appears and the WKWebView is laid out above it (page not
overlaid), with the geometry from `drawerRect` (agent_drawer.zig:76-82, reused).

### Behavior MS4.2: the floating "S" icon drags, persists, and hides while open
**Given** the icon visible,
**When** the user drags it (>6 px) or arrow-keys it, then opens the drawer,
**Then** the icon moves and its center-ratio position is written to `agent-drawer.json`
atomically (reused logic), and the icon is hidden while the drawer is open.

### Behavior MS4.3: `-` folds the panel into the icon's last position
**Given** the open drawer,
**When** the user clicks `-` (or Escape / Ctrl+Shift+Space-equivalent),
**Then** the panel animates into the icon's last position over 180 ms cubic ease-out and the
icon reappears focused.

### Behavior MS4.4: conversation scrolls with input pinned at the bottom; bubbles inert
**Given** the open drawer,
**When** messages arrive and the user types,
**Then** bubbles render as inert text (no markup execution), the list sticks to bottom with a
"new messages" affordance, and the multi-line input sits at the bottom (Enter sends,
Shift+Enter newline) — matching agent_drawer.c:476-596.

### Behavior MS4.5: secrets store in Keychain; token reaches the helper on fd 3 only
**Given** the Secrets window,
**When** the user saves a long-lived token,
**Then** it is validated (shape), stored in the Keychain, never in env, and handed to the helper
only on fd 3.

- **Property (MS4.2 persistence):** roundtrip — `parse(write(ratios)) == ratios` for any clamped
  position in [0,1]² (reuse the Linux property test; it is platform-neutral in `agent_drawer.zig`).
- **Closure (MS4):** the drawer↔helper↔broker chat round-trip is **BLOCKING** but its helper side
  is MS6; in MS4 the drawer shows "agent not available" until MS6 wires the helper (mirroring the
  Linux S2 state). MS4's own closure is the UI render + icon-position persistence (LEAF for
  persistence; the render is verified by the real-screen check, not a socket closure test).
- **EXECUTION / real-screen:** add a macOS `drawer-open` case (and `secrets-window`,
  `approval-card`) to the real-screen check; the orchestrator runs it on the user's Mac. **Not
  approved until it passes on the user's screen.** The offscreen/snapshot pass is necessary but
  not sufficient (the NVIDIA lesson applies to macOS GPU compositing too).

**Gate (MS4):** real-binary macOS drawer e2e (snapshot + socket census of the view tree, the
macOS analog of the `DRAWER windows` row) on both arches, **plus** the real-screen check.
Coordinate with **BlackRobin** (drawer owner).

---

## MS5: Seatbelt sandbox backend behind the shared interface

**Goal.** Define the `SandboxBackend` interface, refactor the Linux bwrap path behind it
(behavior-preserving), implement the **macOS Seatbelt backend**, and encode the one-day spike's
proofs as **failing-first** e2e on a Mac. Carries over all sandbox decisions.

### Design (from `2026-10-14-macos-sandbox-option.md`, read fully)
- `SandboxBackend` interface (see spine above). Linux impl = existing bwrap/seccomp/nested-PID
  wrapped; macOS impl = SBPL profile + app-side launcher.
- Seatbelt profile: `(deny default)`; deny-default reads; **no `same-sandbox` task-port or
  process-info rights**; allow only `localhost:<proxy>`, `localhost:51091`, `localhost:31337`;
  tiny mach-lookup (no WindowServer, no mDNSResponder); profile **file** + `-D` params (not
  inline, avoid ARG_MAX); fixed `/usr/bin/sandbox-exec` path.
- **Hooks spawned app-side**, each in its own profile (profiles don't nest): a macOS
  `zb-hook-run` that asks the app (outside the sandbox) to spawn the hook under its own profile,
  passing stdio over `SCM_RIGHTS`.
- Orphan cleanup: a launcher watching the browser via kqueue `NOTE_EXIT` + pipe EOF + PID
  tracking (the macOS analog of PDEATHSIG/PID-namespace teardown).
- Token route unchanged (FIFO→socketpair→fd 3); on macOS the CLI reopens `/dev/fd/3` (verify in
  the spike — research unverified item 11).

### Behavior MS5.1 (failing-first): a hook cannot read the CLI's memory or args
**Given** a provisioned agent home with a malicious hook and the token in the file store,
**When** the hook runs `task_for_pid(cli)`, `sysctl KERN_PROCARGS2` on the CLI, `proc_pidinfo`,
and `lldb -p <cli>`,
**Then** each fails (the macOS analog of the Linux S3.9 proof, drawer plan:829), proven in the
real binary on a Mac. **Red first:** before the profile denies task-port/process-info, the reads
succeed; the test asserts the denial.

### Behavior MS5.2 (failing-first): network rules hold
**Given** the Seatbelt profile + host allowlist proxy,
**When** the agent connects to the proxy port, `:51091`, `:31337`, then to `127.0.0.1:5432`,
`1.1.1.1:443`, and a DNS lookup,
**Then** the first three succeed and the last three fail; `api.anthropic.com` is allowed only via
the host proxy's hostname check (shared code), not by the profile.

### Behavior MS5.3 (failing-first): the fd-3 token hand-off works with the macOS CLI
**Given** the FIFO→socketpair→fd-3 route,
**When** the macOS CLI starts under the profile,
**Then** it reads the token from `/dev/fd/3` and authenticates (probe against a loopback
server, like `probe_r1` setup.py:722-758), and no live CLI process environment contains the
token.

### Behavior MS5.4 (failing-first): no survivors after `kill -9` of the browser
**Given** the agent running with a hook that double-forks and `setsid`,
**When** the browser is `kill -9`'d,
**Then** within ~1 s no helper, CLI, or hook process remains (via the kqueue/pipe-EOF launcher;
if a `setsid` escape survives, the dedicated-agent-user `kill(-1)` scheme is measured and
recorded as the fallback).

### Workflow Closure (MS5.1 — token isolation is the load-bearing security belt)

#### Production Operation Chain
`token stored (file/Keychain) -> helper reads on fd 3 -> Seatbelt launcher spawns CLI under profile -> CLI holds token in memory -> hook spawned app-side under its own profile -> hook attempts task_for_pid/KERN_PROCARGS2/proc_pidinfo on CLI -> kernel denies -> observable: the hook's recorded read result is "denied" and no token bytes appear`

#### Closure Test: "A hook cannot read the CLI's token from memory or args under Seatbelt."   [BLOCKING: crosses the app↔sandbox spawn boundary and the kernel enforcement seam]
- **SOURCE (seed only):** the stored token (file store `agent-home/secrets/claude-token`, or
  Keychain in MS4) + the provisioned fixture SAI with the malicious hook.
- **TRIGGER (start):** the real browser launching the agent (the production entrypoint
  `zb_agent_run_sync`, agent_host.c) — boundary = highest_new_connector = the macOS
  `SandboxBackend` launcher (new in MS5).
- **DRIVERS:** none async in the observable path — the hook runs and its read either returns
  bytes or EPERM synchronously; the launcher's kqueue watcher is exercised by MS5.4, not here.
- **OBSERVE (assert via):** the hook's recorded attempt result (a file the hook writes under the
  scratchpad) scanned for the canary token and for the syscall return codes — the production
  read path the e2e uses, like the Linux canary scanner (agent_secrets_test.py:247-254).
- **FORBIDDEN SPAN:** the sandbox launcher internals, the profile application, the CLI process —
  the test seeds only the token + hook and observes only the hook's recorded result.
- **RED-AT-SEAM proof:** disable the profile's task-port/process-info denies → the hook reads the
  token → the test goes **red** (canary found). With the denies on, canary absent → green.
- **DRIVABILITY:** store seam = the token store is seedable (always). No async driver needed in
  this span. If the Seatbelt backend cannot deny the read without a dedicated user, that is a
  BLOCKING finding → MS5.4's `kill(-1)` scheme / VM fallback bead.
- **EXECUTION (must run):** runs the real binary on a Mac via `mac_session.py`; needs
  `/usr/bin/sandbox-exec` and the bundled CLI. Missing → **exit nonzero** (fails closed).

> ClosureMap for MS5.1 is emitted at build time pinned to the then-current HEAD (its symbols —
> the `SandboxBackend` launcher, the hook-run app spawn — are created in MS5, so the map is
> written when they resolve, per the derive() symbol-resolvability rule).

**Gate (MS5):** real-binary macOS sandbox e2e (MS5.1–MS5.4) on both arches; the Linux bwrap gate
stays green through the interface refactor. Not a UI slice. The one-day spike (research §"What a
one-day spike must prove") is executed on a Mac by an agent and its results recorded as the red→
green transitions. Coordinate with **BlueBeaver** (helper/sandbox) and the orchestrator (spike
scheduling).

---

## MS6: Agent helper on macOS

**Goal.** Run the Python agent helper and the Claude Agent SDK inside the Seatbelt sandbox, with
the drawer wired to it, so a chat session streams replies — the macOS analog of the Linux P0+S5.

### Behavior MS6.1: the helper runs under Seatbelt and emits `ready`
**Given** the Seatbelt backend (MS5) and a provisioned home,
**When** the browser launches the helper (`launch`/`chat`, the macOS launch path replacing the
bwrap `os.execv` with the `SandboxBackend` macOS impl),
**Then** the helper starts under `sandbox-exec`, reads the token on fd 3, and emits a `ready`
frame validated by `agent_protocol.zig` (platform-neutral, already covered by
`agent_protocol_test.zig`).

### Behavior MS6.2: a chat round-trip streams assistant deltas to the drawer
**Given** the drawer open (MS4) and the helper ready,
**When** the user sends a prompt,
**Then** the helper drives the SDK/CLI and streams `assistant_delta`/`assistant_message` frames
that render in the AppKit drawer (the macOS analog of the Linux S5 chat closure).

### Workflow Closure (MS6.2 — drawer↔helper↔broker chat)

#### Production Operation Chain
`drawer send (AppKit) -> app frame on helper stdin -> chat.py Session -> ClaudeSDKClient (CLI under Seatbelt) -> assistant frames on stdout -> agent_protocol.zig validate -> drawer bubble (AppKit)`

#### Closure Test: "A prompt typed in the macOS drawer produces an assistant reply rendered in the drawer."   [BLOCKING: crosses the app↔helper process boundary and the async SDK streaming edge]
- **SOURCE (seed only):** the prompt text + a fixture/fake Claude API (the macOS e2e uses the
  same `FakeAnthropicApi` seam as Linux, honored only under `--e2e-protocol`).
- **TRIGGER (start):** the drawer Send action (the AppKit handler, new in MS4) — boundary =
  highest_new_connector (the macOS drawer→helper wiring, new in MS6).
- **DRIVERS (async edge):** the SDK streaming → the helper's real stdin/stdout pump
  (chat.py `_pump`) and the 50 ms delta coalescer, driven by the real process, not mocked.
- **OBSERVE (assert via):** the rendered drawer bubble text (read through the e2e's view-tree/
  text census over the socket or a snapshot), not the raw frame stream.
- **FORBIDDEN SPAN:** `chat.py` Session, the SDK client, the frame validator — seeded/mocked none
  (only the upstream API is faked, as on Linux).
- **RED-AT-SEAM proof:** disconnect the drawer→helper wiring → the prompt produces no bubble →
  red. Wired → green.
- **DRIVABILITY:** the fake-API seam is the injected upstream (present under `--e2e-protocol`);
  the streaming driver is the real helper process. No required seam missing.
- **EXECUTION (must run):** real binary + helper venv on a Mac via `mac_session.py`; missing venv
  → **exit nonzero**.

> ClosureMap emitted at build time pinned to then-current HEAD (symbols created in MS4/MS6).

**Gate (MS6):** real-binary macOS chat e2e on both arches; **real-screen check** of a streamed
reply in the drawer (UI-adjacent), orchestrator-run. Coordinate with **BlueBeaver** (helper) and
**BlackRobin** (drawer render).

---

## MS7: Developer-ID signing + hardened runtime + notarization (gated on the Apple Developer ID)

**Goal.** Turn the ad-hoc path into a Developer-ID-signed, hardened-runtime, notarized, stapled
universal `.dmg`. **Deferred until the user has the Developer ID**; designed small by MS1.3.

### Behavior MS7.1: the release bundle is Developer-ID-signed + hardened-runtime
**Given** the Developer ID in the Mac keychain,
**When** the release gate signs,
**Then** `codesign --sign "Developer ID Application: …" --options runtime --entitlements
packaging/macos/entitlements.plist --deep` succeeds and `codesign --verify --strict` passes on
both slices.

### Behavior MS7.2: the `.dmg` is notarized and stapled
**Given** the signed bundle,
**When** the release gate submits it,
**Then** `xcrun notarytool submit --wait` returns `Accepted`, `xcrun stapler staple` succeeds,
and `spctl --assess --type execute` accepts the `.app` — proven on a Mac.

- **Files touched:** `packaging/macos/build-dmg.sh` (swap identity, add `--options runtime` +
  entitlements + `notarytool`/`stapler`), `packaging/macos/entitlements.plist` (finalize).
- **Closure:** LEAF (packaging assertion, no cross-process product behavior) — assert via
  `codesign --verify --strict`, `spctl --assess`, and `stapler validate`.
- 🔴 Red: the release gate asserting a Developer-ID identity + hardened runtime + notarization
  ticket; red today (ad-hoc, unsigned-for-distribution). 🟢 Green: once the ID exists. 🔵 Refactor:
  one signing function shared by MS1 (ad-hoc) and MS7 (Developer ID) selected by an env/flag.

**Gate (MS7):** release gate on both arches; the result is a distributable `.dmg`. Not a UI slice.
**Blocked on:** the user obtaining the Apple Developer ID (tracked as a bead dependency).

---

## Per-slice gate protocol (all slices)

Mirrors the drawer plan §1102, adapted for macOS:
1. Mail "taking the gate slot" only for the gate run itself (gate slot rules per
   `[[gate-slot-from-mail]]`; docs-only commits are exempt).
2. Write the slice's red tests; record the red runs (on a remote Mac for e2e).
3. Green. 4. Refactor (apply the refactor checklist; remove duplication).
5. Quiet gate from a clean `git archive HEAD` + the slice's files, through the macOS gate.
6. Commit only the slice's files (shared-worktree rule: stage only your own files).
7. Mail RoseCat (cod_1) for review.
8. For a UI slice (MS4, and MS6's reply render): add the slice's case to the macOS real-screen
   check; the orchestrator runs it on the user's Mac. **Not approved until it passes there.**
A slice is not done until its closure e2e was **observed to execute** with nonzero assertions;
"SKIP" counts as UNCLOSED.

## Testing infrastructure summary

- **New:** `tests/e2e/mac_session.py` (macOS launcher/guardian, no Xvfb), per-slice
  `tests/e2e/mac_*_test.py`, macOS cases in `tests/manual/real_screen_check.py` (or a
  `mac_real_screen_check.py` sibling), two-arch `tests/mac/gate.sh`.
- **Reused platform-neutral:** `automation_server.zig`, `router.zig`, `engine.zig`,
  `page_port.zig`, `agent_protocol.zig`, `agent_drawer.zig`, `agent_secrets.zig` (logic),
  social-flow Zig, the Python SDK client.
- **Both arches every run** (Intel + Apple Silicon over Tailscale SSH).

## References

- Research: `thoughts/searchable/shared/research/2026-10-14-14-19-macos-launch-support-surface.md` (1df5dce) + its `.closure-adapter.py`
- Sandbox: `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md`, `…/2026-10-14-agent-sandbox-redteam.md`
- Drawer plan (conventions, real-screen check §7.1): `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md`
- Review log (NVIDIA/real-screen, cross-target integrity): `thoughts/searchable/shared/reviews/2026-10-10-automation-integration-review.md`
- Prior WKWebView backend plan: `thoughts/searchable/shared/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md`
- Bead `zigBrowser-8g7` (M9 render + ping/pong DONE on Intel Mac)
- Key code anchors: build.zig:1107-1184, 79-105, 241-272; src/wkwebview_shim.m:788-888; src/automation_gtk_port.zig:22; src/automation_platform.zig:90-95; src/webkit.zig:48/72/91; packaging/macos/build-dmg.sh:90; Info.plist:21-22; tests/mac/{build-on-mac,gate}.sh

## Open Questions (for RoseCat's review)

1. Native input: is responder-chain `NSEvent` delivery sufficient for all event types, or does
   any require TCC-gated `CGEventPost`? (MS2b risk; prove in the slice.)
2. Does the macOS Claude CLI reopen fd 3 via `/dev/fd/3` under Seatbelt as assumed? (research
   unverified item 11; MS5.3 proves it.)
3. Is `sandbox-exec` still accepted for custom profiles on the test Macs' OS versions? (research
   flags SDK-27 kill risk; if not, MS5 pivots to the VM fallback bead.)
4. Should the Linux bwrap refactor behind `SandboxBackend` be its own pre-MS5 Linux slice to keep
   the Linux gate isolated from macOS churn?
5. Slice sizing: is MS2's three-part split (a/b/c) the right cut, or should health/recover (MS2c)
   be its own slice given the recover state machine's size?
