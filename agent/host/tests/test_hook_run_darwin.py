"""zb-hook-run on Darwin (design mail 7929, an MS8 prerequisite; a gated scaffold, unreachable before seatbelt_ready).

zb-hook-run (agent/host/zb_agent_host/hook_run.py) only knows bwrap, so on a Mac every SAI hook would fail to start.
The contract under review:
- setup, Darwin only: stage() also writes runtime/hook.sb, exactly
  sandbox_macos.render_profile(egress=None, bridges=<net.json's ports>, is_hook=True), mode 0600; on Linux it writes
  no hook.sb (zb-hook-run is a stdlib-only lone file and cannot import sandbox_macos, as it cannot import sandbox);
- zb-hook-run, Darwin (hook_run.PLATFORM, a module value like setup.PLATFORM): the same hook-env.json allowlist (the
  exact allowlisted values pass; the REFUSED names never do, even planted in its own environment), then
  os.execve("/usr/bin/sandbox-exec", ["/usr/bin/sandbox-exec", "-f", <runtime>/hook.sb, "-D",
  "SCRATCHPAD=<home/scratchpad>", <hook command...>], <that env>): no relay, no seccomp memfd, no bwrap;
- descriptors, close-except the run marker (MS6.5.1; RoseCat 7938 #1, #2): with no ZB_AGENT_RUN_MARKER_FD it closes
  exactly [3, SC_OPEN_MAX); with ZB_AGENT_RUN_MARKER_FD equal to the reserved number RUN_MARKER_FD (5: not the
  token's 3, the egress 4, nor the >= 10 memfd range) naming an open regular file, it closes exactly [3, 5) and
  [6, SC_OPEN_MAX), so the marker survives into the hook and a planted unrelated descriptor does not; a malformed,
  colliding or other number, a closed descriptor or a non-regular one refuses (exit 2) before any close or exec;
- hook.sb (RoseCat 7938 #3) must be a regular file (lstat) owned by the effective uid and writable by neither group
  nor others; missing, a symlink, a directory, another owner, mode 0620 or 0602 refuse before any close or exec;
- the scratchpad follows sandbox_macos.dparams (RoseCat 7938 #4): an existing directory that is its own canonical
  real path; missing, a regular file, a symlink, or reached through a symlinked parent component refuses before any
  close or exec;
- Linux is unchanged: the same platform value "linux" still execs bwrap (a control).
Mutants for the green (each must red a row): the marker dropped, closerange(3, 4), the owner check, the mode check,
the parent-symlink check, the env allowlist skipped.
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
MARKER_FD = 5  # the reserved ZB_AGENT_RUN_MARKER_FD number (MS6.5.1: distinct from 3, 4 and the >= 10 range)
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
        shutil.copyfile(HOOK_RUN, self.runtime / "bin" / "zb-hook-run")
        self.load(self.runtime / "bin" / "zb-hook-run")
        self.calls = []

    def load(self, script):
        loader = importlib.machinery.SourceFileLoader("zb_hook_run_darwin_copy", str(script))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)

    def hold_marker(self, fd=MARKER_FD, kind="file"):
        """A real marker on descriptor `fd` (a 0400 regular file, or a pipe end for kind="pipe") for this test only;
        whatever the test process had there is restored afterwards."""
        saved = None
        try:
            saved = os.dup(fd)
        except OSError:
            pass
        if kind == "pipe":
            r, w = os.pipe()
            os.dup2(r, fd)
            os.close(r)
            os.close(w)
        else:
            marker = self.tmp / "run.marker"
            marker.write_bytes(b"")
            os.chmod(marker, 0o400)
            src = os.open(marker, os.O_RDONLY)
            os.dup2(src, fd)
            os.close(src)

        def restore():
            if saved is None:
                os.close(fd)
            else:
                os.dup2(saved, fd)
                os.close(saved)
        self.addCleanup(restore)

    def run_main(self, platform, command=("bun", "/srv/hook.ts")):
        def execve(path, argv, env):
            self.calls.append(("execve", path, list(argv), dict(env)))
            raise Exec()

        def closerange(lo, hi):
            self.calls.append(("closerange", lo, hi))
        env = {**self.allowed_env(), "OTHER": "dropped", **PLANTED, **getattr(self, "extra_env", {})}
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

    def allowed_env(self):
        return {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "TMPDIR": "/tmp/x", "LANG": "C.UTF-8"}

    def ranges(self):
        return [(c[1], c[2]) for c in self.calls if c[0] == "closerange"]

    def refused_untouched(self, why):
        self.assertEqual(self.run_main("darwin"), 2, f"{why}: not refused")
        self.assertEqual(self.calls, [], f"{why}: something was closed or exec'd before the refusal")

    def test_darwin_execs_sandbox_exec_with_the_hook_profile_and_the_allowlisted_env(self):
        self.assertEqual(self.run_main("darwin"), "exec")
        execs = [c for c in self.calls if c[0] == "execve"]
        self.assertEqual(len(execs), 1, self.calls)
        _, path, argv, env = execs[0]
        scratchpad = os.path.realpath(self.home / "scratchpad")
        self.assertEqual((path, argv), ("/usr/bin/sandbox-exec",
                                        ["/usr/bin/sandbox-exec", "-f", str(self.profile), "-D",
                                         f"SCRATCHPAD={scratchpad}", "bun", "/srv/hook.ts"]))
        self.assertEqual(env, self.allowed_env(), "the hook's environment is not exactly the allowlisted values")

    def test_without_a_marker_every_descriptor_from_3_up_is_closed_before_the_exec(self):
        self.run_main("darwin")
        kinds = [c[0] for c in self.calls]
        self.assertEqual(self.ranges(), [(3, os.sysconf("SC_OPEN_MAX"))])
        self.assertLess(kinds.index("closerange"), kinds.index("execve"))

    def test_the_run_marker_alone_survives_the_close(self):
        self.hold_marker()
        planted = os.open(os.devnull, os.O_RDONLY)  # an unrelated descriptor the hook must not get
        self.addCleanup(os.close, planted)
        self.extra_env = {"ZB_AGENT_RUN_MARKER_FD": str(MARKER_FD)}
        self.assertEqual(self.run_main("darwin"), "exec")
        top = os.sysconf("SC_OPEN_MAX")
        self.assertEqual(self.ranges(), [(3, MARKER_FD), (MARKER_FD + 1, top)])
        covered = lambda fd: any(lo <= fd < hi for lo, hi in self.ranges())  # noqa: E731
        self.assertFalse(covered(MARKER_FD), "the marker was closed")
        self.assertTrue(covered(planted), "an unrelated descriptor reaches the hook")
        execs = [c for c in self.calls if c[0] == "execve"]
        self.assertNotIn("ZB_AGENT_RUN_MARKER_FD", execs[0][3], "the marker's metadata is not an allowlisted name")

    def test_bad_marker_metadata_refuses_before_any_close(self):
        cases = {"empty": "", "word": "five", "suffix": "5x", "negative": "-5", "huge": "99999999999999999999",
                 "stdin": "0", "token fd": "3", "egress fd": "4", "memfd range": "10", "another number": "6"}
        self.hold_marker()
        for name, value in cases.items():
            with self.subTest(marker=name):
                self.calls = []
                self.extra_env = {"ZB_AGENT_RUN_MARKER_FD": value}
                self.refused_untouched(f"ZB_AGENT_RUN_MARKER_FD={value!r}")

    def test_a_closed_or_non_regular_marker_refuses_before_any_close(self):
        self.extra_env = {"ZB_AGENT_RUN_MARKER_FD": str(MARKER_FD)}
        saved = None
        try:
            saved = os.dup(MARKER_FD)
            os.close(MARKER_FD)
        except OSError:
            pass
        try:
            self.refused_untouched("a closed marker descriptor")
        finally:
            if saved is not None:
                os.dup2(saved, MARKER_FD)
                os.close(saved)
        self.calls = []
        self.hold_marker(kind="pipe")
        self.refused_untouched("a marker descriptor that is a pipe")

    def test_a_bad_hook_profile_refuses_before_any_close(self):
        cases = {
            "hook.sb missing": lambda: self.profile.unlink(),
            "hook.sb a symlink": lambda: (self.profile.rename(self.runtime / "real.sb"),
                                          self.profile.symlink_to(self.runtime / "real.sb")),
            "hook.sb a directory": lambda: (self.profile.unlink(), self.profile.mkdir()),
            "hook.sb group-writable": lambda: os.chmod(self.profile, 0o620),
            "hook.sb other-writable": lambda: os.chmod(self.profile, 0o602),
        }
        for name, spoil in cases.items():
            with self.subTest(case=name):
                self.setUp()
                spoil()
                self.refused_untouched(name)
        with self.subTest(case="hook.sb another uid's"):
            self.setUp()
            with mock.patch.object(os, "geteuid", return_value=os.geteuid() + 1):
                self.refused_untouched("hook.sb owned by another uid")

    def test_a_bad_scratchpad_refuses_before_any_close(self):
        cases = {
            "scratchpad missing": lambda: (self.home / "scratchpad").rmdir(),
            "scratchpad a regular file": lambda: ((self.home / "scratchpad").rmdir(),
                                                  (self.home / "scratchpad").write_text("")),
            "scratchpad a symlink": lambda: ((self.home / "scratchpad").rmdir(), (self.tmp / "else").mkdir(),
                                             (self.home / "scratchpad").symlink_to(self.tmp / "else")),
        }
        for name, spoil in cases.items():
            with self.subTest(case=name):
                self.setUp()
                spoil()
                self.refused_untouched(name)
        with self.subTest(case="home reached through a symlinked parent component"):
            self.setUp()
            link = self.tmp / "via"
            link.symlink_to(self.tmp)
            self.load(link / "agent-home" / "runtime" / "bin" / "zb-hook-run")
            self.refused_untouched("a scratchpad path through a symlinked parent")

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
