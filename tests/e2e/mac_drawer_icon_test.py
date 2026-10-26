#!/usr/bin/env python3
"""Direct macOS product e2e for the floating Agent Drawer icon.

Two launches of the real native app use e2e-only native NSEvent gestures. A
click must open the dock. A 300x200 drag must move the icon without opening it,
and a second real browser window must start at the remembered portable ratios.
Every launch has a private HOME, TMPDIR, and profile.

Run on a Mac:
  python3 -B tests/e2e/mac_drawer_icon_test.py --browser zig-out/bin/zigBrowser
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


INITIAL = "DRAWER\t1\ticon\t944,688,56,56"
OPEN = "DRAWER\t1\topen\tpage=0,307,1024,461\tpanel=0,0,1024,307"
MOVED = "DRAWER\t1\tmoved\t644,488,56,56"
REMEMBERED = "DRAWER\t2\ticon\t644,488,56,56"


def launch(browser: Path, root: Path, mode: str, wanted: str, timeout: float) -> tuple[list[str], str | None]:
    home, temp, profile = root / "home", root / "tmp", root / "profile"
    for directory in (home, temp, profile):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update({"HOME": str(home), "TMPDIR": str(temp), "ZB_DEBUG_DRAWER_ICON": mode})
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
    lines: list[str] = []
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    selector.register(proc.stderr, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    leak = None
    try:
        while time.monotonic() < deadline and proc.poll() is None and wanted not in lines:
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
                leak = f"started browser pid {proc.pid} did not exit after SIGTERM"
        proc.stdout.close()
        proc.stderr.close()
    return lines, leak


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    browser = args.browser.resolve()
    if not browser.is_file():
        print(f"FAIL\tmac-drawer-icon\tbrowser is missing: {browser}")
        return 1

    failures: list[str] = []
    output: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-mac-drawer-icon-") as raw:
        root = Path(raw)
        click_lines, click_leak = launch(browser, root / "click", "click", OPEN, args.timeout)
        drag_lines, drag_leak = launch(browser, root / "drag", "drag", REMEMBERED, args.timeout)
        output.extend(click_lines[-12:])
        output.extend(drag_lines[-12:])
        for label, lines, expected in (
            ("click initial", click_lines, INITIAL),
            ("click opens", click_lines, OPEN),
            ("drag initial", drag_lines, INITIAL),
            ("drag moves", drag_lines, MOVED),
            ("new window remembers", drag_lines, REMEMBERED),
        ):
            if expected not in lines:
                failures.append(f"{label}: missing exact row: {expected}")
        if OPEN in drag_lines:
            failures.append("drag opened the drawer")
        if click_leak is not None:
            failures.append(click_leak)
        if drag_leak is not None:
            failures.append(drag_leak)

    if failures:
        for failure in failures:
            print(f"FAIL\tmac-drawer-icon\t{failure}")
        for line in output:
            print(f"OUTPUT\t{line}")
        return 1
    print("PASS\tmac-drawer-icon\tclick opens; drag moves; next window remembers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
