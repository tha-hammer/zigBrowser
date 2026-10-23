#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.58, plan R30-MS2 new sub-slice MS2c.6) — the native close button of
a popup must reach the automation registry.

Windows are created closable (wkwebview_shim.m, NSWindowStyleMaskClosable) but ZBWindowHost is not an
NSWindowDelegate and nothing handles windowWillClose:. So the red close button only hides the NSWindow:
the WKWebView keeps running, stays in app.windows, still appears in page.list and still answers automation.

The close is driven through the e2e-only seam ZB_DEBUG_NATIVE_CLOSE_ON_TITLE (honoured only with
--e2e-protocol, like every ZB_DEBUG_* hook): when a page sets document.title to that exact value, the shim
prints `NATIVE_CLOSE <id>` and calls -[NSWindow performClose:] on that window, the same AppKit path a click
on the red close button takes (no Accessibility/TCC needed). The test sets the title through a routed
page.evaluate on the popup, so it controls the moment of the close.

Given a popup opened by window.open; When its NSWindow is closed through its close control; Then
  1 the popup leaves page.list,
  2 a command routed to its id fails with reason "no_window" (the error Linux returns for a closed window,
    observed 2026-10-22 with a real WM_DELETE_WINDOW on the Linux build; the plan's text says
    "window_gone", which no code path returns: reported to the orchestrator and SilverRidge),
  3 live_jobs returns to its baseline,
  4 the opener's URL and DOM survive and the browser keeps running,
  5 the shared destroy path ran: the last WINCOUNT row is 1 (removeWindow:, as webViewDidClose: uses).

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py; the rows gate requires its
RED_SHAPE line): 1 fails with the popup still listed, 2 with a result (the popup still answers), 5 with the last
row WINCOUNT 2; 3 and 4 pass.
Target step: `ms2c-gate` (TO BE ADDED by bd 4pa.62). Until the green this file is in no gate script and no
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

from mac_row_session import launch  # noqa: E402
from mac_term_teardown import install_term_only_cleanup, leak_failures  # noqa: E402
from red_shape import PASS, Red, RedShape, reply_kind  # noqa: E402

CLOSE_TITLE = "zb-native-close"
LAUNCH = launch  # the browser source; the hostless selftest injects a scripted fake (SilverRidge c78a1f6)
TEST_ID = "ms2c-close-button"
# The accepted red values (SilverRidge 8721b6d): the hidden popup is still listed, a command routed to it still gets
# a result, and the last WINCOUNT row still counts it (2).
RED_VECTOR = {"1-left-page-list": Red("listed", "not-listed"), "2-routed-no-window": Red("result", "error:timeout"),
              "3-live-jobs-baseline": PASS, "4-opener-intact": PASS,
              "5-shared-destroy-path": Red("WINCOUNT\t2", "WINCOUNT\t3")}
PAGES = {
    "/a": b"<!doctype html><html><head><meta charset='utf-8'><title>OPENER</title></head>"
          b"<body><p id='t'>opener-dom</p></body></html>",
    "/p": b"<!doctype html><html><head><meta charset='utf-8'><title>POPUP</title></head><body>p</body></html>",
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
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
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


# The row-owned recording functions (SilverRidge cf16730): main hands each the RAW observation; the hostless
# selftest (mac_red_shape_selftest.py) drives the same functions with today's Mac observations and with wrong ones.
def record_listed(shape: RedShape, popup_id: str, ids: list) -> None:
    shape.check("1-left-page-list", popup_id not in ids,
                f"the natively closed popup {popup_id} is still in page.list: {ids!r}",
                observed="listed" if popup_id in ids else "not-listed")


def record_routed(shape: RedShape, reply: dict) -> None:
    reason = ((reply.get("error") or {}).get("data") or {}).get("reason") if isinstance(reply, dict) else None
    shape.check("2-routed-no-window", reason == "no_window",
                f"a command routed to the closed popup did not fail with no_window: {reply!r}",
                observed=reply_kind(reply))


def record_destroy(shape: RedShape, out_lines: list) -> None:
    wincount = [l for l in list(out_lines) if l.startswith("WINCOUNT\t")]
    shape.check("5-shared-destroy-path", bool(wincount) and wincount[-1] == "WINCOUNT\t1",
                f"the shared destroy path did not run (WINCOUNT rows {wincount[-4:]!r})",
                observed=wincount[-1] if wincount else None)


def last_live_jobs(err_lines):
    val = None
    for ln in list(err_lines):
        m = re.search(r"zb-live-jobs=(-?\d+)", ln)
        if m:
            val = int(m.group(1))
    return 0 if val is None else val  # no job ever created -> 0 live


def wait_until(pred, timeout_sec: float, step: float = 0.05) -> bool:
    end = time.monotonic() + timeout_sec
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args(argv)
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2c-close-button-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-closebtn-") as tmp:
        socket_path = e2e_socket_path(Path(tmp) / "automation.sock")
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["HOME"] = str(Path(tmp) / "home")  # private HOME: never the account's own profile or caches
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run (SilverRidge fe4542e)
        (Path(tmp) / "home").mkdir()
        env["ZB_DEBUG_NATIVE_CLOSE_ON_TITLE"] = CLOSE_TITLE
        session = LAUNCH([str(browser), f"{fixture.base_url}/a", "--automation-api", "--e2e-protocol",
                          "--profile-dir", str(Path(tmp) / "profile")], env, socket_path, args.timeout_sec)
        proc, out, err = session.proc, session.out, session.err
        proc_holder.append(proc)
        try:
            rpc = session.connect()

            def pages():
                return (rpc.call("page.list", {}) or {}).get("pages") or []

            def page_list_ids():
                return [p.get("window_id") for p in pages()]

            rpc.call("page.url", {"timeout_ms": 10000})
            opener_url = rpc.call("page.url", {"timeout_ms": 10000}).get("url")
            rpc.evaluate("(window.open('/p'), true)")
            if not wait_until(lambda: any(p.get("title") == "POPUP" for p in pages()), 10.0):
                raise AssertionError(f"PRECONDITION the popup never appeared in page.list: {pages()!r}")
            popup_id = next(p.get("window_id") for p in pages() if p.get("title") == "POPUP")
            popup_num = popup_id.rsplit("-", 1)[-1]
            time.sleep(0.5)
            baseline = last_live_jobs(err)

            # The routed eval sets the title; the seam then runs performClose: on the popup's NSWindow.
            try:
                rpc.raw("page.evaluate", {"window_id": popup_id, "expression": f"(document.title = '{CLOSE_TITLE}', true)"})
            except Exception:  # noqa: BLE001 — the reply may race the close
                pass
            if not wait_until(lambda: any(l == f"NATIVE_CLOSE\t{popup_num}" for l in list(out)), 5.0):
                raise AssertionError("PRECONDITION the native close seam never fired (no NATIVE_CLOSE row)")

            wait_until(lambda: popup_id not in page_list_ids(), 3.0)
            record_listed(shape, popup_id, page_list_ids())
            record_routed(shape, rpc.raw("page.title", {"window_id": popup_id}))

            settled = wait_until(lambda: last_live_jobs(err) == baseline, 3.0)
            shape.check("3-live-jobs-baseline", settled,
                        f"live_jobs {last_live_jobs(err)} did not return to baseline {baseline}")

            if proc.poll() is not None:
                shape.check("4-opener-intact", False, f"the browser exited (rc={proc.returncode}) when a popup was closed")
            else:
                url_after = rpc.call("page.url", {"timeout_ms": 10000}).get("url")
                dom_after = rpc.evaluate("document.getElementById('t').textContent")
                shape.check("4-opener-intact", url_after == opener_url and dom_after == "opener-dom",
                            f"the opener changed: url {url_after!r} (was {opener_url!r}), dom {dom_after!r}")

            record_destroy(shape, out)
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"{exc!r} (rc={proc.poll()})")
        finally:
            session.stop()

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    eprint(f"stderr={err[-20:]}")
    return shape.report()  # a missing assertion is a failure (rule 7)


if __name__ == "__main__":
    sys.exit(main())
