#!/usr/bin/env python3
r"""RED (unregistered; NavyCanyon 649755f7, the m8 1032dbb incident): when the cleanup's last census probe, given
only the remaining budget, expires at the total deadline AFTER a successful census that did not match, the shared
WebView2 cleanup must report deadline exhaustion with the last known survivor set — not a generic census failure.

The per-probe timeout equal to the remaining budget is correct and stays; only the diagnostic is wrong today: the
m8 run's 0.057 s last probe timed out and the helper answered "census failed: probe failed: TimeoutExpired",
losing the nine survivors it had just seen. Deletion stays at zero in every case. A first cleanup probe that stalls
before any census succeeded is still a census failure (there is no survivor set to report).

Uses the registered selftest's fakes (tests/windows/webview2_cleanup_test.py: FakeVM, the fake clock, both callers).
Run:  python3 -I tests/windows/webview2_cleanup_deadline_red_test.py
"""
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import webview2_cleanup as wc  # noqa: E402
from webview2_cleanup_test import HELPERS, FakeVM, Helper, M8Caller, SpikeDriverCaller  # noqa: E402

SURVIVORS = [f"('msedgewebview2', {pid}, '{ticks}')" for _, pid, ticks in sorted(HELPERS)]


class DeadlineDiagnostic(unittest.TestCase):
    def assert_exhaustion(self, why, vm):
        self.assertIn("did not return to the pre-run identities", why)
        for s in SURVIVORS:
            self.assertIn(s, why, "the last known survivor set is reported")
        self.assertNotIn("census failed", why)
        self.assertEqual(vm.rm_targets, [], "nothing is deleted")


class HelperDeadline(Helper, DeadlineDiagnostic):
    def test_a_probe_that_expires_at_the_deadline_after_a_nonmatching_census_reports_the_survivors(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)  # read 2 sees the survivors, read 3 never answers
        start = self.clock.now
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assert_exhaustion(why, vm)
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6)

    def test_slow_probes_that_run_out_of_budget_report_the_survivors(self):
        vm = FakeVM(linger=None, clock=self.clock, slow_s=25.0)  # 25 s, 25 s, then 10 s left: the probe expires
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assert_exhaustion(why, vm)

    def test_a_first_probe_that_stalls_is_still_a_census_failure(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=2)  # no census succeeded: no survivor set to report
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertIn("census failed", why)
        self.assertEqual(vm.rm_targets, [])


class SpikeDriverDeadline(SpikeDriverCaller, DeadlineDiagnostic):
    def test_the_spike_driver_reports_the_survivors_at_deadline_exhaustion(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assert_exhaustion(text, vm)


class M8Deadline(M8Caller, DeadlineDiagnostic):
    def test_the_m8_path_reports_the_survivors_at_deadline_exhaustion(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assert_exhaustion(text, vm)


if __name__ == "__main__":
    # only this file's cases (the imported classes' own tests run in the registered selftest)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    for cls in (HelperDeadline, SpikeDriverDeadline, M8Deadline):
        names = [n for n in loader.getTestCaseNames(cls) if n not in loader.getTestCaseNames(cls.__mro__[1])]
        suite.addTests(cls(n) for n in names)
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
