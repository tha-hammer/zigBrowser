#!/usr/bin/python3 -I
"""zb-hook-run: runs one SAI hook in its own PID namespace, from an allowlisted environment.

Installed as <agent-home>/runtime/bin/zb-hook-run (read-only in the sandbox);
every hook command is rewritten as `zb-hook-run -- <command>`. In order it:
1. closes every descriptor >= 3, so no FIFO, socket or pipe of the CLI leaks;
2. builds a fresh environment holding only the names in runtime/hook-env.json
   (refusing the token names and the CLI's messaging capability outright);
3. execs bwrap with that environment (--clearenv plus --setenv per name), in a
   new PID and IPC namespace with its own /proc, the workspace and .claude.json
   read-only, and private /tmp, /run and /dev/shm. The CLI and the helper have no
   PID in there, so /proc/<pid>/environ, /proc/<pid>/mem and ptrace cannot name them.
Standard library only: it runs before, and outside of, the helper's venv.
"""

import json
import os
import sys

BWRAP = "/usr/bin/bwrap"
REFUSED = (
    "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "ZB_TOKEN_FIFO",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_MESSAGING_SOCKET",
)


def refused_names(names):
    return sorted(set(names) & set(REFUSED))


def bwrap_argv(home, env, command):
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
    argv += ["--unshare-pid", "--unshare-ipc", "--die-with-parent", "--new-session",
             "--bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
             "--tmpfs", "/tmp", "--tmpfs", "/run", "--tmpfs", "/dev/shm",
             "--bind", home, home, "--ro-bind", workspace, workspace]
    if os.path.exists(claude_json):
        argv += ["--ro-bind", claude_json, claude_json]
    argv += ["--", *command]
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
    os.closerange(3, os.sysconf("SC_OPEN_MAX"))
    env = {name: os.environ[name] for name in names if name in os.environ}
    os.execve(BWRAP, bwrap_argv(home, env, argv[1:]), env)
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
