#!/usr/bin/python3
"""Installed Mac product proof for approved native agent text entry.

The local page records the value and every key/input event. The product's
e2e-only tool seam still crosses the native broker, approval card, automation
server, WKWebView, and AppKit input path. No Keychain is named or opened.
"""

from __future__ import annotations

import argparse
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines
from mac_agent_click_direct_test import private_json, stop_owned, tool_rows
from mac_live_agent_test import install_dmg, png_size


ACTION_ENV = "ZB_DEBUG_MAC_AGENT_TOOLS_FILE"
TEXT = "Otter42"


class Site:
    def __init__(self) -> None:
        body = b"""<!doctype html><meta charset=utf-8><title>Agent type text</title>
<style>body{font:24px -apple-system;margin:40px}input{font:inherit;width:80%;padding:12px}</style>
<h1>Agent type text test</h1><input id=type-target autocomplete=off>
<pre id=state>value=</pre>
<script>
const target=document.querySelector('#type-target');
window.typeState={value:'',events:[]};
for(const name of ['keydown','keyup','input']) target.addEventListener(name,event=>{
  window.typeState.events.push({name,key:event.key||null,trusted:event.isTrusted});
  window.typeState.value=target.value;
  document.querySelector('#state').textContent=`value=${target.value}`;
});
</script>"""

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path != "/type":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                return

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/type"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def main(site: Site) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--png", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL mac-agent-type-text-direct: macOS is required", flush=True)
        return 1
    dmg = args.dmg.expanduser().resolve()
    png = args.png.expanduser().resolve()
    if not dmg.is_file():
        print(f"FAIL mac-agent-type-text-direct: missing DMG {dmg}", flush=True)
        return 1
    if not png.is_absolute() or not png.parent.is_dir() or png.exists():
        print(f"FAIL mac-agent-type-text-direct: invalid PNG output {png}", flush=True)
        return 1

    home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-otter-type-", dir=home))
    proc: subprocess.Popen | None = None
    rpc: RpcClient | None = None
    keep = True
    try:
        app = install_dmg(dmg, root)
        executable = app / "Contents/MacOS/zigBrowser"
        private_home, data, cache, temp, profile = (
            root / name for name in ("home", "data", "cache", "tmp", "profile")
        )
        for directory in (private_home, data, cache, temp, profile):
            directory.mkdir(mode=0o700)
        action = root / "type-action.json"
        socket_path = root / "automation.sock"
        env = {
            "HOME": str(private_home),
            "XDG_DATA_HOME": str(data),
            "XDG_CACHE_HOME": str(cache),
            "TMPDIR": str(temp),
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "ZIGBROWSER_SOCKET": str(socket_path),
            "ZB_DEBUG_DRAWER_ICON": "click",
            "ZB_DEBUG_MAC_AGENT_TOOLS_APPROVE": "1",
            "ZB_DEBUG_WINDOW_SNAPSHOT_PNG": str(png),
            "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS": "5000",
            ACTION_ENV: str(action),
        }
        proc = subprocess.Popen(
            [
                str(executable), site.url, "--agent-drawer", "on", "--automation-api",
                "--e2e-protocol", "--profile-dir", str(profile),
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        out: list[str] = []
        err: list[str] = []
        assert proc.stdout is not None and proc.stderr is not None
        threading.Thread(target=_read_lines, args=(proc.stdout, out), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, err), daemon=True).start()
        rpc = RpcClient(socket_path, min(args.timeout, 25.0))

        ready_deadline = time.monotonic() + min(args.timeout, 20.0)
        while time.monotonic() < ready_deadline:
            state = rpc.evaluate("window.typeState")
            if isinstance(state, dict) and state.get("value") == "":
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("local text page did not become ready")

        private_json(action, {
            "version": 1,
            "steps": [{
                "id": "type",
                "tool": "mcp__zigbrowser__type_text",
                "args": {"selector": "css=#type-target", "text": TEXT},
            }],
        })

        deadline = time.monotonic() + args.timeout
        rows: list[tuple[str, bool, str]] = []
        approved = False
        while time.monotonic() < deadline:
            rows = tool_rows(out)
            approved = "MAC_AGENT_TOOL_APPROVAL\tpressed" in out
            if rows:
                break
            if proc.poll() is not None:
                break
            time.sleep(0.1)

        if not rows or not rows[0][1]:
            print(f"FAIL mac-agent-type-text-direct: tool result was {rows!r}", flush=True)
            print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
            return 1
        if not approved:
            print("FAIL mac-agent-type-text-direct: real approval button was not pressed", flush=True)
            print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
            return 1
        state = rpc.evaluate("window.typeState")
        events = state.get("events", []) if isinstance(state, dict) else []
        keys = [event for event in events if event.get("name") in {"keydown", "keyup"}]
        inputs = [event for event in events if event.get("name") == "input"]
        if state.get("value") != TEXT or not keys or not inputs:
            print(f"FAIL mac-agent-type-text-direct: page state was {state!r}", flush=True)
            print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
            return 1
        if any(event.get("trusted") is not True for event in keys + inputs):
            print(f"FAIL mac-agent-type-text-direct: untrusted event in {events!r}", flush=True)
            print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
            return 1
        png_deadline = time.monotonic() + min(args.timeout, 15.0)
        dimensions = None
        while time.monotonic() < png_deadline:
            dimensions = png_size(png)
            if dimensions is not None:
                break
            time.sleep(0.1)
        if dimensions is None:
            print(f"FAIL mac-agent-type-text-direct: in-app PNG is unreadable: {png}", flush=True)
            print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
            return 1
        keep = False
        print(f"PNG mac-agent-type-text-direct: {png} {dimensions[0]}x{dimensions[1]}", flush=True)
        print("PASS mac-agent-type-text-direct: approved trusted text reached local input", flush=True)
        return 0
    except Exception as error:
        print(f"FAIL mac-agent-type-text-direct: {type(error).__name__}: {error}", flush=True)
        print(f"EVIDENCE mac-agent-type-text-direct: {root}", flush=True)
        return 1
    finally:
        if rpc is not None:
            rpc.close()
        if proc is not None:
            stop_error = stop_owned(proc)
            if stop_error is not None:
                keep = True
                print(f"LEAK mac-agent-type-text-direct: {stop_error}", flush=True)
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    with Site() as type_site:
        raise SystemExit(main(type_site))
