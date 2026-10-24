#!/usr/bin/env python3
"""RED, UNREGISTERED (owner decision 2026-10-24): the shared /var/folders audit may treat only the reviewed
macOS-protected paths in the per-user parent census as unreadable. Every accepted skip is evidence:

    SKIPPED-PROTECTED<TAB>P<TAB><exact relative path><TAB><nonempty permission reason>

The list is the nine unique P paths behind the Intel MS1c run's 18 duplicate Operation-not-permitted records at
`b0409175`. A listed path is skipped only for EACCES/EPERM while it is unreadable and only under token P. A readable
listed path is audited normally. A suffix, descendant, another root token, or any unlisted unreadable path remains an
incomplete snapshot and therefore INCONCLUSIVE. The before/after protected-skip sets must match; a transition is
INCONCLUSIVE. The markers are unique, ordered, retained in both snapshots and printed by varfolders_end.

Run directly from a clean archive as a non-root user; do not register this red in build.zig.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as base  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
PROTECTED = (
    "0/com.apple.LaunchServices.dv",
    "0/com.apple.ScreenTimeAgent/Store",
    "0/com.apple.SharedWebCredentials",
    "0/com.apple.exchangesync",
    "0/com.apple.lockoutagent",
    "0/com.apple.nsurlsessiond",
    "0/com.apple.progressd/ClassKit",
    "0/com.apple.routined/dv",
    "0/dmd",
)
failures: list[str] = []


def bad(message: str) -> None:
    failures.append(message)


def locked(root: Path, rel: str) -> Path:
    path = root / rel
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0)
    return path


def marker_fields(row: str, line: str) -> tuple[str, str] | None:
    fields = line.split("\t")
    if len(fields) != 4 or fields[:2] != ["SKIPPED-PROTECTED", "P"] or not fields[2] or not fields[3].strip():
        bad(f"{row}: malformed protected-skip marker {line!r}")
        return None
    return fields[2], fields[3]


def exact_markers(row: str, lines: list[str], expected: tuple[str, ...] = PROTECTED) -> None:
    parsed = [marker_fields(row, line) for line in lines]
    paths = [item[0] for item in parsed if item is not None]
    want = sorted(expected, key=os.fsencode)
    if paths != want:
        bad(f"{row}: want each reviewed path once in byte order {want!r}, got {paths!r}")


def snapshot_markers(row: str, path: Path, expected: tuple[str, ...] = PROTECTED) -> None:
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        bad(f"{row}: cannot read snapshot {path}: {error}")
        return
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if errors:
        bad(f"{row}: accepted protected paths must leave no ERROR rows, got {errors!r}")
    exact_markers(row, [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")], expected)


def duplicate_walk_error(row: str, box: base.Box, helper: Path) -> None:
    """Run the embedded snapshotter with os.walk delivering the same permission error twice, matching the Intel
    evidence shape. The snapshot must contain one de-duplicated marker and remain complete."""
    source = box.tmp / "snapshot.py"
    extracted = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$__VF_SNAPSHOT_PY"', "_", str(helper)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if extracted.returncode != 0 or not extracted.stdout:
        bad(f"{row}: cannot extract the shared snapshotter: rc={extracted.returncode} {extracted.stderr!r}")
        return
    source.write_bytes(extracted.stdout)
    roots = box.tmp / "roots"
    roots.write_text(f"T\t{box.T}\nC\t{box.C}\nP\t{box.user}\n")
    output = box.tmp / "snapshot.tsv"
    wrapper = box.tmp / "double-onerror.py"
    wrapper.write_text("""import os, sys
real_walk = os.walk
def walk(top, topdown=True, onerror=None, followlinks=False):
    def twice(error):
        onerror(error)
        onerror(error)
    return real_walk(top, topdown=topdown, onerror=twice if onerror else None, followlinks=followlinks)
os.walk = walk
source, roots, output = sys.argv[1:]
sys.argv = [source, roots, output]
exec(compile(open(source, encoding="utf-8").read(), source, "exec"), {"__name__": "__main__"})
""")
    result = subprocess.run([sys.executable, str(wrapper), str(source), str(roots), str(output)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode != 0:
        bad(f"{row}: duplicate permission observations must remain a complete snapshot, got rc={result.returncode} "
            f"stderr={result.stderr.decode(errors='replace')!r}")
        return
    snapshot_markers(row, output, (PROTECTED[0],))


def expect_refused(row: str, box: base.Box) -> None:
    rc, out = box.call("varfolders_begin")
    fields = out[0].split("\t") if len(out) == 1 else []
    if rc != 2 or len(fields) != 3 or fields[:2] != ["VARFOLDERS", "INCONCLUSIVE"] or not fields[2].strip():
        bad(f"{row}: unreviewed unreadability must refuse with one INCONCLUSIVE line, got rc={rc} {out!r}")


def expect_inconclusive_end(row: str, box: base.Box) -> None:
    rc, out = box.call("varfolders_end")
    if rc != 2 or not out or out[-1].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"]:
        bad(f"{row}: a changed protected-skip boundary must be INCONCLUSIVE, got rc={rc} {out!r}")
    if any(line.startswith("VARFOLDERS\tCOMPLETE\t") for line in out):
        bad(f"{row}: a changed protected-skip boundary must never be COMPLETE: {out!r}")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    base.failures, base.hits = [], []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    if not sys.platform.startswith("linux"):
        return ["R0 this hostless red uses Linux permission and inotify behavior"]
    if os.geteuid() == 0:
        return ["R0 run as a non-root user so mode-000 directories are unreadable"]

    box = base.Box(helper)
    try:  # R1: the complete exact list is the only accepted unreadable P set, and every skip is reported evidence.
        for rel in PROTECTED:
            locked(box.user, rel)
        rc, out = box.call("varfolders_begin")
        if rc != 0 or out:
            bad(f"R1 exact protected P paths: begin must be silent and pass, got rc={rc} {out!r}")
        else:
            snapshot_markers("R1 before", box.ev / "varfolders-before.tsv")
            rc, out = box.call("varfolders_end")
            head = base.roots_line(box)
            if out[:2] != head or rc != 0 or not out or out[-1] != "VARFOLDERS\tCOMPLETE\t0":
                bad(f"R1 exact protected P paths: want headers, markers, COMPLETE 0; got rc={rc} {out!r}")
            else:
                middle = out[2:-1]
                if any(line.startswith("VARFOLDERS-DELTA\t") for line in middle):
                    bad(f"R1 exact protected P paths: unchanged skips are not deltas: {middle!r}")
                exact_markers("R1 end output", middle)
                snapshot_markers("R1 after", box.ev / "varfolders-after.tsv")
    finally:
        box.close()

    box = base.Box(helper)
    try:  # R1b: the real Intel walk reported each protected P path twice; evidence remains one marker per path.
        locked(box.user, PROTECTED[0])
        duplicate_walk_error("R1b duplicate permission observations", box, helper)
    finally:
        box.close()

    # R2-R4: every dimension is exact. These field-isolated near misses must remain fail closed.
    for rel in PROTECTED:
        box = base.Box(helper)
        try:
            locked(box.user, rel + ".unreviewed")
            expect_refused(f"R2 suffix is not reviewed ({rel})", box)
        finally:
            box.close()
        box = base.Box(helper)
        try:
            locked(box.user / "C", rel)
            expect_refused(f"R3 token C is not parent P ({rel})", box)
        finally:
            box.close()
        box = base.Box(helper)
        try:
            locked(box.user / "T", rel)
            expect_refused(f"R3 token T is not parent P ({rel})", box)
        finally:
            box.close()
        box = base.Box(helper)
        try:
            locked(box.user, rel + "/unreviewed-child")
            expect_refused(f"R4 a descendant is not the reviewed path ({rel})", box)
        finally:
            box.close()

    box = base.Box(helper)
    try:  # R5: listed paths are not blind exclusions; when readable, their contents remain in the P census.
        for rel in PROTECTED:
            path = box.user / rel
            path.mkdir(parents=True, exist_ok=True)
            (path / "audited.txt").write_text("before\n")
        rc, out = box.call("varfolders_begin")
        if rc != 0 or out:
            bad(f"R5 readable reviewed paths: begin must pass normally, got rc={rc} {out!r}")
        else:
            before = (box.ev / "varfolders-before.tsv").read_text().splitlines()
            if any(line.startswith("SKIPPED-PROTECTED\t") for line in before):
                bad("R5 readable reviewed paths must be recorded, not skipped")
            target = box.user / PROTECTED[0] / "audited.txt"
            target.write_text("after\n")
            rc, out = box.call("varfolders_end")
            if rc != 2 or not out or out[-1].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"]:
                bad(f"R5 a readable protected path's P change must be reported and INCONCLUSIVE, got rc={rc} {out!r}")
            if not any(line.startswith(f"VARFOLDERS-DELTA\tchanged\tP\t{PROTECTED[0]}/audited.txt\t") for line in out):
                bad(f"R5 the readable reviewed path's changed file is absent from the P deltas: {out!r}")
            if any(line.startswith("SKIPPED-PROTECTED\t") for line in out):
                bad(f"R5 readable reviewed paths must emit no protected-skip marker: {out!r}")
    finally:
        box.close()

    for direction in ("unreadable-to-readable", "readable-to-unreadable"):
        box = base.Box(helper)
        try:  # R6: the before and after protected-skip sets must agree; otherwise the census is incomplete.
            path = box.user / PROTECTED[0]
            path.mkdir(parents=True, exist_ok=True)
            if direction == "unreadable-to-readable":
                path.chmod(0)
            rc, out = box.call("varfolders_begin")
            if rc != 0 or out:
                bad(f"R6 {direction}: begin must pass at its initial boundary, got rc={rc} {out!r}")
            else:
                path.chmod(0o700 if direction == "unreadable-to-readable" else 0)
                expect_inconclusive_end(f"R6 {direction}", box)
        finally:
            box.close()

    if base.hits:
        bad(f"R7 helper changed the audited tree: {base.hits[:6]!r}")
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        print(f"FAIL\tmac-varfolders-protected-paths\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-protected-paths\tR1-R7")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
