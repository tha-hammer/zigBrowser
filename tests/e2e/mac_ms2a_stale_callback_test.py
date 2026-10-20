#!/usr/bin/env python3
"""MS2a RED (unregistered->gate) — a stale navigation callback is ignored (RoseCat 6348/6358).

The currentNav identity guard must ignore a finish/failure callback for a SUPERSEDED navigation that
lands in the submit->didStart window of a new one. A stale `didFinish` that slipped through would set
finishedOrFailed, cancel the new timer, and emit a spurious NAV protocol row (page_port e2e protocol);
a stale failure would mutate/cancel the same state. ZB_DEBUG_SYNTH_STALE synthesizes exactly that stale
callback for the superseded navigation, in the window, right after currentNav is pinned to the new one.

Oracle (via the --e2e-protocol NAV rows on stdout): after the initial load of /a (one NAV /a row) and a
routed navigate to /b (one NAV /b row), a synthesized stale didFinish for the old /a navigation adds NO
second NAV /a row, and the routed navigation to /b still succeeds (page.url == /b). A build without the
synchronous currentNav pin would process the stale callback and emit a spurious NAV /a row — the red.
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-stale-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_SYNTH_STALE"] = "finish"  # synthesize a stale didFinish for the superseded nav
        proc = subprocess.Popen(
            # --e2e-protocol prints the NAV rows AND gates the synth hook on.
            [str(browser), f"{fixture.base_url}/a", "--automation-api", "--e2e-protocol"],
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
                print("FAIL\tms2a-stale-callback-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # wait for /a to settle (emits NAV /a)
            # Routed navigate to /b: the hook synthesizes a stale didFinish for the old /a navigation.
            res = rpc.call("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})
            if res != {"ok": True}:
                failures.append(f"routed navigate to /b did not succeed: {res!r}")
            after = rpc.call("page.url", {"timeout_ms": 10000})["url"]
            if not after.endswith("/b"):
                failures.append(f"page.url after navigate is not /b (stale callback corrupted state?): {after!r}")

            time.sleep(0.5)  # let any (spurious) NAV rows flush
            # Exactly two real navigations (/a then /b) must each emit ONE NAV row. A stale didFinish that
            # slipped through the guard would emit a THIRD (spurious) NAV row — whatever its URL.
            nav_rows = [ln for ln in list(out) if ln.split("\t", 1)[0] == "NAV"]
            if len(nav_rows) != 2:
                failures.append(f"NAV rows = {len(nav_rows)} (want 2: /a then /b): a stale didFinish emitted a spurious row: {nav_rows}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-stale-callback")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"out(NAV)={[l for l in out if l.startswith('NAV')]}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-stale-callback")
    return 0


if __name__ == "__main__":
    sys.exit(main())
