#!/usr/bin/env python3
"""Shared helpers for Slice 2 WebKitGTK app-shell E2E tests."""

from __future__ import annotations

import atexit
import os
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

SKIP_EXIT = 77
HARNESS_EXIT_PREFIX = "ZB_HARNESS_EXIT"


def eprint(msg: str) -> None:
    print(msg, file=os.sys.stderr)


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


def child_pids_linux(proc_pid: int) -> set[int]:
    children_file = Path(f"/proc/{proc_pid}/task/{proc_pid}/children")
    if children_file.exists():
        raw = children_file.read_text(encoding="utf-8").strip()
        if not raw:
            return set()
        return {int(item) for item in raw.split() if item.isdigit()}

    pgrep = shutil.which("pgrep")
    if pgrep is None:
        return set()
    result = subprocess.run([pgrep, "-P", str(proc_pid)], capture_output=True, text=True, check=False)
    if result.returncode not in (0, 1):
        return set()
    return {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}


def assert_children_exit(children: Iterable[int], timeout_sec: float) -> tuple[bool, list[int]]:
    deadline = time.monotonic() + timeout_sec
    children_set = set(children)
    while time.monotonic() < deadline:
        alive = [pid for pid in children_set if is_pid_alive(pid)]
        if not alive:
            return True, []
        time.sleep(0.05)
    alive = [pid for pid in children_set if is_pid_alive(pid)]
    return len(alive) == 0, alive


def isolate_profile_env(env: dict[str, str]) -> dict[str, str]:
    """Point XDG data/cache homes at a fresh temp root (removed at exit).

    zigBrowser defaults its persistent profile to $XDG_DATA_HOME/zigbrowser/
    profile, so without this every E2E launch would read and write the
    developer's real cookies and site data and share them across parallel
    tests."""
    root = tempfile.mkdtemp(prefix="zb-e2e-xdg-")
    atexit.register(shutil.rmtree, root, True)
    env["XDG_DATA_HOME"] = os.path.join(root, "data")
    env["XDG_CACHE_HOME"] = os.path.join(root, "cache")
    return env


def detect_runner(prefer_xvfb: bool) -> tuple[list[str], dict[str, str], str] | None:
    env = isolate_profile_env(dict(os.environ))
    xvfb = shutil.which("xvfb-run")
    display = env.get("DISPLAY")

    # Local default: live display first (xvfb-run is absent on this workstation).
    if not prefer_xvfb:
        if display:
            return [], env, f"DISPLAY={display}"
        if Path("/tmp/.X11-unix/X1").exists():
            env["DISPLAY"] = ":1"
            return [], env, "DISPLAY=:1"

    # CI / explicit xvfb preference.
    if xvfb:
        return [xvfb, "-a"], env, "xvfb-run"

    # Fallback to live display when xvfb is requested but unavailable.
    if display:
        return [], env, f"DISPLAY={display}"
    if Path("/tmp/.X11-unix/X1").exists():
        env["DISPLAY"] = ":1"
        return [], env, "DISPLAY=:1"

    eprint("SKIP: no DISPLAY and no xvfb-run; install xvfb or export DISPLAY")
    return None


def require_file(path: Path, label: str) -> bool:
    if path.exists():
        return True
    eprint(f"SKIP: missing {label}: {path}")
    return False


def protocol_rows(lines: list[str], prefix: str) -> list[list[str]]:
    tag = f"{prefix}\t"
    return [line.split("\t") for line in lines if line.startswith(tag)]


def harness_exit_code(lines: list[str]) -> int | None:
    for line in reversed(lines):
        row = line.split("\t")
        if len(row) != 2 or row[0] != HARNESS_EXIT_PREFIX:
            continue
        try:
            return int(row[1], 10)
        except ValueError:
            return None
    return None


@dataclass
class RunResult:
    returncode: int
    stdout_lines: list[str]
    stderr_lines: list[str]
    tracked_children: set[int]
    timed_out: bool = False
    pid: int | None = None


@dataclass
class ScheduledTaskProcess:
    pid: int | None
    returncode: int | None

    def poll(self) -> int | None:
        return self.returncode


def run_interactive_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], Any], bool],
    on_tick: Callable[[list[str], list[str], Any], None] | None = None,
) -> tuple[bool, RunResult]:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    assert proc.stdout is not None
    assert proc.stderr is not None

    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    out_thread = threading.Thread(target=_read_lines, args=(proc.stdout, stdout_lines), daemon=True)
    err_thread = threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True)
    out_thread.start()
    err_thread.start()

    tracked_children: set[int] = set()
    matched = False
    deadline = time.monotonic() + timeout_sec

    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        tracked_children.update(child_pids_linux(proc.pid))
        if on_tick is not None:
            on_tick(stdout_lines, stderr_lines, proc)
        if condition(stdout_lines, stderr_lines, proc):
            matched = True
            break
        time.sleep(0.05)

    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)

    out_thread.join(timeout=1)
    err_thread.join(timeout=1)

    result = RunResult(
        returncode=proc.returncode,
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=tracked_children,
    )
    return matched, result


def _ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _read_file_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except (FileNotFoundError, PermissionError, OSError):
        return []


def _read_int_file(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None
    try:
        return int(raw, 10)
    except ValueError:
        return None


def _write_windows_task_wrapper(
    script_path: Path,
    cmd: list[str],
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    exit_path: Path,
    pid_path: Path,
    cwd: Path,
) -> None:
    if not cmd:
        raise ValueError("scheduled task command must not be empty")

    env_lines = []
    for key, value in sorted(env.items()):
        if not (key.startswith("ZB_") or key.startswith("WEBVIEW2_") or key == "WINRT_INCLUDE"):
            continue
        if not key.replace("_", "").isalnum():
            continue
        env_lines.append(f"$env:{key} = {_ps_quote(value)}")

    file_path = str(cmd[0])
    arg_string = subprocess.list2cmdline([str(item) for item in cmd[1:]])
    script = "\r\n".join(
        [
            "$ErrorActionPreference = 'Stop'",
            f"$stdoutPath = {_ps_quote(str(stdout_path))}",
            f"$stderrPath = {_ps_quote(str(stderr_path))}",
            f"$exitPath = {_ps_quote(str(exit_path))}",
            f"$pidPath = {_ps_quote(str(pid_path))}",
            "try {",
            f"  Set-Location -LiteralPath {_ps_quote(str(cwd))}",
            *[f"  {line}" for line in env_lines],
            (
                f"  $p = Start-Process -FilePath {_ps_quote(file_path)} "
                f"-ArgumentList {_ps_quote(arg_string)} "
                "-RedirectStandardOutput $stdoutPath "
                "-RedirectStandardError $stderrPath "
                "-PassThru"
            ),
            "  $p.Id | Set-Content -LiteralPath $pidPath -Encoding ASCII",
            "  $p.WaitForExit()",
            "  $p.Refresh()",
            "  if ($null -eq $p.ExitCode) { $exitCode = 0 } else { $exitCode = [int]$p.ExitCode }",
            "  $exitCode | Set-Content -LiteralPath $exitPath -Encoding ASCII",
            f"  Add-Content -LiteralPath $stdoutPath -Encoding UTF8 -Value (\"{HARNESS_EXIT_PREFIX}`t{{0}}\" -f $exitCode)",
            "} catch {",
            "  $_ | Out-String | Add-Content -LiteralPath $stderrPath -Encoding UTF8",
            "  1 | Set-Content -LiteralPath $exitPath -Encoding ASCII",
            f"  Add-Content -LiteralPath $stdoutPath -Encoding UTF8 -Value \"{HARNESS_EXIT_PREFIX}`t1\"",
            "  throw",
            "}",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8", newline="\r\n")


def _cmd_script_quote(path: Path) -> str:
    return '"' + str(path).replace('"', '""') + '"'


def _cmd_set_line(key: str, value: str) -> str:
    return f'set "{key}={value.replace("%", "%%").replace(chr(34), chr(34) + chr(34))}"'


def _write_windows_cmd_wrapper(
    script_path: Path,
    cmd: list[str],
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    cwd: Path,
) -> None:
    if not cmd:
        raise ValueError("scheduled task command must not be empty")

    env_lines = []
    for key, value in sorted(env.items()):
        if not (key.startswith("ZB_") or key.startswith("WEBVIEW2_") or key == "WINRT_INCLUDE"):
            continue
        if not key.replace("_", "").isalnum():
            continue
        env_lines.append(_cmd_set_line(key, value))

    cmd_line = subprocess.list2cmdline([str(item) for item in cmd])
    exit_marker = f"{HARNESS_EXIT_PREFIX}\t%ZB_EXIT_CODE%"
    script = "\r\n".join(
        [
            "@echo off",
            "setlocal",
            f"cd /d {_cmd_script_quote(cwd)}",
            *env_lines,
            f"{cmd_line} > {_cmd_script_quote(stdout_path)} 2> {_cmd_script_quote(stderr_path)}",
            "set \"ZB_EXIT_CODE=%ERRORLEVEL%\"",
            f">> {_cmd_script_quote(stdout_path)} echo {exit_marker}",
            "exit /b %ZB_EXIT_CODE%",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8", newline="\r\n")


def _run_schtasks(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def _stop_windows_task(task_name: str, pid: int | None) -> None:
    if pid is not None:
        _run_schtasks(["taskkill", "/PID", str(pid), "/T", "/F"])
    _run_schtasks(["schtasks", "/end", "/tn", task_name])


def _delete_windows_task(task_name: str) -> None:
    _run_schtasks(["schtasks", "/delete", "/tn", task_name, "/f"])


def run_windows_interactive_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], ScheduledTaskProcess], bool],
    on_tick: Callable[[list[str], list[str], ScheduledTaskProcess], None] | None = None,
    cwd: Path | None = None,
) -> tuple[bool, RunResult]:
    if os.name != "nt":
        raise RuntimeError("interactive scheduled-task runner is Windows-only")

    task_name = f"zb_m8_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    work_dir = Path(tempfile.mkdtemp(prefix="zb_m8_task_"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    exit_path = work_dir / "exit.txt"
    pid_path = work_dir / "pid.txt"
    script_path = work_dir / "run.ps1"
    cwd_path = (cwd or Path.cwd()).resolve()
    _write_windows_task_wrapper(script_path, cmd, env, stdout_path, stderr_path, exit_path, pid_path, cwd_path)

    task_cmd = f'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{script_path}"'
    create = _run_schtasks(
        [
            "schtasks",
            "/create",
            "/tn",
            task_name,
            "/tr",
            task_cmd,
            "/sc",
            "once",
            "/st",
            "23:59",
            "/it",
            "/rl",
            "highest",
            "/f",
        ]
    )
    if create.returncode != 0:
        return False, RunResult(
            returncode=create.returncode,
            stdout_lines=create.stdout.splitlines(),
            stderr_lines=create.stderr.splitlines(),
            tracked_children=set(),
        )

    run = _run_schtasks(["schtasks", "/run", "/tn", task_name])
    if run.returncode != 0:
        _delete_windows_task(task_name)
        return False, RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )

    matched = False
    timed_out = False
    deadline = time.monotonic() + timeout_sec
    pid: int | None = None
    returncode: int | None = None
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    try:
        while time.monotonic() < deadline:
            stdout_lines = _read_file_lines(stdout_path)
            stderr_lines = _read_file_lines(stderr_path)
            pid = _read_int_file(pid_path) or pid
            returncode = _read_int_file(exit_path)
            proc = ScheduledTaskProcess(pid=pid, returncode=returncode)
            if on_tick is not None:
                on_tick(stdout_lines, stderr_lines, proc)
            if condition(stdout_lines, stderr_lines, proc):
                matched = True
                break
            if returncode is not None:
                break
            time.sleep(0.1)
        else:
            timed_out = True
    finally:
        if returncode is None:
            _stop_windows_task(task_name, pid)
            time.sleep(0.2)
            returncode = _read_int_file(exit_path)
        _delete_windows_task(task_name)

    stdout_lines = _read_file_lines(stdout_path)
    stderr_lines = _read_file_lines(stderr_path)
    pid = _read_int_file(pid_path) or pid
    result = RunResult(
        returncode=returncode if returncode is not None else (0 if matched else 1),
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=set(),
        timed_out=timed_out,
        pid=pid,
    )
    return matched, result


def run_windows_interactive_cmd_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], ScheduledTaskProcess], bool],
    cwd: Path | None = None,
) -> tuple[bool, RunResult]:
    if os.name != "nt":
        raise RuntimeError("interactive scheduled-task cmd runner is Windows-only")

    task_name = f"zb_m8_cmd_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    work_dir = Path(tempfile.mkdtemp(prefix="zb_m8_cmd_"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    script_path = work_dir / "run.cmd"
    cwd_path = (cwd or Path.cwd()).resolve()
    _write_windows_cmd_wrapper(script_path, cmd, env, stdout_path, stderr_path, cwd_path)

    task_cmd = f'cmd.exe /d /c call "{script_path}"'
    create = _run_schtasks(
        [
            "schtasks",
            "/create",
            "/tn",
            task_name,
            "/tr",
            task_cmd,
            "/sc",
            "once",
            "/st",
            "23:59",
            "/it",
            "/rl",
            "highest",
            "/f",
        ]
    )
    if create.returncode != 0:
        return False, RunResult(
            returncode=create.returncode,
            stdout_lines=create.stdout.splitlines(),
            stderr_lines=create.stderr.splitlines(),
            tracked_children=set(),
        )

    run = _run_schtasks(["schtasks", "/run", "/tn", task_name])
    if run.returncode != 0:
        _delete_windows_task(task_name)
        return False, RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )

    matched = False
    timed_out = False
    deadline = time.monotonic() + timeout_sec
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    try:
        while time.monotonic() < deadline:
            stdout_lines = _read_file_lines(stdout_path)
            stderr_lines = _read_file_lines(stderr_path)
            proc = ScheduledTaskProcess(pid=None, returncode=harness_exit_code(stdout_lines))
            if condition(stdout_lines, stderr_lines, proc):
                matched = True
                break
            if proc.returncode is not None:
                break
            time.sleep(0.1)
        else:
            timed_out = True
    finally:
        if not matched and harness_exit_code(stdout_lines) is None:
            _stop_windows_task(task_name, None)
            time.sleep(0.2)
        _delete_windows_task(task_name)

    stdout_lines = _read_file_lines(stdout_path)
    stderr_lines = _read_file_lines(stderr_path)
    returncode = harness_exit_code(stdout_lines)
    result = RunResult(
        returncode=returncode if returncode is not None else (0 if matched else 1),
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=set(),
        timed_out=timed_out,
    )
    return matched, result


def run_windows_interactive_to_exit(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    cwd: Path | None = None,
) -> RunResult:
    matched, result = run_windows_interactive_until(
        cmd,
        env,
        timeout_sec,
        lambda _stdout, _stderr, proc: proc.poll() is not None,
        cwd=cwd,
    )
    if not matched and result.returncode == 0:
        result.returncode = 1
    return result


def print_fail_context(label: str, result: RunResult) -> None:
    eprint(f"{label}: return={result.returncode} tracked_children={sorted(result.tracked_children)}")
    eprint("stdout:\n" + "\n".join(result.stdout_lines))
    eprint("stderr:\n" + "\n".join(result.stderr_lines))
