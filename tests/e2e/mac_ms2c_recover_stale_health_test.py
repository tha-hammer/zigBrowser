#!/usr/bin/env python3
"""MS2c RED (unregistered) — a replaced view's late health reply must not touch the fresh view (RoseCat 6551 #2).

healthTick captures the view it pinged; its reply must be applied only if that view is STILL the window's
view. Otherwise a late reply from a view that recovery replaced can clear the fresh view's in-flight ping or
falsely mark the (frozen) replacement responsive.

Driven deterministically with the one-shot ZB_DEBUG_HEALTH_REPLY_HOLD_MS seam: only window-1's FIRST ping
reply is held, long enough that (1) it makes window-1 look unresponsive so recover can run, and (2) the held
reply lands AFTER the window has been recovered to a fresh view AND that fresh view has been frozen. With the
identity gate the stale reply is ignored and the frozen fresh view stays unresponsive; without it the stale
reply falsely marks the frozen view responsive — the red.
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
HOLD_MS = 12000  # comfortably longer than recover + freeze-fresh-view takes
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Stale</title></head><body>live
<script>function freeze(){ setTimeout(function(){ while(true){} }, 50); }</script></body></html>"""


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
    ap.add_argument("--timeout-sec", type=float, default=45.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-stale-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_HEALTH_REPLY_HOLD_MS"] = str(HOLD_MS)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def primary():
            pages = (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []
            return pages[0] if pages else None

        def wait_responsive(target, deadline_s):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                if (primary() or {}).get("responsive") is target:
                    return True
                time.sleep(0.1)
            return (primary() or {}).get("responsive") is target

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-recover-stale-health-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            t0 = time.monotonic()  # window-1's first (held) ping is issued right about now

            # (1) window-1 looks unresponsive because its first ping reply is held.
            if not wait_responsive(False, 6.0):
                failures.append("window-1 did not go unresponsive while its first ping reply was held")

            # (2) recover it to a fresh view.
            r1 = rpc.raw("page.recover", {"window_id": "window-1"})
            incident = (r1.get("result") or {}).get("incident")
            if "error" in r1 or not incident:
                failures.append(f"recover consent failed: {r1.get('error') or r1.get('result')!r}")
            else:
                r2 = rpc.raw("page.recover", {"window_id": "window-1", "incident": incident, "acknowledge": ["window-1"]})
                if "error" in r2:
                    failures.append(f"recover phase 2 errored: {r2['error']}")
            # The fresh view comes up responsive (its own pings are NOT held — one-shot).
            if not wait_responsive(True, 8.0):
                failures.append("fresh view never became responsive after recovery")

            # (3) freeze the fresh view -> genuinely unresponsive (its ping hangs, nothing to hold).
            rpc.raw("page.evaluate", {"expression": "freeze()"})
            if not wait_responsive(False, 6.0):
                failures.append("fresh view did not go unresponsive after freeze()")

            # (4) wait past the hold so window-1's STALE first-ping reply (from the replaced view) has fired.
            while time.monotonic() < t0 + (HOLD_MS / 1000.0) + 1.5:
                time.sleep(0.1)

            # The frozen fresh view must STILL be unresponsive: the stale reply was gated out by identity.
            end = time.monotonic() + 2.5
            flipped = False
            while time.monotonic() < end:
                if (primary() or {}).get("responsive") is True:
                    flipped = True
                    break
                time.sleep(0.1)
            if flipped:
                failures.append("a stale reply from the replaced view falsely marked the frozen fresh view responsive")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-recover-stale-health")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-recover-stale-health")
    return 0


if __name__ == "__main__":
    sys.exit(main())
