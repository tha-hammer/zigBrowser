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
- the live reservation itself (read from netd's own fd with pidfd_getfd; RoseCat 7097) is exactly one AF_INET6
  SOCK_STREAM socket on [::1]:<port> with IPV6_V6ONLY 1, SO_ACCEPTCONN 0, SO_REUSEADDR 0, SO_REUSEPORT 0, close-on-exec;
- `--test-port` (the e2e seam; the app passes --test-* only under --e2e-protocol) is Darwin-only and exact: ASCII
  decimal 1-65535, no sign, leading zero or whitespace, given once.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_netd_darwin_v6. Unregistered until the
green.
"""
import ctypes
import errno
import json
import os
import signal
import tempfile
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


def held_v6_reservations(pid, port):
    """The live netd's own [::1]:<port> sockets, duplicated into this process with pidfd_getfd (Linux 5.6+) so the
    production socket's options are read directly (RoseCat 7097): [(socket, close-on-exec), ...]."""
    libc = ctypes.CDLL(None, use_errno=True)
    pidfd = libc.syscall(434, pid, 0)  # pidfd_open
    if pidfd < 0:
        raise OSError(ctypes.get_errno(), "pidfd_open")
    found = []
    try:
        for name in os.listdir(f"/proc/{pid}/fd"):
            try:
                if not os.readlink(f"/proc/{pid}/fd/{name}").startswith("socket:"):
                    continue
            except OSError:
                continue
            dup = libc.syscall(438, pidfd, int(name), 0)  # pidfd_getfd
            if dup < 0:
                raise OSError(ctypes.get_errno(), "pidfd_getfd")
            s = socket.socket(fileno=dup)
            if s.family == socket.AF_INET6 and s.getsockname()[:2] == ("::1", port):
                with open(f"/proc/{pid}/fdinfo/{name}") as f:
                    flags = int(next(l for l in f if l.startswith("flags:")).split()[1], 8)
                found.append((s, bool(flags & 0o2000000)))
            else:
                s.close()
    finally:
        os.close(pidfd)
    return found


@unittest.skipUnless(socket.has_ipv6 and sys.platform == "linux", "reads the live socket with pidfd_getfd")
class ReservationShape(unittest.TestCase):
    def test_the_reservation_is_exactly_v6only_bound_non_listening_no_reuse_cloexec(self):
        # Two views. The kernel's, read from netd's own fd: bound, never listening, no reuse flags, close-on-exec.
        # And what netd ASKED for, recorded by a socket subclass in netd's process: Linux forces IPV6_V6ONLY on any
        # socket bound to a specific v6 address such as ::1, so the kernel read alone cannot show that netd sets it
        # (the contract requires the explicit request; on macOS the default is 0).
        log = os.path.join(tempfile.mkdtemp(prefix="zbn-v6shape-"), "calls.json")
        self.addCleanup(lambda: (os.path.exists(log) and os.unlink(log), os.rmdir(os.path.dirname(log))))
        launch = (
            "import json, socket, sys\n"
            "from zb_agent_host import netd\n"
            "calls = []\n"
            "class Recording(socket.socket):\n"
            "    def setsockopt(self, *a):\n"
            "        calls.append([int(self.family), [int(x) for x in a]])\n"
            "        return super().setsockopt(*a)\n"
            "netd.socket.socket = Recording\n"
            "netd.PLATFORM = 'darwin'\n"
            "try:\n"
            "    rc = netd.main(sys.argv[1:])\n"
            "finally:\n"
            f"    open({log!r}, 'w').write(json.dumps(calls))\n"
            "sys.exit(rc)\n")
        netd = DarwinNetd(self, launch=launch)
        port = netd.ready_port()
        held = held_v6_reservations(netd.proc.pid, port)
        try:
            self.assertEqual(len(held), 1, "exactly one [::1]:<port> socket")
            (s, cloexec), = held
            self.assertEqual(s.type, socket.SOCK_STREAM)
            self.assertEqual(s.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY), 1, "IPV6_V6ONLY")
            self.assertEqual(s.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN), 0, "never listening")
            self.assertEqual(s.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR), 0, "no SO_REUSEADDR")
            self.assertEqual(s.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT), 0, "no SO_REUSEPORT")
            self.assertTrue(cloexec, "close-on-exec: never inherited")
        finally:
            for s, _ in held:
                s.close()
        netd.proc.stdin.close()
        self.assertEqual(netd.proc.wait(timeout=10), 0)
        with open(log) as f:
            calls = json.load(f)
        v6 = [opts for family, opts in calls if family == socket.AF_INET6]
        self.assertIn([socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1], v6, "netd explicitly requests IPV6_V6ONLY")
        self.assertFalse([o for o in v6 if o[:2] in ([socket.SOL_SOCKET, socket.SO_REUSEADDR],
                                                     [socket.SOL_SOCKET, socket.SO_REUSEPORT])],
                         f"and never a reuse flag on it ({v6})")


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
