"""R1's verdict that no CLI environment holds the token (BlueBeaver 6977; RoseCat 6958), on Linux with
zb_agent_host.proc_darwin's calls faked.

On macOS the verdict is setup's census, proc_darwin.cli_env_clean(exe, root, token, canary), run OUTSIDE Seatbelt
over setup's own descendants (RoseCat 7019; BlueBeaver 7021); the probe asks it over a socketpair
(test_route_probe_census / test_setup_census) and never walks processes itself. It is True only when
- at least one descendant of `root` runs `exe` (proc_darwin.descendants_running(exe, root));
- every one's KERN_PROCARGS2 reads and parses (proc_darwin.environ_of): a failed read is not clean;
- every one's parsed environment holds the canary, the exact entry "ANTHROPIC_BASE_URL=<the probe server's url>"
  that the CLI always inherits: an environment the OS hid (macOS does for platform binaries) or a misparse is
  therefore not clean, never vacuously clean;
- the token appears nowhere in any of their buffers (argv counts: it is as visible as the environment).
A denied child listing or an unreadable path anywhere in the walk is not clean either: only a vanished process may
be skipped (RoseCat 7011).
On Linux the probe's own route_probe._cli_env_clean is unchanged: /proc/<pid>/environ of the descendants running
`cli`, and no canary is required. The Linux probe server passes the canary and records the verdict.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_route_probe_darwin_env.
"""
import json
import os
import shutil
import subprocess
import time
import unittest
import urllib.request
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import route_probe

try:
    from zb_agent_host import proc_darwin
except ImportError:
    proc_darwin = None

TOKEN = "zb-probe-" + "ab" * 24
URL = "http://127.0.0.1:50123"
CANARY = b"ANTHROPIC_BASE_URL=" + URL.encode()


class Base(unittest.TestCase):
    def setUp(self):
        if proc_darwin is None:
            self.fail("agent/host/zb_agent_host/proc_darwin.py is missing (6977)")
        if not hasattr(route_probe, "PLATFORM") or not hasattr(route_probe, "_cli_env_clean"):
            self.fail("route_probe.PLATFORM / route_probe._cli_env_clean is missing (6977)")
        self.addCleanup(mock.patch.stopall)


class Darwin(Base):
    def verdict(self, procs, cli="/opt/claude"):
        """procs: pid -> (argv, env) or an exception to raise from environ_of."""
        mock.patch.object(route_probe, "PLATFORM", "darwin").start()
        walked = []

        def descendants(exe, root):
            walked.append((exe, root))
            return list(procs)

        def environ_of(pid):
            got = procs[pid]
            if isinstance(got, BaseException):
                raise got
            argv, env = got
            raw = b"\0".join([b"\x01\0\0\0" + cli.encode()] + argv + env) + b"\0\0"
            return raw, argv, env

        mock.patch.object(proc_darwin, "descendants_running", side_effect=descendants).start()
        mock.patch.object(proc_darwin, "environ_of", side_effect=environ_of).start()
        result = proc_darwin.cli_env_clean(os.path.realpath(cli), os.getpid(), TOKEN.encode(), CANARY)
        self.assertEqual(walked, [(os.path.realpath(cli), os.getpid())])
        return result

    def test_a_clean_cli_with_the_canary_is_clean(self):
        self.assertIs(self.verdict({7: ([b"/opt/claude"], [b"PATH=/usr/bin", CANARY])}), True)

    def test_no_cli_descendant_is_not_clean(self):
        self.assertIs(self.verdict({}), False)

    def test_a_hidden_environment_is_not_clean(self):
        self.assertIs(self.verdict({7: ([b"/opt/claude"], [])}), False)

    def test_an_environment_without_the_exact_canary_is_not_clean(self):
        # Exact entry, never a substring (BlackRobin 6998): a longer port with the same prefix, a longer key, a path.
        for env in ([b"PATH=/usr/bin"], [b"ANTHROPIC_BASE_URL=http://127.0.0.1:1"], [CANARY + b"/"], [CANARY + b"0"],
                    [b"X" + CANARY]):
            with self.subTest(env=env):
                self.assertIs(self.verdict({7: ([b"/opt/claude"], env)}), False)

    def test_the_canary_only_in_argv_is_not_clean(self):
        self.assertIs(self.verdict({7: ([b"/opt/claude", CANARY], [b"PATH=/usr/bin"])}), False)

    def test_an_unreadable_cli_is_not_clean(self):
        self.assertIs(self.verdict({7: PermissionError(1, "denied")}), False)
        self.assertIs(self.verdict({7: ([b"/opt/claude"], [CANARY]), 8: ProcessLookupError(3, "gone")}), False)

    def test_the_token_anywhere_is_not_clean(self):
        for argv, env in (([b"/opt/claude"], [CANARY, b"ANTHROPIC_API_KEY=" + TOKEN.encode()]),
                          ([b"/opt/claude"], [CANARY, b"X=" + TOKEN.encode()]),
                          ([b"/opt/claude", b"--key", TOKEN.encode()], [CANARY])):
            with self.subTest(argv=argv, env=env):
                self.assertIs(self.verdict({7: (argv, env)}), False)

    def test_one_leaking_cli_among_clean_ones_is_not_clean(self):
        self.assertIs(self.verdict({7: ([b"/opt/claude"], [CANARY]),
                                    8: ([b"/opt/claude"], [CANARY, b"T=" + TOKEN.encode()])}), False)


class DarwinWalkFailures(Base):
    """RoseCat 7011: a clean CLI plus an uninspected subtree or process is never clean. The real walk
    (proc_darwin.descendants_running) runs over faked children()/path(); environ_of is faked."""

    def verdict(self, tree, paths, envs):
        mock.patch.object(route_probe, "PLATFORM", "darwin").start()
        me = os.getpid()

        def children(pid):
            got = tree.get(me if pid == me else pid, [])
            if isinstance(got, BaseException):
                raise got
            return list(got)

        def path(pid):
            got = paths.get(pid)
            if isinstance(got, BaseException):
                raise got
            return got

        def environ_of(pid):
            argv, env = envs[pid]
            return b"\0".join([b"/opt/claude"] + argv + env), argv, env

        mock.patch.object(proc_darwin, "children", side_effect=children).start()
        mock.patch.object(proc_darwin, "path", side_effect=path).start()
        mock.patch.object(proc_darwin, "environ_of", side_effect=environ_of).start()
        return proc_darwin.cli_env_clean("/opt/claude", os.getpid(), TOKEN.encode(), CANARY)

    CLEAN = {7: ([b"/opt/claude"], [CANARY])}

    def test_a_denied_root_listing_is_not_clean(self):
        self.assertIs(self.verdict({os.getpid(): PermissionError(1, "denied")}, {7: "/opt/claude"}, self.CLEAN), False)

    def test_a_denied_intermediate_listing_beside_a_clean_cli_is_not_clean(self):
        tree = {os.getpid(): [7, 8], 8: PermissionError(1, "denied")}
        self.assertIs(self.verdict(tree, {7: "/opt/claude", 8: "/usr/bin/python3"}, self.CLEAN), False)

    def test_an_unreadable_path_beside_a_clean_cli_is_not_clean(self):
        tree = {os.getpid(): [7, 9]}
        self.assertIs(self.verdict(tree, {7: "/opt/claude", 9: PermissionError(1, "denied")}, self.CLEAN), False)

    def test_a_vanished_process_beside_a_clean_cli_is_still_clean(self):
        tree = {os.getpid(): [7, 8, 9], 8: ProcessLookupError(3, "gone")}
        self.assertIs(self.verdict(tree, {7: "/opt/claude", 8: "/usr/bin/python3", 9: None}, self.CLEAN), True)


class LinuxUnchanged(Base):
    def run_child(self, env):
        exe = os.path.realpath(shutil.which("sleep"))
        child = subprocess.Popen([exe, "30"], env=env)
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        deadline = time.monotonic() + 5
        while os.path.realpath(f"/proc/{child.pid}/exe") != exe and time.monotonic() < deadline:
            time.sleep(0.02)
        mock.patch.object(route_probe, "PLATFORM", "linux").start()
        mock.patch.object(proc_darwin, "descendants_running", side_effect=AssertionError("Linux reads /proc")).start()
        return route_probe._cli_env_clean(exe, TOKEN, CANARY)

    def test_a_real_child_without_the_token_is_clean_and_needs_no_canary(self):
        self.assertIs(self.run_child({"PATH": "/usr/bin"}), True)

    def test_a_real_child_holding_the_token_is_not_clean(self):
        self.assertIs(self.run_child({"PATH": "/usr/bin", "LEAK": TOKEN}), False)


class ServerWiring(Base):
    def test_the_server_passes_its_own_url_as_the_canary_and_records_the_verdict(self):
        seen = []

        def fake(cli, probe_token, canary):
            seen.append((cli, probe_token, canary))
            return True

        mock.patch.object(route_probe, "_cli_env_clean", side_effect=fake).start()
        server = route_probe._ProbeServer(TOKEN, "/opt/claude")
        self.addCleanup(server.close)
        req = urllib.request.Request(f"{server.url}/v1/messages", data=json.dumps({}).encode(), method="POST",
                                     headers={"content-type": "application/json", "authorization": "Bearer b"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        self.assertEqual(seen, [("/opt/claude", TOKEN, b"ANTHROPIC_BASE_URL=" + server.url.encode())])
        self.assertIs(server.cli_env_clean, True)


if __name__ == "__main__":
    unittest.main()
