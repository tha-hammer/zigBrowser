#!/usr/bin/env python3
"""Slice 3/4 M3 GTK E2E: traversal navigation outside app base is blocked."""

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

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    index_resolved = index.resolve()
    index_uri = index_resolved.as_uri() + "#auto=traversal"
    app_dir = index_resolved.parent
    traversal_raw_uri = app_dir.as_uri() + "/../outside.html"
    traversal_canonical_uri = app_dir.parent.joinpath("outside.html").as_uri()

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        blocked_rows = protocol_rows(stdout_lines, "BLOCKED")
        nav_rows = protocol_rows(stdout_lines, "NAV")

        saw_block = any(
            len(row) >= 2 and row[1] in {traversal_raw_uri, traversal_canonical_uri}
            for row in blocked_rows
        )
        saw_forbidden_nav = any(
            len(row) >= 2 and row[1] in {traversal_raw_uri, traversal_canonical_uri}
            for row in nav_rows
        )
        return saw_block and not saw_forbidden_nav

    cmd = prefix + [str(browser), index_uri, "--e2e-protocol"]
    matched, result = run_interactive_until(cmd, env, args.timeout_sec, condition)

    if not matched:
        print("FAIL\ttraversal-blocked-not-observed")
        print_fail_context("nav-block-traversal", result)
        return 1

    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        print("PASS\tnav-block-traversal")
        return 0

    print("FAIL\tnav-block-traversal-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context("nav-block-traversal-clean-quit", result)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
