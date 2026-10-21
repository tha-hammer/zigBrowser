"""Setup's sandboxed run ends its whole process tree at its bound (16bad65, both Macs: the hang row's probe_r1 took
60.0 s, setup's subprocess.run timeout, which killed only the sandbox-exec/probe leader; the CLI the SDK started
outlived it until its own exit). RoseCat 7418: an owned process-group backstop at setup's _sandboxed boundary, through
a named production helper (setup.run_in_owned_group), never an SDK-private handle.

With REAL processes, on Linux with the platform injected and the MS6 seam faked to run a stand-in probe: the "probe"
(the group leader) starts a "CLI" that starts a grandchild; all three hold the run's stdout/stderr pipes and would
outlive the bound by far (each also ends itself after 20 s, so a leak is bounded):
- probe_r1 returns no R1 within the bound plus a small grace, not when the last pipe holder exits;
- when it returns, none of the three is alive (gone, or a zombie awaiting the namespace's init);
- the named helper exists (the hard gate observes it instead of subprocess.run);
- (plain, no signal: the seam is faked) when the owned group cannot be proven stopped (owned_group.StopFailed),
  _sandboxed reports no success, names its scratch on stderr, and LEAVES the scratch rather than cleaning up around
  a possibly live process (RoseCat 7436).
It sends signals, so it runs ONLY inside a private PID namespace proven by pidns_guard (the launcher passes its
outer namespace inode in ZB_OUTER_PIDNS) and skips anywhere else.
Run: cd agent/host/tests && outer=$(readlink /proc/self/ns/pid) && unshare --user --map-root-user --pid --fork \\
  --mount-proc sh -c "setsid env ZB_OUTER_PIDNS=$outer python -X dev -m unittest -v test_setup_sandbox_lifetime".
Unregistered until the green.
"""
import contextlib
import io
import os
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

import pidns_guard
import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin, sandbox_macos, setup

GRACE_S = 5
LIFETIME_S = 20  # every stand-in ends itself by then: a leak outside the namespace is bounded

PROBE = textwrap.dedent('''
    import os, subprocess, sys, time
    d = sys.argv[1]
    open(os.path.join(d, "probe"), "w").write(str(os.getpid()))
    subprocess.Popen([sys.executable, "-c", CLI, d])
    time.sleep(LIFETIME)
''')
CLI = textwrap.dedent('''
    import os, subprocess, sys, time
    d = sys.argv[1]
    open(os.path.join(d, "cli"), "w").write(str(os.getpid()))
    subprocess.Popen([sys.executable, "-c",
                      "import os, sys, time; open(os.path.join(sys.argv[1], 'grandchild'), 'w')"
                      ".write(str(os.getpid())); time.sleep(%d)" % LIFETIME, d])
    time.sleep(LIFETIME)
''')


def _alive(pid):
    """Alive = /proc/<pid> exists and is not a zombie (no signal is sent to find out)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


class OwnedGroupBound(unittest.TestCase):
    def setUp(self):
        ok, why = pidns_guard.private_pid_namespace()  # RoseCat 7422: the launcher's namespace-inode sentinel
        if not ok:
            self.skipTest(f"signals real processes: {why}")
        self.addCleanup(mock.patch.stopall)
        self.dir = tempfile.mkdtemp(prefix="zb-lifetime-")
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        mock.patch.object(setup, "PROBE_TIMEOUT_S", 2 - 30).start()  # probe_r1's run bound: PROBE_TIMEOUT_S + 30 = 2 s
        mock.patch.object(proc_darwin, "cli_env_clean", return_value=True).start()
        script = os.path.join(self.dir, "probe.py")
        with open(script, "w") as f:
            f.write(f"LIFETIME = {LIFETIME_S}\nCLI = {('LIFETIME = %d\n' % LIFETIME_S) + CLI!r}\n{PROBE}")

        @contextlib.contextmanager
        def seam(scratch, ro_paths, command, *, loopback_port=None):
            yield [sys.executable, script, self.dir]

        mock.patch.object(sandbox_macos, "setup_sandbox", seam).start()

    def pids(self):
        out = {}
        for name in ("probe", "cli", "grandchild"):
            try:
                with open(os.path.join(self.dir, name)) as f:
                    out[name] = int(f.read())
            except (OSError, ValueError):
                out[name] = None
        return out

    def test_the_bound_ends_the_whole_tree_and_returns_promptly(self):
        started = time.monotonic()
        verdict = setup.probe_r1("/rt/runtime/bin/zb-claude", "/opt/claude")
        took = time.monotonic() - started
        pids = self.pids()
        self.assertIs(verdict, False)
        self.assertTrue(all(pids.values()), f"the stand-ins started: {pids}")
        self.assertLess(took, 2 + GRACE_S, f"probe_r1 waited for the pipe holders ({took:.1f} s)")
        alive = {k: p for k, p in pids.items() if _alive(p)}
        self.assertEqual(alive, {}, "part of the sandboxed tree outlived setup's bound")

    def test_the_named_helper_exists(self):
        self.assertTrue(callable(getattr(setup, "run_in_owned_group", None)),
                        "setup.run_in_owned_group (RoseCat 7418's named seam) is missing")


class StopFailedLeavesTheScratch(unittest.TestCase):
    def test_a_stop_failure_leaves_and_names_the_scratch(self):
        try:
            from zb_agent_host import owned_group
        except ImportError:
            self.fail("zb_agent_host.owned_group is missing")
        self.addCleanup(mock.patch.stopall)
        root = tempfile.mkdtemp(prefix="zb-stopfailed-")
        mock.patch.object(tempfile, "tempdir", root).start()
        mock.patch.object(setup, "PLATFORM", "darwin").start()

        @contextlib.contextmanager
        def seam(scratch, ro_paths, command, *, loopback_port=None):
            yield ["/usr/bin/sandbox-exec", *command]

        mock.patch.object(sandbox_macos, "setup_sandbox", seam).start()
        mock.patch.object(setup, "run_in_owned_group",
                          side_effect=owned_group.StopFailed("process group 4242 could not be stopped")).start()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(setup._sandboxed(["/ro"], ["/opt/claude", "--version"], timeout=1), ("", False))
        (left,) = os.listdir(root)
        self.assertIn(os.path.join(os.path.realpath(root), left), err.getvalue(), "the scratch is named")
        self.assertIn("could not be stopped", err.getvalue())
        os.rmdir(os.path.join(root, left))
        os.rmdir(root)


if __name__ == "__main__":
    unittest.main()
