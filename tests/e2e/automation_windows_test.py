#!/usr/bin/env python3
"""N23 E2E: window targeting through the real binary and socket.

A page opens a login popup (window.open). The test finds it with page.list
(not the primary, opener = the primary), fills and submits its form with
dom.fill / dom.click carrying window_id, and the opener receives the popup's
postMessage. Reads with window_id see only the popup; the primary is not
touched. page.close closes the popup (the primary cannot be closed:
-32602 primary_window); afterwards the same targeted call is -32011
no_window and page.list no longer lists it.

Both ways a popup goes away leave the opener intact (same document: its
DOM state and URL are unchanged, and it keeps answering): (a) page.close
from the client, (b) the popup's own window.close() after it posted its
result, the usual OAuth ending. Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_api_lifecycle_test import _read_lines, call_rpc, expect_equal, terminate
from automation_input_test import rpc_error
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file


def run(socket_path: Path, t: float) -> None:
    ids = iter(range(2000, 2200))

    def rpc(method: str, params: dict):
        return call_rpc(socket_path, method, params, next(ids), t)

    def js(expression: str, **target):
        return rpc("page.evaluate", dict({"expression": expression}, **target))["result"]

    def wait_received():
        deadline = time.monotonic() + t
        received = None
        while time.monotonic() < deadline:
            received = js("window.received")
            if received is not None:
                break
            time.sleep(0.05)
        return received

    primary = rpc("page.list", {})["pages"]
    expect_equal("one window at start", len(primary), 1)
    opener_url = rpc("page.url", {})["url"]
    if not opener_url.endswith("/opener.html"):
        raise AssertionError(f"unexpected opener url {opener_url!r}")
    primary_id = primary[0]["window_id"]
    expect_equal("the primary", primary[0]["primary"], True)

    js("openLogin()")
    deadline = time.monotonic() + t
    pages = []
    while time.monotonic() < deadline:
        pages = rpc("page.list", {})["pages"]
        if len(pages) == 2:
            break
        time.sleep(0.05)
    expect_equal("the popup is listed", len(pages), 2)
    expect_equal("primary listed first", pages[0]["window_id"], primary_id)
    popup = pages[1]
    popup_id = popup["window_id"]
    expect_equal("popup is not primary", popup["primary"], False)
    expect_equal("popup opener", popup.get("opener_window_id"), primary_id)

    target = {"window_id": popup_id}
    expect_equal("targeted title", rpc("page.title", target)["title"], "Login")
    expect_equal("untargeted title is still the opener", rpc("page.title", {})["title"], "Opener")
    expect_equal("fill user", rpc("dom.fill", dict({"selector": "css=#user", "value": "alice"}, **target)), {"ok": True})
    expect_equal("fill pass", rpc("dom.fill", dict({"selector": "css=#pass", "value": "secret"}, **target)), {"ok": True})
    expect_equal("submit", rpc("dom.click", dict({"selector": "css=#submit"}, **target)), {"ok": True})
    expect_equal("popup state", rpc("dom.getText", dict({"selector": "css=#state"}, **target))["text"], "sent")

    expect_equal("the opener got the popup's postMessage", wait_received(), {"user": "alice", "ok": True})
    expect_equal("opener status", rpc("dom.getText", {"selector": "css=#status"})["text"], "got:user=alice")
    # The opener has no login form: targeted calls never fell through to it.
    error = rpc_error(socket_path, "dom.getText", {"selector": "css=#user", "strict": True, "options": {"timeout_ms": 500}}, next(ids), t)
    if error.get("code") not in (-32001, -32009):
        raise AssertionError(f"the opener unexpectedly has #user: {error}")

    # The primary cannot be closed; the popup can.
    error = rpc_error(socket_path, "page.close", {"window_id": primary_id}, next(ids), t)
    expect_equal("primary close code", error["code"], -32602)
    expect_equal("primary close reason", error.get("data", {}).get("reason"), "primary_window")
    expect_equal("close the popup", rpc("page.close", {"window_id": popup_id}), {"ok": True})
    expect_equal("popup gone from the list", [p["window_id"] for p in rpc("page.list", {})["pages"]], [primary_id])
    error = rpc_error(socket_path, "dom.getText", dict({"selector": "css=#state"}, **target), next(ids), t)
    expect_equal("targeted call after close", error["code"], -32011)
    expect_equal("targeted call after close reason", error.get("data", {}).get("reason"), "no_window")

    # (a) The opener survived page.close of its popup: same URL, same state.
    expect_equal("opener url after page.close", rpc("page.url", {})["url"], opener_url)
    expect_equal("opener state after page.close", rpc("dom.getText", {"selector": "css=#status"})["text"], "got:user=alice")
    expect_equal("opener still answers", js("window.received"), {"user": "alice", "ok": True})

    # (b) A popup that closes itself after posting its result. The opener is
    # reset to a sentinel first, so only this popup's message can satisfy it.
    js("(window.received = null, document.getElementById('status').textContent = 'waiting', 0)")
    js("openLogin(true)")
    deadline = time.monotonic() + t
    while time.monotonic() < deadline and len(rpc("page.list", {})["pages"]) != 2:
        time.sleep(0.05)
    pages = rpc("page.list", {})["pages"]
    expect_equal("second popup listed", len(pages), 2)
    second = {"window_id": pages[1]["window_id"]}
    rpc("dom.fill", dict({"selector": "css=#user", "value": "alice"}, **second))
    rpc("dom.fill", dict({"selector": "css=#pass", "value": "secret"}, **second))
    rpc("dom.click", dict({"selector": "css=#submit"}, **second))
    expect_equal("the opener got the self-closing popup's message", wait_received(), {"user": "alice", "ok": True})
    deadline = time.monotonic() + t
    while time.monotonic() < deadline and len(rpc("page.list", {})["pages"]) != 1:
        time.sleep(0.05)
    expect_equal("the popup closed itself", [p["window_id"] for p in rpc("page.list", {})["pages"]], [primary_id])
    error = rpc_error(socket_path, "page.title", second, next(ids), t)
    expect_equal("targeted call after the popup closed itself", (error["code"], error.get("data", {}).get("reason")), (-32011, "no_window"))
    expect_equal("opener state after the popup closed itself", rpc("dom.getText", {"selector": "css=#status"})["text"], "got:user=alice")
    expect_equal("opener url after the popup closed itself", rpc("page.url", {})["url"], opener_url)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--fixture", default="tests/fixtures/automation/popup/opener.html")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    fixture = Path(args.fixture)
    if not require_file(browser, "binary") or not require_file(fixture, "fixture"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with tempfile.TemporaryDirectory(prefix="zb-windows-e2e-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), fixture.resolve().as_uri(), "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stderr_lines: list[str] = []
        threading.Thread(target=_read_lines, args=(proc.stdout, []), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True).start()
        try:
            run(socket_path, args.timeout_sec)
        except Exception as exc:  # noqa: BLE001
            print("FAIL\twindows")
            eprint(f"error={exc!r}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1
        terminate(proc)

    print("PASS\tpopup login through window_id; page.list / page.close; the opener survives both close paths")
    print("PASS\twindows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
