"""The helper's sandbox (D12): the exact bwrap argv every helper, CLI and hook runs under.

Nothing else is mounted: no user home, no profile, no XDG_RUNTIME_DIR, no
agent-home/secrets. `.claude` is read-only as a whole, with only the reviewed
state directories (STATE_DIRS, from the P0.5 write census) bound writable on
top, from agent-home/state/<name> (plan rev 15.4); the workspace is
read-only; the scratchpad is writable.
"""

import os


BWRAP = "/usr/bin/bwrap"
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

def helper_argv(home, *, seccomp_fd=None, ro_paths=(), state_dirs=STATE_DIRS, claude_writable=False):
    """The bwrap prefix for a helper rooted at `home` (an options.AgentHome).

    `seccomp_fd`: a descriptor holding seccomp.program() (seccomp.seccomp_fd()), inherited by bwrap.
    `ro_paths`: extra read-only binds (the venv, the hook command directories
    from runtime/path.json). `claude_writable` binds all of .claude writable;
    only the P0.5 write census uses it.
    """
    argv = [BWRAP, "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--die-with-parent", "--new-session",
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
        # The state lives outside the published build (plan rev 15.4); the
        # build holds an empty mount point for each name.
        # Setup made every source and mount point; a hand-built home may not have.
        os.makedirs(str(home.state), mode=0o700, exist_ok=True)
        state_json, target = os.path.join(str(home.state), ".claude.json"), os.path.join(claude, ".claude.json")
        for path, data in ((state_json, b"{}\n"), (target, b"{}\n")):
            if not os.path.lexists(path):
                with open(path, "xb") as f:
                    f.write(data)
        argv += ["--ro-bind", state_json, target]
        for name, flag in (("backups", "--ro-bind"), *((n, "--bind") for n in state_dirs)):
            source, target = os.path.join(str(home.state), name), os.path.join(claude, name)
            os.makedirs(source, mode=0o700, exist_ok=True)
            os.makedirs(target, mode=0o700, exist_ok=True)
            argv += [flag, source, target]
    argv += ["--bind", str(home.scratchpad), str(home.scratchpad),
             "--perms", "0300", "--dir", TOKEN_DIR,
             "--chdir", str(home.workspace)]
    if seccomp_fd is not None:
        argv += ["--seccomp", str(seccomp_fd)]
    argv.append("--")
    return argv
