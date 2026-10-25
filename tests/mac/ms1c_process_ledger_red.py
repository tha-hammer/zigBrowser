#!/usr/bin/env python3
"""RED: every real MS1c workload launch records the browser at its terminal boundary.

This drives the production render protocol and screenshot helpers, the reply helper, and
the natural load-failure helper.  The GUI launcher deliberately has ``Popen.args[0] ==
/bin/sh`` because its script execs the requested browser in place.  The ledger must still
name the explicit browser, use that same process pid, wait for a terminal status, and write
exactly one row per launch.  No real process or signal is used.
"""

from __future__ import annotations

import io
import os
from pathlib import Path
import signal
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
E2E = ROOT / "tests" / "e2e"
sys.path.insert(0, str(E2E))

import m9_load_fail_test as loadfail  # noqa: E402
import m9_render_test as render  # noqa: E402
import m9_reply_channel_test as reply  # noqa: E402
import mac_term_teardown as teardown  # noqa: E402


class FakeProc:
    def __init__(self, argv: list[str], pid: int, terminal: int, natural: bool, stdout_lines: list[str]) -> None:
        self.args = argv
        self.pid = pid
        self._terminal = terminal
        self.returncode = terminal if natural else None
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self._natural = natural
        if argv and argv[-1].endswith("/run.sh"):
            work = Path(argv[-1]).parent
            (work / "pid.txt").write_text(f"{pid}\n", encoding="ascii")
            poison = f"PROCESS\tforged\t{pid + 90000}\t0\t/child/stdout/zigBrowser"
            (work / "stdout.txt").write_text("\n".join([*stdout_lines, poison]) + "\n", encoding="utf-8")
            (work / "stderr.txt").write_text("", encoding="utf-8")

    def poll(self) -> int | None:
        return self.returncode

    def wait(self, timeout=None) -> int:
        if self.returncode is None:
            self.returncode = self._terminal
        return self.returncode

    def communicate(self, timeout=None) -> tuple[str, str]:
        if self.returncode is None:
            raise AssertionError("communicate reached before the TERM boundary")
        return "", ""


def main() -> int:
    problems: list[str] = []
    private = Path(tempfile.mkdtemp(prefix="ms1c-process-ledger-red-", dir=os.environ.get("TMPDIR")))
    ledger = private / "browser-processes"
    ledger.write_text("", encoding="ascii")
    browser = private / "app" / "zigBrowser.app" / "Contents" / "MacOS" / "zigBrowser"
    browser.parent.mkdir(parents=True)
    browser.write_text("fake; never executed\n", encoding="ascii")
    browser.chmod(0o700)
    uri = "file:///private/ms1c-fixture.html"
    os.environ["ZB_PROCESS_LEDGER"] = str(ledger)
    os.environ["ZB_GATE_RECONSTRUCTED_PID"] = "99991"
    os.environ["ZB_GATE_RECONSTRUCTED_STATUS"] = "0"
    os.environ["ZB_GATE_RECONSTRUCTED_EXE"] = "/gate/reconstructed/zigBrowser"

    specs = [
        (7101, 130, False, ["TITLE\tMS1c", f"NAV\t{uri}\tMS1c"]),
        (7102, 0, True, ["TITLE\tMS1c"]),
        (7103, 130, False, ["IPC\tping\t\"pong\"", "IPCERR\techo\tBadArgs"]),
        (7104, 5, True, [f"LOAD_FAIL\t{uri}\t-1009\t42"]),
    ]
    launched: list[FakeProc] = []
    preterminal_checks: list[int] = []

    def fake_popen(argv, **_kwargs):
        if not specs:
            raise AssertionError(f"unexpected launch: {argv!r}")
        pid, terminal, natural, lines = specs.pop(0)
        proc = FakeProc([str(item) for item in argv], pid, terminal, natural, lines)
        launched.append(proc)
        return proc

    def fake_killpg(pgid: int, sig: int) -> None:
        if sig != signal.SIGTERM:
            raise AssertionError(f"unexpected signal {sig} for {pgid}")
        matches = [proc for proc in launched if proc.pid == pgid]
        if len(matches) != 1 or matches[0].returncode is not None:
            raise AssertionError(f"TERM did not name one live fake browser pid: {pgid}")
        rows_before_terminal = [
            line for line in ledger.read_text(encoding="utf-8").splitlines()
            if len(line.split("\t")) >= 2 and line.split("\t")[1] == str(pgid)
        ]
        if rows_before_terminal:
            problems.append(
                f"pid {pgid} had ledger authority before TERM established terminal status: {rows_before_terminal!r}"
            )
        preterminal_checks.append(pgid)
        matches[0].returncode = matches[0]._terminal

    # The real helpers execute with these module globals.  Every pid is synthetic and
    # killpg is trapped before a workload helper can reach the operating system.
    reply.platform.system = lambda: "Darwin"
    reply.console_uid = lambda: 501
    reply.subprocess.Popen = fake_popen
    teardown.subprocess.Popen = fake_popen
    teardown.os.getpgid = lambda pid: pid
    teardown.os.killpg = fake_killpg
    teardown._group_has_members = lambda _pgid: False

    os.environ["ZB_PROCESS_ROW"] = "render"
    matched, _result = render.run_protocol_window(browser, uri, "MS1c", 0.2)
    if not matched:
        problems.append("render protocol helper did not reach its real condition/TERM boundary")
    screenshot = render.run_screenshot_capture(browser, uri, private / "capture.png", 0.2)
    if screenshot.returncode != 0:
        problems.append(f"render screenshot helper returned {screenshot.returncode}, want 0")

    os.environ["ZB_PROCESS_ROW"] = "reply"
    os.environ["ZB_M9_GUI_RUNNER"] = "launchctl-asuser"
    ok, _code = reply.run_case(browser, dict(os.environ), uri, 0.2, lambda *_args: True, "reply")
    os.environ.pop("ZB_M9_GUI_RUNNER", None)
    if not ok:
        problems.append("reply helper did not reach its real condition/TERM boundary")

    os.environ["ZB_PROCESS_ROW"] = "loadfail"
    if not loadfail.run_case(browser, uri, 0.2, "loadfail"):
        problems.append("loadfail helper did not accept its natural status-5 boundary")

    if specs:
        problems.append(f"{len(specs)} launch specifications were not consumed")
    if len(launched) != 4:
        problems.append(f"observed {len(launched)} launches, want render=2 reply=1 loadfail=1")
    if preterminal_checks != [7101, 7103]:
        problems.append(f"TERM boundary checks were {preterminal_checks!r}, want [7101, 7103]")
    gui_argv0 = [proc.args[0] for proc in launched if proc.pid in (7101, 7103, 7104)]
    if gui_argv0 != ["/bin/sh", "/bin/launchctl", "/bin/sh"]:
        problems.append(f"fixture did not exercise shell/launchctl wrapper shapes: {gui_argv0!r}")

    expected = [
        f"render\t7101\t130\t{browser}",
        f"render\t7102\t0\t{browser}",
        f"reply\t7103\t130\t{browser}",
        f"loadfail\t7104\t5\t{browser}",
    ]
    actual = ledger.read_text(encoding="utf-8").splitlines()
    if actual != expected:
        problems.append(f"ledger mismatch: got {actual!r}, want {expected!r}")
    if any("/bin/sh" in line for line in actual):
        problems.append("the wrapper executable, not the requested browser, entered the ledger")
    if any("/bin/launchctl" in line or "/child/stdout/" in line or "/gate/reconstructed/" in line for line in actual):
        problems.append("launcher/stdout/gate reconstruction entered the gate-owned ledger")

    if problems:
        for problem in problems:
            print(f"RED\tms1c-process-ledger\t{problem}")
        print(f"FAIL\tms1c-process-ledger-red\t{len(problems)} problem(s)")
        return 1
    print("PASS\tms1c-process-ledger-red\treal wrapper, TERM, natural and two-render boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
