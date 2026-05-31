---
title: "WebKitGTK Browser — Slice 1: real page in a real window (TDD)"
date: 2026-05-31
status: revised — all 8 critical + warnings from REVIEW resolved (see §Review Resolution)
type: tdd-plan
project: zigBrowser
engine: WebKitGTK (webkit2gtk-4.1 + GTK3)
zig_version: "0.16.0"
audit_source: thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md
review_source: thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1-REVIEW.md
archive_tag: archive/custom-engine-pre-webkit
laws:
  - "LAW 1 — real working software, no scaffolding: every behavior produces real, user-observable output."
  - "LAW 2 — hostile audit before planning: built against verified reality."
  - "VISIBLE-OUTPUT GATE — every milestone ends in a human-observable artifact, not 'tests green'."
---

# WebKitGTK Browser — Slice 1 TDD Implementation Plan (revised per review)

## Overview

Build the first real vertical slice by **embedding WebKitGTK** (webkit2gtk-4.1 + GTK3): a GTK
window hosts a `WebKitWebView` that loads a CLI URL and renders the **real page with real text**.
URL in → real pixels out. Every milestone ends in a human-observable artifact; tests assert against
**independent oracles** (WebKit's own DOM parse + known `file://` fixtures + OS checks).

**Architecture decision forced by the review (verified):** Zig 0.16 `translate-c` of
`webkit2/webkit2.h` is **not viable** — `zig translate-c $(pkg-config --cflags webkit2gtk-4.1)`
fails with `error: unrecognized parameter: '-pthread'`, and the header's GLib macros/pragmas break
the translate. **All GTK/WebKit/GObject/cairo work lives in a thin C shim** (`src/webkit_shim.c`
+ `.h`), where the GLib/GTK macros (`g_signal_connect`, `GTK_WINDOW`, …) work natively. Zig calls a
**small plain-C API** with signatures we control. This also resolves the "macros not exposed by
translate-c" and "callback ABI" problems — signal wiring happens in C.

## Current State Analysis (verified hostile audit — LAW 2)

### Key Discoveries
- **Clean slate real:** `git ls-files | grep -E '\.(zig|h)$'` → 0 files.
- **WebKitGTK linkable here:** `pkg-config webkit2gtk-4.1` → 2.52.3 (`-lwebkit2gtk-4.1 -lgtk-3 … -ljavascriptcoregtk-4.1`); header `/usr/include/webkitgtk-4.1/webkit2/webkit2.h`; `libwebkit2gtk-4.1.so` dev symlink present.
- **Version path forced:** only **webkit2gtk-4.1 + GTK3 (3.24.49)**; gtk4 / webkitgtk-6.0 dev absent.
- **translate-c broken (verified):** fails on `-pthread` → **C shim** mandatory (not broad translate-c).
- **`.use_pkg_config = .yes` does NOT fail loudly:** Zig 0.16 falls back to `-l<name>` (`std/Build/Step/TranslateC.zig:240-264`). → use `.force` + an explicit `pkg-config --exists` build check.
- **`WEBKIT_LOAD_FINISHED` is terminal, not success** (`WebKitWebView.h:113-135`) — fires after errors too → a load **state machine** is required.
- **Owned context available:** `webkit_web_context_new` / `webkit_web_context_new_ephemeral` exist → own the context so helper-process disposal is ours.
- **Signal handling available:** `g_unix_signal_add` (`glib-unix.h`) → SIGINT/SIGTERM graceful shutdown in the shim.
- **Salvage caveats (verified):** `archive:src/cli.zig:3-15` clean `parseArgs` (reusable). `archive:src/net/url.zig:6-18,33-49` requires a **host** and serializes `{scheme}://{host}{path}` — **cannot represent `file:///abs/...`** and has no scheme allowlist → **not reused as-is** (new `uri.zig` validator). `archive:src/page.zig:3-17,60-79` **imports/owns the deleted custom pipeline** — **not cherry-pickable**; only the arena+ordered-teardown *idea* is reused. `archive:src/errors.zig:1-13` is too small (`NetError` only) → new `BrowserError`.
- **`pillow_tools.py` (archive) has only `check`/`write`/`diff`** — no non-uniformity command → add `nonuniform`.
- **Display present:** `DISPLAY=:1` set → window can open; CI uses Xvfb.

---

# §C — Slice-1 Canonical Contracts (PIN BEFORE ANY BEHAVIOR)

Single source of truth (mirrors the §C2 pattern the reviewer endorsed). Every behavior references §C; none re-defines it. Resolves all 8 critical findings.

## C1 — `NavigationUri` contract (resolves CRIT #1: file:// vs scheme rejection)
A new `src/uri.zig` (NOT the archived host-required `url.zig`). Validates a CLI string for WebKit:
```zig
pub const UriError = error{ InvalidUri, UnsupportedScheme, RelativeUri };
// Allowed schemes for Slice 1: file, http, https. Rejected: javascript, ftp, data, mailto, and
// any relative/scheme-less input. file:// MAY be hostless (file:///abs/path) — host is optional.
pub fn validate(arena, input: []const u8) UriError![:0]const u8; // returns a sentinel-terminated
// canonical URI string ready for webkit_web_view_load_uri; ownership: arena (page lifetime).
```
- Uses `std.Uri.parse` for structure, then an explicit scheme allowlist (file/http/https). Hostless `file://` is valid; http/https require a host. Canonical serialization documented; round-trip property `validate(canonical(x)) == canonical(x)`.

## C2 — `BrowserError` + exit-code table (resolves CRIT #7, warnings on errors)
`src/errors.zig` (extend the salvaged `NetError`; add a Slice-1 set):
```zig
pub const BrowserError = error{
    Usage, InvalidUri, UnsupportedScheme, DisplayUnavailable, GtkInitFailed,
    LoadFailed, SnapshotFailed, WriteFailed, Timeout, Cancelled,
};
pub const LoadFailure = struct { domain: i32, code: i32, message: []const u8 }; // preserves WebKit GError
```
| Exit | Meaning | Trigger |
|---|---|---|
| 0 | success | page loaded / PNG written |
| 1 | Usage | bad args/arity |
| 2 | InvalidUri / UnsupportedScheme | C1 rejection |
| 3 | DisplayUnavailable | no DISPLAY for window/screenshot |
| 4 | GtkInitFailed | gtk_init_check failed |
| 5 | LoadFailed | WebKit load-failed (DNS/TLS/HTTP/file) |
| 6 | SnapshotFailed | get_snapshot async error |
| 7 | WriteFailed | PNG write/rename failed |
| 8 | Timeout | load/snapshot exceeded budget |
| 130 | Cancelled | SIGINT/SIGTERM during op |

## C3 — WebKit operation state schema (resolves CRIT #5, DATA-MODEL crit)
Owned by the C shim (`ZbPage`), one per window/run:
```c
typedef struct {
  GtkWidget *window; WebKitWebView *view; WebKitWebContext *context; // OWNED context (C5)
  char *uri;                  // sentinel-terminated, owned
  char *out_path;             // screenshot only, owned; NULL otherwise
  int   want_screenshot;      // 0/1
  /* per-load state machine (C4) */
  int finished, failed, cancelled, timed_out;
  int load_error_domain, load_error_code; char *load_error_message; // from load-failed
  /* async lifetime (C5) */
  GCancellable *cancellable; guint timeout_source_id;
  gulong sig_load_changed, sig_load_failed, sig_destroy; // handler IDs for clean disconnect
  int exit_code;
} ZbPage;
```
Zig side mirrors only what it needs via the shim API; the C struct owns all GObject/cairo refs.

## C4 — Per-load state machine (resolves CRIT #4: FINISHED ≠ success)
`WEBKIT_LOAD_FINISHED` is terminal even on error. Therefore:
- `load-failed` cb sets `failed=1` + records `LoadFailure` (domain/code/message) and (screenshot mode) returns `TRUE` to suppress WebKit's default error page; (window mode) returns `FALSE` so WebKit's real error page is shown (a real visible artifact).
- `load-changed == FINISHED` triggers success actions **only if** `finished && !failed && !cancelled && !timed_out`. Otherwise the run resolves to the recorded failure/timeout/cancel exit code.
- Screenshot success (title read + snapshot) runs **only** in the success state → **no PNG of an error page** (kills the bogus-PNG risk).

## C5 — Async lifetime / cancellation / timeout / context ownership (resolves CRIT #5, promise warnings)
- **Owned context:** create via `webkit_web_context_new()` (or `_ephemeral` for screenshot) so we control disposal; `webkit_web_view_new_with_context`. Helper (Network/Web) processes are reaped when our context is disposed.
- **GCancellable:** snapshots pass a **non-null** `GCancellable`; on destroy/SIGINT we `g_cancellable_cancel` before freeing anything.
- **Timeouts:** a `g_timeout_add`-backed source (load budget default 15s, snapshot budget 5s) sets `timed_out=1`, calls `webkit_web_view_stop_loading`, cancels async, resolves the run with exit 8.
- **Teardown order (documented):** cancel async → remove timeout source → disconnect signal handlers (stored IDs) → free `cairo_surface` (if any) → `gtk_widget_destroy(window)` → `g_object_unref(context)` → free owned strings.
- **Signals:** `g_unix_signal_add(SIGINT/SIGTERM, …)` → graceful: cancel + `gtk_main_quit`, exit 130.

## C6 — Build interface (resolves CRIT #3: translate-c + fail-loud)
- **No broad translate-c.** `src/webkit_shim.c` + `src/webkit_shim.h` (plain-C API). `build.zig`: `exe.addCSourceFile(.{ .file = b.path("src/webkit_shim.c"), .flags = pkgConfigCFlags })`; `exe.linkSystemLibrary2("webkit2gtk-4.1", .{ .use_pkg_config = .force })`; `exe.linkLibC()`.
- **Fail loudly:** a build step runs `pkg-config --exists webkit2gtk-4.1 gtk+-3.0` and `@panic`/`std.process.exit(1)` with a clear message if absent (because `.force` still must be guarded — the explicit check is the loud failure). Document the apt deps (`libwebkit2gtk-4.1-dev`, `libgtk-3-dev`).
- Zig imports the shim via `@cImport(@cInclude("webkit_shim.h"))` (small, macro-free) — translate-c only ever sees OUR header.

## C7 — Callback ABI (resolves INTERFACE crit: callback signatures)
All callbacks live in C (exact GTK/WebKit signatures), registered with `g_signal_connect_data` in the shim:
```c
static void on_load_changed(WebKitWebView*, WebKitLoadEvent, gpointer /*ZbPage* */);
static gboolean on_load_failed(WebKitWebView*, WebKitLoadEvent, const char *uri, GError*, gpointer);
static void on_snapshot_ready(GObject *source, GAsyncResult*, gpointer); // -> get_snapshot_finish
static void on_destroy(GtkWidget*, gpointer);
static gboolean on_timeout(gpointer); // returns G_SOURCE_REMOVE
static gboolean on_unix_signal(gpointer);
```
The shim exposes to Zig only: `int zb_run_open(const char *uri, int print_title);` `int zb_run_screenshot(const char *uri, const char *out_path, int print_title);` `void zb_version_line(char *buf, size_t len);` — returning exit codes per C2.

## C8 — E2E observation protocol (resolves CRIT #6 + API warnings: machine-readable oracle)
The CLI exposes a stable, machine-readable observation surface (no private hooks):
- `--print-title` flag (valid with `<url>` and `--screenshot`): on a **successful** load, print exactly one line to **stdout**: `TITLE\t<document.title>`; on failure print nothing to stdout (diagnostics to stderr) and exit non-zero.
- `--screenshot out.png <url>`: the PNG is the snapshot oracle.
- All diagnostics/errors → **stderr** only; stdout carries only the protocol line(s).
- **Helper-PID tracking (replaces weak `pgrep -P`):** the E2E harness records the browser's child PIDs *while it is alive* (`pgrep -P <pid>` sampled during the run, or `/proc/<pid>/task/*/children`), then asserts those exact PIDs are gone within a bounded timeout after exit (orphans reparent to init, so a post-exit `pgrep -P` is invalid).

## C9 — Display contract (resolves CRIT #8: headless contradiction)
Slice 1 has **no true no-display path**. Both window and `--screenshot` **require a GTK display**:
- `DISPLAY` unset → exit `DisplayUnavailable` (3), write no file. (No "offscreen fallback" claim.)
- CI runs everything under **`xvfb-run`**. `--screenshot` is "non-interactive," not "headless."

---

## Salvage Manifest (revised — corrected paths, no broken cherry-picks)
```bash
git checkout archive/custom-engine-pre-webkit -- src/cli.zig build.zig.zon
```
- `cli.zig` — reuse `parseArgs`; **extend** the union with `--print-title`; the `.screenshot` `w/h` defaults (1024×768) **survive** as the snapshot viewport size (documented, not dead).
- `build.zig.zon` — reuse package identity (name `zigBrowser`, fingerprint, min zig 0.16).
- **NOT salvaged:** `src/page.zig` (owns deleted pipeline — rewrite as the §C3 WebKit state, salvaging only the arena/teardown *idea*); `src/net/url.zig` (host-required, no file:// — replaced by new `src/uri.zig`, C1); `src/errors.zig` (replaced/extended by §C2 `BrowserError`).
- `tests/snapshots/pillow_tools.py` — restore and **add a `nonuniform <png>` subcommand** (M4).

## Testing Strategy
- **Framework:** Zig 0.16 `zig build test` for unit (uri.zig validation + property test, cli.parseArgs, version-line regex); a **spawn-the-binary E2E harness** under `xvfb-run` using the C8 protocol (`--print-title`, PNG) and C8 PID tracking.
- **Independent oracles only:** WebKit `get_title` (via `--print-title`) + `get_snapshot` PNG + known `file://` fixtures + OS process checks. No self-referential assertions.
- **Fixtures:** `tests/fixtures/live.html` (`<title>WebKitGTK Live</title>`, `<h1>Hello Real Text</h1>`); `tests/fixtures/missing` (nonexistent → load-failed). Deterministic, no network.
- **CI deps (in scope to document):** `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `xvfb`, `python3`, `python3-pil`; skip-vs-fail policy stated.

---

## Behavior 1: link-proof-version  (bootstraps project + C-shim build + salvage)
**Given** webkit2gtk-4.1 + GTK3 installed; build uses the §C6 C-shim path.
**When** `zigBrowser --version`.
**Then** prints `zigBrowser — WebKitGTK <maj.min.mic>, GTK <maj.min.mic>` from the linked libs (shim `zb_version_line` calling `webkit_get_*_version`/`gtk_get_*_version`), exit 0.
**Edge cases:** build fails loudly if `pkg-config --exists` fails (§C6); runtime version may differ from header — print runtime; `--version` with extra args still prints (arity per C8/CLI table).
**Files touched:** `build.zig.zon`, `build.zig`, `src/webkit_shim.h`, `src/webkit_shim.c`, `src/webkit.zig` (thin extern binding), `src/cli.zig`, `src/errors.zig`, `src/main.zig`, `tests/version_test.zig`.
- 🔴 Red: unit test asserts version line matches regex `^zigBrowser — WebKitGTK \d+\.\d+\.\d+, GTK \d+\.\d+\.\d+$` (NOT exact local numbers); E2E `zig build && zigBrowser --version` exit 0. Fails (no project).
- 🟢 Green: build.zig with explicit `pkg-config --exists` guard + C-shim compile/link (§C6); shim `zb_version_line`; main dispatch `.version`.
- 🔵 Refactor: all GTK/WebKit access confined to `webkit_shim.c`; `src/webkit.zig` is the only Zig file importing the shim header.
- **VISIBLE ARTIFACT:** real stdout version line from a genuinely-linked binary. **ORACLE:** matches `pkg-config --modversion` (regex-stable).

## Behavior 2: real-page-in-window
**Given** `tests/fixtures/live.html` and `DISPLAY` set.
**When** `zigBrowser file:///abs/tests/fixtures/live.html` (optionally `--print-title`).
**Then** a GTK window renders the real page with real text after a **successful** terminal load (§C4); with `--print-title`, stdout prints `TITLE\tWebKitGTK Live`.
**Edge cases:** `DISPLAY` unset → exit 3 `DisplayUnavailable` (§C9); missing fixture → load-failed → exit 5, window shows WebKit error page (§C4 window mode returns FALSE); no `<title>` → prints empty title line; success gated on `FINISHED && !failed && !cancelled && !timed_out` (§C4).
**Files touched:** `src/webkit_shim.c` (window/view/owned-context/signals/state machine), `src/webkit.zig`, `src/uri.zig` (validate before load), `src/main.zig`.
- 🔴 Red: E2E under `xvfb-run` spawn with `--print-title`; assert stdout == `TITLE\tWebKitGTK Live`. Fails (no window).
- 🟢 Green: shim `zb_run_open` → owned context, `gtk_init_check` (→ GtkInitFailed/DisplayUnavailable), window, `webkit_web_view_new_with_context`, `g_signal_connect_data` for load-changed/load-failed/destroy (§C7), `webkit_web_view_load_uri`, `gtk_main`; on success FINISHED read `get_title` and (if `--print-title`) print.
- 🔵 Refactor: a single `load_then(uri, action)` flow in the shim shared with M4; document the WebView/Window seam for a future macOS backend.
- **VISIBLE ARTIFACT:** real GTK window on the display showing "Hello Real Text". **ORACLE:** `get_title()` == fixture title (via `--print-title`).

## Behavior 3: clean-quit
**Given** the window open with a loaded page.
**When** the user closes it (`destroy`) — or SIGINT/SIGTERM (§C5).
**Then** async ops cancel, signal handlers disconnect, the owned context is unref'd (helpers reaped), `gtk_main` returns, exit 0 (or 130 on signal).
**Edge cases:** close before load finishes (cancel in-flight); destroy during snapshot (GCancellable); SIGINT/SIGTERM mid-load (§C5).
**Files touched:** `src/webkit_shim.c` (teardown order §C5).
- 🔴 Red: E2E launch under xvfb, record child PIDs (§C8), send destroy, assert exit 0 AND the **recorded** helper PIDs exit within a bounded timeout. Fails (hang/no teardown).
- 🟢 Green: `on_destroy` → cancel + `gtk_main_quit`; teardown in the documented §C5 order; `g_unix_signal_add` handlers.
- 🔵 Refactor: encode teardown as one ordered routine; reuse the §C3 state for the arena/teardown idea.
- **VISIBLE ARTIFACT:** shell returns exit 0; recorded helper PIDs gone. **ORACLE:** exit code + tracked-PID exit (not post-exit `pgrep -P`).

## Behavior 4: screenshot (non-interactive, display-required)
**Given** `tests/fixtures/live.html`, a display (or `xvfb-run`), and `--screenshot out.png <url>`.
**When** `zigBrowser --screenshot /tmp/live.png file:///abs/tests/fixtures/live.html [--print-title]`.
**Then** on a **successful** terminal load (§C4) it calls `get_snapshot` (non-null GCancellable, §C5), writes a real PNG of real text to a temp file in the **destination directory**, atomically renames to `out.png`, exit 0.
**Edge cases:** unwritable path → exit 7 `WriteFailed`, no partial/leftover file (failure preserves any existing output); snapshot before FINISHED waits (async); snapshot/load error → no PNG (exit 6/5); timeout → exit 8; no DISPLAY → exit 3 (§C9); SIGINT mid-snapshot → cancel, no file, exit 130.
**Files touched:** `src/webkit_shim.c` (snapshot + cairo PNG + atomic write), `src/main.zig` (`.screenshot`), `tests/snapshots/pillow_tools.py` (add `nonuniform`).
- 🔴 Red: E2E `--screenshot --print-title`; assert PNG decodes to viewport dims, `pillow_tools.py nonuniform out.png` passes, AND stdout title == fixture. Fails (no screenshot path).
- 🟢 Green: shim `zb_run_screenshot` → load_then(FINISHED-success) → `webkit_web_view_get_snapshot(view, FULL_DOCUMENT, NONE, cancellable, on_snapshot_ready, page)`; `get_snapshot_finish` → `cairo_surface_t*` → `cairo_surface_write_to_png(tmp)` → rename; map errors→exit codes (§C2).
- 🔵 Refactor: share `load_then` with M2; add the `nonuniform` PIL command (stddev/distinct-color threshold).
- **VISIBLE ARTIFACT:** an openable PNG of the real page text. **ORACLE:** PNG non-uniform (`pillow_tools nonuniform`) + title match — both WebKit-produced.

## Behavior 5: bad-uri-real-error
**Given** a malformed/unsupported URI (`http://`, `ftp://x`, `javascript:…`, relative) or unreachable host (`http://127.0.0.1:9/`).
**When** `zigBrowser <bad>` or `--screenshot out.png <bad>`.
**Then** malformed/unsupported → `src/uri.zig` (§C1) rejects pre-load → stderr message, exit 2, no window/PNG; unreachable/TLS/DNS → WebKit `load-failed` (§C4) → exit 5, screenshot writes no file, window shows WebKit's real error page.
**Edge cases:** `file://` to missing file → load-failed exit 5; TLS/DNS failures → exit 5 with preserved `LoadFailure` domain/code on stderr; `--screenshot` on any failure writes NO file.
**Property:** for all inputs, `uri.validate` returns a value or a `UriError` — never panics, never loads an unsupported scheme.
**Files touched:** `src/uri.zig`, `src/main.zig` (validate-before-load), `src/webkit_shim.c` (`on_load_failed` → record §C3/C4), `tests/uri_test.zig`.
- 🔴 Red: unit — `uri.validate` accepts file/http/https, rejects javascript/ftp/relative; E2E — `zigBrowser http://127.0.0.1:9/` exits 5, prints a real network error to stderr, writes no PNG. Fails.
- 🟢 Green: `src/uri.zig` (C1); main validates first; shim `on_load_failed` records failure + (screenshot) returns TRUE / (window) FALSE.
- 🔵 Refactor: one `reportError(BrowserError, ?LoadFailure)`; map WebKit `GError` domains → §C2.
- **VISIBLE ARTIFACT:** real stderr error / WebKit error page; correct non-zero exit; no bogus PNG. **ORACLE:** `uri.zig` vectors + WebKit's real `load-failed` GError.

## Behavior 6: docs/specs reconciled to WebKitGTK (resolves INTERFACE warning)
**Given** `docs/how-to-build.md`, `how-to-run.md`, `how-to-test.md`, `specs/architecture.md|lifecycle.md|networking.md` still describe the deleted custom-engine/libcurl path.
**When** Slice 1 lands.
**Then** those docs are updated to the WebKitGTK + C-shim reality (build deps, run, test/xvfb) **or** clearly marked "obsolete — superseded by WebKitGTK Slice 1" with a pointer to this plan.
**Files touched:** `docs/how-to-build.md`, `docs/how-to-run.md`, `docs/how-to-test.md`, `specs/architecture.md`, `specs/lifecycle.md`, `specs/networking.md`.
- 🔴 Red: a docs-lint test asserting no active how-to references `libcurl`/`drawRect`/custom-engine build steps (greps the doc set). Fails.
- 🟢 Green: update build/run/test docs to webkit2gtk-4.1 + xvfb; mark stale engine specs obsolete.
- 🔵 Refactor: one "WebKitGTK Slice 1" doc index.
- **VISIBLE ARTIFACT:** a human following `how-to-build.md` builds and sees a page — the docs match reality.

## Integration & E2E Testing
- One `load_then(uri, action)` flow drives both window (M2) and screenshot (M4), each gated on §C4 success.
- E2E flows (all under `xvfb-run`): window+`--print-title` title oracle; clean quit + tracked-PID exit; `--screenshot` PNG non-uniformity + title; bad-URI exit/stderr/no-PNG.
- Harness tools (required, documented): `xvfb-run`, `python3`, `python3-pil`; missing tools → **skip with a loud notice**, never a vacuous pass.

## CLI Contract Table (resolves API arity warnings)
| Invocation | stdout | stderr | exit |
|---|---|---|---|
| `--version [extra]` | version line | — | 0 |
| `<file/http/https url> [--print-title]` | `TITLE\t<title>` (if flag, on success) | diagnostics | 0 / 3 / 4 / 5 / 8 / 130 |
| `--screenshot out url [--print-title]` | title line (if flag, on success) | diagnostics | 0 / 2 / 3 / 5 / 6 / 7 / 8 / 130 |
| (no args) / unknown flag / output path starting with `-` / missing screenshot args | — | usage | 1 |
| unsupported/malformed URI | — | error | 2 |

## What We're NOT Doing (later slices)
Address bar + interactive navigation, back/forward/reload, tabs, the differentiator, macOS/WKWebView (seam left in M2), a true no-display rendering path.

## Risks & Mitigations
| Risk | Mitigation |
|---|---|
| Broad translate-c of webkit2.h (verified to fail on -pthread) | C shim owns all GTK/WebKit; Zig sees only our macro-free header (§C6) |
| `.use_pkg_config=.yes` silent fallback | `.force` + explicit `pkg-config --exists` build guard (§C6) |
| FINISHED after a failed load → bogus PNG | load state machine; success only on FINISHED && !failed && !cancelled && !timed_out (§C4) |
| async snapshot races on close/SIGINT | non-null GCancellable + timeout source + ordered teardown + signal handler (§C5) |
| helper-process orphan check unreliable | track child PIDs while alive; assert their bounded exit (§C8), not post-exit pgrep |
| display vs headless ambiguity | Slice 1 requires DISPLAY/xvfb; no DISPLAY → exit 3 (§C9) |
| E2E has no machine oracle | `--print-title` + PNG protocol (§C8) |

## Review Resolution (REVIEW 2026-05-31 — 8 critical + warnings)
| Finding | Resolution |
|---|---|
| CRIT #1 URL/file:// conflict | §C1 new `uri.zig` allows file/http/https, hostless file://; archived url.zig dropped |
| CRIT #2 page.zig salvage invalid | Not cherry-picked; §C3 WebKit state container; salvage only arena/teardown idea |
| CRIT #3 build interface unproven (+verified -pthread fail) | §C6 C shim + `.force` + explicit pkg-config check |
| CRIT #4 FINISHED ≠ success | §C4 load state machine; success-gated actions |
| CRIT #5 async lifetime/cancellation | §C5 GCancellable, timeouts, owned context, teardown order, signals |
| CRIT #6 no external E2E API | §C8 `--print-title` + PNG protocol |
| CRIT #7 CLI/error contract incomplete | §C2 BrowserError + exit table + CLI Contract Table |
| CRIT #8 display/headless contradiction | §C9 display required; no-DISPLAY→exit 3; xvfb in CI |
| WARN errors absent from errors.zig | §C2 BrowserError + LoadFailure |
| WARN DISPLAY inconsistency | §C9 |
| WARN E2E observation undefined | §C8 |
| WARN url path `src/url.zig` vs `src/net/url.zig` | replaced by `src/uri.zig`; all refs corrected |
| WARN pillow_tools lacks nonuniformity | add `nonuniform` cmd (M4) |
| WARN stale docs/specs (libcurl/custom) | Behavior 6 reconciles/obsoletes them |
| WARN callback ABI sketchy | §C7 exact C signatures (callbacks live in C) |
| WARN load-failed return policy | §C4: screenshot returns TRUE (no error PNG); window returns FALSE (show error page) |
| WARN helper cleanup via default context | §C5 owned context; §C8 tracked-PID exit |
| WARN destroy lacks signal cleanup | §C5 g_unix_signal_add SIGINT/SIGTERM |
| WARN screenshot w/h dead fields | survive as snapshot viewport size (documented) |
| WARN url round-trip under-tested | §C1 property test incl scheme allowlist |
| WARN async ownership undefined | §C3/§C5 ownership + teardown order |
| WARN CI deps/skip policy | Testing Strategy + Integration list deps + skip-loud policy |
| WARN --version hard-codes versions | regex assertion, not exact numbers (B1) |
| WARN CLI arity undocumented | CLI Contract Table |

## References
- Audit: `thoughts/searchable/shared/plans/2026-05-31-webkitgtk-pivot-audit-and-replan.md`
- Review: `…-slice1-REVIEW.md` (+ `/tmp/zigBrowser-review-*.md` evidence)
- Salvage: tag `archive/custom-engine-pre-webkit` (`src/cli.zig:3-15`, `build.zig.zon`)
- WebKit API: `/usr/include/webkitgtk-4.1/webkit/WebKitWebView.h` (load_uri/get_title :364-412; snapshot :616-626; load events :113-135; signals :253-258); `webkit_web_context_new[_ephemeral]`; `glib-unix.h` `g_unix_signal_add`
- Build: Zig 0.16 `addCSourceFile` + `linkSystemLibrary2(.use_pkg_config=.force)` + `linkLibC`; translate-c only on our shim header
