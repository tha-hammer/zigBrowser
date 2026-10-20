#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.list enumerates the window(s) on macOS (listWindows).

MS2c multi-window builds on window enumeration: page.list must return each open window with its id, url,
title and primary flag (plus opener/health defaults). This first increment asserts the primary window is
listed. On today's binary the macOS port leaves listWindows at the PagePort `unsupported` default, so
page.list errors — the red. The green wires zb_automation_list_windows (shim) + listWindows (port).
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>ListWindows</title></head><body>primary</body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-lw-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        base = f"{fixture.base_url}/"
        proc = subprocess.Popen(
            [str(browser), base, "--automation-api"],
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
                print("FAIL\tms2c-list-windows-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness
            resp = rpc.raw("page.list", {})
            if "error" in resp:
                failures.append(f"page.list errored (listWindows unsupported?): {resp['error']}")
            else:
                result = resp.get("result") or {}
                # the dispatcher returns the window list under "pages"
                windows = result.get("pages") if isinstance(result, dict) else result
                if not isinstance(windows, list) or not windows:
                    failures.append(f"page.list returned no windows: {result!r}")
                else:
                    primary = next((w for w in windows if w.get("primary")), None)
                    if primary is None:
                        failures.append(f"no primary window in page.list: {windows!r}")
                    else:
                        if primary.get("window_id") != "window-1":
                            failures.append(f"primary window_id != window-1: {primary.get('window_id')!r}")
                        if not (primary.get("url") or "").startswith(fixture.base_url):
                            failures.append(f"primary url wrong: {primary.get('url')!r}")
                        if primary.get("title") != "ListWindows":
                            failures.append(f"primary title wrong: {primary.get('title')!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-list-windows")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-list-windows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
