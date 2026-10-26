#!/usr/bin/env python3
"""Direct macOS product e2e for Agent Drawer minimize shortcuts.

The real native app opens the drawer before each gesture, sends native AppKit
key events through NSApplication, and reports the resulting drawer state.
Escape and Command-Shift-Space must each minimize an open drawer.  The launch
uses a private HOME, TMPDIR, and browser profile.
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


ESCAPE_OPEN = "DRAWER\t1\tshortcut-open-escape\t1"
ESCAPE_CLOSED = "DRAWER\t1\tshortcut-escape\t0"
SPACE_OPEN = "DRAWER\t1\tshortcut-open-command-shift-space\t1"
SPACE_CLOSED = "DRAWER\t1\tshortcut-command-shift-space\t0"
EXPECTED = (ESCAPE_OPEN, ESCAPE_CLOSED, SPACE_OPEN, SPACE_CLOSED)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    browser = args.browser.resolve()
    if not browser.is_file():
        print(f"FAIL\tmac-drawer-shortcuts\tbrowser is missing: {browser}")
        return 1

    lines: list[str] = []
    leak = False
    with tempfile.TemporaryDirectory(prefix="zb-mac-drawer-shortcuts-") as raw:
        root = Path(raw)
        home, temp, profile = root / "home", root / "tmp", root / "profile"
        for directory in (home, temp, profile):
            directory.mkdir(mode=0o700)
        env = dict(os.environ)
        env.update({
            "HOME": str(home),
            "TMPDIR": str(temp),
            "ZB_DEBUG_DRAWER_SHORTCUTS": "1",
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
            while time.monotonic() < deadline and proc.poll() is None and SPACE_CLOSED not in lines:
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
            proc.stdout.close()
            proc.stderr.close()

    failures: list[str] = []
    for expected in EXPECTED:
        if lines.count(expected) != 1:
            failures.append(f"expected one exact row: {expected}")
    if all(row in lines for row in EXPECTED):
        positions = [lines.index(row) for row in EXPECTED]
        if positions != sorted(positions):
            failures.append("shortcut rows are out of order")
    if leak:
        failures.append(f"started browser pid {proc.pid} did not exit after SIGTERM")
    if failures:
        for failure in failures:
            print(f"FAIL\tmac-drawer-shortcuts\t{failure}")
        for line in lines[-20:]:
            print(f"OUTPUT\t{line}")
        return 1
    print("PASS\tmac-drawer-shortcuts\tEscape and Command-Shift-Space minimize")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
