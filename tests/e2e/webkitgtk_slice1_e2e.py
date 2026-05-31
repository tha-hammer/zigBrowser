#!/usr/bin/env python3
"""
WebKitGTK Slice 1 E2E harness skeleton.

Protocol under test (§C8):
- TITLE oracle via `--print-title` stdout line: `TITLE\t<title>`
- PNG oracle via `--screenshot` + `tests/snapshots/pillow_tools.py nonuniform`
- Clean-quit helper check: record child PIDs while parent is alive, then assert
  those exact PIDs have exited after parent termination.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

SKIP_EXIT = 77


def _eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def _is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


def _child_pids_linux(proc_pid: int) -> set[int]:
    children_file = Path(f"/proc/{proc_pid}/task/{proc_pid}/children")
    if children_file.exists():
        raw = children_file.read_text(encoding="utf-8").strip()
        if not raw:
            return set()
        return {int(item) for item in raw.split() if item.isdigit()}

    pgrep = shutil.which("pgrep")
    if pgrep is None:
        return set()
    cmd = [pgrep, "-P", str(proc_pid)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode not in (0, 1):
        return set()
    return {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}


def _assert_children_exit(children: Iterable[int], timeout_sec: float) -> tuple[bool, list[int]]:
    deadline = time.monotonic() + timeout_sec
    children_set = set(children)
    while time.monotonic() < deadline:
        alive = [pid for pid in children_set if _is_pid_alive(pid)]
        if not alive:
            return True, []
        time.sleep(0.05)
    alive = [pid for pid in children_set if _is_pid_alive(pid)]
    return len(alive) == 0, alive


def _detect_runner(prefer_xvfb: bool) -> tuple[list[str], dict[str, str], str] | None:
    env = dict(os.environ)
    xvfb = shutil.which("xvfb-run")
    display = env.get("DISPLAY")

    if prefer_xvfb and xvfb:
        return [xvfb, "-a"], env, "xvfb-run"

    if display:
        return [], env, f"DISPLAY={display}"

    # Coordinator-provided local fallback when xvfb-run is absent.
    if Path("/tmp/.X11-unix/X1").exists():
        env["DISPLAY"] = ":1"
        return [], env, "DISPLAY=:1"

    if xvfb:
        return [xvfb, "-a"], env, "xvfb-run"

    _eprint("SKIP: no DISPLAY and no xvfb-run; install xvfb or export DISPLAY")
    return None


@dataclass
class RunResult:
    returncode: int
    stdout_lines: list[str]
    stderr_lines: list[str]
    tracked_children: set[int]


def _run_with_tracking(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    terminate_on_title: bool,
) -> RunResult:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    assert proc.stdout is not None
    assert proc.stderr is not None
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    out_thread = threading.Thread(target=_read_lines, args=(proc.stdout, stdout_lines), daemon=True)
    err_thread = threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True)
    out_thread.start()
    err_thread.start()

    tracked_children: set[int] = set()
    deadline = time.monotonic() + timeout_sec
    title_seen = False

    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        tracked_children.update(_child_pids_linux(proc.pid))
        title_seen = any(line.startswith("TITLE\t") for line in stdout_lines)
        if terminate_on_title and title_seen:
            proc.send_signal(signal.SIGTERM)
            break
        time.sleep(0.05)

    try:
        proc.wait(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)

    out_thread.join(timeout=1)
    err_thread.join(timeout=1)

    return RunResult(
        returncode=proc.returncode,
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=tracked_children,
    )


def _expect_title_line(lines: list[str], expected_title: str) -> bool:
    want = f"TITLE\t{expected_title}"
    return any(line == want for line in lines)


def _run_pillow_nonuniform(pillow_tool: Path, png_path: Path) -> tuple[int, str, str]:
    result = subprocess.run(
        [sys.executable, str(pillow_tool), "nonuniform", str(png_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


def _resolve_missing_fixture_path(fixtures_dir: Path) -> Path:
    marker = fixtures_dir / "missing-file.txt"
    if not marker.exists():
        return fixtures_dir / "does-not-exist.html"
    rel = marker.read_text(encoding="utf-8").strip()
    if not rel:
        return fixtures_dir / "does-not-exist.html"
    return (Path.cwd() / rel).resolve()


def _format_result(label: str, ok: bool) -> None:
    status = "PASS" if ok else "FAIL"
    print(f"{status}\t{label}")


def main() -> int:
    parser = argparse.ArgumentParser(description="WebKitGTK Slice 1 E2E harness skeleton")
    parser.add_argument("--mode", choices=["open-title", "screenshot", "missing-file", "all"], default="all")
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--fixtures-dir", default="tests/fixtures")
    parser.add_argument("--pillow-tool", default="tests/snapshots/pillow_tools.py")
    parser.add_argument("--work-dir", default="tests/e2e/.tmp")
    parser.add_argument("--timeout-sec", type=float, default=25.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not browser.exists():
        _eprint(f"SKIP: browser binary not found: {browser}")
        return SKIP_EXIT

    fixtures_dir = Path(args.fixtures_dir)
    live_fixture = (fixtures_dir / "live.html").resolve()
    if not live_fixture.exists():
        _eprint(f"SKIP: missing fixture: {live_fixture}")
        return SKIP_EXIT

    pillow_tool = Path(args.pillow_tool)
    if not pillow_tool.exists():
        _eprint(f"SKIP: missing pillow tool: {pillow_tool}")
        return SKIP_EXIT

    runner = _detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    _eprint(f"E2E runner: {runner_note}")

    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    modes = [args.mode] if args.mode != "all" else ["open-title", "screenshot", "missing-file"]
    failures = 0

    for mode in modes:
        if mode == "open-title":
            cmd = prefix + [
                str(browser),
                str(live_fixture.as_uri()),
                "--print-title",
            ]
            result = _run_with_tracking(cmd, env, args.timeout_sec, terminate_on_title=True)
            ok_title = _expect_title_line(result.stdout_lines, "WebKitGTK Live")
            ok_exit = result.returncode in (0, 130)
            ok_children, alive = _assert_children_exit(result.tracked_children, 3.0)
            ok = ok_title and ok_exit and ok_children
            _format_result("open-title protocol + clean-quit", ok)
            if not ok:
                failures += 1
                _eprint(f"open-title return={result.returncode} alive_children={alive}")
                _eprint("stdout:\n" + "\n".join(result.stdout_lines))
                _eprint("stderr:\n" + "\n".join(result.stderr_lines))
            continue

        if mode == "screenshot":
            out_png = work_dir / "live.png"
            if out_png.exists():
                out_png.unlink()
            cmd = prefix + [
                str(browser),
                "--screenshot",
                str(out_png),
                str(live_fixture.as_uri()),
                "--print-title",
            ]
            result = _run_with_tracking(cmd, env, args.timeout_sec, terminate_on_title=False)
            ok_title = _expect_title_line(result.stdout_lines, "WebKitGTK Live")
            ok_exit = result.returncode == 0
            ok_png = out_png.exists()
            nonuniform_ok = False
            if ok_png:
                nonuniform_rc, nonuniform_out, nonuniform_err = _run_pillow_nonuniform(pillow_tool, out_png)
                if nonuniform_rc == 2:
                    _eprint("SKIP: pillow runtime dependency missing")
                    return SKIP_EXIT
                nonuniform_ok = nonuniform_rc == 0
                if not nonuniform_ok:
                    _eprint(f"nonuniform failed rc={nonuniform_rc} out={nonuniform_out} err={nonuniform_err}")
            ok_children, alive = _assert_children_exit(result.tracked_children, 3.0)
            ok = ok_title and ok_exit and ok_png and nonuniform_ok and ok_children
            _format_result("screenshot protocol + nonuniform + clean-quit", ok)
            if not ok:
                failures += 1
                _eprint(f"screenshot return={result.returncode} png_exists={ok_png} alive_children={alive}")
                _eprint("stdout:\n" + "\n".join(result.stdout_lines))
                _eprint("stderr:\n" + "\n".join(result.stderr_lines))
            continue

        if mode == "missing-file":
            missing_path = _resolve_missing_fixture_path(fixtures_dir)
            out_png = work_dir / "missing.png"
            if out_png.exists():
                out_png.unlink()
            cmd = prefix + [
                str(browser),
                "--screenshot",
                str(out_png),
                str(missing_path.as_uri()),
            ]
            result = _run_with_tracking(cmd, env, args.timeout_sec, terminate_on_title=False)
            ok_exit = result.returncode != 0
            ok_no_png = not out_png.exists()
            ok_children, alive = _assert_children_exit(result.tracked_children, 3.0)
            ok = ok_exit and ok_no_png and ok_children
            _format_result("missing-file nonzero + no-png + clean-quit", ok)
            if not ok:
                failures += 1
                _eprint(f"missing-file return={result.returncode} png_exists={out_png.exists()} alive_children={alive}")
                _eprint("stdout:\n" + "\n".join(result.stdout_lines))
                _eprint("stderr:\n" + "\n".join(result.stderr_lines))
            continue

    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
