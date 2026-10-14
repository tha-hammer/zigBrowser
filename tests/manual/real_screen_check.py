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
            Case("on-renderer-default", True, ["--renderer", "default"], note="DMA-BUF GPU buffers, not SHM"),
            Case("on-renderer-mesa-egl", True, ["--renderer", "mesa-egl"], note="Mesa EGL instead of NVIDIA EGL"),
            Case("on-gdk-gl-disable", True, env={"GDK_GL": "disable"}, note="GDK paints the window without GL"),
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


def judge_open(window: Capture, screen: Capture, crop: tuple[int, int, int, int]) -> tuple[bool, str]:
    """The open drawer: the page above it and the panel, on the screen and
    in the window's buffer (the screen is the authority, as in judge)."""
    results = []
    for label, cap, box in (("screen", screen, crop), ("window", window, (0, 0, window.width, window.height))):
        area = max(1, box[2] * box[3])
        page = count(cap, box, PAGE_RGB) / area
        panel = count(cap, box, PANEL_RGB) / area
        ok = page >= OPEN_PAGE_MIN_FRACTION and panel >= OPEN_PANEL_MIN_FRACTION
        results.append((ok, f"open {label} page {page:.0%}, panel {panel:.0%}"))
    return all(ok for ok, _ in results), "; ".join(text for _, text in results)


def icon_centre(screen: Capture, crop: tuple[int, int, int, int]) -> tuple[int, int] | None:
    """The centre of the icon's colour on the screen, in root coordinates."""
    x0, y0, w, h = crop
    hits = [(x, y) for y in range(y0, y0 + h, 2) for x in range(x0, x0 + w, 2)
            if all(abs(screen.pixel(x, y)[i] - ICON_RGB[i]) <= TOLERANCE for i in range(3))]
    if len(hits) * 4 < ICON_MIN_PIXELS:
        return None
    return sum(x for x, _ in hits) // len(hits), sum(y for _, y in hits) // len(hits)


def xtest(action) -> None:
    """Runs action(x11, xtst, display) on a fresh connection to $DISPLAY.
    Used on our own window only: the caller found its target inside it."""
    import ctypes
    import ctypes.util

    xlib, xtst = ctypes.util.find_library("X11"), ctypes.util.find_library("Xtst")
    if xlib is None or xtst is None:
        raise RuntimeError("libX11 or libXtst is missing")
    x11, t = ctypes.CDLL(xlib), ctypes.CDLL(xtst)
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XKeysymToKeycode.restype = ctypes.c_ubyte
    x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    t.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
    t.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    t.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        raise RuntimeError("cannot open the display")
    try:
        action(x11, t, dpy)
    finally:
        x11.XCloseDisplay(dpy)


def click(x: int, y: int) -> None:
    """One left click at root x, y."""
    def act(x11, t, dpy):
        t.XTestFakeMotionEvent(dpy, -1, x, y, 0)
        x11.XSync(dpy, 0)
        time.sleep(0.2)
        for down in (1, 0):
            t.XTestFakeButtonEvent(dpy, 1, down, 0)
            x11.XSync(dpy, 0)
            time.sleep(0.05)
    xtest(act)


def press_escape() -> None:
    """Escape, to the focused window (ours: it was just clicked)."""
    def act(x11, t, dpy):
        code = x11.XKeysymToKeycode(dpy, 0xFF1B)
        for down in (1, 0):
            t.XTestFakeKeyEvent(dpy, code, down, 0)
            x11.XSync(dpy, 0)
            time.sleep(0.05)
    xtest(act)


def case_env(base: dict[str, str], work: Path, extra: dict[str, str]) -> dict[str, str]:
    """The shell's environment without rendering overrides, the browser's
    own variables or its socket; throwaway XDG directories; then the case's."""
    env = {k: v for k, v in base.items() if k not in RENDER_ENV and not k.startswith(("ZIGBROWSER_", "ZB_"))}
    for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
        env[name] = str(work / name.lower())
    env.update(extra)
    return env


def activate(wid: int) -> None:
    """Ask the window manager to raise and focus our window
    (_NET_ACTIVE_WINDOW), so the screen capture sees it, not what covers it."""
    import ctypes
    import ctypes.util

    path = ctypes.util.find_library("X11")
    if path is None:
        return
    x = ctypes.CDLL(path)
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XDefaultRootWindow.restype = ctypes.c_ulong
    x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x.XInternAtom.restype = ctypes.c_ulong
    x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
    x.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]

    class ClientMessage(ctypes.Structure):
        _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                    ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                    ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]

    dpy = x.XOpenDisplay(None)
    if not dpy:
        return
    try:
        root = x.XDefaultRootWindow(dpy)
        ev = ClientMessage(type=33, send_event=1, display=dpy, window=wid,
                           message_type=x.XInternAtom(dpy, b"_NET_ACTIVE_WINDOW", 0), format=32)
        ev.data[0], ev.data[1] = 2, 0  # source: a pager (direct user request); time: current
        x.XSendEvent(dpy, root, 0, (1 << 19) | (1 << 20), ctypes.byref(ev))  # SubstructureRedirect|Notify
        x.XRaiseWindow(dpy, wid)
        x.XSync(dpy, 0)
    finally:
        x.XCloseDisplay(dpy)


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


def run_case(case: Case, default_bin: str, out: Path, settle: float) -> tuple[bool, str]:
    work = Path(tempfile.mkdtemp(prefix=f"zb-real-screen-{case.name}-"))
    try:
        page = work / "page.html"
        page.write_text("<!doctype html><title>zb real screen check</title>"
                        "<style>html,body{margin:0;height:100%;background:#1e6fb4;color:#fff;"
                        "font:32px sans-serif}</style><body><p style='padding:40px'>zigBrowser real-screen check</p>")
        env = case_env(dict(os.environ), work, case.env)
        argv = [case.binary or default_bin, "--profile-dir", str(work / "profile"),
                "--agent-drawer", "on" if case.drawer else "off", *case.args, page.as_uri()]
        log = (out / f"{case.name}.stderr.txt").open("wb")
        log.write(("argv: " + " ".join(argv) + "\nrender env: " + repr({k: v for k, v in env.items() if k in RENDER_ENV})
                   + "\n").encode())
        log.flush()
        try:
            proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as err:
            log.close()
            return False, f"cannot start {argv[0]}: {err.strerror}"
        try:
            deadline = time.monotonic() + 30
            wid = None
            while wid is None and time.monotonic() < deadline and proc.poll() is None:
                time.sleep(0.5)
                wid = our_window(proc.pid)
            if wid is None:
                return False, f"no window (browser exit {proc.poll()})"
            activate(wid)
            time.sleep(settle)
            x, y, w, h = geometry(wid)
            window, screen = capture_both(wid, out, case.name)
            crop = (x, y, w, h)
            if x < 0 or y < 0 or x + w > screen.width or y + h > screen.height or (window.width, window.height) != (w, h):
                return False, (f"window {w}x{h}+{x}+{y} is not wholly on the {screen.width}x{screen.height} screen "
                               f"(window capture {window.width}x{window.height}): move it and run again")
            ok, detail = judge(window, screen, crop, case.icon)
            detail = f"{w}x{h}+{x}+{y}: {detail}"
            if not ok or not case.open_drawer:
                return ok, detail
            centre = icon_centre(screen, crop)
            if centre is None:
                return False, detail + "; no icon on screen to click"
            click(*centre)
            # The open drawer, twice, a second apart: it must draw and stay drawn.
            for sample in (1, 2):
                time.sleep(settle if sample == 1 else 1.0)
                window, screen = capture_both(wid, out, f"{case.name}.open{sample}", crop)
                ok, opened = judge_open(window, screen, crop)
                detail += f"; open #{sample} {opened}"
                if not ok:
                    return False, detail
            press_escape()
            time.sleep(settle)
            window, screen = capture_both(wid, out, f"{case.name}.minimized", crop)
            ok, closed = judge(window, screen, crop, True)
            return ok, detail + "; minimized " + closed
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
    failed = 0
    for case in cases(args.matrix, variants["variant"], variants["variant_page_only"]):
        ok, detail = run_case(case, args.bin, out, args.settle)
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {case.name:<22} {detail}  ({case.note})", flush=True)
        if case.name == "drawer-off" and not ok:
            print("INVALID RUN: the drawer-off control failed, so the capture itself is not trusted "
                  "(a covered window, or a broken build). Fix that and run again.", flush=True)
            return 3
    print(f"{failed} failed; captures and logs in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
