#!/usr/bin/env python3
"""MS2a.3 — immediate quit cancels in-flight work and releases its ref (RoseCat 4981d66 bucket 2, part C).

The fixture's GET hangs, so a `page.url` with a long deadline stays in the readiness poll (a live PREFLIGHT
job whose next poll block is queued on the main queue). The e2e-gated ZB_DEBUG_QUIT_AFTER_MS hook ends the
run loop while that job is live. The app-ended path (zb_auto_on_loop_ended) sets a loop-ended flag and DRAINS
the pending main-queue blocks, so the queued poll runs its loop-ended branch (completes NO_LOOP + unref)
rather than leaking the ref a stopped loop could never run. Asserts:
  - the op returns PROMPTLY at ~the quit time (cancelled / connection closed), NOT at its long deadline —
    the waiter was woken, not left to time out;
  - no work dispatches after quit (the loop-ended branch finishes queued jobs without WebKit work);
  - live jobs reach 0 (the e2e-gated `zb-live-jobs=N` stderr line) — the queued block's ref was released.

Runs ON a Mac (console user, no xvfb), own process group, killpg teardown.
"""
import argparse
import http.server
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_ms2a_routed_test import stop_browser_macos, _install_signal_cleanup  # noqa: E402

SKIP_EXIT = 77
QUIT_AFTER_MS = 4500
OP_TIMEOUT_MS = 15000
SETTLE_SEC = 1.2  # let startup finish (the e2e mirror is set in -initWithURI) before the job is created
ACTION_TIMEOUT = -32009  # downstreamCode(.action_timeout): the waiter's deadline expired (NOT woken)
CANCELLED = -32012       # downstreamCode(.cancelled): NO_LOOP -> error.Cancelled (the app-ended drain woke it)


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def live_jobs_seq(err_lines):
    """Every zb-live-jobs value in order, so a test can see the 0 -> positive -> 0 lifecycle, not just the end."""
    out = []
    for ln in err_lines:
        m = re.search(r"zb-live-jobs=(-?\d+)", ln)
        if m:
            out.append(int(m.group(1)))
    return out


def loop_cancel_count(err_lines):
    """The last zb-loop-cancel value (the app-ended drain cancelled a live readiness job via the no-work path)."""
    val = 0
    for ln in err_lines:
        m = re.search(r"zb-loop-cancel=(\d+)", ln)
        if m:
            val = int(m.group(1))
    return val


class _HangingServer:
    """GET hangs (never responds) so the page never finishes loading -> a routed op stays PREFLIGHT-live."""
    def __init__(self):
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                time.sleep(60)  # hang; the test tears the browser down well before this

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

    with _HangingServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2a-quit-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_QUIT_AFTER_MS"] = str(QUIT_AFTER_MS)  # end [application run] mid-flight
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
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
                print("FAIL\tms2a-immediate-quit-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            # Let startup settle so the e2e stderr mirror is set before the job is created (else the creation's
            # zb-live-jobs=1 is not emitted and the positive-transition oracle cannot see it).
            time.sleep(SETTLE_SEC)

            # Baseline the stderr-observable state BEFORE issuing (RoseCat 41c683a #2): at rest the live count
            # is 0, so the positive transition and the cancel below are THIS request's, not a startup artifact.
            pre_seq = live_jobs_seq(err)
            if pre_seq and pre_seq[-1] != 0:
                failures.append(f"live jobs not at rest before issuing: {pre_seq}")
            base_cancels = loop_cancel_count(err)

            # A routed op on the still-loading (hanging) page -> a live PREFLIGHT job with a long deadline.
            # rpc.raw (not .call) so we can inspect the terminal error code rather than have it raised away.
            t0 = time.monotonic()
            resp = None
            dropped = False
            try:
                resp = rpc.raw("page.url", {"timeout_ms": OP_TIMEOUT_MS})
            except Exception:
                dropped = True  # the process may close the socket as it exits right after waking the waiter
            elapsed = time.monotonic() - t0

            # Prompt wake: ~the quit time, NOT the 15 s deadline. (Quit is armed from launch, so allow for startup.)
            if elapsed > (QUIT_AFTER_MS / 1000.0) + 6.0:
                failures.append(f"op did not return promptly on quit: {elapsed:.1f}s (waiter left to time out, not woken)")
            if elapsed < 0.3:
                failures.append(f"op returned too fast ({elapsed:.1f}s) — was it actually a live polling job?")

            # DEFECT 3 — the terminal, through the dispatch result: the op must NOT have produced a successful
            # read (work ran) and must NOT be action_timeout (the waiter timed out instead of being woken).
            if resp is not None and "result" in resp:
                failures.append(f"page.url SUCCEEDED despite the quit (work ran after quit): {resp['result']!r}")
            if resp is not None and isinstance(resp.get("error"), dict):
                code = resp["error"].get("code")
                if code == ACTION_TIMEOUT:
                    failures.append(f"op returned action_timeout ({code}): the waiter TIMED OUT, the drain did not wake it")
                elif code != CANCELLED:
                    failures.append(f"op error code is {code}, expected cancelled ({CANCELLED}) from the app-ended drain")

            # Give the drain's stderr a moment to flush.
            time.sleep(0.6)

            # DEFECT 2 — this request created a LIVE PREFLIGHT job (a positive transition from the at-rest
            # baseline), then it returned to EXACTLY zero. The test issues exactly one blocking op, so any
            # positive value in the sequence is this request's; a test that only checked the final 0 would
            # pass even if the job was never created.
            seq = live_jobs_seq(err)
            if not any(v >= 1 for v in seq):
                failures.append(f"no positive zb-live-jobs transition: {seq} "
                                "(this request never created a live PREFLIGHT job — assertion would be vacuous)")
            if not seq or seq[-1] != 0:
                failures.append(f"live jobs did not return to EXACTLY 0 after the loop ended: {seq} "
                                "(a queued block's ref leaked)")

            # DEFECT 3 — the observable that the drain CANCELLED the live job via the no-work path: the
            # app-ended drain ran the queued readiness block, which took the loop-ended branch (NO work()), not
            # a timeout and not a WebKit submission. Deleting the production post-run drain never reaches this.
            if loop_cancel_count(err) <= base_cancels:
                failures.append("no zb-loop-cancel after quit: the app-ended drain did not cancel the live "
                                "readiness job via the no-work path (is the PRODUCTION post-run drain present?)")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                try:
                    rpc.close()
                except Exception:
                    pass
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-immediate-quit")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-25:]}")
        return 1
    print("PASS\tms2a-immediate-quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
