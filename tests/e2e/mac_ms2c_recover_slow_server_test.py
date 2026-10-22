#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.55, plan R30-MS2 row 4) — a recovered window whose server stays
down past the 15 s load timer must NOT quit the macOS browser.

page.recover phase 2 swaps a fresh WKWebView into the frozen window and reloads the committed URL through
`loadURI:` (wkwebview_shim.m recoverByReplacingWebView). `loadURI:` arms the 15 s user-load timer, and its
expiry calls `requestExit:ZB_EXIT_TIMEOUT` (onNavigationTimeout:), so a recovery on a slow or down server
ends the whole session. Fix (plan): recovery reloads use the tagged/routed path with no exit timer.

The server here accepts the recovery reload's request and never answers it (it "stays down" for the test),
so only the timer can end the load. Target step: `ms2c-gate` (TO BE ADDED by bd 4pa.62); until the green
this file is in no gate script and no build.zig step.

Failing assertion today (Mac): at t = 20 s after phase 2, `proc.poll() is None` (the process has exited
with ZB_EXIT_TIMEOUT at ~15 s).
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

DOWN_FOR_SEC = 20.0  # longer than the shim's 15 s ZB_NAVIGATION_TIMEOUT_SECONDS
PAGE = b"""<!doctype html><html><head><meta charset='utf-8'><title>R</title></head><body><h1>R</h1>
<script>function freeze(){ setTimeout(function(){ while(true){} }, 100); }</script></body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    """Serves PAGE until `hang` is set; then every request is held open with no reply until `stop`."""

    def __init__(self):
        self.hang = threading.Event()
        self.stop = threading.Event()
        self.held = 0
        fixture = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if fixture.hang.is_set():
                    fixture.held += 1
                    while not fixture.stop.wait(0.05):
                        pass
                    return  # never answered
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(PAGE)))
                self.end_headers()
                self.wfile.write(PAGE)

            def log_message(self, *a):
                pass

        self._srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self._srv.daemon_threads = True
        self.base_url = f"http://127.0.0.1:{self._srv.server_address[1]}"

    def __enter__(self):
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *a):
        self.stop.set()
        self._srv.shutdown()
        self._srv.server_close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=30.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2c-recover-slow-server-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    checked_alive = False

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-slow-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
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

        def responsive():
            pages = (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []
            return pages[0].get("responsive") if pages else None

        try:
            rpc = RpcClient(socket_path, args.timeout_sec)
            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.raw("page.evaluate", {"expression": "freeze()"})
            end = time.monotonic() + 6.0
            while time.monotonic() < end and responsive() is not False:
                time.sleep(0.1)
            if responsive() is not False:
                raise AssertionError("PRECONDITION the watchdog did not report the frozen window unresponsive")

            fixture.hang.set()  # the server is "down" for the recovery reload from here on
            r1 = rpc.raw("page.recover", {"window_id": "window-1"})
            incident = (r1.get("result") or {}).get("incident")
            if "error" in r1 or not incident:
                raise AssertionError(f"PRECONDITION recover phase 1 offered no incident: {r1!r}")
            r2 = rpc.raw("page.recover", {"window_id": "window-1", "incident": incident, "acknowledge": ["window-1"]})
            t0 = time.monotonic()
            rec = (r2.get("result") or {}).get("recovered") or []
            w1 = next((r for r in rec if r.get("window_id") == "window-1"), None)
            if "error" in r2 or w1 is None or not w1.get("reloaded"):
                raise AssertionError(f"PRECONDITION recover phase 2 did not reload window-1: {r2!r}")

            while time.monotonic() - t0 < DOWN_FOR_SEC:
                if proc.poll() is not None:
                    break
                time.sleep(0.1)
            elapsed = time.monotonic() - t0
            checked_alive = True
            rc = proc.poll()
            if rc is not None:
                failures.append(f"the browser exited (rc={rc}) {elapsed:.1f}s after a recovery reload "
                                f"on a server that stayed down (held requests={fixture.held})")
            else:
                health = rpc.raw("page.health", {})
                if "error" in health or not (health.get("result") or {}).get("pages"):
                    failures.append(f"page.health did not answer at t={elapsed:.1f}s: {health!r}")
            if fixture.held < 1:
                failures.append("PRECONDITION the recovery reload never reached the down server")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{exc!r} (rc={proc.poll()})")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if not checked_alive and not failures:
        failures.append("the liveness assertion never ran")  # rule 7
    if failures:
        print("FAIL\tms2c-recover-slow-server")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-recover-slow-server")
    return 0


if __name__ == "__main__":
    sys.exit(main())
