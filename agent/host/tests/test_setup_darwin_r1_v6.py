"""R1 under Seatbelt: setup's probe listener owns BOTH loopback families at its port (RoseCat 7071; BlueBeaver 7075;
JadeBeacon 7079; bead zigBrowser-v9f). Setup's profile permits `(remote tcp "localhost:<port>")`, which admits ::1
too, so besides its 127.0.0.1 listener setup holds an AF_INET6 IPV6_V6ONLY reservation on ::1:<the same port> for
the whole probe: bound, NOT listening, no SO_REUSEADDR/SO_REUSEPORT, not inheritable and NOT passed to the probe.
If it cannot be taken, setup refuses ("no R1"; refuse, not retry). On Linux with the platform injected, the seam
faked with its real signature and setup's census answered clean:

- while the probe runs, a second ::1:<port> bind fails with EADDRINUSE, also with SO_REUSEADDR+SO_REUSEPORT;
- pass_fds is still exactly the listener and the census end (the reservation never reaches the sandbox);
- after probe_r1, both 127.0.0.1:<port> and ::1:<port> are free;
- a ::1 listener already at the port setup's v4 listener gets (forced by the test) makes probe_r1 refuse: False,
  nothing enters the seam or runs, and every socket setup made is closed.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_setup_darwin_r1_v6. Unregistered until
the green.
"""
import errno
import socket
import unittest
from unittest import mock

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


@unittest.skipUnless(socket.has_ipv6, "needs IPv6 loopback")
class V6Reservation(Base):
    def setUp(self):
        super().setUp()
        mock.patch.object(setup, "PLATFORM", "darwin").start()
        self.fake_seam()

    def test_while_the_probe_runs_v6_is_held_and_after_both_families_are_free(self):
        held = []
        self.fake_run()
        inner = setup.subprocess.run.side_effect

        def run(argv, **kwargs):
            port = int(argv[argv.index("--listen-port") + 1])
            held.append((port, bind_errno(socket.AF_INET6, ("::1", port)),
                         bind_errno(socket.AF_INET6, ("::1", port), reuse=True)))
            return inner(argv, **kwargs)

        mock.patch.object(setup.subprocess, "run", side_effect=run).start()
        self.assertIs(setup.probe_r1(WRAPPER, CLI), True)
        ((port, plain, reuse),) = held
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


if __name__ == "__main__":
    unittest.main()
