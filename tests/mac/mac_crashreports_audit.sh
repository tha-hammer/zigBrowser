# shellcheck shell=bash
# The crash-report rule for Mac gates that launch the browser (orchestrator 2026-10-23; the owner's exception for a
# crash report covers only the MS1c missing-dylib control). Sourced, never run. Read-only: it lists the Mac user's real
# ~/Library/Logs/DiagnosticReports before and after a run and writes, changes or deletes nothing there:
#   crashreports_begin <evidence dir> <reports dir>  records the before listing in <evidence dir>; prints nothing and
#                                    exits 0 when it is complete (a missing reports dir is an empty listing), else
#                                    refuses: exit 2 and one CRASHREPORTS<TAB>INCONCLUSIVE<TAB><reason> line
#   crashreports_end <evidence dir> <reports dir>    records the after listing and prints exactly:
#     CRASHREPORT<TAB><added|changed|removed><TAB><path><TAB><sha256>   one per entry that differs, in path byte order
#         (the reports dir itself is the path ., so a dir that appears or goes away during the run is reported)
#         (the sha256 of a regular file's bytes, after the run, or before it for a removed one; - for a directory or
#         other entry type)
#     CRASHREPORTS<TAB>COMPLETE<TAB>0                exit 0: no report appeared, changed or went away
#   or CRASHREPORTS<TAB>INCONCLUSIVE<TAB><reason>    exit 2: any CRASHREPORT line above (a crash report is never a
#         pass), or, with no CRASHREPORT line, a listing that is missing or incomplete, or a reports dir that changed
# A listing is DIR<TAB><path> (or ABSENT<TAB><path> when there is no reports dir) and then one line per entry below it:
# path<TAB>"type sha256" (type f d l p s c b o), then END<TAB><entry count>. An entry that cannot be read, or recorded
# unambiguously (not UTF-8, or a tab or newline in its name), makes it incomplete. As tests/mac/mac_varfolders_audit.sh:
# no here-document, and every /usr/bin/python3 child runs -I -B -X utf8 with TMPDIR set to the evidence dir.

__CR_LIST_PY='
import hashlib, os, stat, sys
top, out = sys.argv[1], sys.argv[2]
rows, errors = [], []
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"),
        (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))
def digest(p):
    fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    h = hashlib.sha256()
    with os.fdopen(fd, "rb") as f:
        for chunk in iter(lambda: f.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()
def err(e):
    errors.append("%s: %s" % (os.path.relpath(e.filename, top) if e.filename else "?", e.strerror))
head = "ABSENT\t" + top
try:
    tst = os.lstat(top)
except FileNotFoundError:
    tst = None
except OSError as e:
    tst = None
    errors.append("the reports dir: %s" % e.strerror)
if tst is not None:
    if not stat.S_ISDIR(tst.st_mode):
        errors.append("the reports dir is not a directory")
    else:
        head = "DIR\t" + top
        rows.append((b".", ".\td -"))  # the reports dir itself: appearing or going away is a change too
        for dirpath, dirs, names in os.walk(top, onerror=err, followlinks=False):
            dirs.sort()
            for n in sorted(dirs + names):
                p = os.path.join(dirpath, n)
                rel = os.path.relpath(p, top)
                try:
                    rel.encode("utf-8")
                except UnicodeEncodeError:
                    errors.append("%r: a name that is not UTF-8 cannot be recorded" % rel)
                    continue
                if "\t" in rel or "\n" in rel:
                    errors.append("%r: a tab or newline in a name cannot be recorded" % rel)
                    continue
                try:
                    st = os.lstat(p)
                    kind = next((k for test, k in KIND if test(st.st_mode)), "o")
                    sha = digest(p) if kind == "f" else "-"
                except OSError as e:
                    err(e)
                    continue
                rows.append((os.fsencode(rel), "%s\t%s %s" % (rel, kind, sha)))
with open(out, "w", encoding="utf-8") as f:
    f.write(head + "\n")
    for _r, line in sorted(rows):
        f.write(line + "\n")
    for e in errors:
        f.write("ERROR\t" + e + "\n")
    f.write("END\t%d\n" % len(rows))
sys.exit(3 if errors else 0)
'

__CR_DIFF_PY='
import os, sys
def inconclusive(reason):
    print("CRASHREPORTS\tINCONCLUSIVE\t" + " ".join(reason.split()))
    sys.exit(2)
def load(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeError):
        return None, None, "missing"
    if len(lines) < 2 or not lines[-1].startswith("END\t") or not lines[0].startswith(("DIR\t", "ABSENT\t")):
        return None, None, "truncated"
    body = lines[1:-1]
    errs = [l for l in body if l.startswith("ERROR\t")]
    if errs:
        return None, None, "incomplete: " + "; ".join(errs)
    if lines[-1] != "END\t%d" % len(body):
        return None, None, "truncated"
    out = {}
    for l in body:
        rel, meta = l.split("\t", 1)
        out[rel] = meta.split(" ")
    return lines[0].split("\t", 1)[1], out, ""
tb, before, why_b = load(sys.argv[1])
ta, after, why_a = load(sys.argv[2])
if before is None or after is None:
    inconclusive("before listing %s, after listing %s" % (why_b or "ok", why_a or "ok"))
if tb != ta:
    inconclusive("the reports dir changed during the run: %s -> %s" % (tb, ta))
rows = []
for rel in sorted(set(before) | set(after), key=os.fsencode):
    b, a = before.get(rel), after.get(rel)
    if b == a:
        continue
    kind = "added" if b is None else "removed" if a is None else "changed"
    rows.append("CRASHREPORT\t%s\t%s\t%s" % (kind, rel, (a or b)[1]))
for r in rows:
    print(r)
if rows:
    inconclusive("%d crash report change(s) during the run: a crash report is never a pass" % len(rows))
print("CRASHREPORTS\tCOMPLETE\t0")
'

__cr_python() { # $1=evidence dir, then the python3 arguments
  local ev="$1"; shift
  TMPDIR="$ev/" /usr/bin/python3 -I -B -X utf8 "$@"
}

__cr_refuse() { # $1=reason: the one bounded line of a refused begin (fail closed, as varfolders_begin)
  local why="${1//$'\t'/ }"
  why="${why//$'\n'/ }"
  printf 'CRASHREPORTS\tINCONCLUSIVE\tbegin refused, no complete before listing: %s\n' "${why:0:400}"
  return 2
}

crashreports_begin() { # $1=evidence dir $2=reports dir; exit 0 with a complete before listing, else 2 (start nothing)
  local ev="${1:?evidence dir}" top="${2:?reports dir}"
  mkdir -p -- "$ev" 2>/dev/null && ev=$(cd -- "$ev" 2>/dev/null && pwd -P) \
    || { __cr_refuse "the evidence dir $1 cannot be made"; return; }
  { printf '%s\n' "$top" > "$ev/crashreports-dir"; } 2>/dev/null || { __cr_refuse "the evidence dir cannot be written"; return; }
  if ! __cr_python "$ev" -c "$__CR_LIST_PY" "$top" "$ev/crashreports-before.tsv" 2> "$ev/crashreports-before.err"; then
    __cr_refuse "$(grep -m 3 '^ERROR' "$ev/crashreports-before.tsv" 2>/dev/null || cat "$ev/crashreports-before.err")"
    return
  fi
}

crashreports_end() { # $1=evidence dir $2=reports dir; exit 0 COMPLETE, 2 INCONCLUSIVE
  local ev="${1:?evidence dir}" top="${2:?reports dir}"
  if ! ev=$(cd -- "$ev" 2>/dev/null && pwd -P) || [ "$(cat "$ev/crashreports-dir" 2>/dev/null)" != "$top" ]; then
    printf 'CRASHREPORTS\tINCONCLUSIVE\tno before listing of %s\n' "${top//$'\t'/ }"
    return 2
  fi
  __cr_python "$ev" -c "$__CR_LIST_PY" "$top" "$ev/crashreports-after.tsv" 2> "$ev/crashreports-after.err"
  __cr_python "$ev" -c "$__CR_DIFF_PY" "$ev/crashreports-before.tsv" "$ev/crashreports-after.tsv"
}
