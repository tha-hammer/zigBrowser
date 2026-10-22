"""The MS6.3 hard-gate case builds every home under the REAL path of its scratch (11b3ac4 on both Macs; RoseCat 7627):
the driver's per-run root was /tmp/zb-hardgate-run-..., macOS's /tmp is a symlink to private/tmp, and the generated
profile's write root (-D SCRATCHPAD=<home>/scratchpad) never matched the resolved path Seatbelt checks, so the helper
was denied creating its token-fifo inside its own scratchpad.

Against the same fake staged host as ms6_hard_gate_fd3_cli_case_test, with h.scratch reached through a symlinked
ancestor (like /tmp -> private/tmp):
- every run's --home, and so its SCRATCHPAD, equals its own realpath and lies under realpath(h.scratch);
- the case itself checks, per row, that the home's scratchpad is its own real path (a passing check);
- an honest host still passes every row.
No signal is sent (the base fixture patches os.kill / os.killpg to raise; h.spawn_group is a fake).
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_cli_realpath_test'
Unregistered until the green."""
import os
import unittest

import ms6_hard_gate_fd3_cli_case_test as base


class SymlinkedScratch(base.FakeStagedHost):
    def setUp(self):
        super().setUp()
        real = os.path.join(self.tmp, "private-tmp")
        os.makedirs(os.path.join(real, "run"))
        os.symlink(real, os.path.join(self.tmp, "tmp"))  # like macOS's /tmp -> private/tmp
        self.scratch = os.path.join(self.tmp, "tmp", "run")
        self.real_scratch = os.path.join(os.path.realpath(real), "run")

    def test_every_home_is_built_under_the_real_scratch(self):
        h = self.run_case()
        self.assertEqual(len(self.runs), 3)
        for run in self.runs:
            argv = run["argv"]
            home = argv[argv.index("--home") + 1]
            with self.subTest(home=home):
                self.assertEqual(home, os.path.realpath(home), "the home is reached through a symlink")
                self.assertTrue(home.startswith(self.real_scratch + os.sep), home)
                self.assertIn(f"SCRATCHPAD={home}/scratchpad", argv)
        self.assertEqual(self.failed(h), [])

    def test_the_case_checks_each_scratchpad_is_its_real_path(self):
        h = self.run_case()
        for row in ("positive", "decoy", "no channel"):
            with self.subTest(row=row):
                want = f"{row}: the home's scratchpad is its own real path"
                labels = [(ok, l) for ok, l in h.checks if l.startswith(want)]
                self.assertEqual([ok for ok, _ in labels], [True], labels)


def load_tests(loader, tests, pattern):
    """Only this file's own rows: the inherited ones pin the plain fixture's paths."""
    own = sorted(n for n in SymlinkedScratch.__dict__ if n.startswith("test_"))
    return unittest.TestSuite(SymlinkedScratch(n) for n in own)


if __name__ == "__main__":
    unittest.main()
