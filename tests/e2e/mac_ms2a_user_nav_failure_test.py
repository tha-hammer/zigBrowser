#!/usr/bin/env python3
"""MS2a RED (registered) — a page-initiated nav failure is NOT suppressed after a routed nav.

RoseCat 38d121a #4: failure suppression must be scoped to the ROUTED navigation's identity, not to the
window. So in a window that has already run a routed navigation, an UNtagged (page-initiated / user)
navigation that fails must still be handled as a real load failure (the browser exits), not silently
swallowed. (With the earlier per-window boolean it was swallowed forever.)

Oracle: after a successful routed page.navigate, a page-initiated navigation to an unreachable host
(set via evaluate) makes the browser exit (the failure is not swallowed). A bridge that suppressed it
per window would keep the browser alive and reach the timeout — the red.
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
PAGES = {
    b"/a": b"<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body><h1>A</h1></body></html>",
    b"/b": b"<!doctype html><html><head><meta charset='utf-8'><title>B</title></head><body><h1>B</h1></body></html>",
}


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        pages = PAGES

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = pages.get(self.path.encode(), b"<title>x</title>")
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-usernav-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/a", "--automation-api"],
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
                print("FAIL\tms2a-user-nav-failure-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            # Run a routed navigation first, so the window has been under automation.
            rpc.call("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})

            # Now a PAGE-INITIATED (untagged) navigation to an unreachable host. This must be treated as
            # a real load failure (browser exits), not swallowed because the window ran automation.
            try:
                rpc.evaluate("location.href = 'https://nonexistent.invalid/'")
            except Exception:
                pass  # the eval may not round-trip cleanly as the page navigates away

            try:
                proc.wait(timeout=8)  # the untagged load failure should bring the browser down
            except subprocess.TimeoutExpired:
                failures.append("browser stayed alive after an untagged page-initiated nav failure "
                                "(it was suppressed because the window had run a routed nav)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-user-nav-failure")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-user-nav-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
