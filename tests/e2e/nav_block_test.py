#!/usr/bin/env python3
"""Slice 2 Behavior 3 E2E: foreign and traversal navigation are blocked."""

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
    parser.add_argument("--blocked-uri", default="https://example.com/")
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
    index_uri = index_resolved.as_uri()
    app_dir = index_resolved.parent
    traversal_raw_uri = app_dir.as_uri() + "/../outside.html"
    traversal_canonical_uri = app_dir.parent.joinpath("outside.html").as_uri()

    def run_case(auto_mode: str, expected_blocked_uris: set[str], forbidden_nav_uris: set[str]) -> tuple[bool, object]:
        def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
            blocked_rows = protocol_rows(stdout_lines, "BLOCKED")
            if not any(len(row) >= 2 and row[1] in expected_blocked_uris for row in blocked_rows):
                return False
            nav_rows = protocol_rows(stdout_lines, "NAV")
            return not any(len(row) >= 2 and row[1] in forbidden_nav_uris for row in nav_rows)

        cmd = prefix + [str(browser), index_uri + f"#auto={auto_mode}", "--e2e-protocol"]
        return run_interactive_until(cmd, env, args.timeout_sec, condition)

    matched, result = run_case(
        "block",
        {args.blocked_uri},
        {args.blocked_uri},
    )
    if not matched:
        print("FAIL\tforeign-blocked-not-observed")
        print_fail_context("nav-block-foreign", result)
        return 1

    matched, result = run_case(
        "traversal",
        {traversal_raw_uri, traversal_canonical_uri},
        {traversal_raw_uri, traversal_canonical_uri},
    )
    if not matched:
        print("FAIL\ttraversal-blocked-not-observed")
        print_fail_context("nav-block-traversal", result)
        return 1

    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        print("PASS\tnav-block-foreign-and-traversal")
        return 0

    print("FAIL\tnav-block-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context("nav-block-clean-quit", result)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
