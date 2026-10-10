#!/usr/bin/env python3
"""E2E: --profile-dir persists cookies across browser restarts.

A local HTTP server sets a cookie on the first launch. After a clean exit, a
second launch on the same profile must still send and expose that cookie; a
launch on a fresh profile must not."""

from __future__ import annotations

import argparse
import http.server
import subprocess
import tempfile
import threading
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file

COOKIE = "zbprofile=persisted"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Profile Fixture</title><p id=msg>profile</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if self.path == "/set":
            self.send_header("Set-Cookie", f"{COOKIE}; Max-Age=3600; Path=/")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def page_cookie(browser: Path, prefix: list[str], env: dict, profile: Path, url: str, tmp: Path, timeout: float) -> str:
    socket_path = tmp / f"automation-{abs(hash((str(profile), url)))}.sock"
    env = dict(env)
    env["ZIGBROWSER_SOCKET"] = str(socket_path)
    proc = subprocess.Popen(
        prefix + [str(browser), url, "--automation-api", "--profile-dir", str(profile)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    assert proc.stdout is not None and proc.stderr is not None
    stderr_lines: list[str] = []
    threading.Thread(target=_read_lines, args=(proc.stdout, []), daemon=True).start()
    threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True).start()
    try:
        return call_rpc(socket_path, "page.evaluate", {"expression": "document.cookie"}, 1, timeout)["result"]
    except Exception:
        eprint(f"stderr={stderr_lines[-20:]}")
        raise
    finally:
        rc = terminate(proc)
        if rc not in (0, 130, -2):
            raise AssertionError(f"browser did not exit cleanly: {rc}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        with tempfile.TemporaryDirectory(prefix="zb-automation-profile-") as tmp_name:
            tmp = Path(tmp_name)
            profile = tmp / "profile"
            fresh = tmp / "fresh"
            t = args.timeout_sec
            first = page_cookie(browser, prefix, env, profile, f"{base}/set", tmp, t)
            if COOKIE not in first:
                raise AssertionError(f"cookie not set on first launch: {first!r}")
            second = page_cookie(browser, prefix, env, profile, f"{base}/check", tmp, t)
            if COOKIE not in second:
                raise AssertionError(f"cookie lost across restart: {second!r}")
            other = page_cookie(browser, prefix, env, fresh, f"{base}/check", tmp, t)
            if COOKIE in other:
                raise AssertionError(f"fresh profile saw another profile's cookie: {other!r}")
            if not (profile / "cookies.sqlite").exists():
                raise AssertionError("cookies.sqlite missing from the profile directory")
    except Exception as exc:
        print("FAIL\tautomation-profile")
        eprint(f"error={exc}")
        return 1
    finally:
        server.shutdown()

    print("PASS\tautomation-profile")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
