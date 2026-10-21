"""zb_agent_host.owned_group, the owned process group setup's sandboxed runs end their tree with (RoseCat 7418, 7422).

Refusals, each BEFORE any signal (os.kill and os.killpg are patched to fail the test if reached):
- a pid that is not an exact int > 1: a MagicMock (it indexes as 1: killpg(1) is kill(-1), every process the user
  owns), True/False, 0, 1, -1, 1.0, "123";
- this process's own pid, or its own process group;
- a real process that is not this process's child (a grandchild);
- a real child of this process that does not lead its own process group.
Behaviour, with real processes:
- run() returns a quick command's returncode and output;
- a leader that hangs while a descendant holds the pipes: run() ends at its bound (TimeoutExpired), and neither is
  alive;
- a leader that EXITS while a descendant still holds the pipes: run() still ends at its bound, the group is stopped
  while the leader is unreaped (its zombie keeps the pgid ours), and the descendant is not alive;
- after run() returns, its leader is reaped (it is no longer this process's child);
- a descendant that closed the pipes and outlives a leader that exited 0: run() returns the result and the
  descendant is not alive (the group is stopped on success too);
Stop failures (RoseCat 7436), each within a bound and explicit, never an unbounded wait or a claimed cleanup:
- a guarded, valid owned group whose killpg is refused (EPERM): stop_group raises StopFailed within 2 s;
- run() whose group stop is refused raises StopFailed (carrying the unreaped leader), not a result or a timeout.
It signals real processes, so it runs ONLY inside a PID namespace that pidns_guard proves, through the kernel, to be
below the launcher's held one (RoseCat 7433); it skips anywhere else. Every stand-in ends itself within 20 s.
Run: cd agent/host/tests && sh -c 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork \\
  --mount-proc env ZB_OUTER_PIDNS_FD=9 python -X dev -m unittest -v test_owned_group'.
Unregistered until the green.
"""
import os
import subprocess
import sys
import time
import types
import unittest
from unittest import mock

import pidns_guard
import support  # noqa: F401  (puts the helper package on sys.path)

try:
    from zb_agent_host import owned_group
except ImportError:
    owned_group = None

GRACE_S = 5
LIFETIME_S = 20


def _alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def _py(code):
    return [sys.executable, "-c", code]


class Base(unittest.TestCase):
    def setUp(self):
        ok, why = pidns_guard.private_pid_namespace()
        if not ok:
            self.skipTest(f"signals real processes: {why}")
        if owned_group is None:
            self.fail("zb_agent_host.owned_group is missing (RoseCat 7418's owned-group primitive)")
        self.addCleanup(mock.patch.stopall)


class Refusals(Base):
    def setUp(self):
        super().setUp()
        self.signals = []

        def record(*args):
            self.signals.append(args)
            raise AssertionError(f"a signal was sent: {args}")

        mock.patch.object(os, "kill", side_effect=record).start()
        mock.patch.object(os, "killpg", side_effect=record).start()

    def assert_refused(self, proc, why):
        with self.assertRaises(owned_group.Refused, msg=why):
            owned_group.stop_group(proc)
        self.assertEqual(self.signals, [], f"{why}: a signal was sent before the refusal")

    def test_a_pid_that_is_not_an_exact_int_above_1_is_refused(self):
        for pid in (mock.MagicMock(), True, False, 0, 1, -1, 1.0, "123", None):
            with self.subTest(pid=repr(pid)):
                self.assert_refused(types.SimpleNamespace(pid=pid), repr(pid))

    def test_this_process_and_its_own_group_are_refused(self):
        self.assert_refused(types.SimpleNamespace(pid=os.getpid()), "this process")
        self.assert_refused(types.SimpleNamespace(pid=os.getpgrp()), "this process's group")

    def test_a_process_that_is_not_our_child_is_refused(self):
        r, w = os.pipe()
        child = subprocess.Popen(_py("import subprocess, sys, time\n"
                                     "g = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(3)'],"
                                     " start_new_session=True)\n"
                                     f"import os; os.write({w}, str(g.pid).encode()); time.sleep(3)"),
                                 pass_fds=(w,))
        os.close(w)
        self.addCleanup(child.wait)
        with os.fdopen(r) as f:
            grandchild = int(f.read(16))
        self.assertTrue(_alive(grandchild))
        self.assert_refused(types.SimpleNamespace(pid=grandchild), "a grandchild that leads its own group")

    def test_our_child_that_does_not_lead_its_own_group_is_refused(self):
        child = subprocess.Popen(_py("import time; time.sleep(3)"))  # stays in our group
        self.addCleanup(child.wait)
        self.assert_refused(child, "a child in our own group")


class Behaviour(Base):
    def test_a_quick_command_returns_its_code_and_output(self):
        done = owned_group.run(_py("print('ok'); import sys; sys.exit(3)"), env=None, pass_fds=(), timeout=10)
        self.assertEqual((done.returncode, done.stdout.strip()), (3, "ok"))

    def bounded(self, leader_code):
        d = os.path.join(support.TEST_TMP, f"owned-{os.getpid()}-{time.monotonic_ns()}")
        os.makedirs(d)
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            owned_group.run(_py(leader_code.replace("DIR", repr(d))), env=None, pass_fds=(), timeout=2)
        took = time.monotonic() - started
        with open(os.path.join(d, "leader")) as f:
            leader = int(f.read())
        with open(os.path.join(d, "descendant")) as f:
            descendant = int(f.read())
        self.assertLess(took, 2 + GRACE_S, f"run waited for the pipe holder ({took:.1f} s)")
        self.assertFalse(_alive(descendant), "the descendant outlived the bound")
        self.assertFalse(_alive(leader), "the leader outlived the bound")
        with self.assertRaises(ChildProcessError, msg="the leader was left unreaped"):
            os.waitpid(leader, os.WNOHANG)

    SPAWN = ("import os, subprocess, sys, time\n"
             "open(os.path.join(DIR, 'leader'), 'w').write(str(os.getpid()))\n"
             "d = subprocess.Popen([sys.executable, '-c', 'import os, time; "
             "open(os.path.join(%r, \"descendant\"), \"w\").write(str(os.getpid())); time.sleep(" + str(LIFETIME_S)
             + ")' % DIR])\n"
             "while not os.path.exists(os.path.join(DIR, 'descendant')): time.sleep(0.05)\n")

    def test_a_hanging_leader_and_its_descendant_end_at_the_bound(self):
        self.bounded(self.SPAWN + f"time.sleep({LIFETIME_S})\n")

    def test_a_leader_that_exits_while_a_descendant_holds_the_pipes_ends_at_the_bound(self):
        self.bounded(self.SPAWN + "sys.exit(0)\n")


class SuccessStopsTheGroup(Base):
    def test_a_descendant_that_closed_the_pipes_is_stopped_with_a_successful_run(self):
        d = os.path.join(support.TEST_TMP, f"owned-ok-{os.getpid()}-{time.monotonic_ns()}")
        os.makedirs(d)
        code = ("import os, subprocess, sys, time\n"
                "subprocess.Popen([sys.executable, '-c', 'import os, time; open(os.path.join(%r, \"descendant\"), "
                "\"w\").write(str(os.getpid())); time.sleep(" + str(LIFETIME_S) + ")'], stdout=subprocess.DEVNULL, "
                "stderr=subprocess.DEVNULL)\n"
                "while not os.path.exists(os.path.join(%r, 'descendant')): time.sleep(0.05)\n"
                "print('done')\n")
        done = owned_group.run(_py(code % (d, d)), env=None, pass_fds=(), timeout=10)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "done"))
        with open(os.path.join(d, "descendant")) as f:
            self.assertFalse(_alive(int(f.read())), "a descendant outlived a successful run")


class StopFailures(Base):
    def setUp(self):
        super().setUp()
        if not hasattr(owned_group, "StopFailed"):
            self.fail("owned_group.StopFailed is missing (RoseCat 7436)")

    def test_a_refused_killpg_is_an_explicit_bounded_failure(self):
        child = subprocess.Popen(_py("import time; time.sleep(3)"), start_new_session=True)
        self.addCleanup(child.wait)
        mock.patch.object(os, "killpg", side_effect=PermissionError(1, "Operation not permitted")).start()
        started = time.monotonic()
        with self.assertRaises(owned_group.StopFailed):
            owned_group.stop_group(child)
        self.assertLess(time.monotonic() - started, 2, "an unbounded wait after a refused kill")

    def test_run_reports_a_refused_stop_not_a_result(self):
        mock.patch.object(os, "killpg", side_effect=PermissionError(1, "Operation not permitted")).start()
        started = time.monotonic()
        with self.assertRaises(owned_group.StopFailed) as cm:
            owned_group.run(_py("import time; time.sleep(3)"), env=None, pass_fds=(), timeout=1)
        self.assertLess(time.monotonic() - started, 1 + GRACE_S)
        leader = getattr(cm.exception, "proc", None)
        self.assertIsNotNone(leader, "StopFailed carries the unreaped leader for its caller")
        leader.wait(10)


if __name__ == "__main__":
    unittest.main()
