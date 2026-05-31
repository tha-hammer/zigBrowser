# Architecture Specification (WebKitGTK Slice 1)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md`
- Runtime target: WebKitGTK `webkit2gtk-4.1` + GTK3

## 1. Scope

Slice 1 is a real embedded-browser vertical slice:

`URL in -> WebKit load -> real pixels in GTK window / PNG out`

Custom HTML/CSS/layout/paint modules from `3d43b1d` are not part of the active runtime path.

## 2. Active runtime path

1. CLI parses command (`open`, `--screenshot`, `--print-title`, `--version`).
2. URI validator accepts only `file`, `http`, `https`.
3. A thin C shim owns GTK/WebKit interaction:
   - create window + WebKitWebView
   - connect load/error/snapshot callbacks
   - drive GTK main loop
4. Success protocol:
   - `--print-title` emits exactly `TITLE\t<title>` on stdout
   - `--screenshot` writes PNG output
5. Failure protocol:
   - diagnostics go to stderr
   - non-zero exit code returned

## 3. Display contract

- A display is required for both interactive window and screenshot mode.
- CI path uses `xvfb-run`.
- Local path may use a live display (for example `DISPLAY=:1`).
- No true no-display rendering path is in Slice 1.

## 4. Build contract

- Build/link must resolve WebKit/GTK via `pkg-config`.
- Required packages are documented in `docs/how-to-build.md`.
- If required packages are missing, build must fail loudly.

## 5. E2E observation contract (§C8)

External oracle surface is CLI-level only:

- stdout title line: `TITLE\t<title>`
- screenshot PNG file
- process cleanup: child PIDs tracked while alive must exit after parent exits

Harness reference: `tests/e2e/webkitgtk_slice1_e2e.py`.

## 6. Legacy boundary

The archived custom-engine architecture is preserved at:

- git tag `archive/custom-engine-pre-webkit`

Any spec content describing `src/page.zig`, custom cascade/layout/paint, or libcurl fetch as active runtime behavior is obsolete for Slice 1.
