#!/usr/bin/env python3
"""MS4.1a RED (unregistered) — load_serial: a per-window counter that increments on each load-commit.

The approval-grant contract binds load_serial and the broker revalidates it, so a navigation between
approve and commit revokes the grant. This groundwork slice only publishes the counter in page.list: each
real load-commit (didCommitNavigation) increments the window's load_serial, strictly monotonically. On a
build that never increments it, the counter stays flat — the red. (The broker that consumes it is MS4.1b,
gated on the plan review.)
"""
import argparse
import http.server
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Serial</title></head><body>x</body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        html = FIXTURE

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(html)

            def log_message(self, *a):
                pass

        self._srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self._srv.daemon_threads = True
        self.base_url = f"http://127.0.0.1:{self._srv.server_address[1]}"

    def __enter__(self):
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *a):
        self._srv.shutdown()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms4-serial-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def serial_of(method):
            pages = (rpc.raw(method, {}).get("result") or {}).get("pages") or []
            return (pages[0] or {}).get("load_serial") if pages else None

        def serial():
            # Both page.list and page.health must report the SAME per-window serial (same lock-backed snapshot).
            ls = serial_of("page.list")
            hs = serial_of("page.health")
            if ls != hs:
                failures.append(f"load_serial differs between page.list ({ls!r}) and page.health ({hs!r})")
            return ls

        def navigate_and_wait(url, prev):
            rpc.raw("page.navigate", {"url": url, "timeout_ms": 8000})
            end = time.monotonic() + 6.0
            while time.monotonic() < end:
                s = serial()
                if isinstance(s, int) and s > prev:
                    return s
                time.sleep(0.05)
            return serial()

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms4-load-serial-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            s0 = serial()
            if not isinstance(s0, int):
                failures.append(f"page.list did not report load_serial: {s0!r}")
            elif s0 < 1:
                failures.append(f"load_serial did not count the initial load-commit: {s0!r}")
            else:
                s1 = navigate_and_wait(f"{fixture.base_url}/?a", s0)
                if not (isinstance(s1, int) and s1 > s0):
                    failures.append(f"load_serial did not increment on a navigation: {s0!r} -> {s1!r}")
                else:
                    s2 = navigate_and_wait(f"{fixture.base_url}/?b", s1)
                    if not (isinstance(s2, int) and s2 > s1):
                        failures.append(f"load_serial did not increment on the next navigation: {s1!r} -> {s2!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms4-load-serial")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms4-load-serial")
    return 0


if __name__ == "__main__":
    sys.exit(main())
