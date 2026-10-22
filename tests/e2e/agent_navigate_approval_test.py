#!/usr/bin/env python3
"""S8 decision 16, part 3 red (chat-drawer plan; S8c/S8d through the real chain): navigate and
reload approval cards in the app, the main window's drawer, the desktop notification, and
cancel on the main window's close.

Like agent_tools_test.py: the real binary on its own Xvfb, the real helper and Claude CLI
against the TLS fake Messages API, in a network namespace of its own (re-exec'd as
--sealed-child). The fake scripts a `tool_use` of mcp__zigbrowser__navigate or ..._reload,
and the test reads the `tool_result` the CLI sends back. It never calls the broker, the cards
or the engine. Pages are served from loopback (http://127.0.0.1:<port>), so each has an origin.

The contract this red pins (plan decision 16 and its part-3 rows):
- **The modes.** A prompt typed in a window whose drawer stays open is interactive; the same
  prompt with that drawer minimized before the call arrives is headless (the test holds the
  fake's tool_use until the drawer is minimized). Every prompt today is typed: full
  automation has no entry yet, and its cells are pinned by the broker's 18-row red (c8cc8c7).
- **The store** is agent-home/settings/navigate_approval: missing = conditional; `yes\\n`
  cards even interactive use; `no\\n` never; anything else (here mode 0644) = yes, and the
  bound window's drawer says "Navigation approval setting is unreadable; asking for every
  navigation." (DRAWER <bound> msg system ...).
- **The card** shows only in the main window's drawer (window 1, the first opened), never in
  the bound window's or any other:
  - `DRAWER 1 approval <card> <navigate|reload> <origin> - <digest>`: the bound window's page
    origin, no account, and the lowercase hex SHA-256 of the exact params the engine gets if
    approved (`{"url":"<url>","window_id":"window-N"}` / `{"window_id":"window-N"}`);
  - `DRAWER 1 msg approval Claude wants to open <url> in window N.` /
    `... Claude wants to reload window N.`;
  - `DRAWER 1 approvalrect <card> approve|deny <rect>` while drawn, for the test's X click;
  - Approve: `approvalstate <card> approved`, then `approvalend <card> done` once the
    navigation ran; Deny: `approvalend <card> denied` and the model gets "The navigation was
    denied."; 120 s unanswered: `approvalend <card> expired`, "The navigation was not
    approved in time." (never the helper's own timeout text); the bound window closed while
    its card waits: `approvalend <card> revoked`, and no answer from the browser.
  - The bound window is not navigated or reloaded while its card waits, nor after any ending
    but `done`; the model gets no answer while it waits.
- **The main window closes** while cards wait: every waiting card is cancelled, each model
  gets "The navigation was cancelled.", nothing is navigated; with no main window a later
  carded call is cancelled at once, with no card in any window and no notification.
- **The desktop notification** (org.freedesktop.Notifications on the session bus): one Notify
  per card, app_name and summary "zigBrowser", body "Claude is waiting for your approval.",
  its only action key `default`; nothing of the step (URL, canary, window id, digest) in any
  argument. Its ActionInvoked(<that id>, "default") from the name's owner presents window 1
  and opens its drawer (`DRAWER 1 open`) and changes no card; another id, another action key,
  or the same signal from a connection that does not own the name does nothing. With no
  notification server on the bus (or no reachable bus), the card still waits and Approve
  still works.
- **The model and the socket cannot choose:** a tool argument naming `navigate_approval` or a
  `window_id` is refused by the tool's schema and navigates nothing; `settings.navigate_approval`,
  `agent.navigate_approval`, `settings.set` and `approval.approve` are -32601 and the store is
  unchanged.

Exit 1 when Xvfb, xauth, bwrap, the venv or the binary is missing. Unregistered until its
green (the green also moves agent_tools_test.py's and test_tools.py's six-tool lists to
eight)."""

from __future__ import annotations

import ctypes
import hashlib
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402 - its world, seams and helpers
from agent_tools_test import DONE, result_text, tool_results  # noqa: E402
from fake_notifications import FakeNotifications, PrivateBus  # noqa: E402

NAVIGATE = "mcp__zigbrowser__navigate"
RELOAD = "mcp__zigbrowser__reload"
CANARY = "zbnavcanary5e1"
NOT_APPROVED = "The navigation was not approved in time."
CANCELLED = "The navigation was cancelled."
DENIED = "The navigation was denied."
HELPER_TIMEOUT = "The browser did not answer in time."
UNREADABLE = "Navigation approval setting is unreadable; asking for every navigation."
TITLE, BODY = "zigBrowser", "Claude is waiting for your approval."
PAGE = """<!doctype html><meta charset="utf-8"><title>%s</title><h1 id="where">%s</h1>
<script>
sessionStorage.loads = String(Number(sessionStorage.loads || 0) + 1);
window.__ready = true;
</script>"""


class Pages:
    """Loopback pages: /one.html (window 1), /pop.html (each popup), /two.html (the target)."""

    def __init__(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - the stdlib's name
                name = self.path.split("?")[0].split("#")[0].strip("/").removesuffix(".html") or "one"
                body = (PAGE % (name, name)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, name: str) -> str:
        return f"{self.origin}/{name}.html"

    def target(self) -> str:
        return f"{self.origin}/two.html#{CANARY}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def params_of(tool: str, win: int, url: str | None = None, doc: tuple[str, int] | None = None) -> str:
    """The exact params the engine gets, as the broker writes them; a carded call's also expect
    the document its card described, `doc` = (origin, load_serial) (part 4, phase A)."""
    params: dict = {"url": url, "window_id": f"window-{win}"} if tool == NAVIGATE else {"window_id": f"window-{win}"}
    if doc is not None:
        params["options"] = {"expect": {"origin": doc[0], "load_serial": doc[1]}}
    return json.dumps(params, separators=(",", ":"))


def digest(tool: str, win: int, url: str | None = None, doc: tuple[str, int] | None = None) -> str:
    return hashlib.sha256(params_of(tool, win, url, doc).encode()).hexdigest()


class Gated:
    """A responder: a prompt holding a key gets its tool_use once the key's gate is set (the
    test minimizes the drawer first); the request carrying its tool_result gets DONE."""

    def __init__(self, calls: dict[str, dict]) -> None:
        self.calls = calls
        self.gates = {key: threading.Event() for key in calls}

    def release(self, key: str) -> None:
        self.gates[key].set()

    def __call__(self, entry, index):
        users = [m for m in (entry.get("body") or {}).get("messages") or [] if m.get("role") == "user"]
        turn = users[-1].get("content") if users else ""  # this turn only: later requests repeat older ones
        blocks = [{"type": "text", "text": turn}] if isinstance(turn, str) else [b for b in turn or [] if isinstance(b, dict)]
        typed = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        # A new prompt first: after an interrupt the CLI sends the interrupted call's
        # tool_result and the next prompt in one turn.
        for key, call in self.calls.items():
            if key in typed:
                self.gates[key].wait(120)
                return {"tool_use": call}
        if any(b.get("type") == "tool_result" for b in blocks):
            return {"text": DONE}
        return {"text": "ok"}


class World:
    """One case's browser, its fake API, its private bus and (maybe) a notification server."""

    def __init__(self, binary: Path, tmp: Path, label: str, calls: dict[str, dict], notifier: str = "fake",
                 store: bytes | None = None, store_mode: int = 0o600) -> None:
        self.pages = Pages()
        self.fake = life.Fake(tmp)
        self.gated = Gated(calls)
        self.fake.api.responder = self.gated
        self.w = life.world(binary, tmp, "navapproval")
        settings = self.w.agent / "settings"
        settings.mkdir(mode=0o700, exist_ok=True)
        self.store = settings / "navigate_approval"
        self.store.unlink(missing_ok=True)
        if store is not None:
            fd = os.open(self.store, os.O_WRONLY | os.O_CREAT | os.O_EXCL, store_mode)
            os.write(fd, store)
            os.close(fd)
            os.chmod(self.store, store_mode)
        self.bus = self.notifications = None
        extra = dict(self.fake.seams())
        if notifier in ("fake", "none"):  # "dead": life's unreachable address stays
            self.bus = PrivateBus(Path(tmp) / f"bus-{label}")
            if notifier == "fake":
                self.notifications = FakeNotifications(self.bus)
        env = life.env_for(self.w, life.runtime_dir(), extra)
        if self.bus is not None:
            env["DBUS_SESSION_BUS_ADDRESS"] = self.bus.address
        from agent_common import Browser
        self.b = Browser(binary, tmp, label, ["--agent-drawer", "on", "--agent-secret-store", "file"], env=env,
                         url=self.pages.url("one"), automation=True)
        self.first_toplevel = None

    def close(self) -> None:
        for gate in self.gated.gates.values():
            gate.set()
        life.release_x(self.b)
        self.b.stop()
        self.fake.close()
        if self.notifications is not None:
            self.notifications.close()
        if self.bus is not None:
            self.bus.close()
        self.pages.close()

    # --- windows -----------------------------------------------------------------------
    def ready(self, check) -> bool:
        if not check(self.b.wait_page(), "window 1's page loaded", self.b):
            return False
        tops = self.b.x.toplevels()
        self.first_toplevel = tops[0][0] if len(tops) == 1 else None
        return check(self.first_toplevel is not None, f"one toplevel before any popup ({tops})")

    def popup(self, check, n: int) -> bool:
        self.b.ev(f"(window.open({json.dumps(self.pages.url('pop'))}), 1)")
        return check(self.b.wait(lambda: self.b.rows("icon", n) != [], 20) and self.b.wait_page(f"window-{n}"),
                     f"window {n} is open with its drawer", self.b)

    def doc(self, win: int) -> tuple[str, int]:
        """Window `win`'s document now: its page's origin (every page here is on this server)
        and its load_serial, as page.list gives it."""
        serial = next(p["load_serial"] for p in self.b.zb.page.list()["pages"] if p["window_id"] == f"window-{win}")
        return self.pages.origin, serial

    def path(self, win: int) -> str:
        return self.b.ev("location.pathname + location.hash", f"window-{win}")

    def loads(self, win: int) -> int:
        return int(self.b.ev("Number(sessionStorage.loads)", f"window-{win}"))

    def raise_first(self) -> None:
        """What clicking window 1's title bar does: it goes on top (no window manager here)."""
        x = self.b.x
        x._x.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x._x.XRaiseWindow(x._dpy, self.first_toplevel)
        x._x.XFlush(x._dpy)
        time.sleep(0.3)

    def close_first(self) -> None:
        """What a window manager's close button does to window 1 (the socket's page.close
        refuses the primary window): WM_DELETE_WINDOW to its toplevel."""
        x = self.b.x
        lib = x._x
        lib.XInternAtom.restype = ctypes.c_ulong
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
        event = life._XEvent()
        event.xclient.type = 33  # ClientMessage
        event.xclient.window = self.first_toplevel
        event.xclient.message_type = lib.XInternAtom(x._dpy, b"WM_PROTOCOLS", 0)
        event.xclient.format = 32
        event.xclient.l[0] = lib.XInternAtom(x._dpy, b"WM_DELETE_WINDOW", 0)
        lib.XSendEvent(x._dpy, self.first_toplevel, 0, 0, ctypes.byref(event))
        lib.XFlush(x._dpy)

    def first_on_top(self) -> bool:
        tops = self.b.x.toplevels()
        return bool(tops) and tops[-1][0] == self.first_toplevel

    # --- the drawer -----------------------------------------------------------------------
    def open_drawer(self, win: int) -> bool:
        """Opens window `win`'s drawer (its icon, or where it was minimized to) unless it is open."""
        from agent_common import centre
        opened, folded = self.b.rows("open", win), self.b.rows("minimized", win)
        if len(opened) > len(folded):
            return True
        spot = folded[-1].rect() if folded else (self.b.wait_row("icon", win) or folded[-1]).rect()
        self.b.x.click(*centre(spot))
        return self.b.wait(lambda: len(self.b.rows("open", win)) > len(opened), 10)

    def prompt(self, key: str, win: int, headless: bool) -> bool:
        """Types `key` in window `win`'s drawer; headless: minimizes it, then lets the call come.
        Window `win` must be the topmost window (no window manager here)."""
        if not self.open_drawer(win):
            return False
        for ch in key:
            self.b.x.key({" ": "space"}.get(ch, ch), settle=0.005)
        self.b.x.key("Return")
        if headless:
            minus = self.b.wait_row("minus", win, timeout=10)
            if minus is None:
                return False
            before = len(self.b.rows("minimized", win))
            from agent_common import centre
            self.b.x.click(*centre(minus.rect()))
            if not self.b.wait(lambda: len(self.b.rows("minimized", win)) > before, 10):
                return False
        self.gated.release(key)
        return True

    def cards(self, win: int | None = None):
        return self.b.rows("approval", win)

    def card_rows(self, kind: str, card: str):
        return [r for r in self.b.rows(kind, 1) if r.fields[0] == card]

    def card_rect(self, card: str, button: str):
        rects = [r for r in self.card_rows("approvalrect", card) if r.fields[1] == button]
        return rects[-1].rect(2) if rects else None

    def click_card(self, card: str, button: str, rect=None) -> bool:
        rect = rect or self.card_rect(card, button)
        if rect is None:
            return False
        from agent_common import centre
        self.b.x.click(*centre(rect))
        return True

    def open_main_by_hand(self) -> bool:
        """No notification to activate: the user raises window 1 and clicks its icon."""
        self.raise_first()
        if self.b.rows("open", 1):
            return True
        icon = self.b.rows("icon", 1)
        if not icon:
            return False
        from agent_common import centre
        self.b.x.click(*centre(icon[-1].rect()))
        return self.b.wait(lambda: self.b.rows("open", 1) != [], 10)

    # --- the API side -----------------------------------------------------------------------
    def answer_for(self, key: str, timeout: float = 30.0):
        """The tool_result block the model got for the prompt holding `key`, once it arrives:
        one in a user turn after that prompt (a later prompt's request repeats older ones)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            block = self._answer(key)
            if block is not None:
                return block
            time.sleep(0.1)
        return None

    def _answer(self, key: str):
        for entry in self.fake.api.messages_requests():
            users = [m for m in (entry.get("body") or {}).get("messages") or [] if m.get("role") == "user"]
            asked = [i for i, m in enumerate(users) if key in json.dumps(m) and "tool_result" not in json.dumps(m)]
            if not asked:
                continue
            for m in users[asked[-1] + 1:]:
                content = m.get("content")
                blocks = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"] \
                    if isinstance(content, list) else []
                if blocks:
                    return blocks[0]
        return None

    def answered(self, key: str) -> bool:
        return self._answer(key) is not None


def nav(url: str) -> dict:
    return {"name": NAVIGATE, "input": {"url": url}}


RELOAD_CALL = {"name": RELOAD, "input": {}}


def wait_card(w: World, check, label: str, count: int = 1):
    ok = w.b.wait(lambda: len(w.cards(1)) >= count, 60)
    check(ok, f"{label}: {count} card(s) in the main window's drawer ({[r.fields for r in w.cards()]})", w.b)
    return w.cards(1)[count - 1] if ok else None


def no_card_elsewhere(w: World, check, label: str) -> None:
    others = [r for r in w.cards() if r.win != 1]
    check(others == [], f"{label}: no card in any other window's drawer ({[(r.win, r.fields) for r in others]})")


def check_notify(w: World, check, label: str, count: int, url: str) -> list[dict]:
    if w.notifications is None:
        return []
    ok = w.b.wait(lambda: len(w.notifications.notifies()) >= count, 15)
    got = w.notifications.notifies()
    check(ok and len(got) == count, f"{label}: {count} desktop notification(s) ({len(got)})")
    for n in got:
        check((n["app_name"], n["summary"], n["body"]) == ("zigBrowser", TITLE, BODY),
              f"{label}: the notification's fixed text ({n['app_name']!r}, {n['summary']!r}, {n['body']!r})")
        check(n["actions"][0::2] == ["default"], f"{label}: its only action is default ({n['actions']})")
        text = json.dumps(n)
        leaked = [s for s in (CANARY, url, "two.html", "window-", *(r.fields[4] for r in w.cards())) if s in text]
        check(leaked == [], f"{label}: nothing of the step in the notification ({leaked})")
    return got


# --- the cases ---------------------------------------------------------------------------------
def case_interactive(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "interactive", {"navhere": None})
    try:
        if not w.ready(check):
            return
        w.gated.calls["navhere"] = nav(w.pages.target())
        w.prompt("navhere", 1, headless=False)
        block = w.answer_for("navhere", 60)
        if not check(block is not None, "interactive: a tool_result reached the API", w.b):
            return
        check(not block.get("is_error"), f"interactive, conditional: navigate ran at once ({result_text(block)[:120]!r})")
        check(w.b.wait(lambda: w.path(1) == f"/two.html#{CANARY}", 10), f"window 1 is on the target ({w.path(1)})")
        check(w.cards() == [], f"no card in any drawer ({[r.fields for r in w.cards()]})")
        check(w.notifications.notifies() == [], "no desktop notification")
    finally:
        w.close()


def case_headless(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "headless", {"navtwo": None})
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        url = w.pages.target()
        w.gated.calls["navtwo"] = nav(url)
        if not check(w.prompt("navtwo", 2, headless=True), "window 2's drawer is minimized before the call", w.b):
            return
        card = wait_card(w, check, "headless")
        if card is None:
            return
        cid = card.fields[0]
        check(card.fields[1:] == ("navigate", w.pages.origin, "-", digest(NAVIGATE, 2, url, w.doc(2))),
              f"the card names navigate, window 2's origin, no account and the params' digest ({card.fields})")
        check(("approval", f"Claude wants to open {url} in window 2.") in life.bubbles(w.b, 1),
              f"the card's text ({life.bubbles(w.b, 1)})")
        no_card_elsewhere(w, check, "headless")
        notes = check_notify(w, check, "headless", 1, url)
        time.sleep(2.0)
        check(not w.answered("navtwo"), "the model has no answer while the card waits")
        check(w.path(2) == "/pop.html", f"window 2 is not navigated while its card waits ({w.path(2)})")
        if not notes:
            return
        nid = notes[0]["id"]
        opens = len(w.b.rows("open", 1))
        for forged in ((nid + 7, "default", False), (nid, "approve", False), (nid, "default", True)):
            w.notifications.invoke(*forged)
        time.sleep(1.5)
        check(len(w.b.rows("open", 1)) == opens and not w.card_rows("approvalstate", cid),
              "another id, another action or a non-owner's signal opens nothing and changes no card")
        w.notifications.invoke(nid, "default")
        check(w.b.wait(lambda: len(w.b.rows("open", 1)) > opens, 10), "activating it opens window 1's drawer", w.b)
        check(w.b.wait(w.first_on_top, 5), "and presents window 1")
        w.notifications.invoke(nid, "default")
        time.sleep(1.0)
        check(not w.card_rows("approvalstate", cid) and not w.card_rows("approvalend", cid),
              "activation, twice, changes no card")
        if not check(w.b.wait(lambda: w.click_card(cid, "approve"), 10), "the Approve button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalstate", cid)] == ["approved"], 10),
              "Approve: approvalstate approved", w.b)
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["done"], 30),
              "then approvalend done, once", w.b)
        block = w.answer_for("navtwo", 30)
        check(block is not None and not block.get("is_error"), f"the model gets the navigation's answer ({block})")
        check(w.b.wait(lambda: w.path(2) == f"/two.html#{CANARY}", 10), f"window 2 is on the target ({w.path(2)})")
        check(w.path(1) == "/one.html", f"window 1 is not navigated ({w.path(1)})")
    finally:
        w.close()


def case_deny(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "deny", {"navdeny": None})
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        w.gated.calls["navdeny"] = nav(w.pages.target())
        w.prompt("navdeny", 2, headless=True)
        card = wait_card(w, check, "deny")
        notes = check_notify(w, check, "deny", 1, w.pages.target())
        if card is None or not notes:
            return
        cid = card.fields[0]
        w.notifications.invoke(notes[0]["id"], "default")
        if not check(w.b.wait(lambda: w.click_card(cid, "deny"), 15), "the Deny button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["denied"], 10),
              "Deny: approvalend denied, once", w.b)
        check(not w.card_rows("approvalstate", cid), "no approvalstate after Deny")
        block = w.answer_for("navdeny", 30)
        check(block is not None and block.get("is_error") is True and DENIED in result_text(block),
              f"the model is told it was denied ({block})")
        time.sleep(1.0)
        check(w.path(2) == "/pop.html", f"window 2 is not navigated ({w.path(2)})")
    finally:
        w.close()


def case_reload(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "reload", {"reloadtwo": RELOAD_CALL})
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        before = w.loads(2)
        w.prompt("reloadtwo", 2, headless=True)
        card = wait_card(w, check, "reload")
        notes = check_notify(w, check, "reload", 1, w.pages.target())
        if card is None or not notes:
            return
        cid = card.fields[0]
        check(card.fields[1:] == ("reload", w.pages.origin, "-", digest(RELOAD, 2, doc=w.doc(2))),
              f"the reload card ({card.fields})")
        check(("approval", "Claude wants to reload window 2.") in life.bubbles(w.b, 1), f"its text ({life.bubbles(w.b, 1)})")
        time.sleep(1.5)
        check(w.loads(2) == before, "window 2 is not reloaded while its card waits")
        w.notifications.invoke(notes[0]["id"], "default")
        if not check(w.b.wait(lambda: w.click_card(cid, "approve"), 15), "the Approve button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["done"], 30),
              "Approve: approvalend done", w.b)
        check(w.b.wait(lambda: w.loads(2) == before + 1, 10), f"window 2 reloaded once ({before} -> {w.loads(2)})")
        block = w.answer_for("reloadtwo", 30)
        check(block is not None and not block.get("is_error"), f"the model gets the reload's answer ({block})")
    finally:
        w.close()


def case_main_close(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "main-close", {"nava": None, "navb": None, "navlater": None})
    try:
        url = w.pages.target()
        for key in ("nava", "navb", "navlater"):
            w.gated.calls[key] = nav(url)
        # Each popup opens on top of the one before: each prompt is typed while its window is topmost.
        if not (w.ready(check) and w.popup(check, 2) and w.prompt("nava", 2, headless=True)
                and w.popup(check, 3) and w.prompt("navb", 3, headless=True)):
            return
        if wait_card(w, check, "main-close", count=2) is None:
            return
        check(sorted(r.fields[4] for r in w.cards(1)) == sorted([digest(NAVIGATE, 2, url, w.doc(2)), digest(NAVIGATE, 3, url, w.doc(3))]),
              "one card for each window's call, both in window 1's drawer")
        check_notify(w, check, "main-close", 2, url)
        w.close_first()
        check(w.b.wait(lambda: len(w.b.zb.page.list()["pages"]) == 2, 15), "window 1 closed; windows 2 and 3 stay", w.b)
        a, b = w.answer_for("nava", 30), w.answer_for("navb", 30)
        for name, block in (("window 2", a), ("window 3", b)):
            check(block is not None and block.get("is_error") is True and CANCELLED in result_text(block),
                  f"{name}'s call is cancelled when the main window closes ({block})")
        time.sleep(1.0)
        check((w.path(2), w.path(3)) == ("/pop.html", "/pop.html"), f"neither window navigated ({w.path(2)}, {w.path(3)})")
        cards = len(w.cards())
        started = time.monotonic()
        w.prompt("navlater", 3, headless=True)
        later = w.answer_for("navlater", 60)
        check(later is not None and later.get("is_error") is True and CANCELLED in result_text(later),
              f"with no main window, a carded call is cancelled ({later})")
        check(later is not None and time.monotonic() - started < 50, "at once, not after a card's time")
        check(len(w.cards()) == cards, "and no card appears in any window")
        check(len(w.notifications.notifies()) == 2, "and no notification is raised")
        check(w.path(3) == "/pop.html", f"window 3 is not navigated ({w.path(3)})")
    finally:
        w.close()


def case_bound_close(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "bound-close", {"navgone": None})
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        w.gated.calls["navgone"] = nav(w.pages.target())
        w.prompt("navgone", 2, headless=True)
        card = wait_card(w, check, "bound-close")
        notes = check_notify(w, check, "bound-close", 1, w.pages.target())
        if card is None or not notes:
            return
        cid = card.fields[0]
        w.notifications.invoke(notes[0]["id"], "default")
        if not check(w.b.wait(lambda: w.card_rect(cid, "approve") is not None, 15), "the Approve button is drawn", w.b):
            return
        spot = w.card_rect(cid, "approve")
        w.b.zb.call("page.close", {"window_id": "window-2"})
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["revoked"], 15),
              "the bound window closed: approvalend revoked", w.b)
        w.click_card(cid, "approve", spot)
        time.sleep(1.5)
        check(not w.card_rows("approvalstate", cid), "a click where Approve was approves nothing")
        late = [result_text(bl) for e in w.fake.api.messages_requests() for bl in tool_results(e)]
        check(not any(t.startswith(("{", "[")) for t in late), f"no answer from the browser for the closed window ({late})")
    finally:
        w.close()


def case_expiry(binary: Path, tmp: Path, check) -> None:
    # The dead bus: the notification cannot be delivered, and the card still waits its 120 s.
    w = World(binary, tmp, "expiry", {"navlate": None}, notifier="dead")
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        w.gated.calls["navlate"] = nav(w.pages.target())
        w.prompt("navlate", 2, headless=True)
        card = wait_card(w, check, "expiry")
        if card is None:
            return
        cid = card.fields[0]
        shown = time.monotonic()
        check(w.b.wait(lambda: w.card_rows("approvalend", cid) != [], 150), "the card ends", w.b)
        took = time.monotonic() - shown
        check([r.fields[1] for r in w.card_rows("approvalend", cid)] == ["expired"], "approvalend expired, once")
        check(115 <= took <= 135, f"at its 120 s ({took:.1f} s)")
        block = w.answer_for("navlate", 30)
        text = result_text(block) if block else ""
        check(block is not None and block.get("is_error") is True and NOT_APPROVED in text and HELPER_TIMEOUT not in text,
              f"the model is told it was not approved in time, not the helper's timeout ({text[:120]!r})")
        check(w.path(2) == "/pop.html", f"window 2 is not navigated ({w.path(2)})")
    finally:
        w.close()


def case_no_notifier(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "no-notifier", {"navquiet": None}, notifier="none")
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        w.gated.calls["navquiet"] = nav(w.pages.target())
        w.prompt("navquiet", 2, headless=True)
        card = wait_card(w, check, "no-notifier")
        if card is None:
            return
        cid = card.fields[0]
        time.sleep(2.0)
        check(not w.card_rows("approvalend", cid) and w.path(2) == "/pop.html",
              "no notification server: the card still waits and nothing ran")
        if not check(w.open_main_by_hand(), "the user opens window 1's drawer by hand", w.b):
            return
        if not check(w.b.wait(lambda: w.click_card(cid, "approve"), 15), "the Approve button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["done"], 30),
              "Approve still works: approvalend done", w.b)
        check(w.b.wait(lambda: w.path(2) == f"/two.html#{CANARY}", 10), f"window 2 is on the target ({w.path(2)})")
    finally:
        w.close()


def case_store_yes(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "store-yes", {"navyes": None}, store=b"yes\n")
    try:
        if not w.ready(check):
            return
        url = w.pages.target()
        w.gated.calls["navyes"] = nav(url)
        w.prompt("navyes", 1, headless=False)
        card = wait_card(w, check, "store yes, interactive")
        if card is None:
            return
        cid = card.fields[0]
        check(card.fields[4] == digest(NAVIGATE, 1, url, w.doc(1)), "the card is window 1's own call")
        check_notify(w, check, "store yes", 1, url)
        time.sleep(1.0)
        check(w.path(1) == "/one.html", "nothing ran before Approve")
        if not check(w.b.wait(lambda: w.click_card(cid, "approve"), 15), "the Approve button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["done"], 30),
              "approvalend done", w.b)
        check(w.b.wait(lambda: w.path(1) == f"/two.html#{CANARY}", 10), f"window 1 is on the target ({w.path(1)})")
    finally:
        w.close()


def case_store_no(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "store-no", {"navno": None}, store=b"no\n")
    try:
        if not (w.ready(check) and w.popup(check, 2)):
            return
        w.gated.calls["navno"] = nav(w.pages.target())
        w.prompt("navno", 2, headless=True)
        block = w.answer_for("navno", 60)
        check(block is not None and not block.get("is_error"), f"store no, headless: navigate ran at once ({block})")
        check(w.b.wait(lambda: w.path(2) == f"/two.html#{CANARY}", 10), f"window 2 is on the target ({w.path(2)})")
        check(w.cards() == [] and w.notifications.notifies() == [], "no card and no notification")
    finally:
        w.close()


def case_store_corrupt(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "store-corrupt", {"navcorrupt": None}, store=b"no\n", store_mode=0o644)
    try:
        if not w.ready(check):
            return
        w.gated.calls["navcorrupt"] = nav(w.pages.target())
        w.prompt("navcorrupt", 1, headless=False)
        card = wait_card(w, check, "a 0644 store, interactive")
        check(w.b.wait(lambda: ("system", UNREADABLE) in life.bubbles(w.b, 1), 10),
              f"the drawer says the setting is unreadable ({life.bubbles(w.b, 1)})")
        if card is None:
            return
        cid = card.fields[0]
        if not check(w.b.wait(lambda: w.click_card(cid, "deny"), 15), "the Deny button is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", cid)] == ["denied"], 10),
              "approvalend denied", w.b)
        check(w.path(1) == "/one.html", f"window 1 is not navigated ({w.path(1)})")
        check(oct(w.store.stat().st_mode & 0o777) == oct(0o644) and w.store.read_bytes() == b"no\n",
              "the store is left as it was")
    finally:
        w.close()


def case_schema(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "schema", {"navpolicy": None, "reloadwindow": {"name": RELOAD, "input": {"window_id": "window-1"}}})
    try:
        if not w.ready(check):
            return
        w.gated.calls["navpolicy"] = {"name": NAVIGATE, "input": {"url": w.pages.target(), "navigate_approval": "no"}}
        for key, field in (("navpolicy", "navigate_approval"), ("reloadwindow", "window_id")):
            before = w.loads(1)
            w.prompt(key, 1, headless=False)
            block = w.answer_for(key, 60)
            text = result_text(block) if block else ""
            check(block is not None and block.get("is_error") is True and field in text and "No such tool" not in text,
                  f"{key}: the tool's input schema refuses {field} ({text[:160]!r})")
            time.sleep(1.0)
            check(w.path(1) == "/one.html" and w.loads(1) == before, f"{key}: window 1 is unchanged")
        check(w.cards() == [], "no card")
    finally:
        w.close()


def case_socket(binary: Path, tmp: Path, check) -> None:
    w = World(binary, tmp, "socket", {})
    try:
        if not w.ready(check):
            return
        for method, params in (("settings.navigate_approval", {"value": "no"}), ("agent.navigate_approval", {"value": "no"}),
                               ("settings.set", {"name": "navigate_approval", "value": "no"}),
                               ("approval.approve", {"card": 1})):
            code = None
            try:
                w.b.zb.call(method, params)
            except Exception as exc:  # noqa: BLE001 - the SDK raises on the error reply
                code = getattr(exc, "code", None)
            check(code == -32601, f"{method} is -32601 ({code})")
        check(not w.store.exists(), "the store is unchanged (still missing)")
    finally:
        w.close()


CASES = {
    "interactive": case_interactive,
    "headless": case_headless,
    "deny": case_deny,
    "reload": case_reload,
    "main-close": case_main_close,
    "bound-close": case_bound_close,
    "expiry": case_expiry,
    "no-notifier": case_no_notifier,
    "store-yes": case_store_yes,
    "store-no": case_store_no,
    "store-corrupt": case_store_corrupt,
    "schema": case_schema,
    "socket": case_socket,
}


def main() -> int:
    if "--sealed-child" not in sys.argv:
        done = subprocess.run(["/usr/bin/bwrap", "--unshare-net", "--die-with-parent", "--dev-bind", "/", "/",
                               "--proc", "/proc", "--", sys.executable, str(Path(__file__).resolve()),
                               "--sealed-child", *sys.argv[1:]])
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
