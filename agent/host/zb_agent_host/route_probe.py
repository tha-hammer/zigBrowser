"""`python -m zb_agent_host probe-r1 --wrapper W --cli C` (chat-drawer plan rev 16.1,
§3c.7; S3.7): setup's R1 probe, run inside setup's own sandbox (setup.setup_sandbox):
a private network namespace, so its one-shot Messages API listens on that
namespace's 127.0.0.1 and the SDK and the CLI talk to it there, in plain HTTP.
No netd, relay, proxy, TLS name or test CA is involved: the probe tests only the
token's fd 3 path. It prints one JSON line, {"r1": true|false}, and exits 0; the
sandbox's death chain (setup helper, bwrap --die-with-parent, its PID namespace)
takes the CLI and anything it started with it.

macOS has no private network namespace, so setup's Seatbelt profile permits exactly one loopback port: setup binds
127.0.0.1:<port> outside the sandbox and hands the listener in, `--listen-fd N --listen-port P` (RoseCat 6958;
BlackRobin 6975). The probe adopts it only after checking it (adopt_listener) and serves on it; anything else exits
2 with no verdict, so R1 fails closed. Off Darwin both flags are refused."""

import argparse
import asyncio
import contextlib
import json
import os
import re
import secrets
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import options, proc_darwin, token

PROBE_TIMEOUT_S = 30
CENSUS_TIMEOUT_S = 10
CENSUS_REPLY_MAX = 64
PLATFORM = sys.platform


class ProbeRefused(Exception):
    """The listening socket setup handed in is not the one loopback listener it promised."""


def adopt_listener(fd, port):
    """macOS (RoseCat 6958; BlueBeaver 6961; BlackRobin 6975): setup binds 127.0.0.1:<port> outside the sandbox,
    whose profile permits only that port, and hands the listener in as `fd`. Adopt it only when it is an AF_INET
    SOCK_STREAM socket that is listening on exactly 127.0.0.1:<port>; otherwise close it and raise ProbeRefused."""
    try:
        if not stat.S_ISSOCK(os.fstat(fd).st_mode):
            raise ProbeRefused("the listen fd is not a socket")
        sock = socket.socket(fileno=fd)
    except OSError as exc:
        with contextlib.suppress(OSError):
            os.close(fd)
        raise ProbeRefused(f"the listen fd is unusable: {exc.strerror or exc}") from None
    except ProbeRefused:
        os.close(fd)
        raise
    try:
        if sock.family != socket.AF_INET or sock.type != socket.SOCK_STREAM:
            raise ProbeRefused("the listen fd is not an IPv4 stream socket")
        if not sock.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN):
            raise ProbeRefused("the listen fd is not listening")
        if sock.getsockname() != ("127.0.0.1", port):
            raise ProbeRefused(f"the listen fd is not on 127.0.0.1:{port}")
    except BaseException:
        sock.close()
        raise
    # It arrived through pass_fds, so it is inheritable here; the CLI under test, which the SDK spawns, must never
    # hold the probe server's listener (BlackRobin 6983). One that cannot be made so is refused (RoseCat 7041).
    try:
        sock.set_inheritable(False)
    except OSError:
        sock.close()
        raise ProbeRefused("the listen fd cannot be made non-inheritable") from None
    return sock


def _stream(text):
    message = {"id": "msg_probe", "type": "message", "role": "assistant", "model": "probe", "content": [],
               "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}}
    yield "message_start", {"type": "message_start", "message": message}
    yield "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}
    yield "content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}
    yield "content_block_stop", {"type": "content_block_stop", "index": 0}
    yield "message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                            "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


def _descendants_running(exe):
    """PIDs of our descendants whose executable is `exe`."""
    me, found = os.getpid(), []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.path.realpath(f"/proc/{entry}/exe") != exe:
                continue
        except OSError:
            continue
        pid = int(entry)
        while pid > 1:
            try:
                with open(f"/proc/{pid}/stat") as f:
                    pid = int(f.read().rsplit(")", 1)[1].split()[1])
            except (OSError, ValueError, IndexError):
                break
            if pid == me:
                found.append(int(entry))
                break
    return found


def adopt_census(fd):
    """macOS (BlueBeaver 7021): setup's end of the census socketpair, passed in as `fd`. Adopted only when it is an
    AF_UNIX SOCK_STREAM socket, then made non-inheritable (the CLI the SDK spawns must never hold it); otherwise it is
    closed and ProbeRefused is raised."""
    try:
        if not stat.S_ISSOCK(os.fstat(fd).st_mode):
            raise ProbeRefused("the census fd is not a socket")
        sock = socket.socket(fileno=fd)
    except OSError as exc:
        with contextlib.suppress(OSError):
            os.close(fd)
        raise ProbeRefused(f"the census fd is unusable: {exc.strerror or exc}") from None
    except ProbeRefused:
        os.close(fd)
        raise
    if sock.family != socket.AF_UNIX or sock.type != socket.SOCK_STREAM:
        sock.close()
        raise ProbeRefused("the census fd is not a Unix stream socket")
    try:
        sock.set_inheritable(False)
    except OSError:  # never continue with a capability the CLI could inherit (RoseCat 7041)
        sock.close()
        raise ProbeRefused("the census fd cannot be made non-inheritable") from None
    return sock


def _ask_census(sock, probe_token, url, timeout=CENSUS_TIMEOUT_S):
    """Asks setup, outside Seatbelt, whether any CLI holds the probe token (RoseCat 7019; BlueBeaver 7021): one line
    `census <token> <url>`, then setup's whole reply up to EOF. True only for exactly b"clean\n" in time."""
    deadline = time.monotonic() + timeout
    reply = b""
    try:
        sock.settimeout(timeout)
        sock.sendall(f"census {probe_token} {url}\n".encode())
        while len(reply) <= CENSUS_REPLY_MAX:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            sock.settimeout(remaining)
            chunk = sock.recv(CENSUS_REPLY_MAX + 1)
            if not chunk:
                break
            reply += chunk
    except OSError:
        return False
    return reply == b"clean\n"


def _cli_env_clean(cli, probe_token, canary):
    """True when no running CLI descendant holds the probe token in its environment.

    Linux (unchanged): /proc/<pid>/environ of each descendant running `cli`; at least one must be read.
    macOS: the probe never inspects processes (it shares Seatbelt with the CLI it tests, whose profile denies
    process-info; RoseCat 7019): the server asks setup's census instead (_ask_census), so here it is never clean."""
    if PLATFORM == "darwin":
        return False
    exe = os.path.realpath(cli)
    token_bytes = probe_token.encode()
    environs = []
    for pid in _descendants_running(exe):
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                environs.append(f.read())
        except OSError:
            pass
    return bool(environs) and all(token_bytes not in e for e in environs)


class _ProbeServer:
    """A one-shot loopback Messages API: records the bearer it receives and
    whether any running CLI process holds the probe token in its environment."""

    def __init__(self, probe_token, cli, listener=None, census=None):
        self.bearer = None
        self.cli_env_clean = None
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):  # noqa: N802 - http.server API
                length = int(self.headers.get("content-length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                if self.path.split("?", 1)[0] == "/v1/messages" and server.bearer is None:
                    server.bearer = self.headers.get("authorization", "")
                    if PLATFORM == "darwin":  # setup's census, outside Seatbelt (BlueBeaver 7021)
                        server.cli_env_clean = census is not None and _ask_census(census, probe_token, server.url)
                    else:
                        server.cli_env_clean = _cli_env_clean(cli, probe_token,
                                                              b"ANTHROPIC_BASE_URL=" + server.url.encode())
                if not body.get("stream"):
                    self._reply(200, "application/json", json.dumps({"type": "message", "content": []}).encode())
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("connection", "close")
                self.end_headers()
                for name, data in _stream("ok"):
                    self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
                self.close_connection = True

            def _reply(self, code, ctype, data):
                self.send_response(code)
                self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        if listener is None:
            self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        else:  # macOS: serve on the listener setup handed in; bind nothing of our own
            self.httpd = ThreadingHTTPServer(listener.getsockname(), Handler, bind_and_activate=False)
            self.httpd.socket.close()
            self.httpd.socket = listener
            self.httpd.server_address = listener.getsockname()
            # What HTTPServer.server_bind would set, so both paths behave the same (BlackRobin 6983).
            self.httpd.server_name = socket.getfqdn(self.httpd.server_address[0])
            self.httpd.server_port = self.httpd.server_address[1]
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def run(wrapper, cli, listener=None, census=None):
    """One turn through the real wrapper, FIFO and socket hand-off, with a
    random probe token, against the probe server on this namespace's own
    loopback. Runs with a throwaway HOME and config (no SAI, no hooks). True
    when the server saw `Bearer <probe>` and no CLI environment held it."""
    from claude_agent_sdk import query

    probe_token = "zb-probe-" + secrets.token_hex(24)
    server = _ProbeServer(probe_token, cli, listener, census=census)
    scratch = Path(tempfile.mkdtemp(prefix="zb-route-probe-"))
    try:
        home = options.AgentHome(scratch / "home")
        for sub in (home.claude_dir, home.workspace, home.tmp):
            sub.mkdir(mode=0o700, parents=True, exist_ok=True)
        handoff = token.FifoHandoff(scratch / "zb-token", probe_token)
        opts = options.build(home, route_env=handoff.env(), cli_path=str(wrapper), base_url=server.url)

        async def turn():
            async for _ in query(prompt="probe", options=opts):
                pass

        try:
            asyncio.run(asyncio.wait_for(turn(), PROBE_TIMEOUT_S))
        except BaseException as exc:  # noqa: BLE001 - the verdict is what the server saw
            if isinstance(exc, KeyboardInterrupt):
                raise
        finally:
            handoff.close()
        return server.bearer == f"Bearer {probe_token}" and server.cli_env_clean is True
    finally:
        server.close()
        if census is not None:
            census.close()
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host probe-r1")
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--listen-fd", action="append")
    parser.add_argument("--listen-port", action="append")
    parser.add_argument("--census-fd", action="append")
    args = parser.parse_args(argv)
    if PLATFORM != "darwin":
        if args.listen_fd is not None or args.listen_port is not None or args.census_fd is not None:
            print("zb_agent_host probe-r1: --listen-fd/--listen-port/--census-fd are macOS-only", file=sys.stderr)
            return 2
        print(json.dumps({"r1": run(Path(args.wrapper), args.cli)}), flush=True)
        return 0
    listener = None
    try:
        fd, port = _listen_args(args.listen_fd, args.listen_port)
        census_fd = _fd_arg(args.census_fd, "--census-fd")
        listener = adopt_listener(fd, port)
        census = adopt_census(census_fd)
    except ProbeRefused as exc:
        if listener is not None:
            listener.close()
        print(f"zb_agent_host probe-r1: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"r1": run(Path(args.wrapper), args.cli, listener, census)}), flush=True)
    return 0


def _fd_arg(raw, flag):
    """A required macOS fd flag, given once: ASCII decimal, no sign, leading zero or whitespace, 3 to 2**31-1."""
    if raw is None or len(raw) != 1:
        raise ProbeRefused(f"{flag} is required on macOS, once")
    if not _DECIMAL.fullmatch(raw[0]) or not 2 < int(raw[0]) < 2**31:
        raise ProbeRefused(f"{flag} must be a plain decimal fd, 3 to 2**31-1")
    return int(raw[0])


_DECIMAL = re.compile(r"[1-9][0-9]{0,9}", re.ASCII)


def _listen_args(raw_fds, raw_ports):
    """Both flags are required on macOS, each exactly once (RoseCat 6985): ASCII decimal with no sign, leading zero
    or whitespace; the fd above 2 and below 2**31, the port 1-65535."""
    if raw_fds is None or raw_ports is None:
        raise ProbeRefused("--listen-fd and --listen-port are required on macOS")
    if len(raw_fds) != 1 or len(raw_ports) != 1:
        raise ProbeRefused("--listen-fd and --listen-port are each given once")
    raw_fd, raw_port = raw_fds[0], raw_ports[0]
    if not (_DECIMAL.fullmatch(raw_fd) and _DECIMAL.fullmatch(raw_port)):
        raise ProbeRefused("--listen-fd and --listen-port must be plain decimal integers")
    fd, port = int(raw_fd), int(raw_port)
    if not 2 < fd < 2**31 or not 1 <= port <= 65535:
        raise ProbeRefused("--listen-fd must be 3 to 2**31-1 and --listen-port 1-65535")
    return fd, port
