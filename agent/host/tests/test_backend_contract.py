"""MS0 (macOS launch plan, rev 6 ed13e5e): the shared ``SandboxBackend`` seam.

MS0 extracts the Linux sandbox policy/argv behind a ``SandboxBackend`` protocol with a
``LinuxBwrapBackend`` implementation, **behavior-preserving**, so macOS Seatbelt can later
satisfy the same contract. This is the contract test for that seam.

The oracle is a **frozen, independent reference** (``reference_launch`` / ``reference_build_argv``
below) that re-implements the Linux bwrap launch policy from first principles. It does **not**
call ``sandbox.helper_argv`` or ``backend.launch_spec`` to build the expectation, so it is not
self-referential: a wrong-argv mutant in the production builder (e.g. an injected
``--wrong-ms0-mutant``, a reordered bind, a flipped ``--ro-bind``/``--bind``) diverges from the
reference and turns this suite red. ``test_oracle_rejects_a_wrong_argv`` pins that property
permanently (RoseCat 5673/5674: the previous oracle compared the backend to a wrapper that
delegated to the same backend, so a wrong-argv mutant stayed 7/7 green).

It asserts, over seven launch variants and the real ``launch.build_argv``:

1. **Behavior preservation (golden oracle).** ``LinuxBwrapBackend.launch_spec`` reproduces the
   frozen reference argv byte-for-byte, and ``sandbox.helper_argv`` (the production facade)
   equals it too.
2. **The launch contract is SEMANTIC (rev 6 LaunchSpec).** ``LaunchSpec`` carries the
   namespaces, the ordered filesystem ``Mount`` contract, the workdir and the seccomp fd — not
   argv alone — and each matches the independent reference. These are the backend-neutral
   statement a macOS Seatbelt backend realizes without a bwrap argv.
3. **The network capability is BACKEND-SUPPLIED (rev 16.2 §3c).** The egress *endpoint* and the
   bridge *policy* come from the backend; hooks get the two bridges only, never egress.

A deliberate policy change (a new state dir, a new etc bind) must update the frozen reference in
the same commit — that is the point of a frozen golden.

Run:
    cd agent/host/tests && python3 -m unittest -v test_backend_contract
"""

import json
import os
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


# ---------------------------------------------------------------------------
# The FROZEN policy. These are copied here on purpose (not imported from
# sandbox), so the reference is independent of the code under test; a mutant in
# the production builder cannot drag the reference along with it.
# ---------------------------------------------------------------------------
REF_BWRAP = "/usr/bin/bwrap"
REF_NET_DIR = "/run/zb-net"
REF_TOKEN_DIR = "/run/zb-token"
REF_TEST_CA = "/run/zb-test-ca.pem"
REF_ETC = ("/etc/ssl", "/etc/ca-certificates", "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf",
           "/etc/passwd", "/etc/group", "/etc/localtime")
REF_USR_LINKS = (("usr/bin", "/bin"), ("usr/sbin", "/sbin"), ("usr/lib", "/lib"), ("usr/lib64", "/lib64"))
REF_STATE_DIRS = ("projects", "sessions", "session-env", "todos", "statsig", "debug", "MEMORY")
REF_CHAT_BOOT = ("import runpy, sys; sys.path.insert(0, sys.argv.pop(1)); "
                 "runpy.run_module('zb_agent_host', run_name='__main__', alter_sys=True)")
EGRESS_PORT = 3128
BRIDGE_PORTS = (51091, 31337)


def reference_launch(home, *, seccomp_fd=None, ro_paths=(), state_dirs=REF_STATE_DIRS,
                     claude_writable=False, net_dir=None):
    """A frozen, independent re-implementation of the Linux bwrap launch policy.

    Returns ``(argv, unshare, mounts, workdir, seccomp_fd)`` — the expected argv
    and the expected semantic contract. ``mounts`` is a tuple of
    ``(source, target, writable)`` triples, in bind order.
    """
    claude = str(home.claude_dir)
    net = net_dir is not None
    unshare = ("pid", "ipc", "uts") + (("net",) if net else ())

    mounts = [("/usr", "/usr", False)]
    mounts += [(p, p, False) for p in REF_ETC if os.path.exists(p)]
    mounts += [(p, p, False) for p in (str(home.runtime), *map(str, ro_paths))]
    mounts.append((str(home.workspace), str(home.workspace), False))
    if claude_writable:
        mounts.append((claude, claude, True))
    else:
        mounts.append((claude, claude, False))
        for name, writable, _is_dir in ((".claude.json", False, False), ("backups", False, True),
                                        *((n, True, True) for n in state_dirs)):
            mounts.append((os.path.join(str(home.state), name), os.path.join(claude, name), writable))
    if net:
        for name in ("egress", "bridges"):
            mounts.append((os.path.join(str(net_dir), name), f"{REF_NET_DIR}/{name}", False))
    mounts.append((str(home.scratchpad), str(home.scratchpad), True))

    workdir = str(home.workspace)

    def flags(mount):
        source, target, writable = mount
        return ["--bind" if writable else "--ro-bind", source, target]

    argv = [REF_BWRAP, *(f"--unshare-{n}" for n in unshare), "--die-with-parent", "--new-session",
            "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run"]
    argv += flags(mounts[0])  # /usr, before the symlink shims
    for target, link in REF_USR_LINKS:
        argv += ["--symlink", target, link]
    for mount in mounts[1:]:
        argv += flags(mount)
    argv += ["--perms", "0300", "--dir", REF_TOKEN_DIR, "--chdir", workdir]
    if seccomp_fd is not None:
        argv += ["--seccomp", str(seccomp_fd)]
    argv.append("--")
    return argv, unshare, tuple(mounts), workdir, seccomp_fd


def reference_build_argv(home, seccomp_fd, python, *, net_dir, bwrap=REF_BWRAP, test_ca=None):
    """A frozen, independent re-implementation of ``launch.build_argv``."""
    venv = os.path.dirname(os.path.dirname(python))
    path_json = json.loads((home.runtime / "path.json").read_text())
    extra = [venv] + [d for d in path_json if d != "/usr" and not d.startswith("/usr/")]
    argv, *_ = reference_launch(home, seccomp_fd=seccomp_fd, ro_paths=extra, net_dir=net_dir)
    argv = list(argv)
    argv[0] = bwrap
    if test_ca is not None:
        argv[-1:-1] = ["--ro-bind", str(test_ca), REF_TEST_CA]  # before the trailing "--"
    runtime = str(home.runtime)
    chat = [python, "-I", "-c", REF_CHAT_BOOT, f"{runtime}/host", "chat", "--home", str(home.root)]
    if test_ca is not None:
        chat += ["--test-ca", REF_TEST_CA]
    relay = ["/usr/bin/python3", "-I", "-S", f"{runtime}/bin/zb-net-relay", "--egress", f"{REF_NET_DIR}/egress"]
    return argv + relay + ["--", *chat]


def _backend():
    """Return a LinuxBwrapBackend instance, or fail with a clear MS0 message (red-for-reason)."""
    cls = getattr(sandbox, "LinuxBwrapBackend", None)
    if cls is None:
        raise AssertionError("MS0 not implemented: sandbox.LinuxBwrapBackend is missing.")
    return cls()


def _spec_mounts(spec):
    """The spec's mounts as plain (source, target, writable) triples, for comparison."""
    return [tuple(m) for m in getattr(spec, "mounts", ())]


class SandboxBackendSeamExists(unittest.TestCase):
    def test_protocol_and_linux_impl_present(self):
        self.assertTrue(hasattr(sandbox, "SandboxBackend"), "MS0: sandbox.SandboxBackend protocol must exist")
        self.assertTrue(hasattr(sandbox, "LinuxBwrapBackend"), "MS0: sandbox.LinuxBwrapBackend must exist")
        self.assertTrue(hasattr(sandbox, "Mount"), "MS0: sandbox.Mount (the portable bind) must exist")


class LaunchSpecMatchesFrozenReference(unittest.TestCase):
    """The backend reproduces the frozen reference argv AND semantic contract, over 7 variants."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.home = options.AgentHome(root)
        # Lay the home out the way `--agent-setup` leaves it (mirrors
        # tests/support.lay_out_state + test_unit.SandboxArgv).
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (root / d).mkdir(parents=True, exist_ok=True)
        for base in (root / "state", root / ".claude"):
            base.mkdir(parents=True, exist_ok=True)
            for name in ("backups", *sandbox.STATE_DIRS):
                (base / name).mkdir(mode=0o700, exist_ok=True)
            (base / ".claude.json").write_text("{}\n")
        # A laid-out netd socket directory, for the net_dir variants.
        self.net_dir = root / "zb-net"
        for sub in ("egress", "bridges"):
            (self.net_dir / sub).mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _check(self, name, **kwargs):
        """Drive the backend AND the production facade against the frozen reference."""
        backend = _backend()
        spec = backend.launch_spec(self.home, **kwargs)
        ref_argv, ref_unshare, ref_mounts, ref_workdir, ref_seccomp = reference_launch(self.home, **kwargs)
        with self.subTest(variant=name, check="argv"):
            self.assertEqual(list(spec.argv), ref_argv,
                             f"MS0[{name}]: backend argv must equal the frozen reference byte-for-byte")
        with self.subTest(variant=name, check="helper_argv facade"):
            self.assertEqual(sandbox.helper_argv(self.home, **kwargs), ref_argv,
                             f"MS0[{name}]: sandbox.helper_argv (production facade) must equal the reference")
        with self.subTest(variant=name, check="unshare"):
            self.assertEqual(tuple(spec.unshare), ref_unshare,
                             f"MS0[{name}]: LaunchSpec.unshare must be the semantic namespace set")
        with self.subTest(variant=name, check="mounts"):
            self.assertEqual(_spec_mounts(spec), list(ref_mounts),
                             f"MS0[{name}]: LaunchSpec.mounts must be the ordered filesystem contract "
                             "(argv is a projection of it, not the other way round)")
        with self.subTest(variant=name, check="workdir"):
            self.assertEqual(spec.workdir, ref_workdir, f"MS0[{name}]: LaunchSpec.workdir must be set")
        with self.subTest(variant=name, check="seccomp_fd"):
            self.assertEqual(spec.seccomp_fd, ref_seccomp, f"MS0[{name}]: LaunchSpec.seccomp_fd must be set")

    def test_variant_1_default(self):
        self._check("default")

    def test_variant_2_seccomp_fd(self):
        self._check("seccomp_fd", seccomp_fd=17)

    def test_variant_3_ro_paths(self):
        self._check("ro_paths", ro_paths=("/opt/zb-venv", "/opt/hookdir"))

    def test_variant_4_net_dir(self):
        self._check("net_dir", net_dir=str(self.net_dir))
        # And the net launch really unshares the network (the whole point of §3c).
        self.assertIn("--unshare-net", reference_launch(self.home, net_dir=str(self.net_dir))[0])

    def test_variant_5_claude_writable(self):
        self._check("claude_writable", claude_writable=True)

    def test_variant_6_custom_state_dirs(self):
        self._check("custom_state_dirs", state_dirs=("projects", "sessions"))

    def test_variant_7_combined(self):
        self._check("combined", seccomp_fd=23, ro_paths=("/opt/zb-venv",), net_dir=str(self.net_dir))

    def test_oracle_rejects_a_wrong_argv(self):
        """Anti-tautology guard (RoseCat 5673/5674): a wrong backend argv must NOT
        compare equal to the frozen reference, or the oracle would be useless."""
        backend = _backend()
        mutant = list(backend.launch_spec(self.home).argv)
        mutant.insert(1, "--wrong-ms0-mutant")
        ref_argv, *_ = reference_launch(self.home)
        self.assertNotEqual(mutant, ref_argv,
                            "the frozen reference must distinguish a wrong argv — it is independent of the backend")

    def test_mounts_project_to_the_argv_binds(self):
        """The argv binds are exactly a projection of LaunchSpec.mounts, in order."""
        spec = _backend().launch_spec(self.home, net_dir=str(self.net_dir))
        argv = list(spec.argv)
        projected = []
        for mount in spec.mounts:
            projected += ["--bind" if mount.writable else "--ro-bind", mount.source, mount.target]
        # Every (flag, source, target) triple from the mounts appears in the argv, in that order.
        binds = []
        i = 0
        while i < len(argv):
            if argv[i] in ("--bind", "--ro-bind"):
                binds += argv[i:i + 3]
                i += 3
            else:
                i += 1
        self.assertEqual(binds, projected,
                         "MS0: the argv's --bind/--ro-bind sequence must equal the projection of LaunchSpec.mounts")


class RealLaunchBuildArgvMatchesReference(unittest.TestCase):
    """The REAL launch.build_argv is driven (not an existence check) against the frozen reference."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.home = options.AgentHome(root)
        for d in (".claude", "workspace", "scratchpad", "runtime"):
            (root / d).mkdir(parents=True, exist_ok=True)
        for base in (root / "state", root / ".claude"):
            base.mkdir(parents=True, exist_ok=True)
            for name in ("backups", *sandbox.STATE_DIRS):
                (base / name).mkdir(mode=0o700, exist_ok=True)
            (base / ".claude.json").write_text("{}\n")
        self.net_dir = root / "zb-net"
        for sub in ("egress", "bridges"):
            (self.net_dir / sub).mkdir(parents=True, exist_ok=True)
        # path.json: the hook command directories; /usr and /usr/* are dropped by build_argv.
        (root / "runtime" / "path.json").write_text(json.dumps(["/usr", "/usr/bin", "/opt/hookdir"]))
        self.python = "/opt/zb-venv/bin/python3"

    def tearDown(self):
        self._tmp.cleanup()

    def _require_build_argv(self):
        if launch is None or not hasattr(launch, "build_argv"):
            self.fail("MS0: launch.build_argv must be present and route through the backend")

    def test_build_argv_equals_reference(self):
        self._require_build_argv()
        got = launch.build_argv(self.home, 17, self.python, net_dir=str(self.net_dir))
        expected = reference_build_argv(self.home, 17, self.python, net_dir=str(self.net_dir))
        self.assertEqual(got, expected,
                         "MS0: launch.build_argv must equal the frozen reference (sandbox prefix + relay + chat)")

    def test_build_argv_with_test_ca_equals_reference(self):
        self._require_build_argv()
        got = launch.build_argv(self.home, 17, self.python, net_dir=str(self.net_dir), test_ca="/some/ca.pem")
        expected = reference_build_argv(self.home, 17, self.python, net_dir=str(self.net_dir), test_ca="/some/ca.pem")
        self.assertEqual(got, expected, "MS0: the --test-ca branch of build_argv must match the reference too")


class NetworkCapabilityIsBackendSupplied(unittest.TestCase):
    """rev 16.2 §3c: the egress endpoint and bridge policy are the backend's to supply."""

    def test_egress_endpoint_backend_supplied(self):
        ep = _backend().egress_endpoint(session="test-session")
        self.assertEqual(getattr(ep, "host", None), "127.0.0.1", "MS0: egress endpoint must be loopback")
        self.assertEqual(getattr(ep, "port", None), EGRESS_PORT,
                         "MS0: egress endpoint must be the fixed proxy port (the CLI rejects unix-socket proxies)")

    def test_bridge_policy_is_the_two_named_ports(self):
        policy = _backend().bridge_policy()
        self.assertEqual(tuple(getattr(policy, "ports", ())), BRIDGE_PORTS,
                         "MS0: the bridge policy must be exactly ports 51091 and 31337 (rev 16.2 §3c)")

    def test_hooks_get_bridges_only_never_egress(self):
        backend = _backend()
        self.assertFalse(getattr(backend.bridge_policy(), "hooks_get_egress", True),
                         "MS0: hooks must get the two bridges ONLY, never egress (rev 16.2 §3c.2b/§3c.8b)")
        hook = backend.hook_launch_spec()
        self.assertEqual(tuple(getattr(hook, "ports", ())), BRIDGE_PORTS,
                         "MS0: the hook network must be exactly the two bridge ports")
        self.assertIsNone(getattr(hook, "egress", "set"), "MS0: a hook's network carries no egress")


if __name__ == "__main__":
    unittest.main()
