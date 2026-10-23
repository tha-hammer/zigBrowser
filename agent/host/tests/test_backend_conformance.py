"""bd zigBrowser-4pa.22 (plan R29-MS6 I1; SilverRidge 6fde992b ruling): LinuxBwrapBackend and MacSeatbeltBackend
both conform to the ``SandboxBackend`` Protocol.

Red 8939353b (SilverRidge 03fe3c09). Registered: ``zig build test-agent-backend-conformance``, in aggregate ``test``
(no skip-to-green).

``state_dirs=None`` is the explicit backend-default sentinel, on the Protocol and both backends alike. Linux turns only
``None`` into its frozen ``STATE_DIRS``; macOS turns only ``None`` into ``()``. An explicit ``()`` means "no state
directories" on both, and a custom Linux tuple keeps today's behaviour.

Rows (each its own test; a failure names it):
- S1 signatures: every Protocol member has identical parameter names, kinds and defaults on both backends (a
  TRIPWIRE: the production proof is MS6.8's driven ``launch.build_launch``).
- S2-S5 the named corrections: ``state_dirs=None`` everywhere, ``network(session=None)``, ``launch_spec(..., network=)``
  and ``egress_dir() -> Optional[str]`` (Linux returns a str, macOS None).
- L1-L4 Linux, against the frozen independent reference of test_backend_contract: the default launch; ``None``
  reproduces it; explicit ``()`` omits every state dir; a custom tuple binds exactly those.
- M1-M3 macOS successes: ``None`` and explicit ``()`` (separate rows), and ``ro_paths`` accepted. M3 is a BROAD-state
  TRIPWIRE: today's profile allows every read, so the read really is available; MS6.7 must bind requested reads in
  the curated profile.
- M4-M7 macOS refusals: ``sandbox.UnsupportedLaunchInput`` (a ``SandboxError``) for ``seccomp_fd``, ``net_dir``,
  ``claude_writable=True`` and a nonempty ``state_dirs``, each alone, raised before any profile exists (no
  ``zb-seatbelt-*`` directory is left in the private temp root).
- N1-N2 the ``network=`` sentinel reaches ``LaunchSpec.network`` and the rendered launch on each backend.

Run:
    cd agent/host/tests && python3 -m unittest -v test_backend_conformance
"""

import inspect
import os
import shutil
import sys
import tempfile
import typing
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from zb_agent_host import options, sandbox, sandbox_macos  # noqa: E402
from test_backend_contract import REF_STATE_DIRS, reference_launch  # noqa: E402 - the frozen Linux reference

MAC_PORT = 52346
SENTINEL_PORT = 54321  # a distinctive egress port, so the rendered macOS profile shows which network it got


def protocol_members():
    """The Protocol's own methods, in definition order."""
    return [name for name, value in vars(sandbox.SandboxBackend).items()
            if not name.startswith("_") and inspect.isfunction(value)]


def shape(fn):
    """A method's parameters as (name, kind, default), ignoring annotations."""
    return [(p.name, p.kind, p.default) for p in inspect.signature(fn).parameters.values()]


def lay_out_home(root):
    """The agent home as `--agent-setup` leaves it (as test_backend_contract does)."""
    home = options.AgentHome(root)
    for d in (".claude", "workspace", "scratchpad", "runtime"):
        (root / d).mkdir(parents=True, exist_ok=True)
    for base in (root / "state", root / ".claude"):
        base.mkdir(parents=True, exist_ok=True)
        for name in ("backups", *sandbox.STATE_DIRS):
            (base / name).mkdir(mode=0o700, exist_ok=True)
        (base / ".claude.json").write_text("{}\n")
    return home


class Conformance(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="zb-conformance-")
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.home = lay_out_home(root / "home")
        self.net_dir = root / "zb-net"
        for sub in ("egress", "bridges"):
            (self.net_dir / sub).mkdir(parents=True)
        # A private temp root: every macOS profile directory lands here, so a leak is visible and nothing reaches
        # the shared /tmp.
        self.temp_root = root / "temp"
        self.temp_root.mkdir()
        saved = tempfile.tempdir
        tempfile.tempdir = str(self.temp_root)
        self.addCleanup(setattr, tempfile, "tempdir", saved)
        self.linux = sandbox.LinuxBwrapBackend()
        self.mac = sandbox_macos.MacSeatbeltBackend(egress_port=MAC_PORT)

    def profile_dirs(self):
        return sorted(p.name for p in self.temp_root.iterdir() if p.name.startswith("zb-seatbelt-"))

    def mac_spec(self, **kwargs):
        spec = self.mac.launch_spec(self.home, **kwargs)
        d = os.path.dirname(spec.argv[2])
        self.addCleanup(shutil.rmtree, d, True)
        return spec

    def assert_linux(self, spec, **ref_kwargs):
        argv, unshare, mounts, workdir, seccomp = reference_launch(self.home, **ref_kwargs)
        self.assertEqual(list(spec.argv), argv)
        self.assertEqual([tuple(m) for m in spec.mounts], list(mounts))
        self.assertEqual(tuple(spec.unshare), unshare)

    # --- S: signatures -------------------------------------------------------------------------------------------
    def test_s1_every_protocol_member_has_the_same_parameters_on_both_backends(self):
        members = protocol_members()
        self.assertIn("launch_spec", members)
        for name in members:
            want = shape(getattr(sandbox.SandboxBackend, name))
            for backend in (sandbox.LinuxBwrapBackend, sandbox_macos.MacSeatbeltBackend):
                with self.subTest(member=name, backend=backend.__name__):
                    self.assertTrue(hasattr(backend, name), f"{backend.__name__} lacks {name}")
                    self.assertEqual(shape(getattr(backend, name)), want,
                                     f"S1: {backend.__name__}.{name} differs from SandboxBackend.{name}")

    def test_s2_state_dirs_defaults_to_the_none_sentinel_everywhere(self):
        for cls in (sandbox.SandboxBackend, sandbox.LinuxBwrapBackend, sandbox_macos.MacSeatbeltBackend):
            with self.subTest(cls=cls.__name__):
                self.assertIsNone(inspect.signature(cls.launch_spec).parameters["state_dirs"].default,
                                  f"S2: {cls.__name__}.launch_spec state_dirs must default to None")

    def test_s3_network_takes_an_optional_session_everywhere(self):
        for cls in (sandbox.SandboxBackend, sandbox.LinuxBwrapBackend, sandbox_macos.MacSeatbeltBackend):
            with self.subTest(cls=cls.__name__):
                params = inspect.signature(cls.network).parameters
                self.assertIn("session", params, f"S3: {cls.__name__}.network must take session")
                self.assertIsNone(params["session"].default)

    def test_s4_launch_spec_takes_a_network_everywhere(self):
        for cls in (sandbox.SandboxBackend, sandbox.LinuxBwrapBackend, sandbox_macos.MacSeatbeltBackend):
            with self.subTest(cls=cls.__name__):
                params = inspect.signature(cls.launch_spec).parameters
                self.assertIn("network", params, f"S4: {cls.__name__}.launch_spec must take network=")
                self.assertIsNone(params["network"].default)

    def test_s5_egress_dir_is_optional_str(self):
        hints = typing.get_type_hints(sandbox.SandboxBackend.egress_dir)
        self.assertEqual(hints.get("return"), typing.Optional[str], "S5: SandboxBackend.egress_dir -> Optional[str]")
        self.assertIsInstance(self.linux.egress_dir(), str)
        self.assertIsNone(self.mac.egress_dir())

    # --- L: Linux state dirs against the frozen reference ----------------------------------------------------------
    def test_l1_linux_default_launch_is_the_frozen_reference(self):
        self.assert_linux(self.linux.launch_spec(self.home), state_dirs=REF_STATE_DIRS)

    def test_l2_linux_none_reproduces_the_frozen_default(self):
        try:
            spec = self.linux.launch_spec(self.home, state_dirs=None)
        except TypeError as exc:
            self.fail(f"L2: state_dirs=None is refused ({exc}); it must mean the frozen STATE_DIRS")
        self.assert_linux(spec, state_dirs=REF_STATE_DIRS)

    def test_l3_linux_explicit_empty_omits_every_state_dir(self):
        spec = self.linux.launch_spec(self.home, state_dirs=())
        self.assert_linux(spec, state_dirs=())
        targets = {m.target for m in spec.mounts}
        for name in REF_STATE_DIRS:
            self.assertNotIn(os.path.join(str(self.home.claude_dir), name), targets)

    def test_l4_linux_custom_tuple_binds_exactly_those(self):
        self.assert_linux(self.linux.launch_spec(self.home, state_dirs=("projects", "todos")),
                          state_dirs=("projects", "todos"))

    # --- M: macOS --------------------------------------------------------------------------------------------------
    def test_m1_mac_none_succeeds(self):
        spec = self.mac_spec(state_dirs=None)
        self.assertEqual(spec.argv[0], "/usr/bin/sandbox-exec")

    def test_m2_mac_explicit_empty_succeeds(self):
        spec = self.mac_spec(state_dirs=())
        self.assertEqual(spec.argv[0], "/usr/bin/sandbox-exec")

    def test_m3_mac_accepts_ro_paths_broad_state_tripwire(self):
        # TRIPWIRE for the BROAD state: the profile still allows every file read, so a requested read is available.
        self.assertIs(sandbox_macos.PROFILE_CURATION, sandbox_macos.Curation.BROAD,
                      "M3: curation changed; MS6.7 must now bind requested reads in the profile")
        self.mac_spec(ro_paths=(str(self.home.runtime),))

    def _refuses(self, row, **kwargs):
        try:
            self.mac_spec(**kwargs)
        except sandbox.SandboxError as exc:
            self.assertIs(type(exc), getattr(sandbox, "UnsupportedLaunchInput", None),
                          f"{row}: {kwargs} raised {type(exc).__name__}, want sandbox.UnsupportedLaunchInput")
        else:
            self.fail(f"{row}: launch_spec accepted {kwargs} and built a profile; it must raise UnsupportedLaunchInput")
        self.assertEqual(self.profile_dirs(), [], f"{row}: a refused launch must leave no profile directory")

    def test_m4_mac_refuses_a_seccomp_fd(self):
        self._refuses("M4", seccomp_fd=5)

    def test_m5_mac_refuses_a_net_dir(self):
        self._refuses("M5", net_dir=str(self.net_dir))

    def test_m6_mac_refuses_claude_writable(self):
        self._refuses("M6", claude_writable=True)

    def test_m7_mac_refuses_nonempty_state_dirs(self):
        self._refuses("M7", state_dirs=("projects",))

    # --- N: the network= sentinel --------------------------------------------------------------------------------
    def sentinel(self, backend):
        base = backend.network()
        return base._replace(egress=base.egress._replace(endpoint=sandbox.Endpoint("127.0.0.1", SENTINEL_PORT)),
                             bridges=sandbox.BridgePolicy(ports=(), hooks_get_egress=False))

    def test_n1_linux_launch_carries_the_given_network(self):
        net = self.sentinel(self.linux)
        spec = self.linux.launch_spec(self.home, net_dir=str(self.net_dir), network=net)
        self.assertIs(spec.network, net)
        targets = {m.target for m in spec.mounts}
        self.assertIn(f"{sandbox.NET_DIR}/egress", targets)
        self.assertNotIn(f"{sandbox.NET_DIR}/bridges", targets, "N1: a network without bridges binds no bridges/")

    def test_n2_mac_launch_carries_the_given_network(self):
        net = self.sentinel(self.mac)
        spec = self.mac_spec(network=net)
        self.assertIs(spec.network, net)
        profile = Path(spec.argv[2]).read_text()
        self.assertIn(str(SENTINEL_PORT), profile, "N2: the profile must allow the given network's egress port")
        self.assertNotIn(str(MAC_PORT), profile, "N2: the profile must not use the default network's port")
        for port in sandbox_macos.CANONICAL_BRIDGES:
            self.assertNotIn(str(port), profile, "N2: a network without bridges allows no bridge port")


if __name__ == "__main__":
    unittest.main()
