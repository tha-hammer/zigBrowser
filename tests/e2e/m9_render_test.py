#!/usr/bin/env python3
"""M9 HW-gated E2E: macOS WKWebView renders a fixture in a real GUI session."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

from m9_reply_channel_test import (
    default_binary,
    hw_gate_ready,
    run_macos_gui_until,
)
from mac_term_teardown import run_term_only
from slice2_common import SKIP_EXIT, RunResult, eprint, print_fail_context, protocol_rows, require_file


class TitleParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._in_title = False
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag.lower() == "title":
            self._in_title = True

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.parts.append(data)

    @property
    def title(self) -> str:
        return "".join(self.parts).strip()


def fixture_title(index: Path) -> str:
    parser = TitleParser()
    parser.feed(index.read_text(encoding="utf-8"))
    if not parser.title:
        raise ValueError(f"missing <title> in {index}")
    return parser.title


def run_protocol_window(browser: Path, uri: str, expected_title: str, timeout_sec: float) -> tuple[bool, RunResult]:
    cmd = [str(browser), uri, "--e2e-protocol", "--print-title"]

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        return title_and_nav_observed(stdout_lines, uri, expected_title)

    runner_override = os.environ.pop("ZB_M9_GUI_RUNNER", None)
    try:
        return run_macos_gui_until(cmd, dict(os.environ), timeout_sec, condition)
    finally:
        if runner_override is not None:
            os.environ["ZB_M9_GUI_RUNNER"] = runner_override


def run_screenshot_capture(browser: Path, uri: str, capture_path: Path, timeout_sec: float) -> RunResult:
    try:
        proc = run_term_only([str(browser), "--screenshot", str(capture_path), uri, "--print-title"], timeout_sec)
    except subprocess.TimeoutExpired as exc:
        return RunResult(
            returncode=1,
            stdout_lines=str(exc.stdout or "").splitlines(),
            stderr_lines=str(exc.stderr or "").splitlines(),
            tracked_children=set(),
            timed_out=True,
        )

    return RunResult(
        returncode=proc.returncode,
        stdout_lines=proc.stdout.splitlines(),
        stderr_lines=proc.stderr.splitlines(),
        tracked_children=set(),
    )


def check_nonuniform_png(path: Path) -> tuple[bool, str]:
    tool = Path("tests/snapshots/pillow_tools.py")
    result = subprocess.run(
        [sys.executable, str(tool), "nonuniform", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    detail = (result.stdout.strip() or result.stderr.strip())
    return result.returncode == 0, detail


def title_and_nav_observed(stdout_lines: list[str], uri: str, expected_title: str) -> bool:
    title_ok = any(line == f"TITLE\t{expected_title}" for line in stdout_lines)
    nav_ok = any(
        len(row) == 3 and row[1] == uri and row[2] == expected_title
        for row in protocol_rows(stdout_lines, "NAV")
    )
    return title_ok and nav_ok


def title_observed(stdout_lines: list[str], expected_title: str) -> bool:
    return any(line == f"TITLE\t{expected_title}" for line in stdout_lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--capture-path", default=None)
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    # Opt-in (default off, so existing M9/Linux usage is unchanged): capture + the title/protocol
    # checks run here, but the PIL-based nonuniform check is DEFERRED to the caller, which analyzes
    # the PNG on a host that has Pillow. Used by the MS1 two-host gate, where the arm Mac has no
    # Pillow: the render still happens on the arm host; tests/mac/gate.sh routes the PNG to the
    # Intel host's PIL. The capture-missing check below still runs, so a missing PNG still fails.
    parser.add_argument("--no-uniform-check", action="store_true",
                        help="skip the local PIL nonuniform check; the caller analyzes the PNG elsewhere")
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        eprint(reason)
        return SKIP_EXIT

    browser = Path(args.binary or default_binary())
    index = Path(args.index)
    if not require_file(browser, "binary") or not require_file(index, "app index"):
        return SKIP_EXIT

    try:
        expected_title = fixture_title(index)
    except ValueError as exc:
        eprint(f"SKIP: {exc}")
        return SKIP_EXIT

    uri = index.resolve().as_uri()
    capture_path = Path(args.capture_path) if args.capture_path else Path(tempfile.gettempdir()) / "zigBrowser-m9-render.png"
    capture_path.parent.mkdir(parents=True, exist_ok=True)
    if capture_path.exists():
        capture_path.unlink()

    protocol_matched, protocol_result = run_protocol_window(browser, uri, expected_title, args.timeout_sec)
    if not protocol_matched:
        print("FAIL\tm9-render-title-or-nav-not-observed")
        print_fail_context("m9-render-title-or-nav-not-observed", protocol_result)
        return 1

    result = run_screenshot_capture(browser, uri, capture_path, args.timeout_sec)
    if result.returncode != 0:
        print("FAIL\tm9-render-screenshot-exit")
        print_fail_context("m9-render-screenshot-exit", result)
        return 1

    if not title_observed(result.stdout_lines, expected_title):
        print("FAIL\tm9-render-screenshot-title-not-observed")
        print_fail_context("m9-render-screenshot-title-not-observed", result)
        return 1

    if not capture_path.exists() or capture_path.stat().st_size == 0:
        print("FAIL\tm9-render-capture-missing")
        print_fail_context("m9-render-capture-missing", result)
        return 1

    if args.no_uniform_check:
        print(f"PASS\tm9-render-webview-screenshot\t{capture_path}\tuniformity deferred to the caller's PIL host")
        return 0

    ok_png, detail = check_nonuniform_png(capture_path)
    if not ok_png:
        print("FAIL\tm9-render-capture-uniform")
        eprint(detail)
        print_fail_context("m9-render-capture-uniform", result)
        return 1

    print(f"PASS\tm9-render-webview-screenshot\t{capture_path}\t{detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
