"""Chat-drawer plan rev 16.18.10 (the orchestrator 2026-10-20; RoseCat 6184): the Secrets window
never outlives its transient parent, and a running sign-in is cancelled exactly once.

DEFENCE IN DEPTH, NOT A CRASH FIX. At the user's S6b1 part A quit, gnome-shell 48.7 (X11)
died on a BadWindow after the main window was closed with the Secrets window open. That crash
was NOT reproduced (0 of 57 tries with the same gnome-shell on a private Xvfb, no clipboard
manager in that rig) and stays OPEN. Nothing here is evidence of its cause or of its fix.

What these cases pin is wrong on its own today: the main window is unmapped and destroyed
first, the Secrets window stays mapped without a parent for 80-150 ms until the process exits
and the X server destroys it, and its destroy handler never runs, so a sign-in in flight is
never cancelled. A separate X client on the private Xvfb (no WM: the toplevels are root
children) selects SubstructureNotify on the root and records the toplevels' UnmapNotify and
DestroyNotify; an app that withdraws a window itself adds its own (synthetic) UnmapNotify,
which a server-side teardown at exit never does.

Cases (run alone or with --only):
- close-idle: the Secrets window open and idle; WM_DELETE_WINDOW to the main window (the last
  one): the Secrets window is unmapped and destroyed before it, by the app.
- close-code: the same with the code field showing; the one ending is `cancelled`.
- term-code: the code field showing; SIGTERM (the app's quit): the app destroys the Secrets
  window (right after the main window: the named gap) and the one ending is `cancelled`.
- other-closes: the Secrets window, presented over the first window, shows its code field; a
  second browser window is closed: the Secrets window stays mapped and the sign-in has no
  ending.
- parent-closes-other-survives: the same, but the first window is closed while the second
  lives: the Secrets window goes first, the one ending is `cancelled`, no Secrets window
  remains, and the browser and the second window keep running."""

import ctypes
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_secrets_test as sec  # noqa: E402,F401
import agent_login_test as lt  # noqa: E402
from agent_common import run_main  # noqa: E402
from xinput import read_display_file  # noqa: E402

TITLE = "Claude Agent account"
UNMAP, DESTROY, CLIENT_MESSAGE = 18, 17, 33
SUBSTRUCTURE_NOTIFY = 1 << 19

X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XInternAtom.restype = ctypes.c_ulong
X.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
X.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_long]
X.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
X.XPending.argtypes = [ctypes.c_void_p]
X.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
X.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
X.XCloseDisplay.argtypes = [ctypes.c_void_p]
X.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
IS_VIEWABLE = 2  # XWindowAttributes.map_state


class _Attributes(ctypes.Structure):  # XWindowAttributes (Xlib.h)
    _fields_ = [("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
                ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
                ("root", ctypes.c_ulong), ("c_class", ctypes.c_int), ("bit_gravity", ctypes.c_int),
                ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
                ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p)]


class _Any(ctypes.Structure):  # XUnmapEvent / XDestroyWindowEvent share this prefix
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("event", ctypes.c_ulong), ("window", ctypes.c_ulong)]


class _Client(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("l", ctypes.c_long * 5)]


class _Event(ctypes.Union):
    _fields_ = [("any", _Any), ("client", _Client), ("pad", ctypes.c_long * 24)]


class Watch:
    """A private X client on the browser's display that records toplevel unmaps and destroys."""

    def __init__(self, b) -> None:
        import os
        display, xauth = read_display_file(b.display_file)
        os.environ["XAUTHORITY"] = xauth
        self.dpy = X.XOpenDisplay(display.encode())
        if not self.dpy:
            raise RuntimeError(f"cannot open {display}")
        self.root = X.XDefaultRootWindow(self.dpy)
        X.XSelectInput(self.dpy, self.root, SUBSTRUCTURE_NOTIFY)
        X.XSync(self.dpy, 0)
        self.events: list[tuple[str, int]] = []

    def delete(self, window: int) -> None:
        """WM_PROTOCOLS/WM_DELETE_WINDOW to `window`: what a WM's close button sends."""
        ev = _Event()
        ev.client.type = CLIENT_MESSAGE
        ev.client.send_event = 1
        ev.client.window = window
        ev.client.message_type = X.XInternAtom(self.dpy, b"WM_PROTOCOLS", 0)
        ev.client.format = 32
        ev.client.l[0] = X.XInternAtom(self.dpy, b"WM_DELETE_WINDOW", 0)
        X.XSendEvent(self.dpy, window, 0, 0, ctypes.byref(ev))
        X.XSync(self.dpy, 0)

    def collect(self, windows: set[int], timeout: float, until: set[int] | None = None) -> None:
        """Events of `windows` until every window in `until` (default: all of them) is
        destroyed, or the timeout."""
        until = windows if until is None else until
        gone: set[int] = set()
        deadline = time.monotonic() + timeout
        ev = _Event()
        while not until <= gone and time.monotonic() < deadline:
            if not X.XPending(self.dpy):
                time.sleep(0.002)
                continue
            X.XNextEvent(self.dpy, ctypes.byref(ev))
            kind, window = ev.any.type, ev.any.window
            if window in windows and kind in (UNMAP, DESTROY):
                self.events.append(("unmap" if kind == UNMAP else "destroy", window))
                if kind == DESTROY:
                    gone.add(window)

    def drain(self, windows: set[int], seconds: float) -> None:
        """Every event of `windows` for the whole of `seconds` (RoseCat 6188: a quiet window,
        so a late unmap or destroy is seen)."""
        deadline = time.monotonic() + seconds
        ev = _Event()
        while time.monotonic() < deadline:
            if not X.XPending(self.dpy):
                time.sleep(0.002)
                continue
            X.XNextEvent(self.dpy, ctypes.byref(ev))
            if ev.any.window in windows and ev.any.type in (UNMAP, DESTROY):
                self.events.append(("unmap" if ev.any.type == UNMAP else "destroy", ev.any.window))

    def viewable(self, window: int) -> bool:
        """The window exists and is mapped with all its ancestors (map_state IsViewable)."""
        attrs = _Attributes()
        X.XSync(self.dpy, 0)
        return bool(X.XGetWindowAttributes(self.dpy, window, ctypes.byref(attrs))) and attrs.map_state == IS_VIEWABLE

    def close(self) -> None:
        if self.dpy:
            X.XCloseDisplay(self.dpy)
            self.dpy = None


def first(events, what: str, window: int) -> int | None:
    return next((i for i, e in enumerate(events) if e == (what, window)), None)


def shutdown_case(binary: Path, tmp: Path, check, name: str, code: bool, how: str) -> None:
    si = lt.SignIn(binary, tmp, name)
    b = si.b
    watch = None
    try:
        if not si.open_window(check):
            return
        if code and not si.sign_in(check):
            return
        mains = b.x.toplevels("zigBrowser")
        secrets = b.x.toplevels(TITLE, 50)
        if not check(len(mains) == 1 and len(secrets) == 1, "one main window and one Secrets window", b):
            return
        main, sw = mains[0][0], secrets[0][0]
        b._x.close()  # this Xvfb ends with the browser: no client of ours may be left on it
        b._x = None
        watch = Watch(b)
        if how == "close":
            watch.delete(main)
        else:
            b.proc.terminate()
        watch.collect({main, sw}, 20)
        seen = list(watch.events)
        watch.close()  # before the browser's Xvfb goes away with it
        watch = None
        print(f"   {name}: {[(k, 'secrets' if w == sw else 'main') for k, w in seen]}", flush=True)
        d_main, d_sw = first(seen, "destroy", main), first(seen, "destroy", sw)
        u_main, u_sw = first(seen, "unmap", main), first(seen, "unmap", sw)
        check(d_main is not None and d_sw is not None, "both toplevels are destroyed")
        if how == "close":  # the close button: the Secrets window goes first
            check(u_sw is not None and (u_main is None or u_sw < u_main),
                  "the Secrets window is unmapped before the main window")
            check(d_sw is not None and d_main is not None and d_sw < d_main,
                  "the Secrets window is destroyed before the main window")
        # Every quit: the app itself takes the Secrets window down (its own unmap, which an
        # X server's teardown at exit never sends: that is one server-side unmap only).
        check(sum(1 for e in seen if e == ("unmap", sw)) == 2,
              "the app unmaps the Secrets window itself (not the X server at exit)")
        if code:
            b.wait(lambda: lt.endings(b) != [], 10)
            check(lt.endings(b) == ["cancelled"], f"the sign-in's one ending is cancelled ({lt.login_states(b)})", b)
        check(b.wait(lambda: b.proc.poll() is not None, 20), "the browser exits", b)
    finally:
        if watch is not None:
            watch.close()
        si.close()


def two_windows(si, check):
    """The Secrets window over the first window with its code field showing, then a second
    browser window: (watch, first, second, secrets) or None."""
    b = si.b
    if not si.open_window(check) or not si.sign_in(check):
        return None
    before = {w for w, *_ in b.x.toplevels("zigBrowser")}
    if not check(b.open_popup(), "a second browser window opens", b):
        return None
    if not check(b.wait(lambda: len(b.x.toplevels("zigBrowser")) == 2, 10), "two browser toplevels", b):
        return None
    after = {w for w, *_ in b.x.toplevels("zigBrowser")}
    secrets = b.x.toplevels(TITLE, 50)
    new = after - before
    if not check(len(before) == 1 and len(new) == 1 and len(secrets) == 1,
                 "one first window, one second window, one Secrets window", b):
        return None
    first_w, second = next(iter(before)), next(iter(new))  # chosen before anything mutates (RoseCat 6188)
    check(first_w != second, "the first and second windows differ")
    watch = Watch(b)
    check(watch.viewable(first_w) and watch.viewable(second) and watch.viewable(secrets[0][0]),
          "all three toplevels are mapped before the close")
    return watch, first_w, second, secrets[0][0]


def case_other_closes(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "shut-other")
    b = si.b
    watch = None
    try:
        got = two_windows(si, check)
        if got is None:
            return
        watch, first_w, second, sw = got
        watch.delete(second)
        watch.collect({first_w, second, sw}, 20, until={second})
        watch.drain({first_w, second, sw}, 2.0)  # a quiet window: a late unmap is seen too
        seen = list(watch.events)
        print(f"   other-closes: {[(k, {sw: 'secrets', first_w: 'first'}.get(w, 'second')) for k, w in seen]}",
              flush=True)
        check(("destroy", second) in seen, "the second window is destroyed")
        check(not any(w in (sw, first_w) for _, w in seen),
              "no unmap or destroy of the Secrets window or the first window, through a 2 s quiet window")
        check(watch.viewable(sw) and watch.viewable(first_w), "the Secrets window and the first window are still mapped")
        check(lt.endings(b) == [] and b.proc.poll() is None, f"the sign-in has no ending ({lt.login_states(b)})", b)
        sec.click_rect(b, lt.rect(b, "cancel"))
        b.wait(lambda: lt.endings(b) != [], 10)
        check(lt.endings(b) == ["cancelled"], f"Cancel still ends it, once ({lt.login_states(b)})", b)
    finally:
        if watch is not None:
            watch.close()
        si.close()


def case_parent_closes_other_survives(binary: Path, tmp: Path, check) -> None:
    si = lt.SignIn(binary, tmp, "shut-parent")
    b = si.b
    watch = None
    try:
        got = two_windows(si, check)
        if got is None:
            return
        watch, first_w, second, sw = got
        watch.delete(first_w)
        watch.collect({first_w, second, sw}, 20, until={first_w, sw})
        seen = list(watch.events)
        print(f"   parent-closes-other-survives: {[(k, {sw: 'secrets', first_w: 'first'}.get(w, 'second')) for k, w in seen]}",
              flush=True)
        d_first, d_sw = first(seen, "destroy", first_w), first(seen, "destroy", sw)
        u_first, u_sw = first(seen, "unmap", first_w), first(seen, "unmap", sw)
        check(d_sw is not None, "the Secrets window is destroyed")
        check(u_sw is not None and (u_first is None or u_sw < u_first),
              "the Secrets window is unmapped before the first window")
        check(d_sw is not None and d_first is not None and d_sw < d_first,
              "the Secrets window is destroyed before the first window")
        b.wait(lambda: lt.endings(b) != [], 10)
        check(lt.endings(b) == ["cancelled"], f"the sign-in's one ending is cancelled ({lt.login_states(b)})", b)
        watch.drain({first_w, second, sw}, 1.5)
        seen = list(watch.events)
        check(b.proc.poll() is None, "the browser keeps running", b)
        check(not any(w == second for _, w in seen), "no unmap or destroy of the second window, through a quiet window")
        check(watch.viewable(second), "the second window is still mapped")
        check(len(b.x.toplevels("zigBrowser")) == 1 and b.x.toplevels(TITLE, 50) == [],
              "the second window remains and no Secrets window does", b)
    finally:
        if watch is not None:
            watch.close()
        si.close()


CASES = {
    "close-idle": lambda b, t, c: shutdown_case(b, t, c, "shut-idle", False, "close"),
    "close-code": lambda b, t, c: shutdown_case(b, t, c, "shut-code", True, "close"),
    "term-code": lambda b, t, c: shutdown_case(b, t, c, "shut-term", True, "term"),
    "other-closes": case_other_closes,
    "parent-closes-other-survives": case_parent_closes_other_survives,
}


def main() -> int:
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    sys.exit(main())
