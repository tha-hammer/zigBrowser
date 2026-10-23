#!/usr/bin/env python3
"""RED (UNREGISTERED; bd zigBrowser-4pa.57, plan R30-MS2, MS2b.2) — a dialog in a later popup is listed
under that popup's STABLE window id.

zb_automation_list_dialogs emits `"window": idx+1`, the window's POSITION in the registry
(wkwebview_shim.m), but zb_automation_respond_dialog, list_windows and the GTK shim (win->auto_id) all use
the stable windowId. After popup window-2 closes, a confirm() in window-3 is listed as window-2: dialog.get
names the wrong window, dialog.get on window-3 says {open:false}, and answering the listed window fails.

Steps: open two popups (window-2, window-3), page.close window-2, raise a confirm() in window-3. Then
  1 dialog.get {} reports the dialog with window_id == window-3 (the id page.list gives it),
  2 dialog.get {window_id: window-3} reports it open, type confirm,
  3 dialog.respond {window_id: <the listed id>, accept: true} returns {"ok": true},
  4 the page's confirm() returned true.

Failing assertions today (Mac), the accepted red vector RED_VECTOR (red_shape.py; the rows gate requires its
RED_SHAPE line): all four fail, with exactly these values: 1 listed as window-2, 2 open=False, 3 error:no_window,
4 not-true (still unanswered).
Target step: `ms2b-gate` (TO BE ADDED by bd 4pa.62); until the green this file is in no gate script and no
build.zig step. Every launch gets a private HOME and its own --profile-dir.
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
from red_shape import Red, RedShape, reply_kind  # noqa: E402

TEST_ID = "ms2b-dialog-popup-id"
# The accepted red values (SilverRidge 8721b6d): listed under the registry POSITION window-2, dialog.get on window-3
# says not open, answering window-2 fails with no_window, and the page's confirm() never returns true.
RED_VECTOR = {"1-listed-under-stable-id": Red("window-2", "window-1"), "2-get-by-id-open": Red("open=False", "open=None"),
              "3-respond-listed-ok": Red("error:no_window", "error:timeout"),
              "4-confirm-returned-true": Red("not-true", "true")}

PAGES = {
    "/a": b"<!doctype html><html><head><meta charset='utf-8'><title>OPENER</title></head><body>o</body></html>",
    "/p1": b"<!doctype html><html><head><meta charset='utf-8'><title>P1</title></head><body>p1</body></html>",
    "/p2": b"<!doctype html><html><head><meta charset='utf-8'><title>P2</title></head><body>p2</body></html>",
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
def record_listed(shape: RedShape, listed: dict, third: str) -> None:
    shape.check("1-listed-under-stable-id", listed.get("window_id") == third,
                f"dialog.get listed the confirm under {listed.get('window_id')!r}, page.list id is {third!r}",
                observed=listed.get("window_id"))


def record_by_id(shape: RedShape, by_id, third: str) -> None:
    shape.check("2-get-by-id-open",
                isinstance(by_id, dict) and bool(by_id.get("open")) and by_id.get("type") == "confirm",
                f"dialog.get on {third} did not report the open confirm: {by_id!r}",
                observed=f"open={by_id.get('open')!r}" if isinstance(by_id, dict) else repr(by_id))


def record_respond(shape: RedShape, answered: dict) -> None:
    shape.check("3-respond-listed-ok", answered.get("result") == {"ok": True},
                f"answering the listed window failed: {answered!r}", observed=reply_kind(answered))


def record_confirm(shape: RedShape, ok: bool) -> None:
    shape.check("4-confirm-returned-true", ok, "the page's confirm() did not return true",
                observed="true" if ok else "not-true")


def wait_until(pred, timeout_sec: float, step: float = 0.05) -> bool:
    end = time.monotonic() + timeout_sec
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2b-dialog-popup-id-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    install_term_only_cleanup(lambda: proc_holder[0] if proc_holder else None)
    shape = RedShape(TEST_ID, RED_VECTOR)

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2b-dlgid-") as tmp:
        socket_path = e2e_socket_path(Path(tmp) / "automation.sock")
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["HOME"] = str(Path(tmp) / "home")  # private HOME: never the account's own profile or caches
        env["ZB_DEBUG_EPHEMERAL_DATA_STORE"] = "1"  # e2e-only hook 16: no website data written outside the run (SilverRidge fe4542e)
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
        third = None
        try:
            rpc = RpcClient(socket_path, args.timeout_sec)

            def pages():
                return (rpc.call("page.list", {}) or {}).get("pages") or []

            def id_of(title):
                return next((p.get("window_id") for p in pages() if p.get("title") == title), None)

            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.evaluate("(window.open('/p1'), window.open('/p2'), true)")
            if not wait_until(lambda: id_of("P1") and id_of("P2"), 10.0):
                raise AssertionError(f"PRECONDITION the two popups never appeared: {pages()!r}")
            second, third = id_of("P1"), id_of("P2")
            if rpc.raw("page.close", {"window_id": second}).get("result") != {"ok": True}:
                raise AssertionError(f"PRECONDITION page.close {second} did not return ok")
            if not wait_until(lambda: second not in [p.get("window_id") for p in pages()], 5.0):
                raise AssertionError(f"PRECONDITION {second} still listed after page.close: {pages()!r}")
            ids = [p.get("window_id") for p in pages()]
            if third not in ids or ids.index(third) != len(ids) - 1:
                raise AssertionError(f"PRECONDITION {third} is not the last listed window: {ids!r}")

            # The confirm opens after this evaluate returns (setTimeout), then blocks window-3's page.
            rpc.raw("page.evaluate", {"window_id": third, "expression":
                                      "(setTimeout(function(){ window.__zbR = confirm('zb-dlg-id?'); }, 50), true)"})
            listed = None
            end = time.monotonic() + 5.0
            while time.monotonic() < end:
                listed = rpc.raw("dialog.get", {}).get("result")
                if isinstance(listed, dict) and listed.get("open"):
                    break
                time.sleep(0.05)
            if not (isinstance(listed, dict) and listed.get("open") and listed.get("type") == "confirm"):
                raise AssertionError(f"PRECONDITION the confirm never opened: {listed!r}")

            record_listed(shape, listed, third)
            record_by_id(shape, rpc.raw("dialog.get", {"window_id": third}).get("result"), third)
            record_respond(shape, rpc.raw("dialog.respond", {"window_id": listed.get("window_id") or third,
                                                             "accept": True}))

            ok = wait_until(lambda: rpc.raw("page.evaluate", {"window_id": third, "expression": "window.__zbR === true"}).get("result") == {"result": True}, 3.0, 0.1)
            record_confirm(shape, ok)
        except Exception as exc:  # noqa: BLE001
            shape.problem(f"{exc!r} (rc={proc.poll()})")
        finally:
            if rpc is not None:
                if third is not None:
                    try:  # never leave a held confirm behind (teardown also answers it)
                        rpc.raw("dialog.respond", {"window_id": third, "accept": False})
                    except Exception:  # noqa: BLE001
                        pass
                rpc.close()
            stop_browser_term_only(proc)

    for msg in leak_failures():  # a browser SIGTERM did not end fails the row (no SIGKILL on a Mac)
        shape.problem(msg)
    eprint(f"stderr={err[-20:]}")
    return shape.report()  # a missing assertion is a failure (rule 7)


if __name__ == "__main__":
    sys.exit(main())
