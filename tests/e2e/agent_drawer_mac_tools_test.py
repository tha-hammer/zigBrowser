#!/usr/bin/env python3
"""Product e2e: Mac drawer tools act on their stable browser window.

The real browser opens a loopback page with its native drawer.  Under
--e2e-protocol only, a private action file supplies the fake agent's ordered
navigate, get_text and click tool calls.  Product result rows are the fake
agent's received tool_result values; the automation socket is used only as an
independent observer of the page that was actually changed.
"""

from __future__ import annotations

import base64
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines
from mac_ms2a_routed_test import stop_browser_macos


ROW = "MAC_AGENT_TOOL\t"
ACTION_ENV = "ZB_DEBUG_MAC_AGENT_TOOLS_FILE"


class Site:
    def __init__(self) -> None:
        pages = {
            "/start": "<!doctype html><title>Start</title><p>before</p>",
            "/target": (
                "<!doctype html><title>Agent Target</title>"
                '<p id="message">Agent reached target</p>'
                '<button id="act" onclick="document.getElementById(\'state\').textContent=\'clicked by agent\'">Act</button>'
                '<p id="state">idle</p>'
            ),
        }

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                body = pages.get(self.path)
                if body is None:
                    self.send_error(404)
                    return
                data = body.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_args):
                return

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def write_private(path: Path, value: dict) -> None:
    raw = json.dumps(value, separators=(",", ":")).encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, raw)
    finally:
        os.close(fd)


def tool_rows(lines: list[str]) -> list[tuple[str, bool, str]]:
    rows = []
    for line in lines:
        if not line.startswith(ROW):
            continue
        fields = line.split("\t")
        if len(fields) != 4 or fields[2] not in {"0", "1"}:
            continue
        try:
            body = base64.b64decode(fields[3], validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        rows.append((fields[1], fields[2] == "1", body))
    return rows


def main() -> int:
    browser = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zigBrowser").resolve()
    if not browser.is_file():
        print(f"FAIL agent-drawer-mac-tools: missing browser {browser}", file=sys.stderr)
        return 1

    failures: list[str] = []
    with Site() as site, tempfile.TemporaryDirectory(prefix="zb-mac-agent-tools-") as raw:
        root = Path(raw)
        profile, xdg_data, xdg_cache, temp = (root / name for name in ("profile", "data", "cache", "tmp"))
        for directory in (profile, xdg_data, xdg_cache, temp):
            directory.mkdir(mode=0o700)
        action = root / "tools.json"
        target = f"{site.origin}/target"
        write_private(
            action,
            {
                "version": 1,
                "steps": [
                    {"id": "navigate", "tool": "mcp__zigbrowser__navigate", "args": {"url": target}},
                    {"id": "read", "tool": "mcp__zigbrowser__get_text", "args": {"selector": "css=#message"}},
                    {"id": "click", "tool": "mcp__zigbrowser__click", "args": {"selector": "css=#act"}},
                ],
            },
        )
        socket_path = root / "automation.sock"
        env = dict(os.environ)
        env.update(
            {
                "TMPDIR": str(temp),
                "XDG_DATA_HOME": str(xdg_data),
                "XDG_CACHE_HOME": str(xdg_cache),
                "ZIGBROWSER_SOCKET": str(socket_path),
                "ZB_DEBUG_DRAWER_LAYOUT": "1",
                ACTION_ENV: str(action),
            }
        )
        proc = subprocess.Popen(
            [
                str(browser),
                f"{site.origin}/start",
                "--agent-drawer",
                "on",
                "--automation-api",
                "--e2e-protocol",
                "--profile-dir",
                str(profile),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        out: list[str] = []
        err: list[str] = []
        threading.Thread(target=_read_lines, args=(proc.stdout, out), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, err), daemon=True).start()
        rpc = None
        try:
            rpc = RpcClient(socket_path, 20.0)
            deadline = time.monotonic() + 25.0
            rows: list[tuple[str, bool, str]] = []
            while time.monotonic() < deadline:
                rows = tool_rows(out)
                if [row[0] for row in rows] == ["navigate", "read", "click"]:
                    break
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
            if [row[0] for row in rows] != ["navigate", "read", "click"]:
                failures.append(f"fake agent received {rows!r}, want navigate/read/click")
            elif not all(row[1] for row in rows):
                failures.append(f"a browser tool failed: {rows!r}")
            elif "Agent reached target" not in rows[1][2]:
                failures.append(f"read-page result did not reach the fake agent: {rows[1][2]!r}")

            url = rpc.call("page.url", {"window_id": "window-1"})["url"]
            if url != target:
                failures.append(f"drawer window did not navigate: {url!r}")
            state = rpc.call(
                "dom.getText", {"selector": "css=#state", "window_id": "window-1"}
            )["text"]
            if state != "clicked by agent":
                failures.append(f"drawer window was not clicked: {state!r}")
        except Exception as exc:  # noqa: BLE001
            failures.append(f"tool flow did not finish: {exc}")
        finally:
            if rpc is not None:
                rpc.close()
            stop_browser_macos(proc)

    if failures:
        print(f"FAIL agent-drawer-mac-tools: {failures[0]}", file=sys.stderr)
        for failure in failures[1:]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print("PASS agent-drawer-mac-tools stable-window navigate-read-click")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
