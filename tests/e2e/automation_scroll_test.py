#!/usr/bin/env python3
"""N18 E2E: dom.scroll and dom.hover against the REAL binary, through the
Python SDK, on tests/fixtures/automation/scroll.html served locally.

The scroll oracle reads the page's offsets in the very next command after
dom.scroll returns: the answer and the page must already agree. Native
(real wheel) scrolling is covered by automation_native_ports_test.py.
Hover: synthetic events do not create CSS :hover; a native hover (plain and
humanized) does, as the menu's computed :hover style shows.
Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import http.server
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

FIXTURE = REPO / "tests/fixtures/automation/scroll.html"


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


def offsets(zb: ZigBrowser) -> dict:
    return page(zb, "({scrollX: window.scrollX, scrollY: window.scrollY})")


def far_in_view(zb: ZigBrowser) -> bool:
    return page(zb, "(() => { const r = document.getElementById('far').getBoundingClientRect();"
                    " const cy = r.top + r.height / 2; return cy >= 0 && cy < innerHeight; })()")


def reset(zb: ZigBrowser) -> None:
    page(zb, "(window.scrollTo(0, 0), window.__scroll.wheels.length = 0, window.__scroll.hovers.length = 0, true)")
    expect_equal("reset", offsets(zb), {"scrollX": 0, "scrollY": 0})


def synthetic(zb: ZigBrowser) -> list[str]:
    passed: list[str] = []
    reset(zb)
    answer = zb.dom.scroll(y=300)
    expect_equal("synthetic scroll by y answer", answer, {"scrollX": 0, "scrollY": 300})
    expect_equal("synthetic scroll by y page", offsets(zb), answer)
    passed.append("synthetic-scroll-by")

    reset(zb)
    answer = zb.dom.scroll("css=#far")
    if not far_in_view(zb):
        raise AssertionError("synthetic scroll to #far: not in view")
    expect_equal("synthetic scroll to #far answer matches page", offsets(zb), answer)
    expect_equal("synthetic scroll sends no wheel", page(zb, "window.__scroll.wheels"), [])
    passed.append("synthetic-scroll-to")

    reset(zb)
    expect_equal("synthetic hover", zb.dom.hover("css=#menu"), {})
    hovers = page(zb, "window.__scroll.hovers")
    for event in ("pointerover:false", "mouseover:false", "mousemove:false"):
        if event not in hovers:
            raise AssertionError(f"synthetic hover: {event} missing from {hovers}")
    expect_equal("synthetic hover does not create :hover", page(zb, "document.getElementById('menu').matches(':hover')"), False)
    passed.append("synthetic-hover")
    return passed


def native_hover(zb: ZigBrowser) -> list[str]:
    """A native hover moves the real pointer: CSS :hover applies."""
    menu_style = "getComputedStyle(document.getElementById('menu')).backgroundColor"
    reset(zb)
    expect_equal("menu before hover", page(zb, menu_style), "rgb(204, 204, 204)")
    expect_equal("native hover", zb.dom.hover("css=#menu", input="native"), {"ok": True})
    expect_equal("native hover: :hover", page(zb, "document.getElementById('menu').matches(':hover')"), True)
    expect_equal("native hover: :hover style", page(zb, menu_style), "rgb(0, 128, 0)")
    if "mousemove:true" not in page(zb, "window.__scroll.hovers"):
        raise AssertionError("native hover: no trusted mousemove on the menu")
    # Move off with a native hover elsewhere, then back with a humanized path.
    zb.dom.hover("css=#top", input="native")
    expect_equal("hover moved away", page(zb, "document.getElementById('menu').matches(':hover')"), False)
    expect_equal("humanized hover", zb.dom.hover("css=#menu", input="native", humanize=True), {"ok": True})
    expect_equal("humanized hover: :hover style", page(zb, menu_style), "rgb(0, 128, 0)")
    return ["native-hover"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (FIXTURE, "scroll fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-scroll-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.origin}/scroll", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                zb.dom.wait_for("css=#far", state="attached", timeout_ms=15000)
                passed = synthetic(zb) + native_hover(zb)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tautomation-scroll")
            eprint(f"error={exc!r}")
            proc.kill()
            proc.wait(timeout=5)
            return 1
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tautomation-scroll")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
