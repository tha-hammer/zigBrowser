#!/usr/bin/env python3
"""Slice 3/4 M6 GTK E2E: load-timeout recovery + T-epsilon race resolution.

- recovery: a load that never commits (the server accepts the request and
  never answers) is given up after 15 s with LOAD_FAIL; the browser lives.
- busy page: a page that committed and then runs a script for 22 s is never
  ended by that timer: it finishes (NAV "Hang Finished"), with no LOAD_FAIL.
- race: a page that finishes just before 15 s gets NAV and no LOAD_FAIL."""

from __future__ import annotations

import argparse
import http.server
import threading
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


HANG_HTML = """<!doctype html>
<html>
  <head>
    <meta charset=\"utf-8\" />
    <title>Hang Start</title>
    <script>
      const start = Date.now();
      while (Date.now() - start < 22000) {}
      document.title = "Hang Finished";
    </script>
  </head>
  <body><h1>Hang Page</h1></body>
</html>
"""

RACE_HTML = """<!doctype html>
<html>
  <head>
    <meta charset=\"utf-8\" />
    <title>Race Start</title>
    <script>
      const start = Date.now();
      while (Date.now() - start < 14000) {}
      document.title = "Race Near Timeout";
    </script>
  </head>
  <body><h1>Race Page</h1></body>
</html>
"""


class NeverAnswers(http.server.BaseHTTPRequestHandler):
    """Accepts the request and never answers: the load never commits."""

    release = threading.Event()

    def do_GET(self) -> None:  # noqa: N802 - http.server API
        NeverAnswers.release.wait(120)

    def log_message(self, *_args) -> None:
        pass


def build_fixtures(work_dir: Path) -> tuple[str, str]:
    work_dir.mkdir(parents=True, exist_ok=True)
    hang_file = work_dir / "hang.html"
    race_file = work_dir / "race.html"
    hang_file.write_text(HANG_HTML, encoding="utf-8")
    race_file.write_text(RACE_HTML, encoding="utf-8")
    return hang_file.resolve().as_uri(), race_file.resolve().as_uri()


def run_case(
    browser: Path,
    env: dict[str, str],
    prefix: list[str],
    uri: str,
    timeout_sec: float,
    ok_condition,
    label: str,
) -> tuple[bool, int]:
    cmd = prefix + [str(browser), uri, "--e2e-protocol"]
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
    parser.add_argument("--timeout-sec", type=float, default=45.0)
    parser.add_argument("--work-dir", default="tests/e2e/.tmp/load_timeout")
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT

    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    hang_uri, race_uri = build_fixtures(Path(args.work_dir))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NeverAnswers)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    never_uri = f"http://127.0.0.1:{server.server_address[1]}/never"

    def timeout_condition(stdout_lines: list[str], _stderr: list[str], proc) -> bool:
        rows = protocol_rows(stdout_lines, "LOAD_FAIL")
        for row in rows:
            if len(row) < 4:
                continue
            if row[1] != never_uri:
                continue
            if row[2] == "" or row[3] == "":
                continue
            return proc.poll() is None
        return False

    def busy_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        nav_rows = protocol_rows(stdout_lines, "NAV")
        load_fail_rows = protocol_rows(stdout_lines, "LOAD_FAIL")
        saw_nav = any(len(row) >= 3 and row[1] == hang_uri and row[2] == "Hang Finished" for row in nav_rows)
        saw_load_fail = any(len(row) >= 2 and row[1] == hang_uri for row in load_fail_rows)
        return saw_nav and not saw_load_fail

    def race_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        nav_rows = protocol_rows(stdout_lines, "NAV")
        load_fail_rows = protocol_rows(stdout_lines, "LOAD_FAIL")
        saw_nav = any(
            len(row) >= 3 and row[1] == race_uri and row[2] == "Race Near Timeout"
            for row in nav_rows
        )
        saw_load_fail = any(len(row) >= 2 and row[1] == race_uri for row in load_fail_rows)
        return saw_nav and not saw_load_fail

    try:
        ok_timeout, timeout_code = run_case(
            browser,
            env,
            prefix,
            never_uri,
            args.timeout_sec,
            timeout_condition,
            "load-timeout-recovery-not-observed",
        )
    finally:
        NeverAnswers.release.set()
        server.shutdown()
        server.server_close()
    if not ok_timeout:
        return timeout_code

    ok_busy, busy_code = run_case(
        browser,
        env,
        prefix,
        hang_uri,
        args.timeout_sec,
        busy_condition,
        "load-timeout-killed-a-committed-page",
    )
    if not ok_busy:
        return busy_code

    ok_race, race_code = run_case(
        browser,
        env,
        prefix,
        race_uri,
        args.timeout_sec,
        race_condition,
        "load-timeout-race-resolution-not-observed",
    )
    if not ok_race:
        return race_code

    print("PASS\tload-timeout-recovery-busy-and-race")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
