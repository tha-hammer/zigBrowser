"""WS5.5b-2 RED (UNREGISTERED, not wired into any zig build step).

The multi-window live PEAK must EQUAL the number of windows opened — proving the N drawers were
CONCURRENTLY live, not opened and closed one at a time. The existing `check_live` only asserts
`peak > 0`, so a serialized N-window run (peak == 1), or one where a mount is never accounted,
wrongly passes. This red pins `check_live_peak_matches`, added green in win_drawer_behaviors_test.

Red state: `check_live_peak_matches` does not exist yet -> these error. Green adds it + mutants to
the registered WinDrawerBehaviorsOracle and wires the live peak row to use it; this throwaway file
is then removed.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import win_drawer_behaviors_test as whb  # noqa: E402


class Ws55b2LivePeakRed(unittest.TestCase):
    def test_peak_equals_window_count(self):
        whb.check_live_peak_matches(2, 0, 2)  # true concurrency: both drawers live at the peak

    def test_serialized_peak_too_low_rejected(self):
        with self.assertRaises(AssertionError):
            whb.check_live_peak_matches(1, 0, 2)  # serial open/close, or a mount not accounted -> peak < n

    def test_overcount_peak_rejected(self):
        with self.assertRaises(AssertionError):
            whb.check_live_peak_matches(3, 0, 2)  # more live than windows -> accounting bug

    def test_leak_final_nonzero_rejected(self):
        with self.assertRaises(AssertionError):
            whb.check_live_peak_matches(2, 1, 2)  # a destroy not accounted -> final != 0


if __name__ == "__main__":
    unittest.main()
