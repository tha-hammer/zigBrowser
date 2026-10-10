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
import time
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, expect_equal, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file


def evaluate(socket_path: Path, expression: str, req_id: int, timeout: float):
    return call_rpc(socket_path, "page.evaluate", {"expression": expression}, req_id, timeout)["result"]


def text_of(socket_path: Path, selector: str, req_id: int, timeout: float) -> str:
    return call_rpc(socket_path, "dom.getText", {"selector": selector}, req_id, timeout)["text"]


def run_contenteditable(socket_path: Path, t: float) -> None:
    ok = {"ok": True}
    expect_equal("type into plain", call_rpc(socket_path, "dom.type", {"selector": "css=#plain", "text": "Hello"}, 10, t), ok)
    expect_equal("plain text after type", text_of(socket_path, "css=#plain", 11, t), "Hello")
    if not evaluate(socket_path, "window.plainInputs", 12, t) >= 5:
        raise AssertionError("plain contenteditable did not receive one input event per character")
    expect_equal("type appends to plain", call_rpc(socket_path, "dom.type", {"selector": "css=#plain", "text": " there"}, 13, t), ok)
    expect_equal("plain text after second type", text_of(socket_path, "css=#plain", 14, t), "Hello there")
    expect_equal("fill plain", call_rpc(socket_path, "dom.fill", {"selector": "css=#plain", "value": "Replaced"}, 15, t), ok)
    expect_equal("plain text after fill", text_of(socket_path, "css=#plain", 16, t), "Replaced")

    expect_equal("type into draft", call_rpc(socket_path, "dom.type", {"selector": "css=#draft", "text": "Hi X"}, 20, t), ok)
    expect_equal("draft model after type", evaluate(socket_path, "window.draftModel", 21, t), "Hi X")
    expect_equal("draft text after type", text_of(socket_path, "css=#draft", 22, t), "Hi X")
    expect_equal("fill draft", call_rpc(socket_path, "dom.fill", {"selector": "css=#draft", "value": "New post"}, 23, t), ok)
    expect_equal("draft model after fill", evaluate(socket_path, "window.draftModel", 24, t), "New post")
    expect_equal("draft text after fill", text_of(socket_path, "css=#draft", 25, t), "New post")


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
        except Exception as exc:
            print(f"FAIL\t{scenario}")
            eprint(f"error={exc}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1
        finally:
            time.sleep(0)

        terminate(proc)

    print("PASS\tautomation-input")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
