#!/usr/bin/env python3
"""N16 E2E: linkedin.* and instagram.* against the REAL binary, driven only
through the Python SDK, on site-modelled fixtures (tests/fixtures/linkedin/,
tests/fixtures/instagram/) served from a local HTTP server - never the live
sites. The browser gets the fixture origin through the test-only
ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN; requests cannot choose it.

Asserts what the fixture pages recorded (window.__li / window.__ig), the
session-cookie gate before navigation (no request reaches the server), the
signed-in marker gate after navigation, platform URL refusal, the daily cap,
and that a failed command's trace holds the social compound span.
Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import http.server
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import AutomationError, ZigBrowser  # noqa: E402
from zigbrowser.errors import ZigBrowserError  # noqa: E402

LINKEDIN = REPO / "tests/fixtures/linkedin/index.html"
INSTAGRAM = REPO / "tests/fixtures/instagram/index.html"
LINKEDIN_PREFIXES = ("/in/", "/feed/", "/messaging/", "/search/", "/checkpoint/")
# N20: LinkedIn sends a challenged session to its checkpoint by redirect.
CHECKPOINT_REDIRECTS = {"/in/checkpoint-me/": "/checkpoint/challenge/ab12/", "/in/gone/": "/feed/"}
# Without active stories Instagram shows the profile instead of the viewer.
STORY_REDIRECTS = {"/stories/no.stories/": "/no.stories/"}


class FixtureServer:
    """Serves the LinkedIn fixture for LinkedIn-shaped paths and the
    Instagram fixture for everything else; logs every requested path."""

    def __init__(self) -> None:
        self.paths: list[str] = []
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802
                with outer._lock:
                    outer.paths.append(self.path)
                redirect = CHECKPOINT_REDIRECTS.get(self.path) or STORY_REDIRECTS.get(self.path)
                if redirect:
                    self.send_response(302)
                    self.send_header("Location", redirect)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                page = LINKEDIN if self.path.startswith(LINKEDIN_PREFIXES) else INSTAGRAM
                body = page.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self._server.server_address[1]}"

    def requested(self, fragment: str) -> bool:
        with self._lock:
            return any(fragment in p for p in self.paths)

    def __enter__(self) -> "FixtureServer":
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc) -> None:
        self._server.shutdown()
        self._server.server_close()


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def expect_error(label: str, call, code: int, reason: str | None = None):
    try:
        call()
    except AutomationError as err:
        expect_equal(f"{label} code", err.code, code)
        if reason is not None:
            expect_equal(f"{label} reason", (err.diagnostics or {}).get("reason"), reason)
        return err
    except ZigBrowserError as err:
        expect_equal(f"{label} code", getattr(err, "code", None), code)
        return err
    raise AssertionError(f"{label}: no error")


def wait_for_socket(path: Path, timeout_sec: float) -> None:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"socket {path} never appeared")


def scenario(zb: ZigBrowser, origin: str, server: FixtureServer) -> list[str]:
    passed: list[str] = []
    li = lambda: zb.page.evaluate("window.__li.result")["result"]  # noqa: E731
    ig = lambda: zb.page.evaluate("window.__ig.result")["result"]  # noqa: E731
    profile = f"{origin}/in/sam/"
    wrong_person = lambda: zb.page.evaluate("window.__li.wrongPerson")["result"]  # noqa: E731

    zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)

    # Session-cookie gate before navigation: no request reaches the site.
    expect_error("logged out (no li_at)", lambda: zb.linkedin.visit(profile), -32011, "logged_out")
    expect_error("logged out (no sessionid)", lambda: zb.instagram.story_view("sam.example"), -32011, "logged_out")
    if server.requested("/in/sam/") or server.requested("/stories/"):
        raise AssertionError(f"a gated flow reached the site: {server.paths}")
    passed.append("session-cookie-gate")

    zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
    zb.cookies.set("sessionid", "fixture-session", domain="127.0.0.1")

    # LinkedIn.
    expect_equal("visit", zb.linkedin.visit(profile), {"ok": True})
    expect_equal("visit page", zb.page.evaluate("window.__li.page")["result"], "profile:sam")
    # Until the profile owner's area is verified live
    # (linkedin.owner_actions_enabled in src/linkedin.zig), connect, follow and
    # message on a profile open and check the profile, then stop before any
    # click: a "People you may know" card must never be clicked.
    for label, call in (
        ("connect", lambda: zb.linkedin.connect(profile, note="Hi Sam, loved your notes on the engine.")),
        ("follow", lambda: zb.linkedin.follow(profile)),
        ("message from profile", lambda: zb.linkedin.message("Hello Sam", profile_url=profile)),
    ):
        expect_error(label, call, -32001, "linkedin_profile_owner_unverified")
        expect_equal(f"{label}: nothing done", (li(), wrong_person(), zb.page.evaluate("window.__li.events")["result"]), (None, [], []))
    # The page checks run first: redirected away from the profile.
    expect_error("not a profile", lambda: zb.linkedin.follow(f"{origin}/in/gone/"), -32001, "linkedin_not_a_profile")
    expect_equal("not a profile: on the feed, nothing done", (zb.page.evaluate("window.__li.page")["result"], li()), ("other", None))
    expect_equal("message in thread", zb.linkedin.message("Again, café ✓", conversation_url=f"{origin}/messaging/thread/7/"), {"ok": True})
    expect_equal("thread message recorded", li(), {"action": "message", "text": "Again, café ✓"})
    post = f"{origin}/feed/update/urn:li:activity:1/"
    expect_equal("like", zb.linkedin.like(post), {"ok": True})
    expect_equal("like recorded", li(), {"action": "like"})
    expect_equal("comment", zb.linkedin.comment(post, "Great post"), {"ok": True})
    expect_equal("comment recorded", li(), {"action": "comment", "text": "Great post"})
    search = zb.linkedin.search("zig dev & café", search_type="companies")
    expect_equal("search", search, {"ok": True, "url": f"{origin}/search/results/companies/?keywords=zig%20dev%20%26%20caf%C3%A9", "resultCount": 3})
    expect_equal("search recorded", li(), {"action": "search", "type": "companies", "keywords": "zig dev & café"})
    expect_equal("extract", zb.linkedin.extract(profile), {"name": "Sam Example", "headline": "Engineer at Example Co", "location": "Springfield"})
    zb.call("dom.waitFor", {"selector": 'css=[aria-label="Follow Sam Example"]', "state": "attached"})
    report = zb.linkedin.selfcheck()
    for key in ("signed_in", "connect_button", "follow_button"):
        if report.get(key, 0) < 1:
            raise AssertionError(f"selfcheck {key} on the profile: {report}")
    zb.linkedin.like(post)
    post_report = zb.linkedin.selfcheck()
    expect_equal("selfcheck on the post", (post_report["liked_button"], post_report["comment_button"], post_report["repost_button"]), (1, 1, 1))
    passed.append("linkedin")

    # Signed-in marker gate after navigation (stale cookie, signed-out page).
    expect_error("signed-out page", lambda: zb.linkedin.follow(f"{origin}/in/sam/?loggedout=1"), -32011, "logged_out")
    passed.append("signed-in-marker-gate")

    # Instagram.
    ig_profile = f"{origin}/sam.example/"
    expect_equal("ig follow", zb.instagram.follow(ig_profile), {"ok": True})
    expect_equal("ig follow recorded", ig(), {"action": "follow"})
    ig_post = f"{origin}/p/C0ffee/"
    expect_equal("ig like", zb.instagram.like(ig_post), {"ok": True})
    expect_equal("ig like recorded", ig(), {"action": "like"})
    expect_equal("ig comment", zb.instagram.comment(ig_post, "So good"), {"ok": True})
    expect_equal("ig comment recorded", ig(), {"action": "comment", "text": "So good"})
    if "keydown:comment" not in zb.page.evaluate("window.__ig.events")["result"]:
        raise AssertionError("the comment was not typed")
    expect_equal("ig dm", zb.instagram.dm("sam.example", "hi Sam"), {"ok": True})
    expect_equal("ig dm recorded", ig(), {"action": "dm", "text": "hi Sam"})
    # Until the live story viewer's markup is verified
    # (instagram.story_viewer_verified in src/instagram.zig), story_view opens
    # the story, checks it is one, then stops: nothing advances.
    expect_error("ig stories", lambda: zb.instagram.story_view("sam.example"), -32001, "instagram_story_viewer_unverified")
    expect_equal("ig stories: nothing advanced", (zb.page.evaluate("window.__ig.page")["result"], zb.page.evaluate("window.__ig.frames")["result"]), ("stories:sam.example", [1]))
    # No active stories: the profile, whose highlights carousel has its own
    # Next and avatars, is not a story viewer. Fail closed, click nothing.
    expect_error("ig no stories", lambda: zb.instagram.story_view("no.stories"), -32001, "instagram_no_story_viewer")
    expect_equal("ig no stories: highlights untouched", zb.page.evaluate("window.__ig.highlightNext")["result"], 0)
    zb.call("dom.waitFor", {"selector": "css=#follow", "state": "attached"})
    ig_report = zb.instagram.selfcheck()
    expect_equal(
        "ig selfcheck on the profile",
        (ig_report["signed_in"] >= 1, ig_report["follow_button"], ig_report["message_button"], ig_report["story_media"], ig_report["story_next"]),
        (True, 1, 1, 0, 0),
    )
    # A story page with a carousel's Next before the viewer's: nothing clicked.
    expect_error("ig two Next buttons", lambda: zb.instagram.story_view("decoy.user"), -32001, "instagram_story_viewer_unverified")
    expect_equal(
        "ig two Next buttons: nothing advanced",
        (zb.page.evaluate("window.__ig.decoyNext")["result"], zb.page.evaluate("window.__ig.frames")["result"]),
        (0, [1]),
    )
    passed.append("instagram")

    # Platform URLs only.
    expect_error("off-platform URL", lambda: zb.linkedin.visit("https://evil.example/in/sam/"), -32602)
    expect_error("other platform's URL", lambda: zb.instagram.follow("https://www.linkedin.com/in/sam/"), -32602)
    passed.append("platform-urls")

    # N20: checkpoint, limit modal and blocked-action pages stop the flow with
    # -32010 {signal, platform}; nothing is clicked after the detection.
    err = expect_error("linkedin checkpoint", lambda: zb.linkedin.visit(f"{origin}/in/checkpoint-me/"), -32010)
    expect_equal("checkpoint signal", (err.diagnostics.get("signal"), err.diagnostics.get("platform")), ("challenge", "linkedin"))
    expect_equal("checkpoint page reached", zb.page.evaluate("window.__li.page")["result"], "checkpoint")
    expect_equal("checkpoint: nothing clicked", zb.page.evaluate("window.__li.events")["result"], [])
    # (The invitation-limit modal after a Connect click returns with
    # linkedin.owner_actions_enabled; until then connect never clicks.)
    err = expect_error("instagram blocked like", lambda: zb.instagram.like(f"{origin}/p/blocked/"), -32010)
    expect_equal("blocked signal", (err.diagnostics.get("signal"), err.diagnostics.get("platform")), ("action_blocked", "instagram"))
    expect_equal("blocked: one Like click", zb.page.evaluate("window.__ig.events")["result"], ["click:like"])
    expect_equal("blocked: not liked", ig(), None)
    passed.append("platform-signals")

    # Daily cap: shared with social.rate_status; nothing reaches the site.
    status = zb.social.rate_status()
    zb.social.set_pacing(daily_cap=100 - status["remaining_actions"])
    before = len(server.paths)
    err = expect_error("daily cap", lambda: zb.instagram.follow(f"{origin}/riley.sample/"), -32010, "social_daily_cap")
    expect_equal("no request at the cap", len(server.paths), before)
    passed.append("daily-cap")

    # A failed command's trace holds the social compound span.
    spans = zb.call("telemetry.query", {"trace_id": err.trace_id})["spans"]
    names = [s["name"] for s in spans]
    expect_equal("trace root", names[0], "automation.command")
    if "automation.social.compound" not in names:
        raise AssertionError(f"no compound span: {names}")
    passed.append("telemetry")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (LINKEDIN, "linkedin fixture"), (INSTAGRAM, "instagram fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-social-") as tmp:
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
            wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                passed = scenario(zb, server.origin, server)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tsocial-flows")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tsocial-flows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
