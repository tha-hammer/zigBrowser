#!/usr/bin/env python3
"""M8 HW-gated E2E: Windows WebView2 LOAD_FAIL rows and failure exit codes."""

from __future__ import annotations

import argparse
import os
import platform
import socket
import threading
import time
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    RunResult,
    browser_profile_dir,
    eprint,
    harness_exit_code,
    protocol_rows,
    require_file,
    run_windows_interactive_cmd_until,
)


REQUIRED_ENV = "ZB_ENABLE_M8_E2E"
LOAD_FAIL_CODES = {5, 8}
RUNTIME_FAILURE_CODES = {9, 10}
EXPECTED_CODES = LOAD_FAIL_CODES | RUNTIME_FAILURE_CODES


class HangingTcpServer:
    def __init__(self) -> None:
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self._sock.settimeout(0.2)
        self.port = int(self._sock.getsockname()[1])
        self._stop = threading.Event()
        self._connections: list[socket.socket] = []
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "HangingTcpServer":
        self._thread.start()
        return self

    def __exit__(self, _exc_type, _exc, _tb) -> None:
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass
        for conn in self._connections:
            try:
                conn.close()
            except OSError:
                pass
        self._thread.join(timeout=1.0)

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            conn.settimeout(0.2)
            self._connections.append(conn)

            def hold(connection: socket.socket) -> None:
                try:
                    while not self._stop.is_set():
                        time.sleep(0.2)
                finally:
                    try:
                        connection.close()
                    except OSError:
                        pass

            threading.Thread(target=hold, args=(conn,), daemon=True).start()


def gate_skip_exit(reason: str) -> int:
    """A missing precondition: skip (77) when run standalone, FAIL (1) under ZB_WIN_GATE=1 (plan D.1, WS1.2).

    Same contract as slice2_common.gate_skip_exit (GrayHarbor's WS0.9 green); this local copy is replaced by
    that import once it lands."""
    eprint(reason)
    if os.environ.get("ZB_WIN_GATE") == "1":
        eprint("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


def hw_gate_ready() -> tuple[bool, str]:
    if platform.system() != "Windows":
        return False, "SKIP: M8 is Windows-only"
    if os.environ.get(REQUIRED_ENV) != "1":
        return False, f"SKIP: set {REQUIRED_ENV}=1 to run M8 HW-gated E2E"
    return True, "ok"


def default_binary() -> str:
    return "zig-out/bin/zigBrowser.exe" if platform.system() == "Windows" else "zig-out/bin/zigBrowser"


def closed_localhost_uri() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        port = int(sock.getsockname()[1])
    finally:
        sock.close()
    return f"http://127.0.0.1:{port}/"


def matching_load_fail_rows(stdout_lines: list[str], uri: str) -> list[list[str]]:
    return [row for row in protocol_rows(stdout_lines, "LOAD_FAIL") if len(row) == 4 and row[1] == uri]


def print_fail_context(label: str, result: RunResult) -> None:
    eprint(f"{label}: return={result.returncode} timed_out={result.timed_out}")
    eprint("stdout:\n" + "\n".join(result.stdout_lines))
    eprint("stderr:\n" + "\n".join(result.stderr_lines))


def valid_int(text: str) -> bool:
    try:
        int(text, 10)
        return True
    except ValueError:
        return False


def assert_failure_contract(label: str, result: RunResult, uri: str, expected_load_code: int) -> bool:
    if result.timed_out:
        print(f"FAIL\t{label}-harness-timeout")
        print_fail_context(label, result)
        return False

    if result.returncode not in EXPECTED_CODES:
        print(f"FAIL\t{label}-exit-code")
        eprint(f"expected one of {sorted(EXPECTED_CODES)}, got {result.returncode}")
        print_fail_context(label, result)
        return False

    load_fail_rows = protocol_rows(result.stdout_lines, "LOAD_FAIL")

    if result.returncode in RUNTIME_FAILURE_CODES:
        if os.environ.get("ZB_WIN_GATE") == "1":
            # A missing or broken WebView2 runtime proves nothing about load failures: under the gate it fails.
            print(f"FAIL\t{label}-runtime-failure-under-gate")
            print_fail_context(label, result)
            return False
        if load_fail_rows:
            print(f"FAIL\t{label}-runtime-failure-emitted-load-fail")
            print_fail_context(label, result)
            return False
        return True

    if result.returncode != expected_load_code:
        print(f"FAIL\t{label}-wrong-load-failure-code")
        eprint(f"expected exit {expected_load_code}, got {result.returncode}")
        print_fail_context(label, result)
        return False

    matching_rows = matching_load_fail_rows(result.stdout_lines, uri)
    if not matching_rows:
        print(f"FAIL\t{label}-missing-4-field-load-fail")
        print_fail_context(label, result)
        return False

    for row in matching_rows:
        if row[2] == "2" and valid_int(row[3]):
            return True

    print(f"FAIL\t{label}-bad-load-fail-domain-code")
    eprint(f"rows={matching_rows}")
    print_fail_context(label, result)
    return False


def run_case(browser: Path, uri: str, expected_load_code: int, timeout_sec: float, label: str) -> bool:
    profile = browser_profile_dir(Path.cwd(), label)  # its own WebView2 folder (NavyCanyon e80e0352)
    cmd = [str(browser), uri, "--e2e-protocol", "--profile-dir", str(profile)]
    env = dict(os.environ)

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        code = harness_exit_code(stdout_lines)
        if code is None:
            return False
        if code in RUNTIME_FAILURE_CODES:
            return True
        return code == expected_load_code and bool(matching_load_fail_rows(stdout_lines, uri))

    _matched, result = run_windows_interactive_cmd_until(cmd, env, timeout_sec, condition)
    return assert_failure_contract(label, result, uri, expected_load_code)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--timeout-sec", type=float, default=45.0)
    parser.add_argument("--mode", choices=["all", "load-fail", "timeout"], default="all")
    parser.add_argument("--fail-uri", default=None)
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        return gate_skip_exit(reason)

    browser = Path(args.binary or default_binary())
    if not require_file(browser, "binary"):
        return gate_skip_exit("SKIP: the binary is missing")

    ok = True
    cases = 0
    if args.mode in ("all", "load-fail"):
        cases += 1
        fail_uri = args.fail_uri or closed_localhost_uri()
        ok = run_case(browser, fail_uri, 5, args.timeout_sec, "m8-load-fail") and ok

    if args.mode in ("all", "timeout"):
        cases += 1
        with HangingTcpServer() as server:
            timeout_uri = f"http://127.0.0.1:{server.port}/"
            ok = run_case(browser, timeout_uri, 8, args.timeout_sec, "m8-load-timeout") and ok

    if not ok:
        return 1

    print("PASS\tm8-load-fail-contract")
    if os.environ.get("ZB_WIN_GATE") == "1":
        # Each gated case passed three checks: the exit code, a 4-field LOAD_FAIL row, its domain/code fields.
        print(f"ASSERTS {3 * cases}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
