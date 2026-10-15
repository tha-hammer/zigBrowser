"""MS0 (macOS launch plan, rev 6 ed13e5e): the shared ``SandboxBackend`` seam.

MS0 extracts the Linux sandbox policy/argv behind a ``SandboxBackend`` protocol with a
``LinuxBwrapBackend`` implementation, **behavior-preserving**, so macOS Seatbelt can later
satisfy the same contract. Per the orchestrator's decision MS0 lands **after** the chat-drawer
S3n1/S3n2 network slices, so it refactors the finished bwrap + netns/proxy/bridge code rather
than racing it — and so the seam must also carry the **network capability** that S3n introduced.

This is the failing-first contract test. It is RED today (no ``SandboxBackend``/``LinuxBwrapBackend``
exist yet) and stays red until MS0 implements the seam. It asserts two things:

1. **Behavior preservation (golden oracle).** ``LinuxBwrapBackend`` reproduces the current
   production ``sandbox.helper_argv`` / ``launch.build_argv`` output exactly. Comparing against the
   live production functions (not a frozen string) keeps the golden correct across whatever S3n2
   adds to the argv (``--unshare-net``, the ``/run/zb-net`` binds), because after S3n2 the backend
   must still equal those same functions.

2. **The network capability is BACKEND-SUPPLIED (rev 16.2 §3c).** The egress *endpoint* and the
   bridge *policy* come from the backend, not the caller — the whole point of the shared seam, so
   macOS can supply an ephemeral host-loopback proxy + per-process Seatbelt port rules while Linux
   supplies private-netns fixed ports + relays (plan MS0 launch spec / MS6 egress mapping):
     * ``egress_endpoint`` is a loopback ``host:port`` the CLI/helper reach, named by
       ``HTTPS_PROXY`` (the CLI rejects Unix-socket proxy URLs, BlueBeaver 5503);
     * ``bridge_policy`` is exactly ports 51091 and 31337;
     * **hooks get bridges only, never egress** (rev 16.2 §3c.2b/§3c.8b) — the hook spec seals the
       network to the two bridges with no proxy endpoint and no API path.

Run (after MS0 lands):
    cd agent/host/tests && python3 -m unittest -v test_backend_contract
"""

import sys
import tempfile
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import options, sandbox  # noqa: E402

try:  # launch.py is the chat-drawer launch command MS0 also refactors.
    from zb_agent_host import launch  # noqa: E402
except Exception:  # noqa: BLE001 - absence is just one fewer golden to check
    launch = None

BRIDGE_PORTS = (51091, 31337)


def _backend():
    """Return a LinuxBwrapBackend instance, or fail with a clear MS0 message (red-for-reason)."""
    cls = getattr(sandbox, "LinuxBwrapBackend", None)
    if cls is None:
        raise AssertionError(
            "MS0 not implemented: sandbox.LinuxBwrapBackend is missing. The SandboxBackend seam "
            "has not been extracted yet (expected after S3n1/S3n2 land)."
        )
    return cls()


class SandboxBackendSeamExists(unittest.TestCase):
    def test_protocol_and_linux_impl_present(self):
        self.assertTrue(
            hasattr(sandbox, "SandboxBackend"),
            "MS0: sandbox.SandboxBackend protocol must exist (the shared seam Linux and macOS satisfy)",
        )
        self.assertTrue(
            hasattr(sandbox, "LinuxBwrapBackend"),
            "MS0: sandbox.LinuxBwrapBackend must exist (the behavior-preserving Linux implementation)",
        )


class BehaviorPreservingArgv(unittest.TestCase):
    """The Linux backend reproduces today's production argv byte-for-byte (oracle property)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.home = options.AgentHome(root)
        # Lay the home out the way `--agent-setup` leaves it, so helper_argv's
        # DEFAULT path (claude_writable=False) walks its state-dir checks without
        # raising SandboxError. Built from the live sandbox.STATE_DIRS so it can
        # never drift (mirrors tests/support.lay_out_state + test_unit.SandboxArgv).
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (root / d).mkdir(parents=True, exist_ok=True)
        for base in (root / "state", root / ".claude"):
            base.mkdir(parents=True, exist_ok=True)
            for name in ("backups", *sandbox.STATE_DIRS):
                (base / name).mkdir(mode=0o700, exist_ok=True)
            (base / ".claude.json").write_text("{}\n")

    def tearDown(self):
        self._tmp.cleanup()

    def test_helper_launch_spec_equals_helper_argv(self):
        backend = _backend()
        spec = backend.launch_spec(self.home)  # the macOS-portable entry point
        golden = sandbox.helper_argv(self.home)
        self.assertEqual(
            list(getattr(spec, "argv", spec)),
            list(golden),
            "MS0: LinuxBwrapBackend.launch_spec(home).argv must equal sandbox.helper_argv(home) "
            "exactly — the refactor is behavior-preserving (golden oracle).",
        )

    def test_launch_spec_reproduces_the_network_argv(self):
        """The S3n network binds (--unshare-net + the egress/bridges binds) match too."""
        backend = _backend()
        net_dir = Path(self._tmp.name) / "zb-net"
        for sub in ("egress", "bridges"):
            (net_dir / sub).mkdir(parents=True, exist_ok=True)
        spec = backend.launch_spec(self.home, net_dir=str(net_dir))
        golden = sandbox.helper_argv(self.home, net_dir=str(net_dir))
        self.assertEqual(
            list(getattr(spec, "argv", spec)),
            list(golden),
            "MS0: the backend must reproduce the net_dir argv (the --unshare-net + egress/bridges "
            "binds) byte-for-byte too — the S3n network sandbox is part of the preserved behavior.",
        )
        self.assertIn("--unshare-net", list(golden), "MS0: a net_dir launch must unshare the network")

    def test_launch_build_argv_still_reproduced(self):
        if launch is None or not hasattr(launch, "build_argv"):
            self.skipTest("launch.build_argv not present in this tree")
        # Once MS0 routes launch.build_argv through the backend, the produced argv must be
        # unchanged for the same (home, seccomp_fd, python, bwrap).
        backend = _backend()
        self.assertTrue(
            hasattr(backend, "launch_spec"),
            "MS0: the backend must own the launch argv that launch.build_argv delegates to",
        )


class NetworkCapabilityIsBackendSupplied(unittest.TestCase):
    """rev 16.2 §3c: the egress endpoint and bridge policy are the backend's to supply."""

    def test_egress_endpoint_backend_supplied(self):
        backend = _backend()
        self.assertTrue(
            hasattr(backend, "egress_endpoint"),
            "MS0: the backend must supply the egress endpoint (Linux: private-netns fixed proxy "
            "port + relay; macOS: ephemeral host-loopback 127.0.0.1:<port>). The CLI rejects "
            "Unix-socket proxy URLs (BlueBeaver 5503), so it is a loopback host:port.",
        )
        ep = backend.egress_endpoint(session="test-session")
        host = getattr(ep, "host", None)
        port = getattr(ep, "port", None)
        self.assertEqual(host, "127.0.0.1", "MS0: egress endpoint must be loopback")
        self.assertIsInstance(port, int, "MS0: egress endpoint must carry a concrete port")
        self.assertTrue(0 < port < 65536, "MS0: egress endpoint port must be a real TCP port")

    def test_bridge_policy_is_the_two_named_ports(self):
        backend = _backend()
        self.assertTrue(hasattr(backend, "bridge_policy"), "MS0: the backend must supply the bridge policy")
        policy = backend.bridge_policy()
        self.assertEqual(
            tuple(getattr(policy, "ports", ())),
            BRIDGE_PORTS,
            "MS0: the bridge policy must be exactly ports 51091 and 31337 (rev 16.2 §3c)",
        )

    def test_hooks_get_bridges_only_never_egress(self):
        backend = _backend()
        policy = backend.bridge_policy()
        self.assertFalse(
            getattr(policy, "hooks_get_egress", True),
            "MS0: hooks must get the two bridges ONLY, never the egress proxy or an API path "
            "(rev 16.2 §3c.2b/§3c.8b) — each hook's view is bridges-only.",
        )
        self.assertTrue(
            hasattr(backend, "hook_launch_spec"),
            "MS0: the backend must supply a hook launch spec that seals the hook's network to the "
            "two bridges only (Linux: nested --unshare-net + bind only bridges/; macOS: a hook "
            "Seatbelt profile permitting only loopback 51091/31337).",
        )


if __name__ == "__main__":
    unittest.main()
