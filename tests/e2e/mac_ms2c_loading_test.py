#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.health reports real PER-WINDOW loading state (RoseCat 6508 #4).

The shim must emit each window's actual WKWebView load state, not a constant. A window driven into a slow
navigation reports loading=true while a sibling window stays loading=false; once the slow load completes
the first returns to loading=false. On a build that omits loading (the port then defaults every window to
false) the navigating window never shows loading=true — the red.
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
SLOW_SECONDS = 4.0
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Load</title></head><body>idle
<script>function openPopup(){ window.open(location.href.split('?')[0] + '?popup', '_blank'); }</script>
</body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        html = FIXTURE

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/slow"):
                    time.sleep(SLOW_SECONDS)  # hold the response open so the navigating window stays loading
                    body = b"<!doctype html><title>slow</title>done"
                else:
                    body = html
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-loading-") as tmp:
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

        def health():
            return (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []

        def by_suffix(ps, q):
            return next((p for p in ps if (p.get("url") or "").endswith(q)), None)

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-loading-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            # A sibling popup that stays idle. Wait for its OWN initial load to finish (loading=false) before
            # the slow nav, else its still-committing initial load would (correctly) show loading=true.
            rpc.raw("page.evaluate", {"expression": "openPopup()"})
            end = time.monotonic() + 8.0
            popup_id = None
            while time.monotonic() < end:
                p = by_suffix(health(), "?popup")
                if p is not None and p.get("loading") is False:
                    popup_id = p["window_id"]
                    break
                time.sleep(0.05)
            if popup_id is None:
                failures.append("sibling popup never finished its initial load (or never appeared)")

            # Drive the PRIMARY into a slow navigation (location.href returns before the load completes).
            rpc.raw("page.evaluate", {"expression": "location.href='/slow'"})

            # Within the slow window, the primary must report loading=true while the sibling stays false.
            saw_primary_loading = False
            sibling_loading_leaked = False
            deadline = time.monotonic() + SLOW_SECONDS - 0.5
            while time.monotonic() < deadline:
                ps = health()
                primary = next((p for p in ps if (p.get("window_id") == "window-1")), None)
                if primary is not None and primary.get("loading") is True:
                    saw_primary_loading = True
                if popup_id is not None:
                    sib = next((p for p in ps if p.get("window_id") == popup_id), None)
                    if sib is not None and sib.get("loading") is True:
                        sibling_loading_leaked = True
                if saw_primary_loading:
                    break
                time.sleep(0.1)

            if not saw_primary_loading:
                failures.append("primary never reported loading=true during a slow navigation (loading omitted/constant?)")
            if sibling_loading_leaked:
                failures.append("idle sibling reported loading=true (loading not per-window)")

            # After the slow load completes, the primary returns to loading=false.
            settle = time.monotonic() + SLOW_SECONDS + 3.0
            cleared = False
            while time.monotonic() < settle:
                primary = next((p for p in health() if p.get("window_id") == "window-1"), None)
                if primary is not None and primary.get("loading") is False:
                    cleared = True
                    break
                time.sleep(0.1)
            if not cleared:
                failures.append("primary stuck at loading=true after the slow load finished")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-loading")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-loading")
    return 0


if __name__ == "__main__":
    sys.exit(main())
