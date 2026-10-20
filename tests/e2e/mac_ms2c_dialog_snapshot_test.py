#!/usr/bin/env python3
"""MS2c RED — page.health dialog_open reflects a dialog open/respond AT ONCE (RoseCat 6556 SHOULD; 6625 determinism).

The snapshot must publish when dialog state changes, not wait for the next 500 ms health tick. When a page
alert is captured (confirmed via dialog.get), page.health must ALREADY report the window dialog_open=true; and
after dialog.respond answers it, page.health must report dialog_open=false immediately. On a build that only
refreshes dialog_open on the health tick, the just-opened/just-answered state is stale at the instant we
check — the red.

Determinism (RoseCat ec36aee SHOULD): the browser is launched with the e2e-gated ZB_DEBUG_HEALTH_TICK_SUSPEND
seam, which freezes the periodic 500 ms health tick. With the tick frozen, the ONLY thing that can republish
the snapshot is the dialog open/respond handler itself — so a mutant that drops the handler's publish reds
deterministically, instead of a tick racing in between dialog.get and the page.health read and false-greening.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Dlg</title></head><body>x
<script>function popAlert(){ setTimeout(function(){ alert('hi'); }, 50); }</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-dlgsnap-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_HEALTH_TICK_SUSPEND"] = "1"  # freeze the 500 ms tick: the dialog handler is the sole publisher
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def dialog_open_in_list():
            # dialog_open is exposed by page.health (listJson omits it); both read the same lock-backed snapshot.
            pages = (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []
            return (pages[0] or {}).get("dialog_open") if pages else None

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-dialog-snapshot-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            if dialog_open_in_list() is not False:
                failures.append(f"dialog_open was not false before any dialog: {dialog_open_in_list()!r}")

            # Open an alert; wait until dialog.get confirms it's captured (so the dialog handler has run).
            rpc.raw("page.evaluate", {"expression": "popAlert()"})
            end = time.monotonic() + 6.0
            while time.monotonic() < end:
                d = rpc.raw("dialog.get", {}).get("result") or {}
                if d.get("open"):
                    break
                time.sleep(0.05)
            if not ((rpc.raw("dialog.get", {}).get("result") or {}).get("open")):
                failures.append("alert never captured by dialog.get")
            else:
                # The dialog handler ran (dialog.get says open) -> page.health must ALREADY show dialog_open.
                if dialog_open_in_list() is not True:
                    failures.append(f"page.health did not reflect the open dialog at once (stale until the tick?): {dialog_open_in_list()!r}")
                # Answer it; page.health must reflect dialog_open=false at once.
                rpc.raw("dialog.respond", {"accept": True})
                if dialog_open_in_list() is not False:
                    failures.append(f"page.health did not reflect the answered dialog at once (stale until the tick?): {dialog_open_in_list()!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-dialog-snapshot")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-dialog-snapshot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
