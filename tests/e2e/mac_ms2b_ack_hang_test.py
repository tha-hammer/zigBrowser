#!/usr/bin/env python3
"""MS2b RED (unregistered) — a never-acknowledged pair returns BOUNDED, no stuck key (RoseCat 6455).

Native key/text sends the keyDown/keyUp pair across a bounded next-main-queue dispatch (a timer, not a
WebView callback), goes INFLIGHT, and only THEN issues the FIFO ack. So if the web process never
acknowledges (frozen/dead), the ack is abandonable at the command deadline: the ABI must RETURN within a
bound rather than hang forever, and because the keyUp was delivered before INFLIGHT there is no stuck key.

ZB_DEBUG_ACK_HANG makes the per-pair ack a promise that never resolves. Oracle: dom.press returns (an
action_timeout) well within the RPC socket timeout — not a hang — and the page recorded a complete
trusted keydown/keyup pair for the key (no key left down). A build that held the job DISPATCHING across
the ack (the pre-6455 shape) waits with no deadline and hangs forever — the RPC socket times out: the red.
"""
import argparse
import http.server
import json
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
CMD_TIMEOUT_MS = 1000
SOCKET_SEC = 8.0  # > the command deadline, so a correct bounded return arrives but a hang trips it
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>AckHang</title></head><body>
<input id="inp" type="text">
<script>
  window.__ev = [];
  var inp = document.getElementById('inp'); inp.focus();
  for (var t of ["keydown", "keyup"]) document.addEventListener(t, (function (tt) {
    return function (e) { window.__ev.push({t: tt, k: e.key || "", tr: e.isTrusted}); };
  })(t), true);
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
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ackhang-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_ACK_HANG"] = "1"  # the per-pair ack never resolves
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
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
                rpc = RpcClient(socket_path, SOCKET_SEC)
            except Exception as exc:
                print("FAIL\tms2b-ack-hang-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            started = time.monotonic()
            try:
                resp = rpc.raw("dom.press", {"selector": "css=#inp", "key": "a", "options": {"input": "native", "timeout_ms": CMD_TIMEOUT_MS}})
            except Exception as exc:  # a socket timeout here == the ABI hung (the pre-6455 unbounded DISPATCHING)
                failures.append(f"dom.press HUNG (no bounded return) with a never-acknowledged ack: {exc!r}")
                resp = None
            elapsed = time.monotonic() - started
            if resp is not None:
                if elapsed > SOCKET_SEC - 1.0:
                    failures.append(f"dom.press returned only near the socket timeout ({elapsed:.1f}s) — effectively a hang")
                if "error" not in resp or resp["error"].get("code") != -32009:
                    failures.append(f"expected a bounded action_timeout, got: {resp.get('error') or resp.get('result')!r}")
                # The keyUp was delivered before the job went INFLIGHT: the page has a complete trusted
                # pair for 'a' (no stuck key), and the character landed. Reads still work — the hung ack
                # is an unresolved promise, not a blocked web process.
                ev = json.loads(rpc.evaluate("JSON.stringify(window.__ev)") or "[]")
                down = any(e["t"] == "keydown" and e["k"] == "a" and e["tr"] for e in ev)
                up = any(e["t"] == "keyup" and e["k"] == "a" and e["tr"] for e in ev)
                if not (down and up):
                    failures.append(f"incomplete trusted pair for 'a' (down={down}, up={up}) — a key may be stuck: {ev}")
                value = rpc.evaluate("document.getElementById('inp').value")
                if value != "a":
                    failures.append(f"the character did not land: value={value!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-ack-hang")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-ack-hang")
    return 0


if __name__ == "__main__":
    sys.exit(main())
