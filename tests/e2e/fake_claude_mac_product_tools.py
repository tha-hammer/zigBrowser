#!/usr/bin/python3
"""A deterministic Claude CLI stand-in for the installed Mac product test.

It speaks the Agent SDK's real bidirectional control protocol.  The fake only
replaces the network model: each SDK MCP request still crosses the in-process
zigbrowser server, native helper frame, product broker and bound WKWebView.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path


SESSION = "fake-mac-product-session"


def answer_setup_probe() -> int | None:
    """Behave like the real CLI for setup's version and R1 route probes."""
    if "--version" in sys.argv:
        print("2.1.301 (fake product tools)", flush=True)
        return 0
    base_url = os.environ.get("ANTHROPIC_BASE_URL")
    raw_fd = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR")
    if base_url is None or raw_fd is None:
        return None
    fd = int(raw_fd)
    chunks = []
    while True:
        chunk = os.read(fd, 1024)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(fd)
    token = b"".join(chunks).rstrip(b"\n").decode("ascii")
    request = urllib.request.Request(
        base_url + "/v1/messages",
        data=b'{"stream":false}',
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()
    return 0


def send(value: dict) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def receive() -> dict | None:
    line = sys.stdin.readline()
    if not line:
        return None
    try:
        value = json.loads(line)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def answer_sdk_initialize(frame: dict) -> bool:
    request = frame.get("request")
    if frame.get("type") != "control_request" or not isinstance(request, dict):
        return False
    if request.get("subtype") != "initialize":
        return False
    send(
        {
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": frame.get("request_id"),
                "response": {"commands": [], "output_style": "fake"},
            },
        }
    )
    return True


def assistant_tool(name: str, tool_id: str, arguments: dict) -> None:
    send(
        {
            "type": "assistant",
            "session_id": SESSION,
            "parent_tool_use_id": None,
            "message": {
                "id": f"msg-{tool_id}",
                "model": "fake-network-model",
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": tool_id, "name": name, "input": arguments}
                ],
                "stop_reason": "tool_use",
                "usage": {},
            },
        }
    )


def control_mcp(request_id: str, message: dict) -> dict:
    send(
        {
            "type": "control_request",
            "request_id": request_id,
            "request": {
                "subtype": "mcp_message",
                "server_name": "zigbrowser",
                "message": message,
            },
        }
    )
    while True:
        frame = receive()
        if frame is None:
            raise SystemExit(2)
        if answer_sdk_initialize(frame):
            continue
        response = frame.get("response")
        if (
            frame.get("type") == "control_response"
            and isinstance(response, dict)
            and response.get("request_id") == request_id
        ):
            return response


def append_evidence(path: Path, value: dict) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, json.dumps(value, separators=(",", ":")).encode() + b"\n")
    finally:
        os.close(fd)


def call_tool(evidence: Path, ordinal: int, name: str, arguments: dict) -> dict:
    full_name = f"mcp__zigbrowser__{name}"
    assistant_tool(full_name, f"tool-{ordinal}", arguments)
    append_evidence(evidence, {"event": "tool-waiting", "tool": full_name})
    response = control_mcp(
        f"tool-control-{ordinal}",
        {
            "jsonrpc": "2.0",
            "id": f"mcp-{ordinal}",
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
    )
    append_evidence(evidence, {"event": "tool-result", "tool": full_name, "response": response})
    return response


def tool_failed(response: dict) -> bool:
    try:
        mcp = response["response"]["mcp_response"]
        return "error" in mcp or bool(mcp.get("result", {}).get("isError"))
    except (KeyError, TypeError, AttributeError):
        return True


def main() -> int:
    probe_result = answer_setup_probe()
    if probe_result is not None:
        return probe_result
    home = Path(os.environ.get("HOME", ""))
    scratch = home / "scratchpad"
    target_file = scratch / "real-tools-target"
    evidence = scratch / "real-tools-evidence.jsonl"
    try:
        target = target_file.read_text(encoding="utf-8").strip()
    except OSError:
        return 2
    append_evidence(evidence, {"event": "fake-start"})

    while True:
        frame = receive()
        if frame is None:
            return 0
        if answer_sdk_initialize(frame):
            break

    while True:
        frame = receive()
        if frame is None:
            return 0
        if answer_sdk_initialize(frame):
            continue
        if frame.get("type") == "user":
            break

    control_mcp(
        "mcp-initialize",
        {
            "jsonrpc": "2.0",
            "id": "mcp-init",
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "zigbrowser-product-test", "version": "1"},
            },
        },
    )
    control_mcp(
        "mcp-initialized",
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
    )
    if tool_failed(call_tool(evidence, 1, "window_info", {})):
        return 1
    if tool_failed(call_tool(evidence, 2, "screenshot", {})):
        return 1
    calls = (
        ("button.artdeco-button", "plain-css"),
        ("css=#css-action", "css-prefix"),
        ("text=Text action", "text"),
        ('role=button[name="Role action"]', "role"),
        ("aria=Shadow action", "aria-shadow"),
        ("#frame-action", "same-origin-frame"),
        ("css=#delayed-action", "delayed-offscreen"),
        ("aria=Notifications", "notifications"),
        ("text=All saved leads", "saved-leads"),
        ("text=Accept", "accept"),
        ("text=/accept all/i", "accept-all"),
        ('text="Exact action"', "exact-action"),
    )
    for ordinal, (selector, _name) in enumerate(calls, 3):
        if tool_failed(call_tool(evidence, ordinal, "click", {"selector": selector})):
            return 1
    if tool_failed(call_tool(evidence, 15, "click", {"selector": "css=#nav-action"})):
        return 1
    if tool_failed(call_tool(evidence, 16, "navigate", {"url": target + "/heavy"})):
        return 1
    if tool_failed(call_tool(evidence, 17, "scroll", {"y": 600})):
        return 1
    missing = call_tool(evidence, 18, "click", {
        "selector": "css=.missing-messages-control",
    })
    if not tool_failed(missing):
        return 1

    send(
        {
            "type": "assistant",
            "session_id": SESSION,
            "parent_tool_use_id": None,
            "message": {
                "id": "msg-done",
                "model": "fake-network-model",
                "role": "assistant",
                "content": [{"type": "text", "text": "Screenshot and selector clicks completed."}],
                "stop_reason": "end_turn",
                "usage": {},
            },
        }
    )
    send(
        {
            "type": "result",
            "subtype": "success",
            "duration_ms": 1,
            "duration_api_ms": 0,
            "is_error": False,
            "num_turns": 1,
            "session_id": SESSION,
            "total_cost_usd": 0.0,
            "result": "Screenshot and selector clicks completed.",
        }
    )
    for frame in iter(receive, None):
        if answer_sdk_initialize(frame):
            continue
        request = frame.get("request")
        if frame.get("type") == "control_request" and isinstance(request, dict):
            send(
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": frame.get("request_id"),
                        "response": {},
                    },
                }
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
