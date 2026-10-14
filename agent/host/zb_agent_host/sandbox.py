"""The helper's sandbox (D12): the exact bwrap argv every helper, CLI and hook runs under.

Nothing else is mounted: no user home, no profile, no XDG_RUNTIME_DIR, no
agent-home/secrets. `.claude` is read-only as a whole, with only the reviewed
state directories (STATE_DIRS, from the P0.5 write census) bound writable on
top, from agent-home/state/<name> (plan rev 15.4); the workspace is
read-only; the scratchpad is writable.
"""

import os


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

def helper_argv(home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS, claude_writable=False, net_dir=None):
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
    return argv


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
