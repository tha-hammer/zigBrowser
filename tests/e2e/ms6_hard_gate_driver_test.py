"""The MS6 hard-gate harness's driver (plan rev 18.1; BlueBeaver 7123, 7127; JadeBeacon 7125): the one pre-seatbelt_ready
harness whose cases (MS6.3's real-CLI fd-3 case, MS6.6 (B)'s R1 chain) run under the staged pinned runtime on both
Macs. These Linux tests pin the driver's fail-closed rules with fake cases, and the entry script's NOT ARMED refusal:

- tests/mac/hard_gate/hard_gate_driver.py <cases dir> imports every case_*.py there (sorted), and runs each module's
  run(h) with a fresh Harness (tests/mac/hard_gate/harness.py). It prints "PASS\\t<NAME>" or "FAIL\\t<NAME>\\t<why>"
  per case and a last line "PASS\\tms6-hard-gate\\t<n> cases" (exit 0) or "FAIL\\tms6-hard-gate\\t..." (exit 1).
- Fail closed: a case whose check() failed, a case that raises, a case that made no check() at all, a case file
  without NAME or run, and an empty cases dir are each a FAIL; two cases with the same NAME are a FAIL.
- Each case gets its own scratch directory (h.scratch), removed afterwards; a case that leaves it unremovable is a FAIL.
- The entry's NOT ARMED refusal, observed with network shims, is in ms6_hard_gate_harness_test (RoseCat 7134).

Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_driver_test. Unregistered until the green.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DRIVER = REPO / "tests" / "mac" / "hard_gate" / "hard_gate_driver.py"


class Driver(unittest.TestCase):
    def setUp(self):
        if not DRIVER.is_file():
            self.fail("tests/mac/hard_gate/hard_gate_driver.py is missing (rev 18.1)")
        self.dir = Path(tempfile.mkdtemp(prefix="zb-hardgate-"))
        self.addCleanup(shutil.rmtree, self.dir, True)

    def case(self, name, body):
        (self.dir / f"case_{name}.py").write_text(textwrap.dedent(body))

    def run_driver(self):
        p = subprocess.run([sys.executable, "-I", str(DRIVER), str(self.dir)], capture_output=True, text=True,
                           timeout=60, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        return p.returncode, p.stdout.splitlines()

    def test_passing_cases_pass_and_the_aggregate_counts_them(self):
        self.case("a", '''
            NAME = "alpha"
            def run(h):
                h.check(True, "one")
                h.check(1 + 1 == 2, "two")
        ''')
        self.case("b", '''
            NAME = "beta"
            def run(h):
                open(h.scratch + "/f", "w").write("x")
                h.check(True, "wrote into its own scratch")
        ''')
        code, lines = self.run_driver()
        self.assertEqual(code, 0, lines)
        self.assertIn("PASS\talpha", lines)
        self.assertIn("PASS\tbeta", lines)
        self.assertEqual(lines[-1], "PASS\tms6-hard-gate\t2 cases")

    def test_every_fail_closed_shape_fails_the_case_and_the_aggregate(self):
        # file key -> (body, the label its FAIL line must carry: its NAME, or the module name when it has none)
        shapes = {
            "failed_check": ('NAME = "failed-check"\ndef run(h):\n    h.check(True, "ok")\n    h.check(False, "bad")\n',
                             "failed-check"),
            "raises": ('NAME = "raises"\ndef run(h):\n    h.check(True, "ok")\n    raise RuntimeError("boom")\n', "raises"),
            "no_check": ('NAME = "no-check"\ndef run(h):\n    pass\n', "no-check"),
            "no_name": ('def run(h):\n    h.check(True, "ok")\n', "case_no_name"),
            "no_run": ('NAME = "no-run"\n', "no-run"),
        }
        for key, (body, label) in shapes.items():
            with self.subTest(shape=key):
                for f in self.dir.glob("case_*.py"):
                    f.unlink()
                self.case("good", 'NAME = "good"\ndef run(h):\n    h.check(True, "fine")\n')
                self.case(key, body)
                code, lines = self.run_driver()
                self.assertEqual(code, 1, lines)
                self.assertTrue(any(l.startswith(f"FAIL\t{label}\t") for l in lines), lines)
                self.assertIn("PASS\tgood", lines, "one failing case never hides a passing one")
                self.assertTrue(lines[-1].startswith("FAIL\tms6-hard-gate"), lines)

    def test_no_cases_at_all_is_a_fail(self):
        code, lines = self.run_driver()
        self.assertEqual(code, 1, lines)
        self.assertTrue(lines[-1].startswith("FAIL\tms6-hard-gate"), lines)

    def test_two_cases_with_one_name_fail(self):
        self.case("a", 'NAME = "same"\ndef run(h):\n    h.check(True, "x")\n')
        self.case("b", 'NAME = "same"\ndef run(h):\n    h.check(True, "y")\n')
        code, lines = self.run_driver()
        self.assertEqual(code, 1, lines)

    def test_each_case_gets_its_own_scratch_and_it_is_removed(self):
        self.case("a", '''
            NAME = "scratch-a"
            def run(h):
                import os
                h.check(os.path.isdir(h.scratch) and os.listdir(h.scratch) == [], "a fresh empty scratch")
                open(os.path.join(h.scratch, "leftover"), "w").write("x")
        ''')
        self.case("b", '''
            NAME = "scratch-b"
            def run(h):
                import os
                h.check(os.path.isdir(h.scratch) and os.listdir(h.scratch) == [], "a fresh empty scratch")
                open(os.path.join(h.scratch, "leftover"), "w").write("x")
        ''')
        code, lines = self.run_driver()
        self.assertEqual(code, 0, lines)
        # The driver reports each case's scratch as "SCRATCH\t<NAME>\t<path>"; each must be gone afterwards.
        roots = {Path(l.split("\t", 2)[2]) for l in lines if l.startswith("SCRATCH\t")}
        self.assertEqual(len(roots), 2, lines)
        self.assertTrue(all(not r.exists() for r in roots), roots)


if __name__ == "__main__":
    unittest.main()
