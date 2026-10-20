#!/usr/bin/env python3
"""MS2b.2 RED (unregistered) — macOS page dialogs: alert / confirm / prompt via WKUIDelegate.

A page dialog must be CAPTURED and left open (never auto-answered): dialog.get reports it with its
window, the page's JS stays blocked until dialog.respond answers it, and while it is open any command
that needs the page fails fast with dialog_open (-32013). This mirrors the GTK contract
(automation_dialogs_test.py) over the mac e2e harness (RpcClient).

On today's binary the shim has NO WKUIDelegate dialog handlers, so alert()/confirm()/prompt() return
their defaults immediately and nothing is captured: dialog.get stays {open:false} and this test REDs.
The green wires runJavaScriptAlertPanel/Confirm/TextInput to hold the completion handler until respond.

Dialogs are triggered via setTimeout so the triggering page.evaluate returns before the dialog opens
(the dialog then blocks the page's next JS turn, which is the point).
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Dialogs</title></head><body>
<input id="file" type="file">
<script>
  function showAlert(m) { alert(m); document.title = 'alerted'; }
  function askConfirm(m) { document.title = 'confirm:' + confirm(m); }
  function askPrompt(m, d) { var r = prompt(m, d); document.title = 'prompt:' + (r === null ? 'null' : r); }
</script></body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        html = FIXTURE

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.end_headers()
                self.wfile.write(html)

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2b-dlg-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def trigger(expr):
            # The dialog opens synchronously and blocks the web process, so this evaluate cannot get its
            # completion back — it times out (or, once the shim maps it, returns dialog_open). Either way
            # the dialog is open afterwards; the result is ignored.
            rpc.raw("page.evaluate", {"expression": expr, "timeout_ms": 1500})

        def wait_dialog(deadline_s):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                d = rpc.raw("dialog.get", {}).get("result")
                if d and d.get("open"):
                    return d
                time.sleep(0.05)
            return rpc.raw("dialog.get", {}).get("result")

        def title():
            return (rpc.raw("page.title", {"timeout_ms": 5000}).get("result") or {}).get("title")

        def wait_title(want, deadline_s=5.0):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                if title() == want:
                    return True
                time.sleep(0.05)
            return False

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2b-dialogs-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            start = rpc.raw("dialog.get", {}).get("result")
            if start != {"open": False}:
                failures.append(f"dialog.get at start was not {{open:false}}: {start!r}")

            # alert: captured, stays open, answered, page resumes.
            trigger("showAlert('hello alert')")
            d = wait_dialog(5.0)
            if d != {"open": True, "type": "alert", "message": "hello alert", "window_id": "window-1"}:
                failures.append(f"alert not captured as expected: {d!r}")
            # while open, a page-reading command fails fast with dialog_open (-32013).
            resp = rpc.raw("page.title", {"timeout_ms": 20000})
            if "error" not in resp or resp["error"].get("code") != -32013:
                failures.append(f"page.title with an alert open did not fail with dialog_open: {resp.get('error') or resp.get('result')!r}")
            if rpc.raw("dialog.respond", {"accept": True}).get("result") != {"ok": True}:
                failures.append("dialog.respond(accept) for the alert did not return ok")
            if not wait_title("alerted"):
                failures.append("the page did not resume after the alert was answered")

            # confirm: dismiss -> false, accept -> true.
            trigger("askConfirm('Discard?')")
            d = wait_dialog(5.0)
            if d != {"open": True, "type": "confirm", "message": "Discard?", "window_id": "window-1"}:
                failures.append(f"confirm not captured as expected: {d!r}")
            rpc.raw("dialog.respond", {"accept": False})
            if not wait_title("confirm:false"):
                failures.append("confirm dismissed did not yield false")

            # prompt: answered with text.
            trigger("askPrompt('Name?','ada')")
            d = wait_dialog(5.0)
            if d != {"open": True, "type": "prompt", "message": "Name?", "default_text": "ada", "window_id": "window-1"}:
                failures.append(f"prompt not captured as expected: {d!r}")
            rpc.raw("dialog.respond", {"accept": True, "text": "grace"})
            if not wait_title("prompt:grace"):
                failures.append("prompt answered with text did not yield 'grace'")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-dialogs")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-dialogs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
