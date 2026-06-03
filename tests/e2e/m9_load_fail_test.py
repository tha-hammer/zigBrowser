#!/usr/bin/env python3
"""M9 HW-gated E2E: macOS WKWebView LOAD_FAIL rows and exit code."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from m9_reply_channel_test import default_binary, hw_gate_ready, run_macos_gui_until
from slice2_common import SKIP_EXIT, RunResult, eprint, harness_exit_code, print_fail_context, protocol_rows, require_file


EXPECTED_LOAD_FAILED = 5


def valid_int(text: str) -> bool:
    try:
        int(text, 10)
        return True
    except ValueError:
        return False


def matching_load_fail_rows(stdout_lines: list[str], uri: str) -> list[list[str]]:
    return [row for row in protocol_rows(stdout_lines, "LOAD_FAIL") if len(row) == 4 and row[1] == uri]


def assert_load_fail_contract(label: str, result: RunResult, uri: str) -> bool:
    if result.timed_out:
        print(f"FAIL\t{label}-harness-timeout")
        print_fail_context(label, result)
        return False

    if result.returncode != EXPECTED_LOAD_FAILED:
        print(f"FAIL\t{label}-exit-code")
        eprint(f"expected {EXPECTED_LOAD_FAILED}, got {result.returncode}")
        print_fail_context(label, result)
        return False

    rows = matching_load_fail_rows(result.stdout_lines, uri)
    if not rows:
        print(f"FAIL\t{label}-missing-4-field-load-fail")
        print_fail_context(label, result)
        return False

    for row in rows:
        if valid_int(row[2]) and valid_int(row[3]):
            return True

    print(f"FAIL\t{label}-bad-load-fail-domain-code")
    eprint(f"rows={rows}")
    print_fail_context(label, result)
    return False


def run_case(browser: Path, uri: str, timeout_sec: float, label: str) -> bool:
    cmd = [str(browser), uri, "--e2e-protocol"]
    env = dict(os.environ)

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        code = harness_exit_code(stdout_lines)
        return code == EXPECTED_LOAD_FAILED and bool(matching_load_fail_rows(stdout_lines, uri))

    _matched, result = run_macos_gui_until(cmd, env, timeout_sec, condition)
    return assert_load_fail_contract(label, result, uri)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    parser.add_argument("--fail-uri", default=None)
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        eprint(reason)
        return SKIP_EXIT

    browser = Path(args.binary or default_binary())
    if not require_file(browser, "binary"):
        return SKIP_EXIT

    bad_uri = args.fail_uri or (Path.cwd() / "tests" / "fixtures" / "app" / "m9-does-not-exist.html").resolve().as_uri()
    if not run_case(browser, bad_uri, args.timeout_sec, "m9-load-fail"):
        return 1

    print("PASS\tm9-load-fail-contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
