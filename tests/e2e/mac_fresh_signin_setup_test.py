#!/usr/bin/env python3
"""Installed macOS app: first-action Sign in provisions, then starts login.

The installed app gets a fresh XDG_DATA_HOME but keeps the real HOME, matching
the owner's first-install path and allowing the login Keychain to work.  An
offline setup-token fake stops the flow at the authorization-code field.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path


DEAD_END = "Claude Agent setup must finish before sign-in."
SETTING_UP = "Setting up the Claude Agent (first time, about a minute)…"
NEED_CODE = "Paste the authorization code from your browser."
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def fail(reason: str) -> int:
    print(f"FAIL\tmac-fresh-signin-setup\t{reason}", flush=True)
    return 1


def app_pids(executable: Path) -> dict[int, str]:
    done = subprocess.run(
        ["/bin/ps", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        check=True,
    )
    prefix = str(executable) + " "
    found: dict[int, str] = {}
    for line in done.stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        pid_text, command = fields
        if command == str(executable) or command.startswith(prefix):
            found[int(pid_text)] = command
    return found


def apple(pid: int, body: str) -> subprocess.CompletedProcess[str]:
    script = (
        'tell application "System Events" to tell first process whose unix id is '
        f"{pid} to tell window \"Claude Agent account\" to {body}"
    )
    return subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        capture_output=True,
        text=True,
        check=False,
    )


def status_text(pid: int) -> str:
    done = apple(pid, "get value of every static text")
    return done.stdout.strip() if done.returncode == 0 else ""


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        with path.open("rb") as stream:
            data = stream.read(33)
    except OSError:
        return None
    if len(data) != 33 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return (width, height) if width >= 600 and height >= 400 else None


def stop_owned(pid: int, command: str) -> bool:
    current = app_pids(Path(command.split(" ", 1)[0])).get(pid)
    if current != command:
        return current is None
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if pid not in app_pids(Path(command.split(" ", 1)[0])):
            return True
        time.sleep(0.1)
    current = app_pids(Path(command.split(" ", 1)[0])).get(pid)
    if current != command:
        return current is None
    os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if pid not in app_pids(Path(command.split(" ", 1)[0])):
            return True
        time.sleep(0.1)
    return False


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--fake-cli", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--setup-png", required=True, type=Path)
    parser.add_argument("--code-png", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=180.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        return fail("this product test requires macOS")

    app = args.app.resolve()
    executable = app / "Contents/MacOS/zigBrowser"
    fake = args.fake_cli.resolve()
    work_dir = args.work_dir.resolve()
    setup_png = args.setup_png.expanduser().resolve()
    code_png = args.code_png.expanduser().resolve()
    if not executable.is_file() or not fake.is_file() or not os.access(fake, os.X_OK):
        return fail("installed app or executable fake CLI is missing")
    if not work_dir.is_dir():
        return fail("owned work directory is missing")
    for output in (setup_png, code_png):
        if not output.is_absolute() or not output.parent.is_dir() or output.exists():
            return fail(f"refusing snapshot output: {output}")

    root = Path(tempfile.mkdtemp(prefix="fresh-signin-", dir=work_dir))
    for name in ("data", "profile", "tmp"):
        (root / name).mkdir(mode=0o700)
    token_file = root / "invalid-token"
    action_file = root / "open-secrets.json"
    write_private(token_file, b"invalid\n")
    write_private(
        action_file,
        json.dumps(
            {
                "version": 1,
                "token_file": str(token_file),
                "prompt": "unused",
                "expect_reply": False,
            },
            separators=(",", ":"),
        ).encode("utf-8"),
    )

    stdout_path = root / "browser.stdout"
    stderr_path = root / "browser.stderr"
    before = app_pids(executable)
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
            f"XDG_DATA_HOME={root / 'data'}",
            "--env",
            f"TMPDIR={root / 'tmp'}",
            "--env",
            f"ZB_DEBUG_OWNER_ACCEPTANCE_FILE={action_file}",
            "--env",
            f"ZIGBROWSER_AGENT_CLAUDE_CLI={fake}",
            "--env",
            f"ZB_DEBUG_MAC_SECRETS_SETUP_PNG={setup_png}",
            "--env",
            f"ZB_DEBUG_MAC_SECRETS_CODE_PNG={code_png}",
            str(app),
            "--args",
            "about:blank",
            "--agent-drawer",
            "on",
            "--e2e-protocol",
            "--profile-dir",
            str(root / "profile"),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    app_pid = None
    command = None
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            after = app_pids(executable)
            created = [(pid, text) for pid, text in after.items() if pid not in before]
            if len(created) == 1:
                app_pid, command = created[0]
                break
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        if app_pid is None or command is None:
            return fail("could not identify the installed app process")

        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if "OWNER_ACCEPTANCE\tsecrets-open\tClaude Agent account" in (
                stdout_path.read_text(encoding="utf-8", errors="replace")
                if stdout_path.exists()
                else ""
            ):
                break
            time.sleep(0.1)
        else:
            return fail("drawer Sign in did not open the Secrets window")

        clicked = apple(app_pid, 'click button "Sign in with Claude.ai"')
        if clicked.returncode != 0:
            return fail(f"could not press Sign in with Claude.ai: {clicked.stderr.strip()}")

        saw_setup = False
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            text = status_text(app_pid)
            if DEAD_END in text:
                return fail(f"dead-end: {DEAD_END}")
            saw_setup = saw_setup or SETTING_UP in text
            if NEED_CODE in text:
                break
            if proc.poll() is not None:
                return fail(f"installed app exited before authorization-code step: {proc.returncode}")
            time.sleep(0.2)
        else:
            return fail("sign-in never reached the authorization-code step")

        if not saw_setup:
            return fail("Secrets never showed first-time setup progress")
        setup_size, code_size = png_size(setup_png), png_size(code_png)
        if setup_size is None:
            return fail("missing readable-size in-app setup PNG")
        if code_size is None:
            return fail("missing readable-size in-app authorization-code PNG")
        print(
            "PASS\tmac-fresh-signin-setup\t"
            f"setup-then-code\t{setup_size[0]}x{setup_size[1]}\t"
            f"{code_size[0]}x{code_size[1]}",
            flush=True,
        )
        return 0
    finally:
        if app_pid is not None and command is not None and not stop_owned(app_pid, command):
            print(f"FAIL\tmac-fresh-signin-setup\towned app did not stop; run retained: {root}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
