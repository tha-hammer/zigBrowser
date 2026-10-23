#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.60, plan R30-MS3 Red 2, MS3.1) — on macOS the pacing (daily-cap)
state survives a restart on a fresh --profile-dir.

The macOS branch of app.applyProfileDir creates no directory, and the pacing store saves
<profile>/automation-pacing.json with atomic_file.replaceJson, which does not create parents. So on a fresh
--profile-dir every save fails ("automation pacing: could not save ...") and the daily caps reset on each
restart. Linux creates the directory.

The plan's red records "one capped action" and checks actions_today == 1 after a restart. A capped action
(x.post, linkedin.*, instagram.*) needs a site page; social.set_pacing reaches the SAME save
(state.changed -> Persister.persist -> pacing_store.save -> replaceJson) into the SAME file, and the
persisted config is restored on restart whatever the day (counts only on the same day). So:
  run 1 on a fresh nested --profile-dir: social.rate_status gives the default cap D (!= 7, else the row is
    vacuous), social.set_pacing {daily_cap: 7} returns ok;
  1 <profile>/automation-pacing.json exists after run 1, and no "could not save" line was logged;
  run 2 on the same --profile-dir:
  2 social.rate_status reports daily_cap == 7 (today: D, because nothing was saved).

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py; the rows gate requires its
RED_SHAPE line): 1-file-exists, 1-no-save-error and 2-cap-restored all fail. Target step: `ms3-gate` (TO BE ADDED by bd 4pa.62); until the green
this file is in no gate script and no build.zig step. Every launch gets a private HOME.
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
from red_shape import FAIL, RedShape  # noqa: E402

TEST_ID = "ms3-profile-pacing-persist"
RED_VECTOR = {"1-file-exists": FAIL, "1-no-save-error": FAIL, "2-cap-restored": FAIL}

NEW_CAP = 7
PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>P</title></head><body>p</body></html>"

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


def run_once(browser: Path, url: str, tmp: Path, profile: Path, run: str, proc_holder: list, timeout_sec: float, act):
    """One browser lifetime on `profile`; `act(rpc)` returns a value. Returns (value, stderr lines)."""
    socket_path = e2e_socket_path(tmp / f"automation-{run}.sock")
    env = dict(os.environ)
    env["ZIGBROWSER_SOCKET"] = str(socket_path)
    env["HOME"] = str(tmp / "home")  # private HOME: never the account's own profile or caches
    env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run (SilverRidge fe4542e)
    proc = subprocess.Popen(
        [str(browser), url, "--automation-api", "--e2e-protocol", "--profile-dir", str(profile)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
    )
    proc_holder[:] = [proc]
    out: list[str] = []
    err: list[str] = []
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
        time.sleep(0.2)  # let the stderr reader drain


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms3-profile-pacing-persist-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms3-pacing-") as tmp_s:
        tmp = Path(tmp_s)
        (tmp / "home").mkdir()
        profile = tmp / "fresh" / "zb-profile"  # nested and not yet existing: a FRESH --profile-dir
        pacing_file = profile / "automation-pacing.json"
        try:
            def first(rpc):
                default_cap = rpc.call("social.rate_status", {}).get("daily_cap")
                ok = rpc.call("social.set_pacing", {"daily_cap": NEW_CAP})
                return default_cap, ok

            (default_cap, ok), err1 = run_once(browser, f"{fixture.base_url}/", tmp, profile, "1", proc_holder,
                                               args.timeout_sec, first)
            if default_cap == NEW_CAP or ok != {"ok": True}:
                raise AssertionError(f"PRECONDITION default cap {default_cap!r} must differ from {NEW_CAP}, "
                                     f"set_pacing must return ok: {ok!r}")
            save_errors = [ln for ln in err1 if "could not save" in ln]
            shape.check("1-file-exists", pacing_file.is_file(), f"after run 1 {pacing_file} does not exist")
            shape.check("1-no-save-error", not save_errors, f"after run 1 save errors={save_errors[-2:]!r}")

            cap2, _err2 = run_once(browser, f"{fixture.base_url}/", tmp, profile, "2", proc_holder,
                                   args.timeout_sec, lambda rpc: rpc.call("social.rate_status", {}).get("daily_cap"))
            shape.check("2-cap-restored", cap2 == NEW_CAP,
                        f"after a restart on the same --profile-dir daily_cap is {cap2!r}, want {NEW_CAP} "
                        f"(the default is {default_cap!r}: the pacing state did not persist)")
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"{exc!r}")

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    return shape.report()  # a missing assertion is a failure (rule 7)


if __name__ == "__main__":
    sys.exit(main())
