#!/usr/bin/env python3
"""Chat drawer S2.5, threat test T1: hostile pages cannot reach or cover the
drawer (thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md,
section 9).

With the drawer on, a hostile top page (tests/fixtures/agent/hostile/),
its same-origin iframe, its cross-origin iframe (a second fixture port) and
a related popup each probe the page world: no zbAgent, zbDrawer, zbSecrets,
zbAuth or zbBroker message handler exists, and zbHost answers every
agent.*, drawer.*, secrets.* and broker.* command with UnknownCommand.

The top page also lays a full-viewport `position:fixed; z-index:2147483647`
cover over everything. Real X clicks still open the drawer through the
icon and minimize it through '-', and the cover sees none of those clicks
(while it does see a click on the page outside the drawer). The drawer's
widget tree (`DRAWER tree`) holds GTK types only: no WebKitWebView.

Exit 1 (never 77) when Xvfb, xauth, xwd, libXtst or the binary is missing."""

from __future__ import annotations

import functools
import http.server
import json
import threading
from pathlib import Path

from agent_common import REPO, Browser, Checks, centre, run_main

HOSTILE = REPO / "tests/fixtures/agent/hostile"
NAMES = ["zbAgent", "zbDrawer", "zbSecrets", "zbAuth", "zbBroker"]
COMMANDS = ["agent.ping", "agent.prompt", "drawer.open", "drawer.minimize", "secrets.get", "secrets.set", "broker.call"]


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass


def serve() -> tuple[http.server.ThreadingHTTPServer, int]:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(HOSTILE)))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def check_probe(check: Checks, b: Browser, where: str, result) -> None:
    if not check(isinstance(result, dict), f"{where}: the probe finished ({result!r})", b):
        return
    handlers = result.get("handlers", {})
    check(all(handlers.get(n) == "undefined" for n in NAMES), f"{where}: no agent/drawer/secrets handler ({handlers})", b)
    zbhost = result.get("zbhost", {})
    check(sorted(zbhost) == sorted(COMMANDS) and all(v in ("rejected:UnknownCommand", "no-zbHost") for v in zbhost.values()),
          f"{where}: zbHost knows no agent/drawer/secrets/broker command ({zbhost})", b)


def poll_json(b: Browser, expression: str, window: str = "window-1"):
    """JSON.parse of `expression` once it is defined, else None."""
    got = None

    def ready() -> bool:
        nonlocal got
        try:
            text = b.ev(f"JSON.stringify({expression})", window)
        except Exception:  # noqa: BLE001 - still loading
            return False
        if text in (None, "undefined"):
            return False
        got = json.loads(text)
        return got is not None
    b.wait(ready, 15)
    return got


def run(binary: Path, tmp: Path, check: Checks) -> None:
    server_a, port_a = serve()
    server_b, port_b = serve()
    top = f"http://127.0.0.1:{port_a}/top.html?cross=http://localhost:{port_b}"
    b = Browser(binary, tmp, "hostile", ["--agent-drawer", "on"], profile=tmp / "p-hostile", url=top)
    try:
        tree = b.wait_row("tree", 1)
        if check(tree is not None, "the drawer's widget tree is reported (DRAWER tree)", b):
            types = tree.fields[0].split(",")
            check(all(t.startswith("Gtk") for t in types) and not any("WebKit" in t for t in types),
                  f"the drawer subtree holds GTK types only, no WebKitWebView ({types})", b)
        check(b.wait_page(), "hostile top page loaded", b)
        check_probe(check, b, "top page", poll_json(b, "window.__result"))
        b.wait(lambda: sorted(poll_json(b, "Object.keys(window.__frames)") or []) == ["cross", "same"], 15)
        frames = poll_json(b, "window.__frames") or {}
        check(sorted(frames) == ["cross", "same"], f"both iframes reported ({sorted(frames)})", b)
        for name in ("same", "cross"):
            check_probe(check, b, f"{name}-origin iframe", frames.get(name))

        b.ev("(window.open('frame.html'), 1)")
        check(b.wait(lambda: len(b.zb.page.list()["pages"]) == 2, 15), "the related popup opened", b)
        check_probe(check, b, "related popup", poll_json(b, "window.__result", "window-2"))
        check(b.wait_row("icon", 2) is not None, "the popup has its own icon", b)
        b.zb.call("page.close", {"window_id": "window-2"})
        check(b.wait(lambda: len(b.zb.page.list()["pages"]) == 1, 10), "the popup closed", b)

        # The cover is live: a click on the page outside the drawer reaches it.
        b.x.click(20, 20)
        check(b.wait(lambda: b.ev("window.__overlay_clicks") == 1, 5), "the cover takes a click on the page", b)
        icon = b.wait_row("icon", 1)
        if not check(icon is not None, "icon row", b):
            return
        b.x.click(*centre(icon.rect()))
        opened, minus = b.wait_row("open", 1), b.wait_row("minus", 1)
        check(opened is not None and minus is not None, "a real click on the icon opens the drawer under the cover", b)
        if minus is not None:
            b.x.click(*centre(minus.rect()))
            check(b.wait_row("anim", 1) is not None and b.wait_row("minimized", 1) is not None,
                  "a real click on '-' minimizes the drawer under the cover", b)
        check(b.ev("window.__overlay_clicks") == 1, f"the cover saw none of the drawer clicks "
                                                    f"({b.ev('window.__overlay_clicks') - 1} reached it)", b)
    finally:
        b.stop()
        check(b.gtk_complaints() == [], f"{b.label}: no GTK warning or critical ({b.gtk_complaints()[:3]})", b)
        for server in (server_a, server_b):
            server.shutdown()
            server.server_close()


def main() -> int:
    return run_main(__doc__, {"hostile": run})


if __name__ == "__main__":
    raise SystemExit(main())
