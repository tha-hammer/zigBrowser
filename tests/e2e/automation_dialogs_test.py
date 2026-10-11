#!/usr/bin/env python3
"""Page dialogs E2E: alert, confirm, prompt and the beforeunload "Leave site?"
prompt, in the primary window and in a popup, through the real binary, the
socket and the Python SDK.

A dialog is never answered by default: it stays open for a human (a native
GTK dialog) until dialog.respond answers it. dialog.get reports it with its
window. page.navigate {onBeforeUnload}: "fail" (default) returns -32013
dialog_open within about a second and leaves the prompt open; "accept"
leaves the page; "dismiss" stays (-32008 beforeunload_dismissed).

Every browser runs on its own Xvfb display, never the user's. Exit 77
(skip) without the binary or xvfb-run."""

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

from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file  # noqa: E402
from zigbrowser import AutomationError, ZigBrowser  # noqa: E402
from zigbrowser.errors import ProtocolError  # noqa: E402

FIXTURES = REPO / "tests/fixtures/automation/dialogs"
# "fail" must answer well before the 30 s navigation deadline; the target is
# about 1 s, with headroom for a loaded host.
FAIL_FAST_SEC = 3.0


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
    print(f"ok   {label}", flush=True)


def wait_until(label: str, probe, timeout: float):
    deadline = time.monotonic() + timeout
    value = None
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"{label}: still {value!r} after {timeout}s")


def expect_error(label: str, call, code: int, reason: str | None) -> float:
    started = time.monotonic()
    try:
        call()
    except (AutomationError, ProtocolError) as exc:
        elapsed = time.monotonic() - started
        data = exc.diagnostics if isinstance(exc, AutomationError) else exc.data
        expect_equal(f"{label}: code", exc.code, code)
        expect_equal(f"{label}: reason", data.get("reason"), reason)
        return elapsed
    raise AssertionError(f"{label}: expected error {code}, got success")


def scenario(zb: ZigBrowser, t: float) -> None:
    index_url = (FIXTURES / "index.html").as_uri()
    next_url = (FIXTURES / "next.html").as_uri()

    def heading(**target) -> str:
        return zb.call("dom.getText", dict({"selector": "css=h1"}, **target))["text"]

    def title(**target) -> str:
        return zb.call("page.title", dict(target))["title"]

    def js(expression: str, **target):
        return zb.call("page.evaluate", dict({"expression": expression}, **target))

    def trigger(expression: str, **target) -> None:
        """Runs page code that opens a dialog. The page's script blocks as
        soon as it opens, so the command itself may end either way: with
        its result, or with dialog_open when the dialog won the race."""
        try:
            js(expression, **target)
        except AutomationError as exc:
            if exc.code != -32013:
                raise

    def open_dialog(**target):
        return wait_until("a dialog opens", lambda: (d := zb.dialog.get(**target)) and d.get("open") and d, t)

    expect_equal("start page", title(), "Dialogs")
    expect_equal("no dialog at start", zb.dialog.get(), {"open": False})
    expect_error("respond with no dialog", lambda: zb.dialog.respond(accept=True), -32602, "no_dialog")

    # --- primary window: alert, confirm, prompt ---
    trigger("showAlert('hello alert')")
    expect_equal("alert reported", open_dialog(), {"open": True, "type": "alert", "message": "hello alert", "window_id": "window-1"})
    # Nothing answers it by default: still open a moment later.
    time.sleep(0.5)
    expect_equal("alert stays open", zb.dialog.get()["open"], True)
    expect_equal("answer the alert", zb.dialog.respond(accept=True), {"ok": True})
    wait_until("the page resumes after the alert", lambda: title() == "alerted", t)
    expect_equal("alert closed", zb.dialog.get(), {"open": False})

    trigger("askConfirm('Discard changes?')")
    expect_equal("confirm reported", open_dialog(), {"open": True, "type": "confirm", "message": "Discard changes?", "window_id": "window-1"})
    zb.dialog.respond(accept=False)
    wait_until("confirm dismissed -> false", lambda: title() == "confirm:false", t)
    trigger("askConfirm('Discard changes?')")
    open_dialog()
    zb.dialog.respond(accept=True, window_id="window-1")
    wait_until("confirm accepted -> true", lambda: title() == "confirm:true", t)

    trigger("askPrompt('Your name?', 'ada')")
    expect_equal("prompt reported", open_dialog(), {"open": True, "type": "prompt", "message": "Your name?", "default_text": "ada", "window_id": "window-1"})
    zb.dialog.respond(accept=True, text="grace")
    wait_until("prompt answered with text", lambda: title() == "prompt:grace", t)
    trigger("askPrompt('Your name?', 'ada')")
    open_dialog()
    zb.dialog.respond(accept=False)
    wait_until("prompt dismissed -> null", lambda: title() == "prompt:null", t)

    # --- beforeunload ---
    expect_error("unknown onBeforeUnload", lambda: zb.page.navigate(next_url, on_before_unload="maybe"), -32602, None)
    elapsed = expect_error("navigate (default fail) on a guarded page", lambda: zb.page.navigate(next_url, timeout_ms=20000), -32013, None)
    if elapsed > FAIL_FAST_SEC:
        raise AssertionError(f"dialog_open took {elapsed:.2f}s (want about 1s)")
    print(f"ok   dialog_open after {elapsed:.2f}s", flush=True)
    leave = open_dialog()
    expect_equal("beforeunload reported", (leave["type"], leave["window_id"]), ("beforeunload", "window-1"))
    time.sleep(0.5)
    expect_equal("the prompt stays open for the human", zb.dialog.get()["open"], True)
    expect_error("navigate while a dialog is open", lambda: zb.page.navigate(next_url, on_before_unload="accept", timeout_ms=20000), -32013, None)
    zb.dialog.respond(accept=False)  # stay
    wait_until("prompt closed", lambda: zb.dialog.get() == {"open": False}, t)
    expect_equal("stayed on the page", heading(), "Dialogs")

    expect_error("navigate dismiss", lambda: zb.page.navigate(next_url, on_before_unload="dismiss", timeout_ms=20000), -32008, "beforeunload_dismissed")
    expect_equal("dismiss leaves no dialog", zb.dialog.get(), {"open": False})
    expect_equal("still on the page after dismiss", heading(), "Dialogs")

    expect_equal("navigate accept", zb.page.navigate(next_url, on_before_unload="accept", timeout_ms=20000), {"ok": True})
    expect_equal("left the page", title(), "Next")
    expect_equal("no dialog after accept", zb.dialog.get(), {"open": False})

    # --- popup ---
    expect_equal("back to the dialogs page", zb.page.navigate(index_url, timeout_ms=20000), {"ok": True})
    js("openPopup()")
    pages = wait_until("popup listed", lambda: (p := zb.page.list()["pages"]) and len(p) == 2 and p, t)
    popup = pages[1]["window_id"]
    wait_until("popup loaded", lambda: title(window_id=popup) == "Popup", t)

    trigger("askConfirm('Popup question?')", window_id=popup)
    got = open_dialog()
    expect_equal("popup confirm reported with its window", got, {"open": True, "type": "confirm", "message": "Popup question?", "window_id": popup})
    expect_equal("targeted get on the popup", zb.dialog.get(window_id=popup), got)
    expect_equal("the primary has no dialog", zb.dialog.get(window_id="window-1"), {"open": False})
    zb.dialog.respond(accept=True, window_id=popup)
    wait_until("popup confirm -> true", lambda: title(window_id=popup) == "popup-confirm:true", t)

    elapsed = expect_error("popup navigate (fail)", lambda: zb.call("page.navigate", {"url": next_url, "timeout_ms": 20000, "window_id": popup}), -32013, None)
    if elapsed > FAIL_FAST_SEC:
        raise AssertionError(f"popup dialog_open took {elapsed:.2f}s")
    expect_equal("popup beforeunload window", open_dialog(window_id=popup)["type"], "beforeunload")
    zb.dialog.respond(accept=True, window_id=popup)  # leave
    wait_until("popup left after accepting", lambda: title(window_id=popup) == "Next", t)

    # A popup closed while its alert is open: the dialog goes with it.
    expect_equal("popup back", zb.call("page.navigate", {"url": (FIXTURES / "popup.html").as_uri(), "timeout_ms": 20000, "window_id": popup}), {"ok": True})
    trigger("showAlert('closing soon')", window_id=popup)
    expect_equal("popup alert", open_dialog()["window_id"], popup)
    expect_equal("close the popup", zb.page.close(popup), {"ok": True})
    expect_equal("its dialog went with it", zb.dialog.get(), {"open": False})
    expect_error("get on the closed popup", lambda: zb.dialog.get(window_id=popup), -32011, "no_window")
    expect_equal("primary still answers", title(), "Dialogs")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    xvfb = shutil.which("xvfb-run")
    if xvfb is None:
        eprint("SKIP: needs xvfb-run (the browser must run on its own display)")
        return SKIP_EXIT

    env = isolate_profile_env(dict(os.environ))
    for name in ("DISPLAY", "WAYLAND_DISPLAY", "ZIGBROWSER_SOCKET"):
        env.pop(name, None)
    with tempfile.TemporaryDirectory(prefix="zb-dialogs-e2e-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            [xvfb, "-a", "-s", "-screen 0 1280x1024x24", str(browser.resolve()), (FIXTURES / "index.html").as_uri(),
             "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True,
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
                scenario(zb, args.timeout_sec)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tdialogs")
            eprint(f"error={exc!r}")
            time.sleep(0.5)
            eprint("browser stderr (last 30 lines):\n" + "".join(stderr_lines[-80:]))
            return 1
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGINT)
                try:
                    proc.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    pass
            # Whatever of the group outlived xvfb-run (browser, Xvfb).
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
    print("PASS\tdialogs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
