"""MS5 fat agent-host (JadeBeacon 7206 approved the design; rule refinements BlueBeaver 7221): the two per-arch macOS
site-packages trees, built on Linux from the lock, merge into ONE universal2 tree by a strict rule. The real trees
(measured 2026-10-21) differ only in four thin Mach-O (cffi, pydantic-core, rpds-py, the claude CLI), their WHEEL Tag
lines, their RECORDs and two SBOMs.

packaging/macos/merge_universal_tree.py: merge(x86_64_root, arm64_root, out, run=subprocess.run):
- the two trees hold exactly the same relative file paths (else MergeError naming the path); no symlinks;
- a byte-identical file is copied once, with its mode;
- a thin x86_64 Mach-O paired with a thin arm64 Mach-O at one path becomes `lipo -create <x86> <arm> -output <out>`
  (through `run`); any other differing Mach-O pairing (same arch twice, fat vs thin, two different fat files) fails;
- `*.dist-info/WHEEL`: only `Tag:` lines may differ; the merged WHEEL keeps every line, with both arches' Tag lines;
- `*.dist-info/sboms/<name>.json` that differ are kept per arch as `<name>.x86_64.json` and `<name>.arm64.json`;
- `*.dist-info/RECORD` is regenerated from the merged files (sha256 urlsafe-b64 without padding, size; its own line
  `<path>,,`), every other difference fails naming the path;
- `out` must not exist; nothing is left under it when the merge fails.

Pure Python with an injectable runner: these tests never call lipo. The real merge on both Macs is
tests/mac/ms5_deps_gate.sh. No process, no signal.
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v mac_merge_universal_test. Unregistered until the green.
"""
import base64
import hashlib
import importlib.util
import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "packaging" / "macos" / "merge_universal_tree.py"
THIN_X86 = bytes.fromhex("cffaedfe07000001")  # MH_MAGIC_64, CPU_TYPE_X86_64 (little-endian)
THIN_ARM = bytes.fromhex("cffaedfe0c000001")  # MH_MAGIC_64, CPU_TYPE_ARM64
FAT = bytes.fromhex("cafebabe00000002")       # FAT_MAGIC, 2 slices (big-endian)


def load():
    if not SCRIPT.is_file():
        raise AssertionError("packaging/macos/merge_universal_tree.py is missing (MS5 fat agent-host)")
    spec = importlib.util.spec_from_file_location("merge_universal_tree", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def record_line(root, rel):
    data = (root / rel).read_bytes()
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{rel},sha256={digest},{len(data)}"


class Merge(unittest.TestCase):
    def setUp(self):
        self.m = load()
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-merge-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.x, self.a, self.out = self.tmp / "x86_64", self.tmp / "arm64", self.tmp / "out"
        self.lipo_calls = []

    def fake_run(self, argv, **kw):
        """Stands in for lipo -create <x86> <arm> -output <out>: records argv, writes a fat file."""
        self.lipo_calls.append(list(argv))
        assert argv[:2] == ["lipo", "-create"] and argv[4] == "-output", argv
        Path(argv[5]).write_bytes(FAT + Path(argv[2]).read_bytes() + Path(argv[3]).read_bytes())

        class Done:
            returncode = 0
        return Done()

    def both(self, rel, x_bytes, a_bytes=None, mode=0o644):
        for root, data in ((self.x, x_bytes), (self.a, x_bytes if a_bytes is None else a_bytes)):
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
            os.chmod(p, mode)

    def package(self):
        """A miniature of the measured shape: one compiled package, one pure one, a CLI, a universal2 .so."""
        self.both("pkg/__init__.py", b"x = 1\n")
        self.both("pkg/_core.cpython-312-darwin.so", THIN_X86 + b"x86 code", THIN_ARM + b"arm code", 0o755)
        self.both("pkg/_univ.abi3.so", FAT + b"both")
        self.both("sdk/_bundled/claude", THIN_X86 + b"cli x86", THIN_ARM + b"cli arm", 0o755)
        self.both("pkg-1.0.dist-info/METADATA", b"Name: pkg\nVersion: 1.0\n")
        self.both("pkg-1.0.dist-info/WHEEL", b"Wheel-Version: 1.0\nGenerator: x\nRoot-Is-Purelib: false\n"
                  b"Tag: cp312-cp312-macosx_10_15_x86_64\n",
                  b"Wheel-Version: 1.0\nGenerator: x\nRoot-Is-Purelib: false\nTag: cp312-cp312-macosx_11_0_arm64\n")
        self.both("pkg-1.0.dist-info/sboms/pkg.cyclonedx.json", b'{"components": 85}\n', b'{"components": 99}\n')
        self.both("pkg-1.0.dist-info/sboms/same.cyclonedx.json", b'{"same": true}\n')
        self.both("pkg-1.0.dist-info/RECORD", b"pkg/_core.cpython-312-darwin.so,sha256=AAA,8\nstale,,\n",
                  b"pkg/_core.cpython-312-darwin.so,sha256=BBB,8\nstale,,\n")

    def merge(self):
        self.m.merge(str(self.x), str(self.a), str(self.out), run=self.fake_run)

    def test_identical_files_are_copied_once_with_their_mode(self):
        self.package()
        self.merge()
        self.assertEqual((self.out / "pkg/__init__.py").read_bytes(), b"x = 1\n")
        self.assertEqual((self.out / "pkg/_univ.abi3.so").read_bytes(), FAT + b"both")

    def test_thin_pairs_go_through_lipo_create_x86_then_arm(self):
        self.package()
        self.merge()
        rels = sorted(Path(c[2]).relative_to(self.x).as_posix() for c in self.lipo_calls)
        self.assertEqual(rels, ["pkg/_core.cpython-312-darwin.so", "sdk/_bundled/claude"])
        for c in self.lipo_calls:
            rel = Path(c[2]).relative_to(self.x)
            self.assertEqual(Path(c[3]), self.a / rel)
            self.assertTrue((self.out / rel).read_bytes().startswith(FAT), rel)
        self.assertTrue(os.stat(self.out / "sdk/_bundled/claude").st_mode & stat.S_IXUSR, "the CLI stays executable")

    def test_wheel_keeps_both_tags(self):
        self.package()
        self.merge()
        wheel = (self.out / "pkg-1.0.dist-info/WHEEL").read_text().splitlines()
        self.assertEqual([l for l in wheel if l.startswith("Tag:")],
                         ["Tag: cp312-cp312-macosx_10_15_x86_64", "Tag: cp312-cp312-macosx_11_0_arm64"])
        self.assertEqual([l for l in wheel if not l.startswith("Tag:")],
                         ["Wheel-Version: 1.0", "Generator: x", "Root-Is-Purelib: false"])

    def test_differing_sboms_are_kept_per_arch_and_identical_ones_once(self):
        self.package()
        self.merge()
        sboms = self.out / "pkg-1.0.dist-info/sboms"
        self.assertEqual(sorted(p.name for p in sboms.iterdir()),
                         ["pkg.cyclonedx.arm64.json", "pkg.cyclonedx.x86_64.json", "same.cyclonedx.json"])
        self.assertEqual((sboms / "pkg.cyclonedx.x86_64.json").read_bytes(), b'{"components": 85}\n')
        self.assertEqual((sboms / "pkg.cyclonedx.arm64.json").read_bytes(), b'{"components": 99}\n')

    def test_record_is_regenerated_from_the_merged_files(self):
        self.package()
        self.merge()
        lines = (self.out / "pkg-1.0.dist-info/RECORD").read_text().splitlines()
        files = sorted(p.relative_to(self.out).as_posix() for p in self.out.rglob("*") if p.is_file())
        want = sorted(record_line(self.out, r) for r in files if r != "pkg-1.0.dist-info/RECORD")
        want.append("pkg-1.0.dist-info/RECORD,,")
        self.assertEqual(sorted(lines), sorted(want))

    def test_every_refusal_names_the_path_and_leaves_nothing(self):
        cases = {
            "only-in-one-tree": lambda: (self.x / "extra.py").write_bytes(b"x"),
            "other-text-differs": lambda: (self.a / "pkg/__init__.py").write_bytes(b"x = 2\n"),
            "same-arch-twice": lambda: (self.a / "pkg/_core.cpython-312-darwin.so").write_bytes(THIN_X86 + b"y"),
            "fat-vs-thin": lambda: (self.a / "pkg/_core.cpython-312-darwin.so").write_bytes(FAT + b"z"),
            "two-different-fat": lambda: (self.a / "pkg/_univ.abi3.so").write_bytes(FAT + b"other"),
            "wheel-non-tag-line": lambda: (self.a / "pkg-1.0.dist-info/WHEEL").write_bytes(
                b"Wheel-Version: 1.0\nGenerator: y\nRoot-Is-Purelib: false\nTag: cp312-cp312-macosx_11_0_arm64\n"),
            "symlink": lambda: (os.symlink("pkg/__init__.py", self.a / "link.py"),
                                os.symlink("pkg/__init__.py", self.x / "link.py")),
        }
        names = {"only-in-one-tree": "extra.py", "other-text-differs": "pkg/__init__.py",
                 "same-arch-twice": "pkg/_core", "fat-vs-thin": "pkg/_core", "two-different-fat": "pkg/_univ",
                 "wheel-non-tag-line": "pkg-1.0.dist-info/WHEEL", "symlink": "link.py"}
        for case, spoil in cases.items():
            with self.subTest(case=case):
                for root in (self.x, self.a, self.out):
                    shutil.rmtree(root, True)
                self.package()
                spoil()
                with self.assertRaises(self.m.MergeError) as cm:
                    self.merge()
                self.assertIn(names[case], str(cm.exception))
                self.assertFalse(self.out.exists(), "a failed merge leaves no output")

    def test_an_existing_output_is_refused(self):
        self.package()
        self.out.mkdir()
        with self.assertRaises(self.m.MergeError):
            self.merge()


if __name__ == "__main__":
    unittest.main()
