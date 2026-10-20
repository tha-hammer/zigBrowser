#!/usr/bin/env python3
"""MS2a.2 RED — automation.js lives in a PRIVATE WKContentWorld; a page-world spoof cannot change results.

The first document defines a HOSTILE, page-owned `window.__zbAutomation` at parse time (document-start,
before any load completes) whose `getText` lies, and re-defines it again after load. It also carries a known
DOM value. The metamorphic property: the page world sees only its OWN `__zbAutomation` (never the real
automation-world object), and `dom.getText` returns the REAL DOM value regardless of the spoof.

Production injects automation.js into a named private WKContentWorld at document-start
(src/wkwebview_shim.m). This test is GREEN on that mechanism; the failing-first evidence is the mutation:
inject automation.js into the PAGE world (or after first load) and these assertions red.

The test never calls the shim directly and never injects automation.js itself — it only drives the socket.
Runs ON a Mac (WKWebView needs the WindowServer); launched directly (no xvfb), own process group, killpg.
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
# Parse-time (document-start) hostile spoof + a known DOM value + a post-load re-spoof. If automation.js ever
# shared the page world, #heading would read the spoof's lie and #spy would see the real automation object.
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>PrivateWorld</title>
<script>
window.__zbAutomation = { getText: function(){ return "SPOOFED-BY-PAGE"; }, marker: "PAGE-SPOOF" };
</script></head><body>
<div id="heading">REAL-DOM-VALUE</div>
<div id="spy"></div>
<script>
// What the PAGE world sees as window.__zbAutomation: its own spoof (marker) if isolated; the real
// automation object (no marker) if automation.js leaked into the page world.
document.getElementById('spy').textContent =
  (window.__zbAutomation && window.__zbAutomation.marker) ? window.__zbAutomation.marker : "NO-MARKER-REAL-OBJECT";
window.__zbAutomation = { getText: function(){ return "RESPOOFED-AFTER-LOAD"; }, marker: "PAGE-RESPOOF" };
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2a-pw-") as tmp:
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

        def get_text(sel):
            r = rpc.raw("dom.getText", {"selector": sel, "options": {"timeout_ms": 8000}})
            if "error" in r:
                return None, r["error"]
            return (r.get("result") or {}).get("text"), None

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2a-private-world-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})

            # 1) The automation world reads the REAL DOM despite the page's parse-time + post-load spoof.
            heading, herr = get_text("css=#heading")
            if herr is not None:
                failures.append(f"dom.getText #heading errored: {herr}")
            elif heading != "REAL-DOM-VALUE":
                failures.append(f"dom.getText returned the page-world spoof, not the real DOM: {heading!r} "
                                f"(automation.js is not isolated in its own content world)")

            # 2) The PAGE world sees only its OWN __zbAutomation (the spoof marker), never the real
            #    automation-world object (which has no marker). #spy carries the page's view.
            spy, serr = get_text("css=#spy")
            if serr is not None:
                failures.append(f"dom.getText #spy errored: {serr}")
            elif spy != "PAGE-SPOOF":
                failures.append(f"the page world observed something other than its own spoof: {spy!r} "
                                f"(expected 'PAGE-SPOOF'; 'NO-MARKER-REAL-OBJECT' means the automation object leaked into the page world)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-private-world")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-private-world")
    return 0


if __name__ == "__main__":
    sys.exit(main())
