#!/usr/bin/env python3
r"""WS2b.1-W10 (plan rev 2.18, the restored Win10 leg): the same 37-row trusted-event matrix
(tests/windows/ws2b1_input_spike.c, win_trusted_input_matrix.REQUIRED) run as zbtest on the Win10 box.

The Win10 box has no build toolchain: tests/windows/win10_spike_run.py builds the spike exe on the Win11 VM
(build-only step ws2b1-input-spike-exe-win), fetches it, stages it with the commit's input.html, scroll.html and
automation.js into %USERPROFILE%\zb\build\run-<sha> on Win10, runs it there and removes both build folders through
the shared WebView2 cleanup. Plan assertion: every isTrusted row is ok on Win10 too (its WebView2 runtime can differ
from the VM's); the capability table and the `capabilities` RPC stay `unproven` until this passes.

Under ZB_WIN_GATE=1 a missing host configuration exits 1; standalone it exits 77. A host run needs NavyCanyon's
exact-commit approval and the orchestrator's release, after GrayHarbor's approved read-only Win10 probe.

Run:  env -u ZB_WIN_KEY -u ZB_WIN_KNOWN_HOSTS -u ZB_HOST_LIVE -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY \
      -u SSH_ASKPASS ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_PORT=2222 ZB_WIN11_USER=zbtext \
      ZB_WIN11_KEY=<key> ZB_WIN11_KNOWN_HOSTS=<known_hosts> ZB_WIN11_MARKER=<marker> \
      ZB_WIN10_HOST=<host> ZB_WIN10_PORT=22 ZB_WIN10_USER=zbtest ZB_WIN10_KEY=<key> \
      ZB_WIN10_KNOWN_HOSTS=<known_hosts> ZB_WIN10_MARKER=<marker> ZB_BUILD_COMMIT=<full sha> \
      python3 -I tests/e2e/win_trusted_input_matrix_w10.py
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir
sys.path.insert(0, str(HERE.parent / "windows"))

from win_trusted_input_matrix import REQUIRED  # noqa: E402  the same rows as the Win11 leg
from win10_spike_run import run_on_win10  # noqa: E402

BUILD_STEP = "ws2b1-input-spike-exe-win"
EXE = "ws2b1-input-spike.exe"
INPUTS = ("tests/fixtures/automation/input.html", "tests/fixtures/automation/scroll.html",
          "src/automation_script/automation.js")

if __name__ == "__main__":
    raise SystemExit(run_on_win10(BUILD_STEP, EXE, INPUTS, REQUIRED, "ws2b1-trusted-input-matrix-w10"))
