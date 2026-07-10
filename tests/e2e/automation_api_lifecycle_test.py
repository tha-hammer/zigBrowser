#!/usr/bin/env python3
"""Track A E2E: --automation-api starts a live UDS JSON-RPC server."""

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

from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file


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


def call_rpc(socket_path: Path, timeout_sec: float) -> dict:
    deadline = time.monotonic() + timeout_sec
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2.0)
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
            "method": "page.url",
            "params": {},
            "id": 1,
        }
        payload = json.dumps(request, separators=(",", ":")).encode("utf-8")
        sock.sendall(struct.pack(">I", len(payload)) + payload)

        header = recv_exact(sock, 4)
        length = struct.unpack(">I", header)[0]
        response = json.loads(recv_exact(sock, length).decode("utf-8"))
        return response


def terminate(proc: subprocess.Popen[str]) -> int:
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
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
            response = call_rpc(socket_path, args.timeout_sec)
            result = response.get("result")
            if response.get("jsonrpc") != "2.0" or response.get("id") != 1:
                raise AssertionError(f"bad JSON-RPC envelope: {response}")
            if not isinstance(result, dict) or result.get("ok") is not True:
                raise AssertionError(f"missing ok result: {response}")
            if result.get("method") != "page.url":
                raise AssertionError(f"wrong method result: {response}")
            nav_deadline = time.monotonic() + args.timeout_sec
            while time.monotonic() < nav_deadline:
                if any(line.startswith("NAV\t") for line in stdout_lines):
                    break
                if proc.poll() is not None:
                    raise AssertionError(f"browser exited before NAV row: {proc.returncode}")
                time.sleep(0.05)
            else:
                raise TimeoutError("browser did not emit NAV row before shutdown")
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

        deadline = time.monotonic() + 3.0
        while socket_path.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if socket_path.exists():
            print("FAIL\tautomation-api-socket-cleanup")
            eprint(f"socket still exists: {socket_path}")
            return 1

    print("PASS\tautomation-api-lifecycle-roundtrip")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
