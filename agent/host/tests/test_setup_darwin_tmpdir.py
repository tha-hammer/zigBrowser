"""Setup's sandboxed runs have a usable temporary directory under Seatbelt (4c0a3db, both Macs: the probe got past its
listener, then died in route_probe.run's tempfile.mkdtemp: "No usable temporary directory found in ['/tmp',
'/var/tmp', '/usr/tmp', ...]"; the setup profile lets the run write only its SCRATCHPAD, and _sandboxed passed no
TMPDIR).

On Linux with the platform injected and the MS6 seam faked (as test_setup_darwin_r1):
- on Darwin, the R1 probe's run and cli_version's run each get TMPDIR = the scratch the seam was given (the profile's
  one writable SCRATCHPAD), an existing directory while the run runs, and HOME stays that same scratch;
- the scratch is its REAL path (e7b7370, both Macs: TMPDIR=/tmp/zb-setup-run-… was still unusable: /tmp is a symlink
  to /private/tmp, Seatbelt matches resolved paths, and sandbox_macos.dparams only normalizes, so the profile's one
  write grant named a path no write ever resolves to): with tempfile's directory behind a symlink, the seam's scratch,
  HOME and TMPDIR are all os.path.realpath of it;
- Linux runs are unchanged (no TMPDIR from setup; bwrap gives them their own /tmp).

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_setup_darwin_tmpdir.
Unregistered until the green.
"""
import os
import shutil
import tempfile
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_setup_darwin_r1 as r1

from zb_agent_host import setup


class Envs(r1.Base):
    def record_envs(self):
        envs = []
        real = setup.subprocess.run

        def run(argv, **kwargs):
            env = dict(kwargs.get("env") or {})
            env["_tmpdir_exists"] = os.path.isdir(env.get("TMPDIR", "/nonexistent-zb"))
            envs.append(env)
            return real(argv, **kwargs)

        mock.patch.object(setup.subprocess, "run", side_effect=run).start()
        return envs


class Darwin(Envs):
    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "darwin").start()

    def test_the_probe_runs_with_tmpdir_in_its_writable_scratch(self):
        self.fake_seam()
        self.fake_run()
        envs = self.record_envs()
        made = self.track_sockets()
        self.assertIs(setup.probe_r1(r1.WRAPPER, r1.CLI), True)
        (seam,), (env,) = self.seam, envs
        self.assertEqual(env.get("TMPDIR"), str(seam["scratch"]), "TMPDIR is the profile's writable SCRATCHPAD")
        self.assertTrue(env["_tmpdir_exists"], "the directory exists while the probe runs")
        self.assertEqual(env.get("HOME"), str(seam["scratch"]))
        self.assert_all_closed(made)

    def test_the_scratch_is_its_real_path_behind_a_symlinked_tmp(self):
        root = tempfile.mkdtemp(prefix="zb-tmpdir-real-")
        self.addCleanup(shutil.rmtree, root, True)
        real = os.path.join(root, "private-tmp")
        os.mkdir(real)
        link = os.path.join(root, "tmp")
        os.symlink(real, link)  # as macOS's /tmp -> private/tmp
        mock.patch.object(tempfile, "tempdir", link).start()
        self.fake_seam()
        self.fake_run()
        envs = self.record_envs()
        made = self.track_sockets()
        self.assertIs(setup.probe_r1(r1.WRAPPER, r1.CLI), True)
        (seam,), (env,) = self.seam, envs
        scratch = str(seam["scratch"])
        self.assertTrue(scratch.startswith(real + os.sep), f"the seam gets the resolved scratch, not {scratch}")
        self.assertEqual(os.path.realpath(scratch), scratch)
        self.assertEqual((env.get("HOME"), env.get("TMPDIR")), (scratch, scratch))
        self.assert_all_closed(made)

    def test_cli_version_runs_with_tmpdir_in_its_writable_scratch(self):
        self.fake_seam()
        mock.patch.object(setup.subprocess, "run",
                          return_value=setup.subprocess.CompletedProcess([], 0, stdout="2.1.0 (Claude Code)\n",
                                                                         stderr="")).start()
        envs = self.record_envs()
        setup.cli_version(r1.CLI)
        (seam,), (env,) = self.seam, envs
        self.assertEqual(env.get("TMPDIR"), str(seam["scratch"]))
        self.assertTrue(env["_tmpdir_exists"])


class Linux(Envs):
    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "linux").start()

    def test_linux_runs_get_no_tmpdir_from_setup(self):
        mock.patch.object(setup.subprocess, "run",
                          return_value=setup.subprocess.CompletedProcess([], 0, stdout="2.1.0 (Claude Code)\n",
                                                                         stderr="")).start()
        envs = self.record_envs()
        setup.cli_version(r1.CLI)
        (env,) = envs
        self.assertNotIn("TMPDIR", env)


if __name__ == "__main__":
    unittest.main()
