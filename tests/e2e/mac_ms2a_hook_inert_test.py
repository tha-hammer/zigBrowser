#!/usr/bin/env python3
"""MS2a RED (registered) — ALL ZB_DEBUG_* test hooks are INERT without --e2e-protocol.

RoseCat: a test hook read from the ambient environment must not change production behavior. Every
ZB_DEBUG_* hook is gated on the app's e2e flag (zb_auto_test_hooks_enabled -> g_active_app.e2eProtocol).
This launches WITHOUT --e2e-protocol but with ALL THREE hook envs set, and proves each production call
site ignores them:
  1. ZB_DEBUG_DISPATCH_HOLD_MS → a routed eval returns promptly (not held).
  2. ZB_DEBUG_REFUSE_NEXT_NAV  → a routed navigation SUCCEEDS (not refused with navigation_failed).
  3. ZB_DEBUG_ACK_FAIL         → a native click SUCCEEDS (not returning Evaluation failed).

Each is a distinct call site, so removing the gate from any one is caught here. (The dispatch-race,
refused-start and ack-error tests prove the SAME hooks DO fire WITH --e2e-protocol, so together they
pin the gate both ways.)
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
HOLD_MS = 1500
BTN = b"<button id='btn' style='width:240px;height:90px'>b</button>"
PAGES = {
    b"/a": b"<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body><h1 id='h'>A</h1>" + BTN + b"</body></html>",
    b"/b": b"<!doctype html><html><head><meta charset='utf-8'><title>B</title></head><body><h1 id='h'>B</h1>" + BTN + b"</body></html>",
}


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        pages = PAGES

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = pages.get(self.path.encode(), b"<title>x</title>")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-inert-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_DISPATCH_HOLD_MS"] = str(HOLD_MS)  # all three hook envs set in the ambient env...
        env["ZB_DEBUG_REFUSE_NEXT_NAV"] = "1"
        env["ZB_DEBUG_ACK_FAIL"] = "1"
        proc = subprocess.Popen(
            # ...but NO --e2e-protocol, so every hook must stay inert.
            [str(browser), f"{fixture.base_url}/a", "--automation-api"],
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
                print("FAIL\tms2a-hook-inert-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness

            # 1. dispatch-hold inert: a routed eval returns promptly and succeeds.
            t0 = time.monotonic()
            try:
                rpc.call("dom.getText", {"selector": "css=#h", "timeout_ms": 10000})
            except Exception as exc:  # noqa: BLE001
                failures.append(f"dom.getText errored with hooks inert: {exc}")
            elapsed = time.monotonic() - t0
            if elapsed >= (HOLD_MS - 700) / 1000.0:
                failures.append(f"dom.getText took {elapsed:.3f}s — the dispatch-hold hook fired without --e2e-protocol")

            # 2. refuse-next-nav inert: a routed navigation SUCCEEDS (not navigation_failed).
            resp = rpc.raw("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})
            if resp.get("result") != {"ok": True}:
                failures.append(f"page.navigate did not succeed with hooks inert (refuse hook fired?): {resp.get('error') or resp}")

            # 3. ack-fail inert: a native click SUCCEEDS (not Evaluation failed).
            resp = rpc.raw("dom.click", {"selector": "css=#btn", "options": {"input": "native", "timeout_ms": 10000}})
            if resp.get("result") != {"ok": True}:
                failures.append(f"dom.click (native) did not succeed with hooks inert (ack-fail hook fired?): {resp.get('error') or resp}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-hook-inert")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-hook-inert")
    return 0


if __name__ == "__main__":
    sys.exit(main())
