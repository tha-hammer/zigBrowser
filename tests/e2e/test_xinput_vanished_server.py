"""The X input harness (xinput.py) survives its X server going away (agent-netd-spawn-e2e in BlackRobin's gates
2f57b1e and c250d14+S8a, BlueBeaver after the orchestrator's netd-flake request).

A case that SIGKILLs the browser (case_browser_killed_before_ready) ends its private Xvfb too: the xsession.py
guardian stops it as soon as the browser's group is gone. The test driver then calls Browser.stop(), whose
XInput.close() is XCloseDisplay, which syncs with the server. When the guardian wins that race (it does under a
loaded parallel gate), Xlib's default IO error handler prints "XIO: fatal IO error 0 (Success) on X server" and calls
exit(1): the whole test process ends at once, with no FAIL line and no "N checks, M failed" summary.

Here the race is made deterministic: each child starts its own private Xvfb (xsession.Display), opens XInput on it,
stops that Xvfb, and then:
- close(): the process survives, and Xlib's fatal "XIO" message is never printed;
- an input call (key) raises XInputError naming the gone server, so a test reports it as a failed check instead of
  vanishing; the process survives;
- a second XInput on a display that is still up keeps working after the first one's server went away;
- the netd sequence: one connection's server goes away and it is closed, then a NEW connection on a new display
  works and closes (the green's first cut segfaulted there: a second libX11 handle without the argtypes);
- a second connection opened on a display started after the first connection opened works, and EVERY connection's
  libX11 carries the argtypes the per-display exit handler needs (that first cut's crash is undefined behaviour that
  a child process may survive by luck: the invariant is what is pinned);
- control: close() with the server still up closes as before.
Teardown is bounded and leaves nothing (RoseCat 7573): each child runs with its own TMPDIR (xsession.Display's temp
dir lands there) that this test removes; a child that outlives its bound is killed (our own Popen child only), and
its Xvfb, which xsession starts with PR_SET_PDEATHSIG, is gone within XVFB_GONE_S with its X lock and socket: a child
that hangs on purpose proves it.
The children stop only their own Xvfb (Popen.terminate on xsession.Display's own child), so run it inside a private
PID namespace with no display: cd tests/e2e && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY unshare --user \\
  --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v test_xinput_vanished_server'
Unregistered until the green."""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHILD_BOUND_S = 60
XVFB_GONE_S = 10

# argv: <dir of xinput.py> <what>.
CHILD = r"""
import sys
sys.path.insert(0, sys.argv[1])
from xsession import Display
from xinput import XInput, XInputError
what = sys.argv[2]
d = Display("640x480x24")
other = Display("640x480x24") if what == "two" else None
try:
    x = XInput(f":{d.number}", d.auth)
    y = XInput(f":{other.number}", other.auth) if other else None
    x._sync()
    if what == "hang":  # outlives its bound on purpose: the Xvfb must not outlive it
        print("xvfb", d.proc.pid, d.number, flush=True)
        import time
        time.sleep(600)
    if what != "alive":
        d.proc.terminate()  # our own Xvfb child, as the guardian stops it
        d.proc.wait(5)
    if what == "sequence":
        x.close()
        d.close()
        d = Display("640x480x24")
        x = XInput(f":{d.number}", d.auth)
        x.key("a")
        print("new ok", flush=True)
    if what == "later":
        later = Display("640x480x24")
        try:
            z = XInput(f":{later.number}", later.auth)
            handler = z._x.XSetIOErrorExitHandler
            print("argtypes", [t.__name__ for t in (handler.argtypes or [])][:1], handler.argtypes is not None,
                  flush=True)
            z.key("a")
            z.close()
            print("later ok", flush=True)
        finally:
            later.close()
    if what == "input":
        try:
            x.key("a")
        except XInputError as exc:
            print("raised", exc, flush=True)
    x.close()
    if y is not None:
        y.key("a")
        print("other ok", flush=True)
        y.close()
    print("survived", flush=True)
finally:
    d.close()
    if other is not None:
        other.close()
"""


def child(what: str, bound: float = CHILD_BOUND_S) -> subprocess.CompletedProcess:
    """The child's result; returncode None when it outlived `bound` and was killed. Its TMPDIR is removed either way."""
    tmp = tempfile.mkdtemp(prefix="zb-xi-vanished-")
    try:
        proc = subprocess.Popen([sys.executable, "-I", "-c", CHILD, str(HERE), what], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env={**os.environ, "TMPDIR": tmp})
        try:
            out, err = proc.communicate(timeout=bound)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()  # our own Popen child, never anything else
            out, err = proc.communicate()
            code = None
        return subprocess.CompletedProcess(proc.args, code, out, err)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def alive(pid: int) -> bool:
    """Running (a zombie awaiting the namespace's init counts as gone)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


class VanishedServerTest(unittest.TestCase):
    def test_close_after_the_server_went_away_does_not_end_the_process(self):
        done = child("close")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("survived", done.stdout)
        self.assertNotIn("XIO", done.stderr)

    def test_input_after_the_server_went_away_raises_instead_of_ending_the_process(self):
        done = child("input")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertRegex(done.stdout, r"raised .*went away")
        self.assertIn("survived", done.stdout)
        self.assertNotIn("XIO", done.stderr)

    def test_another_display_keeps_working_after_one_server_went_away(self):
        done = child("two")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("other ok", done.stdout)
        self.assertIn("survived", done.stdout)

    def test_a_new_connection_after_one_server_went_away_works(self):
        done = child("sequence")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("new ok", done.stdout)
        self.assertIn("survived", done.stdout)

    def test_a_connection_opened_after_a_later_display_started_works(self):
        done = child("later")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("later ok", done.stdout)
        self.assertIn("argtypes ['c_void_p'] True", done.stdout, "the second connection's libX11 has no argtypes")

    def test_a_child_past_its_bound_leaves_no_xvfb_lock_or_socket(self):
        done = child("hang", bound=5)
        self.assertIsNone(done.returncode, "the hanging child was not cut at its bound")
        fields = next((l.split() for l in done.stdout.splitlines() if l.startswith("xvfb ")), None)
        self.assertIsNotNone(fields, done.stdout + done.stderr)
        pid, number = int(fields[1]), fields[2]
        leftovers = []
        deadline = time.monotonic() + XVFB_GONE_S
        while time.monotonic() < deadline:
            leftovers = [what for what, left in (("xvfb", alive(pid)),
                                                 ("lock", os.path.exists(f"/tmp/.X{number}-lock")),
                                                 ("socket", os.path.exists(f"/tmp/.X11-unix/X{number}"))) if left]
            if not leftovers:
                break
            time.sleep(0.1)
        self.assertEqual(leftovers, [], f"the cut child's Xvfb :{number} left these behind")

    def test_close_with_the_server_up_still_closes(self):
        done = child("alive")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("survived", done.stdout)


if __name__ == "__main__":
    unittest.main()
