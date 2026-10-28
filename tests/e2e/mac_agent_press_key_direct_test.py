#!/usr/bin/python3
"""Installed Mac product proof for approved native agent key presses.

Each requested key crosses the native broker, visible approval card,
automation server, WKWebView, and AppKit input path. No Keychain is named or
opened. The local page records trusted keyboard events and Enter submission.
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
KEYS = ("Enter", "Tab", "Escape", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown")


class Site:
    def __init__(self) -> None:
        body = b"""<!doctype html><meta charset=utf-8><title>Agent press key</title>
<style>body{font:24px -apple-system;margin:40px}input{font:inherit;padding:12px}</style>
<h1>Agent press key test</h1><form id=key-form><input id=key-target autocomplete=off>
<input id=next-target><button id=submit-target type=submit>Submit</button></form>
<pre id=state>events=0 submits=0</pre>
<script>
window.keyState={events:[],submits:0};
for(const name of ['keydown','keyup']) document.addEventListener(name,event=>{
  window.keyState.events.push({name,key:event.key,trusted:event.isTrusted,
                               target:event.target.id||''});
  document.querySelector('#state').textContent=
    `events=${window.keyState.events.length} submits=${window.keyState.submits}`;
});
document.querySelector('#key-form').addEventListener('submit',event=>{
  event.preventDefault(); window.keyState.submits+=1;
});
</script>"""

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path.split("?", 1)[0] != "/keys":
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
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/keys"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def run_key(executable: Path, root: Path, site: Site, key: str, timeout: float) -> str | None:
    case = root / key.lower()
    private_home, data, cache, temp, profile = (
        case / name for name in ("home", "data", "cache", "tmp", "profile")
    )
    for directory in (case, private_home, data, cache, temp, profile):
        directory.mkdir(mode=0o700)
    action = case / "action.json"
    socket_path = case / "automation.sock"
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
        [str(executable), f"{site.url}?key={key}", "--agent-drawer", "on",
         "--automation-api", "--e2e-protocol", "--profile-dir", str(profile)],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        start_new_session=True,
    )
    rpc: RpcClient | None = None
    try:
        out: list[str] = []
        err: list[str] = []
        assert proc.stdout is not None and proc.stderr is not None
        threading.Thread(target=_read_lines, args=(proc.stdout, out), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, err), daemon=True).start()
        rpc = RpcClient(socket_path, min(timeout, 25.0))
        ready_deadline = time.monotonic() + min(timeout, 20.0)
        while time.monotonic() < ready_deadline:
            state = rpc.evaluate("window.keyState")
            if isinstance(state, dict) and state.get("events") == []:
                break
            time.sleep(0.05)
        else:
            return f"{key}: local key page did not become ready"

        private_json(action, {"version": 1, "steps": [{
            "id": f"press-{key}", "tool": "mcp__zigbrowser__press_key",
            "args": {"selector": "css=#key-target", "key": key},
        }]})
        deadline = time.monotonic() + timeout
        rows: list[tuple[str, bool, str]] = []
        while time.monotonic() < deadline:
            rows = tool_rows(out)
            if rows or proc.poll() is not None:
                break
            time.sleep(0.1)
        if not rows or not rows[0][1]:
            return f"{key}: tool result was {rows!r}; stdout={out!r}; stderr={err!r}"
        if "MAC_AGENT_TOOL_APPROVAL\tpressed" not in out:
            return f"{key}: real approval button was not pressed"
        state = rpc.evaluate("window.keyState")
        events = state.get("events", []) if isinstance(state, dict) else []
        named = [event for event in events if event.get("key") == key]
        kinds = {event.get("name") for event in named}
        if kinds != {"keydown", "keyup"}:
            return f"{key}: page events were {events!r}"
        if any(event.get("trusted") is not True for event in named):
            return f"{key}: untrusted page event in {named!r}"
        if key == "Enter" and state.get("submits") != 1:
            return f"Enter: form submits were {state.get('submits')!r}, want 1"
        return None
    finally:
        if rpc is not None:
            rpc.close()
        stop_error = stop_owned(proc)
        if stop_error is not None:
            raise RuntimeError(f"{key}: {stop_error}")


def main(site: Site) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL mac-agent-press-key-direct: macOS is required", flush=True)
        return 1
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        print(f"FAIL mac-agent-press-key-direct: missing DMG {dmg}", flush=True)
        return 1
    root = Path(tempfile.mkdtemp(prefix="zb-sr-press-", dir=Path.home().resolve()))
    keep = True
    try:
        app = install_dmg(dmg, root)
        executable = app / "Contents/MacOS/zigBrowser"
        for key in KEYS:
            error = run_key(executable, root, site, key, args.timeout)
            if error is not None:
                print(f"FAIL mac-agent-press-key-direct: {error}", flush=True)
                print(f"EVIDENCE mac-agent-press-key-direct: {root}", flush=True)
                return 1
        keep = False
        print("PASS mac-agent-press-key-direct: approved trusted Enter Tab Escape and arrows", flush=True)
        return 0
    except Exception as error:
        print(f"FAIL mac-agent-press-key-direct: {type(error).__name__}: {error}", flush=True)
        print(f"EVIDENCE mac-agent-press-key-direct: {root}", flush=True)
        return 1
    finally:
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    with Site() as key_site:
        raise SystemExit(main(key_site))
