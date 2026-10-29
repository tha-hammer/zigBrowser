#!/usr/bin/python3
"""Live Intel-Mac product e2e for the installed Claude drawer agent.

The test drives the installed application exactly through visible AppKit
controls. System Events types each prompt into the focused drawer input,
presses Send, and presses each visible Approve button. There is no prompt
manifest, automatic approval hook, fake Claude executable, or fake model.

The owner credential stays at
``~/.local/share/zigbrowser/agent-home/secrets/claude_token``. This test only
stats that path; it never opens, copies, hashes, or prints the file. The app
receives the owner's real HOME and reads the credential through its product
path. Browser data uses a private ``--profile-dir`` below ``~/zb-live-<id>``.

Scenarios 2 and 4 enable only the existing in-app observation hook which calls
``cacheDisplayInRect:toBitmapImageRep:``. Its 55-second delay lets the test
prove the PNG was written after the visible assistant answer. Screen capture
APIs are never used.

Run on the Intel Mac after the owner has provisioned the token file::

  python3 -B tests/e2e/mac_live_agent_test.py \
    --dmg "$HOME/Downloads/zigBrowser_0.2.0_macos.dmg" --keep-going

The default is fail-fast to conserve live-account usage. Use
``--scenarios 1,2,5`` for a reviewed subset.
"""

from __future__ import annotations

import argparse
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
from typing import Optional


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
TOKEN_SHAPE = re.compile(r"sk-ant-[A-Za-z0-9_-]+")
SECRET_ASSIGNMENT = re.compile(
    r"(?i)((?:anthropic_api_key|claude_code_oauth_token|authorization|token)"
    r"\s*[:=]\s*)([^\s,;]+)"
)
RECORD_SEPARATOR = "\x1e"
UNIT_SEPARATOR = "\x1f"


@dataclass(frozen=True)
class Scenario:
    number: int
    name: str
    start_url: str
    prompt: str
    assistant_terms: tuple[str, ...]
    approval_terms: tuple[str, ...] = ()
    snapshot: bool = False


SCENARIOS = (
    Scenario(
        1,
        "window-info",
        "https://example.com/",
        "Use window_info to report the current window URL and title. Do not use another tool.",
        ("example.com", "example domain"),
    ),
    Scenario(
        2,
        "navigate-heading",
        "about:blank",
        "Use the browser tools to open https://example.com and report the page heading exactly.",
        ("example domain",),
        snapshot=True,
    ),
    Scenario(
        3,
        "google-search",
        "https://www.google.com/",
        "On the current Google page, use type_text to enter exactly \"zigbrowser test\" "
        "in the search box, then use press_key with Enter. Report the first result title. "
        "Do not navigate directly to a search URL.",
        ("zigbrowser",),
        ("type_text", "press_key"),
    ),
    Scenario(
        4,
        "form-submit",
        "https://httpbin.org/forms/post",
        "On this httpbin form, use type_text to fill Customer name with Zig Browser Owner, "
        "Telephone with 212-555-0142, and E-mail address with owner-live@zigbrowser.test. "
        "Pick Medium as the Pizza Size, submit the form, then report the echoed values for "
        "custname, custtel, custemail, and size.",
        ("zig browser owner", "212-555-0142", "owner-live@zigbrowser.test", "medium"),
        ("type_text", "click"),
        True,
    ),
    Scenario(
        5,
        "click-more",
        "https://example.com/",
        "On example.com, use click on the \"More information...\" link, then report the new URL.",
        ("iana.org",),
        ("click",),
    ),
)


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    pgid: int
    start: str
    command: str


@dataclass(frozen=True)
class UiItem:
    role: str
    value: str


@dataclass
class ScenarioResult:
    ok: bool
    detail: str
    drawer_lines: list[str]
    assistant: str
    png: Optional[Path]
    cleanup_safe: bool


class PreconditionError(RuntimeError):
    """A condition failed before the next product launch."""


READ_UI_SCRIPT = r'''
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set matches to every process whose unix id is targetPid
    if (count of matches) is not 1 then error "target process is unavailable"
    tell item 1 of matches
      if (count of windows) is 0 then error "target process has no window"
      set output to ""
      repeat with candidate in entire contents of front window
        try
          set candidateRole to role of candidate as text
          if candidateRole is "AXTextArea" or candidateRole is "AXStaticText" then
            set candidateValue to value of candidate as text
            set output to output & candidateRole & (ASCII character 31) & candidateValue & (ASCII character 30)
          end if
        end try
      end repeat
      return output
    end tell
  end tell
end run
'''


SEND_PROMPT_SCRIPT = r'''
on run argv
  set targetPid to item 1 of argv as integer
  set promptText to item 2 of argv
  tell application "System Events"
    set matches to every process whose unix id is targetPid
    if (count of matches) is not 1 then error "target process is unavailable"
    tell item 1 of matches
      set frontmost to true
      delay 0.2
      set promptField to value of attribute "AXFocusedUIElement"
      if (role of promptField as text) is not "AXTextArea" then
        error "focused drawer control is not a text area"
      end if
      if (value of promptField as text) is not "" then
        error "focused drawer input was not empty"
      end if
      keystroke promptText
      delay 0.2
      if (value of promptField as text) is not promptText then
        error "typed prompt did not reach the drawer input"
      end if
      repeat with candidate in entire contents of front window
        try
          if (role of candidate as text) is "AXButton" and (name of candidate as text) is "Send" and enabled of candidate then
            perform action "AXPress" of candidate
            return "SENT"
          end if
        end try
      end repeat
      error "enabled Send button was not found"
    end tell
  end tell
end run
'''


APPROVE_ONE_SCRIPT = r'''
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    set matches to every process whose unix id is targetPid
    if (count of matches) is not 1 then error "target process is unavailable"
    tell item 1 of matches
      if (count of windows) is 0 then return ""
      set summaries to {}
      repeat with candidate in entire contents of front window
        try
          if (role of candidate as text) is "AXStaticText" then
            set candidateValue to value of candidate as text
            if candidateValue starts with "Claude wants to " then set end of summaries to candidateValue
          end if
        end try
      end repeat
      set summaryText to ""
      repeat with summary in summaries
        if summaryText is not "" then set summaryText to summaryText & (ASCII character 31)
        set summaryText to summaryText & summary
      end repeat
      repeat with candidate in entire contents of front window
        try
          if (role of candidate as text) is "AXButton" and (name of candidate as text) is "Approve" and enabled of candidate then
            perform action "AXPress" of candidate
            return "CLICKED" & (ASCII character 30) & summaryText
          end if
        end try
      end repeat
      return ""
    end tell
  end tell
end run
'''


ACCESSIBILITY_PREFLIGHT_SCRIPT = r'''
tell application "System Events" to get unix id of every process
'''


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
        start = " ".join(fields[3:8])
        found[pid] = ProcessIdentity(pid, ppid, pgid, start, fields[8])
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
    if identity is None:
        return None
    current = executable_processes(executable)
    if current.get(identity.pid) != identity:
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
        current_identity = process_table().get(identity.pid)
        if current_identity != identity:
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


def run_osascript(script: str, *arguments: str, timeout: float = 10.0) -> str:
    done = subprocess.run(
        ["/usr/bin/osascript", "-", *arguments],
        input=script,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    if done.returncode != 0:
        detail = redact(done.stderr.strip() or done.stdout.strip() or "osascript failed")
        raise RuntimeError(detail[:600])
    return done.stdout.rstrip("\r\n")


def read_ui(pid: int) -> list[UiItem]:
    raw = run_osascript(READ_UI_SCRIPT, str(pid), timeout=15.0)
    items: list[UiItem] = []
    for record in raw.split(RECORD_SEPARATOR):
        if not record or UNIT_SEPARATOR not in record:
            continue
        role, value = record.split(UNIT_SEPARATOR, 1)
        items.append(UiItem(role, value))
    return items


def ui_values(items: list[UiItem], role: str) -> list[str]:
    return [item.value.strip() for item in items if item.role == role and item.value.strip()]


def wait_for_ready(pid: int, deadline: float) -> list[UiItem]:
    last_error = "drawer did not expose its status"
    failed_statuses = {"No token", "Permission needed", "Stopped", "Unavailable", "Setup failed"}
    while time.monotonic() < deadline:
        try:
            items = read_ui(pid)
        except RuntimeError as error:
            last_error = str(error)
            time.sleep(0.25)
            continue
        labels = set(ui_values(items, "AXStaticText"))
        if "Ready" in labels:
            return items
        failed = sorted(labels & failed_statuses)
        if failed:
            raise RuntimeError(f"drawer status is {failed[0]}")
        time.sleep(0.25)
    raise RuntimeError(f"drawer was not Ready: {last_error}")


def send_prompt(pid: int, prompt: str) -> None:
    result = run_osascript(SEND_PROMPT_SCRIPT, str(pid), prompt, timeout=20.0)
    if result != "SENT":
        raise RuntimeError(f"drawer send returned {result!r}")


def approve_one(pid: int) -> tuple[bool, list[str]]:
    result = run_osascript(APPROVE_ONE_SCRIPT, str(pid), timeout=15.0)
    if not result:
        return False, []
    marker = "CLICKED" + RECORD_SEPARATOR
    if not result.startswith(marker):
        raise RuntimeError(f"approval click returned {result!r}")
    summaries = [part.strip() for part in result[len(marker) :].split(UNIT_SEPARATOR)]
    return True, [part for part in summaries if part]


def assistant_text(items: list[UiItem], baseline: set[str], prompt: str) -> str:
    candidates = [
        value
        for value in ui_values(items, "AXTextArea")
        if value != prompt and value not in baseline
    ]
    return candidates[-1] if candidates else ""


def wait_for_answer(
    pid: int, baseline: set[str], prompt: str, deadline: float
) -> tuple[str, list[str], int]:
    approvals: list[str] = []
    last_answer = ""
    stable = 0
    while time.monotonic() < deadline:
        clicked, summaries = approve_one(pid)
        if clicked:
            approvals.extend(summaries or ["<visible approval card>"])
        items = read_ui(pid)
        labels = set(ui_values(items, "AXStaticText"))
        answer = assistant_text(items, baseline, prompt)
        if answer and answer == last_answer and "Ready" in labels:
            stable += 1
        elif answer:
            last_answer = answer
            stable = 0
        else:
            stable = 0
        if stable >= 3:
            return answer, approvals, time.time_ns()
        if "Stopped" in labels and not answer:
            raise RuntimeError("agent stopped before producing an answer")
        time.sleep(0.35)
    raise RuntimeError("timed out waiting for a stable visible assistant answer")


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


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


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


def validate_answer(scenario: Scenario, answer: str, approvals: list[str]) -> Optional[str]:
    lowered = answer.lower()
    failure_phrases = ("couldn't", "could not", "unable", "failed", "can't", "cannot")
    reported_failure = next((phrase for phrase in failure_phrases if phrase in lowered), None)
    if reported_failure is not None:
        return f"visible assistant answer reports failure ({reported_failure!r})"
    missing = [term for term in scenario.assistant_terms if term not in lowered]
    if missing:
        return f"visible assistant answer lacks {missing!r}"
    approval_text = "\n".join(approvals).lower()
    missing_approvals = [term for term in scenario.approval_terms if term not in approval_text]
    if missing_approvals:
        return (
            f"visible approval cards lack {missing_approvals!r}; "
            f"observed {[redact(item) for item in approvals]!r}"
        )
    return None


def wait_for_snapshot(
    png: Path, stdout: Path, completed_ns: int, deadline: float
) -> tuple[Optional[str], Optional[tuple[int, int]]]:
    while time.monotonic() < deadline and not png.is_file():
        time.sleep(0.2)
    dimensions = png_size(png)
    if dimensions is None:
        return f"in-app cacheDisplayInRect PNG is missing or invalid: {png}", None
    if png.stat().st_mtime_ns < completed_ns:
        return "in-app PNG was written before the visible assistant answer completed", None
    expected = f"WINDOW_SNAPSHOT\t1\t{dimensions[0]}x{dimensions[1]}\t{png}"
    if expected not in read_lines(stdout):
        return "WINDOW_SNAPSHOT product evidence row is missing", None
    return None, dimensions


def run_scenario(
    app: Path,
    root: Path,
    owner_home: Path,
    owner_data: Path,
    scenario: Scenario,
    timeout: float,
) -> ScenarioResult:
    executable = app / "Contents/MacOS/zigBrowser"
    existing = zigbrowser_processes()
    if existing:
        rows = ", ".join(f"pid={pid} {redact(item.command)}" for pid, item in existing.items())
        raise PreconditionError(f"zigBrowser appeared before scenario launch: {rows}")

    scenario_root = root / f"scenario-{scenario.number}-{scenario.name}"
    profile = scenario_root / "profile"
    temp = scenario_root / "tmp"
    cache = scenario_root / "cache"
    for directory in (scenario_root, profile, temp, cache):
        directory.mkdir(mode=0o700)
    stdout = scenario_root / "browser.stdout"
    stderr = scenario_root / "browser.stderr"
    png = scenario_root / "window.png"
    private_write(stdout, b"")
    private_write(stderr, b"")
    drawer_log = owner_data / "zigbrowser/agent-home/state/drawer.log"
    try:
        drawer_offset = drawer_log.stat().st_size
    except OSError:
        drawer_offset = 0

    command = [
        "/usr/bin/open",
        "-n",
        "-W",
        "-o",
        str(stdout),
        "--stderr",
        str(stderr),
        "--env",
        f"HOME={owner_home}",
        "--env",
        f"XDG_DATA_HOME={owner_data}",
        "--env",
        f"XDG_CACHE_HOME={cache}",
        "--env",
        f"TMPDIR={temp}",
    ]
    if scenario.snapshot:
        command.extend(
            [
                "--env",
                f"ZB_DEBUG_WINDOW_SNAPSHOT_PNG={png}",
                "--env",
                "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS=55000",
            ]
        )
    command.extend(
        [
            str(app),
            "--args",
            scenario.start_url,
            "--agent-drawer",
            "on",
            "--profile-dir",
            str(profile),
        ]
    )
    if scenario.snapshot:
        command.append("--e2e-protocol")

    before = executable_processes(executable)
    opener = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    identity: Optional[ProcessIdentity] = None
    reason: Optional[str] = None
    answer = ""
    approvals: list[str] = []
    dimensions: Optional[tuple[int, int]] = None
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            now = executable_processes(executable)
            created = sorted(set(now) - set(before))
            if len(created) == 1:
                identity = now[created[0]]
                break
            if len(created) > 1:
                reason = f"launch created {len(created)} matching app processes, want one"
                break
            if opener.poll() is not None:
                reason = f"open exited {opener.returncode} before the installed app appeared"
                break
            time.sleep(0.1)

        if reason is None and identity is None:
            reason = "installed app did not appear before timeout"
        if reason is None and identity is not None:
            initial_items = wait_for_ready(identity.pid, deadline)
            baseline = set(ui_values(initial_items, "AXTextArea"))
            send_prompt(identity.pid, scenario.prompt)
            answer, approvals, completed_ns = wait_for_answer(
                identity.pid, baseline, scenario.prompt, deadline
            )
            reason = validate_answer(scenario, answer, approvals)
            if reason is None and scenario.snapshot:
                reason, dimensions = wait_for_snapshot(png, stdout, completed_ns, deadline)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        reason = redact(str(error))
    finally:
        stop_error = stop_owned(identity, executable)
        if stop_error is not None:
            reason = f"{reason}; {stop_error}" if reason else stop_error
        try:
            opener.wait(timeout=5)
        except subprocess.TimeoutExpired:
            reason = f"{reason}; open -W did not finish" if reason else "open -W did not finish"
            opener.terminate()
            try:
                opener.wait(timeout=2)
            except subprocess.TimeoutExpired:
                opener.kill()
                opener.wait(timeout=2)

    drawer_lines = safe_drawer_lines(drawer_log, drawer_offset)
    if reason is not None:
        err_tail = read_lines(stderr)[-1:] or ["<no stderr line>"]
        detail = f"{reason}; stderr={redact(err_tail[0])[:600]}"
        return ScenarioResult(
            False,
            detail,
            drawer_lines,
            redact(answer),
            png if scenario.snapshot else None,
            stop_error is None,
        )
    snapshot_detail = f" png={dimensions}" if dimensions is not None else ""
    detail = f"approvals={len(approvals)}{snapshot_detail}"
    return ScenarioResult(
        True,
        detail,
        drawer_lines,
        redact(answer),
        png if scenario.snapshot else None,
        stop_error is None,
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


def preflight(dmg: Path, owner_home: Path, token: Path) -> bool:
    failures: list[str] = []
    token_error = token_precondition(token)
    if token_error is None:
        print(f"PREFLIGHT\tmac-live-agent\ttoken-stat\tregular mode=0600 uid={os.getuid()}", flush=True)
    else:
        failures.append(token_error)

    running = zigbrowser_processes()
    if running:
        for process in running.values():
            failures.append(f"zigBrowser running pid={process.pid} command={redact(process.command)}")
    else:
        print("PREFLIGHT\tmac-live-agent\tprocess-list\tno zigBrowser process", flush=True)

    if not dmg.is_file():
        failures.append(f"DMG is missing: {dmg}")
    if owner_home != Path.home().resolve():
        failures.append("resolved owner HOME changed during preflight")

    if not failures:
        try:
            run_osascript(ACCESSIBILITY_PREFLIGHT_SCRIPT, timeout=10.0)
            print("PREFLIGHT\tmac-live-agent\taccessibility\tSystem Events available", flush=True)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            failures.append(f"System Events accessibility unavailable: {redact(str(error))}")

    for failure in failures:
        print(f"PRECONDITION\tmac-live-agent\t{failure}", flush=True)
    return not failures


def guarded_remove_live_root(root: Path, owner_home: Path) -> None:
    resolved_root = root.resolve()
    resolved_home = owner_home.resolve()
    name = resolved_root.name
    if (
        resolved_root.parent != resolved_home
        or not name.startswith("zb-live-")
        or len(name) <= len("zb-live-")
    ):
        raise RuntimeError(f"refused unguarded cleanup target: {resolved_root}")
    shutil.rmtree(resolved_root)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--scenarios", default="1,2,3,4,5")
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--keep-going", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("PRECONDITION\tmac-live-agent\tmacOS is required", flush=True)
        return 2
    if args.timeout < 60 or args.timeout > 600:
        print("PRECONDITION\tmac-live-agent\t--timeout must be 60..600", flush=True)
        return 2
    try:
        scenarios = selected_scenarios(args.scenarios)
    except ValueError as error:
        print(f"PRECONDITION\tmac-live-agent\t{error}", flush=True)
        return 2

    owner_home = Path.home().resolve()
    owner_data = owner_home / ".local/share"
    agent_home = owner_data / "zigbrowser/agent-home"
    token = agent_home / "secrets/claude_token"
    dmg = args.dmg.expanduser().resolve()
    if not preflight(dmg, owner_home, token):
        return 2

    root = Path(tempfile.mkdtemp(prefix="zb-live-", dir=owner_home))
    failed = False
    cleanup_allowed = True
    try:
        app = install_dmg(dmg, root)
        print(f"PASS\tmac-live-agent\tinstall\t{app}", flush=True)
        for scenario in scenarios:
            if failed and not args.keep_going:
                print(
                    f"FAIL\tmac-live-agent\t{scenario.name}\tnot run after earlier failure to conserve live account usage",
                    flush=True,
                )
                continue
            try:
                result = run_scenario(
                    app, root, owner_home, owner_data, scenario, args.timeout
                )
            except PreconditionError as error:
                failed = True
                cleanup_allowed = not bool(zigbrowser_processes())
                print(f"PRECONDITION\tmac-live-agent\t{redact(str(error))}", flush=True)
                break
            for line in result.drawer_lines:
                print(f"DRAWER_LOG\tmac-live-agent\t{scenario.name}\t{line}", flush=True)
            if result.assistant:
                print(
                    f"ASSISTANT\tmac-live-agent\t{scenario.name}\t{result.assistant[:1200]}",
                    flush=True,
                )
            if result.ok:
                png_detail = f"\t{result.png}" if result.png is not None else ""
                print(
                    f"PASS\tmac-live-agent\t{scenario.name}\t{result.detail}{png_detail}",
                    flush=True,
                )
            else:
                failed = True
                print(f"FAIL\tmac-live-agent\t{scenario.name}\t{result.detail}", flush=True)
            if not result.cleanup_safe:
                cleanup_allowed = False
                break
    except Exception as error:  # fail closed with one bounded product-test row
        failed = True
        cleanup_allowed = not bool(zigbrowser_processes())
        print(
            f"FAIL\tmac-live-agent\tsetup\t{type(error).__name__}: {redact(str(error))}",
            flush=True,
        )
    finally:
        if cleanup_allowed:
            try:
                guarded_remove_live_root(root, owner_home)
                print(f"PASS\tmac-live-agent\tcleanup\tremoved {root}", flush=True)
            except Exception as error:
                failed = True
                print(f"FAIL\tmac-live-agent\tcleanup\t{redact(str(error))}", flush=True)
        else:
            failed = True
            print(
                f"FAIL\tmac-live-agent\tcleanup\tretained guarded root because a zigBrowser process remains: {root}",
                flush=True,
            )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
