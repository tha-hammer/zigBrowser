---
date: 2026-07-09T11:55:51-04:00
planner: Codex
git_commit: f9af985
branch: master
repository: zigBrowser
topic: "Phase 1 Core Automation Engine TDD plan"
tags: [tdd, plan, automation, phase-1, ipc, injected-script, telemetry]
status: draft
scope: "Phase 1 only: Layer 1 injected selector/action JS plus Layer 2 Zig automation engine"
source_prd: thoughts/searchable/shared/prd/2026-07-09-browser-automation-api.md
source_context_map: thoughts/searchable/shared/prd/2026-07-09-browser-automation-api-context-map.html
coordination: "Non-overlap note: Agent Mail showed an active Phase 2/3 external API/platform-input claim; this plan does not design Layer 3, SDKs, social contracts, anti-detection pacing, or Phase 3 native input."
---

# Phase 1 Core Automation Engine TDD Implementation Plan

## Overview

Build only the Phase 1 core automation engine: the injected selector/action script
and the Zig-side engine that routes `dom.*` and `page.*` commands through the
existing IPC surface. This plan makes the smallest implementation that lets a
fixture page prove selector resolution, actionability checks, DOM actions, page
primitives, command serialization, typed automation errors, and telemetry.

The plan intentionally does not implement the external JSON-RPC socket, SDKs,
social media adapters, pacing, anti-detection behavior simulation, cookies,
network interception, or Phase 3 native/CDP input dispatch. It exposes the
interfaces those later phases need, but stops at the Phase 1 boundary.

## Source Contracts

- PRD section 3 requires the IPC result-buffer fix before any automation command
  ships: the current 4096 byte C string ceiling blocks `dom.query`,
  `page.evaluate`, and `page.screenshot` results
  (`2026-07-09-browser-automation-api.md:70`).
- PRD section 4 defines the injected script surface: selectors, actionability,
  DOM actions, and wait primitives
  (`2026-07-09-browser-automation-api.md:409`,
  `:423`, `:439`, `:452`, `:464`).
- PRD section 5 defines Layer 2 command verbs, the 16 ms guaranteed contract
  loop, 12-case `AutomationError`, and the page command queue
  (`2026-07-09-browser-automation-api.md:474`, `:478`, `:517`, `:537`, `:558`).
- PRD section 7 defines root `automation.command` spans, child spans, and the
  redaction/privacy contract
  (`2026-07-09-browser-automation-api.md:629`, `:650`, `:669`, `:686`).
- Context map Phase 1 bounded contexts are BC3, BC6, BC7, and BC11, with gaps
  G1, G5, G6, G8, and G9 blocking the work
  (`2026-07-09-browser-automation-api-context-map.html:323`,
  `:387`, `:395`, `:411`, `:419`, `:926`, `:1051`, `:1536`).

## Current State Analysis

- `src/ipc.zig` has only `ping`, `add`, `echo`, and `os.info`, all routed by
  string comparison in `dispatch()` (`src/ipc.zig:16`).
- `zb_ipc_dispatch` uses a threadlocal 64 KB scratch buffer and a threadlocal
  4096 byte result buffer (`src/ipc.zig:12`, `src/ipc.zig:13`). Oversized
  results are converted to `BadArgs` (`src/ipc.zig:66`).
- The current IPC test suite explicitly asserts that 4094 bytes of echo payload
  fails through the C ABI (`tests/ipc_test.zig:128`).
- The platform IPC handlers call `zb_ipc_dispatch(cmd, args, ...)` without page
  context: GTK at `src/webkit_shim.c:591`, WebView2 at
  `src/webview2_shim.cpp:443`, and macOS at `src/wkwebview_shim.m:611`.
  A `dom.*` command therefore needs a new page-aware dispatch path that receives
  the originating `ZbWindow *`.
- Existing platform code has partial document-start script hooks but no general
  automation script or native-to-JS command path. WebView2 injects only
  `window.__zigBrowserBackend` (`src/webview2_shim.cpp:555`); macOS does the
  same through `WKUserScript` (`src/wkwebview_shim.m:387`). GTK has a
  JS-to-native handler (`src/webkit_shim.c:530`) and an unrelated title eval in
  screenshot code (`src/webkit_shim.c:1262`).
- `build.zig` wires root, IPC, nav policy, and Windows IPC compile tests, but no
  automation modules or script tests (`build.zig:176`, `build.zig:223`).
- The existing E2E harness is line-oriented stdout protocol with file fixtures
  (`tests/e2e/PROTOCOL.md:3`, `tests/e2e/slice2_common.py:144`). Phase 1 needs a
  deterministic automation fixture server because `page.navigate`,
  wait-for-navigation, and network-idle style waits cannot be validated with
  only static `file://` fixtures.

## Desired End State

The repository has a tested Phase 1 automation core:

- `src/ipc.zig` no longer has a 4096 byte result ceiling on the C ABI. Result
  pointers are heap-backed and valid until the next dispatch call on the same
  thread.
- A page-aware IPC entry point lets platform handlers call automation commands
  with the originating page/window while preserving the old `zb_ipc_dispatch`
  compatibility path for non-page commands.
- `dom.*` and `page.*` commands are routed by the Zig automation router and
  executed through a per-page FIFO queue.
- The engine implements the 16 ms retry loop with deterministic fake-clock unit
  tests and real fixture E2E tests.
- A single injected JS file exposes `globalThis.__zbAutomation.handle(json)` in
  the automation world/IIFE scope. It implements selector parsing,
  actionability checks, DOM actions, and wait primitives.
- `AutomationError` has the 12 PRD cases and exposes the downstream code mapping
  `-32001` through `-32012`, without implementing the external JSON-RPC server.
- `TelemetrySink` has an in-memory sink, emits one root `automation.command`
  span per command, emits child spans for selector/actionability/eval, and
  fails tests on raw sensitive data or denied telemetry keys.

## What We Are Not Doing

- No `--automation-api`, Unix domain socket server, WebSocket event push, token
  auth, JSON-RPC framing, CLI activation, SDK, or external client.
- No `cookies.*`, `session.*`, `social.*`, `linkedin.*`, or `instagram.*`
  command implementation.
- No Phase 3 native/CDP input optimization. Phase 1 DOM actions use injected JS
  event synthesis only.
- No behavior simulation, pacing layer, platform rate-limit detector, stealth
  assessment events, or anti-detection hardening beyond the script cleanup and
  telemetry redaction contracts required by Phase 1.
- No network interception implementation or network capability stubs.

## Interfaces Exposed Downstream

These interfaces are exposed so Phase 2/3/5 plans can depend on stable contracts.
This plan does not implement their external consumers.

### Command Verbs

Phase 1 router verbs:

| Verb | Request | Response |
|---|---|---|
| `dom.query` | `{ selector, timeout_ms?, strict? }` | `{ elements: [{ id, tag, text, bbox }] }` |
| `dom.click` | `{ selector, options? }` | `{ ok: true }` or `AutomationError` |
| `dom.fill` | `{ selector, value, options? }` | `{ ok: true }` or `AutomationError` |
| `dom.type` | `{ selector, text, delay_ms?, options? }` | `{ ok: true }` or `AutomationError` |
| `dom.getText` | `{ selector, options? }` | `{ text: string }` |
| `dom.getAttribute` | `{ selector, name, options? }` | `{ value: string | null }` |
| `dom.waitFor` | `{ selector, state?, timeout_ms? }` | `{ ok: true }` or `AutomationError` |
| `page.navigate` | `{ url, waitUntil?, timeout_ms? }` | `{ ok: true }` or `AutomationError` |
| `page.reload` | `{ waitUntil?, timeout_ms? }` | `{ ok: true }` or `AutomationError` |
| `page.url` | `{}` | `{ url: string }` |
| `page.title` | `{}` | `{ title: string }` |
| `page.evaluate` | `{ expression }` | `{ result: any }` |
| `page.screenshot` | `{ fullPage? }` | `{ data: base64 }` |

### AutomationError Taxonomy

| Error | Downstream code |
|---|---:|
| `element_not_found` | -32001 |
| `element_not_visible` | -32002 |
| `element_not_stable` | -32003 |
| `element_obscured` | -32004 |
| `element_disabled` | -32005 |
| `element_not_editable` | -32006 |
| `navigation_timeout` | -32007 |
| `navigation_failed` | -32008 |
| `action_timeout` | -32009 |
| `platform_rate_limited` | -32010 |
| `session_invalid` | -32011 |
| `cancelled` | -32012 |

### Zig Interfaces

Planned files and ownership:

- `src/automation/error.zig`: `AutomationError`, name/code helpers, retryable
  classification.
- `src/automation/page_port.zig`: `AutomationPagePort` vtable for
  `injectScript`, `evalScript`, `navigate`, `reload`, `currentUrl`, `title`, and
  `screenshot`. Fake port lives in tests.
- `src/automation/script_command.zig`: JSON command/result envelope builders and
  parsers for injected JS.
- `src/automation/engine.zig`: 16 ms retry loop, timeout/cancellation handling,
  script response mapping, and root command telemetry.
- `src/automation/queue.zig`: per-page FIFO queue and cancellation handles.
- `src/automation/router.zig`: method grammar, param validation, and dispatch
  from `dom.*`/`page.*` to engine calls.
- `src/automation/telemetry.zig`: `TelemetrySink`, `InMemoryTelemetrySink`,
  redaction scanner, root/child span schemas.
- `src/automation.zig`: public module facade imported by `src/ipc.zig`.
- `src/automation_script/automation.js`: injected script source.
- `tests/automation_*`: Zig unit/integration tests.
- `tests/fixtures/automation/` and `tests/e2e/automation_*.py`: deterministic
  fixture server and real-binary E2E harnesses.

### C ABI Additions

Add page-aware automation dispatch while keeping old IPC stable:

```c
int zb_ipc_dispatch(const char *cmd, const char *args_json,
                    const char **out_result, const char **out_err);

int zb_ipc_dispatch_for_page(ZbWindow *win, const char *cmd,
                             const char *args_json,
                             const char **out_result,
                             const char **out_err);

int zb_automation_eval_json(ZbWindow *win, const char *source,
                            const char *world,
                            const char **out_result,
                            const char **out_err);

int zb_automation_inject_script(ZbWindow *win, const char *source,
                                const char *world,
                                const char **out_err);
```

`zb_ipc_dispatch_for_page` delegates non-automation commands to the existing
dispatch table and routes `dom.*`/`page.*` through the automation router with a
PagePort backed by `win`. `zb_ipc_dispatch` remains valid for tests and legacy
callers but returns `BadArgs` for page-required commands.

## Testing Strategy

- Zig unit and integration tests via `zig build test`.
- A separate JavaScript/DOM suite using Playwright against local fixture pages,
  scoped to the injected script only.
- Real-binary GTK E2E tests first, reusing `tests/e2e/slice2_common.py`; macOS and
  Windows backend tests are compile or hardware-gated smoke checks in Phase 1
  unless the host backend is available.
- Fake PagePort and fake clock tests for engine behavior so retry timing,
  timeout mapping, queueing, and telemetry are deterministic.
- Red/Green/Refactor discipline: every milestone starts by adding or updating
  tests that fail against the current repository for the intended reason.

Core verification commands:

```bash
zig build test
npx playwright test e2e/automation_script.spec.ts --project=chromium
python3 tests/e2e/automation_core_test.py --binary zig-out/bin/zigBrowser
```

The final Phase 1 gate is all three commands plus any platform-gated commands
available on the local host.

## Behavior M0: Scope Guard and Test Harness Wiring

### Specification

Given the existing default Playwright example and no automation tests, when Phase
1 starts, then the build/test harness has explicit automation targets and the
boilerplate Playwright example no longer influences Phase 1 signal.

### TDD Cycle

Red:

- Add `tests/automation_smoke_test.zig` importing the planned automation facade
  and asserting the Phase 1 command verb list.
- Add `e2e/automation_script.spec.ts` with a skipped or failing import of the
  injected script source.
- Add `tests/e2e/automation_fixture_server.py` with one endpoint test that proves
  the server returns deterministic HTML and no external network.
- Wire new Zig tests into `build.zig`; the first run fails because modules do not
  exist.

Green:

- Add empty module facades and fixture server skeletons sufficient to make the
  harness compile while later behavior tests still fail.
- Replace or isolate the default `e2e/example.spec.ts` so CI does not call
  `https://playwright.dev/` as part of this product test suite.

Refactor:

- Keep automation tests under stable names (`automation_*`) and document the
  commands in `tests/e2e/README.md`.

Success criteria:

- `zig build test` runs the automation smoke test.
- `npx playwright test e2e/automation_script.spec.ts --project=chromium` fails
  only on missing behavior, not on fixture setup.

## Behavior M1: IPC Result Buffer Has No 4096 Byte Ceiling

### Specification

Given a command result larger than 4095 bytes, when the C ABI dispatch returns
success, then `out_result` points at a complete nul-terminated JSON string valid
until the next dispatch call on the same thread.

### TDD Cycle

Red:

- Replace `tests/ipc_test.zig:128` with tests that:
  - send an `echo` payload larger than 4096 bytes and expect `rc == 0`;
  - send a 128 KB payload and expect exact JSON string length;
  - perform a second dispatch and verify the second result is complete;
  - preserve `UnknownCommand` and `BadArgs` behavior.
- Add a regression test that `dom.query` can return a fake JSON payload larger
  than 4 KB through the same C result path once the router exists.

Green:

- In `src/ipc.zig`, replace `dispatch_result_cstr: [4096]u8` with a threadlocal
  heap-backed sentinel allocation freed/replaced at the start of the next
  dispatch call.
- Keep `dispatch_err_cstr` static because error names are small.
- Keep `dispatch()` allocator-owned return values unchanged for Zig callers.
- If the 64 KB scratch allocator blocks parsing large inputs, switch the C ABI
  dispatch allocator to an arena backed by the heap with next-call reset.

Refactor:

- Extract result-lifetime logic into a small helper with tests focused on
  allocation, sentinel termination, and next-call replacement.

Success criteria:

- Old ceiling assertion fails before implementation and passes only after the
  dynamic result helper is used.
- No platform shim changes are required for existing `ping/add/echo/os.info`.

## Behavior M2: AutomationError and Router Grammar Are Stable

### Specification

Given a `dom.*` or `page.*` method and JSON params, when the router validates the
request, then it produces exactly one typed engine command or a stable error.

### TDD Cycle

Red:

- Add `tests/automation_error_test.zig` asserting the 12 error names, downstream
  codes, and retryability flags.
- Add `tests/automation_router_test.zig` with table tests for all Phase 1 command
  verbs, unknown methods, invalid params, omitted optional params, and strict
  selector defaults.
- Add a test proving `cookies.*`, `session.*`, `social.*`, `linkedin.*`, and
  `instagram.*` are not implemented in Phase 1.

Green:

- Implement `src/automation/error.zig`.
- Implement method parsing and param validation in `src/automation/router.zig`.
- Return `UnknownCommand` or `BadArgs` at the old IPC boundary, while preserving
  `AutomationError` inside the automation layer for Phase 2 mapping.

Refactor:

- Generate command metadata from a single table so docs, router tests, and
  downstream verb exposure cannot drift.

Success criteria:

- The verb table in this plan matches the router test table.
- Downstream error codes are exposed as helpers but no JSON-RPC server exists.

## Behavior M3: Injected Script Selector Engine Resolves Deterministically

### Specification

Given a fixture DOM, when `__zbAutomation.handle()` receives a selector command,
then it resolves Playwright-compatible selector strings and returns stable,
JSON-serializable element summaries without leaking handles to page code.

### TDD Cycle

Red:

- Add Playwright tests against `tests/fixtures/automation/selectors.html` for:
  - `role=button[name="Save"]`;
  - `testid=send-message-btn`;
  - `text=Follow`;
  - `css=[aria-label="Comment"]`;
  - `xpath=//button[@data-case="xpath"]`;
  - strict mode with zero, one, and multiple matches;
  - malformed selector prefixes.
- Assert returned elements include only `{ id, tag, text, bbox }` and no DOM
  handles or raw internal references.

Green:

- Create `src/automation_script/automation.js` with
  `globalThis.__zbAutomation.handle(jsonOrObject)`.
- Implement `query`, `getText`, and `getAttribute` first.
- Implement accessible-name matching for the Phase 1 fixture scope, then broaden
  only enough to satisfy PRD selector semantics.

Refactor:

- Keep selector parsing in JS, not Zig. Zig passes selectors opaquely.
- Extract selector-kind and selector-hash helpers for telemetry fields.

Success criteria:

- All selector tests pass in Chromium and WebKit Playwright projects where
  available.
- Page code cannot observe automation internals beyond the intentionally created
  isolated-world/IIFE handle in the test harness.

## Behavior M4: Actionability Checks Block Mutating Actions Until Ready

### Specification

Given a selector for a candidate element, when a mutating action is requested,
then the injected script checks attached, visible, stable, receives-events,
enabled, and editable requirements and returns the exact retryable failure until
the element becomes actionable.

### TDD Cycle

Red:

- Add fixture cases in `tests/fixtures/automation/actionability.html` for hidden,
  detached, disabled, readonly, moving, and obscured elements.
- Add Playwright tests that call `click`, `fill`, and `type` with `trial=true`,
  `force=true`, and default options.
- Assert `trial=true` creates no side effects and `force=true` bypasses checks.

Green:

- Implement `runActionabilityChecks(element, action, options)` in the injected
  script.
- Implement stable bounding-box comparison across two animation frames.
- Implement center-point hit testing with `document.elementFromPoint()`.
- Return `ScriptFailure` with `{ ok:false, error, retryable, data }`.

Refactor:

- Keep each check independently testable and map failures through a single
  JS-to-Zig error-name table.
- Ensure observers/timers used by waits are cleaned before each handler resolves.

Success criteria:

- Every PRD check has one passing and one failing fixture case.
- Failure names match `AutomationError` exactly.

## Behavior M5: DOM Actions and Wait Primitives Produce Observable Side Effects

### Specification

Given actionable elements in the fixture DOM, when the script receives DOM action
or wait commands, then it performs the same observable side effects a user-level
action would cause or times out with the right error.

### TDD Cycle

Red:

- Add Playwright tests for:
  - `click` dispatching pointer/mouse/click events in order;
  - `fill` focusing, clearing, setting value, and dispatching input/change;
  - `type` dispatching keydown/input/keyup per character;
  - `waitFor` states `attached`, `visible`, `hidden`, and `detached`;
  - timeout on a never-appearing selector.

Green:

- Implement JS event synthesis for `click`, `fill`, and `type`.
- Implement wait polling and temporary observers with cleanup on success,
  timeout, and cancellation.
- Return compact JSON results only.

Refactor:

- Share side-effect logging in fixtures through `window.__fixtureLog` so tests
  assert event order without inspecting implementation internals.

Success criteria:

- Fixture log proves event order and no side effects in trial mode.
- Wait tests assert cleanup by checking no outstanding fixture observers/timers.

## Behavior M6: PagePort and Page Commands Execute Through a Fake Port First

### Specification

Given a fake `AutomationPagePort`, when page commands are routed, then `navigate`,
`reload`, `url`, `title`, `evaluate`, and `screenshot` map to the correct port
calls and preserve large results.

### TDD Cycle

Red:

- Add `tests/automation_page_port_test.zig` with a fake port recording calls.
- Assert `page.evaluate` returns arbitrary JSON, including arrays/objects and a
  result larger than 4 KB.
- Assert `page.screenshot` returns base64 larger than 4 KB through the same
  result path.
- Assert navigation timeout/failure maps to `navigation_timeout` and
  `navigation_failed`.

Green:

- Implement `AutomationPagePort` and fake test port.
- Implement page-command routing in `src/automation/router.zig` and
  `src/automation/engine.zig`.
- For `page.evaluate`, wrap the expression so the injected script returns a
  JSON-serializable result through `__zbAutomation.handle()`.

Refactor:

- Keep platform-specific screenshot/eval mechanics behind PagePort. The engine
  must not import GTK, WebView2, or WKWebView types.

Success criteria:

- All page command behavior is proven without a real WebView before platform
  shims are touched.

## Behavior M7: Engine Retry Loop Polls Every 16 ms and Maps Timeouts Precisely

### Specification

Given a retryable script failure, when the command deadline has not expired, then
the engine waits exactly 16 ms before trying again. When the deadline expires,
then it returns the most specific automation error observed.

### TDD Cycle

Red:

- Add fake-clock tests where the fake port returns:
  - `element_not_found` twice, then success;
  - `element_obscured`, then `element_not_visible`, then timeout;
  - malformed script JSON;
  - non-retryable failure;
  - cancellation before the next poll.
- Assert retry count, sleep intervals, timeout behavior, and emitted telemetry
  status.

Green:

- Implement the retry loop in `src/automation/engine.zig` with injectable clock
  and sleeper.
- Default timeout is 30000 ms; poll interval is 16 ms.
- Timeout with no match maps to `element_not_found`; timeout after checks maps
  to the most specific actionability error or `action_timeout`.

Refactor:

- Separate policy decisions from JSON parsing so timeout/error mapping is table
  driven and easy to audit.

Success criteria:

- The tests fail if the poll interval changes from 16 ms.
- The engine does not busy-wait in fake or real modes.

## Behavior M8: Per-Page Command Queue Serializes Same-Page Work

### Specification

Given multiple commands for the same page, when they are enqueued concurrently,
then they execute strictly FIFO. Commands for different pages may progress
independently.

### TDD Cycle

Red:

- Add `tests/automation_queue_test.zig` with controlled pending commands.
- Assert same-page ordering, cross-page independence, queued cancellation, and
  in-flight cancellation during retry sleep.

Green:

- Implement `PageCommandQueue` with page-id keyed queues and command handles.
- Integrate queue execution into router/engine entry points.
- For the current synchronous IPC path, still run through the queue so Phase 2
  does not add a different command lifecycle later.

Refactor:

- Keep queue storage independent of transport. It should not mention JSON-RPC,
  sockets, or clients.

Success criteria:

- Queue tests prove ordering with deterministic fake commands.
- Engine telemetry includes `queue.wait_ms` even when wait is zero.

## Behavior M9: Page-Aware IPC Dispatch Integrates Engine With Platform Shims

### Specification

Given a page script calls `window.zbHost("dom.query", args)`, when the platform
handler receives the message, then it passes the originating `ZbWindow *` to the
Zig page-aware dispatcher and returns the automation result to the page.

### TDD Cycle

Red:

- Add C/Zig compile tests proving `zb_ipc_dispatch_for_page` is declared in
  `src/webkit_shim.h` and exported by Zig.
- Add GTK E2E fixture scenario `#auto=automation-query` that calls
  `window.zbHost("dom.query", {selector:"text=Ready"})` and waits for an
  `IPC\tdom.query\t...` protocol line.
- Add a negative E2E scenario proving `zb_ipc_dispatch` without page context
  rejects `dom.query` with `BadArgs`.

Green:

- Add `zb_ipc_dispatch_for_page` in `src/ipc.zig`.
- Update GTK, WebView2, and macOS message handlers to call the page-aware export.
- Add platform PagePort constructors that hold opaque `ZbWindow *` and call
  `zb_automation_eval_json` or `zb_automation_inject_script` in the shim.
- Implement only JS-synthetic DOM action execution in Phase 1.

Refactor:

- Keep all platform-specific async completion and native object lifetimes inside
  the shims. Zig owns deadlines, retries, queueing, and error mapping.

Success criteria:

- Existing IPC E2E tests still pass.
- Automation IPC E2E proves a real fixture page can call `dom.query` and receive
  a typed result.

## Behavior M10: Injected Script Is Installed and Evaluated in the Automation World

### Specification

Given a page loads in zigBrowser, when automation is enabled for that page, then
the automation script is available before command execution and command evals run
through the platform injection/eval seam.

### TDD Cycle

Red:

- Add platform compile checks for the new `zb_automation_inject_script` and
  `zb_automation_eval_json` declarations.
- Add GTK E2E test that page-world `Object.keys(window)` does not show a page
  global named `__zbAutomation` while automation commands still execute.
- Add WebView2/macOS compile or hardware-gated smoke tests using their existing
  document-start hooks.

Green:

- GTK: use `webkit_user_content_manager_add_script()` with a named world where
  available and `webkit_web_view_evaluate_javascript()` for command eval.
- WebView2: replace the marker-only document script with an IIFE-scoped injected
  script and `ExecuteScriptAsync()` command eval.
- macOS: use `WKUserScript` and named `WKContentWorld` where available, with
  `evaluateJavaScript:in:in:completionHandler:`.
- Ensure platform calls complete exactly once with result, typed platform error,
  or cancellation.

Refactor:

- Keep script source loaded from one build-time embedded file or generated Zig
  string, not copy-pasted into each shim.

Success criteria:

- G5 and G6 have fixture coverage: native-to-JS eval exists, and the script
  command handler is not a page-world global where the platform supports
  isolation.

## Behavior M11: TelemetrySink Emits Root Command Spans and Redacts Sensitive Data

### Specification

Given any automation command reaches the router, when it completes or fails, then
exactly one root `automation.command` span is recorded, relevant child spans share
its trace id, and no denied keys or raw sensitive values appear in the sink.

### TDD Cycle

Red:

- Add `tests/automation_telemetry_test.zig` asserting:
  - one root span per command;
  - required root attributes exist, including `trace_id`, `span_id`,
    `command_id`, `rpc.method`, `page.id`, `backend.name`, `duration_ms`,
    `timeout_ms`, `retry.count`, `result.status`, `automation.error`,
    `selector.kind`, `selector.hash`, `action.name`, `action.force`, and
    `action.trial`;
  - child spans for `automation.selector.resolve`,
    `automation.actionability.check`, and `automation.platform.eval`;
  - fill/type values such as `password=abc`, `token=xyz`, raw selectors, cookie
    values, and full URLs with query strings are absent.
- Add a redaction-denylist fixture that intentionally passes sensitive params
  through command args.

Green:

- Implement `TelemetrySink` and `InMemoryTelemetrySink`.
- Add redaction before sink export, not after storage.
- Hash selectors and ids; record lengths/classes for typed text; omit raw values.
- Make telemetry export failure non-fatal to command execution.

Refactor:

- Centralize telemetry attribute names so Phase 2 can reuse them without string
  drift.

Success criteria:

- Tests fail on any missing required root attr.
- Tests fail on denied key names or secret-like raw values anywhere in telemetry.

## Behavior M12: Deterministic Fixture Server Proves End-to-End Phase 1 Commands

### Specification

Given the automation fixture server is running, when zigBrowser opens fixture
pages and in-page test scenarios call `zbHost("dom.*"|"page.*")`, then stdout
protocol lines and fixture state prove the commands executed through the real
engine, not only fake ports.

### TDD Cycle

Red:

- Add `tests/e2e/automation_core_test.py` that starts
  `tests/e2e/automation_fixture_server.py`, launches zigBrowser with
  `--e2e-protocol`, and drives hash-based scenarios.
- Scenarios:
  - `dom.query` returns multiple element summaries larger than 4 KB;
  - `dom.click` waits for a button to become visible, then clicks;
  - `dom.fill` and `dom.type` update fixture inputs without telemetry leaks;
  - `dom.waitFor` resolves after dynamic attach/visible changes;
  - `page.url`, `page.title`, and `page.evaluate` return typed values;
  - `page.navigate` moves from `/nav-a` to `/nav-b`;
  - one intentionally failing selector maps to `element_not_found`.

Green:

- Implement the missing integration code until each scenario produces expected
  `IPC` or `IPCERR` protocol rows.
- Ensure the fixture server uses fixed ports only when explicitly requested;
  default to OS-assigned ports to avoid conflicts.

Refactor:

- Move repeated protocol assertions into helpers, following
  `tests/e2e/slice2_common.py`.

Success criteria:

- `python3 tests/e2e/automation_core_test.py --binary zig-out/bin/zigBrowser`
  passes on Linux/GTK when runtime dependencies are available, or exits 77 with
  a clear skip only for missing display/runtime prerequisites.

## Implementation Order

1. M0: add harness wiring and fixture skeletons.
2. M1: fix IPC result ownership before adding large automation outputs.
3. M2: add error taxonomy and router grammar.
4. M3-M5: build and test the injected script in Playwright fixtures.
5. M6-M8: build fake-port engine, retry loop, and queue.
6. M9-M10: add page-aware dispatch and platform eval/injection seams.
7. M11: add telemetry sink and redaction gates, then thread it through engine.
8. M12: add real-binary fixture E2E coverage for the complete Phase 1 path.

## Release Gate

Phase 1 is complete only when:

- `zig build test` passes.
- `npx playwright test e2e/automation_script.spec.ts --project=chromium` passes.
- `python3 tests/e2e/automation_core_test.py --binary zig-out/bin/zigBrowser`
  passes or skips only for documented host/runtime absence.
- Existing IPC/nav E2E tests still pass on the available host.
- Telemetry redaction scanner finds zero denied sensitive keys or raw secret
  patterns.
- The plan scope remains Phase 1 only: no Layer 3 server, SDK, social contract,
  pacing, anti-detection behavior simulation, cookies, or network interception
  files are implemented as part of this issue.

## Beads Traceability

Create or update a Beads issue for this Phase 1 implementation plan and include
this file path in the issue description:

`thoughts/searchable/shared/plans/2026-07-09-phase1-core-automation-engine-tdd-plan.md`

## System Map

This map covers only the Phase 1 bounded contexts owned by this plan: BC3 IPC
Bridge extension/result ownership, BC6 Automation Engine, BC7 Injected Script
Engine, and the BC11 telemetry-sink core needed for root `automation.command`
spans and the Phase 1 child spans. BC1, BC2, BC4, BC5, BC8, BC9, BC10, and BC12
are referenced only as external seams.

AS-IS evidence from the code:

- BC3 is a real current context in `src/ipc.zig`: `dispatch()` accepts only
  `ping`, `add`, `echo`, and `os.info`, while `zb_ipc_dispatch()` returns C
  strings from a threadlocal 4096 byte result buffer.
- BC4 remains external to this map. Its GTK, WebView2, and WKWebView message
  handlers call `zb_ipc_dispatch(cmd, args_json, ...)` without page-aware
  dispatch.
- BC6, BC7, and BC11 do not exist as source modules yet. Their target boundaries
  are therefore provisional and inferred from the PRD, context map, and this
  plan's planned file ownership.

New IDs introduced here follow the PRD sequence: `IN17`, `OUT19`, `EV7`, `C41`,
`S19`, `G13`, and `G14`. `C39` is reused from the PRD for the result-ownership
contract, applied here only to the Phase 1 IPC C ABI result-buffer fix.

### BC3 IPC Bridge

Status: AS-IS context exists. Target extension is additive and not provisional:
the current boundary is anchored by `src/ipc.zig` and `src/webkit_shim.h`.

#### Boundary Diagram

```mermaid
flowchart TB
    classDef iface   fill:#dae8fc,stroke:#6c8ebf;   %% interfaces  (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366;  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656;   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450;   %% violated/missing

    BC4["External BC4 Platform handlers"]
    BC6["External BC6 Automation Engine"]

    S3["S3 Platform->IPC\nzb_ipc_dispatch C ABI"]:::seam
    S19["S19 IPC->Automation Engine\npage-aware automation dispatch"]:::seam

    subgraph BC3_ASIS["BC3 IPC Bridge - AS-IS"]
        IN4["IN4 IPCCommand\n(cmd,args_json)"]:::iface
        C5["C5 CommandTable\nping/add/echo/os.info"]:::contract
        C6["C6 ResultCeiling\n4095 byte max before nul"]:::contract
        OUT5["OUT5 IPCResult\nJSON string | IpcError"]:::iface
        G1["G1 ResultCeiling gap\nlarge automation results fail"]:::gap
    end

    subgraph BC3_TARGET["BC3 IPC Bridge - Target Phase 1"]
        IN17["IN17 PageAwareIPCCommand\n(win,cmd,args_json)"]:::iface
        C41["C41 PageAwareDispatch\nlegacy fallback + automation route"]:::contract
        C39["C39 ResultOwnership\nheap-backed result lifetime"]:::contract
        OUT19["OUT19 PageAwareIPCResult\nJSON | IpcError | AutomationError"]:::iface
        G13["G13 PageAwareDispatch missing\nno exported page-aware ABI"]:::gap
    end

    BC4 --> S3
    S3 --> IN4
    S3 -. target extension .-> IN17
    IN4 --> C5 --> C6 --> OUT5
    C6 -.-> G1
    IN17 --> C41 --> C39 --> OUT19
    C41 -.-> G13
    OUT19 --> S19 --> BC6
```

#### EBNF Grammar

```ebnf
IN4_IPCCommand ::= "(" CmdName "," ArgsJSON ")"
CmdName ::= "ping" | "add" | "echo" | "os.info"
ArgsJSON ::= "null" | "{}" | JSONObject

OUT5_IPCResult ::= SuccessResult | IpcError
SuccessResult ::= JSONString | JSONNumber | JSONObject
IpcError ::= "UnknownCommand" | "BadArgs"

C5_CommandTable ::=
  "governs: IN4_IPCCommand -> OUT5_IPCResult;"
  "invariant: known commands are ping, add, echo, os.info;"
  "pre: cmd in known set has params matching command shape;"
  "post: ping returns \"pong\";"
  "post: add returns decimal i128 sum;"
  "post: echo returns JSON-quoted msg;"
  "post: os.info returns sysname/release/machine object;"
  "post: unknown command returns error.UnknownCommand;"
  "post: bad args return error.BadArgs;"

C6_ResultCeiling ::=
  "governs: dispatch_result_cstr threadlocal result buffer;"
  "invariant: AS-IS result.len <= 4095 bytes before nul terminator;"
  "pre: dispatch() produced result bytes;"
  "post: fits => copied into [4096]u8 C string and returned via out_result;"
  "post: exceeds => error.BadArgs through copyToCStr failure;"

S3_Platform_IPC ::=
  "seam: external BC4 platform handler -> BC3 IPC Bridge;"
  "interfaces: IN4_IPCCommand, OUT5_IPCResult, IN17_PageAwareIPCCommand, OUT19_PageAwareIPCResult;"
  "events: none;"
  "contracts: C5_CommandTable, C6_ResultCeiling, C39_ResultOwnership, C41_PageAwareDispatch;"

G1_ResultCeilingGap ::=
  "gap: C6_ResultCeiling violates C39_ResultOwnership for automation-scale results;"
  "evidence: zb_ipc_dispatch uses threadlocal dispatch_result_cstr[4096];"
  "impact: dom.query, page.evaluate, and page.screenshot results can exceed 4 KB;"

IN17_PageAwareIPCCommand ::= "(" ZbWindowPtr "," AutomationOrLegacyCmd "," ArgsJSON ")"
ZbWindowPtr ::= "ZbWindow*" | "null"
AutomationOrLegacyCmd ::= CmdName | DomMethod | PageMethod
DomMethod ::= "dom." ("query" | "click" | "fill" | "type" | "getText" | "getAttribute" | "waitFor")
PageMethod ::= "page." ("navigate" | "reload" | "url" | "title" | "evaluate" | "screenshot")

OUT19_PageAwareIPCResult ::= SuccessResult | IpcError | AutomationErrorName
AutomationErrorName ::= "element_not_found" | "element_not_visible" | "element_not_stable"
  | "element_obscured" | "element_disabled" | "element_not_editable"
  | "navigation_timeout" | "navigation_failed" | "action_timeout"
  | "platform_rate_limited" | "session_invalid" | "cancelled"

C41_PageAwareDispatch ::=
  "governs: IN17_PageAwareIPCCommand -> OUT19_PageAwareIPCResult;"
  "invariant: non-automation commands delegate to C5_CommandTable;"
  "invariant: dom.* and page.* commands require non-null page/window context;"
  "pre: cmd is valid UTF-8 and args_json is valid JSON or omitted object;"
  "post: legacy cmd routes to existing dispatch behavior;"
  "post: dom.* or page.* with live page routes to BC6 router through S19;"
  "post: dom.* or page.* without page context returns BadArgs at IPC boundary;"
  "post: unknown non-automation namespace returns UnknownCommand;"

C39_ResultOwnership ::=
  "governs: BC3 C ABI result pointer lifetime;"
  "invariant: successful result strings may exceed 4096 bytes;"
  "invariant: returned pointer remains valid until next dispatch call on same thread;"
  "pre: dispatch has produced JSON result bytes;"
  "post: result is nul-terminated and heap-backed or otherwise dynamically owned;"
  "post: next dispatch releases/replaces previous same-thread result storage;"
  "post: allocation failure maps to internal/BadArgs boundary error, never truncation;"

S19_IPC_AutomationEngine ::=
  "seam: BC3 page-aware IPC dispatch -> BC6 automation router/engine;"
  "interfaces: IN17_PageAwareIPCCommand, OUT19_PageAwareIPCResult, IN8_AutomationCommand, OUT11_CommandResult;"
  "events: EV3_CommandLifecycle may be emitted downstream by BC6;"
  "contracts: C41_PageAwareDispatch, C16_ErrorTaxonomy, C12_ActionRetry;"

G13_PageAwareDispatchMissing ::=
  "gap: C41_PageAwareDispatch target is absent;"
  "evidence: webkit_shim.h declares only zb_ipc_dispatch, not zb_ipc_dispatch_for_page;"
  "evidence: GTK/WebView2/WKWebView handlers call zb_ipc_dispatch without ZbWindow page context;"
  "impact: dom.* and page.* commands cannot reach BC6 with an originating page;"
```

#### Seam Table

| Seam | Interfaces | Events | Contracts |
|---|---|---|---|
| S3 Platform->IPC | IN4, OUT5, IN17, OUT19 | None | C5, C6, C39, C41 |
| S19 IPC->Automation Engine | IN17, OUT19, IN8, OUT11 | EV3 | C41, C16, C12 |

### BC6 Automation Engine

Status: Target Phase 1 only. Provisional because no `src/automation/*` modules
exist yet, and the final router/queue/engine split may shift during
implementation. The boundary is still scoped to Layer 2 command routing, FIFO
execution, retry policy, and typed automation errors.

#### Boundary Diagram

```mermaid
flowchart TB
    classDef iface   fill:#dae8fc,stroke:#6c8ebf;   %% interfaces  (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366;  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656;   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450;   %% violated/missing

    BC3["External BC3 IPC Bridge"]
    BC4["External BC4 PagePort adapter"]
    BC11["External BC11 TelemetrySink"]

    S7["S7 Router->Engine\nvalidated automation command"]:::seam
    S6["S6 Engine->PagePort\ninject/eval/navigate/reload/screenshot"]:::seam
    S15["S15 Components->Sink\nTelemetrySink vtable"]:::seam

    subgraph BC6_ASIS["BC6 Automation Engine - AS-IS"]
        G14["G14 NoEngineModules\nsrc/automation not present"]:::gap
        G8["G8 NoAutoErrors\nAutomationError enum absent"]:::gap
    end

    subgraph BC6_TARGET["BC6 Automation Engine - Target Phase 1"]
        IN8["IN8 AutomationCommand\nmethod,params,page_id,deadline"]:::iface
        C14["C14 PageFIFO\nsame-page serial queue"]:::contract
        C12["C12 ActionRetry\n16 ms poll loop"]:::contract
        C13["C13 Actionability\nrequired checks before mutation"]:::contract
        C15["C15 TrialMode\ntrial no side effects, force bypasses checks"]:::contract
        C16["C16 ErrorTaxonomy\n12 AutomationError variants"]:::contract
        EV3["EV3 CommandLifecycle\nenqueued/retry/success/failure/cancel"]:::iface
        OUT11["OUT11 CommandResult\nResult<T, AutomationError>"]:::iface
    end

    BC3 --> S7 --> IN8
    IN8 --> C14 --> C12 --> C13 --> C15 --> C16 --> OUT11
    C12 --> EV3 --> S15 --> BC11
    C13 --> S6 --> BC4
    IN8 -.-> G14
    C16 -.-> G8
```

#### EBNF Grammar

```ebnf
IN8_AutomationCommand ::= "{"
  Method "," Params "," PageId? "," Deadline
"}"
Method ::= DomMethod | PageMethod
Params ::= JSONObject
PageId ::= String | Integer
Deadline ::= PositiveInteger

OUT11_CommandResult ::= SuccessValue | AutomationErrorName
SuccessValue ::= JSONValue

EV3_CommandLifecycle ::= "enqueued" | "retrying" RetryCount
  | "succeeded" | "failed" AutomationErrorName | "cancelled"

C14_PageFIFO ::=
  "governs: PageCommandQueue for IN8_AutomationCommand;"
  "invariant: commands for same page execute strictly FIFO and one at a time;"
  "invariant: commands for different pages may execute concurrently;"
  "pre: page_id resolves to a live page/window;"
  "post: command completion releases queue head;"
  "post: cancellation removes queued work or interrupts retry sleep;"

C12_ActionRetry ::=
  "governs: AutomationEngine retry loop for IN8_AutomationCommand;"
  "invariant: retry poll interval is exactly 16 ms;"
  "pre: command has deadline derived from timeout_ms or default 30000 ms;"
  "post: retryable script failure sleeps 16 ms before next attempt;"
  "post: timeout with no match returns element_not_found;"
  "post: timeout after checks returns most specific actionability error or action_timeout;"

C13_Actionability ::=
  "governs: mutating DOM commands in IN8_AutomationCommand;"
  "invariant: attached, visible, stable, receives-events, enabled, and editable checks are enforced as required by action;"
  "pre: selector resolution produced an element candidate;"
  "post: mutation does not run until required checks pass unless force=true;"
  "post: failing check maps to exact C16 AutomationError variant;"

C15_TrialMode ::=
  "governs: action options on mutating DOM commands;"
  "invariant: trial=true runs selector and actionability checks without DOM side effects;"
  "invariant: force=true bypasses actionability checks;"
  "pre: command params match the same grammar as a real action;"
  "post: trial returns same validation errors as real action except execution-stage errors;"

C16_ErrorTaxonomy ::=
  "governs: AutomationError enum and downstream code mapping;"
  "invariant: 12 variants map 1:1 to -32001 through -32012;"
  "post: element_not_found -> -32001;"
  "post: element_not_visible -> -32002;"
  "post: element_not_stable -> -32003;"
  "post: element_obscured -> -32004;"
  "post: element_disabled -> -32005;"
  "post: element_not_editable -> -32006;"
  "post: navigation_timeout -> -32007;"
  "post: navigation_failed -> -32008;"
  "post: action_timeout -> -32009;"
  "post: platform_rate_limited -> -32010;"
  "post: session_invalid -> -32011;"
  "post: cancelled -> -32012;"

S7_Router_Engine ::=
  "seam: BC3 IPC dispatch or later external router -> BC6 Automation Engine;"
  "interfaces: IN8_AutomationCommand, OUT11_CommandResult;"
  "events: EV3_CommandLifecycle;"
  "contracts: C14_PageFIFO, C12_ActionRetry, C16_ErrorTaxonomy;"

S6_Engine_PagePort ::=
  "seam: BC6 Automation Engine -> external BC4 PagePort adapter;"
  "interfaces: IN8_AutomationCommand, IN9_ScriptCommand, OUT11_CommandResult, OUT12_ScriptResponse;"
  "events: EV3_CommandLifecycle;"
  "contracts: C12_ActionRetry, C13_Actionability, C39_ResultOwnership;"

G8_NoAutoErrors ::=
  "gap: C16_ErrorTaxonomy target is absent;"
  "evidence: current code has only IpcError{UnknownCommand,BadArgs};"
  "impact: automation failures cannot be reported with PRD error names/codes;"

G14_NoEngineModules ::=
  "gap: BC6 target modules are absent;"
  "evidence: no src/automation.zig or src/automation/* files exist;"
  "impact: IN8, C12, C14, C16, and OUT11 are target-state only;"
```

`S15_Components_Sink` is canonically defined in the BC11 grammar below. It is
shown in this BC6 diagram only to make `EV3` telemetry emission visible.

#### Seam Table

| Seam | Interfaces | Events | Contracts |
|---|---|---|---|
| S7 Router->Engine | IN8, OUT11 | EV3 | C14, C12, C16 |
| S6 Engine->PagePort | IN8, IN9, OUT11, OUT12 | EV3 | C12, C13, C39 |
| S15 Components->Sink | IN13, OUT16 | EV3, EV7 | C32, C33, C34, C35 |

### BC7 Injected Script Engine

Status: Target Phase 1 only. Provisional because no injected script file exists
yet, and the exact split of actionability checks between Zig retry policy and JS
DOM inspection may change. The boundary remains the single injected handler and
DOM-facing selector/action logic.

#### Boundary Diagram

```mermaid
flowchart LR
    classDef iface   fill:#dae8fc,stroke:#6c8ebf;   %% interfaces  (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366;  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656;   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450;   %% violated/missing

    BC4["External BC4 platform eval/inject"]
    DOM["External Page DOM"]

    S9["S9 Platform->Script\nisolated-world inject/eval"]:::seam
    S8["S8 Script->DOM\nselector resolution and event synthesis"]:::seam

    subgraph BC7_ASIS["BC7 Injected Script Engine - AS-IS"]
        G5["G5 NativeToJS missing\nno reusable automation eval"]:::gap
        G6["G6 IsolatedWorld missing\nno __zbAutomation handler"]:::gap
    end

    subgraph BC7_TARGET["BC7 Injected Script Engine - Target Phase 1"]
        IN9["IN9 ScriptCommand\nop,request_id,selector,value,options"]:::iface
        C20["C20 InjectionTiming\ndocument-start availability"]:::contract
        C18["C18 ScriptIsolation\nisolated world, no page globals"]:::contract
        C17["C17 SelectorGrammar\nrole/testid/text/css/xpath"]:::contract
        C19["C19 CleanupContract\nobservers/timers cleaned"]:::contract
        OUT12["OUT12 ScriptResponse\nok value | failure"]:::iface
    end

    BC4 --> S9 --> IN9
    C20 --> S9
    C18 --> S9
    S9 -.-> G5
    C18 -.-> G6
    IN9 --> C17 --> S8 --> DOM
    S8 --> C19 --> OUT12
```

#### EBNF Grammar

```ebnf
IN9_ScriptCommand ::= "{"
  "\"op\":" ScriptOp ","
  "\"request_id\":" String ","
  ("\"selector\":" Selector ",")?
  ("\"value\":" JSONValue ",")?
  ("\"options\":" ActionOptions)?
"}"
ScriptOp ::= "query" | "click" | "fill" | "type" | "getText"
  | "getAttribute" | "waitFor" | "evaluate" | "observeNavigation"
Selector ::= RoleSelector | TestIdSelector | TextSelector | CssSelector | XPathSelector
RoleSelector ::= "role=" RoleName RoleAttribute*
RoleAttribute ::= "[" ("name" | "checked" | "selected" | "expanded" | "level") "=" QuotedValue "]"
TestIdSelector ::= "testid=" IdentifierOrQuotedText
TextSelector ::= "text=" TextMatch
CssSelector ::= "css=" CssText
XPathSelector ::= "xpath=" XPathText
ActionOptions ::= "{" Timeout? Force? Trial? Strict? "}"

OUT12_ScriptResponse ::= ScriptResult | ScriptFailure
ScriptResult ::= "{" "\"ok\":true" ("," "\"value\":" JSONValue)? "}"
ScriptFailure ::= "{"
  "\"ok\":false,"
  "\"error\":" AutomationErrorName ","
  "\"retryable\":" Boolean ","
  "\"data\":" JSONObject
"}"

C20_InjectionTiming ::=
  "governs: automation script installation before command execution;"
  "invariant: script is injected at document-start where platform permits;"
  "invariant: script is present for main frame and supported subframes;"
  "pre: automation enabled before navigation or before first document-start hook;"
  "post: globalThis.__zbAutomation.handle is callable in the automation world before IN9 commands execute;"

C18_ScriptIsolation ::=
  "governs: globalThis.__zbAutomation visibility and script world;"
  "invariant: page-world Object.keys(window) cannot see automation globals where platform isolation permits;"
  "invariant: injected script does not patch shared DOM prototypes;"
  "pre: platform creates or emulates automation execution world;"
  "post: GTK uses named WebKit world where available;"
  "post: WebView2 uses IIFE scope;"
  "post: macOS uses WKUserScript and WKContentWorld where available;"

C17_SelectorGrammar ::=
  "governs: resolveSelector(selector, strict) in injected JS;"
  "invariant: selector strings use Playwright-compatible prefix grammar;"
  "pre: selector has a supported prefix;"
  "post: role= resolves ARIA role and accessible name/attributes;"
  "post: testid= resolves data-testid;"
  "post: text= resolves visible text;"
  "post: css= uses standard CSS selector;"
  "post: xpath= uses XPath expression;"
  "post: strict=true requires exactly one match;"

C19_CleanupContract ::=
  "governs: observers, timers, and temporary state created by IN9 operations;"
  "invariant: no persistent observer/timer remains after operation resolves;"
  "pre: operation may create MutationObserver, IntersectionObserver, PerformanceObserver, animation-frame checks, or polling timers;"
  "post: success, failure, timeout, and cancellation all disconnect/clear temporary resources before OUT12;"

S9_Platform_Script ::=
  "seam: external BC4 platform eval/inject adapter -> BC7 injected script;"
  "interfaces: IN9_ScriptCommand, OUT12_ScriptResponse;"
  "events: none;"
  "contracts: C20_InjectionTiming, C18_ScriptIsolation;"

S8_Script_DOM ::=
  "seam: BC7 injected script -> external page DOM;"
  "interfaces: IN9_ScriptCommand, OUT12_ScriptResponse;"
  "events: none;"
  "contracts: C17_SelectorGrammar, C19_CleanupContract, C13_Actionability;"

G5_NativeToJSMissing ::=
  "gap: S9 target is not available as a reusable automation command path;"
  "evidence: GTK has only screenshot title eval; WebView2/macOS document-start hooks inject marker strings only;"
  "impact: BC6 cannot send IN9 commands to BC7 through the native WebView;"

G6_IsolatedWorldMissing ::=
  "gap: C18_ScriptIsolation and C20_InjectionTiming targets are absent;"
  "evidence: no src/automation_script/automation.js and no __zbAutomation handler exist;"
  "impact: selector/action engine has no isolated runtime boundary;"
```

#### Seam Table

| Seam | Interfaces | Events | Contracts |
|---|---|---|---|
| S9 Platform->Script | IN9, OUT12 | None | C20, C18 |
| S8 Script->DOM | IN9, OUT12 | None | C17, C19, C13 |

### BC11 Observability Telemetry-Sink Core

Status: Target Phase 1 only. Provisional because no telemetry module exists yet,
and the sink may land as either a shared module facade or an injected vtable.
This map covers only the root command span, the Phase 1 child spans, redaction,
trace correlation, and non-fatal export behavior. BC9 anti-detection telemetry,
BC10 social telemetry, BC12 network/input telemetry, and BC8 external transport
telemetry remain external sibling scope.

#### Boundary Diagram

```mermaid
flowchart LR
    classDef iface   fill:#dae8fc,stroke:#6c8ebf;   %% interfaces  (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366;  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656;   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450;   %% violated/missing

    Producers["External producers\nBC3, BC6, BC7"]

    S15["S15 Components->Sink\nstartSpan/addEvent/endSpan"]:::seam

    subgraph BC11_ASIS["BC11 Observability - AS-IS"]
        G9["G9 NoTelemetry\nTelemetrySink absent"]:::gap
    end

    subgraph BC11_TARGET["BC11 Observability - Target Phase 1"]
        IN13["IN13 TelemetryInput\nStartSpan | AddEvent | EndSpan"]:::iface
        EV7["EV7 Phase1TelemetrySpan\nautomation.command + 3 child spans"]:::iface
        C32["C32 RootSpanAttrs\nrequired command dimensions"]:::contract
        C33["C33 RedactionPolicy\nno secrets/raw content"]:::contract
        C34["C34 TraceCorrelation\nchildren share trace_id"]:::contract
        C35["C35 ExportIsolation\nexport failure non-fatal"]:::contract
        OUT16["OUT16 TelemetryExport\nin-memory sink | future OTLP"]:::iface
    end

    Producers --> S15 --> IN13 --> C33 --> C32 --> EV7 --> C34 --> C35 --> OUT16
    C32 -.-> G9
```

#### EBNF Grammar

```ebnf
IN13_TelemetryInput ::= StartSpan | AddEvent | EndSpan
StartSpan ::= SpanName TelemetryAttrs
AddEvent ::= SpanRef EventName TelemetryAttrs
EndSpan ::= SpanRef TelemetryStatus TelemetryAttrs

EV7_Phase1TelemetrySpan ::= "{"
  "\"name\":" Phase1TelemetryName ","
  "\"trace_id\":" String ","
  "\"span_id\":" String ","
  "\"parent_span_id\":" (String | "null") ","
  "\"timestamp\":" IsoTimestamp ","
  "\"duration_ms\":" Number ","
  "\"attributes\":" TelemetryAttrs
"}"
Phase1TelemetryName ::= "automation.command"
  | "automation.selector.resolve"
  | "automation.actionability.check"
  | "automation.platform.eval"

OUT16_TelemetryExport ::= EV7_Phase1TelemetrySpan*

C32_RootSpanAttrs ::=
  "governs: EV7_Phase1TelemetrySpan where name is automation.command;"
  "invariant: exactly one root automation.command span per command that reaches BC6 router;"
  "pre: IN13_TelemetryInput startSpan called for command execution;"
  "post: required attrs include trace_id, span_id, command_id, rpc.method, page.id, backend.name, duration_ms, timeout_ms, retry.count, result.status, automation.error, selector.kind, selector.hash, action.name, action.force, action.trial;"
  "post: missing required attr fails telemetry fixture tests;"

C33_RedactionPolicy ::=
  "governs: IN13_TelemetryInput -> OUT16_TelemetryExport;"
  "invariant: redaction runs before storage/export;"
  "pre: attrs may contain command params or script diagnostic fields;"
  "post: cookie values, bearer tokens, passwords, local storage values, raw typed text, screenshots, DOM snapshots, and full query-string URLs are absent;"
  "post: selectors, IDs, session/profile identifiers, and URL paths are hashed or normalized;"

C34_TraceCorrelation ::=
  "governs: EV7_Phase1TelemetrySpan parent/child relationship;"
  "invariant: child spans share root trace_id;"
  "pre: root automation.command span exists for command;"
  "post: automation.selector.resolve, automation.actionability.check, and automation.platform.eval use parent_span_id of the command root or a descendant under the same trace_id;"

C35_ExportIsolation ::=
  "governs: TelemetrySink export behavior;"
  "invariant: telemetry export failure never fails automation command execution;"
  "pre: sink startSpan/addEvent/endSpan may fail or drop output;"
  "post: command result path remains governed by OUT11/OUT19, not by telemetry exporter status;"

S15_Components_Sink ::=
  "seam: BC3/BC6/BC7 Phase 1 components -> BC11 TelemetrySink;"
  "interfaces: IN13_TelemetryInput, OUT16_TelemetryExport;"
  "events: EV3_CommandLifecycle, EV7_Phase1TelemetrySpan;"
  "contracts: C32_RootSpanAttrs, C33_RedactionPolicy, C34_TraceCorrelation, C35_ExportIsolation;"

G9_NoTelemetry ::=
  "gap: S15_Components_Sink target is absent;"
  "evidence: no TelemetrySink, InMemoryTelemetrySink, span schema, or redaction layer exists in src/;"
  "impact: Phase 1 commands cannot emit required root or child spans;"
```

#### Seam Table

| Seam | Interfaces | Events | Contracts |
|---|---|---|---|
| S15 Components->Sink | IN13, OUT16 | EV3, EV7 | C32, C33, C34, C35 |

### Index

#### Context Roster

| Context | Status in code | Phase 1 ownership in this map | Provisional reason |
|---|---|---|---|
| BC3 IPC Bridge | AS-IS exists in `src/ipc.zig` | Result ownership fix, page-aware dispatch extension, BC3->BC6 seam | Not provisional; boundary exists today |
| BC6 Automation Engine | Target only | Router input, per-page queue, retry loop, actionability/error mapping | Provisional: no `src/automation/*` modules exist yet |
| BC7 Injected Script Engine | Target only | Single injected script handler, selector grammar, DOM actions/waits, cleanup | Provisional: no script exists and JS/Zig actionability split may shift |
| BC11 Observability | Target only | TelemetrySink core, root command span, Phase 1 child spans, redaction | Provisional: no telemetry module exists and sink shape may vary |
| BC1/BC2/BC4/BC5 | External host contexts | Referenced only by seams S3, S6, S9 | Not mapped here |
| BC8/BC9/BC10/BC12 | External sibling target contexts | Referenced only as future consumers/producers | Not mapped here |

#### Context-to-Context Diagram

```mermaid
flowchart LR
    classDef iface   fill:#dae8fc,stroke:#6c8ebf;   %% interfaces  (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366;  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656;   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450;   %% violated/missing

    Host["External host contexts\nBC1/BC2/BC4/BC5"]
    BC3["BC3 IPC Bridge"]
    BC6["BC6 Automation Engine"]
    BC7["BC7 Injected Script Engine"]
    BC11["BC11 Observability"]
    Future["External sibling contexts\nBC8/BC9/BC10/BC12"]

    Host -->|"S3: IN4/IN17 -> OUT5/OUT19"| BC3
    BC3 -->|"S19: IN17 -> IN8, OUT11 -> OUT19"| BC6
    BC6 -->|"S6: IN9 -> OUT12 via external PagePort"| Host
    Host -->|"S9: inject/eval IN9 -> OUT12"| BC7
    BC7 -->|"S8: DOM selector/action seam"| Host
    BC3 -.->|"S15: command/result telemetry"| BC11
    BC6 -.->|"S15: EV3 + root command telemetry"| BC11
    BC7 -.->|"S15: selector/actionability child telemetry"| BC11
    Future -. external .-> BC6
    Future -. external .-> BC11
```

#### Gap/Risk Register

| Gap | Marked on diagram | Boundary violated or missing | Phase 1 handling |
|---|---|---|---|
| G1 ResultCeiling gap | BC3 | C6 static 4096 byte result ceiling violates C39 target result ownership | M1 fixes dynamic result lifetime before automation commands ship |
| G13 PageAwareDispatch missing | BC3 | C41 and S19 target page-aware dispatch do not exist | M9 adds `zb_ipc_dispatch_for_page` and routes `dom.*`/`page.*` to BC6 |
| G14 NoEngineModules | BC6 | BC6 target modules absent | M0/M2/M6/M7/M8 create automation facade, router, engine, queue, fake port tests |
| G8 NoAutoErrors | BC6 | C16 `AutomationError` taxonomy absent | M2 adds 12-case enum and code mapping |
| G5 NativeToJSMissing | BC7 external seam | S9 has no reusable native-to-JS automation eval path | M10 adds platform eval/inject ABI through external BC4 seam |
| G6 IsolatedWorldMissing | BC7 | C18/C20 target script isolation and injection timing absent | M3/M10 add `automation.js` and platform document-start injection |
| G9 NoTelemetry | BC11 | S15/C32-C35 target telemetry sink absent | M11 adds `TelemetrySink`, in-memory sink, root span, child spans, and redaction scanner |

#### Acceptance Self-Check

| Criterion | Result | Notes |
|---|---|---|
| Diagram IDs and grammar entries are 1:1 | PASS | IDs introduced or reused in diagrams have grammar entries: IN4, IN8, IN9, IN13, IN17, OUT5, OUT11, OUT12, OUT16, OUT19, EV3, EV7, C5, C6, C12-C20, C32-C35, C39, C41, S3, S6-S9, S15, S19, G1, G5, G6, G8, G9, G13, G14. Orphan IDs: none. |
| Every contract names its target | PASS | Each `C#_*` grammar entry starts with a `governs:` target. |
| Every seam enumerates interfaces and contracts | PASS | Seam tables enumerate S3, S6, S7, S8, S9, S15, and S19 with interfaces/events/contracts. |
| Every context has all three parts | PASS | BC3, BC6, BC7, and BC11 each have a diagram, EBNF grammar block, and seam table. |
| Violated/missing boundaries are marked with `gap` class | PASS | G1, G5, G6, G8, G9, G13, and G14 are diagram nodes with `:::gap`. |
| Provisional boundaries are labeled with a reason | PASS | BC6, BC7, and BC11 state their provisional reasons; BC3 is explicitly non-provisional. |
