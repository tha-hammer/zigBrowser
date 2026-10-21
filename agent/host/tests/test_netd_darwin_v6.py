"""macOS netd owns BOTH loopback families at its egress port (RoseCat 7071; BlueBeaver 7075, 7076; JadeBeacon 7079;
bead zigBrowser-v9f). Seatbelt's `(remote tcp "localhost:<port>")` admits 127.0.0.1 AND ::1, so netd, besides its
127.0.0.1 listener, holds an AF_INET6 IPV6_V6ONLY reservation on ::1:<the same port> for its whole life: bound,
NOT listening, with no SO_REUSEADDR / SO_REUSEPORT. If the reservation cannot be taken, netd refuses: exit 2, no
ready line ("refuse, not retry"). On Linux with netd's real main() and PLATFORM "darwin" (test_netd_darwin's
launcher):

- a ::1:<P> listener planted BEFORE netd starts with `--test-port P` makes netd refuse, and nothing of netd's is
  left on 127.0.0.1:<P>;
- while netd is live, a second bind on ::1:<port> fails with EADDRINUSE, also with SO_REUSEADDR and SO_REUSEPORT
  set (so netd set neither), and the ready line is unchanged;
- after EOF on stdin, and after SIGTERM, both 127.0.0.1:<port> and ::1:<port> are free again;
- `--test-port` (the e2e seam; the app passes --test-* only under --e2e-protocol) is Darwin-only and exact: ASCII
  decimal 1-65535, no sign, leading zero or whitespace, given once.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_netd_darwin_v6. Unregistered until the
green.
"""
import errno
import signal
import socket
import subprocess
import sys
import unittest

from test_netd import child_env
from test_netd_darwin import LAUNCH, DarwinNetd, listening_inet_sockets


def free_port():
    """A port free on BOTH 127.0.0.1 and ::1 right now."""
    for _ in range(50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s6:
                s6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                s6.bind(("::1", port))
        except OSError:
            continue
        return port
    raise RuntimeError("no port free on both families")


def bind_errno(family, addr, reuse=False):
    """0 when a plain (or, with reuse, SO_REUSEADDR+SO_REUSEPORT) bind succeeds, else its errno."""
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
class V6Reservation(unittest.TestCase):
    def test_a_planted_v6_listener_makes_netd_refuse(self):
        port = free_port()
        planted = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        self.addCleanup(planted.close)
        planted.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        planted.bind(("::1", port))
        planted.listen(1)
        netd = DarwinNetd(self, "--test-port", str(port))
        self.assertEqual(netd.proc.wait(timeout=10), 2, f"refuse, not retry: {netd.err}")
        self.assertEqual(netd.rest_of_stdout(), "", "no ready line")
        netd.drain.join(5)
        self.assertTrue(any("::1" in line for line in netd.err),
                        f"refused for the ::1 reservation, not for anything else: {netd.err}")
        self.assertEqual(bind_errno(socket.AF_INET, ("127.0.0.1", port)), 0, "nothing of netd's left on v4")

    def test_while_live_the_v6_port_cannot_be_taken_even_with_reuse_flags(self):
        netd = DarwinNetd(self)
        port = netd.ready_port()
        self.assertEqual(listening_inet_sockets(netd.proc.pid), [("127.0.0.1", port)],
                         "still exactly one LISTENING socket: the ::1 reservation does not listen")
        self.assertEqual(bind_errno(socket.AF_INET6, ("::1", port)), errno.EADDRINUSE, "::1:<port> is netd's")
        self.assertEqual(bind_errno(socket.AF_INET6, ("::1", port), reuse=True), errno.EADDRINUSE,
                         "even with SO_REUSEADDR+SO_REUSEPORT: netd's reservation set neither")
        netd.proc.stdin.close()
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        self.assertEqual((bind_errno(socket.AF_INET, ("127.0.0.1", port)), bind_errno(socket.AF_INET6, ("::1", port))),
                         (0, 0), "after EOF both families are free")

    def test_test_port_is_honoured_and_sigterm_frees_both_families(self):
        port = free_port()
        netd = DarwinNetd(self, "--test-port", str(port))
        self.assertEqual(netd.ready_port(), port, "the exact port the seam named")
        self.assertEqual(bind_errno(socket.AF_INET6, ("::1", port)), errno.EADDRINUSE)
        netd.proc.send_signal(signal.SIGTERM)
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        self.assertEqual((bind_errno(socket.AF_INET, ("127.0.0.1", port)), bind_errno(socket.AF_INET6, ("::1", port))),
                         (0, 0))


class TestPortGrammar(unittest.TestCase):
    def run_netd(self, platform_launch, *extra):
        """(exit code, stdout); a refusal must name --test-port and must not be "unknown argument"."""
        proc = subprocess.run([sys.executable, "-c", platform_launch, *extra], capture_output=True, text=True,
                              env=child_env(), input="", timeout=20)
        if proc.returncode == 2:
            self.assertIn("--test-port", proc.stderr)
            self.assertNotIn("unknown argument", proc.stderr, "refused by the seam's own rule, not as unknown")
        return proc.returncode, proc.stdout

    def test_bad_spellings_and_repeats_are_refused(self):
        for value in ("0", "65536", "-1", "+80", "080", " 80", "80 ", "", "8٠", "x"):
            with self.subTest(value=value):
                self.assertEqual(self.run_netd(LAUNCH, "--test-port", value), (2, ""))
        self.assertEqual(self.run_netd(LAUNCH, "--test-port", "40001", "--test-port", "40002"), (2, ""))

    def test_linux_refuses_test_port(self):
        linux = LAUNCH.replace("netd.PLATFORM = 'darwin'", "netd.PLATFORM = 'linux'")
        self.assertNotEqual(linux, LAUNCH)
        code, out = self.run_netd(linux, "--sockdir", "/nonexistent-zb/s", "--test-port", "40001")
        self.assertEqual((code, out), (2, ""))


if __name__ == "__main__":
    unittest.main()
