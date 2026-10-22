#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.55, plan R30-MS2 rows 1, 2, 3, 5) — a failed page load after the
primary window's first finish must NOT quit the macOS browser.

The shim exits the whole app (`requestExit:ZB_EXIT_LOAD_FAILED`) for every load failure that is not a
tagged automation navigation (wkwebview_shim.m handleLoadFailureForWebView). Linux records the failure and
keeps running (webkit_shim.c on_window_load_failed). Owner decision R30.3 #1, default option C: quit ONLY
for the primary window's INITIAL load, before its first finish.

This file replaces the oracle of tests/e2e/mac_ms2a_user_nav_failure_test.py, which asserts the exit and so
encodes the defect. The green moves this file over that one (same gate, `ms2a-gate`). Until then this file
is in no gate script and no build.zig step.

Rows (each in a fresh browser, because today the first failure ends the process):
  1 after the first finish, a click on a link to a dead host: the browser stays alive, page.list answers,
    and exactly one LOAD_FAIL row names the dead host (the failure is recorded, not swallowed).
  2 after a ROUTED page.navigate, the page script sets `location` to a dead host: same assertions. This keeps
    RoseCat 38d121a #4: an untagged failure in a window that ran a routed nav is still reported.
  3 after the first finish, a click on a link whose response WebKit cannot display (an attachment): the
    browser stays alive and page.list answers. The plan's row 3 says "a response the policy cancels", but
    nav_policy.decide returns .use for every response, so no real response is ever cancelled; an
    undisplayable response reaches the same failure handler (reported to the orchestrator).
  4 is tests/e2e/mac_ms2c_recover_slow_server_test.py (recovery reload past the 15 s timer).
  5 the kept contract: the primary window's INITIAL load of a dead host, before any finish, still exits with
    ZB_EXIT_LOAD_FAILED (5) and one LOAD_FAIL row. Flips if the owner picks option B.

Failing assertions today (Mac): rows 1-3 `proc.poll() is None` (the process has exited with 5).
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

ZB_EXIT_LOAD_FAILED = 5
DEAD_URL = "http://nonexistent.invalid/"
ALIVE_GRACE_SEC = 2.0  # after the LOAD_FAIL row, today's exit lands well inside this
PAGES = {
    "/a": b"<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body><h1>A</h1>"
          b"<a id='dead' href='" + DEAD_URL.encode() + b"'>dead</a>"
          b"<a id='attach' href='/attach'>attach</a></body></html>",
    "/b": b"<!doctype html><html><head><meta charset='utf-8'><title>B</title></head><body><h1>B</h1></body></html>",
}


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        self.hits: list[str] = []
        fixture = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.hits.append(self.path)
                if self.path == "/attach":
                    body = b"\x00\x01binary-not-a-page\x02\x03"
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Disposition", "attachment; filename=zb.bin")
                else:
                    body = PAGES.get(self.path, b"<title>x</title>")
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
        self._srv.server_close()


class _Browser:
    """One browser process with --automation-api and --e2e-protocol (the LOAD_FAIL/NAV rows)."""

    def __init__(self, browser: Path, url: str, tmp: Path, proc_holder: list):
        self.socket_path = tmp / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        self.proc = subprocess.Popen(
            [str(browser), url, "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder[:] = [self.proc]
        self.out: list[str] = []
        self.err: list[str] = []
        for stream, buf in ((self.proc.stdout, self.out), (self.proc.stderr, self.err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

    def rows(self, tag: str) -> list[list[str]]:
        return [line.split("\t") for line in list(self.out) if line.split("\t", 1)[0] == tag]

    def wait_row(self, tag: str, pred, timeout_sec: float) -> bool:
        end = time.monotonic() + timeout_sec
        while time.monotonic() < end:
            if any(pred(r) for r in self.rows(tag)):
                return True
            if self.proc.poll() is not None:
                return any(pred(r) for r in self.rows(tag))
            time.sleep(0.05)
        return False

    def dead_load_fails(self) -> int:
        return sum(1 for r in self.rows("LOAD_FAIL") if len(r) >= 2 and r[1].startswith(DEAD_URL.rstrip("/")))

    def stop(self):
        stop_browser_macos(self.proc)


def page_list_answers(rpc: RpcClient) -> bool:
    try:
        reply = rpc.raw("page.list", {})
    except Exception:  # noqa: BLE001 — a closed socket is the defect being caught
        return False
    return "error" not in reply and reply.get("result") is not None


def check_alive(label: str, b: _Browser, rpc: RpcClient, failures: list[str], want_dead_fails: int | None):
    time.sleep(ALIVE_GRACE_SEC)
    rc = b.proc.poll()
    if rc is not None:
        failures.append(f"{label}: the browser exited (rc={rc}) after a post-first-finish load failure")
        return
    if not page_list_answers(rpc):
        failures.append(f"{label}: page.list did not answer after the load failure")
    if want_dead_fails is not None and b.dead_load_fails() != want_dead_fails:
        failures.append(f"{label}: LOAD_FAIL rows for {DEAD_URL} = {b.dead_load_fails()}, want {want_dead_fails}")


def run_row(label: str, browser: Path, fixture, proc_holder: list, timeout_sec: float, act, want_dead_fails):
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-loadfail-") as tmp:
        b = _Browser(browser, f"{fixture.base_url}/a", Path(tmp), proc_holder)
        rpc = None
        try:
            if not b.wait_row("NAV", lambda r: len(r) >= 2 and r[1].endswith("/a"), timeout_sec):
                failures.append(f"{label}: PRECONDITION the primary window never finished its first load")
                return failures, b
            rpc = RpcClient(b.socket_path, timeout_sec)
            act(rpc, fixture)
            if want_dead_fails is not None:
                b.wait_row("LOAD_FAIL", lambda r: len(r) >= 2 and r[1].startswith(DEAD_URL.rstrip("/")), 10.0)
            else:
                time.sleep(3.0)  # give the undisplayable response time to fail
                if "/attach" not in fixture.hits:  # the row is vacuous unless the response was really fetched
                    failures.append(f"{label}: PRECONDITION the page never requested /attach")
            check_alive(label, b, rpc, failures, want_dead_fails)
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{label}: unexpected error: {exc!r} (rc={b.proc.poll()})")
        finally:
            if rpc is not None:
                rpc.close()
            b.stop()
    return failures, b


def act_click_dead(rpc: RpcClient, fixture) -> None:
    try:
        rpc.evaluate("(document.getElementById('dead').click(), true)")
    except Exception:  # noqa: BLE001 — the eval may not round-trip as the page starts to navigate
        pass


def act_routed_then_location(rpc: RpcClient, fixture) -> None:
    rpc.call("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 10000})
    try:
        rpc.evaluate(f"(location.href = '{DEAD_URL}', true)")
    except Exception:  # noqa: BLE001
        pass


def act_click_attachment(rpc: RpcClient, fixture) -> None:
    try:
        rpc.evaluate("(document.getElementById('attach').click(), true)")
    except Exception:  # noqa: BLE001
        pass


def row5_initial_load_exits(browser: Path, proc_holder: list, timeout_sec: float) -> tuple[list[str], _Browser]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="zb-loadfail-init-") as tmp:
        b = _Browser(browser, DEAD_URL, Path(tmp), proc_holder)
        try:
            rc = b.proc.wait(timeout=timeout_sec)
            time.sleep(0.2)  # let the reader threads drain stdout
            if rc != ZB_EXIT_LOAD_FAILED:
                failures.append(f"row5: initial-load failure exited rc={rc}, want {ZB_EXIT_LOAD_FAILED}")
            if b.dead_load_fails() != 1:
                failures.append(f"row5: LOAD_FAIL rows for {DEAD_URL} = {b.dead_load_fails()}, want 1")
        except subprocess.TimeoutExpired:
            failures.append(f"row5: the primary window's initial-load failure did not exit within {timeout_sec}s")
        finally:
            b.stop()
    return failures, b


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2a-load-fail-no-quit-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    asserts = 0

    with _FixtureServer() as fixture:
        for label, act, want in (
            ("row1-click-dead-link", act_click_dead, 1),
            ("row2-routed-then-location", act_routed_then_location, 1),
            ("row3-undisplayable-response", act_click_attachment, None),
        ):
            f, b = run_row(label, browser, fixture, proc_holder, args.timeout_sec, act, want)
            asserts += 1
            if f:
                eprint(f"{label} stderr={b.err[-12:]}")
            else:
                print(f"PASS\t{label}")
            failures += f
        f, b = row5_initial_load_exits(browser, proc_holder, args.timeout_sec)
        asserts += 1
        if f:
            eprint(f"row5 stderr={b.err[-12:]}")
        else:
            print("PASS\trow5-initial-load-exits")
        failures += f

    if asserts != 4:
        failures.append(f"ran {asserts} rows, want 4")  # zero or missing rows is a failure (rule 7)
    if failures:
        print("FAIL\tms2a-load-fail-no-quit")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms2a-load-fail-no-quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
