#!/usr/bin/env python3
"""S8a red (chat-drawer plan rev 16.20.52, "S8 in detail" decision 13): an approved message or
DM checks its recipient in two stages, inside each step's own automation.js task, on the REAL
binary through the Python SDK, on the site-modelled fixtures (never a live site).

Instagram (instagram.dm; the fixture picks the mode by username):
- pushstate.user: the Message button's pointerdown moves the page to another profile
  (pushState): -32015 and no click (the composer stays closed), nothing sent.
- wrongthread.user: the composer opens on someone else: -32015, nothing typed, no Send.
- keydownswap.user: the thread header changes on the first typed character's keydown: -32015,
  nothing typed, no Send.
- decoys.user: a hidden header copy, a link quoted in the thread and an inbox list name someone
  else, the header names the approved person: sent once.
- decoyswrong.user: the decoys name the approved person, the header someone else: nothing sent.
- twothreads.user: two open threads hold a message box: nothing sent.
- otherorigin.user: the header links the approved path on another origin: nothing sent.
(decoys.user's header link is absolute and same-origin; the others are relative.)

LinkedIn (linkedin.message with a conversationUrl, its approval naming the recipient carol; the
fixture picks the mode by thread id): wrong, keydown, decoys, decoyswrong, two and otherorigin,
as above, and ok (sent once).

Exit 77 (skip) without a binary/display, like social_flows_test.py."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import social_flows_test as social  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402
from zigbrowser.errors import ZigBrowserError  # noqa: E402

TEXT = "Hi there"


def window_one(zb: ZigBrowser) -> dict:
    return next(p for p in zb.page.list()["pages"] if p["window_id"] == "window-1")


def serial(zb: ZigBrowser) -> int:
    value = window_one(zb)["load_serial"]
    if not isinstance(value, int) or value < 1:
        raise AssertionError(f"window-1 load_serial {value!r}")
    return value


def attempt(zb: ZigBrowser, method: str, params: dict) -> tuple[int | None, dict]:
    try:
        zb.call(method, params)
    except ZigBrowserError as err:
        data = getattr(err, "diagnostics", None) or getattr(err, "data", None) or {}
        return getattr(err, "code", None), data
    return None, {}


def scenario(zb: ZigBrowser, origin: str) -> list[str]:
    failures: list[str] = []
    passed: list[str] = []

    def check(ok: bool, what: str) -> None:
        (passed if ok else failures).append(what)
        print(("ok   " if ok else "FAIL ") + what)

    zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)
    zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
    zb.cookies.set("sessionid", "fixture-session", domain="127.0.0.1")
    deadline = time.monotonic() + 15
    while window_one(zb)["load_serial"] < 1 and time.monotonic() < deadline:
        time.sleep(0.05)
    ev = lambda expr: zb.page.evaluate(expr)["result"]  # noqa: E731

    for user, sends in (("decoys.user", True), ("pushstate.user", False), ("wrongthread.user", False),
                        ("keydownswap.user", False), ("decoyswrong.user", False), ("twothreads.user", False),
                        ("otherorigin.user", False)):
        url = f"{origin}/{user}/"
        code, data = attempt(zb, "instagram.dm", {
            "username": user, "text": TEXT, "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial(zb), "url": url}},
        })
        result = ev("window.__ig ? window.__ig.result : null")
        typed = ev("(document.querySelector('#dm [contenteditable]') || {textContent: ''}).textContent")
        if sends:
            check(code is None and result == {"action": "dm", "text": TEXT}, f"instagram {user}: sent once ({code}, {data}, {result})")
        else:
            check(code == -32015, f"instagram {user}: -32015 ({code}, {data})")
            check(result is None and typed == "", f"instagram {user}: nothing typed or sent ({result!r}, {typed!r})")
        if user == "pushstate.user":
            check(ev("document.getElementById('dm').hidden") is True, "instagram pushstate.user: the Message click never happened")

    for thread, sends in (("ok", True), ("decoys", True), ("wrong", False), ("keydown", False), ("decoyswrong", False), ("two", False),
                          ("otherorigin", False)):
        url = f"{origin}/messaging/thread/{thread}/"
        code, data = attempt(zb, "linkedin.message", {
            "conversationUrl": url, "text": TEXT, "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial(zb), "url": url, "recipient": "carol"}},
        })
        # A request refused before its navigation leaves another fixture's page: no __li.
        sent = ev("window.__li ? window.__li.sent : null")
        if sends:
            check(code is None and sent == [TEXT], f"linkedin {thread}: sent once ({code}, {data}, {sent})")
        else:
            check(code == -32015, f"linkedin {thread}: -32015 ({code}, {data})")
            typed = ev("(document.querySelector('.msg-form__contenteditable') || {textContent: ''}).textContent")
            check(sent == [] and typed == "", f"linkedin {thread}: nothing typed or sent ({sent!r}, {typed!r})")

    if failures:
        raise AssertionError(f"{len(failures)} of {len(failures) + len(passed)} checks failed")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (social.LINKEDIN, "linkedin fixture"), (social.INSTAGRAM, "instagram fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with social.FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-recipient-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN"] = server.origin
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.origin}/feed/", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            social.wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                passed = scenario(zb, server.origin)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\trecipient-guard")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    print(f"PASS\trecipient-guard ({len(passed)} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
