"""bd zigBrowser-4pa.81: a registered step must not turn a skipped test into a pass (the verification rule's "a skip is
a failure"; drawer plan RULE-AUDIT: 29 `= 77 ]` mappings).

RED, UNREGISTERED. The green removes the mappings and registers this census, so a new mapping fails `test`.

Rows (each its own test):
- C1 census, read from the real build.zig: every addSystemCommand whose script maps exit 77 to success, with the step
  that depends on it. No such command may be reachable from aggregate `test`. Today: 29, each with a direct
  `test_step.dependOn`.
- C2 the detector catches every spelling (`= 77`, `-eq 77`, `== 77`, quoted or not, `case ... 77)`) and passes a
  script that only reports 77. A reformatted mapping cannot hide. This passes today; it is the census's own control.
- D1 driven: for three representative mapped steps (automation-core, http2-goaway, page-health), the EXACT script
  string from build.zig is run as the step runs it (`sh -c <script> <name> <binary>`), with a binary path that does
  not exist. Each test returns 77 before it opens any display or starts a browser, so the step's own exit status is
  what the gate would see. A skip must fail the step: today each one exits 0.
- D2 control: the same three scripts still fail on a real failure. The test is given an argument it rejects
  (exit 2), and the step exits nonzero, so D1 is not passing because of a broken harness.

Hostless and safe: env -i with no DISPLAY, WAYLAND_DISPLAY or XAUTHORITY; a nonexistent binary, so no browser or X
server starts; the run happens inside a private user/net/pid/mount namespace, set up by the caller (see Run).

Run (from the repo root):
    unshare --user --map-root-user --net --pid --fork --mount-proc \\
      python3 -X dev -m unittest -v tests/e2e/skip_is_failure_census_test.py
"""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build.zig"
REPRESENTATIVES = ("automation_core_e2e", "http2_goaway_e2e", "page_health_e2e")

# A test of the status against 77 followed, in the same script, by an exit 0 before the status is passed on.
_RC_77 = r'(?:\\?"?\$(?:rc|\?)\\?"?\s*(?:=|==|-eq)\s*\\?"?77\\?"?)'
SKIP_TO_SUCCESS = re.compile(r'(?:\[\s*' + _RC_77 + r'\s*\][^;]*;\s*then\s+exit\s+0|case\s+\\?"?\$(?:rc|\?)\\?"?\s+in[^)]*\b77\)\s*exit\s+0)')
COMMAND = re.compile(r'const (\w+) = b\.addSystemCommand\(&\.\{(.*?)\}\);', re.S)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


_ZIG_ESCAPE = re.compile(r'\\(.)')
_ZIG_CHARS = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}


def zig_unescape(text):
    """A Zig string literal's body as the program sees it (the escapes build.zig uses: \\" \\\\ \\n \\t \\r)."""
    return _ZIG_ESCAPE.sub(lambda m: _ZIG_CHARS.get(m.group(1), "\\" + m.group(1)), text)


def commands(source):
    """{var: [its argv strings, unescaped]} for every b.addSystemCommand in build.zig."""
    return {m.group(1): [zig_unescape(s) for s in STRING.findall(m.group(2))] for m in COMMAND.finditer(source)}


def dependents(source, var):
    """The dependOn lines naming `var`'s step, with any `if (...)` guard: [(guard or "", step)]."""
    out = []
    for m in re.finditer(r'^\s*(?:if \((.*?)\)\s*)?(\w+)\.dependOn\(&' + re.escape(var) + r'\.step\);', source, re.M):
        out.append((m.group(1) or "", m.group(2)))
    return out


def mapped(source):
    """[(var, script)] for every system command whose script maps exit 77 to success."""
    found = []
    for var, argv in commands(source).items():
        for arg in argv:
            if SKIP_TO_SUCCESS.search(arg):
                found.append((var, arg))
    return found


def run_step_script(script, name, binary):
    # The step's `python3` is this interpreter (the gate's), first on PATH; the SDK the e2e tests import needs 3.14.
    with tempfile.TemporaryDirectory(prefix="zb-skip-home-") as home:
        env = {"PATH": f"{os.path.dirname(sys.executable)}:/usr/bin:/bin", "LANG": "C.UTF-8",
               "PYTHONDONTWRITEBYTECODE": "1", "HOME": home, "TMPDIR": tempfile.gettempdir()}
        return subprocess.run(["sh", "-c", script, name, binary], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=120, check=False)


class SkipIsFailure(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = BUILD.read_text()

    def test_c1_no_step_reachable_from_test_maps_a_skip_to_success(self):
        offenders = []
        for var, _script in mapped(self.source):
            for guard, step in dependents(self.source, var):
                if step == "test_step":
                    offenders.append(f"{var} (test_step{', if ' + guard if guard else ''})")
        self.assertEqual(offenders, [], f"C1: {len(offenders)} steps in `test` turn exit 77 into success")

    def test_c2_the_detector_catches_every_spelling_and_only_mappings(self):
        hits = [
            'x; rc=$?; if [ "$rc" = 77 ]; then exit 0; fi; exit "$rc"',
            'x; rc=$?; if [ $rc -eq 77 ]; then exit 0; fi; exit $rc',
            'x; if [ "$?" == "77" ]; then exit 0; fi',
            'x; rc=$?; case "$rc" in 77) exit 0;; esac; exit $rc',
        ]
        misses = [
            'x; rc=$?; if [ "$rc" = 77 ]; then echo skipped >&2; exit 1; fi; exit "$rc"',
            'x; rc=$?; exit "$rc"',
            'echo 77; exit 0',
        ]
        for script in hits:
            with self.subTest(hit=script):
                self.assertIsNotNone(SKIP_TO_SUCCESS.search(script), "C2: a mapping must be detected")
        for script in misses:
            with self.subTest(miss=script):
                self.assertIsNone(SKIP_TO_SUCCESS.search(script), "C2: a non-mapping must not be")
        zig = ('    const demo = b.addSystemCommand(&.{\n        "sh",\n        "-c",\n'
               '        "python3 t.py --binary \\"$1\\"; rc=$?; if [ \\"$rc\\" = 77 ]; then exit 0; fi; exit \\"$rc\\"",\n'
               '        "demo",\n    });\n    test_step.dependOn(&demo.step);\n')
        self.assertEqual([v for v, _ in mapped(zig)], ["demo"], "C2: the Zig string form is unescaped and found")
        self.assertEqual(dependents(zig, "demo"), [("", "test_step")])

    def representative_scripts(self):
        cmds = commands(self.source)
        out = {}
        for var in REPRESENTATIVES:
            self.assertIn(var, cmds, f"{var} is not a system command in build.zig")
            argv = cmds[var]
            self.assertEqual(argv[:2], ["sh", "-c"], f"{var}: not an sh -c step")
            out[var] = (argv[2], argv[3])
        return out

    def test_d1_a_skipped_representative_test_fails_its_step(self):
        missing = str(Path(tempfile.gettempdir()) / "zb-no-such-binary")
        for var, (script, name) in self.representative_scripts().items():
            with self.subTest(step=var):
                r = run_step_script(script, name, missing)
                out = r.stdout.decode(errors="replace")
                self.assertIn("SKIP", out, f"D1: {var}: the test itself must have skipped (output: {out[-300:]!r})")
                self.assertNotEqual(r.returncode, 0, f"D1: {var}: a skip must fail the step, not pass it")

    def test_d2_control_a_real_failure_still_fails_the_step(self):
        for var, (script, name) in self.representative_scripts().items():
            with self.subTest(step=var):
                broken = script.replace('--binary "$1"', '--no-such-option "$1"')
                self.assertNotEqual(broken, script, f"D2: {var}: the script's binary argument moved")
                r = run_step_script(broken, name, "/nonexistent")
                self.assertNotIn(r.returncode, (0, 77), f"D2: {var}: a usage error must fail the step")


if __name__ == "__main__":
    unittest.main()
