#!/usr/bin/env python3
"""Direct macOS product e2e for the native drawer's dock and resize layout.

The test launches the real native ``zigBrowser`` under a private HOME, TMPDIR,
and profile.  With ``--e2e-protocol`` the product-only layout seam opens the
drawer, then resizes the real AppKit window from 1024x768 to 800x600.  The
``DRAWER`` rows report the content bounds and the actual page and panel frames
after AppKit layout.  The exact rows bind the panel to the bottom edge, full
width and inside the content view, rather than trusting proposed geometry.

Run on a Mac:
  python3 -B tests/e2e/mac_drawer_dock_test.py --browser zig-out/bin/zigBrowser
"""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import subprocess
import tempfile
import time
from pathlib import Path


OPEN = "DRAWER\t1\topen\tcontent=0,0,1024,768\tpage=0,269,1024,499\tpanel=0,0,1024,269\tinside=1"
RESIZE = "DRAWER\t1\tresize\tcontent=0,0,800,600\tpage=0,240,800,360\tpanel=0,0,800,240\tinside=1"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    browser = args.browser.resolve()
    if not browser.is_file():
        print(f"FAIL\tmac-drawer-dock\tbrowser is missing: {browser}")
        return 1

    lines: list[str] = []
    leak = False
    with tempfile.TemporaryDirectory(prefix="zb-mac-drawer-dock-") as raw:
        root = Path(raw)
        home, temp, profile = root / "home", root / "tmp", root / "profile"
        for directory in (home, temp, profile):
            directory.mkdir(mode=0o700)
        env = dict(os.environ)
        env.update({
            "HOME": str(home),
            "TMPDIR": str(temp),
            "ZB_DEBUG_DRAWER_LAYOUT": "1",
        })
        proc = subprocess.Popen(
            [str(browser), "about:blank", "--agent-drawer", "on", "--e2e-protocol",
             "--profile-dir", str(profile)],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        assert proc.stdout is not None and proc.stderr is not None
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        selector.register(proc.stderr, selectors.EVENT_READ)
        deadline = time.monotonic() + args.timeout
        try:
            while time.monotonic() < deadline and proc.poll() is None and RESIZE not in lines:
                for key, _ in selector.select(timeout=0.2):
                    line = key.fileobj.readline()
                    if line:
                        lines.append(line.rstrip("\r\n"))
            if proc.poll() is not None:
                for stream in (proc.stdout, proc.stderr):
                    lines.extend(line.rstrip("\r\n") for line in stream.readlines())
        finally:
            selector.close()
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    leak = True

    failures = []
    if OPEN not in lines:
        failures.append(f"missing exact open row: {OPEN}")
    if RESIZE not in lines:
        failures.append(f"missing exact resize row: {RESIZE}")
    if leak:
        failures.append(f"started browser pid {proc.pid} did not exit after SIGTERM")
    if failures:
        for failure in failures:
            print(f"FAIL\tmac-drawer-dock\t{failure}")
        for line in lines[-20:]:
            print(f"OUTPUT\t{line}")
        return 1
    print("PASS\tmac-drawer-dock\tactual open and resize frames are docked inside content")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
