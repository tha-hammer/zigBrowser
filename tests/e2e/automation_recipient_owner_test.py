#!/usr/bin/env python3
"""S8a red (RoseCat 8b05366 on fe89046, plan decision 13 stage 1): the opener of an approved
profile-target message or DM is bound to the profile's OWNER, from the approval, inside its own
automation.js task. A page at the unchanged approved path that shows someone else is refused.
Real binary, Python SDK, the site-modelled fixtures (never a live site).

- instagram.dm owner.user: the header names the approved user: sent once.
- instagram.dm wrongowner.user: the header names mallory at the unchanged /wrongowner.user/
  path (no pushState): -32015 mark_changed at click_message_button, {events 0, chars 0}, the
  composer never opens, nothing typed or sent.
- LinkedIn's profile Message click is never sent by the server (unverified live), so its owner
  mark is proven on the fixture by the same guard the flow builds
  (tests/automation_recipient_owner_test.zig pins it): a dom.click on the owner's Message with
  {path, the contact-info mark for the approved slug, target} passes on /in/carol/ and is
  -32015 mark_changed, {0, 0}, with no click on /in/wrongowner/.

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
from automation_recipient_guard_test import TEXT, attempt, contract, serial, window_one  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

# The flow's LinkedIn owner mark (src/linkedin.zig; pinned by the Zig red).
LI_OWNER = 'xpath=//main//section[@aria-label="Primary content"]//a[contains(@href,"/overlay/contact-info/")]'


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

    for user, refused in (("owner.user", None), ("wrongowner.user", (-32015, "mark_changed", "click_message_button", {"events": 0, "chars": 0}))):
        url = f"{origin}/{user}/"
        code, data = attempt(zb, "instagram.dm", {
            "username": user, "text": TEXT, "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial(zb), "url": url}},
        })
        result = ev("window.__ig ? window.__ig.result : null")
        if refused is None:
            check(code is None and result == {"action": "dm", "text": TEXT}, f"instagram {user}: sent once ({code}, {data}, {result})")
            continue
        check(contract(code, data) == refused, f"instagram {user}: {refused} ({code}, {data})")
        typed = ev("(document.querySelector('#dm [contenteditable]') || {textContent: ''}).textContent")
        check(result is None and typed == "", f"instagram {user}: nothing typed or sent ({result!r}, {typed!r})")
        check(ev("document.getElementById('dm').hidden") is True, f"instagram {user}: the Message click never happened")

    for slug, ok in (("carol", True), ("wrongowner", False)):
        zb.page.navigate(f"{origin}/in/{slug}/")
        # The owner's actions render late, as live.
        deadline = time.monotonic() + 10
        while not ev("!!document.getElementById('message')") and time.monotonic() < deadline:
            time.sleep(0.1)
        guard = {"path": f"/in/{slug}/", "target": True,
                 "marks": [{"selector": LI_OWNER, "attribute": "href", "path": True, "value": f"/in/{slug}/overlay/contact-info/"}]}
        code, data = attempt(zb, "dom.click", {"selector": "css=#message", "options": {"guard": guard}})
        clicked = "click:message" in (ev("window.__li.events") or [])
        if ok:
            check(code is None and clicked, f"linkedin /in/{slug}/: the owner's Message is clicked ({code}, {data})")
        else:
            check((code, data.get("reason"), data.get("sent")) == (-32015, "mark_changed", {"events": 0, "chars": 0}) and not clicked,
                  f"linkedin /in/{slug}/: -32015 mark_changed, nothing sent, no click ({code}, {data}, clicked={clicked})")

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

    with social.FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-recipient-owner-") as tmp:
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
            print("FAIL\trecipient-owner")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    print(f"PASS\trecipient-owner ({len(passed)} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
