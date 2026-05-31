---
date: 2026-05-31T16:52:41-04:00
researcher: maceo (git: tha-hammer)
git_commit: de8bdcc34374e06c4f77efc4bda994b2654739f4
branch: master
repository: zigBrowser
topic: "Slice 3/4 — full JS↔Zig IPC command surface + Windows/macOS cross-OS backends: what is defined today vs future seam"
tags: [research, codebase, ipc, webkit-shim, nav-policy, cross-os, app-shell, slice-4]
status: complete
last_updated: 2026-05-31
last_updated_by: maceo
related_beads: [zigBrowser-19n, zigBrowser-5ir]
---

# Research: Slice 3/4 — full IPC command surface + Windows/macOS cross-OS backends

**Date**: 2026-05-31 16:52 -0400
**Researcher**: maceo (git: tha-hammer)
**Git Commit**: de8bdcc34374e06c4f77efc4bda994b2654739f4
**Branch**: master
**Repository**: zigBrowser

## Research Question
Slice 3/4 of zigBrowser (the Tauri-alternative app shell): the full JS↔Zig IPC command surface (how the Slice 2 `zbHost` handler / `ipc.dispatch` table extends into a complete command API — registration, envelope, reply, error model, the "Slice-4 seam") AND the Windows (WebView2) / macOS (WKWebView) cross-OS backends (what the current WebKitGTK C-shim seam in `src/webkit_shim.{c,h}` and `src/webkit.zig` abstracts, where the per-OS boundary lives, and what each backend would bind). Document what the codebase and its plans (ENG-0003 Slice 1, ENG-0004 Slice 2) actually define today vs what is left as future seam. Documentarian only: describe what IS.

## Summary
As of this commit, zigBrowser's differentiator surface — the JS↔Zig IPC bridge and the navigation-control / sub-window model — is implemented entirely against **one** backend (WebKitGTK + GTK3). The cross-OS (WebView2 / WKWebView) backends exist only as an explicitly-deferred Slice-4 plan item, not as code.

The IPC command API is a three-command table (`ping`, `add`, `os.info`) expressed as a literal if-chain in `src/ipc.zig` `dispatch()` ([ipc.zig:14-38](src/ipc.zig)); that if-chain is exactly what the ENG-0004 plan calls the "Slice-4 command surface seam." JS reaches it through a `zbHost` script-message handler registered on **every** window's `WebKitUserContentManager` ([webkit_shim.c:611-629](src/webkit_shim.c)); the callback reads the message string, hand-parses a `{cmd,args}` envelope, and crosses into Zig via the weak C-ABI export `zb_ipc_dispatch(cmd, args_json, **out_result, **out_err) -> c_int` ([ipc.zig:40-72](src/ipc.zig)). Success replies with a typed JS value built by `jsc_value_new_from_json` + `webkit_script_message_reply_return_value`; errors reply with `webkit_script_message_reply_return_error_message`, rejecting the JS promise ([webkit_shim.c:675,681](src/webkit_shim.c)).

The per-OS boundary **is** the plain-C `zb_*` API declared in `src/webkit_shim.h` ([h:34-45](src/webkit_shim.h)): all GTK/WebKit/JSC/GObject code lives only in the 1616-line `src/webkit_shim.c`, while the two pure, std-only Zig modules behind the seam — `nav_policy.zig` (policy decisions) and `ipc.zig` (command dispatch) — carry no WebKit dependency and are the OS-agnostic logic any future backend would reuse verbatim. A second backend would have to provide the same exported C entry points (`zb_app_run`, `zb_run_open`, `zb_run_screenshot`, `zb_version_line`, `zb_reload`, `zb_window_new`) and consume those two Zig exports unchanged. Today there is no per-OS file split, no OS `#ifdef`, and `build.zig` links `webkit2gtk-4.1`/`gtk+-3.0`/`gio-unix-2.0` unconditionally behind a hard pkg-config guard ([build.zig:7-11,53-63](build.zig)) — i.e., Linux/GTK only.

The plans confirm the split: the full multi-command IPC API and both Windows and macOS backends are listed under ENG-0004 "What We're NOT Doing" → Slice 4; the roadmap names all three system webviews "behind one Zig app-shell model" as the Slice-4 goal; and Slice 1 left only a documentation-obligation seam note for macOS. Tabs / address-bar / bookmarks are **cut**, not deferred.

## Detailed Findings

### IPC command surface today (`src/ipc.zig`)
The command API is a literal if-chain in `dispatch(allocator, cmd, args_json) IpcError![]const u8` ([ipc.zig:14-38](src/ipc.zig)):
- `"ping"` → `expectNoArgs`, returns the 6 bytes `"pong"` ([ipc.zig:15-18](src/ipc.zig)).
- `"add"` → `parseAddArgs`, `i128` sum, decimal text via `allocPrint` ([ipc.zig:20-24](src/ipc.zig)).
- `"os.info"` → `expectNoArgs`, `std.posix.uname()`, JSON object `{sysname,release,machine}` via `std.json.fmt` ([ipc.zig:26-35](src/ipc.zig)).
- fall-through → `error.UnknownCommand` ([ipc.zig:37](src/ipc.zig)).

Each command returns **canonical JSON text** (a JSON string keeps its quotes; a number is bare). Error model: `IpcError = error{UnknownCommand, BadArgs}` ([ipc.zig:3-6](src/ipc.zig)) mapped to codes 1/2 by `ipcErrorCode` ([ipc.zig:121-126](src/ipc.zig)). Envelope validation runs Zig-side over `std.json.Value`: `expectNoArgs` accepts empty/whitespace/`null`/`{}` ([ipc.zig:74-89](src/ipc.zig)); `parseAddArgs` requires a 2-key object with `a`,`b` ([ipc.zig:91-111](src/ipc.zig)); `valueToI64` accepts `.integer`/`.number_string` ([ipc.zig:113-119](src/ipc.zig)).

**Connection:** this if-chain is the concrete artifact the ENG-0004 plan labels the "Slice-4 command surface seam" — extending the command API means adding branches here.

### IPC C-ABI boundary (`zb_ipc_dispatch`)
`pub export fn zb_ipc_dispatch(cmd: [*:0]const u8, args_json: [*:0]const u8, out_result: *?[*:0]const u8, out_err: *?[*:0]const u8) c_int` ([ipc.zig:40-72](src/ipc.zig)) is the FFI adapter wrapping the pure `dispatch`. It nulls both out-params ([ipc.zig:46-47](src/ipc.zig)), backs `dispatch` with a **threadlocal 8 KB scratch** via `FixedBufferAllocator` ([ipc.zig:10,49-50](src/ipc.zig)), spans the C strings ([ipc.zig:52-53](src/ipc.zig)); on error copies `@errorName` into a threadlocal 128-byte err buffer and returns `ipcErrorCode` ([ipc.zig:55-62](src/ipc.zig)); on success copies into a threadlocal 4 KB result buffer and returns 0 ([ipc.zig:64-71](src/ipc.zig)). `copyToCStr` null-terminates and fails closed if oversize ([ipc.zig:128-133](src/ipc.zig)).

**Connection:** `src/webkit.zig` wraps only the **legacy one-shot** calls (`versionLine`/`runOpen`/`runScreenshot`, [webkit.zig:7-19](src/webkit.zig)). `zb_ipc_dispatch` / `zb_policy_decide` are **not** wrapped there — they cross the boundary as Zig→C *exports* the shim links weakly, while `zb_app_run` is called from `app.zig` via `@cImport` ([app.zig:8-10,26](src/app.zig)). The seam is declared in [webkit_shim.h:34-45](src/webkit_shim.h) (entry points + opaque `ZbApp`/`ZbWindow` at [h:18-19](src/webkit_shim.h), `ZB_MAX_WINDOWS=16` at [h:16](src/webkit_shim.h), `ZB_EXIT_*` at [h:21-32](src/webkit_shim.h)); the comment at [h:42](src/webkit_shim.h) marks `zb_policy_decide`/`zb_ipc_dispatch` as "Track-B owned exports; if unavailable … the shim fails closed."

### IPC wiring inside `webkit_shim.c`
The main window creates a UCM (`webkit_user_content_manager_new`, [webkit_shim.c:1143](src/webkit_shim.c)), builds the view with it, then `g_object_unref`s the caller ref ([webkit_shim.c:1150-1152](src/webkit_shim.c)). `zb_window_new` re-fetches the view's UCM and `g_object_ref`s it into `ZbWindow.ucm` ([webkit_shim.c:976-978](src/webkit_shim.c)); child views from `webkit_web_view_new_with_related_view` get their own default UCM but flow through the same path ([webkit_shim.c:702,707](src/webkit_shim.c)). `install_ipc_handler` ([webkit_shim.c:611-629](src/webkit_shim.c)) unregisters then `register_script_message_handler_with_reply(ucm, "zbHost", NULL)` ([:619](src/webkit_shim.c)) and connects `script-message-with-reply-received::zbHost` → `on_ipc_message_received` ([:627](src/webkit_shim.c)); it is called unconditionally from `zb_window_new` ([webkit_shim.c:1009](src/webkit_shim.c)), so **every** window (main and child) gets `zbHost`.

The callback `on_ipc_message_received` (definition at [webkit_shim.c:631](src/webkit_shim.c)) guards `jsc_value_is_string` ([:641-647](src/webkit_shim.c)), reads `jsc_value_to_string` ([:649](src/webkit_shim.c)), hand-parses `cmd` (parser at [:362-407](src/webkit_shim.c)) and `args` defaulting to `"{}"` when absent (parser at [:409-485](src/webkit_shim.c)), then `call_ipc_dispatch` invokes the weak `zb_ipc_dispatch` or a C `fallback_ipc_dispatch` ([:563-569](src/webkit_shim.c); weak decl at [:19-21](src/webkit_shim.c)). Reply: success → `jsc_value_get_context` + `jsc_value_new_from_json` + `webkit_script_message_reply_return_value` + unref ([webkit_shim.c:675](src/webkit_shim.c)); error → `webkit_script_message_reply_return_error_message` ([webkit_shim.c:681](src/webkit_shim.c)). Guard-path error replies also fire at [:642](src/webkit_shim.c) (value NULL/non-string), [:651](src/webkit_shim.c) (string-conversion NULL), and [:661](src/webkit_shim.c) (missing `cmd` → `"BadArgs"`).

Protocol lines `IPC`/`IPCERR` are emitted via `emit_protocol2`, gated on `app->e2e_protocol` ([webkit_shim.c:152-165](src/webkit_shim.c), gate at :154), with fields tab/newline-sanitized by `emit_safe_field` ([:129-138](src/webkit_shim.c)).

**Connection:** the C side stays "dumb" (string in / JSON text out) and the typing + validation live in Zig (`ipc.zig`); `jsc_value_new_from_json` is what turns the Zig-returned text back into a typed JS value.

### Navigation-control + sub-window surface
`src/nav_policy.zig` defines `Decision{use, ignore, open_in_subwindow}` ([nav_policy.zig:3-7](src/nav_policy.zig)) and `DecisionType{navigation_action, new_window_action, response}` ([nav_policy.zig:9-13](src/nav_policy.zig)) with `comptime` asserts pinning ordinals 0/1/2 for both ([nav_policy.zig:15-22](src/nav_policy.zig)). `decide()` returns `open_in_subwindow` for new-window, `use` for response, and for navigation does canonical-path containment of the candidate within `app_base` else `ignore` ([nav_policy.zig:24-38](src/nav_policy.zig)). `zb_policy_decide` maps the `c_int` dtype (unknown → `ignore`, fail-closed) and returns `@intFromEnum` ([nav_policy.zig:40-53](src/nav_policy.zig)). Containment is `file://`-only with host empty/`localhost` ([nav_policy.zig:71-83](src/nav_policy.zig)), POSIX normalization of `.`/`..` ([nav_policy.zig:110-144](src/nav_policy.zig)), and a prefix test ([nav_policy.zig:85-89](src/nav_policy.zig)).

In the shim, `on_window_decide_policy` (definition at [webkit_shim.c:898](src/webkit_shim.c), `user_data = ZbApp*`) finds the window by view ([:182-192](src/webkit_shim.c)), maps the WebKit decision type to 0/1/2 ([:598-609](src/webkit_shim.c)), extracts the candidate URI ([:571-596](src/webkit_shim.c)), applies a child `seed_pending` bypass for a child's first navigation ([:920-925](src/webkit_shim.c)), calls the weak `zb_policy_decide` or `fallback_policy_decide` ([:336-360](src/webkit_shim.c)), then dispatches: `USE` → `webkit_policy_decision_use`; `OPEN_SUBWINDOW` (valid only for NEW_WINDOW) → stash candidate in `app->pending_subwindow_seed_uri` + `webkit_policy_decision_use`, else warn + ignore + `BLOCKED`; otherwise `webkit_policy_decision_ignore` + `BLOCKED\t<candidate>` ([:928-952](src/webkit_shim.c)).

`on_window_create` (definition at [webkit_shim.c:691](src/webkit_shim.c)) guards the cap, calls `webkit_web_view_new_with_related_view` (shares process/session/cookies, [:702](src/webkit_shim.c)), routes the child through `zb_window_new` which re-wires every signal incl. `decide-policy` + `zbHost` ([:707,1009](src/webkit_shim.c)), transfers the seed URI into the child ([:712-718](src/webkit_shim.c)), and returns `GTK_WIDGET(child view)` ([:720](src/webkit_shim.c)). `javascript_can_open_windows_automatically` is enabled so `window.open` reaches `create` ([:986-989](src/webkit_shim.c)). `SUBWIN` is emitted at the child's `WEBKIT_LOAD_FINISHED`, not in `create` ([:877-878](src/webkit_shim.c)).

Structs: `ZbApp` ([webkit_shim.c:103-115](src/webkit_shim.c)) holds `windows[ZB_MAX_WINDOWS]`, `n_windows`, `app_base`, `e2e_protocol`, `print_title`, `exit_code`, `pending_subwindow_seed_uri`, and SIGINT/SIGTERM/SIGHUP source ids. `ZbWindow` ([webkit_shim.c:67-101](src/webkit_shim.c)) holds `gtk_window`/`view`/`ucm`/`context`, `current_uri`/`seed_uri`, `load_superseded`/`seed_pending`, load-state + GError fields, `suppress_success_emit`, deferred-NAV fields + a 75 ms fallback source, a `GCancellable`, a 15 s timeout source, six signal-handler ids, `is_child`, and an `app` back-pointer. (A separate `ZbShot` struct at [:33-65](src/webkit_shim.c) serves the screenshot-only path.)

### The OS-abstraction seam
The per-OS boundary **is** the plain-C `zb_*` API in `webkit_shim.h` ([h:34-45](src/webkit_shim.h)). Zig never references GTK/WebKit/GObject directly: it calls `zb_*` (via `@cImport` in [app.zig:8-10,26](src/app.zig) and externs in [webkit.zig:7-19](src/webkit.zig)) and *provides* the OS-agnostic exports `zb_policy_decide` ([nav_policy.zig:40](src/nav_policy.zig)) and `zb_ipc_dispatch` ([ipc.zig:40](src/ipc.zig)) that the shim links weakly. All WebKitGTK/JSC/GTK code is confined to the single 1616-line `src/webkit_shim.c`.

A Windows (WebView2) or macOS (WKWebView) backend would, to satisfy the **same** contract, implement the exported entry points `zb_app_run` / `zb_run_open` / `zb_run_screenshot` / `zb_version_line` / `zb_reload` / `zb_window_new` ([webkit_shim.h:34-40](src/webkit_shim.h)) and call the unchanged Zig exports for policy + IPC. **Today exactly one backend exists** — there is no per-OS file split, no OS `#ifdef`, and no second shim in the tree. The factoring that makes a swap conceivable already exists in code: `nav_policy.zig` and `ipc.zig` are pure std-only modules with no WebKit dependency.

### Build / link surface
`build.zig` `configureWebKit(module)` ([build.zig:53-63](build.zig)) adds the `src/` include path, compiles `src/webkit_shim.c` with `-std=c11` ([:55-58](build.zig)), and `linkSystemLibrary` for `webkit2gtk-4.1` + `gtk+-3.0` + `gio-unix-2.0` all `.use_pkg_config=.force` ([:60-62](build.zig)) — unconditionally, with no target/OS branch. A hard pkg-config guard (`pkg-config --exists … || exit 1`) runs as a system command that both `exe` and `tests` depend on ([build.zig:7-11,25,44](build.zig)), and both the exe (main.zig) and test (root.zig) modules call `configureWebKit` ([:19,41](build.zig)). There is no place in `build.zig` today that selects a backend by target — backend choice is implicitly "always WebKitGTK."

### Host entry + lifetime model (shared across backends)
`main.zig`'s `pub fn main(init: std.process.Init)` ([main.zig:8](src/main.zig)) builds the arena ([:9-10](src/main.zig)), calls `cli.parseArgs` ([:11](src/main.zig)), and switches ([:13-59](src/main.zig)): `.version` → print `webkit.versionLine` + newline, exit 0 ([:14-22](src/main.zig)); `.usage` → stderr, `errors.exitCode(error.Usage)=1` ([:23-31](src/main.zig)); `.open` → validate URI then exit with the raw int from `c.zb_app_run(uri.ptr, print_title, e2e_protocol)` ([:32-43](src/main.zig)); `.screenshot` → validate + `dupeZ` then `webkit.runScreenshot` ([:45-58](src/main.zig)). `cli.Command` ([cli.zig:3-18](src/cli.zig)) is `version | usage | open{url, print_title, e2e_protocol} | screenshot{url, out, w, h, print_title}`; `parseArgs` routes `--version` / `--screenshot` / else ([cli.zig:20-34](src/cli.zig)); `--e2e-protocol` is recognized **only** in the `open` form ([cli.zig:64-67](src/cli.zig)) — screenshot has no such flag.

Lifetime lives in `zb_app_run` ([webkit_shim.c:1124-1197](src/webkit_shim.c)): `$DISPLAY` check → exit 3, `gtk_init_check` → exit 4, `derive_app_base`, build the main window via `zb_window_new` ([:1160](src/webkit_shim.c)), install SIGINT/SIGTERM → `on_signal_term` and SIGHUP → `on_signal_hup` ([:1166-1168](src/webkit_shim.c)), `load_uri` + `gtk_main`, then destroy remaining windows and return `exit_code`. `on_signal_term` sets exit 130 and quits ([:1086-1112](src/webkit_shim.c)); `on_signal_hup` reloads `windows[0]` via `zb_reload(...,0)` ([:1114-1122](src/webkit_shim.c)); `app_remove_window` quits `gtk_main` when `n_windows==0` ([:294-296](src/webkit_shim.c)). Exit codes come from `errors.exitCode` ([errors.zig:22-31](src/errors.zig)). `NAV`/`LOAD_FAIL`/`SUBWIN` are emitted from `on_window_load_changed` / `on_window_load_failed` with `NAV` pinned to `WEBKIT_LOAD_FINISHED` (and a 75 ms deferred path for empty titles) ([:843-896,814-841](src/webkit_shim.c)); `zb_reload` sets `load_superseded`, cancels, `stop_loading`, then `reload[_bypass_cache]` ([:1017-1037](src/webkit_shim.c)).

### What the plans define for Slice 3/4 vs future seam
| Topic | Status | Source |
|---|---|---|
| `zbHost` handler name + JS `postMessage` API | Defined (Slice 2) | ENG-0004:220-222 |
| `zb_ipc_dispatch` C-ABI signature | Defined (Slice 2, §C14.5) | ENG-0004:383-388 |
| IPC command schema `ping`/`add`/`os.info` | Defined (Slice 2, §C14.8) | ENG-0004:436-443 |
| `ipc.dispatch` table as the Slice-4 seam | Named seam, not yet expanded | ENG-0004:705 |
| Full multi-command IPC API | Deferred to Slice 4 | ENG-0004:154-157 |
| Windows / WebView2 backend | Deferred to Slice 4 | ENG-0004:154-157; audit:87 |
| macOS / WKWebView backend | Deferred to Slice 4 | ENG-0004:154-157; audit:78,87; ENG-0003:188,250 |
| macOS seam documentation in shim | Documentation obligation noted | ENG-0003:188 |
| Download handling (`…_download`) | Documented seam, not implemented | ENG-0004:157 |
| Async IPC commands | Deferred (via `g_idle_add` path) | ENG-0004:245 |
| IPC retries | None (declared) | ENG-0004:246 |
| Sub-frame policy granularity | Deferred | ENG-0004:759 |
| Tabs / address bar / bookmarks | **Cut** (not deferred) | audit:89; ENG-0004:154-155 |

The roadmap defines Slice 4 as "Expand host command surface and cross-OS backends (WebKitGTK/WebView2/WKWebView) behind one Zig app-shell model" (audit:87) and notes macOS deferral with "keep the engine behind a thin Zig seam so the macOS backend can swap in later" (audit:78). ENG-0003 established the thin plain-C shim because `translate-c` of `webkit2.h` fails on `-pthread` (plan1:27-34). The Wails/Electron competitive framing in ENG-0004 is explicitly marked unverified pending a search (ENG-0004:30-36).

## Code References
- `src/ipc.zig:14-38` — `dispatch()` command if-chain (ping/add/os.info); the literal "Slice-4 command surface seam"
- `src/ipc.zig:3-6,121-126` — `IpcError{UnknownCommand,BadArgs}` and `ipcErrorCode` 1/2
- `src/ipc.zig:74-119` — envelope validation (`expectNoArgs`/`parseAddArgs`/`valueToI64`) over `std.json.Value`
- `src/ipc.zig:40-72` — `pub export fn zb_ipc_dispatch` C-ABI adapter; threadlocal `FixedBufferAllocator` scratch
- `src/ipc.zig:10-12,128-133` — threadlocal `scratch[8192]`/`result[4096]`/`err[128]` + `copyToCStr` fail-closed
- `src/nav_policy.zig:3-22` — `Decision`/`DecisionType` enums + comptime ordinal asserts (0/1/2)
- `src/nav_policy.zig:24-53` — `decide()` routing + `zb_policy_decide` export (unknown dtype → ignore, fail-closed)
- `src/nav_policy.zig:71-89,110-144` — `file://`-only canonical-path containment + POSIX `./..` normalization
- `src/webkit.zig:7-19` — Zig externs for the LEGACY one-shot path only (`versionLine`/`runOpen`/`runScreenshot`)
- `src/webkit_shim.h:34-45` — the plain-C `zb_*` seam (entry points + `zb_policy_decide`/`zb_ipc_dispatch`); h:42 "fails closed" note
- `src/webkit_shim.h:16-32` — opaque `ZbApp`/`ZbWindow`, `ZB_MAX_WINDOWS=16`, `ZB_EXIT_*` codes
- `src/webkit_shim.c:611-629` — `install_ipc_handler`: `register_script_message_handler_with_reply('zbHost')`@619 + signal connect@627 (every window)
- `src/webkit_shim.c:631-689` — `on_ipc_message_received` (def@631): JSCValue guard/read, cmd/args parse, `call_ipc_dispatch`, reply success/error
- `src/webkit_shim.c:675,681` — reply path: `jsc_value_new_from_json`+`return_value` (success@675) / `return_error_message` (dispatch error@681); guard errors at 642/651/661
- `src/webkit_shim.c:152-165,129-138` — `emit_protocol2` gated on `app->e2e_protocol`; IPC/IPCERR lines, `emit_safe_field` tab/newline sanitize
- `src/webkit_shim.c:898-954` — `on_window_decide_policy`: type map, candidate URI, seed bypass, USE/OPEN_SUBWINDOW/IGNORE dispatch + BLOCKED
- `src/webkit_shim.c:691-721` — `on_window_create` (def@691): `new_with_related_view`@702, `zb_window_new` re-wiring, seed transfer, returns child widget
- `src/webkit_shim.c:33-65,67-101,103-115` — `ZbShot` (screenshot-only), `ZbWindow`, and `ZbApp` struct field definitions
- `src/webkit_shim.c:956-1015` — `zb_window_new` (def@956): UCM ref@976, signals, `install_ipc_handler`@1009, window-set bookkeeping + WINCOUNT
- `src/webkit_shim.c:1124-1197` — `zb_app_run`: DISPLAY/gtk_init checks, `derive_app_base`, main window (`zb_window_new`@1160), UCM@1143, SIGINT/SIGTERM/SIGHUP@1166-1168, `gtk_main`, teardown
- `src/webkit_shim.c:843-896,814-841,1017-1037` — load-changed (NAV/SUBWIN at FINISHED), load-failed (LOAD_FAIL), `zb_reload`@1017
- `src/webkit_shim.c:294-296` — `app_remove_window` quits `gtk_main` (`gtk_main_quit`@295) when the window set empties
- `src/webkit_shim.c:1199-1201,1545-1605` — legacy `zb_run_open` (e2e_protocol=0) and self-contained `run_screenshot_internal`@1545 (ZbShot path)
- `src/main.zig:8-94` — entry, parseArgs dispatch, `zb_app_run` call, `BrowserError`→exit mapping, stdio writers
- `src/cli.zig:3-84` — `Command` union + `parseArgs`/`parseOpenArgs`/`parseScreenshotArgs`; `--e2e-protocol` only on `open`
- `src/errors.zig:22-31` — `exitCode` table (Usage 1 … Cancelled 130)
- `build.zig:7-11,53-63` — pkg-config guard + `configureWebKit` linking webkit2gtk-4.1/gtk+-3.0/gio-unix-2.0 (`.force`), unconditional/Linux-only

## Architecture Documentation
- **Single explicit FFI boundary.** All platform code is isolated behind a hand-written, macro-free plain-C header (`src/webkit_shim.h`). Zig consumes that header via `@cImport`/externs and additionally *exports* two pure functions (`zb_policy_decide`, `zb_ipc_dispatch`) back to the C side. Direction of calls crosses the boundary both ways: host→engine (`zb_app_run`, `zb_reload`, …) and engine→host (policy + IPC).
- **Weak-linked engine→host exports with C fallbacks.** The shim declares `zb_policy_decide`/`zb_ipc_dispatch` as `__attribute__((weak))` and provides `fallback_policy_decide`/`fallback_ipc_dispatch`, so the C translation unit links and runs even if the Zig exports are absent — "fails closed" ([webkit_shim.c:19-21,336-360,563-569](src/webkit_shim.c); [webkit_shim.h:42](src/webkit_shim.h)).
- **OS-agnostic logic already separated.** Navigation policy (`nav_policy.zig`) and IPC command dispatch (`ipc.zig`) are std-only with no WebKit/GTK dependency, while every GTK/WebKit/JSC/GObject call is confined to `webkit_shim.c`.
- **Per-window UCM + handler re-wiring.** Each window (main and child) owns its own `WebKitUserContentManager`, and `zb_window_new` re-installs the `zbHost` handler and all signals per window rather than relying on inheritance from a related view.
- **Stable text protocol for observation.** When `--e2e-protocol` is set, the shim emits tab-separated `NAV`/`BLOCKED`/`SUBWIN`/`WINCOUNT`/`IPC`/`IPCERR`/`LOAD_FAIL` lines, field-sanitized and flushed per line.
- **Legacy one-shot path retained.** `zb_run_open` (delegates to `zb_app_run` with `e2e_protocol=0`) and a self-contained `run_screenshot_internal` (separate `ZbShot` struct, own context, snapshot to PNG) coexist with the interactive `ZbApp`/`ZbWindow` model.

## Historical Context (from thoughts/)
- `thoughts/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md` — Slice 2 plan: §C12/§C14 IPC contract (`zbHost`, `zb_ipc_dispatch`, ping/add/os.info schema), "Slice-4 command surface seam" naming (line 705), and the "What We're NOT Doing" list deferring the full IPC API + WebView2/WKWebView backends to Slice 4 (lines 154-157).
- `thoughts/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md` — the 4-slice roadmap; Slice 4 = "Expand host command surface and cross-OS backends (WebKitGTK/WebView2/WKWebView) behind one Zig app-shell model" (line 87); macOS thin-seam deferral (line 78); tabs/address-bar/bookmarks not active commitments (line 89).
- `thoughts/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md` — §C6 thin plain-C shim rationale, `translate-c` ruled out on `-pthread` (lines 27-34); "document the WebView/Window seam for a future macOS backend" (line 188); "macOS/WKWebView (seam left in M2)" in its own "What We're NOT Doing" (line 250).

## Related Beads
- `zigBrowser-19n` — [WebKitGTK App Shell] Slice 2: navigation control + JS↔Zig bridge (open)
- `zigBrowser-5ir` — Plan Review: WebKitGTK App Shell Slice 2 (2026-05-31 Codex re-review) (open)

## Open Questions
- None blocking the research question. The codebase defines exactly one backend (WebKitGTK) and a single C-ABI seam; the Windows/macOS backends and the expanded IPC command set are present in the plans only, not in code. (The plans' Wails/Electron competitive framing is itself marked unverified in ENG-0004:30-36.)
