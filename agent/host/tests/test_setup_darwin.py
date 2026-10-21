"""macOS plan rev 14 items 5-6, setup.py's Darwin branches (BlackRobin 6925's four conditions), on Linux with the
platform injected (`setup.PLATFORM`):

- `--browser-pid` fails closed. On Linux it is refused, and nothing runs. On Darwin a missing value, a
  non-integer, a value <= 1, or a pid that is not our parent is a SetupError before anything runs; otherwise
  `parent_watch.arm(pid, DarwinOps())` runs FIRST, before provisioning, and a watch that does not arm stops setup
  with nothing provisioned.
- Setup's own sandbox on Darwin is `sandbox_macos.setup_argv(scratch, ro_paths, command)` (JadeBeacon's MS6). Until
  it exists, setup raises SetupError("the macOS sandbox is not ready") and no child is spawned: never unsandboxed.
- Linux is unchanged: no --browser-pid, provisioning runs as before; the Linux setup_sandbox argv is the same.

Run like the gate: cd agent/host/tests && python -m unittest -v test_setup_darwin. Unregistered until the green.
"""
import contextlib
import io
import os
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import parent_watch, sandbox_macos, setup

BASE = ["--home", "/tmp/zb-h", "--sai-source", "/tmp/zb-s", "--source-home", "/tmp/zb-u",
        "--source-path", "/usr/bin", "--python", "/usr/bin/python3"]


class Main(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(setup, "provision", side_effect=lambda *a, **k: self.calls.append("provision")).start()

    def run_main(self, platform, extra=(), arm=None):
        if not hasattr(setup, "PLATFORM"):
            self.fail("setup.PLATFORM (the injected platform) is missing (rev 14 item 5)")
        mock.patch.object(setup, "PLATFORM", platform).start()
        if arm is not None:
            mock.patch.object(parent_watch, "arm", side_effect=arm).start()
            mock.patch.object(parent_watch, "DarwinOps", lambda: "ops").start()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = setup.main(BASE + list(extra))
        return code, err.getvalue()

    def test_linux_without_browser_pid_provisions_as_before(self):
        code, _ = self.run_main("linux")
        self.assertEqual((code, self.calls), (0, ["provision"]))

    def test_linux_refuses_browser_pid_and_runs_nothing(self):
        code, err = self.run_main("linux", ["--browser-pid", str(os.getppid())])
        self.assertEqual(code, 2)
        self.assertIn("--browser-pid", err)
        self.assertEqual(self.calls, [])

    def test_darwin_bad_browser_pids_are_refused_before_anything_runs(self):
        for extra in ([], ["--browser-pid", "abc"], ["--browser-pid", "1"], ["--browser-pid", "0"],
                      ["--browser-pid", "-5"], ["--browser-pid", str(os.getppid() + 100000)]):
            with self.subTest(extra=extra):
                self.calls.clear()
                armed = []
                code, err = self.run_main("darwin", extra, arm=lambda pid, ops: armed.append(pid) or True)
                self.assertEqual(code, 2, err)
                self.assertIn("--browser-pid", err)
                self.assertEqual((self.calls, armed), ([], []), "nothing runs, not even the watch")

    def test_darwin_arms_the_parent_watch_first(self):
        order = []
        self.calls = order
        code, err = self.run_main("darwin", ["--browser-pid", str(os.getppid())],
                                  arm=lambda pid, ops: order.append(("arm", pid, ops)) or True)
        self.assertEqual(code, 0, err)
        self.assertEqual(order, [("arm", os.getppid(), "ops"), "provision"])

    def test_darwin_a_watch_that_does_not_arm_stops_setup(self):
        code, err = self.run_main("darwin", ["--browser-pid", str(os.getppid())], arm=lambda pid, ops: False)
        self.assertEqual(code, 2, err)
        self.assertEqual(self.calls, [], "nothing provisioned after a failed arm")


class SetupSandbox(unittest.TestCase):
    def setUp(self):
        if not hasattr(setup, "PLATFORM"):
            self.fail("setup.PLATFORM (the injected platform) is missing (rev 14 item 6)")
        self.addCleanup(mock.patch.stopall)
        self.spawned = []
        mock.patch.object(setup.subprocess, "run", side_effect=lambda *a, **k: self.spawned.append(a)).start()

    def test_darwin_without_the_seatbelt_seam_refuses_and_spawns_nothing(self):
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        if hasattr(sandbox_macos, "setup_argv"):
            mock.patch.object(sandbox_macos, "setup_argv", None).start()
        with self.assertRaises(setup.SetupError) as cm:
            setup.cli_version("/opt/claude")
        self.assertEqual(str(cm.exception), "the macOS sandbox is not ready")
        self.assertEqual(self.spawned, [], "never unsandboxed: no child at all")

    def test_darwin_uses_sandbox_macos_setup_argv_when_it_exists(self):
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        mock.patch.object(sandbox_macos, "setup_argv", lambda scratch, ro, cmd: ["sandbox-exec", str(scratch), *cmd],
                          create=True).start()
        argv = setup.setup_sandbox("/tmp/scr", ["/ro"], ["/opt/claude", "--version"])
        self.assertEqual(argv, ["sandbox-exec", "/tmp/scr", "/opt/claude", "--version"])

    def test_linux_setup_sandbox_argv_is_unchanged(self):
        mock.patch.object(setup, "PLATFORM", "linux").start()
        argv = setup.setup_sandbox("/tmp/scr", ["/ro"], ["/opt/claude", "--version"])
        self.assertEqual(argv[:4], [setup.sandbox.BWRAP, "--unshare-net", "--unshare-pid", "--unshare-ipc"])
        self.assertEqual(argv[-5:], ["--chdir", "/tmp/scr", "--", "/opt/claude", "--version"])


if __name__ == "__main__":
    unittest.main()
