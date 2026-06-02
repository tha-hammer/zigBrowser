#!/usr/bin/env python3
"""Slice 3/4 M8 HW-gated E2E: Windows WebView2 reply-channel contract."""

from __future__ import annotations

import argparse
import os
import platform
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    eprint,
    print_fail_context,
    protocol_rows,
    require_file,
    run_windows_interactive_until,
)


REQUIRED_ENV = "ZB_ENABLE_M8_E2E"


def hw_gate_ready() -> tuple[bool, str]:
    if platform.system() != "Windows":
        return False, "SKIP: M8 is Windows-only"
    if os.environ.get(REQUIRED_ENV) != "1":
        return False, f"SKIP: set {REQUIRED_ENV}=1 to run M8 HW-gated E2E"
    return True, "ok"


def default_binary() -> str:
    return "zig-out/bin/zigBrowser.exe" if platform.system() == "Windows" else "zig-out/bin/zigBrowser"


def run_case(
    binary: Path,
    env: dict[str, str],
    uri: str,
    timeout_sec: float,
    ok_condition,
    label: str,
) -> tuple[bool, int]:
    cmd = [str(binary), uri, "--e2e-protocol"]
    matched, result = run_windows_interactive_until(cmd, env, timeout_sec, ok_condition)
    if not matched:
        print(f"FAIL\t{label}")
        print_fail_context(label, result)
        return False, 1

    return True, 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        eprint(reason)
        return SKIP_EXIT

    browser = Path(args.binary or default_binary())
    index = Path(args.index)
    if not require_file(browser, "binary") or not require_file(index, "app index"):
        return SKIP_EXIT

    env = dict(os.environ)
    eprint("runner=interactive-scheduled-task")

    success_uri = index.resolve().as_uri() + "#auto=echo"
    error_uri = index.resolve().as_uri() + "#auto=echo-bad"

    def success_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipc_rows = protocol_rows(stdout_lines, "IPC")
        ipcerr_rows = protocol_rows(stdout_lines, "IPCERR")
        saw_success = any(
            len(row) >= 3 and row[1] == "echo" and row[2] == '"hi-42"' for row in ipc_rows
        )
        saw_error = any(len(row) >= 3 and row[1] == "echo" for row in ipcerr_rows)
        return saw_success and not saw_error

    def error_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipcerr_rows = protocol_rows(stdout_lines, "IPCERR")
        return any(len(row) >= 3 and row[1] == "echo" and row[2] == "BadArgs" for row in ipcerr_rows)

    ok_success, code_success = run_case(
        browser,
        env,
        success_uri,
        args.timeout_sec,
        success_condition,
        "m8-echo-success-not-observed",
    )
    if not ok_success:
        return code_success

    ok_error, code_error = run_case(
        browser,
        env,
        error_uri,
        args.timeout_sec,
        error_condition,
        "m8-echo-badargs-not-observed",
    )
    if not ok_error:
        return code_error

    print("PASS\tm8-reply-channel-contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
