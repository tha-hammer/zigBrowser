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

Failing assertions today (Mac): 1 `popup_id not in page_list_ids()` and 2 (the popup still answers), 5.
Target step: `ms2c-gate` (TO BE ADDED by bd 4pa.62). Until the green this file is in no gate script and no
build.zig step. Every launch gets a private HOME and its own --profile-dir.
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

CLOSE_TITLE = "zb-native-close"
PAGES = {
    "/a": b"<!doctype html><html><head><meta charset='utf-8'><title>OPENER</title></head>"
          b"<body><p id='t'>opener-dom</p></body></html>",
    "/p": b"<!doctype html><html><head><meta charset='utf-8'><title>POPUP</title></head><body>p</body></html>",
}


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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()
    browser = Path(args.browser)
    if not browser.is_file():
        print("FAIL\tms2c-close-button-binary-missing")  # rule 7: a skip is a failure
        eprint(f"binary not found: {browser}")
        return 1

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    asserted = 0

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-closebtn-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["HOME"] = str(Path(tmp) / "home")  # private HOME: never the account's own profile or caches
        (Path(tmp) / "home").mkdir()
        env["ZB_DEBUG_NATIVE_CLOSE_ON_TITLE"] = CLOSE_TITLE
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
            rpc = RpcClient(socket_path, args.timeout_sec)

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
            ids = page_list_ids()
            asserted += 1
            if popup_id in ids:
                failures.append(f"1: the natively closed popup {popup_id} is still in page.list: {ids!r}")

            reply = rpc.raw("page.title", {"window_id": popup_id})
            reason = ((reply.get("error") or {}).get("data") or {}).get("reason")
            asserted += 1
            if reason != "no_window":
                failures.append(f"2: a command routed to the closed popup did not fail with no_window: {reply!r}")

            settled = wait_until(lambda: last_live_jobs(err) == baseline, 3.0)
            asserted += 1
            if not settled:
                failures.append(f"3: live_jobs {last_live_jobs(err)} did not return to baseline {baseline}")

            asserted += 1
            if proc.poll() is not None:
                failures.append(f"4: the browser exited (rc={proc.returncode}) when a popup was closed")
            else:
                url_after = rpc.call("page.url", {"timeout_ms": 10000}).get("url")
                dom_after = rpc.evaluate("document.getElementById('t').textContent")
                if url_after != opener_url or dom_after != "opener-dom":
                    failures.append(f"4: the opener changed: url {url_after!r} (was {opener_url!r}), dom {dom_after!r}")

            wincount = [l for l in list(out) if l.startswith("WINCOUNT\t")]
            asserted += 1
            if not wincount or wincount[-1] != "WINCOUNT\t1":
                failures.append(f"5: the shared destroy path did not run (WINCOUNT rows {wincount[-4:]!r})")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{exc!r} (rc={proc.poll()})")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if asserted != 5 and not failures:
        failures.append(f"ran {asserted} assertions, want 5")  # rule 7
    if failures:
        print("FAIL\tms2c-close-button")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-close-button")
    return 0


if __name__ == "__main__":
    sys.exit(main())
