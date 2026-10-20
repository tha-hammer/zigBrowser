#!/usr/bin/env python3
"""MS2a — the claim->submit race (RoseCat 6298/6325) is closed by linearization, proven by an OBSERVABLE effect.

The macOS bridge's phase model requires that once a job is DISPATCHING (claimed for submission), a timed-out
waiter CANNOT return until the WebKit submission has linearized (DISPATCHING->INFLIGHT). The browser is
launched with ZB_DEBUG_DISPATCH_HOLD_MS, which pauses the main thread BETWEEN zb_job_claim_dispatch and
callAsyncJavaScript (wkwebview_shim.m zb_auto_test_dispatch_hold). The held operation is a page.evaluate with
a SHORT deadline (far below the hold) that performs a HARMLESS OBSERVABLE DOM EFFECT: it sets #heading to
"SUBMITTED".

Oracle (not just timing, RoseCat 6325 item 2):
  - the held eval's deadline expires DURING the hold, so it returns the EXACT action_timeout error (-32009);
  - but the submission still linearizes, so AFTER the hold #heading reads "SUBMITTED" — proving the eval was
    actually submitted (callAsyncJavaScript ran), not merely slept;
  - the session stays usable.
A bridge (or mutant) that claims, sleeps, marks in-flight, and never calls callAsyncJavaScript would return
in ~the hold with the right timeout, but #heading would stay "Race Page" — red.

Runs ON a Mac (console user, no xvfb), own process group (orphan-safe teardown).
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
ACTION_TIMEOUT = -32009  # errors.downstreamCode(.action_timeout)

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
            # --e2e-protocol gates the ZB_DEBUG_* test hooks on; without it the hold env is inert.
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
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2a-dispatch-race-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-20:]}")
                return 1

            # Warm up: wait for the page to finish loading (readiness path, not the held dispatch path).
            rpc.call("page.url", {"timeout_ms": 10000})

            # The held op: a page.evaluate with a harmless observable DOM effect, SHORT deadline (< the hold).
            t0 = time.monotonic()
            resp = rpc.raw("page.evaluate", {
                # An IIFE so it is valid whether the bridge wraps it in `return (...)` or runs it as a
                # statement; the DOM write is the harmless observable effect.
                "expression": "(function(){ document.getElementById('heading').textContent = 'SUBMITTED'; return 'SUBMITTED'; })()",
                # options.timeout_ms (honored since the router page_evaluate parse): the 300 ms deadline
                # expires DURING the 1500 ms DISPATCHING hold, so the waiter is forced to wait for the
                # submission to linearize — a real claim->timeout race, not just a submission proof (RoseCat 6767).
                "options": {"timeout_ms": TIMEOUT_MS},
            })
            elapsed = time.monotonic() - t0

            # 1) EXACT terminal: the waiter cannot abandon mid-DISPATCHING, so once the submission linearizes
            #    the result is delivered — a clean success — or, if the (already-passed) deadline is re-checked
            #    first at INFLIGHT, the exact action_timeout (-32009). Any OTHER error (e.g. a JS -32603) means
            #    the submission misbehaved. Not a broad `except`: exactly one of these two named outcomes.
            err_obj = resp.get("error")
            if err_obj is not None and err_obj.get("code") != ACTION_TIMEOUT:
                failures.append(f"held page.evaluate terminal was neither success nor action_timeout: {err_obj!r}")

            # 2) Must have waited through DISPATCHING (~the hold), not abandoned at ~the short timeout.
            floor = (HOLD_MS - 400) / 1000.0
            if elapsed < floor:
                failures.append(f"page.evaluate returned in {elapsed:.3f}s (< {floor:.3f}s): the waiter abandoned mid-DISPATCHING")

            # 3) OBSERVABLE EFFECT: the submission linearized, so #heading now reads SUBMITTED. If the bridge
            #    sleeps but never calls callAsyncJavaScript, this stays "Race Page" -> red. (This read itself
            #    goes through the hold too, so give it a generous deadline.)
            r = rpc.raw("dom.getText", {"selector": "css=#heading", "options": {"timeout_ms": HOLD_MS + 6000}})
            if "error" in r:
                failures.append(f"post-hold dom.getText errored: {r['error']}")
            else:
                text = (r.get("result") or {}).get("text")
                if text != "SUBMITTED":
                    failures.append(f"the held eval was NOT submitted: #heading is {text!r}, not 'SUBMITTED' "
                                    f"(claim+sleep+mark-inflight without callAsyncJavaScript)")

            # 4) Session still usable.
            try:
                url = rpc.call("page.url", {"timeout_ms": HOLD_MS + 6000})["url"]
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
