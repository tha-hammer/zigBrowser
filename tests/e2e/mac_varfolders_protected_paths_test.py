#!/usr/bin/env python3
"""GREEN, REGISTERED (owner decision 2026-10-24; SilverRidge 93228b3a): the shared /var/folders
audit may treat only the 15 evidence-derived exact (token, relative-path) pairs below as permission-protected.

An accepted observation is deterministic evidence:

    SKIPPED-PROTECTED<TAB><BEFORE|AFTER><TAB><C|P><TAB><exact path><TAB><EACCES|EPERM>

Both snapshot sides are printed by varfolders_end. The protected directory's ordinary lstat row remains in the
snapshot, so metadata changes while its contents stay unreadable remain full deltas. Only EACCES/EPERM at an exact
pair is exempt; another errno, another token, a parent/child/sibling/suffix/one-character variant, an unrecordable
descendant name, or any other unreadable path remains INCONCLUSIVE. A readable listed path is audited normally, and a
before/after skip-boundary transition is never COMPLETE.

This file remains absent from build.zig until the green. Run directly from a clean archive as a non-root user.
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


def pair_key(pair: tuple[str, str]) -> tuple[str, bytes]:
    return pair[0], os.fsencode(pair[1])


def root_for(box: base.Box, token: str) -> Path:
    return box.C if token == "C" else box.T if token == "T" else box.user


def path_for(box: base.Box, pair: tuple[str, str]) -> Path:
    return root_for(box, pair[0]) / pair[1]


def locked(box: base.Box, pair: tuple[str, str]) -> Path:
    path = path_for(box, pair)
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0)
    return path


def marker(side: str, pair: tuple[str, str], reason: str) -> str:
    return f"SKIPPED-PROTECTED\t{side}\t{pair[0]}\t{pair[1]}\t{reason}"


def marker_fields(row: str, line: str) -> tuple[str, str, str, str] | None:
    fields = line.split("\t")
    if len(fields) != 5 or fields[0] != "SKIPPED-PROTECTED" or fields[1] not in ("BEFORE", "AFTER") \
            or fields[2] not in ("C", "P") or not fields[3] or fields[4] not in ("EACCES", "EPERM"):
        bad(f"{row}: malformed protected-skip marker {line!r}")
        return None
    return fields[1], fields[2], fields[3], fields[4]


def exact_markers(row: str, lines: list[str], side: str, expected: tuple[tuple[str, str], ...] = PROTECTED,
                  reason: str = "EACCES") -> None:
    parsed = [marker_fields(row, line) for line in lines]
    got = [(item[1], item[2]) for item in parsed if item is not None]
    want = sorted(expected, key=pair_key)
    if got != want:
        bad(f"{row}: want each exact pair once in byte order {want!r}, got {got!r}")
    for item in parsed:
        if item is not None and (item[0] != side or item[3] != reason):
            bad(f"{row}: want side/reason {side}/{reason}, got {item!r}")


def snapshot_rows(path: Path) -> list[str]:
    return path.read_text().splitlines()


def exact_snapshot(row: str, box: base.Box, path: Path, side: str,
                   expected: tuple[tuple[str, str], ...] = PROTECTED, reason: str = "EACCES") -> None:
    try:
        lines = snapshot_rows(path)
    except OSError as error:
        bad(f"{row}: cannot read snapshot {path}: {error}")
        return
    errors = [line for line in lines if line.startswith("ERROR\t")]
    if errors:
        bad(f"{row}: accepted protected pairs must leave no ERROR rows, got {errors!r}")
    marker_lines = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
    exact_markers(row, marker_lines, side, expected, reason)
    ordinary: dict[tuple[str, str], list[str]] = {}
    for line in lines:
        fields = line.split("\t", 2)
        if len(fields) == 3 and fields[0] in ("C", "P", "T"):
            ordinary.setdefault((fields[0], fields[1]), []).append(fields[2])
    for pair in expected:
        want = base.record(path_for(box, pair))
        got = ordinary.get(pair, [])
        if got != [want]:
            bad(f"{row}: protected {pair!r} must retain its one exact lstat row {want!r}, got {got!r}")
    want_end = f"END\t{sum(len(values) for values in ordinary.values()) + len(marker_lines)}"
    if lines[-1:] != [want_end] or sum(line.startswith("END\t") for line in lines) != 1:
        bad(f"{row}: complete snapshot must end once with {want_end!r}, got {lines[-3:]!r}")


def expect_refused(row: str, box: base.Box) -> None:
    rc, out = box.call("varfolders_begin")
    fields = out[0].split("\t") if len(out) == 1 else []
    if rc != 2 or len(fields) != 3 or fields[:2] != ["VARFOLDERS", "INCONCLUSIVE"] or not fields[2].strip():
        bad(f"{row}: non-exempt error must refuse with one INCONCLUSIVE line, got rc={rc} {out!r}")


def expect_inconclusive_end(row: str, box: base.Box) -> None:
    rc, out = box.call("varfolders_end")
    if rc != 2 or not out or out[-1].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"]:
        bad(f"{row}: changed skip boundary must be INCONCLUSIVE, got rc={rc} {out!r}")
    if any(line.startswith("VARFOLDERS\tCOMPLETE\t") for line in out):
        bad(f"{row}: changed skip boundary must never be COMPLETE: {out!r}")


def extract_snapshotter(row: str, box: base.Box, helper: Path) -> Path | None:
    source = box.tmp / "snapshot.py"
    result = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$__VF_SNAPSHOT_PY"', "_", str(helper)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode != 0 or not result.stdout:
        bad(f"{row}: cannot extract shared snapshotter: rc={result.returncode} {result.stderr!r}")
        return None
    source.write_bytes(result.stdout)
    return source


def forced_snapshot(row: str, box: base.Box, helper: Path, side: str, pair: tuple[str, str], error_number: int,
                    repeats: int) -> tuple[int, Path] | None:
    """Execute the embedded snapshotter with os.walk delivering a selected errno, optionally twice like the Mac."""
    if side not in ("BEFORE", "AFTER"):
        raise ValueError(f"invalid snapshot side {side!r}")
    source = extract_snapshotter(row, box, helper)
    if source is None:
        return None
    roots = box.tmp / "roots"
    roots.write_text(f"T\t{box.T}\nC\t{box.C}\nP\t{box.user}\n")
    output = box.tmp / f"forced-snapshot-{side.lower()}.tsv"
    wrapper = box.tmp / "forced-onerror.py"
    wrapper.write_text("""import os, sys
real_walk = os.walk
error_number, repeats, side = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
def walk(top, topdown=True, onerror=None, followlinks=False):
    def forced(error):
        replacement = OSError(error_number, os.strerror(error_number), error.filename)
        for _ in range(repeats):
            onerror(replacement)
    return real_walk(top, topdown=topdown, onerror=forced if onerror else None, followlinks=followlinks)
os.walk = walk
source, roots, output = sys.argv[4:]
sys.argv = [source, roots, output, side]
exec(compile(open(source, encoding="utf-8").read(), source, "exec"), {"__name__": "__main__"})
""")
    result = subprocess.run([sys.executable, str(wrapper), str(error_number), str(repeats), side, str(source),
                             str(roots), str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.stderr:
        bad(f"{row}: forced snapshot wrote stderr {result.stderr.decode(errors='replace')!r}")
    return result.returncode, output


def mutated(rel: str) -> str:
    return rel[:-1] + ("x" if rel[-1] != "x" else "y")


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
    try:  # R1: all 15 exact EACCES pairs, both sides, one marker and retained metadata each.
        for pair in PROTECTED:
            locked(box, pair)
        rc, out = box.call("varfolders_begin")
        if rc != 0 or out:
            bad(f"R1 exact protected pairs: begin must be silent and pass, got rc={rc} {out!r}")
        else:
            exact_snapshot("R1 BEFORE", box, box.ev / "varfolders-before.tsv", "BEFORE")
            rc, out = box.call("varfolders_end")
            before = [marker("BEFORE", pair, "EACCES") for pair in sorted(PROTECTED, key=pair_key)]
            after = [marker("AFTER", pair, "EACCES") for pair in sorted(PROTECTED, key=pair_key)]
            want = base.roots_line(box) + before + after + ["VARFOLDERS\tCOMPLETE\t0"]
            if rc != 0 or out != want:
                bad(f"R1 exact protected pairs: want both deterministic marker sets and COMPLETE 0, got rc={rc} {out!r}")
            exact_snapshot("R1 AFTER", box, box.ev / "varfolders-after.tsv", "AFTER")
    finally:
        box.close()

    for side in ("BEFORE", "AFTER"):
        box = base.Box(helper)
        try:  # R1b: duplicate EPERM callbacks collapse on each side, retaining lstat identity.
            pair = PROTECTED[0]
            locked(box, pair)
            row = f"R1b duplicate EPERM {side}"
            result = forced_snapshot(row, box, helper, side, pair, errno.EPERM, 2)
            if result is not None:
                rc, output = result
                if rc != 0:
                    bad(f"{row} must remain a complete snapshot, got rc={rc}")
                elif output.is_file():
                    exact_snapshot(row, box, output, side, (pair,), "EPERM")
                else:
                    bad(f"{row} returned success without a snapshot")
        finally:
            box.close()

    for side in ("BEFORE", "AFTER"):
        box = base.Box(helper)
        try:  # R1c: an exact pair plus EIO is an exact ERROR and incomplete on each side.
            pair = PROTECTED[0]
            locked(box, pair)
            row = f"R1c EIO {side}"
            result = forced_snapshot(row, box, helper, side, pair, errno.EIO, 1)
            if result is not None:
                rc, output = result
                lines = snapshot_rows(output) if output.is_file() else []
                markers = [line for line in lines if line.startswith("SKIPPED-PROTECTED\t")]
                errors = [line for line in lines if line.startswith("ERROR\t")]
                want_error = f"ERROR\t{pair[0]}\t{pair[1]}\t{os.strerror(errno.EIO)}"
                ends = [line for line in lines if line.startswith("END\t")]
                if rc != 3 or markers or errors != [want_error] or len(ends) != 1:
                    bad(f"{row} must retain one exact non-exempt ERROR in an incomplete snapshot, got rc={rc} "
                        f"markers={markers!r} errors={errors!r} ends={ends!r}")
        finally:
            box.close()

    # R2: exact strings only. Suffix, one-character change, parent and same basename elsewhere remain fail closed.
    for index, pair in enumerate(PROTECTED):
        token, rel = pair
        variants = [(token, rel + ".unreviewed"), (token, mutated(rel)),
                    (token, f"unreviewed-{index}/{Path(rel).name}")]
        if "/" in rel:
            variants.append((token, rel.rsplit("/", 1)[0]))
        for variant in variants:
            box = base.Box(helper)
            try:
                locked(box, variant)
                expect_refused(f"R2 literal boundary {pair!r} -> {variant!r}", box)
            finally:
                box.close()

    # R3: token is part of identity; the same path under every other root remains non-exempt.
    for pair in PROTECTED:
        for token in ("C", "P", "T"):
            if token == pair[0]:
                continue
            box = base.Box(helper)
            try:
                locked(box, (token, pair[1]))
                expect_refused(f"R3 wrong token {pair!r} under {token}", box)
            finally:
                box.close()

    for pair in PROTECTED:
        box = base.Box(helper)
        try:  # R4: a protected path does not exempt an unreadable descendant.
            locked(box, (pair[0], pair[1] + "/unreviewed-child"))
            expect_refused(f"R4 descendant of {pair!r}", box)
        finally:
            box.close()

    for pair in (PROTECTED[0], next(pair for pair in PROTECTED if pair[0] == "P")):
        box = base.Box(helper)
        try:  # R4b: unrecordable name beneath a readable listed directory stays fail closed.
            path = path_for(box, pair)
            path.mkdir(parents=True, exist_ok=True)
            os.close(os.open(os.fsencode(path) + b"/bad\nname", os.O_CREAT | os.O_WRONLY, 0o644))
            expect_refused(f"R4b unrecordable descendant of {pair!r}", box)
        finally:
            box.close()

    box = base.Box(helper)
    try:  # R5: readable listed paths are audited normally, never blind-excluded.
        for pair in PROTECTED:
            path = path_for(box, pair)
            path.mkdir(parents=True, exist_ok=True)
            (path / "audited.txt").write_text("before\n")
        rc, out = box.call("varfolders_begin")
        if rc != 0 or out:
            bad(f"R5 readable listed paths: begin must pass normally, got rc={rc} {out!r}")
        else:
            if any(line.startswith("SKIPPED-PROTECTED\t") for line in snapshot_rows(box.ev / "varfolders-before.tsv")):
                bad("R5 readable listed paths must be recorded, not skipped")
            changed = (PROTECTED[0], next(pair for pair in PROTECTED if pair[0] == "P"))
            for pair in changed:
                (path_for(box, pair) / "audited.txt").write_text("after\n")
            rc, out = box.call("varfolders_end")
            if rc != 2 or not out or out[-1].split("\t")[:2] != ["VARFOLDERS", "INCONCLUSIVE"]:
                bad(f"R5 readable listed P change must be INCONCLUSIVE, got rc={rc} {out!r}")
            for pair in changed:
                prefix = f"VARFOLDERS-DELTA\tchanged\t{pair[0]}\t{pair[1]}/audited.txt\t"
                if not any(line.startswith(prefix) for line in out):
                    bad(f"R5 readable listed path change {pair!r} is absent: {out!r}")
            if any(line.startswith("SKIPPED-PROTECTED\t") for line in out):
                bad(f"R5 readable listed paths must emit no skip markers: {out!r}")
    finally:
        box.close()

    for pair in (PROTECTED[0], next(pair for pair in PROTECTED if pair[0] == "P")):
        box = base.Box(helper)
        try:  # R5b: available lstat metadata remains a full delta while contents stay unreadable.
            path = locked(box, pair)
            before_meta = base.record(path)
            rc, out = box.call("varfolders_begin")
            if rc != 0 or out:
                bad(f"R5b metadata {pair!r}: begin must pass, got rc={rc} {out!r}")
            else:
                path.chmod(0o100)  # still cannot be listed, but mode/ctime identity changed
                after_meta = base.record(path)
                rc, out = box.call("varfolders_end")
                delta = f"VARFOLDERS-DELTA\tchanged\t{pair[0]}\t{pair[1]}\t{before_meta}\t{after_meta}"
                if pair[0] == "C":
                    final_ok = rc == 0 and bool(out) and out[-1] == "VARFOLDERS\tCOMPLETE\t1"
                else:
                    final_ok = rc == 2 and bool(out) and out[-1].split("\t")[:2] == ["VARFOLDERS", "INCONCLUSIVE"]
                before_line = marker("BEFORE", pair, "EACCES")
                after_line = marker("AFTER", pair, "EACCES")
                body = out[2:] if out[:2] == base.roots_line(box) else []
                if not final_ok or body[:-1] != [before_line, after_line, delta]:
                    bad(f"R5b metadata {pair!r}: want both markers, one full delta and token verdict, got rc={rc} "
                        f"{out!r}")
        finally:
            box.close()

    for pair in (PROTECTED[0], next(pair for pair in PROTECTED if pair[0] == "P")):
        for direction in ("unreadable-to-readable", "readable-to-unreadable"):
            box = base.Box(helper)
            try:  # R6: before/after skip sets must agree; a hidden transition is never COMPLETE.
                path = path_for(box, pair)
                path.mkdir(parents=True, exist_ok=True)
                if direction == "unreadable-to-readable":
                    path.chmod(0)
                rc, out = box.call("varfolders_begin")
                if rc != 0 or out:
                    bad(f"R6 {pair!r} {direction}: begin must pass, got rc={rc} {out!r}")
                else:
                    path.chmod(0o700 if direction == "unreadable-to-readable" else 0)
                    expect_inconclusive_end(f"R6 {pair!r} {direction}", box)
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
