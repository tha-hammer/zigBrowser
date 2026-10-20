#!/usr/bin/env python3
"""MS2a.3 — result/error-string ownership: every returned C string is freed exactly once (RoseCat bucket 2, part B).

Exercises the three string outcomes and proves the live caller-returned-string count returns to 0 after each
drains (so nothing leaks and nothing is double-freed):
  - SUCCESS: page.evaluate returns a string (the port frees it via zb_automation_free);
  - JS-ERROR: page.evaluate throws -> an error string (freed via zb_automation_free);
  - ABANDONED-LATE: a page.evaluate whose Promise resolves after its deadline -> the late result is freed on
    the abandon path (never returned).

The balance is read from the e2e-gated `zb-str-live=N` stderr line emitted by zb_auto_dup_tracked/
zb_auto_free_tracked (atomic, off-main safe). An exact oracle (RoseCat): final count must equal the baseline
(0); a leak leaves it >0, a double-free underflows it <0.

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
LATE_EVAL = "(async function(){ await new Promise(function(r){ setTimeout(r, 2000); }); return 'LATE'; })()"
PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>Strings</title></head><body><div id='t'>ready</div></body></html>"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def last_str_live(err_lines):
    val = None
    for ln in err_lines:
        m = re.search(r"zb-str-live=(-?\d+)", ln)  # signed: a double-free shows as negative
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2a-str-") as tmp:
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
                print("FAIL\tms2a-string-ownership-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            time.sleep(0.3)
            baseline = last_str_live(err)
            if baseline is None:
                failures.append("no zb-str-live line emitted (is --e2e-protocol active?)")
                baseline = 0
            elif baseline != 0:
                failures.append(f"string balance not 0 at baseline (a returned string outlived its call?): {baseline}")

            # SUCCESS: a string result, freed by the port.
            r = rpc.raw("page.evaluate", {"expression": "'OK-STRING-' + (1+1)"})
            if "error" in r:
                failures.append(f"success eval errored: {r['error']}")

            # JS-ERROR: an error string, freed by the port.
            e = rpc.raw("page.evaluate", {"expression": "(function(){ throw new Error('boom'); })()"})
            if "error" not in e:
                failures.append(f"JS-error eval did not error: {e.get('result')!r}")

            # ABANDONED-LATE: the late result is freed on the abandon path (not returned).
            rpc.raw("page.evaluate", {"expression": LATE_EVAL, "options": {"timeout_ms": 300}})
            time.sleep(2.7)  # past the 2 s Promise so the late completion's free runs

            # A final op + drain, then the balance must be EXACTLY back to baseline (0).
            rpc.call("page.url", {"timeout_ms": 10000})
            time.sleep(0.3)
            final = last_str_live(err)
            if final is None or final != baseline:
                failures.append(f"string balance did not return EXACTLY to baseline: baseline={baseline} final={final} "
                                f"(>baseline=leak, <baseline=double-free)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-string-ownership")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-string-ownership")
    return 0


if __name__ == "__main__":
    sys.exit(main())
