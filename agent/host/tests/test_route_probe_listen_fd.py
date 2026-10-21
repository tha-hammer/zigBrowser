"""R1 under Seatbelt, the probe's half (RoseCat 6958; the split in BlueBeaver 6961; BlackRobin 6975's conditions),
on Linux with the platform injected (`route_probe.PLATFORM`):

- On macOS there is no private network namespace, so setup's profile permits exactly one loopback port. Setup binds
  127.0.0.1:<port> OUTSIDE the sandbox and hands the listening socket in: `probe-r1 --listen-fd N --listen-port P`.
- The probe adopts fd N only after checking it: AF_INET, SOCK_STREAM, listening (SO_ACCEPTCONN), and getsockname()
  == ("127.0.0.1", P). Anything else is refused, each for its own reason ("IPv4 stream", "not listening",
  "127.0.0.1:<P>", "not a socket"): the fd is closed, exit 2, nothing on stdout, so R1 fails closed.
- The adopted listener is made non-inheritable: the CLI the SDK spawns must never hold it (BlackRobin 6983).
- The probe server then serves on that socket (it binds nothing of its own), with server_name/server_port set as
  HTTPServer.server_bind would set them.
- Off Darwin both flags are refused and nothing runs; on Darwin both are required, each exactly once, decimal with no
  sign, leading zero or whitespace, fd > 2 and port 1-65535 (RoseCat 6985). Linux is otherwise unchanged.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_route_probe_listen_fd.
Unregistered until the green.
"""
import contextlib
import io
import json
import os
import socket
import unittest
import urllib.request
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import route_probe


def _closed(fd):
    try:
        os.fstat(fd)
    except OSError:
        return True
    return False


def _listener(family=socket.AF_INET, kind=socket.SOCK_STREAM, addr=("127.0.0.1", 0), listen=True):
    """A raw fd the test owns (detached, so no socket object closes it a second time) and its port. Inheritable,
    as an fd that came in through pass_fds is."""
    s = socket.socket(family, kind)
    s.set_inheritable(True)
    s.bind(addr)
    if listen:
        s.listen(4)
    port = s.getsockname()[1] if family in (socket.AF_INET, socket.AF_INET6) else 0
    return s.detach(), port


class Base(unittest.TestCase):
    def setUp(self):
        if not hasattr(route_probe, "PLATFORM"):
            self.fail("route_probe.PLATFORM (the injected platform) is missing (6961/6975)")
        for name in ("adopt_listener", "ProbeRefused"):
            if not hasattr(route_probe, name):
                self.fail(f"route_probe.{name} is missing (6961/6975)")
        self.addCleanup(mock.patch.stopall)
        self.fds = []
        self.addCleanup(self._close_fds)

    def _close_fds(self):
        for fd in self.fds:
            with contextlib.suppress(OSError):
                os.close(fd)

    def own(self, fd):
        self.fds.append(fd)
        return fd


class AdoptListener(Base):
    def test_a_loopback_listener_on_the_passed_port_is_adopted(self):
        fd, port = _listener()
        self.own(fd)
        sock = route_probe.adopt_listener(fd, port)
        self.addCleanup(sock.close)
        self.fds.remove(fd)  # the socket owns it now
        self.assertEqual(sock.fileno(), fd)
        self.assertEqual(sock.getsockname(), ("127.0.0.1", port))
        self.assertFalse(os.get_inheritable(fd), "the CLI the SDK spawns must never inherit the listener (6983)")

    def assert_refused(self, fd, port, why, reason):
        with self.assertRaises(route_probe.ProbeRefused, msg=why) as cm:
            route_probe.adopt_listener(fd, port)
        self.assertIn(reason, str(cm.exception), f"{why}: refused for its own reason")
        self.assertTrue(_closed(fd), f"{why}: a refused fd is closed")

    def test_every_wrong_shape_is_refused_and_closed(self):
        cases = []
        fd, port = _listener(kind=socket.SOCK_DGRAM, listen=False)
        cases.append((fd, port, "a UDP socket", "IPv4 stream"))
        fd, port = _listener(listen=False)
        cases.append((fd, port, "bound but not listening", "not listening"))
        fd, port = _listener(addr=("0.0.0.0", 0))
        cases.append((fd, port, "listening on 0.0.0.0, not 127.0.0.1", f"127.0.0.1:{port}"))
        fd, port = _listener()
        other = port + 1 if port < 65535 else port - 1
        cases.append((fd, other, "a port other than the one setup passed", f"127.0.0.1:{other}"))
        if socket.has_ipv6:
            with contextlib.suppress(OSError):
                fd, port = _listener(family=socket.AF_INET6, addr=("::1", 0))
                cases.append((fd, port, "an AF_INET6 listener", "IPv4 stream"))
        u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        u.bind("\0zb-route-probe-test-%d" % os.getpid())
        u.listen(1)
        cases.append((u.detach(), 1, "an AF_UNIX listener", "IPv4 stream"))
        r, w = os.pipe()
        self.own(w)
        cases.append((r, 1, "a pipe, not a socket", "not a socket"))
        for fd, port, why, reason in cases:
            self.own(fd)
            with self.subTest(why=why):
                self.assert_refused(fd, port, why, reason)

    def test_a_closed_fd_is_refused(self):
        fd, port = _listener()
        os.close(fd)
        with self.assertRaises(route_probe.ProbeRefused):
            route_probe.adopt_listener(fd, port)


class ProbeServerOnTheAdoptedSocket(Base):
    def test_the_probe_server_serves_on_the_adopted_socket(self):
        fd, port = _listener()
        self.own(fd)
        sock = route_probe.adopt_listener(fd, port)
        self.fds.remove(fd)
        server = route_probe._ProbeServer("zb-probe-x", "/nonexistent-cli", listener=sock)
        self.addCleanup(server.close)
        self.assertEqual(server.url, f"http://127.0.0.1:{port}")
        own = route_probe._ProbeServer("zb-probe-y", "/nonexistent-cli")
        self.addCleanup(own.close)
        self.assertEqual((server.httpd.server_name, server.httpd.server_port), (own.httpd.server_name, port),
                         "server_name/server_port as server_bind would set them (6983)")
        req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/messages", data=b"{}", method="POST",
                                     headers={"content-type": "application/json", "authorization": "Bearer b"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(json.loads(resp.read()), {"type": "message", "content": []})
        self.assertEqual(server.bearer, "Bearer b")


class Main(Base):
    def setUp(self):
        super().setUp()
        self.runs = []

        def fake_run(wrapper, cli, listener=None, census=None):
            self.runs.append((str(wrapper), cli, None if listener is None else listener.getsockname()))
            if listener is not None:
                listener.close()
            if census is not None:  # adopted, then closed here: the test no longer owns that fd number
                fd = census.fileno()
                census.close()
                if fd in self.fds:
                    self.fds.remove(fd)
            return True

        mock.patch.object(route_probe, "run", side_effect=fake_run).start()

    def main(self, platform, extra=()):
        if platform == "darwin" and "--census-fd" not in extra:
            # A valid census end (BlueBeaver 7021), so these cases test only the listener flags.
            a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(b.close)
            extra = [*extra, "--census-fd", str(self.own(a.detach()))]
        mock.patch.object(route_probe, "PLATFORM", platform).start()
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = route_probe.main(["--wrapper", "/w/zb-claude", "--cli", "/c/claude", *extra])
        return code, out.getvalue(), err.getvalue()

    def test_linux_is_unchanged(self):
        code, out, err = self.main("linux")
        self.assertEqual((code, json.loads(out)), (0, {"r1": True}), err)
        self.assertEqual(self.runs, [("/w/zb-claude", "/c/claude", None)])

    def test_linux_refuses_the_listen_flags_and_runs_nothing(self):
        fd, port = _listener()
        self.own(fd)
        for extra in (["--listen-fd", str(fd), "--listen-port", str(port)], ["--listen-fd", str(fd)],
                      ["--listen-port", str(port)]):
            with self.subTest(extra=extra):
                code, out, err = self.main("linux", extra)
                self.assertEqual((code, out), (2, ""), err)
                self.assertIn("--listen-", err)
                self.assertEqual(self.runs, [])

    def test_darwin_requires_both_flags(self):
        fd, port = _listener()
        self.own(fd)
        for extra in ([], ["--listen-fd", str(fd)], ["--listen-port", str(port)],
                      ["--listen-fd", "x", "--listen-port", str(port)], ["--listen-fd", str(fd), "--listen-port", "0"]):
            with self.subTest(extra=extra):
                code, out, err = self.main("darwin", extra)
                self.assertEqual((code, out), (2, ""), err)
                self.assertEqual(self.runs, [])

    def test_darwin_flag_grammar_is_exact(self):
        # RoseCat 6985: decimal only, no sign, no leading zero, no whitespace, fd > 2, port 1-65535, each flag once.
        # Every bad spelling exits 2 with no verdict and reaches neither adopt_listener nor run.
        adopted = []
        mock.patch.object(route_probe, "adopt_listener", side_effect=lambda fd, port: adopted.append(fd)).start()
        big = "9" * 30
        bad_fds = ["0", "1", "2", "-1", "+3", "03", " 3", "3 ", "3\n", "2147483648", "9999999999", big, "", "\u0663"]
        bad_ports = ["0", "-1", "+1", "01", "65536", " 80", "80 ", big, "", "\u0668\u0660"]
        cases = [["--listen-fd", fd, "--listen-port", "8080"] for fd in bad_fds]
        cases += [["--listen-fd", "3", "--listen-port", port] for port in bad_ports]
        cases += [["--listen-fd", "3", "--listen-fd", "4", "--listen-port", "8080"],
                  ["--listen-fd", "3", "--listen-port", "8080", "--listen-port", "8081"]]
        for extra in cases:
            with self.subTest(extra=extra):
                adopted.clear()
                self.runs.clear()
                code, out, err = self.main("darwin", extra)
                self.assertEqual((code, out), (2, ""), err)
                self.assertEqual((adopted, self.runs), ([], []))

    def test_darwin_refuses_a_wrong_listener_and_prints_no_verdict(self):
        fd, port = _listener(addr=("0.0.0.0", 0))
        self.own(fd)
        code, out, err = self.main("darwin", ["--listen-fd", str(fd), "--listen-port", str(port)])
        self.assertEqual((code, out), (2, ""), err)
        self.assertEqual(self.runs, [])
        self.assertTrue(_closed(fd))

    def test_darwin_runs_the_probe_on_the_adopted_listener(self):
        fd, port = _listener()
        self.own(fd)
        code, out, err = self.main("darwin", ["--listen-fd", str(fd), "--listen-port", str(port)])
        self.fds.remove(fd)  # adopted, then closed by fake_run
        self.assertEqual((code, json.loads(out)), (0, {"r1": True}), err)
        self.assertEqual(self.runs, [("/w/zb-claude", "/c/claude", ("127.0.0.1", port))])


if __name__ == "__main__":
    unittest.main()
