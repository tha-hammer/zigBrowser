---
date: 2026-07-09T17:00:00-05:00
author: SAI Algorithm
git_commit: f9af985
branch: master
repository: zigBrowser
topic: "TDD plan: Phase 5 — Platform SDKs & Social Contracts"
tags: [tdd, plan, sdk, python, nodejs, cli, linkedin, instagram, social, automation]
status: ready_for_implementation
source_prd: thoughts/searchable/shared/prd/2026-07-09-browser-automation-api.md
source_context_map: thoughts/searchable/shared/prd/2026-07-09-browser-automation-api-context-map.html
source_research: thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md
phase_dependencies: ["Phase 2 (JSON-RPC 2.0 UDS server)", "Phase 4 (pacing/anti-detection)"]
last_updated: 2026-07-09
last_updated_by: SAI Algorithm
last_updated_note: "Initial plan creation for Phase 5 SDKs and Social Contracts"
---

# Phase 5: Platform SDKs & Social Contracts — TDD Implementation Plan

## Overview

Build the external client libraries and social media automation contracts for the zigBrowser Automation API. Phase 5 sits at the top of the dependency chain — it consumes the JSON-RPC 2.0 wire protocol (Phase 2), dom.*/page.* primitives (Phase 1), and pacing/anti-detection layer (Phase 4) as given interfaces.

This plan covers six components, organized from foundation to application:
1. **Generic `social.*` base commands** (Zig server-side) — session checks, pacing control
2. **LinkedIn platform contract** (Zig server-side) — 7 compound actions decomposed into dom.*/page.* primitives
3. **Instagram platform contract** (Zig server-side) — 5 compound actions
4. **Python SDK** (primary client library) — UDS JSON-RPC client with async/sync API, error objects, event subscriptions
5. **Node.js SDK** (secondary client library) — Promise-based API over UDS JSON-RPC
6. **CLI tool** (Python-based) — command-line automation interface with `--trace <trace_id>` telemetry helper

## Current State Analysis

### Key Discoveries

- No SDK, CLI, or JSON-RPC client code exists in the codebase today
- No `sdk/`, `client/`, or `tools/` directories exist
- No `pyproject.toml` or SDK-related `package.json` exists
- Existing E2E tests use Python (pytest) with a custom stdout protocol (`tests/e2e/PROTOCOL.md`), not JSON-RPC
- `tests/fixtures/app/zbhost.js` shows the existing JS bridge pattern (request-id/promise plumbing) — useful as reference for SDK design
- `src/ipc.zig` dispatch pattern (`std.mem.eql` on cmd string, JSON args) is the model the automation router extends
- The PRD §3.5 defines normative EBNF grammars for all wire protocol shapes
- Context map BC10 defines the Social→Engine seam (S14) as compound→primitive decomposition
- Context map BC8 defines the Client→Server seam (S10) as UDS + token handshake

### Given Interfaces (from Phases 1-4)

These are treated as EXISTING and WORKING for this plan:

| Interface | Owner | Contract |
|---|---|---|
| `AutomationApiServer` (UDS JSON-RPC 2.0) | Phase 2 / BC8 | C21 JSONRPCFrame, C22 MethodDispatch, C23 SocketLifecycle |
| `AutomationRouter.dispatch(method, params)` | Phase 2 / BC6 | Routes `dom.*`, `page.*`, `cookies.*`, `session.*` methods |
| `AutomationPagePort` vtable | Phase 1 / BC6 | injectScript, evalScript, navigate, reload, screenshot |
| `AutomationError` enum (12 variants) | Phase 1 / BC6 | C16 ErrorTaxonomy: -32001..-32012 |
| `PageCommandQueue` (per-page FIFO) | Phase 1 / BC6 | C14 PageFIFO |
| `TelemetrySink` vtable | Phase 1 / BC11 | C32 RootSpanAttrs, C33 RedactionPolicy |
| Pacing layer (`PacingLayer`) | Phase 4 / BC9 | C25 TypingSim, C26 ClickSim, C27 RateLimiting |
| DOM-based rate-limit detection | Phase 4 / BC9 | C28 DOMDetection |
| WebSocket event push channel | Phase 2 / BC8 | EV4 EventNotification |

### Existing Test Patterns

**Zig unit tests** — standalone modules wired in `build.zig`:
```zig
const module = b.createModule(.{ .root_source_file = b.path("src/module.zig"), ... });
const tests_module = b.createModule(.{ .root_source_file = b.path("tests/module_test.zig"), ... });
tests_module.addImport("module", module);
```

**Python E2E tests** — pytest under `tests/e2e/`, launching the compiled binary as a subprocess. Example: `tests/e2e/ipc_roundtrip_test.py`.

## Desired End State

### Observable Behaviors

- External Python scripts can connect to zigBrowser's UDS socket and execute automation commands
- `linkedin.connect({profileUrl, note?})` navigates to a profile, clicks Connect, optionally adds a note, and confirms — returning `{ok: true}` or a step-level error
- `instagram.follow({profileUrl})` navigates to a profile and clicks Follow
- `social.login_check()` reports login state for the active platform
- `social.rate_status()` reports remaining daily actions and pacing state
- SDK error objects expose `trace_id`, `command_id`, `automation.error`, and redacted diagnostic fields for debugging
- CLI tool sends any automation command and formats the result; `--trace <trace_id>` queries local telemetry
- Node.js SDK provides equivalent functionality with Promise-based API

### Project Structure

```
sdk/
├── python/
│   ├── pyproject.toml
│   ├── src/
│   │   └── zigbrowser/
│   │       ├── __init__.py
│   │       ├── client.py          # UDS JSON-RPC client
│   │       ├── errors.py          # AutomationError → Python exceptions
│   │       ├── events.py          # WebSocket event subscription
│   │       └── types.py           # Response types, config
│   └── tests/
│       ├── conftest.py            # Mock UDS server fixture
│       ├── test_client.py
│       ├── test_errors.py
│       ├── test_events.py
│       └── test_social.py
├── node/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts
│   │   ├── client.ts
│   │   ├── errors.ts
│   │   └── events.ts
│   └── tests/
│       ├── client.test.ts
│       ├── errors.test.ts
│       └── events.test.ts
└── cli/
    ├── pyproject.toml
    └── src/
        └── zigbrowser_cli/
            ├── __init__.py
            ├── main.py
            └── trace.py

src/
├── social.zig                     # social.* base command handlers
├── linkedin.zig                   # linkedin.* compound action sequences
└── instagram.zig                  # instagram.* compound action sequences

tests/
├── social_test.zig
├── linkedin_test.zig
└── instagram_test.zig
```

## What We're NOT Doing

- Phase 1-4 internals (AutomationEngine, injected script, UDS server, pacing layer)
- TikTok/Facebook platform contracts (PRD §14, deferred)
- Multi-tab orchestration (PRD §14.2, open question)
- Proxy/IP rotation integration (PRD §14.3, open question)
- Headless mode (PRD §14.5, open question)
- OTLP telemetry export (Phase 2 scope — we consume trace_id, not produce export)
- Selector engine or actionability checks (Phase 1 scope)
- Cookie encryption at rest (PRD §14.1, open question)
- Network-level 429 detection (ADR-3, deferred)

## Testing Strategy

- **Framework (Zig)**: Zig built-in test runner via `zig build test`
- **Framework (Python)**: pytest with pytest-asyncio for async tests
- **Framework (Node)**: vitest (lightweight, ESM-native)
- **Mocking**: Mock UDS server fixture for SDK tests; mock AutomationPagePort for Zig social contract tests
- **Test Types**:
  - **Unit (Zig)**: Social contract decomposition into primitive sequences
  - **Unit (Python/Node)**: JSON-RPC serialization, error mapping, event parsing
  - **Integration**: SDK → real zigBrowser with `--automation-api` against test fixture server

---

## Component 1: Generic `social.*` Base Commands

Server-side Zig handlers for `social.login_check`, `social.rate_status`, `social.pause`, `social.set_pacing`. These form the foundation that platform-specific contracts (LinkedIn, Instagram) build on.

### Behavior 1.1: `social.login_check` Returns Login State

#### Test Specification
**Given**: A page loaded on a social media platform (e.g., `https://www.linkedin.com/feed/`)
**When**: `social.login_check` is dispatched
**Then**: Returns `{loggedIn: bool, platform: string, username?: string}` — platform detected from page URL host, login state detected via injected script evaluating platform-specific DOM signals

**Edge Cases**:
- Page not on a recognized platform → `{loggedIn: false, platform: "unknown"}`
- Page is on LinkedIn login page → `{loggedIn: false, platform: "linkedin"}`
- Page is on LinkedIn feed (logged in) → `{loggedIn: true, platform: "linkedin", username: "..."}`

**Files touched**: `src/social.zig` (new), `tests/social_test.zig` (new)

#### TDD Cycle

##### 🔴 Red: Write Failing Test
**File**: `tests/social_test.zig`
```zig
const social = @import("social");

test "login_check returns unknown platform for unrecognized host" {
    var mock_port = MockPagePort.init();
    mock_port.setPageUrl("https://example.com/page");
    mock_port.setEvalResult(.{ .ok = true, .value = .{ .loggedIn = false } });

    const result = try social.loginCheck(&mock_port, null);
    try std.testing.expectEqualStrings("unknown", result.platform);
    try std.testing.expect(!result.logged_in);
    try std.testing.expect(result.username == null);
}

test "login_check detects linkedin from host" {
    var mock_port = MockPagePort.init();
    mock_port.setPageUrl("https://www.linkedin.com/feed/");
    mock_port.setEvalResult(.{ .ok = true, .value = .{ .loggedIn = true, .username = "john-doe" } });

    const result = try social.loginCheck(&mock_port, null);
    try std.testing.expectEqualStrings("linkedin", result.platform);
    try std.testing.expect(result.logged_in);
    try std.testing.expectEqualStrings("john-doe", result.username.?);
}
```

##### 🟢 Green: Minimal Implementation
**File**: `src/social.zig`
```zig
pub const LoginCheckResult = struct {
    logged_in: bool,
    platform: []const u8,
    username: ?[]const u8,
};

pub fn loginCheck(port: *AutomationPagePort, page_id: ?PageId) !LoginCheckResult {
    const url = try port.getPageUrl(page_id);
    const platform = detectPlatform(url);
    const script_result = try port.evalScript(page_id, login_check_js, "zbAutomation", port.allocator);
    return .{
        .logged_in = script_result.loggedIn,
        .platform = platform,
        .username = script_result.username,
    };
}

fn detectPlatform(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "linkedin.com") != null) return "linkedin";
    if (std.mem.indexOf(u8, url, "instagram.com") != null) return "instagram";
    return "unknown";
}
```

##### 🔵 Refactor
- [ ] No duplication
- [ ] Reveals intent: `detectPlatform` clearly named
- [ ] Complexity: single branch per platform, no unnecessary nesting
- [ ] No shallow wrappers
- [ ] Fits existing `src/ipc.zig` patterns for command dispatch

#### Success Criteria
**Automated:**
- [ ] Test fails for right reason (Red): `zig build test -- social_test`
- [ ] Test passes (Green)
- [ ] All tests pass after refactor

---

### Behavior 1.2: `social.rate_status` Returns Pacing State

#### Test Specification
**Given**: Pacing layer configured with `daily_cap=100`, `remaining=73`, `reset_at` midnight
**When**: `social.rate_status` is dispatched
**Then**: Returns `{remaining_actions: 73, reset_at: "2026-07-10T00:00:00", daily_cap: 100}`

**Edge Cases**:
- No pacing configured → returns defaults (cap=100, remaining=100)
- Cap reached → `remaining_actions: 0`

**Files touched**: `src/social.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "rate_status returns pacing state from pacing layer" {
    var mock_pacing = MockPacingLayer.init(.{ .daily_cap = 100, .remaining = 73 });
    const result = try social.rateStatus(&mock_pacing);
    try std.testing.expectEqual(@as(i32, 73), result.remaining_actions);
    try std.testing.expectEqual(@as(i32, 100), result.daily_cap);
}
```

##### 🟢 Green
```zig
pub const RateStatusResult = struct {
    remaining_actions: i32,
    reset_at: []const u8,
    daily_cap: i32,
};

pub fn rateStatus(pacing: *PacingLayer) !RateStatusResult {
    const state = pacing.getState();
    return .{
        .remaining_actions = state.remaining,
        .reset_at = state.reset_at,
        .daily_cap = state.daily_cap,
    };
}
```

##### 🔵 Refactor
- [ ] Thin delegation to pacing layer — correct, no added complexity
- [ ] Matches the passthrough pattern for querying subsystem state

#### Success Criteria
**Automated:**
- [ ] Red/Green/Refactor cycle passes
- [ ] Returns serializable JSON matching PRD §9.3 response shape

---

### Behavior 1.3: `social.pause` Blocks Command Queue

#### Test Specification
**Given**: An active page command queue
**When**: `social.pause({duration_ms: 5000})` is dispatched
**Then**: Queue processing halts for 5000ms, then resumes. Returns `{ok: true}` after the pause completes.

**Edge Cases**:
- duration_ms = 0 → immediate return, no pause
- Cancellation during pause → returns `cancelled` error

**Files touched**: `src/social.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "pause blocks queue for specified duration" {
    var mock_queue = MockPageCommandQueue.init();
    const result = try social.pause(&mock_queue, .{ .duration_ms = 5000 });
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u32, 5000), mock_queue.last_pause_ms);
}
```

##### 🟢 Green
```zig
pub fn pause(queue: *PageCommandQueue, params: PauseParams) !OkResult {
    try queue.pauseFor(params.duration_ms);
    return .{ .ok = true };
}
```

##### 🔵 Refactor
- [ ] Single delegation — correct minimal implementation

---

### Behavior 1.4: `social.set_pacing` Configures Pacing Parameters

#### Test Specification
**Given**: Default pacing configuration
**When**: `social.set_pacing({min_delay_ms: 2000, max_delay_ms: 6000, daily_cap: 50})` is dispatched
**Then**: Pacing layer updated with new parameters. Returns `{ok: true}`.

**Edge Cases**:
- min_delay_ms > max_delay_ms → return `-32602` (invalid params)
- daily_cap = 0 → valid, effectively disables automation
- Partial params → only update provided fields, keep defaults for others

**Files touched**: `src/social.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "set_pacing updates pacing configuration" {
    var mock_pacing = MockPacingLayer.init(.{});
    const result = try social.setPacing(&mock_pacing, .{
        .min_delay_ms = 2000,
        .max_delay_ms = 6000,
        .daily_cap = 50,
    });
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u32, 2000), mock_pacing.config.min_delay_ms);
    try std.testing.expectEqual(@as(u32, 6000), mock_pacing.config.max_delay_ms);
    try std.testing.expectEqual(@as(u32, 50), mock_pacing.config.daily_cap);
}

test "set_pacing rejects min > max" {
    var mock_pacing = MockPacingLayer.init(.{});
    const result = social.setPacing(&mock_pacing, .{
        .min_delay_ms = 9000,
        .max_delay_ms = 3000,
        .daily_cap = 100,
    });
    try std.testing.expectError(error.InvalidParams, result);
}
```

##### 🟢 Green
```zig
pub fn setPacing(pacing: *PacingLayer, params: SetPacingParams) !OkResult {
    if (params.min_delay_ms > params.max_delay_ms) return error.InvalidParams;
    pacing.configure(params);
    return .{ .ok = true };
}
```

##### 🔵 Refactor
- [ ] Validation at boundary — correct placement
- [ ] Single delegation after validation

### Behavior 1.5: Router Integration for `social.*` Methods

#### Test Specification
**Given**: AutomationRouter with social commands registered
**When**: JSON-RPC method `"social.login_check"` arrives
**Then**: Routes to `social.loginCheck` handler. Unknown `social.foo` → `-32601`.

**Files touched**: `src/social.zig` (registration function)

#### TDD Cycle

##### 🔴 Red
```zig
test "router dispatches social.login_check" {
    var router = AutomationRouter.init(test_allocator);
    social.register(&router);
    const result = try router.dispatch("social.login_check", "{}", .{ .id = 1 });
    try std.testing.expect(result.isSuccess());
}

test "router rejects unknown social method" {
    var router = AutomationRouter.init(test_allocator);
    social.register(&router);
    const result = router.dispatch("social.unknown_method", "{}", .{ .id = 2 });
    try std.testing.expectError(error.MethodNotFound, result);
}
```

##### 🟢 Green
```zig
pub fn register(router: *AutomationRouter) void {
    router.addMethod("social.login_check", loginCheckHandler);
    router.addMethod("social.rate_status", rateStatusHandler);
    router.addMethod("social.pause", pauseHandler);
    router.addMethod("social.set_pacing", setPacingHandler);
}
```

##### 🔵 Refactor
- [ ] Registration pattern matches existing `src/ipc.zig` dispatch table approach

#### Success Criteria
**Automated:**
- [ ] All 4 social commands dispatch correctly
- [ ] Unknown social methods return `-32601`
- [ ] Invalid params return `-32602`

---

## Component 2: LinkedIn Platform Contract

Server-side compound action sequences. Each `linkedin.*` method decomposes into a sequence of `dom.*`/`page.*` primitive calls via the AutomationEngine. Selectors use ARIA roles and accessible names for stability against DOM obfuscation (PRD §4.2 priority: `role=` > `testid=` > `text=` > `css=`).

### Behavior 2.1: `linkedin.visit` Navigates to Profile

#### Test Specification
**Given**: Browser on any page, user logged in to LinkedIn
**When**: `linkedin.visit({profileUrl: "https://www.linkedin.com/in/john-doe/"})` is dispatched
**Then**: Executes `page.navigate({url: profileUrl, waitUntil: "networkidle"})`, emits `automation.social.action` telemetry event with `social.platform=linkedin, social.action=visit`

**Edge Cases**:
- Not logged in → `session_invalid` (-32011) error before navigation
- Invalid URL (not linkedin.com) → `-32602` invalid params
- Navigation timeout → `navigation_timeout` (-32007)

**Files touched**: `src/linkedin.zig` (new), `tests/linkedin_test.zig` (new)

#### TDD Cycle

##### 🔴 Red
**File**: `tests/linkedin_test.zig`
```zig
const linkedin = @import("linkedin");

test "visit navigates to profile URL" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });

    const result = try linkedin.visit(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/john-doe/",
    });

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("page.navigate", mock_engine.lastCommand().method);
    try std.testing.expectEqualStrings(
        "https://www.linkedin.com/in/john-doe/",
        mock_engine.lastCommand().params.url,
    );
}

test "visit fails if not logged in" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = false, .platform = "linkedin" });

    const result = linkedin.visit(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/john-doe/",
    });
    try std.testing.expectError(error.SessionInvalid, result);
}

test "visit rejects non-linkedin URL" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });

    const result = linkedin.visit(&mock_engine, .{
        .profile_url = "https://www.instagram.com/john/",
    });
    try std.testing.expectError(error.InvalidParams, result);
}
```

##### 🟢 Green
**File**: `src/linkedin.zig`
```zig
pub fn visit(engine: *AutomationEngine, params: VisitParams) !SocialResult {
    if (!std.mem.startsWith(u8, params.profile_url, "https://www.linkedin.com/"))
        return error.InvalidParams;
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", .{
        .url = params.profile_url,
        .waitUntil = "networkidle",
    });
    return .{ .ok = true };
}

fn requireLinkedInLogin(engine: *AutomationEngine) !void {
    const login = try engine.dispatch("social.login_check", .{});
    if (!login.logged_in) return error.SessionInvalid;
}
```

##### 🔵 Refactor
- [ ] `requireLinkedInLogin` extracted — reusable across all 7 LinkedIn actions
- [ ] URL validation at boundary
- [ ] Fits compound→primitive decomposition pattern from BC10

---

### Behavior 2.2: `linkedin.connect` Sends Connection Request

#### Test Specification
**Given**: Browser on LinkedIn, user logged in
**When**: `linkedin.connect({profileUrl: "https://www.linkedin.com/in/jane/", note: "Hi Jane!"})` is dispatched
**Then**: Executes sequence:
  1. `page.navigate` to profileUrl
  2. `dom.click` on Connect button (`role=button[name="Connect"]`)
  3. If note provided: `dom.click` on "Add a note" button, `dom.fill` note text, `dom.click` Send
  4. If no note: `dom.click` "Send without a note" or "Send"

**Edge Cases**:
- Note exceeds LinkedIn's 300-char limit → truncate and warn in telemetry
- Connect button not found (already connected, pending, etc.) → step-level error with `step: "click_connect"`
- Modal dialog appears (weekly limit) → `platform_rate_limited` (-32010)

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "connect without note sends connection request" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });
    mock_engine.setDomResult("dom.click", .{ .ok = true });

    const result = try linkedin.connect(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
        .note = null,
    });

    try std.testing.expect(result.ok);
    const commands = mock_engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", commands[0].method);
    try std.testing.expectEqualStrings("dom.click", commands[1].method);
    // Connect button selector
    try std.testing.expect(
        std.mem.indexOf(u8, commands[1].params_json, "Connect") != null,
    );
}

test "connect with note fills note field" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });
    mock_engine.setDomResult("dom.click", .{ .ok = true });
    mock_engine.setDomResult("dom.fill", .{ .ok = true });

    const result = try linkedin.connect(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
        .note = "Hi Jane!",
    });

    try std.testing.expect(result.ok);
    const commands = mock_engine.commandLog();
    // Should include: navigate, click Connect, click "Add a note", fill, click Send
    try std.testing.expect(commands.len >= 5);
}
```

##### 🟢 Green
```zig
pub fn connect(engine: *AutomationEngine, params: ConnectParams) !SocialResult {
    try validateLinkedInUrl(params.profile_url);
    try requireLinkedInLogin(engine);

    try engine.dispatch("page.navigate", .{
        .url = params.profile_url,
        .waitUntil = "networkidle",
    });

    try engine.dispatch("dom.click", .{
        .selector = "role=button[name=\"Connect\"]",
        .options = .{ .timeout_ms = 10000 },
    });

    if (params.note) |note| {
        try engine.dispatch("dom.click", .{
            .selector = "role=button[name=\"Add a note\"]",
        });
        const truncated = if (note.len > 300) note[0..300] else note;
        try engine.dispatch("dom.fill", .{
            .selector = "role=textbox[name=\"Add a note\"]",
            .value = truncated,
        });
        try engine.dispatch("dom.click", .{
            .selector = "role=button[name=\"Send\"]",
        });
    } else {
        try engine.dispatch("dom.click", .{
            .selector = "role=button[name=\"Send without a note\"]",
        });
    }

    return .{ .ok = true };
}
```

##### 🔵 Refactor
- [ ] `validateLinkedInUrl` extracted from `visit` — shared validation
- [ ] Note truncation at 300 chars — boundary enforcement
- [ ] Selector strings use ARIA roles per PRD §4.2 priority

---

### Behavior 2.3: `linkedin.message` Sends a Message

#### Test Specification
**Given**: User logged in to LinkedIn
**When**: `linkedin.message({conversationUrl: "...", text: "Hello!"})` is dispatched
**Then**: Navigates to conversation, focuses message input, types text with behavioral simulation, clicks Send

**Edge Cases**:
- profileUrl variant (no existing conversation) → navigate to profile, click Message button first
- Message input not found → step error at `step: "focus_input"`

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "message sends to conversation URL" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });
    mock_engine.setDomResult("dom.click", .{ .ok = true });
    mock_engine.setDomResult("dom.type", .{ .ok = true });

    const result = try linkedin.message(&mock_engine, .{
        .conversation_url = "https://www.linkedin.com/messaging/thread/abc123/",
        .profile_url = null,
        .text = "Hello!",
    });

    try std.testing.expect(result.ok);
    const commands = mock_engine.commandLog();
    try std.testing.expectEqualStrings("page.navigate", commands[0].method);
    // dom.type used (not dom.fill) for behavioral simulation
    try std.testing.expect(hasCommand(commands, "dom.type"));
}
```

##### 🟢 Green
```zig
pub fn message(engine: *AutomationEngine, params: MessageParams) !SocialResult {
    try requireLinkedInLogin(engine);

    if (params.conversation_url) |url| {
        try engine.dispatch("page.navigate", .{ .url = url, .waitUntil = "networkidle" });
    } else if (params.profile_url) |url| {
        try validateLinkedInUrl(url);
        try engine.dispatch("page.navigate", .{ .url = url, .waitUntil = "networkidle" });
        try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Message\"]" });
    } else return error.InvalidParams;

    try engine.dispatch("dom.click", .{
        .selector = "role=textbox[name=\"Write a message…\"]",
    });
    try engine.dispatch("dom.type", .{
        .selector = "role=textbox[name=\"Write a message…\"]",
        .text = params.text,
    });
    try engine.dispatch("dom.click", .{
        .selector = "role=button[name=\"Send\"]",
    });

    return .{ .ok = true };
}
```

##### 🔵 Refactor
- [ ] `dom.type` used instead of `dom.fill` — behavioral simulation through pacing layer
- [ ] conversationUrl vs profileUrl branching is clean

---

### Behavior 2.4: `linkedin.like` Likes a Post

#### Test Specification
**Given**: User logged in, post URL provided
**When**: `linkedin.like({postUrl})` dispatched
**Then**: Navigate to post, click Like button

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "like clicks the Like button on a post" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });

    const result = try linkedin.like(&mock_engine, .{
        .post_url = "https://www.linkedin.com/feed/update/urn:li:activity:123/",
    });

    try std.testing.expect(result.ok);
    try std.testing.expect(hasCommandWithSelector(
        mock_engine.commandLog(),
        "dom.click",
        "Like",
    ));
}
```

##### 🟢 Green
```zig
pub fn like(engine: *AutomationEngine, params: LikeParams) !SocialResult {
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.post_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Like\"]" });
    return .{ .ok = true };
}
```

---

### Behavior 2.5: `linkedin.comment` Comments on a Post

#### Test Specification
**Given**: User logged in, post URL and comment text provided
**When**: `linkedin.comment({postUrl, text})` dispatched
**Then**: Navigate to post, click Comment button to expand, type text, submit

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "comment types and submits comment on post" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });

    const result = try linkedin.comment(&mock_engine, .{
        .post_url = "https://www.linkedin.com/feed/update/urn:li:activity:123/",
        .text = "Great post!",
    });

    try std.testing.expect(result.ok);
    const cmds = mock_engine.commandLog();
    try std.testing.expect(hasCommand(cmds, "dom.type"));
}
```

##### 🟢 Green
```zig
pub fn comment(engine: *AutomationEngine, params: CommentParams) !SocialResult {
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.post_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Comment\"]" });
    try engine.dispatch("dom.type", .{
        .selector = "role=textbox[name=\"Add a comment…\"]",
        .text = params.text,
    });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Post\"]" });
    return .{ .ok = true };
}
```

---

### Behavior 2.6: `linkedin.search` Executes Search

#### Test Specification
**Given**: User logged in
**When**: `linkedin.search({query: "software engineer", filters: {location: "San Francisco"}})` dispatched
**Then**: Navigate to LinkedIn search, fill query, apply filters, extract results as structured data

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "search navigates to search URL with query" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });
    mock_engine.setEvalResult(.{ .results = &[_]SearchResult{} });

    const result = try linkedin.search(&mock_engine, .{
        .query = "software engineer",
        .filters = null,
    });

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("page.navigate", mock_engine.commandLog()[0].method);
}
```

##### 🟢 Green
```zig
pub fn search(engine: *AutomationEngine, params: SearchParams) !SearchResult {
    try requireLinkedInLogin(engine);
    const search_url = try std.fmt.allocPrint(engine.allocator,
        "https://www.linkedin.com/search/results/all/?keywords={s}",
        .{params.query},
    );
    try engine.dispatch("page.navigate", .{ .url = search_url, .waitUntil = "networkidle" });
    const results = try engine.dispatch("page.evaluate", .{
        .expression = linkedin_extract_search_results_js,
    });
    return results;
}
```

---

### Behavior 2.7: `linkedin.extract` Extracts Profile Data

#### Test Specification
**Given**: User logged in, profile URL provided
**When**: `linkedin.extract({profileUrl})` dispatched
**Then**: Navigate to profile, extract structured data: name, headline, company, location, about, experience

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "extract returns structured profile data" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });
    mock_engine.setEvalResult(.{
        .name = "Jane Doe",
        .headline = "Software Engineer",
        .company = "Acme Corp",
    });

    const result = try linkedin.extract(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/jane-doe/",
    });

    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("Jane Doe", result.data.name);
}
```

##### 🟢 Green
```zig
pub fn extract(engine: *AutomationEngine, params: ExtractParams) !ExtractResult {
    try validateLinkedInUrl(params.profile_url);
    try requireLinkedInLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.profile_url, .waitUntil = "networkidle" });
    const data = try engine.dispatch("page.evaluate", .{
        .expression = linkedin_extract_profile_js,
    });
    return .{ .ok = true, .data = data };
}
```

---

### Behavior 2.8: LinkedIn Router Registration

#### Test Specification
**Given**: AutomationRouter
**When**: LinkedIn commands are registered
**Then**: All 7 methods (`linkedin.connect`, `.message`, `.like`, `.comment`, `.visit`, `.search`, `.extract`) route correctly

**Files touched**: `src/linkedin.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "all 7 linkedin methods register and dispatch" {
    var router = AutomationRouter.init(test_allocator);
    linkedin.register(&router);

    const methods = [_][]const u8{
        "linkedin.connect", "linkedin.message", "linkedin.like",
        "linkedin.comment", "linkedin.visit", "linkedin.search",
        "linkedin.extract",
    };
    for (methods) |method| {
        try std.testing.expect(router.hasMethod(method));
    }
}
```

##### 🟢 Green
```zig
pub fn register(router: *AutomationRouter) void {
    router.addMethod("linkedin.connect", connectHandler);
    router.addMethod("linkedin.message", messageHandler);
    router.addMethod("linkedin.like", likeHandler);
    router.addMethod("linkedin.comment", commentHandler);
    router.addMethod("linkedin.visit", visitHandler);
    router.addMethod("linkedin.search", searchHandler);
    router.addMethod("linkedin.extract", extractHandler);
}
```

---

### Behavior 2.9: LinkedIn Telemetry — `automation.social.action` Events

#### Test Specification
**Given**: TelemetrySink configured (in-memory test sink)
**When**: Any `linkedin.*` command executes
**Then**: Emits `automation.social.action` child event with: `social.platform=linkedin`, `social.action=<verb>`, `social.step=<current_step>`, `profile.id_hash` (hashed, never raw URL)

**Files touched**: `src/linkedin.zig`, `tests/linkedin_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "linkedin.visit emits social.action telemetry" {
    var mock_engine = MockAutomationEngine.init();
    var mock_sink = MockTelemetrySink.init();
    mock_engine.setTelemetrySink(&mock_sink);
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "linkedin" });

    _ = try linkedin.visit(&mock_engine, .{
        .profile_url = "https://www.linkedin.com/in/jane/",
    });

    const events = mock_sink.getEvents("automation.social.action");
    try std.testing.expect(events.len > 0);
    try std.testing.expectEqualStrings("linkedin", events[0].attrs.get("social.platform").?);
    try std.testing.expectEqualStrings("visit", events[0].attrs.get("social.action").?);
    // profile URL is hashed, not raw
    try std.testing.expect(events[0].attrs.get("profile.id_hash") != null);
    try std.testing.expect(events[0].attrs.get("profile.url") == null);
}
```

##### 🟢 Green
```zig
fn emitSocialAction(engine: *AutomationEngine, platform: []const u8, action: []const u8, step: []const u8) void {
    if (engine.telemetry) |sink| {
        sink.addEvent(engine.currentSpan(), "automation.social.action", .{
            .{ "social.platform", platform },
            .{ "social.action", action },
            .{ "social.step", step },
        });
    }
}
```

##### 🔵 Refactor
- [ ] Telemetry emission is a cross-cutting concern — single helper function
- [ ] Never logs raw profile URL — hashes per C33 RedactionPolicy
- [ ] No-op if telemetry sink is null — matches C35 ExportIsolation

---

## Component 3: Instagram Platform Contract

Same pattern as LinkedIn. Each `instagram.*` command decomposes into dom.*/page.* primitives.

### Behavior 3.1: `instagram.follow` Follows a User

#### Test Specification
**Given**: User logged in to Instagram
**When**: `instagram.follow({profileUrl: "https://www.instagram.com/janedoe/"})` dispatched
**Then**: Navigate to profile, click Follow button

**Edge Cases**:
- Already following → button says "Following" → step error with context
- Private account → Follow request sent (button changes to "Requested")

**Files touched**: `src/instagram.zig` (new), `tests/instagram_test.zig` (new)

#### TDD Cycle

##### 🔴 Red
```zig
test "follow clicks Follow button on profile" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "instagram" });

    const result = try instagram.follow(&mock_engine, .{
        .profile_url = "https://www.instagram.com/janedoe/",
    });

    try std.testing.expect(result.ok);
    try std.testing.expect(hasCommandWithSelector(
        mock_engine.commandLog(), "dom.click", "Follow",
    ));
}
```

##### 🟢 Green
```zig
pub fn follow(engine: *AutomationEngine, params: FollowParams) !SocialResult {
    try validateInstagramUrl(params.profile_url);
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.profile_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Follow\"]" });
    return .{ .ok = true };
}
```

---

### Behavior 3.2: `instagram.like` Likes a Post

#### Test Specification
**Given**: User logged in, post URL provided
**When**: `instagram.like({postUrl})` dispatched
**Then**: Navigate to post, click heart/Like button (double-click on image or single click on heart icon)

**Files touched**: `src/instagram.zig`, `tests/instagram_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "like clicks heart button on post" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "instagram" });

    const result = try instagram.like(&mock_engine, .{
        .post_url = "https://www.instagram.com/p/ABC123/",
    });

    try std.testing.expect(result.ok);
    try std.testing.expect(hasCommand(mock_engine.commandLog(), "dom.click"));
}
```

##### 🟢 Green
```zig
pub fn like(engine: *AutomationEngine, params: LikeParams) !SocialResult {
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.post_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.click", .{
        .selector = "css=[aria-label=\"Like\"]",
        .options = .{ .timeout_ms = 5000 },
    });
    return .{ .ok = true };
}
```

---

### Behavior 3.3: `instagram.comment` Comments on a Post

#### Test Specification
**Given**: User logged in, post URL and text provided
**When**: `instagram.comment({postUrl, text})` dispatched
**Then**: Navigate, click comment field, type text, submit

**Files touched**: `src/instagram.zig`, `tests/instagram_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "comment types and submits comment" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "instagram" });

    const result = try instagram.comment(&mock_engine, .{
        .post_url = "https://www.instagram.com/p/ABC123/",
        .text = "Nice photo!",
    });

    try std.testing.expect(result.ok);
    try std.testing.expect(hasCommand(mock_engine.commandLog(), "dom.type"));
}
```

##### 🟢 Green
```zig
pub fn comment(engine: *AutomationEngine, params: CommentParams) !SocialResult {
    try requireInstagramLogin(engine);
    try engine.dispatch("page.navigate", .{ .url = params.post_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.click", .{ .selector = "css=[aria-label=\"Add a comment…\"]" });
    try engine.dispatch("dom.type", .{
        .selector = "css=textarea[aria-label=\"Add a comment…\"]",
        .text = params.text,
    });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Post\"]" });
    return .{ .ok = true };
}
```

---

### Behavior 3.4: `instagram.dm` Sends a Direct Message

#### Test Specification
**Given**: User logged in, username and text provided
**When**: `instagram.dm({username, text})` dispatched
**Then**: Navigate to DM thread, compose, send

**Files touched**: `src/instagram.zig`, `tests/instagram_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "dm navigates to DM thread and sends message" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "instagram" });

    const result = try instagram.dm(&mock_engine, .{
        .username = "janedoe",
        .text = "Hey!",
    });

    try std.testing.expect(result.ok);
    try std.testing.expect(hasCommand(mock_engine.commandLog(), "dom.type"));
}
```

##### 🟢 Green
```zig
pub fn dm(engine: *AutomationEngine, params: DmParams) !SocialResult {
    try requireInstagramLogin(engine);
    const dm_url = try std.fmt.allocPrint(engine.allocator,
        "https://www.instagram.com/direct/t/{s}/",
        .{params.username},
    );
    try engine.dispatch("page.navigate", .{ .url = dm_url, .waitUntil = "networkidle" });
    try engine.dispatch("dom.type", .{
        .selector = "css=textarea[placeholder=\"Message...\"]",
        .text = params.text,
    });
    try engine.dispatch("dom.click", .{ .selector = "role=button[name=\"Send\"]" });
    return .{ .ok = true };
}
```

---

### Behavior 3.5: `instagram.story_view` Views Stories

#### Test Specification
**Given**: User logged in, username provided
**When**: `instagram.story_view({username})` dispatched
**Then**: Navigate to user's story, view sequentially (click through each story frame)

**Files touched**: `src/instagram.zig`, `tests/instagram_test.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "story_view navigates to stories and clicks through" {
    var mock_engine = MockAutomationEngine.init();
    mock_engine.setLoginState(.{ .logged_in = true, .platform = "instagram" });

    const result = try instagram.storyView(&mock_engine, .{
        .username = "janedoe",
    });

    try std.testing.expect(result.ok);
}
```

##### 🟢 Green
```zig
pub fn storyView(engine: *AutomationEngine, params: StoryViewParams) !SocialResult {
    try requireInstagramLogin(engine);
    const story_url = try std.fmt.allocPrint(engine.allocator,
        "https://www.instagram.com/stories/{s}/",
        .{params.username},
    );
    try engine.dispatch("page.navigate", .{ .url = story_url, .waitUntil = "networkidle" });
    // Click through stories until "no more stories" or navigation away
    while (true) {
        const next = engine.dispatch("dom.click", .{
            .selector = "role=button[name=\"Next\"]",
            .options = .{ .timeout_ms = 3000 },
        }) catch break;
        _ = next;
    }
    return .{ .ok = true };
}
```

---

### Behavior 3.6: Instagram Router Registration + Telemetry

#### Test Specification
**Given**: AutomationRouter
**When**: Instagram commands registered
**Then**: All 5 methods dispatch. Each emits `automation.social.action` with `social.platform=instagram`.

**Files touched**: `src/instagram.zig`

#### TDD Cycle

##### 🔴 Red
```zig
test "all 5 instagram methods register" {
    var router = AutomationRouter.init(test_allocator);
    instagram.register(&router);

    const methods = [_][]const u8{
        "instagram.follow", "instagram.like", "instagram.comment",
        "instagram.dm", "instagram.story_view",
    };
    for (methods) |method| {
        try std.testing.expect(router.hasMethod(method));
    }
}
```

##### 🟢 Green
```zig
pub fn register(router: *AutomationRouter) void {
    router.addMethod("instagram.follow", followHandler);
    router.addMethod("instagram.like", likeHandler);
    router.addMethod("instagram.comment", commentHandler);
    router.addMethod("instagram.dm", dmHandler);
    router.addMethod("instagram.story_view", storyViewHandler);
}
```

---

## Component 4: Python SDK

Primary client library. Connects to zigBrowser's UDS JSON-RPC 2.0 server. Provides both sync and async APIs.

### Behavior 4.1: UDS Connection Establishment

#### Test Specification
**Given**: A mock UDS server listening at a known socket path
**When**: `ZigBrowser(socket_path="/tmp/zb-test.sock")` is constructed and `connect()` called
**Then**: Client connects to the socket and performs token handshake

**Edge Cases**:
- Socket doesn't exist → `ConnectionError` with clear message
- Token handshake fails → `AuthenticationError`
- Context manager (`with ZigBrowser(...)`) auto-connects and disconnects

**Files touched**: `sdk/python/src/zigbrowser/client.py` (new), `sdk/python/tests/test_client.py` (new), `sdk/python/tests/conftest.py` (new)

#### TDD Cycle

##### 🔴 Red
**File**: `sdk/python/tests/test_client.py`
```python
import pytest
from zigbrowser import ZigBrowser

def test_connect_to_socket(mock_uds_server):
    client = ZigBrowser(socket_path=mock_uds_server.path)
    client.connect()
    assert client.connected
    client.disconnect()
    assert not client.connected

def test_context_manager(mock_uds_server):
    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        assert zb.connected
    assert not zb.connected

def test_connect_nonexistent_socket():
    client = ZigBrowser(socket_path="/tmp/nonexistent.sock")
    with pytest.raises(ConnectionError, match="socket"):
        client.connect()
```

##### 🟢 Green
**File**: `sdk/python/src/zigbrowser/client.py`
```python
import socket
import json

class ZigBrowser:
    def __init__(self, socket_path: str, token: str | None = None):
        self._socket_path = socket_path
        self._token = token
        self._sock: socket.socket | None = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(self._socket_path)
        except (FileNotFoundError, ConnectionRefusedError) as e:
            raise ConnectionError(f"Cannot connect to zigBrowser socket: {e}") from e
        self._sock = sock

    def disconnect(self) -> None:
        if self._sock:
            self._sock.close()
            self._sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.disconnect()
```

##### 🔵 Refactor
- [ ] No duplication
- [ ] Context manager pattern is idiomatic Python
- [ ] Clear error messages at system boundary

---

### Behavior 4.2: JSON-RPC Request/Response Round-Trip

#### Test Specification
**Given**: Connected client
**When**: `client.call("dom.click", {"selector": "role=button[name='Submit']"})` is invoked
**Then**: Sends well-formed JSON-RPC 2.0 request over UDS, receives and parses response. Returns result on success, raises exception on error.

**Edge Cases**:
- Server returns error → raises `AutomationError` with code, message, data
- Server returns malformed JSON → raises `ProtocolError`
- Request timeout → raises `TimeoutError`

**Files touched**: `sdk/python/src/zigbrowser/client.py`, `sdk/python/tests/test_client.py`

#### TDD Cycle

##### 🔴 Red
```python
def test_call_sends_jsonrpc_request(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.call("dom.click", {"selector": "role=button[name='OK']"})

    assert result == {"ok": True}
    req = mock_uds_server.last_request()
    assert req["jsonrpc"] == "2.0"
    assert req["method"] == "dom.click"
    assert req["params"]["selector"] == "role=button[name='OK']"
    assert "id" in req

def test_call_raises_on_rpc_error(mock_uds_server):
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "error": {"code": -32001, "message": "element_not_found",
                  "data": {"trace_id": "abc123", "command_id": "cmd456"}},
        "id": 1,
    })

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        with pytest.raises(AutomationError) as exc_info:
            zb.call("dom.click", {"selector": "role=button[name='Gone']"})

        err = exc_info.value
        assert err.code == -32001
        assert err.error_name == "element_not_found"
        assert err.trace_id == "abc123"
        assert err.command_id == "cmd456"
```

##### 🟢 Green
```python
import itertools

class ZigBrowser:
    _id_counter = itertools.count(1)

    def call(self, method: str, params: dict | None = None) -> dict:
        if not self._sock:
            raise ConnectionError("Not connected")

        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": next(self._id_counter),
        }
        self._send(json.dumps(request))
        response = self._recv()
        parsed = json.loads(response)

        if "error" in parsed:
            raise AutomationError.from_rpc_error(parsed["error"])
        return parsed.get("result")

    def _send(self, data: str) -> None:
        encoded = data.encode("utf-8")
        self._sock.sendall(len(encoded).to_bytes(4, "big") + encoded)

    def _recv(self) -> str:
        length_bytes = self._sock.recv(4)
        length = int.from_bytes(length_bytes, "big")
        data = b""
        while len(data) < length:
            chunk = self._sock.recv(length - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data.decode("utf-8")
```

##### 🔵 Refactor
- [ ] `_send`/`_recv` handle framing — extracted, single responsibility
- [ ] Error construction delegated to `AutomationError.from_rpc_error`

---

### Behavior 4.3: SDK Error Objects with Diagnostic Fields

#### Test Specification
**Given**: A JSON-RPC error response with `data` containing `trace_id`, `command_id`, `automation.error`, and redacted diagnostic fields
**When**: Error is raised as Python exception
**Then**: Exception object exposes `.trace_id`, `.command_id`, `.error_name`, `.code`, `.diagnostics` (redacted data dict)

**Edge Cases**:
- Missing `data` field → diagnostics is empty dict, trace_id/command_id are None
- Standard JSON-RPC errors (parse error, method not found) → `ProtocolError` subclass, not `AutomationError`

**Property**: `repr(error)` always includes trace_id if available — debugging aid

**Files touched**: `sdk/python/src/zigbrowser/errors.py` (new), `sdk/python/tests/test_errors.py` (new)

#### TDD Cycle

##### 🔴 Red
**File**: `sdk/python/tests/test_errors.py`
```python
from zigbrowser.errors import AutomationError, ProtocolError

def test_automation_error_from_rpc():
    rpc_error = {
        "code": -32001,
        "message": "element_not_found",
        "data": {
            "trace_id": "t-abc123",
            "command_id": "c-def456",
            "selector.hash": "h-789",
            "timeout_ms": 5000,
        },
    }
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.code == -32001
    assert err.error_name == "element_not_found"
    assert err.trace_id == "t-abc123"
    assert err.command_id == "c-def456"
    assert err.diagnostics == {"selector.hash": "h-789", "timeout_ms": 5000}
    assert "t-abc123" in repr(err)

def test_automation_error_missing_data():
    rpc_error = {"code": -32005, "message": "element_disabled"}
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.trace_id is None
    assert err.command_id is None
    assert err.diagnostics == {}

def test_protocol_error_for_standard_codes():
    rpc_error = {"code": -32601, "message": "Method not found"}
    err = AutomationError.from_rpc_error(rpc_error)
    assert isinstance(err, ProtocolError)
    assert not isinstance(err, AutomationError)  # ProtocolError is distinct

ERROR_CODE_MAP = {
    -32001: "element_not_found",
    -32002: "element_not_visible",
    -32003: "element_not_stable",
    -32004: "element_obscured",
    -32005: "element_disabled",
    -32006: "element_not_editable",
    -32007: "navigation_timeout",
    -32008: "navigation_failed",
    -32009: "action_timeout",
    -32010: "platform_rate_limited",
    -32011: "session_invalid",
    -32012: "cancelled",
}

@pytest.mark.parametrize("code,name", ERROR_CODE_MAP.items())
def test_all_12_error_codes_map_correctly(code, name):
    rpc_error = {"code": code, "message": name}
    err = AutomationError.from_rpc_error(rpc_error)
    assert err.code == code
    assert err.error_name == name
```

##### 🟢 Green
**File**: `sdk/python/src/zigbrowser/errors.py`
```python
class ZigBrowserError(Exception):
    pass

class ConnectionError(ZigBrowserError):
    pass

class ProtocolError(ZigBrowserError):
    def __init__(self, code: int, message: str):
        self.code = code
        super().__init__(f"JSON-RPC error {code}: {message}")

class AutomationError(ZigBrowserError):
    AUTOMATION_CODES = range(-32012, -32000)

    def __init__(self, code: int, error_name: str,
                 trace_id: str | None = None,
                 command_id: str | None = None,
                 diagnostics: dict | None = None):
        self.code = code
        self.error_name = error_name
        self.trace_id = trace_id
        self.command_id = command_id
        self.diagnostics = diagnostics or {}
        super().__init__(f"{error_name} (code={code}, trace={trace_id})")

    @classmethod
    def from_rpc_error(cls, rpc_error: dict):
        code = rpc_error["code"]
        message = rpc_error["message"]

        if code not in cls.AUTOMATION_CODES:
            return ProtocolError(code, message)

        data = rpc_error.get("data", {})
        trace_id = data.pop("trace_id", None)
        command_id = data.pop("command_id", None)

        return cls(
            code=code,
            error_name=message,
            trace_id=trace_id,
            command_id=command_id,
            diagnostics=data,
        )

    def __repr__(self):
        return (f"AutomationError(code={self.code}, error={self.error_name!r}, "
                f"trace_id={self.trace_id!r})")
```

##### 🔵 Refactor
- [ ] `from_rpc_error` factory separates automation errors from protocol errors — correct dispatch
- [ ] Diagnostics contain only redacted fields from server (trace_id/command_id extracted)
- [ ] `__repr__` includes trace_id for debugging

---

### Behavior 4.4: High-Level Method Wrappers

#### Test Specification
**Given**: Connected client
**When**: `client.dom.click("role=button[name='Submit']")` is called
**Then**: Translates to `client.call("dom.click", {"selector": "role=button[name='Submit']"})`

**Edge Cases**:
- Optional `timeout_ms`, `force`, `trial` kwargs pass through to options
- `client.linkedin.connect(profile_url, note="Hi!")` translates to the compound call

**Files touched**: `sdk/python/src/zigbrowser/client.py`

#### TDD Cycle

##### 🔴 Red
```python
def test_dom_click_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.dom.click("role=button[name='OK']", timeout_ms=5000)

    assert result["ok"] is True
    req = mock_uds_server.last_request()
    assert req["method"] == "dom.click"
    assert req["params"]["selector"] == "role=button[name='OK']"
    assert req["params"]["options"]["timeout_ms"] == 5000

def test_linkedin_connect_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = zb.linkedin.connect(
            "https://www.linkedin.com/in/jane/", note="Hi Jane!"
        )

    req = mock_uds_server.last_request()
    assert req["method"] == "linkedin.connect"
    assert req["params"]["profileUrl"] == "https://www.linkedin.com/in/jane/"
    assert req["params"]["note"] == "Hi Jane!"

def test_page_navigate_wrapper(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.page.navigate("https://example.com", wait_until="networkidle")

    req = mock_uds_server.last_request()
    assert req["method"] == "page.navigate"
    assert req["params"]["url"] == "https://example.com"
    assert req["params"]["waitUntil"] == "networkidle"
```

##### 🟢 Green
```python
class DomNamespace:
    def __init__(self, client):
        self._client = client

    def click(self, selector: str, **options) -> dict:
        params = {"selector": selector}
        if options:
            params["options"] = options
        return self._client.call("dom.click", params)

    def fill(self, selector: str, value: str, **options) -> dict:
        params = {"selector": selector, "value": value}
        if options:
            params["options"] = options
        return self._client.call("dom.fill", params)

    def query(self, selector: str, timeout_ms: int | None = None) -> dict:
        params = {"selector": selector}
        if timeout_ms:
            params["timeout_ms"] = timeout_ms
        return self._client.call("dom.query", params)
    # ... getText, getAttribute, waitFor, type

class LinkedInNamespace:
    def __init__(self, client):
        self._client = client

    def connect(self, profile_url: str, note: str | None = None) -> dict:
        params = {"profileUrl": profile_url}
        if note:
            params["note"] = note
        return self._client.call("linkedin.connect", params)

    def visit(self, profile_url: str) -> dict:
        return self._client.call("linkedin.visit", {"profileUrl": profile_url})
    # ... message, like, comment, search, extract

class ZigBrowser:
    def __init__(self, ...):
        self.dom = DomNamespace(self)
        self.page = PageNamespace(self)
        self.linkedin = LinkedInNamespace(self)
        self.instagram = InstagramNamespace(self)
        self.social = SocialNamespace(self)
        self.cookies = CookiesNamespace(self)
```

##### 🔵 Refactor
- [ ] Namespace objects are thin wrappers around `call()` — correct depth
- [ ] Python kwargs → JSON params mapping is consistent
- [ ] snake_case Python → camelCase JSON-RPC param mapping

---

### Behavior 4.5: WebSocket Event Subscription

#### Test Specification
**Given**: Connected client with WebSocket channel
**When**: `client.on("event.navigation", callback)` registered and navigation event arrives
**Then**: Callback invoked with event params

**Edge Cases**:
- Multiple listeners for same event type → all called
- Event received with no listener → silently dropped
- Connection lost → reconnect attempt with exponential backoff

**Files touched**: `sdk/python/src/zigbrowser/events.py` (new), `sdk/python/tests/test_events.py` (new)

#### TDD Cycle

##### 🔴 Red
```python
def test_event_subscription(mock_uds_server):
    received = []

    def on_nav(params):
        received.append(params)

    with ZigBrowser(socket_path=mock_uds_server.path) as zb:
        zb.on("event.navigation", on_nav)
        mock_uds_server.push_notification({
            "jsonrpc": "2.0",
            "method": "event.navigation",
            "params": {"state": "network_idle", "url": "https://example.com"},
        })
        # Allow event loop to process
        import time; time.sleep(0.1)

    assert len(received) == 1
    assert received[0]["state"] == "network_idle"
```

##### 🟢 Green
```python
import threading

class EventDispatcher:
    def __init__(self):
        self._listeners: dict[str, list[callable]] = {}
        self._thread: threading.Thread | None = None

    def on(self, event_type: str, callback: callable) -> None:
        self._listeners.setdefault(event_type, []).append(callback)

    def dispatch(self, method: str, params: dict) -> None:
        for cb in self._listeners.get(method, []):
            cb(params)

    def start(self, ws_reader) -> None:
        self._thread = threading.Thread(target=self._listen, args=(ws_reader,), daemon=True)
        self._thread.start()

    def _listen(self, ws_reader):
        for msg in ws_reader:
            parsed = json.loads(msg)
            self.dispatch(parsed.get("method", ""), parsed.get("params", {}))
```

##### 🔵 Refactor
- [ ] Daemon thread for event loop — correct for background listener
- [ ] No duplicate dispatch code — single `dispatch` method

---

### Behavior 4.6: Async Python API

#### Test Specification
**Given**: Async context
**When**: `await client.call_async("dom.click", {...})` invoked
**Then**: Uses asyncio for non-blocking UDS I/O

**Files touched**: `sdk/python/src/zigbrowser/client.py`

#### TDD Cycle

##### 🔴 Red
```python
import pytest_asyncio

@pytest.mark.asyncio
async def test_async_call(mock_uds_server):
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    async with AsyncZigBrowser(socket_path=mock_uds_server.path) as zb:
        result = await zb.call("dom.click", {"selector": "role=button"})

    assert result == {"ok": True}
```

##### 🟢 Green
```python
import asyncio

class AsyncZigBrowser:
    async def connect(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(self._socket_path)

    async def call(self, method: str, params: dict | None = None) -> dict:
        request = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": next(self._id_counter)}
        data = json.dumps(request).encode("utf-8")
        self._writer.write(len(data).to_bytes(4, "big") + data)
        await self._writer.drain()
        length_bytes = await self._reader.readexactly(4)
        length = int.from_bytes(length_bytes, "big")
        response_data = await self._reader.readexactly(length)
        parsed = json.loads(response_data.decode("utf-8"))
        if "error" in parsed:
            raise AutomationError.from_rpc_error(parsed["error"])
        return parsed.get("result")

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, *args):
        await self.disconnect()
```

##### 🔵 Refactor
- [ ] Shares error handling logic with sync client — extract base class or module-level function
- [ ] asyncio.open_unix_connection is idiomatic

---

## Component 5: Node.js SDK

### Behavior 5.1: UDS Connection and JSON-RPC Calls

#### Test Specification
**Given**: Mock UDS server
**When**: `const zb = new ZigBrowser({socketPath}); await zb.connect()` then `await zb.call("dom.click", {selector})`
**Then**: Sends JSON-RPC 2.0 request, resolves with result or rejects with AutomationError

**Files touched**: `sdk/node/src/client.ts` (new), `sdk/node/tests/client.test.ts` (new)

#### TDD Cycle

##### 🔴 Red
**File**: `sdk/node/tests/client.test.ts`
```typescript
import { describe, it, expect } from "vitest";
import { ZigBrowser, AutomationError } from "../src/index";

describe("ZigBrowser client", () => {
  it("connects to UDS and sends JSON-RPC request", async () => {
    const server = await createMockServer();
    server.setResponse({ jsonrpc: "2.0", result: { ok: true }, id: 1 });

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();
    const result = await zb.call("dom.click", { selector: "role=button" });

    expect(result).toEqual({ ok: true });
    const req = server.lastRequest();
    expect(req.method).toBe("dom.click");
    expect(req.jsonrpc).toBe("2.0");

    await zb.disconnect();
    await server.close();
  });

  it("rejects with AutomationError on RPC error", async () => {
    const server = await createMockServer();
    server.setResponse({
      jsonrpc: "2.0",
      error: {
        code: -32001,
        message: "element_not_found",
        data: { trace_id: "t-123", command_id: "c-456" },
      },
      id: 1,
    });

    const zb = new ZigBrowser({ socketPath: server.path });
    await zb.connect();

    await expect(zb.call("dom.click", { selector: "role=button" }))
      .rejects.toThrow(AutomationError);

    try {
      await zb.call("dom.click", { selector: "role=button" });
    } catch (e) {
      expect(e).toBeInstanceOf(AutomationError);
      expect(e.code).toBe(-32001);
      expect(e.errorName).toBe("element_not_found");
      expect(e.traceId).toBe("t-123");
      expect(e.commandId).toBe("c-456");
    }

    await zb.disconnect();
    await server.close();
  });
});
```

##### 🟢 Green
**File**: `sdk/node/src/client.ts`
```typescript
import net from "node:net";

export class ZigBrowser {
  private socket: net.Socket | null = null;
  private socketPath: string;
  private idCounter = 0;

  constructor(opts: { socketPath: string }) {
    this.socketPath = opts.socketPath;
  }

  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.socket = net.createConnection(this.socketPath, () => resolve());
      this.socket.on("error", reject);
    });
  }

  async call(method: string, params?: Record<string, unknown>): Promise<unknown> {
    if (!this.socket) throw new Error("Not connected");

    const id = ++this.idCounter;
    const request = { jsonrpc: "2.0", method, params: params ?? {}, id };
    const data = Buffer.from(JSON.stringify(request), "utf-8");
    const header = Buffer.alloc(4);
    header.writeUInt32BE(data.length);

    this.socket.write(Buffer.concat([header, data]));

    const response = await this.readResponse();
    const parsed = JSON.parse(response);

    if ("error" in parsed) {
      throw AutomationError.fromRpcError(parsed.error);
    }
    return parsed.result;
  }

  async disconnect(): Promise<void> {
    return new Promise((resolve) => {
      this.socket?.end(() => resolve());
      this.socket = null;
    });
  }

  private readResponse(): Promise<string> { /* frame reading */ }
}
```

##### 🔵 Refactor
- [ ] Same framing protocol as Python SDK — consistent wire format
- [ ] Promise-based API is idiomatic Node.js

---

### Behavior 5.2: Node.js Error Objects

#### Test Specification
**Given**: JSON-RPC error with automation code
**When**: Parsed by SDK
**Then**: `AutomationError` with `.traceId`, `.commandId`, `.errorName`, `.code`, `.diagnostics`

**Files touched**: `sdk/node/src/errors.ts` (new), `sdk/node/tests/errors.test.ts` (new)

#### TDD Cycle

##### 🔴 Red
```typescript
describe("AutomationError", () => {
  it("maps all 12 automation codes", () => {
    const codes = Array.from({ length: 12 }, (_, i) => -32001 - i);
    for (const code of codes) {
      const err = AutomationError.fromRpcError({
        code,
        message: `error_${code}`,
      });
      expect(err).toBeInstanceOf(AutomationError);
      expect(err.code).toBe(code);
    }
  });

  it("exposes trace_id and command_id from data", () => {
    const err = AutomationError.fromRpcError({
      code: -32001,
      message: "element_not_found",
      data: { trace_id: "t-abc", command_id: "c-def", "selector.hash": "h123" },
    });
    expect(err.traceId).toBe("t-abc");
    expect(err.commandId).toBe("c-def");
    expect(err.diagnostics).toEqual({ "selector.hash": "h123" });
  });

  it("returns ProtocolError for standard JSON-RPC codes", () => {
    const err = AutomationError.fromRpcError({
      code: -32601,
      message: "Method not found",
    });
    expect(err).toBeInstanceOf(ProtocolError);
  });
});
```

##### 🟢 Green
```typescript
export class AutomationError extends Error {
  static AUTOMATION_RANGE = [-32012, -32001];

  constructor(
    public code: number,
    public errorName: string,
    public traceId?: string,
    public commandId?: string,
    public diagnostics: Record<string, unknown> = {},
  ) {
    super(`${errorName} (code=${code}, trace=${traceId})`);
    this.name = "AutomationError";
  }

  static fromRpcError(rpcError: { code: number; message: string; data?: Record<string, unknown> }) {
    const { code, message, data = {} } = rpcError;

    if (code < this.AUTOMATION_RANGE[0] || code > this.AUTOMATION_RANGE[1]) {
      return new ProtocolError(code, message);
    }

    const { trace_id, command_id, ...diagnostics } = data;
    return new AutomationError(code, message, trace_id as string, command_id as string, diagnostics);
  }
}
```

---

### Behavior 5.3: Node.js Event Subscription via EventEmitter

#### Test Specification
**Given**: Connected client
**When**: `zb.on("event.navigation", handler)` and navigation event arrives
**Then**: Handler called with event params. Uses Node.js `EventEmitter` pattern.

**Files touched**: `sdk/node/src/events.ts` (new), `sdk/node/tests/events.test.ts` (new)

#### TDD Cycle (abbreviated — same pattern as Python events)

##### 🔴 Red
```typescript
it("dispatches WebSocket events to listeners", async () => {
  const received: unknown[] = [];
  const zb = new ZigBrowser({ socketPath: server.path });
  await zb.connect();
  zb.on("event.navigation", (params) => received.push(params));
  server.pushNotification({
    jsonrpc: "2.0",
    method: "event.navigation",
    params: { state: "network_idle", url: "https://example.com" },
  });
  await new Promise((r) => setTimeout(r, 50));
  expect(received).toHaveLength(1);
  expect(received[0]).toEqual({ state: "network_idle", url: "https://example.com" });
});
```

---

## Component 6: CLI Tool

Python-based CLI using the Python SDK. Sends any automation command and formats results.

### Behavior 6.1: CLI Sends Automation Commands

#### Test Specification
**Given**: zigBrowser running with `--automation-api`
**When**: `zigbrowser-cli dom.click --selector "role=button[name='OK']"` executed
**Then**: Connects to UDS, sends JSON-RPC request, prints result or error

**Edge Cases**:
- No zigBrowser running → clear error: "Cannot connect to zigBrowser. Is it running with --automation-api?"
- Error response → prints error with trace_id for debugging

**Files touched**: `sdk/cli/src/zigbrowser_cli/main.py` (new), `sdk/cli/tests/test_main.py` (new)

#### TDD Cycle

##### 🔴 Red
```python
from click.testing import CliRunner
from zigbrowser_cli.main import cli

def test_cli_sends_command(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"ok": True}, "id": 1})

    runner = CliRunner()
    result = runner.invoke(cli, ["dom.click", "--selector", "role=button[name='OK']"])

    assert result.exit_code == 0
    assert '"ok": true' in result.output

def test_cli_shows_error_with_trace_id(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "error": {"code": -32001, "message": "element_not_found",
                  "data": {"trace_id": "t-abc123"}},
        "id": 1,
    })

    runner = CliRunner()
    result = runner.invoke(cli, ["dom.click", "--selector", "role=button"])

    assert result.exit_code == 1
    assert "element_not_found" in result.output
    assert "t-abc123" in result.output
    assert "zigbrowser-cli --trace t-abc123" in result.output
```

##### 🟢 Green
```python
import click
import json
import os
from zigbrowser import ZigBrowser
from zigbrowser.errors import AutomationError

@click.group()
def cli():
    pass

@cli.command(name="dom.click")
@click.option("--selector", required=True)
@click.option("--timeout-ms", type=int, default=None)
@click.option("--force", is_flag=True)
@click.option("--trial", is_flag=True)
def dom_click(selector, timeout_ms, force, trial):
    params = {"selector": selector}
    options = {}
    if timeout_ms: options["timeout_ms"] = timeout_ms
    if force: options["force"] = True
    if trial: options["trial"] = True
    if options: params["options"] = options
    _execute("dom.click", params)

def _execute(method, params):
    socket_path = os.environ.get("ZIGBROWSER_SOCKET")
    if not socket_path:
        click.echo("Error: ZIGBROWSER_SOCKET not set", err=True)
        raise SystemExit(1)
    try:
        with ZigBrowser(socket_path=socket_path) as zb:
            result = zb.call(method, params)
            click.echo(json.dumps(result, indent=2))
    except AutomationError as e:
        click.echo(f"Error: {e.error_name} (code {e.code})", err=True)
        if e.trace_id:
            click.echo(f"  trace_id: {e.trace_id}", err=True)
            click.echo(f"  Debug: zigbrowser-cli --trace {e.trace_id}", err=True)
        raise SystemExit(1)
```

##### 🔵 Refactor
- [ ] `_execute` is shared by all command handlers — single error handling path
- [ ] Error output suggests `--trace` command for debugging

---

### Behavior 6.2: `--trace <trace_id>` Telemetry Lookup

#### Test Specification
**Given**: A trace_id from a previous error
**When**: `zigbrowser-cli --trace t-abc123` executed
**Then**: Queries local telemetry sink for the trace, displays formatted span tree: command → selector resolution → actionability check → platform eval

**Edge Cases**:
- No telemetry sink configured → clear message: "No telemetry sink configured"
- Trace not found → "Trace t-abc123 not found"

**Files touched**: `sdk/cli/src/zigbrowser_cli/trace.py` (new)

#### TDD Cycle

##### 🔴 Red
```python
def test_trace_displays_span_tree(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({
        "jsonrpc": "2.0",
        "result": {
            "spans": [
                {"name": "automation.command", "trace_id": "t-abc", "duration_ms": 1234,
                 "attributes": {"rpc.method": "dom.click", "result.status": "error",
                               "automation.error": "element_not_found"}},
                {"name": "automation.selector.resolve", "trace_id": "t-abc", "duration_ms": 1200,
                 "attributes": {"selector.kind": "role", "selector.match_count": 0}},
            ],
        },
        "id": 1,
    })

    runner = CliRunner()
    result = runner.invoke(cli, ["--trace", "t-abc"])

    assert result.exit_code == 0
    assert "automation.command" in result.output
    assert "dom.click" in result.output
    assert "element_not_found" in result.output
    assert "1234ms" in result.output

def test_trace_not_found(mock_uds_server, monkeypatch):
    monkeypatch.setenv("ZIGBROWSER_SOCKET", mock_uds_server.path)
    mock_uds_server.set_response({"jsonrpc": "2.0", "result": {"spans": []}, "id": 1})

    runner = CliRunner()
    result = runner.invoke(cli, ["--trace", "t-nonexistent"])

    assert "not found" in result.output
```

##### 🟢 Green
```python
@cli.command(name="--trace")
@click.argument("trace_id")
def trace_lookup(trace_id):
    socket_path = os.environ.get("ZIGBROWSER_SOCKET")
    if not socket_path:
        click.echo("Error: ZIGBROWSER_SOCKET not set", err=True)
        raise SystemExit(1)

    with ZigBrowser(socket_path=socket_path) as zb:
        result = zb.call("telemetry.query", {"trace_id": trace_id})

    spans = result.get("spans", [])
    if not spans:
        click.echo(f"Trace {trace_id} not found")
        return

    for span in spans:
        attrs = span.get("attributes", {})
        indent = "  " if span["name"] != "automation.command" else ""
        status = attrs.get("result.status", "")
        error = attrs.get("automation.error", "")
        method = attrs.get("rpc.method", span["name"])
        duration = span.get("duration_ms", 0)
        line = f"{indent}{span['name']} ({method}) — {duration}ms"
        if error:
            line += f" — {error}"
        click.echo(line)
```

##### 🔵 Refactor
- [ ] Span tree formatting is readable
- [ ] Queries server for telemetry — uses `telemetry.query` method (server-side must support)

---

## Workflow Closure

### Production Operation Chain

```
SDK client.call("linkedin.connect", params)
  → UDS JSON-RPC request
    → AutomationRouter.dispatch("linkedin.connect", params)
      → linkedin.connect() decomposes into:
        → social.loginCheck() via engine
        → engine.dispatch("page.navigate", ...)
        → engine.dispatch("dom.click", ...) [Connect button]
        → engine.dispatch("dom.fill", ...) [note, if provided]
        → engine.dispatch("dom.click", ...) [Send]
      → emits automation.social.action telemetry
    → JSON-RPC response
  → UDS response
→ SDK returns result or raises AutomationError
```

### Closure Test: linkedin.connect sends connection request through full automation chain   [BLOCKING]

This is BLOCKING because the chain crosses: SDK → UDS transport → router → social contract → engine → pacing → page port → injected script → DOM — all async boundaries and registration points.

- **SOURCE (seed only)**: Mock page DOM (test fixture with LinkedIn-like profile page), pacing config
- **TRIGGER (start)**: `sdk.linkedin.connect(profile_url, note)` — the SDK's public API call
- **DRIVERS (async edges)**: UDS socket I/O (real socket pair), AutomationEngine command queue (drain synchronously in test)
- **OBSERVE (assert via)**: JSON-RPC response received by SDK; mock page port's command log shows correct sequence of dom.*/page.* primitives in order
- **FORBIDDEN SPAN**: Everything between SDK `call()` and mock PagePort — the test must not mock the router, social layer, or engine
- **RED-AT-SEAM proof**: Remove `linkedin.register(router)` → method not found (-32601); disable login check → session_invalid (-32011)
- **DRIVABILITY**: Store seam: mock PagePort injected via vtable. Engine command queue driven synchronously via `queue.drainOne()`. No async edges need clock injection — UDS is synchronous in test.
- **EXECUTION**: Requires: UDS socket pair (stdlib), mock PagePort (in-memory), in-memory TelemetrySink. Test FAILS-CLOSED if socket creation fails.

### Closure Test: SDK error objects preserve trace_id through the chain   [BLOCKING]

- **SOURCE (seed only)**: Mock PagePort that returns `element_not_found` with trace context
- **TRIGGER (start)**: `sdk.dom.click(selector)` — SDK call that will fail
- **DRIVERS (async edges)**: UDS socket I/O (real socket pair)
- **OBSERVE (assert via)**: Caught `AutomationError` exception; assert `error.trace_id` matches the trace_id generated by the engine's TelemetrySink
- **FORBIDDEN SPAN**: Router, engine, telemetry sink — all must run for real
- **RED-AT-SEAM proof**: Remove trace_id from error response data → `error.trace_id is None`
- **DRIVABILITY**: Same as above — UDS socket pair + mock PagePort
- **EXECUTION**: Same infrastructure. Test FAILS-CLOSED if socket creation fails.

### Closure Test: social.set_pacing configures pacing and affects subsequent actions   [LEAF: same-module, no async, no registration]

- Unit test: call `social.setPacing()` → verify pacing layer config updated → subsequent `social.rateStatus()` reflects new values. Purely synchronous, no cross-module boundary.

---

## Integration & E2E Testing

### Integration Tests

1. **SDK → UDS → Router → Social**: Python SDK connects to real zigBrowser with `--automation-api`, sends `social.login_check`, receives structured response
2. **Error propagation**: Send `dom.click` with impossible selector → verify `AutomationError` in SDK has correct code, trace_id
3. **Event subscription**: Subscribe to `event.navigation`, trigger navigation, verify event received
4. **CLI → SDK → zigBrowser**: Run CLI command, verify output matches expected format

### E2E Tests (against test fixture server)

1. **LinkedIn connect flow**: Load LinkedIn-like test fixture → `linkedin.connect` → verify DOM changes
2. **Instagram follow flow**: Load Instagram-like test fixture → `instagram.follow` → verify DOM changes
3. **Rate limiting**: Send actions until daily cap → verify `platform_rate_limited` error
4. **Session detection**: Load fixture without login indicators → verify `session_invalid` error

### E2E Test Fixture Requirements

The test fixture server (from Phase 1) must provide pages that simulate:
- LinkedIn profile page with Connect button, note dialog
- LinkedIn messaging thread with compose input
- LinkedIn search results page
- Instagram profile with Follow button
- Instagram post with Like/Comment controls
- Instagram DM thread
- Login/logout state detection signals
- Rate limit modal/toast overlays

---

## Build Integration

### Zig modules for social contracts

```zig
// In build.zig — add alongside existing nav_policy, ipc test modules
const social_module = b.createModule(.{
    .root_source_file = b.path("src/social.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
});
const social_tests_module = b.createModule(.{
    .root_source_file = b.path("tests/social_test.zig"),
    .target = target, .optimize = optimize, .link_libc = true,
});
social_tests_module.addImport("social", social_module);
// ... same pattern for linkedin, instagram
```

### Python SDK packaging

```toml
# sdk/python/pyproject.toml
[project]
name = "zigbrowser"
version = "0.1.0"
requires-python = ">=3.11"

[project.optional-dependencies]
dev = ["pytest", "pytest-asyncio"]
```

### Node.js SDK packaging

```json
{
  "name": "@zigbrowser/sdk",
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "devDependencies": {
    "vitest": "^3.0.0",
    "typescript": "^5.0.0"
  }
}
```

### CLI packaging

```toml
# sdk/cli/pyproject.toml
[project]
name = "zigbrowser-cli"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["zigbrowser>=0.1.0", "click>=8.0"]

[project.scripts]
zigbrowser-cli = "zigbrowser_cli.main:cli"
```

---

## Implementation Order

1. **social.zig** (Behaviors 1.1–1.5) — foundation for all platform contracts
2. **linkedin.zig** (Behaviors 2.1–2.9) — first platform contract, validates compound→primitive pattern
3. **instagram.zig** (Behaviors 3.1–3.6) — second platform, follows established pattern
4. **Python SDK errors.py** (Behavior 4.3) — error objects first, used by everything else
5. **Python SDK client.py** (Behaviors 4.1–4.2) — core client
6. **Python SDK method wrappers** (Behavior 4.4) — high-level API
7. **Python SDK events** (Behavior 4.5) — WebSocket subscription
8. **Python SDK async** (Behavior 4.6) — async variant
9. **Node.js SDK** (Behaviors 5.1–5.3) — follows Python patterns
10. **CLI tool** (Behaviors 6.1–6.2) — built on Python SDK

---

## References

- PRD: `thoughts/searchable/shared/prd/2026-07-09-browser-automation-api.md`
- Context Map: `thoughts/searchable/shared/prd/2026-07-09-browser-automation-api-context-map.html`
- Research: `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md`
- Codebase Seams: `thoughts/searchable/shared/research/2026-07-09-14-40-codebase-automation-api-seams.md`
- Existing IPC pattern: `src/ipc.zig:38-108` (dispatch function)
- Existing test pattern: `tests/ipc_test.zig`, `tests/nav_policy_test.zig`
- Existing E2E pattern: `tests/e2e/ipc_roundtrip_test.py`
- JS bridge reference: `tests/fixtures/app/zbhost.js`
- PRD §9.1: LinkedIn actions (7 compound actions)
- PRD §9.2: Instagram actions (5 compound actions)
- PRD §9.3: Generic social.* commands (4 commands)
- PRD §5.3: AutomationError enum (12 variants → -32001..-32012)
- PRD §7: Observability architecture (wide events, redaction)
- Context map BC10: Social Contracts (S14 Social→Engine seam)
- Context map BC8: External Transport (S10 Client→Server seam)

---

## System Map

**Scope:** BC10 Social Contracts and Client Tier (Python SDK, Node.js SDK, CLI). All contexts mapped here are **to-be** (target state, Phase 5). No as-is boundaries exist in this phase's scope — the entire client and social contract layer is new.

**External contexts** (referenced at seams only — internals mapped by sibling agents):
- **BC6** Automation Engine — receives decomposed `dom.*/page.*` primitives via S14
- **BC8** External Transport — receives JSON-RPC 2.0 requests via S10, pushes events via EV4
- **BC9** Stealth & Pacing — queried/configured for pacing via BC6 (S12)
- **BC11** Observability — receives `automation.social.action` telemetry via S15

---

### BC10: Social Platform Contracts

**Status:** To-Be (provisional — LinkedIn/Instagram split may not warrant separate sub-contexts until selector maintenance patterns emerge)
**Owns:** `src/social.zig`, `src/linkedin.zig`, `src/instagram.zig`

#### (a) Boundary Diagram

```mermaid
flowchart TB
    classDef iface   fill:#dae8fc,stroke:#6c8ebf   %% interfaces (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450   %% violated/missing

    subgraph BC10["BC10: Social Platform Contracts (to-be, provisional)"]
        IN12["IN12: SocialCommand\nlinkedin.* | instagram.*"]:::iface
        IN18["IN18: SocialGenericCommand\nsocial.login_check | rate_status |\npause | set_pacing"]:::iface

        C43["C43: URLValidation"]:::contract
        C29["C29: LinkedInActions\n7 compound sequences"]:::contract
        C30["C30: InstagramActions\n5 compound sequences"]:::contract
        C42["C42: NoteLimit\nnote ≤ 300 chars"]:::contract
        C44["C44: CompoundDecomposition\ndom.*/page.* primitives only"]:::contract

        C31["C31: SessionValidity\nlogin_check gate"]:::contract
        C41["C41: PacingDelegation\nvalidate + delegate"]:::contract

        EV7["EV7: SocialActionEvent\nautomation.social.action"]:::iface
        OUT15["OUT15: SocialResult"]:::iface
        S14["S14: Social→Engine"]:::seam
    end

    BC6_ext["BC6: Engine (external)"]
    BC11_ext["BC11: Observability (external)"]

    IN12 --> C43
    C43 --> C29
    C43 --> C30
    C29 --> C42
    C29 --> C44
    C30 --> C44
    IN18 --> C31
    IN18 --> C41
    C31 --> S14
    C41 --> S14
    C44 --> S14
    S14 --> OUT15
    S14 ---|"IN8/OUT11"| BC6_ext
    C29 -.-> EV7
    C30 -.-> EV7
    EV7 -.->|"via S15"| BC11_ext
```

#### (b) EBNF Grammar

```ebnf
(* ─── BC10: Social Contracts ─── Interfaces ─── *)

IN12_SocialCommand        ::= PlatformMethod ;
PlatformMethod            ::= ("linkedin" | "instagram") "." PlatformVerb ;
PlatformVerb              ::= "connect" | "message" | "like" | "comment" | "visit"
                            | "search" | "extract" | "follow" | "dm" | "story_view" ;

IN18_SocialGenericCommand ::= "social." GenericVerb ;
GenericVerb               ::= "login_check" | "rate_status" | "pause" | "set_pacing" ;

OUT15_SocialResult        ::= OkResult | StepErrorResult | LoginCheckResult | RateStatusResult ;
OkResult                  ::= "{" "\"ok\":true" "}" ;
StepErrorResult           ::= "{" "\"ok\":false," "\"step\":" String ","
                              "\"error\":" AutomationErrorName "}" ;
LoginCheckResult          ::= "{" "\"loggedIn\":" Boolean "," "\"platform\":" String
                              ("," "\"username\":" String)? "}" ;
RateStatusResult          ::= "{" "\"remaining_actions\":" Integer ","
                              "\"reset_at\":" IsoTimestamp ","
                              "\"daily_cap\":" Integer "}" ;

EV7_SocialActionEvent     ::= "{"
                              "\"name\":\"automation.social.action\","
                              "\"social.platform\":" PlatformName ","
                              "\"social.action\":" ActionVerb ","
                              "\"social.step\":" StepName ","
                              "\"profile.id_hash\":" String?
                              "}" ;
PlatformName              ::= "\"linkedin\"" | "\"instagram\"" ;

(* ─── BC10: Social Contracts ─── Contracts ─── *)

C29_LinkedInActions
    governs: linkedin.* compound action sequences (7 actions)
    invariant: each compound = ordered sequence of dom.*/page.* primitives
    pre:  login verified via C31_SessionValidity before any action
    post: connect → navigate → click Connect → [add note → fill → send] | [send without note]
    post: message → navigate → focus input → dom.type (behavioral sim) → send
    post: like → navigate → click Like button
    post: comment → navigate → click Comment → dom.type → submit
    post: visit → page.navigate to profileUrl (triggers view notification)
    post: search → navigate to search URL → [apply filters] → page.evaluate extract
    post: extract → navigate to profile → page.evaluate extract structured data
    post: each action emits EV7_SocialActionEvent with social.platform="linkedin" ;

C30_InstagramActions
    governs: instagram.* compound action sequences (5 actions)
    invariant: each compound = ordered sequence of dom.*/page.* primitives
    pre:  login verified via C31_SessionValidity before any action
    post: follow → navigate → click Follow
    post: like → navigate → click heart/Like (css=[aria-label="Like"])
    post: comment → navigate → click field → dom.type → submit
    post: dm → navigate to DM thread URL → dom.type → send
    post: story_view → navigate to stories → click Next until exhausted or timeout
    post: each action emits EV7_SocialActionEvent with social.platform="instagram" ;

C31_SessionValidity
    governs: social.login_check result and session_invalid gate
    invariant: every linkedin.*/instagram.* action calls login_check before dispatch
    pre:  browser page loaded on target platform
    post: loggedIn detected via platform-specific DOM signals (injected script eval)
    post: platform detected from page URL host (linkedin.com → "linkedin", etc.)
    post: not logged in + platform action attempted → session_invalid (-32011)
    post: unrecognized host → platform = "unknown" ;

C41_PacingDelegation
    governs: social.set_pacing validation and social.rate_status/pause delegation
    pre:  social.set_pacing({min_delay_ms, max_delay_ms, daily_cap}) received
    post: min_delay_ms ≤ max_delay_ms → delegate to PacingLayer (BC9 via BC6/S12)
    post: min_delay_ms > max_delay_ms → InvalidParams (-32602)
    post: daily_cap = 0 → valid (effectively disables automation)
    post: partial params → update provided fields only, keep defaults
    post: social.rate_status → read PacingLayer state → RateStatusResult
    post: social.pause({duration_ms}) → delegate queue.pauseFor to engine
    post: duration_ms = 0 → immediate return, no pause ;

C42_NoteLimit
    governs: linkedin.connect note parameter
    invariant: note text truncated to 300 characters before dom.fill dispatch
    pre:  note: ?[]const u8 (optional)
    post: note.len > 300 → truncate to note[0..300]
    post: truncation recorded as telemetry dimension, not raised as error ;

C43_URLValidation
    governs: profileUrl/postUrl parameters on all platform compound actions
    invariant: URL must match expected platform domain before any navigation
    pre:  linkedin.* → profileUrl or postUrl parameter provided
    pre:  instagram.* → profileUrl or postUrl or username provided
    post: linkedin.* → URL starts with "https://www.linkedin.com/" or error
    post: instagram.* → URL starts with "https://www.instagram.com/" or error
    post: domain mismatch → InvalidParams (-32602) ;

C44_CompoundDecomposition
    governs: all platform method implementations (compound→primitive invariant)
    invariant: compound actions decompose EXCLUSIVELY into dom.*/page.* primitives
    invariant: no direct DOM access — all interaction via engine.dispatch()
    post: each step dispatched via engine.dispatch(method, params)
    post: selectors use ARIA roles per PRD §4.2 priority:
          role= > testid= > text= > css= > xpath=
    post: dom.type used (not dom.fill) for behavioral simulation through pacing
    post: step failure bubbles AutomationError with step context preserved ;

(* ─── BC10: Social Contracts ─── Seam ─── *)

S14_Social_Engine
    interfaces: IN12_SocialCommand, IN18_SocialGenericCommand,
                IN8_AutomationCommand (external/BC6),
                OUT15_SocialResult, OUT11_CommandResult (external/BC6)
    events:     EV7_SocialActionEvent (emitted to S15/BC11)
    contracts:  C29_LinkedInActions, C30_InstagramActions,
                C31_SessionValidity, C41_PacingDelegation,
                C43_URLValidation, C44_CompoundDecomposition ;
```

#### (c) Seam Table

| S# | Boundary | Interfaces Crossing | Events Crossing | Contracts Governing |
|---|---|---|---|---|
| S14 | BC10 → BC6 | IN12, IN18 → decomposed to IN8 (BC6); OUT11 (BC6) → aggregated to OUT15 | — | C29, C30, C31, C41, C43, C44 |
| S15 | BC10 → BC11 (external) | — | EV7 → IN13 (BC11) | C33 RedactionPolicy (BC11, governs EV7 export) |

---

### Client Tier: Platform SDKs & CLI

**Status:** To-Be (new, Phase 5). Not provisional — clean boundary to BC8 via S10.
**Owns:** `sdk/python/`, `sdk/node/`, `sdk/cli/`

#### (a) Boundary Diagram

```mermaid
flowchart TB
    classDef iface   fill:#dae8fc,stroke:#6c8ebf   %% interfaces (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450   %% violated/missing

    subgraph ClientTier["Client Tier: SDKs & CLI (to-be)"]
        IN19["IN19: UserAPICall\nclient.call() | client.dom.click() |\nclient.linkedin.connect()"]:::iface
        IN20["IN20: CLIInvocation\nzigbrowser-cli method --args |\nzigbrowser-cli --trace id"]:::iface

        C48["C48: NamespaceTranslation\nsnake_case → camelCase\nthin wrappers → call()"]:::contract
        C50["C50: CLITraceHelper\n--trace → telemetry.query\n→ span tree"]:::contract
        C45["C45: ClientFraming\nlength-prefixed JSON-RPC 2.0\nover AF_UNIX"]:::contract
        C46["C46: ErrorMapping\n[-32012,-32001] → AutomationError\nother → ProtocolError"]:::contract
        C47["C47: TraceExposure\ntrace_id, command_id,\ndiagnostics on errors"]:::contract
        C49["C49: EventDispatch\nWS notifications → callbacks\nmulti-listener, dropped if unmatched"]:::contract

        OUT21["OUT21: SDKResult\nparsed dict/object | exception"]:::iface
        OUT22["OUT22: CLIOutput\nJSON | error + trace_id hint"]:::iface
        OUT23["OUT23: SDKEvent\ncallback(params) invocation"]:::iface

        G13["G13: TelemetryQueryMethod\ntelemetry.query not in PRD"]:::gap
        S10["S10: Client→Server"]:::seam
    end

    BC8_ext["BC8: Transport (external)"]

    IN19 --> C48
    IN20 --> C50
    C48 --> C45
    C50 --> C45
    C50 -.- G13
    C45 --> S10
    S10 ---|"IN10/OUT13/EV4"| BC8_ext
    S10 --> C46
    C46 --> C47
    C47 --> OUT21
    C47 --> OUT22
    S10 --> C49
    C49 --> OUT23
```

#### (b) EBNF Grammar

```ebnf
(* ─── Client Tier ─── Interfaces ─── *)

IN19_UserAPICall        ::= SyncCall | AsyncCall | NamespacedCall ;
SyncCall                ::= "client.call(" Method "," Params? ")" ;
AsyncCall               ::= "await client.call(" Method "," Params? ")" ;
NamespacedCall          ::= "client." Namespace "." Verb "(" PythonKwargs ")"
                          | "await client." Namespace "." Verb "(" PythonKwargs ")" ;
Namespace               ::= "dom" | "page" | "cookies" | "social"
                          | "linkedin" | "instagram" ;

IN20_CLIInvocation      ::= "zigbrowser-cli" CLIAction ;
CLIAction               ::= MethodCommand | TraceCommand ;
MethodCommand           ::= Method CLIOption* ;
TraceCommand            ::= "--trace" TraceId ;
CLIOption               ::= "--selector" String | "--timeout-ms" Integer
                          | "--force" | "--trial" ;

OUT21_SDKResult         ::= ParsedResult | RaisedException ;
ParsedResult            ::= JSONValue ;
RaisedException         ::= AutomationError | ProtocolError | ConnectionError ;

OUT22_CLIOutput         ::= SuccessOutput | ErrorOutput ;
SuccessOutput           ::= JSONPrettyPrint ;
ErrorOutput             ::= "Error: " ErrorName " (code " RpcCode ")" NewLine
                            ("  trace_id: " TraceId NewLine)?
                            ("  Debug: zigbrowser-cli --trace " TraceId NewLine)? ;

OUT23_SDKEvent          ::= CallbackInvocation ;
CallbackInvocation      ::= Callback "(" EventParams ")" ;
EventParams             ::= JSONObject ;

(* ─── Client Tier ─── Contracts ─── *)

C45_ClientFraming
    governs: SDK/CLI UDS connection and JSON-RPC message framing
    invariant: 4-byte big-endian length prefix + UTF-8 JSON body
    invariant: matches server-side C21_JSONRPCFrame wire format
    pre:  socket_path points to existing zigBrowser UDS socket
    post: connect() → AF_UNIX socket established
    post: call(method, params) → JSON-RPC request with auto-increment id → response parsed
    post: socket missing → ConnectionError("Cannot connect to zigBrowser socket")
    post: context manager (__enter__/__exit__ / using) auto-connects and disconnects ;

C46_ErrorMapping
    governs: JSON-RPC error response → SDK exception type dispatch
    invariant: code ∈ [-32012, -32001] → AutomationError instance
    invariant: code ∉ [-32012, -32001] → ProtocolError instance
    pre:  parsed JSON-RPC response contains "error" object
    post: AutomationError.from_rpc_error(error_obj) dispatches correctly
    post: all 12 automation codes (-32001..-32012) produce AutomationError
    post: standard JSON-RPC codes (-32700, -32600, -32601, -32602, -32603) → ProtocolError ;

C47_TraceExposure
    governs: AutomationError diagnostic field extraction
    invariant: trace_id and command_id extracted from error.data before diagnostics
    invariant: remaining data fields become diagnostics dict/record
    pre:  error.data may or may not contain trace_id/command_id
    post: err.trace_id = data.pop("trace_id") or None/undefined
    post: err.command_id = data.pop("command_id") or None/undefined
    post: err.diagnostics = remaining data fields after extraction
    post: repr(err)/toString() includes trace_id when present ;

C48_NamespaceTranslation
    governs: SDK high-level method wrapper objects
    invariant: namespace objects are thin delegations to client.call()
    invariant: Python snake_case kwargs → JSON camelCase params
    post: dom.click(selector, timeout_ms=5000)
          → call("dom.click", {"selector": ..., "options": {"timeout_ms": 5000}})
    post: linkedin.connect(profile_url, note="Hi")
          → call("linkedin.connect", {"profileUrl": ..., "note": "Hi"})
    post: DomNamespace, PageNamespace, LinkedInNamespace, InstagramNamespace,
          SocialNamespace, CookiesNamespace constructed in client.__init__ ;

C49_EventDispatch
    governs: WebSocket event notification → SDK callback delivery
    invariant: multiple listeners per event type, all invoked in registration order
    invariant: event with no registered listener → silently dropped (no error)
    invariant: Python: daemon thread reading WS channel; Node: EventEmitter pattern
    pre:  client.on(event_type, callback) registered before event arrives
    post: notification.method matches → callback(notification.params) invoked
    post: connection lost during listen → reconnect with exponential backoff ;

C50_CLITraceHelper
    governs: zigbrowser-cli --trace <trace_id> telemetry lookup
    invariant: queries server via client.call("telemetry.query", {trace_id})
    pre:  ZIGBROWSER_SOCKET env var set and zigBrowser running
    post: trace found → formatted span tree: name, method, duration_ms, error
    post: trace not found → "Trace {trace_id} not found"
    post: no socket env → "Error: ZIGBROWSER_SOCKET not set" ;

(* ─── Client Tier ─── Seam ─── *)

S10_Client_Server
    interfaces: IN19_UserAPICall, IN20_CLIInvocation (client entry),
                IN10_RPCRequest (external/BC8), OUT13_RPCResponse (external/BC8),
                EV4_EventNotification (external/BC8),
                OUT21_SDKResult, OUT22_CLIOutput, OUT23_SDKEvent (client exit)
    contracts:  C45_ClientFraming, C46_ErrorMapping, C47_TraceExposure,
                C21_JSONRPCFrame (external/BC8), C24_UDSOnly (external/BC8) ;

(* ─── Client Tier ─── Gaps ─── *)

G13_TelemetryQueryMethod
    violates: C50_CLITraceHelper (assumes server method that doesn't exist)
    evidence: CLI --trace calls client.call("telemetry.query", {trace_id})
              "telemetry.query" not in BC8 CommandMethod grammar (PRD §3.5)
              not in BC6 AutomationRouter method table
              not in BC11 TelemetrySink interface
    status:   requires either: (a) server-side telemetry.query method added to
              BC6/BC8, or (b) CLI reads local telemetry files directly ;
```

#### (c) Seam Table

| S# | Boundary | Interfaces Crossing | Events Crossing | Contracts Governing |
|---|---|---|---|---|
| S10 | Client Tier → BC8 | IN19, IN20 → serialized as IN10 (BC8); OUT13 (BC8) → parsed as OUT21, OUT22 | EV4 (BC8) → dispatched as OUT23 | C45, C46, C47; C21, C24 (external/BC8) |

---

### Index

#### Context Roster

| Context | Status | Owns | Key Seams |
|---|---|---|---|
| BC10: Social Platform Contracts | To-Be (provisional) | social.zig, linkedin.zig, instagram.zig | S14 → BC6, S15 → BC11 |
| Client Tier: SDKs & CLI | To-Be (new) | sdk/python/, sdk/node/, sdk/cli/ | S10 → BC8 |

#### Context-Map Diagram

```mermaid
flowchart LR
    classDef iface   fill:#dae8fc,stroke:#6c8ebf   %% interfaces (ports)
    classDef contract fill:#d5e8d4,stroke:#82b366  %% contracts
    classDef seam    fill:#fff2cc,stroke:#d6b656   %% seams
    classDef gap     fill:#f8cecc,stroke:#b85450   %% violated/missing

    Client["Client Tier\nPython SDK · Node SDK · CLI"]:::iface
    BC10["BC10: Social Contracts\nsocial.* · linkedin.* · instagram.*"]:::iface
    BC8["BC8: Transport (ext)"]:::seam
    BC6["BC6: Engine (ext)"]:::seam
    BC11["BC11: Observability (ext)"]:::seam
    BC9["BC9: Pacing (ext)"]:::seam

    Client -->|"S10: JSON-RPC over UDS\nIN10↔OUT13, EV4"| BC8
    BC8 -->|"S11: method→router"| BC6
    BC10 -->|"S14: compound→primitive\nIN12/IN18→IN8"| BC6
    BC10 -.->|"S15: EV7 telemetry"| BC11
    BC6 -.->|"S12: pacing queries"| BC9
```

#### Gap/Risk Register

| ID | Severity | Context | Violated / Missing Boundary | Impact | Resolution |
|---|---|---|---|---|---|
| G13 | RISK | Client Tier | C50 CLITraceHelper assumes `telemetry.query` RPC method — not in BC8 CommandMethod grammar or BC6 router | CLI `--trace` feature non-functional until server exposes trace query endpoint | Define `telemetry.query` in BC6/BC8 method grammar, or CLI reads local telemetry files directly |

---

### Acceptance Self-Check

- [x] **Diagram IDs ↔ grammar entries are 1:1** — no orphans
  - BC10: 12 nodes (IN12, IN18, C29, C30, C31, C41, C42, C43, C44, EV7, OUT15, S14) ↔ 12 grammar entries
  - Client Tier: 13 nodes (IN19, IN20, C45, C46, C47, C48, C49, C50, OUT21, OUT22, OUT23, G13, S10) ↔ 13 grammar entries
- [x] **Every contract (C#) names its target** — C29→linkedin.* sequences, C30→instagram.* sequences, C31→login_check gate, C41→pacing delegation, C42→note parameter, C43→URL parameters, C44→compound decomposition, C45→UDS framing, C46→error dispatch, C47→trace exposure, C48→namespace wrappers, C49→event dispatch, C50→CLI trace
- [x] **Every seam (S#) enumerates crossing interfaces and contracts**
  - S14: IN12, IN18, IN8(ext), OUT15, OUT11(ext); EV7→S15; C29, C30, C31, C41, C43, C44
  - S10: IN19, IN20, IN10(ext), OUT13(ext), EV4(ext), OUT21, OUT22, OUT23; C45, C46, C47, C21(ext), C24(ext)
  - S15(ext): EV7; C33(ext)
- [x] **Every context has all three parts** — BC10: diagram ✓ grammar ✓ seam table ✓ | Client Tier: diagram ✓ grammar ✓ seam table ✓
- [x] **Every gap marked with `gap` class** — G13 uses `:::gap` in Client Tier diagram. No gaps in BC10 (all to-be, no violated boundaries)
- [x] **Provisional boundaries labeled** — BC10: provisional (LinkedIn/Instagram split may not warrant sub-contexts until selector maintenance patterns emerge). Client Tier: not provisional (cleanly scoped)
