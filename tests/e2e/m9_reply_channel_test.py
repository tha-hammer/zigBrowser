#!/usr/bin/env python3
"""M9 HW-gated E2E: macOS WKWebView reply-channel contract."""

from __future__ import annotations

import argparse
import os
import platform
import shlex
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Callable

from slice2_common import (
    HARNESS_EXIT_PREFIX,
    SKIP_EXIT,
    RunResult,
    eprint,
    harness_exit_code,
    print_fail_context,
    protocol_rows,
    require_file,
)


REQUIRED_ENV = "ZB_ENABLE_M9_E2E"


class MacGuiProcess:
    def __init__(self, pid: int | None, returncode: int | None) -> None:
        self.pid = pid
        self.returncode = returncode

    def poll(self) -> int | None:
        return self.returncode


def hw_gate_ready() -> tuple[bool, str]:
    if platform.system() != "Darwin":
        return False, "SKIP: M9 is macOS-only"
    if os.environ.get(REQUIRED_ENV) != "1":
        return False, f"SKIP: set {REQUIRED_ENV}=1 to run M9 HW-gated E2E"
    return True, "ok"


def default_binary() -> str:
    return "zig-out/bin/zigBrowser"


def read_file_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except (FileNotFoundError, PermissionError, OSError):
        return []


def read_int_file(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None
    try:
        return int(raw, 10)
    except ValueError:
        return None


def console_uid() -> int:
    result = subprocess.run(["id", "-u"], capture_output=True, text=True, check=True)
    return int(result.stdout.strip(), 10)


def gui_runner_prefix() -> tuple[list[str], str]:
    uid = console_uid()
    mode = os.environ.get("ZB_M9_GUI_RUNNER", "console-user")
    if mode == "launchctl-asuser":
        return ["/bin/launchctl", "asuser", str(uid)], f"launchctl-asuser uid={uid}"
    return [], f"console-user uid={uid}"


def env_exports(env: dict[str, str]) -> list[str]:
    lines = []
    for key, value in sorted(env.items()):
        if not (key.startswith("ZB_") or key.startswith("WEBKIT_")):
            continue
        if not key.replace("_", "").isalnum():
            continue
        lines.append(f"export {key}={shlex.quote(value)}")
    return lines


def terminate_process(pid: int | None) -> None:
    if pid is None:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            return
        time.sleep(0.2)


def write_gui_runner_script(
    script_path: Path,
    cmd: list[str],
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    pid_path: Path,
    cwd: Path,
) -> None:
    command = " ".join(shlex.quote(str(item)) for item in cmd)
    script = "\n".join(
        [
            "#!/bin/sh",
            "set -u",
            f"cd {shlex.quote(str(cwd))}",
            *env_exports(env),
            f": > {shlex.quote(str(stdout_path))}",
            f": > {shlex.quote(str(stderr_path))}",
            f"{command} >> {shlex.quote(str(stdout_path))} 2>> {shlex.quote(str(stderr_path))} &",
            "pid=$!",
            f"printf '%s\\n' \"$pid\" > {shlex.quote(str(pid_path))}",
            "wait \"$pid\"",
            "rc=$?",
            f"printf '{HARNESS_EXIT_PREFIX}\\t%s\\n' \"$rc\" >> {shlex.quote(str(stdout_path))}",
            "exit \"$rc\"",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8")
    script_path.chmod(0o755)


def run_macos_gui_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], MacGuiProcess], bool],
    cwd: Path | None = None,
) -> tuple[bool, RunResult]:
    if platform.system() != "Darwin":
        raise RuntimeError("macOS GUI runner is Darwin-only")

    work_dir = Path(tempfile.mkdtemp(prefix="zigBrowser-m9-gui-"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    pid_path = work_dir / "pid.txt"
    script_path = work_dir / "run.sh"
    write_gui_runner_script(script_path, cmd, env, stdout_path, stderr_path, pid_path, (cwd or Path.cwd()).resolve())

    prefix, _runner_note = gui_runner_prefix()
    proc = subprocess.Popen(
        prefix + ["/bin/sh", str(script_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    matched = False
    timed_out = False
    deadline = time.monotonic() + timeout_sec
    pid: int | None = None
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    try:
        while time.monotonic() < deadline:
            stdout_lines = read_file_lines(stdout_path)
            stderr_lines = read_file_lines(stderr_path)
            pid = read_int_file(pid_path) or pid
            harness_code = harness_exit_code(stdout_lines)
            gui_proc = MacGuiProcess(pid=pid, returncode=harness_code)
            if condition(stdout_lines, stderr_lines, gui_proc):
                matched = True
                break
            if harness_code is not None or proc.poll() is not None:
                break
            time.sleep(0.1)
        else:
            timed_out = True
    finally:
        if harness_exit_code(stdout_lines) is None:
            terminate_process(pid)
        try:
            launch_stdout, launch_stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            launch_stdout, launch_stderr = proc.communicate(timeout=5)

    stdout_lines = read_file_lines(stdout_path)
    stderr_lines = read_file_lines(stderr_path)
    if launch_stderr:
        stderr_lines.extend(launch_stderr.splitlines())
    returncode = harness_exit_code(stdout_lines)
    if returncode is None and proc.returncode not in (None, 0):
        returncode = proc.returncode
    result = RunResult(
        returncode=returncode if returncode is not None else (0 if matched else 1),
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=set(),
        timed_out=timed_out,
        pid=pid,
    )
    if launch_stdout:
        result.stdout_lines.extend(launch_stdout.splitlines())
    return matched, result


def write_reply_fixture(path: Path) -> None:
    path.write_text(
        """<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>M9 Reply Fixture</title>
    <script src="zbhost.js"></script>
  </head>
  <body>
    <h1>M9 Reply Fixture</h1>
    <script>
      window.addEventListener("load", function () {
        window.setTimeout(function () {
          window.zbHost("ping", {}).catch(function () {});
          window.zbHost("echo", {}).catch(function () {});
        }, 30);
      });
    </script>
  </body>
</html>
""",
        encoding="utf-8",
    )


def prepare_reply_fixture(source_dir: Path) -> Path:
    work_dir = Path(tempfile.mkdtemp(prefix="zigBrowser-m9-reply-fixture-"))
    fixture = work_dir / "m9-reply.html"
    write_reply_fixture(fixture)
    zbhost = source_dir / "zbhost.js"
    if zbhost.exists():
        (work_dir / "zbhost.js").write_text(zbhost.read_text(encoding="utf-8"), encoding="utf-8")
    return fixture


def run_case(
    binary: Path,
    env: dict[str, str],
    uri: str,
    timeout_sec: float,
    ok_condition,
    label: str,
) -> tuple[bool, int]:
    cmd = [str(binary), uri, "--e2e-protocol"]
    matched, result = run_macos_gui_until(cmd, env, timeout_sec, ok_condition)
    if matched:
        return True, 0

    print(f"FAIL\t{label}")
    print_fail_context(label, result)
    return False, 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--fixture-dir", default="tests/fixtures/app")
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        eprint(reason)
        return SKIP_EXIT

    browser = Path(args.binary or default_binary())
    fixture_dir = Path(args.fixture_dir)
    if not require_file(browser, "binary") or not require_file(fixture_dir / "zbhost.js", "zbhost fixture"):
        return SKIP_EXIT

    env = dict(os.environ)
    _prefix, runner_note = gui_runner_prefix()
    eprint(f"runner={runner_note}")
    fixture = prepare_reply_fixture(fixture_dir)
    uri = fixture.resolve().as_uri()

    def reply_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipc_rows = protocol_rows(stdout_lines, "IPC")
        ipcerr_rows = protocol_rows(stdout_lines, "IPCERR")
        saw_ping = any(len(row) >= 3 and row[1] == "ping" and row[2] == '"pong"' for row in ipc_rows)
        saw_badargs = any(len(row) >= 3 and row[1] == "echo" and row[2] == "BadArgs" for row in ipcerr_rows)
        return saw_ping and saw_badargs

    ok, code = run_case(browser, env, uri, args.timeout_sec, reply_condition, "m9-reply-contract-not-observed")
    if not ok:
        return code

    print("PASS\tm9-reply-channel-contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
