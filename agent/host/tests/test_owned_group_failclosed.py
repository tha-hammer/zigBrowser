"""owned_group and setup fail CLOSED whenever a run's group cannot be proven stopped (RoseCat 7450 BLOCKED fd1bd92: a
Refused stop, e.g. Darwin's ps timing out, escaped as Refused and setup removed the scratch around a group that was
never proven gone; a cleanup stop failing after an earlier error was swallowed; the selector was built outside the
post-spawn guard).

Signal-interposed, so these run plain and cannot signal: os.kill always fails the test, and os.killpg is a recorder
that fails the test for any pid but the run's own leader (it never really signals). The darwin rows force the Darwin
branch (owned_group's ps reads) on Linux.
- (a) Darwin ps timing out (None) or malformed: run() raises StopFailed carrying the leader, and killpg is never
  called; setup, given Refused or StopFailed from its seam, retains its scratch with exactly its fixed line;
- (b) an earlier read OSError followed by a cleanup stop that cannot be proven: StopFailed wins (the earlier error is
  only its cause), never the bare OSError;
- (c) the selector failing right after the spawn: the leader is still stopped (one killpg, to it) and reaped.
Every stand-in leader exits by itself at once, so a refused stop leaves nothing running.
Run: cd agent/host/tests && python -X dev -m unittest -v test_owned_group_failclosed. Unregistered until the green.
"""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import owned_group, sandbox_macos, setup

QUICK = [sys.executable, "-c", "pass"]


class Interposed(unittest.TestCase):
    def setUp(self):
        self.addCleanup(mock.patch.stopall)
        self.spawned = []
        real_popen = subprocess.Popen

        def popen(*a, **kw):
            p = real_popen(*a, **kw)
            self.spawned.append(p)
            return p

        mock.patch.object(owned_group.subprocess, "Popen", side_effect=popen).start()
        mock.patch.object(os, "kill", side_effect=AssertionError("os.kill reached")).start()
        self.killpg_calls = []

        def killpg(pid, sig):
            self.killpg_calls.append(pid)
            if not self.spawned or pid != self.spawned[-1].pid:
                raise AssertionError(f"killpg reached a pid that is not the run's leader: {pid}")

        mock.patch.object(os, "killpg", side_effect=killpg).start()
        self.addCleanup(self.reap)

    def reap(self):
        for p in self.spawned:
            with contextlib.suppress(Exception):
                p.wait(10)
            for s in (p.stdout, p.stderr):
                if s is not None:
                    s.close()

    def darwin(self, ps_lines):
        mock.patch.object(owned_group, "sys", types.SimpleNamespace(platform="darwin")).start()
        mock.patch.object(owned_group, "_ps", return_value=ps_lines).start()


class DarwinPsCannotProve(Interposed):
    def test_a_ps_timeout_is_stop_failed_and_never_a_signal(self):
        self.darwin(None)
        with self.assertRaises(owned_group.StopFailed) as cm:
            owned_group.run(QUICK, timeout=10)
        self.assertIs(cm.exception.proc, self.spawned[0])
        self.assertEqual(self.killpg_calls, [], "a signal went out without ownership proof")

    def test_malformed_ps_output_is_stop_failed_and_never_a_signal(self):
        for lines in (["garbage"], ["1 2 3"], ["", ""], ["x y"]):
            with self.subTest(lines=lines):
                self.darwin(lines)
                with self.assertRaises(owned_group.StopFailed):
                    owned_group.run(QUICK, timeout=10)
                self.assertEqual(self.killpg_calls, [])
                mock.patch.stopall()
                self.setUp()


class EarlierErrorThenCleanupFailure(Interposed):
    def test_the_cleanup_stop_failure_wins(self):
        self.darwin(None)
        mock.patch.object(owned_group, "_read_until", side_effect=OSError(5, "Input/output error")).start()
        with self.assertRaises(owned_group.StopFailed) as cm:
            owned_group.run(QUICK, timeout=10)
        self.assertIsInstance(cm.exception.__cause__, OSError, "the earlier error is kept as the cause")
        self.assertEqual(self.killpg_calls, [])


class SelectorFailsAfterSpawn(Interposed):
    def test_the_leader_is_still_stopped_and_reaped(self):
        mock.patch.object(owned_group.selectors, "DefaultSelector",
                          side_effect=OSError(24, "Too many open files")).start()
        with self.assertRaises(OSError):
            owned_group.run(QUICK, timeout=10)
        (leader,) = self.spawned
        self.assertEqual(self.killpg_calls, [leader.pid], "the spawned leader's group was not stopped")
        self.assertIsNotNone(leader.returncode, "the spawned leader was left unreaped")


class SetupRetainsTheScratch(unittest.TestCase):
    def test_refused_or_stop_failed_from_the_seam_retains_the_scratch(self):
        for exc in (owned_group.Refused("ps timed out ZB-CANARY"), owned_group.StopFailed("ZB-CANARY")):
            with self.subTest(exc=type(exc).__name__):
                with mock.patch.object(os, "kill", side_effect=AssertionError), \
                        mock.patch.object(os, "killpg", side_effect=AssertionError):
                    root = tempfile.mkdtemp(prefix="zb-failclosed-")
                    with mock.patch.object(tempfile, "tempdir", root), \
                            mock.patch.object(setup, "PLATFORM", "darwin"), \
                            mock.patch.object(sandbox_macos, "setup_sandbox", self.seam), \
                            mock.patch.object(setup, "run_in_owned_group", side_effect=exc):
                        err = io.StringIO()
                        with contextlib.redirect_stderr(err):
                            self.assertEqual(setup._sandboxed(["/ro"], ["/opt/claude"], timeout=1), ("", False))
                left = os.listdir(root)
                self.assertEqual(len(left), 1, "the scratch was removed around an unproven stop")
                scratch = os.path.join(os.path.realpath(root), left[0])
                self.assertEqual(err.getvalue(), "zigBrowser: agent-setup: a sandboxed run could not be proven "
                                                 f"stopped; its scratch is left at {scratch}\n")
                os.rmdir(scratch)
                os.rmdir(root)

    @staticmethod
    @contextlib.contextmanager
    def seam(scratch, ro_paths, command, *, loopback_port=None):
        yield ["/usr/bin/sandbox-exec", *command]


if __name__ == "__main__":
    unittest.main()
