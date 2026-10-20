#!/usr/bin/env python3
"""MS2c RED (unregistered) — page.list + page.health answer OOB while a sibling FIFO is stuck (RoseCat 6508 #3).

The out-of-band methods (page.list, page.health) and each window's command FIFO are independent lanes. With
one window's FIFO occupied by a long page command (a dom.getText for a selector that never appears, retrying
to its deadline — NOT a web-process freeze), both OOB methods must still answer promptly for ALL windows, and
a command to a DIFFERENT window must complete promptly. The occupied FIFO is the forbidden span: nothing the
test times may route through it. If page.list/page.health queued behind page work, or if the windows shared
one FIFO, the prompt operations would stall behind the ~5 s stuck command — the red.
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
PROMPT_BUDGET = 2.0  # an OOB/sibling op must finish well within the stuck command's ~5 s
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>OOB</title></head><body>
<div id="t">content</div>
<script>function openPopup(){ window.open(location.href.split('?')[0] + '?popup', '_blank'); }</script></body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def _queued_timeout(resp):
    """True ONLY for the exact queue-only outcome (RoseCat 6634): a command that waited in a window's FIFO
    past its own deadline — action_timeout (-32009) with data.reason == "queued_past_deadline"
    (src/automation/engine.zig:402). Any OTHER error — an immediate selector/window/eval failure, or a
    retry-exhausted action_timeout with a different reason — is NOT proof of queue ownership and must not
    trip the barrier."""
    err = resp.get("error")
    if not err:
        return False
    data = err.get("data") or {}
    return (err.get("code") == -32009
            and err.get("message") == "action_timeout"
            and data.get("reason") == "queued_past_deadline")


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-oob-") as tmp:
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

        ca = cb = None
        try:
            try:
                ca = RpcClient(socket_path, args.timeout_sec)
                cb = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-oob-during-stuck-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            ca.call("page.url", {"timeout_ms": 10000})
            ca.raw("page.evaluate", {"expression": "openPopup()"})
            end = time.monotonic() + 6.0
            popup_id = None
            while time.monotonic() < end:
                pages = (ca.raw("page.list", {}).get("result") or {}).get("pages") or []
                popup = next((w for w in pages if (w.get("url") or "").endswith("?popup")), None)
                if popup:
                    popup_id = popup["window_id"]
                    break
                time.sleep(0.05)
            if popup_id is None:
                failures.append("popup not created")
                raise RuntimeError("no popup")

            # conn B: occupy the POPUP's FIFO line to its deadline (retrying selector, no freeze).
            stuck = {}

            def hit_popup():
                t0 = time.monotonic()
                try:
                    stuck["resp"] = cb.raw("dom.getText", {"selector": "css=#never-ever", "window_id": popup_id, "options": {"timeout_ms": 5000}})
                except Exception as exc:  # noqa: BLE001
                    stuck["exc"] = repr(exc)
                stuck["elapsed"] = time.monotonic() - t0

            # Pre-stuck: prove #t RESOLVES on the free popup FIFO (so a later timeout is queue ownership, not
            # a bad selector) and that an immediate window failure is NOT misread as queue ownership — the
            # discriminator that keeps the barrier honest (RoseCat 6634: a bare "any error" false-greens here).
            pre = ca.raw("dom.getText", {"selector": "css=#t", "window_id": popup_id, "options": {"timeout_ms": 2000}})
            if "error" in pre or (pre.get("result") or {}).get("text") != "content":
                failures.append(f"popup #t did not resolve while its FIFO was free (pre-stuck): {pre!r}")
            imm = ca.raw("dom.getText", {"selector": "css=#t", "window_id": "window-999999", "options": {"timeout_ms": 300}})
            if "error" not in imm:
                failures.append(f"an unknown window_id unexpectedly succeeded: {imm!r}")
            elif _queued_timeout(imm):
                failures.append(f"discriminator false-green: an immediate window error was read as queue ownership: {imm.get('error')!r}")

            th = threading.Thread(target=hit_popup, daemon=True)
            th.start()
            # Observed queue-entry barrier (not a fixed sleep): a quick #t probe on the popup's FIFO RESOLVES
            # while the line is free and, once the stuck command owns the line, returns the EXACT queue-only
            # outcome (action_timeout / queued_past_deadline). Only that exact outcome trips the barrier, so
            # the timing below can neither race ahead of the stuck command nor be fooled by an unrelated error.
            bend = time.monotonic() + 8.0
            held = False
            while time.monotonic() < bend:
                probe = ca.raw("dom.getText", {"selector": "css=#t", "window_id": popup_id, "options": {"timeout_ms": 300}})
                if _queued_timeout(probe):  # queued behind the stuck command past its deadline -> FIFO is held
                    held = True
                    break
                time.sleep(0.03)
            if not held:
                failures.append("stuck command never took the popup FIFO (no action_timeout/queued_past_deadline on #t)")

            # conn A, while the popup FIFO is stuck: both OOB methods answer for all windows, promptly.
            t0 = time.monotonic()
            lst = (ca.raw("page.list", {}).get("result") or {}).get("pages") or []
            list_elapsed = time.monotonic() - t0
            list_ids = [w.get("window_id") for w in lst]
            if "window-1" not in list_ids or popup_id not in list_ids:
                failures.append(f"page.list did not answer for all windows while a sibling FIFO was stuck: {list_ids!r}")
            if list_elapsed > PROMPT_BUDGET:
                failures.append(f"page.list blocked {list_elapsed:.1f}s behind the stuck FIFO (not OOB)")

            t0 = time.monotonic()
            hp = (ca.raw("page.health", {}).get("result") or {}).get("pages") or []
            health_elapsed = time.monotonic() - t0
            health_ids = [w.get("window_id") for w in hp]
            if "window-1" not in health_ids or popup_id not in health_ids:
                failures.append(f"page.health did not answer for all windows while a sibling FIFO was stuck: {health_ids!r}")
            if health_elapsed > PROMPT_BUDGET:
                failures.append(f"page.health blocked {health_elapsed:.1f}s behind the stuck FIFO (not OOB)")

            # conn A: a page command to the OTHER window (primary) must complete promptly (independent FIFO).
            t0 = time.monotonic()
            r = ca.raw("dom.getText", {"selector": "css=#t"})
            sib_elapsed = time.monotonic() - t0
            if "error" in r:
                failures.append(f"sibling dom.getText errored while the popup FIFO was stuck: {r['error']}")
            elif (r.get("result") or {}).get("text") != "content":
                failures.append(f"sibling dom.getText wrong: {r.get('result')!r}")
            if sib_elapsed > PROMPT_BUDGET:
                failures.append(f"sibling command blocked {sib_elapsed:.1f}s behind the stuck popup FIFO (not independent)")

            th.join(timeout=9.0)
            if stuck.get("elapsed", 0) < 4.0 and "exc" not in stuck:
                failures.append(f"the stuck command did not actually hold its FIFO to the deadline: {stuck!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            for c in (ca, cb):
                if c is not None:
                    try:
                        c.close()
                    except Exception:
                        pass
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-oob-during-stuck")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-oob-during-stuck")
    return 0


if __name__ == "__main__":
    sys.exit(main())
