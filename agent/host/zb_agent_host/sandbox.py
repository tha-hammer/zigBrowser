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
import signal
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
# The upstream hosts the egress proxy may reach. The backend owns this allowlist
# (MS0 rev 6; RoseCat 5750): setup serializes it to runtime/net.json and netd's
# outer stage reads it, instead of netd owning the literal. Linux's default is
# byte-identical to netd's historical API_HOST.
EGRESS_ALLOW = ("api.anthropic.com",)
# The one-shot sign-in's upstream hosts (plan rev 16.18.1, RoseCat 5911): the API
# and `claude setup-token`'s token exchange (2.1.301's TOKEN_URL,
# https://platform.claude.com/v1/oauth/token). Only the login launch gets them,
# through its own manifest (runtime/net-login.json) and its own netd.
LOGIN_EGRESS_ALLOW = ("api.anthropic.com", "platform.claude.com")


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
      * ``seccomp_fd`` — the outer seccomp program descriptor on Linux, or None;
      * ``network`` — the backend-supplied :class:`Network` capability (the egress
        endpoint *and* its upstream allowlist, the egress socket dir, and the
        bridge policy). It is the immutable, backend-neutral statement the CLI
        proxy, ``launch``'s ``--egress``, netd's allowlist/ports and the relay all
        project from, so a macOS backend states the same meaning (RoseCat 5750);
      * ``lifetime`` — the backend's spawn/lifetime policy (:class:`Lifetime`),
        whose native realization is ``agent_host.c``'s ``ZbSpawnPolicy`` threaded
        through ``zb_agent_run_sync`` (RoseCat 5750);
      * ``channel`` — the backend's inherited broker channel (:class:`Channel`): the
        token's fd and its announcing env var, projected by ``token.write_wrapper``.

    Stored as a tuple so the spec is immutable; callers that need a mutable argv
    list wrap ``argv`` in ``list()``. The extra fields default to empty so the
    type stays constructible as ``LaunchSpec(argv)``.
    """
    argv: tuple
    unshare: tuple = ()
    mounts: tuple = ()
    workdir: str = None
    seccomp_fd: object = None
    network: object = None  # a :class:`Network` (defined below), or None
    lifetime: object = None  # a :class:`Lifetime`, or None
    channel: object = None  # a :class:`Channel`, or None


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


class Egress(NamedTuple):
    """The agent's egress policy, backend-supplied (MS0 rev 6; RoseCat 5750).

    ``endpoint`` is the loopback the CLI's HTTPS_PROXY and the outer relay use
    (127.0.0.1:3128 on Linux); ``allow`` is the upstream hosts netd's egress proxy
    may CONNECT to (``("api.anthropic.com",)`` on Linux — the backend owns this
    allowlist now, not netd's own literal); ``dir`` is the outer relay's egress
    socket directory inside the sandbox. A macOS backend states the same meaning.
    """
    endpoint: Endpoint
    allow: tuple
    dir: str


class Network(NamedTuple):
    """The backend's whole network capability: the single immutable value the CLI
    proxy, ``launch`` ``--egress``, netd's allowlist/ports and the relay all
    project from, carried by :class:`LaunchSpec`'s ``network`` field. Changing it
    changes every one of those real consumers (that is what the contract test
    pins), so a changed backend policy cannot silently fail to propagate.
    """
    egress: Egress
    bridges: BridgePolicy


class Lifetime(NamedTuple):
    """The spawn/lifetime policy a backend supplies for the setup CLI's spawn (MS0
    rev 6, route a), carried by :class:`LaunchSpec`'s ``lifetime`` field. It is the
    backend-neutral meaning of "die with the browser"; its native Linux realization
    is ``agent_host.c``'s ``ZbSpawnPolicy`` (``zb_spawn_policy_linux``), threaded
    through ``zb_agent_run_sync`` so the caller owns the policy instead of the C
    hard-coding it. A macOS backend states the same meaning and realizes it with
    posix_spawn + kqueue NOTE_EXIT.

      * ``die_with_parent`` — the child dies when the browser does;
      * ``signal`` — the death signal (SIGKILL on Linux);
      * ``check_parent_race`` — re-check the parent after the fork-to-prctl window
        and exit if it was reparented (RoseCat 5330);
      * ``delay_ms`` — e2e only (else 0): widens that window for the race test.
    """
    die_with_parent: bool
    signal: int
    check_parent_race: bool
    delay_ms: int = 0


class Channel(NamedTuple):
    """The inherited broker channel a backend hands the launched CLI (MS0 rev 6),
    carried by :class:`LaunchSpec`'s ``channel`` field: the token's socket on
    descriptor ``fd`` (3 on Linux), announced to the CLI through the environment
    variable ``env`` (``CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR``). The real
    consumer is ``token.write_wrapper``'s ``zb-claude`` wrapper, which dup2s the
    token socket to ``fd`` and sets ``env`` — so a changed backend channel changes
    the descriptor the CLI really inherits. A macOS backend states the same
    descriptor contract.
    """
    fd: int
    env: str


class SandboxBackend(Protocol):
    """The shared seam a Linux (bwrap) and a macOS (Seatbelt) sandbox both satisfy.

    The backend owns both the launch argv and the network capability: the egress
    endpoint the CLI reaches and the bridge policy, so the caller never hard-codes
    them. macOS supplies an ephemeral host-loopback proxy + per-process Seatbelt
    port rules; Linux supplies netd's fixed private-netns ports + relays.
    """

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS,
                    claude_writable=False, net_dir=None) -> "LaunchSpec": ...

    def network(self) -> "Network": ...

    def login_network(self) -> "Network": ...

    def login_launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), net_dir=None) -> "LaunchSpec": ...

    def lifetime(self) -> "Lifetime": ...

    def channel(self) -> "Channel": ...

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
                    claude_writable=False, net_dir=None, network=None):
        """The bwrap prefix for a helper rooted at `home` (an options.AgentHome).

        `seccomp_fd`: a descriptor holding seccomp.program() (seccomp.seccomp_fd()), inherited by bwrap.
        `ro_paths`: extra read-only binds (the venv, the hook command directories
        from runtime/path.json). `claude_writable` binds all of .claude writable;
        only the P0.5 write census uses it. `net_dir` (§3c.2): netd's socket
        directory; the sandbox then gets a network namespace of its own and sees
        only netd's egress/ and bridges/, read-only, under /run/zb-net.
        `network`: the capability this launch carries (default: :meth:`network`;
        the sign-in passes :meth:`login_network`, whose netd has no bridges/, so
        only egress/ is bound).
        """
        network = network if network is not None else self.network()
        # netd's egress/bridges binds, validated here (before the .claude state
        # checks below), so a missing net dir refuses in exactly the old order.
        names = ("egress", "bridges") if network.bridges.ports else ("egress",)
        net_mounts = _net_mounts(net_dir, names) if net_dir is not None else ()
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
        return LaunchSpec(tuple(argv), unshare=unshare, mounts=mounts, workdir=workdir, seccomp_fd=seccomp_fd,
                          network=network, lifetime=self.lifetime(), channel=self.channel())

    def network(self, session=None):
        """The whole Linux network capability as one immutable :class:`Network` —
        the single source the egress endpoint/dir, the allowlist, the bridge policy
        and (via setup's net.json) netd and the relay all project from. `session`
        is accepted for the macOS backend (an ephemeral per-session port); Linux's
        is fixed. Built from the `relay` topology (one source of truth) plus the
        backend-owned `EGRESS_ALLOW`."""
        (port,) = tuple(relay.EGRESS)  # exactly one egress port (3128); fails loudly if the topology changes
        return Network(
            egress=Egress(Endpoint("127.0.0.1", port), EGRESS_ALLOW, f"{NET_DIR}/egress"),
            bridges=BridgePolicy(ports=tuple(relay.BRIDGES), hooks_get_egress=False),
        )

    def login_network(self):
        """The one-shot sign-in's network (rev 16.18.1): the same egress endpoint
        and dir, the allowlist :data:`LOGIN_EGRESS_ALLOW`, and no bridges
        (setup-token runs no hooks). :meth:`network` is unchanged by it."""
        chat = self.network()
        return Network(egress=chat.egress._replace(allow=LOGIN_EGRESS_ALLOW),
                       bridges=BridgePolicy(ports=(), hooks_get_egress=False))

    def login_launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), net_dir=None):
        """The login helper's launch: :meth:`launch_spec` carrying
        :meth:`login_network`, so only the login netd's egress/ is bound."""
        return self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, net_dir=net_dir,
                                network=self.login_network())

    def egress_endpoint(self, session=None):
        """The loopback the CLI reaches via HTTPS_PROXY: 127.0.0.1:3128 (the outer
        relay, which forwards to netd's egress/proxy.sock), projected from the
        backend's :meth:`network`."""
        return self.network(session).egress.endpoint

    def egress_dir(self):
        """The outer relay's egress socket directory inside the sandbox
        (/run/zb-net/egress), where netd's proxy.sock lives — the only target the
        outer relay forwards 127.0.0.1:3128 to. `launch.build_argv` binds and
        names it, projected from the backend's :meth:`network`."""
        return self.network().egress.dir

    def bridge_policy(self):
        """The two fixed loopback bridges (51091, 31337); hooks never get egress.
        Projected from the backend's :meth:`network`."""
        return self.network().bridges

    def hook_launch_spec(self):
        """A hook's network: the two bridges under /run/zb-net/bridges, no egress.

        Mirrors zb-hook-run (hook_run.py) read-only. The macOS backend realizes
        the same statement as a hook Seatbelt profile permitting only loopback
        51091/31337.
        """
        return HookNetwork(bridges_dir=f"{NET_DIR}/bridges", ports=self.bridge_policy().ports, egress=None)

    def lifetime(self):
        """The Linux spawn/lifetime policy as one immutable :class:`Lifetime` — the
        mirror of agent_host.c's ``zb_spawn_policy_linux(0)``: die with the browser
        by SIGKILL, with the fork-to-prctl race check, no extra delay. The native
        realization is that C policy, now threaded through ``zb_agent_run_sync``; a
        macOS backend supplies its own for the same meaning (RoseCat 5750)."""
        return Lifetime(die_with_parent=True, signal=signal.SIGKILL, check_parent_race=True, delay_ms=0)

    def channel(self):
        """The inherited broker channel as one immutable :class:`Channel` — the token
        socket on fd 3, announced as ``CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR``. The
        real consumer is ``token.write_wrapper`` (the ``zb-claude`` wrapper), which
        dup2s the token to this fd and sets this env var."""
        return Channel(fd=3, env="CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR")


# The single Linux backend instance. `helper_argv` and the network-capability
# delegates below flow through it, so the production launch and network paths go
# through the seam (it is not test-only scaffolding).
_LINUX_BACKEND = LinuxBwrapBackend()


def network(session=None):
    """The backend's whole network capability (one source of truth): the egress
    endpoint + allowlist + dir and the bridge policy. setup serializes it to
    net.json; options/launch/netd/relay all project from it."""
    return _LINUX_BACKEND.network(session)


def lifetime():
    """The backend's spawn/lifetime policy (one source of truth): the native mirror
    that ``zb_agent_run_sync`` threads through ``ZbSpawnPolicy``."""
    return _LINUX_BACKEND.lifetime()


def channel():
    """The backend's inherited broker channel (one source of truth): the token fd and
    its announcing env var, which ``token.write_wrapper`` projects."""
    return _LINUX_BACKEND.channel()


def egress_endpoint(session=None):
    """The CLI's HTTPS_PROXY target, from the backend (one source of truth)."""
    return _LINUX_BACKEND.egress_endpoint(session)


def egress_dir():
    """The outer relay's egress socket directory, from the backend."""
    return _LINUX_BACKEND.egress_dir()


def login_network():
    """The one-shot sign-in's network capability (rev 16.18.1), from the backend:
    setup serializes it to runtime/net-login.json for the login netd."""
    return _LINUX_BACKEND.login_network()


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


def _net_mounts(net_dir, names=("egress", "bridges")):
    """Read-only :class:`Mount`\\ s of netd's `names` (egress/ and bridges/; the
    sign-in's netd has egress/ only), each a real directory, not a link, bound
    under /run/zb-net after the /run tmpfs. connect() works through a read-only
    bind; create, rename and unlink get EROFS (BlueBeaver 5472)."""
    mounts = []
    for name in names:
        source = os.path.join(str(net_dir), name)
        if os.path.islink(source) or not os.path.isdir(source):
            raise SandboxError(f"{source} is missing or not a directory: netd is not running")
        mounts.append(Mount(source, f"{NET_DIR}/{name}", False))
    return tuple(mounts)
