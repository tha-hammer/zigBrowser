#!/usr/bin/env python3
"""Windows plan WS2b.0 (rev 2.17, C5; orchestrator decision (a), 2026-10-22): the
`capabilities` RPC reports the production adapterCapabilities() row of the RUNNING
browser's backend, over the authenticated automation socket.

Launches the REAL binary with --automation-api and speaks raw JSON-RPC frames
(4-byte big-endian length + JSON) to its socket, so the exact error objects are
seen:
  - a wrong token is refused with -32000 (the RPC sits behind the socket's auth);
  - with the sidecar token, `capabilities` answers exactly this backend's row;
  - params other than {} are refused with -32602.
The expected rows are literal (the plan's capability decisions), not computed from
the source. This file drives the Linux (webkitgtk) row; the webview2 row
(input and network both `unproven` until WS2b.1 / zigBrowser-ong.7 runs) is the
Windows leg `windows-capabilities-live`, which needs a host release.

Prints `ASSERTS <n>`. Exit 77 (skip) without a binary or a display runner."""

from __future__ import annotations

import argparse
import json
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # `python3 -I` drops the script dir

from automation_fixture_server import AutomationFixtureServer  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402

LINUX_ROW = {
    "backend": "webkitgtk",
    "input": {"mode": "js_synthetic"},
    "network": {"support": "unsupported", "unsupported_reason": "web_extension_required"},
}

AUTH_FAILED = -32000
INVALID_PARAMS = -32602


class Asserts:
    def __init__(self) -> None:
        self.n = 0

    def equal(self, label: str, actual, expected) -> None:
        self.n += 1
        if actual != expected:
            raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def wait_for(path: Path, timeout_sec: float) -> None:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"{path} never appeared")


def recv_exact(sock: socket.socket, count: int) -> bytes:
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("socket closed mid-frame")
        data += chunk
    return data


def rpc(socket_path: Path, request: dict, timeout_sec: float) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout_sec)
        sock.connect(str(socket_path))
        payload = json.dumps(request).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)
        (length,) = struct.unpack(">I", recv_exact(sock, 4))
        return json.loads(recv_exact(sock, length))


def error_code(reply: dict):
    return reply.get("error", {}).get("code")


def scenario(socket_path: Path, token: str, timeout_sec: float) -> int:
    check = Asserts()
    base = {"jsonrpc": "2.0", "method": "capabilities"}

    refused = rpc(socket_path, {**base, "id": 1, "auth": token + "x"}, timeout_sec)
    check.equal("wrong token refused", error_code(refused), AUTH_FAILED)

    reply = rpc(socket_path, {**base, "id": 2, "auth": token}, timeout_sec)
    check.equal("no error", reply.get("error"), None)
    check.equal("capabilities row", reply.get("result"), LINUX_ROW)
    check.equal("id echoed", reply.get("id"), 2)

    bad = rpc(socket_path, {**base, "id": 3, "auth": token, "params": {"backend": "webview2"}}, timeout_sec)
    check.equal("params refused", error_code(bad), INVALID_PARAMS)
    return check.n


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with AutomationFixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-caps-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        token_path = Path(str(socket_path) + ".token")
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{fixture.base_url}/nav-a", "--automation-api"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            wait_for(socket_path, args.timeout_sec)
            wait_for(token_path, args.timeout_sec)
            asserts = scenario(socket_path, token_path.read_text(encoding="utf-8").strip(), args.timeout_sec)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tcapabilities-rpc")
            eprint(f"error={exc!r}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    print(f"ASSERTS {asserts}")
    print("PASS\tcapabilities-rpc")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
