"""The real-screen check's input guard against a real X server (RoseCat 5393,
5395): a decoy window that covers the target, becomes the active window, or
appears just before the input must receive no button or key event, and the
guard must send none. Runs only on a private Xvfb (xsession.py, :200-:399):

    python3 tests/e2e/xsession.py --xvfb -- python3 -m unittest -v test_real_screen_input

(from tests/manual). A canary client owns both windows and counts the events
each one receives; the guard under test uses its own connection, as on the
user's screen."""

import ctypes
import ctypes.util
import os
import re
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import real_screen_check as rsc  # noqa: E402

KEY_PRESS, BUTTON_PRESS = 2, 4
MASKS = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3)  # Key and Button Press/Release


def private_display() -> bool:
    match = re.fullmatch(r":(\d+)(\.\d+)?", os.environ.get("DISPLAY", ""))
    return bool(match) and 200 <= int(match.group(1)) <= 399


class SetWindowAttributes(ctypes.Structure):  # XSetWindowAttributes (Xlib.h)
    _fields_ = [("background_pixmap", ctypes.c_ulong), ("background_pixel", ctypes.c_ulong),
                ("border_pixmap", ctypes.c_ulong), ("border_pixel", ctypes.c_ulong), ("bit_gravity", ctypes.c_int),
                ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("event_mask", ctypes.c_long),
                ("do_not_propagate_mask", ctypes.c_long), ("override_redirect", ctypes.c_int),
                ("colormap", ctypes.c_ulong), ("cursor", ctypes.c_ulong)]


class Canary:
    """Its own X connection: makes the target and decoy windows, the window
    manager's root properties, the focus, and counts delivered events."""

    def __init__(self):
        x = ctypes.CDLL(ctypes.util.find_library("X11"))
        ul, ptr, i = ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int
        x.XOpenDisplay.restype, x.XOpenDisplay.argtypes = ptr, [ctypes.c_char_p]
        x.XDefaultRootWindow.restype, x.XDefaultRootWindow.argtypes = ul, [ptr]
        x.XCreateSimpleWindow.restype = ul
        x.XCreateSimpleWindow.argtypes = [ptr, ul, i, i, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ul, ul]
        for name in ("XMapRaised", "XUnmapWindow", "XDestroyWindow"):
            getattr(x, name).argtypes = [ptr, ul]
        x.XSelectInput.argtypes = [ptr, ul, ctypes.c_long]
        x.XChangeWindowAttributes.argtypes = [ptr, ul, ul, ptr]
        x.XInternAtom.restype, x.XInternAtom.argtypes = ul, [ptr, ctypes.c_char_p, i]
        x.XChangeProperty.argtypes = [ptr, ul, ul, ul, i, i, ptr, i]
        x.XDeleteProperty.argtypes = [ptr, ul, ul]
        x.XSetInputFocus.argtypes = [ptr, ul, i, ul]
        x.XSync.argtypes = [ptr, i]
        x.XPending.argtypes = [ptr]
        x.XNextEvent.argtypes = [ptr, ptr]
        x.XCloseDisplay.argtypes = [ptr]
        self.x = x
        self.dpy = x.XOpenDisplay(None)
        self.root = x.XDefaultRootWindow(self.dpy)
        self.counts: dict[tuple[int, int], int] = {}

    def window(self, override_redirect=False, x=0, y=0):
        w = self.x.XCreateSimpleWindow(self.dpy, self.root, x, y, 400, 300, 0, 0, 0x808080)
        if override_redirect:
            attrs = SetWindowAttributes(override_redirect=1)
            self.x.XChangeWindowAttributes(self.dpy, w, 1 << 9, ctypes.byref(attrs))  # CWOverrideRedirect
        self.x.XSelectInput(self.dpy, w, MASKS)
        return w

    def show(self, w):
        self.x.XMapRaised(self.dpy, w)
        self.sync()

    def hide(self, w):
        self.x.XUnmapWindow(self.dpy, w)
        self.sync()

    def set_root(self, name: bytes, value, kind=33):  # XA_WINDOW; 6 is XA_CARDINAL
        atom = self.x.XInternAtom(self.dpy, name, 0)
        if value is None:
            self.x.XDeleteProperty(self.dpy, self.root, atom)
        else:
            data = ctypes.c_ulong(value)
            self.x.XChangeProperty(self.dpy, self.root, atom, kind, 32, 0, ctypes.byref(data), 1)
        self.sync()

    def focus(self, w):
        self.x.XSetInputFocus(self.dpy, w, 1, 0)  # RevertToPointerRoot, CurrentTime
        self.sync()

    def sync(self):
        self.x.XSync(self.dpy, 0)
        time.sleep(0.1)
        event = (ctypes.c_long * 24)()  # XEvent
        while self.x.XPending(self.dpy):
            self.x.XNextEvent(self.dpy, event)
            kind, window = ctypes.c_int.from_buffer(event, 0).value, event[4]  # type; XAnyEvent.window
            self.counts[(window, kind)] = self.counts.get((window, kind), 0) + 1

    def got(self, w, kind):
        self.sync()
        return self.counts.get((w, kind), 0)

    def close(self):
        self.x.XCloseDisplay(self.dpy)


def setUpModule():
    # Fails closed instead of skipping: a skipped gate step would pass unverified.
    if not private_display():
        raise RuntimeError("needs a private Xvfb from xsession.py (:200-:399); never run on the user's screen")


class GuardOnRealX(unittest.TestCase):
    def setUp(self):
        self.canary = Canary()
        self.target = self.canary.window()
        self.decoy = self.canary.window(override_redirect=True)
        self.canary.show(self.target)
        self.canary.set_root(b"_NET_SUPPORTING_WM_CHECK", None)
        self.canary.set_root(b"_NET_ACTIVE_WINDOW", None)
        self.x11 = rsc.X11()
        self.calls = []
        for name in ("move", "button", "escape", "key"):  # safe_key presses through key
            real = getattr(self.x11, name)
            setattr(self.x11, name, self._spy(name, real))
        self.addCleanup(self.x11.close)
        self.addCleanup(self.canary.close)

    def _spy(self, name, real):
        def call(*args):
            self.calls.append(name)
            return real(*args)
        return call

    def assert_nothing_reached(self):
        """No XTest event at all (no motion either: RoseCat 5406), and no
        button or key event delivered to either window."""
        self.assertEqual(self.calls, [], "the guard sent input")
        for w in (self.target, self.decoy):
            self.assertEqual((self.canary.got(w, BUTTON_PRESS), self.canary.got(w, KEY_PRESS)), (0, 0), hex(w))

    def test_a_decoy_on_top_gets_nothing_and_no_input_is_sent(self):
        self.canary.show(self.decoy)
        self.canary.focus(self.decoy)
        self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.assertIsNotNone(rsc.safe_escape(self.x11, self.target))
        self.assertEqual(self.calls, [])
        self.assert_nothing_reached()

    def test_a_decoy_that_is_the_active_window_gets_nothing(self):
        self.canary.set_root(b"_NET_SUPPORTING_WM_CHECK", self.decoy)
        for active in (self.decoy, None):  # another active window; an unreadable property
            self.canary.set_root(b"_NET_ACTIVE_WINDOW", active)
            self.canary.focus(self.target)
            self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
            self.assertIsNotNone(rsc.safe_escape(self.x11, self.target))
        self.assertEqual(self.calls, [])
        self.assert_nothing_reached()

    def test_the_active_target_without_the_focus_gets_nothing(self):
        """RoseCat 5400: _NET_ACTIVE_WINDOW names the target, but the focus
        is on a decoy beside it (not covering the click point)."""
        beside = self.canary.window(x=500, y=0)
        self.canary.show(beside)
        self.canary.set_root(b"_NET_SUPPORTING_WM_CHECK", self.target)
        self.canary.set_root(b"_NET_ACTIVE_WINDOW", self.target)
        self.canary.focus(beside)
        self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.assertIsNotNone(rsc.safe_escape(self.x11, self.target))
        self.assertEqual(self.calls, [], "no motion, no button, no key")
        self.assert_nothing_reached()
        self.assertEqual((self.canary.got(beside, BUTTON_PRESS), self.canary.got(beside, KEY_PRESS)), (0, 0))

    def test_a_wrong_typed_active_window_property_refuses(self):
        self.canary.set_root(b"_NET_SUPPORTING_WM_CHECK", self.target)
        self.canary.set_root(b"_NET_ACTIVE_WINDOW", self.target, kind=6)  # XA_CARDINAL
        self.canary.focus(self.target)
        self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.assertEqual(self.calls, [])
        self.assert_nothing_reached()

    def test_a_decoy_mapped_just_before_the_input_gets_nothing(self):
        real_grab = self.x11.grab

        def late_decoy():
            self.canary.show(self.decoy)  # after every earlier check, before the grab's final one
            self.canary.focus(self.decoy)
            real_grab()

        self.x11.grab = late_decoy
        self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.canary.hide(self.decoy)
        self.x11.grab = late_decoy
        self.assertIsNotNone(rsc.safe_escape(self.x11, self.target))
        self.assert_nothing_reached()

    def test_an_unmapped_target_gets_nothing(self):
        self.canary.hide(self.target)
        self.assertIsNotNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.assertIsNotNone(rsc.safe_escape(self.x11, self.target))
        self.assert_nothing_reached()

    def test_the_target_on_top_active_and_focused_gets_exactly_one_click_and_one_escape(self):
        self.canary.set_root(b"_NET_SUPPORTING_WM_CHECK", self.target)
        self.canary.set_root(b"_NET_ACTIVE_WINDOW", self.target)
        self.canary.focus(self.target)
        self.assertIsNone(rsc.safe_click(self.x11, self.target, 200, 150))
        self.assertIsNone(rsc.safe_escape(self.x11, self.target))
        self.assertEqual((self.canary.got(self.target, BUTTON_PRESS), self.canary.got(self.target, KEY_PRESS)), (1, 1))
        self.assertEqual((self.canary.got(self.decoy, BUTTON_PRESS), self.canary.got(self.decoy, KEY_PRESS)), (0, 0))


if __name__ == "__main__":
    unittest.main()
