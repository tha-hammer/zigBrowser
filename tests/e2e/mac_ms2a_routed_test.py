#!/usr/bin/env python3
"""MS2a RED (unregistered) — routed automation commands on the macOS WKWebView backend.

MS2a.1: `page.navigate` + `page.url`/`page.title` over the automation socket must drive the real
WKWebView and report the real page state. The macOS shim does not implement the `zb_automation_*`
routed-command ABI yet (wkwebview_shim.m defines only zb_app_run/run_open/run_screenshot/
version_line/reload/window_new; N12: a build without that platform port answers SDK requests
cleanly with a capability error), so this FAILS today — that is the MS2a red. MS1 proved the
UNSIGNED universal runs; this runs the UNSIGNED build (MS2a may proceed in parallel with MS1b).

Runs ON a Mac (WKWebView needs the WindowServer); the Mac channel is logged in as the console user,
so launch directly (no xvfb prefix, like tests/mac/gate.sh). Unregistered in build.zig
(red-commits-outside-the-gate); the MS2a green registers the macOS routed-command gate.

Mutation-resistant: it asserts the url and title ACTUALLY become the navigated page's, so a stub
that returns {"ok": true} without navigating, or a page.url that echoes the request, still fails.
"""
import argparse
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# Reuse the Linux harness pieces (shipped to the Mac by build-on-mac.sh under tests/e2e). NOT
# automation_core_test.terminate — it reads Linux /proc (slice2_common), which macOS lacks.
from automation_core_test import RpcClient, _read_lines  # noqa: E402
from automation_fixture_server import AutomationFixtureServer  # noqa: E402

SKIP_EXIT = 77


def stop_browser_macos(proc: subprocess.Popen) -> None:
    """macOS-safe teardown: no /proc scan. Terminate, then kill if it lingers."""
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    # --browser matches the macOS gate's m9 harness convention (tests/mac/gate.sh).
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    args = ap.parse_args()

    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    failures: list[str] = []

    def expect_eq(label, actual, expected):
        if actual != expected:
            failures.append(f"{label}: got {actual!r}, want {expected!r}")

    with AutomationFixtureServer(core_delay_s=0.3) as fixture, \
            tempfile.TemporaryDirectory(prefix="zb-ms2a-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        # Console-user launch (no prefix); the Mac session owns the WindowServer.
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/core", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None
        try:
            # If the socket never comes up, that is a HARNESS failure (the server must start even
            # without the WKWebView port); surface it distinctly from the routed-command red.
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2a-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stdout={out[-20:]}")
                eprint(f"stderr={err[-20:]}")
                return 1

            base = fixture.base_url
            # Readiness + MS2a.1: these all return a capability error on macOS today (-> AssertionError
            # from rpc.call), which is the red. The green makes them drive the real WKWebView.
            expect_eq("page.url (initial)", rpc.call("page.url")["url"], f"{base}/core")
            expect_eq("page.title (initial)", rpc.call("page.title")["title"], "zigBrowser Core Fixture")
            expect_eq("page.navigate", rpc.call("page.navigate", {"url": f"{base}/nav-b", "timeout_ms": 10000}), {"ok": True})
            # Mutation-resistant: assert the REAL post-navigation page state, not just ok.
            expect_eq("page.url (after navigate)", rpc.call("page.url")["url"], f"{base}/nav-b")
            expect_eq("page.title (after navigate)", rpc.call("page.title")["title"], "Nav B")
        except AssertionError as exc:
            failures.append(f"routed command rejected (expected on macOS today): {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-routed-commands")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stdout={out[-20:]}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2a-routed-commands")
    return 0


if __name__ == "__main__":
    sys.exit(main())
