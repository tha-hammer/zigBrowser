"""A stopped browser's private display is gone when stop_browser returns (zigBrowser-44h: namespaced e2e runs left
/tmp/.X2xx-lock files and /tmp/.X11-unix sockets behind).

xsession.py's detached guardian removes the private Xvfb (its X lock and socket) only after it sees the browser exit,
so stop_browser used to return while that cleanup was still to come. Outside a namespace the guardian finished later
on its own; inside a PID namespace the driver's exit ends the namespace, the teardown SIGKILLs the guardian and Xvfb
mid-cleanup, and the lock and socket stay behind (18 after 18 one-test namespaced runs, 2026-10-21).

slice2_common.stop_browser now waits, bounded, for the guardian to finish with a PRIVATE display (:200-:399, read
from the browser's own environment; never :0, never another display) once the browser has exited:
- when stop_browser returns, the display's lock and socket are already gone (three sessions in a row);
- a driver that stops its browser and exits at once, as the only process of its own PID namespace, leaves neither
  behind once the namespace has ended;
- a browser that already exited by itself (not yet reaped, like one a test SIGKILLed), whose guardian is still
  waiting out a helper it left, has its display gone when stop_browser returns: the guardian is found before anything
  reaps the browser;
- with a second session running (started first, so its guardian has the lower pid), stopping one browser waits for
  that browser's own guardian only: it returns promptly, its display is gone, and the other session is untouched.
A stand-in "browser" (`sleep`) runs under the real xsession.py --xvfb. It runs ONLY in a private /tmp (RoseCat 7681:
a display number and a failed connect are no ownership on a shared /tmp, where another session can claim the number
between the check and an unlink): its launcher holds the outer /tmp as fd 7 BEFORE it enters a new mount namespace
with a fresh tmpfs on /tmp, and every test refuses unless /tmp is a different filesystem from that fd. So every lock,
socket and leftover clean-up here lives in that private tmpfs. It signals only its own children (stop_browser) and
runs inside a private PID namespace too. The launcher (pinned in build.zig's registered step; RoseCat 7681):
  cd tests/e2e && sh -c 'exec 7</tmp; exec unshare --map-current-user --keep-caps --mount --pid --fork --kill-child \\
    --mount-proc sh -c "mount --rbind /tmp /mnt && mount -t tmpfs -o mode=1777 tmpfs /tmp && mkdir -m 1777 \\
    /tmp/.X11-unix || exit 99; case \\$PWD in /tmp/*) cd \\"/mnt\\${PWD#/tmp}\\" || exit 98;; esac; ZB_OUTER_TMP_FD=7 \\
    setsid -w python3 -X dev -m unittest -v test_xsession_teardown; rc=\\$?; \\
    left=\\$(find /tmp -mindepth 1 ! -path \\
    /tmp/.X11-unix; ls -A /tmp/.X11-unix); \\
    [ -z \\"\\$left\\" ] || { echo \\"private /tmp not empty: \\$left\\"; exit 1; }; \\
    exit \\$rc"'
(--keep-caps: our own uid inside, with the namespace's capabilities, so the tmpfs can be mounted; the old /tmp is
bound at /mnt in that namespace only, so a tree under /tmp stays reachable; afterwards the private /tmp must hold
nothing but the empty /tmp/.X11-unix the launcher made itself.)
Unregistered until the green."""
import os
import socket
import subprocess
import sys
import tempfile
import shutil
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLEANUP_WAIT_S = 30  # a guardian's worst case: helper grace 8 s + group TERM/KILL 10 s + Xvfb TERM 5 s
sys.path.insert(0, str(HERE))

from slice2_common import stop_browser  # noqa: E402
from xinput import read_display_file  # noqa: E402

DRIVER = r"""
import subprocess, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from slice2_common import stop_browser
from xinput import read_display_file
display_file = Path(sys.argv[2])
proc = subprocess.Popen([sys.executable, str(Path(sys.argv[1]) / "xsession.py"), "--xvfb", "--display-file",
                         str(display_file), "--", "sleep", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 20
while not display_file.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
print(read_display_file(display_file)[0][1:], flush=True)
stop_browser(proc)
"""


def private_tmp():
    """(True, "") when /tmp is a different filesystem from the launcher's held outer /tmp (ZB_OUTER_TMP_FD)."""
    raw = os.environ.get("ZB_OUTER_TMP_FD", "")
    if not raw.isdigit() or int(raw) < 3:
        return False, "no held outer /tmp fd from the launcher (ZB_OUTER_TMP_FD)"
    try:
        outer, inner = os.fstat(int(raw)), os.stat("/tmp")
    except OSError as exc:
        return False, f"cannot compare /tmp with the held fd: {exc.strerror}"
    if outer.st_dev == inner.st_dev:
        return False, "/tmp is the launcher's own /tmp, not a private one"
    return True, ""


def leftovers(number):
    return [p for p in (f"/tmp/.X{number}-lock", f"/tmp/.X11-unix/X{number}") if os.path.lexists(p)]


def served(number):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(f"/tmp/.X11-unix/X{number}")
        return True
    except OSError:
        return False
    finally:
        s.close()


class Teardown(unittest.TestCase):
    def setUp(self):
        ok, why = private_tmp()
        if not ok:
            self.fail(f"refusing to run X sessions and clean up X locks outside a private /tmp: {why}")

    def own(self, number):
        """Clean up after a red run: only this session's own display. First give its guardian the time it needs
        (it may still be removing it), then remove what is left only if no server answers on the socket."""
        number = int(number)
        self.assertTrue(200 <= number <= 399, f"not a private display: :{number}")
        deadline = time.monotonic() + CLEANUP_WAIT_S
        while leftovers(number) and served(number) and time.monotonic() < deadline:
            time.sleep(0.05)
        if not served(number):
            for path in leftovers(number):
                os.unlink(path)
        return number

    def start(self, tmp, browser=("sleep", "30")):
        display_file = Path(tmp) / "display"
        proc = subprocess.Popen([sys.executable, str(HERE / "xsession.py"), "--xvfb", "--display-file",
                                 str(display_file), "--", *browser], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while not display_file.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        number = int(read_display_file(display_file)[0][1:])
        self.addCleanup(self.own, number)
        return proc, number

    def test_stop_browser_returns_after_the_private_display_is_gone(self):
        for i in range(3):
            with self.subTest(session=i):
                tmp = tempfile.mkdtemp(prefix="zb-xs-td-")
                self.addCleanup(shutil.rmtree, tmp, True)
                proc, number = self.start(tmp)
                self.assertTrue(leftovers(number), "the session's display never came up")
                stop_browser(proc)
                self.assertEqual(leftovers(number), [], f":{number} was still being cleaned up")

    def test_a_namespace_that_ends_right_after_stop_browser_leaves_nothing(self):
        tmp = tempfile.mkdtemp(prefix="zb-xs-td-")
        self.addCleanup(shutil.rmtree, tmp, True)
        done = subprocess.run(["unshare", "--map-current-user", "--pid", "--fork", "--kill-child", "--mount-proc",
                               sys.executable, "-I", "-c", DRIVER, str(HERE), str(Path(tmp) / "display")],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr[-500:])
        number = self.own_later(done.stdout.split()[0])
        self.assertEqual(leftovers(number), [], f"the ended namespace left :{number}'s lock or socket behind")

    def test_a_browser_that_already_exited_still_has_its_display_gone(self):
        tmp = tempfile.mkdtemp(prefix="zb-xs-td-")
        self.addCleanup(shutil.rmtree, tmp, True)
        # The browser exits at once and leaves a helper in its group for 3 s: its guardian is still mid-cleanup
        # (waiting out that helper) when stop_browser runs.
        proc, number = self.start(tmp, ("sh", "-c", "sleep 3 & sleep 0.5; exit 0"))
        deadline = time.monotonic() + 20
        while os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:  # exited, NOT reaped
            self.assertLess(time.monotonic(), deadline, "the stand-in browser did not exit")
            time.sleep(0.02)
        stop_browser(proc)
        self.assertEqual(leftovers(number), [], f":{number} was still being cleaned up")

    def test_stopping_one_browser_waits_for_its_own_guardian_only(self):
        tmp_other, tmp_mine = (tempfile.mkdtemp(prefix="zb-xs-td-") for _ in range(2))
        for t in (tmp_other, tmp_mine):
            self.addCleanup(shutil.rmtree, t, True)
        other, other_number = self.start(tmp_other)  # first: its guardian has the lower pid
        self.addCleanup(stop_browser, other)
        mine, number = self.start(tmp_mine)
        started = time.monotonic()
        stop_browser(mine)
        self.assertLess(time.monotonic() - started, 10, "stop_browser waited for another session's guardian")
        self.assertEqual(leftovers(number), [], f":{number} was still being cleaned up")
        self.assertIsNone(other.poll(), "the other session's browser was stopped")
        self.assertTrue(served(other_number), "the other session's display went away")

    def own_later(self, raw):
        number = int(raw)
        self.assertTrue(200 <= number <= 399, f"not a private display: :{number}")
        self.addCleanup(self.own, number)
        return number


if __name__ == "__main__":
    unittest.main()
