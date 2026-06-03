# M8 — Windows WebView2 Backend — TDD Implementation Plan

**Plan:** ENG-0006 · 2026-06-01 (rev 2026-06-02, PlanReview findings resolved) · Tier L3
**Beads:** closes `zigBrowser-182` (os.info comptime + windows backend wired) and `zigBrowser-2nb` (WebView2 renders + answers ping); under epic `zigBrowser-ml4`.
**Topology:** see sibling dir `2026-06-01-18-16-ENG-0006-tdd-windows-webview2-backend-m8/` (`components.yaml`, `flows.yaml`, `diagram.mmd`) — closure-lint green (6 components, 8 flows, 0 diagnostics).

> **Tier note (rev 2026-06-02):** this plan is genuinely **L3** — it stands up native COM (CoreWebView2), a Win32 message pump, and an OS-thread-affine reply channel. The PlanReview heuristic scored it **L1** (keyword/size), so its lens was narrower than the work; the two critical findings it nonetheless surfaced (async COM init, COM apartment) are exactly the L3-class mechanics that the narrow lens almost missed. They are resolved below. The full set of normative contracts the milestones depend on is consolidated in **§ M8 Normative Contracts** so each milestone references one source of truth.

## Overview

The first non-Linux vertical slice. A **real WebView2 window** opens in the live Win11 KVM guest, renders a **real fixture page**, and answers IPC `ping`/`echo`/`os.info` over the `chrome.webview` **id-correlated reply channel**, with `build.zig` auto-selecting the windows backend by target.

The Zig core (`src/ipc.zig` dispatch, `src/nav_policy.zig`, `src/errors.zig` codes 9/10), the generic `zb_*` C seam (`src/webkit_shim.h`), and the cross-OS-clean `@cImport` layer (`src/webkit.zig`) are **reused**. The only genuinely new code is: the `os.info` comptime branch, the `build.zig` windows arm, and `src/webview2_shim` (the native host that implements the reply channel `zbhost.js` already expects).

Every milestone ends in a **human-observable artifact**, never "tests green". A **provenance gate** runs throughout: `dumpbin`/`nm` must show `zb_ipc_dispatch` + the WebView2 symbols **DEFINED** (cross-OS reuse proven), and `os.info` returning **real Windows values** is the discriminating test that the *same* Zig dispatch ran — the Linux `std.posix.uname` path cannot even compile for windows.

## Current State Analysis

What exists (Linux/GTK, all green and provenance-verified as of Slice 3/4): the WebKitGTK backend, the Zig IPC/nav core, build-time backend selection (linux only), and the full E2E protocol harness. What's missing: any non-Linux backend, a cross-OS-clean Zig core, and a native implementation of the WebView2 reply channel.

### Key Discoveries (hostile audit, claim vs truth)

- **`src/webkit_shim.h:30-41`** — the C seam is generic (`zb_run_open`/`zb_app_run`/`zb_run_screenshot`/`zb_version_line`/`zb_window_new(ZbApp*, void*)`/`zb_reload` + Zig-owned `zb_policy_decide`/`zb_ipc_dispatch`). The header is reusable as-is by a WebView2 implementation; only the *.c* file is GTK-specific. **`ZbApp`/`ZbWindow` are opaque `typedef struct` forward-decls (`:12-13`)** — backend-agnostic, so the WebView2 shim `#include`s `webkit_shim.h` and needs **no new header** (the `extern "C"` guard at `:6-8` already lets a C++ TU implement these symbols). The exit-code enum (`:15-28`) carries `ZB_EXIT_RUNTIME_MISSING=9`, `ZB_EXIT_WEBVIEW_INIT_FAILED=10`, `ZB_EXIT_LOAD_FAILED=5` — reused unchanged.
- **Only 3 of the 6 shim functions are link-referenced (verified `src/main.zig` + `src/webkit.zig`).** `main.zig:21,43,61` references `zb_version_line`, `zb_app_run`, `zb_run_screenshot`; these **must** be defined for the windows link to succeed. `src/webkit.zig:13` wraps `zb_run_open` in `runOpen`, but **`runOpen` is an unused `pub fn`** — Zig analyzes functions lazily, so an uncalled `pub fn` emits no symbol reference → `zb_run_open` is **dead-code-eliminated**, not a link dependency. `zb_reload`/`zb_window_new` are never referenced at all. (Drives the M2 symbol checklist: IMPLEMENT `zb_app_run`/`zb_version_line`; STUB `zb_run_screenshot`; EXCLUDE the rest.)
- **`src/ipc.zig:33-42`** — `os.info` calls `std.posix.uname()` **unconditionally**. Combined with `src/main.zig:8-11`'s `comptime { _ = @import("ipc.zig"); … }` (which force-links the exports), this means **`ipc.zig` cannot compile for windows today**. This is the sole *Zig-graph* compile blocker. The fix lives entirely in `ipc.zig` via `std.os.windows`/`builtin` (**no C helper** — see M1). (Verified: a windows-target build of the ipc module aborts at `:35`.)
- **`src/ipc.zig:47-79` — `zb_ipc_dispatch` ABI is fully specified.** Returns `c_int`: **`0` = success** with `out_result` set to a **pre-serialized JSON** C-string (e.g. `"pong"`, `"hi-42"`, or `{...}` — already quoted/braced); **nonzero = error** with `out_err` set to `@errorName(err)` (the bare token, e.g. `"BadArgs"`/`"UnknownCommand"`). Both pointers live in **threadlocal static buffers** (`dispatch_result_cstr[4096]`, `dispatch_err_cstr[128]`) valid only until the *next* call on that thread. (Drives M4/M5 routing + lifetime contracts.)
- **`build.zig:2-4,95-118`** — `Backend` enum has only `gtk_backend`; `resolveBackend` `std.debug.panic("NoBackendLinked…")` at **configure time** for non-linux; no windows arm in `pkg_guard`/`configureBackend`/`configureGtkBackend`. These are the exact insertion points. **Crucially, `build.zig:55-70` defines a *backend-free* `ipc_tests` module** (imports only `src/ipc.zig` + `tests/ipc_test.zig`, no `configureBackend`, no C shim) — this is the module the M1 windows **compile gate** must target, because the full `test_module`/`unit_tests` path (`:41-53`) *does* call `configureBackend` and would drag in the un-cross-compilable C++ shim.
- **`tests/fixtures/app/zbhost.js:36-108`** — `sendViaWebView2` (`:82-108`) sends the id-correlated `{id,cmd,args}` envelope; **`onWebViewReply` (`:36-67`) is the receive side**: it requires a **numeric** `data.id`, looks it up in `pending`, and either `reject(asError(data.error))` (when the object owns an `error` key) or `resolve(data.result)`. Replies for unknown ids are **silently dropped** (`:55-59`). `asError`→`safeErrorMessage` (`:8-22`) means a string `error` is used verbatim → native must post the **bare token** (`"BadArgs"`). No native host implements this yet and no passing test exercises it (written-but-dead contract). The GTK path (`:24-34`) uses a different mechanism, so the transports are not symmetric — M8 must make the native side honor *this* protocol.
- **`tests/e2e/m8_reply_channel_test.py:89-100`** — real test body: success oracle asserts an `IPC\techo\t"hi-42"` row AND no `IPCERR\techo`; error oracle asserts `IPCERR\techo\tBadArgs` (`:100`). **HW-gated**: returns SKIP unless `platform.system()=='Windows'` AND `ZB_ENABLE_M8_E2E=1` (`:26-30`). Off-Windows it passes vacuously. This is the honest deferral **and** the discriminating oracle for M8.
- **`src/errors.zig:7,28` + `:11-12,32-33`** — the `BrowserError` enum **already** declares `LoadFailed` (`:7`), `Timeout`, `RuntimeMissing` (`:11`), `WebViewInitFailed` (`:12`), and `exitCode()` maps them to **5/8/9/10** (`:28-33`). All OS-agnostic, reused unchanged. (Corrects a review [VERIFY] that suspected `LoadFailed=5` might be absent — it is present.)
- **`src/main.zig:43-61`** — driver calls `webkit.c.zb_app_run`/`runScreenshot`/`versionLine`; OS-agnostic, no change for a windows backend.
- **Clean slate (verified `git ls-files`)** — zero `webview2`/`win32` files; `src/` is GTK-only. M8 builds the backend from nothing (no stub to lean on).

## Desired End State

In the Win11 guest, over SSH, with `ZB_ENABLE_M8_E2E=1`: `zigBrowser.exe --version` prints a WebView2 + runtime-version line; `zigBrowser.exe file:///…/index.html` opens a real WebView2 window rendering the real page (verifiable by screenshot); `zbHost('ping'|'echo'|'os.info')` round-trips over `chrome.webview` and resolves/rejects the correct id-correlated promise; load failures emit a 4-field `LOAD_FAIL` row with the right exit code. Linux `zig build test` stays green (no regression).

### Observable Behaviors

1. **build_selects_webview2_backend** (`backend_select`) — windows target links *only* the WebView2 backend, emits `zigBrowser.exe`, `--version` names WebView2 + runtime version.
2. **unsupported_target_hard_fails** (`backend_link_check`) — a target with no backend errors `NoBackendLinked` at configure (no silent fallback).
3. **real_page_renders_in_real_webview2_window** (`render_page`) — real page in a real window → screenshot.
4. **ipc_ping_echo_osinfo_roundtrip** (`ipc_post`) — `ping`→'pong', `echo`, `os.info`→real Windows values via the comptime branch.
5. **idcorrelated_reply_resolves_and_badargs_rejects** (`ipc_reply`) — native posts `{id,result|error}`; matching promise resolves; bad args reject with id-correlated `IPCERR`.
6. **load_failure_and_runtime_missing_exit_codes** (`app_ack`) — 4-field `LOAD_FAIL` + exit 5/8; missing runtime → exit 9/10 before any window.

## What We're NOT Doing

- **M9 (macOS / WKWebView)** — deferred, HW-gated (bead `zigBrowser-8g7`); no Apple hardware.
- **No new IPC commands** beyond the existing `ping`/`add`/`echo`/`os.info` surface.
- **No GTK behavior changes** — the Linux path must remain byte-identical.
- **No cross-compile-from-Linux build path** — COM/MSVC import-lib linkage forces an in-guest build (documented in M0).
- **No new navigation/traversal behavior** on windows this slice (nav-policy reuse is implicit; not a tested M8 behavior).

## Testing Strategy

- **Framework:** Zig 0.16 `std.testing` for units. The `-Dtarget=x86_64-windows` **compile gate runs the backend-free `ipc_tests` module** (`build.zig:55-70`, `skip_foreign_checks`) — NOT full `zig build test`, because the `test_module` path calls `configureBackend` and would try to cross-compile the WebView2 C++ shim from Linux (impossible — COM/MSVC; see "What We're NOT Doing"). The full `zig build test` stays the **Linux** regression gate. Then the Python E2E harness (`tests/e2e/slice2_common.py` helpers: `run_interactive_until`, `protocol_rows`, `assert_children_exit`) executed **natively in the Win11 guest over SSH**; screenshot capture via PowerShell (`System.Drawing`) with a non-uniform-pixel + title-match oracle; WebView2 runtime version via registry/`Get-AppxPackage` as the independent build oracle.
- **Unit:** os.info comptime branch returns the windows-shaped struct; `exitCode(RuntimeMissing)=9` / `exitCode(WebViewInitFailed)=10`.
- **Build integration:** windows target links exactly the webview2 backend + emits `zigBrowser.exe`; unsupported target hard-fails `NoBackendLinked`.
- **E2E in-guest (`ZB_ENABLE_M8_E2E=1`):** `m8_reply_channel_test.py` (ping/echo/os.info success + BadArgs IPCERR reply), a NEW render+screenshot test (visible-output gate), a load-failure test (4-field `LOAD_FAIL` + exit codes).
- **Independent oracles only:** real WebView2 runtime version from the registry, real Windows OS values from `cmd /c ver`, fixture `<title>` parsed from source, the `PROTOCOL.md` contract — never an artifact our own render path produced.

---

## M8 Normative Contracts (single source of truth for the milestones)

Every milestone below references this section by tag. These are the contracts the
PlanReview surfaced as missing; they are fixed here once so M1–M6 stay terse.

### C1 — `os.info` Windows field contract (used by M1, M4)

The `os.info` reply struct keys are **platform-invariant**: `{sysname, release, machine}`
(identical key set to the Linux `uname` branch at `ipc.zig:36-39` — `machine` is already
present, so the windows branch adds a value source, **never a new/renamed key**; this is
what keeps the Linux output byte-identical). Windows value sources:

| Field | Source | Example | Notes |
|---|---|---|---|
| `sysname` | literal | `"Windows"` | constant; NOT `"Windows_NT"` |
| `release` | `RtlGetVersion` → `"{major}.{minor}.{build}"` | `"10.0.22631"` | dotted; no "Build " prefix |
| `machine` | `@tagName(builtin.cpu.arch)` | `"x86_64"` | matches `uname`'s `machine` string exactly (NOT `"AMD64"`) |

### C2 — `zb_ipc_dispatch` routing + reply contract (used by M4, M5)

`zb_ipc_dispatch` (`ipc.zig:47-79`) is the **shared** dispatch — the WebView2 shim calls
the *same* symbol the GTK shim does. Routing rule, verbatim from the ABI:

- **return `0`** → success. `out_result` is a **pre-serialized JSON** C-string. The reply
  envelope splices it **raw** after `"result":` (do NOT re-quote/escape — `"pong"` is already
  a JSON string, `{...}` is already an object). → `{"id":<n>,"result":<out_result_raw>}`.
- **return nonzero** → error. `out_err` is the bare error token (`@errorName`, e.g. `"BadArgs"`).
  The reply envelope is `{"id":<n>,"error":"<out_err>"}` (token as a JSON string).

Per-command reply `result` shape (what the page receives after `JSON.parse`):

| cmd | `out_result` (raw) | resolves to |
|---|---|---|
| `ping` | `"pong"` | string `"pong"` |
| `echo` | `"hi-42"` (quoted) | string `"hi-42"` |
| `add` | `42` | number |
| `os.info` | `{"sysname":...,"release":...,"machine":...}` | object |

The protocol rows mirror the same raw payload: `IPC\t<cmd>\t<out_result_raw>` and
`IPCERR\t<cmd>\t<out_err>` (PROTOCOL.md `:18-24`; matches `m8_reply_channel_test.py:93,100`).

### C3 — JS reply receive shape (used by M5) — frozen, do not change

`zbhost.js onWebViewReply` (`:36-67`) is already written and is the authority:
- requires **numeric** `id`; non-numeric / unknown-id replies are **silently dropped** (`:51,55-59`);
- if the parsed object **owns an `error` key** → `reject(asError(data.error))` — and `asError`
  (`:8-22`) uses a string verbatim, so `error` MUST be the bare token string;
- else → `resolve(data.result)`.

So the native side posts **exactly** `{id, result}` on success / `{id, error}` on failure —
field names `result`/`error` are fixed by this parser, not a free choice.

### C4 — `out_result`/`out_err` lifetime across the C/Zig ABI (used by M4, M5)

Both pointers point into **threadlocal static buffers** (`ipc.zig:11-13`,
`dispatch_result_cstr[4096]`, `dispatch_err_cstr[128]`) that are overwritten on the next
`zb_ipc_dispatch` call on that thread. Therefore the shim, inside `AddWebMessageReceived`,
MUST **copy/consume both into the reply envelope synchronously before returning** from the
handler and MUST NOT retain the raw pointer. Zig retains ownership; the shim never frees.
Reply-build scratch is bounded to mirror the Zig side: **≤4352 bytes** (4096 result + 128
err + envelope/`id` overhead); oversize is impossible given the Zig caps but the buffer is
sized to them, not unbounded.

### C5 — id-correlation invariant (used by M5)

WebView2 delivers `add_WebMessageReceived` callbacks and `PostWebMessageAsString` results
on the **UI thread, serially** (the same thread that pumps the message loop — see C7). The
id-correlation property (each reply resolves exactly its own promise; no cross-talk) rests
on this single-threaded serial dispatch. The shim performs **no async dispatch** of replies;
introducing one later would break the invariant and MUST re-derive correlation explicitly.

### C6 — `LOAD_FAIL` `<domain>`/`<code>` mapping (used by M6)

`LoadFailure` (`errors.zig:16-20`) is `{domain:i32, code:i32, message}` and PROTOCOL.md `:30-32`
is `LOAD_FAIL\t<uri>\t<domain>\t<code>`. WebView2 `NavigationCompleted` yields a
`COREWEBVIEW2_WEB_ERROR_STATUS`. Mapping (additive — does NOT touch the GTK domain):

| `<domain>` | meaning | `<code>` |
|---|---|---|
| `1` | GTK `GError` domain (existing, unchanged) | GError code |
| `2` | WebView2 `COREWEBVIEW2_WEB_ERROR_STATUS` | integer value of the status enum |

M6 adds the **domain `2`** row to `tests/e2e/PROTOCOL.md` so the backend has an authoritative
oracle for the `<domain>`/`<code>` pair.

### C7 — Windows COM/window lifecycle for `zb_app_run` (used by M2, M3, M6) — resolves both criticals

1. **COM apartment (resolves Critical #2).** Sequencing is explicit: the **C8 runtime
   check is the very first action** (no COM, no window — so an absent runtime yields a clean
   `RuntimeMissing(9)`); only if it passes does `zb_app_run` make its **first COM call**,
   `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`, paired with `CoUninitialize()` on
   **every** exit path (success, load-fail, init-fail, timeout). Omitting CoInitializeEx makes
   WebView2 COM calls fail in a way indistinguishable from an absent runtime — putting the
   runtime check ahead of COM init is what keeps the C8 discriminator unambiguous.
2. **Async env creation + message pump (resolves Critical #1).**
   `CreateCoreWebView2EnvironmentWithOptions` and the subsequent controller creation are
   **async** — their completion handlers fire **only while the calling thread's message queue
   is pumped**. So after creating the Win32 host window and kicking off env creation,
   `zb_app_run` runs a **`GetMessage`/`TranslateMessage`/`DispatchMessage` loop** on the UI
   thread; the env→controller→Navigate chain advances inside the completion callbacks reached
   by `DispatchMessage`. Without the pump the callback never fires and `zb_app_run` blocks
   forever — the failure mode M3 must red-test (C7-prop below).
3. **Timeout reap (used by M6).** A `SetTimer` posts `WM_TIMER`; the message loop reaps it and,
   on navigation-not-completed, exits with `Timeout(8)` — the Win32 analogue of the GTK
   `g_timeout_add` reap.
4. **Cleanup (resolves the M3 lifecycle warning).** On every exit path, in order:
   `controller->Close()` → `Release()` the controller/webview/environment COM pointers (in
   reverse acquisition order) → `DestroyWindow(hwnd)` → `CoUninitialize()`.

**C7-prop (red test for the pump):** a hang oracle — with the pump disabled, env-creation
never completes and the process must be reaped by the harness timeout (`m8_render_test.py`
sees no `NAV` row within the timeout); with the pump, `NAV` appears. This makes Critical #1
a *testable* hang-vs-not-hang, not a silent stall.

### C8 — `RuntimeMissing(9)` vs `WebViewInitFailed(10)` discriminator (used by M6)

Before any COM init (C7), call `GetAvailableCoreWebView2BrowserVersionString(NULL, &ver)`:
- returns null/empty or `HRESULT` indicating not-found → **`RuntimeMissing(9)`**, before any
  window or `CoInitializeEx`.
- runtime present but `CreateCoreWebView2EnvironmentWithOptions` / controller-creation callback
  delivers a non-`S_OK` `HRESULT`, OR `CoInitializeEx` fails → **`WebViewInitFailed(10)`**.

This makes the two exit codes unambiguous and removes the ambiguity the missing CoInitializeEx
(C7.1) would otherwise inject.

### C9 — `zb_version_line` Windows output format (used by M2)

`zb_version_line(buf,len)` on windows writes exactly: `zigBrowser (WebView2 <runtimeVersion>)`
where `<runtimeVersion>` is the string from `GetAvailableCoreWebView2BrowserVersionString`
(e.g. `zigBrowser (WebView2 120.0.2210.144)`). The E2E `--version` assert and the C++
implementation both target this exact shape.

### C10 — windows shim source language + symbol checklist (used by M2)

The shim is **`src/webview2_shim.cpp` (C++17)** — WebView2's COM interfaces are unusable from
C, so the file extension is decided **now**, not mid-slice. It `#include`s `webkit_shim.h`
(the `extern "C"` block makes the symbols C-linkage). `build.zig`'s windows arm adds it via
`addCSourceFile(.{ .file = "src/webview2_shim.cpp", .flags = &.{"-std=c++17"} })` (or the
MSVC `/std:c++17` equivalent). Per-symbol obligation (from the link analysis in Key Discoveries):

| Symbol | Obligation | Why |
|---|---|---|
| `zb_app_run` | **IMPLEMENT** | called by `main.zig:43` |
| `zb_version_line` | **IMPLEMENT** | called by `main.zig:21` (version path) |
| `zb_run_screenshot` | **STUB** → returns `ZB_EXIT_SNAPSHOT_FAILED` | referenced by `main.zig:61` so must link; M8 captures screenshots via PowerShell `System.Drawing`, NOT in-process — the stub supplements, it does not replace the visible-output gate |
| `zb_run_open` | **EXCLUDE** | `webkit.zig:13` `runOpen` is an unused `pub fn` → DCE'd → no symbol ref |
| `zb_reload` | **EXCLUDE** | never referenced |
| `zb_window_new` | **EXCLUDE** | never referenced |
| `zb_ipc_dispatch`, `zb_policy_decide` | (Zig-owned) | defined in `ipc.zig`/`nav_policy.zig`, force-linked via `main.zig:8-11` — the shim does not define them |

If the linker unexpectedly pulls an EXCLUDE symbol, add a one-line link-safe stub returning
`ZB_EXIT_USAGE`; do not leave it undefined.

---

## Milestone 0 — Host↔guest build/verify channel + Windows toolchain (PREREQUISITE — enabling infra, no flow_id)

**Why first:** the visible-output gate and every E2E need to build *and* run *and* observe inside the guest. No product code until the loop works.

- Add an SSH port-forward to the running guest (qemu user-mode `hostfwd tcp::2222-:22`) — the guest is `qemu:///session` SLIRP NAT, so host→guest needs this; enable the **OpenSSH Server** optional feature in Windows.
- Install in-guest: **Zig 0.16**, a **C/C++ toolchain** (MSVC Build Tools or clang-cl), the **WebView2 SDK** (NuGet `Microsoft.Web.WebView2`) + locate `WebView2Loader`; confirm the **WebView2 Runtime** is present (ships with Win11).
- Sync the repo into the guest (git over SSH or a shared path).
- 🟢 **Green:** `ssh -p 2222 guest 'zig version'` returns a real version; a PowerShell one-liner prints the installed WebView2 Runtime version.
- 🔵 **Refactor:** capture the steps in a repeatable `tests/guest/setup.ps1` + a host-side ssh helper so re-provisioning is one command.
- **Files touched:** `tests/guest/setup.ps1` (new), host-side ssh helper (new), domain XML port-forward (infra, not repo).
- **VISIBLE ARTIFACT:** real Windows stdout over SSH (`zig version` + WebView2 runtime version).

## Milestone 1 — os.info compiles + returns real Windows values cross-OS  (flow: `ipc_post`)

> **⚠️ M1 is COMPILE/SHAPE-ONLY (realness gate).** The M1 unit cross-compiles on the
> Linux host; it can verify that `ipc.zig` *compiles* for windows and that the reply *shape*
> is `{sysname,release,machine}`, but it **cannot execute `RtlGetVersion`** so it cannot prove
> the *values* are real. M1 green therefore must NOT be read as "Windows os.info works" — it
> is satisfiable by comptime-constant strings. **Real value-correctness is bound to M4's
> in-guest oracle** (os.info reply vs `cmd /c ver`, HW-gated `ZB_ENABLE_M8_E2E=1`). Treat
> "M1 done" as "compiles + shape", nothing more.

- 🔴 **Red:** the **backend-free** windows compile gate fails today at `ipc.zig:35`. The gate runs the `ipc_tests` module only (`build.zig:55-70`, no `configureBackend` → no C++ shim), e.g. via a `zig build ipc-test-win` step that builds `tests/ipc_test.zig` for `-Dtarget=x86_64-windows` with `skip_foreign_checks`. (NOT full `zig build test`, whose `test_module` calls `configureBackend` and would drag in the un-cross-compilable WebView2 C++ shim — see Key Discoveries + C10.) Add a unit asserting `os.info` returns a `{sysname,release,machine}`-shaped result for the windows target.
- 🟢 **Green:** replace the unconditional `uname` with `comptime switch (builtin.os.tag)` — **windows branch lives entirely in `ipc.zig` with NO C helper**: `sysname="Windows"`, `release` from `std.os.windows.ntdll.RtlGetVersion` formatted `"{major}.{minor}.{build}"`, `machine=@tagName(builtin.cpu.arch)` (per **C1**); `else` keeps `uname`. `ipc.zig` now compiles for windows. (Dropped the earlier "via the shim" wording — the shim does not exist until M2 and os.info needs none.)
- 🔵 **Refactor:** keep dispatch flat; isolate the platform branch in one helper; Linux behavior byte-identical (existing GTK os.info test stays green).
- **Property (key-invariance, per C1):** the windows branch produces the **same key set** `{sysname,release,machine}` as the Linux branch — `machine` already exists in the struct (`ipc.zig:39`), so no key is added or renamed; the Linux `os.info` output is byte-identical to its pre-M8 value (regression guard).
- **Files touched:** `src/ipc.zig`, `tests/ipc_test.zig`, `build.zig` (add the backend-free `ipc-test-win` compile-gate step).
- **VISIBLE ARTIFACT:** the windows-target ipc compile gate passes (was a hard compile error at `:35`); os.info unit returns the Windows-shaped struct. **NOT a value-correctness artifact** — see the M1 realness banner above.

## Milestone 2 — build selects + links the WebView2 backend by target  (flows: `backend_select`, `backend_link_check`)

- 🔴 **Red:** `zig build -Dtarget=x86_64-windows` panics `NoBackendLinked` (`build.zig:98`). A build-integration check expects `zigBrowser.exe` + a WebView2 `--version` line.
- 🟢 **Green:** add `Backend.webview2_backend`; `resolveBackend`: `.windows => .webview2_backend` (keep `else => NoBackendLinked`); `configureWebView2Backend` adds `src/webview2_shim.cpp` via `addCSourceFile(.{ .file=..., .flags=&.{"-std=c++17"} })` (**C++17, NOT `.c`** — per **C10**), adds the WebView2 SDK include path, links `WebView2Loader` + windows system libs (`ole32`, `oleaut32`, `user32`, `gdi32`, `shell32`); add a windows `pkg_guard` arm (no pkg-config — assert the SDK headers + `WebView2Loader` import lib are present); implement `zb_version_line` for windows per **C9** (`zigBrowser (WebView2 <runtimeVersion>)`). The shim implements exactly the symbols in the **C10 checklist** (`zb_app_run`, `zb_version_line` IMPLEMENT; `zb_run_screenshot` STUB; `zb_run_open`/`zb_reload`/`zb_window_new` EXCLUDE). Build emits `zigBrowser.exe`.
- 🔵 **Refactor:** factor backend-agnostic build wiring; enforce the exactly-one-backend invariant; Linux build path unchanged.
- **Files touched:** `build.zig`, `src/webview2_shim.cpp` (new — for M2, only the `zb_version_line` impl + the `zb_run_screenshot` stub are needed to link `--version`; `zb_app_run` lands in M3). **Reuses `src/webkit_shim.h`** — no new header (per C10/Key Discoveries; `ZbApp`/`ZbWindow` opaque typedefs already there).
- **VISIBLE ARTIFACT:** `zigBrowser.exe` in the guest; `--version` prints exactly `zigBrowser (WebView2 <runtimeVersion>)` (C9); an unsupported target still prints `NoBackendLinked`. **Oracle:** registry/`GetAvailableCoreWebView2BrowserVersionString` runtime version matches the printed line; `dumpbin /symbols` shows `zb_ipc_dispatch` + the WebView2 symbols DEFINED, zero GTK symbols.

## Milestone 3 — real page renders in a real WebView2 window  (flow: `render_page`)

- 🔴 **Red:** a render/screenshot E2E (new, in-guest) is RED — no window opens. **Plus the C7-prop hang oracle:** with the message pump disabled (build flag / injected fault), the env-creation callback never fires and no `NAV` row appears within the harness timeout — this is the *testable* form of Critical #1 (async COM never completes without a pump).
- 🟢 **Green:** `webview2_shim` `zb_app_run`, in **C7** order: (1) `GetAvailableCoreWebView2BrowserVersionString` runtime check (C8 — exit `RuntimeMissing(9)` here if absent, before any COM); (2) `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` (**Critical #2** — first COM action); (3) create the Win32 host window; (4) `CreateCoreWebView2EnvironmentWithOptions` and, in its completion callback, create the controller, `AddScriptToExecuteOnDocumentCreated(zbhost.js)`, then `Navigate` to the `file://` URI; (5) **run a `GetMessage`/`TranslateMessage`/`DispatchMessage` loop on the UI thread** so those async callbacks actually fire (**Critical #1** — without the pump `zb_app_run` blocks forever). Implement `--print-title` from the document title; emit `NAV`/protocol rows on stdout matching the GTK contract.
- 🔵 **Refactor:** share the e2e protocol-emit helper shape with the GTK backend; **explicit cleanup per C7.4** on every exit path — `controller->Close()` → `Release()` controller/webview/environment (reverse acquisition order) → `DestroyWindow(hwnd)` → `CoUninitialize()`.
- **Property (Critical #1, per C7-prop):** with the pump, env→controller→Navigate completes and a `NAV` row is emitted; without it, the process hangs until the harness timeout (no `NAV`). Hang-vs-not-hang is the red/green discriminator, not a silent stall.
- **Files touched:** `src/webview2_shim.cpp`, `tests/e2e/m8_render_test.py` (new), `tests/e2e/PROTOCOL.md` (note windows parity).
- **VISIBLE ARTIFACT:** a screenshot captured in the guest (PowerShell `System.Drawing`, per C10) of the rendered fixture in a real WebView2 window. **Oracle:** non-uniform PNG + `--print-title` == fixture `<title>` (parsed from source).

## Milestone 4 — IPC request reaches zb_ipc_dispatch over chrome.webview  (flow: `ipc_post`)

- 🔴 **Red:** `tests/e2e/m8_reply_channel_test.py` success path RED (no reply channel).
- 🟢 **Green:** `webview2_shim` `AddWebMessageReceived` → parse the `{id,cmd,args}` envelope → call the **same** `zb_ipc_dispatch(cmd, args_json, &out_result, &out_err)` (`ipc.zig:47`) → **route per C2**: return `0` → `IPC\t<cmd>\t<out_result_raw>` (splice the pre-serialized JSON raw, no re-quoting); return nonzero → `IPCERR\t<cmd>\t<out_err>` (bare token). ping→`"pong"`, echo→`"hi-42"`, os.info→object all flow through (reply `result` shapes per the **C2** per-command table).
- 🔵 **Refactor:** dedupe envelope parsing; **bounded scratch ≤4352 bytes per C4** (mirrors the Zig `dispatch_result_cstr[4096]`/`dispatch_err_cstr[128]` caps — not unbounded).
- **Lifetime (per C4):** `out_result`/`out_err` point into Zig threadlocal buffers overwritten on the next dispatch; the shim **copies both into the reply/row synchronously before returning** from the handler and never retains the pointer.
- **Files touched:** `src/webview2_shim.cpp`.
- **VISIBLE ARTIFACT:** IPC protocol rows on guest stdout (ping/echo/os.info) + page DOM updates. **Oracle:** `m8_reply_channel_test.py` success_condition (`row[1]=="echo"` ∧ `row[2]=='"hi-42"'`, `:93`) under `ZB_ENABLE_M8_E2E=1` + **os.info reply vs `cmd /c ver`** (the real-value oracle deferred from M1).

## Milestone 5 — id-correlated reply resolves/rejects the JS promise  (flow: `ipc_reply`)

- 🔴 **Red:** `m8_reply_channel` error/correlation path RED (dispatch result never returns to JS).
- 🟢 **Green:** shim `PostWebMessageAsString` of the **C3-exact** envelope — `{"id":<n>,"result":<out_result_raw>}` on success, `{"id":<n>,"error":"<out_err>"}` on failure (field names `result`/`error` are **fixed by `zbhost.js onWebViewReply` `:36-67`**, not a free choice). `id` is the **numeric** id from the request envelope (echoed back — `onWebViewReply:51` requires a number). `zbhost.js sendViaWebView2` (already written) resolves/rejects the matching pending id. echo BadArgs → `out_err="BadArgs"` (`@errorName`) → `{id,error:"BadArgs"}` → `asError` rejects with that token + `IPCERR\techo\tBadArgs` row.
- 🔵 **Refactor:** rely on the **C5 single-thread invariant** — WebView2 delivers `AddWebMessageReceived`/`PostWebMessageAsString` serially on the UI thread, so ids never cross-talk without any locking; replies for unknown ids are dropped by `onWebViewReply:55-59` (no shim-side bookkeeping needed).
- **Property (per C5):** for any set of concurrent in-flight request ids, each reply resolves exactly the promise whose id it carries (no cross-talk); replies for unknown ids are dropped. This holds *because* dispatch is UI-thread-serial — a future async reply path would invalidate it and must re-establish correlation.
- **Files touched:** `src/webview2_shim.cpp`; possibly a small `tests/fixtures/app/` page for the correlation case.
- **VISIBLE ARTIFACT:** success path resolves values in the page DOM; bad-args path rejects; `IPCERR\techo\tBadArgs` row on stdout. **Oracle:** `m8_reply_channel_test.py` error_condition (`:100`). The full `m8_reply_channel_test.py` now PASSES for real (was a vacuous off-Windows SKIP).

## Milestone 6 — load-failure recovery + runtime-missing exit codes  (flow: `app_ack`)

- 🔴 **Red:** a load-failure E2E is RED (no 4-field `LOAD_FAIL` / wrong exit code on windows).
- 🟢 **Green:** `NavigationCompleted(failed)` → emit 4-field `LOAD_FAIL\t<uri>\t<domain>\t<code>` with **`<domain>=2` (WebView2) and `<code>` = the integer `COREWEBVIEW2_WEB_ERROR_STATUS`** (per **C6**) → exit `LoadFailed(5)`; navigation that never completes → `Timeout(8)` via the **C7.3 `SetTimer`→`WM_TIMER`** reap in the message loop (Win32 analogue of the GTK `g_timeout_add`). Runtime/init failures use the **C8 discriminator**: runtime version string null/not-found → `RuntimeMissing(9)` *before* any window or `CoInitializeEx`; env/controller-creation `HRESULT` failure (runtime present) or `CoInitializeEx` failure → `WebViewInitFailed(10)`. All four codes already exist in `errors.zig` (`LoadFailed=5` `:7,28`, `Timeout=8`, `RuntimeMissing=9` `:11`, `WebViewInitFailed=10` `:12`) — reused, not added.
- 🔵 **Refactor:** align the recovery state machine with the GTK backend so the contract is shared.
- **Files touched:** `src/webview2_shim.cpp`, `tests/e2e/m8_load_fail_test.py` (new), `tests/e2e/PROTOCOL.md` (add the **C6 domain `2`** row so the `<domain>`/`<code>` pair has an authoritative oracle).
- **VISIBLE ARTIFACT:** guest stdout 4-field `LOAD_FAIL\t<uri>\t2\t<status>` row + process exit code 5/8/9/10. **Oracle:** `PROTOCOL.md` 4-field contract (incl. the new domain-`2` row) + `errors.zig:22-37` exitCode table.

---

## Final Visible-Output Gate (whole slice)

In the guest, over SSH, with `ZB_ENABLE_M8_E2E=1`:
- `zigBrowser.exe --version` (WebView2 line),
- a **real screenshot** of the rendered fixture,
- full `m8_reply_channel_test.py` **PASS**,
- the load-failure test **PASS**,
- Linux `zig build test` **still green** (no regression).

**Provenance:** `dumpbin`/`nm` show `zb_ipc_dispatch` **DEFINED** in the windows exe; `os.info` returning real Windows values is the discriminating proof the shared Zig core ran (the linux `uname` path could not compile). Closes `zigBrowser-182` and `zigBrowser-2nb`.

## Order

M0 (channel) → M1 (os.info compile) → M2 (build+select) → M3 (render) → M4 (ipc_post) → M5 (ipc_reply) → M6 (app_ack).

---

## Review Resolution (rev 2026-06-02)

Maps every PlanReview finding (2 critical + 27 warnings + 1 realness) to where it is now
resolved. Re-run `bun SAI/skills/PlanReview/Tools/PlanReview.ts --plan-path <this> ` to confirm.

### Critical
| # | Finding | Resolved in |
|---|---|---|
| C-1 | Async CoreWebView2 env creation needs a Win32 message pump | **C7.2** + **M3** green/property (C7-prop hang oracle) |
| C-2 | `CoInitializeEx(COINIT_APARTMENTTHREADED)` precondition unstated | **C7.1** + **M3** green; `CoUninitialize` on all exits (C7.4) |
| R-1 | M1 green satisfiable by hardcoded constants (realness) | **M1 realness banner** — compile/shape-only; real values bound to **M4** in-guest `cmd /c ver` oracle |

### Contracts
| Finding | Resolved in |
|---|---|
| LOAD_FAIL `<domain>` mapping unspecified | **C6** (domain `2` = WebView2 status; M6 adds the PROTOCOL.md row) |
| RuntimeMissing vs WebViewInitFailed discriminator | **C8** + M6 green |
| Only 2 of 6 shim fns covered (zb_run_open etc.) | **C10** symbol checklist + Key Discoveries DCE analysis |
| os.info JSON keys not declared platform-invariant | **C1** + M1 key-invariance property |
| installWebViewListener receive shape [VERIFY] | **C3** (zbhost.js `:36-67` cited) |
| out_err → `{id,error}` mapping implicit | **C2/C3** (bare token, e.g. `"BadArgs"`) |

### Interfaces
| Finding | Resolved in |
|---|---|
| os.info "via the shim" vs files-touched contradiction | **M1** green (std.os.windows in ipc.zig, no C helper) + **C1** |
| `.c` vs `.cpp` unresolved | **C10** — committed to `src/webview2_shim.cpp` (C++17) |
| zb_run_open/zb_reload/zb_window_new linkage [VERIFY] | **C10** EXCLUDE rows + Key Discoveries (DCE; `webkit.zig:13` runOpen unused) |
| ZbApp/ZbWindow type definitions [VERIFY] | **C10** + Key Discoveries (opaque typedefs `webkit_shim.h:12-13`; shim reuses header) |

### Promises
| Finding | Resolved in |
|---|---|
| out_result/out_err pointer lifetime | **C4** + M4 lifetime note |
| Win32 navigation timeout mechanism | **C7.3** (SetTimer→WM_TIMER) + M6 |
| PostWebMessageAsString threading model | **C5** + M5 property |
| Window/controller cleanup guarantee | **C7.4** + M3 refactor |
| M1 shape-only-on-Linux not warned | **M1 realness banner** |
| IPC scratch buffer bound unquantified | **C4** (≤4352 B) + M4 refactor |
| zb_run_open no implementation slot [VERIFY] | **C10** EXCLUDE (DCE) |

### Data Models
| Finding | Resolved in |
|---|---|
| os.info Windows field value format | **C1** table (sysname/release/machine sources) |
| machine field presence [VERIFY] | **C1** + Key Discoveries (`ipc.zig:39` already present) |
| LoadFailed exit code 5 present? [VERIFY] | **Key Discoveries + M6** (`errors.zig:7,28` — present; review false-alarm) |
| IPC reply result type per command | **C2** per-command reply-shape table |

### APIs
| Finding | Resolved in |
|---|---|
| zb_version_line Windows format | **C9** (`zigBrowser (WebView2 <ver>)`) + M2 |
| os.info Windows field value mapping | **C1** |
| zb_ipc_dispatch int return semantics | **C2** + Key Discoveries (`ipc.zig:47-79`) |
| zb_run_screenshot Windows impl [VERIFY] | **C10** STUB (PowerShell supplements, not in-process) |
| zb_reload/zb_window_new/zb_run_open [VERIFY] | **C10** EXCLUDE |
| IPC reply JSON field names vs JS listener [VERIFY] | **C3** (`result`/`error` fixed by `zbhost.js onWebViewReply`) |
