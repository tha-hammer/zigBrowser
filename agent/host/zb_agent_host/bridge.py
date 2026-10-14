"""The helper's side of browser tools: an in-process MCP server whose handlers ask
the app over stdout (tool_call) and wait for its answer on stdin (tool_result).

The helper answers on its own before the CLI's MCP_TOOL_TIMEOUT runs out
(options.TOOL_DEADLINE_S), so a silent browser yields an is_error result rather
than a CLI-side timeout.
"""

import asyncio
import json
import sys
import threading
import uuid

from claude_agent_sdk import PermissionResultDeny, create_sdk_mcp_server, tool

SERVER = "zigbrowser"


def tool_name(name):
    return f"mcp__{SERVER}__{name}"


class Bridge:
    def __init__(self, out, session, deadline_s):
        self.out = out
        self.session = session
        self.deadline_s = deadline_s
        self._pending = {}
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
                self._loop.call_soon_threadsafe(self._resolve, frame)

    def _resolve(self, frame):
        future = self._pending.pop(frame.get("id"), None)
        if future is not None and not future.done():
            future.set_result(frame)

    async def call(self, name, args):
        call_id = str(uuid.uuid4())
        future = self._loop.create_future()
        self._pending[call_id] = future
        self.out.emit("tool_call", session=self.session, id=call_id, tool=tool_name(name), args=args)
        try:
            frame = await asyncio.wait_for(future, self.deadline_s)
        except asyncio.TimeoutError:
            self._pending.pop(call_id, None)
            return {"content": [{"type": "text", "text": "The browser did not answer in time."}], "is_error": True}
        if not frame.get("ok"):
            return {"content": [{"type": "text", "text": str(frame.get("error") or "failed")}], "is_error": True}
        return {"content": [c for c in frame.get("content", []) if c.get("type") == "text"]}

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
