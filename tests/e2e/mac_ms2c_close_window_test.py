#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.close a popup; the primary cannot be closed; the opener survives.

A page opens a popup (window.open). page.list lists it as a non-primary window whose opener is the
primary; a command carrying its window_id reaches it (forWindow). page.close refuses the primary
(no_window) and closes the popup, which then leaves page.list; the opener window is untouched (same url).

On today's binary the macOS port leaves forWindow/closeWindow at the PagePort `unsupported` defaults, so
page.close errors — the red. The green wires zb_automation_close_window (shim) + forWindow/closeWindow
(port) and tracks each popup's opener.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Opener</title></head><body>
<script>function openPopup(){ window.open(location.href + '?popup', '_blank'); }</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-close-") as tmp:
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

        def wait_pages(n, deadline_s=5.0):
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
                print("FAIL\tms2c-close-window-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            p0 = pages()
            if len(p0) != 1 or not p0[0].get("primary"):
                failures.append(f"expected one primary window at start: {p0!r}")
            primary_id = p0[0].get("window_id") if p0 else None
            opener_url = (rpc.raw("page.url", {"timeout_ms": 5000}).get("result") or {}).get("url")

            # Open a popup.
            rpc.raw("page.evaluate", {"expression": "openPopup()"})
            p = wait_pages(2)
            if len(p) != 2:
                failures.append(f"popup not listed: {p!r}")
                popup_id = None
            else:
                if p[0].get("window_id") != primary_id:
                    failures.append(f"primary not listed first: {p!r}")
                popup = p[1]
                popup_id = popup.get("window_id")
                if popup.get("primary"):
                    failures.append(f"popup marked primary: {popup!r}")
                if popup.get("opener_window_id") != primary_id:
                    failures.append(f"popup opener != primary: {popup.get('opener_window_id')!r} (want {primary_id})")
                # window targeting (forWindow): a command carrying the popup's id reaches it.
                turl = (rpc.raw("page.url", {"window_id": popup_id, "timeout_ms": 5000}).get("result") or {}).get("url")
                if not (turl or "").endswith("?popup"):
                    failures.append(f"targeted page.url did not reach the popup: {turl!r}")

            # The primary cannot be closed: it errors AND the primary stays listed AND the browser lives
            # (so a build that actually closed the primary — error from the dropped connection — is caught).
            if primary_id is not None:
                resp = rpc.raw("page.close", {"window_id": primary_id})
                if "error" not in resp:
                    failures.append(f"closing the primary did not error: {resp.get('result')!r}")
                if primary_id not in [w.get("window_id") for w in pages()]:
                    failures.append("the primary was actually closed (gone from page.list)")
                if proc.poll() is not None:
                    failures.append(f"the browser exited when the primary was closed (rc={proc.returncode})")

            # Close the popup; it leaves the list; the opener survives.
            if popup_id is not None:
                if rpc.raw("page.close", {"window_id": popup_id}).get("result") != {"ok": True}:
                    failures.append("page.close of the popup did not return ok")
                left = wait_pages(1)
                if [w.get("window_id") for w in left] != [primary_id]:
                    failures.append(f"popup still listed after close: {left!r}")
                after = (rpc.raw("page.url", {"timeout_ms": 5000}).get("result") or {}).get("url")
                if after != opener_url:
                    failures.append(f"opener url changed after closing the popup: {after!r} != {opener_url!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-close-window")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-close-window")
    return 0


if __name__ == "__main__":
    sys.exit(main())
