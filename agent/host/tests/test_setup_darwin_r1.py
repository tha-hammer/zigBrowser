"""R1 under Seatbelt, setup's half (RoseCat 6958; BlueBeaver 6961; BlackRobin 6975; JadeBeacon 7004), on Linux with
the platform injected (`setup.PLATFORM`) and the MS6 seam faked with JadeBeacon's agreed signature
`sandbox_macos.setup_sandbox(scratch, ro_paths, command, *, loopback_port=None)`:

- On Darwin, probe_r1 binds 127.0.0.1:0 itself, OUTSIDE the sandbox, listening, and runs the probe through the
  seam with loopback_port=<that port> (the profile permits exactly that one port) and the command extended by
  `--listen-fd <fd> --listen-port <port>`; subprocess.run gets pass_fds=(fd,) and nothing else.
- Setup's copy is not inheritable (only pass_fds hands it on), and setup closes it after the run on every path:
  a verdict, a timeout, the seam refusing.
- A listener that cannot be made (socket(), bind() or listen() failing) is "no R1": probe_r1 returns False, nothing
  enters the seam or runs, and a created socket is closed explicitly (RoseCat 7026).
- cli_version stays network-free (no loopback_port); Linux probe_r1 is unchanged (bwrap argv, no pass_fds, no flags).
- Through the real seam (JadeBeacon 0b9527f): the profile in force during the probe has exactly one outbound rule,
  `(allow network-outbound (remote tcp "localhost:<the pre-bound port>"))` (the tcp form since JadeBeacon 70444e5), and cli_version's has none.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_setup_darwin_r1. Unregistered until the
green.
"""
import contextlib
import json
import os
import re
import socket
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin, sandbox_macos, setup

WRAPPER = "/rt/runtime/bin/zb-claude"
CLI = "/opt/claude"


def _closed(fd):
    try:
        os.fstat(fd)
    except OSError:
        return True
    return False


class Base(unittest.TestCase):
    def setUp(self):
        if not hasattr(setup, "PLATFORM"):
            self.fail("setup.PLATFORM is missing")
        self.addCleanup(mock.patch.stopall)
        self.seam = []
        self.runs = []
        # Setup's census (BlueBeaver 7021) is pinned by test_setup_census; here it says clean.
        mock.patch.object(proc_darwin, "cli_env_clean", return_value=True).start()

    def fake_seam(self, refuse=False):
        @contextlib.contextmanager
        def setup_sandbox(scratch, ro_paths, command, *, loopback_port=None):
            self.seam.append({"scratch": scratch, "command": list(command), "loopback_port": loopback_port})
            if refuse:
                raise setup.SetupError("the macOS sandbox is not ready")
            yield ["/usr/bin/sandbox-exec", "-f", f"{scratch}/p.sb", *command]

        mock.patch.object(sandbox_macos, "setup_sandbox", setup_sandbox).start()

    def track_sockets(self):
        """Keeps a reference to every socket setup creates, so only an explicit close() (not the garbage collector
        dropping setup's last reference) leaves it closed."""
        if not hasattr(setup, "socket"):
            self.fail("setup does not pre-bind a listener (no socket use; 6961)")
        made = []
        real_socket = socket.socket

        def tracking_socket(*args, **kwargs):
            s = real_socket(*args, **kwargs)
            if "fileno" not in kwargs:
                made.append(s)
            return s

        mock.patch.object(setup.socket, "socket", side_effect=tracking_socket).start()
        self.addCleanup(lambda: [s.close() for s in made])
        return made

    def assert_all_closed(self, made):
        self.assertTrue(made, "setup pre-binds a listener")
        self.assertEqual([s.fileno() for s in made], [-1] * len(made), "setup closes its copy explicitly")

    def fake_run(self, outcome="r1"):
        def run(argv, **kwargs):
            rec = {"argv": list(argv), "pass_fds": tuple(kwargs.get("pass_fds", ()))}
            if "--listen-fd" in argv:
                fd = int(argv[argv.index("--listen-fd") + 1])
                port = int(argv[argv.index("--listen-port") + 1])
                rec.update(fd=fd, port=port, inheritable=os.get_inheritable(fd))
                probe = socket.socket(fileno=os.dup(fd))
                with probe:
                    rec.update(family=probe.family, kind=probe.type, name=probe.getsockname(),
                               listening=bool(probe.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)))
            if "--census-fd" in argv and outcome != "timeout":  # ask setup's census, as route_probe does
                cfd = int(argv[argv.index("--census-fd") + 1])
                rec["census_fd"] = cfd
                with socket.socket(fileno=os.dup(cfd)) as ask:
                    ask.settimeout(10)
                    ask.sendall(f"census zb-probe-{'ab' * 24} http://127.0.0.1:{rec['port']}\n".encode())
                    reply = b""
                    while chunk := ask.recv(64):
                        reply += chunk
                    rec["census_reply"] = reply
            self.runs.append(rec)
            if outcome == "timeout":
                raise setup.subprocess.TimeoutExpired(argv, kwargs.get("timeout"))
            return setup.subprocess.CompletedProcess(argv, 0, stdout=json.dumps({"r1": True}) + "\n", stderr="")

        mock.patch.object(setup.subprocess, "run", side_effect=run).start()


class Darwin(Base):
    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "darwin").start()

    def test_the_probe_gets_setups_own_loopback_listener_and_only_that_port(self):
        self.fake_seam()
        self.fake_run()
        made = self.track_sockets()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        (seam,), (run,) = self.seam, self.runs
        self.assertIn("--listen-fd", run["argv"], "setup hands the probe no pre-bound listener (6961)")
        port, fd = run["port"], run["fd"]
        self.assertEqual(seam["loopback_port"], port, "the profile permits exactly the pre-bound port")
        self.assertEqual(seam["command"][-6:], ["--listen-fd", str(fd), "--listen-port", str(port),
                                                 "--census-fd", str(run["census_fd"])])
        self.assertEqual(seam["command"][:4][1:3], ["-m", "zb_agent_host"])
        self.assertEqual(sorted(run["pass_fds"]), sorted((fd, run["census_fd"])),
                         "only the listener and the census end are passed (BlueBeaver 7021)")
        self.assertEqual(run["census_reply"], b"clean\n")
        self.assertEqual((run["family"], run["kind"], run["name"], run["listening"]),
                         (socket.AF_INET, socket.SOCK_STREAM, ("127.0.0.1", port), True))
        self.assertFalse(run["inheritable"], "setup's copy is not inheritable; pass_fds alone hands it on")
        self.assert_all_closed(made)
        self.assertTrue(_closed(fd), "setup closes its copy after the run")

    def test_a_timeout_still_closes_setups_copy(self):
        self.fake_seam()
        self.fake_run("timeout")
        made = self.track_sockets()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False)
        (run,) = self.runs
        self.assertIn("--listen-fd", run["argv"], "setup hands the probe no pre-bound listener (6961)")
        self.assert_all_closed(made)

    def test_a_refusing_seam_still_closes_setups_copy(self):
        self.fake_seam(refuse=True)
        self.fake_run()
        made = self.track_sockets()
        with self.assertRaises(setup.SetupError):
            setup.probe_r1(WRAPPER, CLI)
        self.assertEqual(self.runs, [], "nothing runs unsandboxed")
        self.assert_all_closed(made)

    def failing_listener(self, step):
        """Setup's socket fails at `step` ("socket", "bind" or "listen"); every created socket is kept, so only an
        explicit close() leaves it closed (RoseCat 7026)."""
        if not hasattr(setup, "socket"):
            self.fail("setup does not pre-bind a listener (no socket use; 6961)")
        made = []
        real_socket = socket.socket

        class Failing(real_socket):
            def bind(self, addr):
                if step == "bind":
                    raise OSError(98, "Address already in use")
                return super().bind(addr)

            def listen(self, *args):
                if step == "listen":
                    raise OSError(22, "Invalid argument")
                return super().listen(*args)

        def factory(*args, **kwargs):
            if "fileno" in kwargs:
                return real_socket(*args, **kwargs)
            if step == "socket":
                raise OSError(24, "Too many open files")
            s = Failing(*args, **kwargs)
            made.append(s)
            return s

        patcher = mock.patch.object(setup.socket, "socket", side_effect=factory)
        patcher.start()
        self.addCleanup(lambda: [s.close() for s in made])
        return made, patcher

    def test_a_listener_that_cannot_be_made_is_no_r1_and_nothing_runs(self):
        self.fake_seam()
        self.fake_run()
        for step in ("socket", "bind", "listen"):
            with self.subTest(step=step):
                self.seam.clear()
                self.runs.clear()
                made, patcher = self.failing_listener(step)
                try:
                    self.assertIs(setup.probe_r1(WRAPPER, CLI), False, "fail closed: no R1 without its listener")
                    self.assertEqual((self.seam, self.runs), ([], []), "no seam and no run")
                    if step == "socket":
                        self.assertEqual(made, [])
                    else:
                        self.assert_all_closed(made)
                finally:
                    patcher.stop()

    def test_cli_version_stays_network_free(self):
        self.fake_seam()
        self.fake_run()
        setup.cli_version(CLI)
        (seam,), (run,) = self.seam, self.runs
        self.assertIsNone(seam["loopback_port"])
        self.assertNotIn("--listen-fd", seam["command"])
        self.assertEqual(run["pass_fds"], ())


class DarwinRealSeam(Base):
    """Through JadeBeacon's real sandbox_macos.setup_sandbox (0b9527f): the profile in force while the probe runs
    permits exactly the pre-bound port, and cli_version's permits no network at all."""

    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        self.profiles = []
        real_run = self.fake_run

        def capture(argv, **kwargs):
            with open(argv[2], encoding="utf-8") as f:
                self.profiles.append(f.read())
            return run(argv, **kwargs)

        real_run()
        run = setup.subprocess.run.side_effect
        mock.patch.object(setup.subprocess, "run", side_effect=capture).start()

    def outbound(self, profile):
        return re.findall(r"\(allow network-outbound[^\n]*", profile)

    def test_the_probe_runs_under_a_profile_allowing_exactly_its_port(self):
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        (run,), (profile,) = self.runs, self.profiles
        self.assertEqual(self.outbound(profile), [f'(allow network-outbound (remote tcp "localhost:{run["port"]}"))'])

    def test_cli_version_runs_under_a_profile_with_no_network(self):
        setup.cli_version(CLI)
        (profile,) = self.profiles
        self.assertEqual(self.outbound(profile), [])


class LinuxUnchanged(Base):
    def test_linux_probe_r1_is_unchanged(self):
        mock.patch.object(setup, "PLATFORM", "linux").start()
        mock.patch.object(sandbox_macos, "setup_sandbox", side_effect=AssertionError("Linux never uses Seatbelt")).start()
        self.fake_run()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        (run,) = self.runs
        self.assertEqual(run["argv"][0], setup.sandbox.BWRAP)
        self.assertNotIn("--listen-fd", run["argv"])
        self.assertEqual(run["pass_fds"], ())


if __name__ == "__main__":
    unittest.main()
