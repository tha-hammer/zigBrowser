#!/usr/bin/env python3
"""MS2c RED (unregistered) — script window.close() closes a popup; its opener survives, DOM intact (RoseCat 6508 #2).

A window.open popup is a real related window: WebKit wires it from the supplied configuration, so its
`window.opener` is live (the popup records that in its title). A script close — the opener calling
`popup.close()` — must actually close the popup (WKUIDelegate webViewDidClose:), and the opener must remain
open with its DOM intact and reachable. On a build with no webViewDidClose handler the popup stays open
(script close is a no-op); on one that builds the popup with a fresh (not WebKit-supplied) configuration
`window.opener` is null — both are reds.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>opener</title></head><body>
<div id="t">content</div>
<script>
  var P;
  function openPopup(){ P = window.open(location.href.split('?')[0] + '?popup', '_blank'); }
  function closePopup(){ if (P) P.close(); }
  if (location.search === '?popup') { document.title = window.opener ? 'HAS_OPENER' : 'NO_OPENER'; }
</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-sclose-") as tmp:
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

        def pages():
            return (rpc.raw("page.list", {}).get("result") or {}).get("pages") or []

        def by_q(ps, q):
            return next((w for w in ps if (w.get("url") or "").endswith("?" + q)), None)

        def wait_pages(n, deadline_s=6.0):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                p = pages()
                if len(p) == n:
                    return p
                time.sleep(0.05)
            return pages()

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-script-close-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.raw("page.evaluate", {"expression": "openPopup()"})
            # Wait for the popup to appear AND run its on-load script (title reflects window.opener).
            end = time.monotonic() + 8.0
            popup = None
            while time.monotonic() < end:
                popup = by_q(pages(), "popup")
                if popup is not None and popup.get("title") in ("HAS_OPENER", "NO_OPENER"):
                    break
                time.sleep(0.05)
            if popup is None or popup.get("title") not in ("HAS_OPENER", "NO_OPENER"):
                failures.append(f"popup never reported its opener state: {popup!r}")
            else:
                popup_id = popup["window_id"]
                if popup.get("opener_window_id") != "window-1":
                    failures.append(f"popup opener != primary: {popup.get('opener_window_id')!r}")
                # WebKit-supplied configuration: the popup is a real related window, window.opener is live.
                if popup.get("title") != "HAS_OPENER":
                    failures.append("popup's window.opener was null — popup not built from the WebKit-supplied configuration")

                # Script SELF-close: the popup runs window.close() in its OWN context (it was opened by
                # window.open, so this is allowed). Not the opener calling popup.close().
                rpc.raw("page.evaluate", {"window_id": popup_id, "expression": "window.close()"})
                left = wait_pages(1)
                if by_q(left, "popup") is not None or popup_id in [w.get("window_id") for w in left]:
                    failures.append(f"popup still open after its own window.close() (no webViewDidClose handler?): {left!r}")
                if [w.get("window_id") for w in left] != ["window-1"]:
                    failures.append(f"opener did not survive as the sole window after the popup self-closed: {left!r}")
                # Opener DOM intact and reachable after the popup's script close.
                r = rpc.raw("dom.getText", {"selector": "css=#t"})
                if "error" in r:
                    failures.append(f"opener DOM not reachable after the popup closed itself: {r['error']}")
                elif (r.get("result") or {}).get("text") != "content":
                    failures.append(f"opener DOM changed after the popup closed itself: {r.get('result')!r}")

                # Pin: the PRIMARY's own window.close() is IGNORED (browsers never let script close the main
                # window; webViewDidClose: refuses the primary).
                rpc.raw("page.evaluate", {"expression": "window.close()"})
                still = wait_pages(1)
                if [w.get("window_id") for w in still] != ["window-1"]:
                    failures.append(f"primary window.close() was not ignored (primary vanished): {still!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-script-close")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-script-close")
    return 0


if __name__ == "__main__":
    sys.exit(main())
