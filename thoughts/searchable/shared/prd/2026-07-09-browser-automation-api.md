# zigBrowser Automation API — Product Requirements Document

**Date:** 2026-07-09
**Status:** Draft
**Author:** BronzeDesert (SAI Algorithm)
**Research basis:** `thoughts/searchable/shared/research/2026-07-09-browser-automation-api-contracts.md`

---

## 1. Executive Summary

This PRD specifies a Playwright-style automation API for zigBrowser that enables programmatic control of web pages loaded in the browser's native WebView. The API provides guaranteed action contracts (auto-wait, actionability checks, typed errors) exposed via a local JSON-RPC 2.0 server, with an injected selector/action engine running in an isolated JavaScript world.

The primary use case is social media automation (LinkedIn, Instagram) with stealth requirements. zigBrowser's structural advantages — real GPU-rendered WebView, no extension telltales, desktop residential IP, native TLS fingerprint — position it as a superior alternative to extension-based tools (PhantomBuster, Dux-Soup) and headless browsers (Puppeteer, Playwright with Chromium).

---

## 2. Problem Statement & Motivation

### Why now

Social media automation tools fall into two categories, both with critical weaknesses:

1. **Browser extensions** (Dux-Soup, PhantomBuster): Inject via `chrome-extension://` origin, detectable by platforms. Subject to Chrome Web Store policy changes. Cannot survive Chrome Manifest V3 restrictions on background scripts.

2. **Headless browsers** (Puppeteer, Playwright): Set `navigator.webdriver = true`, produce datacenter IP fingerprints, have detectable CDP `Runtime.enable` side effects, and generate synthetic TLS/JA3 fingerprints.

zigBrowser occupies a unique position: a real desktop browser with native WebView rendering that produces authentic fingerprints while offering programmatic control through its existing IPC bridge.

### What this unlocks

- Programmatic control of any web page loaded in zigBrowser
- Social media automation with near-zero detection surface
- Scriptable workflows via Python/Node SDKs and CLI tools
- Automated testing of web applications using the same browser users interact with

---

## 3. Architecture Overview

Three layers, extending the existing `zbHost` IPC bridge (`src/ipc.zig` dispatch + platform shims):

```
┌──────────────────────────────────────────────────────────────┐
│  LAYER 3: EXTERNAL API                                        │
│  JSON-RPC 2.0 over Unix domain socket                         │
│  Clients: Python scripts, Node SDK, CLI tools                 │
│  Event push: WebSocket channel on same socket                 │
├──────────────────────────────────────────────────────────────┤
│  LAYER 2: AUTOMATION ENGINE                                   │
│  Zig-side: command queue, timeout/retry logic, state machine  │
│  Extends: src/ipc.zig dispatch table                          │
│  Error taxonomy: 12 typed AutomationError cases               │
├──────────────────────────────────────────────────────────────┤
│  LAYER 1: INJECTED SCRIPT                                     │
│  JS in isolated world: selectors, actionability checks,       │
│  DOM interaction, event synthesis, wait primitives             │
│  Injected via platform-specific isolated-world mechanisms     │
└──────────────────────────────────────────────────────────────┘
```

### Integration with existing architecture

The current `src/ipc.zig` dispatch function uses `std.mem.eql` string matching on `cmd` field, with JSON `args`. Current verbs: `ping`, `add`, `echo`, `os.info`. The automation API adds new verb namespaces (`dom.*`, `page.*`, `cookies.*`, `session.*`) following the same pattern.

The existing `zbHost` script message handler in `webkit_shim.c` (line 530-608) provides the JS-to-native bridge. The automation engine uses the reverse path: Zig evaluates JavaScript in the WebView via platform-specific evaluation APIs.

**⚠️ Phase 1 prerequisite — IPC result buffer ceiling.** The current `zb_ipc_dispatch` C export (`src/ipc.zig:13`) uses a threadlocal `dispatch_result_cstr: [4096]u8` static buffer. Any result exceeding 4095 bytes (before nul terminator) triggers a `BadArgs` error via `copyToCStr` failure (line 66-70). This ceiling will be hit immediately by `dom.query` (multiple elements with bounding boxes), `page.evaluate` (page content), and `page.screenshot` (base64 data). **Fix required before any automation command can ship:** switch from the static threadlocal buffer to dynamic allocation with the result pointer valid until the next call (same lifetime contract, heap-backed). The 64KB scratch allocator (`dispatch_scratch: [65536]u8`, line 12) may also need growth for complex automation results.

---

## 4. Layer 1: Injected Automation Script

A single JavaScript file injected at `document-start` in an **isolated script world** — not the page's global context. This is invisible to anti-bot scripts that enumerate `window` properties.

### 4.1 Platform Injection Mechanisms

| Platform | API | Isolation Method |
|---|---|---|
| **Linux** (WebKitGTK) | `webkit_user_content_manager_add_script()` | Named `world_name` parameter |
| **Windows** (WebView2) | `AddScriptToExecuteOnDocumentCreatedAsync()` | IIFE scope (no named worlds) |
| **macOS** (WKWebView) | `WKUserScript` initializer | `WKContentWorld` named world |

All three mechanisms inject before any page script executes and run in a context inaccessible to the page's JavaScript.

### 4.2 Selector Engine

The selector engine resolves elements using prefixed string syntax compatible with Playwright conventions:

| Prefix | Syntax Example | Resolution |
|---|---|---|
| `role=` | `role=button[name="Like"]` | ARIA role + accessible name (most stable for social media) |
| `testid=` | `testid=send-message-btn` | `data-testid` attribute |
| `text=` | `text=Follow` | Visible text content (exact or substring) |
| `css=` | `css=[aria-label="Comment"]` | Standard CSS selector |
| `xpath=` | `xpath=//div[@data-section="messages"]` | XPath expression (last resort) |

**Priority for social media platforms** (obfuscated class names): `role=` > `testid=` > `text=` > `css=` with semantic anchors > `xpath=`.

**Rationale for Playwright-compatible strings over structured JSON:** String selectors are parsed in the injected JS layer (Layer 1), not in Zig (Layer 2). Zig passes the selector string opaquely. This means zero Zig parsing complexity, familiar syntax for Playwright/Puppeteer users, and a trivial JS parser (~50 lines of prefix matching). The JSON-RPC params use JSON for everything except the selector value itself.

### 4.3 Actionability Checks

Before executing any mutating action, the engine verifies the target element passes all applicable checks:

| Check | Definition | Actions requiring it |
|---|---|---|
| **Attached** | Element is connected to the DOM | All |
| **Visible** | Element has non-zero bounding box, `visibility` is not `hidden`, `opacity` > 0 | click, fill, type, hover, select |
| **Stable** | Bounding box identical across 2 consecutive animation frames | click, fill |
| **ReceivesEvents** | Element is the hit-test target at its bbox center (not obscured) | click |
| **Enabled** | Not `disabled` and not `aria-disabled="true"` | click, fill, type, select |
| **Editable** | Not `readonly` and not `aria-readonly="true"` | fill, type |

### 4.4 DOM Actions

| Action | Mechanism | Events Dispatched |
|---|---|---|
| **click** | Compute bbox center → synthesize MouseEvent sequence (mousedown, mouseup, click) | pointerdown, mousedown, pointerup, mouseup, click |
| **fill** | Focus element → clear value → set new value → dispatch events | focus, input (insertText), change |
| **type** | Per-keystroke: focus → for each char: keydown, input (insertText), keyup | keydown, input, keyup per character |
| **select** | Match `<option>` by value/label → set `selectedIndex` → dispatch change | change |
| **check/uncheck** | Click if current state differs from desired state | Same as click |
| **hover** | Move pointer to element bbox center | pointerenter, mouseenter, pointermove, mousemove |
| **scroll** | ScrollIntoView with behavior option | scroll |

### 4.5 Wait Primitives

| Primitive | Behavior |
|---|---|
| **waitForSelector** | Poll DOM until selector matches element in specified state (`attached`, `visible`, `hidden`, `detached`). Reject after `timeout_ms`. |
| **waitForNavigation** | State machine: monitors `readystatechange`, `load`, and network activity. Terminal states: `load` (default), `domcontentloaded`, `networkidle`. |
| **waitForNetworkIdle** | Track in-flight requests. Resolve when 0 requests pending for 500ms (configurable). Uses `PerformanceObserver` with `resource` entry type. |

---

## 5. Layer 2: Automation Engine (Zig IPC)

Extends `src/ipc.zig` with new command verb namespaces. Every command follows the guaranteed contract pattern.

### 5.1 Command Verbs

#### DOM Commands

| Command | Request | Response |
|---|---|---|
| `dom.query` | `{ selector, timeout_ms? }` | `{ elements: [{id, tag, text, bbox}] }` |
| `dom.click` | `{ selector, options? }` | `{ ok: true }` or `AutomationError` |
| `dom.fill` | `{ selector, value, options? }` | `{ ok: true }` or `AutomationError` |
| `dom.type` | `{ selector, text, delay_ms? }` | `{ ok: true }` or `AutomationError` |
| `dom.getText` | `{ selector }` | `{ text: string }` |
| `dom.getAttribute` | `{ selector, name }` | `{ value: string \| null }` |
| `dom.waitFor` | `{ selector, state?, timeout_ms? }` | `{ ok: true }` or `TimeoutError` |

#### Page Commands

| Command | Request | Response |
|---|---|---|
| `page.navigate` | `{ url, waitUntil? }` | `{ ok: true }` or `NavigationError` |
| `page.reload` | `{ waitUntil? }` | `{ ok: true }` |
| `page.url` | `{}` | `{ url: string }` |
| `page.title` | `{}` | `{ title: string }` |
| `page.evaluate` | `{ expression }` | `{ result: any }` |
| `page.screenshot` | `{ path?, fullPage? }` | `{ data: base64 }` |

#### Cookie Commands

| Command | Request | Response |
|---|---|---|
| `cookies.getAll` | `{ url? }` | `{ cookies: [{name, value, domain, path, expires, httpOnly, secure}] }` |
| `cookies.set` | `{ name, value, domain, path?, expires?, httpOnly?, secure? }` | `{ ok: true }` |
| `cookies.delete` | `{ name, domain }` | `{ ok: true }` |

#### Session Commands

| Command | Request | Response |
|---|---|---|
| `session.status` | `{}` | `{ loggedIn: bool, platform: string, user?: string }` |

### 5.2 Guaranteed Contract Pattern

Every mutating action follows this lifecycle:

```
1. Receive command: { selector, timeout_ms (default 30000), force?, trial? }
2. Enter retry loop (poll every 16ms — animation-frame cadence):
   a. Resolve selector → element (or ElementNotFound after timeout)
   b. Run actionability checks for this action type
   c. If all checks pass OR force=true: execute action
   d. If trial=true: return success without executing (dry run)
3. Return Result<T, AutomationError>
```

The 16ms polling interval aligns with requestAnimationFrame cadence (60fps). This ensures actions execute at the earliest possible frame after the element becomes actionable, without busy-waiting.

**`force` option:** Bypasses actionability checks. Use when you know the element state is acceptable despite failing a check (e.g., clicking a partially obscured element).

**`trial` option:** Runs all checks but does not execute the action. Use for pre-validation without side effects.

### 5.3 Error Taxonomy

```zig
const AutomationError = enum {
    element_not_found,        // selector matched 0 elements within timeout
    element_not_visible,      // element matched but not visible
    element_not_stable,       // element bbox changing between frames
    element_obscured,         // another element at hit-test point
    element_disabled,         // disabled or aria-disabled="true"
    element_not_editable,     // readonly or aria-readonly="true"
    navigation_timeout,       // page load exceeded timeout
    navigation_failed,        // DNS, network, or blocked error
    action_timeout,           // generic timeout wrapper
    platform_rate_limited,    // detected rate-limit UI signal or 429
    session_invalid,          // not logged in or session expired
    cancelled,               // caller aborted the command
};
```

Each error variant maps to a specific JSON-RPC error code in the -32001 to -32012 range for programmatic handling by SDK clients.

### 5.4 Command Queue

- One queue per page/tab, strictly serialized
- Commands process one at a time, including their retry loops
- No concurrent actions against the same page
- Commands against different pages may execute in parallel

This serialization prevents race conditions from overlapping DOM mutations and matches the mental model of sequential user interaction.

---

## 6. Layer 3: External API

### 6.1 Transport

**Primary: Unix domain socket with JSON-RPC 2.0.**

Socket path: `$XDG_RUNTIME_DIR/zigbrowser-automation.sock` (Linux/macOS) or `%LOCALAPPDATA%\zigbrowser\automation.sock` (Windows).

UDS provides zero network exposure — the socket is protected by filesystem permissions and is invisible to network scanners. This is critical for a tool handling social media credentials.

**Decision: UDS-only, no TCP fallback.** Council analysis determined that Zig's `std.net` supports AF_UNIX on Windows 10 1803+, eliminating the primary argument for TCP. A single transport means one code path, one security model, and no port-scanning detection vector. A spike to confirm AF_UNIX behavior on Windows in Zig should precede implementation.

**Event push:** WebSocket upgrade on the same Unix socket. Delivers asynchronous notifications:

```json
{"jsonrpc": "2.0", "method": "event.navigation", "params": {"state": "network_idle", "url": "https://linkedin.com/messaging"}}
{"jsonrpc": "2.0", "method": "event.rate_limit", "params": {"platform": "linkedin", "signal": "modal", "text": "You've reached the weekly invitation limit"}}
{"jsonrpc": "2.0", "method": "event.session", "params": {"platform": "linkedin", "loggedIn": false}}
```

### 6.2 Wire Protocol

JSON-RPC 2.0 with standard request/response/notification semantics:

```json
// Request
{
  "jsonrpc": "2.0",
  "method": "dom.click",
  "params": {
    "selector": "role=button[name='Connect']",
    "options": {"timeout_ms": 5000}
  },
  "id": 1
}

// Success
{"jsonrpc": "2.0", "result": {"ok": true}, "id": 1}

// Error
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32001,
    "message": "element_not_found",
    "data": {"selector": "role=button[name='Connect']", "timeout_ms": 5000}
  },
  "id": 1
}
```

### 6.3 Activation

- CLI flag: `zigbrowser --automation-api` starts the UDS listener alongside the browser
- The socket file is created on startup and removed on clean shutdown
- Multiple browser instances use distinct socket paths (append PID or random suffix)
- Socket filename is randomized to avoid enumeration by other local processes

---

## 7. Anti-Detection Architecture

### 7.1 Structural Advantages (inherent to zigBrowser)

| Property | Why it matters |
|---|---|
| Real GPU-rendered WebView | Clean `canvas.toDataURL()` and WebGL fingerprint |
| No browser extension | No `chrome-extension://` origin in `performance.getEntries()` |
| Desktop residential IP | Not flagged by datacenter IP blocklists |
| No `navigator.webdriver` | Not controlled via WebDriver protocol |
| Native OS TLS stack | Authentic JA3/JA4 fingerprint matching the OS browser |

### 7.2 Stealth Design Choices

1. **Isolated script world injection** — page scripts cannot enumerate automation globals via `Object.keys(window)` or prototype chain walking
2. **No `Runtime.enable` on WebView2** — use only Input, DOM, and Network CDP domains. `Runtime.enable` has detectable side effects (see rebrowser.net research)
3. **OS-level input dispatch** where available — CDP `Input.dispatchMouseEvent`/`dispatchKeyEvent` on WebView2 produces OS-level input events, harder to distinguish from human input than synthetic JS `MouseEvent`
4. **Minimal injected footprint** — clean up MutationObservers, IntersectionObservers, and PerformanceObservers after each operation. No persistent DOM modifications.

### 7.2.1 Known Risk: Isolated-World Leakage

**⚠️ Open risk (Council, Sentinel R2-R3).** Isolated script worlds share the DOM with the page context. This creates detectable side-channels:

- **Timing artifacts:** Automation operations that touch the DOM (querySelector, setAttribute, event dispatch) produce timing signatures detectable via `PerformanceObserver` or `requestAnimationFrame` cadence analysis from the page context.
- **Prototype pollution detection:** If the injected script modifies DOM prototypes (e.g., overriding `addEventListener`), the page context can detect the modification.
- **Observer interference:** MutationObservers set from the page context will fire on DOM changes made by the injected script, revealing automation activity.

**Mitigation strategy:** Minimize DOM surface touched by the injected script. Prefer reading over writing. Clean up all observers synchronously. Use `requestAnimationFrame`-aligned operations to blend with rendering cadence. This is an ongoing hardening concern — vendors don't currently check for isolated-world leakage, but detection techniques will evolve.

**Revisit trigger:** Any social media platform deploying timing-based or prototype-chain detection should trigger a hardening sprint on the injected script isolation layer.

### 7.3 Behavioral Simulation

The behavioral layer is the most critical for evading social media detection, which increasingly relies on interaction pattern analysis over technical signals.

**Typing simulation:**
- Per-keystroke dispatch with Gaussian-distributed inter-key delays
- Mean: 120ms, standard deviation: 40ms, range clamped to 80-200ms
- Occasional longer pauses (300-600ms) at word boundaries
- Configurable per-platform profiles

**Click simulation:**
- Mouse movement from current position to target using Bezier curve interpolation
- Natural arc with slight overshoot and correction
- Movement duration proportional to distance (Fitts's law)
- Randomized dwell time at target before click (50-150ms)

**Scrolling:**
- Variable scroll speed with momentum simulation
- Pauses at content boundaries (post edges, section breaks)
- Occasional reverse scroll (reading behavior)

**Session behavior:**
- Randomized session duration with configurable mean/deviation
- Scheduled breaks (5-15 minutes) after sustained activity periods
- Warmup period at session start: passive browsing before automation actions

### 7.4 Rate Limiting & Pacing

Per-platform daily action caps, configurable via the `social.set_pacing` command:

| Parameter | Default | Description |
|---|---|---|
| `min_delay_ms` | 3000 | Minimum delay between consecutive actions |
| `max_delay_ms` | 8000 | Maximum delay between consecutive actions |
| `daily_cap` | 100 | Maximum actions per calendar day |

Delay between actions is drawn uniformly from `[min_delay_ms, max_delay_ms]`. The daily cap is tracked per platform and resets at midnight local time.

**Rate-limit detection (DOM-based):** Monitor for platform-specific signals:
- Error modals ("You've reached your weekly invitation limit")
- Toast notifications ("Action blocked")
- Redirect to challenge/captcha pages
- HTTP error pages rendered in the DOM

Network-level 429 detection is deferred (see Decision ADR-3). A `NetworkInterceptor` interface (vtable-style, ~50 lines of Zig) is defined on day one with a stub implementation on Linux/macOS and a functional implementation on WebView2 via `AddWebResourceRequestedFilter`.

---

## 8. Social Media Platform Contracts

Platform-specific command namespaces built on top of the generic automation engine. Each compound action is a sequence of `dom.*` and `page.*` primitives with platform-specific selectors and pacing.

### 8.1 LinkedIn Actions

| Command | Parameters | Behavior |
|---|---|---|
| `linkedin.connect` | `{ profileUrl, note? }` | Navigate to profile → click Connect → optionally add note → confirm |
| `linkedin.message` | `{ conversationUrl \| profileUrl, text }` | Open conversation or profile → compose message → send |
| `linkedin.like` | `{ postUrl }` | Navigate to post → click Like button |
| `linkedin.comment` | `{ postUrl, text }` | Navigate to post → click Comment → type text → submit |
| `linkedin.visit` | `{ profileUrl }` | Navigate to profile (triggers "viewed your profile" notification) |
| `linkedin.search` | `{ query, filters? }` | Execute search with optional filters → return results |
| `linkedin.extract` | `{ profileUrl }` | Navigate to profile → extract structured data (name, headline, company, etc.) |

### 8.2 Instagram Actions

| Command | Parameters | Behavior |
|---|---|---|
| `instagram.follow` | `{ profileUrl }` | Navigate to profile → click Follow |
| `instagram.like` | `{ postUrl }` | Navigate to post → double-click or click heart |
| `instagram.comment` | `{ postUrl, text }` | Navigate to post → click comment field → type → submit |
| `instagram.dm` | `{ username, text }` | Open DM thread → compose → send |
| `instagram.story_view` | `{ username }` | Navigate to user's story → view sequentially |

### 8.3 Generic Platform Commands

Base contract available for all platforms:

| Command | Request | Response |
|---|---|---|
| `social.login_check` | `{}` | `{ loggedIn: bool, platform: string, username?: string }` |
| `social.rate_status` | `{}` | `{ remaining_actions: int, reset_at: string, daily_cap: int }` |
| `social.pause` | `{ duration_ms }` | `{ ok: true }` (blocks command queue for duration) |
| `social.set_pacing` | `{ min_delay_ms, max_delay_ms, daily_cap }` | `{ ok: true }` |

---

## 9. Platform-Specific Implementation

### 9.1 Linux (WebKitGTK)

**Approach: Custom JS injection** (not WebKitAutomationSession).

WebKitAutomationSession sets `navigator.webdriver = true` — a hard blocker for social media automation. Custom JS injection via `webkit_user_content_manager_add_script()` with a named `world_name` provides full control without detection signals.

| Capability | Implementation |
|---|---|
| Script injection | `webkit_user_content_manager_add_script()` with named world |
| JS evaluation | `webkit_web_view_evaluate_javascript()` with same world name |
| Cookie management | `WebKitCookieManager` via `webkit_web_context_get_cookie_manager()` |
| Input dispatch | Synthetic JS events (no CDP available) |
| Network interception | Deferred — requires WebKit Web Extension (shared library in renderer process). `NetworkInterceptor` interface stubbed with "not supported" |

### 9.2 Windows (WebView2)

**Approach: Hybrid — custom JS injection + selective in-process CDP.**

WebView2 offers the richest automation surface. Use CDP domains selectively (Input, DOM, Network) without enabling Runtime (which is detectable).

| Capability | Implementation |
|---|---|
| Script injection | `AddScriptToExecuteOnDocumentCreatedAsync()` in IIFE scope |
| JS evaluation | `ExecuteScriptAsync()` |
| Cookie management | `CoreWebView2.CookieManager` (preferred) or CDP `Network.getAllCookies/setCookie` |
| Input dispatch | CDP `Input.dispatchMouseEvent`/`dispatchKeyEvent` (OS-level, less detectable) |
| Network interception | `AddWebResourceRequestedFilter` — full `NetworkInterceptor` implementation |

**Critical constraints:**
- NEVER open `--remote-debugging-port` (network-visible detection signal)
- NEVER call `Runtime.enable` globally (detectable side effect — see rebrowser.net)
- Use `CallDevToolsProtocolMethodAsync` for in-process CDP only

### 9.3 macOS (WKWebView)

**Approach: Pure JS-based automation** (most limited platform).

WKWebView offers no CDP, no network interception, and no native automation protocol. All automation runs through JavaScript evaluation and message handlers.

| Capability | Implementation |
|---|---|
| Script injection | `WKUserScript` with `WKContentWorld` named world |
| JS evaluation | `evaluateJavaScript(_:in:in:completionHandler:)` in content world |
| Cookie management | `WKHTTPCookieStore` only (NOT `NSHTTPCookieStorage`) |
| Input dispatch | Synthetic JS events only (no CDP alternative) |
| Network interception | Not available — `NetworkInterceptor` stubbed |

**Session sharing:** Must share `WKProcessPool` and `WKWebsiteDataStore` across windows for consistent session state.

---

## 10. Architecture Decision Records

### ADR-1: Transport — UDS Only

**Decision:** Unix domain socket only. No TCP loopback fallback.

**Context:** The automation API handles social media credentials and session tokens. TCP loopback (127.0.0.1) is visible to local port scanners and other applications. UDS is protected by filesystem permissions.

**Trade-offs:**
| Factor | UDS | TCP |
|---|---|---|
| Security | Filesystem permissions, invisible to network | Visible to local processes, needs auth token |
| Windows support | AF_UNIX available in Win10 1803+ via Zig's `std.net` | Universal |
| Client compatibility | Python/Node/Go/Rust all support UDS | Universal |
| Complexity | Single code path | Dual transport, dual auth |

**Action required:** Spike AF_UNIX on Windows in Zig to confirm behavior before implementation commitment. If AF_UNIX proves unreliable on Windows, revisit with TCP + per-session bearer token as fallback.

**Consequence:** Randomize socket filename to prevent enumeration by other local processes. Require a per-session token handshake on connect — even with UDS filesystem permissions, a token prevents accidental cross-process attachment.

**Council consensus (4/4 agents, R3):** TCP was unanimously rejected as a detection surface. Port-scanning browser extensions, local AV/EDR, and forensic tooling can enumerate listening TCP sockets. AF_UNIX on Windows via Zig `std.net` eliminates the only argument for TCP.

### ADR-2: WebKitGTK Backend — Custom JS Injection

**Decision:** Custom JS injection via isolated script world. Do not use WebKitAutomationSession.

**Context:** `WebKitAutomationSession` sets `navigator.webdriver = true` in WebCore with no configuration override. This is an instant detection signal on every social media platform.

**Consequence:** Same architectural approach (custom JS) on all three platforms, improving consistency and reducing divergence in the automation engine. Higher initial implementation effort, but the stealth requirement is non-negotiable.

**Council consensus (4/4 agents, R1):** Unanimous from round 1. Sentinel deepened the analysis: `WebKitAutomationSession` doesn't just set `navigator.webdriver` — it flips WebKit's internal "automation mode" IPC flag, changes accessibility-tree exposure, alters process spawn behavior, and shifts event-dispatch timing. These are all fingerprintable server-side or via JS timing probes, independent of the `navigator.webdriver` property.

### ADR-3: Network Interception — Deferred with Interface

**Decision:** Define a `NetworkInterceptor` interface (Zig vtable-style, ~50 lines) on day one. Implement on WebView2 via `AddWebResourceRequestedFilter`. Stub on Linux and macOS.

**Context:** Network interception on WebKitGTK requires a separate shared library (Web Extension) loaded into the renderer process — significant complexity. On macOS WKWebView, it's impossible. DOM-based rate-limit detection (watching for error modals, toast notifications, challenge pages) covers 90%+ of social media rate-limit scenarios.

**Trade-off:** May miss server-side 429s that don't surface in DOM. Mitigated by conservative pacing defaults that make hitting rate limits unlikely. The interface allows platform-specific implementations to be added later without architectural changes.

**⚠️ Tracked security debt (Council, Sentinel R3):** Silent throttling — 429s on background XHR/GraphQL, WebSocket-delivered soft-bans, and shadow-rate-limiting — is the primary failure mode for LinkedIn-class targets. Accounts get burned invisibly because shadowbans don't change the user's own UI. DOM-based detection cannot see this. The Linux/macOS `NetworkInterceptor` stubs must be logged as tracked security debt with a revisit trigger, not treated as parity with the WebView2 implementation. LinkedIn messaging uses WebSockets; silent throttling on that channel is undetectable without network-level visibility.

### ADR-4: Selector Syntax — Playwright-Compatible Strings

**Decision:** Playwright-compatible prefix strings (`role=`, `text=`, `css=`, `testid=`, `xpath=`), parsed in the injected JS layer.

**Context:** String selectors are parsed in JavaScript (Layer 1), not Zig (Layer 2). Zig passes the selector string opaquely through IPC. This eliminates Zig-side parsing complexity. Playwright/Puppeteer users already know this syntax. No structured JSON alternative — it doubles API surface for zero benefit.

### ADR-5: Initial Scope — Generic Core + LinkedIn First + Test Fixture

**Decision:** Build the generic automation engine (Layers 1-3) first. Validate with LinkedIn as the first platform-specific contract. Develop a static test fixture server in parallel for CI and cross-platform testing.

**Context:** The three-layer architecture is inherently platform-agnostic — `dom.click`, `page.navigate` don't know about LinkedIn. LinkedIn shapes the platform contract layer, but a deterministic test fixture (complex enough for dynamic DOM patterns — modals, lazy loading, infinite scroll) enables testing without credentials and across all three platforms.

**Validation sequence (Council consensus, R3):** Static test fixture first → LinkedIn second. The fixture establishes a clean baseline so that failures against LinkedIn can be attributed to platform defenses vs. engine bugs. Without this separation, debugging is ambiguous — you can't tell if a failure is your selector engine or LinkedIn's detection.

**Consequence:** Detection vs. behavioral diagnostic logging added from day one to diagnose anti-bot responses during LinkedIn development.

---

## 11. Implementation Roadmap

### Phase 1: Core Automation Engine
**Scope:** Generic Layer 1 + Layer 2
**Dependencies:** None (extends existing `src/ipc.zig`)

- Extend `src/ipc.zig` dispatch with `dom.*` and `page.*` command namespaces
- Build the injected selector/action script (single JS file)
- Implement the actionability check loop with 16ms polling and configurable timeout
- Define the `AutomationError` enum with all 12 error cases
- Implement command queue (one-per-page serialization)
- Build the test fixture server for deterministic validation

### Phase 2: External API
**Scope:** Layer 3
**Dependencies:** Phase 1 (needs commands to expose)

- JSON-RPC 2.0 server over Unix domain socket
- WebSocket event push channel on the same socket
- CLI flag activation (`--automation-api`)
- Socket lifecycle management (create on start, remove on shutdown)
- AF_UNIX Windows spike (prerequisite from ADR-1)

### Phase 3: Platform-Specific Input
**Scope:** Platform optimizations
**Dependencies:** Phase 1 (needs basic automation working)

- WebView2: In-process CDP `Input.dispatchMouseEvent`/`dispatchKeyEvent`
- WebView2: `AddWebResourceRequestedFilter` (full `NetworkInterceptor`)
- WebKitGTK: JS-based synthetic events (baseline from Phase 1)
- WKWebView: JS-based synthetic events (baseline from Phase 1)
- `NetworkInterceptor` interface definition + platform stubs

### Phase 4: Anti-Detection & Pacing
**Scope:** Behavioral simulation layer
**Dependencies:** Phase 3 (needs input dispatch working)

- Gaussian typing delay distribution
- Bezier mouse movement curves
- Per-platform rate limiting with daily caps
- Session behavior simulation (warmup, breaks, duration randomization)
- DOM-based rate-limit detection
- Detection diagnostic logging

### Phase 5: Platform SDKs & Social Contracts
**Scope:** Client libraries + social media contracts
**Dependencies:** Phase 2 (needs external API) + Phase 4 (needs pacing)

- Python SDK (primary — social media automation community uses Python)
- Node.js SDK
- CLI tool for scripting and debugging
- LinkedIn platform contract (first social media target)
- Instagram platform contract
- Generic `social.*` base commands

### Phase Dependencies

```
Phase 1 ──→ Phase 2 ──→ Phase 5
   │                       ↑
   └──→ Phase 3 ──→ Phase 4 ┘
```

Phases 2 and 3 can proceed in parallel after Phase 1. Phase 4 depends on Phase 3. Phase 5 depends on both Phase 2 (external API) and Phase 4 (pacing/anti-detection).

---

## 12. Success Metrics

| Metric | Target | Measurement |
|---|---|---|
| LinkedIn connection acceptance rate | >90% (matching manual) | A/B test: automated vs. manual |
| Detection rate | <1% account restrictions per 1000 actions | Track restriction events over time |
| Cross-platform parity | All `dom.*`/`page.*` commands work on 3 platforms | E2E test suite per platform |
| Action reliability | >99% success rate for non-rate-limited actions | Track AutomationError rates |
| SDK adoption | Python SDK installable via pip, <5 min to first script | User testing |

---

## 13. Open Questions

1. **Cookie encryption at rest:** Should automation sessions encrypt stored cookies? Social media session tokens are high-value targets.
2. **Multi-tab orchestration:** Should the API support coordinating actions across multiple tabs (e.g., monitoring a feed in one tab while messaging in another)?
3. **Proxy integration:** Should zigBrowser support SOCKS5/HTTP proxy configuration for IP rotation? This would extend anti-detection beyond residential IP.
4. **TikTok and Facebook contracts:** Deferred from initial scope. What priority relative to LinkedIn and Instagram?
5. **Headless mode:** Should zigBrowser support a headless rendering mode for server-side automation? This would sacrifice the "desktop context" advantage but enable scaling.

---

## Appendix A: Error Code Mapping

| AutomationError | JSON-RPC Code | HTTP Analogy |
|---|---|---|
| `element_not_found` | -32001 | 404 |
| `element_not_visible` | -32002 | 409 |
| `element_not_stable` | -32003 | 409 |
| `element_obscured` | -32004 | 409 |
| `element_disabled` | -32005 | 403 |
| `element_not_editable` | -32006 | 403 |
| `navigation_timeout` | -32007 | 504 |
| `navigation_failed` | -32008 | 502 |
| `action_timeout` | -32009 | 504 |
| `platform_rate_limited` | -32010 | 429 |
| `session_invalid` | -32011 | 401 |
| `cancelled` | -32012 | 499 |

## Appendix B: References

- Playwright actionability: https://playwright.dev/docs/actionability
- WebView2 CDP in-process: https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/chromium-devtools-protocol
- WebKitGTK automation: https://blogs.igalia.com/carlosgc/2017/09/09/webdriver-support-in-webkitgtk-2-18/
- CDP detection research: https://rebrowser.net/blog/how-to-fix-runtime-enable-cdp-detection-of-puppeteer-playwright-and-other-automation-libraries
- Tauri WebDriver (WKWebView reference): https://github.com/danielraffel/tauri-webdriver
