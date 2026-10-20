#!/usr/bin/env python3
"""MS2a.2 RED (unregistered) — routed navigation failure semantics on the macOS WKWebView backend.

RoseCat 6227.2: `zb_automation_navigate_guarded` waits on a single `finishedOrFailed` boolean and
returns OK for EITHER outcome, and the navigation delegate requests whole-app exit on a load failure.
That contradicts page_port.zig (a failed navigation must map to NavigationFailed) and makes a routed
`page.navigate` to a URL that cannot load either (a) succeed, or (b) kill the browser — neither is
acceptable for an automation client driving an arbitrary site.

This asserts the CONTRACT:
  1. `page.navigate` to a URL that fails to load returns an ERROR (navigation_failed), not {"ok": true}.
  2. The browser stays ALIVE: a subsequent `page.url` still answers, and the committed URL is unchanged
     (the failed provisional navigation did not replace the current document).

On the current build either the call returns {"ok": true} (assertion 1 fails) or the browser exits and
the socket drops (assertions fail with a connection error) — that is the red. The green makes routed
navigation failure a bounded, reported error that leaves the session usable.

Runs ON a Mac (console user, no xvfb, like gate.sh), in its own process group (orphan-safe teardown).
Unregistered in build.zig (red outside the gate).
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

PAGE_A = b"<!doctype html><html><head><meta charset='utf-8'><title>Page A</title></head>" \
         b"<body><h1 id='heading'>Page A</h1></body></html>"


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        page = PAGE_A

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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-navfail-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/a", "--automation-api"],
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
                print("FAIL\tms2a.2-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            start_url = rpc.call("page.url")["url"]

            # A URL that cannot load: an unresolvable host fails provisionally (NSURLErrorCannotFindHost).
            # (A refused TCP port is unreliable — WebKit may substitute about:blank and "succeed".)
            bad = "https://nonexistent.invalid/"
            navigated_ok = False
            try:
                res = rpc.call("page.navigate", {"url": bad, "timeout_ms": 10000})
                navigated_ok = (res == {"ok": True})
            except AssertionError as exc:
                if "navigation_failed" not in str(exc).lower() and "nav" not in str(exc).lower():
                    failures.append(f"navigate to a failing URL errored, but not as navigation_failed: {exc}")
            except Exception as exc:  # noqa: BLE001 — a dropped socket here means the browser exited (the app-exit bug)
                failures.append(f"navigate to a failing URL dropped the connection (browser exited?): {exc}")
            if navigated_ok:
                failures.append("page.navigate to an unreachable URL returned {'ok': True} (should be navigation_failed)")

            # The session must still be usable and the document unchanged by the failed navigation.
            try:
                after = rpc.call("page.url")["url"]
                if after != start_url:
                    failures.append(f"committed URL changed on a failed navigation: {after!r} (was {start_url!r})")
            except Exception as exc:  # noqa: BLE001
                failures.append(f"page.url after a failed navigation did not answer (browser dead/wedged?): {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a.2-nav-failure")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a.2-nav-failure")
    return 0


if __name__ == "__main__":
    sys.exit(main())
