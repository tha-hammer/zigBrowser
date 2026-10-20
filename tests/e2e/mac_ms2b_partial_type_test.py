#!/usr/bin/env python3
"""MS2b RED (unregistered) — native typing abandons partially on a short deadline (RoseCat 6361.4).

nativeText types one code point per acknowledged round trip and stops as soon as the caller's deadline
passes — it must NOT keep typing after the command timed out, and what landed is a PREFIX of the
requested text. ZB_DEBUG_TYPE_DELAY_MS inserts a per-character delay so a short command timeout
deterministically abandons mid-string.

Oracle: dom.type of "abcde" with a timeout far below (delay * characters) errors, and the field holds a
PROPER PREFIX of "abcde" (not the whole string). A build that ignored the deadline and typed on would
leave "abcde" — the red.
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
TEXT = "abcde"
DELAY_MS = 300  # per inter-character delay; full typing ~ DELAY_MS * (2*len - 1) ms
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>PartialType</title></head><body>
<input id="inp" type="text"></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-partial-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_TYPE_DELAY_MS"] = str(DELAY_MS)  # delay between characters -> a short timeout abandons mid-text
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
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
                print("FAIL\tms2b-partial-type-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness
            resp = rpc.raw("dom.type", {"selector": "css=#inp", "text": TEXT, "options": {"input": "native", "timeout_ms": 400}})
            if "error" not in resp:
                failures.append(f"dom.type with a short timeout did not error (typed past the deadline?): {resp.get('result')!r}")
                sent_chars = None
            else:
                # The exact partial-timeout contract (RoseCat 6433.2): an action_timeout (-32009) whose
                # data carries reason=partial_input and a sent_chars count, with NO last_error (a timeout
                # is not a document change). Anything weaker — an undispatched op, a different code, a
                # value=="" partial — must not pass.
                err_obj = resp["error"]
                data = err_obj.get("data") or {}
                sent_chars = data.get("sent_chars")
                if err_obj.get("code") != -32009 or err_obj.get("message") != "action_timeout":
                    failures.append(f"timeout error was not -32009/action_timeout: {err_obj}")
                if data.get("reason") != "partial_input":
                    failures.append(f"data.reason was not partial_input: {data!r}")
                if data.get("last_error") is not None:
                    failures.append(f"a timeout must not carry last_error: {data.get('last_error')!r}")
                if not isinstance(sent_chars, int) or not (1 <= sent_chars < len(TEXT)):
                    failures.append(f"sent_chars is not a non-empty PROPER prefix count (1..{len(TEXT)-1}): {sent_chars!r}")
                    sent_chars = None
            # Wait past the full typing time: on abandonment, delivery STOPPED at the deadline, so the
            # field stays a partial prefix; a build that kept typing in the background (or sent a late
            # pair after give-up) would reach a longer string by now.
            time.sleep((DELAY_MS * (2 * len(TEXT) + 2)) / 1000.0)
            value = rpc.evaluate("document.getElementById('inp').value")
            if value == TEXT:
                failures.append("the whole string was typed despite the short timeout (no partial abandonment)")
            elif value == "":
                failures.append("nothing was typed — a partial timeout must leave the delivered prefix, not an empty field")
            elif not TEXT.startswith(value):
                failures.append(f"typed value is not a prefix of {TEXT!r}: {value!r}")
            # Exact agreement: the field holds EXACTLY the first sent_chars code points — no half pair
            # (value shorter than sent_chars) and no late suffix (value longer) after the settle wait.
            if sent_chars is not None and value != TEXT[:sent_chars]:
                failures.append(f"field value {value!r} != exact prefix TEXT[:{sent_chars}]={TEXT[:sent_chars]!r} (half pair or late suffix)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-partial-type")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-partial-type")
    return 0


if __name__ == "__main__":
    sys.exit(main())
