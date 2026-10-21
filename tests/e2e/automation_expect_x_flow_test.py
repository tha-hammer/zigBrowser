#!/usr/bin/env python3
"""S8a red (chat-drawer plan, "S8 in detail" decision 2 for the X flows): an approved x.post's
phases on the REAL binary, through the Python SDK, on tests/fixtures/x/composer.html served
locally (never x.com).

- An approval matching the window (its origin and load_serial from page.list, and the
  compose_url the flow opens) posts once: the fixture records the text.
- An approval with a stale load_serial is -32015 load_serial_changed, and the flow requests
  nothing.
- An approval for another URL than the compose_url is -32015 unapproved_navigation, and nothing
  is requested.

Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import http.server
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import social_flows_test as social  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402
from zigbrowser.errors import ZigBrowserError  # noqa: E402

FIXTURE = HERE.parent / "fixtures/x/composer.html"


class ComposerServer:
    """Serves the X composer fixture at /composer.html; logs every requested path."""

    def __init__(self) -> None:
        self.paths: list[str] = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                outer.paths.append(self.path)
                if not self.path.startswith("/composer.html"):
                    self.send_error(404)
                    return
                body = FIXTURE.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self._server.server_address[1]}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def __enter__(self) -> "ComposerServer":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(5)


def window_one(zb: ZigBrowser) -> dict:
    return next(p for p in zb.page.list()["pages"] if p["window_id"] == "window-1")


def refused(fn) -> tuple:
    try:
        fn()
    except ZigBrowserError as err:
        data = getattr(err, "diagnostics", None) or getattr(err, "data", None) or {}
        return getattr(err, "code", None), data.get("reason")
    return None, None


def scenario(zb: ZigBrowser, server: ComposerServer) -> list[str]:
    passed: list[str] = []
    origin = server.origin
    compose = f"{origin}/composer.html?mode=compose"

    def approved_post(serial: int, url: str = compose, text: str = "approved post"):
        return zb.call("x.post", {
            "text": text, "compose_url": compose, "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial, "url": url}},
        })

    deadline = time.monotonic() + 15
    while window_one(zb)["load_serial"] < 1 and time.monotonic() < deadline:
        time.sleep(0.05)
    serial = window_one(zb)["load_serial"]
    if not isinstance(serial, int) or serial < 1:
        raise AssertionError(f"window-1 load_serial {serial!r}")
    social.expect_equal("approved post", approved_post(serial), {"ok": True})
    social.expect_equal("approved post recorded", zb.page.evaluate("window.__xResult && window.__xResult.text")["result"], "approved post")
    passed.append("approved-x-post")

    requests = len(server.paths)
    stale = window_one(zb)["load_serial"] - 1
    social.expect_equal("stale serial", refused(lambda: approved_post(stale)), (-32015, "load_serial_changed"))
    social.expect_equal("stale serial: nothing requested", len(server.paths), requests)
    passed.append("stale-serial-refused")

    other = f"{origin}/composer.html?mode=dialog"
    social.expect_equal("another url", refused(lambda: approved_post(window_one(zb)["load_serial"], other)), (-32015, "unapproved_navigation"))
    social.expect_equal("another url: nothing requested", len(server.paths), requests)
    passed.append("unapproved-navigation-refused")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (FIXTURE, "x fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with ComposerServer() as server, tempfile.TemporaryDirectory(prefix="zb-expect-x-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.origin}/composer.html?mode=home", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            social.wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                passed = scenario(zb, server)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\texpect-x-flow")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\texpect-x-flow")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
