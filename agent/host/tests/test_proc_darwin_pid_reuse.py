"""A descendant confirmed gone is never traversed, so a reused pid never lends the census its children (RoseCat 8010,
74f693d, blocking 9de292a). RoseCat's probe: children(root) -> [8], path(8) -> None (ESRCH: 8 is gone), then pid 8
is reused by an unrelated process whose child 7 is a clean CLI; a walk that still queues 8 calls children(8), finds
7, and proc_darwin.cli_env_census says "ok" instead of "cli-not-found".
- descendants_running: a kid whose path() is None is never queued (zero children() calls on it), whether the first
  path() said ESRCH or a failing path()'s immediate re-probe did;
- cli_env_census: that pid as the only candidate -> cli-not-found, and the reused pid's child is never looked at; ok
  only with a separate live descendant running the CLI, the only environment read.
The walk's calls (children, path, environ_of) are faked; os.kill / os.killpg raise.
Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_proc_darwin_pid_reuse
Registered (build.zig: the MS5 agent-setup step), inside a PID namespace."""
import errno
import os
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin

EXE = "/opt/claude"
TOKEN = b"zb-probe-" + b"ef" * 24
CANARY = b"ANTHROPIC_BASE_URL=http://127.0.0.1:50123"
ROOT = os.getpid()
GONE = object()  # path(): None (ESRCH)
UNREADABLE = OSError(errno.EINVAL, "proc_pidpath: Invalid argument")


class PidReuse(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(mock.patch.stopall)

    def fake(self, tree, paths):
        """tree: pid -> children (pid 8's entry is the REUSED process's); paths: pid -> successive path() results."""
        self.children_calls, self.path_calls, self.environ_calls = [], {}, []

        def children(pid):
            self.children_calls.append(pid)
            return list(tree.get(pid, []))

        def path(pid):
            n = self.path_calls[pid] = self.path_calls.get(pid, 0) + 1
            seq = paths.get(pid, [GONE])
            got = seq[min(n, len(seq)) - 1]
            if isinstance(got, BaseException):
                raise got
            return None if got is GONE else got

        def environ_of(pid):
            self.environ_calls.append(pid)
            return b"\0".join([EXE.encode(), b"--x", CANARY]), [b"--x"], [CANARY]

        mock.patch.object(proc_darwin, "children", side_effect=children).start()
        mock.patch.object(proc_darwin, "path", side_effect=path).start()
        mock.patch.object(proc_darwin, "environ_of", side_effect=environ_of).start()

    GONE_AS = (("ESRCH at path()", [GONE]), ("confirmed by the re-probe", [UNREADABLE, GONE]))

    def test_the_walk_never_traverses_a_pid_confirmed_gone(self):
        for label, gone in self.GONE_AS:
            with self.subTest(gone=label):
                self.fake({ROOT: [8], 8: [7]}, {8: gone, 7: [EXE]})
                self.assertEqual(proc_darwin.descendants_running(EXE, ROOT), [])
                self.assertEqual(self.children_calls, [ROOT], "the gone pid was traversed")
                self.assertNotIn(7, self.path_calls, "the reused pid's child was looked at")

    def test_the_gone_pid_as_the_only_candidate_is_cli_not_found(self):
        if not hasattr(proc_darwin, "cli_env_census"):
            self.fail("proc_darwin.cli_env_census is missing (RoseCat 7986)")
        for label, gone in self.GONE_AS:
            with self.subTest(gone=label):
                self.fake({ROOT: [8], 8: [7]}, {8: gone, 7: [EXE]})
                self.assertEqual(proc_darwin.cli_env_census(EXE, ROOT, TOKEN, CANARY), "cli-not-found")
                self.assertNotIn(8, self.children_calls, "the gone pid was traversed")
                self.assertEqual(self.environ_calls, [], "a CLI under the reused pid was checked")

    def test_ok_only_with_a_separate_live_cli_fully_checked(self):
        if not hasattr(proc_darwin, "cli_env_census"):
            self.fail("proc_darwin.cli_env_census is missing (RoseCat 7986)")
        for label, gone in self.GONE_AS:
            with self.subTest(gone=label):
                self.fake({ROOT: [8, 9], 8: [7]}, {8: gone, 9: [EXE], 7: [EXE]})
                self.assertEqual(proc_darwin.cli_env_census(EXE, ROOT, TOKEN, CANARY), "ok")
                self.assertNotIn(8, self.children_calls, "the gone pid was traversed")
                self.assertEqual(self.environ_calls, [9], "only the separate live CLI is checked")


if __name__ == "__main__":
    unittest.main()
