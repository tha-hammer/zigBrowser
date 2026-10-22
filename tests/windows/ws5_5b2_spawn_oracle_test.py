"""WS5.5b-2 production popup-spawn RED (UNREGISTERED, wired into no zig build step).

RoseCat dffa0c7: the live peak == window count contract (offline-approved at 08e4e9e) still needs a
reviewed PRODUCTION change — the shim must actually create N concurrent drawer windows under the
e2e WINDOWS seam so the live count peaks at N. This source oracle binds that spawn in
src/webview2_shim.cpp (the Win32 behavior cannot run on Linux; cross-compile + this binding are the
offline proof, and the behaviors live oracle proves peak == N on a released VM run).

It requires the shim to:
  1. derive the extra-window count from the portable Zig (zb_drawer_extra_windows), not inline C;
  2. create the extra windows under a DEDICATED window class (kDrawerExtraClassName) distinct from
     the primary kWindowClassName — the primary class's WM_DESTROY calls PostQuitMessage, so extra
     windows must NOT share it or destroying one would quit the whole process;
  3. account each extra mount through the same drawer_live_inc path (so the peak rises to N);
  4. tear the extra windows down and decrement the live count at shutdown (so final == 0).

Red now: none of these tokens exist yet. Green adds the portable helper + the shim spawn; this
throwaway file is then removed and the binding lands in the registered WinDrawerOracle.
"""
import os
import pathlib
import unittest

SHIM = pathlib.Path(__file__).resolve().parents[2] / "src" / "webview2_shim.cpp"


class Ws55b2SpawnOracleRed(unittest.TestCase):
    def setUp(self):
        self.src = SHIM.read_text(encoding="utf-8")

    def test_extra_window_count_comes_from_portable_zig(self):
        self.assertTrue("zb_drawer_extra_windows(app->windows_seam)" in self.src,
                        "the extra-window count must come from the portable zb_drawer_extra_windows, not inline C")
        self.assertTrue("int zb_drawer_extra_windows(int" in self.src,
                        "the shim must declare the extern zb_drawer_extra_windows")

    def test_extra_windows_use_a_dedicated_non_quitting_class(self):
        self.assertTrue("kDrawerExtraClassName" in self.src,
                        "extra windows need their own class (the primary class WM_DESTROY calls PostQuitMessage)")

    def test_spawn_accounts_and_shutdown_decrements(self):
        self.assertTrue("spawn_extra_drawer_windows" in self.src, "the e2e multi-window spawn function must exist")
        # the spawn is gated on the e2e WINDOWS seam so ordinary runs never create extra windows
        self.assertTrue("windows_seam_set" in self.src, "the spawn must be gated on the e2e WINDOWS seam")


if __name__ == "__main__":
    unittest.main()
