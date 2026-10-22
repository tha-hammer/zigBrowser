"""WS5.5b-2 terminal-live-row fix RED (UNREGISTERED). RoseCat a3bd708 / e01042c live-run finding.

The released e01042c Win11 run failed: the terminal `live <peak> <final>` row is emitted at run_core's
clean shutdown (after the message loop), but the owned-Job harness TerminateProcess-es the browser, so
clean shutdown never runs and the terminal row never appears. "Terminal 0" is unobservable under
kill-teardown.

APPROACH (for RoseCat to rule on before the green): after the e2e multi-window spawn, the shim posts a
CLEAN QUIT (gated on the WINDOWS seam) so the message loop ends, run_core's shutdown destroys every window
and emits the terminal `live` row BEFORE the harness kill — the owned-Job kill stays a backstop. The
WINDOWS-seam live tests then settle on the `live` row (ZB_SETTLE_KINDS=live), so the harness waits for the
clean-exit terminal row instead of tearing down at `open`.

Red now: the shim has no WINDOWS-seam clean-quit marker, and the live tests do not settle on `live`.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "webview2_shim.cpp"
BEH = ROOT / "tests" / "windows" / "win_drawer_behaviors_test.py"


class Ws55b2CleanQuitRed(unittest.TestCase):
    def test_shim_clean_quits_after_the_multiwindow_spawn(self):
        shim = SHIM.read_text(encoding="utf-8")
        # the green adds, gated on windows_seam_set and right after spawn_extra_drawer_windows, a clean quit
        # marked ZB_WS55_CLEAN_QUIT so run_core's shutdown emits the terminal `live` row before the kill.
        self.assertIn("ZB_WS55_CLEAN_QUIT", shim,
                      "the e2e multi-window run must post a clean quit so the terminal live row emits before kill")

    def test_windows_seam_live_tests_settle_on_the_live_row(self):
        beh = BEH.read_text(encoding="utf-8")
        # close-one + panel-fail + icon-fail must wait for the terminal `live` row, not settle on `open`.
        self.assertGreaterEqual(beh.count('ZB_SETTLE_KINDS="live"'), 3,
                                "the three WINDOWS-seam live tests must settle on the terminal `live` row")


if __name__ == "__main__":
    unittest.main()
