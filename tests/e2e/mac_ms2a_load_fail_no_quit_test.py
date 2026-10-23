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
    browser stays alive, page.list answers, the fixture really served /attach, and exactly one LOAD_FAIL
    row names /attach (the direct observable of handleLoadFailureForWebView; SilverRidge cd515ce minimum).
    Why not the plan's wording: plan row 3 says "a response the policy cancels", but nav_policy.decide
    returns .use for EVERY response (src/nav_policy.zig, `.response => .use`), so no real response is ever
    cancelled and that case cannot be driven through the production policy. An undisplayable response
    fails the provisional navigation with a non-cancel error and reaches the same
    handleLoadFailureForWebView exit path. Substitute accepted by the orchestrator (2026-10-22); plan fit
    is SilverRidge's ruling.
  4 is tests/e2e/mac_ms2c_recover_slow_server_test.py (recovery reload past the 15 s timer).
  5 the kept contract: the primary window's INITIAL load of a dead host, before any finish, still exits with
    ZB_EXIT_LOAD_FAILED (5) and one LOAD_FAIL row. Flips if the owner picks option B.

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py; the rows gate requires its
RED_SHAPE line): rows 1-3 record their one LOAD_FAIL row (the shim emits it before requestExit:), then .alive fails
with exit code 5 exactly and .page-list-answers is not asked; row 5 passes. Any other outcome is a MISMATCH.

Isolation: every launch gets a private HOME and its own --profile-dir under a per-row temp dir, never the
account's default profile.
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

from automation_core_test import RpcClient  # noqa: E402  (annotations)
from mac_row_session import launch  # noqa: E402
from mac_term_teardown import install_term_only_cleanup, leak_failures  # noqa: E402
from red_shape import PASS, Red, RedShape  # noqa: E402

ZB_EXIT_LOAD_FAILED = 5
DEAD_URL = "http://nonexistent.invalid/"
ALIVE_GRACE_SEC = 2.0  # after the LOAD_FAIL row, today's exit lands well inside this
TEST_ID = "ms2a-load-fail-no-quit"
ROWS = ("row1-click-dead-link", "row2-routed-then-location", "row3-undisplayable-response")
# A failing .alive must have exited with ZB_EXIT_LOAD_FAILED (5), not any other code (SilverRidge 8721b6d).
RED_VECTOR = {f"{row}.{aid}": want for row in ROWS
              for aid, want in (("load-fail-once", PASS), ("alive", Red(5, 8, "exit code 5")),
                                ("page-list-answers", Red("not-asked", "no-answer")))}
RED_VECTOR.update({"row5.exit-code": PASS, "row5.load-fail-once": PASS})
PAGES = {
    "/a": b"<!doctype html><html><head><meta charset='utf-8'><title>A</title></head><body><h1>A</h1>"
          b"<a id='dead' href='" + DEAD_URL.encode() + b"'>dead</a>"
          b"<a id='attach' href='/attach'>attach</a></body></html>",
    "/b": b"<!doctype html><html><head><meta charset='utf-8'><title>B</title></head><body><h1>B</h1></body></html>",
}

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

    def __init__(self, browser: Path, url: str, tmp: Path, proc_holder: list, timeout_sec: float):
        self.socket_path = e2e_socket_path(tmp / "automation.sock")
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        env["HOME"] = str(tmp / "home")  # private HOME: never the account's own profile or caches
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run (SilverRidge fe4542e)
        (tmp / "home").mkdir()
        self.session = LAUNCH([str(browser), url, "--automation-api", "--e2e-protocol", "--profile-dir",
                               str(tmp / "profile")], env, self.socket_path, timeout_sec)
        self.proc, self.out, self.err = self.session.proc, self.session.out, self.session.err
        proc_holder[:] = [self.proc]

    def connect(self):
        return self.session.connect()

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

    def load_fails(self, match) -> int:
        return sum(1 for r in self.rows("LOAD_FAIL") if len(r) >= 2 and match(r[1]))

    def dead_load_fails(self) -> int:
        return self.load_fails(is_dead_url)

    def stop(self):
        self.session.stop()


def is_dead_url(u: str) -> bool:
    return u.startswith(DEAD_URL.rstrip("/"))


def is_attach_url(u: str) -> bool:
    return u.endswith("/attach")


def page_list_answers(rpc: RpcClient) -> bool:
    try:
        reply = rpc.raw("page.list", {})
    except Exception:  # noqa: BLE001 — a closed socket is the defect being caught
        return False
    return "error" not in reply and reply.get("result") is not None


def check_alive(label: str, b: _Browser, rpc: RpcClient, shape: RedShape, fail_match):
    time.sleep(ALIVE_GRACE_SEC)
    n = b.load_fails(fail_match)  # the failure must be recorded exactly once (not swallowed, not doubled)
    shape.check(f"{label}.load-fail-once", n == 1, f"LOAD_FAIL rows for the failing load = {n}, want 1")
    rc = b.proc.poll()
    alive = shape.check(f"{label}.alive", rc is None,
                        f"the browser exited (rc={rc}) after a post-first-finish load failure", observed=rc)
    answers = alive and page_list_answers(rpc)
    shape.check(f"{label}.page-list-answers", answers,
                "page.list did not answer after the load failure" if alive else "not asked: the browser had exited",
                observed="answered" if answers else ("no-answer" if alive else "not-asked"))


def run_row(label: str, browser: Path, fixture, proc_holder: list, timeout_sec: float, act, fail_match,
            shape: RedShape):
    with tempfile.TemporaryDirectory(prefix="zb-loadfail-") as tmp:
        b = _Browser(browser, f"{fixture.base_url}/a", Path(tmp), proc_holder, timeout_sec)
        rpc = None
        try:
            if not b.wait_row("NAV", lambda r: len(r) >= 2 and r[1].endswith("/a"), timeout_sec):
                shape.problem(f"{label}: PRECONDITION the primary window never finished its first load")
                return b
            rpc = b.connect()
            act(rpc, fixture)
            b.wait_row("LOAD_FAIL", lambda r: len(r) >= 2 and fail_match(r[1]), 10.0)
            if fail_match is is_attach_url and "/attach" not in fixture.hits:
                shape.problem(f"{label}: PRECONDITION the page never requested /attach")  # else vacuous
            check_alive(label, b, rpc, shape, fail_match)
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"{label}: unexpected error: {exc!r} (rc={b.proc.poll()})")
        finally:
            if rpc is not None:
                rpc.close()
            b.stop()
    return b


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


def row5_initial_load_exits(browser: Path, proc_holder: list, timeout_sec: float, shape: RedShape) -> _Browser:
    with tempfile.TemporaryDirectory(prefix="zb-loadfail-init-") as tmp:
        b = _Browser(browser, DEAD_URL, Path(tmp), proc_holder, timeout_sec)
        try:
            rc = b.proc.wait(timeout=timeout_sec)
            time.sleep(0.2)  # let the reader threads drain stdout
            shape.check("row5.exit-code", rc == ZB_EXIT_LOAD_FAILED,
                        f"initial-load failure exited rc={rc}, want {ZB_EXIT_LOAD_FAILED}")
            shape.check("row5.load-fail-once", b.dead_load_fails() == 1,
                        f"LOAD_FAIL rows for {DEAD_URL} = {b.dead_load_fails()}, want 1")
        except subprocess.TimeoutExpired:
            shape.problem(f"row5: the primary window's initial-load failure did not exit within {timeout_sec}s")
        finally:
            b.stop()
    return b


LAUNCH = launch  # the browser source; the hostless selftest injects a scripted fake (SilverRidge c78a1f6)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args(argv)
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2a-load-fail-no-quit-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)  # a missing row is a missing assertion (rule 7)

    with _FixtureServer() as fixture:
        for label, act, want in zip(ROWS, (act_click_dead, act_routed_then_location, act_click_attachment),
                                    (is_dead_url, is_dead_url, is_attach_url)):
            b = run_row(label, browser, fixture, proc_holder, args.timeout_sec, act, want, shape)
            eprint(f"{label} stderr={b.err[-12:]}")
        b = row5_initial_load_exits(browser, proc_holder, args.timeout_sec, shape)
        eprint(f"row5 stderr={b.err[-12:]}")

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    return shape.report()


if __name__ == "__main__":
    sys.exit(main())
