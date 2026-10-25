#!/usr/bin/env python3
"""RED, UNREGISTERED: retain bounded typed crash fields and attribution reasons.

The consumed arm64 run named and hashed a report but retained no report body.
Its pid, status, diagnostic and Apple-redacted path match the missing-dylib
control, while its classifier verdict says PRODUCT.  A future result must be
self-explaining without retaining the whole ``.ips`` file.

For every valid incident this oracle requires one canonical bounded record::

    CRASHINCIDENT <b64:name> <b64:exception.type> <b64:exception.signal>
      <b64:termination.namespace> <b64:termination.indicator>
      <b64:canonical-JSON termination.details>

and one fixed-reason classifier record::

    CRASHATTRIBUTION <b64:name> <CONTROL|PRODUCT> <reason>

The exact control, a field-isolated non-DYLD control candidate, a wrong-path
control candidate and a launched product fix the CONTROL-versus-PRODUCT
reasons.  Metadata and diagnostic notes carry control-looking decoys, so raw
substrings cannot supply the retained typed fields or reason.  The real gate
fixture additionally requires the records exactly once in ``crash.delta``,
``leg.log`` and the copied ``crashreports`` evidence file.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
AUDIT = HERE / "ms1c_crash_audit.py"
GATE_ORACLE = HERE / "ms1c_crash_attribution_red.py"
SHIM = "@executable_path/../Frameworks/libwkwebview_shim.dylib"
REDACTED = "/Users/USER/*/zigBrowser.app/Contents/MacOS/zigBrowser"
PRODUCT_EXE = "/Users/laroncha/zb-ms1c/app/zigBrowser.app/Contents/MacOS/zigBrowser"
CONTROL_EXE = "/Users/laroncha/zb-ms1c/control/zigBrowser.app/Contents/MacOS/zigBrowser"
CONTROL_PID = 76127
ROWS = (
    ("render", 76001, 130, PRODUCT_EXE),
    ("render", 76002, 0, PRODUCT_EXE),
    ("reply", 76003, 130, PRODUCT_EXE),
    ("loadfail", 76004, 5, PRODUCT_EXE),
    ("arch", 76005, 130, PRODUCT_EXE),
    ("control", CONTROL_PID, -6, CONTROL_EXE),
)
MARKERS = (("render", 76001), ("reply", 76003), ("arch", 76005))
problems: list[str] = []


def field(value: str) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


def report_bytes(
    *,
    pid: int = CONTROL_PID,
    proc_path: str = REDACTED,
    exception_type: str = "EXC_CRASH",
    exception_signal: str = "SIGABRT",
    namespace: str = "DYLD",
    indicator: str = "Library missing",
    details: list[str] | None = None,
) -> bytes:
    if details is None:
        details = [f"Library not loaded: {SHIM}"]
    metadata = {
        "app_name": "zigBrowser",
        "timestamp": "2026-10-25 11:22:31.00 -0400",
        "slice_uuid": "2E11B6BE-9863-3EB2-9245-0937BB22A52A",
        "bundleID": "com.cosmichq.zigBrowser",
        "bug_type": "309",
        "os_version": "macOS 15.7.1 (24G231)",
        "name": "zigBrowser",
        "incident_id": "ARM64-44F1E5E4",
        "reportNotes": (
            f"raw decoy: pid={CONTROL_PID} procPath={REDACTED} "
            f"EXC_CRASH SIGABRT DYLD Library missing {SHIM}"
        ),
    }
    incident = {
        "pid": pid,
        "procName": "zigBrowser",
        "procPath": proc_path,
        "bundleInfo": {"CFBundleIdentifier": "com.cosmichq.zigBrowser"},
        "exception": {"type": exception_type, "signal": exception_signal},
        "termination": {
            "namespace": namespace,
            "indicator": indicator,
            "details": details,
        },
        "diagnosticNotes": [
            f"raw decoy: pid={CONTROL_PID} procPath={REDACTED} DYLD Library missing"
        ],
    }
    return (
        json.dumps(metadata, sort_keys=True, separators=(",", ":"))
        + "\n"
        + json.dumps(incident, sort_keys=True, indent=2)
        + "\n"
    ).encode("utf-8")


def incident_record(name: str, *, exception_type: str, exception_signal: str,
                    namespace: str, indicator: str, details: list[str]) -> str:
    details_json = json.dumps(details, ensure_ascii=False, separators=(",", ":"))
    return "\t".join((
        "CRASHINCIDENT",
        field(name),
        field(exception_type),
        field(exception_signal),
        field(namespace),
        field(indicator),
        field(details_json),
    ))


def run_case(
    label: str,
    raw: bytes,
    expected_rc: int,
    expected_kind: str,
    expected_reason: str,
    *,
    exception_type: str,
    exception_signal: str,
    namespace: str,
    indicator: str,
    details: list[str],
    diagnostic_ok: bool = True,
) -> None:
    name = f"zigBrowser-{label}.ips"
    with tempfile.TemporaryDirectory(prefix="ms1c-incident-red-") as tmp_text:
        tmp = Path(tmp_text)
        diag = tmp / "home" / "Library" / "Logs" / "DiagnosticReports"
        diag.mkdir(parents=True)
        (diag / name).write_bytes(raw)
        ledger = tmp / "browser-processes"
        ledger.write_text(
            "".join(f"{row}\t{pid}\t{status}\t{exe}\n" for row, pid, status, exe in ROWS),
            encoding="utf-8",
        )
        lifecycle = tmp / "browser-lifecycle"
        lifecycle.write_text(
            "".join(f"TERM\t{row}\t{pid}\t{pid}\n" for row, pid in MARKERS),
            encoding="ascii",
        )
        lifecycle.chmod(0o600)
        before = tmp / "home.before"
        before.write_text(f"ROOT\t{field(str(tmp / 'home'))}\nEND\t1\n", encoding="ascii")
        control_err = tmp / "control.err"
        library = SHIM if diagnostic_ok else "@rpath/libother.dylib"
        control_err.write_text(
            f"dyld[{CONTROL_PID}]: Library not loaded: {library}\n"
            f"  Referenced from: <UUID> {CONTROL_EXE}\n",
            encoding="utf-8",
        )
        command = [
            sys.executable, "-B", str(AUDIT), "reports",
            "--ledger", str(ledger),
            "--lifecycle-ledger", str(lifecycle),
            "--audit-marker", str(tmp / "process-audit"),
            "--before", str(before),
            "--diag", str(diag),
            "--diag-rel", "Library/Logs/DiagnosticReports",
            "--control-exe", CONTROL_EXE,
            "--control-err", str(control_err),
            "--ignore-out", str(tmp / "crash.ignore"),
        ]
        result = subprocess.run(command, text=True, capture_output=True, check=False)
    lines = result.stdout.splitlines()
    wanted_incident = incident_record(
        name,
        exception_type=exception_type,
        exception_signal=exception_signal,
        namespace=namespace,
        indicator=indicator,
        details=details,
    )
    wanted_reason = f"CRASHATTRIBUTION\t{field(name)}\t{expected_kind}\t{expected_reason}"
    incident_lines = [line for line in lines if line.startswith("CRASHINCIDENT\t")]
    reason_lines = [line for line in lines if line.startswith("CRASHATTRIBUTION\t")]
    if result.returncode != expected_rc:
        problems.append(f"{label}: exit {result.returncode}, want {expected_rc}")
    if incident_lines != [wanted_incident]:
        problems.append(f"{label}: typed incident record is missing or not exact")
    if reason_lines != [wanted_reason]:
        problems.append(f"{label}: attribution reason is missing or not exact")
    if any(len(line.encode("utf-8")) > 2048 for line in incident_lines + reason_lines):
        problems.append(f"{label}: retained incident evidence is not bounded")
    if result.stderr or "Traceback" in result.stdout:
        problems.append(f"{label}: audit printed stderr or a traceback")


def oversized_field_case() -> None:
    """An attacker-controlled typed field cannot create unbounded evidence."""
    raw = report_bytes(indicator="X" * 4096)
    name = "zigBrowser-oversized-field.ips"
    with tempfile.TemporaryDirectory(prefix="ms1c-incident-bound-red-") as tmp_text:
        tmp = Path(tmp_text)
        diag = tmp / "home" / "Library" / "Logs" / "DiagnosticReports"
        diag.mkdir(parents=True)
        (diag / name).write_bytes(raw)
        (tmp / "browser-processes").write_text(
            "".join(f"{row}\t{pid}\t{status}\t{exe}\n" for row, pid, status, exe in ROWS),
            encoding="utf-8",
        )
        lifecycle = tmp / "browser-lifecycle"
        lifecycle.write_text(
            "".join(f"TERM\t{row}\t{pid}\t{pid}\n" for row, pid in MARKERS),
            encoding="ascii",
        )
        lifecycle.chmod(0o600)
        (tmp / "home.before").write_text(
            f"ROOT\t{field(str(tmp / 'home'))}\nEND\t1\n", encoding="ascii"
        )
        (tmp / "control.err").write_text(
            f"dyld[{CONTROL_PID}]: Library not loaded: {SHIM}\n"
            f"  Referenced from: <UUID> {CONTROL_EXE}\n",
            encoding="utf-8",
        )
        result = subprocess.run(
            [
                sys.executable, "-B", str(AUDIT), "reports",
                "--ledger", str(tmp / "browser-processes"),
                "--lifecycle-ledger", str(lifecycle),
                "--audit-marker", str(tmp / "process-audit"),
                "--before", str(tmp / "home.before"),
                "--diag", str(diag),
                "--diag-rel", "Library/Logs/DiagnosticReports",
                "--control-exe", CONTROL_EXE,
                "--control-err", str(tmp / "control.err"),
                "--ignore-out", str(tmp / "crash.ignore"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
    lines = result.stdout.splitlines()
    prefix = f"CRASHREPORT\t{field(name)}\t"
    reports = [line for line in lines if line.startswith(prefix)]
    if result.returncode != 3 or len(reports) != 1 or "\tMALFORMED\t-\t-" not in reports[0]:
        problems.append("oversized-field: did not fail closed as one bounded MALFORMED report")
    if any(line.startswith(("CRASHINCIDENT\t", "CRASHATTRIBUTION\t")) for line in lines):
        problems.append("oversized-field: invalid typed evidence received an attribution record")
    if any(len(line.encode("utf-8")) > 2048 for line in lines):
        problems.append("oversized-field: an evidence line exceeded 2048 bytes")
    if result.stderr or "Traceback" in result.stdout:
        problems.append("oversized-field: audit printed stderr or a traceback")


def gate_retention() -> None:
    """Run D0/D1 through the real gate fixture and require all copied sinks."""
    source = GATE_ORACLE.read_text(encoding="utf-8")
    needle = (
        'else bad "D1: exact control attribution missing: exit $rc $(tailout)"; fi\n\n'
        '# D1a: an exact incident identity with the wrong recorded terminal status is PRODUCT, never CONTROL.\n'
    )
    injection = r'''else bad "D1: exact control attribution missing: exit $rc $(tailout)"; fi

name=$(field zigBrowser-control.ips)
typed="CRASHINCIDENT${TB}${name}${TB}$(field EXC_CRASH)${TB}$(field SIGABRT)${TB}$(field DYLD)${TB}$(field 'Library missing')${TB}$(field '["Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib"]')"
reason="CRASHATTRIBUTION${TB}${name}${TB}CONTROL${TB}exact-control"
for retained in "$log" "$EV/x86_64/evidence/crash.delta" "$EV/x86_64/evidence/crashreports"; do
  [ "$(grep -Fxc "$typed" "$retained" 2>/dev/null || :)" = 1 ] \
    || bad "E-gate: typed incident missing or duplicated in $retained"
  [ "$(grep -Fxc "$reason" "$retained" 2>/dev/null || :)" = 1 ] \
    || bad "E-gate: attribution reason missing or duplicated in $retained"
done
if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-crash-attribution-red\tmacOS-15 reports, boundary ledger and attribution mutants\n'
  exit 0
else
  exit 1
fi

# D1a: an exact incident identity with the wrong recorded terminal status is PRODUCT, never CONTROL.
'''
    if source.count(needle) != 1:
        problems.append("gate-retention: could not bind the reviewed D1 execution seam")
        return
    modified = source.replace(needle, injection)
    wrapper = (
        "import sys\n"
        "source = sys.stdin.read()\n"
        f"path = {str(GATE_ORACLE)!r}\n"
        "scope = {'__file__': path, '__name__': '__main__'}\n"
        "exec(compile(source, path, 'exec'), scope)\n"
    )
    result = subprocess.run(
        [sys.executable, "-B", "-c", wrapper],
        input=modified,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        tail = " | ".join((result.stdout + result.stderr).splitlines()[-8:])
        problems.append(f"gate-retention: real gate evidence sinks rejected records ({tail})")


def main() -> int:
    control_details = [f"Library not loaded: {SHIM}"]
    run_case(
        "exact-control",
        report_bytes(),
        0,
        "CONTROL",
        "exact-control",
        exception_type="EXC_CRASH",
        exception_signal="SIGABRT",
        namespace="DYLD",
        indicator="Library missing",
        details=control_details,
    )
    run_case(
        "incident-mismatch",
        report_bytes(namespace="SIGNAL", indicator="Abort trap: 6", details=[]),
        2,
        "PRODUCT",
        "control-incident-mismatch",
        exception_type="EXC_CRASH",
        exception_signal="SIGABRT",
        namespace="SIGNAL",
        indicator="Abort trap: 6",
        details=[],
    )
    run_case(
        "path-mismatch",
        report_bytes(proc_path=PRODUCT_EXE),
        2,
        "PRODUCT",
        "control-path-mismatch",
        exception_type="EXC_CRASH",
        exception_signal="SIGABRT",
        namespace="DYLD",
        indicator="Library missing",
        details=control_details,
    )
    run_case(
        "diagnostic-mismatch",
        report_bytes(),
        2,
        "PRODUCT",
        "control-diagnostic-mismatch",
        exception_type="EXC_CRASH",
        exception_signal="SIGABRT",
        namespace="DYLD",
        indicator="Library missing",
        details=control_details,
        diagnostic_ok=False,
    )
    run_case(
        "launched-product",
        report_bytes(
            pid=76005,
            proc_path=PRODUCT_EXE,
            exception_type="EXC_BREAKPOINT",
            exception_signal="SIGTRAP",
            namespace="SIGNAL",
            indicator="Trace/BPT trap: 5",
            details=[],
        ),
        2,
        "PRODUCT",
        "launched-product",
        exception_type="EXC_BREAKPOINT",
        exception_signal="SIGTRAP",
        namespace="SIGNAL",
        indicator="Trace/BPT trap: 5",
        details=[],
    )
    oversized_field_case()
    gate_retention()
    if problems:
        for item in problems:
            print(f"RED: {item}", file=sys.stderr)
        print(f"FAIL: {len(problems)} incident-evidence contracts unmet", file=sys.stderr)
        return 1
    print("PASS: typed incident evidence and CONTROL-versus-PRODUCT reasons are retained")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
