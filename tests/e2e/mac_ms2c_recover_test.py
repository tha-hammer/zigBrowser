#!/usr/bin/env python3
"""MS2c — page.recover on macOS: consent + VIEW-REPLACEMENT recovery through the public API.

page.recover is a two-phase watchdog flow. Phase 1 (consent): for a frozen window it returns an incident,
the at-risk windows and an expiry. Phase 2 (acknowledge) recovers the window — and because macOS WKWebView
has no public API to terminate a web process (private SPI is ruled out by the 2026-10-20 decision), recovery
is done by VIEW REPLACEMENT: the shim swaps a fresh WKWebView into the SAME window (keeping its stable id)
and reloads the committed URL. A frozen window's old (hung) process is abandoned, not killed, so `ended` is
false; `reloaded` is true. After phase 2 the window is responsive again on its original URL.

The window is frozen with a setTimeout infinite loop; the watchdog then reports it unresponsive, which is
what lets page.recover offer consent at all.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Recover</title></head><body>x
<script>function freeze(){ setTimeout(function(){ while(true){} }, 100); }</script></body></html>"""


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
    ap.add_argument("--timeout-sec", type=float, default=30.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-recover-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def responsive():
            pages = (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []
            return pages[0].get("responsive") if pages else None

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-recover-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.raw("page.evaluate", {"expression": "freeze()"})
            # The watchdog must report the window unresponsive before recover offers consent.
            end = time.monotonic() + 6.0
            while time.monotonic() < end and responsive() is not False:
                time.sleep(0.1)
            if responsive() is not False:
                failures.append("the watchdog did not report the frozen window unresponsive")

            # Phase 1: consent offer (server-side) — works on macOS.
            r1 = rpc.raw("page.recover", {"window_id": "window-1"})
            offer = r1.get("result")
            if "error" in r1 or not isinstance(offer, dict) or not offer.get("incident"):
                failures.append(f"recover consent (phase 1) did not offer an incident: {r1.get('error') or offer!r}")
                incident = None
            else:
                incident = offer.get("incident")
                if not offer.get("at_risk"):
                    failures.append(f"consent offer missing at_risk: {offer!r}")

            # Phase 2: acknowledge -> VIEW-REPLACEMENT recovery. The window is recovered (fresh WKWebView,
            # same id, committed URL reloaded) and becomes responsive again.
            if incident is not None:
                r2 = rpc.raw("page.recover", {"window_id": "window-1", "incident": incident, "acknowledge": ["window-1"]})
                if "error" in r2:
                    failures.append(f"recover phase 2 (view-replacement) errored: {r2['error']}")
                else:
                    rec = (r2.get("result") or {}).get("recovered") or []
                    w1 = next((r for r in rec if r.get("window_id") == "window-1"), None)
                    if w1 is None:
                        failures.append(f"phase 2 did not report window-1 recovered: {r2.get('result')!r}")
                    elif not w1.get("reloaded"):
                        failures.append(f"phase 2 did not reload window-1: {w1!r}")
                    elif w1.get("ended"):
                        failures.append(f"a frozen (not crashed) window reported ended=true: {w1!r}")
                    # The replaced view is a fresh web process: the window answers again.
                    end2 = time.monotonic() + 8.0
                    while time.monotonic() < end2 and responsive() is not True:
                        time.sleep(0.1)
                    if responsive() is not True:
                        failures.append("window did not become responsive after view-replacement recovery")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-recover")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-recover")
    return 0


if __name__ == "__main__":
    sys.exit(main())
