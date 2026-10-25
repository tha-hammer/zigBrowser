#!/usr/bin/env python3
"""RED, UNREGISTERED: malformed UNVERIFIED pid/path half-pairs terminate.

The HOME crash-report consumer is an indexed loop.  Either half-present
identity shape must be rejected once, without leaving the cursor on the same
record forever or emitting any partial HOME verdict.
"""

from __future__ import annotations

import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
GATE = HERE / "ms1c_app_gate.sh"
PROTECTED = HERE / "ms1c_home_protected_paths.txt"
EXPECTED = "HOMEAUDIT\tINCONCLUSIVE\tthe crash-report attribution is invalid\n"
problems: list[str] = []


def field(value: str | bytes) -> str:
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")


def extract_home_diff() -> str:
    source = GATE.read_text(encoding="utf-8")
    start_marker = "HOME_DIFF_PY='\n"
    end_marker = "\n'\ntake() {"
    if source.count(start_marker) != 1 or source.count(end_marker) != 1:
        raise ValueError("HOME_DIFF_PY boundary is not unique")
    start = source.index(start_marker) + len(start_marker)
    return source[start:source.index(end_marker, start)]


def snapshot(root: bytes) -> bytes:
    exclude = root + b"/zb-gate-half-pair-red"
    root_meta = "d 700 501 20 8 256 50 50 100 - -"
    return (
        f"ROOT\t{field(root)}\t{field(exclude)}\n"
        f"{field(b'.')}\t{root_meta}\n"
        "END\t1\n"
    ).encode("ascii")


def run_case(label: str, pid_field: str, path_field: str, code: str, work: Path) -> None:
    case = work / label
    case.mkdir()
    root = b"/Users/owner"
    before = case / "before"
    after = case / "after"
    reports = case / "reports"
    before.write_bytes(snapshot(root))
    after.write_bytes(snapshot(root))
    reports.write_text(
        "\t".join((
            "CRASHREPORT", field(f"zigBrowser-{label}.ips"), "1" * 64,
            "UNVERIFIED", pid_field, path_field,
        )) + "\n",
        encoding="ascii",
    )
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(work / "home"),
        "TMPDIR": str(work / "tmp"),
        "XDG_CACHE_HOME": str(work / "xdg-cache"),
        "XDG_CONFIG_HOME": str(work / "xdg-config"),
        "XDG_DATA_HOME": str(work / "xdg-data"),
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    command = [
        "/usr/bin/timeout", "--signal=TERM", "2s",
        sys.executable, "-I", "-X", "dev", "-W", "error", "-B", "-X", "utf8", "-c", code,
        str(before), str(after), os.fsdecode(root), "Library/Logs/DiagnosticReports",
        "/private/control/zigBrowser", str(PROTECTED), str(reports),
    ]
    completed = subprocess.run(command, text=True, capture_output=True, env=environment, check=False)
    if completed.returncode == 124:
        problems.append(f"{label}: HOME crash-report consumer exceeded the hard two-second timeout")
        return
    if completed.returncode != 3:
        problems.append(f"{label}: exit {completed.returncode}, expected 3")
    if completed.stdout != EXPECTED:
        problems.append(f"{label}: output is not the one exact bounded INCONCLUSIVE verdict")
    if len(completed.stdout.encode("utf-8")) > 1000:
        problems.append(f"{label}: output exceeds the 1000-byte evidence bound")
    combined = completed.stdout + completed.stderr
    if completed.stderr or "HOME-DELTA\t" in combined or "Traceback" in combined or "Warning" in combined:
        problems.append(f"{label}: partial evidence, traceback or warning escaped")


def main() -> int:
    try:
        code = extract_home_diff()
    except (OSError, ValueError) as error:
        print(f"FAIL\tms1c-home-crash-pair-red\tsetup: {error}")
        return 1
    scratch = Path(os.environ.get("TMPDIR", ""))
    if not scratch.is_dir():
        print("FAIL\tms1c-home-crash-pair-red\tTMPDIR must name private scratch")
        return 1
    work = Path(tempfile.mkdtemp(prefix="home-crash-pair-red-", dir=str(scratch)))
    for directory in (work / "home", work / "tmp", work / "xdg-cache", work / "xdg-config", work / "xdg-data"):
        directory.mkdir()
    valid_path = field(b"/private/run/app/zigBrowser.app/Contents/MacOS/zigBrowser")
    run_case("missing-pid", "-", valid_path, code, work)
    run_case("missing-path", "7001", "-", code, work)
    if problems:
        for item in problems:
            print(f"not ok  {item}")
        return 1
    print("PASS\tms1c-home-crash-pair-red\tmalformed pid/path half-pairs terminate fail closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
