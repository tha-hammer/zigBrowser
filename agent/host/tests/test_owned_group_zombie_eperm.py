"""Darwin's killpg EPERM on a group whose only member is our own exited, unreaped leader (5b24bc1 on both Macs: the
honest, planted and forge runs, whose leaders had exited by themselves, all failed closed with reason=kill_refused;
the hang run, whose leader was alive at the stop, was proven stopped).

stop_group accepts that EPERM as "the group is already gone" ONLY when all hold (the orchestrator, after 7486):
- the platform is Darwin;
- the errno is exactly EPERM;
- our leader is proven exited and unreaped (our own zombie);
- an independent census of the process table (ps -axo pid=,pgid=,stat=) reads, and shows no live member of the pgid,
  the leader included (it is listed as a zombie, or not at all).
It then completes as any stop: the bounded reap and the group-gone proof. Any other EPERM, and every other errno,
stays StopFailed(reason=kill_refused).

Signal-interposed, so these run plain and cannot signal: os.kill fails the test, and os.killpg records the pid and
then raises the row's errno (AssertionError for any pid but the leader). The Darwin branch is forced and its ps reads
are faked, so the census is exactly what each row says. Every stand-in leader exits by itself and is reaped.
Run: cd agent/host/tests && python -X dev -m unittest -v test_owned_group_zombie_eperm. Unregistered until the green.
"""
import errno
import os
import subprocess
import sys
import time
import types
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_owned_group_failclosed as failclosed

from zb_agent_host import owned_group


class ZombieLeaderEperm(failclosed.Interposed):
    def leader(self, exits=True):
        code = "pass" if exits else "import time; time.sleep(2)"
        p = subprocess.Popen([sys.executable, "-c", code], start_new_session=True)
        self.spawned.append(p)
        if exits:  # wait until it has exited WITHOUT reaping it: our own zombie, its pgid still pinned
            deadline = time.monotonic() + 10
            while os.waitid(os.P_PID, p.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                self.assertLess(time.monotonic(), deadline, "the stand-in leader did not exit")
                time.sleep(0.01)
        return p

    def setup_row(self, p, *, killpg_errno, census, platform="darwin"):
        """census: the lines `ps -axo pid=,pgid=,stat=` gives, or None (unreadable)."""
        def killpg(pid, sig):
            self.killpg_calls.append(pid)
            if pid != p.pid:
                raise AssertionError(f"killpg reached a pid that is not the leader: {pid}")
            raise OSError(killpg_errno, os.strerror(killpg_errno))

        def ps(args):
            if args[:1] == ["-o"]:
                return [f"{os.getpid()} {p.pid}"]  # ownership: our child leading its own group
            return census

        mock.patch.object(os, "killpg", side_effect=killpg).start()
        mock.patch.object(owned_group, "sys", types.SimpleNamespace(platform=platform)).start()
        mock.patch.object(owned_group, "_ps", side_effect=ps).start()

    def assert_kill_refused(self, p):
        with self.assertRaises(owned_group.StopFailed) as cm:
            owned_group.stop_group(p)
        self.assertEqual(getattr(cm.exception, "reason", None), "kill_refused")
        self.assertEqual(self.killpg_calls, [p.pid])

    def completes(self, census_for):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EPERM, census=census_for(p.pid))
        owned_group.stop_group(p)  # no StopFailed: the group is proven already gone
        self.assertIsNotNone(p.returncode, "the zombie leader was reaped")
        self.assertEqual(self.killpg_calls, [p.pid])

    def test_eperm_with_only_our_zombie_leader_listed_completes(self):
        self.completes(lambda pid: [f"{pid} {pid} Z"])

    def test_eperm_with_the_group_absent_from_the_census_completes(self):
        self.completes(lambda pid: [])

    def test_eperm_with_only_other_groups_live_completes(self):
        self.completes(lambda pid: [f"{pid} {pid} Z", "999 999 S", "77 1 Ss"])

    def test_eperm_with_a_live_member_stays_kill_refused(self):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EPERM, census=[f"{p.pid} {p.pid} Z", f"4242 {p.pid} S"])
        self.assert_kill_refused(p)

    def test_eperm_with_the_leader_live_in_the_census_stays_kill_refused(self):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EPERM, census=[f"{p.pid} {p.pid} R"])
        self.assert_kill_refused(p)

    def test_eperm_with_an_unreadable_census_stays_kill_refused(self):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EPERM, census=None)
        self.assert_kill_refused(p)

    def test_eperm_with_an_empty_census_but_a_leader_not_exited_stays_kill_refused(self):
        p = self.leader(exits=False)
        self.setup_row(p, killpg_errno=errno.EPERM, census=[])
        self.assert_kill_refused(p)

    def test_another_errno_with_an_empty_census_stays_kill_refused(self):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EINVAL, census=[])
        self.assert_kill_refused(p)

    def test_eperm_off_darwin_stays_kill_refused(self):
        p = self.leader()
        self.setup_row(p, killpg_errno=errno.EPERM, census=[], platform="linux")
        self.assert_kill_refused(p)


if __name__ == "__main__":
    unittest.main()
