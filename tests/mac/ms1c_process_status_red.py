#!/usr/bin/env python3
"""RED: MS1c terminal status is specific to each row and its real lifecycle.

The real teardown helper must write a gate-owned TERM marker only after its one
identity-checked group SIGTERM succeeds.  The process classifier joins that marker
to the post-terminal process row.  Status 130 is therefore valid only for render's
first (protocol) launch, reply, and arch; it is never a blanket allowlist value.
No real process or signal is used by this oracle.
"""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
E2E = ROOT / "tests" / "e2e"
AUDIT = ROOT / "tests" / "mac" / "ms1c_crash_audit.py"
GATE = ROOT / "tests" / "mac" / "ms1c_app_gate.sh"
sys.path.insert(0, str(E2E))
sys.path.insert(0, str(AUDIT.parent))

import mac_term_teardown as teardown  # noqa: E402
from ms1c_crash_audit import field  # noqa: E402


class FakeProc:
    def __init__(self, pid: int, terminal: int, executable: str, live: bool) -> None:
        self.pid = pid
        self.terminal = terminal
        self.args = [executable, "about:blank"]
        self.returncode = None if live else terminal
        self.terminal_check = None

    def poll(self) -> int | None:
        if self.returncode is not None and self.terminal_check is not None:
            self.terminal_check()
        return self.returncode

    def wait(self, timeout=None) -> int:
        if self.returncode is None:
            raise AssertionError("wait happened before the fake TERM send established status")
        return self.returncode


def process_line(row: str, pid: int, status: int, executable: str) -> str:
    return f"{row}\t{pid}\t{status}\t{executable}"


def marker_line(row: str, pid: int, pgid: int | None = None) -> str:
    return f"TERM\t{row}\t{pid}\t{pid if pgid is None else pgid}"


def run_row(ledger: Path, lifecycle: Path, row: str, count: int, executable: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            "-X", "dev", "-W", "error", "-B", str(AUDIT), "row",
            "--ledger", str(ledger),
            "--lifecycle-ledger", str(lifecycle),
            "--audit-marker", str(ledger.parent / f"audit-{row}"),
            "--row", row,
            "--expected-count", str(count),
            "--expected-exe", executable,
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def main() -> int:
    problems: list[str] = []
    private = Path(tempfile.mkdtemp(prefix="ms1c-process-status-red-", dir=os.environ.get("TMPDIR")))
    ledger = private / "browser-processes"
    lifecycle = private / "browser-lifecycle"
    ledger.write_text("", encoding="ascii")
    lifecycle.write_text("", encoding="ascii")
    app = str(private / "app" / "zigBrowser.app" / "Contents" / "MacOS" / "zigBrowser")
    control = str(private / "control" / "zigBrowser.app" / "Contents" / "MacOS" / "zigBrowser")
    os.environ["ZB_PROCESS_LEDGER"] = str(ledger)
    os.environ["ZB_PROCESS_LIFECYCLE_LEDGER"] = str(lifecycle)

    launched: dict[int, FakeProc] = {}
    sends: list[tuple[int, int]] = []
    pre_send_markers: list[tuple[int, list[str]]] = []

    def fake_killpg(pgid: int, sig: int) -> None:
        if sig != signal.SIGTERM or pgid not in launched or launched[pgid].returncode is not None:
            raise AssertionError(f"unsafe fake signal {pgid=} {sig=}")
        before = [line for line in lifecycle.read_text(encoding="ascii").splitlines() if f"\t{pgid}\t" in line]
        pre_send_markers.append((pgid, before))
        sends.append((pgid, sig))
        launched[pgid].returncode = launched[pgid].terminal

    teardown.os.getpgid = lambda pid: pid
    teardown.os.killpg = fake_killpg
    teardown._group_has_members = lambda _pgid: False

    def term(row: str, pid: int, executable: str) -> None:
        os.environ["ZB_PROCESS_ROW"] = row
        proc = FakeProc(pid, 130, executable, live=True)
        order_reported = False

        def require_marker_before_terminal_observation() -> None:
            nonlocal order_reported
            if order_reported:
                return
            order_reported = True
            markers = lifecycle.read_text(encoding="ascii").splitlines()
            expected = marker_line(row, pid)
            if markers.count(expected) != 1:
                problems.append(
                    f"{row} pid {pid} became terminal before its one post-send lifecycle marker: {markers!r}"
                )

        proc.terminal_check = require_marker_before_terminal_observation
        launched[pid] = proc
        teardown.stop_browser_term_only(proc, grace_s=0.1, executable=executable)

    def natural(row: str, pid: int, status: int, executable: str) -> None:
        os.environ["ZB_PROCESS_ROW"] = row
        proc = FakeProc(pid, status, executable, live=False)
        launched[pid] = proc
        teardown.record_terminal_process(proc, executable)

    # The exact MS1c order: render protocol, render screenshot, reply, loadfail,
    # arch and missing-dylib control.
    term("render", 7201, app)
    natural("render", 7202, 0, app)
    term("reply", 7203, app)
    natural("loadfail", 7204, 5, app)
    term("arch", 7205, app)
    natural("control", 7206, -6, control)

    want_process = [
        process_line("render", 7201, 130, app),
        process_line("render", 7202, 0, app),
        process_line("reply", 7203, 130, app),
        process_line("loadfail", 7204, 5, app),
        process_line("arch", 7205, 130, app),
        process_line("control", 7206, -6, control),
    ]
    want_lifecycle = [marker_line("render", 7201), marker_line("reply", 7203), marker_line("arch", 7205)]
    actual_process = ledger.read_text(encoding="utf-8").splitlines()
    actual_lifecycle = lifecycle.read_text(encoding="utf-8").splitlines()
    if actual_process != want_process:
        problems.append(f"real helper process rows are {actual_process!r}, want {want_process!r}")
    if actual_lifecycle != want_lifecycle:
        problems.append(f"real helper lifecycle rows are {actual_lifecycle!r}, want {want_lifecycle!r}")
    if pre_send_markers != [(7201, []), (7203, []), (7205, [])]:
        problems.append(f"TERM markers existed before their sends: {pre_send_markers!r}")
    if sends != [(7201, signal.SIGTERM), (7203, signal.SIGTERM), (7205, signal.SIGTERM)]:
        problems.append(f"signal sends are {sends!r}")

    for row, count, executable, expected_rows in (
        ("render", 2, app, want_process[:2]),
        ("reply", 1, app, want_process[2:3]),
        ("loadfail", 1, app, want_process[3:4]),
        ("arch", 1, app, want_process[4:5]),
        ("control", 1, control, want_process[5:6]),
    ):
        result = run_row(ledger, lifecycle, row, count, executable)
        expected_output = [
            f"PROCESS\t{record.split(chr(9), 3)[0]}\t{record.split(chr(9), 3)[1]}\t"
            f"{record.split(chr(9), 3)[2]}\t{field(executable)}"
            for record in expected_rows
        ]
        if result.returncode != 0 or result.stdout.splitlines() != expected_output or result.stderr:
            problems.append(
                f"good {row} lifecycle classified rc={result.returncode} out={result.stdout!r} err={result.stderr!r}"
            )

    def fixture_case(
        label: str,
        process_rows: list[str],
        marker_rows: list[str],
        row: str,
        count: int,
        executable: str,
        want_rc: int,
        required: str,
    ) -> None:
        case_ledger = private / f"{label}.process"
        case_lifecycle = private / f"{label}.lifecycle"
        case_ledger.write_text("\n".join(process_rows) + "\n", encoding="utf-8")
        case_lifecycle.write_text("\n".join(marker_rows) + ("\n" if marker_rows else ""), encoding="utf-8")
        result = run_row(case_ledger, case_lifecycle, row, count, executable)
        if result.returncode != want_rc or required not in result.stdout or result.stderr:
            problems.append(
                f"{label} classified rc={result.returncode} out={result.stdout!r} err={result.stderr!r}; "
                f"want rc {want_rc} containing {required!r}"
            )

    # A status-130 record without its exact send, or with a wrong pid/group/row,
    # is incomplete evidence rather than an allowed normal exit.
    fixture_case("term-missing", want_process, want_lifecycle[1:], "render", 2, app, 3,
                 "PROCESSAUDIT\tINCONCLUSIVE\tmissing TERM lifecycle")
    fixture_case("term-wrong-pid", want_process, [marker_line("render", 7291), *want_lifecycle[1:]],
                 "render", 2, app, 3, "PROCESSAUDIT\tINCONCLUSIVE\tconflict TERM lifecycle")
    fixture_case("term-wrong-group", want_process, [marker_line("render", 7201, 7291), *want_lifecycle[1:]],
                 "render", 2, app, 3, "PROCESSAUDIT\tINCONCLUSIVE\tconflict TERM lifecycle")
    fixture_case("term-wrong-row", want_process, [marker_line("reply", 7201), *want_lifecycle[1:]],
                 "render", 2, app, 3, "PROCESSAUDIT\tINCONCLUSIVE\tconflict TERM lifecycle")
    fixture_case("term-duplicate", want_process, [want_lifecycle[0], want_lifecycle[0], *want_lifecycle[1:]],
                 "render", 2, app, 3, "PROCESSAUDIT\tINCONCLUSIVE\tduplicate TERM lifecycle")

    # Exact per-launch statuses: these are product failures even if a blanket
    # status-130 implementation invents a matching TERM marker.
    render_second_130 = [*want_process]
    render_second_130[1] = process_line("render", 7202, 130, app)
    fixture_case("render-screenshot-130", render_second_130,
                 [want_lifecycle[0], marker_line("render", 7202), *want_lifecycle[1:]],
                 "render", 2, app, 1, "PRODUCT-FAIL\tabnormal-exit\trender\t7202\t130")
    loadfail_130 = [*want_process]
    loadfail_130[3] = process_line("loadfail", 7204, 130, app)
    fixture_case("loadfail-130", loadfail_130, [*want_lifecycle, marker_line("loadfail", 7204)],
                 "loadfail", 1, app, 1, "PRODUCT-FAIL\tabnormal-exit\tloadfail\t7204\t130")
    control_130 = [*want_process]
    control_130[5] = process_line("control", 7206, 130, control)
    fixture_case("control-130", control_130, [*want_lifecycle, marker_line("control", 7206)],
                 "control", 1, control, 1, "PRODUCT-FAIL\tabnormal-exit\tcontrol\t7206\t130")
    arch_zero = [*want_process]
    arch_zero[4] = process_line("arch", 7205, 0, app)
    fixture_case("arch-zero", arch_zero, want_lifecycle, "arch", 1, app, 1,
                 "PRODUCT-FAIL\tabnormal-exit\tarch\t7205\t0")
    render_protocol_zero = [*want_process]
    render_protocol_zero[0] = process_line("render", 7201, 0, app)
    fixture_case("render-protocol-zero", render_protocol_zero, want_lifecycle, "render", 2, app, 1,
                 "PRODUCT-FAIL\tabnormal-exit\trender\t7201\t0")
    reply_zero = [*want_process]
    reply_zero[2] = process_line("reply", 7203, 0, app)
    fixture_case("reply-zero", reply_zero, want_lifecycle, "reply", 1, app, 1,
                 "PRODUCT-FAIL\tabnormal-exit\treply\t7203\t0")
    loadfail_zero = [*want_process]
    loadfail_zero[3] = process_line("loadfail", 7204, 0, app)
    fixture_case("loadfail-zero", loadfail_zero, want_lifecycle, "loadfail", 1, app, 1,
                 "PRODUCT-FAIL\tabnormal-exit\tloadfail\t7204\t0")
    control_zero = [*want_process]
    control_zero[5] = process_line("control", 7206, 0, control)
    fixture_case("control-zero", control_zero, want_lifecycle, "control", 1, control, 1,
                 "PRODUCT-FAIL\tabnormal-exit\tcontrol\t7206\t0")

    # The actual gate must create one private lifecycle ledger, give it to the
    # helper environment and pass that same evidence to both row and final-report
    # classification.  The old generic status allowlist must disappear.
    gate_source = GATE.read_text(encoding="utf-8")
    gate_requirements = {
        'creates lifecycle ledger': ': > "$EV/browser-lifecycle"',
        'exports lifecycle ledger': 'export ZB_PROCESS_LIFECYCLE_LEDGER="$EV/browser-lifecycle"',
        'classifies lifecycle ledger': '--lifecycle-ledger "$EV/browser-lifecycle"',
    }
    for label, token in gate_requirements.items():
        if token not in gate_source:
            problems.append(f"real gate {label} is missing")
    if "--allow-status" in gate_source:
        problems.append("real gate still uses a row-agnostic status allowlist")

    if problems:
        for problem in problems:
            print(f"RED\tms1c-process-status\t{problem}")
        print(f"FAIL\tms1c-process-status-red\t{len(problems)} problem(s)")
        return 1
    print("PASS\tms1c-process-status-red\trow-specific terminal status and causal TERM lifecycle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
