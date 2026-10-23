#!/usr/bin/env python3
"""The owner's /var/folders rule (2026-10-23; SilverRidge 94ebe76b): a Mac run that launches the browser may write
under that user's own /var/folders. Each run must resolve the physical per-user roots from both
`getconf DARWIN_USER_TEMP_DIR` and `getconf DARWIN_USER_CACHE_DIR`, take deterministic recursive before/after
snapshots, report EVERY added, changed or removed path there without filtering, and write, change or delete nothing
there itself. A /var/folders delta alone is reportable and may coexist with PASS; a missing or incomplete snapshot, or a
root that changed identity during the run, is INCONCLUSIVE.

RED, UNREGISTERED, fix-forward for SilverRidge 30a7a1e8 (on 143a12f6): tests/mac/mac_varfolders_audit.sh, the one
shared sourced helper (the Mac rows gate and the MS1c .app gate both use it), does not exist yet.

The helper's contract under test (sourced by bash):
  varfolders_begin <evidence dir>   prints nothing and exits 0; resolves and records the roots (path, device, inode),
                                    then the before snapshot, all inside <evidence dir>
  varfolders_end <evidence dir>     the after snapshot, then exactly these lines and nothing else:
      VARFOLDERS_ROOTS<TAB>T<TAB><physical temp root><TAB>C<TAB><physical cache root>
      VARFOLDERS-DELTA<TAB><added|changed|removed><TAB><T|C><TAB><relative path><TAB><before><TAB><after>
      VARFOLDERS<TAB>COMPLETE<TAB><delta count>                                    -> exit 0
   or [the VARFOLDERS_ROOTS line] VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>, no delta  -> exit 2
  A delta's <before>/<after> is the path's record "type mode size mtime_ns inode sha256 link" (type f d l p s c b o;
  mode in octal; sha256 of a regular file's bytes, else -; a symlink's target, else -), and - alone on the absent side.
  Deltas are ordered by root token, then by path bytes.

Rows (hostless; getconf is a stub first on PATH; the roots are directories in a private temp dir, the temp root reached
through a symlink; this test computes every record itself from lstat and the file bytes):
- V1 roots: one VARFOLDERS_ROOTS line with the physical roots.
- V2 no change: begin is silent, end gives exactly the roots line and COMPLETE 0.
- V3 every delta, unfiltered, exact: added files and a nested directory, a changed size, names that look like system
  noise (com.apple.*, .DS_Store) or like the product (zigBrowser*), a same-size rewrite with its mtime and inode
  restored, a symlink retarget, a file replaced by a directory, and a mode change each give exactly one delta, whose six
  fields equal this test's own before/after records, in order, with COMPLETE equal to the count.
- V4 a removed path is a delta (after -): a regular file and a FIFO.
- V5 a dropped before snapshot, a truncated one, or a missing evidence dir is INCONCLUSIVE with no delta.
- V6 unusable roots: getconf fails, prints nothing, names a missing directory, or both name the same directory:
  INCONCLUSIVE with no delta.
- V7 an unreadable directory under a root makes the snapshot incomplete: INCONCLUSIVE with no delta. Run as a non-root
  user, because root reads a mode-000 directory.
- V8 nothing under the roots differs after the helper ran: every entry of every type (file, directory, symlink, FIFO)
  keeps its record, over a no-change cycle and a second end.
- V9 the mutation boundary: a Linux inotify watch on both roots and every directory below them is armed around each
  helper call; any create, delete, move, write or attribute change the helper itself makes there, even one it undoes
  (a transient file, directory, symlink or FIFO; a write or chmod then restore), is red. The watch is first proven
  live: a create and delete by this test while armed must be seen.
- V10 root identity: between begin and end, the getconf answer changes, the physical temp root is replaced by another
  directory at the same path, or the symlink the temp answer goes through is retargeted: each is INCONCLUSIVE.
- V11 a name holding a newline or a tab cannot be recorded unambiguously: INCONCLUSIVE with no delta.
The green adds the helper and a mutant check, which runs these rows against altered copies of the helper.

Run: python3 -X dev tests/e2e/mac_varfolders_audit_test.py [helper path]
"""
from __future__ import annotations

import ctypes
import errno
import hashlib
import os
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests" / "mac" / "mac_varfolders_audit.sh"
failures: list[str] = []
hits: list[str] = []  # V9: inotify events the helper itself caused under the roots

IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE, IN_MOVED_FROM, IN_MOVED_TO = 0x2, 0x4, 0x8, 0x40, 0x80
IN_CREATE, IN_DELETE, IN_DELETE_SELF, IN_MOVE_SELF, IN_Q_OVERFLOW = 0x100, 0x200, 0x400, 0x800, 0x4000
IN_ONLYDIR, IN_DONT_FOLLOW = 0x01000000, 0x02000000
WRITE_MASK = (IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
              | IN_DELETE_SELF | IN_MOVE_SELF)
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"),
        (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))


def bad(msg: str) -> None:
    failures.append(msg)


class Boundary:
    """A Linux inotify watch on a directory tree: every directory below `top` (re-walked at each arm, so a directory
    created between helper calls is watched too) for any change of an entry or of its contents or attributes."""

    def __init__(self, top: Path):
        self.top = top
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        self.paths: dict[int, str] = {}

    def arm(self) -> None:
        for dirpath, dirs, _names in os.walk(self.top, followlinks=False):
            wd = self.libc.inotify_add_watch(self.fd, os.fsencode(dirpath), WRITE_MASK | IN_ONLYDIR | IN_DONT_FOLLOW)
            if wd >= 0:
                self.paths[wd] = dirpath
            elif ctypes.get_errno() not in (errno.EACCES, errno.ENOENT):  # V7's mode-000 directory cannot be watched
                raise OSError(ctypes.get_errno(), f"inotify_add_watch {dirpath}")
        self.collect()

    def collect(self) -> list[str]:
        out = []
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return out
            i = 0
            while i < len(buf):
                wd, mask, _cookie, n = struct.unpack_from("iIII", buf, i)
                name = buf[i + 16:i + 16 + n].rstrip(b"\0").decode(errors="replace")
                i += 16 + n
                if mask & (WRITE_MASK | IN_Q_OVERFLOW):
                    out.append(f"{self.paths.get(wd, '?')}/{name} mask=0x{mask:x}")

    def close(self) -> None:
        os.close(self.fd)


class Box:
    """A private temp dir holding the fake per-user roots, a getconf stub, an evidence dir and the boundary."""

    def __init__(self, helper: Path):
        self.tmp = Path(tempfile.mkdtemp(prefix="zb-vf-"))
        self.helper = helper
        self.var = self.tmp / "var"
        self.user = self.var / "folders" / "ab" / "cdef"
        self.T, self.C = self.user / "T", self.user / "C"
        for d in (self.T, self.C, self.C / "sub"):
            d.mkdir(parents=True)
        (self.T / "old.txt").write_text("old\n")
        (self.T / "same.txt").write_text("aaaa\n")
        (self.T / "kind").write_text("k\n")
        os.mkfifo(self.T / "pipe")
        (self.C / "cache.db").write_text("v1\n")
        (self.C / "mode.txt").write_text("m\n")
        (self.C / "mode.txt").chmod(0o600)
        (self.C / "sub" / "inner").write_text("i\n")
        (self.C / "link").symlink_to("target-a")
        (self.tmp / "link").symlink_to(self.user)  # macOS /var -> /private/var: the getconf answer is not physical
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.ev = self.tmp / "evidence"
        self.stub(f"{self.tmp}/link/T/", f"{self.C}/")
        self.boundary = Boundary(self.var) if sys.platform.startswith("linux") else None

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
        if self.boundary is not None:
            self.boundary.arm()
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(self.tmp / "home")}
        r = subprocess.run(["bash", "-c", f'. "$1" && {fn} "$2"', "_", str(self.helper), str(self.ev)],
                           cwd=self.tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        if self.boundary is not None:
            hits.extend(f"{fn}: {e}" for e in self.boundary.collect())
        return r.returncode, r.stdout.decode(errors="replace").splitlines()

    def cycle(self, between=None) -> tuple[int, list[str]]:
        rc, out = self.call("varfolders_begin")
        if rc != 0 or out:
            bad(f"V2 varfolders_begin must be silent and exit 0, got rc={rc} {out[-3:]!r}")
        if between is not None:
            between(self)
        return self.call("varfolders_end")

    def close(self) -> None:
        if self.boundary is not None:
            self.boundary.close()
        for dirpath, dirs, _names in os.walk(self.tmp):
            for d in dirs:
                p = Path(dirpath) / d
                if not p.is_symlink():
                    os.chmod(p, 0o700)
        shutil.rmtree(self.tmp)


def record(p: Path) -> str:
    """This test's own record of one path, in the contract's form."""
    st = os.lstat(p)
    kind = next((k for test, k in KIND if test(st.st_mode)), "o")
    sha = hashlib.sha256(p.read_bytes()).hexdigest() if kind == "f" else "-"
    link = os.readlink(p) if kind == "l" else "-"
    return f"{kind} {stat.S_IMODE(st.st_mode):o} {st.st_size} {st.st_mtime_ns} {st.st_ino} {sha} {link}"


def observe(box: Box) -> dict:
    out = {}
    for token, base in (("T", box.T), ("C", box.C)):
        for dirpath, dirs, names in os.walk(base):
            for n in dirs + names:
                p = Path(dirpath) / n
                out[(token, str(p.relative_to(base)))] = record(p)
    return out


def order(key):
    return key[0], os.fsencode(key[1])


def want_deltas(before: dict, after: dict) -> list[tuple]:
    rows = []
    for key in sorted(set(before) | set(after), key=order):
        b, a = before.get(key), after.get(key)
        if b != a:
            rows.append(("VARFOLDERS-DELTA", "added" if b is None else "removed" if a is None else "changed",
                         key[0], key[1], b or "-", a or "-"))
    return rows


def parse(row: str, rc: int, out: list[str], want_roots: str | None) -> tuple[str, list[tuple]] | None:
    """The end output's exact structure; returns (final word, deltas), or records a problem under `row`."""
    rest = list(out)
    if want_roots is not None:
        if not rest or rest[0] != want_roots:
            bad(f"{row} want the first line {want_roots!r}, got {rest[:1]!r}")
            return None
        rest = rest[1:]
    elif rest and rest[0].startswith("VARFOLDERS_ROOTS\t"):
        rest = rest[1:]
    if not rest or not rest[-1].startswith("VARFOLDERS\t"):
        bad(f"{row} want a final VARFOLDERS line, got {out[-3:]!r}")
        return None
    final = rest[-1].split("\t")
    deltas = [tuple(l.split("\t")) for l in rest[:-1]]
    if any(len(d) != 6 or d[0] != "VARFOLDERS-DELTA" for d in deltas):
        bad(f"{row} every line between the roots and the final line must be a six-field delta, got {rest[:-1]!r}")
        return None
    if final[1] == "COMPLETE":
        if rc != 0 or len(final) != 3 or final[2] != str(len(deltas)):
            bad(f"{row} COMPLETE must exit 0 and count its {len(deltas)} deltas, got rc={rc} {rest[-1]!r}")
            return None
        for d in deltas:
            kind, before, after = d[1], d[4], d[5]
            if kind not in ("added", "changed", "removed") or d[2] not in ("T", "C") \
                    or (before == "-") != (kind == "added") or (after == "-") != (kind == "removed"):
                bad(f"{row} malformed delta {d!r}")
                return None
        return "COMPLETE", deltas
    if final[1] == "INCONCLUSIVE":
        if rc != 2 or deltas or len(final) < 3:
            bad(f"{row} INCONCLUSIVE must exit 2 with a reason and no delta, got rc={rc} {rest!r}")
            return None
        return "INCONCLUSIVE", []
    bad(f"{row} unknown final line {rest[-1]!r}")
    return None


def inconclusive(row: str, box: Box, rc: int, out: list[str]) -> None:
    got = parse(row, rc, out, None)
    if got is not None and got[0] != "INCONCLUSIVE":
        bad(f"{row} want INCONCLUSIVE exit 2, got rc={rc} {out[-3:]!r}")


def run_rows(helper: Path) -> list[str]:
    global failures, hits
    failures, hits = [], []
    if not helper.is_file():
        return [f"the helper {helper} does not exist"]
    if not sys.platform.startswith("linux"):
        return ["V9 the mutation boundary needs Linux inotify: run this on the Linux gate"]

    box = Box(helper)
    try:  # V9 the boundary is live: it sees this test's own create and delete while armed
        box.boundary.arm()
        probe = box.C / "sub" / "zb-boundary-probe"
        probe.write_text("p")
        probe.unlink()
        if len(box.boundary.collect()) < 2:
            bad("V9 the inotify boundary did not see a create and delete under a root: it would prove nothing")
    finally:
        box.close()

    box = Box(helper)
    try:  # V1 + V2 + V8
        untouched = observe(box)
        rc, out = box.cycle()
        if observe(box) != untouched:
            bad("V8 a begin/end cycle changed, added or deleted an entry under a root")
        want = f"VARFOLDERS_ROOTS\tT\t{box.T}\tC\t{box.C}"
        if sum(1 for l in out if l.startswith("VARFOLDERS_ROOTS\t")) != 1:
            bad(f"V1 want exactly one VARFOLDERS_ROOTS line, got {out!r}")
        got = parse("V1/V2", rc, out, want)
        if got is not None and got != ("COMPLETE", []):
            bad(f"V2 no change: want COMPLETE 0 and no delta, got {out[-3:]!r}")
    finally:
        box.close()

    box = Box(helper)
    try:  # V3 + V4 + V8
        state = {}

        def change(b):
            state["before"] = observe(b)
            (b.T / "new.txt").write_text("n\n")
            (b.T / "d" / "e").mkdir(parents=True)
            (b.T / "d" / "e" / "f.bin").write_bytes(b"\x00\x01")
            (b.C / "cache.db").write_text("v2 longer\n")
            (b.C / "com.apple.WebKit.Networking").mkdir()
            (b.C / ".DS_Store").write_text("x")
            (b.T / "zigBrowser-run.log").write_text("z")
            (b.T / "old.txt").unlink()
            same = b.T / "same.txt"  # same size, same inode, mtime restored: only the bytes differ
            st = os.lstat(same)
            with open(same, "r+b") as f:
                f.write(b"bbbb\n")
            os.utime(same, ns=(st.st_atime_ns, st.st_mtime_ns))
            (b.C / "link").unlink()
            (b.C / "link").symlink_to("target-b")
            (b.T / "kind").unlink()
            (b.T / "kind").mkdir()
            (b.C / "mode.txt").chmod(0o640)
            (b.T / "pipe").unlink()  # a FIFO's record (type p) is exact too
            state["after"] = observe(b)
        rc, out = box.cycle(change)
        paths = sorted((d[1], d[2], d[3]) for d in want_deltas(state["before"], state["after"]))
        named = sorted([("added", "T", "new.txt"), ("added", "T", "d"), ("added", "T", "d/e"),
                        ("added", "T", "d/e/f.bin"), ("changed", "C", "cache.db"),
                        ("added", "C", "com.apple.WebKit.Networking"), ("added", "C", ".DS_Store"),
                        ("added", "T", "zigBrowser-run.log"), ("removed", "T", "old.txt"),
                        ("changed", "T", "same.txt"), ("changed", "C", "link"), ("changed", "T", "kind"),
                        ("changed", "C", "mode.txt"), ("removed", "T", "pipe")])
        if paths != named:  # this test's own records must see every change it made (not size/mtime only)
            bad(f"V3 this test's own records missed a change: want {named!r}, got {paths!r}")
        want = f"VARFOLDERS_ROOTS\tT\t{box.T}\tC\t{box.C}"
        got = parse("V3", rc, out, want)
        if got is not None:
            exact = want_deltas(state["before"], state["after"])
            if got[0] != "COMPLETE" or got[1] != exact:
                missing = [d for d in exact if d not in got[1]]
                extra = [d for d in got[1] if d not in exact]
                bad(f"V3/V4 want the {len(exact)} exact deltas in order; missing {missing!r}, extra {extra!r}"
                    + ("" if missing or extra else ", out of order"))
        before_end = observe(box)
        box.call("varfolders_end")  # a second end must not touch the roots either
        if observe(box) != before_end:
            bad("V8 a second varfolders_end changed, added or deleted an entry under a root")
    finally:
        box.close()

    for name, damage in (("dropped", lambda ev: [p.unlink() for p in ev.rglob("*before*") if p.is_file()]),
                         ("truncated", lambda ev: [p.write_text((p.read_text().splitlines() or [""])[0] + "\n")
                                                   for p in ev.rglob("*before*") if p.is_file()]),
                         ("no evidence dir", lambda ev: shutil.rmtree(ev))):
        box = Box(helper)
        try:  # V5
            box.call("varfolders_begin")
            damage(box.ev)
            rc, out = box.call("varfolders_end")
            inconclusive(f"V5 {name} before snapshot:", box, rc, out)
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
            inconclusive(f"V6 {name}:", box, rc, out)
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
            inconclusive("V7 an unreadable directory:", box, rc, out)
    finally:
        box.close()

    def repoint(b):  # V10a: the getconf answer changes to another existing pair of directories
        for d in ("T", "C"):
            (b.var / "other" / d).mkdir(parents=True)
        b.stub(f"{b.var}/other/T/", f"{b.var}/other/C/")

    def replace_root(b):  # V10b: the same physical path, another directory
        b.T.rename(b.user / "T.old")
        b.T.mkdir()

    def retarget(b):  # V10c: the symlink the temp answer goes through points at another user dir with its own T
        (b.var / "folders" / "zz" / "yyyy" / "T").mkdir(parents=True)
        (b.tmp / "link").unlink()
        (b.tmp / "link").symlink_to(b.var / "folders" / "zz" / "yyyy")
    for name, between in (("changed getconf answer", repoint), ("replaced temp root", replace_root),
                          ("retargeted root symlink", retarget)):
        box = Box(helper)
        try:  # V10
            rc, out = box.cycle(between)
            inconclusive(f"V10 {name}:", box, rc, out)
        finally:
            box.close()

    for name, fname in (("newline", "a\nb"), ("tab", "a\tb")):
        box = Box(helper)
        try:  # V11
            (box.C / fname).write_text("x")
            rc, out = box.cycle()
            inconclusive(f"V11 a name with a {name}:", box, rc, out)
        finally:
            box.close()

    if hits:
        bad(f"V9 the helper itself changed entries under a root ({len(hits)} inotify events): {hits[:6]!r}")
    return list(failures)


def main(argv: list[str]) -> int:
    helper = Path(argv[1]) if len(argv) > 1 else HELPER
    problems = run_rows(helper)
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL\tmac-varfolders-audit\t{len(problems)} problem(s)")
        return 1
    print("PASS\tmac-varfolders-audit\tV1-V11")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
