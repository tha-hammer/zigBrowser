#!/usr/bin/env python3
"""MS2b.2 RED (unregistered) — an in-flight eval that opens a dialog ends promptly dialog_open (RoseCat 6469).

A page script that pops a dialog blocks the web process, so its evaluate can never get its completion
back. The shim's eval dialog-watch detects the dialog opening WHILE the eval is in flight and finishes
that eval promptly with dialog_open (-32013), freeing its connection; the dialog stays open and
answerable. Without the watch the eval hangs to its deadline and wedges that connection.

Two connections prove it (mirroring the Linux second-socket test): connection A issues the
dialog-opening evaluate; connection B watches dialog.get capture it and checks that A returned -32013 on
its own, BEFORE B answers. A build with the watch deleted leaves A blocked until B answers it — A then
returns the confirm result, not -32013: the red.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>EvalDialog</title></head><body>
<script>function ask(){ return confirm('go?'); }</script></body></html>"""


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
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-evaldlg-") as tmp:
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

        conn_a = conn_b = None
        a_result: dict = {}

        def run_eval():
            # A long command deadline: the watcher — not the deadline — is what must end this promptly.
            try:
                a_result["resp"] = conn_a.raw("page.evaluate", {"expression": "ask()", "timeout_ms": 15000})
            except Exception as exc:  # noqa: BLE001
                a_result["exc"] = exc
            a_result["t"] = time.monotonic()

        try:
            try:
                conn_a = RpcClient(socket_path, 20.0)
                conn_b = RpcClient(socket_path, 20.0)
            except Exception as exc:
                print("FAIL\tms2b-eval-dialog-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            conn_b.call("page.url", {"timeout_ms": 10000})
            t0 = time.monotonic()
            th = threading.Thread(target=run_eval, daemon=True)
            th.start()

            # B: the dialog must be captured.
            end = time.monotonic() + 5.0
            dlg = None
            while time.monotonic() < end:
                dlg = (conn_b.raw("dialog.get", {}).get("result") or {})
                if dlg.get("open"):
                    break
                time.sleep(0.05)
            if not (dlg and dlg.get("open") and dlg.get("type") == "confirm"):
                failures.append(f"the in-flight eval's dialog was not captured: {dlg!r}")

            # A must have returned on its OWN (the watch), promptly, with dialog_open — before B answers.
            th.join(timeout=2.0)
            a_returned_before_answer = not th.is_alive()
            if not a_returned_before_answer:
                failures.append("the eval did not return on its own (watch missing: it hangs until answered)")

            # Clean up: answer the dialog so A (if still blocked) unblocks and the browser can quit.
            conn_b.raw("dialog.respond", {"accept": True})
            th.join(timeout=5.0)

            resp = a_result.get("resp")
            if a_returned_before_answer:
                err_obj = (resp or {}).get("error") if resp else None
                if "exc" in a_result:
                    failures.append(f"the eval raised instead of returning dialog_open: {a_result['exc']!r}")
                elif not err_obj or err_obj.get("code") != -32013:
                    failures.append(f"the in-flight eval did not end with dialog_open (-32013): {resp!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            for c in (conn_a, conn_b):
                if c is not None:
                    try:
                        c.close()
                    except Exception:
                        pass
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-eval-dialog")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-eval-dialog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
