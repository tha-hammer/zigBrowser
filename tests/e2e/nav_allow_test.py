#!/usr/bin/env python3
"""Slice 2 Behavior 2 E2E: in-app navigation under base emits NAV to page-b."""

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
    parser.add_argument("--timeout-sec", type=float, default=25.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    index = Path(args.index)
    if not require_file(browser, "binary") or not require_file(index, "app index"):
        return SKIP_EXIT

    page_b_uri = index.resolve().with_name("page-b.html").as_uri()
    index_uri = index.resolve().as_uri() + "#auto=allow"

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        nav_rows = protocol_rows(stdout_lines, "NAV")
        return any(len(row) >= 3 and row[1] == page_b_uri and row[2] == "App Page B" for row in nav_rows)

    cmd = prefix + [str(browser), index_uri, "--e2e-protocol"]
    matched, result = run_interactive_until(cmd, env, args.timeout_sec, condition)

    if not matched:
        print("FAIL\tnav-allow-page-b-not-observed")
        print_fail_context("nav-allow", result)
        return 1

    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        print("PASS\tnav-allow-page-b")
        return 0

    print("FAIL\tnav-allow-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context("nav-allow-clean-quit", result)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
