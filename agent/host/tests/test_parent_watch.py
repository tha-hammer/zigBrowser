"""macOS plan rev 14 item 5 (RoseCat 6771, 6773): setup's parent watch on Darwin, as a pure sequence.

`zb_agent_host.parent_watch.arm(browser_pid, ops)` runs before any other setup work. `browser_pid` comes
from the browser itself (a captured `getppid()` would already be launchd's 1 if the browser died first,
and comparing it with itself proves nothing). Every failure kills setup's whole process group with
SIGKILL (`ops.killpg(own pgid, SIGKILL)`); nothing ever just returns or exits. The one exception is
a setup that does not lead its own group: it never `killpg`s a group it does not lead (that could be the
browser's), and since `arm` runs before setup starts any child it kills only itself (`ops.kill`):

  1. `getppid() == browser_pid` and setup leads its group (`getpgid(0) == getpid()`), else kill;
  2. `register(browser_pid)` (kqueue EVFILT_PROC/NOTE_EXIT); any OSError counts as the browser's death: kill;
  3. re-check `getppid() == browser_pid` after registering (a reused pid: the watch may sit on a
     stranger, but the parent check cannot be fooled), else kill;
  4. only then `start_watcher(watch)`; `watch` kills the group when the wait returns OR raises.

The OS calls are injected, so this runs on Linux. Unregistered until the green.
"""
import signal
import unittest

import support  # noqa: F401  (puts the helper package on sys.path, as every host test does)

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
        self.killed.append(("killpg", pgid, sig))

    def kill(self, pid, sig):
        self.calls.append(("kill", pid, sig))
        self.killed.append(("kill", pid, sig))


class ParentWatchArm(unittest.TestCase):
    def setUp(self):
        if parent_watch is None:
            self.fail("zb_agent_host.parent_watch is missing (rev 14 item 5)")

    def assertKilledOnce(self, ops, how="killpg"):
        self.assertEqual(ops.killed, [(how, SELF, signal.SIGKILL)], f"{how} of {SELF}, by SIGKILL, once: {ops.calls}")
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

    def test_not_the_group_leader_kills_only_itself_never_a_group_it_does_not_lead(self):
        for ppids in ((BROWSER, BROWSER), (1, 1)):
            with self.subTest(ppids=ppids):
                ops = FakeOps(ppids=ppids, pgid=SELF + 1)  # its group is someone else's, maybe the browser's
                self.assertFalse(parent_watch.arm(BROWSER, ops))
                self.assertKilledOnce(ops, how="kill")
                self.assertNotIn(("register", BROWSER), ops.calls)

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
        self.assertEqual(ops.killed, [("killpg", SELF, signal.SIGKILL)])
        ops.killed.clear()
        def failing_wait():
            raise OSError(4, "Interrupted system call")
        watch(failing_wait)  # kevent failed: still the browser's death as far as setup knows (no raise)
        self.assertEqual(ops.killed, [("killpg", SELF, signal.SIGKILL)])


class FakeSessionOps:
    def __init__(self, pids=(), allowed=(), identities=None, available=True, signalable=None):
        self.pids = list(pids)
        self.allowed = set(allowed)
        self.identities = {pid: list(values) for pid, values in (identities or {}).items()}
        self.available = available
        self.signalable = set(pids if signalable is None else signalable)
        self.calls = []
        self.killed = []
        self.logs = []

    def sandbox_check_available(self):
        self.calls.append("available")
        return self.available

    def getpid(self):
        return SELF

    def list_pids(self):
        self.calls.append("list")
        return tuple(self.pids)

    def unique_id(self, pid):
        self.calls.append(("unique", pid))
        values = self.identities.get(pid, [pid * 100])
        if len(values) > 1:
            return values.pop(0)
        return values[0] if values else None

    def can_signal(self, pid):
        self.calls.append(("can-signal", pid))
        return pid in self.signalable

    def sandbox_allows_canary(self, pid, path):
        self.calls.append(("sandbox", pid, path))
        return pid in self.allowed

    def kill(self, pid, sig):
        self.calls.append(("kill", pid, sig))
        self.killed.append((pid, sig))
        self.pids.remove(pid)

    def sleep(self, _seconds):
        pass

    def log(self, message):
        self.logs.append(message)


class SessionReaperDecision(unittest.TestCase):
    CANARY = "/private/tmp/zb-agent-session-0123456789abcdef0123456789abcdef"

    def test_only_stable_sandbox_match_is_killed(self):
        ops = FakeSessionOps(pids=(0, 1, BROWSER, SELF, 30, 40), allowed=(30,),
                             identities={30: (700, 700, 700), 40: (800, 800)})
        self.assertTrue(parent_watch.reap_session(BROWSER, self.CANARY, ops, reaper_pid=SELF))
        self.assertEqual(ops.killed, [(30, signal.SIGKILL)])
        kill_at = ops.calls.index(("kill", 30, signal.SIGKILL))
        self.assertEqual(ops.calls[kill_at - 1], ("unique", 30),
                         "p_uniqueid must be the operation immediately before kill")
        self.assertNotIn(("sandbox", BROWSER, self.CANARY), ops.calls)
        self.assertNotIn(("sandbox", SELF, self.CANARY), ops.calls)

    def test_pid_reuse_after_classification_is_never_signalled(self):
        ops = FakeSessionOps(pids=(30,), allowed=(30,), identities={30: (700, 700, 701)})
        self.assertTrue(parent_watch.reap_session(BROWSER, self.CANARY, ops, reaper_pid=SELF,
                                                  max_passes=1, empty_passes=1))
        self.assertEqual(ops.killed, [])

    def test_a_foreign_sandbox_match_is_never_classified_or_signalled(self):
        ops = FakeSessionOps(pids=(30,), allowed=(30,), signalable=())
        self.assertTrue(parent_watch.reap_session(BROWSER, self.CANARY, ops, reaper_pid=SELF,
                                                  max_passes=1, empty_passes=1))
        self.assertEqual(ops.killed, [])
        self.assertNotIn(("unique", 30), ops.calls)
        self.assertNotIn(("sandbox", 30, self.CANARY), ops.calls)

    def test_missing_sandbox_check_is_group_only_and_enumerates_nothing(self):
        ops = FakeSessionOps(pids=(30,), allowed=(30,), available=False)
        self.assertFalse(parent_watch.reap_session(BROWSER, self.CANARY, ops, reaper_pid=SELF))
        self.assertEqual(ops.killed, [])
        self.assertNotIn("list", ops.calls)
        self.assertIn("process-group cleanup only", ops.logs[0])


if __name__ == "__main__":
    unittest.main()
