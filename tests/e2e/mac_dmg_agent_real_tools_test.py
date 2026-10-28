#!/usr/bin/python3
"""Installed-DMG proof of the real Mac Claude-to-browser tool path.

The fake CLI replaces only the network model.  Send, the native helper, the
SDK MCP server, helper tool frames, broker, approval card and WKWebView are the
installed product.  No ZB_DEBUG_MAC_AGENT_TOOLS_FILE injection is accepted.
"""

from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import plistlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


TOKEN_SERVICE = "dev.zigbrowser.MS63ProductTest"
TOKEN_ACCOUNT = "default"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def fail(reason: str) -> int:
    print(f"FAIL mac-agent-real-tools: {reason}", flush=True)
    return 1


def private_write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)


def build_fake_cli(source: Path, destination: Path) -> None:
    """Keep a native CLI process around the embedded Python model stand-in."""
    encoded = base64.b64encode(source.read_bytes()).decode("ascii")
    program = (
        "import base64;exec(compile(base64.b64decode('"
        + encoded
        + "'),'fake_claude_mac_product_tools.py','exec'))"
    )
    c_source = destination.with_suffix(".c")
    private_write(c_source, f'''#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {{
  static const char program[] = "{program}";
  char **child = calloc((size_t)argc + 4, sizeof(char *));
  if (child == NULL) return 125;
  child[0] = "/usr/bin/python3";
  child[1] = "-B";
  child[2] = "-c";
  child[3] = (char *)program;
  for (int i = 1; i < argc; i++) child[i + 3] = argv[i];
  pid_t pid = 0;
  int rc = posix_spawn(&pid, child[0], NULL, NULL, child, environ);
  free(child);
  if (rc != 0) return 125;
  int status = 0;
  if (waitpid(pid, &status, 0) != pid) return 125;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 125;
}}
'''.encode())
    built = subprocess.run(
        ["/usr/bin/clang", "-Os", "-Wall", "-Wextra", "-Werror", str(c_source), "-o", str(destination)],
        capture_output=True, text=True, check=False,
    )
    if built.returncode != 0:
        raise RuntimeError(f"native fake CLI build failed: {built.stderr[-300:]}")
    destination.chmod(0o700)


def point_private_runtime_at_fake(home: Path, fake: Path) -> None:
    """Retarget only this disposable test home's R1 wrapper."""
    wrapper = home / "runtime/bin/zb-claude"
    lines = wrapper.read_text(encoding="utf-8").splitlines(keepends=True)
    matches = [index for index, line in enumerate(lines) if line.startswith("CLI = ")]
    if len(matches) != 1:
        raise RuntimeError("provisioned R1 wrapper has an unexpected shape")
    lines[matches[0]] = f"CLI = {str(fake)!r}\n"
    wrapper.write_text("".join(lines), encoding="utf-8")
    wrapper.chmod(0o700)


class Site:
    def __init__(self) -> None:
        self.target_seen_ns = 0
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path == "/start":
                    body = b"<!doctype html><title>Before tools</title><p>Start page</p>"
                elif self.path == "/target":
                    owner.target_seen_ns = time.time_ns()
                    body = b"<!doctype html><title>Tool target</title><h1>Real browser tool arrived</h1>"
                else:
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
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def attach_install(dmg: Path, root: Path) -> Path:
    mount, applications = root / "mnt", root / "Applications"
    mount.mkdir(mode=0o700)
    applications.mkdir(mode=0o700)
    attached = subprocess.run(
        ["/usr/bin/hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen",
         "-mountpoint", str(mount), str(dmg)],
        capture_output=True,
        check=False,
    )
    if attached.returncode != 0:
        raise RuntimeError("hdiutil attach failed")
    plist = plistlib.loads(attached.stdout)
    devices = [item.get("dev-entry") for item in plist.get("system-entities", []) if item.get("dev-entry")]
    if not devices:
        raise RuntimeError("hdiutil returned no device")
    installed = applications / "zigBrowser.app"
    try:
        copied = subprocess.run(["/usr/bin/ditto", str(mount / "zigBrowser.app"), str(installed)], check=False)
        if copied.returncode != 0:
            raise RuntimeError("ditto install failed")
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", devices[0]], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return installed


def app_pids(executable: Path) -> dict[int, str]:
    done = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True)
    prefix = str(executable) + " "
    found = {}
    for raw in done.stdout.splitlines():
        fields = raw.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == str(executable) or fields[1].startswith(prefix)):
            found[int(fields[0])] = fields[1]
    return found


def stop_owned(pid: int | None, executable: Path) -> bool:
    if pid is None or pid not in app_pids(executable):
        return True
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and pid in app_pids(executable):
        time.sleep(0.1)
    if pid in app_pids(executable):
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and pid in app_pids(executable):
            time.sleep(0.1)
    return pid not in app_pids(executable)


def evidence_rows(path: Path) -> list[dict]:
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
        return [json.loads(line) for line in lines]
    except (OSError, ValueError):
        return []


def result_text(row: dict) -> str:
    try:
        mcp = row["response"]["response"]["mcp_response"]
        result = mcp.get("result", {})
        content = result.get("content", [])
        return "\n".join(block.get("text", "") for block in content if block.get("type") == "text")
    except (KeyError, TypeError, AttributeError):
        return ""


def result_error(row: dict) -> bool:
    try:
        mcp = row["response"]["response"]["mcp_response"]
        return "error" in mcp or bool(mcp.get("result", {}).get("isError"))
    except (KeyError, TypeError, AttributeError):
        return True


def press_approve(pid: int) -> tuple[bool, str]:
    script = f'''
tell application "System Events"
  tell first process whose unix id is {pid}
    repeat with candidate in entire contents of front window
      try
        if role of candidate is "AXButton" and name of candidate is "Approve" then
          perform action "AXPress" of candidate
          return "clicked"
        end if
      end try
    end repeat
  end tell
end tell
return "missing"
'''
    done = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, check=False)
    return done.returncode == 0 and done.stdout.strip() == "clicked", (done.stderr or done.stdout).strip()


def png_dimensions(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if len(data) < 10_000 or data[:8] != PNG_SIGNATURE or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--fake-cli", type=Path, required=True)
    parser.add_argument("--png", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=75.0)
    args = parser.parse_args()
    if sys.platform != "darwin":
        return fail("macOS is required")
    dmg, fake_source, png = args.dmg.resolve(), args.fake_cli.resolve(), args.png.expanduser().resolve()
    if not dmg.is_file() or not fake_source.is_file() or png.exists() or not png.parent.is_dir():
        return fail("invalid DMG, fake CLI, or PNG output")

    owner_home = Path.home().resolve()
    root = Path(tempfile.mkdtemp(prefix="zb-real-tools-", dir=owner_home))
    proc = None
    app_pid = None
    keychain = root / "tools.keychain-db"
    password = "zb-real-tools-keychain"
    try:
        app = attach_install(dmg, root)
        executable = app / "Contents/MacOS/zigBrowser"
        for name in ("home", "data", "tmp", "profile"):
            (root / name).mkdir(mode=0o700)
        setup_env = {
            "HOME": str(root / "home"), "XDG_DATA_HOME": str(root / "data"),
            "TMPDIR": str(root / "tmp"), "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
        }
        setup = subprocess.run([str(executable), "--agent-setup", "--e2e-protocol"], env=setup_env,
                               capture_output=True, text=True, timeout=180, check=False)
        if setup.returncode != 0:
            return fail(f"installed app setup exited {setup.returncode}: {setup.stderr[-300:]}")
        home = root / "data/zigbrowser/agent-home"
        runtime_fake = home / "scratchpad/fake-claude"
        build_fake_cli(fake_source, runtime_fake)
        point_private_runtime_at_fake(home, runtime_fake)
        fake = runtime_fake
        settings = home / "settings"
        settings.mkdir(mode=0o700, exist_ok=True)
        private_write(settings / "navigate_approval", b"yes\n")
        private_write(home / "scratchpad/real-tools-target", f"{site.origin}/target\n".encode())
        evidence = home / "scratchpad/real-tools-evidence.jsonl"

        for command in (
            ["/usr/bin/security", "create-keychain", "-p", password, str(keychain)],
            ["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)],
            ["/usr/bin/security", "set-keychain-settings", str(keychain)],
            ["/usr/bin/security", "add-generic-password", "-a", TOKEN_ACCOUNT, "-s", TOKEN_SERVICE,
             "-w", "sk-ant-oat01-FAKEPRODUCTTOOLS0123456789", "-A", str(keychain)],
        ):
            done = subprocess.run(command, capture_output=True, text=True, check=False)
            if done.returncode != 0:
                return fail(f"disposable Keychain setup failed: {done.stderr.strip()}")

        stdout, stderr = root / "browser.stdout", root / "browser.stderr"
        private_write(stdout, b"")
        private_write(stderr, b"")
        before = app_pids(executable)
        proc = subprocess.Popen(
            [
                "/usr/bin/open", "-n", "-W", "-o", str(stdout), "--stderr", str(stderr),
                "--env", f"HOME={root / 'home'}", "--env", f"XDG_DATA_HOME={root / 'data'}",
                "--env", f"TMPDIR={root / 'tmp'}", "--env", "ZB_DEBUG_DRAWER_LAYOUT=1",
                "--env", "ZB_DEBUG_DRAWER_AGENT_SEND=Use the browser tools now.",
                "--env", f"ZIGBROWSER_AGENT_CLAUDE_CLI={fake}",
                "--env", f"ZB_DEBUG_MAC_AGENT_KEYCHAIN={keychain}",
                "--env", f"ZB_DEBUG_MAC_AGENT_KEYCHAIN_PASSWORD={password}",
                "--env", f"ZB_DEBUG_WINDOW_SNAPSHOT_PNG={png}",
                "--env", "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS=35000",
                "--env", "ZB_DEBUG_QUIT_AFTER_MS=60000",
                str(app), "--args", f"{site.origin}/start", "--agent-drawer", "on",
                "--e2e-protocol", "--profile-dir", str(root / "profile"),
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            created = [(pid, cmd) for pid, cmd in app_pids(executable).items() if pid not in before]
            if len(created) == 1:
                app_pid = created[0][0]
                break
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        if app_pid is None:
            return fail("installed application did not launch exactly once")

        approved = False
        approve_detail = "approval card never appeared"
        deadline = time.monotonic() + args.timeout
        rows = []
        while time.monotonic() < deadline:
            rows = evidence_rows(evidence)
            if not approved and any(
                row.get("event") == "tool-waiting"
                and row.get("tool") == "mcp__zigbrowser__navigate"
                for row in rows
            ):
                approved, approve_detail = press_approve(app_pid)
            results = [row for row in rows if row.get("event") == "tool-result"]
            if len(results) >= 3:
                break
            if app_pid not in app_pids(executable):
                break
            time.sleep(0.15)

        results = [row for row in rows if row.get("event") == "tool-result"]
        if not results:
            drawer_log = home / "state/drawer.log"
            diagnostics = ""
            for candidate in (drawer_log, stderr):
                try:
                    diagnostics += candidate.read_text(encoding="utf-8", errors="replace")[-500:]
                except OSError:
                    pass
            return fail(
                "fake CLI received no SDK MCP tool_result"
                + f"; evidence={rows!r}"
                + (f"; diagnostics={diagnostics.strip()}" if diagnostics.strip() else "")
            )
        expected = ["mcp__zigbrowser__window_info", "mcp__zigbrowser__navigate",
                    "mcp__zigbrowser__window_info"]
        if [row.get("tool") for row in results] != expected:
            return fail(f"tool_result sequence was {[row.get('tool') for row in results]!r}")
        for row in results:
            if result_error(row):
                return fail(f"{row['tool'].rsplit('__', 1)[-1]} tool_result: {result_text(row) or 'error'}")
        if not approved:
            return fail(f"Approve was not clicked through the visible card: {approve_detail}")
        if site.target_seen_ns == 0:
            return fail("approved navigate never requested the target page")
        after = result_text(results[2])
        if f"{site.origin}/target" not in after:
            return fail(f"post-navigate window_info has the wrong URL: {after!r}")

        deadline = time.monotonic() + 45
        dimensions = None
        while time.monotonic() < deadline:
            dimensions = png_dimensions(png)
            if dimensions is not None:
                break
            time.sleep(0.1)
        if dimensions is None:
            return fail("readable in-app PNG was not produced")
        if png.stat().st_mtime_ns < site.target_seen_ns:
            return fail("in-app PNG was captured before navigation")
        print(f"PNG\t{png}\t{dimensions[0]}x{dimensions[1]}", flush=True)
        print("PASS mac-agent-real-tools installed-cli-sdk-broker-card-navigate", flush=True)
        return 0
    finally:
        app_stopped = proc is None or stop_owned(app_pid, app / "Contents/MacOS/zigBrowser")
        if app_stopped and proc is not None:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=5)
        if app_stopped:
            subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            shutil.rmtree(root, ignore_errors=True)
        else:
            print(f"LEAK mac-agent-real-tools pid={app_pid} retained={root}", flush=True)


if __name__ == "__main__":
    with Site() as site:
        raise SystemExit(main())
