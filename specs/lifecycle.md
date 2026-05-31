# Lifecycle Specification (WebKitGTK Slice 1)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-12-48-ENG-0003-tdd-webkitgtk-browser-slice1.md`

## 1. Scope

Defines runtime lifetime and teardown ordering for one browser run in the WebKitGTK slice.

## 2. Run lifecycle

For `open` and `--screenshot` modes:

1. Validate URI (allowlist: `file`, `http`, `https`).
2. Create GTK window + WebKitWebView with owned WebKit context.
3. Connect load and failure callbacks.
4. Enter GTK main loop.
5. On successful terminal load:
   - optionally emit `TITLE\t<title>`
   - for screenshot mode, request snapshot and write PNG
6. Exit main loop with success or mapped failure code.

## 3. Load state rule

`WEBKIT_LOAD_FINISHED` is terminal but not sufficient for success.

Success requires:

- finished
- not failed
- not cancelled
- not timed out

Screenshot write is permitted only in this success state.

## 4. Teardown order

Required ordered teardown:

1. cancel in-flight async operation
2. stop timeout sources
3. disconnect signal handlers
4. destroy window/view resources
5. unref owned WebKit context
6. free run-owned strings/state

Clean-quit checks in E2E track child PIDs while process is alive, then assert those same PIDs exit within a timeout.

## 5. Signal and timeout policy

- SIGINT/SIGTERM must trigger graceful shutdown path (cancel + quit).
- Timeouts must terminate stuck loads/snapshots with non-zero exit.

## 6. Legacy note

This lifecycle supersedes the archived custom-engine `Page.navigate` arena lifecycle for active runtime behavior.
