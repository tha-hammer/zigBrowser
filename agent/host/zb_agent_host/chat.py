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
import contextlib
import json
import os
import sys
import threading

from claude_agent_sdk import AssistantMessage, ClaudeSDKClient, ResultMessage, StreamEvent, TextBlock

from . import __version__, options, sandbox, token
from .contract import Route
from .files import atomic_write
from .frames import Emitter, encode

DELTA_INTERVAL_S = 0.05
# S5.6 (rev 16.20.2): the app's validator caps (src/agent_protocol.zig), in bytes as
# it measures them: a delta's text, a message's text, and any frame's line.
DELTA_TEXT_MAX = 16 * 1024
MESSAGE_TEXT_MAX = 256 * 1024
FRAME_MAX = 256 * 1024
TRUNCATED = "\n[output truncated]"
# Rev 16.20.12: a bubble's text, the marker included, is at most MESSAGE_TEXT_MAX, so a
# reply's streamed content is at most this.
CONTENT_MAX = MESSAGE_TEXT_MAX - len(TRUNCATED.encode())
TOOL_DEADLINE_S = int(options.TOOL_DEADLINE_S)
APP_FRAMES = ("hello", "open_session", "prompt", "interrupt", "end_session", "shutdown", "tool_result")


# S5.3 (rev 16.14): the CLI reports an API error as an AssistantMessage whose `error`
# names it, and whose text echoes the server's own message. That text is never sent on:
# the prompt ends with an `error` frame in place of its `result` (one ending frame per
# prompt), and the app shows one fixed sentence per code.
API_ERROR_CODES = {"authentication_failed": "auth", "rate_limit": "overloaded", "server_error": "overloaded"}


def utf8_prefix(text, limit):
    """The longest prefix of `text` whose UTF-8 is at most `limit` bytes."""
    data = text.encode("utf-8", "replace")
    end = min(limit, len(data))
    while 0 < end < len(data) and (data[end] & 0xC0) == 0x80:
        end -= 1
    return data[:end].decode("utf-8")


def utf8_pieces(text, limit):
    """`text` in pieces of at most `limit` (>= 4) UTF-8 bytes, each cut on a character
    boundary; their join is `text`."""
    data = text.encode("utf-8", "replace")
    pieces, start = [], 0
    while start < len(data):
        end = min(start + limit, len(data))
        while end < len(data) and end > start and (data[end] & 0xC0) == 0x80:
            end -= 1
        pieces.append(data[start:end].decode("utf-8"))
        start = end
    return pieces


def fit_message(session, text, prompt_id=None):
    """`text` as one assistant_message: whole when its line and its text fit the
    app's caps, else its longest prefix that fits with TRUNCATED after it. The line is
    the frame as emitted, its prompt_id included (S5d; RoseCat 6307), at the largest seq
    the app accepts (a signed 64-bit integer; RoseCat 6314)."""
    def fits(candidate):
        line = encode({"v": 1, "seq": 2**63 - 1, "type": "assistant_message", "session": session,
                       "prompt_id": prompt_id, "text": candidate})
        return len(line.encode()) <= FRAME_MAX and len(candidate.encode("utf-8", "replace")) <= MESSAGE_TEXT_MAX
    if fits(text):
        return text
    low, high = 0, len(text)  # fits(text[:low] + TRUNCATED) holds; text[:high] + TRUNCATED does not
    while high - low > 1:
        mid = (low + high) // 2
        if fits(text[:mid] + TRUNCATED):
            low = mid
        else:
            high = mid
    return text[:low] + TRUNCATED


class Session:
    def __init__(self, chat, session_id):
        self.chat, self.id = chat, session_id
        self.task = None  # the one prompt in flight (RoseCat 5628.3)
        self._new_client()

    def _new_client(self):
        self.route = Route(self.chat.home, self.chat.token, self.chat.fifo_dir)
        self.opts = session_options(self.chat.home, route_env=self.route.env, cli_path=self.route.cli_path,
                                    e2e=self.chat.e2e, test_ca=self.chat.test_ca,
                                    stderr=lambda line: print(line, file=sys.stderr))
        self.client = ClaudeSDKClient(options=self.opts)

    async def renew(self):
        """S5c-1 (rev 16.20.9): the SDK client failed (its reader can die on a CLI message
        over its 1 MiB buffer, as an interrupted endless reply's is). A fresh CLI takes the
        session's place, so its next prompt is answered; that conversation's context is lost."""
        with contextlib.suppress(Exception):
            await self.client.disconnect()  # ends the old CLI (the SDK escalates to SIGKILL)
        self.route.close()
        self._new_client()
        await self.client.connect()

    @property
    def busy(self):
        return self.task is not None and not self.task.done()

    async def open(self):
        await self.client.connect()
        # No SDK session id exists yet: the CLI's own one comes with each result (RoseCat 5632).
        self.chat.out.emit("session_opened", session=self.id)

    async def prompt(self, text, prompt_id=None):
        pending, last = [], 0.0
        forwarded = 0  # the reply's delta bytes sent: the app shows at most CONTENT_MAX
        capped = False  # some of the reply did not fit: nothing more of its text is sent
        streamed = False  # deltas were sent since the last assistant message
        api_error = None
        loop = asyncio.get_running_loop()

        def flush():
            nonlocal pending, last, forwarded, capped, streamed
            if pending:
                # Nothing is dropped below the cap (S5.6). The deltas are exactly the reply's
                # longest prefix that fits CONTENT_MAX: the first code point that does not fit
                # ends them for the reply, and reply_capped says so (rev 16.20.11 to 16.20.13).
                for piece in [] if capped else utf8_pieces("".join(pending), DELTA_TEXT_MAX):
                    fit = utf8_prefix(piece, CONTENT_MAX - forwarded)
                    if fit:
                        self.chat.out.emit("assistant_delta", session=self.id, prompt_id=prompt_id, text=fit)
                        forwarded += len(fit.encode("utf-8"))
                        streamed = True
                    if fit != piece:
                        capped = True
                        self.chat.out.emit("reply_capped", session=self.id, prompt_id=prompt_id)
                        break
                pending, last = [], loop.time()

        await self.client.query(text)
        async for message in self.client.receive_response():
            if isinstance(message, StreamEvent):
                delta = (message.event or {}).get("delta") or {}
                if delta.get("type") == "text_delta":
                    pending.append(delta.get("text", ""))
                    if loop.time() - last >= DELTA_INTERVAL_S:
                        flush()
            elif isinstance(message, AssistantMessage) and message.error is not None:
                pending = []  # deltas of an error message are its text too
                api_error = message.error
            elif isinstance(message, AssistantMessage):
                flush()
                text = "".join(b.text for b in message.content if isinstance(b, TextBlock))
                fitted = fit_message(self.id, text, prompt_id) if text and not capped else None
                # Rev 16.20.13: a completed bubble never shrinks. After the cap nothing more of
                # the reply is sent, and a streamed message that its frame would cut is left
                # to its deltas.
                if fitted is not None and (fitted == text or not streamed):
                    self.chat.out.emit("assistant_message", session=self.id, prompt_id=prompt_id, text=fitted)
                streamed = False
            elif isinstance(message, ResultMessage) and api_error is not None:
                self.chat.error(API_ERROR_CODES.get(api_error, "sdk"), f"the API refused the request ({api_error})", self.id,
                                prompt_id)
            elif isinstance(message, ResultMessage):
                flush()
                self.chat.out.emit("result", session=self.id, prompt_id=prompt_id, sdk_session_id=message.session_id,
                                   subtype=message.subtype, is_error=message.is_error,
                                   num_turns=message.num_turns, cost_usd=message.total_cost_usd)

    async def close(self, reason="end"):
        """Cancels the prompt in flight and waits until it has stopped, then disconnects:
        nothing of this session is emitted after `session_ended`."""
        if self.task is not None:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            self.task = None
        try:
            await self.client.disconnect()
        finally:
            self.route.close()
            self.chat.out.emit("session_ended", session=self.id, reason=reason)


def session_options(home, *, route_env, cli_path, e2e, test_ca, stderr=None):
    """One session's ClaudeAgentOptions: the relay is the CLI's only proxy, whatever
    hello carried; hello's e2e object (§7 seams) may name only the test base URL."""
    base_url = (e2e or {}).get("test_base_url")
    return options.build(home, route_env=route_env, cli_path=cli_path, base_url=base_url,
                         max_retries=0 if base_url else None,
                         proxy=options.relay_proxy_url(), ca_file=test_ca, stderr=stderr)


class Chat:
    def __init__(self, home, token_value, fifo_dir=sandbox.TOKEN_DIR, test_ca=None):
        self.home, self.token = home, token_value
        self.fifo_dir, self.test_ca = fifo_dir, test_ca
        self.e2e = None
        self.out = Emitter()
        self.sessions = {}

    def error(self, code, message, session=None, prompt_id=None):
        """A session's error names its prompt (S5d): `prompt_id` is the prompt it ends, or
        None (null) while the session has none running. A helper-wide error has neither."""
        if session is None:
            self.out.emit("error", session=None, code=code, message=message[:1024])
        else:
            self.out.emit("error", session=session, prompt_id=prompt_id, code=code, message=message[:1024])

    async def handle(self, frame):
        kind, sid = frame.get("type"), frame.get("session")
        if kind == "hello":
            self.e2e = frame.get("e2e")
            atomic_write(self.home.scratchpad / "helper-hello.json", json.dumps(frame), 0o600)
        elif kind == "open_session":
            await self._open(sid)
        elif kind == "prompt" and sid in self.sessions:
            session = self.sessions[sid]
            if session.busy:
                self.error("busy", "a prompt is already running in this session", sid, frame.get("prompt_id"))
            else:
                session.task = asyncio.create_task(self._prompt(session, frame.get("text", ""), frame.get("prompt_id")))
        elif kind == "interrupt" and sid in self.sessions:
            await self.sessions[sid].client.interrupt()
        elif kind == "end_session" and sid in self.sessions:
            await self.sessions.pop(sid).close("end")
        elif kind == "shutdown":
            return False
        elif kind == "tool_result":
            pass  # no browser tool exists before S7
        else:
            self.error("protocol", f"unexpected frame {kind!r}" if kind in APP_FRAMES else "unknown frame type", sid)
        return True

    async def _open(self, sid):
        """A live id is never replaced (RoseCat 5633); a session that cannot open drops
        its route and is reported, and the helper goes on."""
        if sid in self.sessions:
            self.error("protocol", "session already open", sid)
            return
        session = Session(self, sid)
        try:
            await session.open()
        except Exception as exc:  # noqa: BLE001 - reported as a frame, never with the token
            session.route.close()
            with contextlib.suppress(Exception):
                await session.client.disconnect()
            self.error("sdk", f"session could not open ({type(exc).__name__})", sid)
            return
        self.sessions[sid] = session

    async def _prompt(self, session, text, prompt_id=None):
        try:
            await session.prompt(text, prompt_id)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - reported as a frame, never with the token
            with contextlib.suppress(Exception):  # before the error frame: the next prompt finds it ready
                await session.renew()
            self.error("sdk", type(exc).__name__, session.id, prompt_id)

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
