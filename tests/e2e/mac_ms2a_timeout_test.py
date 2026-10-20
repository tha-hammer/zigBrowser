#!/usr/bin/env python3
"""MS2a hang-guard test (macOS): the main-thread bridge's readiness wait must TIME OUT, never hang.

get_url/get_title/navigate run the WKWebView work on the main thread and block the caller with a
dispatch_semaphore gated by a poll deadline + a backstop. This test connects while the page is still
loading (a fixture whose document is delayed well past the call's timeout) and calls page.title with
a SHORT timeout, asserting it returns a timeout error within a bounded wall-time. Without the
bridge's poll-deadline/backstop the readiness wait would spin forever (and this test would hang).

Runs ON a Mac (console user, no xvfb), in its own process group (orphan-safe), reusing the MS2a
harness. Unregistered in build.zig (lands with the MS2a gate).
"""
import argparse
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from automation_fixture_server import AutomationFixtureServer  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


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

    # /core is delayed well past the short page.title timeout below, so the window is NOT ready when
    # the call arrives and the bridge's readiness wait must time out.
    with AutomationFixtureServer(core_delay_s=6.0) as fixture, \
            tempfile.TemporaryDirectory(prefix="zb-ms2a-to-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/core", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        for stream, sink in ((proc.stdout, []), (proc.stderr, [])):
            threading.Thread(target=_read_lines, args=(stream, sink), daemon=True).start()

        rpc = None
        try:
            rpc = RpcClient(socket_path, args.timeout_sec)
            t0 = time.monotonic()
            try:
                # Short timeout while /core is still loading: the bridge must time out, not hang.
                rpc.call("page.title", {"timeout_ms": 800})
                failures.append("page.title on a still-loading page unexpectedly succeeded")
            except AssertionError as exc:
                elapsed = time.monotonic() - t0
                if "timeout" not in str(exc).lower():
                    failures.append(f"page.title error was not a timeout: {exc}")
                if elapsed > 6.0:
                    failures.append(f"page.title took {elapsed:.1f}s — the bridge did not time out promptly")
            # The main thread is not wedged: once the page finishes loading, title reads correctly.
            title = rpc.call("page.title", {"timeout_ms": 15000})["title"]
            if title != "zigBrowser Core Fixture":
                failures.append(f"post-load title wrong (main thread wedged?): {title!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error (possible hang/wedge): {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-hang-guard")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms2a-hang-guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
