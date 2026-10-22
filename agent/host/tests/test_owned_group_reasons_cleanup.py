"""A cleanup stop that fails with its OWN StopFailed keeps that reason (RoseCat 7476: test_owned_group_reasons only
covered a cleanup Refused, mapped to not_ours; the wrapper's inner-StopFailed path was untested).

The earlier read fails (OSError), ownership is proven (Linux /proc, our real child leading its own group), and the
interposed killpg refuses with EPERM: run() must raise StopFailed with reason kill_refused, caused by the OSError,
never a generic reason. Signal-interposed (os.kill fails the test; killpg records the leader and raises), so it runs
plain and cannot signal; the stand-in leader exits by itself and is reaped.
Run: cd agent/host/tests && python -X dev -m unittest -v test_owned_group_reasons_cleanup. Unregistered until the
green.
"""
import os
import sys
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_owned_group_failclosed as failclosed

from zb_agent_host import owned_group


class CleanupKeepsItsOwnReason(failclosed.Interposed):
    def test_an_earlier_error_then_a_refused_kill_is_kill_refused(self):
        calls = []

        def refuse(pid, sig):
            calls.append(pid)
            if not self.spawned or pid != self.spawned[-1].pid:
                raise AssertionError(f"killpg reached a pid that is not the run's leader: {pid}")
            raise PermissionError(1, "Operation not permitted (interposed: nothing was signalled)")

        mock.patch.object(os, "killpg", side_effect=refuse).start()
        mock.patch.object(owned_group, "_read_until", side_effect=OSError(5, "Input/output error")).start()
        with self.assertRaises(owned_group.StopFailed) as cm:
            owned_group.run([sys.executable, "-c", "pass"], timeout=10)
        self.assertEqual(getattr(cm.exception, "reason", None), "kill_refused")
        self.assertIsInstance(cm.exception.__cause__, OSError)
        self.assertEqual(calls, [self.spawned[0].pid], "ownership was proven and exactly the leader was asked")


if __name__ == "__main__":
    unittest.main()
