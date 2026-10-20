#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.health reports a frozen web process unresponsive (MS2c.2 watchdog).

WKWebView exposes no public is-web-process-responsive signal, so the macOS shim runs a JS-ping watchdog:
a ping left unanswered across a tick marks the window unresponsive, with unresponsive_ms growing and an
incident counted; a reply clears it. page.health surfaces {responsive, unresponsive_ms, incident} per
window (the server debounces by debounce_ms).

The fixture freezes its web process with an infinite loop scheduled by setTimeout (so the triggering
evaluate returns first). Oracle: after well past the debounce, page.health reports the primary window
responsive=false with unresponsive_ms >= debounce_ms and incident >= 1. On a build with no watchdog the
window stays responsive=true — the red. (page.health reads cached window state + watchdog counters only;
it does not run page script, so it answers even though the web process is frozen.)
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Health</title></head><body>
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
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-health-") as tmp:
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

        def health_primary():
            resp = rpc.raw("page.health", {})
            if "error" in resp:
                return None, resp["error"]
            result = resp.get("result") or {}
            pages = result.get("pages") or []
            primary = next((p for p in pages if p.get("window_id") == "window-1"), None)
            return (result, primary) if primary else (result, None)

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-health-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            # Healthy to start.
            result, primary = health_primary()
            if primary is None:
                failures.append(f"page.health did not report window-1: {result!r}")
            elif primary.get("responsive") is not True:
                failures.append(f"window-1 not responsive before the freeze: {primary!r}")
            debounce_ms = (result or {}).get("debounce_ms", 2000)

            # Freeze the web process (setTimeout so this evaluate returns first).
            rpc.raw("page.evaluate", {"expression": "freeze()"})
            # Wait well past the debounce so the watchdog has marked it unresponsive for >= debounce_ms.
            time.sleep((debounce_ms + 1800) / 1000.0)

            result, primary = health_primary()
            if primary is None:
                failures.append(f"page.health did not answer with the window frozen: {result!r}")
            else:
                if primary.get("responsive") is not False:
                    failures.append(f"frozen window still reported responsive: {primary!r}")
                ums = primary.get("unresponsive_ms")
                if not isinstance(ums, int) or ums < debounce_ms:
                    failures.append(f"unresponsive_ms {ums!r} < debounce_ms {debounce_ms} (watchdog not tracking)")
                # (incident is surfaced by page.recover, not page.health; the watchdog counts it for recover.)
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-health")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-health")
    return 0


if __name__ == "__main__":
    sys.exit(main())
