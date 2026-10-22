"""WS5.5b-2 terminal-live-row fix RED (UNREGISTERED). RoseCat bc224f7 (corrected shape).

The e01042c live run failed because the terminal `live` row never emits under kill-teardown. RoseCat's
corrected contract (a quit alone is WRONG — the loop would exit before the primary's DestroyWindow, so
`final` reads 1):

1. After the e2e multi-window spawn, drive the PRIMARY's normal close + WM_DESTROY (a posted WM_CLOSE to
   app->hwnd), so the primary decrements and quits; run_core's cleanup then destroys the extras and emits
   the terminal `live` with final 0. Gated on e2e + drawer + a parsed WINDOWS seam; spawn FIRST, primary
   close SECOND. An ordinary/screenshot run, the extra WndProc, a comment, a wrong gate, quit-before-spawn
   or a bare PostQuitMessage must NOT satisfy it.
2. Each of the FOUR WINDOWS-seam live cases (base peak, close-one, panel-fail, icon-fail) sets exactly
   ZB_SETTLE_KINDS=live.
3. After the `live` row the harness boundedly waits for the held process to exit NORMALLY and records that
   no TerminateJobObject/TerminateProcess was needed (the Job kill stays only a timeout/failure backstop).

Red now: the shim posts no WM_CLOSE to the primary after spawn, only three cases settle on `live`, and the
harness has no no-kill clean-exit record. Green adds all three.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHIM = ROOT / "src" / "webview2_shim.cpp"
BEH = ROOT / "tests" / "windows" / "win_drawer_behaviors_test.py"
WD = ROOT / "tests" / "windows" / "win_drawer_test.py"


class Ws55b2CleanCloseRed(unittest.TestCase):
    def test_shim_closes_the_primary_after_spawn(self):
        shim = SHIM.read_text(encoding="utf-8")
        # the green posts WM_CLOSE to the PRIMARY (app->hwnd) after spawn, gated on the WINDOWS seam, marked
        # ZB_WS55_CLEAN_CLOSE — so the primary's WM_DESTROY decrements before cleanup destroys the extras and
        # emits final 0. A bare PostQuitMessage/request_quit after spawn is the wrong shape.
        self.assertIn("ZB_WS55_CLEAN_CLOSE", shim, "the e2e multi-window run must close the PRIMARY after spawn")
        self.assertIn("PostMessageW(app->hwnd, WM_CLOSE", shim, "it must post WM_CLOSE to the primary, not just quit")

    def test_four_windows_seam_cases_settle_on_live(self):
        beh = BEH.read_text(encoding="utf-8")
        self.assertGreaterEqual(beh.count('ZB_SETTLE_KINDS="live"'), 4,
                                "all FOUR WINDOWS-seam live cases (base, close-one, panel-fail, icon-fail) settle on `live`")

    def test_harness_records_normal_exit_without_a_kill(self):
        wd = WD.read_text(encoding="utf-8")
        # after the `live` settle, the harness must bound-wait for a NORMAL exit and record that no kill was
        # needed (the owned-Job kill stays a timeout/failure backstop).
        self.assertIn("no_kill_needed", wd, "the harness must record a normal exit with no TerminateProcess/TerminateJobObject")


if __name__ == "__main__":
    unittest.main()
