#!/usr/bin/env python3
"""A window whose WebKit web process dies says so (no silent blank window).

On its own Xvfb display, the browser loads a page; the test then kills
that browser's WebKitWebProcess children (SIGKILL, so WebKit reports a
crash). page.list must then show "crashed": "crashed" for the window, and
stderr must name the window and the reason.

Crash page: the window does not stay blank. The same view shows "This page
crashed (<reason in words>)" with a Reload link (no zbHost privilege), and
stderr says once "zigBrowser: window 1: showing crash page". page.list
keeps reporting the crash, with the page's URL, while the crash page shows.
This page is a local file, which WebKit lets no string-loaded page link to:
its Reload goes to https://zigbrowser.invalid/reload-crashed-page, which the
browser turns into a load of the page. A real X click on Reload (on the private display)
brings the original page back and clears the crash. The page URL carries
`&`, `'` and a literal `&amp;`. Loading a page again starts a new web process: the window
works and the reason is gone.

Popups: window 1 opens a same-origin popup (window 2, same web process)
and a noopener popup from another origin (window 3, a web process of its
own); each holds some state. Killing window 3's process marks only window 3,
by its id (page.list and stderr); windows 1 and 2 keep their state. Killing
the shared process then marks windows 1 and 2, each by its own id.

Each crashed window shows its own crash page once (stderr names it by id).
Each crashed window's own document is the crash page (text and Reload),
and no page is requested again by itself (the server counts requests):
the count stays the same until the person clicks Reload. The noopener
popup's page is http: its Reload is an ordinary link to the page's URL
(escaped: the URL carries a literal `&amp;`), and a real X click on it requests
the page exactly once more and brings it back.

Blank page: a window opened on about:blank crashes too. Its crash page
loads as about:blank itself, and a link from it to about:blank is followed:
so its Reload is a plain about:blank link. Two fresh browsers: in the
control, after the crash nothing is clicked and no X input is sent for
BLANK_HOLD_SEC, and the crash page and page.list's "crashed" must remain
throughout; in the other, a real X click on Reload must load about:blank
again and clear the crash within BLANK_CLICK_SEC (< BLANK_HOLD_SEC). So
the click, not an automatic reload, clears it.

Quiet shutdown: with the same three windows (two web processes), stopping
the browser with SIGTERM, and in a second run with SIGINT, ends every web
process without a "web process terminated" or crash page line: our own
termination is not a death to report, as for page.close.

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
import http.server
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, stop_browser, xsession_prefix  # noqa: E402
from xinput import XInput  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

PAGE = "<!doctype html><title>crash fixture</title><p id=alive>alive</p>"
# A query the crash page's link must escape: unescaped, "&amp;" would read
# as "&" and the link would go elsewhere.
QUERY = "?from=crash&who='zb'&amp;x=1"
RELOAD_LOCAL = "https://zigbrowser.invalid/reload-crashed-page"
CRASH_TEXT = "This page crashed (the page's process stopped unexpectedly)"
# The blank-page control holds longer, with no input, than the clicked run may take to
# clear: an automatic reload inside the hold turns the control red.
BLANK_HOLD_SEC = 12.0
BLANK_CLICK_SEC = 10.0


def descendants(pid: int) -> list[int]:
    found: list[int] = []
    queue = [pid]
    while queue:
        parent = queue.pop()
        try:
            children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
        except OSError:
            continue
        for child in children:
            found.append(int(child))
            queue.append(int(child))
    return found


def web_processes(pid: int) -> list[int]:
    out = []
    for child in descendants(pid):
        try:
            if Path(f"/proc/{child}/comm").read_text().strip().startswith("WebKitWebProces"):
                out.append(child)
        except OSError:
            pass
    return out


class Pages(http.server.BaseHTTPRequestHandler):
    hits: dict[str, int] = {}  # requests per page name: no automatic retry
    hits_lock = threading.Lock()

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        name = self.path.split("?")[0].strip("/") or "main"
        with Pages.hits_lock:
            Pages.hits[name] = Pages.hits.get(name, 0) + 1
        body = f"<!doctype html><title>{name}</title><p id=name>{name}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")  # any reload reaches the count
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args) -> None:
        pass


def window_one(zb: ZigBrowser) -> dict:
    return next(p for p in zb.page.list()["pages"] if p["window_id"] == "window-1")


def popups(browser: Path, base_env: dict[str, str], check) -> None:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_address[1]}"
    other = f"http://localhost:{server.server_address[1]}"  # another site: another web process
    env = dict(base_env)
    with tempfile.TemporaryDirectory(prefix="zb-crash-popup-e2e-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        display_file = Path(tmp) / "display"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            xsession_prefix(True)[:-1] + ["--display-file", str(display_file), "--",
                                          str(browser.resolve()), f"{origin}/main", "--automation-api",
                                          "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
        )
        stderr_lines: list[str] = []
        threading.Thread(target=lambda: stderr_lines.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        try:
            deadline = time.monotonic() + 20
            while not socket_path.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("socket never appeared")
                time.sleep(0.05)
            with ZigBrowser(socket_path=str(socket_path)) as zb, XInput.from_display_file(display_file) as x:
                def ev(window: str, expression: str):
                    return zb.call("page.evaluate", {"expression": expression, "window_id": window})["result"]

                def pages() -> dict[str, dict]:
                    return {p["window_id"]: p for p in zb.page.list()["pages"]}

                def open_popup(url: str, features: str) -> str:
                    before = set(pages())
                    ev("window-1", f"(window.open('{url}', '_blank', '{features}'), 1)")
                    end = time.monotonic() + 10
                    while time.monotonic() < end:
                        for wid in set(pages()) - before:
                            try:
                                if ev(wid, "document.title") == url.rsplit("/", 1)[1].split("?")[0]:
                                    return wid
                            except Exception:  # noqa: BLE001 - still loading
                                pass
                        time.sleep(0.1)
                    raise TimeoutError(f"popup {url} never loaded: {pages()}")

                def crash_dom(wid: str) -> dict | None:
                    end = time.monotonic() + 10
                    while time.monotonic() < end:
                        try:
                            got = ev(wid, "(() => { const a = document.getElementById('zb-crash-reload'); if (!a) return null;"
                                          " const r = a.getBoundingClientRect(); return {text: document.body.innerText,"
                                          " href: a.href, x: r.left + r.width / 2, y: r.top + r.height / 2}; })()")
                            if got is not None:
                                return got
                        except Exception:  # noqa: BLE001 - no web process yet
                            pass
                        time.sleep(0.1)
                    return None

                def hits(name: str) -> int:
                    with Pages.hits_lock:
                        return Pages.hits.get(name, 0)

                def states() -> dict[str, str]:
                    out = {}
                    for wid in pages():
                        try:
                            out[wid] = ev(wid, "window.__state")
                        except Exception as exc:  # noqa: BLE001
                            out[wid] = f"error {exc}"
                    return out

                def crashed_after_kill(pids: set[int], want: set[str]) -> dict[str, str | None]:
                    for pid in pids:
                        os.kill(pid, signal.SIGKILL)
                    end = time.monotonic() + 10
                    marks = {}
                    while time.monotonic() < end:
                        marks = {wid: p.get("crashed") for wid, p in pages().items()}
                        if all(marks.get(w) == "crashed" for w in want):
                            break
                        time.sleep(0.1)
                    time.sleep(0.3)
                    return marks

                ev("window-1", "(window.__state = 'main state', 1)")
                shared = set(web_processes(proc.pid))
                sibling = open_popup(f"{origin}/sib", "")
                ev(sibling, "(window.__state = 'sibling state', 1)")
                check(set(web_processes(proc.pid)) == shared and len(shared) == 1,
                      f"popups: the same-origin popup ({sibling}) shares window 1's web process ({shared})")
                solo = open_popup(f"{other}/solo{QUERY.replace("'", "%27")}", "noopener")
                ev(solo, "(window.__state = 'solo state', 1)")
                solo_process = set(web_processes(proc.pid)) - shared
                check(len(solo_process) == 1, f"popups: the noopener popup ({solo}) has a web process of its own ({solo_process})")

                solo_hits = hits("solo")
                marks = crashed_after_kill(solo_process, {solo})
                check(marks == {"window-1": None, sibling: None, solo: "crashed"},
                      f"popups: killing the solo popup's process marks only {solo} (got {marks})")
                got = states()
                check(got.get("window-1") == "main state" and got.get(sibling) == "sibling state",
                      f"popups: windows 1 and {sibling} keep their state (got {got})")
                logged = [line.strip() for line in stderr_lines if "web process terminated" in line]
                solo_n = solo.split("-")[1]
                check(logged == [f"zigBrowser: window {solo_n}: web process terminated (crashed)"],
                      f"popups: stderr names only window {solo_n} (got {logged})")
                time.sleep(0.5)
                shown = [line.strip() for line in stderr_lines if "crash page" in line]
                check(shown == [f"zigBrowser: window {solo_n}: showing crash page"],
                      f"popups: only window {solo_n} shows a crash page (got {shown})")

                # The http page's Reload: an ordinary link, clicked for real.
                solo_url = pages()[solo]["url"]
                link = crash_dom(solo)
                check(link is not None and CRASH_TEXT in link["text"],
                      f"popups: {solo}'s own document is the crash page (got {link})")
                check(link is not None and link["href"] == solo_url and "&amp;x=1" in solo_url,
                      f"popups: {solo}'s Reload is a link to its page {solo_url!r} (got {link})")
                time.sleep(1.0)
                check(hits("solo") == solo_hits,
                      f"popups: {solo}'s page is not requested again by itself ({solo_hits} before the crash, {hits('solo')} now)")
                ev(solo, "(window.__offset = null, addEventListener('mousemove', e => "
                         "{ window.__offset = [e.screenX - e.clientX, e.screenY - e.clientY]; }), 1)")
                offset = None
                for step in range(20):
                    x.move(300 + step, 300 + step)
                    time.sleep(0.1)
                    offset = ev(solo, "window.__offset")
                    if offset:
                        break
                if link is not None and offset:
                    x.click(round(offset[0] + link["x"]), round(offset[1] + link["y"]))
                end = time.monotonic() + 15
                while time.monotonic() < end and (pages()[solo].get("crashed") or pages()[solo].get("title") != "solo"):
                    time.sleep(0.1)
                got = pages()[solo]
                check(bool(offset) and got.get("title") == "solo" and "crashed" not in got and got.get("url") == solo_url,
                      f"popups: a real click on {solo}'s Reload brings its page back (offset {offset}, got {got})")
                check(hits("solo") == solo_hits + 1,
                      f"popups: Reload requests {solo}'s page exactly once ({solo_hits} before, {hits('solo')} after)")

                shared_hits = (hits("main"), hits("sib"))
                marks = crashed_after_kill(shared, {"window-1", sibling})
                check(marks == {"window-1": "crashed", sibling: "crashed", solo: None},
                      f"popups: killing the shared process marks windows 1 and {sibling} too (got {marks})")
                health = {p["window_id"]: p.get("crashed") for p in zb.call("page.health", {})["pages"]}
                check(health == marks, f"popups: page.health reports the same crashed windows (got {health})")
                logged = sorted(line.strip() for line in stderr_lines if "web process terminated" in line)
                sib_n = sibling.split("-")[1]
                want = sorted(f"zigBrowser: window {n}: web process terminated (crashed)" for n in ("1", sib_n, solo_n))
                check(logged == want, f"popups: stderr names each window once, by its own id (got {logged})")
                time.sleep(0.5)
                shown = sorted(line.strip() for line in stderr_lines if "crash page" in line)
                want = sorted(f"zigBrowser: window {n}: showing crash page" for n in ("1", sib_n, solo_n))
                check(shown == want, f"popups: each crashed window shows its own crash page once (got {shown})")
                for wid in ("window-1", sibling):
                    dom = crash_dom(wid)
                    check(dom is not None and CRASH_TEXT in dom["text"] and dom["href"] == pages()[wid]["url"],
                          f"popups: {wid}'s own document is the crash page, Reload to {pages()[wid]['url']!r} (got {dom})")
                time.sleep(1.0)
                check((hits("main"), hits("sib")) == shared_hits,
                      f"popups: windows 1 and {sibling} are not requested again by themselves ({shared_hits} -> {(hits('main'), hits('sib'))})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"popups: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-30:]))
        finally:
            stop_browser(proc)
            server.shutdown()
            server.server_close()


def quiet_shutdown(browser: Path, base_env: dict[str, str], check) -> None:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_address[1]}"
    other = f"http://localhost:{server.server_address[1]}"  # another site: another web process
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            label = f"quiet {sig.name}"
            env = dict(base_env)
            with tempfile.TemporaryDirectory(prefix="zb-crash-quiet-e2e-") as tmp:
                socket_path = Path(tmp) / "automation.sock"
                env["ZIGBROWSER_SOCKET"] = str(socket_path)
                proc = subprocess.Popen(
                    xsession_prefix(True) + [str(browser.resolve()), f"{origin}/main", "--automation-api",
                                             "--profile-dir", str(Path(tmp) / "profile")],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
                )
                stderr_lines: list[str] = []
                reader = threading.Thread(target=lambda: stderr_lines.extend(proc.stderr), daemon=True)  # type: ignore[arg-type]
                reader.start()
                try:
                    deadline = time.monotonic() + 20
                    while not socket_path.exists():
                        if time.monotonic() > deadline:
                            raise TimeoutError("socket never appeared")
                        time.sleep(0.05)
                    with ZigBrowser(socket_path=str(socket_path)) as zb:
                        zb.page.evaluate(f"(window.open('{origin}/sib'), window.open('{other}/solo', '_blank', 'noopener'), 1)")
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            titles = sorted(p["title"] for p in zb.page.list()["pages"])
                            if titles == ["main", "sib", "solo"] and len(web_processes(proc.pid)) == 2:
                                break
                            time.sleep(0.1)
                        check(titles == ["main", "sib", "solo"] and len(web_processes(proc.pid)) == 2,
                              f"{label}: three windows in two web processes (titles {titles}, processes {web_processes(proc.pid)})")
                    proc.send_signal(sig)
                    try:
                        rc = proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        rc = None
                    reader.join(timeout=5)
                    check(rc is not None, f"{label}: the browser stopped (rc={rc})")
                    logged = [line.strip() for line in stderr_lines if "web process terminated" in line]
                    check(not logged, f"{label}: no 'web process terminated' line on stderr (got {logged})")
                    shown = [line.strip() for line in stderr_lines if "crash page" in line]
                    check(not shown, f"{label}: no crash page on quit (got {shown})")
                except Exception as exc:  # noqa: BLE001 - report every failure the same way
                    check(False, f"{label}: error={exc!r}")
                    eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-30:]))
                finally:
                    stop_browser(proc)
    finally:
        server.shutdown()
        server.server_close()


def blank_page(browser: Path, base_env: dict[str, str], check, click: bool) -> None:
    name = "blank" if click else "blank control"
    env = dict(base_env)
    with tempfile.TemporaryDirectory(prefix="zb-crash-blank-e2e-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        display_file = Path(tmp) / "display"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            xsession_prefix(True)[:-1] + ["--display-file", str(display_file), "--",
                                          str(browser.resolve()), "about:blank", "--automation-api",
                                          "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
        )
        stderr_lines: list[str] = []
        threading.Thread(target=lambda: stderr_lines.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        try:
            deadline = time.monotonic() + 20
            while not socket_path.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("socket never appeared")
                time.sleep(0.05)
            with ZigBrowser(socket_path=str(socket_path)) as zb, XInput.from_display_file(display_file) as x:
                def ev(expression: str):
                    return zb.call("page.evaluate", {"expression": expression, "window_id": "window-1"})["result"]

                deadline = time.monotonic() + 10
                while window_one(zb).get("url") != "about:blank" and time.monotonic() < deadline:
                    time.sleep(0.1)
                check(window_one(zb).get("url") == "about:blank", f"{name}: the window shows about:blank (got {window_one(zb)})")

                ev("(window.__offset = null, addEventListener('mousemove', e => "
                   "{ window.__offset = [e.screenX - e.clientX, e.screenY - e.clientY]; }), 1)")
                offset = None
                for step in range(20):
                    x.move(100 + step, 100 + step)
                    time.sleep(0.1)
                    offset = ev("window.__offset")
                    if offset:
                        break

                for pid in web_processes(proc.pid):
                    os.kill(pid, signal.SIGKILL)

                def crash_page() -> dict | None:
                    try:
                        return ev("(() => { const a = document.getElementById('zb-crash-reload');"
                                  " if (!a) return null; const r = a.getBoundingClientRect();"
                                  " return {text: document.body.innerText, href: a.href,"
                                  " x: r.left + r.width / 2, y: r.top + r.height / 2}; })()")
                    except Exception:  # noqa: BLE001 - no web process yet
                        return None

                deadline = time.monotonic() + 10
                shown = crash_page()
                while shown is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                    shown = crash_page()
                check(shown is not None and CRASH_TEXT in shown["text"] and shown["href"] == "about:blank",
                      f"{name}: the crash page's Reload is a plain about:blank link (got {shown})")
                info = window_one(zb)
                check(info.get("crashed") == "crashed" and info.get("url") == "about:blank",
                      f"{name}: page.list reports the crash and about:blank (got {info})")

                if not click:
                    # No X event after the crash: it must stay for the whole hold.
                    deadline = time.monotonic() + BLANK_HOLD_SEC
                    kept = True
                    while kept and time.monotonic() < deadline:
                        time.sleep(0.25)
                        info = window_one(zb)
                        try:
                            text = ev("document.getElementById('zb-crash') && document.getElementById('zb-crash').textContent")
                        except Exception as exc:  # noqa: BLE001
                            text = f"error {exc}"
                        kept = info.get("crashed") == "crashed" and bool(text) and "This page crashed" in text
                    check(kept, f"{name}: with no input the crash page and 'crashed' stay for {BLANK_HOLD_SEC} s "
                                f"(page {text!r}, list {info})")
                    return
                if shown is not None and offset:
                    x.click(round(offset[0] + shown["x"]), round(offset[1] + shown["y"]))
                deadline = time.monotonic() + BLANK_CLICK_SEC
                info = window_one(zb)
                while info.get("crashed") is not None and time.monotonic() < deadline:
                    time.sleep(0.1)
                    info = window_one(zb)
                gone = None
                try:
                    gone = ev("document.getElementById('zb-crash') === null")
                except Exception as exc:  # noqa: BLE001
                    gone = f"error {exc}"
                check(gone is True and "crashed" not in info and info.get("url") == "about:blank",
                      f"{name}: a real click on Reload loads about:blank again and clears the crash within "
                      f"{BLANK_CLICK_SEC} s (no crash text {gone!r}, list {info})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"{name}: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-30:]))
        finally:
            stop_browser(proc)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    if shutil.which("Xvfb") is None or shutil.which("xauth") is None:
        eprint("SKIP: needs Xvfb and xauth (the browser must run on its own display)")
        return SKIP_EXIT

    env = isolate_profile_env(dict(os.environ))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET"):
        env.pop(name, None)
    failures: list[str] = []

    def check(ok: bool, label: str) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {label}", flush=True)
        if not ok:
            failures.append(label)

    with tempfile.TemporaryDirectory(prefix="zb-crash-e2e-") as tmp:
        page = Path(tmp) / "page.html"
        page.write_text(PAGE, encoding="utf-8")
        socket_path = Path(tmp) / "automation.sock"
        display_file = Path(tmp) / "display"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        page_url = page.as_uri() + QUERY
        proc = subprocess.Popen(
            xsession_prefix(True)[:-1] + ["--display-file", str(display_file), "--",
                                          str(browser.resolve()), page_url, "--automation-api",
                                          "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env,
        )
        stderr_lines: list[str] = []
        threading.Thread(target=lambda: stderr_lines.extend(proc.stderr), daemon=True).start()  # type: ignore[arg-type]
        try:
            deadline = time.monotonic() + args.timeout_sec
            while not socket_path.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("socket never appeared")
                time.sleep(0.05)
            with ZigBrowser(socket_path=str(socket_path)) as zb, XInput.from_display_file(display_file) as x:
                def ev(expression: str):
                    return zb.call("page.evaluate", {"expression": expression, "window_id": "window-1"})["result"]

                zb.dom.wait_for("css=#alive", state="attached", timeout_ms=15000)
                check("crashed" not in window_one(zb), "a live window reports no termination")
                committed = window_one(zb)["url"]
                check(committed.endswith(QUERY.replace("'", "%27")) or committed.endswith(QUERY),
                      f"the page's committed URL keeps its query ({committed!r})")

                # Where the page's 0,0 is on the private screen: a real pointer
                # move reports both coordinates (the crash page has no script).
                ev("(window.__offset = null, addEventListener('mousemove', e => "
                   "{ window.__offset = [e.screenX - e.clientX, e.screenY - e.clientY]; }), 1)")
                offset = None
                for step in range(20):
                    x.move(100 + step, 100 + step)
                    time.sleep(0.1)
                    offset = ev("window.__offset")
                    if offset:
                        break
                check(bool(offset), f"a real pointer move reaches the page (offset {offset})")

                victims = web_processes(proc.pid)
                check(bool(victims), f"the browser has a web process to kill ({victims})")
                for pid in victims:
                    os.kill(pid, signal.SIGKILL)

                deadline = time.monotonic() + 10
                info = window_one(zb)
                while info.get("crashed") is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                    info = window_one(zb)
                check(info.get("crashed") == "crashed", f"page.list says the window's web process crashed (got {info})")
                health = next(p for p in zb.call("page.health", {})["pages"] if p["window_id"] == "window-1")
                check(health.get("crashed") == "crashed", f"page.health says so too (got {health})")
                time.sleep(0.3)
                logged = [line for line in stderr_lines if "web process terminated" in line]
                check(any("window 1" in line and "crashed" in line for line in logged),
                      f"stderr names the window and the reason (got {logged})")

                def crash_page() -> dict | None:
                    try:
                        return ev("(() => { const a = document.getElementById('zb-crash-reload');"
                                  " if (!a) return null; const r = a.getBoundingClientRect();"
                                  " return {text: document.body.innerText, href: a.href, title: document.title,"
                                  " x: r.left + r.width / 2, y: r.top + r.height / 2}; })()")
                    except Exception:  # noqa: BLE001 - no web process yet
                        return None

                deadline = time.monotonic() + 10
                shown = crash_page()
                while shown is None and time.monotonic() < deadline:
                    time.sleep(0.1)
                    shown = crash_page()
                check(shown is not None and CRASH_TEXT in shown["text"],
                      f"the window shows the crash page with the reason in words (got {shown})")
                check(shown is not None and "Reload" in shown["text"] and shown["href"] == RELOAD_LOCAL,
                      f"its Reload link for a local page is {RELOAD_LOCAL} (got {shown and shown['href']!r})")
                info = window_one(zb)
                check(info.get("crashed") == "crashed" and info.get("url") == committed,
                      f"page.list still reports the crash and the page's URL while the crash page shows (got {info})")
                time.sleep(0.3)
                shown_lines = [line.strip() for line in stderr_lines if "crash page" in line]
                check(shown_lines == ["zigBrowser: window 1: showing crash page"],
                      f"stderr says once that window 1 shows the crash page (got {shown_lines})")

                if shown is not None and offset:
                    x.click(round(offset[0] + shown["x"]), round(offset[1] + shown["y"]))
                deadline = time.monotonic() + 15
                info = window_one(zb)
                while (info.get("crashed") is not None or info.get("title") != "crash fixture") and time.monotonic() < deadline:
                    time.sleep(0.1)
                    info = window_one(zb)
                alive = None
                try:
                    alive = ev("document.getElementById('alive') && document.getElementById('alive').textContent")
                except Exception as exc:  # noqa: BLE001
                    alive = f"error {exc}"
                check(alive == "alive" and "crashed" not in info and info.get("url") == committed,
                      f"a real click on Reload brings the page back and clears the crash (page {alive!r}, list {info})")
                shown_lines = [line.strip() for line in stderr_lines if "crash page" in line]
                check(len(shown_lines) == 1, f"the reload shows no second crash page (got {shown_lines})")

                zb.page.navigate(page.as_uri())
                zb.dom.wait_for("css=#alive", state="attached", timeout_ms=15000)
                check("crashed" not in window_one(zb), "after a new load the window works and the reason is gone")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            failures.append(f"error={exc!r}")
            eprint(f"error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-30:]))
        finally:
            stop_browser(proc)

        popups(browser, env, check)
        blank_page(browser, env, check, click=False)
        blank_page(browser, env, check, click=True)
        quiet_shutdown(browser, env, check)

    if failures:
        print("FAIL\tweb-process-crash")
        return 1
    print("PASS\tweb-process-crash")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
