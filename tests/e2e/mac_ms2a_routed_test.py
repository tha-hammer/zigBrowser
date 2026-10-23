#!/usr/bin/env python3
"""MS2a.1 RED (unregistered) — routed automation commands on the macOS WKWebView backend.

MS2a.1: `page.navigate` + `page.url`/`page.title` + a DOM-change read (`dom.getText css=#heading`)
over the automation socket must drive the real WKWebView and report the real page state. The macOS
shim implements only the 6 lifecycle fns (no `zb_automation_*` routed-command port; N12: a build
without that platform port answers SDK requests cleanly with a capability error), so this FAILS
today — the MS2a.1 red. MS1 proved the UNSIGNED universal runs; this runs the UNSIGNED build (MS2a
may proceed in parallel with MS1b).

Scope note: this is the MS2a.1 red (navigate/url/title + the Closure-A eval/DOM boundary). The
private-world spoof/metamorphic property (MS2a.2) and ownership/readiness/late-completion (MS2a.3)
are separate later red commits.

Runs ON a Mac (WKWebView needs the WindowServer); the Mac channel is logged in as the console user,
so launch directly (no xvfb prefix, like tests/mac/gate.sh). Unregistered in build.zig
(red-commits-outside-the-gate); the MS2a green registers the macOS routed-command gate.

Process hygiene: the browser is launched in its OWN process group (start_new_session) and torn down
by SIGTERM to the whole group (reaped, bounded; NEVER SIGKILL on a Mac, bd zigBrowser-3ui.7), including on
SIGTERM/SIGINT; a browser that does not quit is left running and fails the test (tests/e2e/mac_term_teardown.py).

Mutation-resistant: it asserts the url, title AND the navigated page's DOM heading ACTUALLY become
the new page's, so a stub that returns {"ok": true} without navigating, or a page.url that echoes
the request, still fails; the dom.getText read also crosses the eval/script boundary (Closure A).
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# Reuse the Linux harness pieces (shipped to the Mac by build-on-mac.sh under tests/e2e).
from automation_core_test import RpcClient, _read_lines  # noqa: E402
from automation_fixture_server import AutomationFixtureServer  # noqa: E402
from mac_term_teardown import stop_browser_term_only  # noqa: E402

SKIP_EXIT = 77


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def stop_browser_macos(proc: subprocess.Popen) -> None:
    """macOS-safe, orphan-safe teardown of the browser's whole process GROUP with SIGTERM only (the session brief
    forbids SIGKILL on a Mac; bd zigBrowser-3ui.7). start_new_session makes the browser its own group leader, so the
    group id IS its pid. CRITICAL (dd0b456/6206): the group is still signalled when the leader has already exited,
    so surviving group children are reached. A leader or member still running after the grace is left running and
    the test fails at exit (FAIL mac-teardown-leak). Idempotent. See tests/e2e/mac_term_teardown.py."""
    stop_browser_term_only(proc)


def _install_signal_cleanup(get_proc):
    """On SIGTERM/SIGINT (e.g. an outer gate timeout), tear the browser group down, then re-raise."""
    def handler(signum, _frame):
        proc = get_proc()
        if proc is not None:
            stop_browser_macos(proc)
        # Restore default and re-raise so the exit status reflects the signal.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, handler)


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

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)

    failures: list[str] = []

    def expect_eq(label, actual, expected):
        if actual != expected:
            failures.append(f"{label}: got {actual!r}, want {expected!r}")

    with AutomationFixtureServer(core_delay_s=0.3) as fixture, \
            tempfile.TemporaryDirectory(prefix="zb-ms2a-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        # Console-user launch (no prefix) in its OWN process group (orphan-safe teardown).
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/core", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        assert proc.stdout is not None and proc.stderr is not None
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None
        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2a-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stdout={out[-20:]}")
                eprint(f"stderr={err[-20:]}")
                return 1

            base = fixture.base_url
            # Readiness + MS2a.1. These all return a capability error on macOS today (-> AssertionError
            # from rpc.call), which is the red. The green makes them drive the real WKWebView.
            expect_eq("page.url (initial)", rpc.call("page.url")["url"], f"{base}/core")
            expect_eq("page.title (initial)", rpc.call("page.title")["title"], "zigBrowser Core Fixture")
            expect_eq("page.navigate", rpc.call("page.navigate", {"url": f"{base}/nav-b", "timeout_ms": 10000}), {"ok": True})
            # Mutation-resistant: assert the REAL post-navigation page state, not just ok.
            expect_eq("page.url (after navigate)", rpc.call("page.url")["url"], f"{base}/nav-b")
            expect_eq("page.title (after navigate)", rpc.call("page.title")["title"], "Nav B")
            # Closure A: cross the eval/script boundary — the navigated page's DOM heading, so
            # navigation cannot pass through a cached url/title alone (matches the Linux source test).
            expect_eq("dom.getText #heading (after navigate)",
                      rpc.call("dom.getText", {"selector": "css=#heading"})["text"], "Nav B")
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
