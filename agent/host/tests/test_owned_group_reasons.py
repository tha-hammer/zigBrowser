"""Every StopFailed names WHICH stop proof failed, as one fixed app-owned reason code (e567a51 on both Macs: the honest,
planted and forge runs failed closed with nothing left running, and nothing said which proof failed; the orchestrator
and RoseCat 7461: fixed reason codes only).

owned_group.StopFailed.reason is one of owned_group.REASONS:
- not_ours        the leader's ownership could not be proven (Darwin ps timing out or malformed), also when that is
                  the cleanup stop's failure after an earlier error;
- kill_refused    killpg failed with anything but ESRCH;
- reap_timeout    the leader was not reaped within STOP_S;
- table_unreadable the process table could not be read for the group-gone proof;
- members_alive   a group member was still alive at the bound;
- output_held     the group is proven gone but a process outside it still holds the run's output.
Signal-interposed like test_owned_group_failclosed, so these run plain and cannot signal: os.kill fails the test, and
os.killpg records and then always raises. Every stand-in exits by itself and is reaped.
Run: cd agent/host/tests && python -X dev -m unittest -v test_owned_group_reasons. Unregistered until the green.
"""
import os
import subprocess
import sys
import types
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_owned_group_failclosed as failclosed

from zb_agent_host import owned_group

QUICK = [sys.executable, "-c", "pass"]
EXPECTED = {"not_ours", "kill_refused", "reap_timeout", "table_unreadable", "members_alive", "output_held"}


class Reasons(failclosed.Interposed):
    def reason_of(self, call):
        with self.assertRaises(owned_group.StopFailed) as cm:
            call()
        reason = getattr(cm.exception, "reason", None)
        self.assertIn(reason, EXPECTED, f"not a fixed reason code: {reason!r}")
        return reason

    def test_the_reason_set_is_fixed(self):
        self.assertEqual(set(getattr(owned_group, "REASONS", ())), EXPECTED)

    def test_ownership_unprovable_is_not_ours(self):
        self.darwin(None)
        self.assertEqual(self.reason_of(lambda: owned_group.run(QUICK, timeout=10)), "not_ours")

    def test_a_cleanup_stop_after_an_error_keeps_the_inner_reason(self):
        self.darwin(None)
        mock.patch.object(owned_group, "_read_until", side_effect=OSError(5, "Input/output error")).start()
        self.assertEqual(self.reason_of(lambda: owned_group.run(QUICK, timeout=10)), "not_ours")

    def leader(self):
        p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(1)"], start_new_session=True)
        self.spawned.append(p)
        return p

    def test_a_refused_kill_is_kill_refused(self):
        p = self.leader()
        mock.patch.object(os, "killpg", side_effect=PermissionError(1, "Operation not permitted")).start()
        self.assertEqual(self.reason_of(lambda: owned_group.stop_group(p)), "kill_refused")

    def test_a_leader_not_reaped_in_time_is_reap_timeout(self):
        p = self.leader()
        mock.patch.object(owned_group, "STOP_S", 0.1).start()
        self.assertEqual(self.reason_of(lambda: owned_group.stop_group(p)), "reap_timeout")

    def test_an_unreadable_table_is_table_unreadable(self):
        mock.patch.object(owned_group, "_live_members", return_value=None).start()
        self.assertEqual(self.reason_of(lambda: owned_group.run(QUICK, timeout=10)), "table_unreadable")

    def test_a_member_alive_at_the_bound_is_members_alive(self):
        mock.patch.object(owned_group, "_live_members", return_value=[4242]).start()
        mock.patch.object(owned_group, "STOP_S", 0.1).start()
        self.assertEqual(self.reason_of(lambda: owned_group.run(QUICK, timeout=10)), "members_alive")

    def test_output_held_after_the_group_is_gone_is_output_held(self):
        real = owned_group._read_until
        calls = []

        def second_call_held(sel, chunks, until):
            calls.append(1)
            return real(sel, chunks, until) if len(calls) == 1 else False

        mock.patch.object(owned_group, "_read_until", side_effect=second_call_held).start()
        self.assertEqual(self.reason_of(lambda: owned_group.run(QUICK, timeout=10)), "output_held")


if __name__ == "__main__":
    unittest.main()
