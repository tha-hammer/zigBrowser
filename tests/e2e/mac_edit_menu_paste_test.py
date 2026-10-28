#!/usr/bin/env python3
"""Installed-app proof for standard macOS Edit-menu responder shortcuts."""

from __future__ import annotations

import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EXPECTED = "EDIT_PASTE_TEST\tmenu=1\tsecrets=1\tdrawer=1\tpng=1"


def fail(reason: str, lines: list[str] | None = None) -> int:
    print(f"FAIL\tmac-edit-menu-paste\t{reason}", flush=True)
    for line in (lines or [])[-20:]:
        print(f"OUTPUT\t{line}", flush=True)
    return 1


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 10_000 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return (width, height) if width >= 600 and height >= 400 else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--driver", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=25.0)
    args = parser.parse_args()

    if sys.platform != "darwin":
        return fail("this installed-app test requires macOS")
    app = args.app.expanduser().resolve()
    executable = app / "Contents/MacOS/zigBrowser"
    driver = args.driver.expanduser().resolve()
    output = args.output.expanduser()
    if not executable.is_file():
        return fail(f"installed app executable is missing: {executable}")
    if not driver.is_file():
        return fail(f"driver source is missing: {driver}")
    if not output.is_absolute():
        return fail("--output must be absolute")
    output = output.resolve()
    if output.exists():
        return fail(f"refusing to overwrite output: {output}")

    owner_home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-edit-menu-paste-", dir=owner_home))
    private_home, temp, data, profile = (
        root / "home", root / "tmp", root / "data", root / "profile"
    )
    for directory in (private_home, temp, data, profile):
        directory.mkdir(mode=0o700)
    dylib = root / "mac_edit_menu_paste_driver.dylib"
    stdout_path, stderr_path = root / "browser.stdout", root / "browser.stderr"
    stdout_path.touch(mode=0o600)
    stderr_path.touch(mode=0o600)

    compile_run = subprocess.run(
        ["xcrun", "clang", "-dynamiclib", "-fobjc-arc", str(driver),
         "-framework", "AppKit", "-o", str(dylib)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=args.timeout,
    )
    if compile_run.returncode != 0:
        return fail(f"driver compile exited {compile_run.returncode}: {compile_run.stderr[-1000:]}")

    command = [
        "/usr/bin/open", "-n", "-W", "-o", str(stdout_path),
        "--stderr", str(stderr_path),
        "--env", f"HOME={private_home}",
        "--env", f"TMPDIR={temp}",
        "--env", f"XDG_DATA_HOME={data}",
        "--env", "ZB_DEBUG_DRAWER_LAYOUT=1",
        "--env", "ZB_DEBUG_QUIT_AFTER_MS=8000",
        "--env", f"DYLD_INSERT_LIBRARIES={dylib}",
        "--env", f"ZB_EDIT_PASTE_PNG={output}",
        str(app), "--args", "about:blank", "--agent-drawer", "on",
        "--e2e-protocol", "--profile-dir", str(profile),
    ]
    try:
        launch = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=args.timeout,
        )
    except subprocess.TimeoutExpired:
        return fail(f"owned LaunchServices app did not exit; retained root: {root}")

    lines = stdout_path.read_text(encoding="utf-8", errors="replace").splitlines()
    result_rows = [line for line in lines if line.startswith("EDIT_PASTE_TEST\t")]
    if launch.returncode != 0:
        detail = stderr_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return fail(f"open -W exited {launch.returncode}", lines + detail)
    if result_rows != [EXPECTED]:
        got = result_rows[0] if len(result_rows) == 1 else f"{len(result_rows)} result rows"
        return fail(f"got {got}; want {EXPECTED}", lines)
    dimensions = png_size(output)
    if dimensions is None:
        return fail(f"missing or malformed cache-rendered PNG: {output}", lines)

    shutil.rmtree(root)
    width, height = dimensions
    print(
        f"PASS\tmac-edit-menu-paste\tmenu, Secrets and drawer Cmd+V\t"
        f"{output}\t{width}x{height}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
