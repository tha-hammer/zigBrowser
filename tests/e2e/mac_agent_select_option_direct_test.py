#!/usr/bin/python3
"""Installed Mac product proof for approved agent option selection.

The tool crosses the native broker, visible approval card, automation server,
WKWebView, and the page. The page must observe both input and change events.
No Keychain is named or opened.
"""

from __future__ import annotations

import argparse
import http.server
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines
from mac_agent_click_direct_test import private_json, stop_owned, tool_rows
from mac_live_agent_test import install_dmg


ACTION_ENV = "ZB_DEBUG_MAC_AGENT_TOOLS_FILE"


class Site:
    def __init__(self) -> None:
        body = b"""<!doctype html><meta charset=utf-8><title>Agent select option</title>
<style>body{font:24px -apple-system;margin:40px}select{font:inherit;padding:12px}</style>
<h1>Agent select option test</h1>
<label>Search provider <select id=provider>
<option value="">Choose one</option><option value=google>Google</option>
<option value=zigbrowser>zigBrowser</option></select></label>
<pre id=state>value= events=0</pre>
<script>
window.selectState={events:[]};
const provider=document.querySelector('#provider');
for(const name of ['input','change']) provider.addEventListener(name,event=>{
  window.selectState.events.push({name,value:event.target.value,trusted:event.isTrusted});
  document.querySelector('#state').textContent=
    `value=${provider.value} events=${window.selectState.events.length}`;
});
</script>"""

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path.split("?", 1)[0] != "/select":
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
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/select"
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
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL mac-agent-select-option-direct: macOS is required", flush=True)
        return 1
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        print(f"FAIL mac-agent-select-option-direct: missing DMG {dmg}", flush=True)
        return 1
    root = Path(tempfile.mkdtemp(prefix="zb-sr-select-", dir=Path.home().resolve()))
    keep = True
    proc: subprocess.Popen[str] | None = None
    rpc: RpcClient | None = None
    try:
        app = install_dmg(dmg, root)
        executable = app / "Contents/MacOS/zigBrowser"
        private_home, data, cache, temp, profile = (
            root / name for name in ("home", "data", "cache", "tmp", "profile")
        )
        for directory in (private_home, data, cache, temp, profile):
            directory.mkdir(mode=0o700)
        action = root / "action.json"
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
            ACTION_ENV: str(action),
        }
        proc = subprocess.Popen(
            [str(executable), site.url, "--agent-drawer", "on", "--automation-api",
             "--e2e-protocol", "--profile-dir", str(profile)],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
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
            state = rpc.evaluate("({value:document.querySelector('#provider')?.value,"
                                 "events:window.selectState?.events||null})")
            if state == {"value": "", "events": []}:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("local select page did not become ready")

        private_json(action, {"version": 1, "steps": [{
            "id": "select-google", "tool": "mcp__zigbrowser__select_option",
            "args": {"selector": "css=#provider", "value": "google"},
        }]})
        deadline = time.monotonic() + args.timeout
        rows: list[tuple[str, bool, str]] = []
        while time.monotonic() < deadline:
            rows = tool_rows(out)
            if rows or proc.poll() is not None:
                break
            time.sleep(0.1)
        if not rows or not rows[0][1]:
            raise AssertionError(f"tool result was {rows!r}; stdout={out!r}; stderr={err!r}")
        if "MAC_AGENT_TOOL_APPROVAL\tpressed" not in out:
            raise AssertionError("real approval button was not pressed")
        state = rpc.evaluate("({value:document.querySelector('#provider').value,"
                             "events:window.selectState.events})")
        if not isinstance(state, dict) or state.get("value") != "google":
            raise AssertionError(f"selected value was {state!r}, want google")
        events = state.get("events")
        if [event.get("name") for event in events] != ["input", "change"]:
            raise AssertionError(f"page events were {events!r}, want input then change")
        if any(event.get("value") != "google" for event in events):
            raise AssertionError(f"page saw the wrong selected value: {events!r}")
        keep = False
        print("PASS mac-agent-select-option-direct: approved value reached page input and change", flush=True)
        return 0
    except Exception as error:
        print(f"FAIL mac-agent-select-option-direct: {type(error).__name__}: {error}", flush=True)
        print(f"EVIDENCE mac-agent-select-option-direct: {root}", flush=True)
        return 1
    finally:
        if rpc is not None:
            rpc.close()
        if proc is not None:
            stop_error = stop_owned(proc)
            if stop_error is not None:
                print(f"FAIL mac-agent-select-option-direct: {stop_error}", flush=True)
                keep = True
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    with Site() as select_site:
        raise SystemExit(main(select_site))
