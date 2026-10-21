"""MS5 framework relocation (the user approved relocating the python.org framework; measured 2026-10-21 on both Macs):
the staged CPython 3.12.10 cannot run as staged, because its executables, its Python library and its lib-dynload
extensions load /Library/Frameworks/Python.framework/Versions/3.12/... by absolute path. Relocating only the
executables is a trap: on x86_64 dyld's fallback then loaded a foreign /usr/local/lib/libssl.3.dylib.

packaging/macos/relocate_python_framework.py plans the rewrite from each Mach-O's install id and load commands (as
`otool -D` / `otool -L` report them), pure and testable off-Mac:

- plan(files, old_root) -> install_name_tool argv lists. `files` maps a path relative to the framework version root
  (".../Versions/3.12") to {"id": str or None, "deps": [str]}:
  - an id under old_root becomes "@loader_path/<its basename>" (`-id`);
  - a dependency old_root/<rel> becomes "@loader_path/<rel relative to the depending file's directory>" (`-change`);
  - a dependency under old_root whose target is not one of `files` is refused (ValueError naming both);
  - any other absolute dependency outside /usr/lib/ and /System/ (e.g. /usr/local/lib, /opt/homebrew) is refused;
  - @rpath/@loader_path/@executable_path dependencies and system ones are left alone.
- problems(files, old_root) -> every id or dependency still under /Library/Frameworks/Python.framework, or absolute
  outside /usr/lib/ and /System/ (the static census the Mac gate runs after relocation).

Pure, no process, no signal. The real relocation and the runtime proof (every non-system image loaded comes from the
staged tree, also after the tree is moved) are tests/mac/ms5_relocate_gate.sh on both Macs.
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v mac_relocate_test. Unregistered until the green.
"""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "packaging" / "macos" / "relocate_python_framework.py"
OLD = "/Library/Frameworks/Python.framework/Versions/3.12"


def load():
    if not SCRIPT.is_file():
        raise AssertionError("packaging/macos/relocate_python_framework.py is missing (MS5 relocation)")
    spec = importlib.util.spec_from_file_location("relocate_python_framework", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def framework():
    """The shape measured on both Macs (otool -D / -L of the staged 3.12.10), trimmed to one of each kind."""
    sysdeps = ["/usr/lib/libSystem.B.dylib"]
    return {
        "Python": {"id": f"{OLD}/Python", "deps": [f"{OLD}/Python"] + sysdeps},
        "bin/python3.12": {"id": None, "deps": [f"{OLD}/Python"] + sysdeps},
        "Resources/Python.app/Contents/MacOS/Python": {
            "id": None,
            "deps": ["/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", f"{OLD}/Python"]
            + sysdeps},
        "lib/libssl.3.dylib": {"id": f"{OLD}/lib/libssl.3.dylib",
                               "deps": [f"{OLD}/lib/libssl.3.dylib", f"{OLD}/lib/libcrypto.3.dylib"] + sysdeps},
        "lib/libcrypto.3.dylib": {"id": f"{OLD}/lib/libcrypto.3.dylib",
                                  "deps": [f"{OLD}/lib/libcrypto.3.dylib"] + sysdeps},
        "lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so": {
            "id": None, "deps": [f"{OLD}/lib/libssl.3.dylib", f"{OLD}/lib/libcrypto.3.dylib"] + sysdeps},
        "lib/python3.12/lib-dynload/_json.cpython-312-darwin.so": {"id": None, "deps": sysdeps},
    }


class Plan(unittest.TestCase):
    def setUp(self):
        self.r = load()

    def test_every_absolute_framework_path_becomes_loader_relative(self):
        cmds = self.r.plan(framework(), OLD)
        want = [
            ["install_name_tool", "-id", "@loader_path/Python", "Python"],
            ["install_name_tool", "-change", f"{OLD}/Python", "@loader_path/../Python", "bin/python3.12"],
            ["install_name_tool", "-change", f"{OLD}/Python", "@loader_path/../../../../Python",
             "Resources/Python.app/Contents/MacOS/Python"],
            ["install_name_tool", "-id", "@loader_path/libssl.3.dylib", "lib/libssl.3.dylib"],
            ["install_name_tool", "-change", f"{OLD}/lib/libcrypto.3.dylib", "@loader_path/libcrypto.3.dylib",
             "lib/libssl.3.dylib"],
            ["install_name_tool", "-id", "@loader_path/libcrypto.3.dylib", "lib/libcrypto.3.dylib"],
            ["install_name_tool", "-change", f"{OLD}/lib/libssl.3.dylib", "@loader_path/../../libssl.3.dylib",
             "lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so"],
            ["install_name_tool", "-change", f"{OLD}/lib/libcrypto.3.dylib", "@loader_path/../../libcrypto.3.dylib",
             "lib/python3.12/lib-dynload/_ssl.cpython-312-darwin.so"],
        ]
        self.assertEqual(sorted(cmds), sorted(want))

    def test_a_file_never_rewrites_its_own_id_as_a_dependency(self):
        # otool -L lists a dylib's own id first; that line is the id, not a load command to -change
        for cmd in self.r.plan(framework(), OLD):
            if cmd[1] == "-change":
                self.assertNotEqual(cmd[2], f"{OLD}/{cmd[-1]}", cmd)

    def test_a_framework_dependency_missing_from_the_tree_is_refused(self):
        files = framework()
        del files["lib/libcrypto.3.dylib"]
        with self.assertRaises(ValueError) as cm:
            self.r.plan(files, OLD)
        self.assertIn("lib/libcrypto.3.dylib", str(cm.exception))

    def test_a_foreign_absolute_dependency_is_refused(self):
        for foreign in ("/usr/local/lib/libssl.3.dylib", "/opt/homebrew/lib/libffi.8.dylib", "/Users/x/lib/a.dylib"):
            with self.subTest(dep=foreign):
                files = framework()
                files["lib/python3.12/lib-dynload/_json.cpython-312-darwin.so"]["deps"].append(foreign)
                with self.assertRaises(ValueError) as cm:
                    self.r.plan(files, OLD)
                self.assertIn(foreign, str(cm.exception))

    def test_system_and_relative_dependencies_are_left_alone(self):
        files = {"lib/a.dylib": {"id": "@rpath/a.dylib",
                                 "deps": ["@rpath/a.dylib", "@loader_path/b.dylib", "@executable_path/c",
                                          "/usr/lib/libz.1.dylib", "/System/Library/Frameworks/Foundation.framework/F"]},
                 "lib/b.dylib": {"id": None, "deps": []}}
        self.assertEqual(self.r.plan(files, OLD), [])


class Problems(unittest.TestCase):
    def setUp(self):
        self.r = load()

    def test_the_unrelocated_framework_is_all_problems(self):
        probs = self.r.problems(framework(), OLD)
        self.assertTrue(any("bin/python3.12" in p for p in probs), probs)
        self.assertTrue(any("_ssl.cpython-312-darwin.so" in p for p in probs), probs)

    def test_a_relocated_framework_has_none(self):
        relocated = {
            "Python": {"id": "@loader_path/Python", "deps": ["@loader_path/Python", "/usr/lib/libSystem.B.dylib"]},
            "bin/python3.12": {"id": None, "deps": ["@loader_path/../Python", "/usr/lib/libSystem.B.dylib"]},
        }
        self.assertEqual(self.r.problems(relocated, OLD), [])

    def test_a_foreign_path_left_in_is_a_problem(self):
        files = {"lib/x.so": {"id": None, "deps": ["/usr/local/lib/libssl.3.dylib"]}}
        self.assertEqual(len(self.r.problems(files, OLD)), 1)


if __name__ == "__main__":
    unittest.main()
