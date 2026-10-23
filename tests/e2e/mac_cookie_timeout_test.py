#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.56, plan R30-MS3, MS3.3) — macOS cookie calls return at their
deadline when WebKit's cookie store answers late.

zb_cookies_get_all / _add / _delete claim the job (DISPATCHING) and issue an async WKHTTPCookieStore call but
never call zb_job_inflight(job). In DISPATCHING zb_job_wait has no deadline, so the caller's deadline is
ignored for the whole cookie-store round trip and a wedged network process hangs the server thread. Every
other async op (eval, nav, click) calls zb_job_inflight. Fix (plan): call it right after each async submit.

The late store is the e2e-only seam ZB_DEBUG_COOKIE_DELAY_MS (honoured only with --e2e-protocol): it holds
each WKHTTPCookieStore completion that many ms and prints `zb-cookie-delay-hit=<ms>` on stderr.

The deadline: clients cannot pass timeout_ms to cookies.* — the server's cookie routes use a fixed
port_timeout_ms of 10 000 ms (src/automation/cookie_routes.zig). So the plan's "timeout_ms = 500 against a
3000 ms delay, elapsed < 1500" is applied at the real scale: a 12 500 ms delay against the 10 000 ms
deadline. For each of cookies.getAll, cookies.set and cookies.delete:
  1 the reply is the action_timeout error (error.message == "action_timeout"),
  2 it arrives before the store answers: elapsed < 11.5 s (today it waits the full 12.5 s and succeeds),
and after the late completions have run:
  3 live_jobs returns to its baseline (no job leaked by the abandon) and the browser still runs.

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py; the rows gate requires its
RED_SHAPE line): 1 and 2 fail for every op (each returns OK after ~12.5 s); 3 (live_jobs back to baseline, and
the browser still running) passes.
Target step: `ms3-gate` (TO BE ADDED by bd 4pa.62); until the green this file is in no gate script and no
build.zig step. Every launch gets a private HOME and its own --profile-dir.
"""
import argparse
import http.server
import os
import secrets
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_term_teardown import install_term_only_cleanup, leak_failures, stop_browser_term_only  # noqa: E402
from red_shape import FAIL, PASS, RedShape  # noqa: E402

DELAY_MS = 12_500
SERVER_DEADLINE_S = 10.0  # cookie_routes.port_timeout_ms
LATE_BOUND_S = 11.5
TEST_ID = "ms3-cookie-timeout"
OPS = ("cookies.getAll", "cookies.set", "cookies.delete")
RED_VECTOR = {f"{n} {op}": FAIL for op in OPS for n in ("1-action-timeout", "2-at-deadline")}
RED_VECTOR.update({"3-live-jobs-baseline": PASS, "3-browser-running": PASS})
PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>C</title></head><body>c</body></html>"

def e2e_socket_path(default):
    """The automation socket: in ZB_E2E_SOCKET_DIR when the Mac rows gate sets it (a short directory directly in its
    long run root; macOS caps a socket path at 104 bytes and the browser needs an absolute one), else `default`."""
    d = os.environ.get("ZB_E2E_SOCKET_DIR")
    path = Path(d) / f"{secrets.token_hex(3)}.sock" if d else Path(default)
    if sys.platform == "darwin" and len(str(path)) > 103:  # fail closed, never a truncated or relative socket
        raise RuntimeError(f"PRECONDITION socket path is {len(str(path))} bytes, macOS allows 103: {path}")
    return path


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(PAGE)))
                self.end_headers()
                self.wfile.write(PAGE)

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
        self._srv.server_close()


def last_live_jobs(err_lines):
    val = None
    for ln in list(err_lines):
        m = re.search(r"zb-live-jobs=(-?\d+)", ln)
        if m:
            val = int(m.group(1))
    return 0 if val is None else val


def delay_hits(err_lines) -> int:
    return sum(1 for ln in list(err_lines) if ln.startswith("zb-cookie-delay-hit="))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=30.0)  # > DELAY_MS, so today's slow OK is observed
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms3-cookie-timeout-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms3-cktimeout-") as tmp:
        socket_path = e2e_socket_path(Path(tmp) / "automation.sock")
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["HOME"] = str(Path(tmp) / "home")  # private HOME: never the account's own profile or caches
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run (SilverRidge fe4542e)
        (Path(tmp) / "home").mkdir()
        env["ZB_DEBUG_COOKIE_DELAY_MS"] = str(DELAY_MS)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol",
             "--profile-dir", str(Path(tmp) / "profile")],
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
            rpc = RpcClient(socket_path, args.timeout_sec)
            rpc.call("page.url", {"timeout_ms": 10000})
            time.sleep(0.5)
            baseline = last_live_jobs(err)
            ops = (
                ("cookies.getAll", {}),
                ("cookies.set", {"name": "zbt", "value": "v", "domain": "127.0.0.1", "path": "/"}),
                ("cookies.delete", {"name": "zbt", "domain": "127.0.0.1"}),
            )
            for method, params in ops:
                hits_before = delay_hits(err)
                t0 = time.monotonic()
                reply = rpc.raw(method, params)
                elapsed = time.monotonic() - t0
                if delay_hits(err) <= hits_before:
                    raise AssertionError(f"PRECONDITION {method}: the cookie-delay seam never fired")
                message = (reply.get("error") or {}).get("message")
                shape.check(f"1-action-timeout {method}", message == "action_timeout",
                            f"want the action_timeout error, got {reply!r}")
                shape.check(f"2-at-deadline {method}", elapsed < LATE_BOUND_S,
                            f"returned after {elapsed:.1f}s, not at the {SERVER_DEADLINE_S:.0f}s deadline "
                            f"(the store answered at {DELAY_MS / 1000:.1f}s)")

            # Every late completion has run once the delay has passed since the last call was issued.
            settle_end = time.monotonic() + DELAY_MS / 1000.0 + 3.0
            while time.monotonic() < settle_end and last_live_jobs(err) != baseline:
                time.sleep(0.1)
            shape.check("3-live-jobs-baseline", last_live_jobs(err) == baseline,
                        f"live_jobs {last_live_jobs(err)} did not return to baseline {baseline}")
            shape.check("3-browser-running", proc.poll() is None, f"the browser exited (rc={proc.returncode})")
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"{exc!r} (rc={proc.poll()})")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_term_only(proc)

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    eprint(f"stderr={err[-20:]}")
    return shape.report()  # a missing assertion is a failure (rule 7)


if __name__ == "__main__":
    sys.exit(main())
