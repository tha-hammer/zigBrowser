"""MS4.4's macOS driver never orphans the browser's process group (RoseCat 7886 #1), proven without a browser.

ms4_4_login_gate_test starts the macOS browser as the leader of its own process group
(ms4_4_owned_group.OwnedGroup) and installs install_cleanup. Here a stand-in "browser" is a shell that leaves a
background sleep in its group and execs a sleep itself (a leader plus a grandchild, like WebKit's helper processes):
- SIGTERM, SIGINT and SIGHUP to a driver that holds such a group (an outer timeout, Ctrl-C, an ssh drop) each end the
  driver by that very signal, and afterwards neither the leader nor the grandchild runs;
- OwnedGroup.stop() reaps the leader (its status is kept, /proc no longer lists it as running) and stops the whole
  group;
- once the leader is reaped, stop() signals nothing at all (its pid could be reused), and a second stop() is a no-op;
- without os.waitid (a Python that lacks it; the attribute removed), stop() still stops the whole group and reaps the
  leader, and a second stop() signals nothing (RoseCat 7902);
- Darwin's killpg answers EPERM for a group whose only member is the exited, not yet reaped leader (5b48662 on both
  Macs, BlueBeaver 7909). stop() accepts that EPERM only on an independent `ps` census of the exact group, taken
  before anything is reaped, that shows the leader as a zombie and no live member (RoseCat 7912): then it reaps and
  returns the status. An EPERM that was never sent while a descendant still runs (the leader alone ended) is raised
  and the descendant is left as it is; so is an EPERM while the leader runs; and a census that times out, fails or
  reads malformed is raised too. Each with and without os.waitid.
Linux only (it reads /proc to observe, never to decide). It signals only its own children and the stand-in group it
started, so it runs inside a private PID namespace:
  cd tests/e2e && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c 'setsid -w python3 -X dev -m unittest -v ms4_4_login_gate_cleanup_test; exit $?'
Unregistered until its registration."""
import contextlib
import os
import signal
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ms4_4_owned_group as gate  # noqa: E402

STAND_IN = ["/bin/sh", "-c", "sleep 300 & echo $!; exec sleep 300"]
DRIVER = f"""
import sys, time
sys.path.insert(0, {str(HERE)!r})
import subprocess, ms4_4_owned_group as gate
group = gate.OwnedGroup({STAND_IN!r}, stdout=subprocess.PIPE, text=True)
gate.install_cleanup(lambda: group)
print(group.proc.pid, group.proc.stdout.readline().strip(), flush=True)
time.sleep(300)
"""


def running(pid: int) -> bool:
    """Alive and not a zombie (observed through /proc only)."""
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


class OwnedGroupCleanup(unittest.TestCase):
    def setUp(self):
        self.leftover = []
        self.addCleanup(self.sweep)

    def sweep(self):
        """A red must not leave sleeps behind: SIGKILL only what this test started and still sees as a sleep."""
        for pid in self.leftover:
            if not (isinstance(pid, int) and pid > 1 and running(pid)):
                continue
            try:
                ours = b"sleep" in Path(f"/proc/{pid}/cmdline").read_bytes()
            except (FileNotFoundError, ProcessLookupError):
                continue  # gone meanwhile (a /proc read of an exiting pid can raise ESRCH; BlackRobin 7977)
            if ours:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass  # gone between the read and the kill

    def gone_soon(self, pids, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and any(running(p) for p in pids):
            time.sleep(0.05)
        return [p for p in pids if running(p)]

    def test_each_driver_signal_stops_the_whole_group(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                driver = subprocess.Popen([sys.executable, "-c", DRIVER], stdout=subprocess.PIPE, text=True)
                self.addCleanup(driver.wait, 10)
                leader, grandchild = map(int, driver.stdout.readline().split())
                driver.stdout.close()
                self.leftover += [leader, grandchild]
                self.assertTrue(running(leader) and running(grandchild), "the stand-in group did not start")
                driver.send_signal(sig)
                self.assertEqual(driver.wait(15), -sig, "the driver did not end by the signal it got")
                self.assertEqual(self.gone_soon([leader, grandchild]), [], f"{sig.name} left the group running")

    def test_stop_reaps_the_leader_and_stops_the_group(self):
        group = gate.OwnedGroup(STAND_IN, stdout=subprocess.PIPE, text=True)
        leader, grandchild = group.proc.pid, int(group.proc.stdout.readline())
        group.proc.stdout.close()
        self.leftover += [leader, grandchild]
        status = group.stop(grace_sec=1.0)
        self.assertIsNotNone(status, "the leader was not reaped")
        self.assertEqual(group.proc.returncode, status)
        self.assertEqual(self.gone_soon([leader, grandchild]), [], "stop() left the group running")

    def test_without_waitid_stop_still_stops_the_group_and_reaps(self):
        group = gate.OwnedGroup(STAND_IN, stdout=subprocess.PIPE, text=True)
        leader, grandchild = group.proc.pid, int(group.proc.stdout.readline())
        group.proc.stdout.close()
        self.leftover += [leader, grandchild]
        with mock.patch.object(os, "waitid", side_effect=AssertionError("os.waitid reached")):
            del os.waitid  # the capability is absent, not just failing
            self.assertFalse(hasattr(os, "waitid"))
            status = group.stop(grace_sec=0.5)
        self.assertTrue(hasattr(os, "waitid"), "the real os.waitid was not restored")
        self.assertIsNotNone(status, "the leader was not reaped")
        self.assertEqual(group.proc.returncode, status)
        self.assertEqual(self.gone_soon([leader, grandchild]), [], "the group was left running")
        with mock.patch.object(os, "killpg", side_effect=AssertionError("os.killpg reached")), \
                mock.patch.object(os, "kill", side_effect=AssertionError("os.kill reached")):
            self.assertEqual(group.stop(), status, "a second stop() is not signal-free")

    def eperm_once_exited(self, group):
        """os.killpg as Darwin answers it: the real signal, then EPERM when the leader has exited (a zombie)."""
        real = os.killpg

        def killpg(pid, sig):
            real(pid, sig)
            if pid == group.proc.pid and Path(f"/proc/{pid}").exists() and not running(pid):
                raise PermissionError(1, "Operation not permitted")
        return mock.patch.object(os, "killpg", side_effect=killpg)

    def started(self):
        group = gate.OwnedGroup(STAND_IN, stdout=subprocess.PIPE, text=True)
        leader, grandchild = group.proc.pid, int(group.proc.stdout.readline())
        group.proc.stdout.close()
        self.leftover += [leader, grandchild]
        return group, leader, grandchild

    def test_darwin_eperm_for_an_exited_leader_is_the_group_gone(self):
        for waitid in (True, False):
            with self.subTest(waitid=waitid):
                group, leader, grandchild = self.started()
                with self.eperm_once_exited(group), contextlib.ExitStack() as stack:
                    if not waitid:
                        stack.enter_context(mock.patch.object(os, "waitid", create=True))
                        del os.waitid
                    status = group.stop(grace_sec=1.0)
                self.assertIsNotNone(status, "the leader was not reaped")
                self.assertEqual(group.proc.returncode, status)
                self.assertEqual(self.gone_soon([leader, grandchild]), [], "the group was left running")

    def unsent_eperm_leader_only(self, group):
        """os.killpg as a hostile host could answer: SIGTERM ends only the leader, SIGKILL is never sent (EPERM)."""
        def killpg(pid, sig):
            if pid != group.proc.pid:
                raise AssertionError(f"killpg({pid}) is not the owned group")
            if sig == signal.SIGTERM:
                os.kill(pid, signal.SIGTERM)  # the leader alone; its grandchild keeps running
                return
            raise PermissionError(1, "Operation not permitted")
        return mock.patch.object(os, "killpg", side_effect=killpg)

    def test_an_unsent_eperm_with_a_live_descendant_is_raised(self):
        for waitid in (True, False):
            with self.subTest(waitid=waitid):
                group, leader, grandchild = self.started()
                with self.unsent_eperm_leader_only(group), contextlib.ExitStack() as stack:
                    if not waitid:
                        stack.enter_context(mock.patch.object(os, "waitid", create=True))
                        del os.waitid
                    with self.assertRaises(PermissionError):
                        group.stop(grace_sec=1.0)
                self.assertTrue(running(grandchild), "the descendant was not left as it was")
                self.assertIsNone(group.proc.returncode, "the leader was reaped before the refusal")
                os.killpg(leader, signal.SIGKILL)  # this test's own stand-in group, leader unreaped
                group.proc.wait(10)

    def test_a_failed_census_never_accepts_the_eperm(self):
        bad = {"timeout": subprocess.TimeoutExpired(gate.PS, gate.CENSUS_TIMEOUT_S),
               "exit 1": subprocess.CompletedProcess(gate.PS, 1, "", "ps: error"),
               "malformed": subprocess.CompletedProcess(gate.PS, 0, "12 x Z\n", "")}
        for name, answer in bad.items():
            with self.subTest(census=name):
                group, leader, grandchild = self.started()
                ps = mock.patch.object(gate.subprocess, "run",
                                       side_effect=answer if isinstance(answer, Exception) else [answer])
                with self.eperm_once_exited(group), ps:
                    with self.assertRaises(gate.GroupCensusError):
                        group.stop(grace_sec=1.0)
                self.assertIsNone(group.proc.returncode, "the leader was reaped on a failed census")
                group.proc.wait(10)  # the real signals were sent: the group is already gone
                self.assertEqual(self.gone_soon([leader, grandchild]), [])

    def test_an_eperm_while_the_leader_runs_is_raised(self):
        for waitid in (True, False):
            with self.subTest(waitid=waitid):
                group, leader, grandchild = self.started()
                refused = mock.patch.object(os, "killpg", side_effect=PermissionError(1, "Operation not permitted"))
                with refused, contextlib.ExitStack() as stack:
                    if not waitid:
                        stack.enter_context(mock.patch.object(os, "waitid", create=True))
                        del os.waitid
                    with self.assertRaises(PermissionError):
                        group.stop(grace_sec=0.3)
                self.assertTrue(running(leader), "the refused stop() still ended the leader")
                os.killpg(leader, signal.SIGKILL)  # this test's own stand-in group, leader unreaped
                group.proc.wait(10)

    def test_after_the_leader_is_reaped_stop_signals_nothing(self):
        group = gate.OwnedGroup(["/bin/sh", "-c", "exit 0"])
        group.proc.wait(10)  # reaped by someone else: its pid may be reused now
        with mock.patch.object(os, "killpg", side_effect=AssertionError("os.killpg reached")), \
                mock.patch.object(os, "kill", side_effect=AssertionError("os.kill reached")):
            self.assertEqual(group.stop(), 0)
            self.assertEqual(group.stop(), 0, "a second stop() is not a no-op")


if __name__ == "__main__":
    unittest.main()
