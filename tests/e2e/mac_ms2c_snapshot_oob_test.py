#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.list/page.health answer from a cache while the MAIN QUEUE is held (RoseCat 6508 #6).

The window snapshot must be lock/atomic-backed and never marshal to a possibly-hung main queue. With the
main thread wedged (the e2e-gated ZB_DEBUG_DISPATCH_HOLD_MS hold, triggered by a page.evaluate on one
socket), page.list and page.health on another socket must still answer PROMPTLY for all windows — they read
the published snapshot under a lock, not the main queue. A build that marshals these reads to the main
queue would block behind the ~4 s hold — the red.
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
HOLD_MS = 4000
PROMPT_BUDGET = 2.0  # an OOB read must finish well within the main-queue hold
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Snap</title></head><body>x</body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-snap-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_DISPATCH_HOLD_MS"] = str(HOLD_MS)  # a page.evaluate wedges the main thread this long
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

        ca = cb = None
        try:
            try:
                ca = RpcClient(socket_path, args.timeout_sec)
                cb = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-snapshot-oob-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            # The snapshot is warm once the primary exists.
            end = time.monotonic() + 6.0
            while time.monotonic() < end:
                ids = [w.get("window_id") for w in ((ca.raw("page.list", {}).get("result") or {}).get("pages") or [])]
                if "window-1" in ids:
                    break
                time.sleep(0.05)

            # conn B: a page.evaluate triggers the main-thread hold (~4 s).
            held = {}

            def hold_main():
                t0 = time.monotonic()
                try:
                    cb.raw("page.evaluate", {"expression": "0"})
                except Exception as exc:  # noqa: BLE001
                    held["exc"] = repr(exc)
                held["elapsed"] = time.monotonic() - t0

            th = threading.Thread(target=hold_main, daemon=True)
            th.start()
            time.sleep(0.4)  # let the hold take the main thread before we time the OOB reads

            # conn A: both OOB reads must answer promptly for all windows while the main queue is wedged.
            t0 = time.monotonic()
            lst = (ca.raw("page.list", {}).get("result") or {}).get("pages") or []
            list_elapsed = time.monotonic() - t0
            if "window-1" not in [w.get("window_id") for w in lst]:
                failures.append(f"page.list did not answer during the main-queue hold: {lst!r}")
            if list_elapsed > PROMPT_BUDGET:
                failures.append(f"page.list blocked {list_elapsed:.1f}s behind the held main queue (not cache-backed)")

            t0 = time.monotonic()
            hp = (ca.raw("page.health", {}).get("result") or {}).get("pages") or []
            health_elapsed = time.monotonic() - t0
            if "window-1" not in [w.get("window_id") for w in hp]:
                failures.append(f"page.health did not answer during the main-queue hold: {hp!r}")
            if health_elapsed > PROMPT_BUDGET:
                failures.append(f"page.health blocked {health_elapsed:.1f}s behind the held main queue (not cache-backed)")

            th.join(timeout=10.0)
            # Sanity: the hold really wedged the main thread (the evaluate took ~HOLD_MS).
            if held.get("elapsed", 0) < (HOLD_MS / 1000.0) - 1.0 and "exc" not in held:
                failures.append(f"the main-queue hold did not take effect (evaluate returned too fast): {held!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            for c in (ca, cb):
                if c is not None:
                    try:
                        c.close()
                    except Exception:
                        pass
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-snapshot-oob")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-snapshot-oob")
    return 0


if __name__ == "__main__":
    sys.exit(main())
