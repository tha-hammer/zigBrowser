"""The MS6.3 hard-gate case leaves its scratch removable (24f8d49 on both Macs, BlueBeaver 7714): with the realpath fix
the helper really makes its token FIFO directory, <home>/scratchpad/token-fifo, and FifoHandoff leaves it empty at
mode 0300 by design; the driver's shutil.rmtree(..., ignore_errors=True) cannot list it, so the per-run root
/tmp/zb-hardgate-run-* stayed behind on both Macs.

Against the same fake staged host as ms6_hard_gate_fd3_cli_case_test, whose fake run now makes that directory at
0300 the way FifoHandoff does for every channel row:
- once the case has run, a plain shutil.rmtree of the case's scratch (no ignore_errors) succeeds;
- every token-fifo directory the rows left is the case's own (inside its scratch) and is 0700 again before then;
- an honest host still passes every row.
Run as our own uid WITHOUT capabilities (a 0300 directory is unlistable even by its owner): cd tests/e2e && unshare \\
  --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c 'setsid -w python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_cleanup_test; exit $?'
No signal is sent (the base fixture patches os.kill / os.killpg to raise; h.spawn_group is a fake).
Unregistered until the green."""
import os
import shutil
import stat
import unittest

import ms6_hard_gate_fd3_cli_case_test as base


class TokenFifoDirs(base.FakeStagedHost):
    def fake_run(self, argv, env, pass_fds):
        if pass_fds:  # a channel row: the helper's FifoHandoff makes its directory 0300 and leaves it, empty
            home = argv[argv.index("--home") + 1]
            fifo_dir = os.path.join(home, "scratchpad", "token-fifo")
            os.mkdir(fifo_dir, 0o300)
            os.chmod(fifo_dir, 0o300)
            self.fifo_dirs.append(fifo_dir)
        return super().fake_run(argv, env, pass_fds)

    def setUp(self):
        super().setUp()
        self.fifo_dirs = []
        self.addCleanup(self.unlock)  # runs before the base's rmtree: a red must not leave 0300 dirs in /tmp

    def unlock(self):
        for d in self.fifo_dirs:
            if os.path.isdir(d) and not os.path.islink(d):
                os.chmod(d, 0o700)

    def test_the_cases_scratch_is_removable_afterwards(self):
        h = self.run_case()
        self.assertEqual(self.failed(h), [])
        self.assertEqual(len(self.fifo_dirs), 2, "the positive and decoy rows each made one")
        for d in self.fifo_dirs:
            with self.subTest(fifo_dir=os.path.relpath(d, self.scratch)):
                self.assertTrue(d.startswith(self.scratch + os.sep))
                self.assertEqual(stat.S_IMODE(os.lstat(d).st_mode), 0o700, "left unlistable")
        shutil.rmtree(self.scratch)  # what the driver needs: no ignore_errors, nothing left
        self.assertFalse(os.path.lexists(self.scratch))


def load_tests(loader, tests, pattern):
    """Only this file's own row: the inherited ones pin the plain fixture."""
    return unittest.TestSuite([TokenFifoDirs("test_the_cases_scratch_is_removable_afterwards")])


if __name__ == "__main__":
    unittest.main()
