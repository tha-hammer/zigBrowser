#!/usr/bin/env python3
"""The real-hardware check for a UI slice (chat-drawer plan section 7.1).

The gate runs under a private Xvfb with software GL, so it cannot see a
failure that only the real GPU and driver produce. That gap let a blank
window through: with `--agent-drawer on` the whole window was blank on the
user's NVIDIA screen while the Xvfb gate drew the page and the icon.

This script is prepared by agents and run ONLY by the orchestrator, on the
user's real screen, with the user's permission. Agents never run it on the
user's display; they may run it on their own private Xvfb to check the
script itself.

For each case it starts the built binary with a throwaway profile (no
automation socket, so the live browser and its socket are never touched),
loads a solid-colour page, captures the window, and counts pixels:
  - the page colour must fill most of the window (the page is drawn);
  - with the drawer on, the icon colour must be present (the "S" icon is drawn);
  - drawer-open then clicks that icon (XTest, inside our own window),
    checks the page above the drawer and the drawer's panel twice, a
    second apart, then presses Escape and checks the page and icon again.
A window that is not wholly on the screen fails the case.
The screen's pixels under the window are authoritative: a case passes only
when both the screen and the window's own buffer show the page (and the
icon). Rendering overrides in the shell (RENDER_ENV) are removed before each
case. It writes a PNG of every capture and the browser's stderr (with the
case's argv and render environment) to --out, and prints one line per case.
Exit 0 only when every case passes; exit 3 when the drawer-off control
fails, because then the capture itself is not trusted.

    python3 tests/manual/real_screen_check.py --confirm-user-permission \\
        --bin zig-out/bin/zigBrowser --out /tmp/zb-real-screen [--matrix] \\
        [--variant no-ghost=/path/to/build] [--variant-page-only empty=/path/to/build]

`--case long-run` (S5.6) runs only the long-replies check instead: a throwaway agent
home (its own HOME, data and runtime directories), no real token, the local fake
Messages API and hook decoys, `--media-source off`. The fake answers "long" with
204,800 `y` and "words" with 204,800 bytes of words. For each, the drawer must show
the reply, '-' must fold it within 1 s, and a click in the reply, Ctrl+A and Ctrl+C
must put exactly the original on the clipboard (no added line breaks). Every input
goes through the same server-grab checks as the other cases.

    python3 tests/manual/real_screen_check.py --confirm-user-permission --case long-run \\
        --bin zig-out/bin/zigBrowser --out /tmp/zb-long-run
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "e2e"))
from xinput import Capture  # noqa: E402  (the XWD parser only; it opens no display)

PAGE_RGB = (0x1E, 0x6F, 0xB4)   # the fixture page's background
ICON_RGB = (0xD9, 0x77, 0x57)   # #zb-agent-icon's background (src/agent_drawer.c)
TOLERANCE = 8                   # per channel
PAGE_MIN_FRACTION = 0.40        # of the window's pixels
ICON_MIN_PIXELS = 400           # a 56 px circle has about 2400
PANEL_RGB = (0xF4, 0xF1, 0xEA)  # #zb-agent-drawer's background
OPEN_PAGE_MIN_FRACTION = 0.30   # the open drawer covers the bottom 40%
OPEN_PANEL_MIN_FRACTION = 0.10
BLANK_MAX_FRACTION = 0.90       # --url: one colour over this much of the page is blank
PASS, FAIL, INVALID = "PASS", "FAIL", "INVALID"
# A drawer case and the drawer-off case that must pass for it to mean anything.
CONTROLS = {"on-renderer-default": "off-renderer-default"}

# The fixture is shaped like the page the user saw blank (Wikipedia): a tall
# document of text cards with small images under a sticky header, plus
# layers WebKit 2.54 must composite even under its conservative memory
# policy (RoseCat 5395, RenderLayerCompositor.cpp: a nonzero 3D transform on
# a self-painting wrapper with a running transform animation; a canvas of at
# least 5000 px) and continuous small repaints (canvas, ticking text). Every
# surface is the page blue or white text, so the page colour still covers
# most of the window. 2.54 forces compositing mode whenever acceleration is
# on: this changes layer topology, tiling and damage, not the mode.
_CARD = ("<div class=card><img alt='' src=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' "
         "width='48' height='48'%3E%3Ccircle cx='24' cy='24' r='20' fill='%23ffffff'/%3E%3C/svg%3E\">"
         "<p>A web browser is an application for accessing websites. It retrieves content from a web server and "
         "displays the page on the screen.</p></div>")
FIXTURE_HTML = """<!doctype html><title>zb real screen check</title>
<style>
html,body{margin:0;background:#1e6fb4;color:#fff;font:16px sans-serif}
header{position:sticky;top:0;background:#1e6fb4;padding:12px 40px;font-size:28px;border-bottom:1px solid #fff}
main{padding:20px 40px 20px 360px}
.card{border-top:1px solid #fff;padding:8px 0;display:flex;gap:12px;align-items:center}
.card img{width:48px;height:48px}
#layer3d{position:fixed;left:40px;top:90px;width:120px;height:120px;background:#1e6fb4;
  transform:translate3d(0,0,1px)}
#spin{width:40px;height:40px;margin:40px;background:#f2c94c;animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg) translate3d(0,0,1px)}}
canvas{position:fixed;left:200px;top:90px}
</style>
<body><header>zigBrowser real-screen check <span id=tick>0</span></header>
<div id=layer3d><div id=spin></div></div><canvas id=c width=128 height=128></canvas>
<main>""" + _CARD * 40 + """</main>
<script>
let n = 0;
const ctx = document.getElementById('c').getContext('2d');
(function frame() {
  ctx.fillStyle = '#1e6fb4'; ctx.fillRect(0, 0, 128, 128);
  ctx.fillStyle = `hsl(${n % 360},80%,50%)`; ctx.fillRect(48, 48, 32, 32);
  if (n++ % 30 === 0) document.getElementById('tick').textContent = n;
  requestAnimationFrame(frame);
})();
</script>"""

# Rendering overrides a shell may carry. They are removed before each case,
# so a case's label is the only thing that changes how it renders.
RENDER_ENV = (
    "GDK_GL", "GDK_DEBUG", "GDK_BACKEND", "GDK_SCALE", "GDK_DPI_SCALE", "GSK_RENDERER",
    "WEBKIT_DISABLE_COMPOSITING_MODE", "WEBKIT_FORCE_COMPOSITING_MODE", "WEBKIT_DMABUF_RENDERER_FORCE_SHM",
    "WEBKIT_DISABLE_DMABUF_RENDERER", "WEBKIT_SKIA_ENABLE_CPU_RENDERING", "WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS",
    "__EGL_VENDOR_LIBRARY_FILENAMES", "__EGL_VENDOR_LIBRARY_DIRS", "__GLX_VENDOR_LIBRARY_NAME",
    "__GL_SYNC_TO_VBLANK", "__NV_PRIME_RENDER_OFFLOAD", "LIBGL_ALWAYS_SOFTWARE", "LIBGL_ALWAYS_INDIRECT",
    "GALLIUM_DRIVER", "MESA_LOADER_DRIVER_OVERRIDE", "EGL_PLATFORM", "LD_PRELOAD", "LD_LIBRARY_PATH",
)


class Case:
    def __init__(self, name: str, drawer: bool, args: list[str] | None = None, env: dict[str, str] | None = None,
                 binary: str | None = None, note: str = "", icon: bool | None = None, open_drawer: bool = False) -> None:
        self.name, self.drawer, self.args, self.env = name, drawer, args or [], env or {}
        self.binary, self.note = binary, note
        self.icon = drawer if icon is None else icon  # whether the icon must be drawn
        self.open_drawer = open_drawer  # then click the icon and check the open drawer too


def cases(matrix: bool, variants: list[tuple[str, str]], page_only: list[tuple[str, str]]) -> list[Case]:
    out = [Case("drawer-off", False, note="control: the window without the drawer"),
           Case("drawer-on", True, note="the slice check: defaults plus --agent-drawer on"),
           Case("drawer-open", True, open_drawer=True, note="drawer-on, then a click on the icon opens the drawer")]
    if matrix:
        out += [
            Case("on-hw-never", True, ["--hardware-acceleration", "never"], note="no GPU compositing in WebKit"),
            Case("off-renderer-default", False, ["--renderer", "default"], note="control: DMA-BUF without the drawer"),
            Case("on-renderer-default", True, ["--renderer", "default"], note="DMA-BUF GPU buffers, not SHM"),
            Case("on-renderer-mesa-egl", True, ["--renderer", "mesa-egl"], note="Mesa EGL instead of NVIDIA EGL"),
            Case("on-gdk-gl-disable", True, env={"GDK_GL": "disable"},
                 note="GDK without GL; WebKit then turns its acceleration off too, so this is not a narrow test"),
            # Not WEBKIT_DISABLE_COMPOSITING_MODE=1: on Xvfb it leaves the page unpainted
            # at random even with the drawer off, so it separates nothing.
        ]
    out += [Case(name, True, binary=path, note=f"variant build {path}") for name, path in variants]
    out += [Case(name, True, binary=path, icon=False, note=f"page-only variant {path}") for name, path in page_only]
    return out


def write_png(capture: Capture, box: tuple[int, int, int, int], path: Path) -> None:
    x0, y0, w, h = box
    rows = []
    for y in range(y0, y0 + h):
        row = bytearray(b"\x00")
        for x in range(x0, x0 + w):
            row += bytes(capture.pixel(x, y))
        rows.append(bytes(row))
    chunk = lambda kind, data: (struct.pack(">I", len(data)) + kind + data  # noqa: E731
                                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))


def count(capture: Capture, box: tuple[int, int, int, int], rgb: tuple[int, int, int]) -> int:
    x0, y0, w, h = box
    n = 0
    for y in range(y0, y0 + h, 2):          # every other row and column: a quarter of the pixels
        for x in range(x0, x0 + w, 2):
            p = capture.pixel(x, y)
            if all(abs(p[i] - rgb[i]) <= TOLERANCE for i in range(3)):
                n += 4
    return n


def judge(window: Capture, screen: Capture, crop: tuple[int, int, int, int], need_icon: bool) -> tuple[bool, str]:
    """Pass only when both the window's own pixels and the screen's pixels
    under it show the page (and the icon when required). The screen is the
    authority: a presentation failure leaves the window's buffer drawn and
    the screen blank."""
    results = []
    for label, cap, box in (("screen", screen, crop), ("window", window, (0, 0, window.width, window.height))):
        area = max(1, box[2] * box[3])
        fraction = count(cap, box, PAGE_RGB) / area
        icon = count(cap, box, ICON_RGB)
        ok = fraction >= PAGE_MIN_FRACTION and (not need_icon or icon >= ICON_MIN_PIXELS)
        results.append((ok, f"{label} page {fraction:.0%}, icon {icon} px"))
    return all(ok for ok, _ in results), "; ".join(text for _, text in results)


def judge_not_blank(window: Capture, screen: Capture, crop: tuple[int, int, int, int]) -> tuple[bool, str]:
    """--url: any page; it is drawn when no single colour covers most of it
    (a blank window is one flat colour), on the screen and in the buffer."""
    results = []
    for label, cap, box in (("screen", screen, crop), ("window", window, (0, 0, window.width, window.height))):
        top = top_colour(cap, box)
        results.append((top < BLANK_MAX_FRACTION, f"{label} top colour {top:.0%}"))
    return all(ok for ok, _ in results), "; ".join(text for _, text in results)


def top_colour(cap: Capture, box: tuple[int, int, int, int]) -> float:
    """The share of `box` taken by its most common colour (in 8-level steps)."""
    x0, y0, w, h = box
    colours: dict[tuple[int, int, int], int] = {}
    for y in range(y0, y0 + h, 4):
        for x in range(x0, x0 + w, 4):
            p = cap.pixel(x, y)
            key = (p[0] // 8, p[1] // 8, p[2] // 8)
            colours[key] = colours.get(key, 0) + 1
    return max(colours.values(), default=0) / max(1, sum(colours.values()))


def judge_page(window: Capture, screen: Capture, crop: tuple[int, int, int, int], need_icon: bool,
               any_page: bool) -> tuple[bool, str]:
    if not any_page:
        return judge(window, screen, crop, need_icon)
    ok, detail = judge_not_blank(window, screen, crop)
    if need_icon:
        icon = count(screen, crop, ICON_RGB)
        ok, detail = ok and icon >= ICON_MIN_PIXELS, f"{detail}; screen icon {icon} px"
    return ok, detail


def judge_open(window: Capture, screen: Capture, crop: tuple[int, int, int, int],
               any_page: bool = False) -> tuple[bool, str]:
    """The open drawer: the page above it and the panel, on the screen and
    in the window's buffer (the screen is the authority, as in judge)."""
    results = []
    for label, cap, box in (("screen", screen, crop), ("window", window, (0, 0, window.width, window.height))):
        area = max(1, box[2] * box[3])
        panel = count(cap, box, PANEL_RGB) / area
        if any_page:  # above the drawer (D2: it takes the bottom 40%)
            share = top_colour(cap, (box[0], box[1], box[2], box[3] * 55 // 100))
            page_ok, page_text = share < BLANK_MAX_FRACTION, f"page above: top colour {share:.0%}"
        else:
            page = count(cap, box, PAGE_RGB) / area
            page_ok, page_text = page >= OPEN_PAGE_MIN_FRACTION, f"page {page:.0%}"
        ok = page_ok and panel >= OPEN_PANEL_MIN_FRACTION
        results.append((ok, f"open {label} {page_text}, panel {panel:.0%}"))
    return all(ok for ok, _ in results), "; ".join(text for _, text in results)


def icon_centre(screen: Capture, crop: tuple[int, int, int, int]) -> tuple[int, int] | None:
    """The centre of the icon's colour on the screen, in root coordinates."""
    x0, y0, w, h = crop
    hits = [(x, y) for y in range(y0, y0 + h, 2) for x in range(x0, x0 + w, 2)
            if all(abs(screen.pixel(x, y)[i] - ICON_RGB[i]) <= TOLERANCE for i in range(3))]
    if len(hits) * 4 < ICON_MIN_PIXELS:
        return None
    return sum(x for x, _ in hits) // len(hits), sum(y for _, y in hits) // len(hits)


def case_env(base: dict[str, str], work: Path, extra: dict[str, str]) -> dict[str, str]:
    """The shell's environment without rendering overrides, the browser's
    own variables or its socket; throwaway XDG directories; then the case's."""
    env = {k: v for k, v in base.items() if k not in RENDER_ENV and not k.startswith(("ZIGBROWSER_", "ZB_"))}
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        env[name] = str(work / name.lower())
    env.update(extra)
    return env


class X11:
    """One connection to $DISPLAY, for the safety checks and for XTest input."""

    def __init__(self) -> None:
        import ctypes
        import ctypes.util

        self.c = ctypes
        xlib, xtst = ctypes.util.find_library("X11"), ctypes.util.find_library("Xtst")
        if xlib is None or xtst is None:
            raise RuntimeError("libX11 or libXtst is missing")
        x, t = ctypes.CDLL(xlib), ctypes.CDLL(xtst)
        ul, ptr, i = ctypes.c_ulong, ctypes.c_void_p, ctypes.c_int
        x.XOpenDisplay.restype, x.XOpenDisplay.argtypes = ptr, [ctypes.c_char_p]
        x.XDefaultRootWindow.restype, x.XDefaultRootWindow.argtypes = ul, [ptr]
        x.XTranslateCoordinates.argtypes = [ptr, ul, ul, i, i, ctypes.POINTER(i), ctypes.POINTER(i), ctypes.POINTER(ul)]
        x.XQueryPointer.argtypes = [ptr, ul, ctypes.POINTER(ul), ctypes.POINTER(ul), ctypes.POINTER(i),
                                    ctypes.POINTER(i), ctypes.POINTER(i), ctypes.POINTER(i), ctypes.POINTER(ctypes.c_uint)]
        x.XGetInputFocus.argtypes = [ptr, ctypes.POINTER(ul), ctypes.POINTER(i)]
        x.XQueryTree.argtypes = [ptr, ul, ctypes.POINTER(ul), ctypes.POINTER(ul), ctypes.POINTER(ctypes.POINTER(ul)),
                                 ctypes.POINTER(ctypes.c_uint)]
        x.XInternAtom.restype, x.XInternAtom.argtypes = ul, [ptr, ctypes.c_char_p, i]
        x.XSendEvent.argtypes = [ptr, ul, i, ctypes.c_long, ptr]
        x.XRaiseWindow.argtypes = [ptr, ul]
        x.XSync.argtypes = [ptr, i]
        x.XFree.argtypes = [ptr]
        x.XCloseDisplay.argtypes = [ptr]
        x.XKeysymToKeycode.restype, x.XKeysymToKeycode.argtypes = ctypes.c_ubyte, [ptr, ul]
        x.XGrabServer.argtypes = x.XUngrabServer.argtypes = [ptr]
        x.XGetWindowProperty.argtypes = [ptr, ul, ul, ctypes.c_long, ctypes.c_long, i, ul, ctypes.POINTER(ul),
                                         ctypes.POINTER(i), ctypes.POINTER(ctypes.c_ulong),
                                         ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte))]

        class Attributes(ctypes.Structure):  # XWindowAttributes (Xlib.h)
            _fields_ = [("x", i), ("y", i), ("width", i), ("height", i), ("border_width", i), ("depth", i),
                        ("visual", ptr), ("root", ul), ("c_class", i), ("bit_gravity", i), ("win_gravity", i),
                        ("backing_store", i), ("backing_planes", ul), ("backing_pixel", ul), ("save_under", i),
                        ("colormap", ul), ("map_installed", i), ("map_state", i), ("all_event_masks", ctypes.c_long),
                        ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                        ("override_redirect", i), ("screen", ptr)]

        self.Attributes = Attributes
        x.XGetWindowAttributes.argtypes = [ptr, ul, ctypes.POINTER(Attributes)]
        t.XTestFakeMotionEvent.argtypes = [ptr, i, i, i, ul]
        t.XTestFakeButtonEvent.argtypes = [ptr, ctypes.c_uint, i, ul]
        t.XTestFakeKeyEvent.argtypes = [ptr, ctypes.c_uint, i, ul]
        self.x, self.t = x, t
        self.dpy = x.XOpenDisplay(None)
        if not self.dpy:
            raise RuntimeError("cannot open the display")
        self.root = x.XDefaultRootWindow(self.dpy)

    def close(self) -> None:
        if self.dpy:
            self.x.XCloseDisplay(self.dpy)
            self.dpy = None

    def path_at(self, px: int, py: int) -> list[int]:
        """The windows containing root point px, py, topmost first at each
        level, from the root's child down to the deepest."""
        c, path, window = self.c, [], self.root
        while True:
            cx, cy, child = c.c_int(), c.c_int(), c.c_ulong()
            if not self.x.XTranslateCoordinates(self.dpy, self.root, window, px, py, c.byref(cx), c.byref(cy),
                                                c.byref(child)) or not child.value:
                return path
            path.append(child.value)
            window = child.value

    def pointer_path(self) -> list[int]:
        c, path, window = self.c, [], self.root
        while True:
            r, child = c.c_ulong(), c.c_ulong()
            a, b, d, e, m = c.c_int(), c.c_int(), c.c_int(), c.c_int(), c.c_uint()
            self.x.XQueryPointer(self.dpy, window, c.byref(r), c.byref(child), c.byref(a), c.byref(b), c.byref(d),
                                 c.byref(e), c.byref(m))
            if not child.value:
                return path
            path.append(child.value)
            window = child.value

    def grab(self) -> None:
        """No other client's request runs until ungrab: nothing can restack,
        map or refocus between the last check and the input."""
        self.x.XGrabServer(self.dpy)
        self.x.XSync(self.dpy, 0)

    def ungrab(self) -> None:
        self.x.XUngrabServer(self.dpy)
        self.x.XSync(self.dpy, 0)

    def viewable_rect(self, wid: int) -> tuple[int, int, int, int] | None:
        """`wid`'s rect in root coordinates while it is viewable, else None."""
        c, attrs = self.c, self.Attributes()
        if not self.x.XGetWindowAttributes(self.dpy, wid, c.byref(attrs)) or attrs.map_state != 2:  # IsViewable
            return None
        rx, ry, child = c.c_int(), c.c_int(), c.c_ulong()
        if not self.x.XTranslateCoordinates(self.dpy, wid, self.root, 0, 0, c.byref(rx), c.byref(ry), c.byref(child)):
            return None
        return rx.value, ry.value, attrs.width, attrs.height

    def root_window_property(self, name: bytes) -> int | None:
        """A WINDOW-typed property of the root (None: absent or unreadable)."""
        c = self.c
        atom = self.x.XInternAtom(self.dpy, name, 1)
        if not atom:
            return None
        actual, fmt, n, after = c.c_ulong(), c.c_int(), c.c_ulong(), c.c_ulong()
        data = c.POINTER(c.c_ubyte)()
        # AnyPropertyType: the type is checked here, so a wrong-typed property refuses visibly.
        if self.x.XGetWindowProperty(self.dpy, self.root, atom, 0, 1, 0, 0, c.byref(actual), c.byref(fmt),
                                     c.byref(n), c.byref(after), c.byref(data)) != 0 or not data:
            return None
        try:
            if actual.value != 33 or fmt.value != 32 or n.value != 1:  # XA_WINDOW, one 32-bit item
                return None
            return c.cast(data, c.POINTER(c.c_ulong))[0]
        finally:
            self.x.XFree(data)

    def wm_running(self) -> bool:
        return self.root_window_property(b"_NET_SUPPORTING_WM_CHECK") is not None

    def active(self) -> int | None:
        return self.root_window_property(b"_NET_ACTIVE_WINDOW")

    def pointer(self) -> tuple[int, int]:
        c, r, child = self.c, self.c.c_ulong(), self.c.c_ulong()
        rx, ry, wx, wy, m = c.c_int(), c.c_int(), c.c_int(), c.c_int(), c.c_uint()
        self.x.XQueryPointer(self.dpy, self.root, c.byref(r), c.byref(child), c.byref(rx), c.byref(ry), c.byref(wx),
                             c.byref(wy), c.byref(m))
        return rx.value, ry.value

    def focus(self) -> int:
        c, w, revert = self.c, self.c.c_ulong(), self.c.c_int()
        self.x.XGetInputFocus(self.dpy, c.byref(w), c.byref(revert))
        return w.value

    def parent(self, window: int) -> int:
        c = self.c
        root, parent, children, n = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
        if not self.x.XQueryTree(self.dpy, window, c.byref(root), c.byref(parent), c.byref(children), c.byref(n)):
            return 0
        if children:
            self.x.XFree(children)
        return parent.value

    def activate(self, wid: int) -> None:
        """Ask the window manager to raise and focus `wid` (_NET_ACTIVE_WINDOW)."""
        c = self.c

        class ClientMessage(c.Structure):
            _fields_ = [("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int), ("display", c.c_void_p),
                        ("window", c.c_ulong), ("message_type", c.c_ulong), ("format", c.c_int),
                        ("data", c.c_long * 5)]

        ev = ClientMessage(type=33, send_event=1, display=self.dpy, window=wid,
                           message_type=self.x.XInternAtom(self.dpy, b"_NET_ACTIVE_WINDOW", 0), format=32)
        ev.data[0], ev.data[1] = 2, 0  # source: a pager (a direct user request); time: current
        self.x.XSendEvent(self.dpy, self.root, 0, (1 << 19) | (1 << 20), c.byref(ev))
        self.x.XRaiseWindow(self.dpy, wid)
        self.x.XSync(self.dpy, 0)

    def move(self, px: int, py: int) -> None:
        self.t.XTestFakeMotionEvent(self.dpy, -1, px, py, 0)
        self.x.XSync(self.dpy, 0)

    def button(self) -> None:
        """Left button down and up; up is sent whenever down was."""
        self.t.XTestFakeButtonEvent(self.dpy, 1, 1, 0)
        try:
            self.x.XSync(self.dpy, 0)
        finally:
            self.t.XTestFakeButtonEvent(self.dpy, 1, 0, 0)
            self.x.XSync(self.dpy, 0)

    def key(self, keysym: int, modifiers: tuple[int, ...] = ()) -> None:
        """One key press and release with `modifiers` held; every key pressed is released."""
        held = []
        try:
            for mod in modifiers:
                code = self.x.XKeysymToKeycode(self.dpy, mod)
                self.t.XTestFakeKeyEvent(self.dpy, code, 1, 0)
                held.append(code)
            code = self.x.XKeysymToKeycode(self.dpy, keysym)
            self.t.XTestFakeKeyEvent(self.dpy, code, 1, 0)
            try:
                self.x.XSync(self.dpy, 0)
            finally:
                self.t.XTestFakeKeyEvent(self.dpy, code, 0, 0)
        finally:
            for code in reversed(held):
                self.t.XTestFakeKeyEvent(self.dpy, code, 0, 0)
            self.x.XSync(self.dpy, 0)

    def escape(self) -> None:
        self.key(KEY_ESCAPE)


# --- safety: input goes only to our own window, which must be on top ------------

def sample_points(crop: tuple[int, int, int, int]) -> list[tuple[int, int]]:
    """A 3x3 grid inset from the window's edges, in root coordinates."""
    x, y, w, h = crop
    return [(x + w * fx // 6, y + h * fy // 6) for fy in (1, 3, 5) for fx in (1, 3, 5)]


def covered_points(wid: int, crop: tuple[int, int, int, int], path_at) -> list[tuple[int, int]]:
    """The sample points where our window is not on top (not on the path of
    windows that contain the point)."""
    return [p for p in sample_points(crop) if wid not in path_at(*p)]


def focus_inside(wid: int, focus: int, parent_of) -> bool:
    """Whether the keyboard focus is `wid` or a window inside it."""
    seen = 0
    while focus not in (0, 1) and seen < 64:  # None and PointerRoot are never ours
        if focus == wid:
            return True
        focus, seen = parent_of(focus), seen + 1
    return False


POINTER_ROOT = 1  # X's focus mode in which keys go to the window under the pointer
KEY_ESCAPE, KEY_RETURN, KEY_CONTROL_L = 0xFF1B, 0xFF0D, 0xFFE3  # X keysyms


def window_ready(x11, wid: int) -> str | None:
    """Why `wid` may not take input now (None: it may): it must be viewable,
    and, when a window manager runs, its active window."""
    if x11.viewable_rect(wid) is None:
        return "our window is not viewable"
    if x11.wm_running() and x11.active() != wid:
        return "our window is not the active window"
    return None


def current_rect(windows: str, named: tuple[int, int, int, int]) -> tuple[int, int, int, int] | None:
    """Where a control the drawer named in a row (`minus`, `open`, `icon`) is drawn now, in the
    window's own coordinates, from a `windows` row (Type:input|output:viewable|hidden:depth:
    x:y:w:h, comma-separated): the one viewable input widget of the same width and height.
    The drawer's rows are in screen coordinates once the window has its place (and in the
    window's before it), while `windows` rows are always in the window's; on the user's GNOME
    screen (2026-10-20) the window's top-left was at 0,69, so a row's place, plus the window's
    again, clicked 69 px low. None when not exactly one matches: then nothing is clicked."""
    _x, _y, w, h = named
    hits = []
    for item in windows.split(","):
        parts = item.split(":")
        if len(parts) != 8 or parts[1] != "input" or parts[2] != "viewable":
            continue
        try:
            at = tuple(int(v) for v in parts[4:8])
        except ValueError:
            continue
        if (at[2], at[3]) == (w, h):
            hits.append(at)
    return hits[0] if len(hits) == 1 else None


DRAWN_WAIT_S = 5.0


def drawn_now(b, kind: str, timeout: float = DRAWN_WAIT_S) -> tuple[int, int, int, int] | None:
    """The drawer's `kind` where the newest `windows` row draws it (current_rect), waiting up
    to `timeout` for that row: the census is written when the window is drawn, which can be
    a few rows after the row that says the control is shown. None if it never is."""
    found = []

    def match() -> bool:
        named, windows = b.of(kind), b.of("windows")
        now = current_rect(windows[-1].fields[0], named[-1].rect()) if named and windows else None
        found[:] = [now] if now else []
        return now is not None
    b.wait(match, timeout)
    return found[0] if found else None


def window_rect(rect: tuple[int, int, int, int], origin: tuple[int, int]) -> tuple[int, int, int, int]:
    """A drawer row's screen rect in the window's coordinates (`origin`: the window's top-left
    on the screen)."""
    return rect[0] - origin[0], rect[1] - origin[1], rect[2], rect[3]


def screen_point(rect: tuple[int, int, int, int], origin: tuple[int, int]) -> tuple[int, int]:
    """The screen point at the centre of a rect in the window's coordinates."""
    return origin[0] + rect[0] + rect[2] // 2, origin[1] + rect[1] + rect[3] // 2


def reply_point(text: tuple[int, int, int, int], opened: tuple[int, int, int, int],
                origin: tuple[int, int]) -> tuple[int, int] | None:
    """Where to click the reply, in the window's coordinates: on its text (`text`, the
    `textrect` row, in screen coordinates) and inside the panel's list (`opened`, as drawn,
    without its 48 px header and 64 px input). None if less than 8 px of text is there."""
    x, y, w, h = window_rect(text, origin)
    top, bottom = max(y, opened[1] + 48), min(y + h, opened[1] + opened[3] - 64)
    if bottom - top < 8:
        return None
    return x + min(w // 2, 200), (top + bottom) // 2


ASK_FOCUS = "click once on the zigBrowser window title bar to focus it"
ACTIVE_WAIT_S = 20.0


def ensure_active(x11, wid: int, timeout: float = ACTIVE_WAIT_S, say=print, poll: float = 0.25) -> bool:
    """True once our window may take input (window_ready). The user's real-screen run
    (2026-10-20): GNOME's focus-stealing prevention gave the focus back to the terminal that
    launched us. So, before any input: ask the window manager again (_NET_ACTIVE_WINDOW,
    raise); if it still refuses, ask the user once to click our title bar, and wait up to
    `timeout`. This sends no input of its own; False when the window never became ready."""
    if window_ready(x11, wid) is None:
        return True
    x11.activate(wid)
    until = time.monotonic() + min(1.0, timeout)
    while time.monotonic() < until:
        if window_ready(x11, wid) is None:
            return True
        time.sleep(poll)
    say(f"{ASK_FOCUS} (waiting up to {timeout:.0f} s; no input is sent until it is focused)")
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if window_ready(x11, wid) is None:
            time.sleep(min(0.5, poll * 20))  # let the user's click finish before our pointer moves
            return True
        time.sleep(poll)
    return False


def raise_window(x11, wid: int, tries: int = 3) -> bool:
    """Asks for our window on top and active; True once it is viewable,
    active (with a window manager) and on top at every sample point."""
    for _ in range(tries):
        x11.activate(wid)
        time.sleep(0.7)
        rect = x11.viewable_rect(wid)
        if rect and window_ready(x11, wid) is None and not covered_points(wid, rect, x11.path_at):
            return True
    return False


def focused(x11, wid: int, path: list[int]) -> bool:
    """Whether the keyboard focus is inside our window; with PointerRoot
    focus, whether `path` (the windows at the pointer, or at the point the
    pointer is about to reach) holds our window."""
    focus = x11.focus()
    return wid in path if focus == POINTER_ROOT else focus_inside(wid, focus, x11.parent)


def safe_click(x11, wid: int, px: int, py: int) -> str | None:
    """Clicks at px, py only if, under a server grab, our window is viewable,
    active, focused, contains the point and is on top there. Returns why it
    refused (saying whether the pointer had moved), or None."""
    x11.grab()
    try:
        reason = window_ready(x11, wid)
        rect = x11.viewable_rect(wid)
        path = x11.path_at(px, py)
        if reason is None and not (rect and rect[0] <= px < rect[0] + rect[2] and rect[1] <= py < rect[1] + rect[3]):
            reason = "the click point is outside our window"
        if reason is None and wid not in path:
            reason = "our window is not on top at the click point"
        if reason is None and not focused(x11, wid, path):
            reason = "the keyboard focus is not in our window"
        if reason:
            return reason + "; no input sent"
        x11.move(px, py)
        if x11.pointer() != (px, py) or wid not in x11.pointer_path():
            return "the pointer did not land on our window; it moved, no click sent"
        x11.button()
        return None
    finally:
        x11.ungrab()


def safe_key(x11, wid: int, keysym: int, modifiers: tuple[int, ...] = ()) -> str | None:
    """A key only if, under a server grab, our window is viewable, active,
    and holds the keyboard focus (or, with PointerRoot focus, the pointer)."""
    x11.grab()
    try:
        reason = window_ready(x11, wid)
        if reason is None and not focused(x11, wid, x11.pointer_path()):
            reason = "the keyboard focus is not in our window"
        if reason:
            return reason + "; no input sent"
        x11.key(keysym, modifiers)
        return None
    finally:
        x11.ungrab()


def safe_escape(x11, wid: int) -> str | None:
    return safe_key(x11, wid, KEY_ESCAPE)


def our_window(pid: int) -> int | None:
    tree = subprocess.run(["xwininfo", "-root", "-tree"], capture_output=True, text=True, timeout=30).stdout
    for wid in re.findall(r"^\s*(0x[0-9a-f]+) \"zigBrowser\"", tree, re.M):
        prop = subprocess.run(["xprop", "-id", wid, "_NET_WM_PID"], capture_output=True, text=True, timeout=30).stdout
        if prop.strip().endswith(f"= {pid}"):
            return int(wid, 16)
    return None


def geometry(wid: int) -> tuple[int, int, int, int]:
    info = subprocess.run(["xwininfo", "-id", hex(wid)], capture_output=True, text=True, timeout=30).stdout
    field = lambda name: int(re.search(rf"{name}:\s+(-?\d+)", info).group(1))  # noqa: E731
    return field("Absolute upper-left X"), field("Absolute upper-left Y"), field("Width"), field("Height")


def capture_both(wid: int, out: Path, name: str,
                 crop: tuple[int, int, int, int] | None = None) -> tuple[Capture, Capture]:
    """The window's own buffer and the whole screen, each saved as a PNG
    (the screen cropped to the window, once its place is known)."""
    window = xwd("-id", hex(wid))
    write_png(window, (0, 0, window.width, window.height), out / f"{name}.window.png")
    screen = xwd("-root")
    if crop is None:
        x, y, w, h = geometry(wid)
        crop = (max(x, 0), max(y, 0), max(0, min(w, screen.width - max(x, 0))), max(0, min(h, screen.height - max(y, 0))))
    if crop[2] > 0 and crop[3] > 0:
        write_png(screen, crop, out / f"{name}.screen.png")
    return window, screen


def xwd(*args: str) -> Capture:
    done = subprocess.run(["xwd", "-silent", *args], capture_output=True, timeout=60)
    if done.returncode != 0:
        raise RuntimeError(f"xwd {' '.join(args)}: {done.stderr.decode(errors='replace').strip()}")
    return Capture(done.stdout)


def run_case(case: Case, default_bin: str, out: Path, settle: float, url: str | None = None) -> tuple[str, str]:
    """(PASS | FAIL | INVALID, detail). INVALID: the window was not on top, or
    did not hold the focus, so nothing was judged and no input was sent."""
    work = Path(tempfile.mkdtemp(prefix=f"zb-real-screen-{case.name}-"))
    try:
        page = work / "page.html"
        page.write_text(FIXTURE_HTML)
        env = case_env(dict(os.environ), work, case.env)
        argv = [case.binary or default_bin, "--profile-dir", str(work / "profile"),
                "--agent-drawer", "on" if case.drawer else "off", *case.args, url or page.as_uri()]
        log = (out / f"{case.name}.stderr.txt").open("wb")
        log.write(("argv: " + " ".join(argv) + "\nrender env: " + repr({k: v for k, v in env.items() if k in RENDER_ENV})
                   + "\n").encode())
        log.flush()
        try:
            proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as err:
            log.close()
            return FAIL, f"cannot start {argv[0]}: {err.strerror}"
        try:
            deadline = time.monotonic() + 30
            wid = None
            while wid is None and time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.5)
                wid = our_window(proc.pid)
            if wid is None:
                return FAIL, f"no window (browser exit {proc.poll()})"
            x11 = X11()
            try:
                if not raise_window(x11, wid) and not (ensure_active(x11, wid) and raise_window(x11, wid, tries=1)):
                    return INVALID, "the window stayed covered or inactive: nothing judged, no input sent"
                time.sleep(settle)
                x, y, w, h = geometry(wid)
                crop = (x, y, w, h)
                window, screen = capture_both(wid, out, case.name)
                if x < 0 or y < 0 or x + w > screen.width or y + h > screen.height or (window.width, window.height) != (w, h):
                    return INVALID, (f"window {w}x{h}+{x}+{y} is not wholly on the {screen.width}x{screen.height} screen "
                                     f"(window capture {window.width}x{window.height}): move it and run again")
                covered = covered_points(wid, crop, x11.path_at)
                if covered:
                    return INVALID, f"covered at {covered[:3]} when captured: nothing judged"
                ok, detail = judge_page(window, screen, crop, case.icon, url is not None)
                detail = f"{w}x{h}+{x}+{y}: {detail}"
                if not ok or not case.open_drawer:
                    return (PASS if ok else FAIL), detail
                centre = icon_centre(screen, crop)
                if centre is None:
                    return FAIL, detail + "; no icon on screen to click"
                if not ensure_active(x11, wid):
                    return INVALID, detail + "; our window did not become active: no input sent"
                refused = safe_click(x11, wid, *centre)
                if refused:
                    return INVALID, detail + f"; click refused: {refused}"
                # The open drawer, twice, a second apart: it must draw and stay drawn.
                for sample in (1, 2):
                    time.sleep(settle if sample == 1 else 1.0)
                    window, screen = capture_both(wid, out, f"{case.name}.open{sample}", crop)
                    covered = covered_points(wid, crop, x11.path_at)
                    if covered:
                        return INVALID, detail + f"; covered at {covered[:3]} while open"
                    ok, opened = judge_open(window, screen, crop, url is not None)
                    detail += f"; open #{sample} {opened}"
                    if not ok:
                        return FAIL, detail
                refused = safe_escape(x11, wid)
                if refused:
                    return INVALID, detail + f"; Escape refused: {refused}"
                time.sleep(settle)
                window, screen = capture_both(wid, out, f"{case.name}.minimized", crop)
                ok, closed = judge(window, screen, crop, True)
                return (PASS if ok else FAIL), detail + "; minimized " + closed
            finally:
                x11.close()
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            log.close()
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --- the long-run case (chat-drawer plan S5.6, rev 16.20.10 and 16.20.11) ----------

LONG_RUN = [  # (case, prompt, the reply the fake API gives it)
    ("long-run-unbroken", "long", "y" * (200 * 1024)),
    ("long-run-words", "words", "word " * (200 * 1024 // 5)),
]
LONG_RUN_TOKEN = "sk-ant-oat01-REALSCREEN-not-a-real-token-0123"  # the setup-token shape, not a token
FOLD_MAX_S = 1.0


class LongRunBrowser:
    """The built binary on $DISPLAY with a throwaway agent home and the local fake API;
    its `--e2e-protocol` rows are read from its stdout."""

    def __init__(self, binary: str, work: Path, out: Path) -> None:
        import threading
        import agent_host_lifecycle_test as life
        import agent_setup_test
        from agent_common import host_python, parse_row
        from agent_hook_net import HookNetDecoys
        from fake_anthropic_api import FakeAnthropicApi, make_test_cert

        self.parse_row, self.rows, self.lines = parse_row, [], []
        self.proc = self.api = self.decoys = None
        agent_setup_test.PYTHON = host_python()
        self.world = agent_setup_test.World(work, "long-run")  # its own HOME, data and PATH
        rc, _out, err, _events, _seen = agent_setup_test.run_setup(Path(binary), self.world)
        if rc != 0:
            raise RuntimeError(f"--agent-setup failed: {err.strip()[-300:]}")
        secrets = self.world.agent / "secrets"
        secrets.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(secrets / "claude-token", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, LONG_RUN_TOKEN.encode())
        os.close(fd)
        replies = {prompt: reply for _case, prompt, reply in LONG_RUN}

        def respond(request, index):
            users = [m for m in (request.get("body") or {}).get("messages") or [] if m.get("role") == "user"]
            content = users[-1].get("content") if users else ""
            said = content if isinstance(content, str) else " ".join(
                b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")
            return {"text": next((reply for prompt, reply in replies.items() if prompt in said), "A reply")}

        cert, key = make_test_cert(work / "cert")
        self.api = FakeAnthropicApi(responder=respond, tls=(cert, key))
        self.api.start()
        self.decoys = HookNetDecoys()  # the agent's hooks reach these, never a real service
        seams = {"ZIGBROWSER_AGENT_NET_TEST": " ".join([
                     f"--test-allow fake.zb.invalid={self.api.port}",
                     f"--test-bridge 51091={self.decoys.bridges[51091].port}",
                     f"--test-bridge 31337={self.decoys.bridges[31337].port}"]),
                 "ZIGBROWSER_AGENT_NET_TEST_CA": str(cert),
                 "ZIGBROWSER_AGENT_TEST_BASE_URL": "https://fake.zb.invalid"}
        runtime = work / "run"
        runtime.mkdir(mode=0o700)
        env = life.env_for(self.world, runtime, seams, hostile=False)
        for name in RENDER_ENV:
            env.pop(name, None)
        self.env = env
        page = work / "page.html"
        page.write_text(FIXTURE_HTML)
        self.argv = [binary, "--profile-dir", str(work / "profile"), "--agent-drawer", "on",
                     "--agent-secret-store", "file", "--media-source", "off", "--e2e-protocol", page.as_uri()]
        self.err = (out / "long-run.stderr.txt").open("wb")
        self.err.write(("argv: " + " ".join(self.argv) + "\n").encode())
        self.err.flush()
        self.proc = subprocess.Popen(self.argv, env=env, stdout=subprocess.PIPE, stderr=self.err,
                                     start_new_session=True, text=True)

        def read() -> None:
            for line in self.proc.stdout:
                self.lines.append(line)
                try:
                    self.rows.append(self.parse_row(line.rstrip("\n")))
                except Exception:  # noqa: BLE001 - not a DRAWER row
                    pass
        threading.Thread(target=read, daemon=True).start()

    def of(self, kind: str) -> list:
        return [r for r in list(self.rows) if r.kind == kind and r.win == 1]

    def wait(self, predicate, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            if self.proc.poll() is not None:
                return bool(predicate())
            time.sleep(0.02)
        return bool(predicate())

    def close(self, out: Path) -> None:
        if self.proc is not None:
            if self.proc.poll() is None:
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                    self.proc.wait()
            (out / "long-run.rows.txt").write_text("".join(self.lines))
            self.err.close()
        if self.api is not None:
            self.api.stop()
        if self.decoys is not None:
            self.decoys.close()


def clipboard_env(home: Path) -> dict[str, str]:
    env = {"PATH": "/usr/bin:/bin", "DISPLAY": os.environ["DISPLAY"], "HOME": str(home), "LANG": "C.UTF-8",
           "NO_AT_BRIDGE": "1"}
    if os.environ.get("XAUTHORITY"):
        env["XAUTHORITY"] = os.environ["XAUTHORITY"]
    return env


def read_clipboard(home: Path) -> str | None:
    import ast
    from agent_drawer_copy_test import CLIPBOARD_READ
    done = subprocess.run(["/usr/bin/python3", "-c", CLIPBOARD_READ], env=clipboard_env(home),
                          capture_output=True, text=True, timeout=20)
    try:
        return ast.literal_eval(done.stdout.strip())
    except (SyntaxError, ValueError):
        return None


def describe(text: str | None) -> str:
    """A bounded description: never the whole reply."""
    if text is None:
        return "nothing"
    return f"{len(text)} characters, {text.count(chr(10))} line feeds, {text[:6]!r}...{text[-6:]!r}"


def run_long_run(binary: str, out: Path, settle: float) -> list[tuple[str, str, str]]:
    """(PASS | FAIL | INVALID, case, detail) for each LONG_RUN reply. Every click and key
    goes through safe_click or safe_key; a refused one stops the run (INVALID)."""
    from agent_drawer_copy_test import CLIPBOARD_OWNER, DECOY

    work = Path(tempfile.mkdtemp(prefix="zb-real-screen-long-run-"))
    results: list[tuple[str, str, str]] = []
    b = None
    try:
        b = LongRunBrowser(binary, work, out)
        deadline, wid = time.monotonic() + 30, None
        while wid is None and time.monotonic() < deadline and b.proc.poll() is None:
            time.sleep(0.5)
            wid = our_window(b.proc.pid)
        if wid is None:
            return [(FAIL, "long-run", f"no window (browser exit {b.proc.poll()})")]
        x11 = X11()
        try:
            if not raise_window(x11, wid) and not (ensure_active(x11, wid) and raise_window(x11, wid, tries=1)):
                return [(INVALID, "long-run", "the window stayed covered or inactive: nothing judged, no input sent")]
            time.sleep(settle)

            def origin() -> tuple[int, int]:
                gx, gy, _w, _h = geometry(wid)
                return gx, gy

            def click(rect: tuple[int, int, int, int], what: str) -> None:
                """`rect` in the window's coordinates."""
                if not ensure_active(x11, wid):
                    raise Refused(f"click on {what} refused: our window did not become active; no input sent")
                at = origin()
                point = screen_point(rect, at)
                refused = safe_click(x11, wid, *point)
                if refused:
                    raise Refused(f"click on {what} at {point} (window at {at}) refused: {refused}")

            def key(keysym: int, modifiers: tuple[int, ...] = (), what: str = "a key") -> None:
                if not ensure_active(x11, wid):
                    raise Refused(f"{what} refused: our window did not become active; no input sent")
                refused = safe_key(x11, wid, keysym, modifiers)
                if refused:
                    raise Refused(f"{what} refused: {refused}")

            def control(kind: str) -> tuple[int, int, int, int]:
                """The drawer's `kind` where it is drawn now (drawn_now); never a row's place."""
                now = drawn_now(b, kind)
                if now is None:
                    named = b.of(kind)[-1].rect() if b.of(kind) else None
                    raise Refused(f"the drawer's {kind} {named} is not drawn in the windows rows: no input sent")
                return now

            def reopen() -> bool:
                opened = len(b.of("open"))
                click(control("icon"), "the icon")
                return b.wait(lambda: len(b.of("open")) > opened, 10)

            if not b.wait(lambda: b.of("icon") != [], 30):
                return [(FAIL, "long-run", "no icon row")]
            if not reopen():
                return [(FAIL, "long-run", "the drawer did not open")]
            for n, (case, prompt, reply) in enumerate(LONG_RUN):
                if n > 0:  # the copy's click left the focus in a bubble: fold and reopen focus the input
                    minimized = len(b.of("minimized"))
                    click(control("minus"), "'-'")
                    if not (b.wait(lambda: len(b.of("minimized")) > minimized, 10) and reopen()):
                        results.append((FAIL, case, "the drawer did not fold and reopen before the prompt"))
                        continue
                answered = len([r for r in b.of("msg") if r.fields[0] == "assistant"])
                for ch in prompt:
                    key(ord(ch), what=f"typing {prompt!r}")
                key(KEY_RETURN, what="Enter")
                if not b.wait(lambda: len([r for r in b.of("msg") if r.fields[0] == "assistant"]) > answered, 120):
                    results.append((FAIL, case, f"no reply within 120 s ({describe(None)})"))
                    continue
                shown = [r for r in b.of("msg") if r.fields[0] == "assistant"][-1].fields[1]
                if not reply.startswith(shown.rstrip("…")[:64]):
                    results.append((FAIL, case, f"the reply shown is not the fake's: {shown[:40]!r}"))
                    continue
                # '-' at once: the drawer folds within FOLD_MAX_S of the click.
                minimized = len(b.of("minimized"))
                started = time.monotonic()
                click(control("minus"), "'-'")
                folded = b.wait(lambda: len(b.of("minimized")) > minimized, 30)
                took = time.monotonic() - started
                window, screen = capture_both(wid, out, f"{case}.folded")
                if not folded or took > FOLD_MAX_S:
                    results.append((FAIL, case, f"shown, but '-' folded {'in %.2f s' % took if folded else 'never'} "
                                                f"(at most {FOLD_MAX_S} s)"))
                    continue
                if not reopen():
                    results.append((FAIL, case, "the drawer did not reopen"))
                    continue
                time.sleep(1.0)
                text_rows = [r for r in b.of("textrect") if r.fields[0] == "assistant"]
                opened = control("open")
                rect = tuple(int(v) for v in text_rows[-1].fields[1].split(",")) if text_rows else None
                point = reply_point(rect, opened, origin()) if rect else None
                if point is None:
                    results.append((FAIL, case, f"the reply's text is not visible in the drawer ({rect}, {opened})"))
                    continue
                owner = subprocess.Popen(["/usr/bin/python3", "-c", CLIPBOARD_OWNER, DECOY],
                                         env=clipboard_env(b.world.home), stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True)
                try:
                    owner.stdout.readline()
                    decoy = read_clipboard(b.world.home) == DECOY
                    click((point[0], point[1], 1, 1), "the reply")
                    time.sleep(0.6)
                    key(ord("a"), (KEY_CONTROL_L,), "Ctrl+A")
                    time.sleep(0.3)
                    key(ord("c"), (KEY_CONTROL_L,), "Ctrl+C")
                    time.sleep(0.5)
                    got = read_clipboard(b.world.home)
                finally:
                    owner.kill()
                    owner.wait()
                window, screen = capture_both(wid, out, f"{case}.copied")
                if decoy and got == reply:
                    results.append((PASS, case, f"shown ({describe(shown)} in its row), folded in {took:.2f} s, "
                                                f"copied exactly {len(reply)} characters"))
                else:
                    results.append((FAIL, case, f"copy: want {describe(reply)}, got {describe(got)} "
                                                f"(the decoy owned the clipboard first: {decoy})"))
            return results
        except Refused as stop:
            return results + [(INVALID, "long-run", f"{stop}; nothing more sent")]
        finally:
            x11.close()
    finally:
        if b is not None:
            b.close(out)
        shutil.rmtree(work, ignore_errors=True)


class Refused(Exception):
    """An input the safety check refused: the run stops, and nothing more is sent."""


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--confirm-user-permission", action="store_true",
                    help="required: the user allowed this run on this display")
    ap.add_argument("--bin", default=str(REPO / "zig-out" / "bin" / "zigBrowser"))
    ap.add_argument("--out", required=True, help="a new or empty directory for the PNGs and logs")
    ap.add_argument("--matrix", action="store_true", help="also run the rendering experiment cases")
    ap.add_argument("--variant", action="append", default=[], metavar="NAME=PATH",
                    help="also run a drawer-on case with another build")
    ap.add_argument("--variant-page-only", action="append", default=[], metavar="NAME=PATH",
                    help="like --variant, for a build that draws no icon: only the page is checked")
    ap.add_argument("--settle", type=float, default=4.0, help="seconds between the window appearing and capture")
    ap.add_argument("--case", choices=["long-run"],
                    help="run only this case: long-run is S5.6's 200 KiB replies (with no spaces, then words) "
                         "from a local fake API in a throwaway agent home; each must show, fold within 1 s and "
                         "copy exactly with a click, Ctrl+A and Ctrl+C")
    ap.add_argument("--url", help="load this page instead of the fixture (for example the page the user saw blank); "
                                  "then a page is drawn when no single colour covers 90%% of it")
    args = ap.parse_args(argv)
    if not args.confirm_user_permission:
        print("refusing: run only on the user's screen with their permission (--confirm-user-permission)",
              file=sys.stderr)
        return 2
    if not os.environ.get("DISPLAY"):
        print("refusing: DISPLAY is not set", file=sys.stderr)
        return 2
    variants: dict[str, list[tuple[str, str]]] = {"variant": [], "variant_page_only": []}
    for key, items in variants.items():
        for item in getattr(args, key):
            name, sep, path = item.partition("=")
            if not sep or not name or not path:
                print(f"bad --{key.replace('_', '-')} {item!r}: want NAME=PATH", file=sys.stderr)
                return 2
            items.append((name, path))
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        print(f"refusing: {out} is not empty", file=sys.stderr)
        return 2
    glx = shutil.which("glxinfo")
    if glx:
        info = subprocess.run([glx, "-B"], capture_output=True, text=True, timeout=30)
        (out / "glxinfo.txt").write_text(info.stdout + info.stderr)
    print("Keep the screen free while this runs: each window is raised, and the screen under it is captured.",
          flush=True)
    if args.case == "long-run":
        print("long-run types two prompts into the drawer and replaces the clipboard's contents.", flush=True)
        results = run_long_run(args.bin, out, args.settle)
        for status, name, detail in results:
            print(f"{status:<7} {name:<22} {detail}", flush=True)
        statuses = [status for status, _name, _detail in results]
        print(f"{statuses.count(FAIL)} failed, {statuses.count(INVALID)} invalid; captures and logs in {out}")
        if INVALID in statuses:
            return 3
        return 0 if statuses.count(PASS) == len(LONG_RUN) else 1
    tally = {PASS: 0, FAIL: 0, INVALID: 0}
    statuses: dict[str, str] = {}
    for case in cases(args.matrix, variants["variant"], variants["variant_page_only"]):
        status, detail = run_case(case, args.bin, out, args.settle, args.url)
        tally[status] += 1
        statuses[case.name] = status
        control = CONTROLS.get(case.name)
        if control and statuses.get(control) not in (None, PASS):
            detail += f"; NOT DIAGNOSTIC: its control {control} did not pass, so this fails without the drawer too"
        print(f"{status:<7} {case.name:<22} {detail}  ({case.note})", flush=True)
        if status == INVALID and " refused: " in detail:
            print("STOPPED: an input was refused, so no further case runs. Nothing was sent to another window.",
                  flush=True)
            return 3
        if case.name == "drawer-off" and status != PASS:
            print("INVALID RUN: the drawer-off control did not pass, so the capture itself is not trusted "
                  "(a covered window, or a broken build). Fix that and run again.", flush=True)
            return 3
    print(f"{tally[FAIL]} failed, {tally[INVALID]} invalid (covered or unfocused: not judged, no input sent); "
          f"captures and logs in {out}")
    return 1 if tally[FAIL] else 3 if tally[INVALID] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
