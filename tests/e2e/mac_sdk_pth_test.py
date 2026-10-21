"""The staged interpreter imports the staged SDK (MS6.6 (B) on both Macs, 27a9a62: ModuleNotFoundError claude_agent_sdk;
the orchestrator's .pth conditions, 2026-10-21).

The staged framework python3.12 must see Frameworks/agent-host/site-packages without PYTHONPATH (setup's sandboxed
probe and the hard-gate case both run it), through ONE committed .pth, packaging/macos/agent_host_sdk.pth, that
staging (packaging/macos/sdk_pth.py install, called by stage_agent_runtime.sh) copies into the staged runtime's OWN
site-packages as zb_agent_host_sdk.pth:
- the committed file is one path line and nothing else: newline-terminated, relative (never an absolute host or user
  path), no "import" line (an import line runs code at every interpreter start), no comment, no CR/NUL; from the
  framework's site-packages (<agent-host>/Python.framework/Versions/3.12/lib/python3.12/site-packages) it resolves to
  exactly <agent-host>/site-packages, inside the bundle;
- sdk_pth.problems(site_dir, agent_host) is [] only for exactly that file there: a stray .pth (any other *.pth,
  hidden ones included), an import line, a second line, an absolute path, a path leaving the bundle or naming another
  dir, a symlinked or missing .pth are each a problem;
- sdk_pth.install(site_dir, agent_host) writes exactly the committed bytes and then checks; a stray .pth already there,
  or an existing target, is refused with nothing written;
- python -I does NOT skip site processing (sys.flags.no_site == 0; -I is -E -P -s): shown end to end with a real
  interpreter whose prefix site-packages holds the installed .pth (a venv laid out like the staged framework), which
  imports a stand-in claude_agent_sdk from <agent-host>/site-packages under -I, and still does after the whole tree
  moves (the line is relative to the .pth's own dir);
- the MS5 inventory declares it as a resource (role "sdk-path"), so the cross-arch resource check covers it.
No process is signalled. Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v mac_sdk_pth_test.
Unregistered until the green.
"""
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "packaging" / "macos"))
try:
    import sdk_pth  # packaging/macos/sdk_pth.py
except ImportError:
    sdk_pth = None
import ms5_inventory  # noqa: E402

COMMITTED = REPO / "packaging" / "macos" / "agent_host_sdk.pth"
FRAMEWORK_SITE = Path("Python.framework/Versions/3.12/lib/python3.12/site-packages")
NAME = "zb_agent_host_sdk.pth"


class Base(unittest.TestCase):
    def setUp(self):
        if sdk_pth is None:
            self.fail("packaging/macos/sdk_pth.py is missing")
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-sdk-pth-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.agent = self.tmp / "Frameworks" / "agent-host"
        self.site = self.agent / FRAMEWORK_SITE
        self.site.mkdir(parents=True)
        (self.agent / "site-packages").mkdir()


class CommittedFile(Base):
    def test_it_is_one_relative_path_line_that_resolves_to_the_staged_site_packages(self):
        self.assertTrue(COMMITTED.is_file(), "packaging/macos/agent_host_sdk.pth is missing")
        raw = COMMITTED.read_bytes()
        self.assertTrue(raw.endswith(b"\n") and raw.count(b"\n") == 1, raw)
        line = raw[:-1].decode("ascii")
        self.assertFalse(line.startswith(("import ", "import\t", "/", "#", "~")), line)
        self.assertNotIn("\r", line)
        self.assertEqual((self.site / line).resolve(), (self.agent / "site-packages").resolve())


class Problems(Base):
    def install_exact(self):
        (self.site / NAME).write_bytes(COMMITTED.read_bytes())

    def assertProblem(self, why):
        probs = sdk_pth.problems(self.site, self.agent)
        self.assertTrue(probs, f"{why} must be a problem")

    def test_exactly_the_committed_file_is_clean(self):
        self.install_exact()
        self.assertEqual(sdk_pth.problems(self.site, self.agent), [])

    def test_a_missing_pth_is_a_problem(self):
        self.assertProblem("no .pth")

    def test_a_stray_pth_is_a_problem(self):
        self.install_exact()
        for stray in ("evil.pth", ".hidden.pth", "distutils-precedence.pth"):
            with self.subTest(stray=stray):
                p = self.site / stray
                p.write_text("../../../../../../site-packages\n")
                self.assertProblem(f"a stray {stray}")
                p.unlink()

    def test_every_non_path_or_escaping_line_is_a_problem(self):
        bad = {
            "an import line": "import os; os.system('true')\n",
            "an import line with a tab": "import\tos\n",
            "a second line": "../../../../../../site-packages\n../../../../../../site-packages\n",
            "an absolute path": f"{self.agent / 'site-packages'}\n",
            "a home path": "~/site-packages\n",
            "a comment": "# ../../../../../../site-packages\n",
            "no newline": "../../../../../../site-packages",
            "a CR": "../../../../../../site-packages\r\n",
            "a NUL": "../../../../../../site\0-packages\n",
            "leaving the bundle": "../../../../../../../site-packages\n",
            "another dir in the bundle": "../../../../../../zb_agent_host\n",
            "empty": "",
        }
        for label, text in bad.items():
            with self.subTest(line=label):
                (self.site / NAME).write_text(text)
                self.assertProblem(label)

    def test_a_fifo_target_is_a_problem_and_never_opened(self):
        os.mkfifo(self.site / NAME)
        done = []
        t = threading.Thread(target=lambda: done.append(sdk_pth.problems(self.site, self.agent)), daemon=True)
        t.start()
        t.join(5)
        opened = not done
        if opened:  # it blocked opening the FIFO: unblock it so the thread ends, then fail
            fd = os.open(self.site / NAME, os.O_WRONLY | os.O_NONBLOCK)
            os.close(fd)
            t.join(10)
        self.assertFalse(opened, "problems() opened the FIFO (it blocked)")
        self.assertTrue(done[0], "a FIFO must be a problem")

    def test_a_hidden_flagged_pth_is_a_problem(self):
        """site skips a .pth flagged UF_HIDDEN on macOS; Linux cannot set the flag, so lstat reports it."""
        self.install_exact()
        real = os.lstat

        def flagged(path, *a, **kw):
            st = real(path, *a, **kw)
            if os.path.basename(path) == NAME:
                return types.SimpleNamespace(st_mode=st.st_mode, st_flags=stat.UF_HIDDEN)
            return st

        with mock.patch.object(sdk_pth.os, "lstat", side_effect=flagged):
            self.assertProblem("a UF_HIDDEN-flagged .pth")
        self.assertEqual(sdk_pth.problems(self.site, self.agent), [], "the same file unflagged is clean")

    def test_a_symlinked_pth_is_a_problem(self):
        real = self.tmp / "elsewhere.pth"
        real.write_bytes(COMMITTED.read_bytes())
        (self.site / NAME).symlink_to(real)
        self.assertProblem("a symlinked .pth")


class Install(Base):
    def test_it_writes_exactly_the_committed_bytes(self):
        sdk_pth.install(self.site, self.agent)
        self.assertEqual((self.site / NAME).read_bytes(), COMMITTED.read_bytes())
        self.assertEqual(sorted(p.name for p in self.site.iterdir()), [NAME])

    def test_a_stray_pth_already_there_is_refused_and_nothing_is_written(self):
        (self.site / "evil.pth").write_text("import os\n")
        with self.assertRaises(sdk_pth.Refused):
            sdk_pth.install(self.site, self.agent)
        self.assertFalse((self.site / NAME).exists())

    def test_an_existing_target_is_refused(self):
        (self.site / NAME).write_text("../../../../../../site-packages\n")
        with self.assertRaises(sdk_pth.Refused):
            sdk_pth.install(self.site, self.agent)


class IsolatedInterpreter(Base):
    """A real CPython: a venv at <agent-host>/Python.framework/Versions/3.12 has its prefix site-packages at the same
    depth as the framework's (lib/pythonX.Y/site-packages), so the committed line means the same there."""

    def test_python_dash_I_processes_the_pth_and_imports_the_staged_sdk(self):
        ver = self.agent / "Python.framework" / "Versions" / "3.12"
        shutil.rmtree(ver)
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(ver)], check=True, timeout=120)
        py = ver / "bin" / "python3"
        site = Path(subprocess.run([str(py), "-I", "-c", "import site; print(site.getsitepackages()[0])"],
                                   capture_output=True, text=True, check=True, timeout=60).stdout.strip())
        self.assertEqual(site.relative_to(ver).parts[0], "lib")
        sdk = self.agent / "site-packages" / "claude_agent_sdk"
        sdk.mkdir(parents=True)
        (sdk / "__init__.py").write_text("STAGED = True\n")
        sdk_pth.install(site, self.agent)
        probe = "import sys, claude_agent_sdk; print(sys.flags.no_site, claude_agent_sdk.__file__)"
        for root in (self.tmp, self.tmp.parent / (self.tmp.name + "-moved")):
            with self.subTest(tree=root.name):
                if root != self.tmp:
                    self.addCleanup(shutil.rmtree, root, True)
                    shutil.move(str(self.tmp), str(root))
                agent = root / "Frameworks" / "agent-host"
                out = subprocess.run([str(agent / "Python.framework/Versions/3.12/bin/python3"), "-I", "-c", probe],
                                     capture_output=True, text=True, timeout=60, env={"PATH": "/usr/bin:/bin"})
                self.assertEqual(out.returncode, 0, out.stderr)
                no_site, path = out.stdout.split()
                self.assertEqual(no_site, "0", "-I must keep site processing")
                self.assertEqual(Path(path).resolve(),
                                 (agent / "site-packages/claude_agent_sdk/__init__.py").resolve())


class StagingOrder(unittest.TestCase):
    def test_staging_installs_the_pth_before_the_relocations_signing(self):
        """relocate_python_framework.py signs the framework version last (RoseCat 7339): a .pth written after it is
        outside the seal. The Mac half (tests/mac/ms5_stage_gate.sh) verifies the seal and a post-sign write."""
        sh = (REPO / "packaging" / "macos" / "stage_agent_runtime.sh").read_text()
        install = sh.find('"$REPO/packaging/macos/sdk_pth.py" install')
        relocate = sh.find('"$REPO/packaging/macos/relocate_python_framework.py"')
        self.assertGreater(install, 0, "staging never installs the .pth")
        self.assertGreater(relocate, install, "the .pth must be installed before the relocation signs")


class Inventory(unittest.TestCase):
    def test_the_ms5_inventory_declares_the_pth(self):
        res = ms5_inventory.generate(REPO)["resources"]
        self.assertIn({"role": "sdk-path", "path": f"Frameworks/agent-host/{FRAMEWORK_SITE}/{NAME}"}, res)


if __name__ == "__main__":
    unittest.main()
