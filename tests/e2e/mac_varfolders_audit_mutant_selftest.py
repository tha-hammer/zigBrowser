#!/usr/bin/env python3
"""The owner's /var/folders rule (2026-10-23; SilverRidge 94ebe76b, 30a7a1e8, c65d61e0, f0590a29): the registered
audit rows reject every helper that hides, guesses, mis-records, or writes under the roots itself.

Each case writes an altered copy of tests/mac/mac_varfolders_audit.sh to a private temporary directory (the repository
is never edited), runs the REAL rows of tests/e2e/mac_varfolders_audit_test.py and
tests/e2e/mac_varfolders_census_test.py against it, and requires them to fail;
the unaltered helper (the control) and K1 must pass. Each substitution must occur exactly once, so a drifted helper
fails here instead of passing vacuously. The mutants:
- B1-B6 the helper itself makes a change under a root and undoes it: a transient file (in root discovery), directory,
  symlink or FIFO, a write with its bytes and mtime restored, a chmod to the same mode (the inotify boundary, V9);
- MF a filtered delta (com.apple.*); MD a missing before snapshot read as empty; MB, ME a delete under a root in
  begin and in end; MU an unreadable directory silently skipped;
- S1-S4 a record without the content digest, the link target or the mode, or with the types collapsed;
- D1-D6 before/after swapped, an empty absent side, kind-first order, a wrong count, an extra line, deltas printed
  before an identity INCONCLUSIVE;
- R1, R3, R4 no device/inode binding, no identity check at all, no record of the root itself;
- C1, C2 a record without ctime or without nlink;
- P1-P5 an empty INCONCLUSIVE reason; a malformed, duplicate, or re-resolved roots line; a reason holding tabs;
- U1 a name that is not UTF-8 silently skipped;
- H1 a here-document (macOS /bin/bash 3.2 writes it to a temp file in $TMPDIR, the temp root by default);
- H2 a python3 child without the helper's TMPDIR override that makes a temp file;
- SP1-SP6 the parent census broken: the parent's entries not walked, a change beside T/C still COMPLETE, the parent's
  deltas hidden with the INCONCLUSIVE kept, no common-parent check, no parent line, T and C counted again in it;
- PS1, PS2 a parent entry whose name cannot be recorded silently skipped, or normalized and recorded;
- F2 an evidence dir that cannot be made fails open (V19);
- F1 begin fails open again (1362d73a's ignore-and-run: a failed root discovery or an incomplete before snapshot
  still exits 0, so a caller would launch a browser without a complete before image; V15, SilverRidge 3661c9b8);
- K1 (a control that must pass): that same temp file WITH the override lands outside the roots.
The deletes name only the rows' own fixture files, inside the rows' private temporary roots (their getconf stub is
first on PATH), and run only on Linux (the rows refuse to start elsewhere). Like V7, this runs as a non-root user.
Run: python3 tests/e2e/mac_varfolders_audit_mutant_selftest.py   (registered: zig build test-mac-varfolders-audit)
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mac_varfolders_audit_test as audit  # noqa: E402
import mac_varfolders_census_test as census  # noqa: E402

ROOTS_OK = '  [ "$pt" != "$pc" ] || { echo "temp and cache roots are the same directory $pt" >&2; return 1; }\n'
BEGIN_SNAP = ("""    __vf_refuse "$(grep -m 3 '^ERROR' "$ev/varfolders-before.tsv" 2>/dev/null || cat "$ev/varfolders-before.err")"\n"""
              "    return\n  fi\n")  # the end of begin, after a complete before snapshot
END_SNAP = '  __vf_python "$ev" -c "$__VF_SNAPSHOT_PY" "$ev/varfolders-roots" "$ev/varfolders-after.tsv" \\\n'
EACH = '  while IFS=$\'\\t\' read -r _ r; do %s; done < "$ev/varfolders-roots"\n'
REWRITE = ('/usr/bin/python3 -c "import os,sys\nfor n in os.listdir(sys.argv[1]):\n p=os.path.join(sys.argv[1],n)\n'
           " if os.path.isfile(p) and not os.path.islink(p):\n  st=os.stat(p); b=open(p,'rb').read(); open(p,'wb').write(b)"
           '; os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))" "$r"')
RECHMOD = ('/usr/bin/python3 -c "import os,stat,sys\nfor n in os.listdir(sys.argv[1]):\n p=os.path.join(sys.argv[1],n)\n'
           ' os.chmod(p, stat.S_IMODE(os.lstat(p).st_mode)) if not os.path.islink(p) else None" "$r"')
IDENT = 'if hb != ha:\n    inconclusive("a root changed identity during the run: %s -> %s" % (hb, ha))\n'
FINAL = 'print("VARFOLDERS\\tCOMPLETE\\t%d" % len(rows))\n'
ROOTS_LINE = "  printf 'VARFOLDERS_ROOTS\\t%s\\t%s\\n' \"$rt\" \"$rc\"\n"
SHELL_CHECK = '  if [ "$now" != "$(cat "$ev/varfolders-roots")" ]; then\n'
DIFF_CALL = '  __vf_python "$ev" -c "$__VF_DIFF_PY" "$ev/varfolders-before.tsv" "$ev/varfolders-after.tsv"\n'
SNAP_IMPORTS = "import hashlib, os, stat, sys\n"
TEMP_FILE = SNAP_IMPORTS + "import tempfile\ntempfile.NamedTemporaryFile().close()\n"

MUTANTS = [
    ("B1 transient file in root discovery", [(ROOTS_OK, ROOTS_OK + '  : > "$pt/.zb-vf-transient"; rm -f -- "$pt/.zb-vf-transient"\n')]),
    ("B2 transient directory in begin", [(BEGIN_SNAP, BEGIN_SNAP + EACH % 'mkdir -- "$r/.zbd" && rmdir -- "$r/.zbd"')]),
    ("B3 transient symlink in end", [(END_SNAP, EACH % 'ln -s x "$r/.zbl" && rm -f -- "$r/.zbl"' + END_SNAP)]),
    ("B4 transient FIFO in end", [(END_SNAP, EACH % 'mkfifo "$r/.zbp" && rm -f -- "$r/.zbp"' + END_SNAP)]),
    ("B5 write then restore (bytes, mtime) in end", [(END_SNAP, EACH % REWRITE + END_SNAP)]),
    ("B6 chmod to the same mode in begin", [(BEGIN_SNAP, BEGIN_SNAP + EACH % RECHMOD)]),
    ("MF filtered delta (com.apple)", [("    if b == a:\n        continue\n",
                                        '    if b == a or key[1].startswith("com.apple"):\n        continue\n')]),
    ("MD missing before read as empty", [('        return None, None, "missing"\n', '        return "SAME", {}, ""\n'),
                                         ("if hb != ha:", 'if hb != ha and hb != "SAME":')]),
    ("MB delete in begin", [(BEGIN_SNAP, BEGIN_SNAP + EACH % 'rm -f -- "${r:?}/cache.db"')]),
    ("ME delete in end", [(END_SNAP, EACH % 'rm -f -- "${r:?}/zigBrowser-run.log"' + END_SNAP)]),
    ("MU unreadable directory skipped", [("onerror=err, followlinks=False", "onerror=None, followlinks=False")]),
    ("S1 no content digest", [('        sha = digest(p) if kind == "f" else "-"\n', '        sha = "-"\n')]),
    ("S2 no symlink target", [('        link = os.readlink(p) if kind == "l" else "-"\n', '        link = "-"\n')]),
    ("S3 no mode", [("(kind, stat.S_IMODE(st.st_mode), st.st_uid", "(kind, 0, st.st_uid")]),
    ("S4 types collapsed (f/d/l only)", [('kind = next((k for test, k in KIND if test(st.st_mode)), "o")',
                                          'kind = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) '
                                          'else "f" if stat.S_ISREG(st.st_mode) else "d"')]),
    ("D1 before and after swapped", [('b or "-", a or "-"', 'a or "-", b or "-"')]),
    ("D2 absent side empty, not -", [('b or "-", a or "-"', 'b or "", a or ""')]),
    ("D3 ordered by delta kind first", [("for r in rows:\n", "for r in sorted(rows):\n")]),
    ("D4 count off by one", [(FINAL, 'print("VARFOLDERS\\tCOMPLETE\\t%d" % (len(rows) + 1))\n')]),
    ("D5 an extra output line", [(FINAL, 'print("VARFOLDERS-NOTE\\tsnapshot taken")\n' + FINAL)]),
    ("D6 deltas printed before an identity INCONCLUSIVE", [(IDENT, ""), (FINAL, IDENT + FINAL)]),
    ("R1 no device/inode binding", [(IDENT, "")]),
    ("R3 no identity checks at all", [(IDENT, ""), (SHELL_CHECK, "  if false; then\n")]),
    ("R4 no record of the root itself", [('    entry(token, root, root, ".")\n', "")]),
    ("C1 no ctime", [("st.st_mtime_ns, st.st_ctime_ns, st.st_ino", "st.st_mtime_ns, 0, st.st_ino")]),
    ("C2 no nlink", [("st.st_gid, st.st_nlink,", "st.st_gid, 1,")]),
    ("P1 empty INCONCLUSIVE reason", [("  printf 'VARFOLDERS\\tINCONCLUSIVE\\tthe roots changed during the run\\n'\n",
                                       "  printf 'VARFOLDERS\\tINCONCLUSIVE\\t\\n'\n")]),
    ("P2 malformed roots line (T only)", [(ROOTS_LINE, "  printf 'VARFOLDERS_ROOTS\\t%s\\n' \"$rt\"\n")]),
    ("P3 duplicate roots line", [(ROOTS_LINE, ROOTS_LINE + ROOTS_LINE)]),
    ("P4 roots line from the re-resolved roots, before the identity check",
     [(SHELL_CHECK, "  printf 'VARFOLDERS_ROOTS\\t%s\\n' \"${now//$'\\n'/$'\\t'}\"\n" + SHELL_CHECK)]),
    ("P5 a reason holding tabs", [('" ".join(reason.split())', "reason")]),
    ("U1 a non-UTF-8 name silently skipped",
     [('        errors.append("%s\\t%r\\ta name or link target that is not UTF-8 cannot be recorded" % (token, rel))\n',
       "")]),
    ("H1 a here-document", [(DIFF_CALL, '  __vf_python "$ev" - "$ev/varfolders-before.tsv" "$ev/varfolders-after.tsv"'
                                        ' <<EOF\n$__VF_DIFF_PY\nEOF\n')]),
    ("H2 a python3 child without the TMPDIR override makes a temp file",
     [('  TMPDIR="$ev/" /usr/bin/python3', "  /usr/bin/python3"), (SNAP_IMPORTS, TEMP_FILE)]),
]
MUTANTS.append(("F1 begin fails open (ignore and run)", [
    ('    __vf_refuse "$(cat "$ev/varfolders-roots.err" 2>/dev/null)"\n    return\n', "    return 0\n"),
    ("""    __vf_refuse "$(grep -m 3 '^ERROR' "$ev/varfolders-before.tsv" 2>/dev/null || cat "$ev/varfolders-before.err")"\n    return\n""",
     "    return 0\n")]))
BS = "\\"
UTF_ERR = ('        errors.append("%s' + BS + 't%r' + BS + 'ta name or link target that is not UTF-8 cannot be recorded" '
           '% (token, rel))\n        return\n')
TAB_ERR = ('        errors.append("%s' + BS + 't%r' + BS + 'ta tab or newline in the name or link target cannot be recorded" '
           '% (token, rel))\n        return\n')
P_SKIP = '        if token == "P":\n            return\n'


def indented(block: str) -> str:
    return "".join("    " + line if line.strip() else line for line in block.splitlines(True))


MUTANTS += [
    ("SP1 the parent's entries not walked", [
        ("            dirs[:] = [d for d in dirs if d not in skip]\n            names = [n for n in names if n not in skip]\n",
         "            dirs[:] = []\n            names = []\n")]),
    ("SP2 a change beside T/C still COMPLETE", [("if outside:", "if False:")]),
    ("SP3 the parent's deltas hidden, INCONCLUSIVE kept", [("for r in rows:\n    print(r)\n",
                                                           'for r in rows:\n    if r.split("\\t")[2] != "P":\n        print(r)\n')]),
    ("SP4 no common-parent check", [('  [ -n "$pp" ] && [ "${pc%/*}" = "$pp" ] \\\n'
                                     '    || { echo "temp root $pt and cache root $pc have no common parent" >&2; return 1; }\n', "")]),
    ("SP5 no parent line", [("  printf 'VARFOLDERS_PARENT\\t%s\\n' \"${rp#P$'\\t'}\"\n", "")]),
    ("SP6 the census counts T and C again", [('skip = {os.path.basename(r) for t, r in roots if t in ("T", "C")}', "skip = set()")]),
    ("PS1 a P entry with an unrecordable name silently skipped", [(UTF_ERR, P_SKIP + UTF_ERR), (TAB_ERR, P_SKIP + TAB_ERR)]),
    ("PS2 a P entry with an unrecordable name normalized and recorded", [
        (UTF_ERR, '        if token == "P":\n            rel = rel.encode("utf-8", "replace").decode("utf-8")\n        else:\n'
         + indented(UTF_ERR)),
        (TAB_ERR, '        if token == "P":\n            rel = rel.replace("' + BS + 't", " ").replace("' + BS + 'n", " ")\n'
         '        else:\n' + indented(TAB_ERR))]),
    ("F2 an evidence dir that cannot be made fails open", [
        ('    || { __vf_refuse "the evidence dir $1 cannot be made"; return; }   # one line only', "    || return 0   # one line only")]),
]
CONTROLS = [("K1 the same temp file WITH the TMPDIR override", [(SNAP_IMPORTS, TEMP_FILE)])]


def main() -> int:
    problems: list[str] = []
    control = audit.run_rows(audit.HELPER) + census.run_rows(audit.HELPER)
    if control:
        problems.append(f"control: the unaltered helper fails its rows: {control}")
    src = audit.HELPER.read_text()
    with tempfile.TemporaryDirectory(prefix="zb-vf-mut-") as tmp:
        for cases, want_red in ((MUTANTS, True), (CONTROLS, False)):
            for name, subs in cases:
                text = src
                for old, new in subs:
                    if text.count(old) != 1:
                        problems.append(f"{name}: a substitution occurs {text.count(old)} times in the helper, want 1")
                        break
                    text = text.replace(old, new)
                else:
                    mutant = Path(tmp) / "mutant.sh"
                    mutant.write_text(text)
                    failed = audit.run_rows(mutant) + census.run_rows(mutant)  # both registered oracles
                    rows = sorted({f.split()[0] for f in failed})
                    if bool(failed) != want_red:
                        problems.append(f"{name}: {'survived' if want_red else 'failed'}: {failed[:3]}")
                    else:
                        print(f"ok   {name}: {'red at ' + str(rows) if want_red else 'green'}")
    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"FAIL\tmac-varfolders-audit-mutants\t{len(problems)} problem(s)")
        return 1
    print(f"PASS\tmac-varfolders-audit-mutants\t{len(MUTANTS)} helper mutants red, {len(CONTROLS)} control and the "
          "unaltered helper green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
