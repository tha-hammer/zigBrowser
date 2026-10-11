#!/usr/bin/env python3
"""A killed node_live_group_test.py leaves no display of its own behind.

    node_live_group_kill_test.py --binary zig-out/bin/zigBrowser

node_live_group_test.py runs its vitest under a display of its own (an
outer Xvfb it starts itself). This starts that regression with a unique
marker in its environment, waits until its outer Xvfb is up (the Xvfb child
of the regression, with its X lock and socket), then SIGKILLs the regression
process itself, as an outer `timeout -s KILL`, an OOM kill or a CI job kill
would; the Xvfb is never signalled. Within a bound the outer Xvfb must be
gone, and its lock and socket with it.

Afterwards everything that carries the marker (the orphaned vitest run, the
browser under its launcher) gets time to end on its own; what is left is
reported and cleaned up: last-resort SIGKILL, then the X lock and socket of
a killed Xvfb, only when the lock names that Xvfb. It never uses :0 or :1
and only signals processes that carry its marker.

Opt-in, like node_live_group_test.py: exit 77 (skip) when that test would
skip (no binary, Node, sdk/node/node_modules, Xvfb or xauth)."""

from __future__ import annotations

import argparse
import os
import secrets
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
GROUP_TEST = HERE / "node_live_group_test.py"
SKIP_EXIT = 77
START_SEC = 60.0
GONE_SEC = 10.0
SETTLE_SEC = 60.0
MARKER_VAR = "ZB_GROUP_KILL_MARKER"


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def stat_of(pid: int) -> tuple[str, str, int] | None:
    """(command name, state, ppid) of a live process, else None."""
    try:
        with open(f"/proc/{pid}/stat", encoding="ascii", errors="replace") as stat:
            head, tail = stat.read().rsplit(")", 1)
    except OSError:
        return None
    fields = tail.split()
    return head.split("(", 1)[1], fields[0], int(fields[1])


def alive(pid: int) -> bool:
    info = stat_of(pid)
    return info is not None and info[1] != "Z"


def marked(marker: str) -> dict[int, str]:
    """pid -> command name of every live process whose environment has the marker."""
    needle = f"{MARKER_VAR}={marker}".encode()
    found = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as env:
                if needle not in env.read().split(b"\0"):
                    continue
        except OSError:
            continue
        info = stat_of(int(entry))
        if info is not None and info[1] != "Z":
            found[int(entry)] = info[0]
    return found


def xvfb_display(pid: int) -> str | None:
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as cmd:
            for arg in cmd.read().split(b"\0"):
                if arg.startswith(b":") and arg[1:].isdigit():
                    return arg[1:].decode()
    except OSError:
        pass
    return None


def display_files(display: str) -> list[str]:
    return [p for p in (f"/tmp/.X{display}-lock", f"/tmp/.X11-unix/X{display}") if Path(p).exists()]


def lock_owner(display: str) -> int | None:
    try:
        return int(Path(f"/tmp/.X{display}-lock").read_text().strip())
    except (OSError, ValueError):
        return None


def clean_up(marker: str) -> list[str]:
    """Lets every marked process end on its own (guardians clean their
    displays), then SIGKILLs what is left and removes the lock and socket of
    each killed Xvfb whose lock names it. Returns what had to be killed."""
    deadline = time.monotonic() + SETTLE_SEC
    while marked(marker) and time.monotonic() < deadline:
        time.sleep(0.2)
    left = marked(marker)
    displays = {pid: d for pid, name in left.items() if name == "Xvfb" and (d := xvfb_display(pid))}
    for pid in left:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for pid, display in displays.items():
        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        if not alive(pid) and lock_owner(display) == pid:
            for path in display_files(display):
                Path(path).unlink(missing_ok=True)
    return sorted(set(left.values()))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    args = parser.parse_args()

    marker = secrets.token_hex(8)
    env = dict(os.environ, **{MARKER_VAR: marker})
    test = subprocess.Popen([sys.executable, str(GROUP_TEST), "--binary", args.binary], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    outer: tuple[int, str] | None = None
    try:
        deadline = time.monotonic() + START_SEC
        while time.monotonic() < deadline and test.poll() is None:
            for pid, name in marked(marker).items():
                info = stat_of(pid)
                display = xvfb_display(pid) if name == "Xvfb" else None
                if info is not None and info[2] == test.pid and display and len(display_files(display)) == 2:
                    outer = (pid, display)
            if outer:
                break
            time.sleep(0.05)
        if outer is None:
            if test.poll() == SKIP_EXIT:
                eprint(f"skip: {test.stderr.read().strip()}")
                return SKIP_EXIT
            raise AssertionError(f"the regression's outer Xvfb never came up (rc={test.poll()})")
        xvfb_pid, display = outer
        eprint(f"outer Xvfb pid {xvfb_pid} on :{display}; SIGKILL the regression (pid {test.pid})")

        os.kill(test.pid, signal.SIGKILL)
        test.wait()
        deadline = time.monotonic() + GONE_SEC
        while (alive(xvfb_pid) or display_files(display)) and time.monotonic() < deadline:
            time.sleep(0.05)
        left = (["Xvfb"] if alive(xvfb_pid) else []) + display_files(display)
        if left:
            raise AssertionError(f"{GONE_SEC:.0f} s after the regression was killed, its outer display :{display} is left: {left}")
    except Exception as exc:  # noqa: BLE001
        print("FAIL\tnode-live-group-kill")
        eprint(f"error={exc}")
        if test.poll() is None:
            test.kill()
            test.wait()
        killed = clean_up(marker)
        if killed:
            eprint(f"cleaned up after the failure: {killed}")
        return 1
    killed = clean_up(marker)
    if killed:
        eprint(f"left after the run (not judged, cleaned up): {killed}")
    print("PASS\tnode-live-group-kill")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
