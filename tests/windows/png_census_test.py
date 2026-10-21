#!/usr/bin/env python3
"""WS1.3 release-screenshot red (UNREGISTERED) — the fetched screenshot is a real, NON-UNIFORM PNG.

The png_census ORACLE (independent PNG fixtures: uniform/varied/filters/truncated/absent) is in the
registered-green tests/windows/png_census_selftest.py, which exercises the decoder regardless of this red.
This file is only the WS1.3 slice red: census the fetched screenshot (ZB_WIN_SHOT), RED today because WS1
is not built, so there is no screenshot to census. The real provenance-bound success path (launch the exe,
require exit 0, fetch a run-scoped non-uniform PNG) is tests/windows/screenshot_live_test.py (f2212e1/8f36ee7).

Unregistered (a red stays outside gate-registered steps); registers as the WS1 screenshot phase in green.
Run alone:  python3 -I tests/windows/png_census_test.py -v
"""
import importlib.util
import os
import pathlib
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("png_census", REPO / "tests" / "windows" / "png_census.py")
png_census = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(png_census)

SHOT = os.environ.get("ZB_WIN_SHOT", str(REPO / "zig-out" / "shot.png"))


class WS13Screenshot(unittest.TestCase):
    def test_release_screenshot_is_a_real_nonuniform_png(self):
        self.assertTrue(pathlib.Path(SHOT).exists(),
                        f"WS1.3 screenshot not produced yet: {SHOT} (needs the built exe + --screenshot; set ZB_WIN_SHOT)")
        c = png_census.census(SHOT)
        self.assertTrue(c["valid"], f"not a valid PNG: {c}")
        self.assertTrue(c["non_uniform"], f"the screenshot must be non-uniform (not blank): {c}")


if __name__ == "__main__":
    unittest.main()
