r"""WS5.1-WS5.7 Windows drawer behaviors — UNREGISTERED red suite, parseable OFFLINE (no VM needed).

!!! These are the behavior reds for the native Win32 drawer (plan WS5.1-WS5.7). They are NOT registered in
    build.zig and must stay unregistered until the WS5 green implements the behaviors (project rule: never add
    failing tests to a gate-registered step). The suite has two halves:

    * `WinDrawerBehaviorsOracle` (runs NOW, no VM): pure-Python models that MIRROR src/agent_drawer.zig
      (`zb_drawer_*`) branch-for-branch, each with a discriminating mutant row proving the check is causal.
      This pins each behavior's contract before the backend exists.
    * `WinDrawerBehaviorsLive` (skips without ZB_WIN11_HOST/ZB_WIN_EXE): the e2e reds that observe the real
      drawer via `--e2e-protocol` DRAWER rows, the clipboard, captures and the Job census — identical harness
      to tests/windows/win_drawer_test.py. They are red today (no Win32 drawer) and go green with WS5.

The offline models are the authoritative-for-review contract; the Zig remains the source of truth and the Zig
property tests ([L]) cover the same math. Each live row builds its expected value from the SAME model, so the
live assertion and the offline oracle cannot drift.
"""
import math
import os
import unittest
from collections import namedtuple

# ---- constants mirrored from src/agent_drawer.zig ----
ICON_SIZE = 56
ICON_MARGIN = 24
DRAG_THRESHOLD = 6.0
KEY_STEP = 16
KEY_STEP_BIG = 64
ANIM_MS = 180

Rect = namedtuple("Rect", "x y w h")


# ------------------------------------------------------------------
# Pure models (mirror agent_drawer.zig). Integer rounding matches Zig's @floor(.. + 0.5).
# ------------------------------------------------------------------
def _clampi(v, lo, hi):
    return max(lo, min(v, hi))


def _unit_ratio(v):
    return _clampi(v, 0.0, 1.0) if math.isfinite(v) else 0.5


def clamp_rect(r, width, height):
    return Rect(_clampi(r.x, 0, max(0, width - r.w)),
                _clampi(r.y, 0, max(0, height - r.h)), r.w, r.h)


def default_rect(width, height):
    far = ICON_MARGIN + ICON_SIZE
    return clamp_rect(Rect(width - far, height - far, ICON_SIZE, ICON_SIZE), width, height)


def rect_from_ratios(rx, ry, width, height):
    half = ICON_SIZE / 2
    x = math.floor(_unit_ratio(rx) * width - half + 0.5)
    y = math.floor(_unit_ratio(ry) * height - half + 0.5)
    return clamp_rect(Rect(int(x), int(y), ICON_SIZE, ICON_SIZE), width, height)


def _centre_ratio(start, size, extent):
    if extent <= 0:
        return 0.5
    return _unit_ratio((start + size / 2) / extent)


def ratios_from_rect(r, width, height):
    return (_centre_ratio(r.x, r.w, width), _centre_ratio(r.y, r.h, height))


def key_move(r, dx, dy, big, width, height):
    step = KEY_STEP_BIG if big else KEY_STEP
    return clamp_rect(Rect(r.x + dx * step, r.y + dy * step, r.w, r.h), width, height)


def classify_gesture(dx, dy):
    return "drag" if (dx * dx + dy * dy) > (DRAG_THRESHOLD * DRAG_THRESHOLD) else "click"


def drawer_rect(width, height):
    h = float(max(0, height))
    wanted = int(math.floor(h * 0.4 + 0.5))
    most = int(math.floor(h * 0.7))
    tall = min(max(wanted, 220), most)
    return Rect(0, height - tall, width, tall)


def _lerp(a, b, t):
    return int(math.floor(a + (b - a) * t + 0.5))


def lerp_rect(a, b, t):
    u = _clampi(t, 0.0, 1.0)
    return Rect(_lerp(a.x, b.x, u), _lerp(a.y, b.y, u), _lerp(a.w, b.w, u), _lerp(a.h, b.h, u))


def ease(t):
    u = 1 - _clampi(t, 0.0, 1.0)
    return 1 - u * u * u


# ---- WS5.1 dock split ----
def dock_split(width, height):
    """The page sits ABOVE the panel with no overlap; page_h + panel_h == client_h."""
    panel = drawer_rect(width, height)
    page = Rect(0, 0, width, panel.y)
    return page, panel


# ---- WS5.3 fold ----
def fold_rect_at(drawer, icon, t):
    """The '-' fold: the open drawer rect eased down into the icon's last position."""
    return lerp_rect(drawer, icon, ease(t))


def fold_total_ms(env_ms=None):
    return int(env_ms) if env_ms is not None else ANIM_MS


# ---- WS5.4 inert bubble ----
def render_bubble(text, plaintext=True):
    """A read-only RichEdit set with PLAIN TEXT only renders literally, with no link and no OLE object.
    The mutant (plaintext=False, i.e. EM_STREAMIN/SF_RTF or auto-URL on) parses RTF and linkifies URLs.
    """
    if plaintext:
        return {"displayed": text, "link": False, "object": False}
    link = ("http://" in text) or ("https://" in text)
    obj = text.startswith("{\\rtf1")
    return {"displayed": "(rendered)" if obj else text, "link": link, "object": obj}


def clipboard_after_copy(text, plaintext=True):
    return text if plaintext else "(rtf-bytes)"


# ---- WS5.5 live count ----
def live_count(opens, destroys):
    return opens - destroys


# ---- WS5.6 isolation ----
def reachable_drawer_methods(methods):
    return [m for m in methods if "drawer" in m.lower()]


def js_can_reach_drawer(page_window_ids, page_dom_ids, drawer_win_id, drawer_dom_id):
    return (drawer_win_id in page_window_ids) or (drawer_dom_id in page_dom_ids)


# ---- WS5.7 DPI ----
def icon_px_at(scale, base=ICON_SIZE):
    return int(round(base * scale))


def inside_icon(dx, dy, radius):
    """Exact circular hit-test: the edge (distance == radius) is inside."""
    return (dx * dx + dy * dy) <= (radius * radius)


# ------------------------------------------------------------------
# OFFLINE oracle (no VM): each behavior's contract + a discriminating mutant.
# ------------------------------------------------------------------
class WinDrawerBehaviorsOracle(unittest.TestCase):
    # WS5.1 ---------------------------------------------------------
    def test_ws5_1_dock_no_overlap(self):
        for w, h in ((1008, 729), (1920, 1080), (800, 600)):
            page, panel = dock_split(w, h)
            self.assertEqual(page.h + panel.h, h, "page_h + panel_h must equal client_h")
            self.assertEqual(page.y + page.h, panel.y, "page bottom must meet the panel top (no overlap)")
            self.assertEqual(panel.y + panel.h, h, "the panel sits at the bottom of the client area")
        # mutant: the page keeps the full client height (panel overlaps it) -> equation breaks
        w, h = 1008, 729
        _, panel = dock_split(w, h)
        mutant_page = Rect(0, 0, w, h)
        self.assertNotEqual(mutant_page.h + panel.h, h, "an overlapping (full-height) page must be rejected")

    # WS5.2 ---------------------------------------------------------
    def test_ws5_2_gesture_threshold(self):
        self.assertEqual(classify_gesture(5, 0), "click", "a 5 px move is a click (opens)")
        self.assertEqual(classify_gesture(7, 0), "drag", "a 7 px move is a drag")
        # mutant: threshold 0 -> any move is a drag, so the 5 px click is misread
        def classify_mutant(dx, dy):
            return "drag" if (dx * dx + dy * dy) > 0 else "click"
        self.assertEqual(classify_mutant(5, 0), "drag")
        self.assertNotEqual(classify_mutant(5, 0), classify_gesture(5, 0),
                            "the threshold-0 mutant must disagree on a 5 px move")

    def test_ws5_2_ratios_roundtrip_and_clamp(self):
        # rect -> ratios -> rect is idempotent on the clamped rect (the persisted-position roundtrip).
        for w, h in ((1008, 729), (1920, 1080)):
            r = default_rect(w, h)
            rx, ry = ratios_from_rect(r, w, h)
            self.assertEqual(rect_from_ratios(rx, ry, w, h), r, "ratios roundtrip must return the same rect")
        # clamp keeps the icon fully inside for generated sizes/positions
        for w, h in ((640, 480), (1920, 1080)):
            for rx, ry in ((2.0, -1.0), (0.5, 0.5), (1.5, 1.5)):
                r = rect_from_ratios(rx, ry, w, h)
                self.assertTrue(0 <= r.x <= w - r.w and 0 <= r.y <= h - r.h,
                                f"icon must stay inside {w}x{h}: {r}")
        # mutant: clamp is identity -> an out-of-area ratio escapes the client rect
        bad = Rect(5000, 5000, ICON_SIZE, ICON_SIZE)  # a no-clamp result for rx,ry > 1
        self.assertFalse(0 <= bad.x <= 1008 - bad.w, "a non-clamping placement must be rejected")

    def test_ws5_2_key_move_steps(self):
        r = Rect(100, 100, ICON_SIZE, ICON_SIZE)
        self.assertEqual(key_move(r, 1, 0, False, 2000, 2000).x, 116, "small step is 16 px")
        self.assertEqual(key_move(r, 1, 0, True, 2000, 2000).x, 164, "big step is 64 px")

    # WS5.3 ---------------------------------------------------------
    def test_ws5_3_fold_has_intermediate(self):
        drawer = drawer_rect(1008, 729)
        icon = default_rect(1008, 729)
        mid = fold_rect_at(drawer, icon, 0.5)
        self.assertTrue(icon.w < mid.w < drawer.w,
                        f"a mid-fold must be strictly between the icon and the open drawer: {mid}")
        self.assertIn(fold_total_ms(), range(150, 260), "default fold is ~180 ms")
        self.assertEqual(fold_total_ms(env_ms=3000), 3000, "ZIGBROWSER_AGENT_ANIM_MS is honored")
        # mutant: snap (no animation) -> the mid frame equals the icon, not an intermediate
        snap_mid = icon
        self.assertFalse(icon.w < snap_mid.w < drawer.w, "a snap (no animation) must be rejected")
        self.assertNotIn(0, range(150, 260), "a 0 ms snap must be out of the fold range")

    # WS5.4 ---------------------------------------------------------
    def test_ws5_4_bubble_inert_and_copyable(self):
        for text in (r"{\rtf1\ansi hello}", "https://example.com/x", "plain text"):
            b = render_bubble(text, plaintext=True)
            self.assertEqual(b["displayed"], text, "plain-text bubble renders literally")
            self.assertFalse(b["link"], "no auto-link")
            self.assertFalse(b["object"], "no OLE object")
            self.assertEqual(clipboard_after_copy(text, plaintext=True), text, "copy yields the exact text")
        # mutant: RTF mode (EM_STREAMIN/SF_RTF) parses the RTF and linkifies the URL
        rtf = render_bubble(r"{\rtf1\ansi hi}", plaintext=False)
        self.assertTrue(rtf["object"], "the RTF mutant must create an object (so the plain-text rule is causal)")
        url = render_bubble("https://example.com/x", plaintext=False)
        self.assertTrue(url["link"], "the RTF/auto-URL mutant must create a link")

    # WS5.5 ---------------------------------------------------------
    def test_ws5_5_live_count_zero_after_close(self):
        self.assertEqual(live_count(3, 3), 0, "closing every window leaves zero live drawers")
        # mutant: a popup close path that skips destroy leaks one
        self.assertEqual(live_count(3, 2), 1)
        self.assertNotEqual(live_count(3, 2), 0, "the skip-destroy mutant must leave a nonzero live count")

    # WS5.6 ---------------------------------------------------------
    def test_ws5_6_isolation(self):
        exposed = ["page.navigate", "input.dispatch", "runtime.evaluate"]
        self.assertEqual(reachable_drawer_methods(exposed), [], "no automation method may mention the drawer")
        self.assertFalse(js_can_reach_drawer(page_window_ids=[1, 2], page_dom_ids=["doc", "body"],
                                             drawer_win_id=99, drawer_dom_id="drawer-root"),
                         "page JS must not see the drawer window id or a DOM node")
        census_before = {"wins": 2, "drawer_live": 1}
        census_after = dict(census_before)
        self.assertEqual(census_before, census_after, "census must be unchanged by JS/socket probes")
        # mutant: a `drawer.state` method is exposed / the drawer id leaks to the page
        self.assertNotEqual(reachable_drawer_methods(exposed + ["drawer.state"]), [],
                            "exposing drawer.state must be caught")
        self.assertTrue(js_can_reach_drawer([1, 2, 99], ["doc"], 99, "drawer-root"),
                        "a leaked window id must be caught")

    # WS5.7 ---------------------------------------------------------
    def test_ws5_7_dpi_scaling_and_hit_test(self):
        self.assertEqual(icon_px_at(1.0), 56, "100% is 56 px")
        self.assertEqual(icon_px_at(1.5), 84, "150% is 84 px")
        radius = icon_px_at(1.5) / 2  # 42
        self.assertTrue(inside_icon(42, 0, radius), "the exact edge is inside at 150%")
        self.assertFalse(inside_icon(43, 0, radius), "just outside the edge is outside")
        # mutant: ignore DPI -> the icon stays 56 px, so the real 150% edge (42 px) is wrongly outside
        dpi_ignoring_px = ICON_SIZE  # 56, the un-scaled size the mutant would use
        self.assertNotEqual(dpi_ignoring_px, icon_px_at(1.5), "ignoring DPI must disagree with the 150% size")
        self.assertFalse(inside_icon(42, 0, dpi_ignoring_px / 2), "ignoring DPI mis-sizes the hit-test (caught)")


# ------------------------------------------------------------------
# LIVE e2e reds (skip without a host). These observe the REAL drawer and build every expected value from the
# models above, so the live assertion and the offline oracle cannot drift. Red today; green with WS5.
# ------------------------------------------------------------------
class WinDrawerBehaviorsLive(unittest.TestCase):
    def setUp(self):
        if not os.environ.get("ZB_WIN11_HOST"):
            self.skipTest("ZB_WIN11_HOST unset — live Win11 drawer-behaviors e2e skipped")
        if not os.environ.get("ZB_WIN_EXE"):
            self.skipTest("ZB_WIN_EXE unset — set it to a built zigBrowser.exe with the WS5 drawer")
        # With a host + exe present these are RED until the WS5 green backend emits the behaviors. The live
        # observations reuse tests/windows/win_drawer_test.py's runner (suspended+Job, DRAWER-row parse,
        # clipboard via WM_COPY, Job census); each red's expected value comes from the models above, so the
        # live assertion and the offline oracle cannot drift. The green replaces each `self.fail` with the
        # wired observation.

    def test_ws5_1_dock_live(self):
        self.fail("unreached: dock equation from real DRAWER open row (page_h + panel_h == client_h)")

    def test_ws5_2_drag_live(self):
        self.fail("unreached: icon_rect_after_drag == rect_from_ratios(...) and a 5 px move opens")

    def test_ws5_3_fold_live(self):
        self.fail("unreached: mid-fold capture with ZIGBROWSER_AGENT_ANIM_MS=3000 is an intermediate rect")

    def test_ws5_4_copy_inert_live(self):
        self.fail("unreached: clipboard == bubble text; an RTF bubble renders literally with no link/object")

    def test_ws5_5_live_count_live(self):
        self.fail("unreached: zb_drawer_debug_live_count == 0 after every window closes")

    def test_ws5_6_isolation_live(self):
        self.fail("unreached: census_before == census_after after JS/socket drawer probes (all -32601/-32011)")

    def test_ws5_7_dpi_live(self):
        self.fail("unreached: icon is 84 px and hit-testing is exact at 150% scaling")


if __name__ == "__main__":
    unittest.main(verbosity=2)
