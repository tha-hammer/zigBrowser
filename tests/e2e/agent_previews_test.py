#!/usr/bin/env python3
"""S8e part 2 red (chat-drawer plan D9 and S8 decision 12): the model's dry-run previews through the
real chain, with no card and nothing done on the site.

Each case runs the real binary on its own private Xvfb (agent_common) with the real helper and
the real Claude CLI against the TLS fake Messages API (the lifecycle test's seams), a private
session bus with a fake notification server, and the navigate_approval store at `yes`, so a
preview that wrongly took decision 16's gate would show a card and notify. The LinkedIn and
Instagram fixtures (tests/fixtures/linkedin/, tests/fixtures/instagram/) are served on loopback
and reach the browser through the test-only ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN; their session
cookies are seeded through the socket (cookies.set), as social_flows_test.py does. The fake
scripts a `tool_use`; the test reads the `tool_result` the CLI sends back, the fixture's own
records (window.__li / window.__ig, and window.__input, every pointer, key and edit event before
any handler) and social.rate_status, through the socket, as oracles only:
- li-like: `linkedin_like_preview {postUrl}` gives a dry-run result (`dry_run` true, `would_act`
  "like", the reaction button as its target, the rate-limit scans in `checks`); the bound window
  opened the post (the fixture server saw it), `__li.result` is null and `__input` is `[]`
  (nothing clicked); `remaining_actions` is unchanged; no card in any drawer, no notification;
  the request lists exactly the 17 tools;
- ig-comment: `instagram_comment_preview {postUrl, text}` gives `would_act` "comment"; nothing is
  typed or posted (`__ig.result` null, the textarea empty, `__input` `[]`); no card;
- real-run-refused: `linkedin_like_preview` with `options: {dry_run: false}` is a schema error
  before the browser acts: the post is never requested and nothing is recorded.

It launches and stops browsers, and its teardown may signal them, so it runs only in a PID
namespace the kernel proves is below its launcher's (pidns_guard, as agent_hover_scroll_test.py):
  python3 tests/e2e/agent_previews_test.py --binary zig-out/bin/zigBrowser
A bare `--sealed-child` fails closed (exit 1). Unregistered until its green."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and helpers
from agent_tools_test import answered, result_text, scripted, tool_results  # noqa: E402
from fake_notifications import FakeNotifications, PrivateBus  # noqa: E402
from social_flows_test import FixtureServer  # noqa: E402

PREFIX = "mcp__zigbrowser__"
TOOLS = {PREFIX + n for n in (
    "window_info", "query", "get_text", "get_attribute", "wait_for", "screenshot", "hover", "scroll",
    "linkedin_connect_preview", "linkedin_follow_preview", "linkedin_like_preview", "linkedin_comment_preview",
    "instagram_follow_preview", "instagram_like_preview", "instagram_comment_preview", "navigate", "reload")}
LI_POST = "/feed/update/urn:li:activity:1/"
# The fixtures' own records, read without throwing on the other platform's page.
LI_RESULT = "window.__li ? window.__li.result : null"
IG_RESULT = "window.__ig ? window.__ig.result : null"
IG_POST = "/p/C0ffee/"


class World:
    """One case's browser on the fixture origin, fake API, private bus and fake notification
    server; store `yes`; the session cookies seeded."""

    def __init__(self, binary: Path, tmp: Path, label: str, calls: dict[str, dict]) -> None:
        self.server = FixtureServer().__enter__()
        self.fake = life.Fake(tmp)
        self.fake.api.responder = scripted(calls)
        self.w = life.world(binary, tmp, "previews")
        settings = self.w.agent / "settings"
        settings.mkdir(mode=0o700, exist_ok=True)
        store = settings / "navigate_approval"
        store.unlink(missing_ok=True)
        fd = os.open(store, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"yes\n")
        os.close(fd)
        self.bus = PrivateBus(Path(tmp) / f"bus-{label}")
        self.notifications = FakeNotifications(self.bus)
        env = life.env_for(self.w, life.runtime_dir(), {**self.fake.seams(),
                                                         "ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN": self.server.origin})
        env["DBUS_SESSION_BUS_ADDRESS"] = self.bus.address
        from agent_common import Browser
        self.b = Browser(binary, tmp, label, ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                         url=f"{self.server.origin}/feed/", automation=True)

    def close(self) -> None:
        life.release_x(self.b)
        self.b.stop()
        self.fake.close()
        self.notifications.close()
        self.bus.close()
        self.server.__exit__(None, None, None)

    def ready(self, check) -> bool:
        def loaded() -> bool:
            try:
                return self.b.ev("location.pathname") == "/feed/"
            except Exception:  # noqa: BLE001 - still loading
                return False
        if not check(self.b.wait(loaded, 20), "the fixture's feed loaded", self.b):
            return False
        self.b.zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
        self.b.zb.cookies.set("sessionid", "fixture-session", domain="127.0.0.1")
        return True

    def remaining(self) -> int:
        return self.b.zb.social.rate_status()["remaining_actions"]

    def js(self, expression: str):
        return self.b.ev(expression)

    def ask(self, check, prompt: str):
        """Sends `prompt` in window 1 and returns the one tool_result block the model got."""
        life.send(self.b, prompt, 1)
        entry = answered(self.fake)
        if not check(entry is not None, f"{prompt}: a tool_result reached the API", self.b):
            return None
        blocks = tool_results(entry)
        check(len(blocks) == 1, f"{prompt}: exactly one tool_result ({len(blocks)})")
        return blocks[0] if blocks else None

    def no_card(self, check, what: str) -> None:
        check(self.b.rows("approval") == [], f"{what}: no approval card in any drawer ({self.b.rows('approval')})")
        check(self.notifications.notifies() == [], f"{what}: no notification ({self.notifications.notifies()})")

    def tools(self) -> set[str]:
        return {t.get("name") for t in self.fake.api.messages_requests()[0]["body"].get("tools") or []}


def dry_result(check, block, would_act: str, what: str) -> dict | None:
    text = result_text(block)
    try:
        result = json.loads(text)
    except ValueError:
        check(False, f"{what}: the result is JSON ({text[:160]!r})")
        return None
    check(not block.get("is_error") and result.get("dry_run") is True and result.get("would_act") == would_act,
          f"{what}: a dry run that would {would_act} ({text[:200]!r})")
    check("rate_limit_scans" in [c.get("name") for c in result.get("checks") or []],
          f"{what}: the rate-limit scans are reported ({result.get('checks')})")
    return result


def case_li_like(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "li-like", {})
    try:
        if not w.ready(check):
            return
        w.fake.api.responder = scripted({"preview-like": {"name": PREFIX + "linkedin_like_preview",
                                                           "input": {"postUrl": w.server.origin + LI_POST}}})
        before = w.remaining()
        block = w.ask(check, "preview-like")
        if block is None:
            return
        result = dry_result(check, block, "like", "li like preview")
        if result is not None:
            target = result.get("target") or {}
            check((target.get("tag"), target.get("label")) == ("button", "Reaction button state: no reaction"),
                  f"its target is the reaction button ({target})")
        check(w.server.requested(LI_POST), f"the bound window opened the post ({w.server.paths})")
        check(w.js(LI_RESULT) is None, f"nothing was liked ({w.js(LI_RESULT)})")
        check(w.js("window.__input") == [], f"no input event reached the page ({w.js('window.__input')})")
        check(w.remaining() == before, f"no pacing used ({before} -> {w.remaining()})")
        w.no_card(check, "li like preview")
        check(w.tools() == TOOLS, f"tools-listed: exactly the 17 tools ({sorted(w.tools())})")
    finally:
        w.close()


def case_ig_comment(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "ig-comment", {})
    try:
        if not w.ready(check):
            return
        w.fake.api.responder = scripted({"preview-comment": {"name": PREFIX + "instagram_comment_preview",
                                                             "input": {"postUrl": w.server.origin + IG_POST, "text": "So good"}}})
        block = w.ask(check, "preview-comment")
        if block is None:
            return
        dry_result(check, block, "comment", "ig comment preview")
        check(w.server.requested(IG_POST), f"the bound window opened the post ({w.server.paths})")
        check(w.js(IG_RESULT) is None, f"nothing was posted ({w.js(IG_RESULT)})")
        check(w.js("document.querySelector('textarea') ? document.querySelector('textarea').value : null") == "",
              "nothing was typed")
        check(w.js("window.__input") == [], f"no input event reached the page ({w.js('window.__input')})")
        w.no_card(check, "ig comment preview")
    finally:
        w.close()


def case_real_run_refused(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "real-run-refused", {})
    try:
        if not w.ready(check):
            return
        w.fake.api.responder = scripted({"really-like": {"name": PREFIX + "linkedin_like_preview",
                                                         "input": {"postUrl": w.server.origin + LI_POST,
                                                                   "options": {"dry_run": False}}}})
        before = w.remaining()
        block = w.ask(check, "really-like")
        if block is None:
            return
        check(block.get("is_error") is True and "validation" in result_text(block).lower(),
              f"a preview with options is refused by its schema ({result_text(block)[:160]!r})")
        check(not w.server.requested(LI_POST), f"the post was never opened ({w.server.paths})")
        check(w.remaining() == before, f"no pacing used ({before} -> {w.remaining()})")
        check(PREFIX + "linkedin_like_preview" in w.tools(), f"the preview is offered ({sorted(w.tools())})")
        w.no_card(check, "refused preview")
    finally:
        w.close()


CASES = {
    "li-like": case_li_like,
    "ig-comment": case_ig_comment,
    "real-run-refused": case_real_run_refused,
}

# The launcher (as agent_hover_scroll_test.py, RoseCat 5a204f3 #2): a shell holds this PID namespace
# as fd 9, then bwrap gives a network namespace of its own and unshare a user and PID namespace
# below the held one. The shell inside stays pid 1, so an orphan is adopted by it, never by the test.
LAUNCH = ('script=$1; shift; exec 9</proc/self/ns/pid; exec /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- '
          'unshare --user --map-root-user --pid --fork --mount-proc sh -c "\\"\\$@\\"; exit \\$?" sh '
          'env ZB_OUTER_PIDNS_FD=9 "$0" "$script" --sealed-child "$@"')


def main() -> int:
    if "--sealed-child" not in sys.argv:
        args = sys.argv[1:]
        return subprocess.run(["sh", "-c", LAUNCH, sys.executable, str(Path(__file__).resolve()), *args]).returncode
    sys.argv.remove("--sealed-child")
    # The marker is not proof: the kernel must show this process below the launcher's held
    # namespace (pidns_guard) before any browser starts, since teardown may signal (killpg).
    sys.path.insert(0, str(HERE.parents[1] / "agent" / "host" / "tests"))
    from pidns_guard import private_pid_namespace
    proven, why = private_pid_namespace()
    if not proven:
        print(f"FAIL refusing to start a browser outside a proven private PID namespace: {why}", flush=True)
        return 1
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
