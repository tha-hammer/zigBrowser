#!/usr/bin/env python3
"""Chat drawer S1: the launch switch, the overlay and the floating "S" icon
(thoughts/searchable/shared/plans/2026-10-13-claude-agent-chat-drawer-tdd-plan.md).

Closure test S1, "clicking the S icon opens the drawer, and clicks elsewhere
reach the page": every input is a real X event on the browser's own private
Xvfb (xinput.py, through xsession.py --display-file); every observation is
a `DRAWER` row (validated against D7b by agent_common.parse_row), the
page's own click log read through the automation socket, or an xwd capture.

Cases (each its own browser and display):
- off (--agent-drawer off) with a popup: no DRAWER row at all
- ZIGBROWSER_AGENT_DRAWER=bogus: stderr says it is ignored; the default applies, and
  since S5.5 that is on: the icon row (agent_default_on_test.py checks the default)
- --screenshot ... --agent-drawer on: usage, no DRAWER row
- ZIGBROWSER_AGENT_DRAWER=on with a popup: one icon row per window id
- clicks (S1.3, S1.5): the icon's pixels; four clicks 1 px outside its
  edges and 25 seeded random clicks outside it reach the page at exactly
  those points; the centre click opens the drawer and reaches nothing; 5
  seeded clicks inside the icon reach nothing; the automation socket lists
  the same windows as with the drawer off and knows no agent/drawer/secrets
  method (-32601)
- drag (S1.4): a (-300,-200) drag moves the icon and does not open it; a
  7 px drag moves it; a resize to 500x400 keeps it inside; a popup starts
  at the saved position; a 6 px press-move-release opens it; a relaunch
  with the profile starts at the saved position; a corrupt file falls back
  to the default with a stderr line; with no profile a drag still works
- keyboard (S1.4): Tab reaches the icon, Right x3 moves it +48 px, Shift+Up
  -64 px, Return opens the drawer

Exit 1 (never 77) when Xvfb, xauth, xwd, libXtst or the binary is missing:
these are hard requirements of a drawer slice."""

from __future__ import annotations

import json
import os
import random
import subprocess
import tempfile
import time
from pathlib import Path

from agent_common import (
    CLICK_GRID,
    ENV,
    ICON,
    WIN_H,
    WIN_W,
    Browser,
    Checks,
    centre,
    clamp_rect,
    close_rect,
    default_rect,
    near,
    rect_from_ratios,
    run_main,
)
from zigbrowser.errors import ProtocolError

FIXTURE = CLICK_GRID
PAGE_RGB = (0x20, 0x60, 0xA0)
ICON_RGB = (0xD9, 0x77, 0x57)
GLYPH_RGB = (0xFF, 0xFF, 0xFF)


# --- cases ------------------------------------------------------------------
def case_off(binary: Path, tmp: Path, check: Checks) -> None:
    b = Browser(binary, tmp, "off", ["--agent-drawer", "off"], profile=tmp / "p-off")
    try:
        check(b.wait_page(), "off: page loaded", b)
        check(b.open_popup(), "off: a popup opened (two windows)", b)
        time.sleep(1.0)
        check(b.rows() == [], f"off: no DRAWER row at all (got {len(b.rows())})", b)
    finally:
        b.stop()
    bogus = Browser(binary, tmp, "bogus", [], env_extra={ENV: "bogus"}, profile=tmp / "p-bogus")
    try:
        check(bogus.wait_page(), "bogus variable: page loaded", bogus)
        time.sleep(0.5)
        check(bogus.wait(lambda: bogus.rows("icon", 1) != [], 10), "bogus variable: the default applies (on): the icon", bogus)
        check(f"zigBrowser: {ENV}=bogus ignored" in bogus.err, "bogus variable: stderr says it is ignored", bogus)
    finally:
        bogus.stop()
    shot = subprocess.run([str(binary.resolve()), "--screenshot", str(tmp / "s.png"), FIXTURE, "--agent-drawer", "on"],
                          capture_output=True, text=True, timeout=30, env={"PATH": os.environ.get("PATH", "")})
    check(shot.returncode != 0 and "usage:" in shot.stderr and "DRAWER" not in shot.stdout,
          f"screenshot rejects --agent-drawer (exit {shot.returncode})")


def case_popup_icons(binary: Path, tmp: Path, check: Checks) -> None:
    b = Browser(binary, tmp, "popup", [], env_extra={ENV: "on"}, profile=tmp / "p-popup")
    try:
        check(b.wait_row("icon", 1) is not None, "on (variable): window 1 shows an icon", b)
        check(b.wait_page(), "on: page loaded", b)
        check(b.open_popup(), "on: a popup opened", b)
        check(b.wait_row("icon", 2) is not None, "on: the popup (window 2) shows its own icon", b)
        time.sleep(0.5)
        icon_wins = sorted({r.win for r in b.rows("icon")})
        check(icon_wins == [1, 2], f"on: icon rows for exactly windows 1 and 2 (got {icon_wins})", b)
        check(b.rows("icon", 1)[0].rect() == default_rect(WIN_W, WIN_H),
              f"on: the icon starts bottom-right, 24 px in ({b.rows('icon', 1)[0].rect()})", b)
    finally:
        b.stop()


def case_clicks(binary: Path, tmp: Path, check: Checks) -> None:
    rng = random.Random(0x51C0)
    b = Browser(binary, tmp, "clicks", ["--agent-drawer", "on"], profile=tmp / "p-clicks")
    try:
        row = b.wait_row("icon", 1)
        if not check(row is not None, "clicks: icon row", b):
            return
        check(b.wait_page(), "clicks: page loaded", b)
        x, y, w, h = r = row.rect()
        tops = b.x.toplevels()
        check(len(tops) == 1 and tops[0][1:3] == (0, 0), f"clicks: one toplevel at the root origin ({tops})", b)

        # S1.5: the drawer adds no window and no method to the automation surface.
        pages = b.zb.page.list()["pages"]
        check(len(pages) == 1, f"clicks: page.list sees exactly the one browsing window ({len(pages)})", b)
        health = b.zb.call("page.health", {})["pages"]
        check(len(health) == 1 and health[0]["window_id"] == "window-1" and health[0]["responsive"] is True,
              f"clicks: page.health sees exactly the one browsing window, responsive ({health})", b)
        for method in ("agent.ping", "drawer.open", "secrets.get"):
            try:
                b.zb.call(method, {})
                check(False, f"clicks: {method} is unknown to the socket (it answered)", b)
            except ProtocolError as exc:
                check(exc.code == -32601, f"clicks: {method} -> {exc.code} (want -32601)", b)

        # The icon is drawn where its row says; the page shows around it
        # (once the page has painted: it may be ready before its first frame).
        shot = b.x.screen()
        deadline = time.monotonic() + 10
        while not near(shot.pixel(5, 5), PAGE_RGB) and time.monotonic() < deadline:
            time.sleep(0.2)
            shot = b.x.screen()
        inside = [shot.pixel(px, py) for px in range(x + 4, x + w - 4, 3) for py in range(y + 4, y + h - 4, 3)]
        ring = [shot.pixel(px, py) for px in range(x - 3, x + w + 3) for py in (y - 3, y + h + 2)] + \
               [shot.pixel(px, py) for py in range(y - 3, y + h + 3) for px in (x - 3, x + w + 2)]
        check(sum(near(p, ICON_RGB) for p in inside) > len(inside) // 3,
              f"clicks: the icon colour fills the icon rect ({sum(near(p, ICON_RGB) for p in inside)}/{len(inside)})", b)
        check(any(near(p, GLYPH_RGB, 40) for p in inside), "clicks: the S glyph is drawn inside the rect", b)
        check(all(near(p, PAGE_RGB) for p in ring), "clicks: the page colour shows just outside the rect", b)

        # Outside the icon: four 1 px edge points, then 25 seeded points.
        points = [(x - 1, y + h // 2), (x + w, y + h // 2), (x + w // 2, y - 1), (x + w // 2, y + h)]
        while len(points) < 29:
            px, py = rng.randrange(0, WIN_W), rng.randrange(0, WIN_H)
            if not (x <= px < x + w and y <= py < y + h):
                points.append((px, py))
        for px, py in points:
            b.x.click(px, py)
        b.wait(lambda: len(b.clicks()) >= len(points), 10)
        got = [(c[0], c[1]) for c in b.clicks()]
        check(got == points, f"clicks: all {len(points)} outside clicks reached the page at their points "
                             f"(first mismatch {next(((p, g) for p, g in zip(points, got) if p != g), None)}, "
                             f"{len(got)} recorded)", b)
        check(b.rows("open") == [], "clicks: no outside click opened the drawer", b)

        # The centre opens the drawer; it and 5 seeded inside points reach nothing.
        b.x.click(*centre(r))
        check(b.wait_row("open", 1) is not None, "clicks: the centre click opens the drawer (DRAWER open)", b)
        for _ in range(5):
            b.x.click(rng.randrange(x, x + w), rng.randrange(y, y + h))
        time.sleep(0.5)
        check(len(b.clicks()) == len(points), f"clicks: the 6 clicks inside the icon reached no page "
                                              f"({len(b.clicks()) - len(points)} did)", b)
    finally:
        b.stop()


def saved_ratios(profile: Path) -> tuple[float, float] | None:
    try:
        data = json.loads((profile / "agent-drawer.json").read_text(encoding="utf-8"))
        return float(data["x"]), float(data["y"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def case_drag(binary: Path, tmp: Path, check: Checks) -> None:
    profile = tmp / "p-drag"
    b = Browser(binary, tmp, "drag", ["--agent-drawer", "on"], profile=profile)
    try:
        row = b.wait_row("icon", 1)
        if not check(row is not None, "drag: icon row", b):
            return
        check(b.wait_page(), "drag: page loaded", b)
        r0 = row.rect()
        cx, cy = centre(r0)
        b.x.drag(cx, cy, cx - 300, cy - 200)
        r1_row = b.wait_row("icon", 1, count=2)
        want1 = (r0[0] - 300, r0[1] - 200, ICON, ICON)
        check(r1_row is not None and r1_row.rect() == want1, f"drag: (-300,-200) moves the icon to {want1} "
                                                             f"({r1_row and r1_row.rect()})", b)
        check(b.rows("open") == [] and b.clicks() == [], "drag: the drag opened nothing and reached no page", b)
        cx, cy = centre(want1)
        b.x.drag(cx, cy, cx + 7, cy, steps=7)
        r2_row = b.wait_row("icon", 1, count=3)
        want2 = (want1[0] + 7, want1[1], ICON, ICON)
        check(r2_row is not None and r2_row.rect() == want2, f"drag: a 7 px drag moves it ({r2_row and r2_row.rect()})", b)
        check(b.rows("open") == [], "drag: a 7 px movement is a drag, not a click", b)
        saved = saved_ratios(profile)
        check(saved is not None and rect_from_ratios(*saved, WIN_W, WIN_H) == want2,
              f"drag: agent-drawer.json holds the last drag's position ({saved})", b)

        tops = b.x.toplevels()
        if check(len(tops) == 1, f"drag: one toplevel to resize ({tops})", b):
            b.x.resize(tops[0][0], 500, 400)
            want3 = rect_from_ratios(*(saved or (0, 0)), 500, 400)
            ok = b.wait(lambda: b.rows("icon", 1)[-1].rect() == want3, 10)
            last = b.rows("icon", 1)[-1].rect()
            check(ok and 0 <= last[0] and last[0] + ICON <= 500 and 0 <= last[1] and last[1] + ICON <= 400,
                  f"drag: after a resize to 500x400 the icon is inside at {want3} ({last})", b)

        check(b.open_popup(), "drag: a popup opened", b)
        p_row = b.wait_row("icon", 2)
        check(p_row is not None and saved is not None and close_rect(p_row.rect(), rect_from_ratios(*saved, WIN_W, WIN_H)),
              f"drag: the popup's icon starts at the saved position ({p_row and p_row.rect()})", b)
        if p_row is not None:
            pcx, pcy = centre(p_row.rect())
            b.x.drag(pcx, pcy, pcx + 6, pcy, steps=6)
            check(b.wait_row("open", 2) is not None, "drag: a 6 px press-move-release is a click (popup opens)", b)
    finally:
        b.stop()

    again = Browser(binary, tmp, "relaunch", ["--agent-drawer", "on"], profile=profile)
    try:
        row = again.wait_row("icon", 1)
        check(row is not None and close_rect(row.rect(), want2), f"relaunch: the icon starts at the saved position "
                                                                  f"{want2} ({row and row.rect()})", again)
    finally:
        again.stop()

    (profile / "agent-drawer.json").write_text("{not json", encoding="utf-8")
    corrupt = Browser(binary, tmp, "corrupt", ["--agent-drawer", "on"], profile=profile)
    try:
        row = corrupt.wait_row("icon", 1)
        check(row is not None and row.rect() == default_rect(WIN_W, WIN_H),
              f"corrupt: the icon falls back to the default ({row and row.rect()})", corrupt)
        check("zigBrowser: agent-drawer.json unreadable; using default" in corrupt.err,
              "corrupt: stderr says the file is unreadable", corrupt)
    finally:
        corrupt.stop()

    # No profile at all: no --profile-dir, and no usable default (HOME empty,
    # XDG_DATA_HOME relative, which zigBrowser ignores).
    root = Path(tempfile.mkdtemp(prefix="noprof-", dir=tmp))
    env = {k: v for k, v in os.environ.items() if k not in ("HOME", "XDG_DATA_HOME")}
    env.update(HOME="", XDG_DATA_HOME="relative-data", XDG_CACHE_HOME=str(root / "cache"),
               XDG_CONFIG_HOME=str(root / "config"))
    bare = Browser(binary, tmp, "no-profile", ["--agent-drawer", "on"], env=env)
    try:
        row = bare.wait_row("icon", 1)
        if check(row is not None, "no profile: icon row", bare):
            check(bare.wait_page(), "no profile: page loaded", bare)
            cx, cy = centre(row.rect())
            bare.x.drag(cx, cy, cx - 100, cy - 100)
            moved = bare.wait_row("icon", 1, count=2)
            check(moved is not None and moved.rect()[0] == row.rect()[0] - 100 and bare.proc.poll() is None,
                  "no profile: a drag still moves the icon and nothing crashes", bare)
        written = [p for p in root.parent.rglob("agent-drawer.json") if p.is_relative_to(bare.dir) or p.is_relative_to(root)]
        check(written == [], f"no profile: nothing persisted ({written})", bare)
    finally:
        bare.stop()


def case_keyboard(binary: Path, tmp: Path, check: Checks) -> None:
    # Seeded start position (the SOURCE allows agent-drawer.json): the
    # window's centre, so every move below has room.
    profile = tmp / "p-keys"
    profile.mkdir(mode=0o700)
    (profile / "agent-drawer.json").write_text('{"version":1,"x":0.5,"y":0.5}', encoding="utf-8")
    b = Browser(binary, tmp, "keyboard", ["--agent-drawer", "on"], profile=profile)
    try:
        row = b.wait_row("icon", 1)
        if not check(row is not None, "keyboard: icon row", b):
            return
        check(row.rect() == rect_from_ratios(0.5, 0.5, WIN_W, WIN_H),
              f"keyboard: the icon starts at the seeded position ({row.rect()})", b)
        check(b.wait_page(), "keyboard: page loaded", b)
        r0 = row.rect()
        check(b.rows("focus") == [], "keyboard: the page, not the icon, has the keyboard at startup", b)
        b.x.click(20, 20)  # the page
        for _ in range(6):
            b.x.key("Tab")
            if b.wait(lambda: bool(b.rows("focus", 1)), 0.5):
                break
        focus = b.rows("focus", 1)
        check(bool(focus) and focus[-1].fields == ("icon",), f"keyboard: Tab reaches the icon (DRAWER focus icon) "
                                                             f"({[f.fields for f in focus]})", b)
        n = len(b.rows("icon", 1))
        for _ in range(3):
            b.x.key("Right")
        moved = b.wait_row("icon", 1, count=n + 3, timeout=5)
        want = (r0[0] + 48, r0[1], ICON, ICON)
        check(moved is not None and moved.rect() == clamp_rect(want[0], want[1], WIN_W, WIN_H),
              f"keyboard: Right x3 moves the icon +48 px ({moved and moved.rect()})", b)
        b.x.key("Up", ("Shift_L",))
        up = b.wait_row("icon", 1, count=n + 4, timeout=5)
        want_up = clamp_rect(r0[0] + 48, r0[1] - 64, WIN_W, WIN_H)
        check(up is not None and up.rect() == want_up, f"keyboard: Shift+Up moves it -64 px ({up and up.rect()})", b)
        check(b.rows("open") == [], "keyboard: moving does not open", b)
        b.x.key("Return")
        check(b.wait_row("open", 1, timeout=5) is not None, "keyboard: Return opens the drawer", b)
    finally:
        b.stop()


def main() -> int:
    return run_main(__doc__, {"off": case_off, "popup": case_popup_icons, "clicks": case_clicks, "drag": case_drag,
                               "keyboard": case_keyboard})


if __name__ == "__main__":
    raise SystemExit(main())
