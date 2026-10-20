#!/usr/bin/env python3
"""MS2a RED (registered) — a refused routed navigation leaves the old document settled.

RoseCat 38d121a #3: when a routed navigation's start yields nil (refused), the bridge must return
navigation_failed WITHOUT clearing the window's settled state, so a later url/title/eval does not wait
to timeout on a document that never changed. ZB_DEBUG_REFUSE_NEXT_NAV forces the next routed start to be
refused.

Oracle: after a refused page.navigate, page.url still answers promptly with the ORIGINAL url (the old
document is still settled), and page.title answers too. A bridge that cleared finishedOrFailed before a
refused start would make these wait to timeout — the red.
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
PAGE = b"<!doctype html><html><head><meta charset='utf-8'><title>Page A</title></head><body><h1>A</h1></body></html>"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        page = PAGE

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.end_headers()
                self.wfile.write(page)

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-refuse-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_REFUSE_NEXT_NAV"] = "1"  # the next routed navigation's start is refused
        proc = subprocess.Popen(
            # --e2e-protocol gates the ZB_DEBUG_REFUSE_NEXT_NAV hook on; without it the env is inert.
            [str(browser), f"{fixture.base_url}/a", "--automation-api", "--e2e-protocol"],
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
                print("FAIL\tms2a-refused-start-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            start_url = rpc.call("page.url", {"timeout_ms": 10000})["url"]  # waits for readiness

            # The refused navigation must report EXACTLY navigation_failed (-32008), not succeed and not
            # some unrelated error (auth/schema/timeout), which a broad except would false-green.
            resp = rpc.raw("page.navigate", {"url": f"{fixture.base_url}/b", "timeout_ms": 5000})
            if "error" not in resp:
                failures.append(f"a refused page.navigate did not error: {resp.get('result')!r}")
            else:
                err = resp["error"]
                if err.get("code") != -32008 or err.get("message") != "navigation_failed":
                    failures.append(f"refused page.navigate error was not navigation_failed(-32008): {err}")

            # The old document must still be SETTLED: these must answer promptly (short timeout), not hang.
            t0 = time.monotonic()
            try:
                url_after = rpc.call("page.url", {"timeout_ms": 1500})["url"]
            except Exception as exc:  # noqa: BLE001
                failures.append(f"page.url after a refused navigation did not answer (settled state lost?): {exc}")
                url_after = None
            if url_after is not None and url_after != start_url:
                failures.append(f"committed URL changed after a refused navigation: {url_after!r} (was {start_url!r})")
            if (time.monotonic() - t0) > 1.4:
                failures.append("page.url after a refused navigation took ~its timeout (settled state was cleared)")
            try:
                rpc.call("page.title", {"timeout_ms": 1500})
            except Exception as exc:  # noqa: BLE001
                failures.append(f"page.title after a refused navigation did not answer: {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-refused-start")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-refused-start")
    return 0


if __name__ == "__main__":
    sys.exit(main())
