#!/usr/bin/env python3
"""RED: MS1c terminal status is specific to each row and its real lifecycle.

The real teardown helper must write a gate-owned TERM marker only after its one
identity-checked group SIGTERM succeeds.  The process classifier joins that marker
to the post-terminal process row.  Status 130 is therefore valid only for render's
first (protocol) launch, reply, and arch; it is never a blanket allowlist value.
No real process or signal is used by this oracle.
"""

from __future__ import annotations

import errno
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
E2E = ROOT / "tests" / "e2e"
AUDIT = ROOT / "tests" / "mac" / "ms1c_crash_audit.py"
GATE = ROOT / "tests" / "mac" / "ms1c_app_gate.sh"
SELFTEST = ROOT / "tests" / "mac" / "ms1c_app_gate_selftest.sh"
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


# This suffix extends the existing real-gate fake-Mac fixture. It does not
# model the gate: the unchanged fixture still executes ms1c_app_gate.sh, while
# the launcher and an audit hook expose which lifecycle file actually crossed
# each workload/audit boundary.
GATE_DRIVER_SUFFIX = r'''
mv -f "$X/hostbin/python3" "$X/hostbin/python3.fixture" || exit 1
cat > "$X/hostbin/python3" <<EOF
#!/bin/bash
script=\${1:-}
args=("\$@")
role=\${ZB_ROLE:-}
case "\$role" in intel) base=8100 ;; arm) base=8200 ;; *) exec "$X/hostbin/python3.fixture" "\$@" ;; esac
browser=
if [ "\$script" = - ]; then
  browser=\${2:-}
else
  i=1
  while [ \$i -lt \${#args[@]} ]; do
    if [ "\${args[\$i]}" = --browser ]; then j=\$((i + 1)); browser=\${args[\$j]:-}; break; fi
    i=\$((i + 1))
  done
fi
case "\${script##*/}" in
  m9_render_test.py) row=render ;;
  m9_reply_channel_test.py) row=reply ;;
  m9_load_fail_test.py) row=loadfail ;;
  exec_arch_probe.py) row=arch ;;
  -) row=control ;;
  *) exec "$X/hostbin/python3.fixture" "\$@" ;;
esac
lifecycle=\${ZB_PROCESS_LIFECYCLE_LEDGER:-}
mode=- inode=- size=-
if [ -n "\$lifecycle" ] && [ -e "\$lifecycle" ]; then
  mode=\$(stat -c %a "\$lifecycle" 2>/dev/null || printf '?')
  inode=\$(stat -c %i "\$lifecycle" 2>/dev/null || printf '?')
  size=\$(stat -c %s "\$lifecycle" 2>/dev/null || printf '?')
fi
printf 'W\t%s\t%s\t%s\t%s\t%s\t%s\n' "\$role" "\$row" "\${lifecycle:--}" "\$mode" "\$inode" "\$size" >> "$C/workload.\$role"
ZB_FIXTURE_NO_PROCESS_RECORD=1 "$X/hostbin/python3.fixture" "\$@"
rc=\$?
ledger=\${ZB_PROCESS_LEDGER:-}
if [ -n "\$ledger" ]; then
  case "\$row" in
    render)
      printf 'render\t%s\t130\t%s\nrender\t%s\t0\t%s\n' "\$((base + 1))" "\$browser" "\$((base + 2))" "\$browser" >> "\$ledger"
      [ -n "\$lifecycle" ] && printf 'TERM\trender\t%s\t%s\n' "\$((base + 1))" "\$((base + 1))" >> "\$lifecycle" ;;
    reply)
      printf 'reply\t%s\t130\t%s\n' "\$((base + 3))" "\$browser" >> "\$ledger"
      [ -n "\$lifecycle" ] && printf 'TERM\treply\t%s\t%s\n' "\$((base + 3))" "\$((base + 3))" >> "\$lifecycle" ;;
    loadfail) printf 'loadfail\t%s\t5\t%s\n' "\$((base + 4))" "\$browser" >> "\$ledger" ;;
    arch)
      printf 'arch\t%s\t130\t%s\n' "\$((base + 5))" "\$browser" >> "\$ledger"
      [ -n "\$lifecycle" ] && printf 'TERM\tarch\t%s\t%s\n' "\$((base + 5))" "\$((base + 5))" >> "\$lifecycle" ;;
    control) printf 'control\t%s\t-6\t%s\n' "\$((base + 6))" "\$browser" >> "\$ledger" ;;
  esac
fi
exit "\$rc"
EOF
chmod 0755 "$X/hostbin/python3"

# Add an execution trace to the scratch copy only. The gate archives and runs
# this exact committed copy, so row/report traces are produced by real calls.
/usr/bin/python3 -I -B - "$R/tests/mac/ms1c_crash_audit.py" "$C" <<'PY'
from pathlib import Path
import sys
p, control = Path(sys.argv[1]), sys.argv[2]
s = p.read_text(encoding="utf-8")
needle = 'ROWS = ("render", "render", "reply", "loadfail", "arch", "control")\n'
hook = """_trace_role = os.environ.get("ZB_ROLE", "-")
with open(%r + "/audit." + _trace_role, "a", encoding="utf-8") as _trace:
    _trace.write(json.dumps({"argv": sys.argv[1:], "lifecycle_env": os.environ.get("ZB_PROCESS_LIFECYCLE_LEDGER", "-")}, sort_keys=True) + "\\n")
if len(sys.argv) > 1 and sys.argv[1] == "reports" and os.path.exists(%r + "/mode_lifecycle_corrupt." + _trace_role):
    try:
        _i = sys.argv.index("--lifecycle-ledger")
        with open(sys.argv[_i + 1], "a", encoding="ascii") as _bad:
            _bad.write("BROKEN\\n")
    except (ValueError, OSError, IndexError):
        pass

""" % (control, control)
if needle not in s:
    raise SystemExit("audit trace insertion point missing")
p.write_text(s.replace(needle, hook + needle, 1), encoding="utf-8")
PY
cp -f -- "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$R/tests/mac/ms1c_home_protected_paths.txt" \
  || { bad "could not copy protected-path data"; exit 1; }
"${GIT[@]}" add -- tests/mac/ms1c_crash_audit.py tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m lifecycle-trace \
  || { bad "could not commit lifecycle trace hook"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

OUTBOX=$(realpath "$2")
run_gate lifecycle
printf '%s\n' "$rc" > "$OUTBOX/gate.rc"
cp -f -- "$OUT" "$OUTBOX/gate.out"
for spec in intel:x86_64:8100 arm:arm64:8200; do
  role=${spec%%:*}; rest=${spec#*:}; arch=${rest%%:*}; base=${rest##*:}
  rd=$(rd_of "$role")
  printf '%s\t%s\t%s\t%s\n' "$role" "$arch" "$base" "$rd/evidence/browser-lifecycle" >> "$OUTBOX/meta"
  cp -f -- "$C/workload.$role" "$OUTBOX/workload.$role" 2>/dev/null || :
  cp -f -- "$C/audit.$role" "$OUTBOX/audit.$role" 2>/dev/null || :
  cp -f -- "$EV/$arch/evidence/browser-lifecycle" "$OUTBOX/lifecycle.$role" 2>/dev/null || :
done

# Final reports must re-read the lifecycle file. Corrupt it only after all row
# checks in the Intel leg, immediately as the real reports invocation begins.
run_gate lifecycle-corrupt lifecycle_corrupt.intel
printf '%s\n' "$rc" > "$OUTBOX/corrupt.rc"
cp -f -- "$OUT" "$OUTBOX/corrupt.out"
'''


def lifecycle_arg(argv: list[str]) -> str | None:
    """Return the one lifecycle argument, rejecting missing/duplicate options."""
    positions = [i for i, value in enumerate(argv) if value == "--lifecycle-ledger"]
    if len(positions) != 1 or positions[0] + 1 >= len(argv):
        return None
    return argv[positions[0] + 1]


def integration_trace_errors(
    workload: list[list[str]], audit: list[dict[str, object]], lifecycle_path: str
) -> list[str]:
    """Validate the executed seam, not strings that merely occur in gate source."""
    errors: list[str] = []
    expected_workloads = ["render", "reply", "loadfail", "arch", "control"]
    if [fields[2] for fields in workload if len(fields) >= 3] != expected_workloads:
        errors.append("workload invocation sequence is incomplete or reordered")
    if len(workload) != len(expected_workloads):
        errors.append("workload invocation count is not five")
    inodes: set[str] = set()
    for index, fields in enumerate(workload):
        if len(fields) != 7 or fields[0] != "W":
            errors.append("malformed workload trace")
            continue
        _tag, _role, _row, path, mode, inode, size = fields
        if path != lifecycle_path:
            errors.append("a workload received another lifecycle file")
        if mode != "600" or inode in ("-", "?"):
            errors.append("the workload lifecycle file was not private and regular")
        else:
            inodes.add(inode)
        if index == 0 and size != "0":
            errors.append("the lifecycle file was not freshly empty before render")
    if len(inodes) != 1:
        errors.append("workloads did not share one lifecycle inode")

    expected_audits = ["render", "reply", "loadfail", "arch", "control", "reports"]
    actual_audits: list[str] = []
    for record in audit:
        argv = record.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(value, str) for value in argv):
            errors.append("malformed audit trace")
            continue
        command = argv[0]
        if command == "row":
            try:
                row_at = argv.index("--row")
                command = argv[row_at + 1]
            except (ValueError, IndexError):
                command = "malformed-row"
        actual_audits.append(command)
        if lifecycle_arg(argv) != lifecycle_path:
            errors.append(f"{command} did not receive the shared lifecycle file")
        if record.get("lifecycle_env") != lifecycle_path:
            errors.append(f"{command} did not inherit the shared lifecycle environment")
    if actual_audits != expected_audits:
        errors.append(f"audit invocation sequence is {actual_audits!r}")
    return errors


def prove_integration_mutants() -> list[str]:
    """Field-isolated traces for the five integration survivors in eea40162."""
    path = "/private/run/evidence/browser-lifecycle"
    workloads = [
        ["W", "intel", row, path, "600", "77", "0" if index == 0 else str(index)]
        for index, row in enumerate(("render", "reply", "loadfail", "arch", "control"))
    ]
    audits = [
        {"argv": ["row", "--row", row, "--lifecycle-ledger", path], "lifecycle_env": path}
        for row in ("render", "reply", "loadfail", "arch", "control")
    ]
    audits.append({"argv": ["reports", "--lifecycle-ledger", path], "lifecycle_env": path})
    if integration_trace_errors(workloads, audits, path):
        return ["the independently built good integration trace is rejected"]

    mutants: dict[str, tuple[list[list[str]], list[dict[str, object]]]] = {
        "comment-only": ([], []),
        "unrelated-call": (
            workloads,
            [{"argv": ["noop", "--lifecycle-ledger", path], "lifecycle_env": path}, *audits],
        ),
        "wrong-file": (
            workloads,
            [*audits[:-1], {"argv": ["reports", "--lifecycle-ledger", path + ".other"],
                            "lifecycle_env": path}],
        ),
        "only-one-row": (
            workloads,
            [audits[0], *[
                {"argv": ["row", "--row", row], "lifecycle_env": path}
                for row in ("reply", "loadfail", "arch", "control")
            ], audits[-1]],
        ),
        "reports-omission": (
            workloads,
            [*audits[:-1], {"argv": ["reports"], "lifecycle_env": path}],
        ),
    }
    return [
        f"integration {name} mutant survived"
        for name, (mutant_workloads, mutant_audits) in mutants.items()
        if not integration_trace_errors(mutant_workloads, mutant_audits, path)
    ]


def run_gate_integration(private: Path) -> list[str]:
    errors: list[str] = []
    try:
        fixture = SELFTEST.read_text(encoding="utf-8")
        prefix, marker, _rest = fixture.partition("# ── Base run ──\n")
        if not marker:
            return ["real fake-gate fixture has no Base run boundary"]
        driver = private / "gate-integration.sh"
        outbox = private / "gate-integration"
        outbox.mkdir(mode=0o700)
        driver.write_text(prefix + GATE_DRIVER_SUFFIX, encoding="utf-8")
        driver.chmod(0o700)
        result = subprocess.run(
            ["bash", str(driver), str(ROOT), str(outbox)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [f"real fake-gate integration could not run: {exc}"]
    if result.returncode != 0:
        errors.append(
            f"real fake-gate driver failed rc={result.returncode} "
            f"out={result.stdout[-1000:]!r} err={result.stderr[-1000:]!r}"
        )
        return errors
    try:
        if (outbox / "gate.rc").read_text(encoding="ascii").strip() != "0":
            errors.append("real gate did not accept the exact lifecycle/status execution")
        meta_lines = (outbox / "meta").read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [f"real fake-gate integration evidence is missing: {exc}"]
    if len(meta_lines) != 2:
        errors.append(f"real fake-gate metadata has {len(meta_lines)} legs")
    for meta in meta_lines:
        fields = meta.split("\t")
        if len(fields) != 4:
            errors.append(f"malformed fake-gate metadata {meta!r}")
            continue
        role, _arch, base_text, lifecycle_path = fields
        try:
            workload = [
                line.split("\t")
                for line in (outbox / f"workload.{role}").read_text(encoding="utf-8").splitlines()
            ]
            audit = [
                json.loads(line)
                for line in (outbox / f"audit.{role}").read_text(encoding="utf-8").splitlines()
            ]
            lifecycle_file = outbox / f"lifecycle.{role}"
            lifecycle_rows = lifecycle_file.read_text(encoding="ascii").splitlines()
            lifecycle_mode = stat.S_IMODE(lifecycle_file.stat().st_mode)
            base = int(base_text)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"{role} executable lifecycle evidence is unreadable: {exc}")
            continue
        errors.extend(f"{role}: {error}" for error in integration_trace_errors(workload, audit, lifecycle_path))
        expected = [
            marker_line("render", base + 1),
            marker_line("reply", base + 3),
            marker_line("arch", base + 5),
        ]
        if lifecycle_rows != expected:
            errors.append(f"{role}: copied final lifecycle is {lifecycle_rows!r}, want {expected!r}")
        if lifecycle_mode != 0o600:
            errors.append(f"{role}: copied lifecycle mode is {lifecycle_mode:o}, want 600")
    try:
        corrupt_rc = (outbox / "corrupt.rc").read_text(encoding="ascii").strip()
        corrupt_out = (outbox / "corrupt.out").read_text(encoding="utf-8")
    except OSError as exc:
        errors.append(f"corrupt-final-reports integration evidence is missing: {exc}")
    else:
        if corrupt_rc != "2" or "INCONCLUSIVE" not in corrupt_out or "PASS\tms1c-app-gate" in corrupt_out:
            errors.append("final reports accepted a lifecycle file corrupted after successful row checks")
    errors.extend(prove_integration_mutants())
    return errors


def main() -> int:
    problems: list[str] = []
    private = Path(tempfile.mkdtemp(prefix="ms1c-process-status-red-", dir=os.environ.get("TMPDIR")))
    ledger = private / "browser-processes"
    lifecycle = private / "browser-lifecycle"
    ledger.write_text("", encoding="ascii")
    lifecycle.write_text("", encoding="ascii")
    ledger.chmod(0o600)
    lifecycle.chmod(0o600)
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

    # Failed identity checks and failed sends never authorize status 130.  In
    # particular, ProcessLookupError is not evidence that SIGTERM succeeded.
    saved_leak = teardown._leak
    for offset, failure in enumerate(("lookup", "eperm", "identity"), 1):
        pid = 7300 + offset
        case_ledger = private / f"send-{failure}.process"
        case_lifecycle = private / f"send-{failure}.lifecycle"
        case_ledger.write_text("", encoding="ascii")
        case_lifecycle.write_text("", encoding="ascii")
        case_ledger.chmod(0o600)
        case_lifecycle.chmod(0o600)
        os.environ["ZB_PROCESS_LEDGER"] = str(case_ledger)
        os.environ["ZB_PROCESS_LIFECYCLE_LEDGER"] = str(case_lifecycle)
        os.environ["ZB_PROCESS_ROW"] = "reply"
        proc = FakeProc(pid, 130, app, live=True)
        attempts: list[tuple[int, int]] = []
        leaks: list[str] = []
        teardown._leak = lambda message, pgid=None: leaks.append(f"{message}|{pgid}")
        teardown._group_has_members = lambda _pgid: False
        if failure == "identity":
            teardown.os.getpgid = lambda value: value + 1

            def refused_signal(_pgid: int, _sig: int) -> None:
                raise AssertionError("identity refusal reached a signal API")

            teardown.os.killpg = refused_signal
        else:
            teardown.os.getpgid = lambda value: value

            def failed_signal(pgid: int, sig: int, kind: str = failure) -> None:
                attempts.append((pgid, sig))
                if kind == "lookup":
                    proc.returncode = 130
                    raise ProcessLookupError()
                raise PermissionError(errno.EPERM, "refused")

            teardown.os.killpg = failed_signal
        try:
            teardown.stop_browser_term_only(proc, grace_s=0.1, executable=app)
        except BaseException as exc:  # the oracle must report, not escape, a fake failure case
            problems.append(f"{failure} no-send case raised {type(exc).__name__}: {exc}")
        markers = case_lifecycle.read_text(encoding="ascii").splitlines()
        if markers:
            problems.append(f"{failure} no-send case wrote lifecycle evidence {markers!r}")
        expected_attempts = [] if failure == "identity" else [(pid, signal.SIGTERM)]
        if attempts != expected_attempts:
            problems.append(f"{failure} signal attempts are {attempts!r}, want {expected_attempts!r}")
        if failure in ("eperm", "identity") and not leaks:
            problems.append(f"{failure} refusal did not take the fail-closed leak path")

    # The gate owns a pre-existing mode-0600 regular lifecycle file.  A missing,
    # symlinked, non-regular, non-private or short-write destination must fail
    # closed after the fake send and before a process row can be authorized.
    original_write = teardown.os.write
    for offset, storage_kind in enumerate(("missing", "symlink", "directory", "public", "short-write"), 1):
        pid = 7400 + offset
        case_ledger = private / f"storage-{storage_kind}.process"
        case_lifecycle = private / f"storage-{storage_kind}.lifecycle"
        case_ledger.write_text("", encoding="ascii")
        case_ledger.chmod(0o600)
        if storage_kind == "symlink":
            target = private / "storage-symlink-target"
            target.write_text("", encoding="ascii")
            target.chmod(0o600)
            case_lifecycle.symlink_to(target)
        elif storage_kind == "directory":
            case_lifecycle.mkdir()
        elif storage_kind != "missing":
            case_lifecycle.write_text("", encoding="ascii")
            case_lifecycle.chmod(0o644 if storage_kind == "public" else 0o600)
        os.environ["ZB_PROCESS_LEDGER"] = str(case_ledger)
        os.environ["ZB_PROCESS_LIFECYCLE_LEDGER"] = str(case_lifecycle)
        os.environ["ZB_PROCESS_ROW"] = "arch"
        proc = FakeProc(pid, 130, app, live=True)
        leaks: list[str] = []
        teardown._leak = lambda message, pgid=None: leaks.append(f"{message}|{pgid}")
        teardown.os.getpgid = lambda value: value

        def storage_send(pgid: int, sig: int) -> None:
            if pgid != pid or sig != signal.SIGTERM:
                raise AssertionError("storage case reached an unexpected signal")
            proc.returncode = 130

        teardown.os.killpg = storage_send
        teardown._group_has_members = lambda _pgid: False
        if storage_kind == "short-write":
            lifecycle_inode = case_lifecycle.stat().st_ino

            def short_lifecycle_write(fd: int, data: bytes) -> int:
                if os.fstat(fd).st_ino == lifecycle_inode:
                    return original_write(fd, data[:-1])
                return original_write(fd, data)

            teardown.os.write = short_lifecycle_write
        else:
            teardown.os.write = original_write
        failed_closed = False
        try:
            teardown.stop_browser_term_only(proc, grace_s=0.1, executable=app)
        except (OSError, RuntimeError):
            failed_closed = True
        finally:
            teardown.os.write = original_write
        if leaks:
            failed_closed = True
        if not failed_closed or case_ledger.read_text(encoding="ascii"):
            problems.append(
                f"{storage_kind} lifecycle storage did not fail closed before process authorization"
            )
    teardown._leak = saved_leak
    os.environ["ZB_PROCESS_LEDGER"] = str(ledger)
    os.environ["ZB_PROCESS_LIFECYCLE_LEDGER"] = str(lifecycle)

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
        case_ledger.chmod(0o600)
        case_lifecycle.chmod(0o600)
        result = run_row(case_ledger, case_lifecycle, row, count, executable)
        bounded_inconclusive = (
            want_rc != 3
            or result.stdout.splitlines() == [required]
        )
        if result.returncode != want_rc or required not in result.stdout or result.stderr or not bounded_inconclusive:
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

    # Render launch order is semantic: the protocol launch is first and must be
    # 130 with its marker; the screenshot launch is second and must be 0 without
    # one.  The same multiset assigned to the opposite pids is not equivalent.
    render_swapped = [*want_process]
    render_swapped[0] = process_line("render", 7201, 0, app)
    render_swapped[1] = process_line("render", 7202, 130, app)
    swapped_markers = [marker_line("render", 7202), *want_lifecycle[1:]]
    swapped_ledger = private / "render-swapped.process"
    swapped_lifecycle = private / "render-swapped.lifecycle"
    swapped_ledger.write_text("\n".join(render_swapped) + "\n", encoding="utf-8")
    swapped_lifecycle.write_text("\n".join(swapped_markers) + "\n", encoding="ascii")
    swapped_ledger.chmod(0o600)
    swapped_lifecycle.chmod(0o600)
    swapped = run_row(swapped_ledger, swapped_lifecycle, "render", 2, app)
    swapped_failures = {
        "PRODUCT-FAIL\tabnormal-exit\trender\t7201\t0",
        "PRODUCT-FAIL\tabnormal-exit\trender\t7202\t130",
    }
    if (swapped.returncode != 1 or not swapped_failures.issubset(set(swapped.stdout.splitlines()))
            or swapped.stderr):
        problems.append(
            f"swapped render order classified rc={swapped.returncode} "
            f"out={swapped.stdout!r} err={swapped.stderr!r}"
        )

    # Exact equality, not sign, truthiness or a broadened status set.
    status_variants = (
        ("render-protocol-129", 0, 129, "render", 2, app),
        ("render-protocol-131", 0, 131, "render", 2, app),
        ("render-screenshot-1", 1, 1, "render", 2, app),
        ("reply-129", 2, 129, "reply", 1, app),
        ("reply-131", 2, 131, "reply", 1, app),
        ("loadfail-4", 3, 4, "loadfail", 1, app),
        ("loadfail-6", 3, 6, "loadfail", 1, app),
        ("arch-129", 4, 129, "arch", 1, app),
        ("arch-131", 4, 131, "arch", 1, app),
        ("control-minus-5", 5, -5, "control", 1, control),
        ("control-minus-7", 5, -7, "control", 1, control),
    )
    for label, index, status_value, row, count, executable in status_variants:
        rows = [*want_process]
        pid = 7201 + index
        rows[index] = process_line(row, pid, status_value, executable)
        fixture_case(
            label, rows, want_lifecycle, row, count, executable, 1,
            f"PRODUCT-FAIL\tabnormal-exit\t{row}\t{pid}\t{status_value}",
        )

    # Parsing consumes the entire canonical file.  A selected row cannot hide
    # malformed, unknown, extra, noncanonical or reordered evidence elsewhere.
    lifecycle_corruptions = {
        "lifecycle-extra-field": [want_lifecycle[0] + "\textra", *want_lifecycle[1:]],
        "lifecycle-unknown-action": ["KILL\trender\t7201\t7201", *want_lifecycle[1:]],
        "lifecycle-unknown-row": ["TERM\tother\t7201\t7201", *want_lifecycle[1:]],
        "lifecycle-extra-marker": [*want_lifecycle, marker_line("control", 7206)],
        "lifecycle-reordered": [want_lifecycle[1], want_lifecycle[0], want_lifecycle[2]],
        "lifecycle-blank": [want_lifecycle[0], "", *want_lifecycle[1:]],
        "lifecycle-noncanonical-pid": ["TERM\trender\t07201\t7201", *want_lifecycle[1:]],
    }
    for label, markers in lifecycle_corruptions.items():
        fixture_case(
            label, want_process, markers, "render", 2, app, 3,
            "PROCESSAUDIT\tINCONCLUSIVE\tconflict TERM lifecycle",
        )

    def lifecycle_path_case(label: str, kind: str, reason: str) -> None:
        case_ledger = private / f"{label}.process"
        case_lifecycle = private / f"{label}.lifecycle"
        case_ledger.write_text("\n".join(want_process) + "\n", encoding="utf-8")
        case_ledger.chmod(0o600)
        if kind == "symlink":
            target = private / f"{label}.target"
            target.write_text("\n".join(want_lifecycle) + "\n", encoding="ascii")
            target.chmod(0o600)
            case_lifecycle.symlink_to(target)
        elif kind == "directory":
            case_lifecycle.mkdir()
        elif kind != "missing":
            case_lifecycle.write_text("\n".join(want_lifecycle) + "\n", encoding="ascii")
            case_lifecycle.chmod(0o644)
        result = run_row(case_ledger, case_lifecycle, "render", 2, app)
        expected = f"PROCESSAUDIT\tINCONCLUSIVE\t{reason}"
        if result.returncode != 3 or result.stdout.splitlines() != [expected] or result.stderr:
            problems.append(
                f"{label} lifecycle storage classified rc={result.returncode} "
                f"out={result.stdout!r} err={result.stderr!r}"
            )

    lifecycle_path_case("lifecycle-missing-file", "missing", "missing TERM lifecycle")
    lifecycle_path_case("lifecycle-symlink-file", "symlink", "conflict TERM lifecycle")
    lifecycle_path_case("lifecycle-directory", "directory", "conflict TERM lifecycle")
    lifecycle_path_case("lifecycle-public-file", "public", "conflict TERM lifecycle")

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

    for error in run_gate_integration(private):
        problems.append(f"real gate integration: {error}")

    if problems:
        for problem in problems:
            print(f"RED\tms1c-process-status\t{problem}")
        print(f"FAIL\tms1c-process-status-red\t{len(problems)} problem(s)")
        return 1
    print("PASS\tms1c-process-status-red\trow-specific terminal status and causal TERM lifecycle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
