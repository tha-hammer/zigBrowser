#!/usr/bin/env python3
"""Shared helpers for Slice 2 WebKitGTK app-shell E2E tests."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

SKIP_EXIT = 77


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


def detect_runner(prefer_xvfb: bool) -> tuple[list[str], dict[str, str], str] | None:
    env = dict(os.environ)
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


@dataclass
class RunResult:
    returncode: int
    stdout_lines: list[str]
    stderr_lines: list[str]
    tracked_children: set[int]


def run_interactive_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], subprocess.Popen[str]], bool],
    on_tick: Callable[[list[str], list[str], subprocess.Popen[str]], None] | None = None,
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


def print_fail_context(label: str, result: RunResult) -> None:
    eprint(f"{label}: return={result.returncode} tracked_children={sorted(result.tracked_children)}")
    eprint("stdout:\n" + "\n".join(result.stdout_lines))
    eprint("stderr:\n" + "\n".join(result.stderr_lines))
