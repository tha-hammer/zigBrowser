#!/usr/bin/env python3
"""MS2a.3 — a completion arriving AFTER the deadline is dropped (RoseCat 4981d66 bucket 2, part A).

A page.evaluate whose JS Promise resolves ~2 s later is issued with a 300 ms deadline (options.timeout_ms).
The waiter abandons at the deadline (INFLIGHT -> ABANDONED) and returns the EXACT action_timeout. When the JS
finally resolves, zb_job_complete records nothing on the abandoned job (it frees the late result) and the job
unrefs. Asserts:
  - the eval returns exactly action_timeout (-32009), promptly (~the deadline, not ~the 2 s JS);
  - NO late/second response is ever emitted for that request id: follow-up RPCs AFTER the JS would have
    resolved still get THEIR own matching responses (RpcClient.raw validates the id, so a stray late frame
    would desync and raise);
  - live jobs return to baseline after the late completion arrives (the e2e-gated `zb-live-jobs=N` stderr
    line from zb_job_new/unref).

(Requires page.evaluate to honor options.timeout_ms — see the router page_evaluate case.)
Runs ON a Mac (console user, no xvfb), own process group, killpg teardown.
"""
import argparse
import http.server
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
ACTION_TIMEOUT = -32009
DEADLINE_MS = 300
JS_DELAY_MS = 2000
LATE_EVAL = ("(async function(){ await new Promise(function(r){ setTimeout(r, %d); }); return 'LATE-RESULT'; })()"
             % JS_DELAY_MS)
PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>Late</title></head><body><div id='t'>ready</div></body></html>"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def last_live_jobs(err_lines):
    val = None
    for ln in err_lines:
        m = re.search(r"zb-live-jobs=(\d+)", ln)
        if m:
            val = int(m.group(1))
    return val


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2a-late-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
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
                print("FAIL\tms2a-late-completion-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            time.sleep(0.3)
            baseline = last_live_jobs(err)
            if baseline is None:
                failures.append("no zb-live-jobs line emitted (is --e2e-protocol active?)")
                baseline = 0

            t0 = time.monotonic()
            resp = rpc.raw("page.evaluate", {"expression": LATE_EVAL, "options": {"timeout_ms": DEADLINE_MS}})
            elapsed = time.monotonic() - t0
            err_obj = resp.get("error")
            if err_obj is None or err_obj.get("code") != ACTION_TIMEOUT:
                failures.append(f"late eval did not return action_timeout: {resp.get('error') or resp.get('result')!r}")
            if elapsed > 1.0:
                failures.append(f"late eval blocked {elapsed:.2f}s — it waited for the ~2 s JS instead of abandoning at the {DEADLINE_MS} ms deadline (page.evaluate not honoring options.timeout_ms?)")

            u = rpc.call("page.url", {"timeout_ms": 10000})["url"]
            if not u.startswith("http://127.0.0.1"):
                failures.append(f"follow-up page.url wrong right after the timeout: {u!r}")

            time.sleep((JS_DELAY_MS / 1000.0) + 0.7)
            for _ in range(3):
                got = rpc.call("page.url", {"timeout_ms": 10000})["url"]  # raw() raises on id mismatch -> a stray late frame fails here
                if not got.startswith("http://127.0.0.1"):
                    failures.append(f"a late eval frame desynced the stream (got {got!r})")
                    break

            time.sleep(0.3)
            final = last_live_jobs(err)
            if final is None or final > baseline:
                failures.append(f"live jobs did not return to baseline after the late completion: baseline={baseline} final={final}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error (possible stray late response desyncing the stream): {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-late-completion")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-late-completion")
    return 0


if __name__ == "__main__":
    sys.exit(main())
