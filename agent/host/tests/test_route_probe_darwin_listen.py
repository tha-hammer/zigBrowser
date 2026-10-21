"""The probe's listening check where getsockopt(SO_ACCEPTCONN) is unsupported (db1f05b, both Macs: the sandboxed probe
died in adopt_listener with "OSError: [Errno 42] Protocol not available" before any CLI ran; Darwin does not let
getsockopt read SO_ACCEPTCONN).

On Linux, with that getsockopt made to fail exactly as Darwin's does (ENOPROTOOPT, for SO_ACCEPTCONN only):
- adopt_listener falls back to another listening check: a loopback listener on the passed port is still adopted
  (non-inheritable), and EVERY wrong shape of test_route_probe_listen_fd is still refused for its own reason, a bound
  but not listening socket included ("not listening"), and closed;
- adopt_listener never lets an OSError out of the listening check: any failure there is ProbeRefused (exit 2, nothing
  on stdout), never a traceback and rc 1 as on the Macs;
- main on Darwin runs the probe on the adopted listener (exit 0, {"r1": true}), and the whole Main suite of
  test_route_probe_listen_fd holds unchanged.
The fallback (RoseCat 7387): only when that getsockopt raises ENOPROTOOPT, and only after the exact address check, a
non-blocking accept() under the fd's own status flags (F_GETFL saved, F_SETFL old|O_NONBLOCK, then EXACTLY the old
flags restored: the open file description is shared with setup's descriptor):
- an empty queue (EAGAIN) is listening: adopted, its flags exactly as before (a listener that was already
  non-blocking stays so);
- EINVAL is "not listening": refused and closed;
- an accepted connection (a client before the CLI exists) is closed at once, never served, and the listener refused;
- any other getsockopt error, any other accept/fcntl error and a failed restoration each refuse and close.

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_route_probe_darwin_listen.
Unregistered until the green.
"""
import errno
import fcntl
import os
import socket
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)
import test_route_probe_listen_fd as listen_fd

from zb_agent_host import route_probe

_REAL_GETSOCKOPT = socket.socket.getsockopt


def _darwin_getsockopt(self, level, option, *rest):
    if level == socket.SOL_SOCKET and option == socket.SO_ACCEPTCONN:
        raise OSError(errno.ENOPROTOOPT, "Protocol not available")
    return _REAL_GETSOCKOPT(self, level, option, *rest)


def _no_acceptconn(test):
    mock.patch.object(socket.socket, "getsockopt", _darwin_getsockopt).start()
    test.addCleanup(mock.patch.stopall)


class AdoptListenerWithoutAcceptConn(listen_fd.AdoptListener):
    """Every AdoptListener case again, with SO_ACCEPTCONN unreadable as on Darwin."""

    def setUp(self):
        super().setUp()
        _no_acceptconn(self)

    def test_the_patch_is_darwins_failure(self):
        s = socket.socket()
        self.addCleanup(s.close)
        with self.assertRaises(OSError) as cm:
            s.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)
        self.assertEqual(cm.exception.errno, errno.ENOPROTOOPT)

    def test_no_oserror_escapes_the_listening_check(self):
        fd, port = listen_fd._listener(listen=False)
        self.own(fd)
        try:
            route_probe.adopt_listener(fd, port)
        except route_probe.ProbeRefused:
            pass
        except OSError as exc:  # db1f05b: a traceback and rc 1 instead of a refusal
            self.fail(f"adopt_listener let an OSError out: {exc!r}")
        else:
            self.fail("a bound but not listening socket was adopted")


class AcceptFallback(listen_fd.Base):
    """RoseCat 7387's focused rows for the non-blocking accept() fallback."""

    def setUp(self):
        super().setUp()
        _no_acceptconn(self)

    def adopt(self, fd, port):
        sock = route_probe.adopt_listener(fd, port)
        self.addCleanup(sock.close)
        self.fds.remove(fd)
        return sock

    def refused(self, fd, port, reason):
        with self.assertRaises(route_probe.ProbeRefused) as cm:
            route_probe.adopt_listener(fd, port)
        self.assertIn(reason, str(cm.exception))
        self.assertTrue(listen_fd._closed(fd), "a refused listener is closed")

    def test_an_empty_listening_queue_is_adopted_with_its_flags_unchanged(self):
        fd, port = listen_fd._listener()
        self.own(fd)
        before = fcntl.fcntl(fd, fcntl.F_GETFL)
        self.assertFalse(before & os.O_NONBLOCK)
        sock = self.adopt(fd, port)
        self.assertEqual(fcntl.fcntl(sock.fileno(), fcntl.F_GETFL), before, "exactly the old flags")

    def test_an_already_non_blocking_listener_keeps_its_flags(self):
        fd, port = listen_fd._listener()
        self.own(fd)
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        before = fcntl.fcntl(fd, fcntl.F_GETFL)
        sock = self.adopt(fd, port)
        self.assertEqual(fcntl.fcntl(sock.fileno(), fcntl.F_GETFL), before, "restored exactly, not set blocking")

    def test_bound_but_not_listening_is_refused(self):
        fd, port = listen_fd._listener(listen=False)
        self.own(fd)
        self.refused(fd, port, "not listening")

    def test_a_queued_client_is_closed_unserved_and_the_listener_refused(self):
        fd, port = listen_fd._listener()
        self.own(fd)
        client = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.addCleanup(client.close)
        client.sendall(b"POST /v1/messages HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
        self.refused(fd, port, "early connection")
        try:
            got = client.recv(4096)
        except ConnectionResetError:
            got = b""
        self.assertEqual(got, b"", "nothing is ever served to an early client")

    def test_any_other_getsockopt_error_refuses(self):
        def eio(self_, level, option, *rest):
            if option == socket.SO_ACCEPTCONN:
                raise OSError(errno.EIO, "Input/output error")
            return _REAL_GETSOCKOPT(self_, level, option, *rest)

        mock.patch.object(socket.socket, "getsockopt", eio).start()
        fd, port = listen_fd._listener()
        self.own(fd)
        self.refused(fd, port, "listening state")

    def test_a_failed_flag_read_or_restoration_refuses(self):
        real = fcntl.fcntl
        for label, fail_at in (("F_GETFL", 1), ("F_SETFL non-blocking", 2), ("the restoration", 3)):
            with self.subTest(fails=label):
                calls = []

                def flaky(fd, cmd, *rest):
                    calls.append(cmd)
                    if len(calls) == fail_at:
                        raise OSError(errno.EBADF, "Bad file descriptor")
                    return real(fd, cmd, *rest)

                fd, port = listen_fd._listener()
                self.own(fd)
                with mock.patch.object(fcntl, "fcntl", side_effect=flaky):  # route_probe imports fcntl lazily
                    self.refused(fd, port, "listen fd")

    def test_the_address_is_checked_before_any_accept(self):
        fd, port = listen_fd._listener(addr=("0.0.0.0", 0))
        self.own(fd)
        with mock.patch.object(socket.socket, "accept", side_effect=AssertionError("accept() on an off-target fd")):
            self.refused(fd, port, f"127.0.0.1:{port}")


class MainWithoutAcceptConn(listen_fd.Main):
    """Every Main case again, with SO_ACCEPTCONN unreadable as on Darwin."""

    def setUp(self):
        super().setUp()
        _no_acceptconn(self)


if __name__ == "__main__":
    unittest.main()
