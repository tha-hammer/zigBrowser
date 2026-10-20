"""P0 contract commands: one real SDK turn, the token on route R1 (fd 3 through the wrapper).

`contract-config` runs a single ClaudeSDKClient turn and reports it as frames:
assistant_message (the final text of each assistant message), then result.
"""

import argparse
import asyncio
import errno
import os
import sys

from claude_agent_sdk import AssistantMessage, ClaudeSDKClient, ResultMessage, TextBlock

from . import options, probe, token
from .bridge import Bridge, deny_all
from .frames import Emitter


def add_turn_args(parser):
    parser.add_argument("--home", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--proxy")
    parser.add_argument("--fifo-dir", default="/run/zb-token")
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--mcp", action="store_true", help="register the zigbrowser echo tool")
    parser.add_argument("--mcp-tool-timeout-ms", type=int, default=options.MCP_TOOL_TIMEOUT_MS)
    parser.add_argument("--tool-deadline-ms", type=int)
    parser.add_argument("--probe-workspace", action="store_true",
                        help="report what creating a file in the workspace gives (EROFS in the sandbox)")
    parser.add_argument("--probe-syscalls", action="store_true",
                        help="report what ptrace and process_vm_readv give (EPERM under the outer seccomp filter)")


class Route:
    """R1's CLI env and cli_path for one session; close() drops the FIFO."""

    def __init__(self, home, value, fifo_dir):
        wrapper = home.runtime / "bin" / "zb-claude"
        if not wrapper.exists():
            wrapper.parent.mkdir(parents=True, exist_ok=True)
            token.write_wrapper(wrapper, token.bundled_cli())
        self._fifo = token.FifoHandoff(fifo_dir, value)
        self.env = self._fifo.env()
        self.cli_path = str(wrapper)

    def close(self):
        self._fifo.close()


def probe_workspace(home):
    try:
        fd = os.open(home.workspace / "helper-probe", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    except OSError as exc:
        return errno.errorcode.get(exc.errno, str(exc.errno))
    os.close(fd)
    return "created"


async def run_turn(args, value, out):
    home = options.AgentHome(args.home)
    if args.probe_workspace:
        out.emit("probe", session="contract", workspace_create=probe_workspace(home))
    if args.probe_syscalls:
        out.emit("probe", session="contract", syscalls=probe.syscalls())
    route = Route(home, value, args.fifo_dir)
    try:
        mcp = {}
        if args.mcp:
            deadline_ms = args.tool_deadline_ms or args.mcp_tool_timeout_ms - 10_000
            bridge = Bridge(out, "contract", deadline_ms / 1000, prompt=lambda: 1)  # the turn is its one prompt
            bridge.start()
            mcp = {"servers": {"zigbrowser": bridge.echo_server()}, "allowed": bridge.echo_tools(),
                   "can_use_tool": deny_all}
        opts = options.build(home, route_env=route.env, cli_path=route.cli_path,
                             base_url=args.base_url, proxy=args.proxy,
                             mcp_servers=mcp.get("servers"), allowed_tools=mcp.get("allowed", ()),
                             can_use_tool=mcp.get("can_use_tool"),
                             mcp_tool_timeout_ms=args.mcp_tool_timeout_ms,
                             stderr=lambda line: print(line, file=sys.stderr))
        async with ClaudeSDKClient(options=opts) as client:
            await client.query(args.prompt)
            async for message in client.receive_response():
                if isinstance(message, AssistantMessage):
                    text = "".join(b.text for b in message.content if isinstance(b, TextBlock))
                    if text:
                        out.emit("assistant_message", session="contract", text=text)
                elif isinstance(message, ResultMessage):
                    out.emit("result", session="contract", subtype=message.subtype,
                             is_error=message.is_error, num_turns=message.num_turns,
                             cost_usd=message.total_cost_usd)
    finally:
        route.close()


def main(argv):
    parser = argparse.ArgumentParser(prog="zb_agent_host contract-config")
    add_turn_args(parser)
    args = parser.parse_args(argv)
    home = options.AgentHome(args.home)
    value = token.read_token(3)
    environ = options.helper_environ(home, os.environ)
    os.environ.clear()
    os.environ.update(environ)
    out = Emitter()
    try:
        asyncio.run(run_turn(args, value, out))
    except Exception as exc:  # reported as a frame; the message never carries the token
        out.emit("error", session="contract", code="sdk", message=type(exc).__name__)
        return 1
    return 0
