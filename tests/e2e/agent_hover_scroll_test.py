#!/usr/bin/env python3
"""S8e part 1 red (chat-drawer plan D9 and S8 decision 12): the model's `hover` and `scroll`
through the real chain, with no card.

Each case runs the real binary on its own private Xvfb (agent_common) with the real helper and
the real Claude CLI against the TLS fake Messages API (the lifecycle test's seams), a private
session bus with a fake notification server, and the navigate_approval store set to `yes`, so a
call that wrongly took decision 16's gate would show a card and raise a notification. The fake
scripts a `tool_use`; the test reads the `tool_result` the CLI sends back and the page's own
records (read through the socket's page.evaluate, the oracle, never to act):
- hover: `hover {selector: css=#menu}` gives `#menu` exactly one `mouseover` (the page's own
  log), and the tool_result is not an error;
- scroll-offset: `scroll {y: 900}` leaves the page's `scrollY` at 900 or more, and the result
  names `scrollY`;
- scroll-into-view: `scroll {selector: css=#bottom}` brings `#bottom` into the viewport;
- tools-listed: the first request lists exactly the ten tools (S7.5's six, hover, scroll,
  navigate, reload);
- no card in any of them: no `DRAWER approval` row in window 1, no notification;
- native-refused: `hover` with `options: {input: native}` (it would move the user's own pointer)
  is an error before the browser acts: the CLI's schema refuses it (the broker's own refusal is
  tests/agent_broker_hover_test.zig), and `#menu` gets no `mouseover`.

Like its siblings it re-execs itself sealed (bwrap: a network namespace of its own), and first
into a PID namespace of its own, since it launches and stops browsers:
  python3 tests/e2e/agent_hover_scroll_test.py --binary zig-out/bin/zigBrowser
(it wraps itself in `unshare --user --map-current-user --pid --fork --kill-child --mount-proc`).
Unregistered until its green."""

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

HOVER = "mcp__zigbrowser__hover"
SCROLL = "mcp__zigbrowser__scroll"
TOOLS = {f"mcp__zigbrowser__{n}" for n in ("window_info", "query", "get_text", "get_attribute", "wait_for", "screenshot",
                                            "hover", "scroll", "navigate", "reload")}
PAGE = """<!doctype html><meta charset="utf-8"><title>act</title>
<style>body { margin: 0 } #menu { width: 200px; height: 60px; background: #ccd } #bottom { height: 40px }</style>
<div id="menu">menu</div>
<div style="height: 4000px"></div>
<div id="bottom">bottom</div>
<script>
window.__hovers = [];
document.getElementById("menu").addEventListener("mouseover", e => window.__hovers.push(e.type));
window.__ready = true;
</script>"""


class World:
    """One case's browser, fake API, private bus and fake notification server; store `yes`."""

    def __init__(self, binary: Path, tmp: Path, label: str, calls: dict[str, dict]) -> None:
        self.fake = life.Fake(tmp)
        self.fake.api.responder = scripted(calls)
        self.w = life.world(binary, tmp, "hoverscroll")
        settings = self.w.agent / "settings"
        settings.mkdir(mode=0o700, exist_ok=True)
        store = settings / "navigate_approval"
        store.unlink(missing_ok=True)
        fd = os.open(store, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"yes\n")
        os.close(fd)
        self.bus = PrivateBus(Path(tmp) / f"bus-{label}")
        self.notifications = FakeNotifications(self.bus)
        env = life.env_for(self.w, life.runtime_dir(), dict(self.fake.seams()))
        env["DBUS_SESSION_BUS_ADDRESS"] = self.bus.address
        page = Path(tmp) / "act-page.html"
        page.write_text(PAGE)
        from agent_common import Browser
        self.b = Browser(binary, tmp, label, ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                         url=page.resolve().as_uri(), automation=True)

    def close(self) -> None:
        life.release_x(self.b)
        self.b.stop()
        self.fake.close()
        self.notifications.close()
        self.bus.close()

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

    def hovers(self) -> list[str]:
        return json.loads(self.b.ev("JSON.stringify(window.__hovers)"))


def case_hover(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "hover", {"hover-menu": {"name": HOVER, "input": {"selector": "css=#menu"}}})
    try:
        if not check(w.b.wait_page(), "the page loaded", w.b):
            return
        block = w.ask(check, "hover-menu")
        if block is None:
            return
        check(not block.get("is_error"), f"the hover succeeded ({result_text(block)[:160]!r})")
        check(w.hovers() == ["mouseover"], f"#menu got exactly one mouseover ({w.hovers()})")
        w.no_card(check, "hover")
        tools = {t.get("name") for t in w.fake.api.messages_requests()[0]["body"].get("tools") or []}
        check(tools == TOOLS, f"tools-listed: exactly the ten tools ({sorted(tools)})")
    finally:
        w.close()


def case_scroll_offset(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "scroll-offset", {"scroll-down": {"name": SCROLL, "input": {"y": 900}}})
    try:
        if not check(w.b.wait_page(), "the page loaded", w.b):
            return
        block = w.ask(check, "scroll-down")
        if block is None:
            return
        text = result_text(block)
        check(not block.get("is_error") and "scrollY" in text, f"the scroll succeeded and says where ({text[:160]!r})")
        y = w.b.ev("window.scrollY")
        check(isinstance(y, (int, float)) and y >= 900, f"the page scrolled down ({y})")
        w.no_card(check, "scroll by offset")
    finally:
        w.close()


def case_scroll_into_view(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "scroll-into-view", {"scroll-bottom": {"name": SCROLL, "input": {"selector": "css=#bottom"}}})
    try:
        if not check(w.b.wait_page(), "the page loaded", w.b):
            return
        block = w.ask(check, "scroll-bottom")
        if block is None:
            return
        check(not block.get("is_error"), f"the scroll succeeded ({result_text(block)[:160]!r})")
        seen = w.b.ev("(() => { const r = document.getElementById('bottom').getBoundingClientRect();"
                      " return r.top >= 0 && r.bottom <= innerHeight; })()")
        check(seen is True, f"#bottom is in view ({seen})")
        w.no_card(check, "scroll into view")
    finally:
        w.close()


def case_native_refused(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "native-refused",
              {"hover-native": {"name": HOVER, "input": {"selector": "css=#menu", "options": {"input": "native"}}}})
    try:
        if not check(w.b.wait_page(), "the page loaded", w.b):
            return
        block = w.ask(check, "hover-native")
        if block is None:
            return
        check(block.get("is_error") is True, f"a hover with options is refused ({result_text(block)[:160]!r})")
        check(w.hovers() == [], f"#menu got no mouseover ({w.hovers()})")
        # A control: the tool is offered, so the refusal above is its schema's, not a missing tool's.
        tools = {t.get("name") for t in w.fake.api.messages_requests()[0]["body"].get("tools") or []}
        check(HOVER in tools, f"hover is offered ({sorted(tools)})")
        w.no_card(check, "native hover")
    finally:
        w.close()


CASES = {
    "hover": case_hover,
    "scroll-offset": case_scroll_offset,
    "scroll-into-view": case_scroll_into_view,
    "native-refused": case_native_refused,
}


def main() -> int:
    if "--pid-ns" not in sys.argv and "--sealed-child" not in sys.argv:
        done = subprocess.run(["unshare", "--user", "--map-current-user", "--pid", "--fork", "--kill-child", "--mount-proc",
                               sys.executable, str(Path(__file__).resolve()), "--pid-ns", *sys.argv[1:]])
        return done.returncode
    if "--sealed-child" not in sys.argv:
        args = [a for a in sys.argv[1:] if a != "--pid-ns"]
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *args])
        return done.returncode
    sys.argv.remove("--sealed-child")
    from agent_common import run_main
    try:
        return run_main(__doc__, CASES)
    finally:
        for d in life.RUNTIME_DIRS:
            if str(d).startswith("/tmp/zbl-"):
                subprocess.run(["find", str(d), "-delete"], check=False)


if __name__ == "__main__":
    raise SystemExit(main())
