#!/usr/bin/env python3
"""S8 decision 16, part 4 red (RoseCat f87368e on ebe6529): through the real chain, a waiting
navigate card is bound to its prompt and to the document it describes (plan decision 8, S9.3).

The same world as agent_navigate_approval_test.py (the real binary on its own Xvfb, the real
helper and CLI against the fake Messages API, sealed, a private bus with a fake notification
server). Window 2 asks to navigate in headless mode, so its card waits in window 1's drawer;
then one transition happens, and only then is Approve clicked (when it still can be):

- stop: window 2's own Stop ends its prompt. The card ends `revoked` at once, its buttons go;
  a click where Approve was approves nothing; window 2 is not navigated. A newer prompt then
  gets a card of its own (the store says `yes`), and only that one's Approve navigates.
- user-navigation: the page in window 2 goes to another document by itself. Approve:
  `approvalstate approved`, then `approvalend changed`; window 2 stays on the document it
  moved to; the model gets an error.
- reload: window 2 is reloaded (the socket's page.reload). Approve: `approvalend changed`,
  and window 2 loaded exactly once more (the reload), never again.
- crash: window 2 (a noopener popup of another origin: a web process of its own) has that
  process killed. Approve: `approvalend crashed`; nothing is loaded in window 2.
- recover: window 2's page freezes; page.recover (both phases) ends its process and reloads
  it. Approve: `approvalend changed`; window 2 loaded once more (the recovery), never again.
- helper-kill: the helper (chat) is killed. The card ends `revoked`; a click where Approve was
  approves nothing; window 2 is not navigated.

Signals go only to this browser's own descendants (its WebKitWebProcess and its helper, each
pid checked to be an int > 1), and the whole test runs in a PID namespace of its own. Exit 1
when Xvfb, xauth, bwrap, the venv or the binary is missing. Unregistered until its green."""

from __future__ import annotations

import http.server
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import agent_host_lifecycle_test as life  # noqa: E402
from agent_navigate_approval_test import CANARY, World, check_notify, nav, wait_card  # noqa: E402
from agent_tools_test import result_text  # noqa: E402

SPIN_PAGE = """<!doctype html><meta charset="utf-8"><title>solo</title>
<button id="spin" style="position:fixed;left:20px;top:20px;width:300px;height:100px"
 onclick="while (true) {}">spin</button>
<script>
sessionStorage.loads = String(Number(sessionStorage.loads || 0) + 1);
window.__ready = true;
</script>"""


class Other:
    """Another loopback origin: /solo.html, whose button freezes its page, and a load count."""

    def __init__(self) -> None:
        other = self
        self.hits = 0

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 - the stdlib's name
                if self.path.split("?")[0] == "/solo.html":
                    other.hits += 1
                body = SPIN_PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        # Another site, not just another port: its noopener popup gets a web process of its own.
        self.origin = f"http://localhost:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def web_processes(browser: int | None) -> set[int]:
    out = set()
    for pid in life.descendants(browser) if browser else []:
        try:
            if Path(f"/proc/{pid}/comm").read_text().strip().startswith("WebKitWebProces"):
                out.add(pid)
        except OSError:
            pass
    return out


def kill(pid: int | None, check, what: str) -> bool:
    """SIGKILL to one real descendant of the browser (never a guessed or mocked pid)."""
    if not (isinstance(pid, int) and pid > 1):
        return check(False, f"{what}: no usable pid ({pid!r})")
    os.kill(pid, signal.SIGKILL)
    return True


def raise_other(w: World) -> None:
    """What clicking window 2's title bar does: it goes on top (no window manager here)."""
    import ctypes
    x = w.b.x
    others = [t[0] for t in x.toplevels() if t[0] != w.first_toplevel]
    if others:
        x._x.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x._x.XRaiseWindow(x._dpy, others[-1])
        # And the keyboard, as a window manager's click to front gives it (RevertToParent, now).
        x._x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        x._x.XSetInputFocus(x._dpy, others[-1], 2, 0)
        x._x.XFlush(x._dpy)
        time.sleep(0.3)


def headless_card(w: World, check, key: str, solo: bool = False):
    """Window 2 (a same-origin popup, or with `solo` a noopener popup of another origin)
    asks to navigate with its drawer minimized; its card, shown in window 1."""
    url = w.pages.target()
    w.gated.calls[key] = nav(url)
    if not w.ready(check):
        return None
    if solo:
        before = web_processes(w.b.browser_pid())
        w.b.ev(f"(window.open({json.dumps(w.other.origin + '/solo.html')}, '_blank', 'noopener'), 1)")
        if not check(w.b.wait(lambda: w.b.rows("icon", 2) != [], 20) and w.b.wait_page("window-2"), "window 2 (solo) is open", w.b):
            return None
        w.solo_process = web_processes(w.b.browser_pid()) - before
        if not check(len(w.solo_process) == 1, f"window 2 has a web process of its own ({w.solo_process})"):
            return None
    elif not w.popup(check, 2):
        return None
    if not check(w.prompt(key, 2, headless=True), "window 2's drawer is minimized before the call", w.b):
        return None
    return wait_card(w, check, key)


def open_main(w: World, check) -> bool:
    notes = check_notify(w, check, "main", 1, w.pages.target())
    if not notes:
        return False
    w.notifications.invoke(notes[0]["id"], "default")
    return check(w.b.wait(lambda: w.card_rect(w.cid, "approve") is not None, 15), "window 1's drawer shows the card's buttons", w.b)


def approve_ends(w: World, check, label: str, ending: str) -> None:
    w.click_card(w.cid, "approve")
    check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalstate", w.cid)] == ["approved"], 10),
          f"{label}: Approve still wins the card's consent", w.b)
    check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", w.cid)] == [ending], 30),
          f"{label}: then approvalend {ending}, once", w.b)
    block = w.answer_for(w.key, 30)
    check(block is not None and block.get("is_error") is True, f"{label}: the model gets an error ({block})")


def start(binary: Path, tmp: Path, label: str, key: str, store: bytes | None = None, later: tuple[str, ...] = ()) -> World:
    w = World(binary, tmp, label, {k: None for k in (key, *later)}, store=store)
    w.other = Other()
    w.key = key
    return w


def finish(w: World) -> None:
    try:
        w.close()
    finally:
        w.other.close()


def case_stop(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-stop", "navstop", store=b"yes\n", later=("navnewer",))
    try:
        card = headless_card(w, check, "navstop")
        if card is None:
            return
        w.cid = card.fields[0]
        if not open_main(w, check):
            return
        spot = w.card_rect(w.cid, "approve")
        # The user brings window 2 to the front: its drawer opens, and its Stop ends the prompt.
        raise_other(w)
        if not check(w.open_drawer(2), "window 2's drawer opens", w.b):
            return
        stop = w.b.wait_row("stop", 2, count=len(w.b.rows("open", 2)), timeout=10)
        from agent_common import centre
        w.b.x.click(*centre(stop.rect()))
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", w.cid)] == ["revoked"], 15),
              "Stop: the card ends revoked", w.b)
        w.raise_first()
        w.click_card(w.cid, "approve", spot)
        time.sleep(1.5)
        check(not w.card_rows("approvalstate", w.cid), "a click where Approve was approves nothing")
        check(w.path(2) == "/pop.html", f"window 2 is not navigated ({w.path(2)})")
        # A newer prompt: a card of its own; only its Approve navigates.
        newer_url = w.pages.url("two") + "#newer"
        w.gated.calls["navnewer"] = nav(newer_url)
        raise_other(w)
        # The click on Stop left the keyboard on it: the drawer folds, and reopening it puts
        # the keyboard back in its input (drawer_open), where the newer prompt is typed.
        minus = w.b.rows("minus", 2)[-1]
        folded = len(w.b.rows("minimized", 2))
        w.b.x.click(*centre(minus.rect()))
        w.b.wait(lambda: len(w.b.rows("minimized", 2)) > folded, 10)
        if not check(w.prompt("navnewer", 2, headless=True), "a newer prompt in window 2", w.b):
            return
        if wait_card(w, check, "navnewer", count=2) is None:
            return
        newer = w.cards(1)[1].fields[0]
        check(newer != w.cid, f"the newer prompt's card is a new card ({newer})")
        w.raise_first()
        notes = w.notifications.notifies()
        w.notifications.invoke(notes[-1]["id"], "default")
        if not check(w.b.wait(lambda: w.click_card(newer, "approve"), 15), "the newer card's Approve is drawn", w.b):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", newer)] == ["done"], 30),
              "the newer card ends done", w.b)
        check(w.b.wait(lambda: w.path(2) == "/two.html#newer", 10), f"window 2 is on the newer target only ({w.path(2)})")
        check(not w.card_rows("approvalstate", w.cid), "the stopped card never approved")
    finally:
        finish(w)


def case_user_navigation(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-nav", "navmoved")
    try:
        card = headless_card(w, check, "navmoved")
        if card is None:
            return
        w.cid = card.fields[0]
        w.b.ev("(location.href = '/pop.html?moved', 1)", "window-2")
        if not check(w.b.wait(lambda: w.path(2) == "/pop.html" and "moved" in w.b.ev("location.search", "window-2"), 15),
                     "the page in window 2 moved to another document", w.b):
            return
        if not open_main(w, check):
            return
        approve_ends(w, check, "user-navigation", "changed")
        time.sleep(1.0)
        check(w.b.ev("location.search", "window-2") == "?moved" and CANARY not in w.path(2),
              f"window 2 stays on the document it moved to ({w.path(2)})")
    finally:
        finish(w)


def case_reload(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-reload", "navreload")
    try:
        card = headless_card(w, check, "navreload")
        if card is None:
            return
        w.cid = card.fields[0]
        before = w.loads(2)
        w.b.zb.call("page.reload", {"window_id": "window-2"})
        if not check(w.b.wait(lambda: w.b.wait_page("window-2") and w.loads(2) == before + 1, 15), "window 2 was reloaded", w.b):
            return
        if not open_main(w, check):
            return
        approve_ends(w, check, "reload", "changed")
        time.sleep(1.0)
        check(w.loads(2) == before + 1 and w.path(2) == "/pop.html", f"window 2 loaded once more only ({w.loads(2)})")
    finally:
        finish(w)


def case_crash(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-crash", "navcrash")
    try:
        card = headless_card(w, check, "navcrash", solo=True)
        if card is None:
            return
        w.cid = card.fields[0]
        hits = w.other.hits
        if not kill(next(iter(w.solo_process)), check, "window 2's web process"):
            return
        check(w.b.wait(lambda: any(p.get("window_id") == "window-2" and p.get("crashed") for p in w.b.zb.page.list()["pages"]), 15),
              "window 2 is reported crashed", w.b)
        if not open_main(w, check):
            return
        approve_ends(w, check, "crash", "crashed")
        time.sleep(1.0)
        check(w.other.hits == hits, f"nothing was loaded in window 2 ({hits} -> {w.other.hits})")
    finally:
        finish(w)


def case_recover(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-recover", "navrecover")
    try:
        card = headless_card(w, check, "navrecover", solo=True)
        if card is None:
            return
        w.cid = card.fields[0]
        hits = w.other.hits
        from zigbrowser import ZigBrowser

        def freeze() -> None:
            client = ZigBrowser(socket_path=str(w.b.socket))
            client.connect()
            try:
                client.call("dom.click", {"selector": "css=#spin", "window_id": "window-2",
                                          "options": {"input": "native", "timeout_ms": 30_000}})
            except Exception:  # noqa: BLE001 - recovery cancels it
                pass

        threading.Thread(target=freeze, daemon=True).start()
        health = lambda: {p["window_id"]: p for p in w.b.zb.call("page.health", {})["pages"]}  # noqa: E731
        if not check(w.b.wait(lambda: health()["window-2"]["responsive"] is False, 20), "window 2 froze", w.b):
            return
        first = w.b.zb.call("page.recover", {"window_id": "window-2"})
        acknowledge = sorted(x["window_id"] for x in first.get("at_risk", []))
        w.b.zb.call("page.recover", {"window_id": "window-2", "incident": first.get("incident"), "acknowledge": acknowledge})
        if not check(w.b.wait(lambda: w.other.hits == hits + 1 and w.b.wait_page("window-2"), 20), "window 2 was recovered (reloaded)", w.b):
            return
        if not open_main(w, check):
            return
        approve_ends(w, check, "recover", "changed")
        time.sleep(1.0)
        check(w.other.hits == hits + 1, f"window 2 loaded once more only, by the recovery ({w.other.hits - hits})")
    finally:
        finish(w)


def case_helper_kill(binary: Path, tmp: Path, check) -> None:
    w = start(binary, tmp, "stale-helper", "navhelper")
    try:
        card = headless_card(w, check, "navhelper")
        if card is None:
            return
        w.cid = card.fields[0]
        if not open_main(w, check):
            return
        spot = w.card_rect(w.cid, "approve")
        if not kill(life.chat_pid(w.b.browser_pid()), check, "the helper"):
            return
        check(w.b.wait(lambda: [r.fields[1] for r in w.card_rows("approvalend", w.cid)] == ["revoked"], 20),
              "the helper died: the card ends revoked", w.b)
        w.click_card(w.cid, "approve", spot)
        time.sleep(1.5)
        check(not w.card_rows("approvalstate", w.cid), "a click where Approve was approves nothing")
        check(w.path(2) == "/pop.html", f"window 2 is not navigated ({w.path(2)})")
    finally:
        finish(w)


CASES = {
    "stop": case_stop,
    "user-navigation": case_user_navigation,
    "reload": case_reload,
    "crash": case_crash,
    "recover": case_recover,
    "helper-kill": case_helper_kill,
}


def main() -> int:
    if "--pid-ns" not in sys.argv and "--sealed-child" not in sys.argv:
        # The signals this test sends stay inside a PID namespace of its own.
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
