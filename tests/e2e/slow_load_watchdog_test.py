#!/usr/bin/env python3
"""A slow page is never killed by the 15-second load timer (review SHOULD,
"the legacy 15-second human-load watchdog").

The slow response sends a DOM sentinel at once (the page commits) and then
stays unfinished past 15 s. Each phase runs its own browser on its own Xvfb
display, with the automation API and the --e2e-protocol stdout.

1. Single window: the page goes to the slow page itself (a navigation the
   automation did not start). At 14 s and 16 s it answers at once with the
   sentinel and its web process still runs; no LOAD_FAIL for it.

2. Related windows: window 1 opens a same-origin popup (window 2); both
   keep some JavaScript state. Window 1 then opens two related popups,
   which share the web process of windows 1 and 2:
   - "slow": the slow response;
   - "never": the server accepts the request and never answers (the load
     never commits);
   and one popup with a web process of its own:
   - "solo": the slow response from another origin, opened with noopener.
   At 14 s and at 16 s after those popups opened:
   - windows 1 and 2 answer at once and keep their state;
   - no window reports a dead web process; the shared and the solo web
     processes still run;
   - both slow windows answer with their sentinel. A command sent before
     15 s waits for that window's first load, as for any page still
     loading; at 15 s the timer stops holding it (it must answer, not
     fail). At 16 s they answer at once, and the slow window's screenshot
     is not blank.
   The never-committing load is still given up at 15 s (LOAD_FAIL), without
   ending the web process its related windows share; the slow loads get no
   LOAD_FAIL.

3. Single window whose page goes to the never-answering URL: nothing
   shares its web process, so the old recovery stays: at 16 s it has
   LOAD_FAIL, page.list marks it "terminated_by_api" and stderr names it.

Phases 1 and 2 must not print a "web process terminated" line on stderr.

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
import base64
import http.server
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

SENTINEL = "committed sentinel"
RELEASE = threading.Event()  # set at teardown: the held responses end


class Pages(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path.startswith("/slow"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            body = (f"<!doctype html><title>slow</title>"
                    f"<h1 id=sentinel style='font-size:64px'>{SENTINEL}</h1>").encode() + b" " * 4096
            self.wfile.write(b"%x\r\n%s\r\n" % (len(body), body))
            self.wfile.flush()
            RELEASE.wait(60)
            self._finish_chunked()
            return
        if self.path.startswith("/never"):
            RELEASE.wait(60)
            return
        name = self.path.strip("/") or "main"
        body = f"<!doctype html><title>{name}</title><p id=name>{name}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _finish_chunked(self) -> None:
        try:
            self.wfile.write(b"0\r\n\r\n")
        except OSError:
            pass

    def log_message(self, *_args) -> None:
        pass


def web_processes(pid: int) -> set[int]:
    found: set[int] = set()
    queue = [pid]
    while queue:
        parent = queue.pop()
        try:
            children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
        except OSError:
            continue
        for child in children:
            queue.append(int(child))
            try:
                if Path(f"/proc/{child}/comm").read_text().startswith("WebKitWebProces"):
                    found.add(int(child))
            except OSError:
                pass
    return found


def png_distinct_bytes(data: bytes) -> int:
    """Distinct byte values in a PNG's decompressed image data: a blank
    (one-colour) capture has only a handful; drawn text has many."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return 0
    pos, idat = 8, b""
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if kind == b"IDAT":
            idat += data[pos + 8:pos + 8 + length]
        pos += 12 + length
    return len(set(zlib.decompress(idat)))


class Browser:
    """One browser on its own Xvfb display with the automation API and the
    --e2e-protocol stdout; stdout and stderr lines are collected."""

    def __init__(self, binary: Path, url: str, tmp: Path):
        env = isolate_profile_env(dict(os.environ))
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET"):
            env.pop(name, None)
        self.socket_path = tmp / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        self.stdout: list[str] = []
        self.stderr: list[str] = []
        self.proc = subprocess.Popen(
            xsession_prefix(True) + [str(binary.resolve()), url, "--automation-api", "--e2e-protocol",
                                     "--profile-dir", str(tmp / "profile")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        )
        threading.Thread(target=lambda: self.stderr.extend(self.proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        threading.Thread(target=lambda: self.stdout.extend(self.proc.stdout), daemon=True).start()  # type: ignore[arg-type]

    def connect(self) -> ZigBrowser:
        deadline = time.monotonic() + 20
        while not self.socket_path.exists():
            if time.monotonic() > deadline:
                raise TimeoutError("socket never appeared")
            time.sleep(0.05)
        return ZigBrowser(socket_path=str(self.socket_path))

    def load_failures(self) -> list[str]:
        return [line.rstrip("\n").split("\t")[1] for line in self.stdout
                if line.startswith("LOAD_FAIL\t") and line.count("\t") >= 1]

    def terminations(self) -> list[str]:
        time.sleep(0.3)
        return [line.rstrip() for line in self.stderr if "web process terminated" in line]


def sentinel_of(zb: ZigBrowser, window: str):
    try:
        return zb.call("page.evaluate", {"expression": "document.getElementById('sentinel').textContent",
                                         "window_id": window})["result"]
    except Exception as exc:  # noqa: BLE001
        return f"error {exc}"


def single_window(binary: Path, origin: str, check) -> None:
    """The simplest case: one window, no popups, whose page goes to the slow
    page itself (a navigation the automation did not start)."""
    with tempfile.TemporaryDirectory(prefix="zb-slow-load-e2e-") as tmp_name:
        RELEASE.clear()
        browser = Browser(binary, f"{origin}/main", Path(tmp_name))
        try:
            with browser.connect() as zb:
                check(zb.page.evaluate("document.title")["result"] == "main", "single window: loaded")
                processes = web_processes(browser.proc.pid)
                t0 = time.monotonic()
                zb.page.evaluate(f"(setTimeout(() => {{ location.href = '{origin}/slow'; }}, 0), 1)")
                for at in (14, 16):
                    while time.monotonic() - t0 < at:
                        time.sleep(0.02)
                    start = time.monotonic()
                    got = sentinel_of(zb, "window-1")
                    took = time.monotonic() - start
                    check(got == SENTINEL and took < 2.0,
                          f"single window, {at} s: the slow page answers at once (got {got!r} in {took:.2f}s)")
                    crashed = zb.page.list()["pages"][0].get("crashed")
                    now = web_processes(browser.proc.pid)
                    check(crashed is None and processes <= now,
                          f"single window, {at} s: its web process still runs (crashed={crashed!r}, before {processes}, now {now})")
                failed = browser.load_failures()
                check(not any(uri.endswith("/slow") for uri in failed), f"single window: the slow load got no LOAD_FAIL (got {failed})")
                ended = browser.terminations()
                check(not ended, f"single window: no 'web process terminated' line (got {ended})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"single window: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(browser.stderr[-30:]))
        finally:
            RELEASE.set()
            stop_browser(browser.proc)


def single_window_never(binary: Path, origin: str, check) -> None:
    """A load that never commits, in a window that shares its web process
    with nobody: given up at 15 s and its web process ended, as before."""
    with tempfile.TemporaryDirectory(prefix="zb-slow-load-e2e-") as tmp_name:
        RELEASE.clear()
        browser = Browser(binary, f"{origin}/main", Path(tmp_name))
        try:
            with browser.connect() as zb:
                check(zb.page.evaluate("document.title")["result"] == "main", "never, single window: loaded")
                t0 = time.monotonic()
                zb.page.evaluate(f"(setTimeout(() => {{ location.href = '{origin}/never'; }}, 0), 1)")
                while time.monotonic() - t0 < 16:
                    time.sleep(0.02)
                crashed = zb.page.list()["pages"][0].get("crashed")
                check(crashed == "terminated_by_api", f"never, single window, 16 s: page.list marks it terminated_by_api (got {crashed!r})")
                failed = browser.load_failures()
                # The URI WebKit reports is still the committed page's (the
                # request was never answered), so it may name /main.
                check(failed in ([f"{origin}/never"], [f"{origin}/main"]),
                      f"never, single window: one LOAD_FAIL for the load (got {failed})")
                ended = browser.terminations()
                check(ended == ["zigBrowser: window 1: web process terminated (terminated_by_api)"],
                      f"never, single window: stderr names window 1 (got {ended})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"never, single window: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(browser.stderr[-30:]))
        finally:
            RELEASE.set()
            stop_browser(browser.proc)


def related_windows(binary: Path, origin: str, other: str, check) -> None:
    with tempfile.TemporaryDirectory(prefix="zb-slow-load-e2e-") as tmp_name:
        RELEASE.clear()
        browser = Browser(binary, f"{origin}/main", Path(tmp_name))
        proc = browser.proc
        try:
            with browser.connect() as zb:
                def ev(window: str, expression: str):
                    return zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

                def pages() -> dict[str, dict]:
                    return {p["window_id"]: p for p in zb.page.list()["pages"]}

                def window_for(path: str, timeout: float = 10) -> str:
                    end = time.monotonic() + timeout
                    while time.monotonic() < end:
                        for wid, page in pages().items():
                            if page.get("url", "").startswith(f"{origin}{path}"):
                                return wid
                        time.sleep(0.05)
                    raise TimeoutError(f"no window for {path}: {pages()}")

                check(ev("window-1", "(window.__state = 'main state', document.title)") == "main",
                      "window 1 loaded and holds state")
                ev("window-1", f"(window.open('{origin}/sib'), 1)")
                sib = window_for("/sib")
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        if ev(sib, "document.title") == "sib":
                            break
                    except Exception:  # noqa: BLE001 - still loading
                        pass
                    time.sleep(0.1)
                check(ev(sib, "(window.__state = 'sibling state', window.__state)") == "sibling state",
                      f"the sibling popup ({sib}) loaded and holds state")
                shared_before = web_processes(proc.pid)
                check(len(shared_before) == 1, f"the related windows share one web process ({shared_before})")

                before = set(pages())
                t0 = time.monotonic()
                ev("window-1", f"(window.open('{origin}/slow'), window.open('{origin}/never'), "
                               f"window.open('{other}/slow', '_blank', 'noopener'), 1)")
                # The never-answering popup has no URL yet: tell the new
                # windows apart by opening order (window ids only grow).
                deadline = time.monotonic() + 10
                opened: list[str] = []
                while len(opened) < 3 and time.monotonic() < deadline:
                    opened = sorted((w for w in pages() if w not in before), key=lambda w: int(w.split("-")[1]))
                    time.sleep(0.05)
                if len(opened) != 3:
                    raise TimeoutError(f"expected three new popups, got {pages()}")
                slow, never, solo = opened
                deadline = time.monotonic() + 10
                while len(web_processes(proc.pid)) < 2 and time.monotonic() < deadline:
                    time.sleep(0.05)
                solo_process = web_processes(proc.pid) - shared_before
                check(len(solo_process) == 1, f"the noopener popup ({solo}) has a web process of its own ({solo_process})")

                def at(seconds: float) -> None:
                    while time.monotonic() - t0 < seconds:
                        time.sleep(0.02)

                def siblings_answer(label: str) -> None:
                    for wid, want in (("window-1", "main state"), (sib, "sibling state")):
                        start = time.monotonic()
                        try:
                            got = ev(wid, "window.__state")
                        except Exception as exc:  # noqa: BLE001
                            got = f"error {exc}"
                        took = time.monotonic() - start
                        check(got == want and took < 2.0, f"{label}: {wid} keeps its state and answers at once (got {got!r} in {took:.2f}s)")

                def nothing_crashed(label: str) -> None:
                    listed = pages()
                    dead = {wid: p["crashed"] for wid, p in listed.items() if p.get("crashed")}
                    check(not dead, f"{label}: no window reports a dead web process (got {dead})")
                    check(all(w in listed for w in (slow, never, solo)), f"{label}: all five windows are open ({sorted(listed)})")
                    now = web_processes(proc.pid)
                    check(shared_before <= now, f"{label}: the shared web process still runs (before {shared_before}, now {now})")
                    check(solo_process <= now, f"{label}: the solo window's own web process still runs ({solo_process}, now {now})")

                def sentinel(label: str, window: str, limit: float | None, not_before: float | None = None) -> None:
                    start = time.monotonic()
                    try:
                        got = ev(window, "document.getElementById('sentinel').textContent")
                    except Exception as exc:  # noqa: BLE001
                        got = f"error {exc}"
                    took = time.monotonic() - start
                    answered = time.monotonic() - t0
                    ok = got == SENTINEL and (limit is None or took < limit) and (not_before is None or answered >= not_before)
                    held = "" if not_before is None else f", held until >= {not_before}s"
                    check(ok, f"{label}: {window} answers with its sentinel{held} (got {got!r} at {answered:.1f}s, after {took:.1f}s)")

                at(14)
                siblings_answer("14 s")
                nothing_crashed("14 s")
                # Both slow windows' first loads are still running: these
                # commands wait for them until the timer stops holding them
                # at 15 s (14.8 s allows for timer jitter); a page marked
                # ready at commit would answer at once and fail this.
                sentinel("14 s", slow, None, not_before=14.8)
                sentinel("14 s", solo, None, not_before=14.8)

                at(16)
                siblings_answer("16 s")
                nothing_crashed("16 s")
                sentinel("16 s", slow, 2.0)
                sentinel("16 s", solo, 2.0)
                try:
                    shot = zb.call("page.screenshot", {"window_id": slow})
                    distinct = png_distinct_bytes(base64.b64decode(shot["data"]))
                except Exception as exc:  # noqa: BLE001
                    distinct, shot = 0, {"error": repr(exc)}
                check(distinct > 16, f"16 s: the slow window's screenshot is not blank ({distinct} distinct byte values"
                                     f"{'' if distinct else ', ' + str(shot.get('error'))})")
                check(not pages()[never].get("crashed"), "16 s: the never-answering window has no dead web process")
                # Given up at 15 s, its window no longer holds commands.
                start = time.monotonic()
                try:
                    got = zb.call("page.url", {"window_id": never, "timeout_ms": 5000})
                except Exception as exc:  # noqa: BLE001
                    got = {"error": repr(exc)}
                took = time.monotonic() - start
                check("url" in got and took < 2.0, f"16 s: the never-answering window answers page.url at once (got {got} in {took:.2f}s)")
                failed = browser.load_failures()
                # WebKit gives a popup whose request was never answered no URI
                # yet, so its LOAD_FAIL names "" (or the URL, should it know it).
                check(any(uri in ("", f"{origin}/never") for uri in failed),
                      f"16 s: the never-committing load was given up with LOAD_FAIL (got {failed})")
                check(not any(uri.endswith("/slow") for uri in failed),
                      f"16 s: the committed slow loads got no LOAD_FAIL (got {failed})")
                ended = browser.terminations()
                check(not ended, f"no 'web process terminated' line on stderr (got {ended})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"related windows: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(browser.stderr[-30:]))
        finally:
            RELEASE.set()
            stop_browser(proc)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    args = parser.parse_args()

    binary = Path(args.binary)
    if not require_file(binary, "binary"):
        return SKIP_EXIT
    if shutil.which("Xvfb") is None or shutil.which("xauth") is None:
        eprint("SKIP: needs Xvfb and xauth (the browser must run on its own display)")
        return SKIP_EXIT

    failures: list[str] = []

    def check(ok: bool, label: str) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {label}", flush=True)
        if not ok:
            failures.append(label)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_address[1]}"
    other = f"http://localhost:{server.server_address[1]}"  # another site: another web process
    try:
        single_window(binary, origin, check)
        related_windows(binary, origin, other, check)
        single_window_never(binary, origin, check)
    finally:
        RELEASE.set()
        server.shutdown()
        server.server_close()

    if failures:
        print("FAIL\tslow-load-watchdog")
        return 1
    print("PASS\tslow-load-watchdog")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
