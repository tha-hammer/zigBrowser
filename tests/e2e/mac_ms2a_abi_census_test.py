#!/usr/bin/env python3
"""MS2a — ABI / window census (RoseCat 4981d66 bucket 2, part D).

Two checks, on the dylib the running browser actually loads (@executable_path/../Frameworks):

1. LINK census: the macOS automation ABI the port calls is exported, and the five GTK-era symbols the
   plan's MS2a rev 13 marks SUPERSEDED are ABSENT (the macOS shim uses the eval_json/list_windows ABI +
   the heap-job phase model, not zb_main_invoke_sync/loop_mark/window_alive/window_id_at/run_generation).
2. BEHAVIORAL window registry: opening a popup makes page.list (zb_automation_list_windows) report TWO
   windows with distinct REAL ids and urls (the primary + the popup) — a real registry, not constants.

Runs ON a Mac (nm is local; the socket drives the browser). Own process group, killpg teardown.
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
from mac_term_teardown import run_term_only  # noqa: E402

SKIP_EXIT = 77

# The macOS MS2a ABI the port (automation_macos_port.zig) calls — must be exported by the shim.
REQUIRED = [
    "zb_automation_set_script", "zb_automation_eval_json", "zb_automation_navigate",
    "zb_automation_navigate_guarded", "zb_automation_reload", "zb_automation_get_url",
    "zb_automation_get_title", "zb_automation_list_windows", "zb_automation_close_window",
    "zb_automation_recover_windows", "zb_automation_list_dialogs", "zb_automation_respond_dialog",
    "zb_automation_free",
]
# The GTK-era symbols the macOS phase model supersedes (plan MS2a rev 13) — must NOT be exported.
SUPERSEDED = [
    "zb_main_invoke_sync", "zb_automation_loop_mark", "zb_automation_window_alive",
    "zb_automation_window_id_at", "zb_automation_run_generation",
]

FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Census</title></head><body>
<div id="t">primary</div>
<script>function openPopup(){ window.open(location.href.split('?')[0] + '?popup', '_blank'); }</script></body></html>"""


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

    failures: list[str] = []

    # ---- 1. LINK census on the loaded dylib (@executable_path/../Frameworks/libwkwebview_shim.dylib) ----
    dylib = (browser.resolve().parent / ".." / "Frameworks" / "libwkwebview_shim.dylib").resolve()
    if not dylib.is_file():
        eprint(f"SKIP: shim dylib not found at {dylib}")
        return SKIP_EXIT
    try:
        nm = run_term_only(["nm", "-gU", str(dylib)], 30)  # a timeout stops nm with SIGTERM only (3ui.7)
    except Exception as exc:  # noqa: BLE001
        print("FAIL\tms2a-abi-census")
        eprint(f"  nm failed: {exc}")
        return 1
    # nm prints "<addr> T _zb_automation_eval_json" (macOS leading underscore). Collect defined symbols.
    defined = set()
    for line in nm.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("T", "S", "D"):
            defined.add(parts[2].lstrip("_"))
    for sym in REQUIRED:
        if sym not in defined:
            failures.append(f"required macOS ABI symbol NOT exported by the shim: {sym}")
    for sym in SUPERSEDED:
        if sym in defined:
            failures.append(f"SUPERSEDED GTK symbol unexpectedly exported by the macOS shim: {sym} (phase model should replace it)")

    # ---- 2. BEHAVIORAL window registry: a popup yields two REAL distinct windows ----
    proc_holder: list[subprocess.Popen] = []
    _install_signal_cleanup(lambda: proc_holder[0] if proc_holder else None)
    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2a-census-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
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
                print("FAIL\tms2a-abi-census-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1
            rpc.call("page.url", {"timeout_ms": 10000})
            rpc.raw("page.evaluate", {"expression": "openPopup()"})
            end = time.monotonic() + 6.0
            pages = []
            while time.monotonic() < end:
                pages = (rpc.raw("page.list", {}).get("result") or {}).get("pages") or []
                if len(pages) >= 2 and any((w.get("url") or "").endswith("?popup") for w in pages):
                    break
                time.sleep(0.05)
            ids = [w.get("window_id") for w in pages]
            urls = [w.get("url") or "" for w in pages]
            if len(pages) < 2:
                failures.append(f"list_windows did not report the popup as a second window: {pages!r}")
            elif len(set(ids)) != len(ids):
                failures.append(f"list_windows returned non-distinct window ids (constants?): {ids!r}")
            elif not any(u.endswith("?popup") for u in urls) or not any(u.endswith("/") for u in urls):
                failures.append(f"list_windows urls are not the real primary+popup pair: {urls!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2a-abi-census")
        for f in failures:
            eprint(f"  {f}")
        return 1
    print("PASS\tms2a-abi-census")
    return 0


if __name__ == "__main__":
    sys.exit(main())
