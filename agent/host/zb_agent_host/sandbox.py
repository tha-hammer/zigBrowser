"""The helper's sandbox (D12): the exact bwrap argv every helper, CLI and hook runs under.

Nothing else is mounted: no user home, no profile, no XDG_RUNTIME_DIR, no
agent-home/secrets. `.claude` is read-only as a whole, with only the reviewed
state directories (STATE_DIRS, from the P0.5 write census) bound writable on
top, from agent-home/state/<name> (plan rev 15.4); the workspace is
read-only; the scratchpad is writable.

MS0 (macOS launch plan, rev 6): the bwrap builder and the network topology it
assumes are extracted behind a `SandboxBackend` seam with a `LinuxBwrapBackend`
implementation, so macOS Seatbelt can later satisfy the same contract. The
extraction is behaviour-preserving: `helper_argv` keeps its exact signature and
byte-for-byte output and simply delegates to the Linux backend's `launch_spec`.
`launch_spec` returns a semantic `LaunchSpec` — the namespaces, the ordered
filesystem `Mount` contract, the workdir and the seccomp fd — and the Linux argv
is a projection of that contract, so a macOS Seatbelt backend can satisfy the
same launch without reusing a bwrap argv.
"""

import os
from typing import NamedTuple, Protocol

from . import relay  # the Linux net topology: egress + bridge loopback ports (one source of truth)


BWRAP = "/usr/bin/bwrap"


class SandboxError(Exception):
    """The agent home is not laid out as setup leaves it."""
ETC_FILES = ("/etc/ssl", "/etc/ca-certificates", "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf",
             "/etc/passwd", "/etc/group", "/etc/localtime")
USR_LINKS = (("usr/bin", "/bin"), ("usr/sbin", "/sbin"), ("usr/lib", "/lib"), ("usr/lib64", "/lib64"))

# Writable state under .claude: the P0.5 write census of the bundled CLI (2.1.294)
# and the SAI hooks, reviewed. Data only: no hook may reference a path in here.
# `.claude.json` (it lives in CLAUDE_CONFIG_DIR, not HOME) and `backups/` stay
# read-only: the CLI tolerates it, and its configuration cannot drift. All of
# them live in agent-home/state/, outside every published build (plan rev 15.5).
STATE_DIRS = ("projects", "sessions", "session-env", "todos", "statsig", "debug", "MEMORY")
TOKEN_DIR = "/run/zb-token"
# netd's socket directories inside the sandbox (plan rev 16.2 §3c.2): egress/
# holds proxy.sock (the outer relay's only target), bridges/ the two fixed
# bridge sockets, which zb-hook-run binds on into each sealed hook.
NET_DIR = "/run/zb-net"


class Mount(NamedTuple):
    """One path the sandbox exposes to the launched process, backend-neutrally.

    Linux realizes it as ``--ro-bind``/``--bind`` source target; a macOS backend
    realizes the same ``(source, target, writable)`` as a Seatbelt file-read or
    file-write rule. ``source`` and ``target`` are equal for an in-place bind.
    """
    source: str
    target: str
    writable: bool = False


class LaunchSpec(NamedTuple):
    """The portable, semantic launch contract a backend produces (MS0, rev 6).

    ``argv`` is the realized Linux bwrap prefix (ending in ``--``) that production
    execs; the other fields are the backend-neutral *meaning* of that launch, so a
    macOS Seatbelt backend can satisfy the same contract without reusing a bwrap
    argv (and so the contract test can pin the launch independently of the argv):

      * ``unshare`` — the namespaces isolated: ``("pid", "ipc", "uts")`` always,
        plus ``"net"`` when the process runs in netd's private network namespace;
      * ``mounts`` — the ordered filesystem contract, every path the sandbox
        exposes as a :class:`Mount` (read-only or writable). On Linux the argv
        binds are a projection of exactly this list, in this order;
      * ``workdir`` — the working directory inside the sandbox;
      * ``seccomp_fd`` — the outer seccomp program descriptor on Linux, or None.

    Stored as a tuple so the spec is immutable; callers that need a mutable argv
    list wrap ``argv`` in ``list()``. The extra fields default to empty so the
    type stays constructible as ``LaunchSpec(argv)``.
    """
    argv: tuple
    unshare: tuple = ()
    mounts: tuple = ()
    workdir: str = None
    seccomp_fd: object = None


class Endpoint(NamedTuple):
    """A loopback host:port a caller reaches (e.g. the CLI's HTTPS_PROXY target)."""
    host: str
    port: int


class BridgePolicy(NamedTuple):
    """The host bridges a sandboxed process may reach, and whether hooks get egress.

    ``ports`` are the fixed loopback bridge ports; ``hooks_get_egress`` is always
    False on Linux — a hook reaches the two bridges only, never the egress proxy
    or any API path (rev 16.2 §3c.2b/§3c.8b).
    """
    ports: tuple
    hooks_get_egress: bool = False


class HookNetwork(NamedTuple):
    """A hook's network view: the bridges directory + ports, and no egress.

    It is the macOS-portable statement of "a hook gets the two bridges and
    nothing else", which a macOS backend realizes as a Seatbelt profile. MS0
    makes it the source of the hook runner's bridges mount: setup writes
    ``runtime/net.json`` from it and ``zb-hook-run`` reads that.
    """
    bridges_dir: str
    ports: tuple
    egress: None = None


class SandboxBackend(Protocol):
    """The shared seam a Linux (bwrap) and a macOS (Seatbelt) sandbox both satisfy.

    The backend owns both the launch argv and the network capability: the egress
    endpoint the CLI reaches and the bridge policy, so the caller never hard-codes
    them. macOS supplies an ephemeral host-loopback proxy + per-process Seatbelt
    port rules; Linux supplies netd's fixed private-netns ports + relays.
    """

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS,
                    claude_writable=False, net_dir=None) -> "LaunchSpec": ...

    def egress_endpoint(self, session=None) -> "Endpoint": ...

    def egress_dir(self) -> str: ...

    def bridge_policy(self) -> "BridgePolicy": ...

    def hook_launch_spec(self) -> "HookNetwork": ...


class LinuxBwrapBackend:
    """The behaviour-preserving Linux implementation of :class:`SandboxBackend`.

    ``launch_spec`` reproduces exactly the bwrap argv that ``helper_argv`` has
    always produced; the network methods read the loopback topology from the
    ``relay`` module (the one source of truth: egress on 3128, bridges on
    51091/31337), so a wrong constant can never silently diverge from the relay.
    """

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS,
                    claude_writable=False, net_dir=None):
        """The bwrap prefix for a helper rooted at `home` (an options.AgentHome).

        `seccomp_fd`: a descriptor holding seccomp.program() (seccomp.seccomp_fd()), inherited by bwrap.
        `ro_paths`: extra read-only binds (the venv, the hook command directories
        from runtime/path.json). `claude_writable` binds all of .claude writable;
        only the P0.5 write census uses it. `net_dir` (§3c.2): netd's socket
        directory; the sandbox then gets a network namespace of its own and sees
        only netd's egress/ and bridges/, read-only, under /run/zb-net.
        """
        # netd's egress/bridges binds, validated here (before the .claude state
        # checks below), so a missing net dir refuses in exactly the old order.
        net_mounts = _net_mounts(net_dir) if net_dir is not None else ()
        unshare = ("pid", "ipc", "uts") + (("net",) if net_mounts else ())

        # The ordered filesystem contract. /usr is first (the --symlink shims sit
        # between it and the rest); then the etc files, the runtime and the extra
        # read-only paths, the workspace, .claude (and its reviewed writable
        # state), netd's sockets, and the writable scratchpad. The argv binds
        # below are a projection of exactly this list, in this order.
        head = Mount("/usr", "/usr", False)
        rest = [Mount(path, path, False) for path in ETC_FILES if os.path.exists(path)]
        rest += [Mount(path, path, False) for path in (str(home.runtime), *map(str, ro_paths))]
        rest.append(Mount(str(home.workspace), str(home.workspace), False))
        claude = str(home.claude_dir)
        if claude_writable:
            rest.append(Mount(claude, claude, True))
        else:
            rest.append(Mount(claude, claude, False))
            # The state lives outside the published build (plan rev 15.5): setup
            # made every source and every mount point; a published build is never
            # written after its publish, so anything missing refuses.
            for name, writable, is_dir in ((".claude.json", False, False), ("backups", False, True),
                                           *((n, True, True) for n in state_dirs)):
                source, target = os.path.join(str(home.state), name), os.path.join(claude, name)
                for path in (source, target):
                    ok = os.path.isdir(path) if is_dir else os.path.isfile(path)
                    if os.path.islink(path) or not ok:
                        raise SandboxError(f"{path} is missing or not a {'directory' if is_dir else 'file'}: "
                                           "run zigBrowser --agent-setup")
                rest.append(Mount(source, target, writable))
        rest.extend(net_mounts)
        rest.append(Mount(str(home.scratchpad), str(home.scratchpad), True))
        mounts = (head, *rest)
        workdir = str(home.workspace)

        argv = [BWRAP, *(f"--unshare-{n}" for n in unshare), "--die-with-parent", "--new-session",
                "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run"]
        argv += _bind_flags(head)
        for target, link in USR_LINKS:
            argv += ["--symlink", target, link]
        for mount in rest:
            argv += _bind_flags(mount)
        argv += ["--perms", "0300", "--dir", TOKEN_DIR, "--chdir", workdir]
        if seccomp_fd is not None:
            argv += ["--seccomp", str(seccomp_fd)]
        argv.append("--")
        return LaunchSpec(tuple(argv), unshare=unshare, mounts=mounts, workdir=workdir, seccomp_fd=seccomp_fd)

    def egress_endpoint(self, session=None):
        """The loopback the CLI reaches via HTTPS_PROXY: 127.0.0.1:3128 (the outer
        relay, which forwards to netd's egress/proxy.sock). `session` is accepted
        for the macOS backend (an ephemeral per-session port); Linux's is fixed.
        """
        (port,) = tuple(relay.EGRESS)  # exactly one egress port (3128); fails loudly if the topology changes
        return Endpoint("127.0.0.1", port)

    def egress_dir(self):
        """The outer relay's egress socket directory inside the sandbox
        (/run/zb-net/egress), where netd's proxy.sock lives — the only target the
        outer relay forwards 127.0.0.1:3128 to. `launch.build_argv` binds and
        names it, so it comes from the backend, not a hard-coded path."""
        return f"{NET_DIR}/egress"

    def bridge_policy(self):
        """The two fixed loopback bridges (51091, 31337); hooks never get egress."""
        return BridgePolicy(ports=tuple(relay.BRIDGES), hooks_get_egress=False)

    def hook_launch_spec(self):
        """A hook's network: the two bridges under /run/zb-net/bridges, no egress.

        Mirrors zb-hook-run (hook_run.py) read-only. The macOS backend realizes
        the same statement as a hook Seatbelt profile permitting only loopback
        51091/31337.
        """
        return HookNetwork(bridges_dir=f"{NET_DIR}/bridges", ports=self.bridge_policy().ports, egress=None)


# The single Linux backend instance. `helper_argv` and the network-capability
# delegates below flow through it, so the production launch and network paths go
# through the seam (it is not test-only scaffolding).
_LINUX_BACKEND = LinuxBwrapBackend()


def egress_endpoint(session=None):
    """The CLI's HTTPS_PROXY target, from the backend (one source of truth)."""
    return _LINUX_BACKEND.egress_endpoint(session)


def egress_dir():
    """The outer relay's egress socket directory, from the backend."""
    return _LINUX_BACKEND.egress_dir()


def hook_network():
    """A hook's network capability (bridges dir + ports, no egress), from the backend."""
    return _LINUX_BACKEND.hook_launch_spec()


def helper_argv(home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS, claude_writable=False, net_dir=None):
    """The bwrap prefix for a helper rooted at `home`; the stable public facade.

    Signature and output are unchanged: this delegates to
    ``LinuxBwrapBackend().launch_spec(...)`` and returns its argv as a list, so
    every existing caller is untouched while the argv now comes from the seam.
    """
    return list(_LINUX_BACKEND.launch_spec(
        home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, state_dirs=state_dirs,
        claude_writable=claude_writable, net_dir=net_dir).argv)


def _bind_flags(mount):
    """The bwrap flags that realize one :class:`Mount`: writable binds with
    ``--bind``, read-only with ``--ro-bind``."""
    return ["--bind" if mount.writable else "--ro-bind", mount.source, mount.target]


def _net_mounts(net_dir):
    """Read-only :class:`Mount`\\ s of netd's egress/ and bridges/ (each a real
    directory, not a link), bound under /run/zb-net after the /run tmpfs.
    connect() works through a read-only bind; create, rename and unlink get
    EROFS (BlueBeaver 5472)."""
    mounts = []
    for name in ("egress", "bridges"):
        source = os.path.join(str(net_dir), name)
        if os.path.islink(source) or not os.path.isdir(source):
            raise SandboxError(f"{source} is missing or not a directory: netd is not running")
        mounts.append(Mount(source, f"{NET_DIR}/{name}", False))
    return tuple(mounts)
