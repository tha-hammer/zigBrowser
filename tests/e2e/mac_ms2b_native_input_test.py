#!/usr/bin/env python3
"""MS2b.1a RED (unregistered) — native-input feasibility spike (click) on the macOS WKWebView backend.

MS2b.1a (click-only spike): a NATIVE click (dom.click with options.input="native") must deliver a
TRUSTED event (`event.isTrusted === true`) to the real WKWebView — the in-process responder-chain
NSEvent / CGEvent->NSEvent path, no system post, no TCC. The macOS shim implements only the 6
lifecycle fns (no zb_automation_* / zb_native_* port), so the automation server has no WKWebView
session and rejects the command — the red. MS2b runs the UNSIGNED build (parallel with MS1b).

SCOPE: this is the click-only feasibility spike (MS2b.1a). Plan MS2b.1 is the FULL trusted-event
matrix — focus, click, key, text, contenteditable + beforeinput cancellation, scroll, pointer
movement, navigation-during-input, partial typing, deadline abandonment, on BOTH Macs — and the
capability table (automation_platform.zig) may flip ONLY after the whole matrix passes. This spike
therefore does NOT register the final MS2b gate and does NOT flip capabilities; the remaining red
slices (MS2b.1b key/text/contenteditable+beforeinput, MS2b.1c scroll/pointer/navigation/partial-typing,
MS2b.1d deadline-abandonment, MS2b.2 dialogs) follow before the MS2b green.

Runs ON a Mac (console user, no xvfb, like gate.sh), in its own process group (orphan-safe teardown).
Unregistered in build.zig (red-outside-the-gate).

Mutation-resistant: it asserts the click is TRUSTED (e.isTrusted === true), so a synthetic-event
stub (isTrusted false) or a no-op that returns {"ok": true} without delivering the click both fail.
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

FIXTURE_HTML = b"""<!doctype html><html><head><meta charset="utf-8">
<title>MS2b Native Input</title></head><body>
<button id="btn" style="width:240px;height:90px">Click me</button>
<script>
  window.__clicks = 0; window.__trustedClick = null; window.__keyTrusted = null;
  document.getElementById('btn').addEventListener('click', function (e) {
    window.__clicks += 1; window.__trustedClick = e.isTrusted;
  });
  window.addEventListener('keydown', function (e) { window.__keyTrusted = e.isTrusted; });
</script></body></html>"""


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


class _FixtureServer:
    def __init__(self):
        html = FIXTURE_HTML

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(html)))
                self.end_headers()
                self.wfile.write(html)

            def log_message(self, *a):  # quiet
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

    def expect_eq(label, actual, expected):
        if actual != expected:
            failures.append(f"{label}: got {actual!r}, want {expected!r}")

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2b-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        # Own process group (orphan-safe killpg teardown via stop_browser_macos).
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
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
                print("FAIL\tms2b.1a-socket-not-connectable")
                eprint(f"error={exc}")
                eprint(f"stderr={err[-20:]}")
                return 1

            # MS2b.1a: a NATIVE click must deliver a TRUSTED event. options.input="native" selects the
            # native port (router defaults to synthetic, router.zig parseInputMode) — without it this
            # would exercise the synthetic path, not the native capability it spikes. Returns a
            # capability error on macOS today (-> AssertionError), which is the red.
            expect_eq("dom.click (native)", rpc.call("dom.click", {"selector": "css=#btn", "options": {"input": "native", "timeout_ms": 10000}}), {"ok": True})
            expect_eq("click reached the page", rpc.evaluate("window.__clicks"), 1)
            # Mutation-resistant: the delivered click must be a TRUSTED (native) event, not synthetic.
            expect_eq("click is trusted (native)", rpc.evaluate("window.__trustedClick"), True)
        except AssertionError as exc:
            failures.append(f"native-input command rejected (expected on macOS today): {exc}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2b.1a-native-click")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2b.1a-native-click")
    return 0


if __name__ == "__main__":
    sys.exit(main())
