#!/usr/bin/env python3
"""The crash-report rule for the Mac gates that launch the browser (orchestrator 2026-10-23): the owner's exception
for a crash report covers only the MS1c missing-dylib control, so every other run lists the Mac user's real
~/Library/Logs/DiagnosticReports before and after, read-only (never deleting or changing anything there), reports
each new, changed or removed report with its name and sha256, and is INCONCLUSIVE, never a pass, when any appears.

RED, UNREGISTERED: tests/mac/mac_crashreports_audit.sh, the shared sourced helper (first used by the runtime rows
gate's Mac leg), does not exist yet.

The helper's contract under test (sourced by bash):
  crashreports_begin <evidence dir> <reports dir>   the before listing, in <evidence dir>: prints nothing and exits 0
                                                    when it is complete, else refuses (exit 2, one INCONCLUSIVE line)
  crashreports_end <evidence dir> <reports dir>     the after listing, then exactly these lines and nothing else:
      CRASHREPORT<TAB><added|changed|removed><TAB><path><TAB><sha256>   per entry that differs, in path byte order
          (a regular file's sha256 after the run, or before it when removed; - for a directory or other type)
      CRASHREPORTS<TAB>COMPLETE<TAB>0                                    -> exit 0, only when no line above
   or CRASHREPORTS<TAB>INCONCLUSIVE<TAB><nonempty reason>               -> exit 2: after any CRASHREPORT line, or
          alone when a listing is missing or incomplete or the reports dir differs from begin's
  A missing reports dir is an empty listing, so reports in a dir created during the run are each reported.

Rows (hostless; the reports dir is <private home>/Library/Logs/DiagnosticReports in a private temp dir; TMPDIR is the
reports dir itself, so any temp file the helper made would land inside the boundary; this test computes every sha256):
- CR1 no change: begin is silent; end is exactly COMPLETE 0, exit 0.
- CR2 an added report, an added report in a new subdirectory (its directory too), a same-size rewrite of a report with
  its mtime restored, and a removed report each give exactly one CRASHREPORT line with the exact sha256, in order,
  then INCONCLUSIVE with a nonempty reason, exit 2.
- CR3 no reports dir before or after: COMPLETE 0. No dir before, one report in a dir created during the run: that
  report (and its dir) are reported, INCONCLUSIVE.
- CR4 an unreadable report, and an unreadable subdirectory (as a non-root user): INCONCLUSIVE, no CRASHREPORT line.
- CR5 a dropped, truncated or missing before listing, or end given another reports dir than begin: INCONCLUSIVE, no
  CRASHREPORT line.
- CR6 a name holding a tab, a newline or a byte that is not UTF-8: INCONCLUSIVE, no CRASHREPORT line.
- CR7 the mutation boundary (Linux inotify, as tests/e2e/mac_varfolders_audit_test.py): around every helper call,
  on ~/Library and every directory below it, the helper itself creates, deletes, moves, writes or changes nothing;
  the watch is first proven live. Every entry is also unchanged after the helper ran.
- CR9 fail closed (as varfolders_begin, SilverRidge 3661c9b8): when the before listing is incomplete (CR4, CR6),
  crashreports_begin refuses: exit 2 and exactly one CRASHREPORTS<TAB>INCONCLUSIVE<TAB><nonempty reason> line.
- CR8 a tripwire: the helper has no here-document (macOS /bin/bash 3.2 writes each one to a temp file in $TMPDIR).

Run: python3 -X dev tests/e2e/mac_crashreports_audit_test.py [helper path]
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mac_varfolders_audit_test import Boundary  # noqa: E402  (the same inotify boundary)

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_crashreports_audit.sh"
failures: list[str] = []
hits: list[str] = []


def bad(msg: str) -> None:
    failures.append(msg)


class Box:
    def __init__(self, helper: Path, make_dir: bool = True):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-cr-"))
        self.helper = helper
        self.lib = self.tmp / "home" / "Library"
        self.dir = self.lib / "Logs" / "DiagnosticReports"
        (self.lib / "Logs").mkdir(parents=True)
        if make_dir:
            (self.dir / "Retired").mkdir(parents=True)
            (self.dir / "old.ips").write_text("old report\n")
            (self.dir / "Retired" / "older.ips").write_text("older\n")
        self.ev = self.tmp / "evidence"
        self.boundary = Boundary(self.lib) if sys.platform.startswith("linux") else None

    def call(self, fn: str, top: Path | None = None) -> tuple[int, list[str]]:
        if self.boundary is not None:
            self.boundary.arm()
        before = listing(self.dir)
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(self.tmp / "home"),
               "TMPDIR": f"{self.dir}/" if self.dir.is_dir() else f"{self.lib}/"}
        r = subprocess.run(["bash", "-c", f'. "$1" && {fn} "$2" "$3"', "_", str(self.helper), str(self.ev),
                            str(top or self.dir)], cwd=self.tmp, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=60)
        if self.boundary is not None:
            hits.extend(f"{fn}: {e}" for e in self.boundary.collect())
        if listing(self.dir) != before:
            bad(f"CR7 {fn} changed an entry under the reports dir")
        return r.returncode, r.stdout.decode(errors="replace").splitlines()

    def cycle(self, between=None, end_top: Path | None = None) -> tuple[int, list[str]]:
        rc, out = self.call("crashreports_begin")
        if rc != 0 or out:
            bad(f"CR1 crashreports_begin must be silent and exit 0, got rc={rc} {out[-3:]!r}")
        if between is not None:
            between(self)
        return self.call("crashreports_end", end_top)

    def refused(self, row: str) -> tuple[int, list[str]]:
        """CR9: a begin that cannot take a complete before listing refuses (fails closed): exit 2 and exactly one
        CRASHREPORTS<TAB>INCONCLUSIVE<TAB><nonempty reason> line; the end after it is INCONCLUSIVE too."""
        rc, out = self.call("crashreports_begin")
        fields = out[0].split("\t") if len(out) == 1 else []
        if rc != 2 or len(fields) != 3 or fields[:2] != ["CRASHREPORTS", "INCONCLUSIVE"] or not fields[2].strip():
            bad(f"CR9 {row} crashreports_begin must refuse: exit 2 and one INCONCLUSIVE line with a reason, "
                f"got rc={rc} {out[-3:]!r}")
        return self.call("crashreports_end")

    def close(self) -> None:
        if self.boundary is not None:
            self.boundary.close()
        for dirpath, dirs, names in os.walk(self.tmp):
            for n in dirs + names:
                p = Path(dirpath) / n
                if not p.is_symlink():
                    os.chmod(p, 0o700)
        shutil.rmtree(self.tmp)


def listing(top: Path) -> dict:
    """This test's own listing: path -> (type, sha256 or -); every entry, any type; unreadable entries say so."""
    out = {}
    if not top.is_dir():
        return out
    for dirpath, dirs, names in os.walk(top):
        for n in dirs + names:
            p = Path(dirpath) / n
            rel = os.fsdecode(os.path.relpath(os.fsencode(p), os.fsencode(top)))
            if p.is_symlink():
                out[rel] = ("l", "-")
            elif p.is_dir():
                out[rel] = ("d", "-")
            elif p.is_file():
                try:
                    out[rel] = ("f", hashlib.sha256(p.read_bytes()).hexdigest())
                except OSError:
                    out[rel] = ("f", "unreadable")
            else:
                out[rel] = ("o", "-")
    return out


def want_lines(before: dict, after: dict) -> list[str]:
    rows = []
    for rel in sorted(set(before) | set(after), key=os.fsencode):
        b, a = before.get(rel), after.get(rel)
        if b != a:
            kind = "added" if b is None else "removed" if a is None else "changed"
            rows.append(f"CRASHREPORT\t{kind}\t{rel}\t{(a or b)[1]}")
    return rows


def structure(row: str, rc: int, out: list[str]) -> tuple[str, list[str]] | None:
    """The exact end grammar; returns (final word, report lines) or records a problem."""
    if not out or not out[-1].startswith("CRASHREPORTS\t"):
        bad(f"{row}: want a final CRASHREPORTS line, got {out[-3:]!r}")
        return None
    final, lines = out[-1].split("\t"), out[:-1]
    if any(len(l.split("\t")) != 4 or l.split("\t")[0] != "CRASHREPORT"
           or l.split("\t")[1] not in ("added", "changed", "removed") for l in lines):
        bad(f"{row}: every line before the final one must be a four-field CRASHREPORT line, got {lines!r}")
        return None
    if final == ["CRASHREPORTS", "COMPLETE", "0"] and rc == 0 and not lines:
        return "COMPLETE", []
    if len(final) == 3 and final[1] == "INCONCLUSIVE" and final[2].strip() and rc == 2:
        return "INCONCLUSIVE", lines
    bad(f"{row}: want COMPLETE 0 (exit 0, no report) or INCONCLUSIVE with a nonempty reason (exit 2), "
        f"got rc={rc} {out[-1]!r}")
    return None


def inconclusive_bare(row: str, rc: int, out: list[str]) -> None:
    got = structure(row, rc, out)
    if got is not None and got != ("INCONCLUSIVE", []):
        bad(f"{row}: want INCONCLUSIVE with no CRASHREPORT line, got {out!r}")


def run_rows(helper: Path) -> list[str]:
    global failures, hits
    failures, hits = [], []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    if not sys.platform.startswith("linux"):
        return ["CR7 the mutation boundary needs Linux inotify: run this on the Linux gate"]

    box = Box(helper)
    try:  # CR7 the boundary is live
        box.boundary.arm()
        probe = box.dir / "zb-boundary-probe"
        probe.write_text("p")
        probe.unlink()
        if len(box.boundary.collect()) < 2:
            bad("CR7 the inotify boundary did not see a create and delete in the reports dir: it would prove nothing")
    finally:
        box.close()

    box = Box(helper)
    try:  # CR1
        rc, out = box.cycle()
        if structure("CR1", rc, out) != ("COMPLETE", []):
            bad(f"CR1 no change: want exactly COMPLETE 0, got rc={rc} {out!r}")
    finally:
        box.close()

    box = Box(helper)
    try:  # CR2
        state = {}

        def change(b):
            state["before"] = listing(b.dir)
            (b.dir / "zigBrowser-2026-10-23-120000.ips").write_text('{"crash": 1}\n')
            (b.dir / "Sub").mkdir()
            (b.dir / "Sub" / "WebContent.ips").write_text("w\n")
            same = b.dir / "old.ips"  # same size, mtime restored: only the bytes differ
            st = os.lstat(same)
            with open(same, "r+b") as f:
                f.write(b"OLD REPORT\n")
            os.utime(same, ns=(st.st_atime_ns, st.st_mtime_ns))
            (b.dir / "Retired" / "older.ips").unlink()
            state["after"] = listing(b.dir)
        rc, out = box.cycle(change)
        want = want_lines(state["before"], state["after"])
        named = [("added", "Sub"), ("added", "Sub/WebContent.ips"), ("added", "zigBrowser-2026-10-23-120000.ips"),
                 ("changed", "old.ips"), ("removed", "Retired/older.ips")]
        if sorted((l.split("\t")[1], l.split("\t")[2]) for l in want) != sorted(named):
            bad(f"CR2 this test's own listing missed a change: {want!r}")
        got = structure("CR2", rc, out)
        if got is not None and got != ("INCONCLUSIVE", want):
            bad(f"CR2 want exactly {want!r} then INCONCLUSIVE, got {out!r}")
    finally:
        box.close()

    box = Box(helper, make_dir=False)
    try:  # CR3 no dir at all
        rc, out = box.cycle()
        if structure("CR3 no reports dir", rc, out) != ("COMPLETE", []):
            bad(f"CR3 no reports dir before or after: want COMPLETE 0, got rc={rc} {out!r}")
    finally:
        box.close()
    box = Box(helper, make_dir=False)
    try:  # CR3 a dir created during the run
        def create(b):
            b.dir.mkdir()
            (b.dir / "zigBrowser.ips").write_text("z\n")
        rc, out = box.cycle(create)
        want = [f"CRASHREPORT\tadded\tzigBrowser.ips\t{hashlib.sha256(b'z' + bytes([10])).hexdigest()}"]
        got = structure("CR3 created dir", rc, out)
        if got is not None and got != ("INCONCLUSIVE", want):
            bad(f"CR3 a report in a dir created during the run: want {want!r} then INCONCLUSIVE, got {out!r}")
    finally:
        box.close()

    for name, lock in (("an unreadable report", lambda b: (b.dir / "old.ips").chmod(0)),
                       ("an unreadable subdirectory", lambda b: (b.dir / "Retired").chmod(0))):
        box = Box(helper)
        try:  # CR4
            if os.geteuid() == 0:
                bad("CR4 needs a non-root user (root reads a mode-000 entry): run it as yourself")
                break
            lock(box)
            rc, out = box.refused(f"CR4 {name}:")
            inconclusive_bare(f"CR4 {name}", rc, out)
        finally:
            box.close()

    for name, damage in (("dropped", lambda ev: [p.unlink() for p in ev.rglob("*before*") if p.is_file()]),
                         ("truncated", lambda ev: [p.write_text((p.read_text().splitlines() or [""])[0] + "\n")
                                                   for p in ev.rglob("*before*.tsv")]),
                         ("no evidence dir", lambda ev: shutil.rmtree(ev))):
        box = Box(helper)
        try:  # CR5
            box.call("crashreports_begin")
            damage(box.ev)
            rc, out = box.call("crashreports_end")
            inconclusive_bare(f"CR5 {name} before listing", rc, out)
        finally:
            box.close()
    box = Box(helper)
    try:  # CR5 another reports dir at end
        other = box.lib / "Logs" / "Other"
        other.mkdir()
        rc, out = box.cycle(end_top=other)
        inconclusive_bare("CR5 another reports dir at end", rc, out)
    finally:
        box.close()

    for name, fname in (("newline", b"a\nb.ips"), ("tab", b"a\tb.ips"), ("non-UTF-8 byte", b"a\xff.ips")):
        box = Box(helper)
        try:  # CR6
            os.close(os.open(os.fsencode(box.dir) + b"/" + fname, os.O_CREAT | os.O_WRONLY, 0o644))
            rc, out = box.refused(f"CR6 a name with a {name}:")
            inconclusive_bare(f"CR6 a name with a {name}", rc, out)
        finally:
            box.close()

    if re.search(r"<<-?\s*['\"]?\w", helper.read_text()):  # CR8
        bad("CR8 the helper uses a here-document: macOS /bin/bash 3.2 writes each one to a temp file in $TMPDIR")
    if hits:
        bad(f"CR7 the helper itself changed entries under ~/Library ({len(hits)} inotify events): {hits[:6]!r}")
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL\tmac-crashreports-audit\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-crashreports-audit\tCR1-CR9")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
