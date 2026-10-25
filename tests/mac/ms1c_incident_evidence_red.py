#!/usr/bin/env python3
"""GREEN, REGISTERED: retain bounded typed crash fields and attribution reasons.

The consumed arm64 run named and hashed a report but retained no report body.
Its pid, status, diagnostic and Apple-redacted path match the missing-dylib
control, while its classifier verdict says PRODUCT.  A future result must be
self-explaining without retaining the whole ``.ips`` file.

For every valid incident this oracle requires one canonical bounded record::

    CRASHINCIDENT <b64:name> <b64:exception.type> <b64:exception.signal>
      <b64:termination.namespace> <termination.code-or-->
      <b64:termination.indicator>
      <b64:canonical-JSON termination.details>
      <b64:canonical-JSON termination.reasons>

and one fixed-reason classifier record::

    CRASHATTRIBUTION <b64:name> <CONTROL|PRODUCT> <reason>

All ten classifier reasons are fixed independently.  The acquired macOS-15
shape is represented directly: its generic ``details`` says that launch ended,
while the missing-library diagnostic is in typed ``termination.reasons``.
Metadata and diagnostic notes carry control-looking decoys, so raw substrings
cannot supply retained fields or a reason.  Every scalar, list count, element
and canonical list encoding is bounded independently.  The real two-leg gate
fixture requires one CONTROL and one PRODUCT sequence, in order and exactly
once, in ``crash.delta``, ``leg.log`` and copied ``crashreports`` on both legs.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any


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
DEFAULT = object()
MISSING = object()


def field(value: str) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


def report_bytes(
    *,
    pid: int = CONTROL_PID,
    proc_path: str = REDACTED,
    exception_type: Any = "EXC_CRASH",
    exception_signal: Any = "SIGABRT",
    namespace: Any = "DYLD",
    code: Any = 1,
    indicator: Any = "Library missing",
    details: Any = DEFAULT,
    reasons: Any = DEFAULT,
    app_name: str = "zigBrowser",
    metadata_bundle: str = "com.cosmichq.zigBrowser",
    proc_name: str = "zigBrowser",
    incident_bundle: str = "com.cosmichq.zigBrowser",
) -> bytes:
    if details is DEFAULT:
        details = [f"Library not loaded: {SHIM}"]
    if reasons is DEFAULT:
        reasons = []
    metadata = {
        "app_name": app_name,
        "timestamp": "2026-10-25 11:22:31.00 -0400",
        "slice_uuid": "2E11B6BE-9863-3EB2-9245-0937BB22A52A",
        "bundleID": metadata_bundle,
        "bug_type": "309",
        "os_version": "macOS 15.7.1 (24G231)",
        "name": app_name,
        "incident_id": "ARM64-44F1E5E4",
        "reportNotes": (
            f"raw decoy: pid={CONTROL_PID} procPath={REDACTED} "
            f"EXC_CRASH SIGABRT DYLD Library missing {SHIM}"
        ),
    }
    termination = {
        "namespace": namespace,
        "indicator": indicator,
        "details": details,
        "reasons": reasons,
    }
    if code is not MISSING:
        termination["code"] = code
    incident = {
        "pid": pid,
        "procName": proc_name,
        "procPath": proc_path,
        "bundleInfo": {"CFBundleIdentifier": incident_bundle},
        "exception": {"type": exception_type, "signal": exception_signal},
        "termination": termination,
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
                    namespace: str, code: int | None, indicator: str, details: list[str],
                    reasons: list[str]) -> str:
    details_json = json.dumps(details, ensure_ascii=False, separators=(",", ":"))
    reasons_json = json.dumps(reasons, ensure_ascii=False, separators=(",", ":"))
    return "\t".join((
        "CRASHINCIDENT",
        field(name),
        field(exception_type),
        field(exception_signal),
        field(namespace),
        "-" if code is None else str(code),
        field(indicator),
        field(details_json),
        field(reasons_json),
    ))


def invoke(
    reports: list[tuple[str, bytes]],
    *,
    rows: tuple[tuple[str, int, int, str], ...] = ROWS,
    diagnostic_ok: bool = True,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="ms1c-incident-red-") as tmp_text:
        tmp = Path(tmp_text)
        diag = tmp / "home" / "Library" / "Logs" / "DiagnosticReports"
        diag.mkdir(parents=True)
        for name, raw in reports:
            (diag / name).write_bytes(raw)
        ledger = tmp / "browser-processes"
        ledger.write_text(
            "".join(f"{row}\t{pid}\t{status}\t{exe}\n" for row, pid, status, exe in rows),
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
        return subprocess.run(command, text=True, capture_output=True, check=False)


def parsed_incident(raw: bytes) -> dict[str, Any]:
    text = raw.decode("utf-8", "strict")
    decoder = json.JSONDecoder()
    _metadata, end = decoder.raw_decode(text)
    while end < len(text) and text[end].isspace():
        end += 1
    incident, end = decoder.raw_decode(text, end)
    if text[end:].strip() or not isinstance(incident, dict):
        raise AssertionError("fixture is not exactly two complete JSON records")
    return incident


def expected_sequence(name: str, raw: bytes, kind: str, reason: str) -> list[str]:
    incident = parsed_incident(raw)
    exception, termination = incident["exception"], incident["termination"]
    sequence = [
        "\t".join((
            "CRASHREPORT", field(name), hashlib.sha256(raw).hexdigest(), kind,
            str(incident["pid"]), field(incident["procPath"]),
        )),
        incident_record(
            name,
            exception_type=exception["type"],
            exception_signal=exception["signal"],
            namespace=termination["namespace"],
            code=termination.get("code"),
            indicator=termination["indicator"],
            details=termination.get("details", []),
            reasons=termination.get("reasons", []),
        ),
        f"CRASHATTRIBUTION\t{field(name)}\t{kind}\t{reason}",
    ]
    if kind == "PRODUCT":
        sequence.append(f"PRODUCT-FAIL\tcrash-report\t{field(name)}")
    return sequence


def run_valid_case(
    label: str,
    reports: list[tuple[str, bytes, str, str]],
    expected_rc: int,
    *,
    rows: tuple[tuple[str, int, int, str], ...] = ROWS,
    diagnostic_ok: bool = True,
) -> None:
    result = invoke([(name, raw) for name, raw, _kind, _reason in reports],
                    rows=rows, diagnostic_ok=diagnostic_ok)
    expected: list[str] = []
    for name, raw, kind, reason in sorted(reports):
        expected.extend(expected_sequence(name, raw, kind, reason))
    lines = result.stdout.splitlines()
    if result.returncode != expected_rc:
        problems.append(f"{label}: exit {result.returncode}, want {expected_rc}")
    if lines != expected:
        problems.append(f"{label}: canonical report/incident/reason/product sequence is missing or reordered")
    if any(len(line.encode("utf-8")) > 2048 for line in lines):
        problems.append(f"{label}: retained evidence is not bounded")
    if result.stderr or "Traceback" in result.stdout:
        problems.append(f"{label}: audit printed stderr or a traceback")


def malformed_case(label: str, raw: bytes) -> None:
    """Every invalid or unbounded typed field is one bounded fail-closed row."""
    name = f"zigBrowser-{label}.ips"
    result = invoke([(name, raw)])
    lines = result.stdout.splitlines()
    expected = [
        f"CRASHREPORT\t{field(name)}\t{hashlib.sha256(raw).hexdigest()}\tMALFORMED\t-\t-"
    ]
    if result.returncode != 3 or lines != expected:
        problems.append(f"{label}: invalid field did not yield one exact MALFORMED/INCONCLUSIVE record")
    if any(len(line.encode("utf-8")) > 2048 for line in lines):
        problems.append(f"{label}: malformed evidence exceeded 2048 bytes")
    if any(line.startswith(("CRASHINCIDENT\t", "CRASHATTRIBUTION\t")) for line in lines):
        problems.append(f"{label}: malformed evidence received typed attribution")
    if result.stderr or "Traceback" in result.stdout:
        problems.append(f"{label}: audit printed stderr or a traceback")


def gate_retention() -> None:
    """Drive both legs through the real gate and bind every ordered sink."""
    source = GATE_ORACLE.read_text(encoding="utf-8")
    needle = "# D0: zero reports is permitted, but all six launched processes are recorded.\n"
    injection = r'''# E-gate: one CONTROL and one causal PRODUCT on each real gate leg.
run_detection e-both-legs detect_delayed.intel detect_delayed.arm
if [ "$rc" -ne 1 ] || ! leg_is x86_64 FAIL || ! leg_is arm64 FAIL || ! no_pass || ! all_processes normal; then
  bad "E-gate: two-leg control/product setup was not the expected causal FAIL"
fi

typed_row() { # name type signal namespace code indicator details-json reasons-json
  printf 'CRASHINCIDENT%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$TB" "$(field "$1")" "$TB" "$(field "$2")" "$TB" "$(field "$3")" \
    "$TB" "$(field "$4")" "$TB" "$5" "$TB" "$(field "$6")" \
    "$TB" "$(field "$7")" "$TB" "$(field "$8")"
}
evidence_only() {
  grep -E "^(CRASHREPORT|CRASHINCIDENT|CRASHATTRIBUTION)${TB}|^PRODUCT-FAIL${TB}crash-report${TB}" "$1" 2>/dev/null || :
}

for role in intel arm; do
  if [ "$role" = intel ]; then base=5100; arch=x86_64; else base=6100; arch=arm64; fi
  rd=$(rd_of "$role")
  reports="$X/hosts/$role/Library/Logs/DiagnosticReports"
  control_name=zigBrowser-control.ips
  product_name=zigBrowser-delayed-product.ips
  control_report=$(report_row "$control_name" "$(sha "$reports/$control_name")" CONTROL "$((base + 6))" "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
  control_typed=$(typed_row "$control_name" EXC_CRASH SIGABRT DYLD 1 'Library missing' \
    '["Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib"]' '[]')
  control_reason="CRASHATTRIBUTION${TB}$(field "$control_name")${TB}CONTROL${TB}exact-control"
  product_report=$(report_row "$product_name" "$(sha "$reports/$product_name")" PRODUCT "$((base + 5))" "$rd/$APPEXE")
  product_typed=$(typed_row "$product_name" EXC_BREAKPOINT SIGTRAP SIGNAL 5 'Trace/BPT trap: 5' '[]' '[]')
  product_reason="CRASHATTRIBUTION${TB}$(field "$product_name")${TB}PRODUCT${TB}launched-product"
  product_fail="PRODUCT-FAIL${TB}crash-report${TB}$(field "$product_name")"
  expected="$control_report
$control_typed
$control_reason
$product_report
$product_typed
$product_reason
$product_fail"
  for sink in "$EV/$arch/evidence/crash.delta" "$EV/$arch/evidence/leg.log" "$EV/$arch/evidence/crashreports"; do
    actual=$(evidence_only "$sink")
    [ "$actual" = "$expected" ] \
      || bad "E-gate-$role: ordered CONTROL/PRODUCT evidence differs in $sink"
  done
done

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-crash-attribution-red\tmacOS-15 reports, boundary ledger and attribution mutants\n'
  exit 0
fi
exit 1

# D0: zero reports is permitted, but all six launched processes are recorded.
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
    run_valid_case("exact-control", [
        ("zigBrowser-exact-control.ips", report_bytes(), "CONTROL", "exact-control")
    ], 0)

    first = report_bytes()
    second = report_bytes()
    run_valid_case("control-slot-consumed", [
        ("zigBrowser-control-a.ips", first, "CONTROL", "exact-control"),
        ("zigBrowser-control-b.ips", second, "PRODUCT", "control-slot-consumed"),
    ], 2)

    status_rows = ROWS[:-1] + (("control", CONTROL_PID, -9, CONTROL_EXE),)
    run_valid_case("control-status-mismatch", [
        ("zigBrowser-status.ips", report_bytes(), "PRODUCT", "control-status-mismatch")
    ], 2, rows=status_rows)
    run_valid_case("control-path-mismatch", [
        ("zigBrowser-path.ips", report_bytes(proc_path=PRODUCT_EXE),
         "PRODUCT", "control-path-mismatch")
    ], 2)
    run_valid_case("control-incident-mismatch", [
        ("zigBrowser-incident.ips",
         report_bytes(namespace="SIGNAL", indicator="Abort trap: 6", details=[], reasons=[]),
         "PRODUCT", "control-incident-mismatch")
    ], 2)
    run_valid_case("control-diagnostic-mismatch", [
        ("zigBrowser-diagnostic.ips", report_bytes(),
         "PRODUCT", "control-diagnostic-mismatch")
    ], 2, diagnostic_ok=False)

    product = report_bytes(
        pid=76005,
        proc_path=PRODUCT_EXE,
        exception_type="EXC_BREAKPOINT",
        exception_signal="SIGTRAP",
        namespace="SIGNAL",
        indicator="Trace/BPT trap: 5",
        details=[],
        reasons=[],
    )
    run_valid_case("launched-product", [
        ("zigBrowser-launched.ips", product, "PRODUCT", "launched-product")
    ], 2)
    structured = report_bytes(
        pid=77001,
        proc_path="/Applications/Unexpected.app/Contents/MacOS/unexpected",
        exception_type="EXC_BREAKPOINT",
        exception_signal="SIGTRAP",
        namespace="SIGNAL",
        indicator="Trace/BPT trap: 5",
        details=[],
        reasons=[],
    )
    run_valid_case("structured-product", [
        ("zigBrowser-structured.ips", structured, "PRODUCT", "structured-product")
    ], 2)
    unrelated = report_bytes(
        pid=77002,
        proc_path="/Applications/Other.app/Contents/MacOS/Other",
        exception_type="EXC_CRASH",
        exception_signal="SIGABRT",
        namespace="SIGNAL",
        indicator="Abort trap: 6",
        details=[],
        reasons=[],
        app_name="Other",
        metadata_bundle="invalid.example.Other",
        proc_name="Other",
        incident_bundle="invalid.example.Other",
    )
    run_valid_case("unrelated-process", [
        ("Other-application.ips", unrelated, "OTHER", "unrelated-process")
    ], 0)
    run_valid_case("process-evidence-incomplete", [
        ("zigBrowser-unverified.ips", report_bytes(),
         "UNVERIFIED", "process-evidence-incomplete")
    ], 3, rows=ROWS[:-1])

    # Compact fixture of the acquired 7,384-byte macOS-15 report's typed fields.
    # The library diagnostic is in termination.reasons, not generic details.
    real_shape_details = ["(terminated at launch; ignore backtrace)"]
    real_shape_reasons = [
        f"Library not loaded: {SHIM}",
        "Referenced from: <30856172-172D-3753-B6A5-A702CEDFB969> " + REDACTED,
        "Reason: tried: '/Users/laroncha/zb-gate-44f1e5e43d02e1ad5d7b7aa1f0d34c3fd951515a-"
        "a8141a2f3b889dd1/control/zigBrowser.app/"
        "Contents/Frameworks/libwkwebview_shim.dylib' (no such file)",
    ]
    real_shape = report_bytes(details=real_shape_details, reasons=real_shape_reasons)
    run_valid_case("macos15-reasons-control", [
        ("zigBrowser-2026-10-25-112231.ips", real_shape, "CONTROL", "exact-control")
    ], 0)

    acquired_noncontrols = [
        ("wrong-exception-type", report_bytes(exception_type="EXC_BREAKPOINT",
                                              details=real_shape_details,
                                              reasons=real_shape_reasons)),
        ("wrong-code", report_bytes(code=2, details=real_shape_details,
                                    reasons=real_shape_reasons)),
        ("missing-code", report_bytes(code=MISSING, details=real_shape_details,
                                      reasons=real_shape_reasons)),
        ("wrong-signal", report_bytes(exception_signal="SIGSEGV", details=real_shape_details,
                                      reasons=real_shape_reasons)),
        ("wrong-namespace", report_bytes(namespace="SIGNAL", details=real_shape_details,
                                         reasons=real_shape_reasons)),
        ("wrong-indicator", report_bytes(indicator="Other library error",
                                         details=real_shape_details, reasons=real_shape_reasons)),
        ("missing-shim-reason", report_bytes(details=real_shape_details,
                                             reasons=real_shape_reasons[1:])),
        ("another-library", report_bytes(
            details=real_shape_details,
            reasons=["Library not loaded: @rpath/libother.dylib"] + real_shape_reasons[1:],
        )),
        ("substring-only", report_bytes(
            details=real_shape_details,
            reasons=[f"prefix Library not loaded: {SHIM} suffix"] + real_shape_reasons[1:],
        )),
        ("metadata-only", report_bytes(details=real_shape_details, reasons=[])),
        ("legacy-details-substring", report_bytes(
            details=[f"prefix Library not loaded: {SHIM} suffix"], reasons=[]
        )),
    ]
    for label, raw in acquired_noncontrols:
        run_valid_case(label, [
            (f"zigBrowser-{label}.ips", raw, "PRODUCT", "control-incident-mismatch")
        ], 2)

    too_large = "X" * 4096
    malformed_inputs = [
        ("bound-exception-type", report_bytes(exception_type=too_large)),
        ("bound-exception-signal", report_bytes(exception_signal=too_large)),
        ("bound-termination-namespace", report_bytes(namespace=too_large)),
        ("bound-termination-indicator", report_bytes(indicator=too_large)),
        ("bound-details-count", report_bytes(details=["x"] * 9)),
        ("bound-details-element", report_bytes(details=["x" * 400])),
        ("bound-details-encoding", report_bytes(details=["x" * 200] * 3)),
        ("bound-reasons-count", report_bytes(reasons=["x"] * 9)),
        ("bound-reasons-element", report_bytes(reasons=["x" * 400])),
        ("bound-reasons-encoding", report_bytes(reasons=["x" * 200] * 3)),
        ("bound-termination-code", report_bytes(code=10 ** 1000)),
        ("type-exception-type", report_bytes(exception_type=7)),
        ("type-exception-signal", report_bytes(exception_signal=["SIGABRT"])),
        ("type-termination-namespace", report_bytes(namespace={"name": "DYLD"})),
        ("type-termination-indicator", report_bytes(indicator=None)),
        ("type-termination-code", report_bytes(code="1")),
        ("type-termination-code-bool", report_bytes(code=True)),
        ("type-details-list", report_bytes(details={"reason": "missing"})),
        ("type-details-element", report_bytes(details=[7])),
        ("type-reasons-list", report_bytes(reasons={"reason": "missing"})),
        ("type-reasons-element", report_bytes(reasons=[7])),
        ("encoding-exception", report_bytes(exception_type="\ud800")),
        ("encoding-details", report_bytes(details=["\ud800"])),
        ("encoding-reasons", report_bytes(reasons=["\ud800"])),
    ]
    for label, raw in malformed_inputs:
        malformed_case(label, raw)

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
