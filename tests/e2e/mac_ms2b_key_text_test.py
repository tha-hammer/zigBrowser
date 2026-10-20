#!/usr/bin/env python3
"""MS2b.1b RED (unregistered) — native key + text deliver complete TRUSTED key SEQUENCES.

MS2b.1b: dom.press (native) and dom.type (native) must deliver real, TRUSTED key events to the
WKWebView — per page_port.zig:223-232, nativeKey returns only after the trusted keyUP is acknowledged,
and nativeText uses real key events for every code point. A green that emitted a trusted keydown but no
keyup, or synthetic events for part of the input, must fail — so this records the ORDERED keydown /
keyup / input log (key + isTrusted) and asserts complete trusted down+up pairs, with NO untrusted
(synthetic) key events anywhere (RoseCat 6360).

Covers: a printable key (a), typing (hi), and a named navigation key (ArrowLeft). Reds on the
unsupported port (session_invalid/unsupported). Runs ON a Mac, own process group. Unregistered.
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
  window.__ev = [];
  var inp = document.getElementById('inp');
  function rec(t) { return function (e) { window.__ev.push({t: t, k: e.key, tr: e.isTrusted}); }; }
  inp.addEventListener('keydown', rec('keydown'));
  inp.addEventListener('keyup', rec('keyup'));
  inp.addEventListener('input', function (e) { window.__ev.push({t: 'input', k: null, tr: e.isTrusted}); });
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

            def events():
                return rpc.evaluate("JSON.stringify(window.__ev)") or "[]"

            def has_trusted_pair(log, key):
                import json
                ev = json.loads(log)
                down = any(e["t"] == "keydown" and e["k"] == key and e["tr"] is True for e in ev)
                up = any(e["t"] == "keyup" and e["k"] == key and e["tr"] is True for e in ev)
                untrusted = [e for e in ev if e["t"] in ("keydown", "keyup") and e["tr"] is not True]
                return down, up, untrusted

            try:
                # Printable key: a complete trusted down+up pair for "a".
                expect = rpc.call("dom.press", {"selector": "css=#inp", "key": "a", "options": {"input": "native", "timeout_ms": 10000}})
                if expect != {"ok": True}:
                    failures.append(f"dom.press (native) -> {expect!r}")
                down, up, untrusted = has_trusted_pair(events(), "a")
                if not down:
                    failures.append("dom.press: no trusted keydown for 'a'")
                if not up:
                    failures.append("dom.press: no trusted keyup for 'a' (nativeKey must return after keyup)")
                if untrusted:
                    failures.append(f"dom.press: untrusted (synthetic) key events present: {untrusted}")

                rpc.evaluate("window.__ev = []")
                # Typing: complete trusted sequences for every code point of "hi".
                expect = rpc.call("dom.type", {"selector": "css=#inp", "text": "hi", "options": {"input": "native", "timeout_ms": 10000}})
                if expect != {"ok": True}:
                    failures.append(f"dom.type (native) -> {expect!r}")
                log = events()
                for key in ("h", "i"):
                    down, up, untrusted = has_trusted_pair(log, key)
                    if not (down and up):
                        failures.append(f"dom.type: incomplete trusted down/up for {key!r} (down={down}, up={up})")
                _, _, untrusted = has_trusted_pair(log, "h")
                if untrusted:
                    failures.append(f"dom.type: untrusted (synthetic) key events present: {untrusted}")
                typed_value = rpc.evaluate("document.getElementById('inp').value")
                if typed_value != "ahi":
                    failures.append(f"typed value wrong: {typed_value!r}")

                rpc.evaluate("window.__ev = []")
                # Named navigation key: a complete trusted down+up pair for "ArrowLeft".
                expect = rpc.call("dom.press", {"selector": "css=#inp", "key": "ArrowLeft", "options": {"input": "native", "timeout_ms": 10000}})
                if expect != {"ok": True}:
                    failures.append(f"dom.press ArrowLeft (native) -> {expect!r}")
                down, up, untrusted = has_trusted_pair(events(), "ArrowLeft")
                if not (down and up):
                    failures.append(f"dom.press ArrowLeft: incomplete trusted down/up (down={down}, up={up})")
                if untrusted:
                    failures.append(f"dom.press ArrowLeft: untrusted key events present: {untrusted}")
            except AssertionError as exc:
                failures.append(f"native key/text rejected (expected on the unsupported port): {exc}")
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
