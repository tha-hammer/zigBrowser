# ong.13 — Windows navigation policy (WS2a): TDD plan addendum

Owner: PinkOwl (cc_2). Parent plan: `2026-10-19-windows-launch-tdd-plan.md` rev 2.21, WS2a ABI table
(`_navigate_guarded` = NavigationStarting + `zb_policy_decide`). Bead: `zigBrowser-ong.13`.
Status: **plan for review** (no code yet). Hostless first; any VM run needs NavyCanyon's exact-commit approval and
the orchestrator's release.

## 1. The gap (research, at HEAD d52370f7)

- `src/webview2_shim.cpp` never calls `zb_policy_decide`. Its `NavigationStarting` handler only records ids
  (routed `nav_id`, `current_nav_id`, WS2a.3d). So a routed `page.navigate` outside the app's base, and a
  page-initiated navigation outside it, both load. ABI (`src/webkit_shim.h`, ops comment): a navigation blocked by
  policy answers `ZB_AUTO_ERR_NAV_FAILED`.
- GTK (`src/webkit_shim.c`): `derive_app_base(uri)` = the canonical directory URI of a `file:` start page (else the
  URI itself); every policy decision calls `zb_policy_decide(app->app_base, candidate, dtype)`; `ignore` →
  `webkit_policy_decision_ignore` + e2e `BLOCKED <uri>` row; a routed navigation that is blocked ends as failed.
- `src/nav_policy.zig` (shared with GTK and macOS): `navigation_action` with a `file:` base → `use` only when the
  candidate's normalized path is inside the base directory; non-`file:` base → `use`; unparsable/non-file
  candidate with a file base → `ignore`; `new_window_action` → `open_in_subwindow`; `response` → `use`.

### Hostless probe of today's `decide` with Windows-shaped URLs (base `file:///C:/Users/zbtext/zb/build/run-x/tests/fixtures/app/`)

| candidate | want | today |
|---|---|---|
| `file:///C:/…/app/page-b.html` | use | use |
| `file:///c:/…/app/page-b.html` (drive-letter case) | use | **ignore** |
| `file:///C:/…/APP/page-b.html` (directory case) | use | **ignore** |
| `…/app/../app/page-b.html`, `file://localhost/C:/…`, `page%2Db.html` | use | use |
| `…/automation/input.html`, `file:///D:/x.html`, `app%5C..%5Cautomation…`, `file://server/share/x.html` | ignore | ignore |

So enabling the policy on Windows as-is can block same-file navigations whose spelling differs only in case, e.g. a
base built from a CLI path with `c:` while Chromium reports `C:`. Every existing live row that navigates to
`page-b.html` (routed, private world, WS2a.3d) would then fail.

## 2. Decisions for the reviewer

- **D1 (shared `nav_policy.zig`)**: path containment is ASCII-case-insensitive when the target OS is Windows (NTFS
  default). Implemented as `decideWith(…, fold_case: bool)`; the export passes `builtin.os.tag == .windows`. The fold
  path is unit-tested hostless on Linux by calling `decideWith(…, true)`; GTK/macOS behaviour is unchanged
  (`fold_case = false`, existing tests untouched). Alternative: fold only in the WebView2 shim (would need its own
  canonicalizer — rejected, duplicates the parser).
- **D2 (base)**: the shim derives `app_base` from the start URI exactly as GTK does (directory URI of a `file:`
  start page, else the URI), computed once in `run_core` from the UTF-8 argument.
- **D3 (hook)**: in `NavigationStarting`, read `get_Uri`; `zb_policy_decide(app_base, uri, NAVIGATION)`; on
  `ignore` → `args->put_Cancel(TRUE)`, e2e `BLOCKED <uri>` row (GTK parity), and if this start is the routed job's
  own first start (`nav_job && !nav_start_seen` at entry) the job is finished at once with
  `ZB_AUTO_ERR_NAV_FAILED` ("navigation blocked by policy") and `nav_job` is cleared, so the answer never depends
  on whether WebView2 raises NavigationCompleted for a cancelled start. An unreadable URI fails closed (cancel).
  The first (start-page) navigation is decided too (it is inside its own base).
- **D4 (scope)**: `new_window_action` (NewWindowRequested) stays with WS2c.1 (popup chain); `response` is `use`
  (no hook). The crash-page reload special case is GTK-only (no WebView2 crash page yet).

## 3. Behaviours, tests, mutants

1. **B1 hostless (Zig, red first, unregistered file `tests/windows/nav_policy_windows_test.zig`)**: with
   `fold_case = true`, the drive-letter-case and directory-case candidates above are `use`; every `ignore` row stays
   `ignore` (including `..` escapes past the drive, another drive, UNC host, encoded backslash); with
   `fold_case = false` today's answers are unchanged. Green: `decideWith` + the export. Registered in the green as
   its own step in `zig build test`. Mutant: fold off on Windows → the fold rows fail.
2. **B2 live (product exe over the socket, `tests/e2e/win_routed_test.py`, rows added in the red leg only)**: from
   the file start page A, `page.navigate` to a staged file OUTSIDE the app directory → JSON-RPC error
   `navigation_failed` (`ZB_AUTO_ERR_NAV_FAILED`), and url/title/heading are still page A's; a page-initiated
   navigation outside (`page.evaluate` `location.href = <outside>`) leaves page A in place; `page.navigate` to page B
   (inside, different drive-letter case in the URL we send) still succeeds. Red (no hook): the outside navigations
   load. Mutant: skip the check (always `use`). Guard row: the case-folded inside navigation, whose mutant is D1's
   fold-off.
3. Win11 legs as a chain (red → green → mutant(s)) on the then-current HEAD; Win10 waits on ong.12.

## 4. Hostless checks before any request

`zig build test` slice for B1 (private caches, no display), `cross-check`, both shim syntax variants (MinGW and MSVC
min/max), `windows-live-step-skip`, `windows-vm-steps-unguarded`; `win_routed_test.py` gated rc 1 / standalone 77.
