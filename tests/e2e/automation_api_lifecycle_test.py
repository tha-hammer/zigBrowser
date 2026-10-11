#!/usr/bin/env python3
"""E2E: --automation-api serves real results from the live WebKitGTK page.

Drives page.url, page.title, dom.getText and dom.click over the UDS JSON-RPC
socket against a file:// fixture, and proves the click reached the page by
reading the text it changed."""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from slice2_common import SKIP_EXIT, automation_auth, detect_runner, eprint, require_file, stop_browser


def _read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


def recv_exact(sock: socket.socket, n: int) -> bytes:
    chunks = b""
    while len(chunks) < n:
        chunk = sock.recv(n - len(chunks))
        if not chunk:
            raise ConnectionError("socket closed before full frame")
        chunks += chunk
    return chunks


def raw_call(socket_path: Path, request: dict, timeout_sec: float) -> dict:
    """Send one framed request exactly as given; return the whole response."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout_sec)
        sock.connect(str(socket_path))
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        length = struct.unpack(">I", recv_exact(sock, 4))[0]
        return json.loads(recv_exact(sock, length).decode("utf-8"))


def call_rpc(socket_path: Path, method: str, params: dict, req_id: int, timeout_sec: float) -> dict:
    deadline = time.monotonic() + timeout_sec
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout_sec)
            sock.connect(str(socket_path))
            break
        except OSError as exc:
            last_error = exc
            time.sleep(0.05)
    else:
        raise TimeoutError(f"socket never became connectable: {last_error}")

    with sock:
        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": req_id,
        }
        token = automation_auth(socket_path)
        if token is not None:
            request["auth"] = token
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)

        header = recv_exact(sock, 4)
        length = struct.unpack(">I", header)[0]
        response = json.loads(recv_exact(sock, length).decode("utf-8"))
        if response.get("jsonrpc") != "2.0" or response.get("id") != req_id:
            raise AssertionError(f"bad JSON-RPC envelope for {method}: {response}")
        if "error" in response:
            raise AssertionError(f"{method} returned an error: {response}")
        return response["result"]


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def terminate(proc: subprocess.Popen[str]) -> int:
    return stop_browser(proc)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--index", default="tests/fixtures/automation/lifecycle.html")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    index = Path(args.index)
    if not require_file(browser, "binary") or not require_file(index, "app index"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with tempfile.TemporaryDirectory(prefix="zb-automation-e2e-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)

        cmd = prefix + [
            str(browser),
            index.resolve().as_uri(),
            "--automation-api",
            "--e2e-protocol",
        ]
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None
        assert proc.stderr is not None

        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        stdout_thread = threading.Thread(target=_read_lines, args=(proc.stdout, stdout_lines), daemon=True)
        stderr_thread = threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True)
        stdout_thread.start()
        stderr_thread.start()

        try:
            # Startup race regression: ask for the title the moment the socket
            # accepts, before the start page has finished loading. The bridge
            # must hold the command until the first load ends.
            expect_equal(
                "page.title at startup",
                call_rpc(socket_path, "page.title", {}, 100, args.timeout_sec),
                {"title": "Automation Lifecycle Fixture"},
            )

            nav_deadline = time.monotonic() + args.timeout_sec
            while time.monotonic() < nav_deadline:
                if any(line.startswith("NAV\t") for line in stdout_lines):
                    break
                if proc.poll() is not None:
                    raise AssertionError(f"browser exited before NAV row: {proc.returncode}")
                time.sleep(0.05)
            else:
                raise TimeoutError("browser did not emit NAV row")

            fixture_uri = index.resolve().as_uri()
            t = args.timeout_sec
            expect_equal("page.url", call_rpc(socket_path, "page.url", {}, 1, t), {"url": fixture_uri})
            expect_equal(
                "page.title",
                call_rpc(socket_path, "page.title", {}, 2, t),
                {"title": "Automation Lifecycle Fixture"},
            )
            expect_equal(
                "dom.getText #msg",
                call_rpc(socket_path, "dom.getText", {"selector": "css=#msg"}, 3, t),
                {"text": "Hello automation"},
            )
            expect_equal(
                "dom.getText #status before click",
                call_rpc(socket_path, "dom.getText", {"selector": "css=#status"}, 4, t),
                {"text": "idle"},
            )
            expect_equal(
                "dom.click #go",
                call_rpc(socket_path, "dom.click", {"selector": "css=#go"}, 5, t),
                {"ok": True},
            )
            expect_equal(
                "dom.getText #status after click",
                call_rpc(socket_path, "dom.getText", {"selector": "css=#status"}, 6, t),
                {"text": "clicked"},
            )

            # Default auth: a per-session token in a 0600 sidecar; requests
            # without it or with a wrong one never dispatch.
            sidecar = Path(str(socket_path) + ".token")
            if not sidecar.exists():
                raise AssertionError("no per-session token sidecar next to the socket")
            expect_equal("sidecar mode", oct(sidecar.stat().st_mode & 0o777), oct(0o600))
            token = automation_auth(socket_path) or ""
            if len(token) != 64 or any(ch not in "0123456789abcdef" for ch in token):
                raise AssertionError("generated token is not 32 random bytes in hex")
            probe = {"jsonrpc": "2.0", "method": "page.evaluate", "params": {"expression": "window.__authProbe = 1"}, "id": 7}
            for label, request in (("missing token", probe), ("wrong token", dict(probe, auth="0" * 64))):
                response = raw_call(socket_path, request, t)
                if response.get("error", {}).get("code") != -32000:
                    raise AssertionError(f"{label} was not rejected: {response}")
            expect_equal("rejected requests never ran", call_rpc(socket_path, "page.evaluate",
                         {"expression": "typeof window.__authProbe"}, 8, t), {"result": "undefined"})
        except Exception as exc:
            print("FAIL\tautomation-api-roundtrip")
            eprint(f"error={exc}")
            eprint(f"stdout={stdout_lines[-20:]}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1

        rc = terminate(proc)
        stdout_thread.join(timeout=1)
        stderr_thread.join(timeout=1)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tautomation-api-clean-shutdown")
            eprint(f"return={rc}")
            eprint(f"stdout={stdout_lines[-20:]}")
            eprint(f"stderr={stderr_lines[-20:]}")
            return 1

        # Profile isolation: the default profile must land under the harness's
        # temporary XDG_DATA_HOME, never the developer's real one.
        isolated = Path(env["XDG_DATA_HOME"]) / "zigbrowser" / "profile" / "cookies.sqlite"
        real_root = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
        if Path(env["XDG_DATA_HOME"]).resolve() == Path(real_root).resolve() or not isolated.exists():
            print("FAIL\tautomation-api-profile-isolation")
            eprint(f"expected the default profile under the temp root: {isolated}")
            return 1

        sidecar = Path(str(socket_path) + ".token")
        if sidecar.exists():
            print("FAIL\tautomation-api-token-cleanup")
            eprint(f"token sidecar still exists after shutdown: {sidecar}")
            return 1

        deadline = time.monotonic() + 3.0
        while socket_path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if socket_path.exists():
            print("FAIL\tautomation-api-socket-cleanup")
            eprint(f"socket still exists: {socket_path}")
            return 1

    # An explicit token file that is empty must stop startup, never fall back
    # to an unauthenticated server.
    with tempfile.TemporaryDirectory(prefix="zb-automation-e2e-") as tmp:
        empty = Path(tmp) / "empty.token"
        empty.write_text("  \n", encoding="utf-8")
        socket_path = Path(tmp) / "automation.sock"
        env2 = dict(env)
        env2["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.run(
            prefix + [str(browser), index.resolve().as_uri(), "--automation-api",
                      "--automation-token-file", str(empty)],
            capture_output=True, text=True, env=env2, timeout=args.timeout_sec,
        )
        if proc.returncode == 0 or socket_path.exists():
            print("FAIL\tautomation-api-empty-token-file")
            eprint(f"return={proc.returncode} socket_exists={socket_path.exists()}")
            return 1

    print("PASS\tautomation-api-lifecycle-roundtrip")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
