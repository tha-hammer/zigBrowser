#!/usr/bin/env python3
"""Slice 2 Behavior 5 E2E: IPC success and error protocol lines."""

from __future__ import annotations

import argparse
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    assert_children_exit,
    detect_runner,
    eprint,
    print_fail_context,
    protocol_rows,
    require_file,
    run_interactive_until,
)


def run_case(
    binary: Path,
    env: dict[str, str],
    prefix: list[str],
    uri: str,
    timeout_sec: float,
    ok_condition,
    label: str,
) -> tuple[bool, int]:
    cmd = prefix + [str(binary), uri, "--e2e-protocol"]
    matched, result = run_interactive_until(cmd, env, timeout_sec, ok_condition)
    if not matched:
        print(f"FAIL\t{label}")
        print_fail_context(label, result)
        return False, 1
    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        return True, 0
    print(f"FAIL\t{label}-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context(f"{label}-clean-quit", result)
    return False, 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--timeout-sec", type=float, default=30.0)
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

    success_uri = index.resolve().as_uri() + "#auto=ipc"
    error_uri = index.resolve().as_uri() + "#auto=ipcerr"

    def success_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipc_rows = protocol_rows(stdout_lines, "IPC")
        return any(len(row) >= 3 and row[1] == "os.info" and len(row[2]) > 0 for row in ipc_rows)

    def error_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        err_rows = protocol_rows(stdout_lines, "IPCERR")
        return any(len(row) >= 3 and row[1] == "nope" and row[2] == "UnknownCommand" for row in err_rows)

    ok_success, code_success = run_case(
        browser,
        env,
        prefix,
        success_uri,
        args.timeout_sec,
        success_condition,
        "ipc-roundtrip-success-not-observed",
    )
    if not ok_success:
        return code_success

    ok_error, code_error = run_case(
        browser,
        env,
        prefix,
        error_uri,
        args.timeout_sec,
        error_condition,
        "ipc-roundtrip-error-not-observed",
    )
    if not ok_error:
        return code_error

    print("PASS\tipc-roundtrip-success-and-error")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
