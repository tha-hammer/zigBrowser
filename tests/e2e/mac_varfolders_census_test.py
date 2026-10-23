#!/usr/bin/env python3
"""The per-user parent census of the /var/folders audit (SilverRidge 3661c9b8 and 5f1ce9a5): the owner's exception
covers only the physical T and C roots, so the entries beside them in their common per-user parent (0, X and any
other) are a census only. Before a browser-launching request, a change there must be reported in full and be
INCONCLUSIVE, never a pass, and a missing or incomplete parent census must be non-pass.

RED, UNREGISTERED: tests/mac/mac_varfolders_audit.sh has no parent census yet. The green adds it, teaches the
registered oracle tests/e2e/mac_varfolders_audit_test.py the parent line and this verdict, and registers this file.

The helper's added contract, on top of the registered oracle's:
- the roots line is followed by exactly one VARFOLDERS_PARENT<TAB><the physical common parent of T and C>;
- the parent itself and every entry below it except T and C are recorded under the root token P, with the same
  records as T and C ("type mode uid gid nlink size mtime_ns ctime_ns inode sha256 link"; the parent is the path .);
- a change under P is printed as an ordinary VARFOLDERS-DELTA with token P, among all the deltas of the run in their
  usual order (token, then path bytes), and the end is then VARFOLDERS<TAB>INCONCLUSIVE<TAB><nonempty reason>, exit 2;
- T and C without a common parent, or an unreadable entry beside them, refuse at begin (exit 2, one INCONCLUSIVE line);
  one that becomes unreadable by the end is INCONCLUSIVE with no delta.

Rows (the registered oracle's private-temp Box, getconf stub, TMPDIR and inotify boundary, with 0/zz.db and X/x.bin
beside T and C):
- PC1 no change: exactly the roots line, the parent line and COMPLETE 0.
- PC2 a change in T and C only, with the siblings present: COMPLETE with exactly the T/C deltas, no P delta.
- PC3 changes beside T and C (a file added in 0, a same-size rewrite in X, a new sibling directory with a file, the
  parent's own mode) and a T change in the same run: every delta, exact and in order, then INCONCLUSIVE, exit 2.
- PC4 T and C in two different per-user dirs: begin refuses.
- PC5 an unreadable sibling directory at begin: begin refuses; one made unreadable by the end: INCONCLUSIVE, no delta.
  As a non-root user.
- PC6 the helper itself changes nothing beside T and C either (the boundary covers the whole fake /var/folders tree).

Run: python3 -X dev tests/e2e/mac_varfolders_census_test.py [helper path]
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as base  # noqa: E402  (the registered oracle's Box, records and boundary)

failures: list[str] = []


def bad(msg: str) -> None:
    failures.append(msg)


def census_box(helper: Path) -> "base.Box":
    box = base.Box(helper)
    for d, f, body in (("0", "zz.db", "zz\n"), ("X", "x.bin", "x1\n")):
        (box.user / d).mkdir()
        (box.user / d / f).write_text(body)
    return box


def observe(box) -> dict:
    """The registered oracle's T/C records plus this test's own census of the parent P (without T and C)."""
    out = base.observe(box)
    out[("P", ".")] = base.record(box.user)
    for dirpath, dirs, names in os.walk(box.user):
        if Path(dirpath) == box.user:
            dirs[:] = [d for d in dirs if d not in ("T", "C")]
            names = [n for n in names if n not in ("T", "C")]
        for n in dirs + names:
            p = Path(dirpath) / n
            out[("P", str(p.relative_to(box.user)))] = base.record(p)
    return out


def head(box) -> list[str]:
    return [f"VARFOLDERS_ROOTS\tT\t{box.T}\tC\t{box.C}", f"VARFOLDERS_PARENT\t{box.user}"]


def verdict(row: str, box, rc: int, out: list[str]) -> tuple[str, list[tuple]] | None:
    """COMPLETE (T/C deltas only, exit 0), OUTSIDE (every delta, one of P, then INCONCLUSIVE, exit 2) or
    INCONCLUSIVE (no delta, exit 2); the header, when present, exactly head(box), once and first."""
    rest = list(out)
    if rest[:2] == head(box):
        rest = rest[2:]
    if any(l.startswith(("VARFOLDERS_ROOTS", "VARFOLDERS_PARENT")) for l in rest) or not rest:
        bad(f"{row}: want the header {head(box)!r} once and first, then deltas and one final line, got {out!r}")
        return None
    final, deltas = rest[-1].split("\t"), [tuple(l.split("\t")) for l in rest[:-1]]
    if any(len(d) != 6 or d[0] != "VARFOLDERS-DELTA" or d[2] not in ("C", "P", "T") for d in deltas):
        bad(f"{row}: malformed delta lines {rest[:-1]!r}")
        return None
    if final == ["VARFOLDERS", "COMPLETE", str(len(deltas))] and rc == 0 and out[:2] == head(box):
        return ("COMPLETE", deltas) if all(d[2] != "P" for d in deltas) else None
    if len(final) == 3 and final[:2] == ["VARFOLDERS", "INCONCLUSIVE"] and final[2].strip() and rc == 2:
        if not deltas:
            return "INCONCLUSIVE", []
        if out[:2] == head(box) and any(d[2] == "P" for d in deltas):
            return "OUTSIDE", deltas
    bad(f"{row}: not a COMPLETE, OUTSIDE or INCONCLUSIVE result: rc={rc} {out[-3:]!r}")
    return None


def exact(row: str, box, change, named: list[tuple], want: str) -> None:
    state = {}

    def between(b):
        state["before"] = observe(b)
        change(b)
        state["after"] = observe(b)
    rc, out = box.cycle(between)
    deltas = base.want_deltas(state["before"], state["after"])
    if sorted((d[1], d[2], d[3]) for d in deltas) != sorted(named):
        bad(f"{row}: this test's own records missed a change: want {sorted(named)!r}, got {deltas!r}")
        return
    got = verdict(row, box, rc, out)
    if got != (want, deltas):
        bad(f"{row}: want {want} with exactly {deltas!r}, got rc={rc} {out!r}")


def refused(row: str, box) -> None:
    rc, out = box.call("varfolders_begin")
    fields = out[0].split("\t") if len(out) == 1 else []
    if rc != 2 or len(fields) != 3 or fields[:2] != ["VARFOLDERS", "INCONCLUSIVE"] or not fields[2].strip():
        bad(f"{row}: varfolders_begin must refuse (exit 2, one INCONCLUSIVE line), got rc={rc} {out!r}")
    rc, out = box.call("varfolders_end")
    if verdict(row, box, rc, out) != ("INCONCLUSIVE", []):
        bad(f"{row}: the end after a refused begin must be INCONCLUSIVE with no delta, got rc={rc} {out!r}")


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    if not sys.platform.startswith("linux"):
        return ["PC6 the mutation boundary needs Linux inotify: run this on the Linux gate"]
    base.hits, base.failures = [], []

    box = census_box(helper)
    try:  # PC1
        rc, out = box.cycle()
        want = head(box) + ["VARFOLDERS\tCOMPLETE\t0"]
        if out != want or rc != 0:
            bad(f"PC1 no change: want exactly {want!r}, got rc={rc} {out!r}")
    finally:
        box.close()

    box = census_box(helper)
    try:  # PC2
        exact("PC2 a T/C-only change", box, lambda b: (b.C / "new.db").write_text("n\n"),
              [("added", "C", "new.db"), ("changed", "C", ".")], "COMPLETE")
    finally:
        box.close()

    def beside(b):
        (b.user / "0" / "new.db").write_text("n\n")
        (b.user / "X" / "x.bin").write_text("x2\n")  # same size, new bytes
        (b.user / "Z").mkdir()
        (b.user / "Z" / "z").write_text("z\n")
        b.user.chmod(0o750)
        (b.T / "t.txt").write_text("t\n")
    box = census_box(helper)
    try:  # PC3
        exact("PC3 changes beside T and C", box, beside,
              [("added", "P", "0/new.db"), ("changed", "P", "0"), ("changed", "P", "X/x.bin"), ("added", "P", "Z"),
               ("added", "P", "Z/z"), ("changed", "P", "."), ("added", "T", "t.txt"), ("changed", "T", ".")],
              "OUTSIDE")
    finally:
        box.close()

    box = census_box(helper)
    try:  # PC4
        (box.var / "folders" / "zz" / "other" / "C").mkdir(parents=True)
        box.stub(f"{box.T}/", f"{box.var}/folders/zz/other/C/")
        refused("PC4 T and C without a common parent", box)
    finally:
        box.close()

    for when in ("begin", "end"):
        box = census_box(helper)
        try:  # PC5
            if os.geteuid() == 0:
                bad("PC5 needs a non-root user (root reads a mode-000 directory): run it as yourself")
                break

            def lock(b):
                (b.user / "X" / "locked").mkdir()
                (b.user / "X" / "locked").chmod(0)
            if when == "begin":
                lock(box)
                refused("PC5 an unreadable sibling at begin", box)
            else:
                rc, out = box.cycle(lock)
                if verdict("PC5 an unreadable sibling by the end", box, rc, out) != ("INCONCLUSIVE", []):
                    bad(f"PC5 an unreadable sibling by the end: want INCONCLUSIVE with no delta, got rc={rc} {out!r}")
        finally:
            box.close()

    if base.hits:
        bad(f"PC6 the helper itself changed entries under the fake /var/folders ({len(base.hits)} inotify events): "
            f"{base.hits[:6]!r}")
    return list(failures) + [f for f in base.failures if f.startswith("V2 ")]


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else base.HELPER
    problems = run_rows(helper)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL\tmac-varfolders-census\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-census\tPC1-PC6")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
