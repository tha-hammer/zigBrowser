#!/usr/bin/env python3
"""Slice 3/4 M1/M2 GTK E2E: echo roundtrip success + bad-args rejection.

Besides the browser's IPC/IPCERR rows, the page itself must see its zbHost
promise settle (chat-drawer plan S1.6): the fixture titles the page
"resolved:<value>" or "rejected:<message>" from the promise's own branches.
The title is read through the automation socket (page.evaluate), a path
that does not go through zbHost; --print-title cannot be used, because its
TITLE row reports only the first title of a load."""

from __future__ import annotations

import argparse
import atexit
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sdk/python/src"))

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


def run_case(
    binary: Path,
    env: dict[str, str],
    prefix: list[str],
    uri: str,
    timeout_sec: float,
    ok_condition,
    label: str,
) -> tuple[bool, int]:
    cmd = prefix + [str(binary), uri, "--e2e-protocol", "--automation-api"]
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
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
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

    from zigbrowser import ZigBrowser

    socket_dir = tempfile.TemporaryDirectory(prefix="zb-ipc-e2e-")
    atexit.register(socket_dir.cleanup)
    socket_path = Path(socket_dir.name) / "automation.sock"
    env["ZIGBROWSER_SOCKET"] = str(socket_path)

    def page_title() -> str:
        """The page's own document.title, or "" while the socket is not up."""
        if not socket_path.exists():
            return ""
        try:
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                return str(zb.call("page.evaluate", {"expression": "document.title", "window_id": "window-1"})["result"])
        except Exception:  # noqa: BLE001 - still starting or loading
            return ""

    success_uri = index.resolve().as_uri() + "#auto=echo"
    bad_args_uri = index.resolve().as_uri() + "#auto=echo-bad"

    def success_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipc_rows = protocol_rows(stdout_lines, "IPC")
        ipcerr_rows = protocol_rows(stdout_lines, "IPCERR")
        saw_success = any(
            len(row) >= 3 and row[1] == "echo" and row[2] == '"hi-42"' for row in ipc_rows
        )
        saw_error = any(len(row) >= 3 and row[1] == "echo" for row in ipcerr_rows)
        return saw_success and not saw_error and page_title().startswith("resolved:hi-42")

    def bad_args_condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        ipcerr_rows = protocol_rows(stdout_lines, "IPCERR")
        ipc_rows = protocol_rows(stdout_lines, "IPC")
        saw_bad_args = any(
            len(row) >= 3 and row[1] == "echo" and row[2] == "BadArgs" for row in ipcerr_rows
        )
        saw_success = any(len(row) >= 3 and row[1] == "echo" for row in ipc_rows)
        return saw_bad_args and not saw_success and page_title().startswith("rejected:BadArgs")

    ok_success, code_success = run_case(
        browser,
        env,
        prefix,
        success_uri,
        args.timeout_sec,
        success_condition,
        "ipc-echo-success-not-observed",
    )
    if not ok_success:
        return code_success

    ok_bad_args, code_bad_args = run_case(
        browser,
        env,
        prefix,
        bad_args_uri,
        args.timeout_sec,
        bad_args_condition,
        "ipc-echo-badargs-not-observed",
    )
    if not ok_bad_args:
        return code_bad_args

    print("PASS\tipc-echo-success-and-badargs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
