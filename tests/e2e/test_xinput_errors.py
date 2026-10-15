"""The X input harness (xinput.py) survives an X error about a window that
has just gone away (BlackRobin 5773).

BlackRobin's gate lost `agent-secrets-e2e` to
`X Error of failed request: BadWindow (X_GetProperty)`: XInput.toplevels()
lists the root's children, then asks each for its title, and a window that
closed in between (the Secrets window, a popup) makes the request fail.
Xlib's default error handler then exits the whole test process. Here the
same request is made deterministically, on a window this test destroyed
first. BadWindow and BadDrawable from the read-only requests toplevels()
makes (GetProperty for the title, GetGeometry) are ignored: the call reports
failure, and toplevels() skips the window. Any other X error still ends the
process as before, including BadWindow from a request that changes
something (a resize of the gone window), so a real fault cannot pass
silently (RoseCat 5786).

Run only under `xsession.py --xvfb` (a private display, :200-:399); it
refuses any other display."""

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

# argv: <dir of xinput.py> <what>. Creates a 200x200 window titled zigBrowser
# on its own connection, destroys it, then makes a request about it.
CHILD = r"""
import ctypes, os, sys
sys.path.insert(0, sys.argv[1])
from xinput import XInput
xi = XInput(os.environ["DISPLAY"], os.environ.get("XAUTHORITY", ""))
x, dpy = xi._x, xi._dpy
x.XCreateSimpleWindow.restype = ctypes.c_ulong
x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                  ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
x.XStoreName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_char_p]
x.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
w = x.XCreateSimpleWindow(dpy, x.XDefaultRootWindow(dpy), 0, 0, 200, 200, 0, 0, 0)
x.XStoreName(dpy, w, b"zigBrowser")
xi._sync()
what = sys.argv[2]
if what == "bad-value":  # a fault that is not about a vanished window
    xi.resize(w, 0, 0)  # BadValue: a zero size
    xi._sync()
    print("survived", flush=True)
    sys.exit(0)
x.XDestroyWindow(dpy, w)
xi._sync()
if what == "fetch-name":
    title = ctypes.c_char_p()
    ok = x.XFetchName(dpy, w, ctypes.byref(title))
    xi._sync()
    print("fetch", ok, flush=True)
elif what == "geometry":  # GetGeometry on a gone window: BadDrawable
    root, gx, gy = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int()
    gw, gh, gb, gd = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
    ok = x.XGetGeometry(dpy, w, ctypes.byref(root), ctypes.byref(gx), ctypes.byref(gy), ctypes.byref(gw),
                        ctypes.byref(gh), ctypes.byref(gb), ctypes.byref(gd))
    xi._sync()
    print("geometry", ok, flush=True)
elif what == "resize-gone":  # a request that changes something: BadWindow stays fatal
    xi.resize(w, 300, 300)
    xi._sync()
elif what == "toplevels":
    print("toplevels", [t[0] for t in xi.toplevels()].count(w), flush=True)
print("survived", flush=True)
"""


def private_display() -> bool:
    match = re.fullmatch(r":(\d+)(\.\d+)?", os.environ.get("DISPLAY", ""))
    return bool(match) and 200 <= int(match.group(1)) <= 399


def child(what: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", "-c", CHILD, str(HERE), what], capture_output=True, text=True,
                          timeout=30)


class VanishedWindowTest(unittest.TestCase):
    def setUp(self):
        if not private_display():
            self.fail(f"refusing to run on DISPLAY={os.environ.get('DISPLAY')!r}: use xsession.py --xvfb")

    def test_a_request_about_a_destroyed_window_does_not_end_the_process(self):
        done = child("fetch-name")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("survived", done.stdout)
        self.assertIn("fetch 0", done.stdout, "the call reports failure")
        self.assertNotIn("X Error", done.stderr)

    def test_toplevels_skips_a_window_that_is_gone(self):
        done = child("toplevels")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("toplevels 0", done.stdout)
        self.assertNotIn("X Error", done.stderr)

    def test_a_geometry_read_of_a_destroyed_window_does_not_end_the_process(self):
        done = child("geometry")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("geometry 0", done.stdout, "the call reports failure")
        self.assertNotIn("X Error", done.stderr)

    def test_a_resize_of_a_destroyed_window_still_ends_the_process(self):
        done = child("resize-gone")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertNotIn("survived", done.stdout)
        self.assertIn("BadWindow", done.stderr)

    def test_any_other_x_error_still_ends_the_process(self):
        done = child("bad-value")
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertNotIn("survived", done.stdout)
        self.assertIn("BadValue", done.stderr)


if __name__ == "__main__":
    unittest.main()
