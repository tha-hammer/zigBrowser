---
date: 2026-05-31T18:00:00-04:00
planner: maceo (git: tha-hammer)
git_commit: 6a2f913
branch: master
repository: zigBrowser
topic: "Slice 3/4 TDD plan — full JS↔Zig IPC command surface + Windows (WebView2) / macOS (WKWebView) cross-OS backends"
tags: [tdd, plan, ipc, cross-os, webview2, wkwebview, app-shell, slice-3-4]
status: revised-after-review
revision: 2 (addresses PlanReview 2026-05-31; all 7 criticals + 27 warnings)
tier: L3
related_research: thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md
related_review: 2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4/2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4-REVIEW.md
related_beads: [zigBrowser-ml4, zigBrowser-19n, zigBrowser-5ir]
---

# zigBrowser Slice 3/4 — IPC Command Surface + Cross-OS Backends TDD Implementation Plan

## Overview

Expand the JS↔Zig IPC command surface and add **real** Windows (WebView2) and macOS
(WKWebView) backends. The OS-agnostic Zig core is reused across backends with one
**documented, comptime-guarded** exception (`os.info`, see below) — not blindly
"verbatim." Every milestone ends in a human-observable artifact — rendered text, a
real-pixel screenshot, a protocol line on stdout, or a distinct exit code — never
"tests green" alone.

This plan builds on a **now-live seam** (commits `994f7a2`, `3c8dbe8`): the Zig
`ipc.zig`/`nav_policy.zig` modules are hard-linked (`nm` shows them defined), the C
fallbacks are deleted, the build hard-fails if the core is unlinked, the Zig unit
tests run under `zig build test` (24/24), and a `..`-traversal E2E discriminator
proves the real `nav_policy.zig` is live.

> **Revision 2.** This revision resolves every critical and warning from the
> 2026-05-31 PlanReview. The headline fixes: a new prerequisite milestone **M0**
> de-GTK-ifies the C seam (`void *native_view`), adds the missing exit codes
> (`RuntimeMissing`=9, `WebViewInitFailed`=10), and adds the `os.info` per-OS comptime
> branch — the three compile/contract blockers that previously made M8/M9
> unbuildable. See **§Review Resolutions** for the full mapping.

## Scope of "verbatim reuse" (corrected)
- **Reused verbatim across all backends**: `nav_policy.zig` (`decide`/`zb_policy_decide`)
  and the `ipc.zig` `dispatch` table *structure* + its C-ABI adapter `zb_ipc_dispatch`
  (buffers, error-code mapping, `copyToCStr`).
- **NOT verbatim — documented per-OS branch**: the `os.info` command body calls
  `std.posix.uname()` (`ipc.zig:28`), which is POSIX-only and **will not compile on a
  Windows target**. M0 adds a `comptime builtin.os.tag` branch (macOS/Linux keep
  `uname`; Windows returns `{sysname:"Windows", release:<comptime const>, machine:@tagName(builtin.cpu.arch)}`).
  This is the single intentional divergence from verbatim reuse.

## Current State Analysis

**What exists (verified reality, post-remediation @ `6a2f913`):**
- One live backend: WebKitGTK + GTK3; all platform code in `src/webkit_shim.c` behind
  the plain-C `zb_*` seam in `src/webkit_shim.h`.
- IPC command surface = Zig `dispatch()` (`ping`/`add`/`os.info`), linked and exercised
  by `zig build test` and the Python E2E harness.
- Nav policy = Zig `decide()` (`file://`-only canonical-path containment, POSIX `./..`
  normalization), live.
- `build.zig` links `webkit2gtk-4.1`/`gtk+-3.0`/`gio-unix-2.0` **unconditionally** in
  `configureWebKit()` at **`build.zig:89-99`**; the test step wires the `ipc`/`nav_policy`
  modules at `build.zig:49-86`. There is no target/OS branch and no backend selection.

### Key Discoveries (citations re-verified @ `6a2f913`)
- `src/ipc.zig:14-38` — `dispatch()` command if-chain; extension point for new commands.
- `src/ipc.zig:26-35` — `os.info` calls `std.posix.uname()` — **POSIX-only** (M0 guard).
- `src/ipc.zig:40-72` — `zb_ipc_dispatch` C-ABI adapter; threadlocal 8KB scratch / 4KB
  result / 128B err (`copyToCStr` fails closed on oversize, `ipc.zig:64-68,128-133`).
- `src/ipc.zig:121-126` — `ipcErrorCode` maps `UnknownCommand`→1, `BadArgs`→2.
- `src/nav_policy.zig:24-144` — `decide()` + POSIX normalization; the traversal discriminator.
- `src/webkit_shim.h:34-45` — the plain-C `zb_*` seam (eight functions). **`webkit_shim.h:40`
  declares `zb_window_new(ZbApp *app, WebKitWebView *view)` — the second param is a
  GTK-named type** (forward-declared opaque at `webkit_shim.h:11`, so it compiles without
  GTK, but it is misleading and M0 type-erases it).
- `src/webkit_shim.h:18-19` — `ZbApp`/`ZbWindow` are **opaque** forward-declared structs
  (portable; no GTK types leak through them).
- `src/webkit_shim.h:21-32` — `ZB_EXIT_*` enum (0,1,2,3,4,5,6,7,8,130) — **mirror of
  errors.zig; M0 adds `ZB_EXIT_RUNTIME_MISSING=9`, `ZB_EXIT_WEBVIEW_INIT_FAILED=10`**.
- `src/errors.zig:20-33` — `exitCode()`; **no `RuntimeMissing`/`WebViewInitFailed`;
  `else => 1` aliases them to Usage** (M0 fixes).
- `build.zig:89-99` — `configureWebKit()` unconditional GTK/WebKit linking — the place
  backend selection is introduced (M4).
- `src/main.zig:32-43` — `.open` path calls `c.zb_app_run(...)`; backend-agnostic.
- `src/webkit_shim.c` — GTK reply path `webkit_script_message_reply_return_value` /
  `_return_error_message`; `load_superseded`/`suppress_success_emit` fields for the
  load-vs-timeout race; `on_signal_term`→130, `on_signal_hup`→reload.
- `tests/e2e/*.py` + `tests/snapshots/pillow_tools.py nonuniform` — real-binary E2E harness.

## Desired End State

A single Zig app-shell model with **three real backends** selectable at build time,
all reusing `nav_policy.zig` + the IPC dispatch table (with the documented `os.info`
branch). The IPC surface gains a new command proven to run through the linked Zig
dispatch. On Windows and macOS CI, a real WebView2 / WKWebView window opens, renders a
real page, and answers a real `zbHost` roundtrip via a **specified reply channel**.

### Observable Behaviors
- A Windows-target build compiles the core (no POSIX error) and the seam header compiles in a non-GTK TU.
- New IPC command (`echo`) returns its exact payload as a typed JS value rendered in a real window.
- `echo` with a bad argument rejects the JS promise with `BadArgs` (genuinely new error path).
- A `..`-traversal navigation is BLOCKED identically on every backend via the shared `nav_core`.
- `zig build -Dtarget=…` links exactly one backend; an unmapped target hard-fails with a build-stderr message.
- A hanging load recovers (error page + `LOAD_FAIL`, window alive); a success at T-ε wins the race (no `LOAD_FAIL`).
- SIGINT during a load cancels in-flight and exits 130 within 3 s.
- A real WebView2 (Windows CI) and WKWebView (macOS CI) window renders a real page and answers `ping`→`pong`; a missing runtime exits with a **distinct** code (9/10).

## What We're NOT Doing
- Async IPC commands (`g_idle_add` + reply-timeout) — synchronous main-loop dispatch only (so `ipc_reply` carries no `Timeout`).
- Download handling; sub-frame policy granularity; tabs / address bar / bookmarks (**cut**).
- SIGHUP→reload on the Windows backend — SIGHUP is POSIX-only; it stays a GTK/POSIX behavior (tested on GTK, out of scope for WebView2).
- Re-establishing the GTK seam — landed in `994f7a2`/`3c8dbe8`.

## Decisions (resolved open questions)
- **Recovery is per-backend, not centralized** (shared cores never touch the webview):
  each backend re-implements gtk's timeout + cancel + error-page with its own APIs.
  Error-path coverage is **N+1**.
- **Cross-OS hardware gate.** M0–M7 ship in this slice (observable on Linux/GTK + build
  tests + Windows-target *compile*). **M8 (Windows runtime) / M9 (macOS runtime) are
  gated on Windows/macOS CI**; absent CI they split to a hardware-provisioned Slice 4 —
  not stubbed, not dropped.
- **C fallbacks removed** (done in remediation); the build hard-fails if the core is unlinked.

## Contracts & Reference Tables

### Seam contract after M0 (the "stable contract; backends match exactly")
```c
/* webkit_shim.h — eight entry points every backend implements */
int  zb_run_open(const char *uri, int print_title);           /* legacy one-shot; delegates to zb_app_run(e2e=0) */
int  zb_app_run(const char *uri, int print_title, int e2e_protocol);
int  zb_run_screenshot(const char *uri, const char *out_path, int print_title);
void zb_version_line(char *buf, size_t len);
void zb_reload(ZbWindow *win, int bypass_cache);
ZbWindow *zb_window_new(ZbApp *app, void *native_view);       /* M0: was WebKitWebView*; now type-erased */
/* engine->host exports provided by Zig, consumed weakly by the shim: */
int  zb_policy_decide(const char *base, const char *candidate, int dtype);
int  zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result, const char **out_err);
```
Each backend casts `native_view` internally to its concrete type, documented by a
one-line comment at the cast site: GTK `WebKitWebView *`, Windows `ICoreWebView2 *`,
macOS `WKWebView *`. `ZbApp`/`ZbWindow` remain opaque (no GTK leakage).

### Error catalog (post-M0) — exit codes + retryability
All errors are **non-retryable** (log + halt; the JS handler surfaces a rejected promise). No retry/backoff this slice.

| Error | exit | `ZB_EXIT_*` | Source | Surfaced as |
|---|---|---|---|---|
| Usage | 1 | `ZB_EXIT_USAGE` | cli | stderr usage |
| InvalidUri / UnsupportedScheme | 2 | `ZB_EXIT_INVALID_URI` | uri | stderr |
| DisplayUnavailable | 3 | … | gtk_backend | stderr |
| GtkInitFailed | 4 | … | gtk_backend | stderr |
| LoadFailed | 5 | … | all backends | `LOAD_FAIL` line |
| SnapshotFailed | 6 | … | screenshot path | stderr |
| WriteFailed | 7 | … | screenshot path | stderr |
| Timeout | 8 | … | all backends | `LOAD_FAIL` line |
| **RuntimeMissing** (NEW) | **9** | **`ZB_EXIT_RUNTIME_MISSING`** | win_backend | stderr |
| **WebViewInitFailed** (NEW) | **10** | **`ZB_EXIT_WEBVIEW_INIT_FAILED`** | macos_backend | stderr |
| Cancelled (SIGINT/SIGTERM) | 130 | `ZB_EXIT_CANCELLED` | all backends | clean teardown |

`errors.zig:exitCode()` and the `ZB_EXIT_*` enum (`webkit_shim.h:21-32`) are kept in lock-step. Foreign errors (WebView2 `HRESULT`, WKWebView `NSError`) are mapped to one of the above **inside each shim** before returning from `zb_app_run`/`zb_run_screenshot`; raw `HRESULT`/`NSError` values never propagate past the seam.

### E2E protocol line schema (normative — checked-in as `tests/e2e/PROTOCOL.md`)
Tab-separated, one line per event, flushed per line, fields sanitized (tab/newline-stripped).

| Prefix | Fields (after prefix) | Example |
|---|---|---|
| `NAV` | `<uri>` `<title>` | `NAV\tfile:///app/index.html\tHome` |
| `IPC` | `<cmd>` `<result_json>` | `IPC\techo\t"hi-42"` |
| `IPCERR` | `<cmd>` `<error_name>` | `IPCERR\tfrobnicate\tUnknownCommand` |
| `BLOCKED` | `<candidate_uri>` | `BLOCKED\tfile:///etc/passwd` |
| `LOAD_FAIL` | `<uri>` `<domain>` `<code>` | `LOAD_FAIL\tfile:///x\t1\t-2` |
| `SUBWIN` | `<uri>` | `SUBWIN\tfile:///app/child.html` |
| `WINCOUNT` | `<n>` | `WINCOUNT\t2` |

### JS reply contract (per backend) — how a dispatch result reaches the JS Promise
The fixture posts `{cmd,args}` and awaits a Promise. The reply channel differs per engine but the **contract is identical**: success → resolve with the typed value from `jsc_value_new_from_json`-equivalent; error → reject with an `Error` whose `.message` is the `@errorName` string.

| Backend | JS post API | Reply mechanism |
|---|---|---|
| GTK (live) | `window.webkit.messageHandlers.zbHost.postMessage` | `webkit_script_message_reply_return_value` / `_return_error_message` |
| Windows (M8) | `window.chrome.webview.postMessage` | `ICoreWebView2::PostWebMessageAsString` from the controller on the UI thread; JS resolves a pending Promise keyed by request id |
| macOS (M9) | `window.webkit.messageHandlers.zbHost.postMessage` | `WKScriptMessageHandlerWithReply` `reply(withResult:errorMessage:)` (macOS 12+); fallback `evaluateJavaScript:` resolving a pending Promise |

The fixture uses a **thin JS bridge** (`tests/fixtures/app/zbhost.js`) that normalizes the post call per engine (`window.webkit…` vs `window.chrome.webview…`) and exposes one `zbHost(cmd,args) → Promise`. One shared fixture, no per-backend HTML.

### Thread ownership of IPC dispatch
`zb_ipc_dispatch` uses **threadlocal** buffers, so it must be invoked on a single,
consistent thread per backend. The seam requires script-message callbacks to call
dispatch on the **UI/main thread**: GTK main loop (current); WebView2 message handler
(UI thread); WKWebView handler (main thread). Each backend's Green step states this.

## Testing Strategy
- **Framework**: Zig 0.16 `std.testing` via `zig build test`; Python E2E harness in
  `tests/e2e/` driving the **real compiled binary** with `--e2e-protocol`; screenshot
  PNG oracle via `tests/snapshots/pillow_tools.py nonuniform`.
- **Test Types**:
  - *Compile gate* (`zig build -Dtarget=…`): M0 (Windows-target compile), M4/M5 (selection).
  - *Unit* (`zig build test`): M1 (echo + property), M2 (echo bad-args), M3 (nav decisions).
  - *GTK/Linux E2E*: M1–M3, M6, M7.
  - *Cross-OS E2E* (Windows + macOS CI): M8, M9, plus re-runs of M3/M6/M7 per OS.
- **Oracle discipline**: every test asserts against an independent oracle (literal sent
  value, hand-computed normalization, fixed error constants, known fixture pixels via
  pillow, **distinct** exit-code values) — never against what the same code produced.

---

## Behavior M0: cross-OS seam prerequisites (compile-level)  ⟵ NEW, blocks M4/M8/M9

### Test Specification
**Given**: the current tree, where `zb_window_new` names `WebKitWebView*`, `errors.zig`
lacks `RuntimeMissing`/`WebViewInitFailed`, and `os.info` calls `std.posix.uname()`.
**When**: `zig build` (linux) and `zig build -Dtarget=x86_64-windows-gnu` are run, and
`errors.exitCode(error.RuntimeMissing)` / `(error.WebViewInitFailed)` are evaluated.
**Then**: (a) linux build stays green; (b) the Windows-target build compiles
`ipc.zig`/`nav_policy.zig` and `webkit_shim.h` **past the POSIX error** (reaches the
link stage — link may still fail for lack of a Windows backend, that is M8); (c)
`exitCode(RuntimeMissing)==9`, `exitCode(WebViewInitFailed)==10`.

**Edge Cases**: macOS target (Darwin) keeps `uname` (no branch needed); `ZB_EXIT_*` enum
stays numerically equal to `errors.zig`; GTK `zb_window_new` still casts `native_view`
to `WebKitWebView*` with no behavior change.

**Files touched**: `src/webkit_shim.h` (param type + two enum values), `src/webkit_shim.c`
(internal cast at the `zb_window_new` call site), `src/errors.zig` (two error tags + two
switch arms), `src/ipc.zig` (`os.info` comptime branch), `tests/*` (a Windows-target
compile-gate script + `errors` unit test).

### TDD Cycle
#### 🔴 Red
A compile-gate test running `zig build -Dtarget=x86_64-windows-gnu` — **fails today** with
`std.posix.uname` unavailable on Windows. Plus a unit test:
```zig
test "new cross-os exit codes are distinct" {
    try std.testing.expectEqual(@as(u8, 9), errors.exitCode(error.RuntimeMissing));
    try std.testing.expectEqual(@as(u8, 10), errors.exitCode(error.WebViewInitFailed));
}
```
(fails: tags don't exist / `else=>1`).
#### 🟢 Green
1. `errors.zig`: add `RuntimeMissing`, `WebViewInitFailed` tags; `error.RuntimeMissing => 9`,
   `error.WebViewInitFailed => 10` arms. Mirror `ZB_EXIT_RUNTIME_MISSING=9`,
   `ZB_EXIT_WEBVIEW_INIT_FAILED=10` in `webkit_shim.h`.
2. `webkit_shim.h`: `zb_window_new(ZbApp *app, void *native_view)`; `webkit_shim.c` casts
   `(WebKitWebView *)native_view` at the call site (one-line comment).
3. `ipc.zig` `os.info`:
   ```zig
   const uts = switch (@import("builtin").os.tag) {
       .windows => OsInfo{ .sysname = "Windows", .release = win_release_const, .machine = @tagName(@import("builtin").cpu.arch) },
       else => blk: { const u = std.posix.uname(); break :blk OsInfo{ .sysname = sliceTo(u.sysname), .release = sliceTo(u.release), .machine = sliceTo(u.machine) }; },
   };
   ```
#### 🔵 Refactor
Extract a tiny `os_info.zig` helper if the branch grows; keep the dispatch if-chain flat. No new GTK dependency introduced.

### Success Criteria
**Automated:** linux `zig build` + `zig build test` green; `zig build -Dtarget=x86_64-windows-gnu`
compiles the core (reaches link); the new exit-code unit test green; `ZB_EXIT_*` ≡ `errors.zig`.
**Manual:** the seam header contains no engine-specific parameter type.

---

## Behavior M1: echo command roundtrip

### Test Specification
**Given**: a real WebKitGTK window with `ipc.zig` linked and a new `echo` branch in `dispatch()`.
**When**: JS calls `zbHost("echo", {msg:"hi-42"})` (via the shared `zbhost.js` bridge).
**Then**: the Promise resolves to the typed JS string `"hi-42"`, rendered into the DOM; stdout emits `IPC\techo\t"hi-42"`.

**Echo args schema**: `{ "msg": string }` — `msg` **required**; empty string **valid**;
max byte length = 4096 − JSON quoting(2) − NUL(1) = **4093 bytes** of UTF-8 payload.

**Edge Cases**: empty-string `msg` → returns `""` (distinct from missing key); missing
`msg` → `BadArgs` (M2); JSON-encoded result > 4096 incl. quotes+NUL → `BadArgs` fail-closed
(`copyToCStr`, `ipc.zig:64-68`); non-string `msg` → `BadArgs` (M2).

**Property**: for any UTF-8 string `s` with `len(jsonEncode(s)) + 1 ≤ 4096`,
`dispatch("echo", {msg:s}) == jsonEncode(s)` (round-trip identity). Generator bound = the
4096-byte ceiling above.

**Files touched**: `src/ipc.zig`, `tests/ipc_test.zig`, `tests/e2e/ipc_roundtrip_test.py`,
`tests/fixtures/app/index.html`, `tests/fixtures/app/zbhost.js`.

### TDD Cycle
#### 🔴 Red
```zig
test "dispatch echo returns the exact payload" {
    const a = std.testing.allocator;
    const out = try ipc.dispatch(a, "echo", "{\"msg\":\"hi-42\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"hi-42\"", out);
}
```
Plus a failing E2E asserting the page shows `hi-42` and an `IPC\techo\t"hi-42"` line.
#### 🟢 Green
```zig
fn parseEchoArg(allocator: std.mem.Allocator, args_json: []const u8) IpcError![]const u8; // returns the msg slice (arena-owned)
if (std.mem.eql(u8, cmd, "echo")) {
    const msg = try parseEchoArg(allocator, args_json);
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg, .{})}) catch return error.BadArgs;
}
```
`parseEchoArg` keeps the `IpcError![]const u8` discipline (errors propagate via `try`); the returned slice is allocator-owned.
#### 🔵 Refactor
Extract the single-string-arg parse shared with future commands; keep `dispatch()` flat. No new branches beyond the command.

### Success Criteria
**Automated:** Red fails (`echo` unknown); Green passes; `zig build test` + E2E green; no duplicated arg-parsing (jscpd).
**Manual:** window visibly shows `hi-42`; `echo` exists in no non-Zig path (negative control).

---

## Behavior M2: echo argument-error rejects the JS promise  (Red is genuinely red)

> **Review fix:** the previous M2 unit Red (`expectError(UnknownCommand, dispatch("frobnicate"))`)
> was already green on existing code. The genuine new error path is `echo`'s argument
> validation, which does **not** exist until M1. Unknown-command / malformed-`add` cases
> are retained only as **regression guards** (already green, explicitly labeled), not the
> Red discriminator.

### Test Specification
**Given**: M1's `echo` is implemented in the live Zig dispatch.
**When**: JS calls `zbHost("echo", {})` (missing `msg`) or `zbHost("echo", {msg:42})` (non-string).
**Then**: the Promise rejects with an `Error` whose `.message == "BadArgs"`; stdout emits `IPCERR\techo\tBadArgs`.

**Regression guards (already green):** `zbHost("frobnicate")` → reject `UnknownCommand` + `IPCERR\tfrobnicate\tUnknownCommand`; `zbHost("add",{a:1})` → `BadArgs`.

**JS rejection value shape**: the JS side receives a **rejected Promise**; the rejection
reason is an `Error` whose `message` equals the `@errorName` string (e.g. `"BadArgs"`).
Not a structured object.

**Edge Cases**: whitespace-only args to a no-arg command accepted (`expectNoArgs`);
`add` with 3 keys → `BadArgs`; `number_string` vs `integer` coercion in `valueToI64`.

**Files touched**: `src/ipc.zig` (echo arg validation in `parseEchoArg`), `tests/ipc_test.zig`, `tests/e2e/ipc_roundtrip_test.py`.

### TDD Cycle
#### 🔴 Red (genuinely fails until echo arg-validation exists)
```zig
test "echo with missing msg errors" {
    try std.testing.expectError(error.BadArgs, ipc.dispatch(std.testing.allocator, "echo", "{}"));
}
test "echo with non-string msg errors" {
    try std.testing.expectError(error.BadArgs, ipc.dispatch(std.testing.allocator, "echo", "{\"msg\":42}"));
}
```
Plus an E2E asserting the `echo` promise rejects and `IPCERR\techo\tBadArgs` is emitted.
#### 🟢 Green
Implement `parseEchoArg` validation (`object` with required string `msg`); reuse the existing `ipcErrorCode`→reply path (`ipc.zig:121-126`).
#### 🔵 Refactor
Single-source the `@errorName`→reply-string mapping; ensure the regression guards stay green.

### Success Criteria
**Automated:** both echo-arg Red tests fail first, pass after Green; regression guards stay green; E2E `IPCERR\techo\tBadArgs` present.
**Manual:** the page surfaces the rejected-promise `Error.message == "BadArgs"`.

---

## Behavior M3: cross-OS-shared nav traversal block

### Test Specification
**Given**: a backend with `app_base = file:///app/` and shared `nav_policy.zig` linked.
**When**: a navigation to `file:///app/../etc/passwd` is attempted.
**Then**: BLOCKED (`decision=ignore`); stdout emits `BLOCKED\tfile:///etc/passwd` — identically on GTK/WebView2/WKWebView (same `zb_policy_decide`).

**Edge Cases**: `file://localhost/app/` host accepted; non-`file` scheme → ignore; `/app` exact (no trailing slash) containment edge.

**Property**: for any path `p`, a candidate normalizing outside `app_base` ⇒ `ignore`.

**Files touched**: `tests/nav_policy_test.zig`, `tests/e2e/nav_block_test.py` (+ per-OS variants in M8/M9).

### TDD Cycle
#### 🔴 Red
```zig
test "traversal escaping app_base is ignored" {
    try std.testing.expectEqual(nav_policy.Decision.ignore,
        nav_policy.decide("file:///app/", "file:///app/../etc/passwd", .navigation_action));
}
```
#### 🟢 Green
Satisfied by `nav_policy.zig:110-144`; assert via the E2E `BLOCKED` line.
#### 🔵 Refactor
None beyond naming; the discriminator must remain (cross-OS reuse proof).

### Success Criteria
**Automated:** unit + E2E green; hand-computed oracle (`/etc/passwd ∉ /app/`) matches.
**Manual:** no off-tree navigation; `BLOCKED` line present.

---

## Behavior M4: build selects exactly one backend by target

### Test Specification
**Given**: `build.zig` with a target→backend selection table (introduced at `build.zig:89-99`, the current unconditional `configureWebKit()` site).
**When**: `zig build -Dtarget=x86_64-linux` / `-Dtarget=x86_64-windows` / `-Dtarget=aarch64-macos`.
**Then**: exactly one backend is compiled+linked; `--version` reports the matching engine.

**Backend selection table (concrete schema)** — comptime, keyed on `target.os.tag`:
```zig
const Backend = struct { c_source: []const u8, link_libs: []const []const u8, configure: *const fn(*std.Build.Module,*std.Build) void };
const BACKENDS = std.enums.directEnumArray(std.Target.Os.Tag, ?Backend, 0, .{
    .linux   = .{ .c_source = "src/webkit_shim.c",   .configure = configureWebKit },
    .windows = .{ .c_source = "src/webview2_shim.c", .configure = configureWebView2 },
    .macos   = .{ .c_source = "src/wkwebview_shim.m", .configure = configureWKWebView },
    // all other tags => null => NoBackendLinked (M5)
});
```
`configure<Backend>(module: *std.Build.Module, b: *std.Build) void` is the uniform signature (matches the existing `configureWebKit`).

**`--version` format per engine** (prefix `zigBrowser — <Engine> <semver…>`):
- GTK: `zigBrowser — WebKitGTK x.y.z, GTK a.b.c`
- Windows: `zigBrowser — WebView2 <runtime-version>`
- macOS: `zigBrowser — WKWebView <os-version>`

`root.zig:isVersionLine` is generalized to accept the engine-agnostic `zigBrowser — ` prefix + a known engine token.

**Edge Cases**: unknown target triple → `NoBackendLinked` (M5); two backends linked → build error (exactly-one invariant).

**Files touched**: `build.zig`, `src/webkit.zig` (per-backend version line), `src/root.zig` (generalized prefix), `tests/build_select_test.*`.

### TDD Cycle
#### 🔴 Red
A build test invoking `zig build -Dtarget=…` asserting the linked backend's entry points (`nm`) / the `--version` engine token; fails before the table exists.
#### 🟢 Green
Replace the unconditional `configureWebKit` call (`build.zig:89-99`) with a `BACKENDS[target.os.tag]` lookup that calls the selected `configure`.
#### 🔵 Refactor
Keep `configureWebKit` as one table entry (no shallow wrapper); single selection site.

### Success Criteria
**Automated:** linux links GTK and `--version` matches the generalized `isVersionLine`; unsupported target → M5; `nm` shows the expected `zb_app_run`.
**Manual:** a runnable binary prints its engine identity.

---

## Behavior M5: build hard-fails when no backend is linked

### Test Specification
**Given**: a target whose `os.tag` maps to `null` in `BACKENDS`.
**When**: `zig build -Dtarget=<unmapped>`.
**Then**: the build FAILS via **`@compileError("NoBackendLinked: no backend for <target>")`** in `build.zig`, surfaced as a `zig build` stderr line; nonzero exit; no binary emitted.

**Emission mechanism (explicit):** `@compileError` in `build.zig` (not a panic, not a
runtime check) so the literal `NoBackendLinked` substring appears in `zig build` stderr.

**Edge Cases**: partial backend (missing entry points) → link error; this guard is the
build-time analog of the existing Zig-core link gate (`994f7a2`).

**Files touched**: `build.zig`, `tests/build_select_test.*`.

### TDD Cycle
#### 🔴 Red
A build test for an unmapped target expecting nonzero exit + `NoBackendLinked` substring; currently a build might fall through.
#### 🟢 Green
Add the `@compileError` on the `null` table arm.
#### 🔵 Refactor
Share the diagnostic phrasing with the Zig-core link guard; one assertion site.

### Success Criteria
**Automated:** build exit ≠ 0 + literal `NoBackendLinked` in stderr; no binary.
**Manual:** stderr names the failure clearly.

---

## Behavior M6: per-backend load-timeout recovery (with race resolution)

### Test Specification
**Given**: a backend launched against a URI that never finishes loading.
**When**: the per-backend load timeout (15 s, the existing GTK constant) elapses.
**Then**: the window stays alive showing an error page; stdout emits `LOAD_FAIL\t<uri>\t<domain>\t<code>`; no crash.

**Timeout-vs-completion race (resolved):** whichever fires **first** wins. If load
completion fires before the timeout → the timeout is cancelled, `NAV` is emitted, no
`LOAD_FAIL`. If the timeout fires first → it cancels the load (`load_superseded=1`,
`suppress_success_emit`), emits `LOAD_FAIL`, and a late completion is suppressed. E2E
variant: deliver a successful load at **T−ε** before the timeout → assert `NAV`, **no**
`LOAD_FAIL`.

**New-backend recovery tracking struct (schema, mirrors GTK `ZbWindow` recovery fields):**
`{ native_view, current_uri, seed_uri, load_superseded:bool, suppress_success_emit:bool,
timeout_source_id, cancellable }` — `ZbWinWindow` (WebView2) / `ZbMacWindow` (WKWebView).

**Edge Cases**: each backend mirrors gtk's 15 s timeout + cancel (WebView2 nav-timeout;
WKWebView `WKNavigationDelegate` + `stopLoading`); reload after failure recovers.

**Files touched**: `src/webkit_shim.c` (exists), `src/webview2_shim.c` / `src/wkwebview_shim.m`, `tests/e2e/reload_test.py` (+ per-OS variants).

### TDD Cycle
#### 🔴 Red
E2E pointing at a hanging URI, expecting `LOAD_FAIL` + process alive past the timeout; plus the T−ε success variant expecting `NAV` and no `LOAD_FAIL`.
#### 🟢 Green
Per-backend timeout + cancel + error-page (GTK exists); new backends implement with their APIs and the tracking struct above.
#### 🔵 Refactor
Hoist the shared recovery **contract** (timeout const, error-page URI, `LOAD_FAIL` emit, race rule) into a documented spec each backend satisfies (shared spec, platform-specific code).

### Success Criteria
**Automated:** `LOAD_FAIL` + bounded-liveness green; T−ε race variant green (NAV, no LOAD_FAIL).
**Manual:** error page visible in a still-open window.

---

## Behavior M7: cancel-in-flight load on window close

### Test Specification
**Given**: a backend with a load in flight.
**When**: the window is closed via SIGINT.
**Then**: the in-flight load is cancelled and the process exits **130 within 3 s** (`ZB_SIGINT_DEADLINE_S = 3`, reused by the kill-timer and teardown path); no hang, no zombie.

**Edge Cases**: SIGTERM → 130; close during IPC reply dispatch (reply abandoned cleanly).

**SIGHUP scope (resolved):** SIGHUP→reload `windows[0]` is a **GTK/POSIX-only** behavior;
it gets a GTK E2E case + success criterion. SIGHUP does not exist on Windows → explicitly
**out of scope** for the WebView2 backend (noted in M8). Not a dangling promise.

**Files touched**: `src/webkit_shim.c` (GTK signal handlers exist), new backend shims, `tests/e2e/lifecycle_test.py`, `tests/e2e/sighup_reload_test.py` (GTK-only).

### TDD Cycle
#### 🔴 Red
E2E sending SIGINT during a load, expecting exit 130 within 3 s; a GTK-only SIGHUP test expecting a reload (`NAV` re-emitted) and continued life.
#### 🟢 Green
Wire cancel-on-close per backend (GTK `on_signal_term`→130 exists); GTK SIGHUP→`zb_reload(...,0)` exists.
#### 🔵 Refactor
Unify signal→cancel→quit teardown; share `ZB_SIGINT_DEADLINE_S`.

### Success Criteria
**Automated:** exit 130 (`errors.zig:exitCode(Cancelled)`) within 3 s; GTK SIGHUP reload green.
**Manual:** clean teardown on stdout.

---

## Behavior M8: Windows WebView2 backend — real window + page + ping  ⚠ HW gate (Windows CI)

### Test Specification
**Given**: a Windows CI runner with the WebView2 Runtime installed and `win_backend` linked (M4).
**When**: `zigBrowser <file-uri-to-known-fixture> --e2e-protocol` runs.
**Then**: a real WebView2 window opens, renders the real fixture, and `zbHost("ping")` returns `"pong"` (via `chrome.webview.postMessage` → `PostWebMessageAsString` reply, per the JS reply contract).

**Reply channel (normative — test authored against this BEFORE impl):** JS posts via
`window.chrome.webview.postMessage(JSON.stringify({id,cmd,args}))`; the shim's
`add_WebMessageReceived` handler calls `zb_ipc_dispatch` **on the UI thread** and replies
with `PostWebMessageAsString(JSON.stringify({id,result|error}))`; `zbhost.js` resolves the
Promise keyed by `id`. This is the independent contract the ping→pong E2E asserts against,
so the test exists before the implementation (TDD order preserved).

**Foreign-error mapping:** WebView2 `HRESULT` failures are mapped inside `webview2_shim.c`
to `ZB_EXIT_*` before returning (`E_*` runtime-missing → `RuntimeMissing`/9; nav failure →
`LoadFailed`/5; timeout → `Timeout`/8). Raw `HRESULT` never propagates.

**Edge Cases**: WebView2 Runtime missing → **exit 9 (`RuntimeMissing`)**, distinct from
Usage(1); load timeout → exit 8 + stay-alive (M6); SIGHUP n/a on Windows.

**Seam completeness:** implements all eight `zb_*` functions incl. `zb_run_open`
(delegates to `zb_app_run(e2e=0)`), casting `native_view`→`ICoreWebView2*`.

**Files touched**: `src/webview2_shim.c` (NEW), `build.zig` (windows arm), `src/errors.zig`
(already has codes from M0), `tests/e2e/` Windows job, known fixture, `tests/fixtures/app/zbhost.js`.

### TDD Cycle
#### 🔴 Red
Windows-CI E2E: open window, render fixture (pillow nonuniform), `ping`→`pong` (asserted against the reply-channel contract); runtime-missing case asserts **exit 9**. Fails (no `win_backend`).
#### 🟢 Green
Implement `win_backend`: WebView2 host, UI-thread dispatch, `PostWebMessageAsString` reply, all eight `zb_*` entry points calling the unchanged Zig core; `HRESULT`→`ZB_EXIT_*` mapping.
#### 🔵 Refactor
Factor the host-channel + id-keyed reply glue shared with M9.

### Success Criteria
**Automated:** `pillow nonuniform` on the WebView2 screenshot + known `pong`; runtime-missing → **exit 9** (not 1). On Windows CI.
**Manual:** a human sees a real WebView2 window with the page.
**Gate:** requires Windows CI — else split to Slice 4.

---

## Behavior M9: macOS WKWebView backend — real window + page + ping  ⚠ HW gate (macOS CI)

### Test Specification
**Given**: a macOS CI runner and `macos_backend` (WKWebView + script-message handler) linked (M4).
**When**: `zigBrowser <file-uri-to-known-fixture> --e2e-protocol` runs.
**Then**: a real WKWebView window opens, renders the real fixture, and `zbHost("ping")` returns `"pong"`.

**Reply channel (normative):** `window.webkit.messageHandlers.zbHost.postMessage`;
the shim uses `WKScriptMessageHandlerWithReply` `reply(withResult:errorMessage:)` (macOS 12+),
calling `zb_ipc_dispatch` **on the main thread**; fallback `evaluateJavaScript:` resolving a
pending Promise keyed by id. Same contract as M8; the ping→pong E2E is authored against it first.

**Foreign-error mapping:** WKWebView `NSError` (domain/code) is mapped inside
`wkwebview_shim.m` to `ZB_EXIT_*` before returning (init failure → `WebViewInitFailed`/10;
nav failure → `LoadFailed`/5; timeout → `Timeout`/8). Raw `NSError` never propagates.

**Edge Cases**: WKWebView init failure → **exit 10 (`WebViewInitFailed`)**; `LoadFailed` on bad URI; `os.info` uses `uname` verbatim (Darwin is POSIX).

**Seam completeness:** all eight `zb_*` incl. `zb_run_open`; cast `native_view`→`WKWebView*`.

**Files touched**: `src/wkwebview_shim.m` (NEW, Obj-C), `build.zig` (macos arm), `tests/e2e/` macOS job, known fixture, `tests/fixtures/app/zbhost.js`.

### TDD Cycle
#### 🔴 Red
macOS-CI E2E: open window, render fixture (pillow nonuniform), `ping`→`pong` (against the reply-channel contract); init-failure case asserts **exit 10**. Fails (no `macos_backend`).
#### 🟢 Green
Implement `macos_backend`: WKWebView host, main-thread dispatch, `WKScriptMessageHandlerWithReply`, all eight `zb_*` calling the unchanged core; `NSError`→`ZB_EXIT_*` mapping.
#### 🔵 Refactor
Align with the M8 host-channel/id-keyed-reply contract.

### Success Criteria
**Automated:** `pillow nonuniform` on the WKWebView screenshot + known `pong`; init-failure → **exit 10**. On macOS CI.
**Manual:** a human sees a real WKWebView window with the page.
**Gate:** requires macOS CI — else split to Slice 4.

---

## Integration & E2E Testing
- **Compile gate**: M0 (Windows-target compile), M4/M5 (selection) — exit-code oracle.
- **Integration**: M4/M5 across target triples.
- **E2E (Linux/GTK)**: M1–M3, M6, M7 (+ GTK-only SIGHUP) on the real binary + pillow oracle.
- **E2E (cross-OS)**: M8, M9, and re-runs of M3/M6/M7 on Windows + macOS CI to prove
  `nav_core` + dispatch table reuse (with the documented `os.info` divergence).

## Order
M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9
(seam prerequisites first; pure-logic + GTK E2E; build selection; recovery; hardest cross-OS last).

## Risks / Constraints
- **Win/macOS CI availability** gates M8/M9; absent it they split to Slice 4 (not stubbed).
- **Per-backend recovery is platform-specific** (shared spec, not shared code).
- The `zb_*` seam after M0 is **type-erased** (`void *native_view`) — "match exactly" is now literally satisfiable by all three backends.
- `os.info` is the **one** non-verbatim command (comptime per-OS branch); the IPC surface
  is otherwise identical across OS targets (verified by re-running M1/M2 on each CI).

## Review Resolutions (PlanReview 2026-05-31 → this revision)
| # | Critical finding | Resolution |
|---|---|---|
| 1 | `zb_window_new` embeds GTK type `WebKitWebView*` | **M0**: seam param → `void *native_view`; GTK casts internally; §Seam contract |
| 2 | `RuntimeMissing`/`WebViewInitFailed` absent from `errors.zig` (alias to 1) | **M0**: add tags + arms (9/10) + `ZB_EXIT_*`; M8/M9 `Files touched` include `errors.zig`; oracles assert 9/10 |
| 3 | `os.info` `std.posix.uname()` POSIX-only — breaks Windows compile | **M0**: comptime `builtin.os.tag` branch; §Scope of "verbatim reuse" qualifies the claim |
| 4 | JS→backend reply mechanism GTK-only | §JS reply contract table + per-milestone "Reply channel (normative)"; tests authored against the contract |
| 5 | M8/M9 error oracles pass for any exit | Fixed by #2 — oracles assert **distinct** codes 9/10 |
| 6 | M2 Red self-passing | M2 redefined around `echo` arg-errors (genuinely red until M1); unknown-cmd kept as labeled regression guards |
| 7 | M8/M9 ping→pong test can't precede impl | Reply-channel contract is now normative → test authored first (TDD order preserved) |

**Warnings resolved:** stale `build.zig:53-63` → corrected to `89-99` (+ test-module note);
`zb_run_open` added to M8/M9 seam checklist; `UnsupportedTarget`/`NoBackendLinked` emission =
`@compileError`→stderr; `parseEchoArg` signature stated; `configure<Backend>()` signature
stated; `ZbApp`/`ZbWindow` opacity confirmed; retryability catalog (all non-retryable);
M7 bound = 3 s; M6 race rule + T−ε variant; thread-ownership (UI/main) documented;
SIGHUP scoped GTK/POSIX-only; echo JSON schema + property ceiling (4093/4096); backend table
schema; recovery tracking-struct schema; E2E protocol table; JS rejection value shape
(`Error.message == @errorName`); `--version` per-engine format.

## References
- Research: `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`
- Review: `…ENG-0005…slice3-4/…-REVIEW.md`
- Prior plans: ENG-0004 (slice 2), ENG-0003 (slice 1)
- Remediation commits: `994f7a2`, `3c8dbe8` (Zig seam made real; nm-verified; C fallbacks removed)
- Patterns (re-verified @ `6a2f913`): `src/ipc.zig:14-38,26-35,121-126`, `src/nav_policy.zig:24-144`,
  `src/webkit_shim.h:18-19,21-32,34-45`, `src/errors.zig:20-33`, `build.zig:49-86,89-99`, `src/main.zig:32-43`
- Topology: `2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4/`
