# zigBrowser Automation API — Research Synthesis

**Date:** 2026-07-09
**Goal:** Design an automation API for zigBrowser that enables controlling social media platforms (LinkedIn, Instagram, TikTok, Facebook) loaded inside the browser, with guaranteed contracts.

---

## Executive Summary

zigBrowser is already architecturally positioned for this. The existing `zbHost` IPC bridge (`src/ipc.zig` dispatch + platform shims) is the exact seam to extend. The recommended architecture is a **Playwright-style action contract** (auto-wait + actionability checks + typed errors) exposed via a **local JSON-RPC server** (Unix socket or loopback HTTP), with an **injected selector/action engine** running in an isolated JS world inside each WebView.

Key structural advantages over competitors (PhantomBuster, Dux-Soup):
- Real GPU-rendered WebView = clean canvas/WebGL fingerprint
- No extension-manifest telltales (no `chrome-extension://` origin)
- Desktop/residential IP context (not datacenter)
- No detectable CDP `Runtime.enable` side effects (use in-process CDP selectively on WebView2)

---

## Architecture: Three Layers

```
┌─────────────────────────────────────────────────────────────┐
│  EXTERNAL API (Layer 3)                                      │
│  JSON-RPC over Unix socket / 127.0.0.1 loopback             │
│  Clients: Python scripts, Node SDK, CLI tools                │
├─────────────────────────────────────────────────────────────┤
│  AUTOMATION ENGINE (Layer 2)                                 │
│  Zig-side: command queue, timeout/retry logic, state machine │
│  Extends: src/ipc.zig dispatch table                         │
├─────────────────────────────────────────────────────────────┤
│  INJECTED SCRIPT (Layer 1)                                   │
│  JS in isolated world: selectors, actionability checks,      │
│  DOM interaction, event synthesis                            │
│  Injected via: WKUserScript / WebKitUserScript /             │
│               AddScriptToExecuteOnDocumentCreated            │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Injected Automation Script

A single JS file injected at `document-start` in an **isolated script world** (not the page's global context). This avoids polluting `window` and is invisible to anti-bot scripts that enumerate globals.

### Platform injection mechanisms:
| Platform | Mechanism | Isolation |
|---|---|---|
| Linux (WebKitGTK) | `webkit_user_content_manager_add_script()` with `world_name` | Named world |
| Windows (WebView2) | `AddScriptToExecuteOnDocumentCreatedAsync()` + IIFE | IIFE scope |
| macOS (WKWebView) | `WKUserScript` with `WKContentWorld` | Content world |

### Capabilities the injected script provides:
- **Selector engine**: resolves `role=`, `text=`, `css=`, `testid=`, `xpath=` prefixed selectors
- **Actionability checks**: Attached, Visible, Stable (2 consecutive frames same bbox), ReceivesEvents (hit-test), Enabled, Editable
- **DOM actions**: click (synthetic MouseEvent at bbox center), fill (focus + set value + input/change events), type (per-keystroke InputEvent), select, check/uncheck, hover, scroll
- **Queries**: querySelector, querySelectorAll, textContent, innerHTML, attribute reads, bounding box
- **Wait primitives**: waitForSelector, waitForNavigation (state machine), waitForNetworkIdle

### Selector Priority (for social media platforms with obfuscated classes):
1. `role=button[name="Like"]` — ARIA role + accessible name (most stable)
2. `testid=send-message-btn` — `data-testid` attributes (when available)
3. `text=Follow` — visible text content
4. `css=[aria-label="Comment"]` — CSS with semantic anchors
5. `xpath=//div[@data-section="messages"]` — last resort

---

## Layer 2: Automation Engine (Zig-side)

Extends `src/ipc.zig` with new command verbs. Each command follows the contract:

### Command Dispatch (new verbs in `ipc.zig`):

```
dom.query       { selector, timeout_ms? }          -> { elements: [{id, tag, text, bbox}] }
dom.click       { selector, options? }              -> { ok: true } | AutomationError
dom.fill        { selector, value, options? }       -> { ok: true } | AutomationError
dom.type        { selector, text, delay_ms? }       -> { ok: true } | AutomationError
dom.getText     { selector }                        -> { text: string }
dom.getAttribute { selector, name }                 -> { value: string | null }
dom.waitFor     { selector, state?, timeout_ms? }   -> { ok: true } | TimeoutError

page.navigate   { url, waitUntil? }                -> { ok: true } | NavigationError
page.reload     { waitUntil? }                     -> { ok: true }
page.url        {}                                 -> { url: string }
page.title      {}                                 -> { title: string }
page.evaluate   { expression }                     -> { result: any }
page.screenshot { path?, fullPage? }               -> { data: base64 }

cookies.getAll  { url? }                           -> { cookies: [...] }
cookies.set     { name, value, domain, ... }       -> { ok: true }
cookies.delete  { name, domain }                   -> { ok: true }

session.status  {}                                 -> { loggedIn, platform, user? }
```

### Guaranteed Contract Pattern:

Every mutating action follows this lifecycle:
```
1. Receive command with { selector, timeout_ms (default 30000), force, trial }
2. Enter retry loop (poll every 16ms / animation-frame cadence):
   a. Resolve selector -> element (or ElementNotFound after timeout)
   b. Run actionability checks for this action type
   c. If all pass OR force=true: execute action
   d. If trial=true: return success without executing
3. Return Result<T, AutomationError>
```

### Error Taxonomy (Zig error set):

```zig
const AutomationError = enum {
    element_not_found,        // selector matched 0 elements within timeout
    element_not_visible,      // matched but not visible
    element_not_stable,       // bbox changing between frames
    element_obscured,         // another element at hit point
    element_disabled,         // disabled or aria-disabled
    element_not_editable,     // readonly or aria-readonly
    navigation_timeout,       // page load exceeded timeout
    navigation_failed,        // DNS/network/blocked error
    action_timeout,           // generic timeout wrapper
    platform_rate_limited,    // detected rate-limit UI/429
    session_invalid,          // not logged in / session expired
    cancelled,               // caller aborted
};
```

### Command Queue:
- One queue per page/tab, strictly serialized
- Commands process one at a time (including their retry loops)
- No concurrent actions against the same page

---

## Layer 3: External API

### Transport Options (ranked):

| Transport | When to use |
|---|---|
| **Unix domain socket + JSON-RPC 2.0** | Default. Zero network exposure. Best security. |
| **127.0.0.1:PORT + JSON-RPC 2.0** | When clients can't use UDS (e.g., some Windows tools) |
| **WebSocket on same socket** | Event push channel (navigation events, rate-limit signals) |

### API Shape (JSON-RPC 2.0):

```json
// Request
{"jsonrpc": "2.0", "method": "dom.click", "params": {"selector": "role=button[name='Connect']", "options": {"timeout_ms": 5000}}, "id": 1}

// Success response
{"jsonrpc": "2.0", "result": {"ok": true}, "id": 1}

// Error response
{"jsonrpc": "2.0", "error": {"code": -32001, "message": "element_not_found", "data": {"selector": "role=button[name='Connect']", "timeout_ms": 5000}}, "id": 1}

// Event notification (push, no id)
{"jsonrpc": "2.0", "method": "event.navigation", "params": {"state": "network_idle", "url": "https://linkedin.com/messaging"}}
```

### Activation:
- Start with CLI flag: `zigbrowser --automation-api` (starts UDS listener)
- Optional: `--automation-port=9222` for TCP loopback
- Socket path: `$XDG_RUNTIME_DIR/zigbrowser-automation.sock`

---

## Platform-Specific Implementation Notes

### Linux (WebKitGTK)
- Use `webkit_web_view_evaluate_javascript()` with named `world_name` for isolated injection
- Consider enabling `WebKitAutomationSession` (built-in WebDriver support) as an alternative automation backend — already handles element finding, clicking, typing
- Network interception: NOT available in UI process. Requires a WebKit Web Extension (shared library in renderer process) implementing `WebKitWebPage::send-request` — significant additional complexity
- Cookie management: `WebKitCookieManager` via `webkit_web_context_get_cookie_manager()`

### Windows (WebView2)
- **Best platform for automation** — full CDP available in-process
- Use `CallDevToolsProtocolMethodAsync` for `Input.dispatchMouseEvent`/`dispatchKeyEvent` (OS-level input, harder to detect than synthetic JS events)
- Use `AddWebResourceRequestedFilter` for network interception/blocking
- NEVER open `--remote-debugging-port` (detection signal)
- NEVER call `Runtime.enable` globally (detectable side effect)
- Cookie management: `CoreWebView2.CookieManager` or CDP `Network.getAllCookies/setCookie`

### macOS (WKWebView)
- **Most limited platform** — no CDP, no network interception, no native automation protocol
- Pure JS-based automation only via `evaluateJavaScript` + `WKUserScript` + `WKScriptMessageHandler`
- Must share `WKProcessPool` + `WKWebsiteDataStore` across windows for session sharing
- Cookie management: `WKHTTPCookieStore` only (NOT `NSHTTPCookieStorage`)
- Consider the open-source `danielraffel/tauri-webdriver` as reference for WKWebView automation

---

## Anti-Detection Architecture

### Structural Advantages (already present):
1. Real GPU-rendered WebView (clean canvas/WebGL fingerprint)
2. No browser extension injection (no `chrome-extension://` origin)
3. Desktop residential IP (not datacenter)
4. No `navigator.webdriver = true` (not WebDriver-controlled)
5. Real TLS/JA3 fingerprint (native OS network stack)

### Design Choices to Maintain Stealth:
1. **Inject in isolated world** — page scripts can't enumerate automation globals
2. **No `Runtime.enable`** on WebView2 — use Input/DOM/Network domains only
3. **OS-level input dispatch** where available (CDP `Input.*` on WebView2) vs. synthetic JS events
4. **Human-like timing jitter** — randomized delays between actions (configurable per-platform)
5. **Action pacing** — configurable daily caps and inter-action delays per platform

### Behavioral Layer (most critical for social media):
- Typing: per-keystroke with randomized inter-key delay (80-200ms, Gaussian)
- Clicking: mouse movement curve simulation (Bezier or natural arc)
- Scrolling: variable speed, pause at content
- Session duration: randomized, with breaks
- Daily action limits: configurable per platform (LinkedIn ~100 connections/day, etc.)

---

## Social Media Platform Contracts

### LinkedIn Automation Actions:
```
linkedin.connect    { profileUrl, note? }
linkedin.message    { conversationUrl | profileUrl, text }
linkedin.like       { postUrl }
linkedin.comment    { postUrl, text }
linkedin.visit      { profileUrl }
linkedin.search     { query, filters? }
linkedin.extract    { profileUrl } -> { name, headline, company, ... }
```

### Instagram Automation Actions:
```
instagram.follow    { profileUrl }
instagram.like      { postUrl }
instagram.comment   { postUrl, text }
instagram.dm        { username, text }
instagram.story_view { username }
```

### Generic Platform Actions (base contract):
```
social.login_check  {} -> { loggedIn, platform, username }
social.rate_status  {} -> { remaining_actions, reset_at, daily_cap }
social.pause        { duration_ms }
social.set_pacing   { min_delay_ms, max_delay_ms, daily_cap }
```

---

## Implementation Roadmap

### Phase 1: Core Automation Engine
- Extend `src/ipc.zig` with `dom.*` and `page.*` commands
- Build injected selector/action script (JS)
- Implement actionability check loop with timeout
- Add error taxonomy

### Phase 2: External API
- JSON-RPC server (Unix socket)
- Event push channel
- CLI flag activation (`--automation-api`)

### Phase 3: Platform-Specific Input
- WebView2: in-process CDP `Input.*` dispatch
- WebKitGTK: evaluate-based synthetic events (or WebKit Automation session)
- WKWebView: JS-only synthetic events

### Phase 4: Anti-Detection & Pacing
- Human-like timing injection
- Mouse movement simulation
- Per-platform rate limiting
- Session management

### Phase 5: Platform SDKs
- Python SDK (primary)
- Node.js SDK
- CLI tool for scripting

---

## Key Decisions Required

1. **Transport**: Unix socket (secure, local-only) vs. TCP loopback (more client compat)?
2. **WebKitGTK backend**: Roll our own (JS injection) vs. leverage built-in `WebKitAutomationSession`?
3. **Network interception**: Skip on Linux/macOS (complex) vs. implement Web Extension?
4. **Selector syntax**: Playwright-compatible string format vs. structured JSON params?
5. **Scope**: Start with one platform (LinkedIn) or generic from day one?

---

## References

- Playwright actionability: https://playwright.dev/docs/actionability
- WebView2 CDP in-process: https://learn.microsoft.com/en-us/microsoft-edge/webview2/how-to/chromium-devtools-protocol
- WebKitGTK automation: https://blogs.igalia.com/carlosgc/2017/09/09/webdriver-support-in-webkitgtk-2-18/
- Tauri WebDriver: https://v2.tauri.app/develop/tests/webdriver/
- WKWebView automation (Tauri): https://github.com/danielraffel/tauri-webdriver
- CDP detection: https://rebrowser.net/blog/how-to-fix-runtime-enable-cdp-detection-of-puppeteer-playwright-and-other-automation-libraries
- WebDriver BiDi spec: https://developer.chrome.com/blog/webdriver-bidi
