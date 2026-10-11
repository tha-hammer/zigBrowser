# Chat drawer research check

**Reviewed:** 2026-10-11

**Research pin:** `d9ad717808c310934f0e2fe003220d0a4eaf1560`

**Review target:** committed `HEAD` `7c9d68a5ff4819ce45bcc18630fad0a06a736f29`

**Scope:** read-only validation of the research document and its two sibling closure adapters. No live browser, display, socket, or test was run.

## Verdict

The research remains a useful architectural inventory, but it is not plan-ready against current `HEAD` without this correction layer.

- The GTK window seam is still `zb_window_new`, and the high-level `zbHost` and ordinary automation `page.evaluate` chains still exist.
- Most citations in the files changed since the research pin have moved. Several statements also changed semantically: hardware acceleration is no longer forced off, `page.list` now carries crash state, there are 21 rather than 15 direct Python e2e commands, the e2e launcher now owns browser-process cleanup (and owns a private Xvfb when requested), and the error taxonomy reaches `-32013 dialog_open`.
- ClosureMap A omits the shared-user-content-manager lifecycle of related popups and overstates its end-to-end test at the Promise-settlement edge.
- ClosureMap B omits explicit window targeting and queue acquisition, misstates one same-thread edge as cross-boundary, and draws a direct GTK-dispatch-to-reply edge that does not exist. `page.list` is an out-of-band special path, not an instance of the mapped router/engine path.
- The next plan must make the drawer a privileged surface separate from the page-world `zbHost`; preserve explicit `window_id` routing; handle related popups, dialogs and dead web processes; define Agent SDK subprocess ownership; and apply the current render/media configuration deliberately.
- `page.health` is working-tree work in progress, not committed production at this review target. It must be repinned after its own commit and gate.

All branch-local citations in the research document and both sibling adapters were checked. External-repository locations (`@cosmic/ds`, `cc-agent-ui`) and the external Claude Agent SDK facts were not revalidated because they are not locations in this branch.

## Citation corrections

The table lists every moved, incomplete, or factually wrong branch-local citation. Citations not listed under a correction are summarized in “Citations that remain exact” below.

### Window construction, GTK lifecycle, and `zbHost`

| Research location | Pinned citation or claim | Correct location / current fact at `HEAD` |
|---|---|---|
| 34, 69, 342 | `src/webkit_shim.c:1022`, `:1022-1104` | `zb_window_new` is `src/webkit_shim.c:1097-1184`. |
| 35, 72-75, 343 | `src/webkit_shim.c:1058-1061` | The top-level, size, title, and direct `WebKitWebView` child are `:1133-1136`. |
| 39, 130-133, 347, 395 | `install_ipc_handler :600-618`, called at `:1096` | `:648-666`, called at `:1176`. Registration is still in the page world because the world argument is `NULL` at `:655-657`. |
| 40, 135-140, 348, 396-408 | `on_ipc_message_received :620-678`; dispatch/reply `:661-672` | Callback `:668-726`; validation `:678-705`; C/Zig call `:709`; success `:710-715`; error `:716-719`. `emit_protocol2` is defined at `:221`, not `:191`. |
| 85 | `src/webkit_shim.c:1099-1102` | Registry publication and `gtk_widget_show_all` are `:1179-1182`. |
| 86 | title callback `:771-784` | `:833-846`. |
| 88-90 | settings `:1063-1068`; hardware policy `NEVER` | Settings are `:1138-1144`. The claim is wrong: `zb_apply_hw_policy` is called at `:1141`; the built-in default is WebKit policy plus shared-memory frames (`src/render_config.zig:33-42`), not `NEVER`. |
| 92-94 | signals `:1070-1094` | `:1146-1174`. The old list is incomplete: `script-dialog` and `web-process-terminated` are now connected at `:1168-1171`. |
| 95 | `auto_debug_close_on_key :3682-3687` | `:3814-3825` (the connection is at `:3817`). |
| 98 | main UCM/view `:4204`, `:4212-4214` | UCM `:4835`; view `:4843-4845`. |
| 99, 345 | popup callback `:680-719`; related-view constructor `:690-691` | Callback `:728-766`; constructor `:738-739`; opener and process-group inheritance `:751-755`. |
| 102 | `ZbApp :115-128`; `ZbWindow :62-113` | `ZbApp :131-144`; `ZbWindow :62-129`. |
| 103 | id sites `:1045`, `:1631` | Assignment `:1120`; counter initialization `:1713`; per-run reset `:1859-1864`. |
| 104 | list export `:3737`; worker `:3713` | Export `:3874-3890`; worker `:3845-3872`. The raw schema now also includes `crashed` at `:3860-3866`. |
| 105 | window snapshot `:1625-1633`, `:1743-1762` | Snapshot state `:1704-1715`; publisher `:1823-1844`. |
| 108, 346 | destroy `:786-855`; sharing check `:247-260` | Destroy `:848-926`; `window_shares_process :291-307`. |
| 109 | last-window quit `:400-402` | `app_remove_window :425-450`; quit at `:448-449`. |
| 112-113 | startup `:4180-4239` | DISPLAY/init `:4811-4819`; first `zb_window_new :4857`; load `:4868`; `gtk_main :4870`. |
| 114, 352 | `zb_main_invoke_sync :1548-1575`; GTK queue `:1455-1469` | Invoke `:1630-1657`; queue `:1537-1555`; waiter/GCond `:1566-1615`. |
| 116, 238, 353 | profile context `:4111-4130`; paths `:4116-4125` | Context `:4742-4760`; data/cache/cookies `:4747-4756`. |
| 121 | screenshot `:4621-4688`, layout `:4660-4663` | `:5253-5320`; context/view `:5273-5290`; layout `:5292-5295`. It now receives render and media settings at `:5286-5290`. |
| 143 | `src/webkit_shim.h:320` | `zb_ipc_dispatch` declaration is `src/webkit_shim.h:396-397`. |
| 151, 351 | automation-world install `webkit_shim.c:1643-1676`; world macro `webkit_shim.h:81` | Install `webkit_shim.c:1725-1758`; script `:1731-1735`; handlers `:1736-1750`; macro `webkit_shim.h:117`. |
| 235, 242, 354-356 | old application/config/startup locations | `runOpen` is `src/app.zig:36-68`; HTTP/render/media are applied before WebKit at `:40-45`; socket path `:149-156`; HTTP environment `src/webkit.zig:26-40`; render `:42-62`; media `:64-82`; `app_run` `src/webkit_shim.c:4804-4909`; open CLI parser `src/cli.zig:102-187`; default profile `:194-201`. |
| 238 | pacing path `src/app.zig:93-96` | `src/app.zig:95-100`. |
| 395-408 | Closure A shorthand `on_ipc :620`, signal `:615-617`, call `:1096`, replies `:665/:670`, validation `:630-654`, JSC `:664`, emitter `:191/:667` | `on_ipc :668`; signal `:663-665`; call `:1176`; replies `:713/:718`; validation `:678-705`; JSC `:712`; emitter definition/call `:221/:715`. |
| 405 | “On error, it replies with an error message, never a throw” | Native calls `webkit_script_message_reply_return_error_message` at `:718`, which rejects the JavaScript Promise. The fixture catches that rejection. |
| 461, 465, 469 | embedded adapter copy `on_ipc :620`, `gtk_main :4239`, reply `:665-671` | `:668`, `:4870`, `:713-719`. |
| 569 | production native-to-page example `webkit_shim.c:2594` | The moved `evaluate_javascript` site at `:2686` is a screenshot test hook, not the normal automation path. Production evaluation uses `webkit_web_view_call_async_javascript_function` at `:2202-2204`; the existing fire-and-forget isolated-world notification is `:1818-1819`. |

### Automation server, engine, and clients

| Research location | Pinned citation or claim | Correct location / current fact at `HEAD` |
|---|---|---|
| 184 | socket path `src/app.zig:143-150`; mode `automation_server.zig:1002-1006` | Path `src/app.zig:149-156`; mode application `src/automation_server.zig:191-197`, implementation `:1117-1121`. |
| 185 | credentials `src/app.zig:186-215`; token sidecar `automation_server.zig:985-1000` | Credentials `src/app.zig:192-220`; sidecar `src/automation_server.zig:1100-1115`. |
| 186 | constant-time helper `automation_server.zig:967-974` | Request extraction `:1071-1077`; SHA-256 and `timing_safe.eql` `:1079-1089`. The auth gate `:443-445` is unchanged. |
| 189, 357, 492 | `writeFrame :1053-1059` | `src/automation_server.zig:1168-1174`; call sites remain `:330`, `:342`. |
| 190, 357 | `handleRequestWith :408-540` | `:408-543`. |
| 191, 358 | router table `src/automation/router.zig:269-288` | Table `src/automation/router.zig:281-305`; the special-method dispatch preceding it is `src/automation_server.zig:459-480`. |
| 193, 359, 489 | `Engine.executeWith :301-416`; retry `:512-581`; server call `:521` | Entry/dispatch `src/automation/engine.zig:326-446`; retry `:542-611`; server call `src/automation_server.zig:524`. |
| 193, 360 | `PagePort :112-214` | Vtable `src/automation/page_port.zig:150-284`; wrappers continue through `:389`. |
| 194, 361, 490 | GTK adapter `:39-73`, eval `:156-175`; C eval `webkit_shim.c:2803` | Adapter `src/automation_gtk_port.zig:39-77`; eval `:262-281`, C call `:274`; C export `src/webkit_shim.c:2905-2919`. |
| 197 | “-32001 to -32012”, `src/automation/error.zig:5-28` | Taxonomy is `src/automation/error.zig:5-32` and now includes `-32013 dialog_open` at `:18-21`. |
| 202, 204, 357 | WebSocket `automation_server.zig:1061-1114`; ready `:1103-1113` | `:1176-1229`; ready payload/frame `:1218-1228`. It still sends one frame and closes. |
| 210, 363 | Node `connect :42`, `call :84`, `dispatchEvent :131` | `sdk/node/src/client.ts:44`, `:86`, `:133`. Class `:8` remains exact. |
| 211 | `sdk/node/src/methods.ts:122-392` | Namespaces span `:125-478`; current page list/close API is `:195-239`. |
| 213, 364, 486 | Python sidecar/class/async class `:391/:402/:542`; Closure B calls `:402` | Sidecar `sdk/python/src/zigbrowser/client.py:437`; class `:448`; synchronous `call :533`; async class `:589`, async `call :619`. The old Closure B citation pointed at the class, not `call`. |
| 218 | safety docs `:340-362`; flow check `flow_runner.zig:177-184` | Stop-sign docs `docs/how-to-automate.md:612-630`; detection path `src/automation/flow_runner.zig:159-199`. |
| 219 | X cap `src/automation/x_routes.zig:43` | The numeric default is `:29`; limiter initialization remains `:43`. |
| 221 | telemetry redaction docs `:372-373` | `docs/how-to-automate.md:642-645`. |
| 491 | `auto_job_dispatch :1429`; queue `:1455/:1472` | `src/webkit_shim.c:1511-1528`; queue `:1537-1551`; submission `:1553-1555`. |
| 502, 505 | C waiter `:1484-1533`; completion `:1400` | `src/webkit_shim.c:1566-1615`; `auto_job_complete :1482-1496`. |

### Build, configuration, and harness

| Research location | Pinned citation or claim | Correct location / current fact at `HEAD` |
|---|---|---|
| 45, 168, 365 | dashboard test modules `build.zig:809-840` | `build.zig:873-904`. |
| 52 | Node command `build.zig:847` | Dashboard Node command is now `build.zig:911`. The automation accept and connection threads at `automation_server.zig:199,299` remain exact. |
| 169 | dashboard visual `build.zig:847-850` | `build.zig:906-914`. |
| 177-180, 355 | CLI `:79-82`; app `:35-63`; config `:124-141` | CLI `src/cli.zig:124-126`; app `src/app.zig:36-68`; injection `:50`; config call `:51`; builder `:130-147`; server lifetime `:55-58`. |
| 227-228, 365 | GTK backend `build.zig:890-900`; selector `:868-875` | `configureGtkBackend :954-964`; `resolveBackend :932-939`. |
| 230 | 15 Python e2e scripts at `build.zig:445-581`; runner `slice2_common.py:97-122`; `xvfb-run -a` | There are 21 direct Python e2e commands at `build.zig:445-636`. Runner selection is `tests/e2e/slice2_common.py:135-162`; the owned-launcher prefix is `:27-35`. `tests/e2e/xsession.py:4-20` always owns browser-group cleanup and, with `--xvfb`, the private Xvfb; it does not use `xvfb-run -a`. |
| 233, 356 | flags `src/cli.zig:26-121` | Parse paths are `:38-187`; the list must add `--hardware-acceleration`, `--renderer`, and `--media-source`. |
| 234, 356 | `defaultProfileDir :128` | `src/cli.zig:194-201`. |
| 235 | environment sites `app.zig:74,144,148`, `webkit.zig:25-38`, C `:4180` | `src/app.zig:79,150,154`; HTTP `src/webkit.zig:26-40`; render/media `:42-82`; DISPLAY `src/webkit_shim.c:4811`. The list omits `WEBKIT_DMABUF_RENDERER_FORCE_SHM`, `__EGL_VENDOR_LIBRARY_FILENAMES`, and `ZIGBROWSER_MEDIA_SOURCE`. |
| 242 | network-process inheritance `src/webkit.zig:31-32` | HTTP inheritance `src/webkit.zig:33-39`; render child-environment contract `src/render_config.zig:70-77`. |
| 365 | combined build references `:809-850`, `:868-900` | `build.zig:873-914`, `:932-964`. |
| 379 | trust boundary `docs/how-to-automate.md:65-67` | `docs/how-to-automate.md:93-95`. |
| 548 | `specs/architecture.md:51-53` proves 1024x768 and no toolbar/address/settings | `:51-53` only states that address bar, tabs, and bookmarks are not shipping. The 1024x768/direct-child evidence is `src/webkit_shim.c:1133-1136`; absence of other chrome remains negative source evidence, not a claim supported by that spec citation. |

### Sibling closure adapters

`2026-10-11-03-16-claude-agent-sdk-chat-drawer.closure-adapter.py`:

- line 21: `src/webkit_shim.c:620` -> `:668`;
- line 25: `src/webkit_shim.c:4239` -> `:4870`;
- line 29: `src/webkit_shim.c:665-671` -> `:713-719`.

`2026-10-11-03-16-claude-agent-sdk-chat-drawer.automation-socket.closure-adapter.py`:

- lines 12 and 33: `auto_job_dispatch :1429` -> `src/webkit_shim.c:1511`;
- lines 13 and 34: `auto_job_complete :1400` -> `:1482`;
- line 28: Node `call :84` -> `sdk/node/src/client.ts:86`;
- line 37: `writeFrame :1053` -> `src/automation_server.zig:1168`.

Both files remain staged TODO scaffolds. Neither is a production adapter or a test today.

### Citations that remain exact

The following branch-local citations still select the claimed code at committed `HEAD`: `build.zig.zon:28,34-64`; `build.zig:131-140,163-168`; `src/webkit_shim.h:11`; `src/ipc.zig:15-39,41-73,169-194`; `src/nav_policy.zig:28-36,40`; `src/automation/page_port.zig:7-20`; `src/automation/queue.zig:55-96`; `src/automation/engine.zig:15`; `src/automation_server.zig:55,199,291-301,312-346,318-323,408,443-445`; `src/automation_transport.zig:17-35`; `src/automation_websocket.zig:54-99`; `src/automation_gtk_port.zig:22`; `src/automation_script/js_embed.zig:1`; `src/automation/pacing.zig:10-12`; `sdk/node/src/client.ts:8`; `sdk/node/src/errors.ts:44`; `sdk/cli/src/zigbrowser_cli/main.py:14-54`; the cited dashboard source locations; `tests/fixtures/app/zbhost.js:31,110-133`; `tests/e2e/ipc_roundtrip_test.py:68-87`; `tests/ipc_test.zig:109-215`; `tools/dashboard_visual_check.mjs:73-77`; and the cited macOS/Windows shim lines. In the structured Closure A table, the shorthand paths `webview2_shim.cpp` and `wkwebview_shim.m` should still be written as repo-relative `src/webview2_shim.cpp` and `src/wkwebview_shim.m`.

## Closure audit A: page `zbHost` round trip

### Current production chain

| Step | Production implementation at `HEAD` | Result |
|---|---|---|
| Page caller | Dashboard wrapper `src/dashboard/content/index.html:132-154`; fixture wrapper `tests/fixtures/app/zbhost.js:24-34,110-133` | Still page-world JavaScript. |
| WebKit registration | `install_ipc_handler`, `src/webkit_shim.c:648-666`, called by `zb_window_new` at `:1176` | Still `zbHost`, with reply, `world=NULL`. |
| Receive/validate | `on_ipc_message_received`, `:668-705` | Still requires a JS string containing JSON with a string `cmd`; `args` defaults to `{}`. |
| C/Zig dispatch | `:707-709` -> `src/ipc.zig:41-73` -> `dispatch :15-39` | Still synchronous on GTK and limited to `ping`, `add`, `echo`, `os.info`. |
| Reply | `src/webkit_shim.c:710-719` | Success resolves; `return_error_message` rejects the page Promise. |

The four-node topology remains directionally correct, but “registration is per window” is too simple. A related popup is created by `webkit_web_view_new_with_related_view` (`:738-739`) and shares its opener's user-content manager; `auto_install_script` explicitly relies on that fact (`:1723-1728`). Nevertheless, `zb_window_new` calls `install_ipc_handler` for each `ZbWindow`. That function unregisters/re-registers the one handler on the shared manager and adds another signal callback (`:653-665`). The map carries no frame, origin, nonce, or reliable window provenance into `zb_ipc_dispatch`. A plan must not assume that a popup owns an independent `zbHost` endpoint merely because it owns a `ZbWindow`.

### Tests and gaps

- `tests/e2e/ipc_roundtrip_test.py:68-113` drives a real GTK/WebKit page and observes the success/error protocol rows emitted immediately after the native reply call. It covers page -> WebKit signal -> C/Zig dispatch -> native reply call without a mock.
- It does **not** read `#zb-out` or otherwise prove that the success Promise resolved and the error Promise rejected back in the page. Therefore the behavior named by edge 2 -> 3 (“reply resolves the page promise”) is executed but not asserted. A plan should first add a failing e2e that reads the fixture DOM after both reply paths.
- `tests/ipc_test.zig:109-215` covers the Zig C ABI and dynamic result lifetime, but bypasses WebKit and the page process.
- `tools/dashboard_visual_check.mjs:73-77` stubs `zbHost` and bypasses every native node, as the research already says.

### Security consequence for the drawer

The existing handler is deliberately exposed to every loaded site's page world and has no origin/frame/nonce check. Adding Agent SDK session, prompt, permission, filesystem, or automation-tool commands to `zb_ipc_dispatch` would expose them to Instagram, LinkedIn, X, YouTube, and every other loaded site. The privileged drawer needs its own `WebKitUserContentManager` and bridge, with an app-owned content origin/world and explicit capability checks. It should not become an ordinary related `ZbWindow`, and it should not add powerful commands to global `zbHost`.

## Closure audit B: automation socket `page.evaluate`

### Current production chain

For an ordinary router command such as `page.evaluate`, the current chain is:

1. SDK/raw client writes a 4-byte big-endian framed request. Node `call` is `sdk/node/src/client.ts:86-125`; Python sync `call` is `sdk/python/src/zigbrowser/client.py:533-555`.
2. `handleStream` reads it (`src/automation_server.zig:312-346`) and calls `handleRequestWith` (`:408-543`).
3. `handleRequestWith` removes `window_id`, builds the `window-N`/`page-N` route (`:482-495,566-590`), obtains a fail-closed window handle (`:501-512`), and acquires that window's FIFO turn (`:514-527`).
4. `Engine.executeWith` (`src/automation/engine.zig:326-430`) runs the parsed command; `page.evaluate` reaches the PagePort.
5. `PagePort.evalJson` crosses the Zig/C ABI through `src/automation_gtk_port.zig:262-281` into `zb_automation_eval_json` (`src/webkit_shim.c:2905-2919`). The target is a stable numeric window id, never an implicit fallback.
6. `auto_run_op` uses one deadline for startup readiness and execution (`:2831-2875`), queues `auto_job_dispatch` (`:1511-1555`), and waits (`:1566-1615`). The GTK callback starts the page-world async JS call at `:2184-2205`.
7. The WebKit callback calls exactly-once `auto_job_complete` (`:1480-1496`). The waiter returns through C and the GTK adapter, which duplicates the result into the Zig allocator and frees the shim buffer (`automation_gtk_port.zig:255-280`).
8. The engine parses/formats the result; `handleRequestWith` creates the JSON-RPC envelope (`automation_server.zig:535-542`); `handleStream` calls `writeFrame` at `:342`; framing and flush are `:1168-1174`.

This validates the production chain, including the GTK handoff and return. It also shows why the structured map needs changes:

- Add explicit `splitWindowTarget`/`forWindow` and `PageCommandQueue.acquire` nodes between request handling and engine execution.
- The structured edge from `handleRequestWith` to `executeWith` is not cross-boundary. It remains in the same process and connection thread.
- The real asynchronous/thread boundary is inside the C adapter at idle dispatch and its WebKit callback.
- There is no direct `auto_job_dispatch -> reply_frame` edge. Completion publishes the result and wakes the waiter; the call unwinds through C, Zig adapter, engine, JSON-RPC envelope, and only then `writeFrame`. Add completion/waiter-return and envelope nodes.
- The 64 KiB cap at `automation_server.zig:17,326-332` applies to inbound request payloads. Replies use a `u32` length and are not capped at 64 KiB; screenshots can be larger.
- Pending C jobs are cancelled; running async jobs become abandoned (`webkit_shim.c:1600-1608`). A late completion is freed because `auto_job_complete` only publishes a `RUNNING` job (`:1480-1496`). Those ownership/tombstone semantics belong in the map or its contract notes.

### FIFO and out-of-band paths

- FIFO is per `page-N`, which is equivalent to one stable window id (`automation_server.zig:586-590`; acquire `:517`; `src/automation/queue.zig:55-96`). Different windows may execute concurrently. Across connections, order begins at queue acquisition, not at a global socket-arrival point. One connection is sequential because `handleStream` writes a reply before reading the next header.
- `page.list` and `page.close` branch before the ordinary router at `automation_server.zig:475-477` and run through `handleWindows`/`Engine.executeExternal` (`:657-745`). `page.list` takes no FIFO ticket; `page.close` acquires the target window's ticket at `:727-742`.
- `page.list` still crosses to GTK for one snapshot through PagePort (`automation_gtk_port.zig:164-213`; `webkit_shim.c:3835-3890`) with a fixed 10-second bound. It can bypass a page FIFO, but a frozen GTK main loop would still block it.
- `dialog.get` and `dialog.respond` are also out of band (`automation_server.zig:478-480,747-757`) because the command blocked by a dialog still owns its window's FIFO turn.
- `page.list` now exposes optional `crashed` reasons (`automation_server.zig:715-720`). A blank URL/title with a crash reason is a dead target, not an ordinary blank page.

### Tests and gaps

- `tests/e2e/automation_core_test.py:123-191` drives the real socket, server, router, engine, C/GTK handoff, injected automation, and live WebKit page for `page.evaluate` and the core DOM/page methods.
- `tests/e2e/sdk_python_live_test.py:41-63,82-106` adds the real Python SDK to that production chain. `sdk/node/tests/live.test.ts:69-115` does likewise for Node when run with `ZB_BINARY`.
- `tests/e2e/automation_windows_test.py:31-125` is the no-bypass multi-window proof: list/opener identity, targeted fill/click/read isolation, close ordering, closed-window failure, and preservation of the opener after both client close and popup self-close.
- `tests/e2e/web_process_crash_test.py:87-190` covers per-window/shared-family crash reporting through real `page.list`.
- Server N23 tests use real framing/routing/queue/engine but a fake PagePort, so they bypass GTK/C. Queue-only tests are not closure evidence for the native handoff.
- There is no committed regression that holds a window's FIFO turn and proves `page.list` answers out of band. The code is clear, but the property is not locked by a test. Add that test before using `page.list` as the drawer's liveness/discovery channel.

### Client concurrency constraint

The current SDK clients are not multiplexed. Node has one pending resolve/reject slot (`sdk/node/src/client.ts:12-13,65-82,101-111`) and does not match replies to an id-indexed map. Python's sync reader uses one uncorrelated response queue (`sdk/python/src/zigbrowser/client.py:508-550`). The server itself processes one request at a time per connection. If Agent SDK tool handlers can run concurrently, the integration must serialize one in-flight request per client/connection or first implement id-indexed multiplexing with late-reply handling. Node's 30-second client timer also equals the server's default command budget before transport overhead, so a legal late reply can arrive after the client has timed out.

## Changes since `d9ad717` that the next plan must absorb

### Window and drawer ownership

- `zb_window_new` remains the one standard-window insertion point, but it builds both the primary and every popup. Replacing its direct child with a container will add a drawer to every popup unless the plan explicitly gates it. Decide primary-only, every top-level, or app-global ownership. Screenshot mode has separate construction and should not gain the drawer.
- There is no current “active window” concept. Agent tools must retain an explicit selected `window_id`, refresh it from `page.list`, and fail closed when it disappears. Typed Node/Python DOM/page methods do not accept a window option; callers currently use raw `call` for targeted commands.
- Popups inherit `auto_opener_id` and `process_group` (`webkit_shim.c:751-755`). Closing one related view preserves its opener (`:871-877`), but a process crash affects the family. The drawer should not share the remote content's related process or UCM if it must remain available for diagnosis/recovery.

### Dialogs, crash state, and health

- Since the pin, page dialogs gained `dialog.get`, `dialog.respond`, `page.navigate.onBeforeUnload`, and `-32013 dialog_open`. A dialog blocks the related process family and can end in-flight page work (`webkit_shim.c:4117-4149`). The chat UI must surface the blocked window and ask for an explicit response; it must not silently accept a security-relevant prompt.
- Every window now records `crashed`, `memory_limit`, or `terminated_by_api` and logs it with the window id (`webkit_shim.c:4155-4179`). `page.list` passes it through. The drawer needs a dead-target state, must preserve conversation/session state outside the page process, and needs an explicit recovery policy rather than interpreting empty content as a healthy page.
- Current working-tree `page.health` work is **not part of committed `HEAD`**. The draft observes WebKit's `is-web-process-responsive`, debounces it, and proposes an all-window, no-queue read that never kills or reloads. It would diagnose a hung web process while GTK remains alive, not a hung GTK main loop. The plan must name it as a pending dependency and refresh its ABI/tests after it lands; it must not cite today's WIP lines as production.

### Render, media, and load behavior

- Linux's built-in rendering default is now WebKit's hardware policy plus `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` (`src/render_config.zig:33-42,68-105`). `--hardware-acceleration` and `--renderer` are applied before WebKit starts and per view (`src/app.zig:40-45`; `webkit_shim.c:1138-1144,4656-4666`). Any drawer WebView needs that same deliberate configuration.
- `--media-source on|off` / `ZIGBROWSER_MEDIA_SOURCE` now applies to normal windows, popups, and screenshots. The committed default remains `on` (`src/media_config.zig:18-22`), while the current live operational choice is `off`. Off both disables the WebKit setting and injects a page-world, all-frame script once per UCM to hide MSE constructors (`webkit_shim.c:4596-4628`). The drawer must work without MSE and must not accidentally inherit a remote page's UCM/script policy.
- The 15-second startup watchdog no longer kills a committed document and will not terminate a process another related view shares (`webkit_shim.c:769-815`). Drawer bootstrap/failure UI needs its own bounded state machine rather than borrowing that page-load watchdog.
- The system WebKitGTK version is now 2.54.0, so research lines 58, 322, and 570 describing 2.52.6 are environmentally stale.

### Agent process and streaming channel

- Integrating either Agent SDK changes the current process model: it adds an SDK/Claude child process with stdin/stdout streaming, cancellation, exit, stderr, and backpressure ownership. Define who spawns it, how it is terminated on browser/window shutdown, whether it is app-global or per chat session, and how credentials/environment are deliberately inherited. The existing e2e `xsession.py` guardian is test infrastructure, not production child supervision.
- The automation WebSocket is not a push bus; it emits one `automation.ready` frame and closes. The existing page-world `zbHost` is request/reply only. A chat drawer needs an explicit privileged native-to-drawer streaming channel with ordering, bounded buffering/backpressure, cancellation, drawer reload/reconnect, and process-exit behavior.
- Do not treat general `webkit_web_view_evaluate_javascript` as an existing production event channel. The ordinary PagePort call is a request/response async function in a selected world; the only current fire-and-forget production call is a narrowly scoped automation-world navigation notification.
- Agent permission prompts and browser page dialogs are different state machines. The plan must keep them distinguishable in the UI and avoid holding a page FIFO while waiting indefinitely for a chat permission decision.
- If browser automation is exposed as Agent SDK custom tools, start with the existing flow `dry_run` safety surface for committing social actions, carry explicit `window_id`, and serialize client calls until SDK multiplexing is fixed.

## Required research updates before planning

1. Repin the research and both closure adapters to the implementation commit used by the plan; do not edit the historical pinned document in place.
2. Replace ClosureMap A's per-window registration statement with the shared-UCM contract, and add the missing Promise-settlement assertion.
3. Expand ClosureMap B with window target, per-window queue, completion/waiter return, and JSON-RPC envelope nodes; model `page.list`, `page.close`, and dialogs as separate special paths.
4. Decide and document drawer ownership (primary-only versus every top-level), separate WebView/UCM/process isolation, privileged bridge authentication, and app-owned content loading.
5. Specify Agent SDK subprocess lifecycle and the native-to-drawer streaming/backpressure protocol before selecting TypeScript versus Python.
6. Repin after `page.health` lands and add regressions for its no-queue behavior and committed `page.list`'s out-of-band behavior.
