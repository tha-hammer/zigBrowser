#!/usr/bin/python3
"""Installed-app live drawer product test for macOS.

The app-internal driver is honored only with ``--e2e-protocol``. Manifest
version 2 puts the prompt into the real AppKit drawer input and invokes the
real Send and visible Approve buttons. It never injects a tool call, model
reply, token, CLI, or network result. The CLI, model, broker, fd-3 token route,
and browser tools remain production code.

The owner run only stats
``~/.local/share/zigbrowser/agent-home/secrets/claude_token`` and gives the app
the owner's real HOME. Browser data stays in a private ``--profile-dir`` below
``~/zb-live-<id>``. No System Events, AppleScript UI scripting, Accessibility,
or Screen Recording permission is used.

Before an owner run, prove the path with a private fake-token HOME::

  python3 -B tests/e2e/mac_live_agent_test.py \
    --dmg zigBrowser_0.2.0_macos.dmg --fake-auth-proof \
    --output "$PWD/fake-auth.png"

Run the five live owner scenarios only after explicit approval::

  python3 -B tests/e2e/mac_live_agent_test.py \
    --dmg zigBrowser_0.2.0_macos.dmg --keep-going
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


ACTION_ENV = "ZB_DEBUG_LIVE_AGENT_FILE"
ROW_PREFIX = "LIVE_AGENT\t"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
TOKEN_SHAPE = re.compile(r"sk-ant-[A-Za-z0-9_-]+")
SECRET_ASSIGNMENT = re.compile(
    r"(?i)((?:anthropic_api_key|claude_code_oauth_token|authorization|token)"
    r"\s*[:=]\s*)([^\s,;]+)"
)
AUTH_FAILURE = "authentication_failed"
FAKE_TOKEN = "sk-ant-oat01-" + "A" * 64


@dataclass(frozen=True)
class Scenario:
    number: int
    name: str
    start_url: str
    prompt: str
    tools: frozenset[str]
    approval: bool
    result_terms: tuple[str, ...]
    assistant_terms: tuple[str, ...]


SCENARIOS = (
    Scenario(
        1,
        "window-info",
        "https://example.com/",
        "Use window_info to report the current window URL and title. Do not use another tool.",
        frozenset({"window_info"}),
        False,
        ("example.com", "example domain"),
        ("example.com", "example domain"),
    ),
    Scenario(
        2,
        "navigate-heading",
        "about:blank",
        "Use the browser tools to open https://example.com and report the page heading exactly.",
        frozenset({"navigate", "get_text"}),
        True,
        ("example domain",),
        ("example domain",),
    ),
    Scenario(
        3,
        "google-search",
        "https://www.google.com/",
        "On the current Google page, use type_text to enter exactly \"zigbrowser test\" "
        "in the search box, then use press_key with Enter. Report the first result title. "
        "Do not navigate directly to a search URL.",
        frozenset({"type_text", "press_key", "get_text"}),
        True,
        ("zigbrowser",),
        ("zigbrowser",),
    ),
    Scenario(
        4,
        "form-submit",
        "https://httpbin.org/forms/post",
        "On this httpbin form, use type_text to fill Customer name with Zig Browser Owner, "
        "Telephone with 212-555-0142, and E-mail address with owner-live@zigbrowser.test. "
        "Pick Medium as the Pizza Size, submit the form, then report the echoed values for "
        "custname, custtel, custemail, and size.",
        frozenset({"type_text", "click", "get_text"}),
        True,
        ("zig browser owner", "212-555-0142", "owner-live@zigbrowser.test", "medium"),
        ("zig browser owner", "212-555-0142", "owner-live@zigbrowser.test", "medium"),
    ),
    Scenario(
        5,
        "click-more",
        "https://example.com/",
        "On example.com, use click on the \"More information...\" link, then report the new URL.",
        frozenset({"click"}),
        True,
        ("iana.org",),
        ("iana.org",),
    ),
)


@dataclass
class LiveRows:
    sent: bool
    complete: bool
    tools: list[dict[str, Any]]
    approvals: list[dict[str, Any]]
    assistants: list[str]
    snapshots: list[str]
    malformed: list[str]


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    pgid: int
    start: str
    command: str


def redact(text: str) -> str:
    text = TOKEN_SHAPE.sub("[REDACTED]", text)
    text = SECRET_ASSIGNMENT.sub(r"\1[REDACTED]", text)
    return text.replace("\r", " ").replace("\n", " ")


def private_write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(data)
        while view:
            count = os.write(fd, view)
            if count <= 0:
                raise OSError("short private write")
            view = view[count:]
    finally:
        os.close(fd)


def install_dmg(dmg: Path, root: Path) -> Path:
    mount = root / "mount"
    applications = root / "Applications"
    mount.mkdir(mode=0o700)
    applications.mkdir(mode=0o700)
    attached = subprocess.run(
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
        capture_output=True,
        check=False,
    )
    if attached.returncode != 0:
        raise RuntimeError("hdiutil attach failed")
    device = None
    try:
        manifest = plistlib.loads(attached.stdout)
        for entry in manifest.get("system-entities", []):
            if entry.get("dev-entry"):
                device = entry["dev-entry"]
                break
    except (plistlib.InvalidFileException, TypeError, ValueError):
        pass
    if device is None:
        subprocess.run(
            ["/usr/bin/hdiutil", "detach", str(mount)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        raise RuntimeError("hdiutil returned no mounted device")
    installed = applications / "zigBrowser.app"
    copy_error = None
    try:
        copied = subprocess.run(
            ["/usr/bin/ditto", str(mount / "zigBrowser.app"), str(installed)],
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
        raise RuntimeError("hdiutil could not detach the test DMG")
    if copy_error is not None:
        raise RuntimeError(copy_error)
    executable = installed / "Contents/MacOS/zigBrowser"
    if not executable.is_file():
        raise RuntimeError("installed DMG has no zigBrowser executable")
    return installed


def process_table() -> dict[int, ProcessIdentity]:
    done = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,pgid=,lstart=,command="],
        capture_output=True,
        text=True,
        check=True,
    )
    found: dict[int, ProcessIdentity] = {}
    for raw in done.stdout.splitlines():
        fields = raw.strip().split(None, 8)
        if len(fields) != 9:
            continue
        try:
            pid, ppid, pgid = (int(fields[index]) for index in range(3))
        except ValueError:
            continue
        found[pid] = ProcessIdentity(
            pid, ppid, pgid, " ".join(fields[3:8]), fields[8]
        )
    return found


def is_zigbrowser_process(process: ProcessIdentity) -> bool:
    executable = process.command.split(None, 1)[0]
    return executable.endswith("/zigBrowser.app/Contents/MacOS/zigBrowser")


def zigbrowser_processes() -> dict[int, ProcessIdentity]:
    return {
        pid: process
        for pid, process in process_table().items()
        if is_zigbrowser_process(process)
    }


def executable_processes(executable: Path) -> dict[int, ProcessIdentity]:
    exact = str(executable)
    prefix = exact + " "
    return {
        pid: process
        for pid, process in process_table().items()
        if process.command == exact or process.command.startswith(prefix)
    }


def owned_tree(root: ProcessIdentity) -> dict[int, ProcessIdentity]:
    table = process_table()
    if table.get(root.pid) != root:
        return {}
    children: dict[int, list[int]] = {}
    for process in table.values():
        children.setdefault(process.ppid, []).append(process.pid)
    found: dict[int, ProcessIdentity] = {}
    pending = [root.pid]
    while pending:
        pid = pending.pop()
        process = table.get(pid)
        if process is None or pid in found:
            continue
        found[pid] = process
        pending.extend(children.get(pid, ()))
    return found


def matching_survivors(expected: dict[int, ProcessIdentity]) -> list[ProcessIdentity]:
    table = process_table()
    return [process for pid, process in expected.items() if table.get(pid) == process]


def stop_owned(identity: Optional[ProcessIdentity], executable: Path) -> Optional[str]:
    if identity is None or executable_processes(executable).get(identity.pid) != identity:
        return None
    owned = owned_tree(identity)
    try:
        os.kill(identity.pid, signal.SIGTERM)
    except ProcessLookupError:
        return None
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if process_table().get(identity.pid) != identity:
            break
        time.sleep(0.1)
    else:
        if process_table().get(identity.pid) != identity:
            return "owned application identity changed before forced quit"
        try:
            os.kill(identity.pid, signal.SIGKILL)
        except ProcessLookupError:
            return None
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and process_table().get(identity.pid) == identity:
            time.sleep(0.1)
        if process_table().get(identity.pid) == identity:
            return f"owned application pid {identity.pid} survived TERM and KILL"

    descendants = {pid: value for pid, value in owned.items() if pid != identity.pid}
    deadline = time.monotonic() + 8.0
    survivors = matching_survivors(descendants)
    while survivors and time.monotonic() < deadline:
        time.sleep(0.1)
        survivors = matching_survivors(descendants)
    if survivors:
        names = ",".join(
            f"{item.pid}:{Path(item.command.split()[0]).name}" for item in survivors[:8]
        )
        return f"owned application descendants survived controlled quit: {names}"
    return None


def stop_opener(opener: subprocess.Popen[bytes]) -> Optional[str]:
    try:
        opener.wait(timeout=5)
        return None
    except subprocess.TimeoutExpired:
        opener.terminate()
    try:
        opener.wait(timeout=2)
    except subprocess.TimeoutExpired:
        opener.kill()
        opener.wait(timeout=2)
    return "open -W did not finish after the app stopped"


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def safe_drawer_lines(path: Path, start_size: int) -> list[str]:
    try:
        with path.open("rb") as stream:
            stream.seek(min(start_size, path.stat().st_size))
            raw_lines = stream.read().splitlines()
    except OSError:
        return ["<no new drawer.log lines>"]
    if not raw_lines:
        return ["<no new drawer.log lines>"]
    return [redact(line.decode("utf-8", errors="replace"))[:1200] for line in raw_lines]


def decode_payload(payload: str) -> bytes:
    return base64.b64decode(payload, validate=True)


def parse_live_rows(lines: list[str], scenario: str) -> LiveRows:
    parsed = LiveRows(False, False, [], [], [], [], [])
    prefix = f"{ROW_PREFIX}{scenario}\t"
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or fields[0] != "LIVE_AGENT" or fields[1] != scenario:
            parsed.malformed.append(line)
            continue
        event, payload = fields[2], fields[3]
        try:
            if event == "sent" and payload == "-":
                parsed.sent = True
            elif event == "complete" and payload == "-":
                parsed.complete = True
            elif event == "tool":
                value = json.loads(decode_payload(payload).decode("utf-8"))
                if not isinstance(value, dict):
                    raise ValueError("tool payload is not an object")
                parsed.tools.append(value)
            elif event == "approval":
                value = json.loads(decode_payload(payload).decode("utf-8"))
                if not isinstance(value, dict):
                    raise ValueError("approval payload is not an object")
                parsed.approvals.append(value)
            elif event == "assistant":
                parsed.assistants.append(decode_payload(payload).decode("utf-8"))
            elif event == "snapshot":
                parsed.snapshots.append(decode_payload(payload).decode("utf-8"))
            else:
                parsed.malformed.append(line)
        except (ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
            parsed.malformed.append(line)
    return parsed


def png_size(path: Path) -> Optional[tuple[int, int]]:
    try:
        with path.open("rb") as stream:
            header = stream.read(24)
        size = path.stat().st_size
    except OSError:
        return None
    if size < 10_000 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    if width < 600 or height < 400:
        return None
    return width, height


def tool_name(value: dict[str, Any]) -> str:
    name = value.get("tool")
    return name.rsplit("__", 1)[-1] if isinstance(name, str) else ""


def validate_scenario(scenario: Scenario, rows: LiveRows, png: Path) -> Optional[str]:
    if rows.malformed:
        return f"malformed live row: {rows.malformed[0]!r}"
    if not rows.sent:
        return "version-2 real-control driver did not click Send"
    if not rows.complete:
        return "version-2 real-control driver did not complete"
    failed_tools = [tool for tool in rows.tools if tool.get("ok") is not True]
    if failed_tools:
        return f"tool failed: {failed_tools[0]!r}"
    used = {tool_name(tool) for tool in rows.tools}
    missing = sorted(scenario.tools - used)
    if missing:
        return f"missing required real tool calls {missing}; observed {sorted(used)!r}"
    if scenario.approval and not any(
        item.get("outcome") == "approved" for item in rows.approvals
    ):
        return f"no real Approve button completed; observed {rows.approvals!r}"
    if len(rows.assistants) != 1 or not rows.assistants[0].strip():
        return f"found {len(rows.assistants)} final assistant rows, want one"
    all_text = "\n".join(
        rows.assistants
        + [tool.get("body", "") for tool in rows.tools if isinstance(tool.get("body"), str)]
    ).lower()
    if not all(term in all_text for term in scenario.result_terms):
        return f"page/tool evidence lacks {scenario.result_terms!r}"
    assistant = rows.assistants[0].lower()
    if not all(term in assistant for term in scenario.assistant_terms):
        return f"assistant answer lacks {scenario.assistant_terms!r}"
    if rows.snapshots != [str(png)]:
        return f"snapshot rows are {rows.snapshots!r}, want {[str(png)]!r}"
    if png_size(png) is None:
        return f"in-app PNG is missing or invalid: {png}"
    return None


def discover_app(
    opener: subprocess.Popen[bytes], executable: Path, before: set[int], deadline: float
) -> tuple[Optional[ProcessIdentity], Optional[str]]:
    while time.monotonic() < deadline:
        now = executable_processes(executable)
        created = sorted(set(now) - before)
        if len(created) == 1:
            return now[created[0]], None
        if len(created) > 1:
            return None, f"launch created {len(created)} matching app processes, want one"
        if opener.poll() is not None:
            return None, f"open exited {opener.returncode} before the installed app appeared"
        time.sleep(0.1)
    return None, "installed app did not appear before timeout"


def launch_command(
    app: Path,
    stdout: Path,
    stderr: Path,
    home: Path,
    data: Path,
    cache: Path,
    temp: Path,
    profile: Path,
    action: Path,
    start_url: str,
    extra_env: tuple[str, ...] = (),
) -> list[str]:
    command = [
        "/usr/bin/open",
        "-n",
        "-W",
        "-o",
        str(stdout),
        "--stderr",
        str(stderr),
        "--env",
        f"HOME={home}",
        "--env",
        f"XDG_DATA_HOME={data}",
        "--env",
        f"XDG_CACHE_HOME={cache}",
        "--env",
        f"TMPDIR={temp}",
        "--env",
        f"{ACTION_ENV}={action}",
    ]
    for value in extra_env:
        command.extend(("--env", value))
    command.extend(
        (
            str(app),
            "--args",
            start_url,
            "--agent-drawer",
            "on",
            "--e2e-protocol",
            "--profile-dir",
            str(profile),
        )
    )
    return command


def run_scenario(
    app: Path,
    root: Path,
    owner_home: Path,
    owner_data: Path,
    scenario: Scenario,
    timeout: float,
) -> tuple[bool, str, list[str], Path, bool]:
    executable = app / "Contents/MacOS/zigBrowser"
    scenario_root = root / f"scenario-{scenario.number}-{scenario.name}"
    profile, temp, cache = (
        scenario_root / "profile",
        scenario_root / "tmp",
        scenario_root / "cache",
    )
    for directory in (scenario_root, profile, temp, cache):
        directory.mkdir(mode=0o700)
    stdout, stderr = scenario_root / "browser.stdout", scenario_root / "browser.stderr"
    action, png = scenario_root / "live-action.json", scenario_root / "window.png"
    private_write(stdout, b"")
    private_write(stderr, b"")
    private_write(
        action,
        json.dumps(
            {
                "version": 2,
                "scenario": scenario.name,
                "prompt": scenario.prompt,
                "approve": "all",
                "snapshot_png": str(png),
            },
            separators=(",", ":"),
        ).encode("utf-8"),
    )
    drawer_log = owner_data / "zigbrowser/agent-home/state/drawer.log"
    try:
        drawer_offset = drawer_log.stat().st_size
    except OSError:
        drawer_offset = 0
    before = set(executable_processes(executable))
    opener = subprocess.Popen(
        launch_command(
            app,
            stdout,
            stderr,
            owner_home,
            owner_data,
            cache,
            temp,
            profile,
            action,
            scenario.start_url,
        ),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + timeout
    identity, reason = discover_app(opener, executable, before, deadline)
    rows = LiveRows(False, False, [], [], [], [], [])
    try:
        while reason is None and identity is not None and time.monotonic() < deadline:
            rows = parse_live_rows(read_lines(stdout), scenario.name)
            if rows.complete and rows.snapshots:
                break
            if process_table().get(identity.pid) != identity:
                reason = "owned installed application exited before completion"
                break
            time.sleep(0.2)
        if reason is None:
            reason = validate_scenario(scenario, rows, png)
        if reason is None and time.monotonic() >= deadline:
            reason = f"scenario exceeded {timeout:.0f}s"
    finally:
        stop_error = stop_owned(identity, executable)
        opener_error = stop_opener(opener)
        for error in (stop_error, opener_error):
            if error is not None:
                reason = f"{reason}; {error}" if reason else error
    drawer_lines = safe_drawer_lines(drawer_log, drawer_offset)
    cleanup_safe = stop_error is None
    if reason is not None:
        err_tail = read_lines(stderr)[-1:] or ["<no stderr line>"]
        return False, f"{reason}; stderr={redact(err_tail[0])[:600]}", drawer_lines, png, cleanup_safe
    return (
        True,
        f"tools={len(rows.tools)} approvals={len(rows.approvals)} png={png_size(png)}",
        drawer_lines,
        png,
        cleanup_safe,
    )


def run_fake_auth(
    app: Path, root: Path, private_home: Path, output: Path, timeout: float
) -> tuple[bool, str, list[str], bool]:
    executable = app / "Contents/MacOS/zigBrowser"
    data = private_home / ".local/share"
    agent_home = data / "zigbrowser/agent-home"
    secrets = agent_home / "secrets"
    scenario_root = root / "fake-auth"
    profile, temp, cache = (
        scenario_root / "profile",
        scenario_root / "tmp",
        scenario_root / "cache",
    )
    for directory in (
        private_home,
        private_home / ".local",
        data,
        data / "zigbrowser",
        agent_home,
        secrets,
        scenario_root,
        profile,
        temp,
        cache,
    ):
        directory.mkdir(mode=0o700, exist_ok=True)
    token = secrets / "claude_token"
    if not token.exists():
        private_write(token, FAKE_TOKEN.encode("ascii"))
    if stat.S_IMODE(token.stat().st_mode) != 0o600:
        return False, "private fake token is not mode 0600", [], True

    stdout, stderr = scenario_root / "browser.stdout", scenario_root / "browser.stderr"
    action, unused_live_png = (
        scenario_root / "live-action.json",
        scenario_root / "live-unused.png",
    )
    private_write(stdout, b"")
    private_write(stderr, b"")
    private_write(
        action,
        json.dumps(
            {
                "version": 2,
                "scenario": "fake-auth",
                "prompt": "Use window_info to report the current page.",
                "approve": "all",
                "snapshot_png": str(unused_live_png),
            },
            separators=(",", ":"),
        ).encode("utf-8"),
    )
    drawer_log = agent_home / "state/drawer.log"
    try:
        drawer_offset = drawer_log.stat().st_size
    except OSError:
        drawer_offset = 0
    before = set(executable_processes(executable))
    opener = subprocess.Popen(
        launch_command(
            app,
            stdout,
            stderr,
            private_home,
            data,
            cache,
            temp,
            profile,
            action,
            "https://example.com/",
            (
                f"ZB_DEBUG_WINDOW_SNAPSHOT_PNG={output}",
                "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS=55000",
                "ZB_DEBUG_QUIT_AFTER_MS=60000",
            ),
        ),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + timeout
    identity, reason = discover_app(opener, executable, before, deadline)
    auth_observed_ns: Optional[int] = None
    rows = LiveRows(False, False, [], [], [], [], [])
    try:
        sent_deadline = min(deadline, time.monotonic() + 10.0)
        while reason is None and identity is not None and time.monotonic() < sent_deadline:
            rows = parse_live_rows(read_lines(stdout), "fake-auth")
            if rows.sent:
                break
            if process_table().get(identity.pid) != identity:
                reason = "owned installed application exited before Send"
                break
            time.sleep(0.1)
        if reason is None and not rows.sent:
            reason = "version-2 real-control driver did not click Send"

        while reason is None and identity is not None and time.monotonic() < deadline:
            drawer_text = "\n".join(safe_drawer_lines(drawer_log, drawer_offset))
            if auth_observed_ns is None and AUTH_FAILURE in drawer_text:
                auth_observed_ns = time.time_ns()
            if auth_observed_ns is not None and png_size(output) is not None:
                break
            if process_table().get(identity.pid) != identity:
                reason = "owned installed application exited before authentication evidence"
                break
            time.sleep(0.2)
        if reason is None and auth_observed_ns is None:
            reason = "drawer did not show authentication_failed after Send"
        dimensions = png_size(output)
        if reason is None and dimensions is None:
            reason = "in-app cacheDisplayInRect PNG is missing or invalid"
        if reason is None and output.stat().st_mtime_ns < auth_observed_ns:
            reason = "in-app PNG was written before authentication_failed appeared"
        expected = (
            f"WINDOW_SNAPSHOT\t1\t{dimensions[0]}x{dimensions[1]}\t{output}"
            if dimensions is not None
            else ""
        )
        if reason is None and expected not in read_lines(stdout):
            reason = "WINDOW_SNAPSHOT product evidence row is missing"
        combined = "\n".join(
            read_lines(stdout)
            + read_lines(stderr)
            + safe_drawer_lines(drawer_log, drawer_offset)
        )
        if FAKE_TOKEN in combined:
            reason = "fake token leaked into app output or drawer diagnostics"
        if reason is None and "DRAWER_AGENT_E2E\tready-fd3" not in "\n".join(read_lines(stderr)):
            reason = "real fd-3 agent host did not report ready"
    finally:
        stop_error = stop_owned(identity, executable)
        opener_error = stop_opener(opener)
        for error in (stop_error, opener_error):
            if error is not None:
                reason = f"{reason}; {error}" if reason else error
    drawer_lines = safe_drawer_lines(drawer_log, drawer_offset)
    cleanup_safe = stop_error is None
    if reason is not None:
        err_tail = read_lines(stderr)[-1:] or ["<no stderr line>"]
        return False, f"{reason}; stderr={redact(err_tail[0])[:600]}", drawer_lines, cleanup_safe
    return (
        True,
        f"Send clicked; {AUTH_FAILURE}; png={png_size(output)} path={output}",
        drawer_lines,
        cleanup_safe,
    )


def selected_scenarios(raw: str) -> list[Scenario]:
    values: list[Scenario] = []
    for item in raw.split(","):
        item = item.strip()
        if not item.isdigit():
            raise ValueError(f"invalid scenario number {item!r}")
        number = int(item)
        match = next((scenario for scenario in SCENARIOS if scenario.number == number), None)
        if match is None or match in values:
            raise ValueError(f"invalid or duplicate scenario number {number}")
        values.append(match)
    return values


def token_precondition(token: Path) -> Optional[str]:
    try:
        metadata = os.stat(token, follow_symlinks=False)
    except OSError as error:
        return f"token file stat failed: {error.strerror}"
    if not stat.S_ISREG(metadata.st_mode):
        return "token path is not a regular file"
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        return f"token file mode is {stat.S_IMODE(metadata.st_mode):04o}, want 0600"
    if metadata.st_uid != os.getuid():
        return f"token file uid is {metadata.st_uid}, want {os.getuid()}"
    return None


def common_preflight(dmg: Path) -> list[str]:
    failures: list[str] = []
    running = zigbrowser_processes()
    if running:
        for process in running.values():
            failures.append(
                f"zigBrowser running pid={process.pid} command={redact(process.command)}"
            )
    else:
        print("PREFLIGHT\tmac-live-agent\tprocess-list\tno zigBrowser process", flush=True)
    if not dmg.is_file():
        failures.append(f"DMG is missing: {dmg}")
    return failures


def owner_preflight(dmg: Path, token: Path) -> bool:
    failures = common_preflight(dmg)
    token_error = token_precondition(token)
    if token_error is None:
        print(
            f"PREFLIGHT\tmac-live-agent\ttoken-stat\tregular mode=0600 uid={os.getuid()}",
            flush=True,
        )
    else:
        failures.append(token_error)
    for failure in failures:
        print(f"PRECONDITION\tmac-live-agent\t{failure}", flush=True)
    return not failures


def guarded_remove_live_root(root: Path, home: Path) -> None:
    resolved_root = root.resolve()
    resolved_home = home.resolve()
    name = resolved_root.name
    if (
        resolved_root.parent != resolved_home
        or not name.startswith("zb-live-")
        or len(name) <= len("zb-live-")
    ):
        raise RuntimeError(f"refused unguarded cleanup target: {resolved_root}")

    token_fifo = (
        resolved_root
        / "private-home/.local/share/zigbrowser/agent-home/scratchpad/token-fifo"
    )
    if token_fifo.is_dir() and not token_fifo.is_symlink():
        os.chmod(token_fifo, 0o700)
    shutil.rmtree(resolved_root)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--scenarios", default="1,2,3,4,5")
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--keep-going", action="store_true")
    parser.add_argument("--fake-auth-proof", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("PRECONDITION\tmac-live-agent\tmacOS is required", flush=True)
        return 2
    if args.timeout < 60 or args.timeout > 600:
        print("PRECONDITION\tmac-live-agent\t--timeout must be 60..600", flush=True)
        return 2
    if args.fake_auth_proof != (args.output is not None):
        print(
            "PRECONDITION\tmac-live-agent\t--fake-auth-proof and --output are required together",
            flush=True,
        )
        return 2
    try:
        scenarios = selected_scenarios(args.scenarios)
    except ValueError as error:
        print(f"PRECONDITION\tmac-live-agent\t{error}", flush=True)
        return 2

    owner_home = Path.home().resolve()
    owner_data = owner_home / ".local/share"
    token = owner_data / "zigbrowser/agent-home/secrets/claude_token"
    dmg = args.dmg.expanduser().resolve()
    if args.fake_auth_proof:
        failures = common_preflight(dmg)
        output = args.output.expanduser()
        if not output.is_absolute():
            failures.append("--output must be an absolute path")
        else:
            output = output.resolve()
            if not output.parent.is_dir():
                failures.append(f"output parent is missing: {output.parent}")
            if output.exists():
                failures.append(f"refusing to overwrite output: {output}")
        for failure in failures:
            print(f"PRECONDITION\tmac-live-agent\t{failure}", flush=True)
        if failures:
            return 2
    elif not owner_preflight(dmg, token):
        return 2

    root = Path(tempfile.mkdtemp(prefix="zb-live-", dir=owner_home))
    failed = False
    cleanup_safe = True
    try:
        app = install_dmg(dmg, root)
        print(f"PASS\tmac-live-agent\tinstall\t{app}", flush=True)
        if args.fake_auth_proof:
            private_home = root / "private-home"
            warmup = root / "fake-auth-runtime-warmup.png"
            warm_ok, warm_detail, warm_lines, warm_safe = run_fake_auth(
                app, root, private_home, warmup, args.timeout
            )
            cleanup_safe = cleanup_safe and warm_safe
            print(
                f"{'PASS' if warm_ok else 'FAIL'}\tmac-live-agent\t"
                f"fake-auth-runtime-warmup\t{warm_detail}",
                flush=True,
            )
            if warm_ok:
                ok, detail, drawer_lines, safe = run_fake_auth(
                    app, root, private_home, output, args.timeout
                )
                cleanup_safe = cleanup_safe and safe
            else:
                ok, detail, drawer_lines = False, warm_detail, warm_lines
            for line in drawer_lines:
                print(f"DRAWER_LOG\tmac-live-agent\tfake-auth\t{line}", flush=True)
            print(
                f"{'PASS' if ok else 'FAIL'}\tmac-live-agent\tfake-auth\t{detail}",
                flush=True,
            )
            failed = not ok
        else:
            for scenario in scenarios:
                if failed and not args.keep_going:
                    print(
                        f"FAIL\tmac-live-agent\t{scenario.name}\t"
                        "not run after earlier failure to conserve live account usage",
                        flush=True,
                    )
                    continue
                if zigbrowser_processes():
                    print(
                        f"PRECONDITION\tmac-live-agent\tzigBrowser appeared before {scenario.name}",
                        flush=True,
                    )
                    failed = True
                    cleanup_safe = False
                    break
                ok, detail, drawer_lines, png, safe = run_scenario(
                    app, root, owner_home, owner_data, scenario, args.timeout
                )
                cleanup_safe = cleanup_safe and safe
                for line in drawer_lines:
                    print(
                        f"DRAWER_LOG\tmac-live-agent\t{scenario.name}\t{line}",
                        flush=True,
                    )
                print(
                    f"{'PASS' if ok else 'FAIL'}\tmac-live-agent\t{scenario.name}\t"
                    f"{detail}\t{png}",
                    flush=True,
                )
                failed = failed or not ok
                if not safe:
                    break
    except Exception as error:  # fail closed with one bounded product-test row
        failed = True
        cleanup_safe = not bool(zigbrowser_processes())
        print(
            f"FAIL\tmac-live-agent\tsetup\t{type(error).__name__}: {redact(str(error))}",
            flush=True,
        )
    finally:
        if cleanup_safe:
            try:
                guarded_remove_live_root(root, owner_home)
                print(f"PASS\tmac-live-agent\tcleanup\tremoved {root}", flush=True)
            except Exception as error:
                failed = True
                print(f"FAIL\tmac-live-agent\tcleanup\t{redact(str(error))}", flush=True)
        else:
            failed = True
            print(
                f"FAIL\tmac-live-agent\tcleanup\tretained guarded root because an owned process remains: {root}",
                flush=True,
            )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
