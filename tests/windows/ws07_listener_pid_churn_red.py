#!/usr/bin/env python3
"""WS0.7 listener PID-ownership — RED (UNREGISTERED until green). bead zigBrowser-bdq.

Today validate_probes compares the file server's `listeners` as a strict full SET of int ports
(commit 9a203eb): ANY difference pre vs post fails. That is safe but trips on genuine OS dynamic-port
churn (a service rebinding an ephemeral RPC port >= 49152 between the pre and post probe).

The design (thoughts/.../2026-10-20-ws07-file-server-field-design.md; bead bdq): host_probe emits
`listeners` as typed `{port, pid}`; the gate tolerates a POST-ONLY port IFF its pid already owned a
PRE listener AND port >= 49152 (benign ephemeral churn by the same process); ANY new-pid listener, a
dropped listener, or a service-port (< 49152) change still fails closed.

This file is intentionally NOT registered in build.zig (a red must stay outside gate-registered steps);
the green commit that implements host_probe pid emission + the gate tolerance registers it and proves
the mutants. It drives gate.sh against the same hostless fake ssh/virsh as gate_twohost_selftest.

Run alone:  python3 -I tests/windows/ws07_listener_pid_churn_red.py -v
"""
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gate_twohost_selftest import _TwoHostCase, _fs_probe  # reuse the hostless two-host harness


def _typed(listeners):
    """A file-server probe whose `listeners` are typed {port, pid} objects (the new schema)."""
    return _fs_probe(listeners=listeners)


# A stable baseline: ssh/rpc/smb service ports owned by real services, plus one ephemeral RPC port.
_PRE = [{"port": 22, "pid": 4}, {"port": 135, "pid": 900}, {"port": 139, "pid": 4},
        {"port": 445, "pid": 4}, {"port": 49664, "pid": 900}]


class WS07ListenerPidChurn(_TwoHostCase):
    def test_benign_ephemeral_churn_same_pid_is_tolerated(self):
        # pid 900 drops its ephemeral 49664 and rebinds 49700 — same owning process, both >= 49152.
        post = [{"port": 22, "pid": 4}, {"port": 135, "pid": 900}, {"port": 139, "pid": 4},
                {"port": 445, "pid": 4}, {"port": 49700, "pid": 900}]
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _typed(_PRE), "ZB_SELFTEST_PROBE_WIN10_POST": _typed(post)})
            self.assertEqual(proc.returncode, 0,
                             "benign ephemeral churn by the same pid must be tolerated\n%s\n%s"
                             % (proc.stdout, proc.stderr))

    def test_new_pid_listener_fails_closed(self):
        # A brand-new listener owned by a pid that held NO pre listener is a disturbance.
        post = _PRE + [{"port": 50001, "pid": 1234}]
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _typed(_PRE), "ZB_SELFTEST_PROBE_WIN10_POST": _typed(post)})
            self.assertNotEqual(proc.returncode, 0, "a new-pid listener must fail closed")

    def test_service_port_change_fails_closed(self):
        # A changed SERVICE port (< 49152) is never benign churn, even by a known pid.
        post = [{"port": 22, "pid": 4}, {"port": 135, "pid": 900}, {"port": 139, "pid": 4},
                {"port": 445, "pid": 4}, {"port": 8080, "pid": 900}, {"port": 49664, "pid": 900}]
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _typed(_PRE), "ZB_SELFTEST_PROBE_WIN10_POST": _typed(post)})
            self.assertNotEqual(proc.returncode, 0, "a service-port (<49152) change must fail closed")

    def test_dropped_listener_fails_closed(self):
        # Losing a pre listener is a disturbance too (not just additions).
        post = [{"port": 22, "pid": 4}, {"port": 135, "pid": 900}, {"port": 139, "pid": 4},
                {"port": 445, "pid": 4}]  # dropped 49664
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _typed(_PRE), "ZB_SELFTEST_PROBE_WIN10_POST": _typed(post)})
            self.assertNotEqual(proc.returncode, 0, "a dropped listener must fail closed")


if __name__ == "__main__":
    unittest.main()
