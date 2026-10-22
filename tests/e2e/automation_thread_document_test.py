#!/usr/bin/env python3
"""S8a red (chat-drawer plan decision 13, a thread that opens as a new page): an approved
instagram.dm whose Message click loads the thread as its own document continues there, and only
on the platform's thread path. Real binary, Python SDK, the site-modelled Instagram fixture
(never a live site).

- crossdoc.user: Message loads /direct/t/77/ (a new document whose dialog header links the
  approved user): the flow captures that document and types and sends there, once.
- crossdocwrong.user: Message loads /mallory/ instead: -32015 thread_url_changed, and nothing
  is typed or sent on either page.

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


def scenario(zb: ZigBrowser, origin: str) -> list[str]:
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

    code, data = dm("crossdoc.user")
    check(code is None, f"crossdoc.user: the flow succeeds ({code}, {data})")
    check(ev("location.pathname") == "/direct/t/77/", f"crossdoc.user: it ended on the thread page ({ev('location.pathname')!r})")
    check(ev("window.__ig ? window.__ig.result : null") == {"action": "dm", "text": TEXT},
          f"crossdoc.user: sent once on the thread page ({ev('window.__ig ? window.__ig.result : null')})")

    code, data = dm("crossdocwrong.user")
    check((code, data.get("reason")) == (-32015, "thread_url_changed"), f"crossdocwrong.user: -32015 thread_url_changed ({code}, {data})")
    check(ev("location.pathname") == "/mallory/", f"crossdocwrong.user: the window shows the other profile ({ev('location.pathname')!r})")
    check(ev("window.__ig ? window.__ig.result : null") is None, "crossdocwrong.user: nothing sent")
    typed = ev("(document.querySelector('[contenteditable]') || {textContent: ''}).textContent")
    check(typed == "", f"crossdocwrong.user: nothing typed ({typed!r})")

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
                passed = scenario(zb, server.origin)
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
