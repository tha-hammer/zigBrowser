#!/usr/bin/env python3
"""Intel Mac owner acceptance: installed DMG -> Secrets -> drawer -> reply.

This direct product test mounts the supplied DMG read-only, copies its app into
an owned temporary Applications directory, launches that installed copy with a
private browser profile, and observes exact rows from the real AppKit controls.

The e2e-only action file asks the application to perform the owner-visible
sequence itself: open the drawer's Set Up control, enter the token into the
Secrets window's secure field and press Save, enter the prompt and press Send.
The application emits each OWNER_ACCEPTANCE row only after the corresponding
visible AppKit state exists.  The action file is ignored without
--e2e-protocol; its token is in a separate 0600 file, never argv or environment.

Set ZB_TEST_CLAUDE_TOKEN to a real long-lived token to require a live assistant
reply. Without it the test uses a format-valid test token and still runs every
step through Send; only the live reply assertion is reported as skipped.

The fixed product Keychain item must be absent before the run. The test refuses
to overwrite an existing credential, never prints the token, and removes only
the exact credential it inserted.

Run on the Intel Mac:
  python3 -B tests/e2e/mac_owner_acceptance_test.py --dmg zigBrowser_0.2.0_macos.dmg
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional


SERVICE = "dev.zigbrowser.ClaudeAgentToken"
ACCOUNT = "default"
DUMMY_TOKEN = "sk-ant-oat01-" + ("Z" * 32)
TOKEN_RE = re.compile(r"sk-ant-oat01-[A-Za-z0-9_-]{22,499}\Z")
PROMPT = "Reply with exactly: zigBrowser owner acceptance"
OPEN_ROW_PREFIX = "DRAWER\t1\topen\t"
SECRETS_ROW = "OWNER_ACCEPTANCE\tsecrets-open\tClaude Agent account"
STORED_ROW = "OWNER_ACCEPTANCE\tcredential-stored\tconnected"
SENT_ROW = "OWNER_ACCEPTANCE\tmessage-sent\tuser-bubble"
REPLY_ROW = "OWNER_ACCEPTANCE\treply-bubble\tassistant"
ACTION_ENV = "ZB_DEBUG_OWNER_ACCEPTANCE_FILE"


class Results:
    def __init__(self) -> None:
        self.failed = False

    def passed(self, step: str, detail: str) -> None:
        print(f"PASS\towner-acceptance\t{step}\t{detail}", flush=True)

    def failed_step(self, step: str, detail: str) -> None:
        self.failed = True
        print(f"FAIL\towner-acceptance\t{step}\t{detail}", flush=True)

    def skipped(self, step: str, detail: str) -> None:
        print(f"SKIP\towner-acceptance\t{step}\t{detail}", flush=True)


def app_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def wait_for_rows(path: Path, wanted: set[str], timeout: float) -> list[str]:
    deadline = time.monotonic() + timeout
    lines: list[str] = []
    while time.monotonic() < deadline:
        lines = app_lines(path)
        if wanted.issubset(set(lines)):
            break
        time.sleep(0.25)
    return lines


def keychain_read() -> tuple[str, bytes]:
    done = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if done.returncode == 0:
        return "present", done.stdout.rstrip(b"\r\n")
    if done.returncode == 44 or b"could not be found" in done.stderr:
        return "absent", b""
    return "error", b""


def keychain_delete() -> bool:
    done = subprocess.run(
        ["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", ACCOUNT],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return done.returncode == 0


def attach_and_install(dmg: Path, root: Path) -> tuple[Optional[Path], Optional[str]]:
    mount = root / "mnt"
    install = root / "Applications"
    mount.mkdir(mode=0o700)
    install.mkdir(mode=0o700)
    done = subprocess.run(
        [
            "/usr/bin/hdiutil",
            "attach",
            "-plist",
            "-readonly",
            "-nobrowse",
            "-noautoopen",
            "-mountpoint",
            str(mount),
            str(dmg),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if done.returncode != 0:
        return None, "hdiutil attach failed"
    device = None
    try:
        plist = plistlib.loads(done.stdout)
        for entity in plist.get("system-entities", []):
            if entity.get("dev-entry"):
                device = entity["dev-entry"]
                break
    except (plistlib.InvalidFileException, ValueError, TypeError):
        pass
    if device is None:
        subprocess.run(
            ["/usr/bin/hdiutil", "detach", str(mount)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return None, "hdiutil did not report a mounted device"

    app = mount / "zigBrowser.app"
    installed = install / "zigBrowser.app"
    copy_error = None
    try:
        if not app.is_dir():
            copy_error = "mounted DMG has no zigBrowser.app"
        else:
            copied = subprocess.run(
                ["/usr/bin/ditto", str(app), str(installed)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if copied.returncode != 0:
                copy_error = "ditto could not install zigBrowser.app"
    finally:
        detached = subprocess.run(
            ["/usr/bin/hdiutil", "detach", device],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    if detached.returncode != 0:
        return None, "hdiutil could not detach the test DMG"
    if copy_error is not None:
        return None, copy_error
    binary = installed / "Contents" / "MacOS" / "zigBrowser"
    if not binary.is_file():
        return None, "installed app has no zigBrowser executable"
    return binary, None


def write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
    finally:
        os.close(fd)


def record_exact_row(results: Results, lines: list[str], row: str, step: str, detail: str) -> bool:
    count = lines.count(row)
    if count == 1:
        results.passed(step, detail)
        return True
    results.failed_step(step, f"found {count} exact product rows, want one: {row}")
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    dmg = args.dmg.resolve()
    results = Results()
    real_token = os.environ.get("ZB_TEST_CLAUDE_TOKEN")
    token = real_token if real_token is not None else DUMMY_TOKEN
    if not TOKEN_RE.fullmatch(token):
        results.failed_step("token-input", "ZB_TEST_CLAUDE_TOKEN is not a valid long-lived token shape")
        return 1
    if not dmg.is_file():
        results.failed_step("install", f"DMG is missing: {dmg}")
        return 1

    home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-owner-acceptance-", dir=home))
    proc: Optional[subprocess.Popen] = None
    browser_stopped = True
    inserted = False
    may_store = False
    token_file: Optional[Path] = None
    action_file: Optional[Path] = None
    stdout_path, stderr_path = root / "browser.stdout", root / "browser.stderr"
    stdout_file = None
    stderr_file = None
    try:
        browser, install_error = attach_and_install(dmg, root)
        if browser is None:
            results.failed_step("install", install_error or "unknown installation failure")
            return 1
        results.passed("install", "mounted DMG read-only and copied zigBrowser.app")

        key_state, _ = keychain_read()
        may_store = key_state == "absent"
        if key_state == "present":
            results.failed_step("keychain-precondition", "existing product credential; refusing to overwrite it")
        elif key_state == "error":
            results.failed_step("keychain-precondition", "could not establish that the product credential is absent")
        else:
            results.passed("keychain-precondition", "product credential is absent")
        if not may_store:
            return 1

        temp, profile = root / "tmp", root / "profile"
        temp.mkdir(mode=0o700)
        profile.mkdir(mode=0o700)
        token_file = root / "owner-token"
        action_file = root / "owner-action.json"
        write_private(token_file, token.encode("ascii"))
        action = json.dumps(
            {"version": 1, "token_file": str(token_file), "prompt": PROMPT},
            separators=(",", ":"),
        ).encode("utf-8")
        write_private(action_file, action)

        env = dict(os.environ)
        env.pop("ZB_TEST_CLAUDE_TOKEN", None)
        env.update(
            {
                "TMPDIR": str(temp),
                "ZB_DEBUG_DRAWER_LAYOUT": "1",
                "ZB_DEBUG_EPHEMERAL_DATA_STORE": "1",
                ACTION_ENV: str(action_file),
            }
        )
        stdout_file = stdout_path.open("wb")
        stderr_file = stderr_path.open("wb")
        proc = subprocess.Popen(
            [
                str(browser),
                "about:blank",
                "--agent-drawer",
                "on",
                "--e2e-protocol",
                "--profile-dir",
                str(profile),
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stdout_file,
            stderr=stderr_file,
        )
        browser_stopped = False
        time.sleep(0.5)
        if proc.poll() is not None:
            results.failed_step("launch", f"installed application exited {proc.returncode}")
            return 1
        results.passed("launch", "installed application is running with a private profile")

        wanted = {SECRETS_ROW, STORED_ROW, SENT_ROW}
        if real_token is not None:
            wanted.add(REPLY_ROW)
        lines = wait_for_rows(stdout_path, wanted, max(args.timeout, 120.0 if real_token else args.timeout))

        open_rows = [line for line in lines if line.startswith(OPEN_ROW_PREFIX)]
        if len(open_rows) == 1:
            results.passed("drawer-open", "observed one native drawer open row")
        else:
            results.failed_step("drawer-open", f"found {len(open_rows)} native drawer open rows, want one")

        secrets_open = record_exact_row(
            results,
            lines,
            SECRETS_ROW,
            "secrets-open",
            "drawer Set Up opened the native Secrets window",
        )
        stored_row = record_exact_row(
            results,
            lines,
            STORED_ROW,
            "credential-store-row",
            "Secrets Save showed the connected state",
        )
        key_state, key_value = keychain_read()
        stored = may_store and key_state == "present" and key_value == token.encode("ascii")
        if stored:
            inserted = True
            results.passed("credential-store", "login Keychain contains the exact test credential")
        elif may_store:
            results.failed_step("credential-store", "login Keychain does not contain the exact test credential")
        else:
            results.failed_step("credential-store", "blocked by Keychain precondition")

        sent = record_exact_row(
            results,
            lines,
            SENT_ROW,
            "message-send",
            "Send produced the visible user bubble",
        )

        if real_token is None:
            results.skipped(
                "reply-bubble",
                "ZB_TEST_CLAUDE_TOKEN is unset; only the live reply assertion is skipped",
            )
        else:
            record_exact_row(
                results,
                lines,
                REPLY_ROW,
                "reply-bubble",
                "a visible assistant bubble appeared",
            )

        required_rows = [SECRETS_ROW, STORED_ROW, SENT_ROW]
        positions = [lines.index(row) for row in required_rows if row in lines]
        if secrets_open and stored_row and sent and positions == sorted(positions):
            results.passed("event-order", "Secrets, credential and Send rows are ordered")
        else:
            results.failed_step("event-order", "required product rows are missing or out of order")

    finally:
        if may_store:
            state, current = keychain_read()
            if state == "present" and current == token.encode("ascii"):
                if keychain_delete():
                    inserted = False
                    results.passed("credential-cleanup", "removed only the credential inserted by this run")
                else:
                    results.failed_step("credential-cleanup", "could not remove the credential inserted by this run")
            elif state == "present":
                results.failed_step("credential-cleanup", "credential changed during run; refusing to remove it")
            elif inserted and state == "absent":
                inserted = False
                results.passed("credential-cleanup", "credential inserted by this run is absent")
        if token_file is not None:
            token_file.unlink(missing_ok=True)
        if action_file is not None:
            action_file.unlink(missing_ok=True)
        if proc is not None and proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=10.0)
                browser_stopped = True
            except subprocess.TimeoutExpired:
                results.failed_step("shutdown", f"owned application pid {proc.pid} ignored SIGTERM; run root retained")
        elif proc is not None:
            browser_stopped = True
        if stdout_file is not None:
            stdout_file.close()
        if stderr_file is not None:
            stderr_file.close()
        if browser_stopped and root.parent == home and root.name.startswith("zb-owner-acceptance-"):
            shutil.rmtree(root)

    return 1 if results.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
