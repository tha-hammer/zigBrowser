#!/usr/bin/env python3
"""MS2b RED (unregistered) — a native click to a CHANGED document is refused (DOC_CHANGED), not delivered.

RoseCat 6253.2 / option (b): the documentToken guard must deliver NOTHING when the document the engine
located against is not the one about to receive the click. A real reload is masked by the engine's
relocate-recovery, so this uses the narrow e2e-gated hook ZB_DEBUG_STALE_TOKEN: the native-click guard
reads a fabricated stale token (a genuine mismatch) WITHOUT reloading — locate still succeeds, only the
guard sees a changed document, so the engine relocates and retries but the guard keeps refusing until
the deadline.

Oracle: dom.click (native) returns element_not_found / reason document_changed (code -32001), and the
click never reaches the page (window.__clicks == 0). A bridge with the guard removed would deliver the
click (dom.click ok, window.__clicks == 1) — the red. Unregistered (nativeClick is not final-gated until
the MS2b matrix).
"""
import argparse
import http.server
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>DocChanged</title></head><body>
<button id="btn" style="width:240px;height:90px">Click me</button>
<script>window.__clicks = 0;
  document.getElementById('btn').addEventListener('click', function () { window.__clicks += 1; });
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-docchg-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_STALE_TOKEN"] = "1"  # the native-click guard reads a stale token (gated on --e2e-protocol)
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
        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2b-doc-changed-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness

            resp = rpc.raw("dom.click", {"selector": "css=#btn", "options": {"input": "native", "timeout_ms": 4000}})
            if "error" not in resp:
                failures.append(f"dom.click (native) succeeded against a changed document: {resp.get('result')!r}")
            else:
                err_obj = resp["error"]
                reason = (err_obj.get("data") or {}).get("reason")
                if err_obj.get("code") != -32001 or reason != "document_changed":
                    failures.append(f"dom.click error was not element_not_found/document_changed(-32001): {err_obj}")

            # The click must NOT have reached the page.
            if rpc.evaluate("window.__clicks") != 0:
                failures.append("the click reached the page despite the document-token mismatch")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-doc-changed")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-doc-changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
