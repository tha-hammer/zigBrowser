# WebKitGTK E2E Harnesses

This directory contains both Slice 1 and Slice 2 harness scripts.

Slice 1:
- `webkitgtk_slice1_e2e.py`

Slice 2:
- `reload_test.py`
- `nav_allow_test.py`
- `nav_block_test.py`
- `subwindow_test.py`
- `ipc_roundtrip_test.py`

Usage:

Common behavior:
- uses display-first local runs (`DISPLAY`, fallback `:1`)
- uses `xvfb-run` when requested/available for CI
- tracks helper child PIDs while alive, then asserts those exact PIDs exit
- exits `77` with a loud skip when required runtime tools are missing

Dependencies:
- `python3`
- `python3-pil`
- `xvfb` for CI environments without a live display
