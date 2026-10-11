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
    # Connect and follow click only the profile's own control, inside the
    # owner's area (<main>'s "Primary content" section, live probe v2): the
    # visible copy, never the display:none copy, the aria-hidden toolbar
    # clone outside <main> or a "People you may know" card.
    other_copies = lambda: zb.page.evaluate("window.__li.otherCopies")["result"]  # noqa: E731
    expect_equal("connect", zb.linkedin.connect(profile, note="Hi Sam, loved your notes on the engine."), {"ok": True})
    expect_equal("connect recorded", li(), {"action": "connect", "note": "Hi Sam, loved your notes on the engine."})
    events = zb.page.evaluate("window.__li.events")["result"]
    if "keydown:note" not in events:
        raise AssertionError(f"the note was not typed: {events}")
    expect_equal("connect: only the own visible copy", (wrong_person(), other_copies(), events.count("click:connect")), ([], [], 1))
    expect_equal("connect without note", zb.linkedin.connect(profile), {"ok": True})
    expect_equal("connect without note recorded", li(), {"action": "connect", "note": None})
    expect_equal("connect without note: only the own visible copy", (wrong_person(), other_copies()), ([], []))
    # The invite dialog is in a shadow root and handles composed clicks only.
    expect_equal("connect: the shadow dialog's own button", zb.page.evaluate("window.__li.events")["result"], ["click:connect", "click:send_without_note"])
    expect_equal("follow", zb.linkedin.follow(profile), {"ok": True})
    expect_equal("follow recorded", li(), {"action": "follow"})
    # Live label after Follow (2026-10-11): the flow confirmed exactly this.
    expect_equal("follow: the live Following label", zb.page.evaluate("document.getElementById('follow').getAttribute('aria-label')")["result"], "Following, click to unfollow Sam Example")
    expect_equal("follow: only the own button", wrong_person(), [])
    # Another person with the owner's name, in a card and in <main> outside
    # the owner's area, both rendered before the owner's buttons: never
    # looked at; the owner's own control is clicked.
    same = f"{origin}/in/same-name/"
    expect_equal("same-name decoys", zb.linkedin.connect(same), {"ok": True})
    expect_equal("same-name decoys: only the owner", (li(), wrong_person(), other_copies()), ({"action": "connect", "note": None}, [], []))
    expect_equal("same-name decoys follow", zb.linkedin.follow(same), {"ok": True})
    expect_equal("same-name decoys follow: only the owner", (li(), wrong_person()), ({"action": "follow"}, []))
    # Two visible own Follow buttons in the owner's area: fail closed.
    expect_error("own Follow twice", lambda: zb.linkedin.follow(f"{origin}/in/twice/"), -32001, "linkedin_profile_action_ambiguous")
    expect_equal("own Follow twice: nothing done", (li(), wrong_person()), (None, []))
    # The profile's own Message has not been seen live: open, check, then
    # stop before any click.
    expect_error("message from profile", lambda: zb.linkedin.message("Hello Sam", profile_url=profile), -32001, "linkedin_profile_owner_unverified")
    expect_equal("message from profile: nothing done", (li(), wrong_person(), zb.page.evaluate("window.__li.events")["result"]), (None, [], []))
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

    # Connect through the owner's More menu (the live layout without an own
    # Connect, 2026-10-11): the owner's visible More (never its hidden copy,
    # the sticky clone or a card's More), the menu's "Connect", then the
    # invite dialog 4 s later in a shadow root, then the live Pending label.
    events = lambda: zb.page.evaluate("window.__li.events")["result"]  # noqa: E731
    labels = lambda: zb.page.evaluate(  # noqa: E731
        "[document.querySelector('[data-own-connect]') && document.querySelector('[data-own-connect]').getAttribute('aria-label'),"
        " document.getElementById('follow').getAttribute('aria-label'),"
        " Array.from(document.querySelectorAll('[role=alert]')).map(function (e) { return e.textContent; })]")["result"]
    for path in ("creator.user", "creator.inline"):
        creator = f"{origin}/in/{path}/"
        started = time.monotonic()
        expect_equal(f"{path}: connect via More", zb.linkedin.connect(creator), {"ok": True})
        if time.monotonic() - started < 4.0:
            raise AssertionError(f"{path}: the flow did not wait for the late dialog")
        expect_equal(f"{path}: recorded", li(), {"action": "connect", "note": None})
        expect_equal(f"{path}: More, its Connect, the dialog's Send", events(), ["click:more", "click:menu_connect", "click:send_without_note"])
        expect_equal(f"{path}: no other More, no card", (wrong_person(), other_copies()), ([], []))
        expect_equal(
            f"{path}: the live labels and toast",
            labels(),
            ["Pending, click to withdraw invitation sent to Sam Example", "Following, click to unfollow Sam Example", ["Invitation sent to Sam."]],
        )
    creator = f"{origin}/in/creator.user/"
    expect_equal("More route with a note", zb.linkedin.connect(creator, note="Hi Sam"), {"ok": True})
    expect_equal("More route with a note: recorded", li(), {"action": "connect", "note": "Hi Sam"})
    if "keydown:note" not in events():
        raise AssertionError(f"More route: the note was not typed: {events()}")
    report = zb.linkedin.selfcheck()
    expect_equal("selfcheck after the invitation", (report["pending_button"], report["following_button"], report["invite_sent_toast"]), (1, 1, 1))
    # The owner's menu without Connect (already pending or connected): the
    # menu is closed again, nothing else clicked.
    err = expect_error("menu without Connect", lambda: zb.linkedin.connect(f"{origin}/in/creator.pending/"), -32001, "linkedin_profile_connect_not_in_menu")
    expect_equal("menu without Connect: closed, nothing chosen", (events(), li(), wrong_person(), other_copies()), (["click:more", "menu:escape"], None, [], []))
    passed.append("more-menu-connect")

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
    # The viewer as live (probe of 2026-10-11): its own Next (an svg in a
    # div[role=button], outside <main>) frame by frame; the zero-size "Next"
    # of the page behind it and the story previews are never clicked. The
    # last Next leaves for the profile.
    expect_equal("ig stories", zb.instagram.story_view("sam.example"), {"ok": True, "framesViewed": 3})
    expect_equal(
        "ig stories seen, nothing else clicked",
        (zb.page.evaluate("window.__ig.page")["result"], zb.page.evaluate("window.__ig.storyFrames")["result"], zb.page.evaluate("window.__ig.storyDecoyNext")["result"]),
        ("profile:sam.example", [1, 2, 3], 0),
    )
    # Instagram can go on to the next person's stories: the flow stops at the
    # end of the requested user's, and the other person's are not advanced.
    expect_equal("ig stories then another person", zb.instagram.story_view("next.user"), {"ok": True, "framesViewed": 3})
    expect_equal("ig another person's stories untouched", (zb.page.evaluate("window.__ig.page")["result"], zb.page.evaluate("window.__ig.frames")["result"]), ("stories:riley.sample", [1]))
    # Instagram also moves on BY ITSELF when a frame ends: the flow checks
    # whose story it is before every Next and never clicks on someone else's
    # (review 5046).
    try:
        auto = zb.instagram.story_view("auto.user")
    except AutomationError as err:  # moved on before the first check: refused
        auto = (err.code, (err.diagnostics or {}).get("reason"))
    if auto not in ({"ok": True, "framesViewed": 1}, (-32001, "instagram_no_story_viewer")):
        raise AssertionError(f"ig story moved on by itself: {auto}")
    zb.call("dom.waitFor", {"selector": "css=#story-next", "state": "attached"})
    expect_equal("ig moved on by itself: the other person's story untouched", (zb.page.evaluate("window.__ig.page")["result"], zb.page.evaluate("window.__ig.frames")["result"]), ("stories:riley.sample", [1]))
    story_report = zb.instagram.selfcheck()
    expect_equal("ig selfcheck in the viewer", (story_report["story_next"], story_report["story_media"] >= 1), (1, True))
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
    # A second viewer-shaped Next outside <main> (a carousel): fail closed,
    # nothing clicked.
    expect_error("ig two Next buttons", lambda: zb.instagram.story_view("decoy.user"), -32001, "instagram_story_next_ambiguous")
    expect_equal(
        "ig two Next buttons: nothing advanced",
        (zb.page.evaluate("window.__ig.decoyNext")["result"], zb.page.evaluate("window.__ig.frames")["result"]),
        (0, [1]),
    )
    passed.append("instagram")

    # options.dry_run: each acting flow runs up to its committing click, which
    # is only tried (actionability checks, no event). No handler on the page
    # sees anything (window.__input records every pointer, key and edit event
    # before any handler), nothing is typed, sent or counted.
    remaining = zb.social.rate_status()["remaining_actions"]
    page_input = lambda: zb.page.evaluate("window.__input")["result"]  # noqa: E731
    js = lambda expression: zb.page.evaluate(expression)["result"]  # noqa: E731

    def dry(label, call, would_act, target):
        result = call()
        expect_equal(f"{label} dry run", (result.get("dry_run"), result.get("would_act")), (True, would_act))
        got = result.get("target")
        if target is None:
            expect_equal(f"{label} target", got, None)
        else:
            expect_equal(f"{label} target", (got.get("tag"), got.get("label")), target)
            box = got.get("box") or {}
            if not (box.get("width", 0) > 0 and box.get("height", 0) > 0):
                raise AssertionError(f"{label}: target has no box: {got}")
        if "rate_limit_scans" not in [c["name"] for c in result["checks"]]:
            raise AssertionError(f"{label}: no rate-limit scans reported: {result['checks']}")
        expect_equal(f"{label}: no input event on the page", page_input(), [])
        return result

    dry("li connect", lambda: zb.linkedin.connect(profile, note="Hi Sam", dry_run=True), "connect", ("a", "Invite <owner> to connect"))
    expect_equal(
        "li connect dry run: no Connect click, no invite dialog, no other copy",
        (li(), zb.page.evaluate("window.__li.events")["result"], wrong_person(), other_copies(), js("document.getElementById('invite-host').shadowRoot.getElementById('invite').hidden")),
        (None, [], [], [], True),
    )
    # The More route: only the owner's More is tried; the menu stays shut.
    more = dry("li connect via More", lambda: zb.linkedin.connect(f"{origin}/in/creator.user/", dry_run=True), "connect", ("button", "More"))
    expect_equal(
        "li connect via More dry run: the menu step is reported, nothing opened",
        ([c for c in more["checks"] if c["name"] == "more_menu"], li(), zb.page.evaluate("window.__li.events")["result"], js("document.getElementById('menu').hidden")),
        ([{"name": "more_menu", "result": "not_reached", "reason": "Connect is inside the owner's More menu; opening it needs a click"}], None, [], True),
    )
    dry("li follow", lambda: zb.linkedin.follow(profile, dry_run=True), "follow", ("button", "Follow <owner>"))
    expect_equal("li follow dry run: still Follow", (li(), js("document.getElementById('follow').getAttribute('aria-label')")), (None, "Follow Sam Example"))
    expect_error("li follow dry run, own Follow twice", lambda: zb.linkedin.follow(f"{origin}/in/twice/", dry_run=True), -32001, "linkedin_profile_action_ambiguous")
    dry("li like", lambda: zb.linkedin.like(post, dry_run=True), "like", ("button", "Reaction button state: no reaction"))
    expect_equal("li like dry run: not liked", (li(), js("document.querySelector('[aria-label^=\"Reaction button state: \"]').getAttribute('aria-label')")), (None, "Reaction button state: no reaction"))
    dry("li comment", lambda: zb.linkedin.comment(post, "Great post", dry_run=True), "comment", ("button", "Comment"))
    expect_equal("li comment dry run: box closed and empty", (li(), js("document.querySelector('.comments-comment-box__form').hidden"), js("document.querySelector('.comments-comment-box__form [contenteditable]').textContent")), (None, True, ""))
    dry("ig follow", lambda: zb.instagram.follow(ig_profile, dry_run=True), "follow", ("button", "Follow"))
    expect_equal("ig follow dry run: still Follow", (ig(), js("document.getElementById('follow').textContent")), (None, "Follow"))
    dry("ig like", lambda: zb.instagram.like(ig_post, dry_run=True), "like", ("svg", "Like"))
    expect_equal("ig like dry run: not liked", (ig(), zb.page.evaluate("window.__ig.events")["result"]), (None, []))
    dry("ig comment", lambda: zb.instagram.comment(ig_post, "So good", dry_run=True), "comment", ("textarea", "Add a comment\u2026"))
    expect_equal("ig comment dry run: nothing typed or posted", (ig(), js("document.querySelector('textarea').value")), (None, ""))
    dry("ig story", lambda: zb.instagram.story_view("sam.example", dry_run=True), "story_view", ("div", "Next"))
    expect_equal(
        "ig story dry run: first frame only, Next never clicked",
        (zb.page.evaluate("window.__ig.page")["result"], zb.page.evaluate("window.__ig.frames")["result"], zb.page.evaluate("window.__ig.decoyNext")["result"]),
        ("stories:sam.example", [1], 0),
    )
    expect_error("ig story dry run, two Next buttons", lambda: zb.instagram.story_view("decoy.user", dry_run=True), -32001, "instagram_story_next_ambiguous")
    expect_equal(
        "ig two Next buttons dry run: neither Next touched",
        (zb.page.evaluate("window.__ig.decoyNext")["result"], zb.page.evaluate("window.__ig.frames")["result"], page_input()),
        (0, [1], []),
    )
    gate = dry("ig story behind a View story button", lambda: zb.instagram.story_view("gate.user", dry_run=True), "story_view", None)
    stop = [c for c in gate["checks"] if c["name"] == "view_story_click"]
    if not (stop and stop[0]["result"] == "not_reached" and stop[0]["reason"].startswith("instagram_story_view_needs_click")):
        raise AssertionError(f"ig story gate: no stop reason: {gate['checks']}")
    expect_equal("ig story gate: View story never clicked", zb.page.evaluate("window.__ig.events")["result"], [])
    expect_equal("dry runs count nothing", zb.social.rate_status()["remaining_actions"], remaining)
    # The real story_view refuses the "View story" button too.
    expect_error("ig story behind a View story button (real)", lambda: zb.instagram.story_view("gate.user"), -32001, "instagram_story_view_needs_click")
    expect_equal("ig story gate (real): View story never clicked", zb.page.evaluate("window.__ig.events")["result"], [])
    passed.append("dry-run")

    # A failed flow says which step failed (data.step). A story page with no
    # navigation has no signed-in marker: the wait for it times out.
    for label, call in (
        ("dry run", lambda: zb.instagram.story_view("nonav.user", dry_run=True)),
        ("real", lambda: zb.instagram.story_view("nonav.user")),
    ):
        err = expect_error(f"ig story without the nav ({label})", call, -32001, "timeout")
        expect_equal(f"ig story without the nav ({label}): step", err.diagnostics.get("step"), "waitFor_signed_in")
        expect_equal(
            f"ig story without the nav ({label}): nothing clicked",
            (page_input(), zb.page.evaluate("window.__ig.frames")["result"]),
            ([], [1]),
        )
    passed.append("failed-step")

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
    err = expect_error("linkedin invitation limit", lambda: zb.linkedin.connect(f"{origin}/in/limit-reached/"), -32010)
    expect_equal("limit signal", (err.diagnostics.get("signal"), err.diagnostics.get("platform")), ("invitation_limit", "linkedin"))
    expect_equal("limit: only the Connect click", zb.page.evaluate("window.__li.events")["result"], ["click:connect"])
    expect_equal("limit: no invitation", li(), None)
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
