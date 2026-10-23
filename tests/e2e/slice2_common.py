#!/usr/bin/env python3
"""Shared helpers for Slice 2 WebKitGTK app-shell E2E tests."""

from __future__ import annotations

import atexit
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

SKIP_EXIT = 77
HARNESS_EXIT_PREFIX = "ZB_HARNESS_EXIT"
WIN_GATE_ENV = "ZB_WIN_GATE"


def gate_skip_exit(reason: str) -> int:
    """Exit code for a missing precondition (Windows plan WS0.9, D.1): SKIP_EXIT when a human runs the test
    standalone; 1 under the gate (ZB_WIN_GATE=1), where a skip is a failure. Use as `return gate_skip_exit(...)`."""
    print(reason, file=sys.stderr)
    if os.environ.get(WIN_GATE_ENV) == "1":
        print(f"{WIN_GATE_ENV}=1: precondition missing; a skip is a failure under the gate", file=sys.stderr)
        return 1
    return SKIP_EXIT
# The one launcher for E2E browsers (see its docstring): the browser keeps
# its own PID, and a guardian ends it and its private Xvfb if the test dies.
XSESSION = Path(__file__).resolve().parent / "xsession.py"


def xsession_prefix(xvfb: bool, screen: str | None = None) -> list[str]:
    """Command prefix that runs a browser under xsession.py (--xvfb: on its
    own Xvfb display, never the caller's)."""
    prefix = [sys.executable, str(XSESSION)]
    if xvfb:
        prefix.append("--xvfb")
    if screen is not None:
        prefix += ["--screen", screen]
    return prefix + ["--"]


# An agent helper's processes (chat-drawer plan S5.5): the helper's launch
# (`python -m zb_agent_host ...`), netd (`.../zb_agent_host/netd.py`) and the relay.
AGENT_HELPER_MARKERS = ("zb_agent_host", "zb-net-relay")


def agent_helper_processes(root: int) -> list[list[str]]:
    """The argv of every live descendant of `root` that is an agent helper process."""
    kids: dict[int, list[int]] = {}
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            fields = Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue
        if fields[0] != "Z":
            kids.setdefault(int(fields[1]), []).append(int(entry))
    found, todo = [], [root]
    while todo:
        for child in kids.get(todo.pop(), []):
            todo.append(child)
            try:
                argv = [a.decode(errors="replace") for a in Path(f"/proc/{child}/cmdline").read_bytes().split(b"\0") if a]
            except OSError:
                continue
            if any(marker in arg for arg in argv for marker in AGENT_HELPER_MARKERS):
                found.append(argv[:4])
    return found


GUARDIAN_GONE_SEC = 30.0  # xsession's worst case: helper grace 8 s + group TERM/KILL 10 s + Xvfb TERM 5 s


def _xsession_guardian(pid: int) -> int | None:
    """The xsession.py guardian watching browser `pid`: the process whose argv names xsession.py and which holds a
    pidfd for `pid` (its fdinfo names the pid while `pid` is alive or not yet reaped). None without /proc (Windows,
    macOS) or when there is none. Only observed, never signalled."""
    if not os.path.isdir("/proc"):
        return None
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            if b"xsession.py" not in Path(f"/proc/{entry}/cmdline").read_bytes():
                continue
            for fd in os.listdir(f"/proc/{entry}/fd"):
                if os.readlink(f"/proc/{entry}/fd/{fd}") != "anon_inode:[pidfd]":
                    continue
                if ["Pid:", str(pid)] in (line.split() for line in
                                          Path(f"/proc/{entry}/fdinfo/{fd}").read_text().splitlines()):
                    return int(entry)
        except OSError:
            continue  # gone meanwhile, or not ours to read
    return None


def _running(pid: int) -> bool:
    """Running (a zombie awaiting its reaper counts as gone)."""
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def stop_browser(proc: subprocess.Popen, grace_sec: float = 8.0, agent_helpers_allowed: bool = False) -> int | None:
    """Shared teardown for a browser started with an xsession prefix: SIGINT
    (a clean shutdown); a browser still running after `grace_sec` gets
    SIGKILL with its whole process group (browser and WebKit helpers). After
    a clean exit the helpers are left to exit on their own (tests assert
    that); the guardian ends any that linger, then removes the private
    display, and once the browser has exited this waits (at most
    GUARDIAN_GONE_SEC) for that guardian to finish: a driver that exits next,
    ending its PID namespace, would otherwise SIGKILL the guardian and Xvfb
    mid-cleanup and leave /tmp/.X<n>-lock and the X socket behind
    (zigBrowser-44h). Safe to call more than once. Returns the browser's exit
    status.

    The drawer is on by default (S5.5), and nothing starts an agent helper
    until its Send: unless `agent_helpers_allowed` (the agent tests), a
    helper process found under the browser fails the test with an
    AssertionError, after the teardown."""
    guardian = _xsession_guardian(proc.pid) if proc.returncode is None else None  # before anything reaps it
    helpers = agent_helper_processes(proc.pid) if proc.poll() is None and not agent_helpers_allowed else []
    code = _stop(proc, grace_sec)
    if guardian is not None and code is not None:
        deadline = time.monotonic() + GUARDIAN_GONE_SEC
        while _running(guardian):
            if time.monotonic() >= deadline:
                raise AssertionError(f"the xsession guardian of browser {proc.pid} did not finish its display "
                                     f"cleanup within {GUARDIAN_GONE_SEC:.0f} s")
            time.sleep(0.02)
    if helpers:
        raise AssertionError(f"an agent helper ran in a test that never pressed Send: {helpers}")
    return code


def _stop(proc: subprocess.Popen, grace_sec: float) -> int | None:
    if proc.poll() is None:
        try:
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=grace_sec)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    return proc.returncode


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


def automation_auth(socket_path: Path) -> str | None:
    """The per-session token zigBrowser writes next to its socket
    (<socket>.token, mode 0600) when no --automation-token-file is given."""
    try:
        return (Path(str(socket_path) + ".token")).read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def detect_runner(prefer_xvfb: bool) -> tuple[list[str], dict[str, str], str] | None:
    """(command prefix, env, note) for launching the browser. Every prefix
    is an xsession.py one, so the browser never outlives the test."""
    env = isolate_profile_env(dict(os.environ))
    xvfb = shutil.which("Xvfb") is not None and shutil.which("xauth") is not None
    display = env.get("DISPLAY")

    # Local default: live display first.
    if not prefer_xvfb:
        if display:
            return xsession_prefix(False), env, f"DISPLAY={display}"
        if Path("/tmp/.X11-unix/X1").exists():
            env["DISPLAY"] = ":1"
            return xsession_prefix(False), env, "DISPLAY=:1"

    # CI / explicit xvfb preference: a private Xvfb owned by xsession.py.
    if xvfb:
        return xsession_prefix(True), env, "xvfb"

    # Fallback to live display when xvfb is requested but unavailable.
    if display:
        return xsession_prefix(False), env, f"DISPLAY={display}"
    if Path("/tmp/.X11-unix/X1").exists():
        env["DISPLAY"] = ":1"
        return xsession_prefix(False), env, "DISPLAY=:1"

    eprint("SKIP: no DISPLAY and no Xvfb/xauth; install xvfb or export DISPLAY")
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
            pass
    stop_browser(proc, grace_sec=0)

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

    # Start-Process resolves a bare FilePath against the process directory and PATH, never the Set-Location below
    # (a relative `zigBrowser.exe` was "not found" on the Win11 VM), so a program in the run's cwd goes in absolute.
    program = Path(cmd[0])
    if not program.is_absolute() and (cwd / program).is_file():
        program = cwd / program
    file_path = str(program)
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


# The task runs at least privilege (Windows plan WS0.4 item 4): a standard test user cannot request `/rl highest`
# ("ERROR: Access is denied." at /create on the Win11 VM, review c70c24e), and nothing here needs elevation.
TASK_RUN_LEVEL = "limited"


def _failed(what: str, proc: subprocess.CompletedProcess[str]) -> str:
    return f"runner: {what} failed (rc={proc.returncode}): {(proc.stderr or proc.stdout).strip()}"


def _stop_windows_task(task_name: str, pid: int | None) -> list[str]:
    """Ends the task's process tree and the task. Returns a diagnostic per failed step: either can fail for a
    process that already exited, so these are reported in the result, not judged here (WS0.4 item 5 does)."""
    steps = [] if pid is None else [("taskkill", ["taskkill", "/PID", str(pid), "/T", "/F"])]
    steps.append(("schtasks /end", ["schtasks", "/end", "/tn", task_name]))
    notes = []
    for what, args in steps:
        proc = _run_schtasks(args)
        if proc.returncode != 0:
            notes.append(_failed(what, proc))
    return notes


def _delete_windows_task(task_name: str) -> str | None:
    """Deletes the task. A task left behind fails the run (WS0.4 item 4): returns the failure, or None."""
    proc = _run_schtasks(["schtasks", "/delete", "/tn", task_name, "/f"])
    return None if proc.returncode == 0 else _failed(f"schtasks /delete /tn {task_name}", proc)


def _fail_on_cleanup(matched: bool, result: RunResult, notes: list[str], delete_error: str | None) -> bool:
    """Adds the cleanup diagnostics to the result; a failed delete makes the run fail. Returns `matched`."""
    result.stderr_lines.extend(notes)
    if delete_error is None:
        return matched
    result.stderr_lines.append(delete_error)
    if result.returncode == 0:
        result.returncode = 1
    return False


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
            TASK_RUN_LEVEL,
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
        result = RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )
        return _fail_on_cleanup(False, result, [], _delete_windows_task(task_name)), result

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
        stop_notes: list[str] = []
        if returncode is None:
            stop_notes = _stop_windows_task(task_name, pid)
            time.sleep(0.2)
            returncode = _read_int_file(exit_path)
        delete_error = _delete_windows_task(task_name)

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
    return _fail_on_cleanup(matched, result, stop_notes, delete_error), result


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
            TASK_RUN_LEVEL,
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
        result = RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )
        return _fail_on_cleanup(False, result, [], _delete_windows_task(task_name)), result

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
        stop_notes: list[str] = []
        if not matched and harness_exit_code(stdout_lines) is None:
            stop_notes = _stop_windows_task(task_name, None)
            time.sleep(0.2)
        delete_error = _delete_windows_task(task_name)

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
    return _fail_on_cleanup(matched, result, stop_notes, delete_error), result


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
