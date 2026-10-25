#!/usr/bin/env python3
"""Registered lstat-first protected-directory ordering oracle (SilverRidge b55c3b5f).

The consumed Intel run exposed the opposite callback order from the existing
marker-only fixture: os.walk first yields an exact reviewed C directory, the
snapshotter's entry() lstat is denied, and only then does os.walk report the
same directory's enumeration denial.  EACCES/EPERM in that exact order must
leave one canonical side marker, no ERROR, no invented ordinary identity and
an exact END count.  A successful first lstat still leaves one directory row
plus the marker.  Literal pairs, errno, marker syntax and transition boundaries
remain fail closed.

Direct: python3 -X dev -W error -B tests/e2e/mac_varfolders_lstat_first_protected_test.py [helper]
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
PAIRS = (
    ("C", "com.apple.WebKit.GPU.Sandbox"),
    ("C", "com.apple.WebKit.Networking.Sandbox"),
    ("C", "com.apple.WebKit.WebContent.Sandbox"),
)
failures: list[str] = []


def bad(row: str, why: str) -> None:
    failures.append(f"{row}: {why}")


def path_for(box: base.Box, pair: tuple[str, str]) -> Path:
    return box.C / pair[1]


def marker(side: str, pair: tuple[str, str], reason: str) -> str:
    return f"SKIPPED-PROTECTED\t{side}\t{pair[0]}\t{base.evidence_field(pair[1])}\t{reason}"


def extract(row: str, box: base.Box, helper: Path, variable: str, name: str) -> Path | None:
    result = subprocess.run(
        ["bash", "-c", f'. "$1"; printf "%s" "${{{variable}}}"', "_", str(helper)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.returncode != 0 or not result.stdout:
        bad(row, f"cannot extract {variable}: rc={result.returncode} {result.stderr!r}")
        return None
    path = box.tmp / name
    path.write_bytes(result.stdout)
    return path


def forced_snapshot(
    row: str,
    box: base.Box,
    snapshotter: Path,
    roots: Path,
    pair: tuple[str, str],
    side: str,
    enumeration_error: int,
    identity_error: int,
) -> tuple[int, Path, list[str]]:
    """Yield target, deny entry lstat, then deliver the walk callback."""
    target = path_for(box, pair)
    tag = f"{pair[1].replace('/', '-')}-{side.lower()}-{enumeration_error}-{identity_error}"
    output = box.tmp / f"snapshot-{tag}.tsv"
    trace = box.tmp / f"trace-{tag}.txt"
    wrapper = box.tmp / f"wrapper-{tag}.py"
    wrapper.write_text(
        """import os, sys
enumeration_error, identity_error = map(int, sys.argv[1:3])
source, roots, output, side, target, trace = sys.argv[3:]
real_lstat, real_scandir = os.lstat, os.scandir
target = os.path.normpath(os.fsencode(target))
events = []
def same(path, wanted):
    return os.path.normpath(os.fsencode(os.fspath(path))) == wanted
def lstat(path, *args, **kwargs):
    if same(path, target):
        events.append("lstat")
        if identity_error:
            raise OSError(identity_error, os.strerror(identity_error), path)
    return real_lstat(path, *args, **kwargs)
def scandir(path):
    if same(path, target):
        events.append("enumerate")
        raise OSError(enumeration_error, os.strerror(enumeration_error), path)
    return real_scandir(path)
os.lstat, os.scandir = lstat, scandir
sys.argv = [source, roots, output, side]
try:
    with open(source, encoding="utf-8") as stream:
        code = compile(stream.read(), source, "exec")
    exec(code, {"__name__": "__main__"})
finally:
    with open(trace, "w", encoding="ascii") as stream:
        stream.write(" ".join(events) + "\\n")
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(wrapper), str(enumeration_error), str(identity_error), str(snapshotter), str(roots),
         str(output), side, str(target), str(trace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stdout or result.stderr:
        bad(row, f"snapshotter must be silent, got stdout={result.stdout!r} stderr={result.stderr!r}")
    try:
        events = trace.read_text(encoding="ascii").split()
    except OSError as error:
        bad(row, f"missing operation trace: {error}")
        events = []
    return result.returncode, output, events


def read_lines(row: str, output: Path) -> list[str]:
    try:
        return output.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        bad(row, f"cannot read snapshot: {error}")
        return []


def ordinary(lines: list[str]) -> dict[tuple[str, str], list[str]]:
    rows: dict[tuple[str, str], list[str]] = {}
    for line in lines:
        fields = line.split("\t", 2)
        if len(fields) != 3 or fields[0] not in ("T", "C", "P"):
            continue
        try:
            rel = os.fsdecode(base.decode_field(fields[1]))
        except ValueError:
            continue
        rows.setdefault((fields[0], rel), []).append(fields[2])
    return rows


def end_is_exact(lines: list[str], rows: dict[tuple[str, str], list[str]], markers: list[str]) -> bool:
    want = f"END\t{sum(len(values) for values in rows.values()) + len(markers)}"
    return lines[-1:] == [want] and [line for line in lines if line.startswith("END\t")] == [want]


def exact_marker_only(
    row: str,
    rc: int,
    output: Path,
    pair: tuple[str, str],
    side: str,
    reason: str,
    events: list[str],
) -> None:
    lines = read_lines(row, output)
    rows = ordinary(lines)
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    ordered = bool(events) and events[0] == "lstat" and "enumerate" in events \
        and "lstat" in events[events.index("enumerate") + 1:]
    if not (rc == 0 and not rows.get(pair) and markers == [marker(side, pair, reason)] and not errors
            and end_is_exact(lines, rows, markers) and ordered):
        bad(row, "want rc0, lstat before enumeration then callback lstat, one exact marker, no identity/ERROR and "
            "exact END; "
            f"got rc={rc} events={events!r} row={rows.get(pair)!r} markers={markers!r} errors={errors!r} "
            f"tail={lines[-3:]!r}")


def exact_row_and_marker(
    row: str,
    box: base.Box,
    rc: int,
    output: Path,
    pair: tuple[str, str],
    side: str,
    reason: str,
    events: list[str],
) -> None:
    lines = read_lines(row, output)
    rows = ordinary(lines)
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if not (rc == 0 and rows.get(pair) == [base.record(path_for(box, pair))]
            and markers == [marker(side, pair, reason)] and not errors
            and end_is_exact(lines, rows, markers) and events[0:1] == ["lstat"]
            and events[-1:] == ["enumerate"]):
        bad(row, "successful lstat must leave one row plus marker and exact END; "
            f"got rc={rc} events={events!r} row={rows.get(pair)!r} markers={markers!r} errors={errors!r}")


def exact_incomplete(
    row: str,
    rc: int,
    output: Path,
    pair: tuple[str, str],
    events: list[str],
    allow_marker: bool,
    error_count: int,
) -> None:
    lines = read_lines(row, output)
    rows = ordinary(lines)
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    prefix = f"ERROR\t{pair[0]}\t{base.evidence_field(pair[1])}\t"
    marker_ok = len(markers) <= 1 if allow_marker else not markers
    if not (rc == 3 and not rows.get(pair) and marker_ok and len(errors) == error_count
            and all(line.startswith(prefix) for line in errors) and end_is_exact(lines, rows, markers)
            and events[0:1] == ["lstat"] and "enumerate" in events):
        bad(row, "non-exempt observation must stay bounded and incomplete; "
            f"got rc={rc} events={events!r} row={rows.get(pair)!r} markers={markers!r} errors={errors!r}")


def run_diff(row: str, differ: Path, before: Path, after: Path) -> tuple[int, list[str]]:
    result = subprocess.run(
        [sys.executable, str(differ), str(before), str(after)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stderr:
        bad(row, f"differ wrote stderr {result.stderr.decode(errors='replace')!r}")
    return result.returncode, result.stdout.decode(errors="replace").splitlines()


def clean_marker_only(source: Path, output: Path) -> None:
    lines = source.read_text(encoding="ascii").splitlines()
    output.write_text(
        "\n".join(line for line in lines if not line.startswith("ERROR\t")) + "\n",
        encoding="ascii",
    )


def corrupt_marker(source: Path, output: Path, kind: str) -> None:
    lines = source.read_text(encoding="ascii").splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith("SKIPPED-PROTECTED\t"))
    fields = lines[index].split("\t")
    if kind == "duplicate":
        lines.insert(index + 1, lines[index])
        lines[-1] = f"END\t{int(lines[-1].split(chr(9))[1]) + 1}"
    elif kind == "noncanonical":
        fields[3] = "bad:" + fields[3][4:]
        lines[index] = "\t".join(fields)
    elif kind == "wrong-side":
        fields[1] = "BEFORE" if fields[1] == "AFTER" else "AFTER"
        lines[index] = "\t".join(fields)
    else:
        raise AssertionError(kind)
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


def expect_inconclusive(row: str, differ: Path, before: Path, after: Path) -> None:
    rc, out = run_diff(row, differ, before, after)
    if rc != 2 or len(out) != 1 or out[0].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"] \
            or any(line.startswith(("VARFOLDERS-DELTA\t", "VARFOLDERS\tCOMPLETE\t")) for line in out):
        bad(row, f"want one bounded INCONCLUSIVE and no partial evidence, got rc={rc} {out!r}")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures, base.hits = [], []
    if not helper.is_file():
        return [f"helper does not exist: {helper}"]

    box = base.Box(helper)
    try:
        for pair in PAIRS:
            path_for(box, pair).mkdir(parents=True, exist_ok=True)
        roots = box.tmp / "roots.tsv"
        roots.write_text(
            f"T\t{base.evidence_field(box.T)}\nC\t{base.evidence_field(box.C)}\n"
            f"P\t{base.evidence_field(box.user)}\n",
            encoding="ascii",
        )
        snapshotter = extract("L0", box, helper, "__VF_SNAPSHOT_PY", "snapshot.py")
        differ = extract("L0", box, helper, "__VF_DIFF_PY", "diff.py")
        if snapshotter is None or differ is None:
            return list(failures)

        denied: dict[tuple[tuple[str, str], int, str], Path] = {}
        identity: dict[tuple[tuple[str, str], str], Path] = {}
        for pair in PAIRS:
            for error_number in (errno.EACCES, errno.EPERM):
                reason = errno.errorcode[error_number]
                for side in ("BEFORE", "AFTER"):
                    row = f"L1 {pair[1]} {side} {reason} lstat-first"
                    rc, output, events = forced_snapshot(
                        row, box, snapshotter, roots, pair, side, error_number, error_number,
                    )
                    denied[(pair, error_number, side)] = output
                    exact_marker_only(row, rc, output, pair, side, reason, events)

                before = box.tmp / f"clean-{pair[1]}-{reason}-before.tsv"
                after = box.tmp / f"clean-{pair[1]}-{reason}-after.tsv"
                clean_marker_only(denied[(pair, error_number, "BEFORE")], before)
                clean_marker_only(denied[(pair, error_number, "AFTER")], after)
                rc, out = run_diff(f"L2 stable {pair!r} {reason}", differ, before, after)
                want = [marker("BEFORE", pair, reason), marker("AFTER", pair, reason),
                        "VARFOLDERS\tCOMPLETE\t0"]
                if rc != 0 or out != want:
                    bad(f"L2 stable {pair!r} {reason}", f"want {want!r}, got rc={rc} {out!r}")

            for side in ("BEFORE", "AFTER"):
                row = f"L3 successful lstat {pair!r} {side}"
                rc, output, events = forced_snapshot(
                    row, box, snapshotter, roots, pair, side, errno.EACCES, 0,
                )
                identity[(pair, side)] = output
                exact_row_and_marker(row, box, rc, output, pair, side, "EACCES", events)

        # Literal path boundary: similar names and descendants are not protected pairs.
        negatives = (
            ("C", PAIRS[0][1] + ".unreviewed"),
            ("C", PAIRS[0][1] + "/unreviewed-child"),
        )
        for pair in negatives:
            path_for(box, pair).mkdir(parents=True, exist_ok=True)
            row = f"L4 unlisted/widened {pair!r}"
            rc, output, events = forced_snapshot(
                row, box, snapshotter, roots, pair, "BEFORE", errno.EACCES, errno.EACCES,
            )
            exact_incomplete(row, rc, output, pair, events, False, 2)

        # Errno boundary, including each direction of an approved/unapproved mix.
        errno_cases = (
            (errno.EIO, errno.EIO, False, 2),
            (errno.EACCES, errno.EIO, True, 2),
            (errno.EIO, errno.EPERM, False, 1),
        )
        for enumeration_error, identity_error, allow_marker, error_count in errno_cases:
            row = (f"L5 errno {errno.errorcode[identity_error]}-first/"
                   f"{errno.errorcode[enumeration_error]}-enumeration")
            rc, output, events = forced_snapshot(
                row, box, snapshotter, roots, PAIRS[0], "BEFORE", enumeration_error, identity_error,
            )
            exact_incomplete(row, rc, output, PAIRS[0], events, allow_marker, error_count)

        # Strict marker syntax on the lstat-first marker-only boundary.
        clean_before = box.tmp / "strict-before.tsv"
        clean_after = box.tmp / "strict-after.tsv"
        clean_marker_only(denied[(PAIRS[0], errno.EACCES, "BEFORE")], clean_before)
        clean_marker_only(denied[(PAIRS[0], errno.EACCES, "AFTER")], clean_after)
        for kind in ("duplicate", "noncanonical", "wrong-side"):
            corrupt = box.tmp / f"strict-{kind}.tsv"
            corrupt_marker(clean_after, corrupt, kind)
            expect_inconclusive(f"L6 {kind}", differ, clean_before, corrupt)

        # Reason, marker and identity availability are transition boundaries.
        reason_after = box.tmp / "reason-after.tsv"
        clean_marker_only(denied[(PAIRS[0], errno.EPERM, "AFTER")], reason_after)
        expect_inconclusive("L7 reason transition", differ, clean_before, reason_after)
        expect_inconclusive("L7 identity transition", differ, clean_before, identity[(PAIRS[0], "AFTER")])
        normal_after = box.tmp / "normal-after.tsv"
        normal = subprocess.run(
            [sys.executable, str(snapshotter), str(roots), str(normal_after), "AFTER"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if normal.returncode != 0 or normal.stdout or normal.stderr:
            bad("L7 normal control", f"unexpected result rc={normal.returncode} {normal.stdout!r} {normal.stderr!r}")
        expect_inconclusive("L7 marker transition", differ, clean_before, normal_after)
    finally:
        box.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print(f"FAIL\tmac-varfolders-lstat-first-protected\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-lstat-first-protected\tL1-L7")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
