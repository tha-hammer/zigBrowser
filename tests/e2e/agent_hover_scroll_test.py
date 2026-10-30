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
- tools-listed: the first request lists exactly the fourteen browser tools (S7.5's six, hover,
  scroll, navigate, reload, click, type_text, press_key, select_option);
- no card in any of them: no `DRAWER approval` row in window 1, no notification;
- native-refused: `hover` with `options: {input: native}` (it would move the user's own pointer)
  is an error before the browser acts: the CLI's schema refuses it (the broker's own refusal is
  tests/agent_broker_hover_test.zig), and `#menu` gets no `mouseover`;
- scroll-empty, scroll-mixed (RoseCat 5a204f3 #1): `scroll {}` and `scroll {selector, y}` are
  schema errors before the browser acts, and the page does not move; scroll is offered.

It launches and stops browsers, and its teardown may signal them (stop_browser's killpg), so it
runs only in a PID namespace the kernel proves is below its launcher's (RoseCat 5a204f3 #2):
  python3 tests/e2e/agent_hover_scroll_test.py --binary zig-out/bin/zigBrowser
re-execs itself as `sh -c 'exec 9</proc/self/ns/pid; exec bwrap --unshare-net ... -- unshare
--user --map-root-user --pid --fork --mount-proc sh -c "..." sh env ZB_OUTER_PIDNS_FD=9 python3
<this> --sealed-child ...'`, and the child checks pidns_guard.private_pid_namespace() before
any browser starts. `--sealed-child` from a caller without that proof fails closed (exit 1).
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
                                            "hover", "scroll", "navigate", "reload", "click", "type_text",
                                            "press_key", "select_option")}
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
        check(tools == TOOLS, f"tools-listed: exactly the fourteen browser tools ({sorted(tools)})")
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


def scroll_refused(binary: Path, tmp: Path, check, label: str, args: dict) -> None:
    """A scroll shape the broker refuses is refused by the CLI's schema first: an error, and
    the page does not move."""
    w = World(binary, tmp, label, {label: {"name": SCROLL, "input": args}})
    try:
        if not check(w.b.wait_page(), "the page loaded", w.b):
            return
        block = w.ask(check, label)
        if block is None:
            return
        check(block.get("is_error") is True and "validation" in result_text(block).lower(),
              f"scroll {args} is refused by its schema ({result_text(block)[:160]!r})")
        y = w.b.ev("window.scrollY")
        check(y == 0, f"the page did not move ({y})")
        tools = {t.get("name") for t in w.fake.api.messages_requests()[0]["body"].get("tools") or []}
        check(SCROLL in tools, f"scroll is offered ({sorted(tools)})")
        w.no_card(check, label)
    finally:
        w.close()


def case_scroll_empty(binary: Path, tmp: Path, check) -> None:
    scroll_refused(binary, tmp, check, "scroll-empty", {})


def case_scroll_mixed(binary: Path, tmp: Path, check) -> None:
    scroll_refused(binary, tmp, check, "scroll-mixed", {"selector": "css=#bottom", "y": 900})


CASES = {
    "hover": case_hover,
    "scroll-offset": case_scroll_offset,
    "scroll-into-view": case_scroll_into_view,
    "native-refused": case_native_refused,
    "scroll-empty": case_scroll_empty,
    "scroll-mixed": case_scroll_mixed,
}


# The launcher (RoseCat 5a204f3 #2): a shell holds this PID namespace as fd 9, then bwrap gives
# a network namespace of its own and unshare a user and PID namespace below the held one. The
# shell inside stays pid 1, so an orphan is adopted by it, never by the test.
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
