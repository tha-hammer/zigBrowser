"""`launch` (chat-drawer plan D7, D12, rev 16 §3c.2; S3b): what the app spawns. It
builds the exact sandbox argv (P0's sandbox.helper_argv with the outer seccomp
filter, the venv and the hook command directories read-only, and its own network
namespace that sees only netd's egress/ and bridges/), then execs bwrap **in
place** with exactly the helper's environment, so bwrap keeps the PID the app
spawned and its PR_SET_PDEATHSIG. bwrap's command is the outer relay (proxy-only:
127.0.0.1:3128 -> /run/zb-net/egress/proxy.sock), which runs `chat`.

    python -m zb_agent_host launch --home H --python PY --net-dir DIR
        [--bwrap BWRAP] [--test-ca PEM] [--command chat|login] [--e2e-claude-cli CLI]

On macOS the normal path always uses ``sandbox-exec`` through
``MacSeatbeltBackend``.  A direct, unsandboxed launch exists only for local
diagnostics and requires the explicit ``--unsandboxed-dev`` flag.

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
import contextlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from typing import NamedTuple

from . import options, sandbox, sandbox_macos, seccomp
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
    net_dir: str | None  # Linux-required, refused on macOS (main)
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


@dataclass(frozen=True)
class LaunchRequest:
    """One helper launch, backend-neutral (MS6.8; SilverRidge a365949c): what to run (home, python, command), the
    read paths it needs, and its command's e2e inputs. The realization fields are one backend's: Linux requires the
    seccomp fd and netd's socket dir and may take a bwrap override; macOS takes none of them."""
    home: options.AgentHome
    python: str
    command: str = "chat"
    read_paths: tuple = ()
    test_ca: str | None = None  # chat only
    claude_cli: str | None = None  # login only
    seccomp_fd: int | None = None
    net_dir: str | None = None
    bwrap: str | None = None


class LaunchPlan(NamedTuple):
    argv: tuple
    spec: sandbox.LaunchSpec


def requested_reads(home, python, claude_cli=None, test_ca=None):
    """The helper's read paths: Python packages, hook command directories, and optional login/test inputs."""
    venv = os.path.dirname(os.path.dirname(python))
    extra = [venv]
    # The macOS bundle places third-party packages beside Python.framework,
    # rather than below Versions/<version>.  The inner helper imports those
    # packages under Seatbelt, so grant that exact containing agent-host tree.
    marker = f"{os.sep}Python.framework{os.sep}Versions{os.sep}"
    if PLATFORM == "darwin" and marker in python:
        agent_host = python.split(marker, 1)[0]
        extra += [agent_host, os.path.join(agent_host, "site-packages")]
        frameworks = os.path.dirname(agent_host)
        if os.path.basename(frameworks) == "Frameworks":
            extra.append(os.path.join(os.path.dirname(frameworks), "Resources",
                                      os.path.basename(agent_host), "site-packages"))
    extra += [d for d in json.loads((home.runtime / "path.json").read_text())
              if d != "/usr" and not d.startswith("/usr/")]
    if claude_cli is not None:
        extra.append(os.path.dirname(claude_cli))
    if test_ca is not None:
        extra.append(test_ca)
    return tuple(extra)


@contextlib.contextmanager
def build_launch(backend, request):
    """The helper's launch over the backend Protocol (MS6.8), for exactly the extent of the spawn: the backend's
    lease, then the outer relay when the spec has a relay socket dir, else the spec's direct loopback port handed to
    the inner helper. Yields a LaunchPlan."""
    binds = getattr(backend, "SANDBOX_PROGRAM", None) == sandbox.BWRAP
    if request.bwrap is not None and not binds:
        raise sandbox.UnsupportedLaunchInput("--bwrap is the Linux sandbox's only")
    network = backend.login_network() if request.command == "login" else None
    with backend.launch(request.home, seccomp_fd=request.seccomp_fd, ro_paths=request.read_paths,
                        net_dir=request.net_dir, network=network) as spec:
        argv = list(spec.argv)
        if request.bwrap is not None:
            argv[0] = request.bwrap
        runtime = str(request.home.runtime)
        inner = [request.python, "-I", "-c", CHAT_BOOT, f"{runtime}/host", request.command,
                 "--home", str(request.home.root)]
        if request.command == "chat" and isinstance(
                backend, (sandbox_macos.MacSeatbeltBackend, sandbox_macos.MacUnsandboxedDevBackend)):
            # Linux supplies /run/zb-token inside bwrap.  A Mac has no /run
            # bind and its only writable capability is the agent scratchpad.
            inner += ["--fifo-dir", str(request.home.scratchpad / "token-fifo")]
        if request.command == "chat" and request.test_ca is not None:
            if binds:
                argv[-1:-1] = ["--ro-bind", str(request.test_ca), TEST_CA]  # before the trailing "--"
            inner += ["--test-ca", TEST_CA if binds else str(request.test_ca)]
        if request.command == "login" and request.claude_cli is not None:
            inner += ["--e2e-claude-cli", request.claude_cli]
        egress = spec.network.egress
        if egress.dir is not None:
            argv += ["/usr/bin/python3", "-I", "-S", f"{runtime}/bin/zb-net-relay", "--egress", egress.dir, "--"]
        else:
            inner += ["--egress-port", str(egress.endpoint.port)]
        yield LaunchPlan(tuple(argv + inner), spec)


def build_argv(home, seccomp_fd, python, *, net_dir, bwrap=sandbox.BWRAP, test_ca=None, command="chat",
               claude_cli=None):
    """The Linux launch argv (the compatibility wrapper): build_launch over an explicit LinuxBwrapBackend."""
    request = LaunchRequest(home=home, python=python, command=command,
                            read_paths=requested_reads(home, python, claude_cli if command == "login" else None),
                            test_ca=test_ca, claude_cli=claude_cli, seccomp_fd=seccomp_fd, net_dir=net_dir,
                            bwrap=bwrap)
    with build_launch(sandbox.LinuxBwrapBackend(), request) as plan:
        return list(plan.argv)


def _token_fds():
    """The helper's token descriptors that are open here (chat's fd 3, login's fd 4), passed through to it."""
    fds = []
    for fd in (3, 4):
        try:
            os.fstat(fd)
        except OSError:
            continue
        fds.append(fd)
    return tuple(fds)


def spawn_helper(argv, env, *, pass_fds=None):
    """Runs the sandboxed helper as a child and returns its status (macOS: the lease must outlive the spawn, so the
    launch cannot exec in place)."""
    token_fds = _token_fds() if pass_fds is None else tuple(pass_fds)
    return subprocess.run(list(argv), env=env, pass_fds=token_fds, check=False).returncode


def _arm_darwin_watches(session_canary=None):
    """Arm the group kill and, for Seatbelt, the out-of-group sandbox-identity reaper.

    The native browser spawner makes this process the leader of a fresh group;
    direct diagnostic invocations do not have that ownership proof and keep
    their existing behavior.  A launch already reparented to launchd is treated
    as browser death by giving ``arm`` an impossible expected parent.
    """
    if sys.platform != "darwin":
        return False, False
    try:
        if os.getpgid(0) != os.getpid():
            return False, False
    except OSError:
        return False, False
    browser_pid = os.getppid()
    # Keep the Darwin watcher out of the portable launch module's import
    # closure.  Diagnostic launches that do not own their process group do
    # not arm it, while the native group leader loads the existing fail-closed
    # kqueue implementation only after proving group ownership.
    from . import parent_watch  # noqa: PLC0415
    browser_pid = browser_pid if browser_pid > 1 else 0
    reaper = False
    if session_canary is not None and browser_pid > 1:
        # Fork before DarwinOps starts its watcher thread. The child calls setsid(), so the accepted group
        # SIGKILL cannot kill the only observer capable of finding a setsid/double-fork escapee.
        reaper = parent_watch.spawn_session_reaper(browser_pid, os.getpid(), session_canary)
    return parent_watch.arm(browser_pid, parent_watch.DarwinOps()), reaper


def _arm_darwin_browser_watch():
    """Compatibility wrapper for the accepted group-only watcher."""
    watched, _reaper = _arm_darwin_watches()
    return watched


def _launch_darwin(session, args, backend):
    # Capture the token channel before kqueue opens: when fd 3/4 is absent in a
    # diagnostic run, kqueue may receive that number, but it is a lifetime
    # observer and must never be mistaken for a token descriptor at exec.
    token_fds = _token_fds()
    home = options.AgentHome(session.home)
    request = LaunchRequest(home=home, python=session.python, command=session.command,
                            read_paths=requested_reads(home, session.python, args.e2e_claude_cli, args.test_ca),
                            test_ca=args.test_ca, claude_cli=args.e2e_claude_cli)
    try:
        with build_launch(backend, request) as plan:
            # build_launch has now materialized the real per-session canary, but no sandboxed child exists yet.
            # Arm the forked observer before DarwinOps starts a thread, then retain the accepted group watcher.
            session_canary = getattr(backend, "session_canary", None)
            watched, reaper_armed = _arm_darwin_watches(session_canary)
            try:
                env = options.helper_environ(home, os.environ)
                if watched:
                    return spawn_helper(plan.argv, env, pass_fds=token_fds)
                return spawn_helper(plan.argv, env)
            except OSError as exc:
                print(f"zigBrowser: agent: sandbox unavailable ({exc})", file=sys.stderr)
                return EXIT_NO_SANDBOX
            finally:
                # A diagnostic/non-group launch has no observer. Do not leak its canary after the child returns.
                if session_canary is not None and not reaper_armed:
                    release = getattr(backend, "release_session_canary", None)
                    if release is not None:
                        release()
    except (sandbox.SandboxError, OSError, ValueError) as exc:
        print(f"zigBrowser: agent: {exc}", file=sys.stderr)
        return EXIT_USAGE


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
    parser.add_argument("--net-dir")  # Linux-required, refused on macOS
    parser.add_argument("--bwrap")  # Linux only (default sandbox.BWRAP)
    parser.add_argument("--test-ca")
    parser.add_argument("--command", choices=("chat", "login"), default="chat")
    parser.add_argument("--e2e-claude-cli")
    parser.add_argument("--egress-port", action="append")  # macOS only (netd's loopback port); refused off Darwin
    parser.add_argument("--unsandboxed-dev", action="store_true")  # macOS-only, explicit unsafe development escape
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
    # The Session parse + the Darwin fail-closed branch come BEFORE touching bwrap (RoseCat 820a978): a real Mac
    # has no bwrap, so a valid --egress-port must give the EXIT_USAGE "not ready", never the bwrap EXIT_NO_SANDBOX.
    try:
        session = build_session(args)
    except UsageError as exc:
        print(f"zigBrowser: agent: {exc}", file=sys.stderr)
        return EXIT_USAGE
    if PLATFORM == "darwin":
        for flag, value in (("--net-dir", args.net_dir), ("--bwrap", args.bwrap)):
            if value is not None:
                print(f"zigBrowser: agent: {flag} is the Linux launch's only", file=sys.stderr)
                return EXIT_USAGE
        if args.unsandboxed_dev:
            print(sandbox_macos.UNSANDBOXED_DEV_STATUS, file=sys.stderr)
            backend = sandbox_macos.MacUnsandboxedDevBackend(
                session.egress_port, explicit_dev=args.unsandboxed_dev)
        else:
            # The drawer's production default is always Seatbelt. PROFILE_CURATION still records whether the
            # profile has reached release curation, but it must never select a host-rights launch.
            backend = sandbox_macos.MacSeatbeltBackend(session.egress_port)
        return _launch_darwin(session, args, backend)
    if args.unsandboxed_dev:
        print("zigBrowser: agent: --unsandboxed-dev is macOS-only", file=sys.stderr)
        return EXIT_USAGE
    if session.net_dir is None:
        print("zigBrowser: agent: --net-dir is required", file=sys.stderr)
        return EXIT_USAGE
    bwrap = args.bwrap if args.bwrap is not None else sandbox.BWRAP
    if not os.access(bwrap, os.X_OK):
        print("zigBrowser: agent: sandbox unavailable (bwrap)", file=sys.stderr)
        return EXIT_NO_SANDBOX
    home = options.AgentHome(session.home)
    fd = seccomp.seccomp_fd()
    try:
        command = build_argv(home, fd, session.python, net_dir=session.net_dir, bwrap=bwrap, test_ca=args.test_ca,
                             command=session.command, claude_cli=args.e2e_claude_cli)
    except (sandbox.SandboxError, OSError, ValueError) as exc:
        print(f"zigBrowser: agent: {exc}", file=sys.stderr)
        return EXIT_USAGE
    os.set_inheritable(fd, True)
    os.execve(bwrap, command, options.helper_environ(home, os.environ))
    return EXIT_NO_SANDBOX
