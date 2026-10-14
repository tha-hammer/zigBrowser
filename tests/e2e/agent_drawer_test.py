#!/usr/bin/env python3
"""Chat drawer S2: the drawer shell
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md).

Closure test S2, "'-' minimizes the drawer into the icon's last position":
real X input on a private Xvfb (xinput.py); observed through validated
`DRAWER` rows (agent_common.parse_row), the page's own click log and xwd
captures. The icon's start position is seeded in agent-drawer.json.

- open (S2.1): the icon click opens the drawer full width at the bottom,
  40% tall; '-' is at its top right; the input has focus; the icon is gone
  (a click where it was reaches the page); the widget order is header,
  message list, input row
- minimize (S2.2): '-' animates (>= 3 frames) from the drawer to the
  icon's last rect R, then `minimized R`, `icon R`, focus on the icon, the
  icon drawn at R; the stand-in is drawn (`fold` rows) at >= 2 rects between
  the two, shrinking toward R; stretched to 3 s (ZIGBROWSER_AGENT_ANIM_MS,
  e2e only), an xwd capture shows it mid-flight over page area neither end
  state covers; Escape and Ctrl+Shift+Space do the same; a resize
  during the animation re-targets it; a 200 px tall window gets a drawer
  70% tall
- scroll and send (S2.3, S2.4): 200 seeded messages
  (ZIGBROWSER_AGENT_DRAWER_DEMO, honoured only with --e2e-protocol) open
  scrolled to the newest; the wheel scrolls up and the input row does not
  move; Send shows the user bubble and "Agent not available yet" without
  jumping the view, and "New messages" appears until the list is back at
  the bottom; Enter on an empty input sends nothing; Shift+Enter is a
  newline; a pasted 50 KB message wraps and does not widen the drawer

Exit 1 (never 77) when Xvfb, xauth, xwd, libXtst or the binary is missing."""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from agent_common import WIN_H, WIN_W, Browser, Checks, centre, drawer_rect, near, rect_from_ratios, run_main
from xinput import Clipboard

SEED = (0.5, 0.2)  # the icon sits above the drawer's area
ICON_RGB = (0xD9, 0x77, 0x57)
DEMO = "ZIGBROWSER_AGENT_DRAWER_DEMO"
ANIM = "ZIGBROWSER_AGENT_ANIM_MS"
GHOST_RGB = (0xF4, 0xF1, 0xEA)
PAGE_RGB = (0x20, 0x60, 0xA0)
NO_AGENT = "Agent not available yet"


def seeded_profile(tmp: Path, name: str) -> Path:
    profile = tmp / name
    profile.mkdir(mode=0o700)
    (profile / "agent-drawer.json").write_text(f'{{"version":1,"x":{SEED[0]},"y":{SEED[1]}}}', encoding="utf-8")
    return profile


def steady_gtk(tmp: Path) -> dict[str, str]:
    """A GTK config with a steady text cursor, so captures compare equal."""
    config = Path(tempfile.mkdtemp(prefix="xdg-config-", dir=tmp))
    (config / "gtk-3.0").mkdir()
    (config / "gtk-3.0/settings.ini").write_text("[Settings]\ngtk-cursor-blink=false\ngtk-enable-animations=false\n",
                                                 encoding="utf-8")
    return {"XDG_CONFIG_HOME": str(config)}


def strip(b: Browser, x0: int, y0: int, x1: int, y1: int) -> list[tuple[int, int, int]]:
    shot = b.x.screen()
    return [shot.pixel(x, y) for y in range(y0, y1, 3) for x in range(x0, x1, 3)]


def type_text(b: Browser, text: str) -> None:
    for ch in text:
        b.x.key("space" if ch == " " else ch, settle=0.01)


def kinds(b: Browser, *wanted: str) -> list[tuple[str, tuple[str, ...]]]:
    return [(r.kind, r.fields) for r in b.rows(win=1) if r.kind in wanted]


def case_open_minimize(binary: Path, tmp: Path, check: Checks) -> None:
    b = Browser(binary, tmp, "open-minimize", ["--agent-drawer", "on"], profile=seeded_profile(tmp, "p-open"))
    try:
        icon = b.wait_row("icon", 1)
        if not check(icon is not None, "icon row", b):
            return
        R = icon.rect()
        check(R == rect_from_ratios(*SEED, WIN_W, WIN_H), f"the icon starts at the seeded position ({R})", b)
        check(b.wait_page(), "page loaded", b)
        tree = b.wait_row("tree", 1)
        if check(tree is not None, "DRAWER tree row", b):
            types = tree.fields[0].split(",")
            order = [types.index(t) if t in types else -1 for t in ("GtkButton", "GtkScrolledWindow", "GtkTextView")]
            check(-1 not in order and order == sorted(order),
                  f"the drawer reads header ('-'), message list, input row from top to bottom ({types})", b)

        # S2.1: open.
        b.x.click(*centre(R))
        opened, minus = b.wait_row("open", 1), b.wait_row("minus", 1)
        if not check(opened is not None and minus is not None, "the icon click opens the drawer (open, minus)", b):
            return
        D = opened.rect()
        check(D == drawer_rect(WIN_W, WIN_H) and D[1] + D[3] == WIN_H,
              f"full width at the bottom, 40% tall: {drawer_rect(WIN_W, WIN_H)} ({D})", b)
        M = minus.rect()
        check(M[0] + M[2] >= WIN_W - 64 and D[1] <= M[1] <= D[1] + 48, f"'-' sits at the drawer's top right ({M})", b)
        check(b.wait(lambda: ("focus", ("input",)) in kinds(b, "focus"), 5), "the input has focus (focus input)", b)
        b.x.click(*centre(R))
        check(b.wait(lambda: len(b.clicks()) == 1, 5), "a click where the icon was reaches the page (icon hidden)", b)
        check(len(b.rows("open", 1)) == 1, "the drawer opened once", b)

        # S2.2 closure: '-' animates into R.
        b.x.click(*centre(M))
        anim, minimized = b.wait_row("anim", 1), b.wait_row("minimized", 1)
        if check(anim is not None and minimized is not None, "'-' runs the animation (anim, minimized)", b):
            frames = int(anim.fields[0])
            check(frames >= 3 and anim.rect(1) == D and anim.rect(2) == R,
                  f"anim: >= 3 frames from the drawer {D} to R {R} (got {anim.fields})", b)
            check(minimized.rect() == R, f"minimized at R ({minimized.rect()})", b)
            check_fold_rows(check, b, b.rows("fold", 1), D, R)
        again = b.wait_row("icon", 1, count=2)
        check(again is not None and again.rect() == R, f"the icon is back at R ({again and again.rect()})", b)
        check(b.wait(lambda: kinds(b, "focus")[-1:] == [("focus", ("icon",))], 5), "focus returns to the icon", b)
        shot = b.x.screen()
        cx, cy = centre(R)
        check(near(shot.pixel(cx - 12, cy - 12), ICON_RGB), f"the icon is drawn at R ({shot.pixel(cx - 12, cy - 12)})", b)

        # Escape minimizes; Ctrl+Shift+Space toggles.
        b.x.click(*centre(R))
        check(b.wait_row("open", 1, count=2) is not None, "the icon opens it again", b)
        b.x.key("Escape")
        check(b.wait_row("minimized", 1, count=2) is not None and b.rows("minimized", 1)[1].rect() == R,
              "Escape minimizes into R", b)
        b.x.key("space", ("Control_L", "Shift_L"))
        check(b.wait_row("open", 1, count=3) is not None, "Ctrl+Shift+Space opens the drawer", b)
        b.x.key("space", ("Control_L", "Shift_L"))
        check(b.wait_row("minimized", 1, count=3) is not None, "Ctrl+Shift+Space minimizes it", b)

        # A resize during the animation re-targets it to the clamped R.
        b.x.key("space", ("Control_L", "Shift_L"))
        fourth = b.wait_row("minus", 1, count=4)
        tops = b.x.toplevels()
        if check(fourth is not None and len(tops) == 1, "open again before the resize", b):
            b.x.click(*centre(fourth.rect()))
            b.x.resize(tops[0][0], 600, 500)
            want = rect_from_ratios(*SEED, 600, 500)
            anim4, min4 = b.wait_row("anim", 1, count=4), b.wait_row("minimized", 1, count=4)
            check(anim4 is not None and min4 is not None and anim4.rect(2) == want and min4.rect() == want,
                  f"a resize mid-animation re-targets it to {want} ({anim4 and anim4.fields}, {min4 and min4.rect()})", b)

            # A window shorter than 220 / 0.7 px: the drawer takes 70%.
            b.x.resize(tops[0][0], 600, 200)
            small = rect_from_ratios(*SEED, 600, 200)
            b.wait(lambda: b.rows("icon", 1)[-1].rect() == small, 5)
            b.x.click(*centre(small))
            five = b.wait_row("open", 1, count=5)
            check(five is not None and five.rect() == drawer_rect(600, 200) and five.rect()[3] == 140,
                  f"a 200 px tall window gets a 140 px drawer ({five and five.rect()})", b)
    finally:
        b.stop()
        check(b.gtk_complaints() == [], f"{b.label}: no GTK warning or critical ({b.gtk_complaints()[:3]})", b)


def toward(prev: int, now: int, end: int) -> bool:
    """`now` is no further from `end` than `prev` was, give or take the one
    pixel of rounding: x and w are rounded separately, so a right or bottom
    edge (x + w) can step 1 px back between two frames."""
    return abs(end - now) <= abs(end - prev) + 1


def check_fold_rows(check: Checks, b: Browser, folds: list, D, R) -> None:
    """S2.2 mid-fold (rev 12): the stand-in was drawn at least twice strictly
    between the open rect D and R, shrinking toward R frame by frame."""
    rects = [f.rect(1) for f in folds]
    frames = [int(f.fields[0]) for f in folds]
    between = [r for r in rects if r not in (D, R)]
    check(len(between) >= 2, f"the fold was drawn at >= 2 intermediate rects ({len(between)}: {between[:4]})", b)
    check(frames == sorted(frames) and len(set(frames)) == len(frames), f"fold frames increase ({frames})", b)
    pairs = list(zip(rects, rects[1:]))
    check(all(q[2] <= p[2] and q[3] <= p[3] for p, q in pairs), "each fold rect is no larger than the one before", b)
    check(all(toward(p[0], q[0], R[0]) and toward(p[1], q[1], R[1]) and
              toward(p[0] + p[2], q[0] + q[2], R[0] + R[2]) and toward(p[1] + p[3], q[1] + q[3], R[1] + R[3])
              for p, q in pairs), "every fold edge moves toward R's (within 1 px of rounding)", b)
    if rects:
        first, last = rects[0], rects[-1]
        check(all(abs(R[i] - last[i]) < abs(R[i] - first[i]) or R[i] == first[i] for i in range(4)),
              f"over the whole fold every coordinate gets closer to R ({first} -> {last})", b)


def case_fold_pixels(binary: Path, tmp: Path, check: Checks) -> None:
    """With the animation stretched to 3 s (e2e-only seam), the fold is seen
    on screen mid-flight, over page area neither end state covers."""
    b = Browser(binary, tmp, "fold-pixels", ["--agent-drawer", "on"], env_extra={ANIM: "3000"},
                profile=seeded_profile(tmp, "p-fold"))
    try:
        icon = b.wait_row("icon", 1)
        if not check(icon is not None, "icon row", b):
            return
        R = icon.rect()
        check(b.wait_page(), "page loaded", b)
        b.x.click(*centre(R))
        opened, minus = b.wait_row("open", 1), b.wait_row("minus", 1)
        if not check(opened is not None and minus is not None, "the drawer opens", b):
            return
        D = opened.rect()
        time.sleep(0.5)
        # A fixed point between R and the open drawer's top edge: the fold
        # must pass over it, and neither end state covers it. Watched with
        # xwd alone, independent of any row.
        corridor = (R[0] + R[2] // 2, (R[1] + R[3] + D[1]) // 2)
        check(near(b.x.screen().pixel(*corridor), PAGE_RGB), f"the corridor point {corridor} shows the page while open", b)
        b.x.click(*centre(minus.rect()))
        seen_fold = False
        deadline = time.monotonic() + 1.6
        while time.monotonic() < deadline and not seen_fold:
            seen_fold = near(b.x.screen().pixel(*corridor), GHOST_RGB)
        check(seen_fold, f"xwd sees the fold pass over the corridor point {corridor}", b)
        time.sleep(0.4)
        before = b.rows("fold", 1)
        shot = b.x.screen()
        after = b.rows("fold", 1)
        check(b.rows("minimized", 1) == [], "the stretched fold is still running at the capture", b)
        if not check(len(before) >= 1 and len(after) > len(before), "fold rows straddle the capture", b):
            return
        a, c = before[-1].rect(1), after[len(before)].rect(1)
        x0, y0 = max(a[0], c[0]), max(a[1], c[1])
        x1, y1 = min(a[0] + a[2], c[0] + c[2]), min(a[1] + a[3], c[1] + c[3])
        # A point the stand-in covers both just before and just after the
        # capture, above the drawer (outside D) and outside R.
        points = [(x, y) for x in range(x0 + 4, x1 - 4, 8) for y in range(y0 + 4, min(y1, D[1]) - 4, 8)
                  if not (R[0] <= x < R[0] + R[2] and R[1] <= y < R[1] + R[3])]
        if check(bool(points), f"the fold passes over page area outside both end states ({a}, {c})", b):
            px, py = points[len(points) // 2]
            check(near(shot.pixel(px, py), GHOST_RGB), f"the fold is on screen at {px},{py} ({shot.pixel(px, py)})", b)
            out_x = x0 - 6
            if out_x >= 0:
                check(near(shot.pixel(out_x, py), PAGE_RGB), f"the page shows just outside the fold ({shot.pixel(out_x, py)})", b)
        check(b.wait_row("minimized", 1, timeout=10) is not None, "the stretched fold ends in R", b)
        time.sleep(0.3)
        check(near(b.x.screen().pixel(*corridor), PAGE_RGB), "the corridor point shows the page again after the fold", b)
        check_fold_rows(check, b, b.rows("fold", 1), D, R)
    finally:
        b.stop()
        check(b.gtk_complaints() == [], f"{b.label}: no GTK warning or critical ({b.gtk_complaints()[:3]})", b)


def case_scroll_send(binary: Path, tmp: Path, check: Checks) -> None:
    refused = Browser(binary, tmp, "demo-refused", ["--agent-drawer", "on"], env_extra={DEMO: "messages:5"},
                      profile=seeded_profile(tmp, "p-refused"), e2e=False)
    try:
        refused.wait(lambda: any(DEMO in line for line in refused.err), 15)
        check(f"zigBrowser: {DEMO} ignored without --e2e-protocol" in refused.err,
              "the demo seed is refused without --e2e-protocol", refused)
    finally:
        refused.stop()

    b = Browser(binary, tmp, "scroll-send", ["--agent-drawer", "on"], env_extra={DEMO: "messages:200", **steady_gtk(tmp)},
                profile=seeded_profile(tmp, "p-scroll"))
    try:
        icon = b.wait_row("icon", 1)
        if not check(icon is not None, "icon row", b):
            return
        check(b.wait_page(), "page loaded", b)
        seeded = [r for r in b.rows("msg", 1) if r.fields[0] == "system"]
        check(len(seeded) == 200, f"200 seeded system messages ({len(seeded)})", b)
        b.x.click(*centre(icon.rect()))
        opened = b.wait_row("open", 1)
        if not check(opened is not None, "the drawer opens", b):
            return
        D = opened.rect()
        check(b.wait(lambda: kinds(b, "scroll")[-1:] == [("scroll", ("bottom",))], 5),
              "it opens scrolled to the newest message (scroll bottom)", b)
        time.sleep(0.5)
        input_row = (D[0], D[1] + D[3] - 56, D[0] + D[2], D[1] + D[3] - 2)
        before = strip(b, *input_row)
        list_point = (D[0] + D[2] // 2, D[1] + D[3] // 2)
        b.x.wheel(*list_point, up=True, notches=5)
        check(b.wait(lambda: kinds(b, "scroll")[-1:] != [("scroll", ("bottom",))], 5),
              f"the wheel scrolls up ({kinds(b, 'scroll')[-1:]})", b)
        time.sleep(0.5)
        check(strip(b, *input_row) == before, "the input row stays where it was", b)
        scrolled = kinds(b, "scroll")[-1]

        type_text(b, "hello")
        b.x.key("Return")
        check(b.wait(lambda: kinds(b, "msg")[-2:] == [("msg", ("user", "hello")), ("msg", ("system", NO_AGENT))], 5),
              f"Send shows the user bubble, then '{NO_AGENT}' ({kinds(b, 'msg')[-2:]})", b)
        check(b.wait(lambda: kinds(b, "unread")[-1:] == [("unread", ("shown",))], 5), "'New messages' appears", b)
        check(kinds(b, "scroll")[-1] == scrolled, "the view did not jump to the bottom", b)
        n = len(kinds(b, "msg"))
        b.x.key("Return")
        time.sleep(0.7)
        check(len(kinds(b, "msg")) == n, "the input was cleared: Enter on it sends nothing", b)
        type_text(b, "a")
        b.x.key("Return", ("Shift_L",))
        type_text(b, "b")
        b.x.key("Return")
        check(b.wait(lambda: ("msg", ("user", "a b")) in kinds(b, "msg"), 5) and
              ("msg", ("user", "a")) not in kinds(b, "msg"), "Shift+Enter is a newline inside one message", b)
        b.x.wheel(*list_point, up=False, notches=60)
        check(b.wait(lambda: kinds(b, "scroll")[-1:] == [("scroll", ("bottom",))], 5), "back at the bottom", b)
        check(b.wait(lambda: kinds(b, "unread")[-1:] == [("unread", ("hidden",))], 5), "'New messages' goes away", b)

        # A 50 KB pasted message wraps; the drawer does not widen.
        minus = b.wait_row("minus", 1)
        header = (D[0], D[1] + 2, D[0] + D[2], D[1] + 40)
        head_before = strip(b, *header)
        long_text = ("x" * 99 + " ") * 500
        with Clipboard(b.x, long_text):
            b.x.key("v", ("Control_L",))
            time.sleep(0.5)
        b.x.key("Return")
        got = b.wait(lambda: any(r.fields[0] == "user" and r.fields[1].startswith("x" * 99) for r in b.rows("msg", 1)), 10)
        sent = [r for r in b.rows("msg", 1) if r.fields[0] == "user" and r.fields[1].startswith("x" * 99)]
        check(got and len(sent) == 1 and sent[0].fields[1].endswith("…") and len(sent[0].fields[1].encode()) == 4096 + 3,
              f"the pasted 50 KB message is one bubble; its row is capped at 4 KiB + '…' "
              f"({sent and len(sent[0].fields[1].encode())} bytes)", b)
        time.sleep(0.5)
        check(strip(b, *header) == head_before, "the drawer's header did not move or widen", b)
        if minus is not None:
            b.x.click(*centre(minus.rect()))
            check(b.wait_row("minimized", 1) is not None, "'-' still minimizes after the long message", b)
    finally:
        b.stop()
        check(b.gtk_complaints() == [], f"{b.label}: no GTK warning or critical ({b.gtk_complaints()[:3]})", b)


def main() -> int:
    return run_main(__doc__, {"open": case_open_minimize, "fold": case_fold_pixels, "scroll": case_scroll_send})


if __name__ == "__main__":
    raise SystemExit(main())
