"""The MS6 hard-gate harness itself (plan rev 18.1; RoseCat 7134, caf95b9): the Harness's process-group ownership and
the entry's NOT ARMED refusal, observed.

- h.spawn_group(argv, env, pass_fds, timeout) owns its process group EXACTLY once. It waits for the leader WITHOUT
  reaping it, so the leader's zombie keeps the pgid from being reused. Then it SIGKILLs the whole group, which also
  takes a child that outlived the leader, and only then reaps. close() never signals a group spawn_group already
  reaped. Tests: a normal run (output, one group kill), a timeout (None, bounded, no survivor), a child outliving the
  leader (killed), 3 MB of output (no deadlock), close() twice (no extra signal), and, at the moment of the group
  kill, the leader is not yet reaped (/proc/<pgid> still exists).
- tests/mac/ms6_hard_gate.sh, NOT ARMED with the pins absent and with pins present but staging absent: exit 3, "NOT
  ARMED", and recording ssh/scp/sftp/curl/nc/rsync shims (first on PATH, canary hosts in every host variable) see no
  call at all.

Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_harness_test. Unregistered until the
green.
"""
import os
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
            # The leader must still be unreaped when its group is signalled: /proc/<pgid> exists (alive or zombie),
            # so the pgid cannot have been reused by an unrelated group.
            self.kills.append((pgid, sig, os.path.exists(f"/proc/{pgid}")))
            return real(pgid, sig)

        from unittest import mock
        patcher = mock.patch.object(self.harness.os, "killpg", side_effect=counting_killpg)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.h = self.harness.Harness(self.scratch)

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"

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
        self.h.spawn_group(["/bin/true"], timeout=10)
        before = list(self.kills)
        self.h.close()
        self.h.close()
        self.assertEqual(self.kills, before, "exactly once: close() leaves an already-reaped group alone")


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
        shims, record = repo / "shims", repo / "network-calls"
        shims.mkdir()
        for tool in ("ssh", "scp", "sftp", "curl", "nc", "rsync"):
            (shims / tool).write_text(f"#!/bin/sh\necho {tool} \"$@\" >> '{record}'\nexit 99\n")
            (shims / tool).chmod(0o755)
        env = {"PATH": f"{shims}:/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(repo),
               "ZB_MAC_HOST": "canary-intel@192.0.2.10", "ZB_MAC_ARM_HOST": "canary-arm@192.0.2.11",
               "ZB_MAC_KEY": str(repo / "no-key"), "ZB_MAC_ARM_KEY": str(repo / "no-key")}
        p = subprocess.run(["bash", str(repo / "tests" / "mac" / "ms6_hard_gate.sh")], capture_output=True,
                           text=True, timeout=30, cwd=repo, env=env)
        return p, (record.read_text() if record.exists() else "")

    def test_without_the_pinned_tree_the_gate_is_not_armed_and_touches_no_network(self):
        p, calls = self.run_gate(with_pins=False)
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("NOT ARMED", p.stdout + p.stderr)
        self.assertEqual(calls, "", "no ssh/scp/curl/nc, to any host")

    def test_pins_without_staging_is_still_not_armed_and_touches_no_network(self):
        p, calls = self.run_gate(with_pins=True)
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("NOT ARMED", p.stdout + p.stderr)
        self.assertEqual(calls, "", "no ssh/scp/curl/nc, to any host")


if __name__ == "__main__":
    unittest.main()
