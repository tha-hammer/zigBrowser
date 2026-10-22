"""Without os.waitid (macOS's Python 3.12), the no-wait exit check polls the kqueue once (found while writing 261640d:
_exited_now called _await_unreaped(pid, now), which registered NOTE_EXIT and returned False at the elapsed deadline
without ever polling, so on a Mac a leader that HAD exited was never seen as exited without waiting).

With os.waitid hidden from owned_group and select's kqueue faked (no process, no signal):
- an exit already pending at registration time: _exited_now is True, after one zero-timeout poll;
- a leader still running: _exited_now is False, and it never blocks (the poll's timeout is 0);
- a leader already reaped or gone (ESRCH at registration): True, as before;
- _await_unreaped with a deadline already passed still polls once before giving up.
Run: cd agent/host/tests && python -X dev -m unittest -v test_owned_group_kqueue_poll. Unregistered until the green.
"""
import os
import types
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import owned_group


class _NoWaitid:
    """owned_group's view of os, without waitid (as on macOS); everything else is the real os."""

    def __getattr__(self, name):
        if name == "waitid":
            raise AttributeError(name)
        return getattr(os, name)


class FakeKqueue:
    def __init__(self, pending, register_error=None):
        self.pending, self.register_error, self.timeouts = pending, register_error, []

    def control(self, changes, max_events, timeout=None):
        self.timeouts.append(timeout)
        if changes:
            if self.register_error:
                raise self.register_error
            return []
        return ["NOTE_EXIT"] if self.pending else []

    def close(self):
        pass


class KqueuePoll(unittest.TestCase):
    def kq(self, pending, register_error=None):
        kq = FakeKqueue(pending, register_error)
        fake_select = types.SimpleNamespace(kqueue=lambda: kq, kevent=lambda *a, **kw: ("kevent", a, kw),
                                            KQ_FILTER_PROC=-5, KQ_EV_ADD=1, KQ_EV_ONESHOT=16, KQ_NOTE_EXIT=0x80000000)
        p1 = mock.patch.object(owned_group, "select", fake_select)
        p2 = mock.patch.object(owned_group, "os", _NoWaitid())
        p1.start()
        p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)
        return kq

    def test_an_exit_already_pending_is_seen_without_waiting(self):
        kq = self.kq(pending=True)
        self.assertIs(owned_group._exited_now(4242), True)
        self.assertTrue(kq.timeouts and all(t in (0, 0.0) for t in kq.timeouts), kq.timeouts)

    def test_a_running_leader_is_not_exited_and_nothing_blocks(self):
        kq = self.kq(pending=False)
        self.assertIs(owned_group._exited_now(4242), False)
        self.assertTrue(all(t in (0, 0.0) for t in kq.timeouts), f"a poll could block: {kq.timeouts}")

    def test_esrch_at_registration_is_exited(self):
        self.kq(pending=False, register_error=ProcessLookupError(3, "No such process"))
        self.assertIs(owned_group._exited_now(4242), True)

    def test_an_elapsed_deadline_still_polls_once(self):
        kq = self.kq(pending=True)
        self.assertIs(owned_group._await_unreaped(4242, 0.0), True)
        self.assertGreaterEqual(len(kq.timeouts), 2, "registered, but never polled")


if __name__ == "__main__":
    unittest.main()
