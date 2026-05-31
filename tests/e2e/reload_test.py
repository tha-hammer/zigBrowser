#!/usr/bin/env python3
"""Slice 2 Behavior 1 E2E: programmatic reload via SIGHUP emits a second NAV."""

from __future__ import annotations

import argparse
import shutil
import signal
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
    parser.add_argument("--fixture", default="tests/fixtures/app/index.mutable.html")
    parser.add_argument("--work-dir", default="tests/e2e/.tmp/reload_case")
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    fixture = Path(args.fixture)
    if not require_file(browser, "binary") or not require_file(fixture, "reload fixture"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    mutable_index = work_dir / "index.html"
    shutil.copyfile(fixture, mutable_index)
    uri = mutable_index.resolve().as_uri()

    state = {"reloaded": False}

    def on_tick(stdout_lines: list[str], _stderr: list[str], proc) -> None:
        nav_rows = protocol_rows(stdout_lines, "NAV")
        if state["reloaded"]:
            return
        if any(len(row) >= 3 and row[2] == "Reload Title A" for row in nav_rows):
            text = mutable_index.read_text(encoding="utf-8")
            text = text.replace("Reload Title A", "Reload Title B")
            text = text.replace("Reload Marker A", "Reload Marker B")
            mutable_index.write_text(text, encoding="utf-8")
            proc.send_signal(signal.SIGHUP)
            state["reloaded"] = True

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        nav_rows = protocol_rows(stdout_lines, "NAV")
        saw_a = any(len(row) >= 3 and row[1] == uri and row[2] == "Reload Title A" for row in nav_rows)
        saw_b = any(len(row) >= 3 and row[1] == uri and row[2] == "Reload Title B" for row in nav_rows)
        return saw_a and saw_b

    cmd = prefix + [str(browser), uri, "--e2e-protocol"]
    matched, result = run_interactive_until(cmd, env, args.timeout_sec, condition, on_tick=on_tick)

    if not matched:
        print("FAIL\treload-second-nav-not-observed")
        print_fail_context("reload", result)
        return 1

    ok_exit = result.returncode in (0, 130)
    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    if ok_exit and ok_children:
        print("PASS\treload-nav-a-to-b")
        return 0

    print("FAIL\treload-clean-quit")
    if not ok_children:
        eprint(f"alive_children={alive}")
    print_fail_context("reload-clean-quit", result)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
