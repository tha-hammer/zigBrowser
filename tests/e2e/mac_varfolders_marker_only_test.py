#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge fac0064b item 1).

The released Intel evidence showed an exact reviewed C/P directory for which
both enumeration and the follow-up lstat failed with EACCES/EPERM.  Such an
observation has no identity to invent: each snapshot side must retain exactly
one side-tagged marker, no ordinary row and no ERROR.  Stable marker-only
observations are consumable; reason, marker-set, side or identity-availability
transitions remain INCONCLUSIVE.  The existing lstat-success case still keeps
one complete directory row plus its marker.  Literal-policy and evidence-codec
boundaries remain fail closed.

This file must remain absent from build.zig until the production green.
Run: python3 -X dev tests/e2e/mac_varfolders_marker_only_test.py [helper]
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
    ("P", "0/com.apple.LaunchServices.dv"),
)
failures: list[str] = []


def bad(row: str, why: str) -> None:
    failures.append(f"{row}: {why}")


def root_for(box: base.Box, token: str) -> Path:
    return box.C if token == "C" else box.user


def path_for(box: base.Box, pair: tuple[str, str]) -> Path:
    return root_for(box, pair[0]) / pair[1]


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
    repeats: int = 2,
) -> tuple[int, Path, tuple[int, int]]:
    """Hide the target from its parent, then deliver repeated walk errors.

    When identity_error is nonzero, every callback's follow-up lstat fails too,
    matching the retained Intel shape.  With identity_error zero, this is the
    existing row-plus-marker control.
    """
    target = path_for(box, pair)
    tag = f"{pair[0]}-{side.lower()}-{enumeration_error}-{identity_error}-{repeats}"
    output = box.tmp / f"snapshot-{tag}.tsv"
    trace = box.tmp / f"trace-{tag}.txt"
    wrapper = box.tmp / f"wrapper-{tag}.py"
    wrapper.write_text(
        """import os, sys
enumeration_error, identity_error, repeats = map(int, sys.argv[1:4])
source, roots, output, side, target, trace = sys.argv[4:]
real_lstat, real_walk = os.lstat, os.walk
target = os.path.normpath(os.fsencode(target))
parent, basename = os.path.dirname(target), os.path.basename(target)
counts = {"lstat": 0, "enumerate": 0}
def same(path, wanted):
    return os.path.normpath(os.fsencode(os.fspath(path))) == wanted
def lstat(path, *args, **kwargs):
    if same(path, target):
        counts["lstat"] += 1
        if identity_error:
            raise OSError(identity_error, os.strerror(identity_error), path)
    return real_lstat(path, *args, **kwargs)
def walk(top, topdown=True, onerror=None, followlinks=False):
    for dirpath, dirs, names in real_walk(top, topdown=topdown, onerror=onerror, followlinks=followlinks):
        if same(dirpath, parent) and basename in dirs:
            dirs.remove(basename)
            yield dirpath, dirs, names
            for _ in range(repeats):
                counts["enumerate"] += 1
                if onerror is not None:
                    onerror(OSError(enumeration_error, os.strerror(enumeration_error), target))
        else:
            yield dirpath, dirs, names
os.lstat, os.walk = lstat, walk
sys.argv = [source, roots, output, side]
try:
    with open(source, encoding="utf-8") as stream:
        code = compile(stream.read(), source, "exec")
    exec(code, {"__name__": "__main__"})
finally:
    with open(trace, "w", encoding="ascii") as stream:
        stream.write("%d %d\\n" % (counts["lstat"], counts["enumerate"]))
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        [sys.executable, str(wrapper), str(enumeration_error), str(identity_error), str(repeats),
         str(snapshotter), str(roots), str(output), side, str(target), str(trace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stdout or result.stderr:
        bad(row, f"snapshotter must be silent, got stdout={result.stdout!r} stderr={result.stderr!r}")
    try:
        fields = trace.read_text(encoding="ascii").split()
        counts = (int(fields[0]), int(fields[1]))
        if len(fields) != 2:
            raise ValueError(fields)
    except (OSError, ValueError, IndexError) as error:
        bad(row, f"missing lstat/enumeration trace: {error}")
        counts = (0, 0)
    return result.returncode, output, counts


def read_lines(row: str, output: Path) -> list[str]:
    try:
        return output.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        bad(row, f"cannot read canonical snapshot: {error}")
        return []


def ordinary_rows(row: str, lines: list[str]) -> dict[tuple[str, str], list[str]]:
    ordinary: dict[tuple[str, str], list[str]] = {}
    for line in lines:
        fields = line.split("\t", 2)
        if len(fields) != 3 or fields[0] not in ("T", "C", "P"):
            continue
        try:
            rel = os.fsdecode(base.decode_field(fields[1]))
        except ValueError as error:
            bad(row, f"malformed ordinary path {line!r}: {error}")
            continue
        ordinary.setdefault((fields[0], rel), []).append(fields[2])
    return ordinary


def exact_marker_only(
    row: str,
    output: Path,
    pair: tuple[str, str],
    side: str,
    reason: str,
    counts: tuple[int, int],
) -> None:
    lines = read_lines(row, output)
    ordinary = ordinary_rows(row, lines)
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if ordinary.get(pair):
        bad(row, f"lstat-denied path must have no invented/reused identity, got {ordinary[pair]!r}")
    if markers != [marker(side, pair, reason)]:
        bad(row, f"want one deduplicated side-tagged marker, got {markers!r}")
    if errors:
        bad(row, f"accepted marker-only observation must have no ERROR, got {errors!r}")
    want_end = f"END\t{sum(len(values) for values in ordinary.values()) + len(markers)}"
    ends = [line for line in lines if line.startswith("END\t")]
    if ends != [want_end] or lines[-1:] != [want_end]:
        bad(row, f"want one final {want_end!r}, got ends={ends!r} tail={lines[-3:]!r}")
    if counts[0] < 1 or counts[1] != 2:
        bad(row, f"did not drive repeated enumeration plus failed lstat, got {counts!r}")


def exact_row_and_marker(
    row: str,
    box: base.Box,
    output: Path,
    pair: tuple[str, str],
    side: str,
    reason: str,
    counts: tuple[int, int],
) -> None:
    lines = read_lines(row, output)
    ordinary = ordinary_rows(row, lines)
    got = ordinary.get(pair, [])
    want = base.record(path_for(box, pair))
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if got != [want] or markers != [marker(side, pair, reason)] or errors:
        bad(row, f"lstat-success control wants one row plus one marker and no ERROR, "
            f"got row={got!r} markers={markers!r} errors={errors!r}")
    if counts[0] < 1 or counts[1] != 2:
        bad(row, f"control did not drive repeated enumeration and successful lstat, got {counts!r}")


def exact_non_exempt(row: str, output: Path, pair: tuple[str, str], counts: tuple[int, int]) -> None:
    lines = read_lines(row, output)
    ordinary = ordinary_rows(row, lines)
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    target = f"{pair[0]}\t{base.evidence_field(pair[1])}\t"
    if markers or not errors or not all(line.startswith("ERROR\t" + target) for line in errors) \
            or ordinary.get(pair):
        bad(row, f"non-exempt failure must stay incomplete with exact-path ERROR(s), no marker/identity; "
            f"got markers={markers!r} errors={errors!r} row={ordinary.get(pair)!r}")
    if counts[1] != 2:
        bad(row, f"negative did not drive repeated enumeration, got {counts!r}")


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


def expect_inconclusive(row: str, differ: Path, before: Path, after: Path) -> None:
    rc, out = run_diff(row, differ, before, after)
    if rc != 2 or not out or out[-1].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"] \
            or any(line.startswith(("VARFOLDERS-DELTA\t", "VARFOLDERS\tCOMPLETE\t")) for line in out):
        bad(row, f"transition/malformed evidence must be INCONCLUSIVE with no partial delta, got rc={rc} {out!r}")


def corrupt_marker(source: Path, output: Path, kind: str) -> None:
    lines = source.read_text(encoding="ascii").splitlines()
    index = next(i for i, line in enumerate(lines) if line.startswith("SKIPPED-PROTECTED\t"))
    fields = lines[index].split("\t")
    if kind == "duplicate":
        lines.insert(index + 1, lines[index])
        end = lines[-1].split("\t")
        lines[-1] = f"END\t{int(end[1]) + 1}"
    elif kind == "noncanonical":
        fields[3] = "bad:" + fields[3][4:]
        lines[index] = "\t".join(fields)
    elif kind == "wrong-side":
        fields[1] = "BEFORE" if fields[1] == "AFTER" else "AFTER"
        lines[index] = "\t".join(fields)
    else:
        raise AssertionError(kind)
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures, base.hits = [], []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]

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
        snapshotter = extract("M0", box, helper, "__VF_SNAPSHOT_PY", "snapshot.py")
        differ = extract("M0", box, helper, "__VF_DIFF_PY", "diff.py")
        if snapshotter is None or differ is None:
            return list(failures)

        marker_only: dict[tuple[tuple[str, str], int, str], Path] = {}
        identity: dict[tuple[tuple[str, str], str], Path] = {}
        for pair in PAIRS:
            for error_number in (errno.EACCES, errno.EPERM):
                reason = errno.errorcode[error_number]
                for side in ("BEFORE", "AFTER"):
                    row = f"M1 {pair[0]}/{pair[1]} {side} {reason} marker-only"
                    rc, output, counts = forced_snapshot(
                        row, box, snapshotter, roots, pair, side, error_number, error_number,
                    )
                    marker_only[(pair, error_number, side)] = output
                    if rc != 0:
                        bad(row, f"exact protected double denial must remain complete, got rc={rc}")
                    exact_marker_only(row, output, pair, side, reason, counts)

                row = f"M2 stable {pair!r} {reason}"
                before = marker_only[(pair, error_number, "BEFORE")]
                after = marker_only[(pair, error_number, "AFTER")]
                rc, out = run_diff(row, differ, before, after)
                want = [marker("BEFORE", pair, reason), marker("AFTER", pair, reason),
                        "VARFOLDERS\tCOMPLETE\t0"]
                if rc != 0 or out != want:
                    bad(row, f"stable marker-only observations must be consumable as {want!r}, got rc={rc} {out!r}")

            for side in ("BEFORE", "AFTER"):
                row = f"M4 lstat-success {pair!r} {side}"
                rc, output, counts = forced_snapshot(
                    row, box, snapshotter, roots, pair, side, errno.EACCES, 0,
                )
                identity[(pair, side)] = output
                if rc != 0:
                    bad(row, f"lstat-success control must remain complete, got rc={rc}")
                exact_row_and_marker(row, box, output, pair, side, "EACCES", counts)

        # M3: reason, marker set, identity availability and encoded side are all transition boundaries.
        expect_inconclusive(
            "M3 reason transition", differ,
            marker_only[(PAIRS[0], errno.EACCES, "BEFORE")],
            marker_only[(PAIRS[0], errno.EPERM, "AFTER")],
        )
        expect_inconclusive(
            "M3 marker-set transition", differ,
            marker_only[(PAIRS[0], errno.EACCES, "BEFORE")],
            marker_only[(PAIRS[1], errno.EACCES, "AFTER")],
        )
        expect_inconclusive(
            "M3 identity-availability transition", differ,
            marker_only[(PAIRS[0], errno.EACCES, "BEFORE")], identity[(PAIRS[0], "AFTER")],
        )

        # M5: literal policy, errno and descendant boundaries never become marker-only exemptions.
        negatives = (
            (("C", PAIRS[0][1] + ".unreviewed"), errno.EACCES),
            (("C", PAIRS[0][1] + "/unreviewed-child"), errno.EACCES),
            (PAIRS[0], errno.EIO),
        )
        for pair, error_number in negatives:
            path_for(box, pair).mkdir(parents=True, exist_ok=True)
            row = f"M5 non-exempt {pair!r} {errno.errorcode[error_number]}"
            rc, output, counts = forced_snapshot(
                row, box, snapshotter, roots, pair, "BEFORE", error_number, error_number,
            )
            if rc != 3:
                bad(row, f"non-exempt double denial must be incomplete, got rc={rc}")
            exact_non_exempt(row, output, pair, counts)

        # M6: duplicate, noncanonical and wrong-side markers are never consumed as stable evidence.
        clean_before = identity[(PAIRS[0], "BEFORE")]
        clean_after = identity[(PAIRS[0], "AFTER")]
        for kind in ("duplicate", "noncanonical", "wrong-side"):
            corrupt = box.tmp / f"corrupt-{kind}.tsv"
            corrupt_marker(clean_after, corrupt, kind)
            expect_inconclusive(f"M6 {kind}", differ, clean_before, corrupt)
    finally:
        box.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print("FAIL " + problem)
    if problems:
        print(f"FAIL\tmac-varfolders-marker-only\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-marker-only\tM1-M6")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
