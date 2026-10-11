#!/usr/bin/env python3
"""E2E harness hygiene: a browser started through the shared launcher
(slice2_common.detect_runner) never outlives its test.

A real driver script launches zigBrowser exactly the way the E2E tests do,
then dies mid-test or tears down with the shared helper. Afterwards no
process carrying the run's marker (browser, WebKit helpers, Xvfb) may
survive, and the private display leaves no X lock, socket or auth dir:

- xvfb/SIGKILL  the driver is killed outright (no Python cleanup runs)
- xvfb/SIGTERM  the driver is terminated (default handler, no cleanup)
- display/SIGKILL  no private Xvfb: the browser runs on a display this
                   test owns, and the driver is killed outright
- xvfb/stop     the driver tears down with slice2_common.stop_browser
- xvfb/child-left  the "browser" (a marked sh) exits by itself and leaves a
                   child in its process group while the driver lives on

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary, Xvfb
or xauth. Anything a failing case leaves behind is cleaned up by PID."""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

E2E_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(E2E_DIR))

from slice2_common import SKIP_EXIT, eprint, require_file  # noqa: E402

MARK = "ZB_HARNESS_MARK"

DRIVER = r'''
import os, sys, time, subprocess
sys.path.insert(0, sys.argv[1])
import slice2_common
mode, binary, page, profile = sys.argv[2:6]
prefix, env, _note = slice2_common.detect_runner(mode != "display")
env["ZB_HARNESS_MARK"] = os.environ["ZB_HARNESS_MARK"]
env.pop("ZIGBROWSER_SOCKET", None)
command = ["sh", "-c", "sleep 600 & sleep 1; exit 0"] if mode == "child-left" else [binary, page, "--profile-dir", profile]
proc = subprocess.Popen(prefix + command,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
print("launched", proc.pid, flush=True)
if mode == "stop":
    sys.stdin.readline()
    slice2_common.stop_browser(proc)
    print("stopped", flush=True)
elif mode == "child-left":
    proc.wait()
    print("exited", proc.returncode, flush=True)
    time.sleep(600)
else:
    time.sleep(600)
'''


def marked(mark: str) -> dict[int, str]:
    """pid -> name of every live process whose environment carries `mark`."""
    needle = f"{MARK}={mark}".encode()
    found: dict[int, str] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if needle not in (entry / "environ").read_bytes().split(b"\0"):
                continue
            stat = (entry / "stat").read_text()
        except OSError:
            continue
        if stat.rsplit(")", 1)[1].split()[0] == "Z":
            continue  # a zombie is gone; only its exit status is left
        found[int(entry.name)] = stat[stat.index("(") + 1 : stat.rindex(")")]
    return found


def cmdline(pid: int) -> list[str]:
    try:
        return [a.decode(errors="replace") for a in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if a]
    except OSError:
        return []


def xvfb_residue(xvfb_pid: int) -> list[Path]:
    """The lock, socket and auth dir a running Xvfb uses. Its display number
    comes from the X lock file that names its PID (with -displayfd the
    number is not on its command line)."""
    paths: list[Path] = []
    for lock in Path("/tmp").glob(".X*-lock"):
        number = lock.name[2:-5]
        try:
            owner = int(lock.read_text(encoding="ascii").strip())
        except (OSError, ValueError):
            continue
        if number.isdigit() and owner == xvfb_pid:
            paths += [lock, Path(f"/tmp/.X11-unix/X{number}")]
    args = cmdline(xvfb_pid)
    if "-auth" in args and args.index("-auth") + 1 < len(args):
        paths.append(Path(args[args.index("-auth") + 1]).parent)
    return paths


def kill_leftovers(pids: dict[int, str], residue: list[Path]) -> None:
    """Clean up after a failing case, by PID: Xvfb first with TERM (so it
    removes its own lock), then everything else with KILL."""
    for pid, name in pids.items():
        try:
            os.kill(pid, signal.SIGTERM if name == "Xvfb" else signal.SIGKILL)
        except OSError:
            pass
    time.sleep(1)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    tmp = Path(tempfile.gettempdir())
    for path in residue:
        if path.is_dir() and path.parent == tmp and path.name.startswith(("xvfb-run.", "zb-xsession-")):
            shutil.rmtree(path, ignore_errors=True)
        elif path.name.startswith(".X") and path.name.endswith("-lock"):
            # A lock (and its socket) left by a killed Xvfb whose owner is dead.
            try:
                owner = int(path.read_text(encoding="ascii").strip())
                os.kill(owner, 0)
            except ProcessLookupError:
                for stale in (path, Path(f"/tmp/.X11-unix/X{path.name[2:-5]}")):
                    try:
                        stale.unlink()
                    except OSError:
                        pass
            except (OSError, ValueError):
                pass


class PrivateDisplay:
    """An Xvfb owned by this test (for the no-private-Xvfb case)."""

    def __init__(self) -> None:
        read_fd, write_fd = os.pipe()
        self.proc = subprocess.Popen(
            ["Xvfb", "-displayfd", str(write_fd), "-nolisten", "tcp", "-screen", "0", "1280x1024x24"],
            pass_fds=(write_fd,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        os.close(write_fd)
        with os.fdopen(read_fd) as pipe:
            number = pipe.readline().strip()
        if not number.isdigit():
            self.close()
            raise RuntimeError("private Xvfb did not start")
        self.display = f":{number}"

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)


def run_case(name: str, mode: str, end: str, binary: Path, page: str, work: Path, display: str | None) -> list[str]:
    mark = uuid.uuid4().hex
    env = dict(os.environ)
    for var in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "ZIGBROWSER_SOCKET"):
        env.pop(var, None)
    if display is not None:
        env["DISPLAY"] = display
    env[MARK] = mark
    driver_path = work / "driver.py"
    driver_path.write_text(DRIVER, encoding="utf-8")
    driver = subprocess.Popen(
        [sys.executable, str(driver_path), str(E2E_DIR), mode, str(binary), page, str(work / f"profile-{mark}")],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        start_new_session=True,
    )
    failures: list[str] = []
    residue: list[Path] = []
    try:
        # Mid-test: the browser is up and has its WebKit helpers.
        deadline = time.monotonic() + 30
        seen: dict[int, str] = {}
        while time.monotonic() < deadline and driver.poll() is None:
            seen = marked(mark)
            up = "sleep" in seen.values() if mode == "child-left" else any(n.startswith("WebKitWeb") for n in seen.values())
            if up and (mode == "display" or "Xvfb" in seen.values()):
                break
            time.sleep(0.1)
        else:
            out, err = driver.communicate(timeout=5) if driver.poll() is not None else ("", "")
            return [f"{name}: browser never came up (seen {sorted(seen.values())}; driver rc={driver.poll()}; {err[-400:]!r})"]
        for pid, proc_name in seen.items():
            if proc_name == "Xvfb":
                residue += xvfb_residue(pid)
        time.sleep(0.5)

        if end == "stop":
            assert driver.stdin is not None and driver.stdout is not None
            driver.stdin.write("stop\n")
            driver.stdin.flush()
            driver.wait(timeout=30)
            if "stopped" not in driver.stdout.read():
                failures.append(f"{name}: stop_browser did not return")
        elif end != "none":
            os.kill(driver.pid, signal.SIGKILL if end == "kill" else signal.SIGTERM)
            driver.wait(timeout=10)

        def left_over() -> dict[int, str]:  # the driver, alive in child-left, does not count
            return {pid: n for pid, n in marked(mark).items() if pid != driver.pid}

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            left = left_over()
            stale = [p for p in residue if p.exists()]
            if not left and not stale:
                break
            time.sleep(0.1)
        left = left_over()
        stale = [p for p in residue if p.exists()]
        if left:
            failures.append(f"{name}: survived the driver: {sorted(left.values())}")
        if stale:
            failures.append(f"{name}: display residue left: {[str(p) for p in stale]}")
        if mode != "display" and not any(p.name.endswith("-lock") for p in residue):
            failures.append(f"{name}: no private Xvfb display (lock file) was seen")
        return failures
    finally:
        if driver.poll() is None:
            driver.kill()
            driver.wait(timeout=5)
        kill_leftovers(marked(mark), residue)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
    if not require_file(binary, "binary"):
        return SKIP_EXIT
    missing = [tool for tool in ("Xvfb", "xauth") if shutil.which(tool) is None]
    if missing:
        eprint(f"SKIP: needs {', '.join(missing)}")
        return SKIP_EXIT

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-harness-group-") as tmp:
        work = Path(tmp)
        page = work / "page.html"
        page.write_text("<!doctype html><title>harness</title><p>harness group</p>", encoding="utf-8")
        cases = [
            ("xvfb/SIGKILL", "xvfb", "kill"),
            ("xvfb/SIGTERM", "xvfb", "term"),
            ("xvfb/stop", "stop", "stop"),
            ("xvfb/child-left", "child-left", "none"),
        ]
        for name, mode, end in cases:
            got = run_case(name, mode, end, binary, page.as_uri(), work, None)
            print(f"{'FAIL' if got else 'PASS'}\t{name}", flush=True)
            failures += got
        own = PrivateDisplay()
        try:
            got = run_case("display/SIGKILL", "display", "kill", binary, page.as_uri(), work, own.display)
            print(f"{'FAIL' if got else 'PASS'}\tdisplay/SIGKILL", flush=True)
            failures += got
        finally:
            own.close()

    for failure in failures:
        eprint(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
