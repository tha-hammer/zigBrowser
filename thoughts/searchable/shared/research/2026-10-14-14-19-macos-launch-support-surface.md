---
date: 2026-10-14T14:19:00-04:00
researcher: cc_3 / JadeBeacon (Opus 4.8)
git_commit: bcc721d527feefb9bce227e40f970173405847ea
branch: zb-automation-integration-2026-10-10-11-59
repository: zigBrowser
topic: "macOS support surface for a zigBrowser launch — codebase as it is today"
tags: [research, codebase, macos, wkwebview, cross-platform, build, automation, drawer, sandbox, seatbelt, e2e]
status: complete
last_updated: 2026-10-14
last_updated_by: cc_3 / JadeBeacon
---

# Research: macOS support surface for a zigBrowser launch

**Date**: 2026-10-14T14:19:00-04:00
**Researcher**: cc_3 / JadeBeacon (Opus 4.8)
**Git Commit**: bcc721d527feefb9bce227e40f970173405847ea
**Branch**: zb-automation-integration-2026-10-10-11-59
**Repository**: zigBrowser

## Research Question

Document the codebase **as it is today** for everything a macOS launch touches, so a
TDD plan can follow. macOS is launch-critical because most of the userbase is on Mac.
Eight sub-questions: (1) platform layering and the C ABI per platform; (2)
build/toolchain, cross-compile, signing/packaging, CI; (3) the automation layer's
platform-neutral vs GTK-bound split; (4) render/media/hardware config vs WKWebView;
(5) the chat drawer GTK-vs-portable split and what AppKit must reproduce; (6) the agent
helper and sandbox Linux-only paths and the Seatbelt plan; (7) tests/e2e and a macOS
test strategy; (8) existing macOS docs and prior decisions.

This document describes what exists. It does not recommend changes.

## Summary

zigBrowser is built around **one shared C ABI header, `src/webkit_shim.h` (435 lines)**,
with three native backends selected at build time by target OS: GTK/WebKitGTK on Linux
(`src/webkit_shim.c`, ~5,670 lines), WebView2 on Windows (`src/webview2_shim.cpp`), and
**WKWebView/Cocoa on macOS (`src/wkwebview_shim.m`, 888 lines)**. The engine, automation
server, router, config modules, flow logic, token sidecar and frame validator are
platform-neutral Zig. Everything that touches a live page funnels through one vtable,
`PagePort` (`src/automation/page_port.zig`), whose only implementation is the GTK adapter
`src/automation_gtk_port.zig`, gated `supported = builtin.os.tag == .linux`
(automation_gtk_port.zig:22).

**The macOS shim today covers the 6 core app/window functions only** — `zb_app_run`,
`zb_run_open`, `zb_run_screenshot`, `zb_version_line`, `zb_reload`, `zb_window_new` — and
**none of the ~70 `zb_automation_*` / `zb_native_*` automation-bridge functions** the
Linux shim implements. A real Intel Mac (macOS 15.3) has already rendered a fixture page
and answered ping→pong under the macOS backend (bead `zigBrowser-8g7`, CLOSED,
"M9 DONE"), so the window/render/IPC seam works; the automation surface does not exist on
macOS. The capability table already models this: `.wkwebview` has `js_synthetic` input and
`network = unsupported (no_platform_api)` (automation_platform.zig:90-95).

Real macOS builds happen **natively on a remote Intel Mac over Tailscale SSH**
(`tests/mac/build-on-mac.sh`), not cross-compiled; Linux only does a no-link symbol
cross-check for `aarch64-macos`/`x86_64-macos`. Packaging produces an **ad-hoc-signed
`.dmg`** (`codesign --sign -`), with **no notarization, no hardened runtime, no
entitlements, no universal/arm64 binary**. The chat drawer is **entirely GTK3 native
widgets** (no webview, no web world) and is explicitly out of scope for macOS/Windows in
its own plan. The Python agent helper logic is portable, but its confinement is entirely
Linux-kernel (bwrap, nested PID ns, seccomp-bpf, `/proc`, `--die-with-parent`,
`memfd_create`); the FIFO→socketpair→fd-3 token route is portable POSIX. Two committed
research docs (2026-10-14) already chart the macOS sandbox replacement (Seatbelt first, VM
fallback). The e2e harness is Linux/Xvfb/X11-bound end to end; only `m9_*` tests and
`tests/mac/gate.sh` target macOS, run remotely.

## Detailed Findings

### 1. Platform layering and the C ABI (per platform)

**Backend selection** — `build.zig:1107-1114` (`resolveBackend`) maps `.linux →
gtk_backend`, `.windows → webview2_backend`, `.macos → macos_backend`, else panics
`NoBackendLinked`. `configureBackend` (build.zig:1116-1127) dispatches to one
per-backend configurator applied to both the exe module (build.zig:161) and the test
module (build.zig:191). A `pkg_guard` precondition (build.zig:142-150) runs per backend;
for macOS it is `CheckMacosBackendStep` (build.zig:79-105), which fails the build if
`src/wkwebview_shim.m` is absent.

**The three shims and the Zig binding:**

| File | Lines | Role |
|---|---|---|
| `src/webkit_shim.h` | 435 | Shared C ABI header (`@cImport`ed by Zig) |
| `src/webkit_shim.c` | ~5,670 | Linux GTK3 / WebKitGTK shim (full ABI) |
| `src/wkwebview_shim.m` | 888 | macOS Cocoa / WKWebView shim (6 core functions) |
| `src/webview2_shim.cpp` | — | Windows WebView2 shim (3 functions) |
| `src/webkit.zig` | — | Zig wrapper, `@cImport("webkit_shim.h")` at webkit.zig:4-6 |

**C ABI coverage, per platform.** The macOS shim defines exactly six functions, all
verified: `zb_app_run` (wkwebview_shim.m:788), `zb_run_open` (:834), `zb_run_screenshot`
(:838, real snapshot via `ZBSnapshotRunner`), `zb_version_line` (:853, reads the
`com.apple.WebKit` bundle version), `zb_reload` (:872), `zb_window_new` (:880). It also
calls the two Zig-implemented exports `zb_policy_decide` (`src/nav_policy.zig:40`, called
at wkwebview_shim.m:532/554/570) and `zb_ipc_dispatch` (`src/ipc.zig:41`, called at
wkwebview_shim.m:611).

Everything else in `webkit_shim.h` — the automation bridge — is **Linux-only**:
`zb_main_invoke_sync` (h:68), `zb_app_set_hw_policy`/`_media_source`/`_agent_drawer`
(h:90-122), `zb_automation_eval_json` (h:199), `zb_automation_navigate*`/`_reload`
(h:219-223), `zb_automation_list_windows`/`_close_window`/`_recover_windows`
(h:163-179), `zb_automation_list_dialogs`/`_respond_dialog` (h:238-239),
`zb_automation_get_url`/`_get_title` (h:243-244), `zb_cookies_*` (h:276-285),
`zb_set_input_files` (h:317), `zb_screenshot_png` (h:323), the six
`zb_native_scroll/_move/_pointer/_click/_key/_text` (h:331-361), and ~25
`zb_automation_debug_*`/`zb_drawer_debug_*` test hooks (h:364-424). None is present in
`wkwebview_shim.m`. The Windows shim defines only `zb_app_run`, `zb_run_screenshot`
(returns `ZB_EXIT_SNAPSHOT_FAILED`) and `zb_version_line`.

**Structural differences.** Linux uses rich `ZbApp`/`ZbWindow` C structs (window array,
ids, process groups, GObject signals per view at webkit_shim.c:1298-1329). macOS uses
two-word structs bridging to ObjC classes `ZBAppHost` (an `NSApplicationDelegate`) and
`ZBWindowHost` (a `WKNavigationDelegate`/`WKUIDelegate`/`WKScriptMessageHandlerWithReply`),
with an `NSWindow` at 1024×768 (wkwebview_shim.m:370-393). The `zbHost` script-message
handler is registered on Linux via
`webkit_user_content_manager_register_script_message_handler_with_reply(ucm,"zbHost",NULL)`
in the default world (webkit_shim.c:701-719); on macOS via
`addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"zbHost"`
(wkwebview_shim.m:367-368). Linux additionally registers `zbNavigation`/`zbFiles` in the
isolated `ZB_AUTOMATION_WORLD` ("zigbrowser-automation") and injects the automation
script (webkit_shim.c:1880-1913); macOS injects only a one-line backend marker
`window.__zigBrowserBackend = 'wkwebview'`. Linux has an explicit server-thread→GTK-thread
bridge (`auto_queue_on_gtk` webkit_shim.c:1692, `auto_job_wait` :1721,
`zb_main_invoke_sync` :1785); macOS has only `dispatch_async(dispatch_get_main_queue(),…)`
for signals (wkwebview_shim.m:228-240) and `[application run]` (:823).

**How the Zig side copes with the missing surface.**
`automation_gtk_port.zig:22` and `automation_gtk_cookie_port.zig:21` set
`supported = builtin.os.tag == .linux`; `pagePort()` returns null when unsupported
(automation_gtk_port.zig:39-41). `webkit.zig` short-circuits `preferHttp1`, `applyRender`,
`applyMediaSource`, `applyAgentDrawer` with `comptime builtin.os.tag != .linux`
(webkit.zig:36/48/72/91). `app.zig:166` does the same for `applyProfileDir`, and
`app.zig:45` rejects `--agent-setup` off Linux. `src/automation_platform.zig` holds a
capability table (verified): `.webview2 → cdp_input, network supported`;
`.webkitgtk → js_synthetic, network unsupported (web_extension_required)`;
`.wkwebview → js_synthetic, network unsupported (no_platform_api)`
(automation_platform.zig:78-97).

### 2. Build / toolchain / packaging / CI

**Per-backend linking** (all verified): GTK compiles `webkit_shim.c`, `agent_drawer.c`,
`agent_host.c` and links `webkit2gtk-4.1`, `gtk+-3.0`, `gio-unix-2.0` via pkg-config
(build.zig:1129-1147). Windows compiles `webview2_shim.cpp` as C++17 and links the
WebView2 loader + Win32 libs (build.zig:1149-1172). macOS compiles `wkwebview_shim.m`
with `-fobjc-arc` and `linkFramework("WebKit"/"Cocoa"/"Foundation")`
(build.zig:1174-1184). **No `.mm`/`.swift` files exist and no Swift interop appears
anywhere.** The macOS backend does not compile `agent_drawer.c` or `agent_host.c`.

**Cross-compilation from Linux is no-link only.** `build.zig:241-245` defines
`cross_targets` = {`x86_64-windows-gnu`+webview2 shim, `aarch64-macos`+wkwebview shim,
`x86_64-macos`+wkwebview shim}. The loop (build.zig:246-269) builds `src/main.zig` as an
**object** per target (no link, shim not compiled) and feeds it to
`tools/check_cross_symbols.py` (`--require zb_app_run --require zb_version_line`) to
verify every undefined `zb_*` symbol is defined by that target's shim. Exposed as
`zig build cross-check` (build.zig:270-272), part of `zig build test` (build.zig:993-994).
`docs/how-to-build.md:52-73` states "no SDK, no link" and that the ObjC compile + WebKit
link are "Not checked on Linux". No `-isysroot`, `MacOSX` SDK path, `xcrun`, or
`zig build -Dtarget=*-macos` exists.

**Real macOS builds are remote and native.** `tests/mac/build-on-mac.sh:25-27` tars
`src build.zig build.zig.zon tests`, scp/ssh's it to the Mac, and runs
`$HOME/.local/bin/zig build <step>` there (build-on-mac.sh:34). It deliberately does **not**
pass `-Dtarget` (comments :29-33: an explicit target stops Zig auto-detecting the Xcode SDK
framework paths, so WebKit/Cocoa/Foundation would fail to resolve). Host defaults
`ZB_MAC_HOST=maceojourdan@100.92.212.47` over Tailscale (build-on-mac.sh:14-15). The build
host is labelled `x86_64-macos` (build-on-mac.sh:6). `tests/mac/gate.sh:24` runs the build
then the `m9_*` tests remotely and copies back a render PNG.

**Apple Silicon vs Intel.** The only arch handling is the two no-link cross-check entries
(build.zig:243-244). The real Mac build is native `x86_64-macos`. **No `lipo`, universal
binary, or `arm64` branch on `target.result.cpu.arch` exists.** The M9 success (bead 8g7)
was on an Intel Mac.

**Signing / notarization / bundling** — all in `packaging/macos/build-dmg.sh`, run
remotely. `VERSION=0.2.0`, `BUNDLE_ID=com.cosmichq.zigBrowser`. It builds
`zigBrowser.app/Contents/{MacOS,Resources}`, stamps `__VERSION__` into `Info.plist`,
builds an `.icns` via `sips`+`iconutil`, then **ad-hoc signs**:
`codesign --force --sign - --deep "$APP_BUNDLE"` (build-dmg.sh:90, verified), verifies,
and makes a UDZO `.dmg` with an `/Applications` symlink (build-dmg.sh:100-105).
`packaging/macos/Info.plist` sets `LSMinimumSystemVersion` **13.0**,
`NSHighResolutionCapable` true, and `http`/`https` `CFBundleURLTypes` (verified Info.plist
lines 21-36). **Absent:** Developer ID identity, `--options runtime` (hardened runtime),
any `*.entitlements`, `notarytool`/`stapler`/`xcrun`, `productbuild`. No `build.zig` step
performs bundling/signing.

**CI.** The only workflow is `.github/workflows/playwright.yml`, `runs-on: ubuntu-latest`,
running `npx playwright test` on push/PR to main/master. It never invokes `zig` and has
**no macOS or Windows job**. No `.gitlab-ci`, `Makefile`, or `justfile`.

### 3. Automation layer — platform-neutral Zig vs GTK/WebKitGTK/X11

The automation stack is a JSON-RPC server over a Unix socket that dispatches into a Zig
engine talking to the page only through `PagePort`.

| Piece | Class | Evidence |
|---|---|---|
| Unix socket server, accept/frame loop, JSON-RPC envelope, SHA-256 constant-time auth | platform-neutral Zig | automation_server.zig:165-350, 412-460, 1478-1485 |
| Socket path planning (incl. macOS/Windows variants) | platform-neutral Zig | automation_transport.zig:5-35 (`.linux, .macos` at :29) |
| Router (dom.*/page.* parse) | platform-neutral Zig | automation/router.zig:6-25 |
| Engine: retry, queue, native-input orchestration, telemetry | platform-neutral Zig | automation/engine.zig:642-1000; automation/queue.zig |
| `PagePort` interface + `no_page` fallback | platform-neutral Zig | automation/page_port.zig:181-527 |
| `automation.js` content script (DOM actions) | page-side JS, isolated world | automation_script/automation.js, js_embed.zig |
| **GTK adapter (`PagePort` over C ABI)** | **GTK/WebKitGTK-bound** | automation_gtk_port.zig:15-78; `supported = os.tag == .linux` :22 |
| JS eval / navigate / reload / url / title / screenshot | GTK/WebKitGTK-bound | webkit_shim.c:1973, 2898-2914, 2783 |
| Native input (click/key/text/move/scroll) | GTK/GDK-bound (`gtk_main_do_event`); **no X11/XTEST/uinput** | webkit_shim.c:3373-3574, 3826-3842 |
| GTK main-thread marshaling | GTK-bound | webkit_shim.c:1692-1812 |
| `page.health` JSON + 2000 ms debounce | platform-neutral Zig | automation_server.zig:677-684, 762-783 |
| responsiveness signal source | WebKitGTK-bound | webkit_shim.c:4468-4486 |
| `page.recover` state machine, incident token, 60 s TTL, process-family logic | platform-neutral Zig | automation_server.zig:810-934, 942-1106 |
| `page.recover` action (terminate web process, wait, reload) | GTK/WebKitGTK-bound | webkit_shim.c:4110-4207 |
| Dialog routes (`dialog.get`/`respond`) | platform-neutral Zig | automation_server.zig:1123-1180 |
| Dialog capture/answer | GTK/WebKitGTK-bound | webkit_shim.c:1321, 4523-4557, 4567-4625 |
| linkedin.*/instagram.* site flows | platform-neutral Zig | automation/social_flow_routes.zig:1-104; linkedin.zig; instagram.zig |
| Cookie routes (Zig) / cookie port (GTK impl) | neutral / GTK-bound | automation/cookie_routes.zig; automation_gtk_cookie_port.zig:1-15 |
| Popups / related views (shared web process) | GTK/WebKitGTK-bound | webkit_shim.c:781-820 |
| Automation-socket token sidecar `<socket>.token` (0600, exclusive create) | platform-neutral Zig (POSIX perms) | automation_server.zig:1496-1511; app.zig:287-311 |

**Native input mechanism (verified in prior analysis):** the Linux shim builds `GdkEvent`
objects and delivers them with `gtk_main_do_event` (webkit_shim.c:3373-3377) — "Events go
through gtk_main_do_event like real input from the display"; pointer via `gdk_event_new`
+ `gdk_seat_get_pointer`, keys via `gdk_keymap_get_entries_for_keyval`. **No X11/XTEST**
in product code; the only X references are the `DISPLAY` startup check (webkit_shim.c:5155,
5599) and comments. Real XTEST input exists only in the test harness (`tests/e2e/xinput.py`).
The two token systems are distinct: the automation-socket token sidecar
(automation_server.zig:1496) and the drawer's Claude token store (`src/agent_secrets.*`,
Linux/GTK only) — neither is read by the other.

### 4. Render / media / hardware config vs WKWebView

The config pipeline is pure Zig (`src/cli.zig` parses, `src/render_config.zig` +
`src/media_config.zig` hold types/defaults, `src/webkit.zig` applies) and a GTK applier
(`src/webkit_shim.c`).

- **Render.** `RenderConfig{ hw_policy: {never,always,webkit}, renderer:
  {default,shm,mesa_egl} }`, default `{ .hw_policy=.webkit, .renderer=.shm }`
  (render_config.zig:20-35). The renderer maps to env vars —
  `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` for `shm`, `__EGL_VENDOR_LIBRARY_FILENAMES=…` for
  `mesa_egl` (render_config.zig:72-78) — set with `setenv(…,0)` (no overwrite) before
  `zb_app_run` (webkit.zig:47-62). `--hardware-acceleration`/`--renderer`
  (cli.zig:90-101/200-206). Policy reaches WebKitGTK via
  `webkit_settings_set_hardware_acceleration_policy` per view (webkit_shim.c:5000-5008,
  called 1290-1294 and 5628-5631). `webkit.applyRender` is a no-op off Linux
  (webkit.zig:48). The header comment (render_config.zig:5-14) records the NVIDIA RTX 3080
  / WebKitGTK 2.54 investigation that chose `webkit`+`FORCE_SHM`.
- **Media.** `MediaSource{on,off}`, default `on`, env `ZIGBROWSER_MEDIA_SOURCE`
  (media_config.zig:17-25). `--media-source` (cli.zig:102-107/209). When off,
  `zb_apply_media_source` calls `webkit_settings_set_enable_mediasource(FALSE)` **and**
  injects a user script that `delete`s `MediaSource`/`SourceBuffer`/… at document-start in
  all frames (webkit_shim.c:4952-4970) — because WebKitGTK 2.54 still exposes MSE with the
  setting false (comment :4947-4951). Rationale (media_config.zig:6-12): the 2026-10-11
  Instagram MSE seek-flush deadlock (WebKit bugs 320336/272975); **the default stays `on`,
  the workaround is opt-in**. (This matches the standing operational note to relaunch the
  live browser with `--media-source off`.)
- **Hardware policy decision.** Flag-then-default precedence, no env var for the policy
  itself; `webkit` (default) sets nothing on `WebKitSettings`, `never`/`always` call the
  WebKitGTK policy setter. The renderer is purely process-env, read by WebKit/EGL/web
  processes at start.
- **WebKitGTK API surface used** (no direct WKWebView equivalent documented here, only the
  surface): `webkit_settings_*` (hardware-accel policy, mediasource, JS-open-windows),
  `WebKitUserContentManager` + `webkit_user_script_new`,
  `webkit_web_context_new_with_website_data_manager`,
  `webkit_web_view_new_with_related_view` (popups). The pure Zig config modules have **no**
  WebKit dependency; `webkit.zig` is the guarded boundary.

### 5. Chat drawer — GTK-specific vs portable, and what AppKit must reproduce

The drawer is **entirely GTK3 native widgets**: no WebView, no web context, no content
world, no user-content-manager. Its isolation from the page's JS world is therefore
**structural** — the drawer is native widgets, unreachable from page JS or the automation
socket (agent_drawer.h:4-8). It is off by default (agent_config.zig:17), enabled by
`--agent-drawer on` (webkit.zig:90-97), and **not wired to any agent in this tree**
(header "No agent is connected yet (slice S2)", agent_drawer.c:6-8; Send shows "Agent not
available yet").

**Mounting & host.** `zb_window_new` calls `zb_drawer_attach(gtk_window, view, auto_id,
e2e_protocol)` when the drawer is on (webkit_shim.c:1284-1288), else adds the view
directly. `zb_drawer_attach` (agent_drawer.c:967-1007) builds a custom
`GtkContainer` **`ZbDrawerHost`** with no GdkWindow (agent_drawer.c:277-291), replacing
`GtkOverlay` — the comment (:264-276) records that `GtkOverlay` blanked the browser on the
user's NVIDIA screen. `size_allocate` cuts the page height above the panel
(agent_drawer.c:364-389); the icon/ghost draw in the page's own window via an `after`
handler on the page "draw" signal (:302, 406-415).

| Behavior | Class | Evidence |
|---|---|---|
| Bottom-dock geometry (40%, min 220, max 70%, full width) | portable logic | agent_drawer.zig:76-82 |
| Click-vs-drag (6 px), clamp, key-step (16/64 px), ratio persistence, default pos | portable logic | agent_drawer.zig:19-72 |
| Icon position file `agent-drawer.json` (atomic write) | portable logic | agent_drawer.zig:148-181 |
| Fold animation timing/easing (180 ms, cubic ease-out, lerp rects) | portable logic | agent_drawer.zig:86-103 |
| Token shape validation (16-512 printable) | portable logic | agent_secrets.zig:12-22 |
| Frame validation (`agent_protocol.zig`) | portable logic (`std` only) | agent_protocol.zig:10-80 |
| `ZbDrawerHost` custom container, no-window workaround, draw ordering | **GTK-specific, AppKit rewrite** | agent_drawer.c:277-415 |
| Floating "S" icon (GtkButton, 56 px `#d97757` circle), pointer/drag/key wiring | **GTK-specific** | agent_drawer.c:950-963, 730-818 |
| Fold driver (ghost widget, `gtk_widget_add_tick_callback`, `GdkFrameClock`) | **GTK-specific** | agent_drawer.c:628-695 |
| Panel (GtkListBox bubbles as inert `GtkLabel`, GtkTextView input, scroll-stick) | **GTK-specific widgets** | agent_drawer.c:476-565, 867-948 |
| Window shortcuts (Ctrl+Shift+Space, Escape) | GTK wiring, portable intent | agent_drawer.c:704-724 |
| Secrets window UI (not wired into build/callers) | **GTK-specific** | agent_secrets_window.c:319-393 |
| Secret Service backend (libsecret via `dlopen`) | **GTK/Linux-specific** | agent_secrets.c |
| Private-file token store (0700/0600, `O_NOFOLLOW`, statx) | Linux impl, portable rules | agent_secrets.zig:80-156 |

**Approval card:** not implemented in `src/` (no "approv" match); specified in the drawer
plan as a native row (plan §D10, :497-519) where only the Approve handler mints grants.
**What an AppKit drawer must reproduce:** the bottom dock that shrinks the page above it,
a floating draggable "S" icon with click-vs-drag and keyboard move, the 180 ms cubic
ease-out fold, native (non-web) isolation, inert-text message bubbles with stick-to-bottom,
the `agent-drawer.json` position persistence, and (for secrets) a Keychain backend in place
of libsecret. `build.zig:1125` has a `macos_backend`, but the drawer sources are added only
in `configureGtkBackend` — the drawer plan (:804) lists "macOS and Windows drawers" under
"What we are NOT doing".

### 6. Agent helper and sandbox — Linux-only paths and the Seatbelt plan

The Python helper `agent/host/zb_agent_host/` has five subcommands (`__main__.py:6-12`):
`launch` (builds the bwrap argv and `os.execv`s bwrap), `chat` (drawer helper inside the
sandbox), `setup`/`provision-runtime` (build the agent home), `contract-config` (one SDK
turn). It drives the Claude Agent SDK → bundled `claude` CLI via a generated `zb-claude`
wrapper, talks to the browser over stdin/stdout NDJSON, and reads the token on **fd 3**.

**Helper logic is portable; confinement is Linux-kernel-only:**

| Mechanism | Location | Class |
|---|---|---|
| Argv/frame/file construction, settings sanitize, copy rules, hook wrapping | sandbox.py:41-72; setup.py:78-327; provision.py:36-45 | portable Python |
| `/usr/bin/bwrap` hardcoded; main argv (`--unshare-pid/ipc/uts`, `--proc`, `--dev`, `--tmpfs`, `--ro-bind`, `--bind`, `--perms`, `--dir`, `--chdir`) | sandbox.py:13, 30-72 | Linux-only (namespaces + bind mounts) |
| `--die-with-parent` | sandbox.py:38; hook_run.py:44; setup.py:603 | Linux-only (bwrap PDEATHSIG) |
| Nested PID+IPC namespace per hook (`zb-hook-run`) | hook_run.py:33-69 | Linux-only |
| `--seccomp <fd>` + BPF program (x86_64 nums; deny ptrace/process_vm_*) | sandbox.py:69-70; seccomp.py:19-45 | Linux-only (x86_64 syscall nums hardcoded) |
| `os.memfd_create` + `F_DUPFD` (seccomp fd) | seccomp.py:51-59 | Linux-only (`memfd_create`) |
| `/proc` mounted + reads (`exe`/`stat`/`environ`) | sandbox.py:39; setup.py:644-665, 689; probe.py:79 | Linux-only |
| `PR_SET_PDEATHSIG` via `prctl` (C side) | src/agent_host.c:52 | Linux-only |
| ptrace/process_vm_* probes (ctypes) | probe.py:22-23, 74 | Linux-only |
| FIFO create/open (`os.mkfifo`) + socketpair→fd 3 handoff | token.py:63-131 | **portable POSIX** |

**Token route (R1), portable POSIX end to end:** browser → helper on fd 3
(`token.read_token(3)`, chat.py:159); helper creates a 0300 dir + a 0600 FIFO named with
`secrets.token_hex(16)` and writes `value+"\n"` from a daemon thread (token.py:63-82);
only `ZB_TOKEN_FIFO` (the path) travels in env (token.py:84-85). The `zb-claude` wrapper
opens+unlinks the FIFO, reads it, creates a `socket.socketpair()`, writes the token to one
end, `dup2`s the other onto fd 3, sets `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`, and
`os.execv`s the CLI (token.py:104-134). **No SCM_RIGHTS, no `--unshare-net`, no
`renameat2`/`openat2`/`RESOLVE_BENEATH`** anywhere in `agent/host`. The docstring
(token.py:7-9) explains the socketpair exists because the CLI reopens pipes/FIFOs through
`/proc/self/fd/3`, which blocks for a dead-writer FIFO — a `/proc`-specific behavior the
macOS sandbox research flags as needing a `/dev/fd/3` equivalent check.

**Provisioning:** atomic `dist-<n>` builds swapped via a `current` symlink
(setup.py:520-531); `COPY_ALLOWLIST` = CLAUDE.md, settings.json, SAI, hooks, commands,
skills, agents (setup.py:48); SHA-256 manifest of `.claude` (setup.py:331-339); writable
state dirs = projects/sessions/session-env/todos/statsig/debug/MEMORY bound over a
read-only `.claude` (sandbox.py:27, 57-65).

**The macOS replacement is already researched (not built).** Two committed docs
(2026-10-14) chart it:
- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md` (committed
  86ddf01): keep bwrap on Linux; the one big hole is the shared host netns; fix with
  `--unshare-net` + host allowlist proxy + named bridges for `:51091`/`:31337`. macOS →
  Seatbelt, Windows → WSL2; VM is a later pluggable backend.
- `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md` (committed
  da24aba): the Linux design cannot run natively on macOS (no namespaces, seccomp-bpf,
  `/proc`, `PR_SET_PDEATHSIG`). Build **Seatbelt first** (SBPL profile, hooks spawned
  app-side because profiles don't nest, deny all task-port/process-info except self; profile
  file + `-D` params; fixed `/usr/bin/sandbox-exec` path), with a **Virtualization.framework
  Linux VM as the fallback**. One shared backend interface covers Linux bwrap / macOS
  Seatbelt-or-VM / Windows WSL2; the proxy + port bridges are shared host-side code. The
  doc notes `src/wkwebview_shim.m` already registers `zbHost` in `WKContentWorld.pageWorld`
  and that a WKWebView `PagePort` adapter + a private `WKContentWorld` would be the macOS
  broker. Both docs list unverified XNU items to prove in a one-day spike.

### 7. Tests / e2e and the macOS test strategy

The e2e suite is Python launching the real binary through one launcher,
`tests/e2e/xsession.py`, which starts a private **Xvfb** (display `:200-:399`), writes a
cookie with `xauth`, and sets `DISPLAY`/`XAUTHORITY` (xsession.py:108-174), guarding the
process group with `prctl(PR_SET_PDEATHSIG)` and `/proc` scanning. Tests connect to the
automation Unix socket and read the `<socket>.token` sidecar (slice2_common.py:126-132).
`tests/e2e/xinput.py` drives **real X input via libX11/libXtst** (`XTestFake*`), refusing
`:0`/`:1`.

| Test / harness | Class | Evidence |
|---|---|---|
| `xsession.py`, `agent_common.py` | X11/Xvfb + Linux | Xvfb, xauth, `/proc`, `prctl`, `pidfd_open`, inotify |
| `xinput.py` | X11/Xvfb | libX11/libXtst, `xwd` |
| `agent_setup_test.py` | Linux (no display) | `/proc`, inotify, PDEATHSIG |
| `web_process_crash_test.py` | X11/Xvfb + Linux | Xvfb, XTest, `/proc`, `WebKitWebProces*` |
| `agent_secrets_test.py` | X11/Xvfb + Linux | Xvfb, XTest, dbus-daemon, gnome-keyring, `/proc` |
| `http2_goaway_test.py` | Linux-guarded | GnuTLS `LD_PRELOAD`, libsoup, gcc, openssl, Xvfb |
| `tests/manual/test_real_screen_input.py` | X11 (`:200-:399`) | real XTest guard tests |
| `tests/manual/test_real_screen_check.py` | platform-neutral | fake captures, no display (build.zig:733-740) |
| `tests/agent_protocol_test.zig` | platform-neutral | `std` only (build.zig:303-315) |
| `tests/agent_secrets_test.zig` | Linux-specific | `std.os.linux` openat/statx/mknod |
| `m8_*` | Windows only | `platform.system()=="Windows"` |
| **`m9_*` + `tests/mac/gate.sh`** | **macOS only, run remotely over SSH** | `platform.system()=="Darwin"`; gate.sh:36-44 |

Skip-vs-fail is a convention: older tests exit 77 (converted to success in `build.zig`)
when tools are missing; drawer/secrets/agent-host tests fail closed with exit 1. The
macOS-capable tests that exist today are the three `m9_*` gate tests
(`m9_render_test.py`, `m9_reply_channel_test.py`, `m9_load_fail_test.py`) that
`tests/mac/gate.sh` builds and runs on the remote Mac — i.e. the macOS test strategy today
covers render + IPC reply channel + load-fail, the same surface the 6-function shim
provides. Only `agent_protocol_test.zig` is clearly platform-neutral; everything
page-facing assumes Xvfb/X11.

### 8. Existing docs and prior decisions

- `docs/how-to-build.md:52-73` — the one user-facing cross-platform section ("Windows and
  macOS builds"): platform SDKs needed; Linux does a no-SDK no-link cross-compile; a server
  without page/cookie ports answers SDK methods or `-32011`.
- `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`
  — the primary cross-OS research: "Today exactly one backend exists — no per-OS file
  split, no OS `#ifdef`" (:74); Windows/macOS/WKWebView all "Deferred to Slice 4"; Slice 4
  = "cross-OS backends behind one Zig app-shell model", macOS a "thin Zig seam".
- `thoughts/searchable/shared/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md`
  — the full TDD plan for real WebView2 + WKWebView backends: `WebViewInitFailed=10`,
  per-OS IPC reply channels (WKWebView `WKScriptMessageHandlerWithReply`, macOS 12+),
  `aarch64-macos` target + `wkwebview_shim.m`/`configureWKWebView`, `ZbMacWindow`,
  SIGHUP noted GTK/POSIX-only.
- `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md`
  — Windows WebView2 got a real plan; "M9 (macOS/WKWebView) — deferred, HW-gated (bead
  zigBrowser-8g7); no Apple hardware".
- `thoughts/searchable/shared/plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md`
  — "macOS packaging (no Mac; M9 deferred)"; "Code signing / notarization (follow-up)".
- `thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md` — drawer
  plan, GTK-first; macOS/Windows drawers explicitly out of scope (:804).
- `thoughts/searchable/shared/research/2026-10-10-11-32-automation-layer-current-state.md` —
  current automation-layer state (closest sibling to the in-process broker).
- Bead `zigBrowser-8g7` (CLOSED): "M9 DONE on real Intel Mac (macOS 15.3): real WKWebView
  window renders real fixture page (visually verified takeSnapshot), answers ping⇒pong."

## Code References

- `build.zig:1107-1114` — `resolveBackend` (os.tag → backend)
- `build.zig:1174-1184` — `configureMacosBackend` (compiles `wkwebview_shim.m` `-fobjc-arc`; links WebKit/Cocoa/Foundation)
- `build.zig:79-105` — `CheckMacosBackendStep` (fails if shim missing)
- `build.zig:241-272` — cross-compile matrix (no-link symbol check for `aarch64-macos`/`x86_64-macos`)
- `src/wkwebview_shim.m:788,834,838,853,872,880` — the 6 macOS ABI functions
- `src/webkit_shim.h:435` — shared C ABI (full Linux coverage; 6 on macOS)
- `src/automation/page_port.zig:181-527` — `PagePort` vtable + `no_page`
- `src/automation_gtk_port.zig:22,39-78` — the only `PagePort` impl, Linux-gated
- `src/automation_platform.zig:78-97` — capability table (`.wkwebview` js_synthetic / network unsupported)
- `src/automation_server.zig:412-530,942-1106,1496-1511` — dispatch, recover, token sidecar
- `src/webkit.zig:36,48,72,91` — `comptime os.tag != .linux` guards
- `src/render_config.zig:20-78` / `src/media_config.zig:6-25` — render/media config
- `src/agent_drawer.c:277-415,628-695,950-963` / `src/agent_drawer.zig:16-181` — drawer (GTK host + portable logic)
- `src/agent_secrets.zig:7-156` / `src/agent_secrets.c` — token store (Linux/libsecret)
- `agent/host/zb_agent_host/sandbox.py:13-72`, `seccomp.py:19-59`, `token.py:63-134`, `hook_run.py:33-69` — Linux sandbox + portable token route
- `src/agent_host.c:47-55` — `prctl(PR_SET_PDEATHSIG)` child setup
- `packaging/macos/build-dmg.sh:90` — ad-hoc `codesign --sign -`; `packaging/macos/Info.plist:21-22` — `LSMinimumSystemVersion 13.0`
- `tests/mac/build-on-mac.sh:25-34`, `tests/mac/gate.sh:24-44` — remote native Mac build + `m9_*` gate
- `.github/workflows/playwright.yml` — the only CI (ubuntu-latest, Playwright, no zig/macOS)

## Architecture Documentation

The design is a **single C ABI seam** (`webkit_shim.h`) with a per-OS translation unit
chosen by `resolveBackend`, and a **single page-access vtable** (`PagePort`) with a single
GTK implementation. Platform-neutral Zig owns the socket server, JSON-RPC, router, engine,
queue, retry, telemetry, recover state machine, config types, site flows, token sidecar,
and NDJSON frame validation. The platform boundary is explicit and consistent: Zig modules
gate on `builtin.os.tag`, and the capability table (`automation_platform.zig`) names each
backend's input mode and network support ahead of any real implementation. The macOS
backend today realizes only the app/window/render/IPC seam (proven on a real Intel Mac via
bead 8g7); the automation, drawer, config-apply, and sandbox surfaces are Linux-only by
construction. The documented cross-OS intent (Slice 4) is "cross-OS backends behind one Zig
app-shell model, macOS a thin Zig seam."

## Workflow Closure Map

The core launch-critical behavior macOS must reproduce is **"an automation command sent
over the Unix socket drives the live page and the result is observable to the client."**
Below is its production operation chain as it exists on the Linux/GTK path at HEAD
`bcc721d`. On macOS this chain is intact through the socket→engine→`PagePort` nodes
(platform-neutral) but **absent from the platform-adapter node onward** — `wkwebview_shim.m`
implements none of the `zb_automation_*`/`zb_native_*` functions, and
`automation_gtk_port.supported` is false off Linux, so `pagePort()` returns null
(automation_gtk_port.zig:39-41).

Chain (source → observable), each edge with producer/consumer/registration/contract/
runtime/error/test:

1. **loaded_page** (SOURCE). The current document in window 1, loaded via
   `zb_automation_navigate_guarded` (webkit_shim.c:3076). Seed = navigate to a fixture.
   `production-called`.
2. **socket_request** (ENTRYPOINT). Producer: client; consumer:
   `automation_server.handleStream`/`handleRequestWith` (automation_server.zig:316/412).
   Registration: `server.start()` binds `$ZIGBROWSER_SOCKET` or
   `$XDG_RUNTIME_DIR/zigbrowser-automation-<nonce>.sock` chmod 0600
   (automation_server.zig:165-204, 1513-1517; app.zig:239-246). Contract: length-prefixed
   frames ≤64 KiB, `jsonrpc:"2.0"`, SHA-256 constant-time `auth` (automation_server.zig:
   331, 426-450, 1478-1485). Runtime: per-connection thread; token from `<socket>.token`.
   Error: `-32600/-32602/-32601`; bad auth rejected. Test: `automation_core_test.py`.
   `production-called`.
3. **router_command**. `automation.router.parse` → `Command` (automation_server.zig:503;
   router.zig:6-25). Error: `UnknownCommand`→-32601, `BadArgs`→-32602. `production-called`.
4. **engine_execute**. `queue.acquire` (per-page turn) then `engine.executeWith`
   (automation_server.zig:518-526; engine.zig:642). Runtime: cancel flag, queue wait,
   recover gate (`error.Recovering`→recovering reply). `production-called`.
5. **pageport_call**. `engine` → `PagePort` vtable (`evalJson`/`nativeClick`/`navigate`)
   (page_port.zig:185-205; engine.zig:642-813). Defaults: native input →
   `error.Unsupported`. `production-called` (interface); the live impl is node 6.
6. **platform_adapter** (adds/changes for macOS). GTK: `automation_gtk_port` vtable →
   C ABI `zb_automation_eval_json`/`zb_native_click`/`zb_automation_navigate_guarded`
   (automation_gtk_port.zig:56-78). Registration: `buildAutomationConfig` passes
   `automation_gtk_port.pagePort()` (app.zig:220-237). On macOS this node is **unmounted**
   (`pagePort()` → null). `production-called` on Linux; `not-found` on macOS.
7. **native_shim_effect** (adds/changes for macOS). GTK: `webkit_shim` marshals onto the
   GTK main thread (`auto_queue_on_gtk`/`auto_job_wait`, webkit_shim.c:1692/1721) and applies
   via WebKitGTK/GDK (eval `webkit_web_view_call_async_javascript_function` :1973; native
   input `gtk_main_do_event` :3373). Error: deadline → timeout code mapped by
   `mapCode` (automation_gtk_port.zig:337-350). On macOS this is **unmounted** (shim lacks
   the functions). `production-called` on Linux; `not-found` on macOS.
8. **observable_readback** (OBSERVABLE). The client reads the effect through
   `zb_automation_eval_json` (webkit_shim.c:3060, reads live DOM) or
   `zb_automation_get_url` (:3102), returned as the JSON-RPC result. Input acks are read
   via `globalThis.__zbAutomation.inputAck()` (automation_gtk_port.zig:450).
   `production-called`.

**Labels:** nodes 1-5 and 8 are `production-called` on every platform (platform-neutral
Zig + the Linux shim read fns); nodes 6-7 are `production-called` on Linux and
`not-found`/`unmounted` on macOS. **`highest_new_connector` = node 6 (platform_adapter)** —
a macOS automation slice adds the WKWebView `PagePort` adapter there, and the belt would
run from that connector down to the observable read.

**Async edge:** edge 5→6→7 crosses the Zig→C-ABI boundary, and the shim marshals the call
onto the GTK main-loop thread and blocks the caller until the loop runs the job
(webkit_shim.c:1692-1770). The real synchronous drain is the GTK main loop, entered via
`zb_automation_loop_mark` (webkit_shim.c:5211, wraps `gtk_main`); in the running browser
the loop runs continuously, so the async edge self-drains before the observe read.

### ClosureMap (structured — derive() input)

```json
{
  "behavior": "An automation command sent over the Unix socket drives the live page and its result is observable to the client.",
  "git_commit": "bcc721d527feefb9bce227e40f970173405847ea",
  "repo": "/home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59",
  "nodes": [
    { "id": "loaded_page",         "module": "src/webkit_shim.c",            "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                    "seedable_store": "zb_automation_navigate_guarded" },
    { "id": "socket_request",      "module": "src/automation_server.zig",    "is_entrypoint": true,  "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "router_command",      "module": "src/automation/router.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "engine_execute",      "module": "src/automation/engine.zig",    "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "pageport_call",       "module": "src/automation/page_port.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null,                    "seedable_store": null },
    { "id": "platform_adapter",    "module": "src/automation_gtk_port.zig",  "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                    "seedable_store": null },
    { "id": "native_shim_effect",  "module": "src/webkit_shim.c",            "is_entrypoint": false, "adds_or_changes": true,  "read_path": null,                    "seedable_store": null },
    { "id": "observable_readback", "module": "src/webkit_shim.c",            "is_entrypoint": false, "adds_or_changes": false, "read_path": "zb_automation_eval_json", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": true,  "driver": null },
    { "is_async": true,  "cross_boundary": true,  "driver": "zb_automation_loop_mark" },
    { "is_async": false, "cross_boundary": false, "driver": null }
  ]
}
```

### Closure adapter (staged proposal — `2026-10-14-14-19-macos-launch-support-surface.closure-adapter.py`)

```python
"""Closure adapter (STAGED PROPOSAL — not wired into the repo).
Derived from the ClosureMap for: an automation command drives the live page, observable to the client.
Pin: bcc721d527feefb9bce227e40f970173405847ea.
Promote into /home/maceo/ntm_Dev/zb-automation-integration-2026-10-10-11-59 and complete each TODO(promote) before use.
Speaks the 7-op contract apps/closure-oracle already talks to (mock_adapter.py).
"""
import http.server, json, sys
ASYNC_EDGES = ["e5_adapter_to_shim"]              # edge index 5: Zig->C-ABI->GTK-main-loop marshal
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []                                          # Phase-0 /seed_sink target

def handle(op, p):
    if op == "/reset":        SINK.clear(); CONNECTOR.update({e: True for e in ASYNC_EDGES}); return {"ok": True}
    if op == "/set_connector": CONNECTOR[p["edge"]] = p["enabled"]; return {"ok": True}
    if op == "/seed_sink":     SINK.append(p["value"]); return {"ok": True}
    if op == "/seed":
        # TODO(promote): load fixture into window 1 via zb_automation_navigate_guarded(p["data"])  (src/webkit_shim.c:3076)
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): send the JSON-RPC command over the automation socket -> handleRequestWith(p["args"])  (src/automation_server.zig:412)
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True): return {"ok": True}  # oracle disabled = red-at-seam
        # TODO(promote): drive the GTK main loop so the marshalled job runs — zb_automation_loop_mark/gtk_main  (src/webkit_shim.c:5211)
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return json.dumps(zb_automation_eval_json(<probe>))  (src/webkit_shim.c:3060)
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

**Sibling behavior not separately mapped (incomplete in this tree):** "drawer open → helper
→ broker → drawer bubble." The chain exists in pieces — drawer UI (`agent_drawer.c`),
helper spawn (`agent_host.c:57-74` → bwrap → `chat.py`), NDJSON validation
(`agent_protocol.zig`) — but the drawer is **not wired to the helper** (S2 only;
agent_drawer.c:6-8 "No agent is connected yet"), so the trigger→observe seam is `unmounted`
end to end. No ClosureMap/adapter is emitted for it until it is connected.

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md` — one
  backend today, cross-OS deferred to Slice 4; macOS a "thin Zig seam".
- `thoughts/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md:78,87` —
  Linux/GTK-first; macOS WKWebView deferred behind a thin Zig seam.
- `thoughts/shared/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md`
  — the WKWebView backend TDD plan (reply channels, targets, `ZbMacWindow`).
- `thoughts/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md` — M9
  macOS deferred, HW-gated (bead zigBrowser-8g7).
- `thoughts/shared/plans/2026-06-03-08-26-ENG-0007-tdd-distribution-installers-slice5.md` —
  macOS packaging + signing/notarization deferred.
- `thoughts/shared/research/2026-10-14-agent-sandbox-redteam.md` — Linux bwrap hardening;
  macOS→Seatbelt, Windows→WSL2.
- `thoughts/shared/research/2026-10-14-macos-sandbox-option.md` — Seatbelt-first macOS
  sandbox backend, VM fallback, shared backend interface.
- `thoughts/shared/research/2026-10-10-11-32-automation-layer-current-state.md` — current
  automation-layer state.

## Related Research

- `thoughts/searchable/shared/research/2026-10-14-agent-sandbox-redteam.md`
- `thoughts/searchable/shared/research/2026-10-14-macos-sandbox-option.md`
- `thoughts/searchable/shared/research/2026-10-14-almostnode-fit.md`
- `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`
- `thoughts/searchable/shared/research/2026-10-10-11-32-automation-layer-current-state.md`
- `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md`

## Open Questions

These are gaps in *today's codebase coverage* (not recommendations):

1. The macOS `PagePort` adapter and the `zb_automation_*`/`zb_native_*` implementations in
   `wkwebview_shim.m` do not exist; the entire automation surface (DOM, native input,
   health/recover, dialogs, cookies, screenshots, windows) is unimplemented on macOS.
2. No `applyRender`/`applyMediaSource`/hardware-policy equivalent exists for WKWebView; the
   config apply path is Linux-guarded.
3. No AppKit drawer, no Keychain secrets backend, no macOS approval card.
4. No macOS agent-sandbox backend exists (Seatbelt/VM are researched, not built); several
   XNU facts remain "unverified" in the sandbox docs pending a one-day Mac spike.
5. Packaging ships an ad-hoc-signed `.dmg` only — no notarization, hardened runtime,
   entitlements, or universal (arm64+x86_64) binary; the M9 validation was Intel-only.
6. CI has no macOS job; macOS tests (`m9_*`) run only via the manual remote `tests/mac/gate.sh`.
