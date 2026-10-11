#!/usr/bin/env python3
"""A killed vitest run of the Node SDK's live test leaves nothing behind.

    node_live_group_test.py --binary zig-out/bin/zigBrowser

Starts `vitest run tests/live.test.ts` (sdk/node) with ZB_BINARY and a unique
marker in its environment, which every process it starts inherits (browser,
WebKit helpers, Xvfb). Once a marked zigBrowser is running, the whole vitest
run is killed with SIGKILL: the main process, then every worker (node) that
carries the marker, as `pkill -9 -f vitest`, an OOM kill or a CI job kill
would. The browser itself is not signalled. (Killing only the main process
is not enough: its worker then finishes the test and its own teardown.) Then,
within a bound, no marked browser process may remain (zigBrowser, its WebKit
helpers, the launcher's Xvfb and guardian), and no X display that a marked
Xvfb held may keep its lock or socket. vitest's own orphaned workers are
reported, not judged, and are cleaned up afterwards with everything else that
carries the marker.

This test provides a display of its own (an unmarked Xvfb, DISPLAY for vitest)
so that a live test which draws on the caller's DISPLAY also runs: the old
direct-spawn live test leaked its browser on it (RED). It never uses :0 or
:1, and it only signals processes that carry its marker, plus its own Xvfb.

Opt-in, like the live test itself: exit 77 (skip) without the binary, Node,
sdk/node/node_modules (npm ci), Xvfb or xauth."""

from __future__ import annotations

import argparse
import os
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
NODE_SDK = REPO / "sdk/node"
VITEST = NODE_SDK / "node_modules/.bin/vitest"
SKIP_EXIT = 77
START_SEC = 60.0
GONE_SEC = 30.0
# Display numbers for this test's own Xvfb: clear of xvfb-run -a (99 up) and
# the launcher's private range (200-399).
OWN_DISPLAYS = range(450, 500)


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def marked(marker: str) -> dict[int, str]:
    """pid -> command name of every live process whose environment has the marker."""
    needle = f"ZB_LIVE_MARKER={marker}".encode()
    found = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/environ", "rb") as env:
                if needle not in env.read().split(b"\0"):
                    continue
            with open(f"/proc/{entry}/stat", encoding="ascii", errors="replace") as stat:
                head, tail = stat.read().rsplit(")", 1)
            if tail.split()[0] == "Z":
                continue
            found[int(entry)] = head.split("(", 1)[1]
        except OSError:
            continue
    return found


# Processes of the browser and its launcher (command names as /proc/<pid>/stat
# shows them, cut to 15 characters); everything else marked is the runner's.
BROWSER_FAMILY = ("zigBrowser", "WebKit", "Xvfb", "python3", "xauth")


def browser_family(procs: dict[int, str]) -> dict[int, str]:
    return {pid: name for pid, name in procs.items() if name.startswith(BROWSER_FAMILY)}


def xvfb_display(pid: int) -> str | None:
    """The display number a running Xvfb was started on."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as cmd:
            for arg in cmd.read().split(b"\0"):
                if arg.startswith(b":") and arg[1:].isdigit():
                    return arg[1:].decode()
    except OSError:
        pass
    return None


def start_own_xvfb(tmp: Path) -> tuple[subprocess.Popen, str]:
    for number in OWN_DISPLAYS:
        if Path(f"/tmp/.X{number}-lock").exists() or Path(f"/tmp/.X11-unix/X{number}").exists():
            continue
        auth = tmp / "Xauthority"
        auth.touch()
        subprocess.run(["xauth", "-q", "-f", str(auth), "add", f":{number}", ".", secrets.token_hex(16)], check=True)
        proc = subprocess.Popen(["Xvfb", f":{number}", "-nolisten", "tcp", "-auth", str(auth)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and proc.poll() is None:
            if Path(f"/tmp/.X11-unix/X{number}").exists():
                os.environ["XAUTHORITY"] = str(auth)
                return proc, f":{number}"
            time.sleep(0.05)
        if proc.poll() is None:
            proc.kill()
        proc.wait()
    raise RuntimeError("no free display for the test's own Xvfb")


def kill_marked(marker: str) -> None:
    """Last-resort cleanup after a failure: only processes with our marker."""
    for pid in marked(marker):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    missing = [name for name, ok in (
        ("binary", binary.is_file()),
        ("node", shutil.which("node") is not None),
        ("sdk/node/node_modules (npm ci)", VITEST.exists()),
        ("Xvfb", shutil.which("Xvfb") is not None),
        ("xauth", shutil.which("xauth") is not None),
    ) if not ok]
    if missing:
        eprint(f"skip: missing {', '.join(missing)}")
        return SKIP_EXIT

    marker = secrets.token_hex(8)
    with tempfile.TemporaryDirectory(prefix="zb-node-live-group-") as tmp:
        own_xvfb, own_display = start_own_xvfb(Path(tmp))
        env = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET")}
        # ZB_LIVE_HOLD_MS keeps the browser up long enough to kill the run.
        env.update({"DISPLAY": own_display, "ZB_BINARY": str(binary), "ZB_LIVE_MARKER": marker, "ZB_LIVE_HOLD_MS": "20000"})
        vitest = subprocess.Popen([str(VITEST), "run", "tests/live.test.ts"], cwd=NODE_SDK, env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        displays: set[str] = set()
        try:
            deadline = time.monotonic() + START_SEC
            while time.monotonic() < deadline:
                procs = marked(marker)
                if any(name.startswith("zigBrowser") for name in procs.values()):
                    break
                if vitest.poll() is not None:
                    raise AssertionError(f"vitest ended (rc={vitest.returncode}) before a browser ran: is the live test skipped?")
                time.sleep(0.1)
            else:
                raise AssertionError("no marked zigBrowser started")
            time.sleep(1.0)  # past startup: the browser has its window and helpers
            before = marked(marker)
            displays = {d for pid, name in before.items() if name == "Xvfb" and (d := xvfb_display(pid))}
            eprint(f"before the kill: {sorted(set(before.values()))}, private displays {sorted(displays)}")

            os.kill(vitest.pid, signal.SIGKILL)  # the vitest main process, then its workers
            vitest.wait()
            for pid, name in marked(marker).items():
                if name.startswith("node"):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

            deadline = time.monotonic() + GONE_SEC
            left = browser_family(marked(marker))
            while left and time.monotonic() < deadline:
                time.sleep(0.2)
                left = browser_family(marked(marker))
            if left:
                raise AssertionError(f"left behind {GONE_SEC:.0f} s after the kill: {sorted(left.items())}")
            runner_left = marked(marker)
            if runner_left:
                eprint(f"vitest's own leftovers (not judged, cleaned up): {sorted(set(runner_left.values()))}")
            residue = [path for d in sorted(displays) for path in (f"/tmp/.X{d}-lock", f"/tmp/.X11-unix/X{d}") if Path(path).exists()]
            if residue:
                raise AssertionError(f"display files left behind: {residue}")
        except Exception as exc:  # noqa: BLE001
            print("FAIL\tnode-live-group")
            eprint(f"error={exc}")
            kill_marked(marker)
            try:
                os.killpg(vitest.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            return 1
        finally:
            kill_marked(marker)
            own_xvfb.terminate()
            try:
                own_xvfb.wait(timeout=5)
            except subprocess.TimeoutExpired:
                own_xvfb.kill()
                own_xvfb.wait()
    print("PASS\tnode-live-group")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
