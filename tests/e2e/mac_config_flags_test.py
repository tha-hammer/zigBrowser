#!/usr/bin/env python3
"""MS3.2 RED (unregistered) — backend-flag .macos arm: media-source/hardware-acceleration apply, renderer refused.

- `--media-source off` disables MSE: window.MediaSource is undefined in every window.
- default (`--media-source on`) keeps MSE: window.MediaSource is a constructor.
- `--hardware-acceleration never` is accepted on macOS (the browser starts normally).
- `--renderer shm` is a parser-valid value that macOS does NOT support: the binary exits nonzero with the
  exact seam refusal message and never starts.

On a build whose .macos arm doesn't apply media-source off, window.MediaSource stays defined — the red.
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
# The page records typeof window.MediaSource into its title (set at document start, so after the shim's
# MSE-removal user script would have run). page.list then surfaces "undefined" (off) or "function" (on).
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>pending</title></head><body>x
<script>document.title = typeof window.MediaSource;</script></body></html>"""


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

    with _FixtureServer() as fixture:

        def launch(extra):
            tmp = tempfile.mkdtemp(prefix="zb-ms3cfg-")
            sp = Path(tmp) / "automation.sock"
            env = dict(os.environ)
            env["ZIGBROWSER_SOCKET"] = str(sp)
            env.pop("ZIGBROWSER_MEDIA_SOURCE", None)  # don't let the env override the flag under test
            p = subprocess.Popen(
                [str(browser), f"{fixture.base_url}/", "--automation-api", *extra],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
            )
            o, e = [], []
            for stream, buf in ((p.stdout, o), (p.stderr, e)):
                threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()
            return p, sp, o, e

        def media_source_title(extra):
            """Launch with `extra` flags; return the primary window's title (= typeof window.MediaSource)."""
            p, sp, o, e = launch(extra)
            proc_holder[:] = [p]
            rpc = None
            try:
                rpc = RpcClient(sp, args.timeout_sec)
                rpc.call("page.url", {"timeout_ms": 10000})
                end = time.monotonic() + 6.0
                title = ""
                while time.monotonic() < end:
                    pages = (rpc.raw("page.list", {}).get("result") or {}).get("pages") or []
                    title = (pages[0] or {}).get("title") if pages else ""
                    if title in ("undefined", "function", "object"):
                        break
                    time.sleep(0.05)
                return title
            finally:
                if rpc is not None:
                    rpc.close()
                stop_browser_macos(p)

        # 1. media-source off -> MSE removed.
        off_title = media_source_title(["--media-source", "off"])
        if off_title != "undefined":
            failures.append(f"--media-source off did not disable MSE (typeof window.MediaSource={off_title!r})")

        # 2. default (media-source on) -> MSE present.
        on_title = media_source_title([])
        if on_title not in ("function", "object"):
            failures.append(f"default build unexpectedly lacks MSE (typeof window.MediaSource={on_title!r})")

        # 3. hardware-acceleration never -> accepted on macOS (the browser starts and serves).
        acc_title = media_source_title(["--hardware-acceleration", "never"])
        if acc_title not in ("function", "object"):
            failures.append(f"--hardware-acceleration never was not accepted (no window served; title={acc_title!r})")

        # 4. renderer shm -> refused on macOS: exits nonzero with the exact message, no window.
        p, sp, o, e = launch(["--renderer", "shm"])
        proc_holder[:] = [p]
        try:
            rc = p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            rc = None
            stop_browser_macos(p)
        time.sleep(0.2)
        blob = "\n".join(o) + "\n" + "\n".join(e)
        if rc is None or rc == 0:
            failures.append(f"--renderer shm was NOT refused on macOS (exit rc={rc})")
        if "--renderer=shm is not supported on macOS" not in blob:
            failures.append(f"renderer refusal message missing/wrong: {blob[-300:]!r}")

    if failures:
        print("FAIL\tms3-config-flags")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms3-config-flags")
    return 0


if __name__ == "__main__":
    sys.exit(main())
