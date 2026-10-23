# ong.13 — Windows navigation policy (WS2a): TDD plan addendum (rev 3)

Owner: PinkOwl (cc_2). Parent plan: `2026-10-19-windows-launch-tdd-plan.md` rev 2.21, WS2a ABI table
(`_navigate_guarded` = NavigationStarting + `zb_policy_decide`). Bead: `zigBrowser-ong.13`.
Status: **rev 3 for re-review** — rev 1 `3ed85a19` BLOCKED in `f38f8153`; rev 2 `db68cb09` BLOCKED in `e9dd47ee`
(D1, D4, the B2 fixture approved and unchanged here). Rev 3 adds exactly the `e9dd47ee` minimum: the D2 C ABI, the
D3 failed-cancel fallback, and the D5 page-initiated same-base coverage. No red, product edit or host request until
this revision is approved.

## 1. The gap (research, at HEAD d52370f7; unchanged from rev 1)

- `src/webview2_shim.cpp` never calls `zb_policy_decide`: a routed `page.navigate` outside the app's base and a
  page-initiated navigation outside it both load. ABI (`src/webkit_shim.h`, ops comment): a navigation blocked by
  policy answers `ZB_AUTO_ERR_NAV_FAILED`.
- GTK (`src/webkit_shim.c`): `derive_app_base(uri)`; every policy decision calls
  `zb_policy_decide(app->app_base, candidate, dtype)`; `ignore` → `webkit_policy_decision_ignore` + e2e
  `BLOCKED <uri>` row (`emit_protocol1`, e2e-gated); a blocked routed navigation ends as failed.
- `src/nav_policy.zig` (shared with GTK/macOS): with a `file:` base, `navigation_action` is `use` only when the
  decoded, lexically normalized candidate path is the base directory or inside it (segment boundary: the base path
  ends with `/`); a non-`file:`/unparsable base → `use`; a non-`file:`/unparsable/non-local-host candidate with a
  `file:` base → `ignore`; `new_window_action` → `open_in_subwindow`; `response` → `use`.
- Hostless probe of today's `decide` (base `file:///C:/…/tests/fixtures/app/`): drive-letter case
  (`file:///c:/…/app/page-b.html`) → `ignore` (wrong: same file); directory case (`…/APP/…`) → `ignore`;
  `..`/`localhost`/percent-encoding → `use`; outside dir, other drive, encoded backslash, UNC host → `ignore`.

## 2. Decisions (rev 2)

### D1 — drive-designator folding only (revised per f38f8153)

- `nav_policy.zig` gains `decideWith(app_base, candidate, dtype, fold_drive: bool)`; `decide` = `decideWith(…, false)`
  (POSIX unchanged). The export `zb_policy_decide` passes `fold_drive = builtin.os.tag == .windows`.
- With `fold_drive`, after URI decode and lexical `.`/`..` normalization of BOTH base and candidate, a leading drive
  designator — exactly `/X:` where X is an ASCII letter, followed by `/` or end — has its letter upper-cased in both.
  Nothing else is folded: every later component is compared exactly, so a directory-case alias (`…/APP/…`) is
  `ignore` (fail closed). Arbitrary component-case aliases need a separate design based on real Windows path
  resolution/case mode, and are out of scope.
- The live fold mutant edits the production export wiring (`fold_drive = false` in `zb_policy_decide`), not the
  hostless helper.

### D2 — the Windows base contract (revised per f38f8153)

A new pure function `nav_policy.baseFromStart(start_uri, out) ?[]const u8` behind a C export, computed in `run_core`
from the UTF-8 start argument and stored in `AppState` (`std::string app_base`) before `create_environment` (so
before the first navigation) for the whole AppState lifetime.

**C ABI (declared in `src/webkit_shim.h`, next to `zb_policy_decide`; rev 3 per e9dd47ee):**

```c
/* The navigation-policy base for a start URI (ong.13 D2): the directory URI (trailing '/') of a valid local file:
 * start, GTK's last-slash prefix for a non-file start, the start unchanged for a malformed file: start.
 * Returns the base's byte length EXCLUDING the NUL, or a negative code:
 *   ZB_POLICY_BASE_INVALID  (-1)  start == NULL, or out == NULL with cap != 0;
 *   ZB_POLICY_BASE_INTERNAL (-2)  internal failure (e.g. a path longer than the policy buffers);
 *   ZB_POLICY_BASE_SHORT    (-3)  out != NULL and cap <= length: nothing is written.
 * out == NULL && cap == 0 is the size query (returns the length). With storage, cap > length is required: exactly
 * length bytes and a NUL are written and the length is returned. On every negative return `out` is untouched. */
int zb_policy_base_from_start(const char *start, char *out, size_t cap);
```

The shim calls it twice (size query, then `cap = len + 1`); any negative result makes `run_core` print
`zigBrowser: cannot derive the navigation policy base` on stderr and return `ZB_EXIT_INVALID_URI` before any window
or navigation exists (fail closed: no unconfined run). The result:

- **valid local `file:` start** (scheme `file`, empty or `localhost` host, absolute path): decode the path, drop the
  query and fragment, normalize `.`/`..` lexically, then take the directory: if the start path ends with `/` the start
  is a directory and the base is that directory; otherwise drop the last segment. Result: `file://` + the
  percent-encoded directory path + a trailing `/` (only bytes outside RFC 3986 unreserved / `/` / `:` / `@` / sub-delims
  are encoded; the policy decodes again).
  (GTK note: for a trailing-slash start GTK's `g_canonicalize_filename` + `g_path_get_dirname` yields the PARENT
  directory. Windows keeps the directory itself: WebView2 shows a listing of that directory and its own entries must
  stay reachable. Behavioural difference recorded; GTK unchanged.)
- **non-`file:` start**: GTK's last-slash rule (`uri` up to and including its last `/`, else the whole `uri`). This
  is behaviourally immaterial for the decision — the shared policy returns `use` for any non-`file:` base — and is
  kept only for parity.
- **malformed `file:` start** (non-local host such as `file://server/share/x`, relative or unparsable path): the start
  URI unchanged, as GTK's fallback. The policy then finds no local base and returns `use` — the same (unconfined)
  outcome GTK has for such a start; the start page itself could not be confined meaningfully.
- **Hostless pins through the EXPORT (B1c)**: empty start `""` → returns 0, size query 0, `cap = 1` writes just the
  NUL; exact fit (`cap = len + 1`) → success, the bytes and NUL; one byte short (`cap = len`) → `ZB_POLICY_BASE_SHORT`
  and a sentinel-filled `out` is untouched; `cap = 0` with storage → SHORT, untouched; `start == NULL` → INVALID;
  `out == NULL, cap = 5` → INVALID; malformed `file://server/share/x.html` → its own length and the unchanged string.
- **Hostless pins of the helper (B1b)**: `file:///C:/run/app/test.html` → `file:///C:/run/app/`; `…/test.html?x=1`, `…#f`,
  `…?x=1#f` → same; `file:///C:/run/app/` (trailing slash) → `file:///C:/run/app/`;
  `file:///C:/run/app/../app/test.html` → `file:///C:/run/app/`; `file://localhost/C:/run/app/t.html` →
  `file:///C:/run/app/`; a space / `%` / non-ASCII byte in a segment is percent-encoded; `file:///home/u/app/t.html`
  (POSIX) → `file:///home/u/app/`; `https://h/a/b?q` → `https://h/a/` (last slash); `file://server/share/x.html` and
  `file:relative.html` → unchanged.

### D3 — the `NavigationStarting` hook (location approved; lifecycle revised per f38f8153)

The policy runs FIRST in the handler, before any of `current_nav_*`, `nav_start_seen`, `nav_id*` or the WS2a.3d
deferred-abandon seam is touched; a cancelled start is never the current navigation and never binds a routed id.

Every COM effect is its own statement whose `HRESULT` is stored before any branch (no effecting call inside a
condition); error paths are guard clauses; decision and error values are named constants.

1. `args == nullptr` → no args to cancel with: `cancel_hr = E_POINTER` (named), go to the block step with
   `stop` as the only mechanism.
2. `uri_hr = args->get_Uri(&uri)`; on failure or a null string → the block step with candidate `(null)`. A successful
   `get_Uri` string is converted to UTF-8 and then always freed with `CoTaskMemFree` (every path).
3. `decision = zb_policy_decide(app_base, uri, ZB_DTYPE_NAVIGATION)`; only `decision == ZB_DECISION_USE` proceeds to
   today's bookkeeping. Anything else → the block step.
4. **Block step**: `cancel_hr = args->put_Cancel(TRUE)` (skipped when `args` is null). If it failed:
   `stop_hr = app->webview->Stop()`. Then:
   - `put_Cancel` or the fallback `Stop()` SUCCEEDED → the e2e row `BLOCKED <uri>` (sanitized like the other
     protocol rows, flushed), then the routed block (step 5); return.
   - BOTH failed → the forbidden navigation may continue, so nothing claims a block: stderr
     `zigBrowser: navigation policy could not block <uri> (put_Cancel 0x%08lx, Stop 0x%08lx); quitting` (distinct, no
     `BLOCKED` row), the routed block (step 5) with "navigation could not be blocked", then the existing controlled
     path `request_quit(app, ZB_EXIT_LOAD_FAILED)`; return.
5. **Routed block**: if a routed job is waiting for its own first start (`nav_job != nullptr && !nav_start_seen`), it
   is detached (`nav_job = nullptr`), finished `ZB_AUTO_ERR_NAV_FAILED` with "navigation blocked by policy" (or
   "navigation blocked: no event args/uri" in 1–2), and its separate navigation hold is released exactly once. A
   later `NavigationCompleted` for the cancelled id is inert: `nav_job` is null or belongs to a newer navigation
   whose id differs.
6. A page-initiated blocked start leaves `nav_job` (if any, already started) untouched.

### D4 — approved (unchanged)

`NewWindowRequested` stays with WS2c.1; no response-policy hook; the GTK-only crash page is out of scope.

### D5 — effect on the existing WS2a.3 slice (new; found while revising)

- The slice executable links the shim but not `nav_policy.zig`; once the shim calls `zb_policy_decide` it must link
  the real policy object (`build.zig`, slice module only; no stub).
- The slice parent starts on the `file:` fixture and its WS2a.3d rows navigate to `http://127.0.0.1` loopback pages;
  the `--ws2a3d-timeout-close` child does the same. With the policy on, those are (correctly) blocked. Minimum: the
  parent and that child start from the loopback server instead (`GET /app/index.html` serves the fixture bytes),
  whose non-`file:` base is `use`, so every existing 3a–3d/ong.20 row keeps its meaning; `page-b.html` stays a
  `file:` URL (allowed from a non-`file:` base). The ong.20 child already starts on `/slow`.
- Other live tests: the private-world test navigates to `clean.html` beside its `test.html` (same dir, allowed).
  **Corrected in rev 3 (e9dd47ee):** `tests/windows/ws2b1_input_spike.c` (`windows-trusted-input-matrix-live`) DOES
  navigate — page-initiated, same-base (`location.href` to `input.html?nav=2` and to the scroll page) in its
  navigation-during-input and scroll-page rows. The policy-first handler changes that accepted path, which B2's
  page-initiated *blocked* row does not exercise, so B2 gains an independent page-initiated, same-base ALLOWED row
  (below). The transport, capabilities, screenshot, config-flag, refusal and drawer tests do not navigate.
- B3 keeps starting from the `file:` fixture so it exercises confinement.

## 3. Behaviours, tests, mutants

- **B1 hostless (Zig; red first in the new UNREGISTERED `tests/windows/nav_policy_windows_test.zig`; registered in
  the green as its own `zig build test` member)**:
  - B1a `decideWith(…, fold_drive = true)`: drive-letter case only → `use`; directory case → `ignore`; segment
    boundary (`/C:/run/app2/x` vs base `/C:/run/app/`) → `ignore`; the base directory itself → `use`;
    normalization before comparison (`/c:/run/x/../app/p.html`, `/C:/run/app/./p.html`) → `use`; `..` past the drive
    into another drive, another drive, UNC host, encoded backslash, `https:` candidate → `ignore`; a POSIX base with
    a case-different path → `ignore` (no designator to fold). `fold_drive = false` reproduces today's answers for
    every row. Red: `decideWith` does not exist (compile error) — the red file is unregistered.
  - B1b `baseFromStart`: every pin in D2.
  - Mutant (hostless, export wiring): `zb_policy_decide` with `fold_drive = false` → the drive-case row through the
    export fails.
- **B2 live (`tests/e2e/win_routed_test.py`, rows added in the red leg)** — fixture per f38f8153: launch
  `%run%\app\test.html`, page B at `%run%\app\page-b.html`, the distinguishable outside page at `%run%\outside.html`,
  all inside the one owned `ws20-*` root and its existing cleanup. Three independent test executions (separate test
  methods, each launching its own browser), so a red cannot hide a later behaviour:
  - routed block: `page.navigate` to the outside page → JSON-RPC `navigation_failed`; then, bounded and stable,
    url/title/heading are still A's; the exact `BLOCKED <outside uri>` row was printed.
  - page-initiated block: `page.evaluate` `location.href = <outside>` → A stays (bounded, stable) and the exact
    `BLOCKED` row.
  - drive-case allow: `page.navigate` to page B with only the drive letter's case changed → `{"ok": true}` and B's
    url/title/heading.
  - page-initiated same-base allow (rev 3): `page.evaluate` `setTimeout(() => { location.href = <page B> }, 50)` →
    within a bound, B's url/title/heading, and no `BLOCKED` row.
  - Red (no hook): both block rows red (the two allow rows pass). Mutants: skip the check (always `use`) → both
    block rows red; export-fold-off → only the drive-case row red. The page-initiated allow row is the regression
    guard for the trusted-input matrix's same-base navigations: it must pass at red, green and every mutant.
- **B3 live ownership (`tests/windows/ws2a3_async_ownership.c`, registered via `windows-async-ownership-live`)**: a
  new child `--ws2a3-policy-block` starts on the `file:` fixture, takes the live-jobs baseline, routes
  `zb_automation_navigate` to `…/tests/fixtures/automation/input.html` (outside `app/`) → `ZB_AUTO_ERR_NAV_FAILED`
  with the policy message, the title stays App Index A, and live jobs return to the baseline before the close.
  Mutant: omit the navigation-hold release in the routed block → live jobs stay baseline + 1 → that row red.
- **B4 live failed-cancel fallback (rev 3; same slice, registered)**: a slice-only seam
  `zb_automation_debug_block_fail(int on)` (under `ZB_WS2A3_SEAMS`, pinned by `ws2a3_seam_gating_test.py`) replaces
  the stored `put_Cancel` and `Stop()` results with `E_FAIL` after each call. A new child `--ws2a3-policy-block-fail`
  (file start) turns it on and routes a navigate outside the base. It must see: the call answers
  `ZB_AUTO_ERR_NAV_FAILED` with "navigation could not be blocked", `zb_app_run` ends on its own (no WM_CLOSE) within
  10 s with `ZB_EXIT_LOAD_FAILED`, live jobs back to the baseline, the distinct stderr line present and no `BLOCKED`
  row. Mutant: ignore the failed `Stop()` result (treat it as a success) → `BLOCKED` is emitted and the run does not
  end → that row red.
- Win11 legs as one chain per review (red → green → each mutant) on the then-current HEAD; Win10 waits on ong.12.

## 4. Hostless checks before any request

`zig build test` member for B1a–B1c (the export pins included; private caches, no display); seam gating extended
with the `block_fail` export/state/reads (product build omits them); `cross-check`; both shim syntax variants (MinGW and
MSVC min/max, with and without `ZB_WS2A3_SEAMS`); `windows-ws2a3-seam-gating`, `windows-live-step-skip`,
`windows-vm-steps-unguarded`, `windows-msvc-minmax`; a hostless Windows link of the slice C test with the real
policy object; `win_routed_test.py` gated rc 1 / standalone skip.
