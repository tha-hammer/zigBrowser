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
The fallback itself (RoseCat's choice) is the green's; an early connection it might accept is closed and refused,
never served (the orchestrator, after db1f05b).

Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_route_probe_darwin_listen.
Unregistered until the green.
"""
import errno
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


class MainWithoutAcceptConn(listen_fd.Main):
    """Every Main case again, with SO_ACCEPTCONN unreadable as on Darwin."""

    def setUp(self):
        super().setUp()
        _no_acceptconn(self)


if __name__ == "__main__":
    unittest.main()
