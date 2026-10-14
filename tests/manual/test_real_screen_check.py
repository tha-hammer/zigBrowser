"""Unit checks of real_screen_check.py's verdict and environment, with fake
captures: no display, no browser. Run: python3 -m unittest tests/manual/test_real_screen_check.py"""

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import real_screen_check as rsc  # noqa: E402


def capture(width, height, paint):
    """An XWD dump (32 bpp, LSB first) whose pixel (x, y) is paint(x, y)."""
    header = struct.pack(">25I", 100, 7, 2, 24, width, height, 0, 0, 32, 0, 32, 32, width * 4, 4,
                         0xFF0000, 0x00FF00, 0x0000FF, 8, 0, 0, width, height, 0, 0, 0)
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            r, g, b = paint(x, y)
            pixels += struct.pack("<I", (r << 16) | (g << 8) | b)
    return rsc.Capture(header + bytes(pixels))


def drawn(x, y):
    """The page everywhere, with the icon's colour in a 40x40 square."""
    return rsc.ICON_RGB if 50 <= x < 90 and 50 <= y < 90 else rsc.PAGE_RGB


W, H = 120, 100
GOOD_WINDOW = capture(W, H, drawn)
# The screen is larger; the window sits at 10,20 on it.
GOOD_SCREEN = capture(W + 30, H + 40, lambda x, y: drawn(x - 10, y - 20) if x >= 10 and y >= 20 else (0, 0, 0))
BLANK_SCREEN = capture(W + 30, H + 40, lambda x, y: (0, 0, 0))
CROP = (10, 20, W, H)


class VerdictTest(unittest.TestCase):
    def test_page_and_icon_drawn_on_screen_and_in_the_window_pass(self):
        ok, detail = rsc.judge(GOOD_WINDOW, GOOD_SCREEN, CROP, need_icon=True)
        self.assertTrue(ok, detail)

    def test_a_good_window_buffer_with_blank_screen_pixels_fails(self):
        """The incident: the client's pixmap can hold the page while the
        screen shows nothing. The screen pixels are authoritative."""
        ok, detail = rsc.judge(GOOD_WINDOW, BLANK_SCREEN, CROP, need_icon=True)
        self.assertFalse(ok, detail)
        self.assertIn("screen page 0%", detail)

    def test_a_blank_window_buffer_fails_even_with_screen_pixels(self):
        ok, _ = rsc.judge(capture(W, H, lambda x, y: (0, 0, 0)), GOOD_SCREEN, CROP, need_icon=True)
        self.assertFalse(ok)

    def test_a_missing_icon_fails_only_when_the_icon_is_required(self):
        no_icon = capture(W, H, lambda x, y: rsc.PAGE_RGB)
        screen = capture(W + 30, H + 40, lambda x, y: rsc.PAGE_RGB)
        self.assertFalse(rsc.judge(no_icon, screen, CROP, need_icon=True)[0])
        self.assertTrue(rsc.judge(no_icon, screen, CROP, need_icon=False)[0])


def opened(x, y):
    """The page above, the panel over the bottom 40%."""
    return rsc.PANEL_RGB if y >= 60 else rsc.PAGE_RGB


class OpenDrawerTest(unittest.TestCase):
    def test_the_page_above_the_panel_on_screen_passes(self):
        screen = capture(W + 30, H + 40, lambda x, y: opened(x - 10, y - 20))
        ok, detail = rsc.judge_open(capture(W, H, opened), screen, CROP)
        self.assertTrue(ok, detail)

    def test_a_blank_screen_with_the_drawer_open_fails(self):
        ok, detail = rsc.judge_open(capture(W, H, opened), BLANK_SCREEN, CROP)
        self.assertFalse(ok, detail)
        self.assertIn("open screen page 0%, panel 0%", detail)

    def test_the_icon_is_found_where_its_colour_is(self):
        self.assertEqual(rsc.icon_centre(GOOD_SCREEN, CROP), (79, 89))
        self.assertIsNone(rsc.icon_centre(BLANK_SCREEN, CROP))


class FakeX11:
    """Stands in for real_screen_check.X11: records input instead of sending
    it, and the server grab around it."""

    def __init__(self, path, pointer_path, focus, parents, rect=(0, 0, 100, 100), wm=False, active=None,
                 lands=None):
        self._path, self._pointer_path, self._focus, self._parents = path, pointer_path, focus, parents
        self._rect, self._wm, self._active, self._lands = rect, wm, active, lands
        self.sent, self.grabs = [], []

    def grab(self):
        self.grabs.append("grab")

    def ungrab(self):
        self.grabs.append("ungrab")

    def viewable_rect(self, wid):
        return self._rect

    def wm_running(self):
        return self._wm

    def active(self):
        return self._active

    def path_at(self, x, y):
        return self._path(x, y)

    def pointer_path(self):
        return self._pointer_path

    def pointer(self):
        return self._lands or (self.sent[-1][1:] if self.sent and self.sent[-1][0] == "move" else (-1, -1))

    def focus(self):
        return self._focus

    def parent(self, w):
        return self._parents.get(w, 0)

    def move(self, x, y):
        self.sent.append(("move", x, y))

    def button(self):
        self.sent.append(("button",))

    def escape(self):
        self.sent.append(("escape",))


OURS, TERMINAL, FRAME = 0x400001, 0x700001, 0x300001
ON_TOP = staticmethod(lambda px, py: [FRAME, OURS])


class SafetyTest(unittest.TestCase):
    """Input goes only to our own window: viewable, active (with a window
    manager), on top at the point, holding the focus, all checked under one
    server grab before any XTest event (RoseCat 5393, 5395)."""

    def ready(self, **kw):
        args = dict(path=lambda px, py: [FRAME, OURS], pointer_path=[FRAME, OURS], focus=OURS, parents={})
        args.update(kw)
        return FakeX11(**args)

    def assert_refused(self, x, refused, sent=()):
        self.assertIsNotNone(refused)
        self.assertEqual(x.sent, list(sent))
        self.assertEqual(x.grabs, ["grab", "ungrab"], "the grab is always released")

    def test_our_window_ready_gets_the_click_inside_one_grab(self):
        x = self.ready(wm=True, active=OURS)
        self.assertIsNone(rsc.safe_click(x, OURS, 10, 10))
        self.assertEqual(x.sent, [("move", 10, 10), ("button",)])
        self.assertEqual(x.grabs, ["grab", "ungrab"])

    def test_a_covered_click_point_sends_nothing(self):
        x = self.ready(path=lambda px, py: [FRAME, TERMINAL])
        refused = rsc.safe_click(x, OURS, 10, 10)
        self.assert_refused(x, refused)
        self.assertTrue(refused.endswith("no input sent"), refused)

    def test_an_inactive_unmapped_or_unreadable_window_sends_nothing(self):
        for label, kw in (("another window is active", dict(wm=True, active=TERMINAL)),
                          ("the active property is unreadable", dict(wm=True, active=None)),
                          ("unmapped", dict(rect=None)),
                          ("the point is outside the window", dict(rect=(50, 50, 10, 10)))):
            with self.subTest(label):
                x = self.ready(**kw)
                self.assert_refused(x, rsc.safe_click(x, OURS, 10, 10))
                x = self.ready(**kw)
                if label != "the point is outside the window":
                    self.assert_refused(x, rsc.safe_escape(x, OURS))

    def test_a_click_needs_the_focus_too_not_only_the_active_window(self):
        """RoseCat 5400: active and focused are not the same thing."""
        for focus, parents in ((TERMINAL, {TERMINAL: 1}), (0, {})):
            x = self.ready(wm=True, active=OURS, focus=focus, parents=parents)
            refused = rsc.safe_click(x, OURS, 10, 10)
            self.assert_refused(x, refused)
            self.assertIn("focus", refused)
        x = self.ready(focus=1, path=lambda px, py: [FRAME, TERMINAL])  # PointerRoot over another window
        self.assert_refused(x, rsc.safe_click(x, OURS, 10, 10))
        x = self.ready(focus=1)  # PointerRoot, the point over ours
        self.assertIsNone(rsc.safe_click(x, OURS, 10, 10))

    def test_a_pointer_that_lands_elsewhere_moves_but_never_clicks_and_says_so(self):
        x = self.ready(lands=(11, 10))
        refused = rsc.safe_click(x, OURS, 10, 10)
        self.assert_refused(x, refused, [("move", 10, 10)])
        self.assertIn("it moved, no click sent", refused)
        x = self.ready(pointer_path=[FRAME, TERMINAL])
        self.assert_refused(x, rsc.safe_click(x, OURS, 10, 10), [("move", 10, 10)])

    def test_escape_only_with_the_focus_inside_our_window(self):
        for focus, pointer, parents, allowed in (
                (TERMINAL, [FRAME, OURS], {TERMINAL: 1}, False), (0, [FRAME, OURS], {}, False),
                (OURS, [], {}, True), (OURS + 7, [], {OURS + 7: OURS}, True),
                (1, [FRAME, TERMINAL], {}, False),  # PointerRoot: keys go where the pointer is
                (1, [FRAME, OURS], {}, True)):
            x = self.ready(pointer_path=pointer, focus=focus, parents=parents)
            refused = rsc.safe_escape(x, OURS)
            self.assertEqual(refused is None, allowed, (hex(focus), refused))
            self.assertEqual(x.sent, [("escape",)] if allowed else [])
            self.assertEqual(x.grabs, ["grab", "ungrab"])

    def test_a_window_covered_at_any_sample_point_is_not_judged(self):
        crop = (100, 50, 600, 300)
        corner = rsc.sample_points(crop)[0]
        covered = rsc.covered_points(OURS, crop, lambda px, py: [TERMINAL] if (px, py) == corner else [FRAME, OURS])
        self.assertEqual(covered, [corner])
        self.assertEqual(rsc.covered_points(OURS, crop, lambda px, py: [FRAME, OURS]), [])


class AnyPageTest(unittest.TestCase):
    def test_a_flat_window_is_blank_and_a_varied_one_is_drawn(self):
        flat = capture(W + 30, H + 40, lambda x, y: (0xE0, 0xE0, 0xE0))
        varied = capture(W + 30, H + 40, lambda x, y: ((x * 7) % 256, (y * 5) % 256, 90))
        self.assertFalse(rsc.judge_not_blank(capture(W, H, lambda x, y: (0xE0, 0xE0, 0xE0)), flat, CROP)[0])
        self.assertTrue(rsc.judge_not_blank(capture(W, H, lambda x, y: ((x * 7) % 256, (y * 5) % 256, 90)),
                                            varied, CROP)[0])


class EnvironmentTest(unittest.TestCase):
    def test_render_overrides_from_the_shell_never_reach_a_case(self):
        shell = {"DISPLAY": ":0", "XAUTHORITY": "/x/auth", "HOME": "/h", "PATH": "/usr/bin",
                 "ZIGBROWSER_SOCKET": "/run/zb.sock", "ZIGBROWSER_AGENT_DRAWER": "off", "ZB_DRAWER_VARIANT": "x",
                 **{name: "stale" for name in rsc.RENDER_ENV}}
        env = rsc.case_env(shell, Path("/w"), {"GDK_GL": "disable"})
        self.assertEqual((env["DISPLAY"], env["XAUTHORITY"], env["HOME"]), (":0", "/x/auth", "/h"))
        self.assertEqual(env["GDK_GL"], "disable")
        leaked = sorted(k for k, v in env.items() if v == "stale" or k.startswith(("ZIGBROWSER_", "ZB_")))
        self.assertEqual(leaked, [])
        self.assertEqual(env["XDG_DATA_HOME"], "/w/xdg_data_home")

    def test_the_render_list_names_every_variable_the_matrix_and_renderer_use(self):
        for name in ("GDK_GL", "GDK_DEBUG", "WEBKIT_DISABLE_COMPOSITING_MODE", "WEBKIT_DMABUF_RENDERER_FORCE_SHM",
                     "WEBKIT_DISABLE_DMABUF_RENDERER", "__EGL_VENDOR_LIBRARY_FILENAMES", "__GLX_VENDOR_LIBRARY_NAME",
                     "LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER"):
            self.assertIn(name, rsc.RENDER_ENV)


if __name__ == "__main__":
    unittest.main()
