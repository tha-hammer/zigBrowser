#!/usr/bin/env python3
"""MS2c RED (unregistered) — the MS2c.4 crash controls: no-input persistence + clicked-Reload (RoseCat 6508 #5).

Two authoritative controls on top of the crash-presentation handler:

1. NO-INPUT PERSISTENCE: after a content-process termination, with NO further input for a bounded hold
   longer than 3 s, the window stays crashed on the static crash document — the browser never
   auto-reloads. A 3-second automatic-reload would clear the crashed state inside the hold — the red this
   control kills.
2. CLICKED-RELOAD: recovery happens only on the user's reload. page.reload (the same WebKit
   reloadBypassingCache a user's Reload click triggers — NOT a fresh page.navigate) reloads the kept
   committed URL, which commits for real and clears crashed.

Also asserts the per-window native diagnostic on stderr (window id).

The termination is driven by the e2e-gated one-shot ZB_DEBUG_SYNTH_CRASH hook, which synthesizes the
PUBLIC webViewWebContentProcessDidTerminate: callback (WebKit exposes no public, safe way to kill a
specific WebContent process, and killing by PID would hit shared/other processes — see the plan's MS2c.4
accepted substitute). The production handler the hook invokes is unchanged and is the real crash path.
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
NO_INPUT_HOLD = 4.0  # > the 3 s auto-reload mutant it must kill
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-crashctl-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_SYNTH_CRASH"] = "1"
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
                print("FAIL\tms2c-crash-controls-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-20:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            # Wait for the synth termination to be reported crashed + the static crash doc to show.
            end = time.monotonic() + 8.0
            while time.monotonic() < end:
                p = primary()
                if p and p.get("crashed") == "crashed" and p.get("title") == "zb-crash":
                    break
                time.sleep(0.05)
            p = primary()
            if not (p and p.get("crashed") == "crashed"):
                failures.append(f"window not crashed after the synth termination: {p!r}")
            if p and p.get("title") != "zb-crash":
                failures.append(f"static crash document not showing: {p!r}")

            # (c) native per-window diagnostic on stderr.
            if not any("terminated: window-1" in line for line in err):
                failures.append(f"no per-window termination diagnostic on stderr: {err[-10:]!r}")

            # (1) NO-INPUT PERSISTENCE: no input for > 3 s; must stay crashed on the crash doc (no auto-reload).
            time.sleep(NO_INPUT_HOLD)
            p2 = primary()
            if not (p2 and p2.get("crashed") == "crashed"):
                failures.append(f"crashed cleared with no input in {NO_INPUT_HOLD}s (auto-reloaded?): {p2!r}")
            if p2 and p2.get("title") != "zb-crash":
                failures.append(f"left the crash document with no input (auto-reloaded?): {p2!r}")
            if proc.poll() is not None:
                failures.append(f"browser exited on the crash (rc={proc.returncode})")

            # (2) CLICKED-RELOAD: page.reload (NOT page.navigate) reloads the kept committed URL and recovers.
            r = rpc.raw("page.reload", {"timeout_ms": 8000})
            if "error" in r:
                failures.append(f"page.reload (clicked-Reload) errored on the crashed window: {r['error']}")
            end = time.monotonic() + 6.0
            p3 = None
            while time.monotonic() < end:
                p3 = primary()
                if p3 and not p3.get("crashed"):
                    break
                time.sleep(0.05)
            if p3 and p3.get("crashed"):
                failures.append(f"clicked-Reload did not recover (still crashed): {p3!r}")
            elif p3 and p3.get("title") != "Live":
                failures.append(f"clicked-Reload did not restore the committed page (title {p3.get('title')!r}): {p3!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-crash-controls")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-crash-controls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
