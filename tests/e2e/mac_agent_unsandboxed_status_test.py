#!/usr/bin/env python3
"""The native drawer and stderr name the macOS development launch policy.

This is a direct product test.  It launches the native browser with a private
HOME, TMPDIR, and profile.  The e2e-only layout seam exposes the real drawer's
initial messages; the quit hook only ends the real AppKit run loop.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path


STATUS = "agent running unsandboxed (dev build)"
DRAWER_ROW = f"DRAWER\t1\tmsg\tsystem\t{STATUS}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    browser = args.browser.resolve()
    if not browser.is_file():
        print(f"FAIL mac-agent-unsandboxed-status: browser is missing: {browser}")
        return 1

    root = Path(tempfile.mkdtemp(prefix="zb-mac-agent-unsandboxed-status-"))
    home, temp, profile = root / "home", root / "tmp", root / "profile"
    for directory in (home, temp, profile):
        directory.mkdir(mode=0o700)
    env = dict(os.environ)
    env.update({
        "HOME": str(home),
        "TMPDIR": str(temp),
        "ZB_DEBUG_DRAWER_LAYOUT": "1",
        "ZB_DEBUG_QUIT_AFTER_MS": "1200",
    })
    proc = subprocess.Popen(
        [str(browser), "about:blank", "--agent-drawer", "on", "--e2e-protocol",
         "--profile-dir", str(profile)],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    leaked = False
    try:
        stdout, stderr = proc.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        proc.send_signal(signal.SIGTERM)
        try:
            stdout, stderr = proc.communicate(timeout=10.0)
        except subprocess.TimeoutExpired:
            leaked = True
            stdout, stderr = "", ""

    out_lines = stdout.splitlines()
    err_lines = stderr.splitlines()
    failures: list[str] = []
    if leaked:
        failures.append(f"owned browser pid {proc.pid} ignored SIGTERM; retained {root}")
    else:
        shutil.rmtree(root)
    if not leaked and proc.returncode != 0:
        failures.append(f"browser exited {proc.returncode}, want 0")
    if err_lines.count(STATUS) != 1:
        failures.append(f"stderr has {err_lines.count(STATUS)} exact development-status lines, want 1")
    if out_lines.count(DRAWER_ROW) != 1:
        failures.append(f"drawer has {out_lines.count(DRAWER_ROW)} exact development-status rows, want 1")

    if failures:
        for failure in failures:
            print(f"FAIL mac-agent-unsandboxed-status: {failure}")
        for line in (out_lines + err_lines)[-20:]:
            print(f"OUTPUT {line}")
        return 1
    print("PASS mac-agent-unsandboxed-status: drawer and stderr name the development policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
