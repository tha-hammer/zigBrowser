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
        self.assertIsNone(s.egress_port)
        self.assertEqual((s.home, s.python, s.net_dir, s.command),
                         ("/tmp/zb-h", "/usr/bin/python3", "/tmp/zb-net", "chat"))

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
    def test_darwin_refuses_after_a_good_parse(self):
        with mock.patch.object(launch, "PLATFORM", "darwin"), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(BASE + ["--egress-port", "3128"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        self.assertIn("macOS launch is not ready", err.getvalue())

    def test_darwin_bad_egress_port_refused_before_launch(self):
        with mock.patch.object(launch, "PLATFORM", "darwin"), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(BASE + ["--egress-port", "0"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()

    def test_linux_refuses_the_flag_through_main(self):
        with mock.patch.object(launch, "PLATFORM", "linux"), \
                mock.patch.object(launch.os, "execve") as ex:
            err = io.StringIO()
            with redirect_stderr(err):
                rc = launch.main(BASE + ["--egress-port", "3128"])
        self.assertEqual(rc, launch.EXIT_USAGE)
        ex.assert_not_called()
        self.assertIn("macOS-only", err.getvalue())


if __name__ == "__main__":
    unittest.main()
