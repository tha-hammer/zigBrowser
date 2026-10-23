# shellcheck shell=bash
# The owner's /var/folders rule (2026-10-23; SilverRidge 94ebe76b, 30a7a1e8, c65d61e0), one shared helper for every
# Mac gate that launches the browser (the runtime rows gate, the MS1c .app gate). Sourced, never run. A run may write
# under the user's own /var/folders; this records exactly what changed there and writes, changes or deletes nothing
# there itself:
#   varfolders_begin <evidence dir>  prints nothing; resolves the physical per-user roots from getconf
#                                    DARWIN_USER_TEMP_DIR and DARWIN_USER_CACHE_DIR and takes the before snapshot
#   varfolders_end <evidence dir>    re-resolves the roots, takes the after snapshot and prints exactly:
#     VARFOLDERS_ROOTS<TAB>T<TAB><temp root><TAB>C<TAB><cache root>
#     VARFOLDERS-DELTA<TAB><added|changed|removed><TAB><T|C><TAB><path><TAB><before><TAB><after>
#         one per changed path (the root itself is the path .), ordered by root token then path bytes; <before> is -
#         for an added path and <after> is - for a removed one
#     VARFOLDERS<TAB>COMPLETE<TAB><n>   exit 0: n deltas; a delta alone is reportable and may coexist with PASS
#   or [the roots line] VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>   exit 2, no delta: the roots are unusable or changed
#         identity (getconf answer, symlink target, or the directory's device/inode), or a snapshot is missing or
#         incomplete
# A snapshot is ROOT<TAB>token<TAB>path<TAB>device<TAB>inode per root, then one line per path, the root (.) and every
# entry below it: token<TAB>path<TAB>"type mode uid gid nlink size mtime_ns ctime_ns inode sha256 link" (type f d l p
# s c b o; sha256 of a regular file's bytes, else -; a symlink's target, else -; ctime catches every other inode
# change, such as an extended attribute or a hard link), in path byte order, then END<TAB><path count>. An entry that
# cannot be read, or recorded unambiguously (not UTF-8, or a tab or newline in its name or link target), makes it
# incomplete. Nothing here uses a here-document (macOS /bin/bash 3.2 writes each to a temp file in $TMPDIR, by default
# the audited temp root), and every python3 child runs with TMPDIR set to the evidence dir. /usr/bin/python3 is named
# explicitly (-I -B -X utf8: no user site, no bytecode written anywhere, UTF-8 whatever the locale).

__VF_SNAPSHOT_PY='
import hashlib, os, stat, sys
roots = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
heads, rows, errors = [], [], []
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"),
        (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))
def digest(p):
    fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    h = hashlib.sha256()
    with os.fdopen(fd, "rb") as f:
        for chunk in iter(lambda: f.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()
def entry(token, root, p, rel):
    try:
        st = os.lstat(p)
        kind = next((k for test, k in KIND if test(st.st_mode)), "o")
        link = os.readlink(p) if kind == "l" else "-"
        sha = digest(p) if kind == "f" else "-"
    except OSError as e:
        errors.append("%s\t%s\t%s" % (token, rel, e.strerror))
        return
    try:
        rel.encode("utf-8")
        link.encode("utf-8")
    except UnicodeEncodeError:
        errors.append("%s\t%r\ta name or link target that is not UTF-8 cannot be recorded" % (token, rel))
        return
    if any(ch in s for s in (rel, link) for ch in "\t\n"):
        errors.append("%s\t%r\ta tab or newline in the name or link target cannot be recorded" % (token, rel))
        return
    meta = "%s %o %d %d %d %d %d %d %d %s %s" % (kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_nlink,
                                                st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, sha, link)
    rows.append((token, os.fsencode(rel), "%s\t%s\t%s" % (token, rel, meta)))
for token, root in roots:
    def err(e, token=token, root=root):
        rel = os.path.relpath(e.filename, root) if e.filename else "?"
        errors.append("%s\t%s\t%s" % (token, rel, e.strerror))
    try:
        rst = os.lstat(root)
    except OSError as e:
        err(e)
        continue
    if not stat.S_ISDIR(rst.st_mode):
        errors.append("%s\t.\tthe root is not a directory" % token)
        continue
    heads.append("ROOT\t%s\t%s\t%d\t%d" % (token, root, rst.st_dev, rst.st_ino))
    entry(token, root, root, ".")
    for dirpath, dirs, names in os.walk(root, onerror=err, followlinks=False):
        dirs.sort()
        for n in sorted(dirs + names):
            p = os.path.join(dirpath, n)
            entry(token, root, p, os.path.relpath(p, root))
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for h in heads:
        f.write(h + "\n")
    for _t, _r, line in sorted(rows):
        f.write(line + "\n")
    for e in errors:
        f.write("ERROR\t" + e + "\n")
    f.write("END\t%d\n" % len(rows))
sys.exit(3 if errors else 0)
'

__VF_DIFF_PY='
import os, sys
def load(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeError):
        return None, None, "missing"
    if not lines or not lines[-1].startswith("END\t"):
        return None, None, "truncated"
    heads = [l for l in lines[:-1] if l.startswith("ROOT\t")]
    body = [l for l in lines[:-1] if not l.startswith("ROOT\t")]
    errs = [l for l in body if l.startswith("ERROR\t")]
    if errs:
        return None, None, "incomplete: " + "; ".join(errs)
    if len(heads) != 2 or lines[-1] != "END\t%d" % len(body):
        return None, None, "truncated"
    out = {}
    for l in body:
        token, rel, meta = l.split("\t", 2)
        out[(token, rel)] = meta
    return heads, out, ""
hb, before, why_b = load(sys.argv[1])
ha, after, why_a = load(sys.argv[2])
def inconclusive(reason):  # exactly three fields: a reason never holds a tab
    print("VARFOLDERS\tINCONCLUSIVE\t" + " ".join(reason.split()))
    sys.exit(2)
if before is None or after is None:
    inconclusive("before snapshot %s, after snapshot %s" % (why_b or "ok", why_a or "ok"))
if hb != ha:
    inconclusive("a root changed identity during the run: %s -> %s" % (hb, ha))
rows = []
for key in sorted(set(before) | set(after), key=lambda k: (k[0], os.fsencode(k[1]))):
    b, a = before.get(key), after.get(key)
    if b == a:
        continue
    kind = "added" if b is None else "removed" if a is None else "changed"
    rows.append("VARFOLDERS-DELTA\t%s\t%s\t%s\t%s\t%s" % (kind, key[0], key[1], b or "-", a or "-"))
for r in rows:
    print(r)
print("VARFOLDERS\tCOMPLETE\t%d" % len(rows))
'

__vf_roots() { # prints "T<TAB><physical temp>\nC<TAB><physical cache>", or a reason on stderr and returns 1
  local t c pt pc
  t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || { echo "getconf DARWIN_USER_TEMP_DIR failed" >&2; return 1; }
  c=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null) || { echo "getconf DARWIN_USER_CACHE_DIR failed" >&2; return 1; }
  [ -n "$t" ] && [ -n "$c" ] || { echo "getconf gave an empty root" >&2; return 1; }
  pt=$(cd -- "$t" 2>/dev/null && pwd -P) || { echo "temp root $t is not a directory" >&2; return 1; }
  pc=$(cd -- "$c" 2>/dev/null && pwd -P) || { echo "cache root $c is not a directory" >&2; return 1; }
  [ "$pt" != "$pc" ] || { echo "temp and cache roots are the same directory $pt" >&2; return 1; }
  printf 'T\t%s\nC\t%s\n' "$pt" "$pc"
}

__vf_python() { # $1=evidence dir, then the python3 arguments: a child that never writes under the audited roots
  local ev="$1"; shift
  TMPDIR="$ev/" /usr/bin/python3 -I -B -X utf8 "$@"
}

varfolders_begin() { # $1=evidence dir
  local ev="${1:?evidence dir}"
  mkdir -p -- "$ev" && ev=$(cd -- "$ev" && pwd -P) || return 1
  __vf_roots > "$ev/varfolders-roots" 2> "$ev/varfolders-roots.err" || return 0   # end reports INCONCLUSIVE
  __vf_python "$ev" -c "$__VF_SNAPSHOT_PY" "$ev/varfolders-roots" "$ev/varfolders-before.tsv" \
    2> "$ev/varfolders-before.err"
  return 0
}

varfolders_end() { # $1=evidence dir; exit 0 COMPLETE, 2 INCONCLUSIVE
  local ev="${1:?evidence dir}" now why rt rc
  if ! ev=$(cd -- "$ev" 2>/dev/null && pwd -P) || ! [ -s "$ev/varfolders-roots" ]; then
    why=$(tr '\n' ' ' 2>/dev/null < "$ev/varfolders-roots.err")
    printf 'VARFOLDERS\tINCONCLUSIVE\tno recorded roots: %s\n' "${why:-the evidence dir or its roots file is missing}"
    return 2
  fi
  now=$(__vf_roots 2>&1) || { printf 'VARFOLDERS\tINCONCLUSIVE\troots now unusable: %s\n' "${now//$'\t'/ }"; return 2; }
  if [ "$now" != "$(cat "$ev/varfolders-roots")" ]; then
    printf 'VARFOLDERS\tINCONCLUSIVE\tthe roots changed during the run\n'
    return 2
  fi
  { IFS= read -r rt && IFS= read -r rc; } < "$ev/varfolders-roots"   # plain bash: BSD sed and tr differ
  printf 'VARFOLDERS_ROOTS\t%s\t%s\n' "$rt" "$rc"
  __vf_python "$ev" -c "$__VF_SNAPSHOT_PY" "$ev/varfolders-roots" "$ev/varfolders-after.tsv" \
    2> "$ev/varfolders-after.err"
  __vf_python "$ev" -c "$__VF_DIFF_PY" "$ev/varfolders-before.tsv" "$ev/varfolders-after.tsv"
}
