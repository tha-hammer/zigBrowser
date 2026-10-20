"""The helper's side of browser tools: an in-process MCP server whose handlers ask
the app over stdout (tool_call) and wait for its answer on stdin (tool_result).

The helper answers on its own before the CLI's MCP_TOOL_TIMEOUT runs out
(options.TOOL_DEADLINE_S), so a silent browser yields an is_error result rather
than a CLI-side timeout.

S7.0 (chat-drawer plan rev 16.20.30): a call names the session's running prompt, which
`prompt` provides (the app's validator requires it since S5d); with none running nothing
is sent. A tool_result is matched by `id` alone, and one that is not pending here changes
nothing. In `chat` the Bridge reads no stdin: Chat hands it each tool_result (resolve).
Only the P0 contract command starts its own reader (start).
"""

import asyncio
import base64
import binascii
import json
import sys
import threading
import uuid

from claude_agent_sdk import PermissionResultDeny, create_sdk_mcp_server, tool

from .frames import encode

SERVER = "zigbrowser"
RESULT_MAX = 1 << 20  # a tool_result's line, as encode() writes it (section 3)
ERROR_MAX = 4096
IMAGE_MIMES = ("image/png", "image/jpeg")
BAD_RESULT = "the browser sent a bad result"


def tool_name(name):
    return f"mcp__{SERVER}__{name}"


def failed(text):
    return {"content": [{"type": "text", "text": text}], "is_error": True}


def _base64(text):
    try:
        base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return False
    return True


def _block(block):
    """A content block in section 3's grammar as the MCP block the model gets, or None."""
    if type(block) is not dict:
        return None
    if block.get("type") == "text" and set(block) == {"type", "text"} and type(block["text"]) is str:
        return {"type": "text", "text": block["text"]}
    if (block.get("type") == "image" and set(block) == {"type", "mime", "data_b64"} and block["mime"] in IMAGE_MIMES
            and type(block["data_b64"]) is str and _base64(block["data_b64"])):
        return {"type": "image", "data": block["data_b64"], "mimeType": block["mime"]}
    return None


def _envelope(frame):
    """The frame's own fields, when it carries its D7b envelope exactly ({"v":1,"seq":n}, n an
    integer of at least 1, as the app writes every frame; RoseCat 6538); else None."""
    v, seq = frame.get("v"), frame.get("seq")
    if type(v) is not int or v != 1 or type(seq) is not int or seq < 1:
        return None
    return set(frame) - {"v", "seq"}


def checked(frame, size=None):
    """S7.0.7: the handler's answer for a tool_result in section 3's grammar, or None when the
    frame is not in it (rev 16.20.32). The 1 MiB is the line as read (RoseCat 6526); with no
    `size`, the frame as encode() writes it."""
    fields = _envelope(frame)
    if fields is None or (len(encode(frame).encode()) if size is None else size) > RESULT_MAX \
            or type(frame.get("ok")) is not bool:
        return None
    if frame["ok"]:
        if fields != {"type", "session", "id", "ok", "content"} or type(frame["content"]) is not list:
            return None
        blocks = [_block(block) for block in frame["content"]]
        return None if None in blocks else {"content": blocks}
    error = frame.get("error")
    if fields != {"type", "session", "id", "ok", "error"} or type(error) is not str or not error \
            or len(error.encode()) > ERROR_MAX:
        return None
    return failed(error)


class Bridge:
    def __init__(self, out, session, deadline_s, prompt):
        self.out = out
        self.session = session
        self.deadline_s = deadline_s
        self.prompt = prompt  # the running prompt's id, or None
        self._pending = {}  # id -> the waiting call's future
        self._loop = None

    def start(self, stream=None):
        self._loop = asyncio.get_running_loop()
        threading.Thread(target=self._read, args=(stream or sys.stdin,), daemon=True).start()

    def _read(self, stream):
        for line in stream:
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            if frame.get("type") == "tool_result":
                self._loop.call_soon_threadsafe(self.resolve, frame, len(line.rstrip("\n").encode()))

    def resolve(self, frame, size=None):
        """The app's tool_result (Chat routes it by session): it answers the call it names
        by `id`, if that call is still waiting here; any other changes nothing. `size` is the
        line's length in bytes as it was read (without its newline)."""
        call_id = frame.get("id")
        future = self._pending.pop(call_id, None) if type(call_id) is str else None
        if future is None or future.done():
            return
        answer = checked(frame, size)
        if answer is None:  # its content never reaches the model
            self.out.emit("error", session=None, code="protocol", message="bad tool_result")
            answer = failed(BAD_RESULT)
        future.set_result(answer)

    def waiting(self):
        """The ids of the calls still waiting for their tool_result."""
        return sorted(self._pending)

    def prompt_ended(self):
        """The running prompt ended: each of its waiting calls ends, and its id is forgotten."""
        pending, self._pending = self._pending, {}
        for future in pending.values():
            if not future.done():
                future.set_result(None)

    async def call(self, name, args):
        prompt_id = self.prompt()
        if prompt_id is None:
            return failed("no prompt is running")  # the app would reject the frame
        call_id = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        self._pending[call_id] = future
        self.out.emit("tool_call", session=self.session, prompt_id=prompt_id, id=call_id, tool=tool_name(name),
                      args=args)
        try:
            answer = await asyncio.wait_for(future, self.deadline_s)
        except asyncio.TimeoutError:
            self._pending.pop(call_id, None)
            return failed("The browser did not answer in time.")
        return failed("the prompt ended") if answer is None else answer

    def server(self):
        @tool("echo", "Echoes the text back through the browser (contract tool).", {"text": str})
        async def echo(args):
            return await self.call("echo", {"text": args.get("text", "")})

        return create_sdk_mcp_server(SERVER, tools=[echo])

    @staticmethod
    def allowed_tools():
        return [tool_name("echo")]


async def deny_all(tool, _input, _context):
    """can_use_tool: nothing beyond the allowed in-process tools is ever approved."""
    print(f"zb_agent_host: denied tool {tool}", file=sys.stderr)
    return PermissionResultDeny(message="This tool is not available.")
