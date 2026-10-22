"""EVERY R1 row fails on a stop failure, naming its fixed reason (RoseCat 7476: at e567a51 the planted and forge runs
also ended in StopFailed on both Macs, yet their expected "no R1" verdicts passed; only the positive row showed it).

On the fake staged host, setup's seam raises StopFailed(<canary message>, reason) for every run. For each of the
positive, planted, forge and hang rows the case must emit a FAILED check "<row>: the run's process group was proven
stopped (reason=<code>)", "reason=unknown" for a reason outside the fixed set, and no label may carry the canary
message or the untrusted reason text.
No process is started and no signal is sent (the same fakes as the base suite).
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_r1_reason_modes_test. Unregistered
until the green.
"""
import os
import unittest

import ms6_hard_gate_r1_reason_test as reason

ROWS = ("positive", "planted", "forge", "hang")


class EveryRowFailsOnAStopFailure(reason.ReasonInTheLabel):
    test_a_fixed_reason_is_named_and_the_message_is_not = None
    test_an_unknown_reason_is_not_echoed = None

    def checks_for(self, code):
        setup = self.fake_setup()
        setup.RESULT.update(msg=f"{reason.CANARY} process group 4242", reason=code)
        self.scratch = os.path.join(self.tmp, f"scratch-modes-{code}")
        os.mkdir(self.scratch)
        h = self.harness()
        h.checks = []
        self.case.run(h)
        return h.checks

    def assert_every_row_fails(self, checks, shown):
        for row in ROWS:
            with self.subTest(row=row):
                hits = [(ok, label) for ok, label in checks
                        if label.startswith(f"{row}: the run's process group was proven stopped")]
                self.assertEqual(len(hits), 1, f"{row}: no stop-proof check")
                ok, label = hits[0]
                self.assertFalse(ok, f"{row}: a stop failure passed")
                self.assertIn(f"reason={shown}", label)

    def test_a_fixed_reason_fails_every_row(self):
        checks = self.checks_for("output_held")
        self.assert_every_row_fails(checks, "output_held")
        self.assertFalse([label for _ok, label in checks if reason.CANARY in label])

    def test_an_unknown_reason_fails_every_row_unechoed(self):
        checks = self.checks_for("ZB-UNTRUSTED-REASON")
        self.assert_every_row_fails(checks, "unknown")
        self.assertFalse([label for _ok, label in checks if "ZB-UNTRUSTED-REASON" in label or reason.CANARY in label])


if __name__ == "__main__":
    unittest.main()
