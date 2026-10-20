#!/usr/bin/env python3
"""MS3 RED (unregistered) — cookies.* over WKHTTPCookieStore on macOS.

- cookies.set adds a cookie; cookies.getAll lists it with its fields;
- a reload sends it to the server (echoed) and a normal cookie is visible to document.cookie;
- an httpOnly cookie is in getAll and in the server's Cookie header, but NOT in document.cookie;
- cookies.delete removes just the named cookie;
- no cookie VALUE ever appears in the browser's stdout/stderr.

On a build with no macOS cookie port, cookies.* is unsupported — the red.
"""
import argparse
import html
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
VAL = "zbvalue123"       # normal cookie value — must never hit stdout/stderr
HVAL = "zbhttponly456"   # httpOnly cookie value — must never hit stdout/stderr


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                received = self.headers.get("Cookie", "")
                body = (
                    "<!doctype html><meta charset=utf-8><title>Cookie Fixture</title>"
                    f"<p id=cookie>{html.escape(received)}</p><p id=jscookie></p>"
                    "<script>document.getElementById('jscookie').textContent=document.cookie;</script>"
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self._srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self._srv.daemon_threads = True
        self.port = self._srv.server_address[1]
        self.base_url = f"http://127.0.0.1:{self.port}"

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms3-cookie-") as tmp:
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

        def cookies():
            return (rpc.raw("cookies.getAll", {}).get("result") or {}).get("cookies") or []

        def by_name(cks, n):
            return next((c for c in cks if c.get("name") == n), None)

        def text(selector):
            return ((rpc.raw("dom.getText", {"selector": selector}).get("result") or {}).get("text") or "")

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms3-cookie-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})

            # set a normal cookie and an httpOnly one.
            r = rpc.raw("cookies.set", {"name": "zbc", "value": VAL, "domain": "127.0.0.1", "path": "/"})
            if "error" in r:
                failures.append(f"cookies.set (normal) errored (macOS cookie port unsupported?): {r['error']}")
            r = rpc.raw("cookies.set", {"name": "zbh", "value": HVAL, "domain": "127.0.0.1", "path": "/", "httpOnly": True})
            if "error" in r:
                failures.append(f"cookies.set (httpOnly) errored: {r['error']}")

            # getAll lists both, with the right fields.
            cks = cookies()
            zbc, zbh = by_name(cks, "zbc"), by_name(cks, "zbh")
            if zbc is None or zbc.get("value") != VAL:
                failures.append(f"getAll missing/incorrect normal cookie: {zbc!r}")
            if zbh is None or zbh.get("value") != HVAL:
                failures.append(f"getAll missing/incorrect httpOnly cookie: {zbh!r}")
            if zbh is not None and zbh.get("httpOnly") is not True:
                failures.append(f"httpOnly cookie not flagged httpOnly in getAll: {zbh!r}")
            if zbc is not None and zbc.get("httpOnly") is not False:
                failures.append(f"normal cookie wrongly flagged httpOnly: {zbc!r}")

            # reload so the cookies are sent; the server echoes the Cookie header, the page records document.cookie.
            rpc.raw("page.navigate", {"url": f"{fixture.base_url}/", "timeout_ms": 10000})
            server_seen = text("css=#cookie")
            js_seen = text("css=#jscookie")
            if "zbc=" + VAL not in server_seen:
                failures.append(f"normal cookie not sent to the server: {server_seen!r}")
            if "zbh=" + HVAL not in server_seen:
                failures.append(f"httpOnly cookie not sent to the server: {server_seen!r}")
            if "zbc=" + VAL not in js_seen:
                failures.append(f"normal cookie not visible to document.cookie: {js_seen!r}")
            if "zbh" in js_seen:
                failures.append(f"httpOnly cookie leaked into document.cookie: {js_seen!r}")

            # delete only the normal cookie; the httpOnly one remains.
            r = rpc.raw("cookies.delete", {"name": "zbc", "domain": "127.0.0.1"})
            if "error" in r:
                failures.append(f"cookies.delete errored: {r['error']}")
            cks2 = cookies()
            if by_name(cks2, "zbc") is not None:
                failures.append(f"deleted cookie still present: {[c.get('name') for c in cks2]!r}")
            if by_name(cks2, "zbh") is None:
                failures.append("delete removed the wrong cookie (httpOnly one gone)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

        # No cookie value ever leaves through the browser's stdout/stderr.
        blob = "\n".join(out) + "\n" + "\n".join(err)
        if VAL in blob or HVAL in blob:
            failures.append("a cookie value appeared in the browser's stdout/stderr")

    if failures:
        print("FAIL\tms3-cookie")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms3-cookie")
    return 0


if __name__ == "__main__":
    sys.exit(main())
