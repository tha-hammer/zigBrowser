#!/usr/bin/python3
"""Live Intel-Mac product e2e for the real Claude drawer agent.

This test never reads a credential.  The installed application receives the
real login HOME and consumes its existing product Keychain item through the
normal fd-3 launch path.  Browser state is isolated in a private XDG data home
and one private WebKit profile per scenario.

The test drives visible product actions through a 0600 e2e action file.  That
file contains prompts and approval policy, never a token.  The product emits
``LIVE_AGENT`` rows only with ``--e2e-protocol`` and takes each PNG with
``cacheDisplayInRect:toBitmapImageRep:``.  Screen Recording is never used.

Action manifest, version 1::

  {"version":1,"scenario":"window-info","prompt":"...",
   "approve":"all","snapshot_png":"/absolute/private/path.png"}

Product rows::

  LIVE_AGENT <scenario> sent -
  LIVE_AGENT <scenario> tool <base64(JSON {tool,ok,body})>
  LIVE_AGENT <scenario> approval <base64(JSON {verb,outcome})>
  LIVE_AGENT <scenario> assistant <base64(UTF-8 text)>
  LIVE_AGENT <scenario> snapshot <base64(absolute path)>
  LIVE_AGENT <scenario> complete -

Run on the Intel Mac with an owner-approved installed DMG::

  python3 -B tests/e2e/mac_live_agent_test.py --dmg zigBrowser_0.2.0_macos.dmg

Use ``--scenarios 1,2,5`` while the click/type/press tools are still landing.
The default is fail-fast so one product regression does not spend more of the
owner's Claude allowance.  ``--keep-going`` is for a reviewed full pass.
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
        "What page is this window on?",
        frozenset({"window_info"}),
        False,
        ("example.com", "example domain"),
        ("example.com", "example domain"),
    ),
    Scenario(
        2,
        "navigate-heading",
        "about:blank",
        "Go to https://example.com and tell me the heading",
        frozenset({"navigate", "get_text"}),
        True,
        ("example domain",),
        ("example domain",),
    ),
    Scenario(
        3,
        "google-search",
        "https://www.google.com/",
        "Search Google for zigbrowser and tell me the first result's title",
        frozenset({"navigate", "get_text"}),
        False,
        ("zigbrowser",),
        ("zigbrowser",),
    ),
    Scenario(
        4,
        "form-submit",
        "about:blank",
        "Open https://httpbin.org/forms/post, fill the customer name with Test User and submit",
        frozenset({"navigate", "type_text", "click", "get_text"}),
        True,
        ("test user",),
        ("test user",),
    ),
    Scenario(
        5,
        "click-more",
        "https://example.com/",
        "Click the 'More information...' link on example.com",
        frozenset({"click"}),
        True,
        ("iana.org",),
        ("iana", "more information"),
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


def executable_pids(executable: Path) -> dict[int, str]:
    done = subprocess.run(
        ["/bin/ps", "-axo", "pid=,command="],
        capture_output=True,
        text=True,
        check=True,
    )
    exact = str(executable)
    prefix = exact + " "
    found: dict[int, str] = {}
    for raw in done.stdout.splitlines():
        fields = raw.strip().split(None, 1)
        if len(fields) != 2:
            continue
        if fields[1] == exact or fields[1].startswith(prefix):
            found[int(fields[0])] = fields[1]
    return found


def stop_owned(pid: Optional[int], executable: Path) -> Optional[str]:
    if pid is None:
        return None
    current = executable_pids(executable)
    if pid not in current:
        return None
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if pid not in executable_pids(executable):
            return None
        time.sleep(0.1)
    return f"owned application pid {pid} ignored SIGTERM; it was not killed"


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


def safe_drawer_line(path: Path, start_size: int) -> str:
    try:
        with path.open("rb") as stream:
            stream.seek(min(start_size, path.stat().st_size))
            new = stream.read()
    except OSError:
        return "<no drawer.log line>"
    raw_lines = new.splitlines()
    if not raw_lines:
        return "<no drawer.log line>"
    line = raw_lines[-1].decode("utf-8", errors="replace")
    line = TOKEN_SHAPE.sub("[REDACTED]", line)
    return line.replace("\t", " | ").replace("\r", " ").replace("\n", " ")[:1200]


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
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 10_000 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    if width < 600 or height < 400:
        return None
    return width, height


def tool_name(value: dict[str, Any]) -> str:
    name = value.get("tool")
    if not isinstance(name, str):
        return ""
    return name.rsplit("__", 1)[-1]


def all_text(rows: LiveRows) -> str:
    pieces = list(rows.assistants)
    for tool in rows.tools:
        body = tool.get("body")
        if isinstance(body, str):
            pieces.append(body)
    return "\n".join(pieces).lower()


def validate_scenario(scenario: Scenario, rows: LiveRows, png: Path) -> Optional[str]:
    if rows.malformed:
        return f"malformed live row: {rows.malformed[0]!r}"
    if not rows.sent:
        return "the action file did not produce the sent row"
    if not rows.complete:
        return "the action file did not produce the complete row"
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
        return f"no approved visible card; observed {rows.approvals!r}"
    if len(rows.assistants) != 1 or not rows.assistants[0].strip():
        return f"found {len(rows.assistants)} final assistant rows, want one nonempty row"
    combined = all_text(rows)
    if not all(term in combined for term in scenario.result_terms):
        return f"page/tool evidence lacks {scenario.result_terms!r}"
    assistant = rows.assistants[0].lower()
    if not any(term in assistant for term in scenario.assistant_terms):
        return f"assistant answer lacks one of {scenario.assistant_terms!r}"
    if rows.snapshots != [str(png)]:
        return f"snapshot rows are {rows.snapshots!r}, want exactly {str(png)!r}"
    dimensions = png_size(png)
    if dimensions is None:
        return f"in-app PNG is missing or invalid: {png}"
    return None


def run_scenario(
    app: Path,
    root: Path,
    real_home: Path,
    xdg_data: Path,
    xdg_cache: Path,
    scenario: Scenario,
    timeout: float,
) -> tuple[bool, str, Path]:
    executable = app / "Contents/MacOS/zigBrowser"
    scenario_root = root / f"scenario-{scenario.number}-{scenario.name}"
    profile = scenario_root / "profile"
    temp = scenario_root / "tmp"
    for directory in (scenario_root, profile, temp):
        directory.mkdir(mode=0o700)
    stdout = scenario_root / "browser.stdout"
    stderr = scenario_root / "browser.stderr"
    action = scenario_root / "live-action.json"
    png = scenario_root / "drawer.png"
    private_write(stdout, b"")
    private_write(stderr, b"")
    private_write(
        action,
        json.dumps(
            {
                "version": 1,
                "scenario": scenario.name,
                "prompt": scenario.prompt,
                "approve": "all",
                "snapshot_png": str(png),
            },
            separators=(",", ":"),
        ).encode("utf-8"),
    )
    drawer_log = xdg_data / "zigbrowser/agent-home/state/drawer.log"
    try:
        drawer_offset = drawer_log.stat().st_size
    except OSError:
        drawer_offset = 0

    before = executable_pids(executable)
    opener = subprocess.Popen(
        [
            "/usr/bin/open",
            "-n",
            "-W",
            "-o",
            str(stdout),
            "--stderr",
            str(stderr),
            "--env",
            f"HOME={real_home}",
            "--env",
            f"TMPDIR={temp}",
            "--env",
            f"XDG_DATA_HOME={xdg_data}",
            "--env",
            f"XDG_CACHE_HOME={xdg_cache}",
            "--env",
            f"{ACTION_ENV}={action}",
            str(app),
            "--args",
            scenario.start_url,
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
    pid = None
    reason = None
    rows = LiveRows(False, False, [], [], [], [], [])
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            created = sorted(set(executable_pids(executable)) - set(before))
            if len(created) == 1:
                pid = created[0]
                break
            if len(created) > 1:
                reason = f"launch created {len(created)} matching app processes, want one"
                break
            if opener.poll() is not None:
                reason = f"open exited {opener.returncode} before the installed app appeared"
                break
            time.sleep(0.1)

        while reason is None and pid is not None and time.monotonic() < deadline:
            lines = read_lines(stdout)
            rows = parse_live_rows(lines, scenario.name)
            if rows.complete and rows.snapshots:
                break
            if pid not in executable_pids(executable):
                reason = "owned installed application exited before completion"
                break
            time.sleep(0.2)

        if reason is None:
            reason = validate_scenario(scenario, rows, png)
        if reason is None and time.monotonic() >= deadline:
            reason = f"scenario exceeded {timeout:.0f}s"
    finally:
        stop_error = stop_owned(pid, executable)
        if stop_error is not None:
            reason = f"{reason}; {stop_error}" if reason else stop_error
        try:
            opener.wait(timeout=5)
        except subprocess.TimeoutExpired:
            reason = f"{reason}; open -W did not finish" if reason else "open -W did not finish"

    detail = safe_drawer_line(drawer_log, drawer_offset)
    if reason is not None:
        err_tail = read_lines(stderr)[-1:] or ["<no stderr line>"]
        return False, f"{reason}; drawer.log={detail}; stderr={err_tail[0][:600]}", png
    dimensions = png_size(png)
    return True, f"tools={len(rows.tools)} approvals={len(rows.approvals)} png={dimensions}", png


def selected_scenarios(raw: str) -> list[Scenario]:
    values = []
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--scenarios", default="1,2,3,4,5")
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--keep-going", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL\tmac-live-agent\tprecondition\tmacOS is required", flush=True)
        return 1
    if args.timeout < 15 or args.timeout > 600:
        print("FAIL\tmac-live-agent\tprecondition\t--timeout must be 15..600", flush=True)
        return 1
    try:
        scenarios = selected_scenarios(args.scenarios)
    except ValueError as error:
        print(f"FAIL\tmac-live-agent\tprecondition\t{error}", flush=True)
        return 1
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        print(f"FAIL\tmac-live-agent\tprecondition\tDMG is missing: {dmg}", flush=True)
        return 1

    real_home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-live-agent-", dir=real_home))
    xdg_data, xdg_cache = root / "data", root / "cache"
    xdg_data.mkdir(mode=0o700)
    xdg_cache.mkdir(mode=0o700)
    failed = False
    retained = False
    try:
        app = install_dmg(dmg, root)
        print(f"PASS\tmac-live-agent\tinstall\t{app}", flush=True)
        for index, scenario in enumerate(scenarios):
            if failed and not args.keep_going:
                print(
                    f"FAIL\tmac-live-agent\t{scenario.name}\tnot run after earlier failure to conserve live account usage",
                    flush=True,
                )
                continue
            ok, detail, png = run_scenario(
                app, root, real_home, xdg_data, xdg_cache, scenario, args.timeout
            )
            if ok:
                print(f"PASS\tmac-live-agent\t{scenario.name}\t{detail}\t{png}", flush=True)
            else:
                failed = True
                retained = True
                print(f"FAIL\tmac-live-agent\t{scenario.name}\t{detail}", flush=True)
        if retained:
            print(f"EVIDENCE\tmac-live-agent\t{root}", flush=True)
        return 1 if failed else 0
    except Exception as error:  # fail closed with one bounded product-test row
        retained = True
        print(f"FAIL\tmac-live-agent\tsetup\t{type(error).__name__}: {error}", flush=True)
        print(f"EVIDENCE\tmac-live-agent\t{root}", flush=True)
        return 1
    finally:
        if not retained and not failed:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
