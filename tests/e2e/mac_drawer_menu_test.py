#!/usr/bin/env python3
"""Direct macOS product e2e for View > Agent Drawer.

The real native app installs its minimal main menu, locates the actual
``View > Agent Drawer`` item, and invokes that item's target/action twice.
Exact product rows prove the item exists, opens the drawer, then closes it.
The launch uses a private HOME, TMPDIR, and browser profile.
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


PRESENT = "DRAWER\t1\tmenu\tView > Agent Drawer"
OPEN = "DRAWER\t1\tmenu-open\t1"
CLOSED = "DRAWER\t1\tmenu-close\t0"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    browser = args.browser.resolve()
    if not browser.is_file():
        print(f"FAIL\tmac-drawer-menu\tbrowser is missing: {browser}")
        return 1

    lines: list[str] = []
    leak = False
    with tempfile.TemporaryDirectory(prefix="zb-mac-drawer-menu-") as raw:
        root = Path(raw)
        home, temp, profile = root / "home", root / "tmp", root / "profile"
        for directory in (home, temp, profile):
            directory.mkdir(mode=0o700)
        env = dict(os.environ)
        env.update({
            "HOME": str(home),
            "TMPDIR": str(temp),
            "ZB_DEBUG_DRAWER_MENU": "1",
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
            while time.monotonic() < deadline and proc.poll() is None and CLOSED not in lines:
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
    for label, expected in (("item", PRESENT), ("open", OPEN), ("close", CLOSED)):
        if lines.count(expected) != 1:
            failures.append(f"{label}: expected one exact row: {expected}")
    if all(row in lines for row in (PRESENT, OPEN, CLOSED)):
        positions = [lines.index(row) for row in (PRESENT, OPEN, CLOSED)]
        if positions != sorted(positions):
            failures.append("menu rows are out of order")
    if leak:
        failures.append(f"started browser pid {proc.pid} did not exit after SIGTERM")
    if failures:
        for failure in failures:
            print(f"FAIL\tmac-drawer-menu\t{failure}")
        for line in lines[-20:]:
            print(f"OUTPUT\t{line}")
        return 1
    print("PASS\tmac-drawer-menu\tView item opens and closes the drawer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
