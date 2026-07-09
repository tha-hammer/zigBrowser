---
date: 2026-07-09T14:40:00-05:00
researcher: SAI
git_commit: c1ebbd7fd05fa9696cc7d76053a03f6a981b2c7b
branch: master
repository: zigBrowser
topic: "Codebase research: existing seams, interfaces, and infrastructure relevant to building a browser automation API"
tags: [research, codebase, ipc, automation, c-abi, webview, zbhost, injection, e2e-protocol]
status: complete
last_updated: 2026-07-09
last_updated_by: SAI
---

# Research: Existing Codebase Seams for Browser Automation API

**Date**: 2026-07-09T14:40:00-05:00
**Researcher**: SAI
**Git Commit**: c1ebbd7fd05fa9696cc7d76053a03f6a981b2c7b
**Branch**: master
**Repository**: zigBrowser

## Research Question

What exists in the zigBrowser codebase today that is relevant to building a browser automation API for controlling social media platforms (LinkedIn, Instagram, TikTok, Facebook)? Document all seams, interfaces, injection mechanisms, and infrastructure that an automation system would extend or interact with.

## Summary

zigBrowser is a cross-platform WebView app shell (Tauri-alternative) with a functional bidirectional IPC bridge between page JavaScript and native Zig code. The codebase has a clear, well-separated architecture: OS-agnostic Zig logic (`ipc.zig`, `nav_policy.zig`) behind a C ABI contract (`webkit_shim.h`), with three platform shims implementing the same surface for Linux/WebKitGTK, Windows/WebView2, and macOS/WKWebView.

The IPC dispatch table (`src/ipc.zig`) currently handles 4 commands (`ping`, `add`, `echo`, `os.info`) and is explicitly identified as the extension seam for new automation verbs. The JS bridge (`zbhost.js`) provides the page-side transport. The E2E protocol (`--e2e-protocol`) demonstrates a proven event-emission pattern for machine-readable output. No automation, DOM interaction, cookie management, JS evaluation (from native), or external API server infrastructure exists today.

## Detailed Findings

### 1. IPC Dispatch Mechanism (`src/ipc.zig`, 187 lines)

The core extension point for automation commands.

**Pure Zig entry point** (`src/ipc.zig:16-40`):
```zig
pub fn dispatch(allocator: std.mem.Allocator, cmd: []const u8, args_json: []const u8) IpcError![]const u8
```
- Linear `std.mem.eql` chain against `cmd` string
- Returns allocator-owned `[]const u8` containing a JSON-encoded result
- Error type: `IpcError = error{ UnknownCommand, BadArgs }`

**C ABI export** (`src/ipc.zig:42-74`):
```zig
pub export fn zb_ipc_dispatch(cmd, args_json, out_result, out_err) c_int
```
- Uses threadlocal `FixedBufferAllocator` over 64KB scratch buffer
- Result ceiling: 4096 bytes (4095 usable + nul terminator)
- Return codes: 0=success, 1=UnknownCommand, 2=BadArgs
- Pointers valid until next call on same thread

**Current command table:**

| Command | Args | Returns |
|---------|------|---------|
| `ping` | none | `"pong"` (JSON string) |
| `add` | `{a: i64, b: i64}` | sum as number literal |
| `echo` | `{msg: string}` | msg as JSON string |
| `os.info` | none | `{sysname, release, machine}` |

**Test coverage** (`tests/ipc_test.zig`, 165 lines): Happy paths, arg validation, error codes, 4096-byte ceiling boundary test.

### 2. C ABI Contract (`src/webkit_shim.h`, 47 lines)

Bidirectional interface between Zig and platform shims.

**Group A — Shim implements, Zig calls** (lifecycle/UI):

| Function | GTK | WebView2 | WKWebView |
|----------|-----|----------|-----------|
| `zb_app_run(uri, print_title, e2e_protocol)` | `webkit_shim.c:1103` | `webview2_shim.cpp:707` | `wkwebview_shim.m:788` |
| `zb_run_screenshot(uri, out_path, print_title)` | `webkit_shim.c:1601` | `webview2_shim.cpp:751` | `wkwebview_shim.m:838` |
| `zb_version_line(buf, len)` | `webkit_shim.c:1605` | `webview2_shim.cpp:759` | `wkwebview_shim.m:853` |
| `zb_run_open(uri, print_title)` | `webkit_shim.c:1186` | **not implemented** | `wkwebview_shim.m:834` |
| `zb_reload(win, bypass_cache)` | `webkit_shim.c:958` | **not implemented** | `wkwebview_shim.m:872` |
| `zb_window_new(app, native_view)` | `webkit_shim.c:893` | **not implemented** | `wkwebview_shim.m:880` |

**Group B — Zig implements, shim calls** (policy + IPC):

| Function | Implementation | Callers |
|----------|---------------|---------|
| `zb_policy_decide(base, candidate, dtype)` | `nav_policy.zig:40-44` | `webkit_shim.c:864`, `wkwebview_shim.m:532,554,570` |
| `zb_ipc_dispatch(cmd, args_json, out_result, out_err)` | `ipc.zig:42-74` | `webkit_shim.c:591`, `wkwebview_shim.m:611`, `webview2_shim.cpp:444` |

**Opaque types**: `ZbApp`, `ZbWindow` — defined differently per platform. `ZB_MAX_WINDOWS = 16`.

**Force-link in main.zig** (`src/main.zig:8-11`):
```zig
comptime { _ = @import("ipc.zig"); _ = @import("nav_policy.zig"); }
```

### 3. JavaScript Bridge (`tests/fixtures/app/zbhost.js`, 134 lines)

Page-side API for IPC.

**Public API**: `window.zbHost(cmd, args) → Promise<result>`

**Transport detection** (tries GTK first, falls back to WebView2):

| Platform | Transport | Reply Mechanism |
|----------|-----------|-----------------|
| Linux/macOS | `window.webkit.messageHandlers.zbHost.postMessage(JSON.stringify({cmd, args}))` | Native reply callback (sync per-call) |
| Windows | `window.chrome.webview.postMessage(JSON.stringify({id, cmd, args}))` | Message event with correlation ID |

**Key differences**:
- GTK/macOS: `postMessage` returns a value directly (reply-capable handler)
- WebView2: fire-and-forget message + ID-keyed pending-promise map + `message` event listener for responses (`zbhost.js:69-108`)

### 4. Script Injection Mechanisms

Current state of JS injection from native into the WebView:

| Platform | Document-Start Injection | Isolated World | `__zigBrowserBackend` |
|----------|-------------------------|----------------|----------------------|
| Linux (WebKitGTK) | **None** — only IPC handler registration | No | **Not injected** |
| Windows (WebView2) | `AddScriptToExecuteOnDocumentCreated` (`webview2_shim.cpp:555-578`) | No (IIFE only) | `'webview2'` |
| macOS (WKWebView) | `WKUserScript` at `WKUserScriptInjectionTimeAtDocumentStart` (`wkwebview_shim.m:383-393`) | `WKContentWorld.pageWorld` (page world, not isolated) | `'wkwebview'` |

**No isolated content worlds are used anywhere.** All injection runs in the page's normal JS global context. The `zbHost` handler on macOS is explicitly registered in `WKContentWorld.pageWorld` (`wkwebview_shim.m:368`).

**JS evaluation from native** — only one call site exists today:
- `webkit_web_view_evaluate_javascript(view, "document.title", ...)` at `webkit_shim.c:1255-1264` (screenshot title retrieval, async with GAsyncResult callback)
- macOS/Windows use native WebView APIs for title (`webView.title`, `get_DocumentTitle`) — no `evaluateJavaScript` calls from native.

### 5. Navigation Policy (`src/nav_policy.zig`, ~144 lines)

**Decision enum**: `use` (allow), `ignore` (block), `open_in_subwindow`

**Logic** (`nav_policy.zig:24-38`):
- `.new_window_action` → always `open_in_subwindow`
- `.response` → always `use`
- `.navigation_action` → `file://` containment check (canonicalize paths, reject `../` traversal)
- Non-file base (http/https) → permissive (always `.use`, since `canonicalBaseDirPath` fails on non-file schemes → fallback `.use`)

**Key implication for automation**: When zigBrowser loads `https://linkedin.com`, the navigation policy is fully permissive — all same-origin and cross-origin navigation is allowed. Policy only restricts `file://` URIs to stay within `app_base`.

### 6. CLI (`src/cli.zig`, 153 lines)

**Current flags:**

| Command | Syntax |
|---------|--------|
| Default (open) | `zigbrowser [URL] [--print-title] [--e2e-protocol]` |
| Screenshot | `zigbrowser --screenshot <out.png> <URL> [--print-title]` |
| Version | `zigbrowser --version` |

Default URL (no args): `https://cosmic-hr-development.up.railway.app/`

**No `--automation-api` or similar flag exists.** Adding one would follow the exact pattern of `--e2e-protocol`: a boolean flag parsed in `parseOpenArgs`, threaded through `Command.open`, passed to `zb_app_run`.

### 7. E2E Protocol and Test Infrastructure

**Protocol** (`tests/e2e/PROTOCOL.md`): Line-delimited, tab-separated stdout events, flushed immediately. Gated by `app->e2e_protocol` flag.

**Event tags**:

| Tag | Format | Emitter |
|-----|--------|---------|
| `NAV` | `NAV\t<uri>\t<title>` | `webkit_shim.c:241-255` |
| `IPC` | `IPC\t<cmd>\t<result_json>` | `webkit_shim.c:597` |
| `IPCERR` | `IPCERR\t<cmd>\t<error_name>` | `webkit_shim.c:563,572,581,601` |
| `BLOCKED` | `BLOCKED\t<candidate_uri>` | `webkit_shim.c:853,884,889` |
| `SUBWIN` | `SUBWIN\t<uri>` | `webkit_shim.c:814-815` |
| `WINCOUNT` | `WINCOUNT\t<n>` | `webkit_shim.c:305` |
| `LOAD_FAIL` | `LOAD_FAIL\t<uri>\t<domain>\t<code>` | `webkit_shim.c:182-194` |

**Python test harness** (`tests/e2e/slice2_common.py`):
- `run_interactive_until(cmd, env, timeout, condition, on_tick)` — spawn binary, poll stdout, assert condition
- `protocol_rows(lines, prefix)` — filter/split by tag
- Hash-triggered scenarios: Python builds URI with `#auto=<scenario>`, fixture JS reads hash and clicks pre-wired elements
- Tests never drive DOM directly — assertions are on protocol stdout lines

**Playwright** (`e2e/example.spec.ts`): Untouched boilerplate testing `playwright.dev` itself. No connection to zigBrowser. Not a foundation for anything.

### 8. Cookie and Session Management

**Current state: minimal and implicit.**

| Platform | Cookie Config | Data Store | Profile System |
|----------|--------------|------------|----------------|
| Linux (GTK) | `ACCEPT_ALWAYS` on default context (`webkit_shim.c:1122-1126`) | Default `WebKitWebContext` (implicit path) | None |
| Windows | None | `CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, ...)` (`webview2_shim.cpp:692`) — default user data folder | None |
| macOS | None | `WKWebsiteDataStore.defaultDataStore` (implicit) | None |

**Screenshot path**: Uses isolated context on GTK (`webkit_web_context_new()` at `webkit_shim.c:1552`).

**No cookie get/set/delete APIs exist.** No persistent storage path configuration. No user-data-dir option.

### 9. Window Management

**GTK** (`webkit_shim.c:61-110`):
- `ZbApp.windows[ZB_MAX_WINDOWS]` array + `n_windows` counter
- Child windows: `webkit_web_view_new_with_related_view(parent_view)` (shares context/cookies)
- Each window gets its own IPC handler via `install_ipc_handler`

**macOS** (`wkwebview_shim.m:242-349`):
- `ZBAppHost.windows` (`NSMutableArray`) + `mainWindow`
- Child windows: reuse same `WKWebViewConfiguration` from `createWebViewWithConfiguration:` delegate
- Cookies shared via same `WKWebsiteDataStore.defaultDataStore`

**Windows** (`webview2_shim.cpp`):
- Single `AppState` struct with one `ICoreWebView2` instance
- No multi-window support — no `NewWindowRequested` handler, no `zb_window_new` implementation

### 10. Process Lifecycle

1. `main()` → `cli.parseArgs()` → `uri.validate()` → `zb_app_run(uri, print_title, e2e_protocol)`
2. GTK init → cookie policy → create main WebView → `zb_window_new` (wires signals) → load URI → `gtk_main()`
3. Signals wired per-window: `load-changed`, `load-failed`, `notify::title`, `decide-policy`, `create`, GTK `destroy`
4. SIGHUP → reload window 0; SIGINT → exit 130 with 3s deadline; SIGTERM → immediate shutdown
5. Last window close → `gtk_main_quit()` → `zb_app_run` returns exit code

## Code References

- `src/ipc.zig:16-40` — `dispatch()` command table
- `src/ipc.zig:42-74` — `zb_ipc_dispatch` C ABI export
- `src/webkit_shim.h:30-41` — complete C ABI contract
- `src/webkit_shim.c:530-548` — `install_ipc_handler` (GTK)
- `src/webkit_shim.c:550-608` — `on_ipc_message_received` (GTK IPC handler)
- `src/webkit_shim.c:835-891` — `on_window_decide_policy` (navigation policy)
- `src/webkit_shim.c:1103-1183` — `zb_app_run` (GTK, main lifecycle)
- `src/webview2_shim.cpp:412-463` — `handle_web_message` (Windows IPC handler)
- `src/webview2_shim.cpp:555-578` — `install_document_script_and_navigate` (Windows injection)
- `src/wkwebview_shim.m:367-368` — `zbHost` handler registration (macOS)
- `src/wkwebview_shim.m:383-393` — `+newConfiguredWebView` (macOS injection)
- `src/wkwebview_shim.m:582-623` — IPC handler (macOS)
- `src/nav_policy.zig:24-38` — `decide()` logic
- `src/cli.zig:54-84` — `parseOpenArgs` (flag parsing)
- `src/main.zig:37-49` — `.open` command execution
- `tests/fixtures/app/zbhost.js:110-131` — `zbHost()` public API
- `tests/e2e/slice2_common.py:144-200` — `run_interactive_until` harness
- `specs/architecture.md` — active architecture specification

## Architecture Documentation

**Data flow (existing IPC, JS→Zig direction):**
```
Page JS → zbhost.js → platform message handler → shim on_ipc_message_received
→ zb_ipc_dispatch (C ABI) → ipc.dispatch() (Zig) → JSON result
→ shim reply → JS Promise resolves
```

**Data flow (automation would require, external→WebView direction):**
```
External client → [NEW: socket/HTTP server in Zig] → [NEW: zb_evaluate_js (Group A)]
→ platform shim evaluates JS in WebView → result back → client response
```

**Key architectural constraint**: The current IPC only flows JS→Zig. Automation needs Zig→JS (evaluate arbitrary JS from native side). Only one existing call does this today: `webkit_web_view_evaluate_javascript` for screenshot title retrieval on GTK. WebView2 has `ExecuteScriptAsync` available but unused. macOS has `evaluateJavaScript:` available but unused.

**Build system**: Zig 0.16.0, `build.zig` auto-selects backend per target OS. No external Zig dependencies. Platform deps via pkg-config (GTK) or SDK paths (WebView2) or frameworks (macOS).

## Workflow Closure Map

The existing IPC roundtrip behavior: "Page JavaScript sends a command via zbHost → platform shim receives and dispatches → Zig processes → result returned to JS."

**Production chain:**

```text
Page JS zbHost(cmd, args)
  → zbhost.js serializes JSON, calls platform transport
  → Platform shim message handler (webkit_shim.c:550 / webview2_shim.cpp:412 / wkwebview_shim.m:582)
  → Extracts cmd/args_json, calls zb_ipc_dispatch (ipc.zig:42)
  → ipc.dispatch() matches command (ipc.zig:16-40)
  → Result JSON copied to threadlocal buffer (ipc.zig:66-73)
  → Shim sends reply via platform mechanism
  → Page JS Promise resolves with result
```

**Per-edge evidence:**

| Edge | Producer | Consumer | Registration | Contract | Error behavior | Tests |
|------|----------|----------|--------------|----------|---------------|-------|
| JS → shim | `zbhost.js:110-131` | `webkit_shim.c:550` | `install_ipc_handler` (`webkit_shim.c:530-548`) via `g_signal_connect_data` | JSON envelope `{cmd: string, args: object}` | Invalid JSON → `IPCERR "invalid"` reply | `ipc_roundtrip_test.py` |
| shim → Zig | `webkit_shim.c:591` | `ipc.zig:42` | `comptime` force-link in `main.zig:8-11` | C ABI: `int zb_ipc_dispatch(char*, char*, char**, char**)` | rc≠0 → `out_err` set | `tests/ipc_test.zig` |
| Zig dispatch | `ipc.zig:42` | `ipc.zig:16` (dispatch fn) | Direct call within same module | `dispatch(allocator, cmd, args_json) → IpcError![]const u8` | `UnknownCommand`/`BadArgs` error union | `tests/ipc_test.zig` |
| Zig → shim (reply) | `ipc.zig:72` (sets `out_result`) | `webkit_shim.c:592-597` | Same call stack (synchronous return) | Nul-terminated C string, valid until next call | Result >4095 bytes → `BadArgs` error | `tests/ipc_test.zig:128-160` |
| shim → JS | `webkit_shim.c:595` | `zbhost.js:31` | WebKit reply mechanism / WebView2 `PostWebMessageAsString` | JSON value (GTK: `JSCValue`; Win: `{id, result}` string) | Error → `webkit_script_message_reply_return_error_message` | `ipc_roundtrip_test.py` |

**Node labels and depths:**

| Depth | Node | Module | production-called | adds_or_changes |
|-------|------|--------|-------------------|-----------------|
| 0 | `zbhost.js:zbHost()` | JS bridge | production-called (every page load) | No |
| 1 | shim message handler | platform shim (C/ObjC/C++) | production-called | No |
| 2 | `zb_ipc_dispatch` | ipc.zig (C ABI) | production-called | No |
| 3 | `ipc.dispatch()` | ipc.zig (Zig) | production-called | **Yes** (new commands added here) |
| 4 | shim reply path | platform shim | production-called | No |
| 5 | JS Promise resolution | zbhost.js | production-called | No |

**`highest_new_connector`**: Depth 3 (`ipc.dispatch()`) — this is where new automation commands are added.

### ClosureMap (structured — derive() input)

```json
{
  "behavior": "Page JavaScript sends an IPC command via zbHost and receives the dispatched result as a resolved Promise",
  "git_commit": "c1ebbd7fd05fa9696cc7d76053a03f6a981b2c7b",
  "repo": "/home/maceo/ntm_Dev/zigBrowser",
  "nodes": [
    { "id": "zbhost-js-call", "module": "js-bridge", "is_entrypoint": true, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "shim-message-handler", "module": "platform-shim", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "zb-ipc-dispatch-cabi", "module": "ipc", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "ipc-dispatch-zig", "module": "ipc", "is_entrypoint": false, "adds_or_changes": true, "read_path": null, "seedable_store": null },
    { "id": "shim-reply", "module": "platform-shim", "is_entrypoint": false, "adds_or_changes": false, "read_path": null, "seedable_store": null },
    { "id": "js-promise-resolution", "module": "js-bridge", "is_entrypoint": false, "adds_or_changes": false, "read_path": "zbHost", "seedable_store": null }
  ],
  "edges": [
    { "is_async": true, "cross_boundary": true, "driver": "on_ipc_message_received" },
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": false, "cross_boundary": false, "driver": null },
    { "is_async": false, "cross_boundary": true, "driver": null },
    { "is_async": true, "cross_boundary": true, "driver": "onWebViewReply" }
  ]
}
```

## Historical Context (from thoughts/)

- `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md` — Original IPC surface design research. Identifies `ipc.zig` dispatch table as "Slice-4 command surface seam." Documents the cross-OS backend architecture choices.
- `thoughts/searchable/shared/plans/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4.md` — TDD plan for IPC + cross-OS backends
- `thoughts/searchable/shared/plans/2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8.md` — Windows WebView2 backend TDD plan
- `thoughts/searchable/shared/research/2026-07-04-08-57-zigbrowser-filestore-seams-grammar-contracts.md` — Filestore seams, interfaces, contracts, grammar documentation
- `thoughts/searchable/shared/research/2026-07-04-12-30-build-time-config-seams.md` — Build-time JSON config ingestion research
- `thoughts/searchable/shared/research/2026-07-07-14-45-zig-repl-embedding-sandboxed-inference.md` — REPL embedding research (JS evaluation from native side)
- `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md` — Same-day automation API design research (the input to this codebase research)
- `specs/architecture.md` — Active architecture spec (Slice 2 app shell)
- `specs/lifecycle.md` — Load/snapshot lifecycle, teardown order
- `tests/e2e/PROTOCOL.md` — Normative E2E protocol spec

## Related Research

- `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md` — The automation API design synthesis that motivated this codebase research. Proposes a 3-layer architecture (injected script, automation engine extending ipc.zig, external JSON-RPC server).

## Open Questions

1. **JS evaluation from Zig**: The automation API requires Zig → JS direction (evaluate JS in the WebView from native code). Only one callsite exists today (`webkit_web_view_evaluate_javascript` for screenshot title). This needs new Group-A C ABI functions per platform — what's the async callback story for cross-platform JS evaluation results?
2. **4096-byte result ceiling**: Current `zb_ipc_dispatch` truncates results >4095 bytes to an error. DOM queries (e.g., `dom.query` returning multiple elements with bbox data) could easily exceed this. The ceiling is enforced by a threadlocal buffer — what's the migration path (dynamic allocation? streaming?)?
3. **Windows multi-window gap**: WebView2 shim has no `zb_window_new`/`zb_reload`/`NewWindowRequested` — automation needs to interact with specific windows/tabs. Is Windows multi-window a prerequisite?
4. **Linux document-start injection**: GTK has NO document-start script injection (unlike Windows/macOS which inject `__zigBrowserBackend`). Automation's injected selector engine needs document-start injection on all platforms.
5. **Isolated worlds**: No platform currently uses an isolated JS world. Automation scripts in the page's global context are visible to page anti-bot scripts. WebKitGTK supports `world_name` parameter; WKWebView supports `WKContentWorld`; WebView2 would need IIFE wrapping.
