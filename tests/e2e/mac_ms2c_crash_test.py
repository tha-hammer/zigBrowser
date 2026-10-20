#!/usr/bin/env python3
"""MS2c RED (unregistered) — crash presentation parity: a dead web process is reported, URL kept, no auto-reload.

When a window's web process ends, the public webViewWebContentProcessDidTerminate handler marks the window
crashed, shows a STATIC crash document, keeps the committed URL, and NEVER auto-reloads (parity with
Linux). page.list reports crashed; the flag clears only on a later real commit.

The crash is driven by the e2e-gated one-shot ZB_DEBUG_SYNTH_CRASH hook, which synthesizes the public
termination callback after the first load (a WebContent process cannot be killed safely on a shared host
with public API; the production handler is unchanged and is what the synth invokes).

Oracle: after the synth crash, page.list reports the primary crashed="crashed" with its original url kept
and the static crash document showing (title "zb-crash"); after a further wait it is STILL crashed and
STILL the crash doc (no auto-reload); the browser stays alive. On a build with no crash handling the
window never reports crashed — the red.
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Live</title></head><body>live content</body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-crash-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_SYNTH_CRASH"] = "1"  # synthesize the termination callback once after the first load
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

        def primary():
            pages = (rpc.raw("page.list", {}).get("result") or {}).get("pages") or []
            return pages[0] if pages else None

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-crash-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            # Wait for the synth crash to be reported.
            end = time.monotonic() + 5.0
            p = None
            while time.monotonic() < end:
                p = primary()
                if p and p.get("crashed"):
                    break
                time.sleep(0.05)
            if not (p and p.get("crashed") == "crashed"):
                failures.append(f"window not reported crashed after the synth termination: {p!r}")
            else:
                if not (p.get("url") or "").startswith(fixture.base_url):
                    failures.append(f"committed url not kept after crash: {p.get('url')!r}")
                # The static crash doc loads a moment after `crashed` is set; wait for it.
                end2 = time.monotonic() + 3.0
                while time.monotonic() < end2 and (primary() or {}).get("title") != "zb-crash":
                    time.sleep(0.05)
                if (primary() or {}).get("title") != "zb-crash":
                    failures.append(f"static crash document not showing (title {(primary() or {}).get('title')!r})")

            # No auto-reload: still crashed and still the crash doc after a wait.
            time.sleep(1.5)
            p2 = primary()
            if not (p2 and p2.get("crashed") == "crashed"):
                failures.append(f"crashed flag cleared without a real commit (auto-reloaded?): {p2!r}")
            if p2 and p2.get("title") != "zb-crash":
                failures.append(f"window auto-reloaded off the crash document: {p2!r}")
            if proc.poll() is not None:
                failures.append(f"browser exited on the web-process crash (rc={proc.returncode})")

            # A real commit clears crashed.
            rpc.raw("page.navigate", {"url": f"{fixture.base_url}/", "timeout_ms": 8000})
            end = time.monotonic() + 5.0
            p3 = None
            while time.monotonic() < end:
                p3 = primary()
                if p3 and not p3.get("crashed"):
                    break
                time.sleep(0.05)
            if p3 and p3.get("crashed"):
                failures.append(f"crashed not cleared by a real commit: {p3!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-crash")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-crash")
    return 0


if __name__ == "__main__":
    sys.exit(main())
