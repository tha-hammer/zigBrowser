"""The R1 hard-gate case names WHICH stop proof failed, as a fixed reason code and nothing else (e567a51 on both Macs:
"probe run raised StopFailed" did not say which owned-group proof failed; the orchestrator and RoseCat 7461).

On the fake staged host of ms6_hard_gate_r1_case_test, setup's seam raises a StopFailed carrying `reason` and a
message holding a canary:
- a reason from the fixed set appears in the positive row's label as "reason=<code>";
- a reason outside the set appears as "reason=unknown" (an exception's attribute is not trusted text);
- the message canary never appears in any check label;
- the case's own copy of the codes (STOP_REASONS) is exactly owned_group.REASONS.
No process is started and no signal is sent (the same fakes as the base suite).
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_r1_reason_test. Unregistered until
the green.
"""
import os
import unittest

import ms6_hard_gate_r1_case_test as base

CANARY = "ZB-REASON-MSG-CANARY-4e1d"
RAISING = '''
class StopFailed(Exception):
    def __init__(self, message, reason):
        super().__init__(message)
        self.reason = reason
def run_in_owned_group(argv, *, env=None, pass_fds=(), timeout):
    raise StopFailed(RESULT["msg"], RESULT["reason"])
def probe_r1(wrapper, cli):  # as setup._sandboxed: a stop failure is no success, never an escaping exception
    try:
        return _probe_r1(wrapper, cli)
    except StopFailed:
        return False
'''


class ReasonInTheLabel(base.RunWithAFakeStagedHost):
    # Only this file's rows: the base suite's own rows run in ms6_hard_gate_r1_case_test.
    test_every_row_runs_and_is_released_with_its_own_cli = None
    test_each_rows_release_gets_that_rows_own_cli = None
    test_no_check_label_ever_carries_token_material = None
    test_a_failing_positive_shows_the_probes_rc_and_token_free_tails = None

    def setUp(self):
        super().setUp()
        path = os.path.join(self.prefix, "zb_agent_host", "setup.py")
        with open(path) as f:
            text = f.read()
        self.assertIn("def run_in_owned_group(", text)
        text = (text.replace("def run_in_owned_group(", "def _unused_run_in_owned_group(", 1)
                .replace("def probe_r1(", "def _probe_r1(", 1) + RAISING)
        with open(path, "w") as f:
            f.write(text)
        self.forget()

    def labels_for(self, reason):
        setup = self.fake_setup()
        setup.RESULT.update(msg=f"{CANARY} process group 4242", reason=reason)
        self.scratch = os.path.join(self.tmp, f"scratch-{reason}")
        os.mkdir(self.scratch)
        h = self.harness()
        h.checks = []
        self.case.run(h)
        return [label for _ok, label in h.checks]

    def test_a_fixed_reason_is_named_and_the_message_is_not(self):
        labels = self.labels_for("output_held")
        (line,) = [label for label in labels if label.startswith("positive: an honest CLI")]
        self.assertIn("probe run raised StopFailed (reason=output_held)", line)
        self.assertFalse([label for label in labels if CANARY in label], "the exception message reached a label")

    def test_an_unknown_reason_is_not_echoed(self):
        labels = self.labels_for("ZB-UNTRUSTED-REASON")
        (line,) = [label for label in labels if label.startswith("positive: an honest CLI")]
        self.assertIn("probe run raised StopFailed (reason=unknown)", line)
        self.assertFalse([label for label in labels if "ZB-UNTRUSTED-REASON" in label])


class TheCodesAgree(unittest.TestCase):
    def test_the_case_holds_exactly_owned_groups_codes(self):
        import importlib.util
        path = base.CASE.parents[3] / "agent" / "host" / "zb_agent_host" / "owned_group.py"
        spec = importlib.util.spec_from_file_location("zb_owned_group_codes", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        self.assertEqual(tuple(base.load_case().STOP_REASONS), tuple(mod.REASONS))


if __name__ == "__main__":
    unittest.main()
