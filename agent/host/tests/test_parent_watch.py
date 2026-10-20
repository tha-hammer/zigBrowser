"""macOS plan rev 14 item 5 (RoseCat 6771, 6773): setup's parent watch on Darwin, as a pure sequence.

`zb_agent_host.parent_watch.arm(browser_pid, ops)` runs before any other setup work. `browser_pid` comes
from the browser itself (a captured `getppid()` would already be launchd's 1 if the browser died first,
and comparing it with itself proves nothing). Every failure kills setup's whole process group with
SIGKILL (`ops.killpg(own pgid, SIGKILL)`); nothing ever just returns or exits:

  1. `getppid() == browser_pid` and setup leads its group (`getpgid(0) == getpid()`), else kill;
  2. `register(browser_pid)` (kqueue EVFILT_PROC/NOTE_EXIT); any OSError counts as the browser's death: kill;
  3. re-check `getppid() == browser_pid` after registering (a reused pid: the watch may sit on a
     stranger, but the parent check cannot be fooled), else kill;
  4. only then `start_watcher(watch)`; `watch` kills the group when the wait returns OR raises.

The OS calls are injected, so this runs on Linux. Unregistered until the green.
"""
import signal
import unittest

try:
    from zb_agent_host import parent_watch
except ImportError:  # the red: the module does not exist yet
    parent_watch = None

BROWSER = 4242
SELF = 777


class FakeOps:
    """Records every call; `ppids` is the sequence getppid() returns, one value per call."""

    def __init__(self, ppids=(BROWSER, BROWSER), pgid=SELF, register_error=None):
        self.ppids = list(ppids)
        self.pgid = pgid
        self.register_error = register_error
        self.calls = []
        self.killed = []
        self.started = []

    def getppid(self):
        self.calls.append("getppid")
        return self.ppids.pop(0) if len(self.ppids) > 1 else self.ppids[0]

    def getpid(self):
        return SELF

    def getpgid(self, pid):
        assert pid == 0
        return self.pgid

    def register(self, pid):
        self.calls.append(("register", pid))
        if self.register_error is not None:
            raise self.register_error

    def start_watcher(self, watch):
        self.calls.append("start_watcher")
        self.started.append(watch)

    def killpg(self, pgid, sig):
        self.calls.append(("killpg", pgid, sig))
        self.killed.append((pgid, sig))


class ParentWatchArm(unittest.TestCase):
    def setUp(self):
        if parent_watch is None:
            self.fail("zb_agent_host.parent_watch is missing (rev 14 item 5)")

    def assertKilledOnce(self, ops):
        self.assertEqual(ops.killed, [(SELF, signal.SIGKILL)], f"the whole group, by SIGKILL, once: {ops.calls}")
        self.assertEqual(ops.started, [], f"no watcher after a kill: {ops.calls}")

    def test_all_good_arms_the_watcher_and_kills_nothing(self):
        ops = FakeOps()
        self.assertTrue(parent_watch.arm(BROWSER, ops))
        self.assertEqual(ops.killed, [])
        self.assertEqual(len(ops.started), 1)
        # Registration on the browser's pid, between the two parent checks, then the watcher.
        self.assertEqual(ops.calls, ["getppid", ("register", BROWSER), "getppid", "start_watcher"])

    def test_a_parent_already_gone_kills_before_registering(self):
        ops = FakeOps(ppids=(1, 1))  # re-parented to launchd: the browser died before setup ran
        self.assertFalse(parent_watch.arm(BROWSER, ops))
        self.assertKilledOnce(ops)
        self.assertNotIn(("register", BROWSER), ops.calls)

    def test_not_the_group_leader_kills(self):
        ops = FakeOps(pgid=SELF + 1)
        self.assertFalse(parent_watch.arm(BROWSER, ops))
        self.assertKilledOnce(ops)

    def test_a_registration_error_counts_as_death(self):
        for err in (ProcessLookupError(3, "No such process"), OSError(9, "Bad file descriptor"),
                    PermissionError(1, "Operation not permitted")):
            with self.subTest(err=type(err).__name__):
                ops = FakeOps(register_error=err)
                self.assertFalse(parent_watch.arm(BROWSER, ops))
                self.assertKilledOnce(ops)

    def test_a_parent_that_changes_after_registering_kills(self):
        # The reused-pid case: the registration succeeded (on whatever now holds the pid), but setup's
        # parent is no longer the browser.
        ops = FakeOps(ppids=(BROWSER, 1))
        self.assertFalse(parent_watch.arm(BROWSER, ops))
        self.assertKilledOnce(ops)

    def test_the_watcher_kills_the_group_when_the_wait_ends_or_fails(self):
        ops = FakeOps()
        self.assertTrue(parent_watch.arm(BROWSER, ops))
        watch = ops.started[0]
        watch(lambda: None)  # NOTE_EXIT arrived
        self.assertEqual(ops.killed, [(SELF, signal.SIGKILL)])
        ops.killed.clear()
        def failing_wait():
            raise OSError(4, "Interrupted system call")
        watch(failing_wait)  # kevent failed: still the browser's death as far as setup knows
        self.assertEqual(ops.killed, [(SELF, signal.SIGKILL)])


if __name__ == "__main__":
    unittest.main()
