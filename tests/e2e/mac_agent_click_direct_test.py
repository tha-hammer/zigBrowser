#!/usr/bin/python3
"""Installed Mac product proof for the agent's approved native click.

The e2e-only product seam injects one model tool call directly into the native
broker, before the helper/SDK routing owned by another slice.  The installed
app, broker, approval card, automation server, WKWebView, and input event are
real.  This test never reads, creates, names, or points at a Keychain.
"""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines
from mac_live_agent_test import install_dmg


ROW = "MAC_AGENT_TOOL\t"
ACTION_ENV = "ZB_DEBUG_MAC_AGENT_TOOLS_FILE"


class Site:
    def __init__(self) -> None:
        body = b"""<!doctype html><meta charset=utf-8><title>Agent click</title>
<style>body{font:24px -apple-system;margin:40px}button{font:inherit;padding:18px}</style>
<h1>Agent click test</h1><button id=click-target>Click target</button>
<pre id=state>clicks=0 trusted=unset</pre>
<script>
window.clickState={clicks:0,trusted:null};
document.querySelector('#click-target').addEventListener('click', event=>{
  window.clickState={clicks:window.clickState.clicks+1,trusted:event.isTrusted};
  document.querySelector('#state').textContent=
    `clicks=${window.clickState.clicks} trusted=${event.isTrusted}`;
});
</script>"""

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path != "/click":
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
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/click"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def private_json(path: Path, value: dict) -> None:
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


def press_approve(pid: int) -> tuple[bool, str]:
    script = f'''
tell application "System Events"
  tell first process whose unix id is {pid}
    repeat with candidate in entire contents of front window
      try
        if role of candidate is "AXButton" and name of candidate is "Approve" and enabled of candidate then
          perform action "AXPress" of candidate
          return "clicked"
        end if
      end try
    end repeat
  end tell
end tell
return "missing"
'''
    done = subprocess.run(
        ["/usr/bin/osascript", "-e", script], capture_output=True, text=True, check=False
    )
    return done.returncode == 0 and done.stdout.strip() == "clicked", (
        done.stderr or done.stdout
    ).strip()


def stop_owned(proc: subprocess.Popen) -> str | None:
    if proc.poll() is not None:
        return None
    os.kill(proc.pid, signal.SIGTERM)
    try:
        proc.wait(timeout=12)
        return None
    except subprocess.TimeoutExpired:
        return f"owned application pid {proc.pid} ignored SIGTERM; retained run root"


def main(site: Site) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=35.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        print("FAIL mac-agent-click-direct: macOS is required", flush=True)
        return 1
    dmg = args.dmg.expanduser().resolve()
    if not dmg.is_file():
        print(f"FAIL mac-agent-click-direct: missing DMG {dmg}", flush=True)
        return 1

    home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-otter-click-", dir=home))
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
        action = root / "click-action.json"
        private_json(
            action,
            {
                "version": 1,
                "steps": [
                    {
                        "id": "click",
                        "tool": "mcp__zigbrowser__click",
                        "args": {"selector": "css=#click-target"},
                    }
                ],
            },
        )
        socket_path = root / "automation.sock"
        env = {
            "HOME": str(private_home),
            "XDG_DATA_HOME": str(data),
            "XDG_CACHE_HOME": str(cache),
            "TMPDIR": str(temp),
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "ZIGBROWSER_SOCKET": str(socket_path),
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

        deadline = time.monotonic() + args.timeout
        approved = False
        approve_detail = "approval card never appeared"
        state = {"clicks": 0, "trusted": None}
        rows: list[tuple[str, bool, str]] = []
        while time.monotonic() < deadline:
            rows = tool_rows(out)
            state = rpc.evaluate("window.clickState") or state
            if not approved:
                approved, approve_detail = press_approve(proc.pid)
            if approved and rows:
                break
            if rows and state.get("clicks", 0) != 0 and not approved:
                print(
                    "FAIL mac-agent-click-direct: click dispatched before its approval card "
                    f"(state={state!r}, rows={rows!r})",
                    flush=True,
                )
                print(f"EVIDENCE mac-agent-click-direct: {root}", flush=True)
                return 1
            if proc.poll() is not None:
                break
            time.sleep(0.15)

        if not approved:
            print(
                f"FAIL mac-agent-click-direct: no enabled Approve button ({approve_detail})",
                flush=True,
            )
            print(f"EVIDENCE mac-agent-click-direct: {root}", flush=True)
            return 1
        if rows != [("click", True, rows[0][2] if rows else "")]:
            print(f"FAIL mac-agent-click-direct: tool result was {rows!r}", flush=True)
            print(f"EVIDENCE mac-agent-click-direct: {root}", flush=True)
            return 1
        state = rpc.evaluate("window.clickState")
        if state != {"clicks": 1, "trusted": True}:
            print(
                f"FAIL mac-agent-click-direct: page state was {state!r}, want one trusted click",
                flush=True,
            )
            print(f"EVIDENCE mac-agent-click-direct: {root}", flush=True)
            return 1
        keep = False
        print("PASS mac-agent-click-direct: approved trusted click reached local page", flush=True)
        return 0
    except Exception as error:  # fail closed with evidence retained
        print(
            f"FAIL mac-agent-click-direct: {type(error).__name__}: {error}", flush=True
        )
        print(f"EVIDENCE mac-agent-click-direct: {root}", flush=True)
        return 1
    finally:
        if rpc is not None:
            rpc.close()
        if proc is not None:
            stop_error = stop_owned(proc)
            if stop_error is not None:
                keep = True
                print(f"LEAK mac-agent-click-direct: {stop_error}", flush=True)
        if not keep:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    with Site() as click_site:
        raise SystemExit(main(click_site))
