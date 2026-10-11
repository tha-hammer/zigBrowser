---
date: 2026-10-10T11:32:03-04:00
researcher: tha-hammer
git_commit: 32362d42643417816b8e7b50deb20bd5d64dbf4d
branch: master
repository: zigBrowser
topic: "Current state of the automation layer (server, router, injected script, shim, SDKs, cookies) to continue development"
tags: [research, codebase, automation, automation_server, router, automation-js, webkit-shim, sdk, cookies, social]
status: complete
last_updated: 2026-10-10
last_updated_by: tha-hammer
---

# Research: Current state of the zigBrowser automation layer

**Date**: 2026-10-10T11:32:03-04:00
**Researcher**: tha-hammer
**Git Commit**: 32362d42643417816b8e7b50deb20bd5d64dbf4d
**Branch**: master
**Repository**: zigBrowser
**Permalink base**: `https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/` (HEAD confirmed on `backup` remote `refs/heads/master`; `gh` could not resolve `Cosmic-HQ/zigBrowser`)

## Research Question

Research the codebase so development of the automation layer can continue. Context carried in from a prior audit: the automation server acknowledges commands without executing them (`src/automation_server.zig:129-177`); `type()` sets `.value`, which has no effect on contenteditable (`src/automation_script/automation.js:255-263`); there is no select/dropdown or key-press support; there is no persistent cookie storage or cookie import; the SDK lists cookie/social commands the server does not handle; no open beads issues track automation work.

## Summary

The automation layer is made of separately built and separately tested pieces. Only one piece is wired into the running browser binary: the Unix-socket JSON-RPC server.

- **Running path today.** `zigbrowser <url> --automation-api` starts `AutomationApiServer` on its own thread, then enters the GTK main loop (`src/app.zig:38-47`). Each socket connection carries one length-prefixed JSON-RPC frame. The server validates the envelope and the optional token, calls `automation.router.parse()`, throws the parsed command away, and replies `{"ok":true,"method":<method>}` (`src/automation_server.zig:164-176`). The server holds no reference to any WebView, window, or shim function.
- **Router.** `router.parse()` accepts exactly 13 method strings: 7 `dom.*` and 6 `page.*` (`src/automation/router.zig:163-183`). Every other namespace (`cookies.*`, `social.*`, `linkedin.*`, `instagram.*`, `session.*`, `telemetry.*`) returns `error.UnknownCommand`, which becomes JSON-RPC -32601.
- **Injected script.** `src/automation_script/automation.js` defines `window.__zbAutomation.handle()`. Its ops are `query`, `getText`, `getAttribute`, `click`, `fill`, `type`, `waitFor`, and `rateLimitScan` (`automation.js:30-49`). It is embedded only into a Zig test module (`build.zig:471-481`). No shim injects it into a page. Its behaviour is tested only in Playwright's own Chromium, Firefox, and WebKit builds (`e2e/automation_script.spec.ts`), never inside zigBrowser.
- **WebKitGTK shim.** The only native-to-JS call is `webkit_web_view_evaluate_javascript(…"document.title"…)`, and only on the screenshot path (`src/webkit_shim.c:1262`). There are no user scripts. There is no main-thread hand-off primitive (`g_idle_add` / `g_main_context_invoke`). The only cookie code is `set_accept_policy(ACCEPT_ALWAYS)` on the default `WebKitWebContext` (`webkit_shim.c:1122-1126`). There is no data directory, no persistent cookie storage, and no profile flag.
- **Platform, social, and anti-detection modules** (`automation_platform.zig`, `social.zig`, `linkedin.zig`, `instagram.zig`, `automation/{pacing,stealth,session,bezier,gaussian}.zig`) are test-only. No production `src/` code calls them. The social flows call a duck-typed `engine.dispatch(method, params)`, and no production type implements it.
- **SDKs.** The Python SDK has wrappers for 30 method strings. Twenty of them (`linkedin.*`, `instagram.*`, `social.*`, `cookies.*`; plus `telemetry.query` from the CLI) are not in the router table. The SDKs never send the `auth` token, and they do not use the websocket.
- **Plan vs history.** In the Phase 1 plan, milestones M6–M12 are the ones that connect the router to the WebView: PagePort, retry loop, queue, `zb_ipc_dispatch_for_page`, `zb_automation_eval_json`, `zb_automation_inject_script`, telemetry sink, and fixture E2E. Git history has commits for M0, M1, M2, M4, and M5 only. Beads `zigBrowser-oy2` ("wire Phases 1-5 + live tests") is closed. Its notes record only "Track A" (server lifecycle plus websocket ready push).
- **Not present anywhere:** `dom.select`/`dom.press` (or similar), contenteditable typing, cookie import/export, X/Twitter support.

## Detailed Findings

### 1. Process startup and the automation server

- CLI flags: `--automation-api` and `--automation-token-file <path>` (`src/cli.zig:75-85`). Using the token file without `--automation-api` is a usage error (`src/cli.zig:98`).
- `runOpen` (`src/app.zig:33-53`): if `automation_api` is set, it builds the config, runs `AutomationApiServer.init` and then `start()` (with `defer stop()`), then makes the blocking call `c.zb_app_run(...)` (`src/app.zig:38-47`).
- Socket path: if `$ZIGBROWSER_SOCKET` is set it is used directly. Otherwise the path is `planSocketPath(platform, $XDG_RUNTIME_DIR or /tmp, getpid())`, which gives `…/zigbrowser-automation-<pid hex>.sock` (`src/app.zig:85-93`; `src/automation_transport.zig` `planSocketPath`).
- Token: read from the file, at most 4096 bytes, whitespace-trimmed. An empty token means no auth check (`src/app.zig:100-108`, `src/automation_server.zig:151`).
- `start()` deletes any stale socket file, binds and listens, and spawns `serveLoop` on a `std.Thread` (`src/automation_server.zig:46-56`). `stop()` sets an atomic flag, self-connects to wake `accept`, joins the thread, and deletes the socket (`:58-74`).
- `handleStream` (`:95-126`) reads 4 bytes first:
  - If they are `"GET "`, it handles a websocket upgrade. It sends `101` plus a single `automation.ready` text frame, then the connection ends (`:103-106`, `:230-268`).
  - Otherwise the 4 bytes are a big-endian u32 length, max 64 KiB (`:7`, `:108-114`). The server reads the payload and replies with one frame. Each connection carries one request (`:88-91`).
- `handleRequest` (`:129-177`) returns these error codes:
  - -32700: parse error.
  - -32600: invalid request (not an object, or a bad `jsonrpc`/`method`).
  - -32000: token mismatch. The token is read from the request's `auth` string on every request (`:179-185`).
  - -32601: `UnknownCommand`.
  - -32602: `BadArgs`.
  - -32603: other errors (`:122`). This includes non-object `params` (`paramsJson` returns `error.InvalidParams`, `:191`).
- After a successful parse: `defer command.deinit()`, then the fixed template `{"jsonrpc":"2.0","result":{"ok":true,"method":…},"id":…}` (`:168-176`).
- The router context is `.{}` (`:164`), so `page_id` is `"page-unknown"`, `window_id` is `"window-unknown"`, and `telemetry_sink` is null. Router telemetry is therefore skipped on this path (`src/automation/router.zig:141-152`).
- Threading: the server thread and the GTK main thread share only the atomic `stopping` flag (`src/automation_server.zig:21`). No queue, mutex, or GLib dispatch connects the two.

### 2. Router grammar (`src/automation/router.zig`)

- Types: `Namespace {dom, page}` (`:4`), `Verb` with 13 variants (`:6-20`), `WaitState` (`:22`), `RouteContext` (`:24-28`), `ParsedCommand` (`:30-53`). `ParsedCommand` fields: `selector`, `name`, `value`, `text`, `expression`, `url`, `timeout_ms`, `strict`, `force`, `trial`, `delay_ms`, `wait_state`, `wait_until`, `full_page`. All of them live in an arena.
- `parse(allocator, method, params_json, context) (error{UnknownCommand,BadArgs})!ParsedCommand` (`:55-60`).

| Method | Required | Optional |
|---|---|---|
| `dom.query` | `selector` | `strict` (false), `timeout_ms` |
| `dom.click` | `selector` | `options.{force,trial,timeout_ms}`, `strict` (true) |
| `dom.fill` | `selector`, `value` | action options |
| `dom.type` | `selector`, `text` | `delay_ms`, action options |
| `dom.getText` | `selector` | `strict` (true) |
| `dom.getAttribute` | `selector`, `name` | `strict` (true) |
| `dom.waitFor` | `selector` | `strict` (true), `timeout_ms`, `state` (visible) |
| `page.navigate` | `url` | `timeout_ms`, `waitUntil` |
| `page.reload` | — | `timeout_ms`, `waitUntil` |
| `page.url` / `page.title` | — (params must be empty) | — |
| `page.evaluate` | `expression` | — |
| `page.screenshot` | — | `fullPage` (false) |

- The table is at `verbFromMethod` (`:163-183`). `src/automation.zig:5-19` keeps the same 13 strings in `phase1_command_verbs`.
- Unknown extra keys are ignored, except on `page.url` and `page.title` (`:126-130`). Empty params are normalized to `{}` (`:157-161`).

### 3. Injected script (`src/automation_script/automation.js`)

- Entry point: `handle(input)` takes a JSON string or object and switches on `command.op` (`automation.js:24-50`). It is exposed as a non-enumerable, non-writable `globalThis.__zbAutomation` = `{version:'phase1-m4-actionability', handle, debugOutstandingWaits}` (`:515-526`).
- The command shape differs from the router's. The script expects `{op, selector, value?, text?, name?, strict?, force?, trial?, options?, state?, timeout_ms?, trace_id?, parent_span_id?, command_id?}`. The router emits `ParsedCommand` with a `verb` enum. No code anywhere maps one to the other.
- Selectors: `role=`, `testid=`, `text=`, `css=`, `xpath=` (`parseSelector` `:293-303`, `resolveSelector` `:305-320`).
  - `role=name[name="…"]` matches an explicit `role` attribute or an implicit role for `button`, `a[href]`, or `input`. The name comes from `aria-label` or the normalized `textContent` (`:322-366`).
  - Matching searches `document.querySelectorAll('body *')` only. It does not descend into shadow DOM or iframes (`:350-352`).
- Actionability (`runActionabilityChecks` `:203-213`), checked in this order: attached, visible, stable (`data-moving` attribute), receives-events (`elementFromPoint` hit test), enabled, editable (for fill and type).
  - `isEditable` returns true for `isContentEditable`, or for `input`/`textarea` that is neither readonly nor disabled (`:234-240`).
  - So a contenteditable element passes the editability check.
- Actions:
  - `synthesizeClick` dispatches `MouseEvent`s named `pointerdown`, `mousedown`, `pointerup`, `mouseup`, `click` at the element. No coordinates are set (`:242-246`).
  - `synthesizeFill` runs `focus()`, sets `element.value = value`, then fires `InputEvent('input', insertText)` and `change` (`:248-253`).
  - `synthesizeType` runs `focus()`, then for each character: `keydown`, then `element.value = (element.value||'') + char`, then `InputEvent('input')`, then `keyup` (`:255-263`).
  - `fill` and `type` write only to `.value`. They never touch `textContent`, `innerHTML`, `execCommand`, `beforeinput`, or Selection/Range. On a contenteditable element, `.value` is an ordinary expando property, so the visible text is unchanged.
  - The events are untrusted (`isTrusted === false`). `KeyboardEvent` is built with `key` only, without `code`, `keyCode`, or `which`.
- `waitFor` returns a Promise. It uses a MutationObserver on `documentElement`, filtered to the `class`, `hidden`, and `style` attributes. It also polls every 16 ms and has a timeout that defaults to 30 s (`:106-168`).
- `rateLimitScan` checks three modal selectors against the text regex `/limit|restrict|block|captcha|verify/i`, and checks the path regex `/challenge|captcha|checkpoint/i` (`:170-193`).
- Failures from `resolveForCommand` always set `error: 'element_not_found'` and put the specific reason in `data.reason` (`failure`, `:409-417`). Actionability failures set the specific error name (`actionFailure`, `:419-430`).
- Ops not present: select/option, key press, scroll, hover, focus/blur, upload, check/uncheck, setContent, navigation.

### 4. WebKitGTK shim and app wiring

- Exported C surface (`src/webkit_shim.h:30-41`): `zb_run_open`, `zb_app_run`, `zb_run_screenshot`, `zb_version_line`, `zb_reload`, `zb_window_new`. Two functions are implemented in Zig: `zb_policy_decide` (`src/nav_policy.zig:40`) and `zb_ipc_dispatch` (`src/ipc.zig:41`).
- Zig calls only `zb_app_run` (`src/app.zig:45`, `:50`), `zb_run_screenshot`, and `zb_version_line` (`src/webkit.zig:7-19`). It never calls `zb_reload` or `zb_window_new`.
- `zb_app_run` (`webkit_shim.c:1103-1184`) runs these steps in order:
  1. Checks `DISPLAY` and runs `gtk_init_check`.
  2. Gets the default `WebKitWebContext` and sets its cookie policy to `ACCEPT_ALWAYS` (`:1122-1126`).
  3. Creates a new `WebKitUserContentManager` and builds the view with it (`:1128-1137`).
  4. Calls `zb_window_new`.
  5. Installs SIGINT, SIGTERM, and SIGHUP sources (`:1151-1153`). SIGHUP triggers a reload.
  6. Calls `webkit_web_view_load_uri` (`:1155`).
  7. Enters `gtk_main()` (`:1156`).
- `zb_window_new` (`:893-956`) sets `javascript_can_open_windows_automatically` and hardware acceleration `NEVER`. It connects the load, title, policy, and create signals, and calls `install_ipc_handler` (`:950`). There is a 16-window cap (`webkit_shim.h:10`).
- The page→native channel is `zbHost`, registered with reply in the default world (`webkit_shim.c:530-548`). `on_ipc_message_received` (`:550-608`) extracts `cmd` and `args` with a hand-written scanner and calls `zb_ipc_dispatch`. That function knows four commands: `ping`, `add`, `echo`, `os.info` (`src/ipc.zig:15-39`). It returns its result through a heap-backed `threadlocal` buffer (`src/ipc.zig:12-13`; the M1 commit `06f660b` removed the old 4096-byte ceiling).
- The native→page channel exists only on the screenshot title path (`webkit_shim.c:1262`, finish at `:1389`). The shim never calls `webkit_user_script_new`, `webkit_user_content_manager_add_script`, `run_javascript`, or `call_async_javascript_function`.
- Main-loop sources in the shim: only `g_timeout_add` / `g_timeout_add_seconds` for load and screenshot timeouts, and `g_unix_signal_add`. All are installed from code already running on the GTK thread. The shim has no `g_idle_add` or `g_main_context_invoke`.
- Cookies and data:
  - The main window uses `webkit_web_context_get_default()` with no `WebKitWebsiteDataManager` and no data directories.
  - Screenshots use a separate `webkit_web_context_new()` (`:1552`).
  - Child windows share their parent's context through `webkit_web_view_new_with_related_view` (`:620-621`).
  - The shim has no `webkit_cookie_manager_set_persistent_storage`, `add_cookie`, `get_cookies`, or `delete_cookie`.
- Config:
  - `zigbrowser.json` holds only `{"url": …}`. It is read at build time (`build.zig:131-140`). `config_schema.zig` has `SiteConfig{url}` only.
  - The CLI has no profile, data-dir, or cookie flags.
- Navigation policy: navigation from a `file://` base is limited to that directory. From an `http(s)` base, all navigation is allowed. New-window requests open subwindows (`src/nav_policy.zig:24-38`).
- Other shims:
  - `webview2_shim.cpp` and `wkwebview_shim.m` each inject only a marker script, `window.__zigBrowserBackend = '<backend>'` (`webview2_shim.cpp:561-577`, `wkwebview_shim.m:386-391`).
  - Neither shim has JS eval, cookie, or data-store code.
  - `CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, …)` passes a null user-data folder (`webview2_shim.cpp:692`).

### 5. Platform input module (`src/automation_platform.zig`) — test-only

- `InputMode` is either `cdp_input` or `js_synthetic` (`:19-22`). `adapterCapabilities` (`:77-98`) assigns the modes: webview2 uses CDP and has network capability; webkitgtk and wkwebview use js_synthetic and have no network capability.
- The backends are fakes: `FakeWebView2Cdp` (`:167-183`), `FakePlatformEval` (`:451-478`), `FakeWebView2NetworkAdapter` (`:284-298`).
- `KeyInput {action: down|up|type, key, text, trial}` (`:154-165`). The synthetic key script dispatches `KeyboardEvent('keydown'|'keyup', {key})` on `document.activeElement`. `.type` maps to `keydown`, and `text` is unused (`:698-721`). The mouse script dispatches `PointerEvent` at `elementFromPoint(x, y)` (`:687-713`).
- Cookies: `CookieOperation {get,set,delete,clear}` (`:47-52`) is used only as a telemetry label in `recordCookieCommandTelemetry` (`:772`).
- Callers: none outside the file's own tests (`:884-1254`) and the `_ = automation_platform;` reachability reference in `src/root.zig:7,19`. `build.zig` defines no module for it.

### 6. Social modules — test-only

- `src/social.zig` provides:
  - `loginCheck(port)`, `rateStatus(pacing)`, `pause(queue, …)`, `setPacing(pacing, …)`. These are generic over duck-typed ports (`:14-65`).
  - `socialVerb` / `isSocialMethod` (`:71-91`).
  - `detectPlatform(url)`, which recognises `linkedin`, `instagram`, or `unknown` (`:95`).
- `src/linkedin.zig` provides `visit`, `connect`, `message`, `like`, `comment`, `follow`, `search` (`:53-114`). Each one gates on `engine.loginCheck()` and emits `engine.dispatch("page.navigate" | "dom.click" | "dom.fill", <string>)`. The selectors are like `role=button[name="Connect"]`. `search` discards `query` and `search_type` (`:113-114`).
- `src/instagram.zig` provides `follow`, `like`, `comment`, `dm`, `storyView` (`:43-76`).
- Modules exist only for tests (`build.zig:409-452`). No `src/` file imports them. The `MockEngine` that implements `dispatch` lives in `tests/linkedin_test.zig:9-35`.
- No file mentions X/Twitter (case-insensitive grep over `src/`).

### 7. Anti-detection and pacing modules — test-only

- `pacing.zig`: `RateLimiter` with defaults of 3000–8000 ms delay and 100 actions/day. It returns `error.PlatformRateLimited` at the cap and resets on the UTC day.
- `gaussian.zig`: `computeTypingDelays`, Box-Muller, `TypingProfile`.
- `bezier.zig`: `generateMousePath`, a Fitts's-law duration.
- `session.zig`: `SessionSimulator`, which handles warmup and breaks.
- `stealth.zig`: telemetry emitters.
- All of these are imported only by `tests/automation/*_test.zig` (`build.zig:362-400`). `src/automation.zig` re-exports only `errors`, `router`, and `telemetry` (`:1-3`).

### 8. SDKs and CLI

- **Transport.** All SDKs use a Unix socket with a 4-byte big-endian length prefix and a JSON-RPC 2.0 envelope.
  - Node: `sdk/node/src/client.ts:48` (`call`), with a single in-flight request and a 30 s timeout.
  - Python: `sdk/python/src/zigbrowser/client.py:281` (`call`). The sync client has a reader thread that starts only after `on()`. The async client also exists.
  - CLI: `sdk/cli/src/zigbrowser_cli/main.py:57` (`_execute`). It reads `ZIGBROWSER_SOCKET`.
- **Not used by any SDK.** The Python SDK stores `token` but never sends `auth`. No SDK uses the websocket path.
- **Python namespaces** (`client.py:214-219`): `dom`, `page`, `linkedin`, `instagram`, `social`, `cookies`.
  - `cookies.get_all/set/delete` send `cookies.getAll`, `cookies.set`, and `cookies.delete` (`client.py:192-200`).
  - No wrappers exist for `page.url` or `page.title`.
- **Error mapping.** Codes -32012 to -32001 map to `AutomationError(name)`. Every other code maps to `ProtocolError` (`sdk/python/src/zigbrowser/errors.py:30`, `sdk/node/src/errors.ts:44-63`).
- **Tests.** All SDK tests use an in-process `MockUDSServer` (`sdk/python/tests/conftest.py:10-93`, `sdk/node/tests/helpers.ts:6-75`). None of them connects to the real binary.

| Method string(s) sent | In router table? |
|---|---|
| `dom.query/click/fill/type/getText/getAttribute/waitFor`, `page.navigate/reload/evaluate/screenshot` | yes (`router.zig:165-177`) |
| `linkedin.connect/visit/message/like/comment/search/extract` | no |
| `instagram.follow/like/comment/dm/story_view` | no |
| `social.login_check/rate_status/pause/set_pacing` | no |
| `cookies.getAll/set/delete` | no |
| `telemetry.query` (CLI `trace`) | no |

- Two strings appear on only one side:
  - `linkedin.extract` is sent by the SDK, but there is no `extract` in `src/linkedin.zig:131-137`.
  - `linkedin.follow` exists in Zig, but the SDK has no wrapper for it.

### 9. Tests that touch the automation layer

| Test | Kind | What it proves |
|---|---|---|
| `tests/automation_router_test.zig` | unit | Parsing of 13 methods; `UnknownCommand` for `cookies.get`, `social.post`, `linkedin.connect`, `instagram.follow`, …; telemetry redaction (`:7-137`) |
| `tests/automation_server_test.zig` | real AF_UNIX, no WebView | `page.url` returns a response containing `"ok":true` and `"method":"page.url"` (`:41-44`); websocket `101` and `automation.ready` |
| `tests/e2e/automation_api_lifecycle_test.py` | real binary + display | `result.ok is True` and `result.method == "page.url"` (`:133-136`); a `NAV` row; socket cleanup. Wired into `zig build test`, with exit 77 counted as a pass (`build.zig:322-329`) |
| `tests/automation/js_contract_test.zig` | substring checks on embedded JS | Source contains `rateLimitScan`, `observer.disconnect()`, `defineProperty`, … |
| `e2e/automation_script.spec.ts` | Playwright stock browsers | Selectors, strictness, actionability errors, trial/force, event order for click/fill/type, waitFor states. Script loaded by `page.addScriptTag` (`:21-24`). Not in `build.zig` or npm scripts. No contenteditable target; no `rateLimitScan` |
| `tests/{social,linkedin,instagram}_test.zig` | unit with mocks | Emitted command sequences |
| `tests/e2e/ipc_roundtrip_test.py` | real binary | Page→native `zbHost` `echo` (not the automation API) |

## Code References

- [`src/app.zig:38-47`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/app.zig#L38-L47): starts the server, then blocks in `zb_app_run`.
- [`src/app.zig:85-108`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/app.zig#L85-L108): socket path and token sources.
- [`src/automation_server.zig:95-126`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_server.zig#L95-L126): `handleStream`, which handles framing and the websocket branch.
- [`src/automation_server.zig:129-177`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_server.zig#L129-L177): `handleRequest`, which parses and returns the fixed `{ok,method}`.
- [`src/automation/router.zig:55-155`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation/router.zig#L55-L155): `parse`.
- [`src/automation/router.zig:163-183`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation/router.zig#L163-L183): `verbFromMethod`, the 13-method table.
- [`src/automation_script/automation.js:24-50`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_script/automation.js#L24-L50): `handle` op switch.
- [`src/automation_script/automation.js:234-263`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_script/automation.js#L234-L263): `isEditable`, `synthesizeClick`, `synthesizeFill`, `synthesizeType`.
- [`src/automation_script/automation.js:515-526`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_script/automation.js#L515-L526): `__zbAutomation` global.
- [`src/automation_script/js_embed.zig:1`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_script/js_embed.zig#L1): `@embedFile("automation.js")`.
- [`build.zig:471-481`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/build.zig#L471-L481): `js_embed` module, imported only by the JS contract test.
- [`src/webkit_shim.c:530-608`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/webkit_shim.c#L530-L608): `zbHost` handler and the dispatch into `zb_ipc_dispatch`.
- [`src/webkit_shim.c:1103-1184`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/webkit_shim.c#L1103-L1184): `zb_app_run`, with the default context and cookie policy at `:1122-1126`.
- [`src/webkit_shim.c:1262`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/webkit_shim.c#L1262): the only `webkit_web_view_evaluate_javascript` call.
- [`src/ipc.zig:12-73`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/ipc.zig#L12-L73): threadlocal result buffer, the 4 IPC commands, and `zb_ipc_dispatch`.
- [`src/automation_platform.zig:687-721`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/automation_platform.zig#L687-L721): synthetic mouse and key script builders (test-only).
- [`src/linkedin.zig:53-114`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/src/linkedin.zig#L53-L114): LinkedIn flows via `engine.dispatch` (test-only).
- [`sdk/python/src/zigbrowser/client.py:188-219`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/sdk/python/src/zigbrowser/client.py#L188-L219): `CookiesNamespace` and the namespace wiring.
- [`tests/automation_server_test.zig:41-44`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/tests/automation_server_test.zig#L41-L44): asserts the `{ok,method}` template.
- [`tests/e2e/automation_api_lifecycle_test.py:128-136`](https://github.com/tha-hammer/zigBrowser/blob/32362d42643417816b8e7b50deb20bd5d64dbf4d/tests/e2e/automation_api_lifecycle_test.py#L128-L136): asserts the same template against the real binary.

## Architecture Documentation

- **Layering as planned and as built.**
  - The PRD describes three layers: an injected script (Layer 1), a Zig engine (router, queue, retries, telemetry), and an external API (UDS JSON-RPC plus websocket events).
  - At HEAD, Layer 1 exists as `automation.js`. The engine exists only as the router plus the error and telemetry modules. The external API exists as `automation_server.zig`.
  - The connecting pieces named in the Phase 1 plan are not in the tree. A grep for `PagePort|zb_ipc_dispatch_for_page|zb_automation_eval_json|zb_automation_inject_script` over `src`, `tests`, and `build.zig` matches only test mocks (`MockPagePort` in `tests/social_test.zig:4`). The pieces are: PagePort (M6), retry loop (M7), per-page FIFO queue (M8), page-aware dispatch (M9), inject/eval (M10), sink wiring (M11), and fixture E2E (M12).
- **Two automation-shaped JSON-RPC handlers exist.**
  - `automation_server.zig` uses length-prefixed frames, auth on every request, and the router. It is used in production.
  - `automation_rpc.zig` uses newline-delimited frames, auth once per connection, and a `Router` vtable with `dispatchFn` (`automation_rpc.zig:60-123`). It is reachable only from `root.zig` test discovery and its own tests. It has its own `AutomationError` enum (`:14-27`), which duplicates `automation/error.zig`.
- **Duck-typed ports.** `social`, `linkedin`, and `instagram` take `anytype` `port`/`engine`/`pacing`/`queue` parameters. No concrete production implementation of these interfaces exists.
- **Planned per-platform eval seams** (Phase 1 plan M10):
  - GTK: `webkit_user_content_manager_add_script` plus `webkit_web_view_evaluate_javascript`.
  - WebView2: `ExecuteScriptAsync`.
  - macOS: `evaluateJavaScript:in:in:completionHandler:`.
  - Ownership split (plan M9 refactor note): the shims own async completion and native object lifetimes; Zig owns deadlines, retries, queueing, and error mapping.
- **Error codes.** `automation/error.zig` assigns -32001 through -32012 (`element_not_found` … `cancelled`), computed as `-32001 - ordinal`. The SDKs map that range to named errors.
- **Telemetry.** The design hashes selector, URL, and typed values, and never records raw values. This is implemented in `automation/telemetry.zig` and `automation_platform.zig`, and in `automation.js` (`hashText`).

## Workflow Closure Map

Behavior mapped: **an SDK client sends `dom.click` (or `dom.type`) over the automation socket → the element in the page receives the action → the client gets the real result.**

| Depth | Node | Location | Label | Adds/changes |
|---|---|---|---|---|
| 0 | SDK `call("dom.click", …)` | `sdk/python/src/zigbrowser/client.py:281` | production-called (CLI `main.py:57`) | no |
| 1 | UDS frame → `handleStream` → `handleRequest` | `src/automation_server.zig:95-177` | production-called (`src/app.zig:40-42`) | **yes**: currently returns a template instead of dispatching |
| 2 | `router.parse` | `src/automation/router.zig:55` | production-called (`automation_server.zig:164`) | no for click/type; yes if new verbs are added |
| 3 | Server thread → GTK main thread hand-off | — | **not found** (no `g_idle_add` / `g_main_context_invoke` / queue in `src/`) | yes |
| 4 | Native eval of `__zbAutomation.handle(cmd)` in the WebView, with the script injected at document start | — (only `webkit_shim.c:1262` evaluates JS, for `document.title`) | **not found** | yes |
| 5 | `handle` → `runAction` → `synthesizeClick` / `synthesizeType` | `src/automation_script/automation.js:24`, `:73`, `:242`, `:255` | `handle`: **test-only** (Semgrep closure map; called only from `e2e/automation_script.spec.ts`). `synthesize*`: called only within the script | yes for `type` on contenteditable |
| 6 | Eval result → server thread → JSON-RPC response → SDK return | `automation_server.zig:125` (`writeFrame`) | production-called, but it currently carries the template | yes |

`highest_new_connector`: node 1 (`handleRequest`). Edges at the time of research:

- **0→1** (UDS, synchronous request/response, crosses the process boundary).
  - Contract: a 4-byte big-endian length followed by a JSON-RPC 2.0 object; `auth` is required when the token is non-empty.
  - Error behaviour: oversize frames get -32700. A failure to read the payload closes the connection silently (`:118`).
  - Tests: `tests/automation_server_test.zig`, `tests/e2e/automation_api_lifecycle_test.py`. Both use `page.url` only.
- **1→2** (synchronous, same thread).
  - `UnknownCommand` → -32601; `BadArgs` → -32602.
  - The context is the default, so there is no page, window, or telemetry sink.
  - Tests: `tests/automation_router_test.zig`.
- **2→3** (crosses threads).
  - Nothing implements this edge at HEAD. The parsed command is freed at `automation_server.zig:168`.
- **3→4** (Zig → C shim).
  - No exported shim function takes a script or command (`webkit_shim.h:30-41`).
- **4→5** (native → page JS).
  - `automation.js` is never injected. `js_embed` is linked only into the JS contract test (`build.zig:471-481`).
- **5→6** (async eval completion → reply).
  - Nothing implements this edge.
  - `waitFor` returns a Promise (`automation.js:119`). Its completion would therefore have to resolve asynchronously.

Negative evidence:
- Tests that write the final observable directly: `tests/automation_server_test.zig:41-44` and `tests/e2e/automation_api_lifecycle_test.py:133-136` assert the template response. That response is produced without passing through nodes 3–5.
- Tests that bypass the production chain: `e2e/automation_script.spec.ts` drives node 5 directly with `page.addScriptTag` and `page.evaluate`, so it skips nodes 1–4.

### ClosureMap (structured — derive() input)

```json
{
  "behavior": "An SDK client sends dom.click or dom.type over the automation socket, the target element in the loaded page receives the action, and the client receives the real per-command result.",
  "git_commit": "32362d42643417816b8e7b50deb20bd5d64dbf4d",
  "repo": "/home/maceo/ntm_Dev/zigBrowser",
  "nodes": [
    { "id": "sdk_call", "module": "sdk/python", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": "zb_app_run initial URI page DOM (src/webkit_shim.c:1103, load at :1155)" },
    { "id": "server_handle_request", "module": "src/automation_server.zig", "is_entrypoint": true, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "router_parse", "module": "src/automation/router.zig", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "main_thread_handoff", "module": "src/automation_server.zig <-> src/webkit_shim.c (not present)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "webview_eval", "module": "src/webkit_shim.c (not present)", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "automation_js_handle", "module": "src/automation_script/automation.js", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "rpc_result_returned", "module": "sdk/python", "is_entrypoint": false, "adds_or_changes": true, "read_path": "ZigBrowser.call (sdk/python/src/zigbrowser/client.py:281)", "seedable_store": null }
  ],
  "edges": [
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": true, "cross_boundary": true, "driver": "gtk_main (src/webkit_shim.c:1156) — no hand-off source exists at HEAD" },
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": true, "cross_boundary": true, "driver": "gtk_main (src/webkit_shim.c:1156) — evaluate_javascript completion callback, not present for automation at HEAD" },
    { "is_async": true, "cross_boundary": true, "driver": "gtk_main (src/webkit_shim.c:1156) — eval-finish to server-thread reply, not present at HEAD" }
  ]
}
```

### Closure adapter (staged proposal — `2026-10-10-11-32-automation-layer-current-state.closure-adapter.py`)

Staged as a sibling file next to this document. It is not wired into the repo.

```python
"""Closure adapter (STAGED PROPOSAL — not wired into the repo).
Derived from the ClosureMap for: SDK dom.click/dom.type -> element acted on -> real result.
Pin: 32362d42643417816b8e7b50deb20bd5d64dbf4d.
Promote into /home/maceo/ntm_Dev/zigBrowser and complete each TODO(promote) before use.
Speaks the 7-op contract apps/closure-oracle already talks to (mock_adapter.py).
"""
import http.server, json, sys
ASYNC_EDGES = ["main_thread_handoff", "webview_eval", "rpc_result_returned"]
CONNECTOR = {e: True for e in ASYNC_EDGES}
SINK = []

def handle(op, p):
    if op == "/reset":        SINK.clear(); CONNECTOR.update({e: True for e in ASYNC_EDGES}); return {"ok": True}
    if op == "/set_connector": CONNECTOR[p["edge"]] = p["enabled"]; return {"ok": True}
    if op == "/seed_sink":     SINK.append(p["value"]); return {"ok": True}
    if op == "/seed":
        # TODO(promote): launch zigbrowser <fixture file:// URI> --automation-api with ZIGBROWSER_SOCKET
        #   -> zb_app_run initial URI (src/webkit_shim.c:1103, load at :1155; started from src/app.zig:38-47)
        return {"ok": True}
    if op == "/trigger":
        # TODO(promote): send framed JSON-RPC p["args"] (e.g. dom.click) to the socket
        #   -> AutomationApiServer.handleStream/handleRequest (src/automation_server.zig:95, :129)
        return {"ok": True}
    if op == "/drive":
        if not CONNECTOR.get(p["edge"], True): return {"ok": True}
        # TODO(promote): no driver exists at HEAD; GTK main loop gtk_main (src/webkit_shim.c:1156)
        #   is the only loop that could drain a hand-off/eval completion.
        return {"ok": True}
    if op == "/observe":
        # TODO(promote): return the response read via ZigBrowser.call (sdk/python/src/zigbrowser/client.py:281)
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

## Historical Context (from thoughts/)

- `thoughts/searchable/shared/prd/2026-07-09-browser-automation-api.md` (Draft) holds the normative grammar and contracts.
  - Methods and params: §5.1, around lines 480–515.
  - Errors: Appendix A, around lines 1134–1149, which assigns -32001 through -32012.
  - Cookies: the PRD specifies `cookies.getAll {url?}`, `cookies.set {name,value,domain,path?,expires?,httpOnly?,secure?}`, `cookies.delete {name,domain}`, and `session.status`. It has no cookie import or export method. Contract C11 says cookie operations apply to the active profile.
  - ADR-2 chooses custom JS injection into a named world over `WebKitAutomationSession`, because the latter sets `navigator.webdriver=true`.
  - Key events appear only inside `dom.type`. `select` is mentioned only as a Layer 1 script action (around §4.4, line 459). There is no `dom.select` or `dom.press` in the grammar.
- `thoughts/searchable/shared/plans/2026-07-09-phase1-core-automation-engine-tdd-plan.md` lays out milestones M0–M12.
  - M9 (around line 678) defines `zb_ipc_dispatch_for_page`.
  - M10 (around line 721) defines `zb_automation_inject_script` and `zb_automation_eval_json`, with per-platform eval APIs.
  - Phase 1 explicitly excluded the socket server, `cookies.*`, `session.*`, and the social namespaces (around lines 103–114).
- `thoughts/searchable/shared/plans/2026-07-09-phase2-3-external-api-platform-input-tdd-plan.md` covers P2.0–P2.5 (socket, framing, auth, dispatch, websocket, OTLP) and P3.1–P3.6 (platform input adapters).
  - Its framing is newline-delimited, which matches `automation_rpc.zig`. The production server uses length prefixes instead.
- `thoughts/searchable/shared/plans/2026-07-09-phase4-anti-detection-pacing-tdd-plan.md` defines typing delays (mean 120 ms, standard deviation 40, clamp [80, 200]) and pacing (3000–8000 ms, 100/day).
- `thoughts/searchable/shared/plans/2026-07-09-phase5-sdks-social-contracts-tdd-plan.md` covers `social.*`, LinkedIn, Instagram, and the Python, Node, and CLI SDKs. It excludes TikTok and Facebook, multi-tab, proxy, headless, and cookie encryption.
- `thoughts/searchable/shared/handoffs/general/2026-07-11_08-10-43_zb-sequences-bridge-orchestration.md`
  - Line 20 states "zigBrowser automation API (Phases 1–5) — ✅ COMPLETE".
  - Line 35 states that `--automation-api` "now actually starts the server (was the `oy2` gap)".
- `thoughts/searchable/shared/plans/2026-07-09-sequences-integration-93-creation-94-authoring-plan-REVIEW.md` (around line 90, finding C-5) records that `dom.fill` sets `.value` and does not work on contenteditable. It proposes a `dom.setContent` verb. This is the only repo document that mentions contenteditable.
- Beads `zigBrowser-oy2` ("Cross-phase E2E integration for automation API (wire Phases 1-5 + live tests)") is **CLOSED**.
  - Its description lists the remaining work as "wire the injected automation.js + Zig dispatch + UDS JSON-RPC server + SDK clients + pacing layer together, and add live E2E tests that drive a real WebView."
  - Its notes record only Track A: commits `0b96814` (server runtime wiring) and `0d8f63f` (websocket ready push).
- Git history shows Phase 1 commits `450dca9` (M0), `06f660b` (M1), `508e4b7` (M2), `f7fa45a` (M4), and `aad8af4` (M5). No commits are labelled M3 or M6–M12 for the automation engine. The selector engine (M3) ships inside `automation.js`.

## Related Research

- `thoughts/searchable/shared/research/2026-07-09-14-40-codebase-automation-api-seams.md`: pre-implementation seams snapshot at `c1ebbd7`.
- `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md`: three-layer design and the five-phase roadmap.

## Open Questions

- Which framing will the integrated server keep? The production server uses a 4-byte length prefix. The Phase 2/3 plan and `automation_rpc.zig` use newline-delimited frames. The SDKs use the length prefix.
- Script world: will `automation.js` go into the default page world or a named isolated world? The Phase 1 plan's M10 test requires `__zbAutomation` to stay hidden from the page world.
- Cookie persistence: should it come from a `WebKitWebsiteDataManager` with data directories, or from `webkit_cookie_manager_set_persistent_storage` on the default context? No profile or data-dir concept exists in the config or CLI yet.
- Untrusted events: the JS-synthetic `click` and `type` events have `isTrusted=false`. This research did not determine whether target sites (for example X's composer, which is built on Draft.js and contenteditable) ignore untrusted input.
- Missing grammar for X's scheduling dialog: `select` and key-press verbs have no method string, router variant, or `automation.js` op. The PRD does not define one either.
- Tests asserting the template: `tests/automation_server_test.zig:41-44` and `tests/e2e/automation_api_lifecycle_test.py:133-136` assert the `{ok,method}` template for `page.url`. If the server starts returning real results, these assertions describe behaviour that will change.
