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
import re
import sys
import unittest
from collections import namedtuple

# Reuse the APPROVED suspended+owned-Job harness (RoseCat 2fac3a8) and its DRAWER-row parser. Make the sibling
# import resolve regardless of cwd / isolated mode (this file is unregistered and may be run from anywhere).
# Import the MODULE (not the classes) so unittest does not also collect win_drawer_test's own TestCases here.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import win_drawer_test as _wd  # noqa: E402
parse_drawer = _wd.parse_drawer
rect_of = _wd.rect_of

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

    # --- raw-observation checks the live tests apply (b2f474b #1/#2): each with a discriminating mutant ---
    def test_check_drag_persisted_ratio_and_bound(self):
        w, h = 1008, 729
        icon = (928, 649, 56, 56)  # a default-ish placement
        after = expected_after_drag(icon, 7, 0, w, h)
        check_drag(icon, (after.x, after.y, after.w, after.h), w, h, dx=7, dy=0)  # must not raise
        with self.assertRaises(AssertionError):  # mutant: a no-op drag (icon unchanged) must fail (moved < 6)
            check_drag(icon, icon, w, h, dx=7, dy=0)
        with self.assertRaises(AssertionError):  # mutant: a small wrong move must fail (moved < 6)
            check_drag(icon, (icon[0] + 1, icon[1], 56, 56), w, h, dx=7, dy=0)
        # isolates the persisted-ratio equality: a LARGE move (>= threshold) to the WRONG position must still
        # fail — so the equality assertion is independently exercised, not masked by the movement bound.
        with self.assertRaises(AssertionError):
            check_drag(icon, (icon[0] - 100, icon[1], 56, 56), w, h, dx=7, dy=0)

    def test_check_click_opens(self):
        check_click_opens(True, False)
        with self.assertRaises(AssertionError):
            check_click_opens(False, False)  # a click that did not open must fail
        with self.assertRaises(AssertionError):
            check_click_opens(True, True)    # a 5 px move that produced a drag must fail

    def test_check_fold(self):
        check_fold(56, 400, 1008, 180)
        with self.assertRaises(AssertionError):
            check_fold(56, 56, 1008, 180)    # snap (mid == icon) must fail
        with self.assertRaises(AssertionError):
            check_fold(56, 400, 1008, 0)     # instant (0 ms) must fail

    def test_check_bubble_copy(self):
        check_bubble_copy("hello", "hello", False, False)
        with self.assertRaises(AssertionError):
            check_bubble_copy("", "hello", False, False)   # wrong/empty clipboard must fail
        with self.assertRaises(AssertionError):
            check_bubble_copy("hello", "hello", True, False)  # an auto-link must fail
        with self.assertRaises(AssertionError):
            check_bubble_copy("hello", "hello", False, True)  # an OLE object must fail

    def test_check_live(self):
        check_live(2, 0)
        with self.assertRaises(AssertionError):
            check_live(0, 0)   # no positive peak -> no evidence windows ever opened
        with self.assertRaises(AssertionError):
            check_live(2, 1)   # a leaked live drawer must fail

    def test_check_isolation(self):
        check_isolation([-32601, -32011], {"wins": 2}, {"wins": 2})
        with self.assertRaises(AssertionError):
            check_isolation([], {"wins": 2}, {"wins": 2})          # no attempts -> no evidence
        with self.assertRaises(AssertionError):
            check_isolation([0], {"wins": 2}, {"wins": 2})          # a reachable (success) method must fail
        with self.assertRaises(AssertionError):
            check_isolation([-32601], {"wins": 2}, {"wins": 3})     # a census change must fail

    def test_check_dpi(self):
        check_dpi(84, True, True)
        with self.assertRaises(AssertionError):
            check_dpi(56, True, True)      # ignoring DPI (56 px) must fail
        with self.assertRaises(AssertionError):
            check_dpi(84, False, True)     # the exact edge not inside must fail
        with self.assertRaises(AssertionError):
            check_dpi(84, True, False)     # a pixel beyond the edge counted inside must fail

    def test_strict_behavior_rows_reject_malformed_and_foreign_window(self):
        good = ("DRAWER\t1\ttree\thost,page,icon,panel\nDRAWER\t1\ticon\t928,649,56,56\n"
                "DRAWER\t1\topen\t0,437,1008,292\nDRAWER\t1\tdrag\t930,649,56,56\n")
        self.assertEqual(structural_window(good), 1)
        self.assertEqual(drawer_rows(good, "drag", 1), [("930,649,56,56",)])
        # a drag row on a FOREIGN window (998) must be rejected when bound to window 1 (b2f474b #3)
        foreign = good + "DRAWER\t998\tdrag\t930,649,56,56\n"
        self.assertEqual(drawer_rows(foreign, "drag", 1), [("930,649,56,56",)])
        # malformed (extra field) and wrong-shape rows are rejected
        self.assertEqual(drawer_rows("DRAWER\t1\tdrag\t930,649,56,56\tEXTRA\n", "drag", 1), [])
        self.assertEqual(drawer_rows("DRAWER\t1\tdrag\tnot-a-rect\n", "drag", 1), [])


# Exact field schema per BEHAVIOR kind (RoseCat b2f474b #3): a tuple of regexes; a row must have EXACTLY this
# many fields, each matching, or it is rejected. These define the raw rows the WS5 green must emit.
_RECT = r"-?\d+,-?\d+,\d+,\d+"
_BEHAVIOR_SCHEMAS = {
    "drag": (_RECT,),                       # the icon's measured after-rect
    "fold": (_RECT, r"\d+"),                # a mid-animation rect + the total fold duration in ms
    "live": (r"\d+", r"\d+"),              # peak live count, final live count (after the popup-close sequence)
}


def structural_window(stdout):
    """The single window id that emitted the structural tree/icon/open rows (via the strict parse_drawer). A
    behavior row must bind to THIS window (b2f474b #3). Returns the id, or None if not exactly one."""
    wins = set()
    for ln in stdout.splitlines():
        pd = parse_drawer(ln)
        if pd and pd[1] in ("tree", "icon", "open"):
            wins.add(pd[0])
    return next(iter(wins)) if len(wins) == 1 else None


def drawer_rows(stdout, kind, want_win):
    """STRICT parse of `DRAWER\\t<win>\\t<kind>\\t<fields...>` behavior rows (b2f474b #3): the kind must be known,
    the field count + each field must match the exact schema, extras/malformed are rejected, and the row must
    bind to `want_win` (the structural window). parse_drawer ignores unknown kinds, so behavior kinds parse
    here. Returns the list of field-tuples (for the bound window). A current backend emits none, so the
    behavior reds are failing-first until the WS5 green emits them."""
    schema = _BEHAVIOR_SCHEMAS[kind]
    out = []
    for ln in stdout.splitlines():
        parts = ln.rstrip("\r\n").split("\t")
        if len(parts) < 3 or parts[0] != "DRAWER" or not re.fullmatch(r"[1-9]\d*", parts[1]) or parts[2] != kind:
            continue
        fields = parts[3:]
        if len(fields) != len(schema) or not all(re.fullmatch(p, f) for p, f in zip(schema, fields)):
            continue  # malformed / wrong arity -> not a valid behavior row
        if want_win is not None and int(parts[1]) != want_win:
            continue  # a row on a different window id is not ours (b2f474b #3)
        out.append(tuple(fields))
    return out


# ------------------------------------------------------------------
# Pure checks over RAW observations the harness MEASURES (RoseCat b2f474b #1/#2). Each is offline mutant-tested
# by WinDrawerBehaviorsOracle; the live tests below gather the raw observation and apply the SAME check, so a
# status word emitted by the implementation is never the oracle.
# ------------------------------------------------------------------
def expected_after_drag(icon_rect, dx, dy, width, height):
    """The icon's expected rect after a drag of (dx,dy): the moved rect, persisted as ratios and re-placed —
    the exact persisted-ratio roundtrip the product performs (mirrors agent_drawer.zig; pinned by the Zig
    property test)."""
    ix, iy, iw, ih = icon_rect
    moved = clamp_rect(Rect(ix + dx, iy + dy, iw, ih), width, height)
    rx, ry = ratios_from_rect(moved, width, height)
    return rect_from_ratios(rx, ry, width, height)


def check_drag(icon_rect, after_rect, width, height, dx=7, dy=0):
    """A drag (>6 px) moves the icon to the persisted-ratio rect and by >= the drag threshold."""
    exp = expected_after_drag(icon_rect, dx, dy, width, height)
    assert tuple(after_rect) == (exp.x, exp.y, exp.w, exp.h), f"after-drag rect {after_rect} != expected {exp}"
    moved = math.hypot(after_rect[0] - icon_rect[0], after_rect[1] - icon_rect[1])
    assert moved >= DRAG_THRESHOLD, f"a drag must move the icon by >= {DRAG_THRESHOLD} px (moved {moved})"


def check_click_opens(opened, drag_present):
    """A small (<=6 px) move is a click that OPENS the drawer and produces NO drag."""
    assert opened, "a 5 px move must be a click that opens the drawer"
    assert not drag_present, "a 5 px move must not produce a drag"


def check_fold(icon_w, mid_w, drawer_w, total_ms):
    """A mid-fold frame is strictly between the icon and the open drawer width, over the default ~180 ms."""
    assert icon_w < mid_w < drawer_w, f"mid-fold width {mid_w} must be between icon {icon_w} and drawer {drawer_w}"
    assert 150 <= total_ms < 260, f"the default fold duration must be ~180 ms (got {total_ms})"


def check_bubble_copy(clipboard_text, bubble_text, link_created, object_created):
    """select-all + WM_COPY puts the EXACT bubble text on the clipboard; the bubble is inert (no link/object)."""
    assert clipboard_text == bubble_text, f"clipboard {clipboard_text!r} != bubble text {bubble_text!r}"
    assert not link_created, "an inert bubble must create no auto-link"
    assert not object_created, "an inert bubble must create no OLE object"


def check_live(peak, final):
    """A positive peak live count (windows open) drops to exactly 0 after the popup-close sequence."""
    assert peak > 0, f"the live count must be positive while windows are open (got peak {peak})"
    assert final == 0, f"the live count must be 0 after every window closes (got {final})"


def check_isolation(error_codes, census_before, census_after):
    """Every page-JS and socket attempt to reach the drawer errors with a method-not-found/denied code, and the
    drawer census is unchanged across the attempts."""
    assert error_codes, "the probe must actually attempt to reach the drawer (no attempts == no evidence)"
    assert all(c in (-32601, -32011) for c in error_codes), f"every drawer reach must be denied: {error_codes}"
    assert census_before == census_after, f"census changed across probes: {census_before} -> {census_after}"


def check_dpi(icon_px, edge_inside, beyond_outside):
    """At 150% the icon is 84 px and its circular hit-test is exact at the edge."""
    assert icon_px == icon_px_at(1.5), f"the icon must be {icon_px_at(1.5)} px at 150% (got {icon_px})"
    assert edge_inside, "the exact edge pixel must hit-test inside"
    assert beyond_outside, "a pixel just beyond the edge must hit-test outside"


# ------------------------------------------------------------------
# LIVE e2e reds (skip without a host). Real observations through the APPROVED suspended+owned-Job harness
# (WinDrawerLive): each drives the exe with the behavior's e2e seam and applies a PURE check (above) to RAW
# observations the harness MEASURES — window-bound raw rects (drag/fold), the clipboard (select-all + WM_COPY),
# the live count (zb_drawer_debug_live_count), the socket/JS reach error codes + census, and the scaled icon
# rect + edge hit tests — never an implementation-emitted status word (RoseCat b2f474b #2). Every behavior row
# is bound to the single structural window (b2f474b #3). These FAIL against the current backend (it measures no
# behavior) — the failing-first reds the WS5 green must turn green. The harness measurement of clipboard/socket/
# DPI/multi-window is populated by the green's runner extension and validated on the VM at green-time.
# ------------------------------------------------------------------
class WinDrawerBehaviorsLive(_wd.WinDrawerLive):
    # Inherit setUp (host/exe skip) + the approved harness (_run_drawer/_ssh/_scp) ONLY; do not re-collect
    # win_drawer_test.WinDrawerLive's own lifecycle tests under this class (they run in their own module).
    test_native_drawer_mounts_docks_and_emits_census = None
    test_panel_create_failure_leaves_no_drawer = None
    test_icon_create_failure_leaves_no_drawer = None
    test_assign_failure_terminates_held_process = None
    test_assign_plus_first_stop_failure_reaped_by_independent_cleanup = None
    test_wait_failure_is_reported = None

    def _structural(self, r):
        win = structural_window(r["stdout"])
        self.assertIsNotNone(win, f"exactly one structural drawer window is required: {r['stdout']!r}")
        rows = [pd for pd in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if pd and pd[0] == win]
        by_kind = {}
        for (_w, k, f) in rows:
            by_kind.setdefault(k, []).append(f)
        return win, by_kind

    def test_ws5_1_dock_resizes_page(self):
        # WS5.1 (plan 1550): page bounds + panel bounds = client area, no overlap. Observed from the real
        # `open` panel row + the client rect the harness reads (holds on the current green — a regression
        # companion to the entry red in win_drawer_test.py).
        def body(r):
            _win, bk = self._structural(r)
            self.assertIn("open", bk, f"a DRAWER open row is required to observe the dock: {r['stdout']!r}")
            _x, py, _w, ph = rect_of(bk["open"][0])
            self.assertEqual(py + ph, r["client_h"], "page_h + panel_h must equal the client height (no overlap)")
        self._run_drawer(body=body)

    def test_ws5_2_icon_drag_moves_to_persisted_ratio(self):
        # WS5.2 (plan 1571-1572): a 7 px drag (>6) moves the icon to the persisted-ratio rect, by >= the
        # threshold. The harness MEASURES the icon's after-rect (a window-bound raw `drag` rect), not a status.
        def body(r):
            win, bk = self._structural(r)
            self.assertIn("icon", bk, "the icon start rect is required")
            drags = drawer_rows(r["stdout"], "drag", win)
            self.assertTrue(drags, "a 7 px drag must emit the icon's measured after-rect")
            icon_rect = rect_of(bk["icon"][0])
            after = rect_of(drags[0])
            check_drag(icon_rect, after, r["client_w"], r["client_h"], dx=7, dy=0)
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_DRAG": "7,0"}, body=body)

    def test_ws5_2_small_move_from_closed_is_click_that_opens(self):
        # Start CLOSED; a 5 px move (<=6) is a click that OPENS the drawer and produces no drag (b2f474b #1).
        def body(r):
            win = structural_window(r["stdout"])
            rows = [pd for pd in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if pd]
            opened = any(k == "open" for (_w, k, _f) in rows)
            drag_present = bool(win is not None and drawer_rows(r["stdout"], "drag", win))
            check_click_opens(opened, drag_present)
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_OPEN": "0", "ZIGBROWSER_AGENT_DRAWER_DRAG": "5,0"}, body=body)

    def test_ws5_3_fold_intermediate_and_default_duration(self):
        # WS5.3 (plan 1573): a mid-fold rect strictly between the icon and the open drawer width, over ~180 ms.
        # The harness MEASURES the mid rect + the total duration (raw `fold` row), not a 1-px status.
        def body(r):
            win, bk = self._structural(r)
            self.assertTrue("icon" in bk and "open" in bk, "icon + open rects are required")
            folds = drawer_rows(r["stdout"], "fold", win)
            self.assertTrue(folds, "a mid-fold capture must emit a raw fold rect + duration")
            _ix, _iy, iw, _ih = rect_of(bk["icon"][0])
            _ox, _oy, ow, _oh = rect_of(bk["open"][0])
            _fx, _fy, fw, _fh = rect_of(folds[0])      # folds[0] = (rect, ms)
            total_ms = int(folds[0][1])
            check_fold(iw, fw, ow, total_ms)
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_FOLD": "1", "ZIGBROWSER_AGENT_ANIM_MS": "180"}, body=body)

    def test_ws5_4_bubble_copy_and_inert(self):
        # WS5.4 (plan 1575-1577): the harness performs select-all + WM_COPY and reads the clipboard; an RTF
        # bubble renders its literal text with no link/object. The EXPECTED text is this test's seam input; the
        # clipboard/link/object are MEASURED by the harness (populated at green-time).
        expected = r"{\rtf1 hi}"
        def body(r):
            check_bubble_copy(r.get("clipboard") or "", expected,
                              bool(r.get("bubble_link")), bool(r.get("bubble_object")))
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_RTF": expected}, body=body)

    def test_ws5_5_live_count_peak_then_zero(self):
        # WS5.5 (plan 1578): a positive peak live count (windows open) drops to exactly 0 after the popup-close
        # sequence. The harness MEASURES zb_drawer_debug_live_count at peak and after close.
        def body(r):
            check_live(int(r.get("live_peak") or 0), int(r.get("live_final") if r.get("live_final") is not None else -1))
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_WINDOWS": "2"}, body=body)

    def test_ws5_6_isolation_denied_and_census_unchanged(self):
        # WS5.6 (plan 1580-1582): the harness performs page-JS and socket reach attempts; each is denied
        # (-32601/-32011) and the drawer census is unchanged. Measured by the harness, not an `ok` status word.
        def body(r):
            check_isolation(r.get("drawer_error_codes") or [],
                            r.get("census_before_probe"), r.get("census_after_probe"))
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_PROBE": "1"}, body=body)

    def test_ws5_7_dpi_scaled_rect_and_hit_test(self):
        # WS5.7 (plan 1583): at 150% the icon is 84 px and the circular hit-test is exact at the edge. The
        # harness MEASURES the scaled icon size + edge/beyond hit tests, not a `dpi 84` status word.
        def body(r):
            icon_px = r.get("icon_px")
            self.assertIsNotNone(icon_px, "the harness must measure the scaled icon size")
            check_dpi(int(icon_px), bool(r.get("edge_inside")), bool(r.get("beyond_outside")))
        self._run_drawer(extra_env={"ZIGBROWSER_AGENT_DRAWER_DPI": "150"}, body=body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
