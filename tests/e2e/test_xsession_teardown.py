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
  behind once the namespace has ended.
A stand-in "browser" (`sleep`) runs under the real xsession.py --xvfb. Any lock or socket this test finds left is
removed ONLY for the display number its own session reported, and only when no X server answers on that socket.
It signals its own children (stop_browser), so run it inside a private PID namespace:
  cd tests/e2e && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c 'setsid -w python3 -X dev -m unittest -v test_xsession_teardown; exit $?'
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

    def start(self, tmp):
        display_file = Path(tmp) / "display"
        proc = subprocess.Popen([sys.executable, str(HERE / "xsession.py"), "--xvfb", "--display-file",
                                 str(display_file), "--", "sleep", "30"], stdout=subprocess.DEVNULL,
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

    def own_later(self, raw):
        number = int(raw)
        self.assertTrue(200 <= number <= 399, f"not a private display: :{number}")
        self.addCleanup(self.own, number)
        return number


if __name__ == "__main__":
    unittest.main()
