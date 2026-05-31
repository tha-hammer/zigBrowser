---
date: 2026-05-31T18:00:00-04:00
planner: maceo (git: tha-hammer)
git_commit: a55b48b
branch: master
repository: zigBrowser
topic: "Slice 3/4 TDD plan — full JS↔Zig IPC command surface + Windows (WebView2) / macOS (WKWebView) cross-OS backends"
tags: [tdd, plan, ipc, cross-os, webview2, wkwebview, app-shell, slice-3-4]
status: ready
tier: L3
related_research: thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md
related_beads: [zigBrowser-19n, zigBrowser-5ir]
---

# zigBrowser Slice 3/4 — IPC Command Surface + Cross-OS Backends TDD Implementation Plan

## Overview

Expand the JS↔Zig IPC command surface and add **real** Windows (WebView2) and macOS
(WKWebView) backends that reuse the same OS-agnostic Zig core (`ipc.zig`,
`nav_policy.zig`) verbatim. Every milestone ends in a human-observable artifact —
rendered text in a real window, a real-pixel screenshot, a protocol line on stdout,
or a process exit code — never "tests green" alone.

This plan builds on a **now-live seam**. The hostile audit that opened this plan
found the headline Slice-2 modules were never linked into the binary (the live IPC
and nav-policy were duplicate C fallbacks; `nm` showed `U zb_ipc_dispatch` /
`U zb_policy_decide`). That has since been remediated (commits `994f7a2`,
`3c8dbe8`): the Zig modules are hard-linked (`nm` shows them **defined**), the C
fallbacks are deleted, the build hard-fails if the Zig core is unlinked, the Zig
unit tests run under `zig build test` (24/24), and a `..`-traversal E2E discriminator
proves the real `nav_policy.zig` is live (the deleted C prefix-check would have
allowed it). The "OS-agnostic Zig logic reused verbatim" thesis is therefore now
**true for the one backend that exists** — which is the precondition for adding more.

## Current State Analysis

**What exists (verified reality, post-remediation):**
- A single live backend: WebKitGTK + GTK3, all platform code in the 1616-line
  `src/webkit_shim.c` behind the plain-C `zb_*` seam in `src/webkit_shim.h`.
- The IPC command surface is the Zig `dispatch()` if-chain in `src/ipc.zig`
  (`ping`/`add`/`os.info`), now linked and exercised by both `zig build test` and
  the Python E2E harness against the real binary.
- Navigation policy is the Zig `decide()` in `src/nav_policy.zig` (`file://`-only
  canonical-path containment with POSIX `./..` normalization), now live.
- The build links `webkit2gtk-4.1`/`gtk+-3.0`/`gio-unix-2.0` **unconditionally**
  in `build.zig:53-63` — there is no target/OS branch and no backend selection.

### Key Discoveries
- `src/ipc.zig:14-38` — `dispatch()` command if-chain; extension point for new commands.
- `src/ipc.zig:40-72` — `zb_ipc_dispatch` C-ABI adapter; threadlocal 8KB scratch /
  4KB result / 128B err buffers (`copyToCStr` fails closed on oversize).
- `src/nav_policy.zig:24-144` — `decide()` + POSIX normalization; the traversal
  discriminator that proves Zig (not a prefix-check) is live.
- `src/webkit_shim.h:34-45` — the plain-C `zb_*` seam any backend must satisfy
  (`zb_app_run`/`zb_run_open`/`zb_run_screenshot`/`zb_version_line`/`zb_reload`/`zb_window_new`)
  plus the engine→host exports `zb_policy_decide`/`zb_ipc_dispatch`.
- `build.zig:53-63` — `configureWebKit()` links GTK/WebKit unconditionally; **the place
  backend selection must be introduced**.
- `src/main.zig:32-43` — `.open` path calls `c.zb_app_run(...)`; backend-agnostic at this layer.
- `src/errors.zig:22-31` — exit-code table (Usage 1 … Cancelled 130) reused across backends.
- `tests/e2e/*.py` + `tests/snapshots/pillow_tools.py` — the real-binary E2E harness
  (`--e2e-protocol` tab-separated lines) and the PNG `nonuniform` screenshot oracle.
- Commits `994f7a2`/`3c8dbe8` — remediation that made the seam real (nm-verified).

## Desired End State

A single Zig app-shell model with **three real backends** selectable at build time,
all reusing the same `ipc_core`/`nav_core`. The IPC command surface is extended with
at least one new command proven to run through the linked Zig dispatch (negative
control: absent from any non-Zig path). On Windows and macOS CI, a real WebView2 /
WKWebView window opens, renders a real page, and answers a real `zbHost` roundtrip.

### Observable Behaviors
- New IPC command (`echo`) returns its exact payload as a typed JS value rendered in a real window.
- Unknown/malformed commands reject the JS promise with typed `UnknownCommand`/`BadArgs`.
- A `..`-traversal navigation is BLOCKED identically on every backend via the shared `nav_core`.
- `zig build -Dtarget=…` links exactly one backend; an unmapped target hard-fails the build.
- A hanging load recovers (error page + `LOAD_FAIL`, window stays alive) on each backend.
- SIGINT during a load cancels in-flight and exits 130 cleanly.
- A real WebView2 window (Windows CI) and a real WKWebView window (macOS CI) render a real page and answer `ping`→`pong`.

## What We're NOT Doing
- Async IPC commands (the `g_idle_add` + reply-timeout path) — synchronous main-loop
  dispatch only this slice (so `ipc_reply` carries no `Timeout`).
- Download handling (`…_download` seam).
- Sub-frame policy granularity.
- Tabs / address bar / bookmarks — **cut**, not deferred.
- Re-establishing the GTK seam — already landed in `994f7a2`/`3c8dbe8`.

## Decisions (resolved open questions)
- **Recovery is per-backend, not centralized.** The shared Zig cores never touch the
  webview, so recovery cannot be centralized; each backend re-implements gtk's
  timeout + cancel + error-page with its own APIs (WebView2 nav-timeout/cancel;
  WKWebView `WKNavigationDelegate` + `stopLoading`). Error-path coverage is **N+1**:
  one build-time test (`NoBackendLinked`) + per-backend runtime recovery suites.
- **Cross-OS hardware gate.** M1–M7 ship in this slice (all observable on Linux/GTK +
  build tests). **M8 (Windows) and M9 (macOS) are gated on Windows/macOS CI
  provisioning.** If CI runners are available they ship here; if not, M8/M9 split to a
  hardware-provisioned Slice 4 — they are **not** stubbed and **not** dropped.
- **C fallbacks: removed** (already done in remediation); the build hard-fails if the
  Zig core is unlinked, so there is nothing to mask whether Zig runs.

## Testing Strategy
- **Framework**: Zig 0.16 `std.testing` via `zig build test`; Python E2E harness in
  `tests/e2e/` driving the **real compiled binary** with `--e2e-protocol`
  (tab-separated `NAV`/`IPC`/`IPCERR`/`BLOCKED`/`SUBWIN`/`LOAD_FAIL`/`WINCOUNT` lines);
  screenshot PNG oracle via `tests/snapshots/pillow_tools.py nonuniform`.
- **Test Types**:
  - *Unit* (`zig build test`): `ipc.zig` dispatch (M1/M2) and `nav_policy.zig` decisions (M3) against hand-known values.
  - *GTK/Linux E2E*: M1–M3, M6, M7 on the real binary.
  - *Build tests* (`zig build -Dtarget=…`, exit-code oracle): M4, M5.
  - *Cross-OS E2E* (Windows + macOS CI): M8, M9, plus re-runs of M3/M6/M7 per OS to prove core reuse.
- **Oracle discipline**: every test asserts against an independent oracle (literal sent
  value, hand-computed normalization, fixed error constants, known fixture pixels via
  pillow, exit-code table) — never against what the same code produced.

---

## Behavior M1: echo command roundtrip

### Test Specification
**Given**: a real WebKitGTK window loaded with the app fixture, `src/ipc.zig` linked
(`nm` shows `zb_ipc_dispatch` defined), with a new `echo` branch in `dispatch()`.
**When**: JS calls `window.webkit.messageHandlers.zbHost.postMessage(JSON.stringify({cmd:"echo",args:{msg:"hi-42"}}))`.
**Then**: the Promise resolves to the typed JS string `"hi-42"`, rendered into the DOM; stdout emits an `IPC` line for `echo`.

**Edge Cases**: empty args → `BadArgs`; result larger than the 4KB threadlocal result
buffer → `BadArgs` fail-closed (`copyToCStr`); non-string `postMessage` payload → guard error reply.

**Property**: for any UTF-8 string `s` within the buffer bound, `echo({msg:s}) == s`
(round-trip identity) — add a property test over a generated string domain alongside the example.

**Files touched**: `src/ipc.zig`, `tests/ipc_test.zig`, `tests/e2e/ipc_roundtrip_test.py`,
`tests/fixtures/app/index.html` (echo render hook). Healthy blast radius (one impl + tests).

### TDD Cycle
#### 🔴 Red
**File**: `tests/ipc_test.zig`
```zig
test "dispatch echo returns the exact payload" {
    const a = std.testing.allocator;
    const out = try ipc.dispatch(a, "echo", "{\"msg\":\"hi-42\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("\"hi-42\"", out); // canonical JSON string
}
```
Plus a failing E2E asserting the page shows `hi-42` and an `IPC\techo` line appears.

#### 🟢 Green
**File**: `src/ipc.zig`
```zig
if (std.mem.eql(u8, cmd, "echo")) {
    const msg = try parseEchoArg(allocator, args_json); // {msg:string}
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(msg, .{})}) catch return error.BadArgs;
}
```

#### 🔵 Refactor
Extract the single-string-arg parse shared with future commands; keep `dispatch()`
a flat readable if-chain (matches `ping`/`add` style at `ipc.zig:14-38`). No new branches beyond the command.

### Success Criteria
**Automated:** Red fails for the right reason (`echo` unknown); Green passes; `zig build test` green; E2E green; no duplicated arg-parsing (`grep`/jscpd).
**Manual:** the window visibly shows `hi-42`; `echo` exists in no non-Zig path (negative control).

---

## Behavior M2: typed error reply rejects the JS promise

### Test Specification
**Given**: a real WebKitGTK window with the live Zig dispatch.
**When**: JS posts `{cmd:"frobnicate"}` (unknown) or `{cmd:"add",args:{a:1}}` (malformed).
**Then**: the Promise rejects with `UnknownCommand` (code 1) / `BadArgs` (code 2); stdout emits an `IPCERR` line.

**Edge Cases**: whitespace-only args to a no-arg command accepted (`expectNoArgs`);
`add` with 3 keys → `BadArgs` (`count!=2`); `number_string` vs `integer` coercion in `valueToI64`.

**Files touched**: `tests/ipc_test.zig`, `tests/e2e/ipc_roundtrip_test.py` (no `src/ipc.zig` change — error paths already exist).

### TDD Cycle
#### 🔴 Red
```zig
test "unknown command errors" {
    try std.testing.expectError(error.UnknownCommand, ipc.dispatch(std.testing.allocator, "frobnicate", "{}"));
}
```
Plus an E2E asserting the JS promise rejects and an `IPCERR` line is emitted.

#### 🟢 Green
Confirm the existing `error.UnknownCommand`/`error.BadArgs` → `ipcErrorCode` 1/2 path
(`ipc.zig:121-126`) reaches `webkit_script_message_reply_return_error_message` and `IPCERR`.

#### 🔵 Refactor
Consolidate error-code mapping if duplicated; ensure `@errorName` is the single source of the reply string.

### Success Criteria
**Automated:** Red→Green on both error kinds; `zig build test` + E2E green.
**Manual:** the page surfaces the rejected-promise error; `IPCERR` line present.

---

## Behavior M3: cross-OS-shared nav traversal block

### Test Specification
**Given**: a backend launched with `app_base = file:///app/` and the shared `nav_policy.zig` linked.
**When**: a navigation to `file:///app/../etc/passwd` is attempted.
**Then**: BLOCKED (decision=`ignore`); stdout emits `BLOCKED\t<candidate>` — identically on GTK/WebView2/WKWebView (same `zb_policy_decide`).

**Edge Cases**: `file://localhost/app/` host accepted; non-`file` scheme → ignore; `/app` exact (no trailing slash) containment edge.

**Property**: for any path `p`, `decide(base, base ++ "/../" ++ p)` after POSIX
normalization escaping `base` ⇒ `ignore` (no traversal ever escapes containment).

**Files touched**: `tests/nav_policy_test.zig`, `tests/e2e/nav_block_test.py`. (No impl change — proves the live module.)

### TDD Cycle
#### 🔴 Red
```zig
test "traversal escaping app_base is ignored" {
    try std.testing.expectEqual(
        nav_policy.Decision.ignore,
        nav_policy.decide("file:///app/", "file:///app/../etc/passwd", .navigation_action),
    );
}
```
#### 🟢 Green
Already satisfied by `nav_policy.zig:110-144` POSIX normalization — assert it via the E2E `BLOCKED` line.
#### 🔵 Refactor
None beyond naming clarity; the discriminator must remain (it is the cross-OS reuse proof).

### Success Criteria
**Automated:** unit + E2E green; the hand-computed oracle (`/etc/passwd ∉ /app/`) matches.
**Manual:** the page does not navigate off-tree; `BLOCKED` line present.

---

## Behavior M4: build selects exactly one backend by target

### Test Specification
**Given**: `build.zig` with target→backend selection.
**When**: `zig build -Dtarget=x86_64-linux` (and, once implemented, `-Dtarget=x86_64-windows` / `aarch64-macos`).
**Then**: exactly one backend is compiled+linked; the binary's `--version` reports the matching engine (e.g. `WebKitGTK x.y.z, GTK a.b.c` on Linux).

**Edge Cases**: unknown target triple → `UnsupportedTarget` build error; two backends accidentally linked → build error (exactly-one invariant).

**Files touched**: `build.zig`, `src/webkit.zig` (version line per backend), a build-test script under `tests/`.

### TDD Cycle
#### 🔴 Red
A build test invoking `zig build -Dtarget=…` and asserting the linked backend's
entry points (`nm`) / the `--version` string; fails before the selection table exists.
#### 🟢 Green
Add a target→backend mapping in `build.zig` that calls a backend-specific
`configure<Backend>()` instead of the unconditional `configureWebKit` at `build.zig:53-63`.
#### 🔵 Refactor
Extract a single selection table (`target.os → {csource, libs, version_fn}`); keep
`configureWebKit` as one entry in it (no shallow wrapper).

### Success Criteria
**Automated:** linux build links GTK and `--version` matches `root.zig:isVersionLine`;
unsupported target errors; `nm` shows the expected `zb_app_run`.
**Manual:** a runnable binary prints its engine identity.

---

## Behavior M5: build hard-fails when no backend is linked

### Test Specification
**Given**: a target with no backend mapping.
**When**: `zig build`.
**Then**: the build FAILS with `NoBackendLinked` (nonzero exit) — never a silent stub binary.

**Edge Cases**: partial backend (missing entry points) → link error surfaced as
`NoBackendLinked`; aligns with the existing Zig-core link gate from `994f7a2`.

**Files touched**: `build.zig`, build-test script.

### TDD Cycle
#### 🔴 Red
A build test for an unmapped target expecting nonzero exit + `NoBackendLinked` text; currently a build might succeed/fall through.
#### 🟢 Green
Add the exactly-one-backend assertion in `build.zig` (comptime/build-graph guard) emitting `NoBackendLinked`.
#### 🔵 Refactor
Share the diagnostic with the Zig-core link guard; one assertion site.

### Success Criteria
**Automated:** build exit ≠ 0 + literal `NoBackendLinked`; no binary emitted.
**Manual:** stderr names the failure clearly.

---

## Behavior M6: per-backend load-timeout recovery

### Test Specification
**Given**: a backend launched against a URI that never finishes loading.
**When**: the per-backend load timeout elapses.
**Then**: the window stays alive showing an error page; stdout emits `LOAD_FAIL`; the process does not crash or silently exit.

**Edge Cases**: each backend mirrors gtk's 15s timeout + `GCancellable` (WebView2
nav-timeout/cancel; WKWebView `WKNavigationDelegate` + `stopLoading`); reload after failure recovers.

**Files touched**: `src/webkit_shim.c` (GTK, exists), future `src/webview2_shim.c` /
`src/wkwebview_shim.m`, `tests/e2e/reload_test.py` (+ per-OS variants).

### TDD Cycle
#### 🔴 Red
An E2E pointing at a hanging URI, expecting `LOAD_FAIL` + the process alive past the timeout.
#### 🟢 Green
Per-backend timeout + cancel + error-page (GTK already at `webkit_shim.c` load-failed/`zb_reload`); new backends re-implement with their APIs.
#### 🔵 Refactor
Hoist the shared recovery *shape* (timeout duration, error-page URI, `LOAD_FAIL` emit) into a documented contract each backend satisfies — not shared code (platform-specific), shared spec.

### Success Criteria
**Automated:** `LOAD_FAIL` line + bounded liveness check green per backend.
**Manual:** error page visible in a still-open window.

---

## Behavior M7: cancel-in-flight load on window close

### Test Specification
**Given**: a backend with a load in flight.
**When**: the window is closed via SIGINT.
**Then**: the in-flight load is cancelled and the process exits 130 cleanly within a bounded time (no hang, no zombie).

**Edge Cases**: SIGTERM → 130; SIGHUP → reload `windows[0]` (not exit); close during IPC reply dispatch.

**Files touched**: `src/webkit_shim.c` (GTK signal handlers exist), new backend shims, `tests/e2e/` lifecycle test.

### TDD Cycle
#### 🔴 Red
An E2E sending SIGINT during a load, expecting exit 130 within a bounded wall-clock.
#### 🟢 Green
Wire cancel-on-close per backend (GTK `on_signal_term` at `webkit_shim.c:1086-1112` exists).
#### 🔵 Refactor
Unify the signal→cancel→quit teardown contract across backends.

### Success Criteria
**Automated:** exit code 130 (`errors.zig:exitCode(Cancelled)`); bounded time (no kill needed).
**Manual:** clean teardown on stdout.

---

## Behavior M8: Windows WebView2 backend — real window + real page + ping  ⚠ HW gate

### Test Specification
**Given**: a Windows CI runner with the WebView2 Runtime installed and `win_backend` linked.
**When**: `zigBrowser <file-uri-to-known-fixture> --e2e-protocol` runs.
**Then**: a real WebView2 window opens, renders the real fixture page, and a JS `zbHost` `ping` returns `"pong"`.

**Edge Cases**: WebView2 Runtime missing → `RuntimeMissing` exit; load timeout → `Timeout` + stay-alive (M6).

**Files touched**: `src/webview2_shim.c` (NEW, implements the `zb_*` contract), `build.zig`
(windows selection from M4), `tests/e2e/` Windows job, a known colored fixture.

### TDD Cycle
#### 🔴 Red
A Windows-CI E2E: open window, render fixture, `ping`→`pong`; fails (no `win_backend`).
#### 🟢 Green
Implement `win_backend`: WebView2 host, host message channel (`zbHost` equivalent),
`zb_app_run`/`zb_window_new`/`zb_reload`/`zb_version_line`/`zb_run_screenshot`, calling the **unchanged** Zig `zb_ipc_dispatch`/`zb_policy_decide`.
#### 🔵 Refactor
Factor common host-channel glue shared with M9; keep platform calls in the shim.

### Success Criteria
**Automated:** `pillow_tools.py nonuniform` on the WebView2 screenshot (real pixels) + known `pong`; on Windows CI.
**Manual:** a human sees a real WebView2 window with the page.
**Gate:** requires Windows CI — else split to Slice 4 (hardware-provisioned).

---

## Behavior M9: macOS WKWebView backend — real window + real page + ping  ⚠ HW gate

### Test Specification
**Given**: a macOS CI runner and `macos_backend` (WKWebView + `WKScriptMessageHandler`) linked.
**When**: `zigBrowser <file-uri-to-known-fixture> --e2e-protocol` runs.
**Then**: a real WKWebView window opens, renders the real fixture page, and a JS `zbHost` `ping` returns `"pong"`.

**Edge Cases**: WKWebView init failure → `WebViewInitFailed` exit; `LoadFailed` on bad URI.

**Files touched**: `src/wkwebview_shim.m` (NEW, Objective-C, implements the `zb_*` contract),
`build.zig` (macOS selection from M4), `tests/e2e/` macOS job, known fixture.

### TDD Cycle
#### 🔴 Red
A macOS-CI E2E: open window, render fixture, `ping`→`pong`; fails (no `macos_backend`).
#### 🟢 Green
Implement `macos_backend`: WKWebView host + script message handler, the `zb_*` entry points, calling the unchanged Zig core.
#### 🔵 Refactor
Align with the M8 host-channel glue contract.

### Success Criteria
**Automated:** pillow `nonuniform` on the WKWebView screenshot + known `pong`; on macOS CI.
**Manual:** a human sees a real WKWebView window with the page.
**Gate:** requires macOS CI — else split to Slice 4 (hardware-provisioned).

---

## Integration & E2E Testing
- **Integration**: M4/M5 build-selection tests across target triples (exit-code oracle).
- **E2E (Linux/GTK)**: M1–M3, M6, M7 on the real binary via `tests/e2e/*.py` + pillow oracle.
- **E2E (cross-OS)**: M8, M9, and re-runs of M3/M6/M7 on Windows + macOS CI to prove
  `ipc_core`/`nav_core` are reused verbatim (the cross-OS thesis, verifiable per OS).

## Order
M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9
(pure-logic + GTK E2E first; build selection; recovery; hardest cross-OS last).

## Risks / Constraints
- **Win/macOS CI availability** gates M8/M9; absent it, they split to a
  hardware-provisioned Slice 4 (not stubbed, not dropped).
- **Per-backend recovery is platform-specific** (shared spec, not shared code) — change
  amplification risk if a new failure mode appears: add it to the contract first.
- The `zb_*` C-ABI seam (`webkit_shim.h:34-45`) is the stable contract; new backends
  must match it exactly and consume the Zig exports unchanged.

## References
- Research: `thoughts/searchable/shared/research/2026-05-31-16-52-slice3-4-ipc-and-cross-os-backends.md`
- Prior plans: `thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md`,
  `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md`
- Remediation commits: `994f7a2`, `3c8dbe8` (Zig seam made real; nm-verified; C fallbacks removed)
- Patterns: `src/ipc.zig:14-38`, `src/nav_policy.zig:24-144`, `src/webkit_shim.h:34-45`, `build.zig:53-63`, `src/errors.zig:22-31`
- Topology: `2026-05-31-18-00-ENG-0005-tdd-ipc-surface-and-cross-os-backends-slice3-4/`
