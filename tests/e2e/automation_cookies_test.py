#!/usr/bin/env python3
"""E2E: cookies.* against the real browser's cookie store (local HTTP).

- cookies.set makes a cookie visible to the page (document.cookie);
- an httpOnly cookie shows in cookies.getAll but not in document.cookie;
- cookies.delete removes it;
- cookies.import of a Netscape cookies.txt survives a restart on the same
  --profile-dir and is sent to the server;
- no cookie value ever appears in the browser's stdout/stderr."""

from __future__ import annotations

import argparse
import html
import http.server
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, expect_equal, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file

SECRET = "zbsecret"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        received = self.headers.get("Cookie", "")
        body = (
            "<!doctype html><title>Cookie Fixture</title>"
            f"<p id=cookie>{html.escape(received)}</p>"
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class Browser:
    def __init__(self, binary: Path, prefix: list[str], env: dict, profile: Path, url: str, tmp: Path, name: str):
        self.socket_path = tmp / f"{name}.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        self.proc = subprocess.Popen(
            prefix + [str(binary), url, "--automation-api", "--profile-dir", str(profile)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert self.proc.stdout is not None and self.proc.stderr is not None
        self.output: list[str] = []
        self.readers = [
            threading.Thread(target=_read_lines, args=(stream, self.output), daemon=True)
            for stream in (self.proc.stdout, self.proc.stderr)
        ]
        for reader in self.readers:
            reader.start()
        self.next_id = 1

    def rpc(self, method: str, params: dict, timeout: float):
        self.next_id += 1
        return call_rpc(self.socket_path, method, params, self.next_id, timeout)

    def js(self, expression: str, timeout: float):
        return self.rpc("page.evaluate", {"expression": expression}, timeout)["result"]

    def close(self) -> list[str]:
        """Stop the browser, wait for both output readers to hit EOF, and
        return everything it printed (so shutdown output is included)."""
        rc = terminate(self.proc)
        for reader in self.readers:
            reader.join(timeout=5)
            if reader.is_alive():
                raise AssertionError("browser output reader did not finish")
        if rc not in (0, 130, -2):
            raise AssertionError(f"browser did not exit cleanly: {rc}")
        return list(self.output)


def names(result: dict) -> dict[str, dict]:
    return {cookie["name"]: cookie for cookie in result["cookies"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    binary = Path(args.binary)
    if not require_file(binary, "binary"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    t = args.timeout_sec
    outputs: list[str] = []
    try:
        with tempfile.TemporaryDirectory(prefix="zb-automation-cookies-") as tmp_name:
            tmp = Path(tmp_name)
            profile = tmp / "profile"

            first = Browser(binary, prefix, env, profile, f"{base}/page", tmp, "first")
            try:
                expect_equal("set script cookie", first.rpc("cookies.set", {
                    "name": "zbjs", "value": f"v1-{SECRET}", "domain": "127.0.0.1", "path": "/"}, t), {"ok": True})
                if f"zbjs=v1-{SECRET}" not in first.js("document.cookie", t):
                    raise AssertionError("page does not see the cookie set over the socket")

                expect_equal("set httpOnly cookie", first.rpc("cookies.set", {
                    "name": "zbhttp", "value": f"hidden-{SECRET}", "domain": "127.0.0.1", "path": "/",
                    "httpOnly": True}, t), {"ok": True})
                listed = names(first.rpc("cookies.getAll", {"url": f"{base}/page"}, t))
                expect_equal("getAll lists both", sorted(k for k in listed if k.startswith("zb")), ["zbhttp", "zbjs"])
                expect_equal("getAll httpOnly flag", listed["zbhttp"]["httpOnly"], True)
                expect_equal("getAll value", listed["zbjs"]["value"], f"v1-{SECRET}")
                if "zbhttp" in first.js("document.cookie", t):
                    raise AssertionError("httpOnly cookie leaked into document.cookie")

                # Exact round-trip through socket -> CookiePort -> WebKit store,
                # bound to each named cookie object.
                expiry = int(time.time()) + 3600
                expect_equal("set secure persistent cookie", first.rpc("cookies.set", {
                    "name": "zbsecure", "value": f"sec-{SECRET}", "domain": "127.0.0.1", "path": "/",
                    "secure": True, "expires": expiry}, t), {"ok": True})
                listed = names(first.rpc("cookies.getAll", {}, t))
                expect_equal("secure cookie attributes",
                             {k: listed["zbsecure"][k] for k in ("domain", "path", "expires", "httpOnly", "secure")},
                             {"domain": "127.0.0.1", "path": "/", "expires": expiry, "httpOnly": False, "secure": True})
                expect_equal("httpOnly session cookie attributes",
                             {k: listed["zbhttp"][k] for k in ("expires", "httpOnly", "secure")},
                             {"expires": -1, "httpOnly": True, "secure": False})
                expect_equal("script cookie attributes",
                             {k: listed["zbjs"][k] for k in ("expires", "httpOnly", "secure")},
                             {"expires": -1, "httpOnly": False, "secure": False})

                expect_equal("delete", first.rpc("cookies.delete", {"name": "zbjs"}, t), {"ok": True})
                if "zbjs" in first.js("document.cookie", t):
                    raise AssertionError("deleted cookie still visible to the page")
                if "zbjs" in names(first.rpc("cookies.getAll", {}, t)):
                    raise AssertionError("deleted cookie still in getAll")

                cookies_txt = tmp / "cookies.txt"
                cookies_txt.write_text(
                    "# Netscape HTTP Cookie File\n"
                    f"127.0.0.1\tFALSE\t/\tFALSE\t{expiry}\tzbimport\tfromfile-{SECRET}\n",
                    encoding="utf-8",
                )
                expect_equal("import", first.rpc("cookies.import", {"path": str(cookies_txt), "format": "netscape"}, t),
                             {"imported": 1, "skipped": 0})
            finally:
                outputs.extend(first.close())

            # Restart on the same profile: the imported cookie is sent to the server.
            second = Browser(binary, prefix, env, profile, f"{base}/echo", tmp, "second")
            try:
                received = second.rpc("dom.getText", {"selector": "css=#cookie"}, t)["text"]
                if f"zbimport=fromfile-{SECRET}" not in received:
                    raise AssertionError(f"imported cookie not sent after restart: {received!r}")
                if "zbjs" in received:
                    raise AssertionError("deleted cookie came back after restart")
                restored = names(second.rpc("cookies.getAll", {}, t))
                expect_equal("imported cookie expiry after restart", restored["zbimport"]["expires"], expiry)
                expect_equal("secure cookie survived restart", restored["zbsecure"]["secure"], True)
                if "zbhttp" in restored:
                    raise AssertionError("session cookie survived a restart")
            finally:
                outputs.extend(second.close())

            leaked = [line for line in outputs if SECRET in line]
            if leaked:
                raise AssertionError(f"cookie values reached browser output: {len(leaked)} line(s)")
    except Exception as exc:
        print("FAIL\tautomation-cookies")
        eprint(f"error={exc}")
        return 1
    finally:
        server.shutdown()

    print("PASS\tautomation-cookies")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
