---
title: "WebKitGTK App Shell — Slice 2: navigation control + JS↔Zig bridge (TDD)"
date: 2026-05-31
status: revised x2 — PlanReview (13 crit + 31 warn) + Codex re-review (2 crit + 3 warn) all resolved
review_source: thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2-REVIEW.md
rereview_source: thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2-REVIEW-2026-05-31-codex.md
type: tdd-plan
project: zigBrowser
engine: WebKitGTK (webkit2gtk-4.1 + GTK3)
zig_version: "0.16.0"
slice: 2
depends_on: "Slice 1 (ENG-0003) — LANDED & green (commits dbeec2e, e0e0f0a); prerequisite satisfied. Slice 2 introduces the interactive ZbApp/ZbWindow model atop Slice 1's one-shot shim."
audit_source: thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md
archive_tag: archive/custom-engine-pre-webkit
laws:
  - "LAW 1 — real working software, no scaffolding: every behavior produces real, user-observable output."
  - "LAW 2 — hostile audit before planning: built against verified reality (headers grepped, working tree inspected)."
  - "VISIBLE-OUTPUT GATE — every milestone ends in a human-observable artifact, not 'tests green'."
---

# WebKitGTK App Shell — Slice 2 TDD Implementation Plan

## The product turn (why this slice exists)

Slice 4 ("the differentiator") is now decided, and it reaches backward to reshape Slice 2.
**zigBrowser is not a browser — it is a Zig answer to Tauri:** a cross-OS desktop-app shell
where Zig's frictionless cross-compilation (`zig build -Dtarget=…`, `zig cc`) plus the **system
webview** (WebKitGTK on Linux, WebView2 on Windows, WKWebView on macOS) powers a desktop app with
a **web frontend and a Zig backend**. The nearest analogues are **Wails** (Go + system webview)
and, by contrast, **Electron** (bundles its own Chromium → large binaries). zigBrowser's wager:
Zig's cross-compilation story is uniquely frictionless, and the system webview keeps binaries tiny.

> Positioning note (unverified, confirm before publishing): the "other one" the overseer referenced
> is most likely **Wails**; Electron and Neutralinojs are adjacent. The *technical* claims in this
> plan are verified against the installed headers (file:line throughout); the competitive framing is
> not and should be sanity-checked with a search before it appears in public docs (M6).

Consequence: an app shell has **no editable address bar, no tabs, no bookmarks**. Its "navigation"
is **navigation _control_** — the shell decides what the embedded webview may load, external links
open in an **app-owned sub-window**, and a web button can call a **Zig** function and show the
result. That last behavior is the whole reason to build a shell at all; this slice ships a minimal,
real version of it.

## Overview

This is a thin, end-to-end **interactive** slice layered on Slice 1's window + `WebKitWebView` +
owned context + per-load state machine. It adds five real, user-observable behaviors and one docs
reconciliation:

1. **programmatic-reload** — host-triggered reload picks up on-disk changes (the dev loop).
2. **app-origin-navigation-allowed** — in-app navigation within the app's own origin renders.
3. **disallowed-navigation-blocked** — main-frame navigation to a foreign origin is refused.
4. **external-link-opens-in-app-subwindow** — an external/`target=_blank` link opens a **new
   app-owned window** (NOT the system browser).
5. **js-calls-zig-and-sees-result** — a web button invokes a Zig function over an IPC bridge and the
   page displays a value only Zig could have produced (the differentiator, minimal form).
6. **roadmap/docs reconciled** — the roadmap and docs match the app-shell reality (tabs cut, Slice 4
   = full IPC + cross-OS backends).

Every milestone ends in a human-observable artifact; every test asserts against an **independent
oracle** (WebKit's own `get_uri`/`get_title`/load events, on-disk fixtures, or a Zig-computed value
the JS could not fabricate). No self-referential assertions.

## Current State Analysis (verified hostile audit — LAW 2; refreshed 2026-05-31 post-re-review)

### Key Discoveries (re-audited against the now-landed Slice 1 code)

- **Slice 1 HAS LANDED — verified against the working tree** (corrects the earlier "0 source files"; the
  original audit predated implementation). `git log`: `dbeec2e "Slice1 spine: WebKitGTK build/shim
  window+screenshot pipeline"`, `e0e0f0a "Slice 1 verified green: E2E harness + fixtures + uri_test +
  docs reconcile"`. `git ls-files` now tracks: `build.zig`, `src/{cli,errors,main,root,uri,webkit}.zig`,
  `src/webkit_shim.{c,h}`, `tests/uri_test.zig`. **The Slice 2 prerequisite is satisfied.**
- **Slice 1's real shim API is ONE-SHOT** (`src/webkit_shim.h`): `int zb_run_open(const char *uri, int
  print_title)`, `int zb_run_screenshot(const char *uri, const char *out, int print_title)`,
  `void zb_version_line(char*, size_t)`, plus a `ZB_EXIT_*` enum. The per-load state struct is the
  **internal `ZbPage`** (`src/webkit_shim.c:14-47`, not exported). There is **NO** `decide-policy`,
  **NO** `create`, **NO** UCM/IPC wiring yet (verified: `grep` found none). **Slice 2 therefore
  *introduces* the interactive `ZbApp`/`ZbWindow` model (§C14.1) and refactors the one-shot `zb_run_open`
  into an interactive `zb_app_run`; it reuses Slice 1's window/owned-context/§C4-state *machinery inside
  the shim* (the `ZbPage` per-load fields, §C14.1) and `uri.zig`.**
- **`uri.zig` is real and reusable as planned** — `pub fn validate(arena: std.mem.Allocator, input:
  []const u8) UriError![:0]const u8` (`src/uri.zig:5`), `UriError = { InvalidUri, UnsupportedScheme,
  RelativeUri }` (`:3`), with passing tests for file/http/https accept + javascript/ftp/relative reject.
  Slice 2 reuses it for `app_base`/candidate validation (§C14.2). (The archived host-required `url.zig`
  remains correctly unused.)
- **`errors.zig` is real** — `BrowserError` + `LoadFailure` + an exit-code mapping
  (`src/errors.zig:1-31`) matching Slice 1 §C2.
- **`cli.zig` is real** — `Command` union `{ version, open{print_title}, screenshot{print_title} }` +
  `parseArgs` (`src/cli.zig:3-19`). **Slice 2 extends this** with the app-entry `open` form +
  `--e2e-protocol` flag (§C8+).
- **Interactive lifetime is a model shift.** Slice 1 is one-shot with exit codes (bad URL → exit 2/5).
  Slice 2 is interactive: a failed load must **not** exit; it shows an error page / stays alive, and the
  process exits only on last-window-close or SIGINT/SIGTERM (§C13).
- **Toolchain present:** `pkg-config` → webkit2gtk-4.1 **2.52.3**, gtk+-3.0 **3.24.49**; `DISPLAY=:1`;
  CI uses `xvfb-run` (per Slice 1 §C9).

### Verified API surface (grepped from installed headers)

Header root: `/usr/include/webkitgtk-4.1/webkit/`.

| Capability | Symbol | file:line |
|---|---|---|
| reload | `webkit_web_view_reload` | `WebKitWebView.h:415` |
| reload (no cache) | `webkit_web_view_reload_bypass_cache` | `WebKitWebView.h:418` |
| current URI (oracle) | `webkit_web_view_get_uri` | `WebKitWebView.h:442` |
| title (oracle) | `webkit_web_view_get_title` | `WebKitWebView.h:412` |
| load events | `WEBKIT_LOAD_STARTED/REDIRECTED/COMMITTED/FINISHED` | `WebKitWebView.h:131-134` |
| policy decision types | `…NAVIGATION_ACTION / …NEW_WINDOW_ACTION / …RESPONSE` | `WebKitWebView.h:107-109` |
| allow / refuse / download | `webkit_policy_decision_use / _ignore / _download` | `WebKitPolicyDecision.h:53-63` |
| nav action (URI) | `webkit_navigation_action_get_request` (+ `webkit_uri_request_get_uri`) | `WebKitNavigationAction.h:77` |
| nav action type | `webkit_navigation_action_get_navigation_type` | `WebKitNavigationAction.h:68` |
| **create (new window)** | `GtkWidget *(* create)(WebKitWebView*, WebKitNavigationAction*)` | `WebKitWebView.h:260` |
| related sub-view | `webkit_web_view_new_with_related_view` | `WebKitWebView.h:334` |
| user content mgr ctor | `webkit_user_content_manager_new` | `WebKitUserContentManager.h:51` |
| view w/ UCM | `webkit_web_view_new_with_user_content_manager` | `WebKitWebView.h:343` |
| get UCM | `webkit_web_view_get_user_content_manager` | `WebKitWebView.h:629` |
| **IPC handler (reply)** | `webkit_user_content_manager_register_script_message_handler_with_reply` | `WebKitUserContentManager.h:119` |
| IPC reply value | `webkit_script_message_reply_return_value` | `WebKitUserContentManager.h:207` |
| read JS message value | `webkit_javascript_result_get_js_value` → `JSCValue` | `WebKitJavascriptResult.h:57` |
| IPC reply (success) | `webkit_script_message_reply_return_value` | `WebKitUserContentManager.h:207` |
| **IPC reply (error → JS reject)** | `webkit_script_message_reply_return_error_message` | `WebKitUserContentManager.h:211` |
| JSC: is-string guard | `jsc_value_is_string` | `jsc/JSCValue.h:119` |
| JSC: read string | `jsc_value_to_string` | `jsc/JSCValue.h:122` |
| JSC: typed reply from JSON | `jsc_value_new_from_json` | `jsc/JSCValue.h:316` |
| nav target-name (**logging only**, NOT a main-frame oracle — §C14.9) | `webkit_navigation_action_get_frame_name` | `WebKitNavigationAction.h:86` |
| load failure (LOAD_FAIL line) | `load-failed` signal | `WebKitWebView.h:255` |

> `gtk_show_uri_on_window` (`gtkshow.h:39`) — the "open in system browser" path — is **deliberately
> NOT used**; the overseer chose an app-owned sub-window instead (M4).
>
> **FFI/struct/encoding specifics** for every symbol below the C↔Zig seam are pinned in **§C14**
> (data structures, integer encodings, export adapters, IPC schema, memory ordering).

## Desired End State

Running the (Slice-1-built) binary on an app entry (`file://…/index.html`) yields a window that
behaves like an **app**: it renders only what the shell permits, external links pop a second
app-owned window, a button on the page calls Zig and shows a Zig-computed value, and reloading picks
up edits. Verified through the E2E stdout protocol below + Zig unit tests.

### Observable Behaviors
- **reload:** Given the app shows `index.html`; when the file changes and the host reloads; then the
  window shows the new content.
- **allow:** Given the allowlist = the app's `file://` base; when an in-app link goes to a page under
  that base; then it renders.
- **block:** Given a foreign origin; when content tries to navigate the main frame there; then the
  app stays put.
- **sub-window:** Given an external/`target=_blank` link; when activated; then a new app-owned window
  opens rendering that page (count of app windows == 2).
- **IPC:** Given a page with a button wired to `zbHost`; when clicked; then the page shows a value
  Zig computed (e.g. real `uname`).

## What We're NOT Doing
Editable address bar; tabs (former Slice 3 — **cut**); bookmarks; host-level back/forward buttons
(SPA routing lives inside the webview — only needed for MPA, deferred); the full multi-command IPC
API and the Windows (WebView2) / macOS (WKWebView) backends (Slice 4); persistent history; download
handling (`…_download` left as a documented seam, not implemented).

## Prerequisite & Salvage
- **Prereq gate:** ✅ **SATISFIED** — Slice 1 is landed & green (`dbeec2e`, `e0e0f0a`; `src/` populated,
  `uri_test`/E2E passing). Slice 2 builds directly on it.
- **Reuse from Slice 1 (verified against the real tree):** `uri.zig` (`validate(arena, input)
  UriError![:0]const u8`, `src/uri.zig:5`), `errors.zig` (`BrowserError`/`LoadFailure`), `cli.zig`
  (`Command`/`parseArgs` — **extended** for the app-entry form + `--e2e-protocol`), the C shim
  (`webkit_shim.{c,h}`) with its owned-context creation + §C4 state machine + §C5 teardown + the internal
  `ZbPage` per-load fields (`webkit_shim.c:14-47`), the §C8 stdout protocol + helper-PID tracking, the
  `xvfb-run` E2E harness, `tests/fixtures/`.
- **Refactor (not pure reuse):** Slice 1's **one-shot** entries (`zb_run_open`/`zb_run_screenshot`) become
  the interactive `zb_app_run` over the new `ZbApp`/`ZbWindow` model (§C14.1); `decide-policy`/`create`/UCM
  wiring is **new** (none exists in Slice 1's shim — verified).
- **NOT reused:** archived `url.zig` (host-required), `gtk_show_uri_on_window` (replaced by M4
  sub-window).

## §C continuation — new canonical contracts (PIN BEFORE ANY BEHAVIOR)

Single source of truth; behaviors reference these and never re-define them. Continues Slice 1 §C1–§C9.

### C10 — NavPolicy contract (the app-vs-browser boundary)
Pure, side-effect-free decision in Zig (`src/nav_policy.zig`), called from the C `decide-policy` cb:
```zig
pub const Decision = enum { use, ignore, open_in_subwindow };
pub const DecisionType = enum { navigation_action, new_window_action, response };
/// app_base: canonical file:// dir prefix of the app (from uri.zig); candidate: target URI.
pub fn decide(app_base: []const u8, candidate: []const u8, dtype: DecisionType) Decision;
```
Rules (Slice 2):
- `new_window_action` (target=_blank / window.open) → **open_in_subwindow** (M4).
- `navigation_action`, candidate under `app_base` (same-origin `file://` subtree) → **use** (M2).
- `navigation_action`, candidate is a foreign origin (any http/https, or `file://` outside base) →
  **ignore** (M3). Applies to **all** frame navigations (main + sub-frame) — no frame oracle (§C14.9).
- `response` → **use** for allowed origins (kept minimal; download deferred).
- Hash/fragment navigation within the same document → **use** (no policy churn).
- **Frame scope (corrected per re-review):** Slice 2 applies the allowlist to **all `NAVIGATION_ACTION`
  decisions — main frame and sub-frame alike** (no main-frame oracle exists; see **§C14.9**). A foreign
  sub-frame *navigation* is therefore blocked too (stricter, secure-by-default for an app). Sub-*resources*
  (img/CSS/JS, which are `RESPONSE` decisions) are not gated.

**Routing is exhaustive and non-overlapping** (resolves the B3/B4 routing critical): a **plain** foreign
link (`navigation_action`) is **always `ignore`** (B3); a `target=_blank`/`window.open` foreign link
(`new_window_action`) is **always `open_in_subwindow`** (B4). No foreign navigation is ever both. The
int↔enum encoding at the C seam is pinned in **§C14.3**; `app_base` derivation in **§C14.2**.

### C11 — Sub-window contract (the `create` signal)
The C shim handles the `create` signal (`WebKitWebView.h:260`):
- Build a **new owned `GtkWindow`** + a related WebView via `webkit_web_view_new_with_related_view`
  (**shared context/session** — cookies/localStorage/cache shared by design, §C14.4), attach it, return
  the GtkWidget per the signal ABI.
- The child does **NOT** implicitly inherit handlers — the shim must **explicitly re-connect**
  `decide-policy` (C10) and **re-register** the `zbHost` IPC handler (C12) on the child before returning
  (**§C14.10**; recursive for grandchildren).
- The child is **tracked** in `ZbApp.windows` (fixed array, cap `ZB_MAX_WINDOWS`=16; main window is
  index 0, **§C14.1**) for §C5-ordered teardown; closing a child destroys only that window and emits
  `WINCOUNT`; closing the **last** window (`n_windows==0`) quits (C13). Exceeding the cap → `create`
  returns NULL + `g_warning`.
- E2E emits `WINCOUNT\t<n>` on set change and `SUBWIN\t<uri>` at the child's `WEBKIT_LOAD_FINISHED`.

### C12 — IPC bridge contract (the differentiator, minimal)
- One `WebKitUserContentManager` per WebView (`webkit_user_content_manager_new`,
  `webkit_web_view_new_with_user_content_manager`).
- Register handler **`zbHost`** with reply:
  `webkit_user_content_manager_register_script_message_handler_with_reply(ucm, "zbHost", NULL)`.
  JS calls `await window.webkit.messageHandlers.zbHost.postMessage(JSON.stringify({cmd, args}))`.
- C reads the message via `webkit_javascript_result_get_js_value` → `JSCValue`, **guards non-string**
  (`jsc_value_is_string`, §C14.7) → `jsc_value_to_string`, then calls Zig (the JSON envelope is parsed in
  Zig, not C):
  ```zig
  // src/ipc.zig — pure dispatch, unit-testable. Caller owns the returned slice (FBA-backed, §C14.6).
  pub const IpcError = error{ UnknownCommand, BadArgs };
  pub fn dispatch(arena: std.mem.Allocator, cmd: []const u8, args_json: []const u8) IpcError![]const u8;
  // returns canonical JSON TEXT (§C14.8)
  ```
- **C-ABI bridge (§C14.5):** the C shim never calls `dispatch` directly (error unions/slices aren't
  C-ABI). It calls `zb_ipc_dispatch(cmd, args_json, &out_result, &out_err) → int` (0=ok). `nav_policy`
  is bridged the same way via `zb_policy_decide` (§C14.5); int↔enum encoding pinned in §C14.3.
- **Command/return schema** pinned in **§C14.8** (`ping`→`"pong"`; `add`→JSON number `5`;
  `os.info`→`{"sysname","release","machine"}`). `dispatch` returns JSON text; the shim turns it into a
  **typed** JS value via `jsc_value_new_from_json` (`JSCValue.h:316`).
- **Reply (§C14.5/§C14.6):** success → `webkit_script_message_reply_return_value` (JS promise resolves
  with the typed value); error → `webkit_script_message_reply_return_error_message` (`UCM.h:211`, JS
  promise **rejects** with the variant name). The page writes the value into `#zb-out`
  (`.catch` writes `ERR:<msg>`). E2E emits `IPC\t<cmd>\t<result>` (success) or `IPCERR\t<cmd>\t<msg>`
  (error). **Memory ordering** (no use-after-free): §C14.6.
- **UCM lifetime:** explicitly-created UCMs are `g_object_unref`'d after the view ctor (§C14.11).
- **Threading:** the handler runs on the WebKit main loop; replies are issued synchronously inside the
  callback (no cross-thread hop). Any future async command must hop back via `g_idle_add`.
- **Retryability:** no IPC error is retried (§C14.12).

### C13 — Interactive lifetime (model shift from Slice 1)
- Process does **not** exit on `load-failed` (interactive). The failing view shows WebKit's real error
  page (window mode, per Slice 1 §C4 returns FALSE), the app stays alive, and `LOAD_FAIL` is emitted (§C8+).
- **No error is retried** (load-failed, `UnknownCommand`, `BadArgs`) — log + continue (§C14.12).
- The **main window is tracked in the same set** (`ZbApp.windows[0]`, §C14.1) as children — no
  special-casing. Exit when `n_windows == 0` (last window — main or child — closed) or SIGINT/SIGTERM
  (Slice 1 §C5), exit 0 (or 130 on signal). Per-window teardown reuses Slice 1 §C5 order (array order).

### C8+ — E2E observation protocol extension
Extends Slice 1 §C8 (stdout = protocol only, stderr = diagnostics). On the relevant events the shim
prints exactly one tab-separated line:
- `NAV\t<uri>\t<title>` — **emitted once per main-frame navigation, at `WEBKIT_LOAD_FINISHED` only.
  `COMMITTED` is NOT an emit point** (resolves the COMMITTED-vs-FINISHED ambiguity — `get_title` is only
  reliably populated at FINISHED; pinning to one state guarantees exactly one line with a non-empty title).
- `BLOCKED\t<uri>` — when C10 returns `ignore` (emitted from the `decide-policy` cb).
- `SUBWIN\t<uri>` — when a C11 child view reaches `WEBKIT_LOAD_FINISHED` (same rule as NAV, on the child).
- `WINCOUNT\t<n>` — emitted whenever the tracked window set changes (after a `create` adds a window,
  after a `destroy` removes one). `n` = total tracked windows (main + children). **This is the
  authoritative window-count oracle** for B4 (`WINCOUNT\t2` after a sub-window opens); harnesses do NOT
  infer counts from `SUBWIN` lines.
- `LOAD_FAIL\t<uri>\t<error-description>` — emitted from the `load-failed` handler
  (`WebKitWebView.h:255`) when a load fails. Makes "reload of deleted file → app stays alive" (B1) and
  the bad-URI cases assertable without polling. **Not** emitted for loads cancelled by a newer
  `zb_reload`/navigation (see §C8+ cancellation rule).
- `IPC\t<cmd>\t<result>` — when a C12 reply succeeds (`webkit_script_message_reply_return_value`).
- `IPCERR\t<cmd>\t<error-message>` — when a C12 dispatch fails (`..._return_error_message`); lets the
  harness assert the unknown-command/bad-args path exercised the real C→Zig seam, not a silent swallow.

**`<result>`/`<error-description>` escaping:** before emission, any literal `\t` or `\n` in a protocol
field is replaced with a single space. (These lines are a debug oracle, not the actual IPC reply — the
real reply value is unmodified; only the stdout line is sanitized so the tab-delimited parser is safe.)

**Cancellation rule:** when `zb_reload` or a new navigation cancels an in-flight load, the shim sets a
`load_superseded` flag on the window (reusing Slice 1 §C4/§C5 cancel state) so the spurious
`load-failed`/`FINISHED` that WebKit delivers for the cancelled request emits **no** `NAV`/`LOAD_FAIL`
line. Only the terminal state of the *current* load is reported.

**Flag propagation:** `--e2e-protocol` is parsed in `app.zig` (extends Slice 1 `cli.zig`) and stored as
`ZbApp.e2e_protocol` (an `int`, see §C14). Every shim emit function reads `app->e2e_protocol`; default
0 → no protocol lines, so a real user never sees them.

---

# §C14 — Review Resolution: FFI boundary, data structures, encodings (PIN BEFORE CODE)

This section closes the 13 criticals + warnings from the 2026-05-31 PlanReview. It is the authoritative
source for the C↔Zig seam, struct layouts, integer encodings, and IPC schema. Earlier §C sections defer
to it on any of these specifics.

## C14.1 — Data structures (resolves Data-Models criticals: `ZbWindow`/`ZbApp.children` undefined)
Owned by the C shim; the Zig side never re-declares the layout (it only receives opaque `*ZbWindow`/`*ZbApp`).
```c
#define ZB_MAX_WINDOWS 16   /* main + children; exceeding the cap → create cb refuses, logs g_warning, returns NULL */

typedef struct ZbApp ZbApp;

typedef struct ZbWindow {
  GtkWidget               *gtk_window;     /* owned top-level */
  WebKitWebView           *view;          /* the embedded view */
  WebKitUserContentManager *ucm;          /* per-view UCM (zbHost registered here) */
  WebKitWebContext        *context;       /* owned context (Slice 1 §C5); shared with children (C14.4) */
  char                    *current_uri;   /* last main-frame FINISHED uri, owned */
  int                      load_superseded; /* set on cancel/reload — suppress spurious terminal line */
  /* Slice 1 §C3 per-load state (finished/failed/cancelled/timed_out, error domain/code/msg,
     GCancellable, timeout_source_id, signal handler IDs) is embedded here unchanged. */
  ZbApp                   *app;           /* back-pointer */
} ZbWindow;

struct ZbApp {
  ZbWindow *windows[ZB_MAX_WINDOWS];  /* fixed array, NO allocator; index 0 is the main window */
  int       n_windows;                /* current count; WINCOUNT\t<n_windows> emitted on change */
  char     *app_base;                 /* canonical file:// dir prefix (C14.2), owned */
  int       e2e_protocol;             /* --e2e-protocol flag (C8+) */
};
```
- **Main window IS in the set** (`windows[0]`) — resolves the "main-window membership unspecified"
  warning. Quit rule (§C13): `gtk_main_quit` when `n_windows == 0` (last window — main or child — closed).
- Fixed array (no dynamic container/allocator) → teardown iteration order is array order; O(1) count;
  cap = 16 (a desktop app rarely needs more; exceeding → refuse + warn, no crash).

## C14.2 — `app_base` derivation (resolves "app_base unspecified")
`app_base` = the **directory prefix** of the app-index URI: take the CLI `<app-index file://…>`, canonicalize
the path via `uri.zig` (realpath of the file), then keep everything **up to and including the final `/`**.
Example: `file:///home/u/app/index.html` → `app_base = "file:///home/u/app/"`. Containment
(`nav_policy.decide`) is a canonical-path **prefix** test on the realpath'd candidate, so `…/../outside.html`
canonicalizes out of the prefix and is correctly rejected. A unit vector in `nav_policy_test.zig` derives
`app_base` from a known `file://` argument and asserts containment results.

## C14.3 — Integer encodings across the C↔Zig ABI (resolves Decision/DecisionType encoding criticals)
Pinned, with `comptime` asserts in Zig and a `_Static_assert`/switch in C so reordering breaks the build:
| Zig enum | value | C source |
|---|---|---|
| `Decision.use` | 0 | → `webkit_policy_decision_use(decision)` |
| `Decision.ignore` | 1 | → `webkit_policy_decision_ignore(decision)` |
| `Decision.open_in_subwindow` | 2 | → **also `webkit_policy_decision_use(decision)`** (see mapping rule below) |
| `DecisionType.navigation_action` | 0 | `WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION` |
| `DecisionType.new_window_action` | 1 | `WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION` |
| `DecisionType.response` | 2 | `WEBKIT_POLICY_DECISION_TYPE_RESPONSE` |

**`open_in_subwindow` mapping rule (corrected per re-review — there is no third WebKit action):** WebKit
policy decisions are only `use` / `ignore` / `download`, and a `NEW_WINDOW_ACTION` accepts only `use` or
`ignore` (verified: `WebKitWebView.h:85-88`; GIR `WebKit2-4.1.gir` NEW_WINDOW_ACTION doc). Therefore:
- `Decision.open_in_subwindow` is **only valid for `new_window_action`**. At the `decide-policy` seam the
  cb calls `webkit_policy_decision_use(decision)` — this lets WebKit proceed to fire the **`create`**
  signal, where C14.10 constructs the app-owned child view. (The child window is created in `create`,
  **not** at the policy seam.)
- `Decision.open_in_subwindow` returned for any **non-`new_window_action`** type is a contract violation:
  the shim `g_warning`s and falls back to `webkit_policy_decision_ignore` (fail-closed). `nav_policy.decide`
  by construction only returns `open_in_subwindow` for `new_window_action`; the C guard is defense-in-depth.

The C `decide-policy` cb maps the WebKit type → these ints, calls `zb_policy_decide`, and `switch`es the
returned int: `0`/`2` → `webkit_policy_decision_use` (with the `2`-for-non-new-window guard above),
`1` → `webkit_policy_decision_ignore`. `nav_policy.zig` has
`comptime { std.debug.assert(@intFromEnum(Decision.use) == 0); std.debug.assert(@intFromEnum(Decision.open_in_subwindow) == 2); … }`.

## C14.4 — `webkit_web_view_new_with_related_view` sharing semantics (resolves "sharing undocumented")
Intentional for an app shell: a related view **shares the same `WebKitWebContext` / network session** as its
parent — **shared cookies, localStorage, IndexedDB, and HTTP cache, and the same web/network helper
processes**. This is the desired Tauri-like model (one app identity across its windows). The child reuses
`ZbWindow.context` (not a new context); only the child's `view`/`ucm`/`gtk_window` are new. Documented so
test authors know cross-window state is shared by design.

## C14.5 — C↔Zig FFI export adapters (resolves the FFI criticals — `pub export fn` / `callconv(.C)`)
`nav_policy.decide` and `ipc.dispatch` stay **pure internal Zig**. Thin `export` adapters bridge to C. All
adapter symbols are declared `extern` in `webkit_shim.h` so both sides compile against one signature.

```zig
// src/nav_policy.zig — pure internal (unchanged signature), plus the adapter:
pub export fn zb_policy_decide(base: [*:0]const u8, candidate: [*:0]const u8, dtype: c_int) c_int {
    const d = decide(std.mem.span(base), std.mem.span(candidate), @enumFromInt(dtype));
    return @intFromEnum(d); // 0/1/2 per C14.3
}

// src/ipc.zig — pure internal: pub fn dispatch(arena: std.mem.Allocator, cmd, args_json) IpcError![]const u8
// C-ABI adapter (out-param + return code; NO error union across FFI):
pub export fn zb_ipc_dispatch(
    cmd: [*:0]const u8,
    args_json: [*:0]const u8,
    out: *[*:0]const u8,   // on success → sentinel-terminated JSON result text (owned by caller's FBA, C14.6)
    out_err: *[*:0]const u8, // on error → sentinel-terminated error message
) c_int { … } // returns 0 on success (out set), non-zero on IpcError (out_err set)
```
Matching C declarations in `webkit_shim.h`:
```c
int  zb_policy_decide(const char *base, const char *candidate, int dtype);   /* 0=use 1=ignore 2=subwindow */
int  zb_ipc_dispatch (const char *cmd, const char *args_json,
                      const char **out_result, const char **out_err);        /* 0=ok, !=0 IpcError */
void zb_reload       (ZbWindow *win, int bypass_cache);
ZbWindow *zb_window_new(ZbApp *app, WebKitWebView *view);                     /* shared main+child builder */
```
`zb_ipc_reply` is **C-internal only** (not a Zig export) — it wraps the WebKit reply call:
```c
/* exactly one of result/err is non-NULL */
static void zb_ipc_reply(WebKitScriptMessageReply *reply, const char *result_json, const char *err);
/* result_json → jsc_value_new_from_json(ctx, result_json) → webkit_script_message_reply_return_value
   err         → webkit_script_message_reply_return_error_message(reply, err)            (UCM.h:211) */
```

## C14.6 — IPC memory ownership & lifetime (resolves arena/use-after-free criticals)
- The IPC callback owns a **fixed 8 KB stack buffer** wrapped in a `std.heap.FixedBufferAllocator`; that
  FBA's allocator is passed to `dispatch`. No heap allocator is used for Slice 2's small replies.
- **Mandatory ordering** (one inline comment block in `webkit_shim.c`'s IPC cb pins it):
  1. reset the FBA; call `zb_ipc_dispatch` → result/err text lives in the FBA buffer;
  2. build the reply value: success → `jsc_value_new_from_json(ctx, out_result)` (**copies** the bytes,
     `JSCValue.h:316`); error → keep the C string for `return_error_message`;
  3. the FBA buffer remains valid until after step 2 returns (it is stack-scoped to the callback);
  4. call `webkit_script_message_reply_return_value(reply, jsc_value)` (success) or
     `webkit_script_message_reply_return_error_message(reply, out_err)` (error);
  5. emit `IPC`/`IPCERR`. The buffer naturally dies at callback return — no manual free, no use-after-free.
- Re-entrancy: each IPC callback has its own stack buffer/FBA → no cross-call aliasing.

## C14.7 — IPC message read & NULL guard (resolves "JSCValue NULL guard absent")
In the IPC cb, before crossing to Zig:
```c
JSCValue *v = webkit_javascript_result_get_js_value(js_result);  /* JavascriptResult.h:57 */
if (!v || !jsc_value_is_string(v)) {                              /* JSCValue.h:119 */
    webkit_script_message_reply_return_error_message(reply, "zbHost: message must be a JSON string");
    return; /* no NULL crosses into Zig */
}
char *msg = jsc_value_to_string(v);                              /* JSCValue.h:122 */
/* parse the {cmd,args} envelope in Zig (ipc.zig), not C */
```

## C14.8 — IPC command & envelope schema (resolves os.info/add/args schema + tab-escaping)
`dispatch` always returns **canonical JSON text**; the shim turns it into a typed JS value via
`jsc_value_new_from_json`, so the JS caller receives a real number/string/object (not always a string).
| command | `args` JSON | return JSON text | JS receives |
|---|---|---|---|
| `ping` | `{}` (or absent/`null`) | `"pong"` (6 bytes, **quotes included** — JSON string) | string `"pong"` |
| `add` | `{"a":<int>,"b":<int>}` | `5` (1 byte, **no quotes** — JSON number) | number `5` |
| `os.info` | `{}` | `{"sysname":"Linux","release":"6.x","machine":"x86_64"}` | object |

**Representation (resolves the add string-vs-number warning):** `dispatch` returns **canonical JSON token
text**; the shim passes it verbatim to `jsc_value_new_from_json`, so the JS type follows the JSON. The Zig
unit test compares those exact bytes — `add` → `try expectEqualStrings("5", r)` (the Zig literal `"5"` is
the single byte `5`, **not** a quoted JSON string `"\"5\""`); `ping` → `expectEqualStrings("\"pong\"", r)`.
Numbers are unquoted everywhere; the earlier `5`/`"5"` wording is unified to *"the byte `5`"*.
- No-arg commands accept missing/`{}`/`null` `args`; non-conforming `args` → `IpcError.BadArgs`.
- `add` non-integer / missing field → `BadArgs`. Unknown `cmd` → `UnknownCommand`.
- Error → `zb_ipc_dispatch` returns non-zero, `out_err` = the variant name
  (`"UnknownCommand"`/`"BadArgs"`) → `return_error_message` → the JS promise **rejects** with that message.
  The fixture's JS `.catch(e => zbOut.textContent = "ERR:" + e.message)` makes the error path observable in
  the DOM, and `IPCERR\t<cmd>\t<msg>` makes it observable to the harness.

## C14.9 — Policy enforcement scope (corrected per re-review)
**There is NO reliable main-frame oracle on a navigation policy decision in webkit2gtk-4.1, and Slice 2
does not use one.** `webkit_navigation_action_get_frame_name` (`WebKitNavigationAction.h:86`) is
**target-name metadata only** — verified against GIR (`/usr/share/gir-1.0/WebKit2-4.1.gir`,
`get_frame_name` doc): *"Gets the navigation target frame name … if navigation was triggered by clicking a
link with a target attribute equal to `_blank`, this will return that value. In all other cases this
function will return NULL."* So `NULL` means *"no named target"*, **not** *"main frame"* — it cannot
discriminate main frame from sub-frame. The earlier `NULL ⇒ main frame` claim was wrong and is removed.
- **Slice 2 policy applies to ALL `NAVIGATION_ACTION` decisions** (main frame *and* sub-frame frame
  navigations) against `app_base`. This needs no frame oracle, is implementable from verified APIs, and is
  the **stricter, more secure** app-shell stance: a foreign-origin frame navigation anywhere is blocked.
- This does **not** affect sub-resources (images/CSS/scripts) — those arrive as `RESPONSE` decisions /
  resource loads, which Slice 2 leaves at `use` (a page may pull its own assets). Only *frame navigations*
  are gated.
- `get_frame_name` may still be read for **logging only** (to show what target a blocked nav had); it is
  never used as a policy discriminator.

## C14.10 — `create`-signal child wiring (resolves "child does not inherit handlers")
**Trigger sequence:** for a `new_window_action`, `decide-policy` returns `webkit_policy_decision_use`
(§C14.3) → WebKit fires the **`create`** signal → this callback builds and returns the app-owned child
view (returning a view from `create` is what makes WebKit open it in our window; returning `NULL` cancels
the new window).

WebKit does **not** propagate `decide-policy` connections or UCM handlers from a related view. Inside the
`create` callback, **before returning the child widget**, the shim must:
1. `webkit_web_view_new_with_related_view(parent)` → child view (shares context, C14.4);
2. `g_signal_connect(child, "decide-policy", G_CALLBACK(on_decide_policy), app)` and connect
   `load-changed`/`load-failed`/`create` (recursively, for grandchildren);
3. obtain the child UCM (`webkit_web_view_get_user_content_manager`) and
   `register_script_message_handler_with_reply(ucm, "zbHost", NULL)` + connect `script-message-with-reply-received`;
4. wrap in `zb_window_new(app, child)`, track in `ZbApp.windows`, emit `WINCOUNT`.

## C14.11 — UCM reference cleanup (resolves "UCM GObject leak")
When a window is built with an explicitly-created UCM
(`webkit_user_content_manager_new` → `webkit_web_view_new_with_user_content_manager`), the shim calls
`g_object_unref(ucm)` **after** the view constructor (the view takes its own ref). One line in
`zb_window_new`. (Child views created via `new_with_related_view` instead use
`webkit_web_view_get_user_content_manager` — no extra ref to release.)

## C14.12 — `app.zig` public interface (resolves "app.zig interface absent") — see also §C14.5
```zig
// src/app.zig — the Zig host entry; thin, delegates rendering to the shim.
pub fn run(gpa: std.mem.Allocator, args: cli.Args) BrowserError!u8; // parse, derive app_base (C14.2),
    // call zb_app_run (shim) which builds the main window via zb_window_new and enters gtk_main;
    // returns the process exit code (0 / 130).
// Reload is a shim entry (zb_reload, C14.5) invoked by the host trigger; UCM wiring happens INSIDE
// zb_window_new (C14.10/C14.11), not as a separate Zig call.
```
- **Reload trigger contract (resolves "reload trigger not concretely specified"):** the app installs a
  `g_unix_signal_add(SIGHUP, …)` handler (reusing Slice 1 §C5's `g_unix_signal_add` infra) that calls
  `zb_reload(app->windows[0], /*bypass=*/0)` on the **main window**. This is a real live-reload affordance
  (idiomatic for dev servers) **and** the deterministic black-box E2E trigger: the harness sends `SIGHUP`
  to the spawned PID and asserts the second `NAV` line. No test-only code path — the production signal
  handler is what the test exercises. (`reload_bypass_cache` is reachable via the in-app reload control;
  SIGHUP uses the normal reload.)
- **Retryability (resolves "retryability undeclared"):** No error in Slice 2 is retried. `load-failed` →
  show WebKit's error page, log uri to stderr, `LOAD_FAIL` line, stay alive. `IpcError.UnknownCommand` /
  `BadArgs` → reject the JS promise via `return_error_message`, log to stderr, `IPCERR` line; no retry.
- **`window.open()` triggering `create`:** the `create` signal docblock (`WebKitWebView.h:86`) states it
  fires "when WebKit is about to create a new window" — this covers both `target=_blank` and JS
  `window.open()`. Both route through C14.10. (Documented behavior; the B4 E2E exercises both.)

## Testing Strategy
- **Framework:** Zig 0.16 `zig build test` for units (pure `nav_policy.decide` vectors;
  `ipc.dispatch` vectors; any envelope JSON parse). A **spawn-the-binary E2E harness** under
  `xvfb-run` reusing Slice 1 §C8 (machine-readable stdout + helper-PID tracking) and the §C8+ lines.
- **Driving the real handlers (no bypass):** E2E loads fixture pages whose JS triggers the real code
  paths — `window.location`/anchor clicks (decide-policy), `window.open`/`target=_blank` (create), and
  a button that calls `zbHost.postMessage` (IPC). The E2E driver may emit synthetic activation via the
  page's own JS on load; the **production** `decide-policy`/`create`/IPC code runs unchanged.
- **Independent oracles only:** WebKit `get_uri`/`get_title`/load events; on-disk fixture files
  (before≠after for reload); Zig-computed values for IPC (the page cannot produce `uname`/the Zig sum
  by itself). No fixture-and-code-share-a-fiction tests.
- **Fixtures (new):** `tests/fixtures/app/index.html` containing: an IPC button → `#zb-out` (with
  `.catch(e=>…"ERR:"+e.message)`) and an unknown-cmd button (B5); a link to `page-b.html` under base
  (B2); a **plain** foreign `<a href>` (no target) for the block test (B3); a **`target=_blank`** foreign
  link for the sub-window test (B4, distinct from B3 per the routing fix). `tests/fixtures/app/page-b.html`;
  a mutable copy for reload (B1). Deterministic, no network for allow/block/reload/IPC; the sub-window
  target is a second local `file://` page (no live internet needed).
- **CI deps (documented, reuse Slice 1):** `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `xvfb`, `python3`;
  missing tools → **skip with a loud notice**, never a vacuous pass.

---

## Behavior 1: programmatic-reload (picks up disk changes)

### Test Specification
**Given** the app window shows `index.html` loaded from a temp dir.
**When** the file content on disk changes and the host triggers reload (the `SIGHUP` → main-window reload
contract, §C14.12).
**Then** the load runs again (`STARTED → … → FINISHED`) and the window shows the **new** content;
`NAV\t<file-uri>\t<new-title>` is emitted.

**Edge Cases:** reload while a prior load is in flight → prior cancelled cleanly (Slice 1 §C5) and the
cancelled load's spurious terminal event emits **no** `NAV`/`LOAD_FAIL` (`load_superseded`, §C8+);
`reload_bypass_cache` variant forces a fresh fetch; reload of a now-deleted file → `load-failed` →
WebKit error page, **app stays alive** (C13), `LOAD_FAIL\t<uri>\t<desc>` emitted (§C8+).

**Property:** for any sequence of (edit, reload) pairs, the post-reload `document.title` equals the
title in the current on-disk file — never a cached prior value.

**Files touched:** `src/webkit_shim.c` (reload entry + reuse cancel/teardown), `src/webkit_shim.h`
(`zb_reload(ZbWindow*, int bypass_cache)`), `src/app.zig` (`SIGHUP` reload trigger §C14.12), `tests/e2e/reload_test.*`,
`tests/fixtures/app/index.html`.

### TDD Cycle
- 🔴 **Red:** E2E (xvfb) loads a copied fixture, asserts initial `NAV…<title-A>`, rewrites the file to
  `<title-B>`, **sends `SIGHUP` to the spawned PID** (§C14.12), asserts a second `NAV…<title-B>`. Fails
  (no SIGHUP handler / reload entry).
- 🟢 **Green:** shim `zb_reload(win, bypass)` (§C14.5) → set `load_superseded`, cancel in-flight (§C5) →
  `webkit_web_view_reload[_bypass_cache]`; emit `NAV` at `WEBKIT_LOAD_FINISHED` **only** (§C8+),
  `LOAD_FAIL` on `load-failed`.
- 🔵 **Refactor:** one `reload_current(win, bypass)` routine; share the FINISHED→NAV emit with B2/B4.
- **VISIBLE ARTIFACT:** the edited text appears in the window after reload.
- **ORACLE:** the on-disk file (title before ≠ after); WebKit `get_title`.

## Behavior 2: app-origin-navigation-allowed

### Test Specification
**Given** the app shows `index.html`; allowlist = the app's `file://` base dir (canonicalized via
`uri.zig`).
**When** an in-app link/route navigates to `page-b.html` under that base.
**Then** `decide-policy` (NAVIGATION_ACTION) → C10 `use`; the window renders page-b's real content;
`NAV\t…/page-b.html\t<title-B>` emitted.

**Edge Cases:** hash/fragment nav within the same page → `use`, no full reload; redirect to another
allowed-base URL → `use`; `page-b` under a sibling dir **outside** base → handled by B3.

**Property:** `decide(app_base, c, navigation_action) == .use` **iff** `c` is a `file://` URI whose
canonical path is within `app_base` (else `.ignore`); proven over a vector table incl. path-traversal
(`…/../outside.html`) which must NOT be treated as in-base.

**Files touched:** `src/nav_policy.zig` (new, C10), `src/webkit_shim.c` (`decide-policy` cb →
`zb_policy_decide`), `src/webkit_shim.h` (`int zb_policy_decide(const char* base, const char* uri, int dtype)`),
`tests/nav_policy_test.zig`, `tests/e2e/nav_allow_test.*`, `tests/fixtures/app/page-b.html`.

### TDD Cycle
- 🔴 **Red:** unit — `decide(base, base/page-b.html, navigation_action) == .use`; path-traversal
  vector `.ignore`. E2E — click in-app link, assert `NAV…page-b.html`. Fails (no policy fn / cb).
- 🟢 **Green:** `nav_policy.zig` (canonical-path containment using `uri.zig`, `app_base` per §C14.2) +
  `pub export fn zb_policy_decide` adapter (§C14.5); shim `decide-policy` cb detects main-frame
  (`get_frame_name`==NULL, §C14.9), maps the WebKit type → `dtype` int (§C14.3), calls `zb_policy_decide`,
  `switch`es 0→`webkit_policy_decision_use`.
- 🔵 **Refactor:** extract containment helper; reuse in B3; `comptime` assert the §C14.3 encoding.
- **VISIBLE ARTIFACT:** the app view swaps to page-b's real text.
- **ORACLE:** `get_uri == file://…/page-b.html` + FINISHED; `get_title` == fixture title.

## Behavior 3: disallowed-navigation-blocked

### Test Specification
**Given** the app on an app page; allowlist excludes foreign origins.
**When** page content attempts to navigate the **main frame in-place** (a **plain** `<a href>` / `window.location`,
i.e. `navigation_action` — distinct from B4's `target=_blank`) to a foreign origin (e.g. `https://evil.test`
or a `file://` outside base).
**Then** `decide-policy` → C10 `ignore`; the app stays on its current page; `BLOCKED\t<uri>` emitted.

**Edge Cases:** foreign origin via top-level redirect → still blocked; `file://` path-traversal out of
base → blocked; sub-frame load inside an allowed page → **allowed** (documented main-frame-only stance,
C10); a blocked nav does not crash or exit (C13).

**Property:** for all `c` not within `app_base` and `dtype == navigation_action`,
`decide(...) == .ignore` (never `.use`). No input panics.

**Files touched:** `src/nav_policy.zig` (extend), `src/webkit_shim.c` (`ignore` branch + `BLOCKED`
emit), `tests/nav_policy_test.zig` (extend), `tests/e2e/nav_block_test.*`,
`tests/fixtures/app/index.html` (add disallowed link).

### TDD Cycle
- 🔴 **Red:** unit — foreign + traversal vectors → `.ignore`. E2E — trigger main-frame nav to
  `https://evil.test`, assert `BLOCKED…` and `get_uri` unchanged. Fails.
- 🟢 **Green:** shim `ignore` branch → `webkit_policy_decision_ignore`; emit `BLOCKED`.
- 🔵 **Refactor:** unify allow/block into one C10 table; single decision-log emit.
- **VISIBLE ARTIFACT:** the app does NOT navigate away; it stays on its UI.
- **ORACLE:** `get_uri` unchanged after the attempt + `BLOCKED\t<uri>`.

## Behavior 4: external-link-opens-in-app-subwindow

### Test Specification
**Given** the app page contains a `target=_blank` (and/or `window.open()`) external link.
**When** it is activated.
**Then** the policy resolves `new_window_action` → `open_in_subwindow`; the `create` signal builds a
**new app-owned GtkWindow** + related WebView (C11/§C14.10) that loads the target; the app now has
**two** windows; `WINCOUNT\t2` then `SUBWIN\t<uri>` (at the child's FINISHED) emitted. The system browser
is **not** launched.

**Boundary with B3 (resolves the routing critical):** a **plain** foreign `<a href>` (no `target`) is a
`navigation_action` → `ignore` (that is B3, not this behavior). Only `new_window_action`
(`target=_blank` / `window.open`) opens a sub-window. The fixture therefore has **two distinct**
foreign links: a plain one (B3) and a `target=_blank` one (B4).

**Edge Cases:** `window.open()` from JS → same `create` path (§C14.12); closing the child destroys only
the child and emits `WINCOUNT\t1` (C13); a child can open a grandchild (tracked, recursive wiring
§C14.10); exceeding `ZB_MAX_WINDOWS` (16) → `create` returns NULL + `g_warning`, no crash (§C14.1);
child inherits policy + IPC via explicit re-wiring (§C14.10), not implicit propagation.

**Property:** every `new_window_action` resolves to **exactly one** new tracked child window (never an
uncontrolled WebKit default window, never a system-browser launch); no `navigation_action` ever opens a
sub-window.

**Files touched:** `src/webkit_shim.c` (`create` cb + `zb_window_new` child builder + child tracking +
recursive wiring §C14.10), `src/webkit_shim.h` (`ZbWindow`/`ZbApp` per §C14.1, `zb_window_new` per
§C14.5), `src/nav_policy.zig` (`open_in_subwindow` branch), `tests/e2e/subwindow_test.*`,
`tests/fixtures/app/index.html` (a `target=_blank` link — distinct from B3's plain foreign link).

### TDD Cycle
- 🔴 **Red:** E2E — activate the `target=_blank` link; assert `WINCOUNT\t2` and `SUBWIN…<target>`. Fails
  (no `create` handler).
- 🟢 **Green:** `decide-policy` on `NEW_WINDOW_ACTION` → `webkit_policy_decision_use` (§C14.3) so WebKit
  fires `create`; `create` cb → `webkit_web_view_new_with_related_view` → new owned GtkWindow → attach;
  **explicitly re-connect** `decide-policy`/load signals + **re-register** `zbHost` on the child UCM
  (§C14.10 — not inherited); `g_object_unref` not needed for related-view UCM (§C14.11); return widget;
  track in `ZbApp.windows`, emit `WINCOUNT`; on child `FINISHED` emit `SUBWIN`.
- 🔵 **Refactor:** one `zb_window_new(app, view)` (§C14.5) shared by Slice 1's main window and this child.
- **VISIBLE ARTIFACT:** a second app-owned window opens rendering the external page.
- **ORACLE:** child `get_uri == target` + `WINCOUNT\t2` (authoritative count, §C8+).

## Behavior 5: js-calls-zig-and-sees-result (the differentiator)

### Test Specification
**Given** `index.html` has a button wired to
`window.webkit.messageHandlers.zbHost.postMessage(JSON.stringify({cmd:"os.info"}))` writing the
resolved reply into `#zb-out`.
**When** the button is clicked.
**Then** the IPC handler (C12) reads the message, calls Zig `ipc.dispatch("os.info", …)`, returns the
real `uname` values via `webkit_script_message_reply_return_value`; the page displays a value **only
Zig could produce**; `IPC\tos.info\t<result>` emitted.

**Edge Cases:** `ping`→`pong` and `add {a,b}`→sum also covered; unknown command → `IpcError`/structured
JS rejection (handler returns an error value, page shows the error, **no crash**); malformed envelope →
`BadArgs` rejection; a reply issued after the page navigated away is dropped safely (reply ref guarded).

**Property:** for the supported command set, `ipc.dispatch(cmd, args)` is deterministic and matches an
independent computation of the same value (the Zig sum equals `a+b`; `os.info.sysname` equals the
process's real `uname().sysname`); unknown commands always yield `error.UnknownCommand`, never a panic.

**Files touched:** `src/ipc.zig` (new: pure `dispatch` + `pub export fn zb_ipc_dispatch` adapter §C14.5
+ envelope parse §C14.8), `src/webkit_shim.c` (UCM create + `g_object_unref` §C14.11 +
`register_script_message_handler_with_reply` + JSCValue NULL-guarded read §C14.7 + `zb_ipc_reply`
success/error §C14.5/§C14.6), `src/webkit_shim.h` (`zb_ipc_dispatch` concrete extern §C14.5),
`src/app.zig` (`run`, UCM wiring inside `zb_window_new` §C14.12), `tests/ipc_test.zig`,
`tests/e2e/ipc_roundtrip_test.*`, `tests/fixtures/app/index.html` (button + `#zb-out` + `.catch`).

### TDD Cycle
- 🔴 **Red:** unit (`std.testing.allocator`) — `dispatch(a, "add", "{\"a\":2,\"b\":3}")` → `"5"` (JSON
  number text, §C14.8); `dispatch(a, "os.info", "{}")` → object whose `sysname` == the real
  `std.posix.uname().sysname`; `dispatch(a, "nope", "{}")` → `error.UnknownCommand`;
  `dispatch(a, "add", "{}")` → `error.BadArgs`. E2E — click the button, assert `#zb-out` text == the
  Zig value AND `IPC\tos.info\t…`; click an unknown-cmd button, assert `#zb-out` == `ERR:UnknownCommand`
  AND `IPCERR\tnope\tUnknownCommand`. Fails (no handler).
- 🟢 **Green:** shim creates a UCM per WebView (then `g_object_unref`, §C14.11), registers `zbHost` with
  reply, NULL-guards + reads the `JSCValue` string (§C14.7), calls `zb_ipc_dispatch` (§C14.5) into an
  FBA buffer (§C14.6), replies via `return_value` (typed via `jsc_value_new_from_json`) or
  `return_error_message`; `ipc.zig` implements `ping`/`os.info`/`add` per the §C14.8 schema.
- 🔵 **Refactor:** make `ipc.dispatch` a table (`cmd → fn`) — this table is the **Slice-4 command
  surface seam**; document it. Confine all JSC/WebKit handling to the shim.
- **VISIBLE ARTIFACT:** the page shows a value Zig computed (real `uname` / sum), live.
- **ORACLE:** Zig-computed value == DOM `#zb-out` text (+ `IPC` line); unit vectors for `dispatch`.

## Behavior 6: roadmap/docs reconciled to the app-shell pivot

### Test Specification
**Given** the roadmap/docs still frame the project as a browser (tabs, address bar) and pre-date the
Tauri-alternative decision.
**When** Slice 2 lands.
**Then** the roadmap and active docs describe the **app shell**: Slice 3 "tabs" is **cut/replaced**,
Slice 4 = full IPC command API + Windows (WebView2) / macOS (WKWebView) backends; no active doc claims
an address bar/tabs/bookmarks as features.

**Edge Cases:** the audit/roadmap doc keeps its history but gains an "app-shell pivot" addendum;
the competitor framing (Wails/Electron) is marked unverified pending a search.

**Files touched:** `thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md`
(addendum), `docs/how-to-build.md`/`how-to-run.md` (app-shell run model), `specs/architecture.md`
(IPC + sub-window + policy), `README`/roadmap as present.

### TDD Cycle
- 🔴 **Red:** a docs-lint test (greps the active doc set) asserting no active how-to advertises
  address-bar/tabs/bookmarks as shipping features and that a roadmap entry names the app-shell pivot.
  Fails.
- 🟢 **Green:** update roadmap + docs to the app-shell reality; mark stale browser framing obsolete.
- 🔵 **Refactor:** one "App Shell — Slice 2" doc index linking this plan.
- **VISIBLE ARTIFACT:** a human reads the roadmap and it matches the built shell.
- **ORACLE:** the docs-lint grep + a human walkthrough of `how-to-run.md`.

## Integration & E2E Testing
- One `decide-policy` handler drives B2/B3/B4 (use/ignore/open_in_subwindow) via the single C10 table.
- One window-build routine serves the main window (Slice 1) and C11 children.
- One UCM-per-WebView wiring serves the main and child views for C12.
- E2E flows (all under `xvfb-run`, `--e2e-protocol`): reload (NAV×2), allow (NAV page-b), block
  (BLOCKED + get_uri unchanged), sub-window (SUBWIN + count 2), IPC round-trip (IPC + DOM value).
- Harness reuses Slice 1 §C8 helper-PID tracking to confirm children/helpers are reaped on quit.

## CLI / Run Contract (delta from Slice 1)
| Invocation | behavior |
|---|---|
| `zigBrowser <app-index file://…>` | opens the app window (interactive; does not exit on load-failed) |
| `… --e2e-protocol` | additionally prints `NAV`/`BLOCKED`/`SUBWIN`/`IPC` lines to stdout |
| window close / last window / SIGINT | graceful teardown, exit 0 (130 on signal) — C13 |
| (Slice 1 flags `--version`, `--screenshot`, `--print-title`) | unchanged |

## Risks & Mitigations
| Risk | Mitigation |
|---|---|
| Slice 1 prerequisite | ✅ Resolved — Slice 1 landed & green (`dbeec2e`/`e0e0f0a`); Slice 2 unblocked |
| Refactor of Slice 1 one-shot shim into interactive model | scope `zb_run_open`→`zb_app_run` carefully; keep `--version`/`--screenshot` paths working (CLI delta table); reuse `ZbPage` per-load fields unchanged |
| `create`-signal child windows leak | track every window in `ZbApp.windows` (fixed array, §C14.1); §C5 ordered teardown per window; close-last quits |
| IPC reply on wrong thread / after navigation | reply synchronously inside the main-loop callback; guard reply ref if page changed |
| Policy bypassable via sub-frames | documented **main-frame-only** stance (C10); tightening deferred |
| `target=_blank` spawns uncontrolled WebKit window | `create` cb always returns OUR child view (C11); never NULL-default |
| JSCValue/JSON parsing in C is fiddly | read as string in C, parse JSON in Zig (`ipc.zig`); keep C dumb |
| Competitor framing wrong/unverified | M6 marks Wails/Electron claims unverified; confirm with a search before public docs |
| E2E activation not exercising real handlers | fixture JS triggers real `decide-policy`/`create`/IPC; production code path unchanged |

## Review Resolution (PlanReview 2026-05-31 — 13 critical + 31 warnings)

All API claims below verified against installed headers.

### Critical (13)
| # | Finding | Resolution |
|---|---|---|
| 1 | C↔Zig extern boundary unspecified (nav_policy + ipc) | **§C14.5** — `pub export fn zb_policy_decide`/`zb_ipc_dispatch` `callconv(.C)` adapters; matching `extern` in `webkit_shim.h` |
| 2 | ipc.dispatch return-slice lifetime vs JSC | **§C14.6** — FBA buffer; `jsc_value_new_from_json` copies before buffer dies; explicit step ordering |
| 3 | ipc.dispatch arena param has no type | **§C12/§C14.5** — `arena: std.mem.Allocator`; caller owns slice |
| 4 | zb_ipc_dispatch C-ABI export undefined | **§C14.5** — `int zb_ipc_dispatch(cmd, args, **out_result, **out_err)`; 0=ok |
| 5 | zb_ipc_reply signature literally `(...)` | **§C14.5** — `zb_ipc_reply(reply, result_json, err)`; success→`return_value`, error→`return_error_message` (UCM.h:211) |
| 6 | B4 property contradicts C10/B3 | **§C10 + B3/B4** — plain foreign `navigation_action`→`ignore` (B3); only `new_window_action`→`open_in_subwindow` (B4); fixture split into two distinct links |
| 7 | NAV emit ambiguous (COMMITTED/FINISHED) | **§C8+** — pinned to `WEBKIT_LOAD_FINISHED` only; one line, non-empty title |
| 8 | UCM GObject ref leak | **§C14.11** — `g_object_unref(ucm)` after view ctor |
| 9 | ipc.dispatch arena owner/lifetime/cleanup | **§C14.6** — stack FBA, valid through reply, no manual free |
| 10 | ZbWindow struct fields undefined | **§C14.1** — full field list pinned |
| 11 | ZbApp.children type unspecified | **§C14.1** — fixed `windows[ZB_MAX_WINDOWS]` array, `n_windows` |
| 12 | zb_ipc_reply/dispatch C sigs `...` | resolved by #4/#5 (§C14.5) |
| 13 | Decision/DecisionType int encoding undefined | **§C14.3** — 0/1/2 mapping table + `comptime`/`_Static_assert` |

### Warnings (31) — grouped
| Theme | Findings | Resolution |
|---|---|---|
| IPC error → JS shape + observability | error shape, no E2E error line, error response format | **§C14.8/§C8+** — `return_error_message` → JS reject; `IPCERR\t<cmd>\t<msg>` line; `.catch` → `#zb-out` |
| `<result>` tab-safety | unbounded/tab-unsafe result field (×2) | **§C8+** — `\t`/`\n` → space before emission |
| LOAD_FAIL observability | no protocol line for load-failed | **§C8+** — `LOAD_FAIL\t<uri>\t<desc>` |
| Main-frame detection `[VERIFY]` ×2 | no frame accessor cited | **§C14.9** — `webkit_navigation_action_get_frame_name` (NavigationAction.h:86, NULL⇒main) + response variant (:64) |
| JSCValue NULL guard | non-string message → NULL | **§C14.7** — `jsc_value_is_string` guard → error reply |
| app_base derivation | transformation unspecified | **§C14.2** — dir prefix up to final `/`, realpath-canonical |
| related-view sharing semantics | what is shared | **§C14.4** — shared context/cookies/storage/cache, intentional |
| Decision/DecisionType int↔C maps ×2 | ordinal + WebKit type mapping | **§C14.3** |
| app.zig interface absent | no function names | **§C14.12** — `pub fn run`; UCM wiring in `zb_window_new` |
| ZbApp.children container + allocator ×2 | type/allocator | **§C14.1** — fixed array, no allocator |
| zb_window_new signature | undefined | **§C14.5** — `ZbWindow *zb_window_new(ZbApp*, WebKitWebView*)` |
| --e2e-protocol propagation | mechanism | **§C8+/§C14.1** — `ZbApp.e2e_protocol` field |
| Retryability | undeclared | **§C14.12/§C13** — no retries; log + continue |
| create-signal child wiring | handlers not inherited | **§C14.10** — explicit `g_signal_connect` + re-register `zbHost` |
| window-count oracle | no count line | **§C8+** — authoritative `WINCOUNT\t<n>` |
| window.open() fires create | not confirmed | **§C14.12** — create docblock (WebView.h:86) covers `window.open`+`_blank` |
| cancelled-load spurious load-failed | unhandled | **§C8+** — `load_superseded` suppresses spurious terminal line |
| main window in tracking set | special-casing | **§C14.1/§C13** — main is `windows[0]`; quit on `n_windows==0` |
| os.info / add / args schema ×3 | shapes undefined | **§C14.8** — command/args/return schema table |

### Codex re-review (2026-05-31): 2 critical + 3 warnings — all resolved
All API semantics below re-verified against headers **and GIR** (`/usr/share/gir-1.0/WebKit2-4.1.gir`).
| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | ❌ | `get_frame_name` `NULL ⇒ main frame` is **wrong** (GIR: returns target name e.g. `_blank`, NULL = no named target) | **§C14.9 rewritten** — no main-frame oracle exists; Slice 2 policy applies to **all `NAVIGATION_ACTION`** (main + sub-frame); `get_frame_name` is logging-only. §C10 stance + API table + B3 updated. |
| 2 | ❌ | `open_in_subwindow` has no WebKit action (only use/ignore/download; NEW_WINDOW_ACTION = use/ignore) | **§C14.3 + §C14.10 + B4** — `open_in_subwindow` ⇒ `webkit_policy_decision_use` on `NEW_WINDOW_ACTION`, child built in `create`; invalid for other dtypes → `g_warning` + fail-closed `ignore`. |
| 3 | ⚠️ | Reload trigger not concretely E2E-drivable | **§C14.12 + B1** — `SIGHUP` → `zb_reload(main, 0)` (real live-reload + black-box trigger); harness sends SIGHUP, asserts 2nd `NAV`. |
| 4 | ⚠️ | `add` return string-vs-number drift | **§C14.8** — `dispatch` returns canonical JSON token text; `add`→bytes `5` (unquoted); unit asserts `expectEqualStrings("5", r)`; unified everywhere. |
| 5 | ⚠️ | Current-state stale ("0 source files") | **Frontmatter + Current State + Prereq + Risks refreshed** — Slice 1 landed & green (`dbeec2e`/`e0e0f0a`); re-audited the real shim (one-shot `zb_run_open`, internal `ZbPage`, no policy/IPC yet); prereq satisfied. |

## References
- Slice 1 plan: `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md` (§C1 uri.zig, §C4 state machine, §C5 teardown, §C8 protocol, §C9 display)
- Audit/roadmap: `thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md`
- WebKit headers (verified file:line): `WebKitWebView.h` (86 create docblock, 107-109 policy types, 131-134 load events, 255 load-failed, 260 create, 334 related-view, 343/629 UCM, 412/415/418/442 title/reload/uri); `WebKitPolicyDecision.h:53-63`; `WebKitNavigationAction.h:68,77,86 (get_frame_name)`; `WebKitNavigationPolicyDecision.h:55,70`; `WebKitResponsePolicyDecision.h:64 (is_main_frame_main_resource)`; `WebKitUserContentManager.h:51,119,207,211 (return_error_message)`; `WebKitJavascriptResult.h:57`; `jsc/JSCValue.h:111,119,122,316 (new_string/is_string/to_string/new_from_json)`
- Build: reuse Slice 1 §C6 (C shim + `linkSystemLibrary2(.use_pkg_config=.force)` + explicit `pkg-config --exists` guard + `linkLibC`); add `src/nav_policy.zig`, `src/ipc.zig`, `src/app.zig`.
