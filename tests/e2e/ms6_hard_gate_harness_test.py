"""The MS6 hard-gate harness itself (plan rev 18.1; RoseCat 7134, caf95b9): the Harness's process-group ownership and
the entry's NOT ARMED refusal, observed.

- h.spawn_group(argv, env, pass_fds, timeout) owns its process group EXACTLY once. It waits for the leader WITHOUT
  reaping it, so the leader's zombie keeps the pgid from being reused. Then it SIGKILLs the whole group, which also
  takes a child that outlived the leader, and only then reaps. close() never signals a group spawn_group already
  reaped. Tests: a normal run (output, one group kill), a timeout (None, bounded, no survivor), a child outliving the
  leader (killed), 3 MB of output (no deadlock), close() twice (no extra signal), and, at the moment of the group
  kill, the leader is not yet reaped (/proc/<pgid> still exists; on Darwin, kill(pgid, 0) still succeeds).
- The same tests again with os.waitid REMOVED (bead zigBrowser-a2t): the app bundles python.org CPython 3.12, which
  has no os.waitid on macOS (it arrived there in 3.13), so spawn_group must wait for the leader without reaping it
  through kqueue EVFILT_PROC NOTE_EXIT, with the same exactly-once, kill-while-unreaped invariant. Darwin only (Linux
  has no kqueue); tests/mac/ms6_harness_mac_gate.sh runs this module on both Macs and requires no skip.
- With neither os.waitid nor select.kqueue, spawn_group refuses (RuntimeError) before spawning anything.
- tests/mac/ms6_hard_gate.sh: NOT ARMED (exit 3) with the pins absent; with malformed pins (armed since the MS5 pins,
  RoseCat 7250), exit 1 naming the pins. Either way the recording ssh/scp/sftp/curl/nc/rsync shims (first on PATH,
  canary hosts in every host variable) see no call at all. tests/e2e/ms6_hard_gate_entry_test.py covers the armed
  entry's other preconditions and its first network call.

Registered (build.zig: test-mac-census and the Linux test step). Run like the gate, inside a private user+PID namespace:
cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_harness_test'
"""
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DRIVER = REPO / "tests" / "mac" / "hard_gate" / "hard_gate_driver.py"
GATE = REPO / "tests" / "mac" / "ms6_hard_gate.sh"


class SpawnGroup(unittest.TestCase):
    """RoseCat 7134: h.spawn_group owns its process group EXACTLY once. It waits for the leader without reaping it
    (so the leader's zombie keeps the pgid from being reused), SIGKILLs the whole group, which also takes children
    that outlive the leader, then reaps; close() never touches a group spawn_group already reaped."""

    def setUp(self):
        sys.path.insert(0, str(DRIVER.parent))
        self.addCleanup(sys.path.remove, str(DRIVER.parent))
        import importlib
        self.harness = importlib.import_module("harness")
        self.scratch = tempfile.mkdtemp(prefix="zb-hardgate-sg-")
        self.addCleanup(shutil.rmtree, self.scratch, True)
        self.kills = []
        real = os.killpg

        def counting_killpg(pgid, sig):
            # The leader must still be unreaped when its group is signalled: it exists (alive or zombie), so the
            # pgid cannot have been reused by an unrelated group.
            # Never pass anything but a real child pgid to the real killpg, nor to exists() (kill(pid, 0) on Darwin):
            # killpg(1) is kill(-1), every process of the user (2026-10-21: a mocked pid logged the user out twice).
            # So validate first, then observe (RoseCat 7167).
            if type(pgid) is not int or pgid <= 1 or pgid == os.getpgrp():
                raise AssertionError(f"refusing a real killpg({pgid!r}): not a child's own group")
            self.kills.append((pgid, sig, self.exists(pgid)))
            return real(pgid, sig)

        from unittest import mock
        patcher = mock.patch.object(self.harness.os, "killpg", side_effect=counting_killpg)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.h = self.harness.Harness(self.scratch)

    @staticmethod
    def exists(pid):
        """The process exists, alive or an unreaped zombie (Linux: /proc; Darwin: kill(pid, 0), which succeeds on a
        zombie there too, measured on both Macs)."""
        if sys.platform == "darwin":
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            return True
        return os.path.exists(f"/proc/{pid}")

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        if sys.platform == "darwin":
            stat = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
            return stat.strip() != "" and not stat.strip().startswith("Z")
        # The child may exit between kill(pid, 0) and the open (FileNotFoundError, RoseCat on 554f36c), or between the
        # open and the read (ProcessLookupError, ESRCH: seen in a namespaced test-mac-census run): either is dead.
        try:
            with open(f"/proc/{pid}/stat") as f:
                return f.read().rsplit(")", 1)[1].split()[0] != "Z"
        except (FileNotFoundError, ProcessLookupError):
            return False

    def group_kills(self):
        kills = [k for k in self.kills if k[1] == 9]
        self.assertTrue(all(k[2] for k in kills), f"the group is signalled only while its leader is unreaped: {kills}")
        return kills

    def test_a_normal_run_returns_its_output_and_kills_the_group_once(self):
        code, out, err = self.h.spawn_group(["/bin/sh", "-c", "echo out; echo err >&2"], timeout=10)
        self.assertEqual((code, out, err), (0, b"out\n", b"err\n"))
        self.assertEqual(len(self.group_kills()), 1, self.kills)

    def test_a_timeout_is_none_and_leaves_no_survivor(self):
        started = time.monotonic()
        code, _, _ = self.h.spawn_group(["/bin/sh", "-c", "echo $$; sleep 30"], timeout=0.5)
        self.assertIsNone(code)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(len(self.group_kills()), 1, self.kills)

    def test_a_child_that_outlives_the_leader_is_killed(self):
        code, out, _ = self.h.spawn_group(["/bin/sh", "-c", "sleep 30 </dev/null >/dev/null 2>&1 & echo $!"],
                                          timeout=10)
        child = int(out.decode().strip())
        self.assertEqual(code, 0)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.alive(child):
            time.sleep(0.02)
        self.assertFalse(self.alive(child), "the surviving child of the exited leader is killed with the group")
        self.assertEqual(len(self.group_kills()), 1, self.kills)

    def test_large_output_does_not_deadlock(self):
        code, out, _ = self.h.spawn_group(["/bin/sh", "-c", "head -c 3000000 /dev/zero"], timeout=20)
        self.assertEqual((code, len(out)), (0, 3000000))

    def test_close_never_signals_a_group_spawn_group_already_reaped(self):
        self.h.spawn_group(["/usr/bin/true"], timeout=10)
        before = list(self.kills)
        self.h.close()
        self.h.close()
        self.assertEqual(self.kills, before, "exactly once: close() leaves an already-reaped group alone")


def remove_attr(tc, obj, name):
    """Hide obj.name for this test (as on an interpreter without it), restored afterwards."""
    if hasattr(obj, name):
        saved = getattr(obj, name)
        delattr(obj, name)
        tc.addCleanup(setattr, obj, name, saved)


def import_harness(tc):
    sys.path.insert(0, str(DRIVER.parent))
    tc.addCleanup(sys.path.remove, str(DRIVER.parent))
    import importlib
    return importlib.import_module("harness")


class SpawnGroupWithoutWaitid(SpawnGroup):
    """Bead zigBrowser-a2t: every SpawnGroup test again, on the bundled CPython 3.12's macOS surface (no os.waitid).
    The leader wait goes through kqueue EVFILT_PROC NOTE_EXIT, which never reaps."""

    def setUp(self):
        if not hasattr(select, "kqueue"):
            self.skipTest("no kqueue here: the no-waitid path is Darwin's (CPython 3.12 on macOS)")
        super().setUp()
        remove_attr(self, os, "waitid")
        self.kqueues = 0
        real = select.kqueue

        def counting_kqueue():
            self.kqueues += 1
            return real()
        from unittest import mock
        patcher = mock.patch.object(select, "kqueue", side_effect=counting_kqueue)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_leader_wait_goes_through_kqueue(self):
        self.assertFalse(hasattr(os, "waitid"))
        code, out, _ = self.h.spawn_group(["/bin/sh", "-c", "sleep 0.2; echo late"], timeout=10)
        self.assertEqual((code, out), (0, b"late\n"))
        self.assertGreaterEqual(self.kqueues, 1, "without os.waitid the leader is awaited through kqueue")
        self.assertEqual(len(self.group_kills()), 1, self.kills)


class SpawnGroupWithNeither(unittest.TestCase):
    """With neither os.waitid nor select.kqueue there is no way to wait without reaping: refuse before spawning."""

    def test_spawn_group_refuses_before_spawning_anything(self):
        harness = import_harness(self)
        remove_attr(self, os, "waitid")
        remove_attr(self, select, "kqueue")
        scratch = tempfile.mkdtemp(prefix="zb-hardgate-sg-")
        self.addCleanup(shutil.rmtree, scratch, True)
        from unittest import mock
        # Popen is mocked to RAISE, so no fake process (and no MagicMock pid, which indexes as 1: killpg(1) is kill(-1),
        # every process of the user) can ever exist here; and no signal may reach the kernel from this test.
        no_signal = AssertionError("a signal was sent from a test whose Popen is mocked")
        with mock.patch.object(harness.os, "killpg", side_effect=no_signal) as killpg, \
                mock.patch.object(harness.os, "kill", side_effect=no_signal) as kill, \
                mock.patch.object(harness.subprocess, "Popen", side_effect=AssertionError("spawned")) as popen:
            with self.assertRaises(RuntimeError) as cm:
                harness.Harness(scratch).spawn_group(["/usr/bin/true"], timeout=5)
        killpg.assert_not_called()
        kill.assert_not_called()
        self.assertIn("waitid", str(cm.exception))
        self.assertIn("kqueue", str(cm.exception))
        popen.assert_not_called()


class Gate(unittest.TestCase):
    """RoseCat 7134: NOT ARMED is observed to touch no network. The gate runs in a throwaway git repo (with and
    without a pins file) with recording ssh/scp/curl/nc shims first on PATH and canary hosts in every host variable;
    the record must stay empty."""

    def run_gate(self, with_pins):
        if not GATE.is_file():
            self.fail("tests/mac/ms6_hard_gate.sh is missing (rev 18.1)")
        repo = Path(tempfile.mkdtemp(prefix="zb-hardgate-repo-"))
        self.addCleanup(shutil.rmtree, repo, True)
        (repo / "tests" / "mac").mkdir(parents=True)
        shutil.copy2(GATE, repo / "tests" / "mac" / "ms6_hard_gate.sh")
        if with_pins:
            (repo / "packaging" / "macos").mkdir(parents=True)
            (repo / "packaging" / "macos" / "agent_runtime_pins.json").write_text("{}\n")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        # The armed entry certifies a commit (RoseCat 7267): it resolves and exports one before reading anything.
        subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m",
                        "fixture"], check=True)
        shims, record = repo / "shims", repo / "network-calls"
        shims.mkdir()
        for tool in ("ssh", "scp", "sftp", "curl", "nc", "rsync"):
            (shims / tool).write_text(f"#!/bin/sh\necho {tool} \"$@\" >> '{record}'\nexit 99\n")
            (shims / tool).chmod(0o755)
        env = {"PATH": f"{shims}:/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(repo),
               "ZB_MAC_HOST": "canary-intel@192.0.2.10", "ZB_MAC_ARM_HOST": "canary-arm@192.0.2.11",
               "ZB_MAC_KEY": str(repo / "no-key"), "ZB_MAC_ARM_KEY": str(repo / "no-key")}
        # The documented entry runs the commit's bytes (RoseCat 7275), never a working-tree file.
        text = subprocess.run(["git", "-C", str(repo), "show", "HEAD:tests/mac/ms6_hard_gate.sh"], check=True,
                              capture_output=True, text=True).stdout
        p = subprocess.run(["bash", "-c", text, "ms6-hard-gate", "HEAD"], capture_output=True, text=True,
                           timeout=30, cwd=repo, env=env)
        return p, (record.read_text() if record.exists() else "")

    def test_without_the_pinned_tree_the_gate_is_not_armed_and_touches_no_network(self):
        p, calls = self.run_gate(with_pins=False)
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("NOT ARMED", p.stdout + p.stderr)
        self.assertEqual(calls, "", "no ssh/scp/curl/nc, to any host")

    def test_malformed_pins_are_refused_and_touch_no_network(self):
        # Armed since the MS5 pins (RoseCat 7250): a pins file is no longer "not armed" but must be well formed; "{}"
        # is refused before any network (tests/e2e/ms6_hard_gate_entry_test.py covers every precondition).
        p, calls = self.run_gate(with_pins=True)
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("pins", p.stdout + p.stderr)
        self.assertEqual(calls, "", "no ssh/scp/curl/nc, to any host")


if __name__ == "__main__":
    unittest.main()
