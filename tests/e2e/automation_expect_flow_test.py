#!/usr/bin/env python3
"""S8a (chat-drawer plan, "S8 in detail" decision 2): an approved flow's phases on the REAL
binary, through the Python SDK, on the site-modelled LinkedIn fixture (never a live site).

- An approval matching the window (its origin and load_serial from page.list, and the post URL
  the flow opens) runs linkedin.like once: the fixture records the like. Phase C reads
  automation.js's per-document token in the isolated world, so this also proves that op in
  WebKit (an unreadable token would be -32015 document_token_unreadable).
- An approval with a stale load_serial is -32015 load_serial_changed, and the flow requests
  nothing from the site.
- An approval for another post is -32015 unapproved_navigation, and nothing is requested.

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


def window_one(zb: ZigBrowser) -> dict:
    return next(p for p in zb.page.list()["pages"] if p["window_id"] == "window-1")


def scenario(zb: ZigBrowser, origin: str, server: social.FixtureServer) -> list[str]:
    passed: list[str] = []
    li = lambda: zb.page.evaluate("window.__li.result")["result"]  # noqa: E731
    zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)
    zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
    post = f"{origin}/feed/update/urn:li:activity:1/"

    def approved_like(serial: int, url: str = post):
        return zb.call("linkedin.like", {
            "postUrl": post,
            "window_id": "window-1",
            "options": {"expect": {"origin": origin, "load_serial": serial, "url": url}},
        })

    # The start page's first load has committed (page.list is answered before it).
    deadline = time.monotonic() + 15
    while window_one(zb)["load_serial"] < 1 and time.monotonic() < deadline:
        time.sleep(0.05)
    serial = window_one(zb)["load_serial"]
    if not isinstance(serial, int) or serial < 1:
        raise AssertionError(f"window-1 load_serial {serial!r}")
    social.expect_equal("approved like", approved_like(serial), {"ok": True})
    social.expect_equal("approved like recorded", li(), {"action": "like"})
    passed.append("approved-flow-acts")

    requests = len(server.paths)
    stale = window_one(zb)["load_serial"] - 1
    social.expect_error("stale serial", lambda: approved_like(stale), -32015, "load_serial_changed")
    social.expect_equal("stale serial: nothing requested", len(server.paths), requests)
    passed.append("stale-serial-refused")

    social.expect_error("another post", lambda: approved_like(window_one(zb)["load_serial"], f"{origin}/feed/update/urn:li:activity:2/"),
                        -32015, "unapproved_navigation")
    social.expect_equal("another post: nothing requested", len(server.paths), requests)
    passed.append("unapproved-navigation-refused")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (social.LINKEDIN, "linkedin fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with social.FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-expect-flow-") as tmp:
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
            print("FAIL\texpect-flow")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\texpect-flow")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
