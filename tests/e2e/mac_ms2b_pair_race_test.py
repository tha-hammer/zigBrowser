#!/usr/bin/env python3
"""MS2b RED (unregistered) — the per-pair ownership transition closes the check->send race (RoseCat 6397.1).

Native typing delivers each code point as an indivisible keyDown/keyUp pair. Between pairs the job is
INFLIGHT (the deadline may abandon it); to send the NEXT pair the callback must re-own the job atomically
(INFLIGHT -> DISPATCHING), and while DISPATCHING the waiter blocks WITHOUT a deadline. So if the command
deadline falls while a pair is legitimately owned, the waiter must NOT return — the command completes and
every code point lands.

This drives that with the e2e-gated ZB_DEBUG_PAIR_HOLD_MS hook: it pauses on the main thread AFTER the
re-own and BEFORE the next pair's keyDown, with the hold set far longer than the command timeout. On the
correct build the re-own put the job in DISPATCHING before the hold, so the waiter waits past the deadline
and dom.type SUCCEEDS with the whole string typed. A check-then-act mutant (an is-inflight check instead
of the atomic INFLIGHT->DISPATCHING reclaim) leaves the job INFLIGHT during the hold: the waiter abandons
at the deadline, dom.type returns action_timeout, and the second pair lands AFTER give-up — the red.

Unregistered until the MS2b matrix is final-gated.
"""
import argparse
import http.server
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
TEXT = "ab"          # two code points -> exactly one inter-pair re-own (the discriminating window)
HOLD_MS = 3000       # main-thread hold inside the owned window (>> the command deadline)
TIMEOUT_MS = 1500    # command deadline: well past the first pair (no premature abandon), but inside the hold
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>PairRace</title></head><body>
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-pairrace-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_PAIR_HOLD_MS"] = str(HOLD_MS)  # hold inside the owned window, > the command timeout
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
                print("FAIL\tms2b-pair-race-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness
            # The second pair is re-owned atomically (INFLIGHT->DISPATCHING) before the hold, and the
            # waiter cannot abandon while DISPATCHING, so BOTH code points are delivered within the owned
            # window before the command returns — even though the hold (3000ms) outlasts the deadline
            # (1500ms), so the command ends in action_timeout. The telling fact is data.sent_chars == 2:
            # every pair landed before the waiter returned. A check-then-act build leaves the job INFLIGHT
            # during the hold, so the waiter abandons at the deadline with sent_chars == 1 and the second
            # pair lands LATE (after give-up) — the red.
            resp = rpc.raw("dom.type", {"selector": "css=#inp", "text": TEXT, "options": {"input": "native", "timeout_ms": TIMEOUT_MS}})
            # The hold (3000ms) is guaranteed to outlast the deadline (1500ms), so the ONLY correct
            # outcome is action_timeout with BOTH pairs delivered within the owned window before the
            # waiter returned: data.sent_chars == len(TEXT). A success response is impossible here and is
            # NOT accepted (that would let an inerted hold survive — RoseCat 6481); a check-then-act
            # reclaim gives sent_chars == 1 (abandoned mid-hold, late pair).
            err_obj = resp.get("error")
            if not err_obj:
                failures.append(f"dom.type did not time out despite a hold ({HOLD_MS}ms) past the deadline ({TIMEOUT_MS}ms): {resp.get('result')!r}")
            else:
                sent = (err_obj.get("data") or {}).get("sent_chars")
                if err_obj.get("code") != -32009:
                    failures.append(f"expected action_timeout (-32009), got {err_obj}")
                if sent != len(TEXT):
                    failures.append(f"sent_chars={sent!r}, want {len(TEXT)} — a pair was abandoned mid-hold (check->send race not closed)")
            value = rpc.evaluate("document.getElementById('inp').value")
            if value != TEXT:
                failures.append(f"field value {value!r} != {TEXT!r} (a pair was lost or landed late)")
            if proc.poll() is not None:
                failures.append(f"browser exited during the owned-pair hold (rc={proc.returncode})")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b-pair-race")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b-pair-race")
    return 0


if __name__ == "__main__":
    sys.exit(main())
