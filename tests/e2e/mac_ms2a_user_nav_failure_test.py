#!/usr/bin/env python3
"""MS2a (registered in ms2a-gate) — a page-initiated nav failure after a routed nav is RECORDED, and the browser stays.

RoseCat 38d121a #4: failure suppression must be scoped to the ROUTED navigation's identity, not to the
window. So in a window that has already run a routed navigation, an UNtagged (page-initiated / user)
navigation that fails must still be handled as a real load failure, not silently swallowed.

bd zigBrowser-4pa.55 (V03-F1; owner decision R30.3 #1, option C): "handled" no longer means "the browser
exits". The old oracle asserted the exit, which was the defect: only the primary window's initial load, before
its first finish, may end the session (src/load_failure_policy.zig). Rewritten in the commit that fixes the shim.

Oracle: after a successful routed page.navigate, a page-initiated navigation to an unreachable host (set via
evaluate) is recorded as exactly one LOAD_FAIL row naming that host (not swallowed, not doubled), the browser is
still running after a grace period, and page.list still answers. Each run has a private HOME and its own
--profile-dir.
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
DEAD_HOST = "nonexistent.invalid"
ALIVE_GRACE_SEC = 2.0  # before 4pa.55 the exit followed the LOAD_FAIL row well inside this
PAGES = {
    b"/a": b"<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body><h1>A</h1></body></html>",
    b"/b": b"<!doctype html><html><head><meta charset='utf-8'><title>B</title></head><body><h1>B</h1></body></html>",
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-usernav-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["HOME"] = str(Path(tmp) / "home")  # private HOME: never the account's own profile or caches
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run
        (Path(tmp) / "home").mkdir()
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/a", "--automation-api", "--e2e-protocol",
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
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2a-user-nav-failure-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            # Run a routed navigation first, so the window has been under automation.
            rpc.call("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})

            # Now a PAGE-INITIATED (untagged) navigation to an unreachable host. It must be recorded as a real
            # load failure (one LOAD_FAIL row), not swallowed because the window ran automation, and it must not
            # end the session (4pa.55).
            try:
                rpc.evaluate(f"location.href = 'https://{DEAD_HOST}/'")
            except Exception:
                pass  # the eval may not round-trip cleanly as the page navigates away

            def dead_load_fails() -> int:
                rows = [line.split("\t") for line in list(out)]
                return sum(1 for r in rows if r[0] == "LOAD_FAIL" and len(r) >= 2 and DEAD_HOST in r[1])

            end = time.monotonic() + 10
            while time.monotonic() < end and dead_load_fails() == 0 and proc.poll() is None:
                time.sleep(0.05)
            time.sleep(ALIVE_GRACE_SEC)
            n = dead_load_fails()
            if n != 1:
                failures.append(f"LOAD_FAIL rows for the untagged failure = {n}, want 1 "
                                "(0: swallowed because the window had run a routed nav)")
            rc = proc.poll()
            if rc is not None:
                failures.append(f"the browser exited (rc={rc}) after an untagged page-initiated nav failure "
                                "past its first finish (4pa.55: only the initial load may end the session)")
            else:
                try:
                    reply = rpc.raw("page.list", {})
                    if "error" in reply or reply.get("result") is None:
                        failures.append(f"page.list did not answer after the failure: {reply}")
                except Exception as exc:  # noqa: BLE001 - a closed socket is the defect being caught
                    failures.append(f"page.list did not answer after the failure: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-user-nav-failure")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-user-nav-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
