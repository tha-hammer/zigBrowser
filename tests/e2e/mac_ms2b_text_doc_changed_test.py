#!/usr/bin/env python3
"""MS2b — native typing re-checks the documentToken AFTER EVERY code point (RoseCat 6361.1 / 6424).

nativeText delivers one keyDown/keyUp pair per code point and, after each pair's input is processed,
re-reads __zbAutomation.documentToken through the FIFO ack. If a character navigated the page the
remaining characters are NOT typed into the replacement document: the sequence stops with a partial
document_changed carrying the exact count delivered into the old document.

This drives the recheck with the e2e-gated ZB_DEBUG_STALE_TOKEN="after:N" hook, which makes the Nth
documentToken read return a stale value. Read #1 is the PREFLIGHT guard; read #1+k is the recheck after
the k-th code point. Two cases prove the recheck is load-bearing THROUGHOUT the string, not just for the
first character (RoseCat 6424): after:1 stops after 1 code point, after:3 stops after 3. A build that
rechecked only the first character — or not at all — would type the whole string and fail both cases.

Oracle per case: the error is element_not_found (-32001) with data.reason=partial_input,
data.last_error=document_changed, data.sent_chars=N, and the field holds EXACTLY the first N code points
(no suffix in the replacement document). Registered in the two-host MS2b gate.
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
TEXT = "abcde"
# (after_n, expected code points delivered before the recheck goes stale).
# read #1 = PREFLIGHT; recheck after code point k is read #(1+k). after:N goes stale on read #(N+1),
# i.e. the recheck following code point N -> exactly N code points land first.
CASES = [(1, 1), (3, 3)]
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>TextDocChanged</title></head><body>
<input id="inp" type="text"></body></html>"""


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


def run_case(browser: Path, timeout_sec: float, after_n: int, want_sent: int, failures: list[str],
             proc_holder: list[subprocess.Popen]):
    """Fresh browser per case (the stale hook counts reads process-wide)."""
    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-textdc-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZB_DEBUG_STALE_TOKEN"] = f"after:{after_n}"
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api", "--e2e-protocol"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder[:] = [proc]  # register for signal cleanup (RoseCat 6455: no stranded process group)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()
        rpc = None
        tag = f"after:{after_n}"
        try:
            try:
                rpc = RpcClient(socket_path, timeout_sec)
            except Exception as exc:
                failures.append(f"[{tag}] socket not connectable: {exc}; stderr={err[-6:]}")
                return
            rpc.call("page.url", {"timeout_ms": 10000})  # warm up readiness
            resp = rpc.raw("dom.type", {"selector": "css=#inp", "text": TEXT, "options": {"input": "native", "timeout_ms": 5000}})
            if "error" not in resp:
                failures.append(f"[{tag}] dom.type succeeded while the document 'changed' mid-text: {resp.get('result')!r}")
            else:
                e = resp["error"]
                data = e.get("data") or {}
                if e.get("code") != -32001 or e.get("message") != "element_not_found":
                    failures.append(f"[{tag}] error was not -32001/element_not_found: {e}")
                if data.get("reason") != "partial_input":
                    failures.append(f"[{tag}] data.reason was not partial_input: {data!r}")
                if data.get("last_error") != "document_changed":
                    failures.append(f"[{tag}] data.last_error was not document_changed: {data!r}")
                if data.get("sent_chars") != want_sent:
                    failures.append(f"[{tag}] sent_chars={data.get('sent_chars')!r}, want {want_sent}")
            # The field holds exactly the first `want_sent` code points — the suffix never entered the
            # replacement document, and no extra pair landed.
            value = rpc.evaluate("document.getElementById('inp') ? document.getElementById('inp').value : '<gone>'")
            if value != TEXT[:want_sent]:
                failures.append(f"[{tag}] field value {value!r} != exact prefix {TEXT[:want_sent]!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"[{tag}] unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)
            proc_holder.clear()


def selftest() -> int:
    """Non-live harness pin (RoseCat 6455/6481): without launching a browser, prove run_case places its
    spawned process in the signal-cleanup holder BEFORE the first blocking operation (the RpcClient
    connect) and clears it only AFTER stop. Stubs Popen/RpcClient/stop_browser_macos so nothing real
    runs; the RpcClient stub captures the holder state at the first blocking op, the stop stub captures it
    at teardown, and the post-run holder must be empty."""
    import io
    mod = sys.modules[__name__]
    holder: list = []
    observed: dict = {}

    class FakeProc:
        pid = 424242
        returncode = 0

        def __init__(self):
            self.stdout = io.StringIO("")
            self.stderr = io.StringIO("")

        def poll(self):
            return None

    class FakeRpc:
        def __init__(self, sock, timeout):
            observed["holder_at_first_blocking"] = list(holder)  # must already hold the proc
            raise RuntimeError("selftest: stop run_case at the first blocking op")

    def fake_stop(proc):
        observed["holder_at_stop"] = list(holder)  # still held when we stop

    orig = (subprocess.Popen, mod.RpcClient, mod.stop_browser_macos)
    subprocess.Popen = lambda *a, **k: FakeProc()
    mod.RpcClient = FakeRpc
    mod.stop_browser_macos = fake_stop
    try:
        run_case(Path("/nonexistent"), 1.0, 1, 1, [], holder)
    finally:
        subprocess.Popen, mod.RpcClient, mod.stop_browser_macos = orig

    bad = []
    if not observed.get("holder_at_first_blocking"):
        bad.append("the proc was NOT in the cleanup holder before the first blocking op")
    if not observed.get("holder_at_stop"):
        bad.append("the proc was NOT in the holder at stop time")
    if holder:
        bad.append(f"the holder was not cleared after stop: {holder!r}")
    if bad:
        print("FAIL\tms2b-text-doc-changed-selftest")
        for b in bad:
            eprint(f"  {b}")
        return 1
    print("PASS\tms2b-text-doc-changed-selftest")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--browser", default="zig-out/bin/zigBrowser")
    ap.add_argument("--timeout-sec", type=float, default=25.0)
    ap.add_argument("--selftest", action="store_true", help="non-live harness pin for the cleanup holder")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    browser = Path(args.browser)
    if not browser.is_file():
        eprint(f"SKIP: binary not found: {browser}")
        return SKIP_EXIT

    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    failures: list[str] = []
    for after_n, want_sent in CASES:
        run_case(browser, args.timeout_sec, after_n, want_sent, failures, proc_holder)

    if failures:
        print("FAIL\tms2b-text-doc-changed")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms2b-text-doc-changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
