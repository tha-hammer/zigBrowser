#!/usr/bin/env python3
"""GREEN, REGISTERED (red 68141527; SilverRidge 82ecec84): a protected regular file whose lstat succeeds but whose
contents cannot be opened must keep its ordinary metadata row, with SHA ``-``, as well as its side-tagged
SKIPPED-PROTECTED marker.

The embedded snapshotter is exercised directly on both BEFORE and AFTER for EACCES and EPERM. Each pair must
produce complete snapshots that the embedded differ accepts. Changing the normalized reason across the boundary
must remain INCONCLUSIVE. It is registered directly under test-mac-varfolders-audit and the aggregate test.

Run: python3 -X dev tests/e2e/mac_varfolders_digest_protected_test.py [helper path]
"""
from __future__ import annotations

import errno
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as base  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
PAIR = ("C", "com.apple.WebKit.GPU.Sandbox")
failures: list[str] = []


def bad(message: str) -> None:
    failures.append(message)


def extract(row: str, box: base.Box, helper: Path, variable: str, name: str) -> Path | None:
    result = subprocess.run(
        ["bash", "-c", f'. "$1"; printf "%s" "${{{variable}}}"', "_", str(helper)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.returncode != 0 or not result.stdout:
        bad(f"{row}: cannot extract {variable}: rc={result.returncode} {result.stderr!r}")
        return None
    path = box.tmp / name
    path.write_bytes(result.stdout)
    return path


def sha_unavailable_record(path: Path) -> str:
    fields = base.record(path).split(" ")
    if len(fields) != 11 or fields[0] != "f":
        raise AssertionError(f"unexpected regular-file record {fields!r}")
    fields[9] = "-"
    return " ".join(fields)


def forced_snapshot(
    row: str,
    box: base.Box,
    snapshotter: Path,
    roots: Path,
    side: str,
    error_number: int,
) -> tuple[int, Path, tuple[int, int]] | None:
    target = box.C / PAIR[1]
    output = box.tmp / f"snapshot-{side.lower()}-{errno.errorcode[error_number].lower()}.tsv"
    trace = box.tmp / f"trace-{side.lower()}-{errno.errorcode[error_number].lower()}.txt"
    wrapper = box.tmp / f"wrapper-{side.lower()}-{errno.errorcode[error_number].lower()}.py"
    wrapper.write_text(
        """import os, sys
error_number = int(sys.argv[1])
source, roots, output, side, target, trace = sys.argv[2:]
real_lstat, real_open = os.lstat, os.open
counts = {"lstat": 0, "open": 0}
def lstat(path, *args, **kwargs):
    if os.fsdecode(path) == target:
        counts["lstat"] += 1
    return real_lstat(path, *args, **kwargs)
def denied_open(path, flags, *args, **kwargs):
    if os.fsdecode(path) == target:
        counts["open"] += 1
        raise OSError(error_number, os.strerror(error_number), path)
    return real_open(path, flags, *args, **kwargs)
os.lstat, os.open = lstat, denied_open
sys.argv = [source, roots, output, side]
try:
    exec(compile(open(source, encoding="utf-8").read(), source, "exec"), {"__name__": "__main__"})
finally:
    with open(trace, "w", encoding="utf-8") as f:
        f.write("%d %d\\n" % (counts["lstat"], counts["open"]))
"""
    )
    result = subprocess.run(
        [sys.executable, str(wrapper), str(error_number), str(snapshotter), str(roots), str(output), side,
         str(target), str(trace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stdout or result.stderr:
        bad(f"{row}: snapshotter must be silent, got stdout={result.stdout!r} stderr={result.stderr!r}")
    try:
        counts = tuple(int(value) for value in trace.read_text().split())
    except (OSError, ValueError) as error:
        bad(f"{row}: missing lstat/open trace: {error}")
        return result.returncode, output, (0, 0)
    if len(counts) != 2:
        bad(f"{row}: malformed lstat/open trace {counts!r}")
        return result.returncode, output, (0, 0)
    return result.returncode, output, (counts[0], counts[1])


def exact_snapshot(
    row: str,
    path: Path,
    side: str,
    reason: str,
    want_record: str,
    counts: tuple[int, int],
) -> None:
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        bad(f"{row}: cannot read snapshot: {error}")
        return
    ordinary: dict[tuple[str, str], list[str]] = {}
    for line in lines:
        fields = line.split("\t", 2)
        if len(fields) == 3 and fields[0] in ("C", "P", "T"):
            try:
                rel = os.fsdecode(base.decode_field(fields[1]))
            except ValueError as error:
                bad(f"{row}: malformed ordinary-row path: {error}: {line!r}")
                continue
            ordinary.setdefault((fields[0], rel), []).append(fields[2])
    got_rows = ordinary.get(PAIR, [])
    if got_rows != [want_record]:
        bad(f"{row}: want one ordinary row with SHA '-', got {got_rows!r}")
    want_marker = f"SKIPPED-PROTECTED\t{side}\t{PAIR[0]}\t{base.evidence_field(PAIR[1])}\t{reason}"
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    if markers != [want_marker]:
        bad(f"{row}: want exactly side-tagged marker {want_marker!r}, got {markers!r}")
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if errors:
        bad(f"{row}: protected digest failure must emit no ERROR row, got {errors!r}")
    body_count = sum(len(values) for values in ordinary.values()) + len(markers)
    want_end = f"END\t{body_count}"
    ends = [line for line in lines if line.startswith("END\t")]
    if ends != [want_end] or lines[-1:] != [want_end]:
        bad(f"{row}: want one final exact {want_end!r}, got {ends!r} and tail {lines[-2:]!r}")
    if counts[0] < 1 or counts[1] != 1:
        bad(f"{row}: the target must have successful lstat and one denied open, got lstat/open={counts!r}")


def run_diff(row: str, differ: Path, before: Path, after: Path) -> tuple[int, list[str]]:
    result = subprocess.run(
        [sys.executable, str(differ), str(before), str(after)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stderr:
        bad(f"{row}: differ wrote stderr {result.stderr.decode(errors='replace')!r}")
    return result.returncode, result.stdout.decode(errors="replace").splitlines()


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures = []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]

    box = base.Box(helper)
    try:
        target = box.C / PAIR[1]
        target.write_text("protected bytes\n")
        want_record = sha_unavailable_record(target)
        roots = box.tmp / "roots.tsv"
        roots.write_text(f"T\t{base.evidence_field(box.T)}\nC\t{base.evidence_field(box.C)}\n"
                         f"P\t{base.evidence_field(box.user)}\n")
        snapshotter = extract("D0", box, helper, "__VF_SNAPSHOT_PY", "snapshot.py")
        differ = extract("D0", box, helper, "__VF_DIFF_PY", "diff.py")
        if snapshotter is None or differ is None:
            return list(failures)

        outputs: dict[tuple[str, int], Path] = {}
        for error_number in (errno.EACCES, errno.EPERM):
            reason = errno.errorcode[error_number]
            for side in ("BEFORE", "AFTER"):
                row = f"D1 {side} {reason}"
                result = forced_snapshot(row, box, snapshotter, roots, side, error_number)
                if result is None:
                    continue
                rc, output, counts = result
                outputs[(side, error_number)] = output
                if rc != 0:
                    bad(f"{row}: protected digest failure must leave a complete snapshot, got rc={rc}")
                if output.is_file():
                    exact_snapshot(row, output, side, reason, want_record, counts)
                else:
                    bad(f"{row}: success path did not write a snapshot")

            before = outputs.get(("BEFORE", error_number))
            after = outputs.get(("AFTER", error_number))
            if before is not None and after is not None:
                row = f"D2 accepted diff {reason}"
                rc, out = run_diff(row, differ, before, after)
                want = [
                    f"SKIPPED-PROTECTED\tBEFORE\t{PAIR[0]}\t{base.evidence_field(PAIR[1])}\t{reason}",
                    f"SKIPPED-PROTECTED\tAFTER\t{PAIR[0]}\t{base.evidence_field(PAIR[1])}\t{reason}",
                    "VARFOLDERS\tCOMPLETE\t0",
                ]
                if rc != 0 or out != want:
                    bad(f"{row}: want accepted no-delta diff {want!r}, got rc={rc} {out!r}")

        before = outputs.get(("BEFORE", errno.EACCES))
        after = outputs.get(("AFTER", errno.EPERM))
        if before is not None and after is not None:
            row = "D3 reason transition"
            rc, out = run_diff(row, differ, before, after)
            want = ["VARFOLDERS\tINCONCLUSIVE\tthe protected-skip set changed during the run"]
            if rc != 2 or out != want:
                bad(f"{row}: want exact fail-closed transition {want!r}, got rc={rc} {out!r}")
    finally:
        box.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\tmac-varfolders-digest-protected\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-digest-protected\tD1-D3")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
