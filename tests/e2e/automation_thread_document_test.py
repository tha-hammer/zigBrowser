#!/usr/bin/env python3
"""S8a red (chat-drawer plan decision 13, a thread that opens as a new page): an approved
instagram.dm whose Message click loads the thread as its own document continues there, and only
on the platform's thread path. Real binary, Python SDK, the site-modelled Instagram fixture
(never a live site).

- crossdoc.user: Message loads /direct/t/77/ (a new document whose dialog header links the
  approved user): the flow captures that document and types and sends there, once.
- crossdocwrong.user: Message loads /mallory/ instead: -32015 thread_url_changed, and nothing
  is typed or sent on either page.
- crossdocmallory.user: Message loads a real thread page (/direct/t/78/) whose header names
  someone else: the thread path passes, the recipient mark refuses the first thread step
  (-32015 mark_changed at click_dm_input, {0, 0}), nothing focused, typed or sent.
- What is sent is counted outside the pages (the fixture's /__record/<what>/<path> requests to
  the server, which survive the navigation): exactly one send for crossdoc.user, and no focus,
  keydown or send after the opener in the refused cases (RoseCat 7504 #3, #4).
- guard.document itself: a dom.click whose guard names another document is -32015
  document_changed before its first event ({events 0, chars 0}).

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
from automation_recipient_guard_test import TEXT, attempt, serial, window_one  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402


def records(server, since: int) -> list[str]:
    """The fixture's /__record/<what>/<page path> requests since `since` (an index into paths)."""
    time.sleep(0.5)  # a keepalive fetch fired just before the flow answered still lands
    return [p for p in server.paths[since:] if p.startswith("/__record/")]


def scenario(zb: ZigBrowser, origin: str, server) -> list[str]:
    failures: list[str] = []
    passed: list[str] = []

    def check(ok: bool, what: str) -> None:
        (passed if ok else failures).append(what)
        print(("ok   " if ok else "FAIL ") + what)

    zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)
    zb.cookies.set("sessionid", "fixture-session", domain="127.0.0.1")
    deadline = time.monotonic() + 15
    while window_one(zb)["load_serial"] < 1 and time.monotonic() < deadline:
        time.sleep(0.05)
    ev = lambda expr: zb.page.evaluate(expr)["result"]  # noqa: E731

    def dm(user: str):
        return attempt(zb, "instagram.dm", {
            "username": user, "text": TEXT, "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial(zb), "url": f"{origin}/{user}/"}},
        })

    since = len(server.paths)
    code, data = dm("crossdoc.user")
    check(code is None, f"crossdoc.user: the flow succeeds ({code}, {data})")
    check(ev("location.pathname") == "/direct/t/77/", f"crossdoc.user: it ended on the thread page ({ev('location.pathname')!r})")
    got = records(server, since)
    sent = [r for r in got if r.startswith("/__record/send/")]
    check(sent == ["/__record/send/direct/t/77/"], f"crossdoc.user: exactly one send, on the thread page ({sent})")
    # The exact text, typed once (RoseCat dddfbca #3): the box held it at Send, and the thread page
    # saw one keydown per character.
    result = ev("window.__ig ? window.__ig.result : null")
    check(result == {"action": "dm", "text": TEXT}, f"crossdoc.user: Send carried exactly the text ({result})")
    keys = [r for r in got if r == "/__record/keydown/direct/t/77/"]
    check(len(keys) == len(TEXT), f"crossdoc.user: typed once, one keydown per character ({len(keys)} for {len(TEXT)})")

    since = len(server.paths)
    code, data = dm("crossdocwrong.user")
    check((code, data.get("reason")) == (-32015, "thread_url_changed"), f"crossdocwrong.user: -32015 thread_url_changed ({code}, {data})")
    check(ev("location.pathname") == "/mallory/", f"crossdocwrong.user: the window shows the other profile ({ev('location.pathname')!r})")
    got = records(server, since)
    check(got == [], f"crossdocwrong.user: no focus, keydown or send after the opener ({got})")

    since = len(server.paths)
    code, data = dm("crossdocmallory.user")
    check((code, data.get("reason"), data.get("step"), data.get("sent")) == (-32015, "mark_changed", "click_dm_input", {"events": 0, "chars": 0}),
          f"crossdocmallory.user: the thread page names someone else: -32015 mark_changed at click_dm_input ({code}, {data})")
    check(ev("location.pathname") == "/direct/t/78/", f"crossdocmallory.user: on its thread page ({ev('location.pathname')!r})")
    got = records(server, since)
    check(got == [], f"crossdocmallory.user: no focus, keydown or send ({got})")

    code, data = attempt(zb, "dom.click", {"selector": "css=body", "options": {"guard": {"document": "not-this-document", "target": True}}})
    check((code, data.get("reason"), data.get("sent")) == (-32015, "document_changed", {"events": 0, "chars": 0}),
          f"guard.document naming another document: -32015 document_changed, nothing sent ({code}, {data})")

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
    for path, label in ((browser, "binary"), (social.INSTAGRAM, "instagram fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with social.FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-thread-doc-") as tmp:
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
                passed = scenario(zb, server.origin, server)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tthread-document")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    print(f"PASS\tthread-document ({len(passed)} checks)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
