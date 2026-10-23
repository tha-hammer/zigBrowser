#!/usr/bin/env python3
"""The owner's /var/folders rule (2026-10-23; SilverRidge 94ebe76b): a Mac run that launches the browser may write
under that user's own /var/folders. Each run must resolve the physical per-user roots from both
`getconf DARWIN_USER_TEMP_DIR` and `getconf DARWIN_USER_CACHE_DIR`, take deterministic recursive before/after
snapshots, report EVERY added, changed or removed path there without filtering, and delete nothing there. A
/var/folders delta alone is reportable and may coexist with PASS; a missing or incomplete snapshot is INCONCLUSIVE.

RED, UNREGISTERED: tests/mac/mac_varfolders_audit.sh, the one shared sourced helper (the Mac rows gate and the MS1c
.app gate both use it), does not exist yet.

The helper's contract under test (sourced by bash):
  varfolders_begin <evidence dir>   resolve and record the roots, then the before snapshot, all inside <evidence dir>
  varfolders_end <evidence dir>     the after snapshot, then
      VARFOLDERS_ROOTS<TAB>T<TAB><physical temp root><TAB>C<TAB><physical cache root>
      VARFOLDERS-DELTA<TAB><added|changed|removed><TAB><T|C><TAB><relative path><TAB><before><TAB><after>  (sorted)
      VARFOLDERS<TAB>COMPLETE<TAB><delta count>                          -> exit 0
   or VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>                           -> exit 2

Rows (hostless; getconf is a stub first on PATH; the roots are directories in a private temp dir):
- V1 roots: a symlinked temp root resolves to its physical directory, and both roots are recorded.
- V2 no change: COMPLETE 0 and no delta.
- V3 every delta, unfiltered: an added file, an added nested directory and file, a changed file, and names that look
  like system noise (com.apple.*, .DS_Store) or like the product (zigBrowser*) each give exactly one delta.
- V4 a removed path is a delta.
- V5 a dropped before snapshot, a truncated one, or a missing evidence dir is INCONCLUSIVE.
- V6 unusable roots: getconf fails, prints nothing, names a missing directory, or both name the same directory:
  INCONCLUSIVE.
- V7 an unreadable directory under a root makes the snapshot incomplete: INCONCLUSIVE. Run as a non-root user,
  because root reads a mode-000 directory.
- V8 nothing is deleted or written under the roots: after begin and end, every file that existed (including files
  added between them) is still there, byte for byte, and no file of the helper's own appears under a root.
The green adds the helper and a mutant check, which runs these rows against altered copies of the helper. Each must
fail: a filter that hides com.apple.* deltas (V3); a missing before snapshot treated as empty (V5); a delete under a
root (V8).

Run: python3 -X dev tests/e2e/mac_varfolders_audit_test.py [helper path]
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
failures: list[str] = []


def bad(msg: str) -> None:
    failures.append(msg)


class Box:
    """A private temp dir holding the fake per-user roots, a getconf stub and an evidence dir."""

    def __init__(self, helper: Path):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-vf-"))
        self.helper = helper
        self.user = self.tmp / "var" / "folders" / "ab" / "cdef"
        self.T, self.C = self.user / "T", self.user / "C"
        for d in (self.T, self.C):
            d.mkdir(parents=True)
        (self.T / "old.txt").write_text("old\n")
        (self.C / "cache.db").write_text("v1\n")
        (self.tmp / "link").symlink_to(self.user)  # macOS /var -> /private/var: the getconf answer is not physical
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.ev = self.tmp / "evidence"
        self.stub(f"{self.tmp}/link/T/", f"{self.C}/")

    def stub(self, temp: str | None, cache: str | None, rc: int = 0) -> None:
        lines = ["#!/bin/bash", 'case "$1" in']
        if temp is not None:
            lines.append(f"  DARWIN_USER_TEMP_DIR) printf '%s\\n' '{temp}'; exit {rc} ;;")
        if cache is not None:
            lines.append(f"  DARWIN_USER_CACHE_DIR) printf '%s\\n' '{cache}'; exit {rc} ;;")
        lines += ["esac", "exit 1"]
        p = self.bin / "getconf"
        p.write_text("\n".join(lines) + "\n")
        p.chmod(0o755)

    def call(self, fn: str) -> tuple[int, list[str]]:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(self.tmp / "home")}
        r = subprocess.run(["bash", "-c", f'. "$1" && {fn} "$2"', "_", str(self.helper), str(self.ev)],
                           cwd=self.tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        return r.returncode, r.stdout.decode(errors="replace").splitlines()

    def cycle(self, between=None) -> tuple[int, list[str]]:
        rc, out = self.call("varfolders_begin")
        if rc != 0:
            return rc, out
        if between is not None:
            between(self)
        return self.call("varfolders_end")

    def files(self) -> dict:
        out = {}
        for base in (self.T, self.C):
            for dirpath, dirs, names in os.walk(base):
                for n in names:
                    p = Path(dirpath) / n
                    out[str(p.relative_to(self.user))] = p.read_bytes()
        return out

    def close(self) -> None:
        for dirpath, dirs, _names in os.walk(self.tmp):
            for d in dirs:
                os.chmod(Path(dirpath) / d, 0o700)
        shutil.rmtree(self.tmp)


def deltas(out):
    return [l.split("\t") for l in out if l.startswith("VARFOLDERS-DELTA\t")]


def summary(out):
    s = [l for l in out if l.startswith("VARFOLDERS\t")]
    return s[-1] if s else None


def run_rows(helper: Path) -> list[str]:
    global failures
    failures = []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    box = Box(helper)
    try:  # V1 + V2 + V8 (a cycle with no change leaves every file under the roots as it was)
        untouched = box.files()
        rc, out = box.cycle()
        if box.files() != untouched:
            bad("V8 a begin/end cycle deleted, changed or added a file under a root")
        roots = [l for l in out if l.startswith("VARFOLDERS_ROOTS\t")]
        want = f"VARFOLDERS_ROOTS\tT\t{box.T}\tC\t{box.C}"
        if roots != [want]:
            bad(f"V1 roots: want [{want!r}], got {roots!r}")
        if rc != 0 or summary(out) != "VARFOLDERS\tCOMPLETE\t0" or deltas(out):
            bad(f"V2 no change: want COMPLETE 0 and no delta, got rc={rc} {out[-3:]!r}")
    finally:
        box.close()

    box = Box(helper)
    try:  # V3 + V4 + V8
        def change(b):
            (b.T / "new.txt").write_text("n\n")
            (b.T / "d" / "e").mkdir(parents=True)
            (b.T / "d" / "e" / "f.bin").write_bytes(b"\x00\x01")
            (b.C / "cache.db").write_text("v2 longer\n")
            (b.C / "com.apple.WebKit.Networking").mkdir()
            (b.C / ".DS_Store").write_text("x")
            (b.T / "zigBrowser-run.log").write_text("z")
            (b.T / "old.txt").unlink()
        rc, out = box.cycle(change)
        got = sorted((d[1], d[2], d[3]) for d in deltas(out))
        want = sorted([("added", "T", "new.txt"), ("added", "T", "d"), ("added", "T", "d/e"), ("added", "T", "d/e/f.bin"),
                       ("changed", "C", "cache.db"), ("added", "C", "com.apple.WebKit.Networking"),
                       ("added", "C", ".DS_Store"), ("added", "T", "zigBrowser-run.log"), ("removed", "T", "old.txt")])
        if got != want:
            bad(f"V3/V4 deltas: want {want!r}, got {got!r}")
        if [l for l in out if l.startswith("VARFOLDERS-DELTA\t")] != sorted(l for l in out if l.startswith("VARFOLDERS-DELTA\t")):
            bad("V3 deltas are not in a deterministic (sorted) order")
        if rc != 0 or summary(out) != f"VARFOLDERS\tCOMPLETE\t{len(want)}":
            bad(f"V3 a delta alone is reportable: want COMPLETE {len(want)} exit 0, got rc={rc} {summary(out)!r}")
        before_end = box.files()
        rc2, _ = box.call("varfolders_end")  # a second end must not touch the roots either
        if box.files() != before_end:
            bad("V8 the helper deleted or changed a file under a root")
        if set(box.files()) - set(before_end):
            bad("V8 the helper wrote under a root")
    finally:
        box.close()

    for name, damage in (("dropped", lambda ev: [p.unlink() for p in ev.rglob("*before*") if p.is_file()]),
                         ("truncated", lambda ev: [p.write_text((p.read_text().splitlines() or [""])[0] + "\n")
                                                   for p in ev.rglob("*before*") if p.is_file()]),
                         ("no evidence dir", lambda ev: shutil.rmtree(ev))):
        box = Box(helper)
        try:  # V5
            rc, out = box.call("varfolders_begin")
            damage(box.ev)
            rc, out = box.call("varfolders_end")
            if rc != 2 or not (summary(out) or "").startswith("VARFOLDERS\tINCONCLUSIVE\t") or deltas(out):
                bad(f"V5 {name} before snapshot: want INCONCLUSIVE exit 2 and no delta, got rc={rc} {out[-3:]!r}")
        finally:
            box.close()

    for name, args in (("getconf fails", (None, None, 1)), ("empty answer", ("", "", 0)),
                       ("missing directory", ("/nonexistent/zb-vf/T/", None, 0)), ("same directory", (None, None, 0))):
        box = Box(helper)
        try:  # V6
            temp, cache, code = args
            if name == "same directory":
                temp = cache = f"{box.T}/"
            elif name == "missing directory":
                cache = f"{box.C}/"
            box.stub(temp, cache, code)
            rc, out = box.cycle()
            if rc != 2 or not (summary(out) or "").startswith("VARFOLDERS\tINCONCLUSIVE\t"):
                bad(f"V6 {name}: want INCONCLUSIVE exit 2, got rc={rc} {out[-3:]!r}")
        finally:
            box.close()

    box = Box(helper)
    try:  # V7
        if os.geteuid() == 0:
            bad("V7 needs a non-root user (root reads a mode-000 directory): run it as yourself")
        else:
            locked = box.C / "locked"
            locked.mkdir()
            (locked / "x").write_text("x")
            locked.chmod(0)
            rc, out = box.cycle()
            if rc != 2 or not (summary(out) or "").startswith("VARFOLDERS\tINCONCLUSIVE\t"):
                bad(f"V7 an unreadable directory: want INCONCLUSIVE exit 2, got rc={rc} {out[-3:]!r}")
    finally:
        box.close()
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL\tmac-varfolders-audit\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-audit\tV1-V8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
