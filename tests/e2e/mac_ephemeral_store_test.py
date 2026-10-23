#!/usr/bin/env python3
"""macOS e2e-only hook 16, ZB_DEBUG_EPHEMERAL_DATA_STORE (SilverRidge fe4542e): with --e2e-protocol every window
uses ONE non-persistent WKWebsiteDataStore, so a Mac e2e run writes no website data outside its run root (the
default store and the --profile-dir store, dataStoreForIdentifier, live in WebKit's own location under the
account Library).

Two launches on the same in-run --profile-dir, each with the hook, a private HOME and --e2e-protocol:
  1 each launch prints `zb-data-store=ephemeral` exactly once (the shim chose the ephemeral store);
  2 run 1: cookies.set then cookies.getAll shows the cookie (the store works);
  3 run 2: cookies.getAll does NOT show it (nothing persisted across the restart).
Its inert production state (the hook ignored without --e2e-protocol) is a row of mac_ms2a_hook_inert_test.py.
Runs in tests/mac/ms_runtime_rows_gate.sh (the socket goes in its short ZB_E2E_SOCKET_DIR).
"""
import argparse
import http.server
import os
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_term_teardown import install_term_only_cleanup, leak_failures, stop_browser_term_only  # noqa: E402

PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>E</title></head><body>e</body></html>"
COOKIE = "zbeph"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def e2e_socket_path(default):
    """The automation socket: in ZB_E2E_SOCKET_DIR when the Mac rows gate sets it (a short directory directly in its
    long run root; macOS caps a socket path at 104 bytes and the browser needs an absolute one), else `default`."""
    d = os.environ.get("ZB_E2E_SOCKET_DIR")
    path = Path(d) / f"{secrets.token_hex(3)}.sock" if d else Path(default)
    if sys.platform == "darwin" and len(str(path)) > 103:  # fail closed, never a truncated or relative socket
        raise RuntimeError(f"PRECONDITION socket path is {len(str(path))} bytes, macOS allows 103: {path}")
    return path


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


def run_once(browser: Path, url: str, tmp: Path, run: str, proc_holder: list, timeout_sec: float, act):
    socket_path = e2e_socket_path(tmp / f"s{run}.sock")
    env = dict(os.environ)
    env["ZIGBROWSER_SOCKET"] = str(socket_path)
    env["HOME"] = str(tmp / "home")
    env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"
    proc = subprocess.Popen(
        [str(browser), url, "--automation-api", "--e2e-protocol", "--profile-dir", str(tmp / "profile")],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
    )
    proc_holder[:] = [proc]
    out: list = []
    err: list = []
    for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
        threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()
    rpc = None
    try:
        rpc = RpcClient(socket_path, timeout_sec)
        rpc.call("page.url", {"timeout_ms": 10000})
        return act(rpc), err
    finally:
        if rpc is not None:
            rpc.close()
        stop_browser_term_only(proc)
        time.sleep(0.2)


def names(rpc) -> list:
    return [c.get("name") for c in (rpc.call("cookies.getAll", {}) or {}).get("cookies") or []]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms3-ephemeral-store-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list = []
    asserted = 0

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-eph-") as tmp_s:
        tmp = Path(tmp_s)
        (tmp / "home").mkdir()
        try:
            def first(rpc):
                ok = rpc.call("cookies.set", {"name": COOKIE, "value": "v", "domain": "127.0.0.1", "path": "/"})
                return ok, names(rpc)

            (ok, seen1), err1 = run_once(browser, f"{fixture.base_url}/", tmp, "1", proc_holder, args.timeout_sec, first)
            seen2, err2 = run_once(browser, f"{fixture.base_url}/", tmp, "2", proc_holder, args.timeout_sec, names)
            for run, err in (("1", err1), ("2", err2)):
                marks = [ln for ln in err if ln == "zb-data-store=ephemeral"]
                asserted += 1
                if len(marks) != 1:
                    failures.append(f"1 run {run}: zb-data-store=ephemeral printed {len(marks)} times, want 1")
            asserted += 1
            if ok != {"ok": True} or COOKIE not in seen1:
                failures.append(f"2: run 1 could not set and read back the cookie: set={ok!r} seen={seen1!r}")
            asserted += 1
            if COOKIE in seen2:
                failures.append(f"3: the cookie survived the restart, so the store persisted: {seen2!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{exc!r}")

    if asserted != 4 and not failures:
        failures.append(f"ran {asserted} assertions, want 4")  # rule 7
    failures += leak_failures()  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
    if failures:
        print("FAIL\tms3-ephemeral-store")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms3-ephemeral-store")
    return 0


if __name__ == "__main__":
    sys.exit(main())
