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


class LaunchSpec(NamedTuple):
    """The portable result of a backend launch: the sandbox argv prefix.

    On Linux `argv` is the bwrap prefix (ending in ``--``); a macOS backend
    would carry its sandbox-exec profile here instead. Stored as a tuple so the
    spec is immutable; callers that need a mutable list wrap it in ``list()``.
    """
    argv: tuple


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

    This mirrors ``hook_run.py`` read-only (MS0 does not change the hook runner);
    it is the macOS-portable statement of "a hook gets the two bridges and
    nothing else", which a macOS backend realizes as a Seatbelt profile.
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
        net = _net_binds(net_dir) if net_dir is not None else []
        argv = [BWRAP, "--unshare-pid", "--unshare-ipc", "--unshare-uts", *(["--unshare-net"] if net else []),
                "--die-with-parent", "--new-session",
                "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run",
                "--ro-bind", "/usr", "/usr"]
        for target, link in USR_LINKS:
            argv += ["--symlink", target, link]
        for path in ETC_FILES:
            if os.path.exists(path):
                argv += ["--ro-bind", path, path]
        for path in (str(home.runtime), *map(str, ro_paths)):
            argv += ["--ro-bind", path, path]
        argv += ["--ro-bind", str(home.workspace), str(home.workspace)]
        claude = str(home.claude_dir)
        if claude_writable:
            argv += ["--bind", claude, claude]
        else:
            argv += ["--ro-bind", claude, claude]
            # The state lives outside the published build (plan rev 15.5): setup
            # made every source and every mount point; a published build is never
            # written after its publish, so anything missing refuses.
            for name, flag, is_dir in ((".claude.json", "--ro-bind", False), ("backups", "--ro-bind", True),
                                       *((n, "--bind", True) for n in state_dirs)):
                source, target = os.path.join(str(home.state), name), os.path.join(claude, name)
                for path in (source, target):
                    ok = os.path.isdir(path) if is_dir else os.path.isfile(path)
                    if os.path.islink(path) or not ok:
                        raise SandboxError(f"{path} is missing or not a {'directory' if is_dir else 'file'}: "
                                           "run zigBrowser --agent-setup")
                argv += [flag, source, target]
        argv += net
        argv += ["--bind", str(home.scratchpad), str(home.scratchpad),
                 "--perms", "0300", "--dir", TOKEN_DIR,
                 "--chdir", str(home.workspace)]
        if seccomp_fd is not None:
            argv += ["--seccomp", str(seccomp_fd)]
        argv.append("--")
        return LaunchSpec(tuple(argv))

    def egress_endpoint(self, session=None):
        """The loopback the CLI reaches via HTTPS_PROXY: 127.0.0.1:3128 (the outer
        relay, which forwards to netd's egress/proxy.sock). `session` is accepted
        for the macOS backend (an ephemeral per-session port); Linux's is fixed.
        """
        (port,) = tuple(relay.EGRESS)  # exactly one egress port (3128); fails loudly if the topology changes
        return Endpoint("127.0.0.1", port)

    def bridge_policy(self):
        """The two fixed loopback bridges (51091, 31337); hooks never get egress."""
        return BridgePolicy(ports=tuple(relay.BRIDGES), hooks_get_egress=False)

    def hook_launch_spec(self):
        """A hook's network: the two bridges under /run/zb-net/bridges, no egress.

        Mirrors zb-hook-run (hook_run.py) read-only. The macOS backend realizes
        the same statement as a hook Seatbelt profile permitting only loopback
        51091/31337.
        """
        return HookNetwork(bridges_dir=f"{NET_DIR}/bridges", ports=tuple(relay.BRIDGES), egress=None)


# The single Linux backend instance. `helper_argv` delegates to it, so the
# production launch path flows through the seam (it is not test-only scaffolding).
_LINUX_BACKEND = LinuxBwrapBackend()


def helper_argv(home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS, claude_writable=False, net_dir=None):
    """The bwrap prefix for a helper rooted at `home`; the stable public facade.

    Signature and output are unchanged: this delegates to
    ``LinuxBwrapBackend().launch_spec(...)`` and returns its argv as a list, so
    every existing caller is untouched while the argv now comes from the seam.
    """
    return list(_LINUX_BACKEND.launch_spec(
        home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, state_dirs=state_dirs,
        claude_writable=claude_writable, net_dir=net_dir).argv)


def _net_binds(net_dir):
    """Read-only binds of netd's egress/ and bridges/ (each a real directory, not
    a link), after the /run tmpfs. connect() works through a read-only bind;
    create, rename and unlink get EROFS (BlueBeaver 5472)."""
    argv = []
    for name in ("egress", "bridges"):
        source = os.path.join(str(net_dir), name)
        if os.path.islink(source) or not os.path.isdir(source):
            raise SandboxError(f"{source} is missing or not a directory: netd is not running")
        argv += ["--ro-bind", source, f"{NET_DIR}/{name}"]
    return argv
