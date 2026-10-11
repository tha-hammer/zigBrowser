#!/usr/bin/env python3
"""PagePort v3.3/v3.4 E2E: page.screenshot, dom.setInputFiles and native
dom.scroll against the REAL binary (GTK adapter + shim), through the Python
SDK, on tests/fixtures/automation/ports.html served locally.

Asserts:
- page.screenshot returns a valid PNG whose size is the viewport in device
  pixels, with the fixture's solid red block at a known pixel;
- dom.setInputFiles makes the input fire `change` with the chosen file's
  name and size (single and multiple inputs);
- a missing path is refused with -32602 data.reason "bad_file" and the
  input is never clicked;
- native dom.scroll (by offset and to a selector) moves scrollY, as read in
  the very next command, with trusted wheel events.
Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import base64
import http.server
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402
from zigbrowser.errors import ProtocolError  # noqa: E402

FIXTURE = REPO / "tests/fixtures/automation/ports.html"


class FixtureServer:
    def __init__(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                body = FIXTURE.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self._server.server_address[1]}"

    def __enter__(self) -> "FixtureServer":
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc) -> None:
        self._server.shutdown()
        self._server.server_close()


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def wait_for_socket(path: Path, timeout_sec: float) -> None:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"socket {path} never appeared")


def page(zb: ZigBrowser, expression: str):
    return zb.page.evaluate(expression)["result"]


def decode_png(data: bytes) -> tuple[int, int, list[bytes], int]:
    """(width, height, rows, bytes per pixel) of an 8-bit RGB/RGBA PNG,
    checking the signature, every chunk CRC and the filters."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("screenshot is not a PNG (bad signature)")
    pos, idat, header = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        (crc,) = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
        if zlib.crc32(kind + body) & 0xFFFFFFFF != crc:
            raise AssertionError(f"PNG chunk {kind!r}: bad CRC")
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    if header is None:
        raise AssertionError("PNG without IHDR")
    width, height, depth, color, _, _, interlace = header
    if depth != 8 or color not in (2, 6) or interlace != 0:
        raise AssertionError(f"unexpected PNG format depth={depth} color={color} interlace={interlace}")
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows: list[bytes] = []
    prev = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        line = bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up = prev[i]
            up_left = prev[i - bpp] if i >= bpp else 0
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - up_left
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                pred = left if pa <= pb and pa <= pc else (up if pb <= pc else up_left)
                line[i] = (line[i] + pred) & 0xFF
            elif kind != 0:
                raise AssertionError(f"PNG row {y}: bad filter {kind}")
        rows.append(bytes(line))
        prev = line
    return width, height, rows, bpp


def screenshot(zb: ZigBrowser) -> list[str]:
    view = page(zb, "({w: innerWidth, h: innerHeight, dpr: devicePixelRatio})")
    shot = zb.page.screenshot()
    png = base64.b64decode(shot["data"], validate=True)
    width, height, rows, bpp = decode_png(png)
    expect_equal("screenshot width (answer = PNG)", shot["width"], width)
    expect_equal("screenshot height (answer = PNG)", shot["height"], height)
    expect_equal("screenshot width (viewport)", width, round(view["w"] * view["dpr"]))
    expect_equal("screenshot height (viewport)", height, round(view["h"] * view["dpr"]))
    x = y = int(50 * view["dpr"])
    pixel = tuple(rows[y][x * bpp:x * bpp + 3])
    if not (pixel[0] >= 245 and pixel[1] <= 10 and pixel[2] <= 10):
        raise AssertionError(f"pixel ({x},{y}) should be the fixture's red block, got {pixel}")
    white = tuple(rows[y][(width - 5) * bpp:(width - 5) * bpp + 3])
    if min(white) < 245:
        raise AssertionError(f"pixel ({width - 5},{y}) should be the white page, got {white}")
    eprint(f"screenshot {width}x{height}, {len(png)} bytes")
    return ["screenshot-png"]


def files(zb: ZigBrowser, tmp: Path) -> list[str]:
    passed: list[str] = []
    one = tmp / "zb-upload.txt"
    one.write_bytes(b"z" * 1234)
    two = tmp / "zb-photo.png"
    two.write_bytes(b"\x89PNG" + b"\0" * 96)

    answer = zb.dom.set_input_files("css=#f", [str(one)])
    expect_equal("single input answer", answer, {"multiple": False, "changed": True})
    changes = page(zb, "window.__ports.changes")
    expect_equal("single input change", changes, [{"id": "f", "trusted": True, "files": [{"name": "zb-upload.txt", "size": 1234}]}])
    passed.append("set-input-files")

    answer = zb.dom.set_input_files("css=#multi", [str(one), str(two)])
    expect_equal("multiple input answer", answer, {"multiple": True, "changed": True})
    last = page(zb, "window.__ports.changes")[-1]
    expect_equal("multiple input files", last["files"], [{"name": "zb-upload.txt", "size": 1234}, {"name": "zb-photo.png", "size": 100}])
    passed.append("set-input-files-multiple")

    clicks = page(zb, "window.__ports.clicks")
    changes_before = len(page(zb, "window.__ports.changes"))
    try:
        zb.dom.set_input_files("css=#f", [str(tmp / "missing.txt")])
    except ProtocolError as err:
        expect_equal("missing path code", err.code, -32602)
        expect_equal("missing path reason", err.data.get("reason"), "bad_file")
    else:
        raise AssertionError("a missing path was accepted")
    expect_equal("missing path: input never clicked", page(zb, "window.__ports.clicks"), clicks)
    expect_equal("missing path: no change", len(page(zb, "window.__ports.changes")), changes_before)
    passed.append("set-input-files-bad-path")
    return passed


def native_scroll(zb: ZigBrowser) -> list[str]:
    passed: list[str] = []
    page(zb, "(window.scrollTo(0, 0), window.__ports.wheels.length = 0, true)")
    answer = zb.dom.scroll(y=300, input="native")
    now = page(zb, "({scrollX: window.scrollX, scrollY: window.scrollY})")
    expect_equal("native scroll by: page right after the call", now, {"scrollX": answer["scrollX"], "scrollY": answer["scrollY"]})
    expect_equal("native scroll by: scrollY", now["scrollY"], 300)
    wheels = page(zb, "window.__ports.wheels")
    if not wheels or not all(wheels):
        raise AssertionError(f"native scroll by: trusted wheel events expected, got {wheels}")
    passed.append("native-scroll-by")

    page(zb, "(window.scrollTo(0, 0), window.__ports.wheels.length = 0, true)")
    answer = zb.dom.scroll("css=#far", input="native")
    state = page(zb, "(() => { const r = document.getElementById('far').getBoundingClientRect();"
                     " return {scrollY: window.scrollY, cy: r.top + r.height / 2, h: innerHeight}; })()")
    if not (0 <= state["cy"] < state["h"]):
        raise AssertionError(f"native scroll to #far: not in view right after the call: {state}")
    expect_equal("native scroll to #far: answer = page", answer["scrollY"], state["scrollY"])
    if state["scrollY"] <= 0:
        raise AssertionError("native scroll to #far: scrollY did not move")
    wheels = page(zb, "window.__ports.wheels")
    if not wheels or not all(wheels):
        raise AssertionError(f"native scroll to #far: trusted wheel events expected, got {wheels}")
    passed.append("native-scroll-to")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (FIXTURE, "ports fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-ports-") as tmp_name:
        tmp = Path(tmp_name)
        socket_path = tmp / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.origin}/ports", "--automation-api", "--profile-dir", str(tmp / "profile")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                zb.dom.wait_for("css=#far", state="attached", timeout_ms=15000)
                passed = screenshot(zb) + files(zb, tmp) + native_scroll(zb)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tautomation-native-ports")
            eprint(f"error={exc!r}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tautomation-native-ports")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
