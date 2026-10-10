#!/usr/bin/env python3
"""E2E: input verbs against the live WebKitGTK page over the automation socket.

N1: dom.type / dom.fill on contenteditable elements, both a plain one and a
Draft.js-like editor that cancels beforeinput and applies text to its own
model (the shape of X's post box)."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
import threading
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, expect_equal, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file


def evaluate(socket_path: Path, expression: str, req_id: int, timeout: float):
    return call_rpc(socket_path, "page.evaluate", {"expression": expression}, req_id, timeout)["result"]


def text_of(socket_path: Path, selector: str, req_id: int, timeout: float) -> str:
    return call_rpc(socket_path, "dom.getText", {"selector": selector}, req_id, timeout)["text"]


def run_contenteditable(socket_path: Path, t: float) -> None:
    ok = {"ok": True}
    ids = iter(range(10, 100))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def plain_inputs() -> int:
        return evaluate(socket_path, "window.plainInputs", next(ids), t)

    # Plain editor: exactly one input event per typed character and one per
    # fill, so a duplicated native + synthetic input fails the test.
    expect_equal("type into plain", rpc("dom.type", {"selector": "css=#plain", "text": "Hello"}), ok)
    expect_equal("plain text after type", text_of(socket_path, "css=#plain", next(ids), t), "Hello")
    expect_equal("input events after type", plain_inputs(), 5)
    expect_equal("type appends to plain", rpc("dom.type", {"selector": "css=#plain", "text": " there"}), ok)
    expect_equal("plain text after second type", text_of(socket_path, "css=#plain", next(ids), t), "Hello there")
    expect_equal("input events after second type", plain_inputs(), 11)
    expect_equal("fill plain", rpc("dom.fill", {"selector": "css=#plain", "value": "Replaced"}), ok)
    expect_equal("plain text after fill", text_of(socket_path, "css=#plain", next(ids), t), "Replaced")
    expect_equal("input events after fill", plain_inputs(), 12)
    expect_equal("empty fill plain", rpc("dom.fill", {"selector": "css=#plain", "value": ""}), ok)
    expect_equal("plain text after empty fill", evaluate(socket_path, "document.getElementById('plain').textContent", next(ids), t), "")
    expect_equal("input events after empty fill", plain_inputs(), 13)

    # Draft.js-like editor: it cancels beforeinput and owns the edit.
    expect_equal("type into draft", rpc("dom.type", {"selector": "css=#draft", "text": "Hi X"}), ok)
    expect_equal("draft model after type", evaluate(socket_path, "window.draftModel", next(ids), t), "Hi X")
    expect_equal("draft text after type", text_of(socket_path, "css=#draft", next(ids), t), "Hi X")
    expect_equal("draft beforeinputs after type", evaluate(socket_path, "window.draftBeforeInputs", next(ids), t), 4)
    expect_equal("fill draft", rpc("dom.fill", {"selector": "css=#draft", "value": "New post"}), ok)
    expect_equal("draft model after fill", evaluate(socket_path, "window.draftModel", next(ids), t), "New post")
    expect_equal("draft text after fill", text_of(socket_path, "css=#draft", next(ids), t), "New post")
    expect_equal("empty fill draft", rpc("dom.fill", {"selector": "css=#draft", "value": ""}), ok)
    expect_equal("draft model after empty fill", evaluate(socket_path, "window.draftModel", next(ids), t), "")
    expect_equal("draft DOM after empty fill", evaluate(socket_path, "document.getElementById('draft').textContent", next(ids), t), "")


def run_press(socket_path: Path, t: float) -> None:
    ok = {"ok": True}
    ids = iter(range(200, 300))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def last_key() -> dict:
        return evaluate(socket_path, "window.keylog[window.keylog.length - 1]", next(ids), t)

    # Enter in a form input submits the form.
    expect_equal("press Enter", rpc("dom.press", {"selector": "css=#q", "key": "Enter"}), ok)
    expect_equal("Enter submitted the form", evaluate(socket_path, "window.submits", next(ids), t), 1)
    entry = last_key()
    expect_equal("Enter keydown fields", {k: entry[k] for k in ("key", "code", "keyCode", "target")},
                 {"key": "Enter", "code": "Enter", "keyCode": 13, "target": "q"})

    # Tab moves focus to the next tabbable element; Shift+Tab moves it back.
    expect_equal("press Tab", rpc("dom.press", {"selector": "css=#q", "key": "Tab"}), ok)
    expect_equal("focus after Tab", evaluate(socket_path, "document.activeElement.id", next(ids), t), "q2")
    expect_equal("press Shift+Tab", rpc("dom.press", {"key": "Tab", "modifiers": ["Shift"]}), ok)
    expect_equal("focus after Shift+Tab", evaluate(socket_path, "document.activeElement.id", next(ids), t), "q")

    # Without a selector the key goes to the focused element.
    expect_equal("press Escape", rpc("dom.press", {"key": "Escape"}), ok)
    entry = last_key()
    expect_equal("Escape keydown fields", {k: entry[k] for k in ("key", "code", "keyCode", "target")},
                 {"key": "Escape", "code": "Escape", "keyCode": 27, "target": "q"})

    # Modifier flags and the character code mapping.
    expect_equal("press Control+a", rpc("dom.press", {"selector": "css=#q2", "key": "a", "modifiers": ["Control"]}), ok)
    entry = last_key()
    expect_equal("Control+a keydown fields", {k: entry[k] for k in ("key", "code", "keyCode", "ctrl", "shift", "target")},
                 {"key": "a", "code": "KeyA", "keyCode": 65, "ctrl": True, "shift": False, "target": "q2"})
    expect_equal("Control+a inserted nothing", evaluate(socket_path, "document.getElementById('q2').value", next(ids), t), "")

    # A printable key on an input types its character.
    expect_equal("press x", rpc("dom.press", {"selector": "css=#q2", "key": "x"}), ok)
    expect_equal("x typed into q2", evaluate(socket_path, "document.getElementById('q2').value", next(ids), t), "x")
    if evaluate(socket_path, "window.keyupCount", next(ids), t) < 6:
        raise AssertionError("each press must end with keyup")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--fixture", default="tests/fixtures/automation/input.html")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    fixture = Path(args.fixture)
    if not require_file(browser, "binary") or not require_file(fixture, "input fixture"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with tempfile.TemporaryDirectory(prefix="zb-automation-input-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), fixture.resolve().as_uri(), "--automation-api"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        for stream, sink in ((proc.stdout, stdout_lines), (proc.stderr, stderr_lines)):
            threading.Thread(target=_read_lines, args=(stream, sink), daemon=True).start()

        scenario = "contenteditable"
        try:
            run_contenteditable(socket_path, args.timeout_sec)
            print("PASS\tcontenteditable type/fill")
            scenario = "press"
            run_press(socket_path, args.timeout_sec)
            print("PASS\tdom.press")
        except Exception as exc:
            print(f"FAIL\t{scenario}")
            eprint(f"error={exc}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1

        terminate(proc)

    print("PASS\tautomation-input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
