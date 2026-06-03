#!/usr/bin/env python3
"""M9 HW-gated E2E: macOS WKWebView renders a fixture in a real GUI session."""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

from m9_reply_channel_test import (
    default_binary,
    env_exports,
    gui_runner_prefix,
    hw_gate_ready,
    read_file_lines,
    read_int_file,
    terminate_process,
)
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


def write_render_script(
    script_path: Path,
    browser: Path,
    uri: str,
    stdout_path: Path,
    stderr_path: Path,
    pid_path: Path,
    capture_path: Path,
    env: dict[str, str],
    cwd: Path,
    settle_sec: float,
) -> None:
    command = " ".join(
        shlex.quote(str(item))
        for item in [browser, uri, "--e2e-protocol", "--print-title"]
    )
    script = "\n".join(
        [
            "#!/bin/sh",
            "set -u",
            f"cd {shlex.quote(str(cwd))}",
            *env_exports(env),
            f": > {shlex.quote(str(stdout_path))}",
            f": > {shlex.quote(str(stderr_path))}",
            f"{command} >> {shlex.quote(str(stdout_path))} 2>> {shlex.quote(str(stderr_path))} &",
            "pid=$!",
            f"printf '%s\\n' \"$pid\" > {shlex.quote(str(pid_path))}",
            f"sleep {settle_sec:.3f}",
            "if ! kill -0 \"$pid\" 2>/dev/null; then",
            "  wait \"$pid\"",
            "  rc=$?",
            "  printf 'ZB_HARNESS_EXIT\\t%s\\n' \"$rc\" >> " + shlex.quote(str(stdout_path)),
            "  exit 1",
            "fi",
            f"/usr/sbin/screencapture -x {shlex.quote(str(capture_path))}",
            "capture_rc=$?",
            "kill \"$pid\" 2>/dev/null || true",
            "sleep 0.5",
            "kill -9 \"$pid\" 2>/dev/null || true",
            "wait \"$pid\" 2>/dev/null",
            "rc=$?",
            "printf 'ZB_HARNESS_EXIT\\t%s\\n' \"$rc\" >> " + shlex.quote(str(stdout_path)),
            "exit \"$capture_rc\"",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8")
    script_path.chmod(0o755)


def run_render_capture(
    browser: Path,
    uri: str,
    capture_path: Path,
    env: dict[str, str],
    timeout_sec: float,
    settle_sec: float,
) -> RunResult:
    work_dir = Path(tempfile.mkdtemp(prefix="zigBrowser-m9-render-"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    pid_path = work_dir / "pid.txt"
    script_path = work_dir / "render.sh"
    write_render_script(
        script_path,
        browser,
        uri,
        stdout_path,
        stderr_path,
        pid_path,
        capture_path,
        env,
        Path.cwd().resolve(),
        settle_sec,
    )

    prefix, _runner_note = gui_runner_prefix()
    try:
        proc = subprocess.run(
            prefix + ["/bin/sh", str(script_path)],
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        pid = read_int_file(pid_path)
        terminate_process(pid)
        stdout_lines = read_file_lines(stdout_path)
        stderr_lines = read_file_lines(stderr_path)
        if exc.stderr:
            stderr_lines.extend(str(exc.stderr).splitlines())
        if exc.stdout:
            stdout_lines.extend(str(exc.stdout).splitlines())
        return RunResult(
            returncode=1,
            stdout_lines=stdout_lines,
            stderr_lines=stderr_lines,
            tracked_children=set(),
            timed_out=True,
            pid=pid,
        )

    stdout_lines = read_file_lines(stdout_path)
    stderr_lines = read_file_lines(stderr_path)
    if proc.stderr:
        stderr_lines.extend(proc.stderr.splitlines())
    if proc.stdout:
        stdout_lines.extend(proc.stdout.splitlines())
    return RunResult(
        returncode=proc.returncode,
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--capture-path", default=None)
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    parser.add_argument("--settle-sec", type=float, default=5.0)
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

    result = run_render_capture(browser, uri, capture_path, dict(os.environ), args.timeout_sec, args.settle_sec)

    if not title_and_nav_observed(result.stdout_lines, uri, expected_title):
        print("FAIL\tm9-render-title-or-nav-not-observed")
        print_fail_context("m9-render-title-or-nav-not-observed", result)
        return 1

    if not capture_path.exists() or capture_path.stat().st_size == 0:
        print("FAIL\tm9-render-capture-missing")
        print_fail_context("m9-render-capture-missing", result)
        return 1

    ok_png, detail = check_nonuniform_png(capture_path)
    if not ok_png:
        print("FAIL\tm9-render-capture-uniform")
        eprint(detail)
        print_fail_context("m9-render-capture-uniform", result)
        return 1

    print(f"PASS\tm9-render-real-window\t{capture_path}\t{detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
