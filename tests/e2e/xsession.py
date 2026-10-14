#!/usr/bin/env python3
"""Run one E2E browser so that nothing it starts outlives its test.

    xsession.py [--xvfb] [--screen WxHxD] [--display-file PATH] -- command [args...]

The command replaces this process (exec), so the caller's Popen handle is
the browser itself: its PID, signals and exit status are the browser's. It
leads a new session, so its process group holds the browser and its WebKit
helpers (slice2_common.stop_browser signals that group).

Before the exec, a detached guardian is started. It owns the private Xvfb
(--xvfb: its own display, X lock and auth cookie) and watches two
processes: the caller that launched this script (the test driver) and the
browser. When the browser exits, the guardian stops Xvfb and removes the
display's files. When the driver dies first, however it died (SIGKILL
included), the guardian ends the browser's process group (TERM, then KILL)
and then does the same cleanup. When the browser exits first, whatever is
left in its group gets HELPER_GRACE_SEC to exit on its own (tests assert
that WebKit helpers do), then the guardian ends it the same way. Without
--xvfb the browser uses the caller's DISPLAY; the group handling is the
same.

--display-file PATH: before the exec, the browser's DISPLAY and XAUTHORITY
are written to PATH (a new 0600 file; it must not exist), so the test
driver can send real X input to that private display (tests/e2e/xinput.py).

Exit status 1 with a message on stderr when the display cannot be set up."""

from __future__ import annotations

import ctypes
import os
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

XVFB_START_SEC = 20.0
GROUP_TERM_SEC = 5.0
HELPER_GRACE_SEC = 8.0
XVFB_TERM_SEC = 5.0
PR_SET_PDEATHSIG = 1


def die_with_parent() -> None:
    """In a child: the kernel sends SIGTERM when the guardian exits."""
    ctypes.CDLL(None, use_errno=True).prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0)


def pidfd(pid: int) -> int | None:
    try:
        return os.pidfd_open(pid)
    except ProcessLookupError:
        return None


def group_members(pgid: int) -> list[int]:
    """Live (non-zombie) processes in process group `pgid`."""
    members = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", encoding="ascii", errors="replace") as stat:
                fields = stat.read().rsplit(")", 1)[1].split()
        except OSError:
            continue
        if fields[0] != "Z" and int(fields[2]) == pgid:
            members.append(int(entry))
    return members


def group_gone(pgid: int, wait_sec: float) -> bool:
    deadline = time.monotonic() + wait_sec
    while group_members(pgid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def end_group(pgid: int) -> None:
    """TERM the browser's process group, then KILL what is left of it."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if not group_members(pgid):
            return
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        if group_gone(pgid, GROUP_TERM_SEC):
            return


def lock_owner(number: int) -> int | None:
    """PID recorded in display :number's X lock file, if any."""
    try:
        with open(f"/tmp/.X{number}-lock", encoding="ascii") as lock:
            return int(lock.read().strip())
    except (OSError, ValueError):
        return None


class Display:
    """A private Xvfb on a free display number of its own range (never :0
    or :1; xvfb-run -a starts at 99), with the usual X lock and a fresh
    cookie."""

    FIRST, LAST = 200, 399

    def __init__(self, screen: str) -> None:
        self.dir = tempfile.mkdtemp(prefix="zb-xsession-")
        self.auth = os.path.join(self.dir, "Xauthority")
        self.number: str | None = None
        self.proc: subprocess.Popen | None = None
        for number in range(self.FIRST, self.LAST + 1):
            if os.path.exists(f"/tmp/.X{number}-lock") or os.path.exists(f"/tmp/.X11-unix/X{number}"):
                continue
            self._xauth("add", f":{number}", ".", secrets.token_hex(16))
            if self._start(number, screen):
                self.number = str(number)
                return
            self._xauth("remove", f":{number}")
        self.close()
        raise RuntimeError("Xvfb did not start on any free display")

    def _start(self, number: int, screen: str) -> bool:
        """Xvfb on :number. Ready once the X lock names it and its socket
        exists; False when it exits first (the number was taken meanwhile).
        (No -displayfd: with it this Xvfb takes no X lock at all.)"""
        proc = subprocess.Popen(
            ["Xvfb", f":{number}", "-nolisten", "tcp", "-screen", "0", screen, "-auth", self.auth],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=die_with_parent,
        )
        deadline = time.monotonic() + XVFB_START_SEC
        while time.monotonic() < deadline and proc.poll() is None:
            if lock_owner(number) == proc.pid and os.path.exists(f"/tmp/.X11-unix/X{number}"):
                self.proc = proc
                return True
            time.sleep(0.02)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=XVFB_TERM_SEC)
            except subprocess.TimeoutExpired:
                proc.kill()
        proc.wait()
        return False

    def _xauth(self, *args: str) -> None:
        subprocess.run(["xauth", "-q", "-f", self.auth, *args], check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def close(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()  # Xvfb removes its own lock and socket
            try:
                self.proc.wait(timeout=XVFB_TERM_SEC)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.number is not None and self.proc is not None:
            if lock_owner(int(self.number)) == self.proc.pid:  # left by a killed Xvfb of ours
                for path in (f"/tmp/.X{self.number}-lock", f"/tmp/.X11-unix/X{self.number}"):
                    try:
                        os.unlink(path)
                    except OSError:
                        pass
        shutil.rmtree(self.dir, ignore_errors=True)


def guard(report_fd: int, driver: int, browser: int, xvfb: bool, screen: str) -> None:
    """The detached guardian (never returns)."""
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    driver_fd, browser_fd = pidfd(driver), pidfd(browser)
    display = None
    try:
        if xvfb:
            display = Display(screen)
            message = f"DISPLAY=:{display.number}\nXAUTHORITY={display.auth}\n"
        else:
            message = "OK\n"
    except Exception as exc:  # noqa: BLE001 - reported to the launcher
        message = f"ERR {exc}\n"
    os.write(report_fd, message.encode())
    os.close(report_fd)
    if message.startswith("ERR"):
        os._exit(1)

    watched = [fd for fd in (driver_fd, browser_fd) if fd is not None]
    if len(watched) == 2:
        poller = select.poll()
        for fd in watched:
            poller.register(fd, select.POLLIN)
        ready = {fd for fd, _ in poller.poll()}
        if browser_fd in ready:  # the browser exited: its helpers get a grace period
            group_gone(browser, HELPER_GRACE_SEC)
    end_group(browser)  # the driver died, or helpers outlived the grace period
    if display is not None:
        display.close()
    os._exit(0)


def main(argv: list[str]) -> int:
    xvfb = False
    screen = "1280x1024x24"
    display_file: str | None = None
    args = list(argv)
    while args and args[0] != "--":
        flag = args.pop(0)
        if flag == "--xvfb":
            xvfb = True
        elif flag == "--screen" and args:
            screen = args.pop(0)
        elif flag == "--display-file" and args:
            display_file = args.pop(0)
        else:
            print(f"xsession: unknown option {flag}", file=sys.stderr)
            return 2
    if not args or args[0] != "--" or len(args) < 2:
        print("usage: xsession.py [--xvfb] [--screen WxHxD] [--display-file PATH] -- command [args...]", file=sys.stderr)
        return 2
    command = args[1:]

    driver = os.getppid()
    if os.getpgid(0) != os.getpid():
        os.setsid()
    browser = os.getpid()

    read_fd, write_fd = os.pipe()
    first = os.fork()
    if first == 0:
        os.close(read_fd)
        os.setsid()  # out of the browser's group: its teardown never hits the guardian
        if os.fork() != 0:
            os._exit(0)
        try:
            guard(write_fd, driver, browser, xvfb, screen)
        finally:
            os._exit(1)
    os.close(write_fd)
    os.waitpid(first, 0)
    report = b""
    while chunk := os.read(read_fd, 4096):
        report += chunk
    os.close(read_fd)
    text = report.decode(errors="replace")
    if not text or text.startswith("ERR"):
        print(f"xsession: {text.strip()[4:] or 'guardian failed'}", file=sys.stderr)
        return 1

    env = dict(os.environ)
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    if display_file is not None:
        try:
            fd = os.open(display_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as out:
                out.write(f"DISPLAY={env.get('DISPLAY', '')}\nXAUTHORITY={env.get('XAUTHORITY', '')}\n")
        except OSError as exc:
            print(f"xsession: cannot write {display_file}: {exc}", file=sys.stderr)
            return 1
    try:
        os.execvpe(command[0], command, env)
    except OSError as exc:
        print(f"xsession: cannot run {command[0]}: {exc}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
