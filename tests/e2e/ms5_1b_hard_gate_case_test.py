"""MS5.1b's macOS half as a hard-gate case (tests/mac/hard_gate/case_ms5_1b_skipped_links.py), on Linux with the
repo's own zb_agent_host standing in for the staged one.

The case runs, under the staged interpreter, the real setup.provision (select_token_route=False: no CLI is run) on a
SAI source it builds itself in its scratch: a skill with a dependency tree (node_modules), and four links that
resolve outside their item (a directory link nested in the skill, a file link in it, a link inside the dependency
tree, and a relative link up into the source HOME), each target holding a distinct binary canary. Its checks:
- the staged agent-host is present and this is the staged interpreter (as every staged case);
- setup succeeds and warns "skipped <link>: it links outside" for each of the four, and none is in the home;
- a fail-closed census of the whole agent home (each entry lstat'ed, symlinks never followed, any other non-regular
  entry or unreadable file a finding) finds no canary bytes, no marker in any name, and no finding;
- the dependency tree beside the skipped link is copied byte for byte.
Here, with the real shipped harness.Harness (ZB_HG_PYTHON / ZB_HG_PREFIX set as the gate sets them):
- an honest staged setup passes every check, and each of those checks is present;
- a staged setup that follows outbound links after warning (a mutated setup.py in the fake prefix) fails the case;
- the case is self-contained: it reads no other case file and imports no test module.
No signal is sent and no process is started (the case starts none: provision runs no CLI with the route off).
Run under the pinned agent-host python (setup imports the SDK), in a private PID namespace:
  cd tests/e2e && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v ms5_1b_hard_gate_case_test; exit $?'
Unregistered until the green."""
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
CASE = HARD_GATE / "case_ms5_1b_skipped_links.py"
EXPECTED = ("the staged agent-host is present", "this case runs under the staged interpreter",
            "setup provisions the home", "skipped skills/demo/assets", "skipped skills/demo/notes.md",
            "skipped skills/demo/node_modules/evil", "skipped skills/demo/up", "no canary bytes",
            "the dependency tree")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Ms51bCase(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="zb-ms51b-case-")))
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
        self.forget_staged()  # the case must import the staged tree, not one an earlier row loaded
        harness = load(HARD_GATE / "harness.py", "zb_hg_harness_ms51b")
        scratch = self.tmp / "scratch"
        scratch.mkdir(mode=0o700, exist_ok=True)
        env = {"ZB_HG_PYTHON": sys.executable, "ZB_HG_PREFIX": str(self.prefix)}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(io.StringIO()) as out:
            h = harness.Harness(str(scratch))
            try:
                load(CASE, "zb_hg_case_ms51b").run(h)
            finally:
                h.close()
        return h, out.getvalue()

    def test_an_honest_staged_setup_passes_every_check(self):
        h, out = self.run_case()
        self.assertEqual(h.failures, [], out)
        for label in EXPECTED:
            with self.subTest(check=label):
                self.assertIn(f"ok   {label}", out)

    def test_a_staged_setup_that_follows_outbound_links_fails(self):
        setup_py = self.prefix / "zb_agent_host" / "setup.py"
        text = setup_py.read_text()
        old = ("                print(f\"zigBrowser: agent-setup: skipped {entry_rel}: it links outside "
               "{rel.split('/')[0]}\",\n                      file=sys.stderr)\n                continue\n")
        self.assertEqual(text.count(old), 1, "the mutation's anchor moved")
        setup_py.write_text(text.replace(old, old.replace("                continue\n", "")))
        h, out = self.run_case()
        self.assertNotEqual(h.failures, [], out)

    def test_the_case_is_self_contained(self):
        source = CASE.read_text()
        self.assertEqual(re.findall(r"case_ms\w+|_test\b|import test_", source), [])


if __name__ == "__main__":
    unittest.main()
