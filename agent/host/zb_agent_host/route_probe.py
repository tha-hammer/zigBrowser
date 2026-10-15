"""`python -m zb_agent_host probe-r1 --wrapper W --cli C` (chat-drawer plan rev 16.1,
§3c.7; S3.7): setup's R1 probe, run inside setup's own sandbox (setup.setup_sandbox):
a private network namespace, so its one-shot Messages API listens on that
namespace's 127.0.0.1 and the SDK and the CLI talk to it there, in plain HTTP.
No netd, relay, proxy, TLS name or test CA is involved: the probe tests only the
token's fd 3 path. It prints one JSON line, {"r1": true|false}, and exits 0; the
sandbox's death chain (setup helper, bwrap --die-with-parent, its PID namespace)
takes the CLI and anything it started with it."""

import argparse
import asyncio
import json
import os
import secrets
import shutil
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import options, token

PROBE_TIMEOUT_S = 30


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


class _ProbeServer:
    """A one-shot loopback Messages API: records the bearer it receives and
    whether any running CLI process holds the probe token in its environment."""

    def __init__(self, probe_token, cli):
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
                    environs = []
                    for pid in _descendants_running(os.path.realpath(cli)):
                        try:
                            with open(f"/proc/{pid}/environ", "rb") as f:
                                environs.append(f.read())
                        except OSError:
                            pass
                    server.cli_env_clean = bool(environs) and all(probe_token.encode() not in e for e in environs)
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

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def run(wrapper, cli):
    """One turn through the real wrapper, FIFO and socket hand-off, with a
    random probe token, against the probe server on this namespace's own
    loopback. Runs with a throwaway HOME and config (no SAI, no hooks). True
    when the server saw `Bearer <probe>` and no CLI environment held it."""
    from claude_agent_sdk import query

    probe_token = "zb-probe-" + secrets.token_hex(24)
    server = _ProbeServer(probe_token, cli)
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
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host probe-r1")
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--cli", required=True)
    args = parser.parse_args(argv)
    print(json.dumps({"r1": run(Path(args.wrapper), args.cli)}), flush=True)
    return 0
