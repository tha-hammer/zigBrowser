#!/usr/bin/env python3
"""MS2c RED (unregistered) — per-window_id FIFO independence on macOS.

Commands to different windows run on independent per-window FIFO lines (server queue.zig, with the stable
non-reused ids), so a command stuck on a frozen window must NOT block commands to another window.

A command on window B's line is kept busy to its deadline (a dom.getText for a selector that never
appears retries until timeout_ms), WITHOUT freezing any web process. A page-script command to window A
must complete PROMPTLY meanwhile. If page work were serialized on one lane, A would wait behind B's
retrying command — the red. (A freeze is deliberately avoided: window.open popups may share the opener's
web process on macOS, which would confound process-sharing with queue independence.)
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Opener</title></head><body>
<div id="t">content</div>
<script>
  function openPopup(){ window.open(location.href.split('?')[0] + '?popup', '_blank'); }
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-fifo-") as tmp:
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
                print("FAIL\tms2c-window-fifo-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            ca.call("page.url", {"timeout_ms": 10000})
            ca.raw("page.evaluate", {"expression": "openPopup()"})
            end = time.monotonic() + 5.0
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
            # (popup healthy; no freeze)

            # conn B: a page-script command targeted at the FROZEN popup — it will hang until its deadline.
            stuck = {}

            def hit_popup():
                t0 = time.monotonic()
                try:  # a selector that never appears retries until the deadline, holding B's FIFO line
                    stuck["resp"] = cb.raw("dom.getText", {"selector": "css=#never-ever", "window_id": popup_id, "options": {"timeout_ms": 4000}})
                except Exception as exc:  # noqa: BLE001
                    stuck["exc"] = repr(exc)
                stuck["elapsed"] = time.monotonic() - t0

            th = threading.Thread(target=hit_popup, daemon=True)
            th.start()
            time.sleep(0.2)  # ensure the popup op is in flight before we time the primary

            # conn A: a page-script command to the RESPONSIVE primary must complete promptly.
            t0 = time.monotonic()
            r = ca.raw("dom.getText", {"selector": "css=#t"})
            primary_elapsed = time.monotonic() - t0
            if "error" in r:
                failures.append(f"primary dom.get_text errored while the popup was stuck: {r['error']}")
            elif (r.get("result") or {}).get("text") != "content":
                failures.append(f"primary dom.get_text wrong: {r.get('result')!r}")
            if primary_elapsed > 2.0:
                failures.append(f"primary command blocked {primary_elapsed:.1f}s behind the popup's retrying command (not independent)")
            th.join(timeout=8.0)
            # Sanity: the popup command really was stuck (took a while / errored), else the freeze didn't take.
            if stuck.get("elapsed", 0) < 2.0 and "exc" not in stuck:
                failures.append(f"the popup command did not hold its line to the deadline: {stuck!r}")
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
        print("FAIL\tms2c-window-fifo")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-window-fifo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
