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
