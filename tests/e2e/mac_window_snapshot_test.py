#!/usr/bin/env python3
"""Launch an installed Mac app through LaunchServices and capture its window.

The product action is available only with --e2e-protocol. It renders the
browser window's own content view, so this test never needs Screen Recording
permission and never captures another application's pixels.

Run on either Mac after installing the DMG app into an owned directory:
  python3 -B mac_window_snapshot_test.py \
    --app Applications/zigBrowser.app --output "$HOME/Desktop/zigBrowser-window.png"
"""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SNAPSHOT_ENV = "ZB_DEBUG_WINDOW_SNAPSHOT_PNG"


def fail(reason: str) -> int:
    print(f"FAIL\twindow-snapshot\t{reason}", flush=True)
    return 1


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 33 or len(data) < 10_000 or data[:8] != PNG_SIGNATURE:
        return None
    if data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    if width < 600 or height < 400:
        return None
    return width, height


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=25.0)
    args = parser.parse_args()

    if sys.platform != "darwin":
        return fail("this product test requires macOS")
    app = args.app.expanduser().resolve()
    executable = app / "Contents/MacOS/zigBrowser"
    if not executable.is_file():
        return fail(f"installed app executable is missing: {executable}")
    output = args.output.expanduser()
    if not output.is_absolute():
        return fail("--output must be an absolute path")
    output = output.resolve()
    if not output.parent.is_dir():
        return fail(f"output parent is missing: {output.parent}")
    if output.exists():
        return fail(f"refusing to overwrite existing output: {output}")

    owner_home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-window-snapshot-", dir=owner_home))
    private_home = root / "home"
    temp = root / "tmp"
    data = root / "data"
    profile = root / "profile"
    for directory in (private_home, temp, data, profile):
        directory.mkdir(mode=0o700)
    stdout_path = root / "browser.stdout"
    stderr_path = root / "browser.stderr"
    for path in (stdout_path, stderr_path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)

    proc = subprocess.Popen(
        [
            "/usr/bin/open",
            "-n",
            "-W",
            "-o",
            str(stdout_path),
            "--stderr",
            str(stderr_path),
            "--env",
            f"HOME={private_home}",
            "--env",
            f"TMPDIR={temp}",
            "--env",
            f"XDG_DATA_HOME={data}",
            "--env",
            "ZB_DEBUG_DRAWER_LAYOUT=1",
            "--env",
            "ZB_DEBUG_QUIT_AFTER_MS=8000",
            "--env",
            f"{SNAPSHOT_ENV}={output}",
            str(app),
            "--args",
            "about:blank",
            "--agent-drawer",
            "on",
            "--e2e-protocol",
            "--profile-dir",
            str(profile),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    deadline = time.monotonic() + args.timeout
    dimensions = None
    while time.monotonic() < deadline:
        dimensions = png_size(output)
        if dimensions is not None:
            break
        if proc.poll() is not None:
            break
        time.sleep(0.1)

    exited = False
    try:
        proc.wait(timeout=max(1.0, deadline - time.monotonic()))
        exited = True
    except subprocess.TimeoutExpired:
        pass

    lines = stdout_path.read_text(encoding="utf-8", errors="replace").splitlines()
    snapshot_rows = [line for line in lines if line.startswith("WINDOW_SNAPSHOT\t1\t")]
    if dimensions is None:
        detail = stderr_path.read_text(encoding="utf-8", errors="replace").strip().splitlines()
        return fail(f"missing PNG at {output}; stderr tail={detail[-3:]}")
    if len(snapshot_rows) != 1:
        return fail(f"found {len(snapshot_rows)} completion rows, want one")
    if not exited:
        return fail(f"owned LaunchServices application did not exit; run root retained: {root}")

    shutil.rmtree(root)
    width, height = dimensions
    print(f"PASS\twindow-snapshot\t{output}\t{width}x{height}\t{output.stat().st_size} bytes", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
