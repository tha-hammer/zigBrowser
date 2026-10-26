"""bd zigBrowser-4pa.21, plan MS6.8 slice 2a (SilverRidge d751d158 ruling): the Zig launch builders compose with the
real Python consumer.

Registered (the slice-2a green; red approved by SilverRidge e39f6c90): the named step ``test-agent-launch-bridge``
builds the bridge and runs this module, and aggregate ``test`` depends on it, with no skip mapping.

This is a PREPARATORY connector proof, not proof of a production Darwin launch: the browser's Darwin helper and login
path does not call these builders until 4pa.27/MS8 (configureAgentHelper/Login return on non-Linux), and the Darwin
spawn policy is bound there (option b).

``src/agent_launch_bridge.zig`` is a test-only executable over the REAL builders (``agent_helper.launch`` and
``agent_login.launch``). It prints their whole argv, environment, warnings and refusal as JSON. Each row asserts the
exact prefix ``[python, "-m", "zb_agent_host", "launch"]``, then hands the rest of that argv to the REAL
``launch.main``: on Darwin with ``sandbox_macos.LAUNCH_SPEC_CONSUMABLE()`` patched True (this test seam only) and a
recording ``subprocess.Popen``; on Linux with a recording ``os.execve``. The private ``sandbox._LINUX_BACKEND`` stays
poisoned (the slice-1 harness). The bridge's path is ``$ZB_LAUNCH_BRIDGE``; a missing bridge FAILS every row (no skip).

The builder's Darwin realization carries netd's loopback egress port; its Linux realization carries netd's socket
dir. Rows (each its own test):
- D Darwin, the real consumer, ports 51234 and 40001 each:
  - D1 chat: no ``--net-dir``/``--bwrap``, no refusal; main spawns once inside the lease (the profile present while
    the child is waited for, gone after) and returns the child's status; the inner chat carries ``--egress-port <n>``.
  - D2 login (with the e2e CLI): the same for the inner login, which also carries ``--e2e-claude-cli``.
  - D3 login without the e2e CLI, which is not refused.
  - D4 chat's e2e test CA reaches the inner chat as ``--test-ca <host path>``.
- X Darwin inputs that must be refused before dispatch (named refusal, so the Python consumer is never reached):
  - X1 an e2e bwrap override, for chat and for login;
  - X2 the e2e whole-host-command override (it would bypass ``zb_agent_host launch`` and Seatbelt), whose argv also
    stays the launch argv;
  - X3 egress port 0, for chat and for login, with and without --e2e-protocol (zero is never valid).
- W Darwin without --e2e-protocol: the bwrap and host-command seams keep their "ignored" warning, no refusal, and the
  argv still reaches main and spawns with the port.
- L Linux, the real consumer (byte-for-byte):
  - L1 chat: execve's argv equals ``test_backend_contract.reference_build_argv``;
  - L2 chat with the e2e test CA and an e2e bwrap override: execve's path is the override and its argv the reference;
  - L3 login with the e2e CLI equals ``test_launch_connector.reference_login_argv``;
  - L4 the e2e host-command override still replaces the whole Linux argv (unchanged behaviour).

Run: zig build test-agent-launch-bridge (or, by hand: ZB_LAUNCH_BRIDGE=<bridge> python3 -X dev -m unittest -v
test_launch_bridge).
"""

import json
import os
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import test_launch_connector as tlc  # the slice-1 harness: home fixture, poisoned global, Darwin/Linux main seams
from test_backend_contract import REF_BWRAP, reference_build_argv

from zb_agent_host import launch

PYTHON = tlc.PYTHON
PORTS = (tlc.MAC_PORT, tlc.OTHER_PORT)
PREFIX = [PYTHON, "-m", "zb_agent_host", "launch"]
BWRAP_REFUSAL = "zigBrowser: agent: ZIGBROWSER_AGENT_BWRAP is the Linux sandbox's only"
HOST_CMD_REFUSAL = "zigBrowser: agent: ZIGBROWSER_AGENT_HOST_CMD would bypass the macOS launch"
PORT_REFUSAL = "zigBrowser: agent: the macOS egress port must be 1..65535"
BWRAP_IGNORED = "zigBrowser: ZIGBROWSER_AGENT_BWRAP ignored without --e2e-protocol"
HOST_CMD_IGNORED = "zigBrowser: ZIGBROWSER_AGENT_HOST_CMD ignored without --e2e-protocol"


class Bridge(tlc.Connector):
    def setUp(self):
        super().setUp()
        self.bridge = os.environ.get("ZB_LAUNCH_BRIDGE")
        if not self.bridge or not os.access(self.bridge, os.X_OK):
            self.fail(f"ZB_LAUNCH_BRIDGE is not an executable bridge: {self.bridge!r}")
        root = Path(self._tmp.name)
        self.cli = root / "fake-claude"
        self.cli.write_text("#!/bin/sh\n")
        self.test_ca = root / "test-ca.pem"
        self.test_ca.write_text("ca\n")

    # --- helpers -------------------------------------------------------------------------------------------------
    def build(self, command, realization, *extra):
        argv = [self.bridge, command, "--python", PYTHON, "--home", str(self.home.root), *realization, *extra]
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=30)
        self.assertEqual(r.returncode, 0, f"the bridge failed: {r.stderr.decode(errors='replace')}")
        return json.loads(r.stdout)

    def darwin_form(self, command, port, *extra):
        return self.build(command, ("--darwin", str(port)), *extra)

    def launch_args(self, row, out):
        """The builder's argv after its exact prefix: what the browser passes to `zb_agent_host launch`."""
        argv = out["argv"]
        self.assertEqual(argv[:4], PREFIX, f"{row}: the argv must start {PREFIX}")
        return argv[4:]

    def assert_no_linux_flags(self, row, args):
        for flag in ("--net-dir", "--bwrap"):
            self.assertNotIn(flag, args, f"{row}: a Darwin launch argv carries no {flag}")

    def darwin_consume(self, row, args):
        """The real launch.main on Darwin over a recording Popen (status 7). Returns the inner argv and stderr."""
        seen = {}

        def on_wait(proc):
            argv = list(proc.args)
            seen["argv"] = argv
            seen["live"] = os.path.isfile(argv[2]) and len(self.profile_dirs()) == 1

        popen = tlc.RecordingPopen(status=7, on_wait=on_wait)
        rc, err, ex, _, _, _ = self.darwin(args, ready=True, popen=popen)
        self.assertEqual(len(popen.calls), 1, f"{row}: main must spawn once (rc={rc}, stderr={err!r})")
        self.assertTrue(seen.get("live"), f"{row}: the profile must be present while the child is waited for")
        self.assertEqual(rc, 7, f"{row}: main returns the child's status")
        ex.assert_not_called()
        self.assertEqual(self.profile_dirs(), [], f"{row}: no profile is left")
        return self.seatbelt_inner(seen["argv"])

    def linux_consume(self, row, args, bwrap=REF_BWRAP):
        with tlc.poisoned(), mock.patch.object(launch, "PLATFORM", "linux"), \
                mock.patch.object(launch.os, "access", return_value=True), \
                mock.patch.object(launch.seccomp, "seccomp_fd", return_value=9), \
                mock.patch.object(launch.os, "set_inheritable"), \
                mock.patch.object(launch.os, "execve") as ex:
            rc, err = self.run_main(args)
        self.assertEqual(ex.call_count, 1, f"{row}: execve once (rc={rc}, stderr={err!r})")
        path, argv, _env = ex.call_args.args
        self.assertEqual(path, bwrap, f"{row}: execve's path")
        return list(argv)

    # --- D: Darwin through the real consumer -----------------------------------------------------------------------
    def test_d1_darwin_chat_reaches_the_inner_chat_with_the_port(self):
        for port in PORTS:
            with self.subTest(port=port):
                out = self.darwin_form("chat", port)
                self.assertIsNone(out["refusal"], "D1: no refusal")
                args = self.launch_args("D1", out)
                self.assert_no_linux_flags("D1", args)
                self.assertEqual(self.darwin_consume("D1", args), self.inner("chat", "--egress-port", str(port)))

    def test_d2_darwin_login_with_the_e2e_cli_reaches_the_inner_login_with_the_port(self):
        for port in PORTS:
            with self.subTest(port=port):
                out = self.darwin_form("login", port, "--e2e", "--claude-cli", str(self.cli))
                self.assertIsNone(out["refusal"], "D2: no refusal")
                args = self.launch_args("D2", out)
                self.assert_no_linux_flags("D2", args)
                self.assertEqual(self.darwin_consume("D2", args),
                                 self.inner("login", "--e2e-claude-cli", str(self.cli), "--egress-port", str(port)))

    def test_d3_darwin_login_reaches_the_inner_login_with_the_port(self):
        for port in PORTS:
            with self.subTest(port=port):
                out = self.darwin_form("login", port)
                self.assertIsNone(out["refusal"], "D3: an ordinary Darwin login is not refused (a caller stops on one)")
                args = self.launch_args("D3", out)
                self.assert_no_linux_flags("D3", args)
                self.assertEqual(self.darwin_consume("D3", args), self.inner("login", "--egress-port", str(port)))

    def test_d4_darwin_chat_test_ca_reaches_the_inner_chat(self):
        out = self.darwin_form("chat", tlc.MAC_PORT, "--e2e", "--test-ca", str(self.test_ca))
        self.assertIsNone(out["refusal"], "D4: no refusal")
        args = self.launch_args("D4", out)
        self.assert_no_linux_flags("D4", args)
        self.assertEqual(self.darwin_consume("D4", args),
                         self.inner("chat", "--test-ca", str(self.test_ca), "--egress-port", str(tlc.MAC_PORT)))

    # --- X: refused before dispatch -------------------------------------------------------------------------------
    def test_x1_darwin_e2e_bwrap_override_is_refused_for_chat_and_login(self):
        for command in ("chat", "login"):
            with self.subTest(command=command):
                out = self.darwin_form(command, tlc.MAC_PORT, "--e2e", "--bwrap", "/opt/marker-bwrap")
                self.assertEqual(out["refusal"], BWRAP_REFUSAL, f"X1: {command}: the bwrap override is refused")
                self.assertNotIn("/opt/marker-bwrap", out["argv"], f"X1: {command}: and never reaches the argv")

    def test_x2_darwin_e2e_host_command_is_refused_and_the_argv_stays_the_launch(self):
        out = self.darwin_form("chat", tlc.MAC_PORT, "--e2e", "--host-cmd", "/opt/marker-host")
        self.assertEqual(out["refusal"], HOST_CMD_REFUSAL, "X2: the host-command override is refused on Darwin")
        self.assertEqual(out["argv"][:4], PREFIX, "X2: the argv is still the zb_agent_host launch argv")
        self.assertNotIn("/opt/marker-host", out["argv"])

    def test_x3_darwin_port_zero_is_refused_for_chat_and_login_with_or_without_e2e(self):
        for command in ("chat", "login"):
            for e2e in (False, True):
                with self.subTest(command=command, e2e=e2e):
                    out = self.darwin_form(command, 0, *(("--e2e",) if e2e else ()))
                    self.assertEqual(out["refusal"], PORT_REFUSAL, f"X3: {command}, e2e={e2e}: port 0 is always refused")

    # --- W: Darwin without --e2e-protocol --------------------------------------------------------------------------
    def test_w1_darwin_seams_without_e2e_are_ignored_and_the_launch_still_reaches_main(self):
        out = self.darwin_form("chat", tlc.MAC_PORT, "--bwrap", "/opt/marker-bwrap", "--host-cmd", "/opt/marker-host")
        self.assertIsNone(out["refusal"], "W1: no refusal without --e2e-protocol")
        self.assertEqual(out["warnings"], [BWRAP_IGNORED, HOST_CMD_IGNORED], "W1: one ignored line each")
        args = self.launch_args("W1", out)
        self.assert_no_linux_flags("W1", args)
        self.assertEqual(self.darwin_consume("W1", args), self.inner("chat", "--egress-port", str(tlc.MAC_PORT)))

    # --- L: Linux through the real consumer, byte-for-byte ---------------------------------------------------------
    def linux_form(self, command, *extra):
        return self.build(command, ("--linux", str(self.net_dir)), *extra)

    def test_l1_linux_chat_equals_the_frozen_argv(self):
        out = self.linux_form("chat")
        self.assertIsNone(out["refusal"])
        argv = self.linux_consume("L1", self.launch_args("L1", out))
        self.assertEqual(argv, reference_build_argv(self.home, 9, PYTHON, net_dir=str(self.net_dir)))

    def test_l2_linux_chat_test_ca_and_bwrap_override_equal_the_frozen_argv(self):
        override = "/opt/override/bwrap"
        out = self.linux_form("chat", "--e2e", "--test-ca", str(self.test_ca), "--bwrap", override)
        self.assertIsNone(out["refusal"])
        argv = self.linux_consume("L2", self.launch_args("L2", out), bwrap=override)
        self.assertEqual(argv, reference_build_argv(self.home, 9, PYTHON, net_dir=str(self.net_dir), bwrap=override,
                                                    test_ca=str(self.test_ca)))

    def test_l3_linux_login_with_the_e2e_cli_equals_the_frozen_argv(self):
        out = self.linux_form("login", "--e2e", "--claude-cli", str(self.cli))
        self.assertIsNone(out["refusal"])
        argv = self.linux_consume("L3", self.launch_args("L3", out))
        self.assertEqual(argv, tlc.reference_login_argv(self.home, 9, PYTHON, net_dir=str(self.net_dir),
                                                        claude_cli=str(self.cli)))

    def test_l4_linux_e2e_host_command_still_replaces_the_whole_argv(self):
        out = self.linux_form("chat", "--e2e", "--host-cmd", "/opt/marker-host")
        self.assertIsNone(out["refusal"])
        self.assertEqual(out["argv"], ["/opt/marker-host"])


def load_tests(loader, tests, pattern):
    """Only this module's rows; the inherited slice-1 rows run in test_launch_connector."""
    suite = unittest.TestSuite()
    for name in loader.getTestCaseNames(Bridge):
        if name in Bridge.__dict__:
            suite.addTest(Bridge(name))
    return suite


if __name__ == "__main__":
    unittest.main()
