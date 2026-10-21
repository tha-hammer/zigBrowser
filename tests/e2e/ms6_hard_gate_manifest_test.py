"""The MS6 hard gate runs ONLY its reviewed cases (RoseCat 7250 #2, #3): an armed harness that globbed case_*.py would
run a newly committed, unreviewed signal test on a real person's Mac.

tests/mac/hard_gate/hard_gate_driver.py --manifest <MANIFEST.json> <cases dir>:
- MANIFEST.json is {"cases": [{"file": "case_<name>.py", "sha256": "<64 hex>"}, ...]}: plain file names (no path),
  each once, each with the SHA-256 of the reviewed file;
- BEFORE importing anything, the case_*.py files of the dir must be exactly the manifest's set, each with its pinned
  SHA-256; an extra (unreviewed) case, a missing one, an edited one, or a malformed manifest is a FAIL naming it, and
  then NO case is imported at all (each fake case below writes a sentinel when imported);
- with an exact match, the cases run as before.
The committed tests/mac/hard_gate/MANIFEST.json lists exactly the reviewed set, case_ms5_spawn_io.py and
case_ms6_6b_r1_chain.py, with their current hashes; nothing of the MS6.5 reaper is in the cases dir or the manifest
(RoseCat 7250 #3, 7244).

No process signal: the fake cases only check(True). Registered (green) inside the namespace like the driver suite.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_manifest_test'
"""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HARD_GATE = REPO / "tests" / "mac" / "hard_gate"
DRIVER = HARD_GATE / "hard_gate_driver.py"
MANIFEST = HARD_GATE / "MANIFEST.json"
REVIEWED = {"case_ms5_spawn_io.py", "case_ms6_6b_r1_chain.py"}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class DriverManifest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-hg-manifest-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cases = self.tmp / "cases"
        self.cases.mkdir()
        self.sentinels = self.tmp / "imported"
        self.sentinels.mkdir()

    def case(self, name):
        """A fake case that records its own import, then passes one check."""
        path = self.cases / f"case_{name}.py"
        path.write_text(f"open({str(self.sentinels / name)!r}, 'w').close()\n"
                        f"NAME = {name!r}\ndef run(h):\n    h.check(True, 'fine')\n")
        return path

    def manifest(self, entries):
        path = self.tmp / "MANIFEST.json"
        path.write_text(json.dumps({"cases": entries}))
        return path

    def entry(self, path):
        return {"file": Path(path).name, "sha256": sha(path)}

    def run_driver(self, manifest):
        p = subprocess.run([sys.executable, "-I", str(DRIVER), "--manifest", str(manifest), str(self.cases)],
                           capture_output=True, text=True, timeout=60, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        return p.returncode, p.stdout.splitlines()

    def imported(self):
        return sorted(p.name for p in self.sentinels.iterdir())

    def test_an_exact_manifest_runs_its_cases(self):
        a, b = self.case("alpha"), self.case("beta")
        code, lines = self.run_driver(self.manifest([self.entry(a), self.entry(b)]))
        self.assertEqual(code, 0, lines)
        self.assertEqual(lines[-1], "PASS\tms6-hard-gate\t2 cases")
        self.assertEqual(self.imported(), ["alpha", "beta"])

    def refused(self, manifest, needle):
        code, lines = self.run_driver(manifest)
        self.assertEqual(code, 1, lines)
        self.assertTrue(lines and lines[-1].startswith("FAIL\tms6-hard-gate\t"), lines)
        self.assertIn(needle, "\n".join(lines))
        self.assertEqual(self.imported(), [], "no case may be imported once the manifest check fails")

    def test_an_unreviewed_extra_case_is_refused_and_nothing_is_imported(self):
        a = self.case("alpha")
        m = self.manifest([self.entry(a)])
        self.case("unreviewed")
        self.refused(m, "case_unreviewed.py")

    def test_a_missing_reviewed_case_is_refused(self):
        a, b = self.case("alpha"), self.case("beta")
        m = self.manifest([self.entry(a), self.entry(b)])
        b.unlink()
        self.refused(m, "case_beta.py")

    def test_an_edited_case_is_refused(self):
        a = self.case("alpha")
        m = self.manifest([self.entry(a)])
        a.write_text(a.read_text() + "# edited after review\n")
        self.refused(m, "case_alpha.py")

    def test_a_malformed_manifest_is_refused(self):
        a = self.case("alpha")
        good = self.entry(a)
        bad = {
            "not json": "{",
            "no cases list": json.dumps({"case": [good]}),
            "duplicate entry": json.dumps({"cases": [good, good]}),
            "a path, not a name": json.dumps({"cases": [{"file": "../case_alpha.py", "sha256": good["sha256"]}]}),
            "not a case name": json.dumps({"cases": [{"file": "alpha.py", "sha256": good["sha256"]}]}),
            "bad sha256": json.dumps({"cases": [{"file": "case_alpha.py", "sha256": "abc"}]}),
            "empty": json.dumps({"cases": []}),
        }
        for label, text in bad.items():
            with self.subTest(manifest=label):
                path = self.tmp / "MANIFEST.json"
                path.write_text(text)
                self.refused(path, "manifest")


class CommittedManifest(unittest.TestCase):
    def test_it_lists_exactly_the_reviewed_cases_with_their_current_hashes(self):
        self.assertTrue(MANIFEST.is_file(), "tests/mac/hard_gate/MANIFEST.json is missing")
        cases = json.loads(MANIFEST.read_text())["cases"]
        self.assertEqual({c["file"] for c in cases}, REVIEWED)
        self.assertEqual(len(cases), len(REVIEWED))
        for c in cases:
            self.assertEqual(c["sha256"], sha(HARD_GATE / c["file"]), c["file"])
        self.assertEqual({p.name for p in HARD_GATE.glob("case_*.py")}, REVIEWED,
                         "a case file outside the reviewed set sits in tests/mac/hard_gate")

    def test_nothing_of_the_ms6_5_reaper_is_in_the_hard_gate(self):
        for p in HARD_GATE.iterdir():
            if p.is_file():
                self.assertNotIn("reaper", p.read_text(errors="replace").lower(), p.name)


if __name__ == "__main__":
    unittest.main()
