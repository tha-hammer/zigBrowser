#!/usr/bin/env python3
"""RED, UNREGISTERED: bind Apple's control-report path redaction to all proof.

The consumed arm64 MS1c run retained this exact report identity::

    CRASHREPORT b64:emlnQnJvd3Nlci0yMDI2LTEwLTI0LTIyNTczOS5pcHM=
      4c46a3304e2ac6d6229545aed5ec380440a4dec215b1111561fb006213b641fe
      UNVERIFIED 62307
      b64:L1VzZXJzL1VTRVIvKi96aWdCcm93c2VyLmFwcC9Db250ZW50cy9NYWNPUy96aWdCcm93c2Vy

Its macOS 15 ``procPath`` is the literal Apple-redacted form
``/Users/USER/*/zigBrowser.app/Contents/MacOS/zigBrowser``.  It is CONTROL only
when that path is joined to the unique recorded control pid, status -6, the
exact missing-shim DYLD incident and the observed diagnostic for the exact
unredacted control executable.  Exact unredacted paths remain valid.  A second
matching report, a merely similar redaction/suffix, product identity, bundle
identity, another DYLD failure, or incomplete process evidence never becomes
CONTROL.

Every case uses the repaired complete real-shaped process table and lifecycle:
render protocol 130, render screenshot 0, reply 130, loadfail 5, arch 130 and
control -6.  The report fixture is a faithful two-record macOS 15 ``.ips``
(metadata JSON followed by its separate incident JSON).  The original retained
name, digest, pid and encoded path above stay locked independently because the
compact causal fixture necessarily has different bytes.
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
from typing import Optional


HERE = Path(__file__).resolve().parent
AUDIT = HERE / "ms1c_crash_audit.py"

RETAINED_NAME = "zigBrowser-2026-10-24-225739.ips"
RETAINED_DIGEST = "4c46a3304e2ac6d6229545aed5ec380440a4dec215b1111561fb006213b641fe"
RETAINED_PID = 62307
RETAINED_REDACTED_PATH = "/Users/USER/*/zigBrowser.app/Contents/MacOS/zigBrowser"
PRODUCT_EXE = (
    "/Users/laroncha/zb-gate-98e92b9708bcc55194cf8e5084bb8c5467e54d9c-"
    "1937cd5ebefc43fa/app/zigBrowser.app/Contents/MacOS/zigBrowser"
)
CONTROL_EXE = (
    "/Users/laroncha/zb-gate-98e92b9708bcc55194cf8e5084bb8c5467e54d9c-"
    "1937cd5ebefc43fa/control/zigBrowser.app/Contents/MacOS/zigBrowser"
)
SHIM = "@executable_path/../Frameworks/libwkwebview_shim.dylib"
ROWS = (
    ("render", 62233, 130, PRODUCT_EXE),
    ("render", 62242, 0, PRODUCT_EXE),
    ("reply", 62255, 130, PRODUCT_EXE),
    ("loadfail", 62270, 5, PRODUCT_EXE),
    ("arch", 62284, 130, PRODUCT_EXE),
    ("control", RETAINED_PID, -6, CONTROL_EXE),
)
MARKERS = (
    ("render", 62233),
    ("reply", 62255),
    ("arch", 62284),
)

problems: list[str] = []


def field(value: str) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


RETAINED_RECORD = (
    f"CRASHREPORT\t{field(RETAINED_NAME)}\t{RETAINED_DIGEST}\tUNVERIFIED\t"
    f"{RETAINED_PID}\t{field(RETAINED_REDACTED_PATH)}"
)


def problem(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def retained_evidence_contract() -> None:
    expected = (
        "CRASHREPORT\tb64:emlnQnJvd3Nlci0yMDI2LTEwLTI0LTIyNTczOS5pcHM=\t"
        "4c46a3304e2ac6d6229545aed5ec380440a4dec215b1111561fb006213b641fe\t"
        "UNVERIFIED\t62307\t"
        "b64:L1VzZXJzL1VTRVIvKi96aWdCcm93c2VyLmFwcC9Db250ZW50cy9NYWNPUy96aWdCcm93c2Vy"
    )
    if RETAINED_RECORD != expected:
        problem("R0-retained-evidence", "the original name/digest/pid/path row changed")


def report_bytes(
    *,
    pid: int = RETAINED_PID,
    proc_path: str = RETAINED_REDACTED_PATH,
    bundle_id: str = "com.cosmichq.zigBrowser",
    proc_name: str = "zigBrowser",
    exception_type: str = "EXC_CRASH",
    exception_signal: str = "SIGABRT",
    namespace: str = "DYLD",
    indicator: str = "Library missing",
    detail: str = f"Library not loaded: {SHIM}",
) -> bytes:
    metadata = {
        "app_name": "zigBrowser",
        "timestamp": "2026-10-24 22:57:39.00 -0400",
        "app_version": "0.2.0",
        "slice_uuid": "2E11B6BE-9863-3EB2-9245-0937BB22A52A",
        "build_version": "1",
        "platform": 1,
        "bundleID": bundle_id,
        "share_with_app_devs": 0,
        "is_first_party": 0,
        "bug_type": "309",
        "os_version": "macOS 15.7.1 (24G231)",
        "roots_installed": 0,
        "name": "zigBrowser",
        "incident_id": "CONTROL-98E92B97",
    }
    incident = {
        "uptime": 42,
        "procRole": "Foreground",
        "version": 2,
        "userID": 501,
        "deployVersion": 210,
        "modelCode": "Mac15,6",
        "coalitionID": 700,
        "osVersion": {"train": "macOS 15.7.1", "build": "24G231", "releaseType": "User"},
        "captureTime": "2026-10-24 22:57:39.1234 -0400",
        "incident": "CONTROL-98E92B97",
        "pid": pid,
        "translated": False,
        "cpuType": "ARM-64",
        "procLaunch": "2026-10-24 22:57:39.0000 -0400",
        "procName": proc_name,
        "procPath": proc_path,
        "bundleInfo": {"CFBundleIdentifier": bundle_id},
        "parentProc": "Python",
        "parentPid": 4000,
        "exception": {
            "codes": "0x0, 0x0",
            "rawCodes": [0, 0],
            "type": exception_type,
            "signal": exception_signal,
        },
        "termination": {
            "code": 1,
            "flags": 518,
            "namespace": namespace,
            "indicator": indicator,
            "details": [detail],
        },
        "faultingThread": 0,
        "threads": [],
        "usedImages": [],
    }
    return (
        json.dumps(metadata, sort_keys=True, separators=(",", ":"))
        + "\n"
        + json.dumps(incident, sort_keys=True, indent=2)
        + "\n"
    ).encode("utf-8")


def diagnostic(executable: str = CONTROL_EXE, library: str = SHIM) -> str:
    return (
        f"dyld[{RETAINED_PID}]: Library not loaded: {library}\n"
        f"  Referenced from: <2E11B6BE-9863-3EB2-9245-0937BB22A52A> {executable}\n"
        f"  Reason: tried: '{library}' (no such file)\n"
    )


def expected_lines(reports: list[tuple[str, bytes, str]]) -> list[str]:
    lines: list[str] = []
    for name, raw, kind in sorted(reports):
        text = raw.decode("utf-8")
        decoder = json.JSONDecoder()
        _metadata, end = decoder.raw_decode(text)
        while end < len(text) and text[end].isspace():
            end += 1
        incident, _end = decoder.raw_decode(text, end)
        pid = incident["pid"]
        proc_path = incident["procPath"]
        lines.append(
            f"CRASHREPORT\t{field(name)}\t{hashlib.sha256(raw).hexdigest()}\t"
            f"{kind}\t{pid}\t{field(proc_path)}"
        )
        if kind == "PRODUCT":
            lines.append(f"PRODUCT-FAIL\tcrash-report\t{field(name)}")
    return lines


def run_case(
    label: str,
    reports: list[tuple[str, bytes, str]],
    expected_rc: int,
    *,
    rows: tuple[tuple[str, int, int, str], ...] = ROWS,
    diag_text: Optional[str] = None,
) -> None:
    with tempfile.TemporaryDirectory(prefix="ms1c-redacted-control-") as tmp_text:
        tmp = Path(tmp_text)
        diag = tmp / "home" / "Library" / "Logs" / "DiagnosticReports"
        diag.mkdir(parents=True)
        for name, raw, _kind in reports:
            (diag / name).write_bytes(raw)

        ledger = tmp / "browser-processes"
        ledger.write_text(
            "".join(f"{row}\t{pid}\t{status}\t{executable}\n" for row, pid, status, executable in rows),
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
        control_err.write_text(diag_text if diag_text is not None else diagnostic(), encoding="utf-8")
        ignore = tmp / "crash.ignore"
        audit_marker = tmp / "process-audit"

        command = [
            sys.executable,
            "-B",
            str(AUDIT),
            "reports",
            "--ledger",
            str(ledger),
            "--lifecycle-ledger",
            str(lifecycle),
            "--audit-marker",
            str(audit_marker),
            "--before",
            str(before),
            "--diag",
            str(diag),
            "--diag-rel",
            "Library/Logs/DiagnosticReports",
            "--control-exe",
            CONTROL_EXE,
            "--control-err",
            str(control_err),
            "--ignore-out",
            str(ignore),
        ]
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        actual = completed.stdout.splitlines()
        expected = expected_lines(reports)
        expected_ignore = [
            field(f"Library/Logs/DiagnosticReports/{name}") for name, _raw, _kind in sorted(reports)
        ]
        try:
            actual_ignore = ignore.read_text(encoding="ascii").splitlines()
        except OSError as error:
            actual_ignore = [f"<unreadable: {error}>"]
        if completed.returncode != expected_rc:
            problem(label, f"rc {completed.returncode}, expected {expected_rc}")
        if completed.stderr:
            problem(label, f"unexpected stderr {completed.stderr!r}")
        if actual != expected:
            problem(label, f"records {actual!r}, expected {expected!r}")
        if actual_ignore != expected_ignore:
            problem(label, f"ignore census {actual_ignore!r}, expected {expected_ignore!r}")
        if any(len(line.encode("utf-8")) > 1000 for line in actual):
            problem(label, "an evidence line is not bounded")


def main() -> int:
    retained_evidence_contract()

    exact = report_bytes(proc_path=CONTROL_EXE)
    redacted = report_bytes()
    run_case("C0-exact-control", [(RETAINED_NAME, exact, "CONTROL")], 0)
    run_case("C1-canonical-redacted-control", [(RETAINED_NAME, redacted, "CONTROL")], 0)

    near_paths = {
        "C2-redaction-without-suffix": "/Users/USER/*",
        "C2-suffix-only": "/zigBrowser.app/Contents/MacOS/zigBrowser",
        "C2-real-user-instead-of-literal-redaction": "/Users/USER/name/zigBrowser.app/Contents/MacOS/zigBrowser",
        "C2-wrong-redacted-user": "/Users/OTHER/*/zigBrowser.app/Contents/MacOS/zigBrowser",
        "C2-extra-redacted-component": "/Users/USER/*/control/zigBrowser.app/Contents/MacOS/zigBrowser",
        "C2-wrong-app-suffix": "/Users/USER/*/Other.app/Contents/MacOS/zigBrowser",
        "C2-wrong-executable-suffix": "/Users/USER/*/zigBrowser.app/Contents/MacOS/Other",
    }
    for label, path in near_paths.items():
        run_case(label, [(RETAINED_NAME, report_bytes(proc_path=path), "PRODUCT")], 2)

    run_case(
        "C3-product-pid",
        [(RETAINED_NAME, report_bytes(pid=62284), "PRODUCT")],
        2,
    )
    run_case(
        "C3-control-pid-product-path",
        [(RETAINED_NAME, report_bytes(proc_path=PRODUCT_EXE), "PRODUCT")],
        2,
    )
    wrong_status = ROWS[:-1] + (("control", RETAINED_PID, -5, CONTROL_EXE),)
    run_case(
        "C3-wrong-control-status",
        [(RETAINED_NAME, redacted, "PRODUCT")],
        2,
        rows=wrong_status,
    )
    run_case(
        "C3-wrong-diagnostic-executable",
        [(RETAINED_NAME, redacted, "PRODUCT")],
        2,
        diag_text=diagnostic(PRODUCT_EXE),
    )
    run_case(
        "C3-other-DYLD-library",
        [(RETAINED_NAME, report_bytes(detail="Library not loaded: @rpath/libother.dylib"), "PRODUCT")],
        2,
    )
    run_case(
        "C3-non-DYLD-termination",
        [(
            RETAINED_NAME,
            report_bytes(namespace="SIGNAL", indicator="Abort trap: 6", detail="signal 6"),
            "PRODUCT",
        )],
        2,
    )
    run_case(
        "C3-bundle-id-alone",
        [(
            RETAINED_NAME,
            report_bytes(pid=70001, proc_path="/Applications/Other.app/Contents/MacOS/Other", proc_name="Other"),
            "PRODUCT",
        )],
        2,
    )

    run_case(
        "C4-second-redacted-control",
        [
            ("zigBrowser-control-a.ips", redacted, "CONTROL"),
            ("zigBrowser-control-b.ips", redacted, "PRODUCT"),
        ],
        2,
    )
    run_case(
        "C5-missing-control-process",
        [(RETAINED_NAME, redacted, "UNVERIFIED")],
        3,
        rows=ROWS[:-1],
    )
    run_case(
        "C5-absent-process-table",
        [(RETAINED_NAME, redacted, "UNVERIFIED")],
        3,
        rows=(),
    )
    run_case(
        "C5-conflicting-control-process",
        [(RETAINED_NAME, redacted, "UNVERIFIED")],
        3,
        rows=ROWS + (("control", RETAINED_PID, -6, CONTROL_EXE),),
    )

    if problems:
        for item in problems:
            print(f"not ok  {item}")
        return 1
    print("PASS\tms1c-control-redacted-path-red\tmacOS-15 canonical control attribution")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
