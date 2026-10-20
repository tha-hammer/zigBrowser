#!/usr/bin/env python3
"""MS2b RED (unregistered) — native key coverage: modifier-only, function, and non-BMP keys (RoseCat 6361.4).

Wiring nativeKey/nativeText exposes the WHOLE router.native_key_names set plus any single Unicode code
point. This exercises the paths beyond the printable/arrow basics covered by mac_ms2b_key_text_test.py:
  - a MODIFIER-ONLY key (Shift), synthesized as a flagsChanged press/release -> a trusted keydown/keyup
    with key "Shift";
  - a FUNCTION key (F1) -> a trusted keydown/keyup with key "F1";
  - a NON-BMP code point (an emoji) typed via dom.type -> inserted as ONE code point, trusted.

Mutation-resistant: asserts the trusted keydown/keyup with the right key names and the non-BMP insertion,
so an unsupported/synthetic/wrong-key stub fails. Unregistered (MS2b not final-gated yet).
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
EMOJI = "\U0001F600"  # 😀 — a single non-BMP code point (surrogate pair in UTF-16)
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>MS2b Key Coverage</title></head><body>
<input id="inp" type="text">
<script>
  window.__ev = [];
  var inp = document.getElementById('inp'); inp.focus();
  function rec(t) { return function (e) { window.__ev.push({t: t, k: e.key, tr: e.isTrusted}); }; }
  document.addEventListener('keydown', rec('keydown'), true);
  document.addEventListener('keyup', rec('keyup'), true);
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2b-cov-") as tmp:
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

        import json

        def trusted_pair(key):
            ev = json.loads(rpc.evaluate("JSON.stringify(window.__ev)") or "[]")
            down = any(e["t"] == "keydown" and e["k"] == key and e["tr"] is True for e in ev)
            up = any(e["t"] == "keyup" and e["k"] == key and e["tr"] is True for e in ev)
            return down, up

        rpc = None
        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2b-key-coverage-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            try:
                for key in ("Shift", "F1"):
                    rpc.evaluate("window.__ev = []")
                    if rpc.call("dom.press", {"selector": "css=#inp", "key": key, "options": {"input": "native", "timeout_ms": 10000}}) != {"ok": True}:
                        failures.append(f"dom.press {key} did not return ok")
                    down, up = trusted_pair(key)
                    if not (down and up):
                        failures.append(f"dom.press {key}: incomplete trusted down/up (down={down}, up={up})")

                # Non-BMP: one code point typed and inserted.
                rpc.evaluate("document.getElementById('inp').value = ''")
                if rpc.call("dom.type", {"selector": "css=#inp", "text": EMOJI, "options": {"input": "native", "timeout_ms": 10000}}) != {"ok": True}:
                    failures.append("dom.type of a non-BMP emoji did not return ok")
                value = rpc.evaluate("document.getElementById('inp').value")
                if value != EMOJI:
                    failures.append(f"non-BMP value wrong: {value!r} (want the emoji)")
            except AssertionError as exc:
                failures.append(f"native key coverage rejected: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-key-coverage")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-key-coverage")
    return 0


if __name__ == "__main__":
    sys.exit(main())
