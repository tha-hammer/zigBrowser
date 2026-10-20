#!/usr/bin/env python3
"""MS2c RED (unregistered) — two-hop popup chain with a STABLE, frozen opener identity (RoseCat 6510).

A true two-hop chain: primary opens A, and A (on load) opens B. B's opener must be A's STABLE id, and it
must stay that id even after A (the middle window) is closed — never retargeted to a surviving or new
window.

To make the opener assertion bite, two throwaway popups are opened and closed BEFORE A, so that when A
opens B, A's position in the registry (index 1) no longer equals A's stable id (4). A `child.openerId =
indexOfObject(self)+1` implementation would then record B.opener as an index-derived 2 (the dead throwaway's
id), not A's real id 4 — the red. With stable ids, B.opener is A's id and is frozen across A's close.
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
# primary (no query) opens windows on command via openq(q). A window loaded with ?chain auto-opens a
# single child (?leaf) on load; ?p1/?p2/?leaf windows open nothing.
FIXTURE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Chain</title></head><body>x
<script>
  function openq(q){ window.open(location.href.split('?')[0] + '?' + q, '_blank'); }
  if (location.search === '?chain') { openq('leaf'); }
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

    with _FixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-ms2c-chain-") as tmp:
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

        def pages():
            return (rpc.raw("page.list", {}).get("result") or {}).get("pages") or []

        def by_q(ps, q):
            return next((w for w in ps if (w.get("url") or "").endswith("?" + q)), None)

        def wait_pages(n, deadline_s=6.0):
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                p = pages()
                if len(p) == n:
                    return p
                time.sleep(0.05)
            return pages()

        def wait_urls(suffixes, deadline_s=8.0):
            # A new window appears in page.list before its navigation commits (url == ""), so wait for the
            # expected ?suffix urls to actually settle, not merely for the window count.
            end = time.monotonic() + deadline_s
            while time.monotonic() < end:
                p = pages()
                if all(by_q(p, q) is not None for q in suffixes):
                    return p
                time.sleep(0.05)
            return pages()

        def close(wid):
            return rpc.raw("page.close", {"window_id": wid}).get("result")

        try:
            try:
                rpc = RpcClient(socket_path, args.timeout_sec)
            except Exception as exc:
                print("FAIL\tms2c-popup-chain-socket-not-connectable")
                eprint(f"error={exc}; stderr={err[-10:]}")
                return 1

            rpc.call("page.url", {"timeout_ms": 10000})
            primary_id = (pages()[0] or {}).get("window_id")

            # Two throwaway popups, then close them, so the registry compacts BEFORE A is created. This
            # drives A's registry index below its stable id, which is what makes the opener check bite.
            rpc.raw("page.evaluate", {"expression": "openq('p1')"})
            wait_urls(["p1"])
            rpc.raw("page.evaluate", {"expression": "openq('p2')"})
            ps = wait_urls(["p1", "p2"])
            t1, t2 = by_q(ps, "p1"), by_q(ps, "p2")
            if t1 is None or t2 is None:
                failures.append(f"throwaway popups not created: {ps!r}")
            else:
                close(t1["window_id"])
                close(t2["window_id"])
                back = wait_pages(1)
                if [w.get("window_id") for w in back] != [primary_id]:
                    failures.append(f"throwaways did not close back to just the primary: {back!r}")

            # primary opens A (?chain); A, on load, opens B (?leaf).
            rpc.raw("page.evaluate", {"expression": "openq('chain')"})
            ps = wait_urls(["chain", "leaf"])
            a = by_q(ps, "chain")
            b = by_q(ps, "leaf")
            if a is None or b is None:
                failures.append(f"two-hop chain did not form (primary->A->B): {[(w.get('window_id'), w.get('url')) for w in ps]}")

            if a and b:
                a_id = a["window_id"]
                b_id = b["window_id"]
                if a.get("opener_window_id") != primary_id:
                    failures.append(f"A opener != primary: {a.get('opener_window_id')!r} (want {primary_id})")
                # THE discriminator: B's opener is A's STABLE id, not an index-derived value.
                if b.get("opener_window_id") != a_id:
                    failures.append(f"B opener != A's stable id: {b.get('opener_window_id')!r} (want {a_id}) — index-derived opener?")
                # B reachable by its own id.
                burl = (rpc.raw("page.url", {"window_id": b_id, "timeout_ms": 5000}).get("result") or {}).get("url")
                if not (burl or "").endswith("?leaf"):
                    failures.append(f"B not reachable by id {b_id}: {burl!r}")

                # Close the MIDDLE window A. B must survive, keep its id, and keep A's now-closed id as its
                # opener — never retargeted to a surviving/new window.
                if close(a_id) != {"ok": True}:
                    failures.append("closing A (the middle) did not return ok")
                left = wait_pages(2)
                surviving_ids = [w.get("window_id") for w in left]
                b_after = by_q(left, "leaf")
                if b_after is None:
                    failures.append(f"B vanished after closing its opener A: {left!r}")
                else:
                    if b_after["window_id"] != b_id:
                        failures.append(f"B id changed from {b_id} to {b_after['window_id']} after closing A (ids not stable)")
                    if b_after.get("opener_window_id") != a_id:
                        failures.append(f"B opener changed after A closed: {b_after.get('opener_window_id')!r} (want frozen {a_id})")
                    if a_id in surviving_ids:
                        failures.append(f"A's id {a_id} still names a surviving window — opener points at a live window, not the dead opener: {surviving_ids!r}")
                    burl2 = (rpc.raw("page.url", {"window_id": b_id, "timeout_ms": 5000}).get("result") or {}).get("url")
                    if not (burl2 or "").endswith("?leaf"):
                        failures.append(f"B no longer reachable by its stable id {b_id} after A closed: {burl2!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"unexpected error: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print("FAIL\tms2c-popup-chain")
        for f in failures:
            eprint(f"  {f}")
        eprint(f"stderr={err[-20:]}")
        return 1
    print("PASS\tms2c-popup-chain")
    return 0


if __name__ == "__main__":
    sys.exit(main())
