#!/usr/bin/env python3
"""MS2b RED (unregistered) — native typing re-checks the documentToken PER CHARACTER (RoseCat 6361.1).

nativeText must not send the suffix of a typed string into a REPLACEMENT document: if a character
navigates the page, the remaining characters must not land in the new document. The bridge re-checks
__zbAutomation.documentToken after each character (via the FIFO ack). This drives that with the e2e-gated
ZB_DEBUG_STALE_TOKEN=after:1 hook: the PREFLIGHT guard's token read passes (read #1), but the first
per-character RECHECK read (read #2) returns a stale token — as if the first character changed the
document — so typing stops with DOC_CHANGED and the suffix is not delivered.

Oracle: dom.type (native) returns element_not_found / reason document_changed (-32001) and the input is
NOT filled with the whole string. A build without the per-character recheck would type the whole string
(dom.type ok) — the red. Unregistered (nativeText is not final-gated until the MS2b matrix).
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>TextDocChanged</title></head><body>
<input id="inp" type="text"></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-textdc-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_STALE_TOKEN"] = "after:1"  # PREFLIGHT read ok; the first per-char recheck is stale
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
                print("FAIL\tms2b-text-doc-changed-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness
            resp = rpc.raw("dom.type", {"selector": "css=#inp", "text": "abcde", "options": {"input": "native", "timeout_ms": 5000}})
            if "error" not in resp:
                failures.append(f"dom.type (native) succeeded while the document 'changed' mid-text: {resp.get('result')!r}")
            else:
                err_obj = resp["error"]
                reason = (err_obj.get("data") or {}).get("reason")
                if err_obj.get("code") != -32001 or reason != "document_changed":
                    failures.append(f"dom.type error was not element_not_found/document_changed(-32001): {err_obj}")
            # The whole string must NOT have been typed into the (replacement) document.
            value = rpc.evaluate("document.getElementById('inp') ? document.getElementById('inp').value : '<gone>'")
            if value == "abcde":
                failures.append("the full string was typed despite the mid-text document change (no per-char recheck)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-text-doc-changed")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-text-doc-changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
