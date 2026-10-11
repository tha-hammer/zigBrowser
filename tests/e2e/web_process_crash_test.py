#!/usr/bin/env python3
"""A window whose WebKit web process dies says so (no silent blank window).

On its own Xvfb display, the browser loads a page; the test then kills
that browser's WebKitWebProcess children (SIGKILL, so WebKit reports a
crash). page.list must then show "crashed": "crashed" for the window, and
stderr must name the window and the reason. Loading a page again starts a
new web process: the window works and the reason is gone.

Popups: window 1 opens a same-origin popup (window 2, same web process)
and a noopener popup from another origin (window 3, a web process of its
own); each holds some state. Killing window 3's process marks only window 3,
by its id (page.list and stderr); windows 1 and 2 keep their state. Killing
the shared process then marks windows 1 and 2, each by its own id.

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
from zigbrowser import ZigBrowser  # noqa: E402

PAGE = "<!doctype html><title>crash fixture</title><p id=alive>alive</p>"


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
    def do_GET(self) -> None:  # noqa: N802 - http.server API
        name = self.path.strip("/") or "main"
        body = f"<!doctype html><title>{name}</title><p id=name>{name}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            xsession_prefix(True) + [str(browser.resolve()), f"{origin}/main", "--automation-api",
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
            with ZigBrowser(socket_path=str(socket_path)) as zb:
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
                                if ev(wid, "document.title") == url.rsplit("/", 1)[1]:
                                    return wid
                            except Exception:  # noqa: BLE001 - still loading
                                pass
                        time.sleep(0.1)
                    raise TimeoutError(f"popup {url} never loaded: {pages()}")

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
                solo = open_popup(f"{other}/solo", "noopener")
                ev(solo, "(window.__state = 'solo state', 1)")
                solo_process = set(web_processes(proc.pid)) - shared
                check(len(solo_process) == 1, f"popups: the noopener popup ({solo}) has a web process of its own ({solo_process})")

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

                marks = crashed_after_kill(shared, {"window-1", sibling})
                check(marks == {"window-1": "crashed", sibling: "crashed", solo: "crashed"},
                      f"popups: killing the shared process marks windows 1 and {sibling} too (got {marks})")
                logged = sorted(line.strip() for line in stderr_lines if "web process terminated" in line)
                sib_n = sibling.split("-")[1]
                want = sorted(f"zigBrowser: window {n}: web process terminated (crashed)" for n in ("1", sib_n, solo_n))
                check(logged == want, f"popups: stderr names each window once, by its own id (got {logged})")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            check(False, f"popups: error={exc!r}")
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-30:]))
        finally:
            stop_browser(proc)
            server.shutdown()
            server.server_close()


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
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            xsession_prefix(True) + [str(browser.resolve()), page.as_uri(), "--automation-api",
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
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                zb.dom.wait_for("css=#alive", state="attached", timeout_ms=15000)
                check("crashed" not in window_one(zb), "a live window reports no termination")

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
                time.sleep(0.3)
                logged = [line for line in stderr_lines if "web process terminated" in line]
                check(any("window 1" in line and "crashed" in line for line in logged),
                      f"stderr names the window and the reason (got {logged})")

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

    if failures:
        print("FAIL\tweb-process-crash")
        return 1
    print("PASS\tweb-process-crash")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
