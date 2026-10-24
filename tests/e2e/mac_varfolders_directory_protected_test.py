#!/usr/bin/env python3
"""RED, UNREGISTERED (SilverRidge 6806513a item A).

An EACCES/EPERM traversal failure at each exact reviewed C/P directory is
supplementary evidence: the embedded snapshotter must lstat the directory and
retain exactly one complete ordinary row (SHA/link ``-``), as well as exactly
one side-tagged SKIPPED-PROTECTED marker.  This drives both callback orders:
the traversal callback can arrive before an ordinary row exists, or after the
parent enumeration already recorded it.  Stable pairs are accepted; reason or
marker-presence transitions remain INCONCLUSIVE.  Broad paths and other errno
remain incomplete.

This file deliberately stays out of build.zig until the production green.
Run: python3 -X dev tests/e2e/mac_varfolders_directory_protected_test.py [helper]
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
PROTECTED = (
    ("C", "com.apple.WebKit.GPU.Sandbox"),
    ("C", "com.apple.WebKit.Networking.Sandbox"),
    ("C", "com.apple.WebKit.WebContent.Sandbox"),
    ("C", "com.apple.WorkflowKit.BackgroundShortcutRunner/ShortcutsSandboxCache"),
    ("C", "com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache"),
    ("C", "com.apple.siriactionsd/ShortcutsSandboxCache"),
    ("P", "0/com.apple.LaunchServices.dv"),
    ("P", "0/com.apple.ScreenTimeAgent/Store"),
    ("P", "0/com.apple.SharedWebCredentials"),
    ("P", "0/com.apple.exchangesync"),
    ("P", "0/com.apple.lockoutagent"),
    ("P", "0/com.apple.nsurlsessiond"),
    ("P", "0/com.apple.progressd/ClassKit"),
    ("P", "0/com.apple.routined/dv"),
    ("P", "0/dmd"),
)
failures: list[str] = []


def bad(message: str) -> None:
    failures.append(message)


def root_for(box: base.Box, token: str) -> Path:
    return box.C if token == "C" else box.user


def path_for(box: base.Box, pair: tuple[str, str]) -> Path:
    return root_for(box, pair[0]) / pair[1]


def marker(side: str, pair: tuple[str, str], reason: str) -> str:
    return f"SKIPPED-PROTECTED\t{side}\t{pair[0]}\t{pair[1]}\t{reason}"


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


def forced_snapshot(
    row: str,
    box: base.Box,
    snapshotter: Path,
    roots: Path,
    pair: tuple[str, str],
    side: str,
    error_number: int,
    callback_order: str,
    identity_error: int = 0,
) -> tuple[int, Path, tuple[int, int]]:
    """Run the real embedded source with one forced directory-enumeration error.

    ``missing`` models the released ordering: the walker reports the denied
    child without first returning it in its parent's directory list.
    ``existing`` denies scandir of the child after the parent returned it, so
    the repair must not duplicate the row already recorded by entry().
    """
    target = path_for(box, pair)
    pair_index = PROTECTED.index(pair) if pair in PROTECTED else "unlisted"
    identity_tag = "-identity" if identity_error else ""
    tag = f"{pair[0]}-{pair_index}-{side.lower()}-{errno.errorcode[error_number].lower()}-{callback_order}{identity_tag}"
    output = box.tmp / f"snapshot-{tag}.tsv"
    trace = box.tmp / f"trace-{tag}.txt"
    wrapper = box.tmp / f"wrapper-{tag}.py"
    wrapper.write_text(
        """import os, sys
error_number, identity_error = int(sys.argv[1]), int(sys.argv[2])
callback_order, source, roots, output, side, target, trace = sys.argv[3:]
real_lstat, real_scandir, real_walk = os.lstat, os.scandir, os.walk
target = os.path.normpath(target)
parent, basename = os.path.dirname(target), os.path.basename(target)
counts = {"lstat": 0, "enumerate": 0}
def same(path, wanted):
    return os.path.normpath(os.fsdecode(os.fspath(path))) == wanted
def lstat(path, *args, **kwargs):
    if same(path, target):
        counts["lstat"] += 1
        if identity_error:
            raise OSError(identity_error, os.strerror(identity_error), path)
    return real_lstat(path, *args, **kwargs)
def denied_scandir(path):
    if same(path, target):
        counts["enumerate"] += 1
        raise OSError(error_number, os.strerror(error_number), path)
    return real_scandir(path)
def missing_first_walk(top, topdown=True, onerror=None, followlinks=False):
    for dirpath, dirs, names in real_walk(top, topdown=topdown, onerror=onerror, followlinks=followlinks):
        if same(dirpath, parent) and basename in dirs:
            dirs.remove(basename)
            yield dirpath, dirs, names
            counts["enumerate"] += 1
            if onerror is not None:
                onerror(OSError(error_number, os.strerror(error_number), target))
        else:
            yield dirpath, dirs, names
os.lstat = lstat
if callback_order == "missing":
    os.walk = missing_first_walk
elif callback_order == "existing":
    os.scandir = denied_scandir
else:
    raise AssertionError(callback_order)
sys.argv = [source, roots, output, side]
try:
    exec(compile(open(source, encoding="utf-8").read(), source, "exec"), {"__name__": "__main__"})
finally:
    with open(trace, "w", encoding="utf-8") as stream:
        stream.write("%d %d\\n" % (counts["lstat"], counts["enumerate"]))
"""
    )
    result = subprocess.run(
        [sys.executable, str(wrapper), str(error_number), str(identity_error), callback_order, str(snapshotter), str(roots),
         str(output), side, str(target), str(trace)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stdout or result.stderr:
        bad(f"{row}: snapshotter must be silent, got stdout={result.stdout!r} stderr={result.stderr!r}")
    try:
        count_fields = trace.read_text().split()
        counts = (int(count_fields[0]), int(count_fields[1]))
        if len(count_fields) != 2:
            raise ValueError(count_fields)
    except (OSError, ValueError, IndexError) as error:
        bad(f"{row}: missing lstat/enumeration trace: {error}")
        counts = (0, 0)
    return result.returncode, output, counts


def normal_snapshot(snapshotter: Path, roots: Path, output: Path, side: str) -> int:
    result = subprocess.run(
        [sys.executable, str(snapshotter), str(roots), str(output), side],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    if result.stdout or result.stderr:
        bad(f"normal {side}: snapshotter must be silent, got stdout={result.stdout!r} stderr={result.stderr!r}")
    return result.returncode


def exact_complete_snapshot(
    row: str,
    output: Path,
    pair: tuple[str, str],
    side: str,
    reason: str,
    want_record: str,
    counts: tuple[int, int],
) -> None:
    try:
        lines = output.read_text().splitlines()
    except OSError as error:
        bad(f"{row}: cannot read snapshot: {error}")
        return
    ordinary: dict[tuple[str, str], list[str]] = {}
    for line in lines:
        fields = line.split("\t", 2)
        if len(fields) == 3 and fields[0] in ("C", "P", "T"):
            ordinary.setdefault((fields[0], fields[1]), []).append(fields[2])
    got_rows = ordinary.get(pair, [])
    if got_rows != [want_record]:
        bad(f"{row}: want one exact ordinary directory row, got {got_rows!r}")
    want_marker = marker(side, pair, reason)
    got_markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    if got_markers != [want_marker]:
        bad(f"{row}: want one exact marker {want_marker!r}, got {got_markers!r}")
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if errors:
        bad(f"{row}: exact protected traversal error must emit no ERROR row, got {errors!r}")
    want_end = f"END\t{sum(len(values) for values in ordinary.values()) + len(got_markers)}"
    ends = [line for line in lines if line.startswith("END\t")]
    if ends != [want_end] or lines[-1:] != [want_end]:
        bad(f"{row}: want one final exact {want_end!r}, got {ends!r} and tail {lines[-2:]!r}")
    if counts[0] < 1 or counts[1] != 1:
        bad(f"{row}: lstat must succeed and one enumeration must fail, got {counts!r}")


def exact_incomplete_snapshot(row: str, output: Path, pair: tuple[str, str]) -> None:
    lines = output.read_text().splitlines() if output.is_file() else []
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if markers or len(errors) != 1 or errors[0].split("\t")[:3] != ["ERROR", pair[0], pair[1]]:
        bad(f"{row}: non-exempt failure must have one exact-path ERROR and no marker, got {lines[-4:]!r}")
    if len([line for line in lines if line.startswith("END\t")]) != 1:
        bad(f"{row}: incomplete snapshot must still have one END record, got {lines[-4:]!r}")


def exact_unavailable_identity(
    row: str,
    output: Path,
    pair: tuple[str, str],
    side: str,
    counts: tuple[int, int],
) -> None:
    lines = output.read_text().splitlines() if output.is_file() else []
    ordinary = [line for line in lines if line.startswith(f"{pair[0]}\t{pair[1]}\t")]
    markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    errors = [line for line in lines if line.startswith("ERROR\t")]
    want_marker = marker(side, pair, "EACCES")
    if ordinary or markers != [want_marker] or len(errors) != 1 \
            or errors[0].split("\t")[:3] != ["ERROR", pair[0], pair[1]]:
        bad(f"{row}: unavailable lstat identity must be incomplete with one marker/error and no row, got {lines[-5:]!r}")
    if counts != (1, 1):
        bad(f"{row}: wanted one failed lstat after one traversal error, got {counts!r}")
    if len([line for line in lines if line.startswith("END\t")]) != 1:
        bad(f"{row}: unavailable-identity snapshot must retain one END record, got {lines[-4:]!r}")


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


def expect_transition(row: str, differ: Path, before: Path, after: Path) -> None:
    rc, out = run_diff(row, differ, before, after)
    want = ["VARFOLDERS\tINCONCLUSIVE\tthe protected-skip set changed during the run"]
    if rc != 2 or out != want:
        bad(f"{row}: transition must fail closed as {want!r}, got rc={rc} {out!r}")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures = []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]

    box = base.Box(helper)
    try:
        for pair in PROTECTED:
            path_for(box, pair).mkdir(parents=True, exist_ok=True)
        roots = box.tmp / "roots.tsv"
        roots.write_text(f"T\t{box.T}\nC\t{box.C}\nP\t{box.user}\n")
        snapshotter = extract("A0", box, helper, "__VF_SNAPSHOT_PY", "snapshot.py")
        differ = extract("A0", box, helper, "__VF_DIFF_PY", "diff.py")
        if snapshotter is None or differ is None:
            return list(failures)

        normal: dict[str, Path] = {}
        for side in ("BEFORE", "AFTER"):
            output = box.tmp / f"normal-{side.lower()}.tsv"
            rc = normal_snapshot(snapshotter, roots, output, side)
            if rc != 0:
                bad(f"A0 normal {side}: readable fixture must snapshot completely, got rc={rc}")
            normal[side] = output

        outputs: dict[tuple[tuple[str, str], str, int, str], Path] = {}
        for pair in PROTECTED:
            want_record = base.record(path_for(box, pair))
            fields = want_record.split(" ")
            if len(fields) != 11 or fields[0] != "d" or fields[9:] != ["-", "-"]:
                bad(f"A0 {pair!r}: fixture is not an exact directory SHA/link '-' record: {want_record!r}")
            for callback_order in ("missing", "existing"):
                for error_number in (errno.EACCES, errno.EPERM):
                    reason = errno.errorcode[error_number]
                    for side in ("BEFORE", "AFTER"):
                        row = f"A1 {pair[0]}/{pair[1]} {callback_order} {side} {reason}"
                        rc, output, counts = forced_snapshot(
                            row, box, snapshotter, roots, pair, side, error_number, callback_order,
                        )
                        outputs[(pair, callback_order, error_number, side)] = output
                        if rc != 0:
                            bad(f"{row}: exact protected directory error must leave a complete snapshot, rc={rc}")
                        if output.is_file():
                            exact_complete_snapshot(row, output, pair, side, reason, want_record, counts)
                        else:
                            bad(f"{row}: success did not write a snapshot")

                    before = outputs[(pair, callback_order, error_number, "BEFORE")]
                    after = outputs[(pair, callback_order, error_number, "AFTER")]
                    row = f"A2 stable {pair!r} {callback_order} {reason}"
                    rc, out = run_diff(row, differ, before, after)
                    want = [marker("BEFORE", pair, reason), marker("AFTER", pair, reason),
                            "VARFOLDERS\tCOMPLETE\t0"]
                    if rc != 0 or out != want:
                        bad(f"{row}: want exact stable acceptance {want!r}, got rc={rc} {out!r}")

                expect_transition(
                    f"A3 reason transition {pair!r} {callback_order}", differ,
                    outputs[(pair, callback_order, errno.EACCES, "BEFORE")],
                    outputs[(pair, callback_order, errno.EPERM, "AFTER")],
                )
                expect_transition(
                    f"A3 marker removed {pair!r} {callback_order}", differ,
                    outputs[(pair, callback_order, errno.EACCES, "BEFORE")], normal["AFTER"],
                )
                expect_transition(
                    f"A3 marker added {pair!r} {callback_order}", differ, normal["BEFORE"],
                    outputs[(pair, callback_order, errno.EACCES, "AFTER")],
                )

        # A4: a path outside the literal policy and an errno outside EACCES/EPERM remain incomplete.
        negatives = (("C", "com.apple.WebKit.GPU.Sandbox.unreviewed"), PROTECTED[0])
        for pair, error_number in ((negatives[0], errno.EACCES), (negatives[1], errno.EIO)):
            path_for(box, pair).mkdir(parents=True, exist_ok=True)
            for callback_order in ("missing", "existing"):
                for side in ("BEFORE", "AFTER"):
                    row = f"A4 non-exempt {pair!r} {errno.errorcode[error_number]} {callback_order} {side}"
                    rc, output, counts = forced_snapshot(
                        row, box, snapshotter, roots, pair, side, error_number, callback_order,
                    )
                    if rc != 3:
                        bad(f"{row}: non-exempt traversal error must make the snapshot incomplete, got rc={rc}")
                    exact_incomplete_snapshot(row, output, pair)
                    if counts[1] != 1:
                        bad(f"{row}: the negative control did not drive one enumeration error: {counts!r}")

        # A5: even an exact protected traversal error cannot excuse an unavailable lstat identity.
        for pair in (PROTECTED[0], next(item for item in PROTECTED if item[0] == "P")):
            for side in ("BEFORE", "AFTER"):
                row = f"A5 unavailable identity {pair!r} {side}"
                rc, output, counts = forced_snapshot(
                    row, box, snapshotter, roots, pair, side, errno.EACCES, "missing", errno.EACCES,
                )
                if rc != 3:
                    bad(f"{row}: unavailable identity must make the snapshot incomplete, got rc={rc}")
                exact_unavailable_identity(row, output, pair, side, counts)
    finally:
        box.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\tmac-varfolders-directory-protected\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-directory-protected\tA1-A5")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
