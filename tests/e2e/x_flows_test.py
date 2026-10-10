#!/usr/bin/env python3
"""N11 E2E: x.post / x.schedule_post / x.login_check against the real binary
on tests/fixtures/x/composer.html, served from a local HTTP server (never
x.com).

Asserts what the fixture recorded (window.__xResult): the exact text (the
restored stale draft is replaced, not appended to), the schedule dialog's
selected values, the Draft editor's event record, which Post button was
clicked (hidden copies are skipped, a late button is waited for), that a
racing page command waits for the whole flow (server handshake), and the
logged-out gate. Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import http.server
import json
import signal
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/x/composer.html"


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


class HoldServer:
    """Serves the X fixture over HTTP. GET /hold blocks until the test has
    sent the racing command, then answers; every request is logged in
    order so the test can check the racing page load came after /hold."""

    GRACE_SEC = 1.0

    def __init__(self) -> None:
        self.clicked = threading.Event()
        self.release = threading.Event()
        self._log: list[str] = []
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:  # quiet
                pass

            def do_GET(self) -> None:  # noqa: N802
                if self.path.startswith("/hold"):
                    outer.clicked.set()
                    outer.release.wait(60)
                    time.sleep(outer.GRACE_SEC)
                    outer._record("hold:answered")
                    body, kind = b"ok", "text/plain"
                elif self.path.startswith("/composer.html"):
                    if "marker=raced" in self.path:
                        outer._record("raced:requested")
                    body, kind = FIXTURE.read_bytes(), "text/html; charset=utf-8"
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.base = f"http://127.0.0.1:{self._server.server_address[1]}"

    def _record(self, event: str) -> None:
        with self._lock:
            self._log.append(event)

    def order(self) -> list[str]:
        with self._lock:
            return list(self._log)

    def __enter__(self) -> "HoldServer":
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc) -> None:
        self.release.set()
        self._server.shutdown()
        self._server.server_close()


def run_scenarios(socket_path: Path, server: HoldServer, timeout_sec: float) -> list[str]:
    passed: list[str] = []
    base = f"{server.base}/composer.html"
    rpc = RpcClient(socket_path, timeout_sec + 30)

    def recorded():
        return rpc.call("page.evaluate", {"expression": "window.__xResult"})["result"]

    # x.post replaces the restored draft and clicks the compose-page button.
    text = "hello from zigBrowser, café ✓"
    expect_equal("x.post", rpc.call("x.post", {"text": text, "compose_url": f"{base}?mode=compose"}), {"ok": True})
    expect_equal("posted text (stale draft replaced)", recorded(), {"text": text, "scheduled": None, "button": "tweetButton"})
    # Draft behaviour: one deletion clears the stale draft, then one cancelled
    # beforeinput per character owned by the editor's model; never a native
    # input event (that would mean the browser edited behind the editor).
    events = rpc.call("page.evaluate", {"expression": "window.__xEvents"})["result"]
    expect_equal("draft events", events, ["beforeinput:deleteContentBackward"] + ["beforeinput:insertText"] * len(text))
    expect_equal("toast", rpc.call("dom.getText", {"selector": "testid=toast"})["text"], "Your post was sent.")
    passed.append("x.post")

    expect_equal("x.login_check", rpc.call("x.login_check", {}), {"loggedIn": True, "platform": "x"})
    passed.append("x.login_check")

    # x.schedule_post drives the dialog's native selects (24h -> 12h).
    sched = rpc.call("x.schedule_post", {"text": "scheduled one", "date": "2026-11-05", "time": "14:07", "compose_url": f"{base}?mode=compose"})
    expect_equal("x.schedule_post", sched, {"ok": True, "scheduledFor": "2026-11-05T14:07"})
    expect_equal(
        "scheduled values",
        recorded(),
        {
            "text": "scheduled one",
            "scheduled": {"month": "11", "day": "5", "year": "2026", "hour": "2", "minute": "7", "ampm": "PM"},
            "button": "tweetButton",
        },
    )
    passed.append("x.schedule_post")

    # Timeline layout: two hidden tweetButton copies (display:none and
    # visibility:hidden with a real box) and an inline button that appears
    # late. Only the actionable inline button may be clicked.
    expect_equal("x.post home", rpc.call("x.post", {"text": "from the timeline", "compose_url": f"{base}?mode=home"}), {"ok": True})
    expect_equal("decoys skipped", recorded()["button"], "tweetButtonInline")
    passed.append("hidden-decoys+late-button")

    # One queue turn per flow, proven by a server handshake (no timestamps):
    # after the Post click, the fixture's toast waits for GET /hold. The
    # server answers /hold only after the racing client has sent
    # page.navigate to /composer.html?marker=raced (plus a grace that is
    # ample for an unqueued navigation to reach the server).
    # Serialized, the server must see /hold answered before the raced page
    # is requested, x.post succeeds, and the final URL is the raced one. A
    # navigation inside the flow would request the raced page while /hold is
    # still pending (and the toast would never appear).
    raced_url = f"{server.base}/composer.html?mode=compose&marker=raced"
    racer_result: dict[str, object] = {}

    def racer():
        other = RpcClient(socket_path, timeout_sec + 30)
        try:
            if not server.clicked.wait(timeout_sec + 30):
                racer_result["error"] = "the flow never reached the held step"
                return
            # Send without waiting, then let the server answer /hold.
            request = {"jsonrpc": "2.0", "method": "page.navigate", "id": 1, "params": {"url": raced_url}}
            if other.token:
                request["auth"] = other.token
            payload = json.dumps(request).encode("utf-8")
            other.sock.sendall(struct.pack(">I", len(payload)) + payload)
            server.release.set()
            length = struct.unpack(">I", other._recv_exact(4))[0]
            response = json.loads(other._recv_exact(length).decode("utf-8"))
            racer_result["navigate"] = response.get("result", response.get("error"))
        finally:
            server.release.set()
            other.close()

    t = threading.Thread(target=racer)
    t.start()
    compose = f"{server.base}/composer.html?mode=compose&hold={server.base}/hold"
    outcome = rpc.call("x.post", {"text": "no interleaving", "compose_url": compose})
    t.join(timeout=timeout_sec + 30)
    expect_equal("x.post racing", outcome, {"ok": True})
    expect_equal("racer", racer_result, {"navigate": {"ok": True}})
    expect_equal("server order", server.order(), ["hold:answered", "raced:requested"])
    expect_equal("navigation ran after the flow", rpc.call("page.url")["url"], raced_url)
    passed.append("single-queue-turn")

    # Logged-out page: login link, no composer -> -32011 logged_out, nothing posted.
    response = rpc.raw("x.post", {"text": "should not post", "compose_url": f"{base}?mode=loggedout"})
    error = response.get("error") or {}
    expect_equal("logged-out code", error.get("code"), -32011)
    expect_equal("logged-out reason", (error.get("data") or {}).get("reason"), "logged_out")
    expect_equal("nothing posted while logged out", recorded(), None)
    passed.append("logged-out-gate")

    rpc.close()
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary") or not require_file(FIXTURE, "x fixture"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with HoldServer() as server, tempfile.TemporaryDirectory(prefix="zb-x-flows-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.base}/composer.html?mode=compose", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stderr_lines: list[str] = []
        threading.Thread(target=_read_lines, args=(proc.stdout, []), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True).start()
        try:
            passed = run_scenarios(socket_path, server, args.timeout_sec)
        except Exception as exc:  # noqa: BLE001
            print("FAIL\tx-flows")
            eprint(f"error={exc!r}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1
        rc = terminate(proc)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tx-flows-clean-shutdown")
            eprint(f"return={rc}")
            return 1

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tx-flows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
