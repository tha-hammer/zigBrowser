#!/usr/bin/env python3
"""MS2c RED (unregistered) — view-replacement recovery of a window with an OPEN dialog (RoseCat 6551 #1).

A page dialog (alert) blocks the web process, so the watchdog reports the window unresponsive and
page.recover can offer consent. Phase 2 (view replacement) must ANSWER the held dialog completion before
abandoning the old view — releasing a WKWebView with an uncalled JS-panel completion raises an NSException.
On a build that merely zeroes pendingDialogKind, the old view is freed with the completion still retained
and uncalled: the browser aborts (or recovery errors). Here recovery must succeed, the browser stay alive,
and the fresh page be responsive with no dialog open.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Dlg</title></head><body>live
<script>function popAlert(){ setTimeout(function(){ alert('held'); }, 50); }</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-rdlg-") as tmp:
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

        def primary():
            pages = (rpc.raw("page.health", {}).get("result") or {}).get("pages") or []
            return pages[0] if pages else None

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-recover-dialog-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            debounce_ms = (rpc.raw("page.health", {}).get("result") or {}).get("debounce_ms") or 2000
            # Open an alert (via setTimeout so this eval returns); it blocks the web process.
            rpc.raw("page.evaluate", {"expression": "popAlert()"})

            # The blocked web process goes unresponsive; recover can then offer consent.
            end = time.monotonic() + (debounce_ms / 1000.0) + 6.0
            while time.monotonic() < end and (primary() or {}).get("responsive") is not False:
                time.sleep(0.1)
            if (primary() or {}).get("responsive") is not False:
                failures.append("window with an open alert never went unresponsive")

            r1 = rpc.raw("page.recover", {"window_id": "window-1"})
            offer = r1.get("result") or {}
            incident = offer.get("incident")
            if "error" in r1 or not incident:
                failures.append(f"recover consent (phase 1) failed with a dialog open: {r1.get('error') or offer!r}")
            else:
                r2 = rpc.raw("page.recover", {"window_id": "window-1", "incident": incident, "acknowledge": ["window-1"]})
                if "error" in r2:
                    failures.append(f"recover phase 2 errored recovering a window with an open dialog: {r2['error']}")
                else:
                    rec = (r2.get("result") or {}).get("recovered") or []
                    w1 = next((r for r in rec if r.get("window_id") == "window-1"), None)
                    if w1 is None or not w1.get("reloaded"):
                        failures.append(f"phase 2 did not reload window-1: {r2.get('result')!r}")
                    # The browser must still be alive (an uncalled dialog completion would have aborted it).
                    if proc.poll() is not None:
                        failures.append(f"browser aborted recovering a window with an open dialog (rc={proc.returncode})")
                    # The fresh view comes up responsive with no dialog open.
                    end2 = time.monotonic() + 8.0
                    while time.monotonic() < end2:
                        p = primary()
                        if p and p.get("responsive") is True and p.get("dialog_open") is False:
                            break
                        time.sleep(0.1)
                    p = primary()
                    if not (p and p.get("responsive") is True):
                        failures.append(f"fresh view not responsive after recovery: {p!r}")
                    if p and p.get("dialog_open") is True:
                        failures.append(f"a dialog is still open after recovery: {p!r}")
                    # The held completion lives on the HOST (pendingAlertCompletion), not the old view: a
                    # DROPPED (unanswered) one is only released when a LATER dialog overwrites it, which
                    # raises WebKit's uncalled-completion NSException. Open a second alert to force that: the
                    # fixed build (which answered the old one) survives; a build that merely zeroed the kind
                    # aborts here.
                    rpc.raw("page.evaluate", {"expression": "popAlert()"})
                    time.sleep(1.5)
                    if proc.poll() is not None:
                        failures.append(f"browser aborted when a second dialog overwrote a dropped completion (rc={proc.returncode})")
            # The held dialog was answered, not released uncalled — no WebKit completion NSException.
            blob = "\n".join(err)
            if "was not called" in blob or "NSInternalInconsistencyException" in blob:
                failures.append(f"a held dialog completion was released uncalled: {err[-8:]!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-recover-dialog")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-recover-dialog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
