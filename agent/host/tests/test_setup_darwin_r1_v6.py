"""R1 under Seatbelt: setup's probe listener owns BOTH loopback families at its port (RoseCat 7071; BlueBeaver 7075;
JadeBeacon 7079; bead zigBrowser-v9f). Setup's profile permits `(remote tcp "localhost:<port>")`, which admits ::1
too, so besides its 127.0.0.1 listener setup holds an AF_INET6 IPV6_V6ONLY reservation on ::1:<the same port> for
the whole probe: bound, NOT listening, no SO_REUSEADDR/SO_REUSEPORT, not inheritable and NOT passed to the probe.
If it cannot be taken, setup refuses ("no R1"; refuse, not retry). On Linux with the platform injected, the seam
faked with its real signature and setup's census answered clean:

- while the probe runs, a second ::1:<port> bind fails with EADDRINUSE, also with SO_REUSEADDR+SO_REUSEPORT, and the
  reservation setup itself created is exactly one AF_INET6 SOCK_STREAM socket on [::1]:<port> with IPV6_V6ONLY 1,
  SO_ACCEPTCONN 0, SO_REUSEADDR 0, SO_REUSEPORT 0, not inheritable (read directly; RoseCat 7097);
- pass_fds is still exactly the listener and the census end (the reservation never reaches the sandbox);
- after probe_r1, both 127.0.0.1:<port> and ::1:<port> are free;
- a ::1 listener already at the port setup's v4 listener gets (forced by the test) makes probe_r1 refuse: False,
  nothing enters the seam or runs, and every socket setup made is closed.

A gate host without IPv6 loopback FAILS this module by name (IPV6_MISSING; bd 4pa.29, CR11), never skips it to
green; MissingIpv6IsAFailure proves that with IPv6 forced off.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_setup_darwin_r1_v6 (registered: the
agent-setup-ms5 step's setup-darwin-r1-v6 command, in `zig build test`).
"""
import errno
import io
import socket
import unittest
from unittest import mock

import ipv6_gate

import support  # noqa: F401  (puts the helper package on sys.path)

from test_setup_darwin_r1 import CLI, WRAPPER, Base

from zb_agent_host import setup


def bind_errno(family, addr, reuse=False):
    with socket.socket(family, socket.SOCK_STREAM) as s:
        if family == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        if reuse:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        try:
            s.bind(addr)
        except OSError as exc:
            return exc.errno
        return 0


class V6Reservation(Base):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        ipv6_gate.require_ipv6_loopback("setup's [::1] reservation test")

    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        self.fake_seam()

    def test_while_the_probe_runs_v6_is_held_and_after_both_families_are_free(self):
        held, shapes, made = [], [], []
        self.fake_run()
        inner = setup.subprocess.run.side_effect
        real_socket = socket.socket
        recording = [True]
        requested = []

        class Recording(real_socket):
            # What setup ASKS for: Linux forces IPV6_V6ONLY on any socket bound to ::1, so only the request shows
            # that setup sets it (the contract requires it; macOS defaults to 0).
            def setsockopt(self, *a):
                requested.append((self.family, a))
                return super().setsockopt(*a)

        def factory(*args, **kwargs):
            if "fileno" in kwargs or not recording[0]:
                return real_socket(*args, **kwargs)
            s = Recording(*args, **kwargs)
            made.append(s)  # setup's own sockets, made before the probe runs
            return s

        mock.patch.object(setup.socket, "socket", side_effect=factory).start()

        def run(argv, **kwargs):
            recording[0] = False
            port = int(argv[argv.index("--listen-port") + 1])
            # The production-created reservation, read directly (RoseCat 7097).
            for s in made:
                if s.family == socket.AF_INET6:
                    shapes.append({"name": s.getsockname()[:2], "type": s.type,
                                   "v6only": s.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY),
                                   "acceptconn": s.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN),
                                   "reuseaddr": s.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR),
                                   "reuseport": s.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT),
                                   "inheritable": s.get_inheritable()})
            held.append((port, bind_errno(socket.AF_INET6, ("::1", port)),
                         bind_errno(socket.AF_INET6, ("::1", port), reuse=True)))
            return inner(argv, **kwargs)

        support.fake_setup_runs(setup, side_effect=run).start()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        ((port, plain, reuse),) = held
        self.assertEqual(shapes, [{"name": ("::1", port), "type": socket.SOCK_STREAM, "v6only": 1, "acceptconn": 0,
                                   "reuseaddr": 0, "reuseport": 0, "inheritable": False}],
                         "exactly one reservation: V6ONLY, never listening, no reuse flags, not inheritable")
        v6 = [a for family, a in requested if family == socket.AF_INET6]
        self.assertIn((socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1), v6, "setup explicitly requests IPV6_V6ONLY")
        self.assertFalse([a for a in v6 if a[:2] in ((socket.SOL_SOCKET, socket.SO_REUSEADDR),
                                                     (socket.SOL_SOCKET, socket.SO_REUSEPORT))],
                         f"and never a reuse flag on it ({v6})")
        self.assertEqual((plain, reuse), (errno.EADDRINUSE, errno.EADDRINUSE),
                         "::1:<port> is setup's during the probe, even against SO_REUSEADDR+SO_REUSEPORT")
        (run_rec,) = self.runs
        self.assertEqual(sorted(run_rec["pass_fds"]), sorted((run_rec["fd"], run_rec["census_fd"])),
                         "the reservation is never passed to the probe")
        self.assertEqual((bind_errno(socket.AF_INET, ("127.0.0.1", port)), bind_errno(socket.AF_INET6, ("::1", port))),
                         (0, 0), "after probe_r1 both families are free")

    def test_a_planted_v6_listener_at_the_port_is_no_r1_and_nothing_runs(self):
        planted = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        self.addCleanup(planted.close)
        planted.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        planted.bind(("::1", 0))
        planted.listen(1)
        port = planted.getsockname()[1]
        self.fake_run()
        made = []
        real_socket = socket.socket

        class OntoPlantedPort(real_socket):
            """setup's AF_INET listener, forced onto the planted port (the OS would pick a free one)."""

            def bind(self, addr):
                return super().bind((addr[0], port))

        def factory(*args, **kwargs):
            if "fileno" in kwargs:
                return real_socket(*args, **kwargs)
            family = args[0] if args else kwargs.get("family", socket.AF_INET)
            s = (OntoPlantedPort if family == socket.AF_INET else real_socket)(*args, **kwargs)
            made.append(s)
            return s

        mock.patch.object(setup.socket, "socket", side_effect=factory).start()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), False, "refuse, not retry")
        self.assertEqual((self.seam, self.runs), ([], []), "nothing enters the seam or runs")
        self.assertEqual([s.fileno() for s in made], [-1] * len(made), "every socket setup made is closed")
        self.assertTrue(any(s.family == socket.AF_INET6 for s in made), "setup tried to reserve ::1")


class MissingIpv6IsAFailure(unittest.TestCase):
    """A gate host without IPv6 loopback FAILS V6Reservation by name (bd 4pa.29, CR11): the class is run here with
    IPv6 forced off, and must end in an IPV6_MISSING error with no test run and nothing skipped. Nothing is started:
    the precondition stops the class before any test."""

    def run_v6_reservation(self):
        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(V6Reservation))
        problems = [tb for _, tb in result.errors + result.failures]
        self.assertFalse(result.wasSuccessful(), "a host without IPv6 must not pass the reservation tests")
        self.assertEqual(result.skipped, [], "a host without IPv6 must not skip them to green")
        self.assertEqual(result.testsRun, 0, "no reservation test runs without IPv6")
        self.assertTrue(any("IPV6_MISSING" in tb for tb in problems), f"the failure names the cause: {problems!r}")
        return problems

    def test_has_ipv6_false_is_a_named_failure(self):
        with mock.patch.object(socket, "has_ipv6", False):
            problems = self.run_v6_reservation()
        self.assertTrue(any("socket.has_ipv6 is False" in tb for tb in problems), problems)

    def test_an_unbindable_v6_loopback_is_a_named_failure(self):
        refused = OSError(errno.EADDRNOTAVAIL, "Cannot assign requested address")
        with mock.patch.object(socket, "has_ipv6", True), \
                mock.patch.object(ipv6_gate, "_bind_v6_loopback", side_effect=refused):
            problems = self.run_v6_reservation()
        self.assertTrue(any("[::1] cannot be bound" in tb for tb in problems), problems)

if __name__ == "__main__":
    unittest.main()
