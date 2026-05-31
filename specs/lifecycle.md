# Lifecycle Specification (WebKitGTK App Shell Slice 2)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md`

## 1. Scope

Defines runtime lifetime and teardown ordering for interactive app-shell runs.

## 2. Run lifecycle

For app-entry `open` mode:

1. Validate URI (allowlist: `file`, `http`, `https`).
2. Create GTK window + WebKitWebView with owned WebKit context.
3. Connect load and failure callbacks.
4. Enter GTK main loop.
5. Apply navigation policy decisions and optional sub-window creation.
6. Handle IPC requests through the `zbHost` bridge when page JS invokes host messages.
7. Exit main loop only on last-window close or process signal.

## 3. Load state rule

`WEBKIT_LOAD_FINISHED` is terminal but not sufficient for success.

Success requires:

- finished
- not failed
- not cancelled
- not timed out

Protocol `NAV` emission is pinned to this success state.

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
- Timeouts/cancellation must suppress superseded terminal lines and prevent stale callback side effects.

## 6. Legacy note

This lifecycle supersedes the archived custom-engine `Page.navigate` arena lifecycle for active runtime behavior.
