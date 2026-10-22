"""macOS plan rev 14 items 5-6, setup.py's Darwin branches (BlackRobin 6925's four conditions), on Linux with the
platform injected (`setup.PLATFORM`):

- `--browser-pid` fails closed. On Linux it is refused, and nothing runs. On Darwin a missing value, a
  non-integer, a value <= 1, or a pid that is not our parent is a SetupError before anything runs; otherwise
  `parent_watch.arm(pid, DarwinOps())` runs FIRST, before provisioning, and a watch that does not arm stops setup
  with nothing provisioned.
- Setup's own sandbox on Darwin is the context manager `sandbox_macos.setup_sandbox(scratch, ro_paths, command)`
  (JadeBeacon's MS6, 45bbbff): `_sandboxed` runs the command inside it, and its per-run profile under scratch is
  gone afterwards. The REAL symbol is driven through setup's own code (pure stdlib, so on Linux). Until it exists,
  setup raises SetupError("the macOS sandbox is not ready") and no child is spawned: never unsandboxed. On Darwin
  `setup_sandbox` (the Linux bwrap argv builder) refuses rather than hand back a bwrap argv.
- Linux is unchanged: no --browser-pid, provisioning runs as before; the Linux setup_sandbox argv is the same.

Run like the gate: cd agent/host/tests && python -m unittest -v test_setup_darwin. Unregistered until the green.
"""
import contextlib
import io
import os
import unittest
from pathlib import Path
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

    def test_darwin_a_non_integer_browser_pid_is_a_value_error_not_a_traceback(self):
        # BlackRobin 6952/6956: "12abc" and "" each say "must be an integer" and exit 2.
        for raw in ("12abc", ""):
            with self.subTest(raw=raw):
                self.calls.clear()
                armed = []
                code, err = self.run_main("darwin", ["--browser-pid", raw],
                                          arm=lambda pid, ops: armed.append(pid) or True)
                self.assertEqual(code, 2, err)
                self.assertIn("--browser-pid must be an integer", err)
                self.assertNotIn("Traceback", err)
                self.assertEqual((self.calls, armed), ([], []))

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
        support.fake_setup_runs(setup, side_effect=lambda *a, **k: self.spawned.append(a)).start()

    def test_darwin_without_the_seatbelt_seam_refuses_and_spawns_nothing(self):
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        mock.patch.object(sandbox_macos, "setup_sandbox", None).start()
        with self.assertRaises(setup.SetupError) as cm:
            setup.cli_version("/opt/claude")
        self.assertEqual(str(cm.exception), "the macOS sandbox is not ready")
        self.assertEqual(self.spawned, [], "never unsandboxed: no child at all")

    def test_darwin_runs_through_the_real_sandbox_macos_setup_sandbox(self):
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        seen = {}

        def fake_run(argv, **kwargs):
            # At run time the real per-run profile exists under the scratch that is also HOME and SCRATCHPAD.
            scratch = kwargs["env"]["HOME"]
            seen.update(argv=list(argv), scratch=scratch, profile=argv[2],
                        profile_existed=os.path.isfile(argv[2]), profile_text=Path(argv[2]).read_text())
            return setup.subprocess.CompletedProcess(argv, 0, stdout="2.1.294 (Claude Code)\n", stderr="")

        support.fake_setup_runs(setup, side_effect=fake_run).start()
        self.assertEqual(setup.cli_version("/opt/claude"), "2.1.294")
        argv, scratch, profile = seen["argv"], seen["scratch"], seen["profile"]
        self.assertEqual(argv[:2], ["/usr/bin/sandbox-exec", "-f"])
        self.assertEqual(os.path.dirname(profile), scratch, "the profile lives under setup's own scratch")
        self.assertTrue(os.path.basename(profile).startswith(".zb-setup-sandbox-") and profile.endswith(".sb"))
        self.assertEqual(argv[3:], ["-D", f"SCRATCHPAD={scratch}", "/opt/claude", "--version"])
        self.assertTrue(seen["profile_existed"])
        self.assertNotIn("network-outbound", seen["profile_text"].replace("deny network-outbound", ""),
                         "setup's profile grants no network")
        self.assertFalse(os.path.exists(profile), "the per-run profile is gone afterwards")
        self.assertFalse(os.path.exists(scratch), "and so is the scratch")

    def test_darwin_a_timeout_deletes_the_profile_and_reports_failure(self):
        # BlackRobin 6956: TimeoutExpired inside the `with` leaves through the context manager's exit, so the
        # per-run profile and the scratch are gone and _sandboxed reports the failure ("", False).
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        seen = {}

        def fake_run(argv, **kwargs):
            seen.update(profile=argv[2], scratch=kwargs["env"]["HOME"], existed=os.path.isfile(argv[2]))
            raise setup.subprocess.TimeoutExpired(argv, kwargs["timeout"])

        support.fake_setup_runs(setup, side_effect=fake_run).start()
        self.assertEqual(setup._sandboxed(["/ro"], ["/opt/claude", "--version"], timeout=1), ("", False))
        self.assertTrue(seen["existed"], "the profile existed while the command ran")
        self.assertFalse(os.path.exists(seen["profile"]), "the timed-out run's profile is deleted")
        self.assertFalse(os.path.exists(seen["scratch"]), "and so is the scratch")
        self.assertEqual(setup.cli_version("/opt/claude"), "unknown", "a timed-out --version reports unknown")

    def test_darwin_setup_sandbox_refuses_to_build_the_linux_argv(self):
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        with self.assertRaises(setup.SetupError):
            setup.setup_sandbox("/tmp/scr", ["/ro"], ["/opt/claude", "--version"])

    def test_linux_setup_sandbox_argv_is_unchanged(self):
        mock.patch.object(setup, "PLATFORM", "linux").start()
        argv = setup.setup_sandbox("/tmp/scr", ["/ro"], ["/opt/claude", "--version"])
        self.assertEqual(argv[:4], [setup.sandbox.BWRAP, "--unshare-net", "--unshare-pid", "--unshare-ipc"])
        self.assertEqual(argv[-5:], ["--chdir", "/tmp/scr", "--", "/opt/claude", "--version"])


if __name__ == "__main__":
    unittest.main()
