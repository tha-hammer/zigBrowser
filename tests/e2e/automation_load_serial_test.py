#!/usr/bin/env python3
"""S8a (chat-drawer plan rev 16.20.38, S8 in detail): `load_serial` on Linux (GTK). Each window
counts its committed loads (WEBKIT_LOAD_COMMITTED): the first load gives 1 or more, every
navigation and reload adds exactly one, a same-document change (pushState, a hash change)
adds none, a popup counts its own, and page.list and page.health report the same number. An
approval binds it, so a navigation between the card and the commit is seen (plan D10, S8a).

The real binary on its own Xvfb (xsession.py), its automation socket, two fixture pages.
Exit 1 when Xvfb, xauth or the binary is missing."""

from __future__ import annotations

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

PAGE = """<!doctype html><meta charset="utf-8"><title>%s</title><h1>%s</h1>
<script>window.__ready = true;</script>"""


def pages(tmp: Path) -> tuple[str, str]:
    a, b = tmp / "serial-a.html", tmp / "serial-b.html"
    a.write_text(PAGE % ("serial a", "a"))
    b.write_text(PAGE % ("serial b", "b"))
    return a.resolve().as_uri(), b.resolve().as_uri()


def serials(b, window: str = "window-1") -> tuple[int | None, int | None]:
    listed = next((p for p in b.zb.page.list()["pages"] if p["window_id"] == window), {})
    health = next((p for p in b.zb.call("page.health", {})["pages"] if p["window_id"] == window), {})
    return listed.get("load_serial"), health.get("load_serial")


def settle(b, window: str, want: int) -> bool:
    return b.wait(lambda: serials(b, window)[0] == want, 10)


def case_counts(binary: Path, tmp: Path, check) -> None:
    from agent_common import Browser
    url_a, url_b = pages(tmp)
    b = Browser(binary, tmp, "load-serial", [], url=url_a, e2e=False)
    try:
        if not check(b.wait_page(), "the first page loaded", b):
            return
        first, health = serials(b)
        check(isinstance(first, int) and first >= 1, f"the first load gives a serial of 1 or more ({first})")
        check(health == first, f"page.health reports the same serial as page.list ({health} vs {first})")
        if not isinstance(first, int):
            return
        b.zb.call("page.navigate", {"url": url_b, "window_id": "window-1"})
        check(settle(b, "window-1", first + 1), f"a navigation adds exactly one ({serials(b)})")
        b.ev("history.pushState({}, '', '#pushed'), location.hash = 'hashed', 1")
        time.sleep(0.5)
        check(serials(b)[0] == first + 1, f"a same-document change adds none ({serials(b)})")
        b.zb.call("page.reload", {"window_id": "window-1"})
        check(settle(b, "window-1", first + 2), f"a reload adds exactly one ({serials(b)})")
        check(serials(b)[1] == serials(b)[0], f"page.health still agrees ({serials(b)})")
        b.ev(f"(window.open({url_a!r}), 1)")
        if check(b.wait(lambda: len(b.zb.page.list()["pages"]) == 2, 15), "a popup opened", b):
            # The popup is listed before its first load commits. Exactly 1, not the first
            # page's lower bound: window.open of a file: URL commits that one document, with
            # no about:blank and no redirect, so a second count is a double count.
            settle(b, "window-2", 1)
            popup = serials(b, "window-2")[0]
            check(popup == 1 and serials(b)[0] == first + 2,
                  f"the popup counts its own load, the opener's is unchanged ({popup}, {serials(b)})")
    finally:
        b.stop()


CASES = {"counts": case_counts}


def main() -> int:
    from agent_common import run_main
    return run_main(__doc__, CASES)


if __name__ == "__main__":
    raise SystemExit(main())
