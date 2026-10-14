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
  - with the drawer on, the icon colour must be present (the "S" icon is drawn).
It writes a PNG of every capture and the browser's stderr to --out, and
prints one line per case. Exit 0 only when every expected case passes.

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


class Case:
    def __init__(self, name: str, drawer: bool, args: list[str] | None = None, env: dict[str, str] | None = None,
                 binary: str | None = None, note: str = "", icon: bool | None = None) -> None:
        self.name, self.drawer, self.args, self.env = name, drawer, args or [], env or {}
        self.binary, self.note = binary, note
        self.icon = drawer if icon is None else icon  # whether the icon must be drawn


def cases(matrix: bool, variants: list[tuple[str, str]], page_only: list[tuple[str, str]]) -> list[Case]:
    out = [Case("drawer-off", False, note="control: the window without the drawer"),
           Case("drawer-on", True, note="the slice check: defaults plus --agent-drawer on")]
    if matrix:
        out += [
            Case("on-hw-never", True, ["--hardware-acceleration", "never"], note="no GPU compositing in WebKit"),
            Case("on-renderer-default", True, ["--renderer", "default"], note="DMA-BUF GPU buffers, not SHM"),
            Case("on-renderer-mesa-egl", True, ["--renderer", "mesa-egl"], note="Mesa EGL instead of NVIDIA EGL"),
            Case("on-gdk-gl-disable", True, env={"GDK_GL": "disable"}, note="GDK paints the window without GL"),
            Case("on-no-compositing", True, env={"WEBKIT_DISABLE_COMPOSITING_MODE": "1"}, note="WebKit without compositing"),
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
        env = dict(os.environ)
        env.pop("ZIGBROWSER_SOCKET", None)
        for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"):
            env[name] = str(work / name.lower())
        env.update(case.env)
        argv = [case.binary or default_bin, "--profile-dir", str(work / "profile"),
                "--agent-drawer", "on" if case.drawer else "off", *case.args, page.as_uri()]
        log = (out / f"{case.name}.stderr.txt").open("wb")
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
            time.sleep(settle)
            x, y, w, h = geometry(wid)
            window = xwd("-id", hex(wid))
            write_png(window, (0, 0, window.width, window.height), out / f"{case.name}.window.png")
            screen = xwd("-root")
            sx, sy = max(x, 0), max(y, 0)
            crop = (sx, sy, min(w, screen.width - sx), min(h, screen.height - sy))
            write_png(screen, crop, out / f"{case.name}.screen.png")
            box = (0, 0, window.width, window.height)
            page_px = count(window, box, PAGE_RGB)
            icon_px = count(window, box, ICON_RGB)
            fraction = page_px / max(1, window.width * window.height)
            ok = fraction >= PAGE_MIN_FRACTION and (not case.icon or icon_px >= ICON_MIN_PIXELS)
            return ok, f"page {fraction:.0%} of {window.width}x{window.height}, icon {icon_px} px"
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
    failed = 0
    for case in cases(args.matrix, variants["variant"], variants["variant_page_only"]):
        ok, detail = run_case(case, args.bin, out, args.settle)
        failed += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {case.name:<22} {detail}  ({case.note})", flush=True)
    print(f"{failed} failed; captures and logs in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
