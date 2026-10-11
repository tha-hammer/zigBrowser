#!/usr/bin/env python3
"""A window whose WebKit web process dies says so (no silent blank window).

On its own Xvfb display, the browser loads a page; the test then kills
that browser's WebKitWebProcess children (SIGKILL, so WebKit reports a
crash). page.list must then show "crashed": "crashed" for the window, and
stderr must name the window and the reason. Loading a page again starts a
new web process: the window works and the reason is gone.

Never uses the caller's DISPLAY. Exit 77 (skip) without the binary,
Xvfb or xauth."""

from __future__ import annotations

import argparse
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


def window_one(zb: ZigBrowser) -> dict:
    return next(p for p in zb.page.list()["pages"] if p["window_id"] == "window-1")


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

    if failures:
        print("FAIL\tweb-process-crash")
        return 1
    print("PASS\tweb-process-crash")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
