"""launch.py's `--egress-port` (BlackRobin 7035/7108, seam 2): Darwin-required / off-Darwin-refused, parsed onto
a frozen `Session(home, python, net_dir, command, egress_port)` carrier. Mirrors setup's `--browser-pid`. On
Darwin, after a good parse, `main` still refuses ("the macOS launch is not ready") until the lease/dispatch
slice (7027/7035) — nothing reaches MacSeatbeltBackend here. Linux is byte-identical (egress_port None).

Linux on this host; PLATFORM is injected via `launch.PLATFORM`. `os.execve` is mocked so main's Linux path
never replaces the test process. Run: cd agent/host/tests && python -m unittest -v test_launch. Unregistered
until the green.
"""
import io
import types
import unittest
from contextlib import redirect_stderr
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import launch

BASE = ["--home", "/tmp/zb-h", "--python", "/usr/bin/python3", "--net-dir", "/tmp/zb-net"]


def _args(**kw):
    ns = types.SimpleNamespace(home="/tmp/zb-h", python="/usr/bin/python3", net_dir="/tmp/zb-net",
                               command="chat", egress_port=None, bwrap="/usr/bin/bwrap", test_ca=None,
                               e2e_claude_cli=None)
    for k, v in kw.items():
        setattr(ns, k, v)
    return ns


class EgressPortParse(unittest.TestCase):
    def test_linux_refuses_the_flag(self):
        with mock.patch.object(launch, "PLATFORM", "linux"):
            with self.assertRaises(launch.UsageError):
                launch.build_session(_args(egress_port=["3128"]))

    def test_linux_none_is_a_session_with_no_port(self):
        with mock.patch.object(launch, "PLATFORM", "linux"):
            s = launch.build_session(_args(egress_port=None))
        # the exact five dataclass fields (RoseCat 820a978 SHOULD)
        self.assertEqual((s.home, s.python, s.net_dir, s.command, s.egress_port),
                         ("/tmp/zb-h", "/usr/bin/python3", "/tmp/zb-net", "chat", None))

    def test_darwin_parse_table(self):
        with mock.patch.object(launch, "PLATFORM", "darwin"):
            for bad in (None, ["0"], ["65536"], ["0123"], ["12a"], ["3128", "3128"], [""], [" 3128"]):
                with self.subTest(bad=bad), self.assertRaises(launch.UsageError):
                    launch.build_session(_args(egress_port=bad))
            s = launch.build_session(_args(egress_port=["3128"]))
        self.assertEqual(s.egress_port, 3128)

    def test_darwin_accepts_the_range_bounds(self):
        with mock.patch.object(launch, "PLATFORM", "darwin"):
            self.assertEqual(launch.build_session(_args(egress_port=["1"])).egress_port, 1)
            self.assertEqual(launch.build_session(_args(egress_port=["65535"])).egress_port, 65535)

    def test_session_is_frozen(self):
        with mock.patch.object(launch, "PLATFORM", "linux"):
            s = launch.build_session(_args())
        with self.assertRaises(Exception):
            s.egress_port = 1  # frozen dataclass


class DarwinRefusesLaunch(unittest.TestCase):
    """On a real Mac there is NO bwrap, so the Darwin fail-closed branch MUST be reached BEFORE os.access(bwrap)
    (RoseCat 820a978): a valid --egress-port must give EXIT_USAGE 'not ready', never EXIT_NO_SANDBOX(3). Each
    case forces bwrap absent (os.access -> False) AND asserts bwrap is never consulted on the Darwin path, so
    the ordering bug in 8fd0398 (bwrap checked first -> exit 3) reds here."""

    def _run_darwin(self, argv):
        access = mock.MagicMock(return_value=False)  # bwrap absent, and records any probe
        with mock.patch.object(launch, "PLATFORM", "darwin"), \
                mock.patch.object(launch.os, "access", access), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(argv)
        return rc, err.getvalue(), ex, access

    def test_darwin_refuses_linux_net_dir_before_bwrap(self):
        rc, err, ex, access = self._run_darwin(BASE + ["--egress-port", "3128"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        self.assertNotEqual(rc, launch.EXIT_NO_SANDBOX)  # NOT the bwrap refusal
        self.assertIn("--net-dir is the Linux launch's only", err)
        ex.assert_not_called()
        access.assert_not_called()  # bwrap must never be consulted on the Darwin path

    def test_darwin_invalid_port_is_usage_before_bwrap(self):
        for bad in ("0", "65536", "0123", "12a"):
            with self.subTest(bad=bad):
                rc, _err, ex, access = self._run_darwin(BASE + ["--egress-port", bad])
                self.assertEqual(rc, launch.EXIT_USAGE)
                ex.assert_not_called()
                access.assert_not_called()

    def test_darwin_missing_port_is_usage_before_bwrap(self):
        rc, _err, ex, access = self._run_darwin(BASE)  # no --egress-port
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        access.assert_not_called()

    def test_darwin_duplicate_port_is_usage_before_bwrap(self):
        rc, _err, ex, access = self._run_darwin(BASE + ["--egress-port", "3128", "--egress-port", "3129"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        access.assert_not_called()

    def test_linux_refuses_the_flag_through_main(self):
        with mock.patch.object(launch, "PLATFORM", "linux"), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(BASE + ["--egress-port", "3128"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        self.assertIn("macOS-only", err.getvalue())

    def test_linux_refuses_the_unsandboxed_dev_flag(self):
        with mock.patch.object(launch, "PLATFORM", "linux"), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(BASE + ["--unsandboxed-dev"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        self.assertIn("--unsandboxed-dev is macOS-only", err.getvalue())


if __name__ == "__main__":
    unittest.main()
