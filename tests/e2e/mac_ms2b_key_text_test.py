#!/usr/bin/env python3
"""MS2b.1b RED (unregistered) — native key + text input deliver TRUSTED events on the macOS backend.

MS2b.1b: a native key press (dom.press options.input="native") and native typing (dom.type
options.input="native") must deliver TRUSTED key events (event.isTrusted === true) to the real
WKWebView — the in-process NSEvent path, no synthetic DOM events. The macOS port does not implement
nativeKey/nativeText yet (the PagePort keeps the unsupported defaults), so the engine rejects these
native commands — the red. The native-click capability (MS2b.1a) is already wired; key/text are the
next matrix slice.

Mutation-resistant: it asserts the key reached the page with e.isTrusted === true and e.key correct,
and that typing set the input's value via trusted events — so a synthetic-event stub (isTrusted false)
or an unsupported stub both fail.

Runs ON a Mac (console user, no xvfb), own process group (orphan-safe teardown). Unregistered.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>MS2b Key/Text</title></head><body>
<input id="inp" type="text">
<script>
  window.__keyTrusted = null; window.__lastKey = null; window.__textTrusted = null;
  var inp = document.getElementById('inp');
  inp.addEventListener('keydown', function (e) { window.__keyTrusted = e.isTrusted; window.__lastKey = e.key; });
  inp.addEventListener('input', function (e) { window.__textTrusted = e.isTrusted; });
</script></body></html>"""


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

    def expect_eq(label, actual, expected):
        if actual != expected:
            failures.append(f"{label}: got {actual!r}, want {expected!r}")

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2b-kt-") as tmp:
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
        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2b.1b-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            try:
                # Native key press: focuses #inp, then a trusted keydown with key "a".
                expect_eq("dom.press (native)", rpc.call("dom.press", {"selector": "css=#inp", "key": "a", "options": {"input": "native", "timeout_ms": 10000}}), {"ok": True})
                expect_eq("keydown is trusted (native)", rpc.evaluate("window.__keyTrusted"), True)
                expect_eq("keydown key", rpc.evaluate("window.__lastKey"), "a")
                # Native typing: trusted input events set the field value.
                expect_eq("dom.type (native)", rpc.call("dom.type", {"selector": "css=#inp", "text": "hi", "options": {"input": "native", "timeout_ms": 10000}}), {"ok": True})
                expect_eq("typed value", rpc.evaluate("document.getElementById('inp').value"), "ahi")
                expect_eq("input is trusted (native)", rpc.evaluate("window.__textTrusted"), True)
            except AssertionError as exc:
                failures.append(f"native key/text rejected (expected on macOS today): {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b.1b-key-text")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b.1b-key-text")
    return 0


if __name__ == "__main__":
    sys.exit(main())
