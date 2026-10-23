#!/usr/bin/env python3
"""zigBrowser-ong.10 RED (UNREGISTERED): every registered live Windows step's test file is in the phase list.

Bug (FoggyReef, found at 4f9cac2): delete tests/e2e/win_capabilities_test.py from tests/windows/live_phases.txt
while the step windows-capabilities-live stays in build.zig, and the registered live_step_skip_test.py still passes
(Ran 10 OK). Nothing pins that each `windows-*-live` step (and windows-drawer-behaviors) has its test file listed,
so a live test can silently drop out of `zig build windows-live` and `gate.sh --product`.

Check: for every live step that live_step_skip_test discovers, each test file named in its registered argv is a
phase-list entry, unless the step is on the reviewed exclusion list below; every exclusion names a step that
exists; every phase entry is a file that exists. This compares registration text, so it is a labelled TRIPWIRE
(plan rule 5); the execution proof of what the gate runs stays the hostless `windows-live` / `gate.sh --product`
runs. The green moves it into live_step_skip_test.py (step windows-live-step-skip).

Run alone:  python3 -I tests/windows/live_phase_membership_red_test.py -v
"""
import pathlib
import re
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import live_step_skip_test as lss  # noqa: E402

# Live steps deliberately NOT in the phase list, each with its reason.
NOT_IN_PHASES = {
    "windows-wincontain-argv-live": "Job Object model dropped (OD-W4); D.6(a) retires it",
    "windows-wincontain-resolve-live": "Job Object model dropped (OD-W4); D.6(a) retires it",
    "windows-wincontain-job-live": "Job Object model dropped (OD-W4); D.6(a) retires it",
}


def step_test_files(argv: list[str]) -> list[str]:
    return sorted({m for a in argv for m in re.findall(r"tests/[\w/.-]+\.py", a)})


class PhaseListMembershipRed(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_zig = (lss.REPO / "build.zig").read_text()
        cls.steps = lss.live_steps(cls.build_zig)
        cls.phases = lss.phase_entries()

    def test_every_live_step_test_file_is_a_phase_entry(self):
        for step in self.steps:
            if step in NOT_IN_PHASES:
                continue
            with self.subTest(step=step):
                files = step_test_files(lss.step_argv(self.build_zig, step))
                self.assertTrue(files, f"{step}: no tests/*.py file in its registered argv")
                for f in files:
                    self.assertIn(f, self.phases, f"{step}: {f} is registered but missing from {lss.PHASES.name}, so "
                                  "`zig build windows-live` and `gate.sh --product` would never run it")

    def test_every_exclusion_names_a_registered_step(self):
        self.assertEqual(sorted(set(NOT_IN_PHASES) - set(self.steps)), [], "a stale exclusion hides nothing; remove it")

    def test_every_phase_entry_exists(self):
        for entry in self.phases:
            with self.subTest(entry=entry):
                self.assertTrue((lss.REPO / entry).is_file(), f"phase entry {entry} does not exist")


if __name__ == "__main__":
    unittest.main()
