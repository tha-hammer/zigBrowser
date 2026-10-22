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
- control: close() with the server still up closes as before.
The children stop only their own Xvfb (Popen.terminate on xsession.Display's own child), so run it inside a private
PID namespace with no display: cd tests/e2e && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY unshare --user \\
  --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest -v test_xinput_vanished_server'
Unregistered until the green."""

import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

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
    if what != "alive":
        d.proc.terminate()  # our own Xvfb child, as the guardian stops it
        d.proc.wait(5)
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


def child(what: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", "-c", CHILD, str(HERE), what], capture_output=True, text=True,
                          timeout=60)


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

    def test_close_with_the_server_up_still_closes(self):
        done = child("alive")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("survived", done.stdout)


if __name__ == "__main__":
    unittest.main()
