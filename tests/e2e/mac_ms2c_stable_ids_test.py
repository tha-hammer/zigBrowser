#!/usr/bin/env python3
"""MS2c RED (unregistered) — window ids are STABLE: closing one window never renumbers the others.

Each window keeps its id for life. With two popups open, closing the FIRST must leave the second's id (and
its reachability by that id) unchanged. On an index-based scheme (the pre-change shim) closing a window
compacts the array and the survivor's id shifts — the red.
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
<script>function openOne(q){ window.open(location.href.split('?')[0] + '?' + q, '_blank'); }</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-ids-") as tmp:
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

        def wait_pages(n, deadline_s=6.0):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                p = pages()
                if len(p) == n:
                    return p
                time.sleep(0.05)
            return pages()

        def by_q(ps, q):
            return next((w for w in ps if (w.get("url") or "").endswith("?" + q)), None)

        def wait_urls(suffixes, deadline_s=8.0):
            # A new window appears in page.list before its navigation commits (url == ""), so wait for the
            # expected ?suffix urls to settle, not merely for the window count (a cold/slow build races).
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                p = pages()
                if all(by_q(p, q) is not None for q in suffixes):
                    return p
                time.sleep(0.05)
            return pages()

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-stable-ids-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.raw("page.evaluate", {"expression": "openOne('a')"})
            wait_urls(["a"])
            rpc.raw("page.evaluate", {"expression": "openOne('b')"})
            ps = wait_urls(["a", "b"])
            a = by_q(ps, "a")
            b = by_q(ps, "b")
            if len(ps) != 3 or a is None or b is None:
                failures.append(f"expected two identifiable popups (?a, ?b): {[(w.get('window_id'), w.get('url')) for w in ps]}")
                a = b = None

            if a and b:
                b_id = b["window_id"]
                # Close the FIRST popup (?a); the second (?b) must keep its id and reachability.
                if rpc.raw("page.close", {"window_id": a["window_id"]}).get("result") != {"ok": True}:
                    failures.append("closing popup ?a did not return ok")
                left = wait_pages(2)
                b_after = by_q(left, "b")
                if b_after is None:
                    failures.append(f"popup ?b vanished after closing ?a: {left!r}")
                else:
                    if b_after["window_id"] != b_id:
                        failures.append(f"popup ?b id changed from {b_id} to {b_after['window_id']} (ids not stable)")
                    # still reachable by its original id
                    turl = (rpc.raw("page.url", {"window_id": b_id, "timeout_ms": 5000}).get("result") or {}).get("url")
                    if not (turl or "").endswith("?b"):
                        failures.append(f"popup ?b not reachable by its stable id {b_id}: {turl!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-stable-ids")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-stable-ids")
    return 0


if __name__ == "__main__":
    sys.exit(main())
