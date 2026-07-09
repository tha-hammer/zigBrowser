# WebKitGTK E2E Harnesses

This directory contains real-binary E2E harnesses for Slice 1-4.

Core helpers:
- `slice2_common.py`

Slice 1:
- `webkitgtk_slice1_e2e.py`

Slice 2:
- `nav_allow_test.py`
- `subwindow_test.py`

Slice 3/4 (Linux GTK now):
- `ipc_roundtrip_test.py` (M1/M2)
- `nav_block_test.py` (M3 traversal block)
- `load_timeout_test.py` (M6 timeout + T-epsilon race)
- `lifecycle_test.py` (M7 SIGINT->130<=3s)
- `reload_test.py` (M7 GTK-only SIGHUP reload)

Slice 3/4 (HW-gated contracts):
- `m8_reply_channel_test.py` (Windows WebView2; exits 77 off-platform)
- `m9_reply_channel_test.py` (macOS WKWebView; exits 77 off-platform)

Automation Phase 1:
- `automation_fixture_server.py` (deterministic local HTML fixture server)
- `../../e2e/automation_script.spec.ts` (Playwright injected-script harness)

Protocol:
- `PROTOCOL.md` (normative `--e2e-protocol` line schema)

Runtime behavior:
- Uses display-first local runs (`DISPLAY`, fallback `:1`).
- Uses `xvfb-run` when requested/available for CI.
- Tracks helper child PIDs while alive, then asserts those exact PIDs exit.
- Exits `77` with a loud skip when required runtime tools are missing or HW-gated tests are off-platform.
