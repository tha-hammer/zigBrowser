"""`launch` (chat-drawer plan D7, D12, rev 16 §3c.2; S3b): what the app spawns. It
builds the exact sandbox argv (P0's sandbox.helper_argv with the outer seccomp
filter, the venv and the hook command directories read-only, and its own network
namespace that sees only netd's egress/ and bridges/), then execs bwrap **in
place** with exactly the helper's environment, so bwrap keeps the PID the app
spawned and its PR_SET_PDEATHSIG. bwrap's command is the outer relay (proxy-only:
127.0.0.1:3128 -> /run/zb-net/egress/proxy.sock), which runs `chat`.

    python -m zb_agent_host launch --home H --python PY --net-dir DIR
        [--bwrap BWRAP] [--test-ca PEM] [--command chat|login] [--e2e-claude-cli CLI]

`--command login` (S6b1, rev 16.18.3) runs the one-shot sign-in helper instead of
`chat`: the backend's login launch spec (egress only: the login netd has no bridges)
and the outer relay running `login`. The login helper's token pipe, fd 4, passes
through untouched, as the chat helper's fd 3 does. `--e2e-claude-cli` (only from the
app under --e2e-protocol, only with `login`) names the fake setup-token CLI; its
directory is bound read-only. `--test-ca` is chat's only and is refused with `login`.

`--bwrap` and `--test-ca` are passed by the app only under --e2e-protocol
(plan section 7, BlueBeaver 5570): the test CA is bound read-only at
/run/zb-test-ca.pem and named to `chat`, which gives it to the CLI only. The
token descriptor (fd 3) passes through untouched. Exit 3 when bwrap is missing
(the drawer says "Agent sandbox unavailable"), 2 for a bad argument or home."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from dataclasses import dataclass

from . import options, sandbox, seccomp
from .platforms import posix_only

PLATFORM = sys.platform
EXIT_USAGE = 2
EXIT_NO_SANDBOX = 3


class UsageError(Exception):
    """A bad launch argument; main maps it to EXIT_USAGE."""


@dataclass(frozen=True)
class Session:
    """The per-launch carrier the lease/dispatch slice (7027/7035) will take as `backend.launch(session, ...)`.
    `egress_port` is the netd loopback port on macOS (from `--egress-port`), and None on Linux."""
    home: str
    python: str
    net_dir: str
    command: str
    egress_port: int | None


# --egress-port grammar: 1..65535, decimal, no leading zero (the same shape as netd's port / parseDarwinReadyPort).
_EGRESS_PORT = re.compile(r"[1-9][0-9]{0,4}", re.ASCII)


def _egress_port(raw):
    """`--egress-port`, fail-closed like setup's `--browser-pid`: required on Darwin (given exactly once, decimal
    1..65535, no leading zero), refused off Darwin. `raw` is argparse's append list (or None). Returns int|None."""
    if PLATFORM != "darwin":
        if raw is not None:
            raise UsageError("--egress-port is macOS-only")
        return None
    if raw is None or len(raw) != 1:
        raise UsageError("--egress-port is required on macOS, given once")
    value = raw[0]
    if not _EGRESS_PORT.fullmatch(value) or not (1 <= int(value) <= 65535):
        raise UsageError("--egress-port must be a decimal 1..65535 with no leading zero")
    return int(value)


def build_session(args):
    """Validate the per-launch args into the frozen `Session` carrier. Raises `UsageError` on a bad argument."""
    return Session(home=args.home, python=args.python, net_dir=args.net_dir, command=args.command,
                   egress_port=_egress_port(args.egress_port))
TEST_CA = "/run/zb-test-ca.pem"
# `python -I` ignores PYTHONPATH, so the helper's package (the home's read-only
# runtime/host copy) is put on sys.path by argument, and the helper's
# environment stays exactly options.HELPER_ENV_NAMES.
CHAT_BOOT = ("import runpy, sys; sys.path.insert(0, sys.argv.pop(1)); "
             "runpy.run_module('zb_agent_host', run_name='__main__', alter_sys=True)")


def build_argv(home, seccomp_fd, python, *, net_dir, bwrap=sandbox.BWRAP, test_ca=None, command="chat",
               claude_cli=None):
    venv = os.path.dirname(os.path.dirname(python))
    extra = [venv] + [d for d in json.loads((home.runtime / "path.json").read_text())
                      if d != "/usr" and not d.startswith("/usr/")]
    if command == "login":
        if claude_cli is not None:
            extra.append(os.path.dirname(claude_cli))
        argv = list(sandbox._LINUX_BACKEND.login_launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=extra,
                                                             net_dir=net_dir).argv)
        argv[0] = bwrap
        runtime = str(home.runtime)
        login = [python, "-I", "-c", CHAT_BOOT, f"{runtime}/host", "login", "--home", str(home.root)]
        if claude_cli is not None:
            login += ["--e2e-claude-cli", claude_cli]
        relay = ["/usr/bin/python3", "-I", "-S", f"{runtime}/bin/zb-net-relay", "--egress", sandbox.egress_dir()]
        return argv + relay + ["--", *login]
    argv = sandbox.helper_argv(home, seccomp_fd=seccomp_fd, ro_paths=extra, net_dir=net_dir)
    argv[0] = bwrap
    if test_ca is not None:
        argv[-1:-1] = ["--ro-bind", str(test_ca), TEST_CA]  # before the trailing "--"
    runtime = str(home.runtime)
    chat = [python, "-I", "-c", CHAT_BOOT, f"{runtime}/host", "chat", "--home", str(home.root)]
    if test_ca is not None:
        chat += ["--test-ca", TEST_CA]
    relay = ["/usr/bin/python3", "-I", "-S", f"{runtime}/bin/zb-net-relay", "--egress", sandbox.egress_dir()]
    return argv + relay + ["--", *chat]


def _regular_file(path):
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def main(argv):
    posix_only("launch")  # WS7.5: bwrap and execve
    parser = argparse.ArgumentParser(prog="zb_agent_host launch")
    parser.add_argument("--home", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--net-dir", required=True)
    parser.add_argument("--bwrap", default=sandbox.BWRAP)
    parser.add_argument("--test-ca")
    parser.add_argument("--command", choices=("chat", "login"), default="chat")
    parser.add_argument("--e2e-claude-cli")
    parser.add_argument("--egress-port", action="append")  # macOS only (netd's loopback port); refused off Darwin
    args = parser.parse_args(argv)
    if args.e2e_claude_cli is not None and (args.command != "login" or not os.path.isabs(args.e2e_claude_cli)
                                            or not _regular_file(args.e2e_claude_cli)):
        print("zigBrowser: agent: bad --e2e-claude-cli", file=sys.stderr)
        return EXIT_USAGE
    if args.test_ca is not None and args.command == "login":
        print("zigBrowser: agent: --test-ca is the chat helper's only", file=sys.stderr)
        return EXIT_USAGE
    if args.test_ca is not None and not _regular_file(args.test_ca):
        print("zigBrowser: agent: bad ZIGBROWSER_AGENT_NET_TEST_CA", file=sys.stderr)
        return EXIT_USAGE
    if not os.access(args.bwrap, os.X_OK):
        print("zigBrowser: agent: sandbox unavailable (bwrap)", file=sys.stderr)
        return EXIT_NO_SANDBOX
    try:
        session = build_session(args)
    except UsageError as exc:
        print(f"zigBrowser: agent: {exc}", file=sys.stderr)
        return EXIT_USAGE
    if PLATFORM == "darwin":
        # The port parses onto session.egress_port, but nothing reaches MacSeatbeltBackend until the lease/
        # dispatch slice (7027/7035) threads it in. Until then the macOS launch refuses, fail closed.
        print("zigBrowser: agent: the macOS launch is not ready", file=sys.stderr)
        return EXIT_USAGE
    home = options.AgentHome(session.home)
    fd = seccomp.seccomp_fd()
    try:
        command = build_argv(home, fd, session.python, net_dir=session.net_dir, bwrap=args.bwrap, test_ca=args.test_ca,
                             command=session.command, claude_cli=args.e2e_claude_cli)
    except (sandbox.SandboxError, OSError, ValueError) as exc:
        print(f"zigBrowser: agent: {exc}", file=sys.stderr)
        return EXIT_USAGE
    os.set_inheritable(fd, True)
    os.execve(args.bwrap, command, options.helper_environ(home, os.environ))
    return EXIT_NO_SANDBOX
