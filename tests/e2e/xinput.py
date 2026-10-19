#!/usr/bin/env python3
"""Real X input for E2E tests, on a private display only.

The browser is started under `xsession.py --xvfb --display-file PATH`; that
file names the private Xvfb (DISPLAY, XAUTHORITY). `XInput.from_display_file`
opens exactly that display and refuses anything else: `:0`, `:1`, any
display outside xsession.py's own range (:200-:399), or a file that is not
xsession.py's two lines. Events go through the X server (libXtst's
XTestFake*), so GTK receives them the way it receives a person's hand: not
through zigBrowser's automation, and not through GDK synthesis.

`screen()` reads the root window with `xwd` (an XWD dump, parsed here).
`Clipboard` owns the private display's CLIPBOARD selection, so a test can
paste real text (Ctrl+V) the way a person would.

A window can close between being listed and being asked about: the
BadWindow or BadDrawable that a read-only GetProperty (its title) or
GetGeometry gets is ignored, and the call just fails. Any other X error,
including BadWindow from a request that changes something (a resize, input,
the clipboard), still ends the process through Xlib's default handler
(test_xinput_errors.py; BlackRobin 5773, RoseCat 5786)."""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import re
import struct
import subprocess
import threading
import time
from pathlib import Path

FIRST_PRIVATE, LAST_PRIVATE = 200, 399  # xsession.Display's range

# X keysyms used by the tests (X11/keysymdef.h).
KEYSYMS = {
    "Tab": 0xFF09, "Return": 0xFF0D, "Escape": 0xFF1B, "space": 0x0020,
    "Left": 0xFF51, "Up": 0xFF52, "Right": 0xFF53, "Down": 0xFF54, "Home": 0xFF50, "End": 0xFF57,
    "Shift_L": 0xFFE1, "Control_L": 0xFFE3, "Alt_L": 0xFFE9,
}


class _XErrorEvent(ctypes.Structure):  # XErrorEvent (Xlib.h)
    _fields_ = [("type", ctypes.c_int), ("display", ctypes.c_void_p), ("resourceid", ctypes.c_ulong),
                ("serial", ctypes.c_ulong), ("error_code", ctypes.c_ubyte), ("request_code", ctypes.c_ubyte),
                ("minor_code", ctypes.c_ubyte)]


_X_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(_XErrorEvent))
_BAD_WINDOW, _BAD_DRAWABLE = 3, 9  # X.h
_X_GET_GEOMETRY, _X_GET_PROPERTY = 14, 20  # Xproto.h: the reads toplevels() makes of a listed window
_handler: list = []  # [our handler, Xlib's previous one]: kept alive while the process runs


def _install_error_handler(x) -> None:
    """Once per process (Xlib's handler is global): ignore BadWindow and BadDrawable from
    the read-only GetProperty and GetGeometry only; hand every other error to the previous
    handler (Xlib's default prints it and exits)."""
    if _handler:
        return
    x.XSetErrorHandler.restype = _X_ERROR_HANDLER
    x.XSetErrorHandler.argtypes = [_X_ERROR_HANDLER]

    def on_error(dpy, event):
        if event.contents.error_code in (_BAD_WINDOW, _BAD_DRAWABLE) and \
                event.contents.request_code in (_X_GET_GEOMETRY, _X_GET_PROPERTY):
            return 0  # the window went away between listing it and reading it
        previous = _handler[1]
        if previous:
            return previous(dpy, event)
        os.write(2, f"X Error {event.contents.error_code} (request {event.contents.request_code})\n".encode())
        os._exit(1)

    ours = _X_ERROR_HANDLER(on_error)
    _handler.extend([ours, x.XSetErrorHandler(ours)])


class XInputError(RuntimeError):
    pass


def read_display_file(path: str | os.PathLike) -> tuple[str, str]:
    """(DISPLAY, XAUTHORITY) from an xsession.py --display-file, validated."""
    text = Path(path).read_text(encoding="utf-8")
    values = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    display, xauth = values.get("DISPLAY", ""), values.get("XAUTHORITY", "")
    match = re.fullmatch(r":(\d+)", display)
    if match is None or not FIRST_PRIVATE <= int(match.group(1)) <= LAST_PRIVATE:
        raise XInputError(f"refusing display {display!r}: not an xsession.py private display")
    if not xauth or not os.path.isfile(xauth):
        raise XInputError(f"refusing display {display!r}: no private XAUTHORITY")
    return display, xauth


class XInput:
    def __init__(self, display: str, xauth: str) -> None:
        self.display_name, self.xauth = display, xauth
        x11 = ctypes.util.find_library("X11") or "libX11.so.6"
        xtst = ctypes.util.find_library("Xtst") or "libXtst.so.6"
        try:
            self._x = ctypes.CDLL(x11)
            self._t = ctypes.CDLL(xtst)
        except OSError as exc:
            raise XInputError(f"libX11/libXtst unavailable: {exc}") from exc
        x, t = self._x, self._t
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XKeysymToKeycode.restype = ctypes.c_ubyte
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                 ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
                                 ctypes.POINTER(ctypes.c_uint)]
        x.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
        x.XFree.argtypes = [ctypes.c_void_p]
        x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
                                   ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
                                   ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
                                   ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        x.XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint, ctypes.c_uint]
        t.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        _install_error_handler(x)
        previous = os.environ.get("XAUTHORITY")
        os.environ["XAUTHORITY"] = xauth
        try:
            self._dpy = x.XOpenDisplay(display.encode())
        finally:
            if previous is None:
                os.environ.pop("XAUTHORITY", None)
            else:
                os.environ["XAUTHORITY"] = previous
        if not self._dpy:
            raise XInputError(f"cannot open display {display}")

    @classmethod
    def from_display_file(cls, path: str | os.PathLike) -> "XInput":
        return cls(*read_display_file(path))

    def close(self) -> None:
        if self._dpy:
            self._x.XCloseDisplay(self._dpy)
            self._dpy = None

    def __enter__(self) -> "XInput":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()

    def _sync(self) -> None:
        self._x.XSync(self._dpy, 0)

    # --- pointer ---------------------------------------------------------
    def move(self, x: int, y: int) -> None:
        self._t.XTestFakeMotionEvent(self._dpy, -1, int(x), int(y), 0)
        self._sync()

    def button(self, pressed: bool, button: int = 1) -> None:
        self._t.XTestFakeButtonEvent(self._dpy, button, 1 if pressed else 0, 0)
        self._sync()

    def click(self, x: int, y: int, button: int = 1, settle: float = 0.03) -> None:
        self.move(x, y)
        time.sleep(settle)
        self.button(True, button)
        time.sleep(settle)
        self.button(False, button)
        time.sleep(settle)

    def wheel(self, x: int, y: int, up: bool, notches: int = 1, settle: float = 0.05) -> None:
        """Mouse-wheel notches at (x, y): X buttons 4 (up) and 5 (down)."""
        self.move(x, y)
        for _ in range(notches):
            time.sleep(settle)
            self.button(True, 4 if up else 5)
            self.button(False, 4 if up else 5)
        time.sleep(settle)

    def drag(self, x0: int, y0: int, x1: int, y1: int, steps: int = 12, settle: float = 0.02) -> None:
        """Press at (x0, y0), move in `steps` to (x1, y1), release there."""
        self.move(x0, y0)
        time.sleep(settle)
        self.button(True)
        for i in range(1, steps + 1):
            time.sleep(settle)
            self.move(round(x0 + (x1 - x0) * i / steps), round(y0 + (y1 - y0) * i / steps))
        time.sleep(settle)
        self.button(False)
        time.sleep(settle)

    # --- keyboard --------------------------------------------------------
    def _keycode(self, name: str) -> int:
        keysym = KEYSYMS.get(name)
        if keysym is None:
            if len(name) == 1 and 0x20 <= ord(name) < 0x7F:
                keysym = ord(name)
            else:
                raise XInputError(f"unknown key {name!r}")
        code = self._x.XKeysymToKeycode(self._dpy, keysym)
        if code == 0:
            raise XInputError(f"no keycode for {name!r}")
        return code

    def key(self, name: str, modifiers: tuple[str, ...] = (), settle: float = 0.03) -> None:
        mods = [self._keycode(m) for m in modifiers]
        code = self._keycode(name)
        for m in mods:
            self._t.XTestFakeKeyEvent(self._dpy, m, 1, 0)
        self._t.XTestFakeKeyEvent(self._dpy, code, 1, 0)
        self._t.XTestFakeKeyEvent(self._dpy, code, 0, 0)
        for m in reversed(mods):
            self._t.XTestFakeKeyEvent(self._dpy, m, 0, 0)
        self._sync()
        time.sleep(settle)

    # --- windows ---------------------------------------------------------
    def toplevels(self, name: str = "zigBrowser", min_size: int = 100) -> list[tuple[int, int, int, int, int]]:
        """(window, x, y, width, height) of the root's children titled `name`
        and at least `min_size` px each way (GDK's 10x10 client-leader window
        carries the same title)."""
        root = self._x.XDefaultRootWindow(self._dpy)
        root_ret, parent = ctypes.c_ulong(), ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        if not self._x.XQueryTree(self._dpy, root, ctypes.byref(root_ret), ctypes.byref(parent),
                                  ctypes.byref(children), ctypes.byref(count)):
            return []
        found = []
        try:
            for i in range(count.value):
                window = children[i]
                title = ctypes.c_char_p()
                if self._x.XFetchName(self._dpy, window, ctypes.byref(title)) and title.value is not None:
                    text = title.value.decode(errors="replace")
                    self._x.XFree(title)
                    if text != name:
                        continue
                    groot = ctypes.c_ulong()
                    gx, gy = ctypes.c_int(), ctypes.c_int()
                    gw, gh, gb, gd = ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
                    self._x.XGetGeometry(self._dpy, window, ctypes.byref(groot), ctypes.byref(gx), ctypes.byref(gy),
                                         ctypes.byref(gw), ctypes.byref(gh), ctypes.byref(gb), ctypes.byref(gd))
                    if gw.value >= min_size and gh.value >= min_size:
                        found.append((window, gx.value, gy.value, gw.value, gh.value))
        finally:
            if children:
                self._x.XFree(children)
        return found

    def resize(self, window: int, width: int, height: int) -> None:
        self._x.XResizeWindow(self._dpy, window, width, height)
        self._sync()

    # --- pixels ----------------------------------------------------------
    def screen(self) -> "Capture":
        env = dict(os.environ, XAUTHORITY=self.xauth)
        done = subprocess.run(["xwd", "-root", "-silent", "-display", self.display_name],
                              capture_output=True, env=env, timeout=30, check=False)
        if done.returncode != 0:
            raise XInputError(f"xwd failed: {done.stderr.decode(errors='replace').strip()}")
        return Capture(done.stdout)


class Capture:
    """A parsed XWD dump (ZPixmap, 24/32 bits per pixel, TrueColor)."""

    def __init__(self, data: bytes) -> None:
        header = struct.unpack(">25I", data[:100])
        (header_size, _version, pixmap_format, _depth, width, height, _xoff, byte_order, _unit, _bit_order,
         _pad, bits_per_pixel, bytes_per_line, _visual_class, red_mask, green_mask, blue_mask, _bits_rgb,
         _cmap_entries, ncolors, _ww, _wh, _wx, _wy, _border) = header
        if pixmap_format != 2 or bits_per_pixel not in (24, 32):
            raise XInputError(f"unsupported XWD format {pixmap_format}/{bits_per_pixel}bpp")
        self.width, self.height = width, height
        self._bpp = bits_per_pixel // 8
        self._stride = bytes_per_line
        self._little = byte_order == 0
        self._masks = (red_mask, green_mask, blue_mask)
        self._pixels = data[header_size + ncolors * 12:]

    def pixel(self, x: int, y: int) -> tuple[int, int, int]:
        offset = y * self._stride + x * self._bpp
        raw = self._pixels[offset:offset + self._bpp]
        value = int.from_bytes(raw, "little" if self._little else "big")
        out = []
        for mask in self._masks:
            shift = (mask & -mask).bit_length() - 1
            out.append((value & mask) >> shift)
        return out[0], out[1], out[2]


class _SelectionRequest(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("owner", ctypes.c_ulong), ("requestor", ctypes.c_ulong),
                ("selection", ctypes.c_ulong), ("target", ctypes.c_ulong), ("property", ctypes.c_ulong),
                ("time", ctypes.c_ulong)]


class _SelectionNotify(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("requestor", ctypes.c_ulong), ("selection", ctypes.c_ulong),
                ("target", ctypes.c_ulong), ("property", ctypes.c_ulong), ("time", ctypes.c_ulong)]


class Clipboard:
    """Owns CLIPBOARD on the private display (its own connection and thread)
    and answers TARGETS, UTF8_STRING and STRING requests with `text`.

        with Clipboard(xi, text):
            xi.key("v", ("Control_L",))
    """

    SELECTION_CLEAR, SELECTION_REQUEST, SELECTION_NOTIFY = 29, 30, 31

    def __init__(self, owner: XInput, text: str) -> None:
        self._data = text.encode("utf-8")
        self._x = owner._x
        x = self._x
        x.XInternAtom.restype = ctypes.c_ulong
        x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        x.XCreateSimpleWindow.restype = ctypes.c_ulong
        x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                          ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        x.XSetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
        x.XGetSelectionOwner.restype = ctypes.c_ulong
        x.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XPending.argtypes = [ctypes.c_void_p]
        x.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        x.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
        x.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self._conn = XInput(owner.display_name, owner.xauth)
        dpy = self._conn._dpy
        atom = lambda name: x.XInternAtom(dpy, name.encode(), 0)  # noqa: E731
        self._clipboard, self._targets = atom("CLIPBOARD"), atom("TARGETS")
        self._utf8, self._string, self._atom = atom("UTF8_STRING"), 31, 4
        root = x.XDefaultRootWindow(dpy)
        self._window = x.XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0)
        x.XSetSelectionOwner(dpy, self._clipboard, self._window, 0)
        x.XSync(dpy, 0)
        if x.XGetSelectionOwner(dpy, self._clipboard) != self._window:
            raise XInputError("could not own CLIPBOARD")
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        x, dpy = self._x, self._conn._dpy
        event = ctypes.create_string_buffer(192)
        while not self._stop.is_set():
            if not x.XPending(dpy):
                time.sleep(0.01)
                continue
            x.XNextEvent(dpy, event)
            kind = ctypes.c_int.from_buffer(event).value
            if kind != self.SELECTION_REQUEST:
                continue
            req = _SelectionRequest.from_buffer_copy(event.raw[:ctypes.sizeof(_SelectionRequest)])
            prop = req.property or req.target
            if req.target == self._targets:
                atoms = (ctypes.c_ulong * 3)(self._targets, self._utf8, self._string)
                x.XChangeProperty(dpy, req.requestor, prop, self._atom, 32, 0, atoms, 3)
            elif req.target in (self._utf8, self._string):
                x.XChangeProperty(dpy, req.requestor, prop, req.target, 8, 0, self._data, len(self._data))
            else:
                prop = 0
            reply = _SelectionNotify(type=self.SELECTION_NOTIFY, send_event=1, display=dpy, requestor=req.requestor,
                                     selection=req.selection, target=req.target, property=prop, time=req.time)
            x.XSendEvent(dpy, req.requestor, 0, 0, ctypes.byref(reply))
            x.XFlush(dpy)

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=2)
        self._x.XDestroyWindow(self._conn._dpy, self._window)
        self._conn.close()

    def __enter__(self) -> "Clipboard":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()
