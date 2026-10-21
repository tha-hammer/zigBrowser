"""The MS6 hard-gate Harness never signals anything but its own child's own process group (RoseCat on efe2517; the
2026-10-21 logouts: a mocked Popen's MagicMock pid reached os.killpg as 1, and killpg(1) is kill(-1)).

Harness._consume(entry) may SIGKILL a group only when entry's pid is ALL of:
- an int above 1 (a MagicMock indexes as 1; 0, 1 and -1 are "every process" or "my group" to kill/killpg);
- not this process's own group (os.getpgrp());
- the leader of its own group (pgid == pid: spawn_group's start_new_session=True invariant);
- this process's child (ppid == os.getpid()), so a real but unrelated group leader is never signalled.
Otherwise it raises RuntimeError before any signal. Leader and parent are read where they still exist for an
unreaped zombie: /proc/<pid>/stat on Linux, `ps -o ppid=,pgid=` on Darwin (getpgid/getsid fail with ESRCH on a zombie
there, measured on both Macs).

NO test here sends a signal through the code under test: os.kill and os.killpg are patched to raise around every
_consume call and asserted uncalled. The real children this module starts are stopped only afterwards, outside the
patches, by their own Popen, with their pid checked. Run on Linux only inside a PID namespace, with the test process
leading its own group (so "my own group" is a real pgid above 1, not the namespace's 0):
unshare --user --map-root-user --pid --fork --mount-proc sh -c 'setsid python3 -X dev -m unittest ...'

Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_harness_safety_test. Unregistered until
the green.
"""
import os
import subprocess
import sys
import tempfile
import shutil
import types
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
HARNESS_DIR = REPO / "tests" / "mac" / "hard_gate"


def stop_real_child(proc):
    """Stops a child this module started itself, outside every patch; never a pid that is not a real child's."""
    if type(proc.pid) is int and proc.pid > 1 and proc.poll() is None:
        proc.kill()
    proc.wait(10)


class NeverSignalsAStranger(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(HARNESS_DIR))
        self.addCleanup(sys.path.remove, str(HARNESS_DIR))
        import importlib
        self.harness = importlib.import_module("harness")
        scratch = tempfile.mkdtemp(prefix="zb-hardgate-safety-")
        self.addCleanup(shutil.rmtree, scratch, True)
        self.h = self.harness.Harness(scratch)

    def refuses(self, proc, why):
        entry = {"proc": proc, "consumed": False}
        no_signal = AssertionError("a signal reached os.kill/os.killpg from the code under test")
        with mock.patch.object(self.harness.os, "killpg", side_effect=no_signal) as killpg, \
                mock.patch.object(self.harness.os, "kill", side_effect=no_signal) as kill:
            with self.assertRaises(RuntimeError, msg=why):
                self.h._consume(entry)
        killpg.assert_not_called()
        kill.assert_not_called()

    def test_a_mocked_process_is_refused(self):
        self.refuses(mock.MagicMock(), "a MagicMock pid indexes as 1: killpg(1) is kill(-1)")

    def test_pids_that_mean_every_process_or_my_group_are_refused(self):
        for pid in (0, 1, -1, True, 1.0, "1234"):
            with self.subTest(pid=pid):
                self.refuses(types.SimpleNamespace(pid=pid, wait=lambda: 0), f"pid {pid!r}")

    def test_this_process_own_group_is_refused(self):
        self.assertGreater(os.getpgrp(), 1, "run with the test process leading a real group (see the docstring)")
        self.refuses(types.SimpleNamespace(pid=os.getpgrp(), wait=lambda: 0), "killpg(getpgrp()) kills the harness")

    def test_a_real_child_that_does_not_lead_its_own_group_is_refused(self):
        child = subprocess.Popen(["/bin/sleep", "30"])  # no start_new_session: it is in OUR group
        self.addCleanup(stop_real_child, child)
        self.assertNotEqual(child.pid, os.getpgrp())
        self.refuses(child, "pgid != pid: signalling it as a group would hit our own group")

    def test_a_real_group_leader_that_is_not_our_child_is_refused(self):
        # A grandchild that leads its own group: a real int, a real group, but not ours to signal.
        mid = subprocess.Popen([sys.executable, "-I", "-c",
                                "import subprocess, sys; p = subprocess.Popen(['/bin/sleep', '30'], "
                                "start_new_session=True); print(p.pid, flush=True); sys.stdin.read(); p.kill(); "
                                "p.wait()"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def stop_mid():
            mid.stdin.close()
            mid.stdout.close()
            mid.wait(10)
        self.addCleanup(stop_mid)
        grandchild = int(mid.stdout.readline())
        self.assertGreater(grandchild, 1)
        self.refuses(types.SimpleNamespace(pid=grandchild, wait=lambda: 0), "a group leader that is not our child")


if __name__ == "__main__":
    unittest.main()
