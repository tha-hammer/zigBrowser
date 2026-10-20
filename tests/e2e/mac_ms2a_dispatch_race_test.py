#!/usr/bin/env python3
"""MS2a RED (unregistered) — the claim->submit race (RoseCat 6298) is closed by linearization.

The macOS bridge's phase model requires that once a job is DISPATCHING (claimed for submission), a
timed-out waiter CANNOT return until the WebKit submission has linearized (DISPATCHING->INFLIGHT).
This pins that invariant deterministically: the browser is launched with ZB_DEBUG_DISPATCH_HOLD_MS,
which pauses the main thread for that long BETWEEN zb_job_claim_dispatch and callAsyncJavaScript
(wkwebview_shim.c zb_auto_test_dispatch_hold). A routed eval (dom.getText) is then issued with a SHORT
command timeout, far less than the hold.

Oracle (timing): the eval's deadline expires DURING the hold (while DISPATCHING), so a correct bridge
makes the call block until the submission completes — the RPC round trip takes at least ~the hold,
NOT ~the short timeout. A bridge that let the waiter abandon mid-DISPATCHING would return in ~the
timeout. We assert the elapsed wall time, independent of whether the late result or a timeout is
returned, and that the session stays usable afterwards.

Runs ON a Mac (console user, no xvfb), own process group (orphan-safe teardown). Unregistered.
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
TIMEOUT_MS = 300

PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>Race</title></head>" \
       b"<body><h1 id='heading'>Race Page</h1></body></html>"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        page = PAGE

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-race-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_DISPATCH_HOLD_MS"] = str(HOLD_MS)  # pause between the dispatch claim and submission
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
                print("FAIL\tms2a-dispatch-race-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            # Warm up: wait for the page to finish loading (readiness), so the measured eval's PREFLIGHT
            # is immediate and it actually reaches the DISPATCHING claim + hold (page.url uses the
            # readiness path, not the held eval path).
            rpc.call("page.url", {"timeout_ms": 10000})

            # A routed eval with a SHORT timeout, while the bridge holds between claim and submission.
            t0 = time.monotonic()
            try:
                rpc.call("dom.getText", {"selector": "css=#heading", "timeout_ms": TIMEOUT_MS})
            except Exception:
                pass  # a late timeout is acceptable; the invariant under test is the ELAPSED time
            elapsed = time.monotonic() - t0

            # Must have waited through DISPATCHING (~the hold), not returned at ~the short timeout.
            floor = (HOLD_MS - 400) / 1000.0  # generous margin below the 1.5s hold
            if elapsed < floor:
                failures.append(
                    f"dom.getText returned in {elapsed:.3f}s (< {floor:.3f}s): the waiter abandoned "
                    f"mid-DISPATCHING instead of waiting for the submission to linearize")

            # Session still usable after the held op.
            try:
                url = rpc.call("page.url")["url"]
                if not url.startswith("http://127.0.0.1"):
                    failures.append(f"page.url after the held op looks wrong: {url!r}")
            except Exception as exc:  # noqa: BLE001
                failures.append(f"session unusable after the held op: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-dispatch-race")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-dispatch-race")
    return 0


if __name__ == "__main__":
    sys.exit(main())
