#!/usr/bin/env python3
"""MS2a RED (unregistered->gate) — a stale navigation FAILURE callback is ignored (RoseCat 6348/6358).

Companion to the stale-success red: the handleLoadFailureForWebView identity guard must ignore a
didFailProvisional callback for a SUPERSEDED navigation. Without the guard, the stale failure for the
(untagged) initial-load navigation would fall through to the user-load failure path and EXIT the
browser. ZB_DEBUG_SYNTH_STALE=fail synthesizes that stale failure during a new routed navigation.

Oracle: the routed navigate to /b succeeds, the browser stays alive, and page.url is /b. A build whose
failure handler mutated/cancelled current state on the stale callback (or exited) would fail here.
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-stalef-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_SYNTH_STALE"] = "fail"  # synthesize a stale didFailProvisional for the superseded nav
        proc = subprocess.Popen(
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
                print("FAIL\tms2a-stale-failure-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # /a settles
            try:
                res = rpc.call("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})
                if res != {"ok": True}:
                    failures.append(f"routed navigate to /b did not succeed under a stale failure: {res!r}")
                after = rpc.call("page.url", {"timeout_ms": 10000})["url"]
                if not after.endswith("/b"):
                    failures.append(f"page.url after navigate is not /b: {after!r}")
            except Exception as exc:  # noqa: BLE001 — a dropped socket here means the stale failure exited the browser
                failures.append(f"the browser dropped the session under a stale failure (exited?): {exc}")

            if proc.poll() is not None:
                failures.append(f"the browser exited (code {proc.returncode}) on a stale failure callback")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-stale-failure")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-stale-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
