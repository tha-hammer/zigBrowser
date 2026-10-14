# Architecture Specification (WebKitGTK App Shell Slice 2)

Grounding:
- Plan: `thoughts/searchable/shared/plans/2026-05-31-14-41-ENG-0004-tdd-webkitgtk-appshell-slice2.md`
- Runtime target: WebKitGTK `webkit2gtk-4.1` + GTK3

## 1. Scope

Slice 2 shifts from one-shot page load to an interactive app shell:

`app entry URI -> policy-controlled navigation -> app-owned windows -> JS<->host IPC`

Custom HTML/CSS/layout/paint modules from `archive/custom-engine-pre-webkit` remain historical only.

## 2. Active runtime path

1. CLI parses app-entry invocation and optional `--e2e-protocol`.
2. URI validation gates allowed input shape.
3. Shim creates and tracks app windows/WebViews.
4. Policy callback decides `use` vs `ignore` vs `open_in_subwindow`.
5. `create` callback builds app-owned sub-windows for `_blank`/`window.open`.
6. `zbHost` message handler bridges JS messages to Zig dispatch.
7. Event protocol emits machine-readable lines for E2E assertions.

## 3. App-shell contracts

- Foreign plain navigations are blocked in policy.
- `_blank` or `window.open` routes to an app-owned sub-window (not system browser).
- IPC replies can resolve (`IPC`) or reject (`IPCERR`) and are visible in page DOM.
- Process lifetime is interactive: app remains alive across load failures until last window close or signal.

## 4. E2E protocol contract (§C8+)

Standard stdout protocol lines:

- `NAV\t<uri>\t<title>`
- `BLOCKED\t<uri>`
- `SUBWIN\t<uri>`
- `WINCOUNT\t<n>`
- `IPC\t<cmd>\t<result>`
- `IPCERR\t<cmd>\t<message>`
- `LOAD_FAIL\t<uri>\t<message>`

Harness references:
- `tests/e2e/reload_test.py`
- `tests/e2e/nav_allow_test.py`
- `tests/e2e/nav_block_test.py`
- `tests/e2e/subwindow_test.py`
- `tests/e2e/ipc_roundtrip_test.py`

## 5. Product boundary

Slice 2 is an app-shell pivot. Active docs/specs should not present address bar, tabs, or bookmarks as shipping features.

The agent drawer (Linux, opt-in, `--agent-drawer on`) is part of the product: a native GTK icon and drawer per browsing window, unreachable from pages and from the automation socket (`docs/agent-drawer.md`).
