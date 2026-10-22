"""zb-hook-run on Darwin (design mail 7929, an MS8 prerequisite; a gated scaffold, unreachable before seatbelt_ready).

zb-hook-run (agent/host/zb_agent_host/hook_run.py) only knows bwrap, so on a Mac every SAI hook would fail to start.
The contract under review:
- setup, Darwin only: stage() also writes runtime/hook.sb, exactly
  sandbox_macos.render_profile(egress=None, bridges=<net.json's ports>, is_hook=True), mode 0600; on Linux it writes
  no hook.sb (zb-hook-run is a stdlib-only lone file and cannot import sandbox_macos, as it cannot import sandbox);
- zb-hook-run, Darwin (hook_run.PLATFORM, a module value like setup.PLATFORM): the same hook-env.json allowlist (the
  REFUSED names never pass, even planted in its own environment) and the same closing of every descriptor >= 3,
  then os.execve("/usr/bin/sandbox-exec", ["/usr/bin/sandbox-exec", "-f", <runtime>/hook.sb, "-D",
  "SCRATCHPAD=<real path of home/scratchpad>", <hook command...>], <that env>): no relay, no seccomp memfd, no bwrap;
- it refuses (exit 2, nothing exec'd) when hook.sb is missing, is a symlink or is not a regular file, or when the
  scratchpad is missing, a symlink, or not a directory;
- Linux is unchanged: the same platform value "linux" still execs bwrap (a control).
The script runs from a copy at <home>/runtime/bin/zb-hook-run (it finds its runtime from its own path); os.execve is a
recorder that stops the run, os.closerange a recorder (no real descriptor is closed), and os.kill / os.killpg raise.
Nothing is executed and no signal is sent. Setup rows run the real provision (route off) in-process.
Run: cd agent/host/tests && unshare --map-current-user --pid --fork --kill-child --mount-proc \\
  sh -c '"$ZB_AGENT_HOST_PYTHON" -X dev -m unittest -v test_hook_run_darwin; exit $?'
Unregistered until the green."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import sandbox_macos, setup
from test_provision import Sandbox

HOOK_RUN = Path(setup.__file__).resolve().parent / "hook_run.py"
ALLOWED = ["PATH", "HOME", "TMPDIR", "LANG"]
PLANTED = {"CLAUDE_CODE_OAUTH_TOKEN": "zb-planted-token", "ANTHROPIC_API_KEY": "zb-planted-key",
           "HTTPS_PROXY": "http://127.0.0.1:3128", "ZB_TOKEN_FIFO": "/tmp/fifo"}


class Exec(Exception):
    """os.execve as a recorder: the run stops where the exec would replace it."""


class HookRunDarwin(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="zb-hookrun-darwin-")))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "agent-home"
        self.runtime = self.home / "runtime"
        (self.runtime / "bin").mkdir(parents=True)
        (self.home / "scratchpad").mkdir(mode=0o700)
        (self.home / "workspace").mkdir()
        (self.runtime / "hook-env.json").write_text(json.dumps(ALLOWED))
        net = {"bridges_dir": "/run/zb-net/bridges", "ports": [51091, 31337]}
        (self.runtime / "net.json").write_text(json.dumps(net))
        self.profile = self.runtime / "hook.sb"
        self.profile.write_text("(version 1)\n(deny default)\n")
        os.chmod(self.profile, 0o600)
        script = self.runtime / "bin" / "zb-hook-run"
        shutil.copyfile(HOOK_RUN, script)
        loader = importlib.machinery.SourceFileLoader("zb_hook_run_darwin_copy", str(script))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        self.calls = []

    def run_main(self, platform, command=("bun", "/srv/hook.ts")):
        def execve(path, argv, env):
            self.calls.append(("execve", path, list(argv), dict(env)))
            raise Exec()

        def closerange(lo, hi):
            self.calls.append(("closerange", lo))
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "TMPDIR": "/tmp/x", "LANG": "C.UTF-8",
               "OTHER": "dropped", **PLANTED}
        with mock.patch.object(self.mod, "PLATFORM", platform, create=True), \
                mock.patch.object(self.mod.os, "execve", side_effect=execve), \
                mock.patch.object(self.mod.os, "closerange", side_effect=closerange), \
                mock.patch.dict(os.environ, env, clear=True):
            if platform == "darwin":
                stack = mock.patch.object(self.mod, "filter_fd",
                                          side_effect=AssertionError("a seccomp memfd on Darwin"))
            else:
                stack = mock.patch.object(self.mod, "filter_fd", return_value=99)
            with stack:
                try:
                    return self.mod.main(["--", *command])
                except Exec:
                    return "exec"

    def test_darwin_execs_sandbox_exec_with_the_hook_profile_and_the_allowlisted_env(self):
        self.assertEqual(self.run_main("darwin"), "exec")
        execs = [c for c in self.calls if c[0] == "execve"]
        self.assertEqual(len(execs), 1, self.calls)
        _, path, argv, env = execs[0]
        scratchpad = os.path.realpath(self.home / "scratchpad")
        self.assertEqual((path, argv), ("/usr/bin/sandbox-exec",
                                        ["/usr/bin/sandbox-exec", "-f", str(self.profile), "-D",
                                         f"SCRATCHPAD={scratchpad}", "bun", "/srv/hook.ts"]))
        self.assertEqual(sorted(env), sorted(ALLOWED))
        self.assertFalse(set(env) & set(PLANTED), "a refused name reached the hook")

    def test_every_descriptor_is_closed_before_the_exec(self):
        self.run_main("darwin")
        kinds = [c[0] for c in self.calls]
        self.assertIn("closerange", kinds)
        self.assertIn("execve", kinds)
        self.assertLess(kinds.index("closerange"), kinds.index("execve"))
        self.assertEqual([c[1] for c in self.calls if c[0] == "closerange"], [3])

    def test_a_bad_hook_profile_or_scratchpad_refuses_without_exec(self):
        cases = {
            "hook.sb missing": lambda: self.profile.unlink(),
            "hook.sb a symlink": lambda: (self.profile.rename(self.runtime / "real.sb"),
                                          self.profile.symlink_to(self.runtime / "real.sb")),
            "hook.sb a directory": lambda: (self.profile.unlink(), self.profile.mkdir()),
            "scratchpad missing": lambda: (self.home / "scratchpad").rmdir(),
            "scratchpad a symlink": lambda: ((self.home / "scratchpad").rmdir(), (self.tmp / "else").mkdir(),
                                             (self.home / "scratchpad").symlink_to(self.tmp / "else")),
        }
        for name, spoil in cases.items():
            with self.subTest(case=name):
                self.setUp()
                spoil()
                self.assertEqual(self.run_main("darwin"), 2)
                self.assertEqual([c for c in self.calls if c[0] == "execve"], [], f"{name}: something was exec'd")

    def test_linux_still_execs_bwrap(self):
        self.assertEqual(self.run_main("linux"), "exec")
        execs = [c for c in self.calls if c[0] == "execve"]
        self.assertEqual([c[1] for c in execs], [self.mod.BWRAP])


class SetupHookProfile(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)

    def provision(self, platform):
        box = Sandbox(self)
        with mock.patch.object(setup, "PLATFORM", platform):
            box.provision()
        return box.home.root / "runtime"

    def test_darwin_setup_writes_the_hook_profile_for_the_backends_bridges(self):
        runtime = self.provision("darwin")
        ports = tuple(json.loads((runtime / "net.json").read_text())["ports"])
        profile = runtime / "hook.sb"
        self.assertTrue(profile.is_file() and not profile.is_symlink(), "no runtime/hook.sb on Darwin")
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o600)
        self.assertEqual(profile.read_text(), sandbox_macos.render_profile(egress=None, bridges=ports, is_hook=True))

    def test_linux_setup_writes_no_hook_profile(self):
        runtime = self.provision("linux")
        self.assertFalse(os.path.lexists(runtime / "hook.sb"))


if __name__ == "__main__":
    unittest.main()
