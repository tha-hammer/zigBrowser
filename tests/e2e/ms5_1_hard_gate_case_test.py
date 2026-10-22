"""MS5.1's inherited S3a corrections (da5eb70; RoseCat 833767e) on a Mac, as a hard-gate case
(tests/mac/hard_gate/case_ms5_1_s3a_links.py), proven here on Linux with the repo's own zb_agent_host standing
in for the staged one. The plan: "the Mac port must reuse the corrected behavior, not port today's defects".

Under the staged runtime the case runs the real setup.provision (route off: no CLI run, no process, no signal) on three
SAI sources it writes under the real path of its scratch, each into its own agent home:
- chain: CLAUDE.md -> hop/CLAUDE.md with hop -> a directory outside (a link in a parent component): setup warns
  "skipped CLAUDE.md: its link is a chain", and the target's canary is nowhere in the home;
- alias: skills/alias and skills/zzz-alias -> real (internal aliases, before and after the real name) and
  skills/real/loop -> .. (a real cycle):
  setup ends well within its bound, both names hold the payload, and setup warns "a link cycle";
- quote: a Stop hook whose command is `python3 "unterminated` (a malformed quote): setup refuses with SetupError
  "hook command has shell syntax" (never a parser crash) and leaves no agent home.
Here, with the real shipped harness.Harness (ZB_HG_PYTHON / ZB_HG_PREFIX set as the gate sets them):
- an honest staged setup passes every named check;
- each of three staged setup.py mutants fails the case: the parent-component chain check removed (_link_target), the
  internal alias dropped by a global seen set (an alias to a directory already copied is skipped), and the hook
  grammar check replaced by shlex.split (the old crash);
- the case is self-contained (its code imports no test module and names no other case file).
No signal is sent and no process is started. Run under the pinned agent-host python (setup imports the SDK):
  cd tests/e2e && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v ms5_1_hard_gate_case_test; exit $?'
Registered (build.zig: test-mac-census and the Linux test step), inside the namespace."""
import ast
import contextlib
import importlib.util
import io
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
HARD_GATE = REPO / "tests" / "mac" / "hard_gate"
CASE = REPO / "tests" / "mac" / "hard_gate" / "case_ms5_1_s3a_links.py"
EXPECTED = ("the staged agent-host is present", "this case runs under the staged interpreter",
            "chain: setup provisions", "chain: skipped CLAUDE.md", "chain: the canary is nowhere",
            "alias: setup provisions", "alias: both names hold the payload", "alias: the cycle is bounded",
            "quote: setup refuses", "quote: no agent home")
MUTANTS = {
    "chain followed": ("    if os.path.realpath(target) != target:\n        return None\n", ""),
    "alias dropped": ("            path = resolved\n",
                      "            if resolved.is_dir():\n                continue  # an internal alias dropped\n"
                      "            path = resolved\n"),
    "quote crash": ("        raise SetupError(f\"hook command has shell syntax: {where}\")\n",
                    "        import shlex\n        return shlex.split(command)\n"),
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Ms51Case(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="zb-ms51-case-")))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.prefix = self.tmp / "prefix"
        shutil.copytree(REPO / "agent" / "host" / "zb_agent_host", self.prefix / "zb_agent_host",
                        ignore=shutil.ignore_patterns("__pycache__"))
        self.addCleanup(self.forget_staged)

    def forget_staged(self):
        for name in [n for n in sys.modules if n == "zb_agent_host" or n.startswith("zb_agent_host.")]:
            del sys.modules[name]
        while str(self.prefix) in sys.path:
            sys.path.remove(str(self.prefix))

    def run_case(self):
        self.forget_staged()
        harness = load(HARD_GATE / "harness.py", "zb_hg_harness_ms51")
        scratch = Path(tempfile.mkdtemp(dir=self.tmp, prefix="scratch-"))
        env = {"ZB_HG_PYTHON": sys.executable, "ZB_HG_PREFIX": str(self.prefix)}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()) as out:
            h = harness.Harness(str(scratch))
            try:
                load(CASE, "zb_hg_case_ms51").run(h)
            finally:
                h.close()
        return h, out.getvalue()

    def test_an_honest_staged_setup_passes_every_check(self):
        h, out = self.run_case()
        self.assertEqual(h.failures, [], out)
        for label in EXPECTED:
            with self.subTest(check=label):
                self.assertIn(f"ok   {label}", out)

    def test_each_staged_setup_mutant_fails_the_case(self):
        setup_py = self.prefix / "zb_agent_host" / "setup.py"
        honest = setup_py.read_text()
        for name, (old, new) in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertEqual(honest.count(old), 1, f"{name}: the mutation's anchor moved")
                setup_py.write_text(honest.replace(old, new))
                try:
                    h, out = self.run_case()
                finally:
                    setup_py.write_text(honest)
                self.assertNotEqual(h.failures, [], f"{name} passed the case:\n{out}")

    def test_the_case_is_self_contained(self):
        tree = ast.parse(CASE.read_text())
        imported = [a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names]
        imported += [n.module or "" for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)]
        doc = ast.get_docstring(tree, clean=False)
        strings = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)
                   and n.value != doc]
        self.assertEqual([m for m in imported if m.endswith("_test") or m.startswith(("test_", "case_"))], [])
        self.assertEqual([t for t in strings if re.search(r"case_\w+\.py|_test\.py", t)], [])


if __name__ == "__main__":
    unittest.main()
