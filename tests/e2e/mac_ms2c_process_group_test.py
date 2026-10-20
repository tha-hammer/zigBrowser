#!/usr/bin/env python3
"""MS2c RED (unregistered) — recover's at_risk set covers the whole WebContent-process family (RoseCat 6508 #4/#7).

A window.open popup shares its opener's WebContent process on macOS, so freezing that process endangers
every window in the family. page.recover phase 1 (consent) must report ALL of them in `at_risk`, built from
each window's process_group. On a build that omits process_group (the port then defaults it to 0 and the
server groups every window to itself) recovering the primary names only the primary — understating the
acknowledgement set, which is the red. (Phase 2 stays unsupported/fail-closed per the 2026-10-20 decision;
this test only exercises the phase-1 consent set.)
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
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Family</title></head><body>x
<script>
  function openPopup(){ window.open(location.href.split('?')[0] + '?popup', '_blank'); }
  function freeze(){ setTimeout(function(){ while(true){} }, 100); }
</script></body></html>"""


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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-pgroup-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(os.environ)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [str(browser), f"{fixture.base_url}/", "--automation-api"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
            start_new_session=True,
        )
        proc_holder.append(proc)
        out: list[str] = []
        err: list[str] = []
        for stream, buf in ((proc.stdout, out), (proc.stderr, err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

        rpc = None

        def health():
            return rpc.raw("page.health", {}).get("result") or {}

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-process-group-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            # A window.open popup — shares the primary's WebContent process.
            rpc.raw("page.evaluate", {"expression": "openPopup()"})
            end = time.monotonic() + 6.0
            popup_id = None
            while time.monotonic() < end:
                pg = next((p for p in (health().get("pages") or []) if (p.get("url") or "").endswith("?popup")), None)
                if pg:
                    popup_id = pg["window_id"]
                    break
                time.sleep(0.05)
            if popup_id is None:
                failures.append("popup never appeared")
                raise RuntimeError("no popup")

            debounce_ms = health().get("debounce_ms") or 2000

            # Freeze the shared WebContent process (setTimeout so this evaluate returns first). Both the
            # primary and the popup share it, so both go unresponsive.
            rpc.raw("page.evaluate", {"expression": "freeze()"})
            time.sleep((debounce_ms + 1800) / 1000.0)  # past debounce so the watchdog has marked it

            # Phase 1 consent on the primary: at_risk must list the WHOLE family, popup included.
            r1 = rpc.raw("page.recover", {"window_id": "window-1"})
            offer = r1.get("result") or {}
            if "error" in r1 or not offer.get("incident"):
                failures.append(f"recover phase 1 did not offer an incident (window not seen unresponsive?): {r1.get('error') or offer!r}")
            else:
                at_risk = offer.get("at_risk") or []
                # at_risk entries are {window_id, url} objects — compare on the id.
                at_risk_ids = [(w.get("window_id") if isinstance(w, dict) else w) for w in at_risk]
                if "window-1" not in at_risk_ids:
                    failures.append(f"at_risk missing the target primary: {at_risk_ids!r}")
                if popup_id not in at_risk_ids:
                    failures.append(f"at_risk understated: {popup_id} (the shared-process popup) not in {at_risk_ids!r} — process_group not grouping the family")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-process-group")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-process-group")
    return 0


if __name__ == "__main__":
    sys.exit(main())
