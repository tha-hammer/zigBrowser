"""`chat` (chat-drawer plan D7, D7b, rev 16 §3c; S3b): the helper the drawer talks to.

    python -m zb_agent_host chat --home H [--test-ca PEM]     (token on fd 3, read once)

The token reaches each CLI only on route R1 (FIFO -> zb-claude -> fd 3, §3c.1).
A token-route record other than R1 refuses with exit 2 before the token is read;
a legacy R3 record says R3 was removed. Every CLI gets the outer relay as its
proxy (§3c.2), and the test CA (named by launch, e2e only) in its environment.

stdin carries app frames (hello, open_session, prompt, interrupt,
end_session, shutdown); stdout carries helper frames, each validated by the
app. One ClaudeSDKClient per drawer session, built by the single options
builder. Text deltas are coalesced (at most one frame per 50 ms). The token
is never written anywhere; errors say what failed, never with the token."""

import argparse
import asyncio
import json
import os
import sys
import threading

from claude_agent_sdk import AssistantMessage, ClaudeSDKClient, ResultMessage, StreamEvent, TextBlock

from . import __version__, options, sandbox, token
from .contract import Route
from .files import atomic_write
from .frames import Emitter

DELTA_INTERVAL_S = 0.05
TOOL_DEADLINE_S = int(options.TOOL_DEADLINE_S)
APP_FRAMES = ("hello", "open_session", "prompt", "interrupt", "end_session", "shutdown", "tool_result")


class Session:
    def __init__(self, chat, session_id):
        self.chat, self.id = chat, session_id
        self.route = Route(chat.home, chat.token, chat.fifo_dir)
        self.opts = session_options(chat.home, route_env=self.route.env, cli_path=self.route.cli_path,
                                    e2e=chat.e2e, test_ca=chat.test_ca,
                                    stderr=lambda line: print(line, file=sys.stderr))
        self.client = ClaudeSDKClient(options=self.opts)

    async def open(self):
        await self.client.connect()
        self.chat.out.emit("session_opened", session=self.id, sdk_session_id=self.id)

    async def prompt(self, text):
        pending, last = [], 0.0
        loop = asyncio.get_running_loop()

        def flush():
            nonlocal pending, last
            if pending:
                self.chat.out.emit("assistant_delta", session=self.id, text="".join(pending)[:16 * 1024])
                pending, last = [], loop.time()

        await self.client.query(text)
        async for message in self.client.receive_response():
            if isinstance(message, StreamEvent):
                delta = (message.event or {}).get("delta") or {}
                if delta.get("type") == "text_delta":
                    pending.append(delta.get("text", ""))
                    if loop.time() - last >= DELTA_INTERVAL_S:
                        flush()
            elif isinstance(message, AssistantMessage):
                flush()
                text = "".join(b.text for b in message.content if isinstance(b, TextBlock))
                if text:
                    self.chat.out.emit("assistant_message", session=self.id, text=text[:256 * 1024])
            elif isinstance(message, ResultMessage):
                flush()
                self.chat.out.emit("result", session=self.id, subtype=message.subtype, is_error=message.is_error,
                                   num_turns=message.num_turns, cost_usd=message.total_cost_usd)

    async def close(self, reason="end"):
        try:
            await self.client.disconnect()
        finally:
            self.route.close()
            self.chat.out.emit("session_ended", session=self.id, reason=reason)


def session_options(home, *, route_env, cli_path, e2e, test_ca, stderr=None):
    """One session's ClaudeAgentOptions: the relay is the CLI's only proxy, whatever
    hello carried; hello's e2e object (§7 seams) may name only the test base URL."""
    return options.build(home, route_env=route_env, cli_path=cli_path, base_url=(e2e or {}).get("test_base_url"),
                         proxy=options.RELAY_PROXY, ca_file=test_ca, stderr=stderr)


class Chat:
    def __init__(self, home, token_value, fifo_dir=sandbox.TOKEN_DIR, test_ca=None):
        self.home, self.token = home, token_value
        self.fifo_dir, self.test_ca = fifo_dir, test_ca
        self.e2e = None
        self.out = Emitter()
        self.sessions = {}
        self.tasks = {}

    def error(self, code, message, session=None):
        self.out.emit("error", session=session, code=code, message=message[:1024])

    async def handle(self, frame):
        kind, sid = frame.get("type"), frame.get("session")
        if kind == "hello":
            self.e2e = frame.get("e2e")
            atomic_write(self.home.scratchpad / "helper-hello.json", json.dumps(frame), 0o600)
        elif kind == "open_session":
            session = Session(self, sid)
            self.sessions[sid] = session
            await session.open()
        elif kind == "prompt" and sid in self.sessions:
            self.tasks[sid] = asyncio.create_task(self._prompt(self.sessions[sid], frame.get("text", "")))
        elif kind == "interrupt" and sid in self.sessions:
            await self.sessions[sid].client.interrupt()
        elif kind == "end_session" and sid in self.sessions:
            task = self.tasks.pop(sid, None)
            if task is not None:
                task.cancel()
            await self.sessions.pop(sid).close("end")
        elif kind == "shutdown":
            return False
        elif kind == "tool_result":
            pass  # no browser tool exists before S7
        else:
            self.error("protocol", f"unexpected frame {kind!r}" if kind in APP_FRAMES else "unknown frame type", sid)
        return True

    async def _prompt(self, session, text):
        try:
            await session.prompt(text)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - reported as a frame, never with the token
            self.error("sdk", type(exc).__name__, session.id)

    async def run(self):
        self.out.emit("ready", version=__version__, route="R1", selfcheck={"ok": True, "failures": []},
                      tool_deadline_s=TOOL_DEADLINE_S)
        loop = asyncio.get_running_loop()
        lines = asyncio.Queue()
        threading.Thread(target=_pump, args=(sys.stdin, loop, lines), daemon=True).start()
        while True:
            line = await lines.get()
            if line is None:
                break
            try:
                frame = json.loads(line)
            except ValueError:
                self.error("protocol", "bad frame")
                continue
            if not isinstance(frame, dict) or not await self.handle(frame):
                break
        for sid in list(self.sessions):
            await self.sessions.pop(sid).close("end")


def _pump(stream, loop, queue):
    for line in stream:
        loop.call_soon_threadsafe(queue.put_nowait, line)
    loop.call_soon_threadsafe(queue.put_nowait, None)


def recorded_route(home):
    """The route --agent-setup recorded, or None when there is no readable record."""
    try:
        record = json.loads((home.runtime / "token-route.json").read_text())
        return record.get("route") if isinstance(record, dict) else None
    except (OSError, ValueError):
        return None


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host chat")
    parser.add_argument("--home", required=True)
    parser.add_argument("--test-ca")
    parser.add_argument("--fifo-dir", default=sandbox.TOKEN_DIR)  # only tests outside the sandbox move it
    args = parser.parse_args(argv)
    home = options.AgentHome(args.home)
    route = recorded_route(home)
    if route != "R1":
        try:
            os.close(3)  # the token is never read
        except OSError:
            pass
        print("zigBrowser: agent: token route R3 was removed: run zigBrowser --agent-setup again" if route == "R3"
              else "zigBrowser: agent: token route is not set up: run zigBrowser --agent-setup", file=sys.stderr)
        return 2
    out = Emitter()
    try:
        value = token.read_token(3)
    except (OSError, ValueError):
        out.emit("error", session=None, code="auth", message="no usable token")
        return 2
    asyncio.run(Chat(home, value, args.fifo_dir, args.test_ca).run())
    return 0
