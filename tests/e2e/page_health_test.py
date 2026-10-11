#!/usr/bin/env python3
"""page.health reports a frozen page, out of band (watchdog slice 1; review
log, "Required failing test and watchdog direction").

One browser on its own Xvfb display, with the automation API:

- window 1 (127.0.0.1): a button whose click runs `while (true) {}`;
- "solo" (localhost, opened with noopener: a web process of its own): a
  button whose click busies the page for 9 s, then lets it go;
- "never" (localhost, noopener): a load the server never answers.

Checks:
1. Before anything: every window responsive, unresponsive_ms 0, no dialog,
   no "crashed"; only "never" is loading; debounce_ms is reported.
2. A native click on window 1's button. That click holds window 1's
   command queue (it waits for the page) until its 10 s deadline. page.health still answers at once
   while it is held, and window 1 turns responsive:false within WebKit's
   own deadline plus the debounce. Every answer has responsive ==
   (unresponsive_ms < debounce_ms). The solo window stays responsive and
   answers page.evaluate at once.
3. The solo page's 9 s busy loop: it turns responsive:false, then back to
   responsive:true with unresponsive_ms 0 once the loop ends (busy is only
   suspected, never final).
4. An alert in the solo window: dialog_open:true, and it stays responsive
   past WebKit's deadline plus the debounce (a dialog is not a freeze).
5. stderr: `zigBrowser: window N: page not responding for Ns` once per
   window that stayed unresponsive past the debounce, and `zigBrowser:
   window N: page responding again` once when it answers again; no repeat
   while the state holds, and no line on the normal quit.

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
import http.server
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

RELEASE = threading.Event()  # set at teardown: the never-answered request ends
# WebKit marks a web process unresponsive once it misses a reply for about
# 3 s; page.health then waits debounce_ms more. This bound adds slack for a
# loaded host.
DETECT_SLACK_S = 6.0
# Window 1's click waits for a page that never answers: it holds window 1's
# queue, and native input for every window, until this deadline.
CLICK_DEADLINE_MS = 10_000

PAGE = """<!doctype html><title>{name}</title>
<button id=spin style="position:fixed;left:20px;top:20px;width:300px;height:120px"
 onclick="{handler}">spin</button><p id=name>{name}</p>"""
FOREVER = "while (true) {}"
BUSY_9S = "const end = Date.now() + 9000; while (Date.now() < end) {}"


class Pages(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path.startswith("/never"):
            RELEASE.wait(60)
            return
        name = self.path.strip("/") or "main"
        body = PAGE.format(name=name, handler=FOREVER if name == "main" else BUSY_9S).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def run(binary: Path, origin: str, other: str, check) -> None:
    with tempfile.TemporaryDirectory(prefix="zb-page-health-e2e-") as tmp_name:
        tmp = Path(tmp_name)
        env = isolate_profile_env(dict(os.environ))
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET"):
            env.pop(name, None)
        socket_path = tmp / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        stderr: list[str] = []
        proc = subprocess.Popen(
            xsession_prefix(True) + [str(binary.resolve()), f"{origin}/main", "--automation-api",
                                     "--profile-dir", str(tmp / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
        )
        threading.Thread(target=lambda: stderr.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        try:
            deadline = time.monotonic() + 20
            while not socket_path.exists():
                if proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"no automation socket (browser exit {proc.poll()})")
                time.sleep(0.05)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                checks(zb, socket_path, origin, other, check)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr[-30:]))
        finally:
            RELEASE.set()
            stop_browser(proc)
        time.sleep(0.3)
        log_checks(stderr, check)


def log_checks(stderr: list[str], check) -> None:
    """5. The live log: one line when a window has been unresponsive past
    the debounce, one when it answers again; nothing repeated, nothing on
    the normal quit (window 1 was still frozen when the browser quit)."""
    events: dict[str, list[str]] = {}
    for line in stderr:
        m = re.fullmatch(r"zigBrowser: window (\d+): page (?:not responding for (\d+)s|responding again)", line.rstrip("\n"))
        if not m:
            continue
        if m.group(2) is not None:
            seconds = int(m.group(2))
            check(2 <= seconds <= 4, f"log: window {m.group(1)}'s line gives the time so far, the debounce or a little more ({line.rstrip()})")
            events.setdefault(m.group(1), []).append("not responding")
        else:
            events.setdefault(m.group(1), []).append("responding again")
    check(events == {"1": ["not responding"], "2": ["not responding", "responding again"]},
          f"log: window 1 (still frozen at quit) has one 'not responding' line; window 2 (the 9 s loop) one, then one "
          f"'responding again'; the loading window none ({events})")


def checks(zb: ZigBrowser, socket_path: Path, origin: str, other: str, check) -> None:
    def ev(window: str, expression: str):
        return zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

    debounce_ms: list[int] = []

    def health(label: str) -> tuple[dict[str, dict], float]:
        start = time.monotonic()
        result = zb.call("page.health", {})
        took = time.monotonic() - start
        if not debounce_ms:
            debounce_ms.append(result.get("debounce_ms"))
        pages = {p["window_id"]: p for p in result["pages"]}
        for wid, p in pages.items():
            want = p["unresponsive_ms"] < result["debounce_ms"]
            if p["responsive"] != want:
                check(False, f"{label}: {wid} responsive={p['responsive']} disagrees with unresponsive_ms="
                             f"{p['unresponsive_ms']} and debounce_ms={result['debounce_ms']}")
        return pages, took

    check(ev("window-1", "document.title") == "main", "window 1 loaded")
    ev("window-1", f"(window.open('{other}/solo', '_blank', 'noopener'), "
                   f"window.open('{other}/never', '_blank', 'noopener'), 1)")
    deadline = time.monotonic() + 15
    solo = never = None
    while (solo is None or never is None) and time.monotonic() < deadline:
        listed = zb.page.list()["pages"]
        new = sorted((p["window_id"] for p in listed if p["window_id"] != "window-1"), key=lambda w: int(w.split("-")[1]))
        if len(new) == 2:
            solo, never = new
        time.sleep(0.05)
    if solo is None or never is None:
        raise TimeoutError(f"expected two popups: {zb.page.list()}")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            if ev(solo, "document.title") == "solo":
                break
        except Exception:  # noqa: BLE001 - still loading
            pass
        time.sleep(0.1)

    # 1. Baseline.
    pages, _ = health("baseline")
    check(isinstance(debounce_ms[0], int) and 500 <= debounce_ms[0] <= 10_000,
          f"baseline: debounce_ms is reported ({debounce_ms[0]!r})")
    check(sorted(pages) == sorted(["window-1", solo, never]), f"baseline: page.health lists every window ({sorted(pages)})")
    for wid, p in pages.items():
        check(p["responsive"] is True and p["unresponsive_ms"] == 0 and p["dialog_open"] is False and "crashed" not in p,
              f"baseline: {wid} responsive, no dialog, not crashed ({p})")
        check(p["loading"] is (wid == never), f"baseline: {wid} loading={wid == never} ({p})")

    # 2. Window 1 freezes after a native click; its queue stays held.
    clicker = ZigBrowser(socket_path=str(socket_path))
    clicker.connect()  # its own connection: this click blocks until the page answers
    click_result: list = []

    def click() -> None:
        try:
            click_result.append(clicker.call("dom.click", {"selector": "css=#spin",
                                                           "options": {"input": "native", "timeout_ms": CLICK_DEADLINE_MS}}))
        except Exception as exc:  # noqa: BLE001 - expected: the page never answers
            click_result.append(exc)

    clicked_at = time.monotonic()
    threading.Thread(target=click, daemon=True).start()
    bound = debounce_ms[0] / 1000 + DETECT_SLACK_S
    frozen_at = None
    slowest = 0.0
    seen_suspected = False
    while time.monotonic() - clicked_at < bound + 2:
        pages, took = health("freeze")
        slowest = max(slowest, took)
        p = pages.get("window-1", {})
        if p.get("unresponsive_ms", 0) > 0 and p.get("responsive"):
            seen_suspected = True
        if p.get("responsive") is False:
            frozen_at = time.monotonic() - clicked_at
            break
        time.sleep(0.2)
    check(frozen_at is not None and frozen_at <= bound,
          f"freeze: window 1 turns responsive:false within {bound:.1f} s of the click (after {frozen_at})")
    check(not click_result, f"freeze: the click still holds window 1's queue while page.health answers ({click_result})")
    check(slowest < 1.0, f"freeze: page.health answered at once every time (slowest {slowest:.2f} s)")
    check(seen_suspected,
          "freeze: before the debounce ended, window 1 was reported unresponsive_ms > 0 but still responsive:true")
    pages, _ = health("freeze, other windows")
    check(pages[solo]["responsive"] is True and pages[solo]["unresponsive_ms"] == 0,
          f"freeze: the solo window (own web process) stays responsive ({pages[solo]})")
    start = time.monotonic()
    title = ev(solo, "document.title")
    check(title == "solo" and time.monotonic() - start < 2.0, f"freeze: the solo window answers page.evaluate at once ({title!r})")
    held, _ = health("freeze, held")
    check(held["window-1"]["unresponsive_ms"] >= debounce_ms[0], f"freeze: window 1 stays unresponsive ({held['window-1']})")

    # 3. A bounded busy loop: suspected, then responsive again. Native input
    # is one at a time across windows, so window 1's click must end first.
    deadline = time.monotonic() + CLICK_DEADLINE_MS / 1000 + 5
    while not click_result and time.monotonic() < deadline:
        time.sleep(0.1)
    check(bool(click_result), f"freeze: window 1's click ended at its deadline ({click_result})")
    pages, _ = health("frozen, click ended")
    check(pages["window-1"]["responsive"] is False, f"freeze: window 1 is still reported frozen after its click ended ({pages['window-1']})")
    busy_click = ZigBrowser(socket_path=str(socket_path))
    busy_click.connect()
    busy_result: list = []

    def busy() -> None:
        try:
            busy_result.append(busy_click.call("dom.click", {"selector": "css=#spin", "window_id": solo,
                                                             "options": {"input": "native", "timeout_ms": 20_000}}))
        except Exception as exc:  # noqa: BLE001 - reported below if the loop never ran
            busy_result.append((round(time.monotonic() - busy_at, 1), exc, getattr(exc, "diagnostics", None)))

    busy_at = time.monotonic()
    threading.Thread(target=busy, daemon=True).start()
    went_false = came_back = None
    while time.monotonic() - busy_at < 9 + bound + 4:
        pages, _ = health("busy")
        p = pages[solo]
        if went_false is None and p["responsive"] is False:
            went_false = time.monotonic() - busy_at
        if went_false is not None and p["responsive"] is True and p["unresponsive_ms"] == 0:
            came_back = time.monotonic() - busy_at
            break
        time.sleep(0.2)
    check(went_false is not None, f"busy: the solo window was reported responsive:false during its 9 s loop "
                                  f"(after {went_false}; click {busy_result})")
    check(came_back is not None, f"busy: and responsive:true with unresponsive_ms 0 once the loop ended (after {came_back})")

    # 4. A dialog is not a freeze.
    # The alert may open before this call answers (-32013 dialog_open).
    _quiet(lambda: ev(solo, "(setTimeout(() => alert('health'), 50), 1)"))
    deadline = time.monotonic() + 5
    p = {}
    while time.monotonic() < deadline:
        p = health("dialog")[0][solo]
        if p["dialog_open"]:
            break
        time.sleep(0.1)
    check(p.get("dialog_open") is True, f"dialog: the solo window reports dialog_open:true ({p})")
    opened_at = time.monotonic()
    worst = p
    while time.monotonic() - opened_at < 3 + debounce_ms[0] / 1000 + 1:
        p = health("dialog")[0][solo]
        if not p["responsive"]:
            worst = p
            break
        time.sleep(0.25)
    check(worst.get("responsive") is True, f"dialog: the solo window stays responsive while its alert is open ({worst})")
    zb.call("dialog.respond", {"accept": True, "window_id": solo})


def _quiet(fn) -> None:
    try:
        fn()
    except Exception:  # noqa: BLE001 - the page is busy; only page.health matters
        pass


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
        run(binary, origin, other, check)
    finally:
        RELEASE.set()
        server.shutdown()
        server.server_close()

    if failures:
        print("FAIL\tpage-health")
        return 1
    print("PASS\tpage-health")
    return 0


if __name__ == "__main__":
    sys.exit(main())
