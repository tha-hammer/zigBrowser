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
- `load_timeout_test.py` (M6 timeout for a load that never commits, a busy
  committed page that is not ended, and the T-epsilon race)
- `slow_load_watchdog_test.py` (gate step: that 15 s timer never ends a
  committed page, nor a web process related windows share. At 14 s and
  16 s the opener and its sibling popup keep their state and answer; the
  committed slow windows answer (a command sent before 15 s is held until
  the timer releases it, at 16 s at once); the never-committing related
  popup gets LOAD_FAIL without ending the shared process; a lone window
  whose load never commits still has its web process ended)
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
- Every browser starts through `xsession.py` (the prefix from
  `slice2_common.detect_runner` / `xsession_prefix`): `--prefer-xvfb` gives it
  a private Xvfb (its own display, lock and auth cookie). The browser keeps its
  own PID; a detached guardian ends its process group and removes the private
  display when the test driver dies, however it died. Tear down with
  `slice2_common.stop_browser` (SIGINT, then SIGKILL to the whole group).
  `harness_group_test.py` is the regression for this.
- Tracks helper child PIDs while alive, then asserts those exact PIDs exit.
- Exits `77` with a loud skip when required runtime tools are missing or HW-gated tests are off-platform.
