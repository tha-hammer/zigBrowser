#!/usr/bin/env python3
"""Slice 2 Behavior 4 E2E: target=_blank foreign link opens an app-owned sub-window."""

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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--subwin-uri", default="https://example.org/")
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

    index_uri = index.resolve().as_uri() + "#auto=subwindow"

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        wincount_rows = protocol_rows(stdout_lines, "WINCOUNT")
        subwin_rows = protocol_rows(stdout_lines, "SUBWIN")
        saw_two = any(len(row) >= 2 and row[1] == "2" for row in wincount_rows)
        saw_subwin = any(len(row) >= 2 and row[1] == args.subwin_uri for row in subwin_rows)
        return saw_two and saw_subwin

    cmd = prefix + [str(browser), index_uri, "--e2e-protocol"]
    matched, result = run_interactive_until(cmd, env, args.timeout_sec, condition)

    if not matched:
        print("FAIL\tsubwindow-or-wincount-not-observed")
        print_fail_context("subwindow", result)
        return 1

    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        print("PASS\tsubwindow-opened")
        return 0

    print("FAIL\tsubwindow-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context("subwindow-clean-quit", result)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
