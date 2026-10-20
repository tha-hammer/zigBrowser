#!/usr/bin/env python3
"""MS2b — native key coverage with EXACT ordered trusted events (RoseCat 6426, 6361.4).

Wiring nativeKey/nativeText exposes the whole `router.native_key_names` set plus any single Unicode code
point. This exercises a representative key from each event class and the non-BMP path, and — unlike the
earlier any()-match version (RoseCat 6426) — asserts the COMPLETE ORDERED event list per action, so a
keyup-before-keydown, a duplicate, a missing release, a synthetic/untrusted event, or any extra event
fails:

  - MODIFIER-only keys (Shift/Control/Alt/Meta), synthesized as flagsChanged -> exactly one trusted
    keydown then one trusted keyup, nothing else;
  - FUNCTION keys (F1, F12) and NAVIGATION/EDITING keys (ArrowLeft, Home, End, PageUp, Delete, Backspace,
    Insert) -> the same exact trusted down/up pair, no input event;
  - a NON-BMP code point (emoji) typed via dom.type -> a trusted keydown/keyup pair bracketing a trusted
    input event, and the field holds exactly the one code point.

The exhaustive router<->shim name parity is proven separately and purely by
mac_ms2b_key_table_parity_test.py; this file proves the real trusted delivery per class. Registered in
the two-host MS2b gate.
"""
import argparse
import http.server
import json
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
MODIFIERS = ["Shift", "Control", "Alt", "Meta"]
FUNCTION = ["F1", "F12"]
NAV_EDIT = ["ArrowLeft", "Home", "End", "PageUp", "Delete", "Backspace", "Insert"]
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>MS2b Key Coverage</title></head><body>
<input id="inp" type="text">
<script>
  window.__ev = [];
  var inp = document.getElementById('inp'); inp.focus();
  function rec(t) { return function (e) { window.__ev.push({t: t, k: e.key || "", tr: e.isTrusted}); }; }
  for (var t of ["keydown", "keyup", "input"]) document.addEventListener(t, rec(t), true);
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

        rpc = None

        def events():
            return json.loads(rpc.evaluate("JSON.stringify(window.__ev)") or "[]")

        def assert_all_trusted(ev, label):
            bad = [e for e in ev if not e["tr"]]
            if bad:
                failures.append(f"{label}: untrusted/synthetic event(s) recorded: {bad}")

        def press_pair(key):
            """A named/modifier press must record EXACTLY one trusted keydown then one trusted keyup for
            `key`, in that order, with no input event and nothing else."""
            rpc.evaluate("window.__ev = []")
            if rpc.call("dom.press", {"selector": "css=#inp", "key": key, "options": {"input": "native", "timeout_ms": 10000}}) != {"ok": True}:
                failures.append(f"dom.press {key} did not return ok")
                return
            ev = events()
            assert_all_trusted(ev, f"press {key}")
            seq = [(e["t"], e["k"]) for e in ev]
            if seq != [("keydown", key), ("keyup", key)]:
                failures.append(f"press {key}: event sequence was {seq}, want exactly [keydown {key}, keyup {key}]")

        rpc = None
        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2b-key-coverage-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            for key in MODIFIERS + FUNCTION + NAV_EDIT:
                press_pair(key)

            # Non-BMP: one trusted keydown/keyup pair bracketing one trusted input, one code point inserted.
            rpc.evaluate("window.__ev = []")
            rpc.evaluate("document.getElementById('inp').value = ''")
            if rpc.call("dom.type", {"selector": "css=#inp", "text": EMOJI, "options": {"input": "native", "timeout_ms": 10000}}) != {"ok": True}:
                failures.append("dom.type of a non-BMP emoji did not return ok")
            ev = events()
            assert_all_trusted(ev, "type emoji")
            kd = [e for e in ev if e["t"] == "keydown"]
            ku = [e for e in ev if e["t"] == "keyup"]
            inp = [e for e in ev if e["t"] == "input"]
            if not (len(kd) == 1 and kd[0]["k"] == EMOJI):
                failures.append(f"emoji: want exactly one trusted keydown for the emoji, got {kd}")
            if not (len(ku) == 1 and ku[0]["k"] == EMOJI):
                failures.append(f"emoji: want exactly one trusted keyup for the emoji, got {ku}")
            if len(inp) != 1:
                failures.append(f"emoji: want exactly one trusted input event, got {inp}")
            # Order: keydown precedes input precedes keyup.
            order = [e["t"] for e in ev if e["t"] in ("keydown", "input", "keyup")]
            if order != ["keydown", "input", "keyup"]:
                failures.append(f"emoji: event order was {order}, want [keydown, input, keyup]")
            value = rpc.evaluate("document.getElementById('inp').value")
            if value != EMOJI:
                failures.append(f"non-BMP value wrong: {value!r} (want the emoji)")
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
