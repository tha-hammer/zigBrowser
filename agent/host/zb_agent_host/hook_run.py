#!/usr/bin/python3 -I
"""zb-hook-run: runs one SAI hook in its own PID and network namespaces, from an allowlisted environment.

Installed as <agent-home>/runtime/bin/zb-hook-run (read-only in the sandbox);
every hook command is rewritten as `zb-hook-run -- <command>`. In order it:
1. closes every descriptor >= 3, so no FIFO, socket or pipe of the CLI leaks;
2. builds a fresh environment holding only the names in runtime/hook-env.json
   (refusing the token names, the CLI's messaging capability and its proxy outright);
3. only then puts the hook filter (hook_filter) in a fresh memfd at a descriptor
   >= 10, the only one it lets bwrap inherit;
4. execs bwrap with that environment (--clearenv plus --setenv per name), in a
   new PID, IPC and network namespace with its own /proc, the workspace and
   .claude.json read-only, and private /tmp, /run and /dev/shm. The CLI and the
   helper have no PID in there, so /proc/<pid>/environ, /proc/<pid>/mem and
   ptrace cannot name them. Of /run/zb-net only bridges/ comes back (read-only),
   and the hook runs under runtime/bin/zb-net-relay --bridges, so it reaches
   127.0.0.1:51091 and :31337 and nothing else: no proxy, DNS or other host
   (chat-drawer plan rev 16.2, §3c.8b). bwrap installs the filter last, after
   its own namespace and mount setup, and closes its descriptor: the relay and
   the hook run under it, on top of the helper's outer filter (§3c.6).
Standard library only: it runs before, and outside of, the helper's venv.
"""

import fcntl
import json
import os
import struct
import sys

BWRAP = "/usr/bin/bwrap"
REFUSED = (
    "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "ZB_TOKEN_FIFO",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_MESSAGING_SOCKET",
    "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
)
BRIDGES = "/run/zb-net/bridges"

# The hook filter (§3c.6), x86_64 only, like the outer one (seccomp.py).
AUDIT_ARCH_X86_64 = 0xC000003E
X32_SYSCALL_BIT = 0x40000000
HOOK_DENIED = (  # EPERM: no new namespaces, mounts or io_uring for a hook
    272, 308,                                # unshare, setns
    165, 166, 155,                           # mount, umount2, pivot_root
    428, 429, 430, 431, 432, 433, 442,       # open_tree, move_mount, fsopen, fsconfig, fsmount, fspick, mount_setattr
    425, 426, 427,                           # io_uring_setup, io_uring_enter, io_uring_register
)
NR_CLONE, NR_CLONE3 = 56, 435
# CLONE_NEWTIME, NEWNS, NEWCGROUP, NEWUTS, NEWIPC, NEWUSER, NEWPID, NEWNET
CLONE_NEW_ANY = 0x80 | 0x20000 | 0x02000000 | 0x04000000 | 0x08000000 | 0x10000000 | 0x20000000 | 0x40000000
RET_KILL_PROCESS, RET_ERRNO, RET_ALLOW = 0x80000000, 0x00050000, 0x7FFF0000
EPERM, ENOSYS = 1, 38
LD_W_ABS, JEQ_K, JGE_K, JSET_K, RET_K = 0x20, 0x15, 0x35, 0x45, 0x06


def refused_names(names):
    return sorted(set(names) & set(REFUSED))


def hook_filter():
    """The hook filter as raw classic BPF. Jumps are relative (i + 1 + k), and only forward:
    clone3 gets ENOSYS (glibc then falls back to clone), and clone with any
    CLONE_NEW* bit in its flags (args[0]) gets EPERM; fork, vfork and threads pass."""
    n = len(HOOK_DENIED)
    allow, enosys, eperm = 9 + n, 10 + n, 11 + n
    insns = [
        (LD_W_ABS, 0, 0, 4),                                 # 0: A = arch
        (JEQ_K, 1, 0, AUDIT_ARCH_X86_64),                    # 1: x86_64 -> 3
        (RET_K, 0, 0, RET_KILL_PROCESS),                     # 2: any other ABI
        (LD_W_ABS, 0, 0, 0),                                 # 3: A = nr
        (JGE_K, eperm - 5, 0, X32_SYSCALL_BIT),              # 4: x32 numbers
    ]
    for i, nr in enumerate(HOOK_DENIED):                     # 5 .. 4+n
        insns.append((JEQ_K, eperm - (6 + i), 0, nr))
    insns += [
        (JEQ_K, enosys - (6 + n), 0, NR_CLONE3),             # 5+n
        (JEQ_K, 0, allow - (7 + n), NR_CLONE),               # 6+n: clone -> its flags
        (LD_W_ABS, 0, 0, 16),                                # 7+n: A = low word of args[0]
        (JSET_K, eperm - (9 + n), 0, CLONE_NEW_ANY),         # 8+n
        (RET_K, 0, 0, RET_ALLOW),                            # 9+n
        (RET_K, 0, 0, RET_ERRNO | ENOSYS),                   # 10+n
        (RET_K, 0, 0, RET_ERRNO | EPERM),                    # 11+n
    ]
    return b"".join(struct.pack("<HBBI", *insn) for insn in insns)


def filter_fd():
    """hook_filter() in a memfd at a descriptor >= 10, inheritable: call it only after
    every inherited descriptor is closed, or that close would take it too."""
    fd = os.memfd_create("zb-hook-seccomp", os.MFD_CLOEXEC)
    try:
        data = hook_filter()
        while data:
            data = data[os.write(fd, data):]
        os.lseek(fd, 0, os.SEEK_SET)
        high = fcntl.fcntl(fd, fcntl.F_DUPFD, 10)
    finally:
        os.close(fd)
    os.set_inheritable(high, True)
    return high


def bwrap_argv(home, env, command, filter_fd=None):
    workspace = os.path.join(home, "workspace")
    claude_json = os.path.join(home, ".claude.json")
    argv = [BWRAP, "--clearenv"]
    for name, value in env.items():
        argv += ["--setenv", name, value]
    # Mounts apply in order: the host root first, then what replaces parts of it.
    # --dev: device nodes on the plain root bind cannot be opened inside the user
    # namespace (even /dev/null), so the hook gets bwrap's minimal /dev. The agent
    # home is mounted back over the private /tmp, /run and /dev/shm (it may live
    # under one of them), and the read-only binds come last.
    argv += ["--unshare-pid", "--unshare-ipc", "--unshare-net", "--die-with-parent", "--new-session",
             "--bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
             "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", "/dev/shm",
             "--bind", home, home, "--ro-bind", workspace, workspace]
    if os.path.exists(claude_json):
        argv += ["--ro-bind", claude_json, claude_json]
    # Its own network (§3c.8b): only netd's bridges/ comes back, read-only, and the
    # bridge-only relay gives the hook 127.0.0.1:51091 and :31337, nothing else.
    if filter_fd is not None:
        argv += ["--seccomp", str(filter_fd)]
    argv += ["--ro-bind", BRIDGES, BRIDGES, "--",
             "/usr/bin/python3", "-I", "-S", os.path.join(home, "runtime", "bin", "zb-net-relay"),
             "--bridges", BRIDGES, "--", *command]
    return argv


def main(argv):
    if len(argv) < 2 or argv[0] != "--":
        print("usage: zb-hook-run -- <hook command...>", file=sys.stderr)
        return 2
    runtime = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    home = os.path.dirname(runtime)
    with open(os.path.join(runtime, "hook-env.json")) as f:
        names = json.load(f)
    bad = refused_names(names)
    if bad:
        print(f"zb-hook-run: refused names in hook-env.json: {', '.join(bad)}", file=sys.stderr)
        return 2
    env = {name: os.environ[name] for name in names if name in os.environ}
    os.closerange(3, os.sysconf("SC_OPEN_MAX"))
    os.execve(BWRAP, bwrap_argv(home, env, argv[1:], filter_fd()), env)
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
