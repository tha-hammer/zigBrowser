# shellcheck shell=bash
# The owner's /var/folders rules (2026-10-23/24; SilverRidge 94ebe76b, 30a7a1e8, c65d61e0, 93228b3a), one shared
# helper for every
# Mac gate that launches the browser (the runtime rows gate, the MS1c .app gate). Sourced, never run. A run may write
# under the user's own /var/folders; this records exactly what changed there and writes, changes or deletes nothing
# there itself:
#   varfolders_begin <evidence dir>  resolves the physical per-user roots from getconf DARWIN_USER_TEMP_DIR and
#                                    DARWIN_USER_CACHE_DIR and takes the before snapshot; prints nothing and exits 0
#                                    when it is complete, else refuses (fails closed): exit 2 and one line
#                                    VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>, and the caller must start nothing
#   varfolders_end <evidence dir>    re-resolves the roots, takes the after snapshot and prints exactly:
#     VARFOLDERS_ROOTS<TAB>T<TAB><encoded temp root><TAB>C<TAB><encoded cache root>
#     VARFOLDERS_PARENT<TAB><encoded common per-user parent>   (SilverRidge 3661c9b8: its other entries, such as 0 and X,
#         are a census only, outside the owner's exception; the root token P is that parent without T and C)
#     SKIPPED-PROTECTED<TAB><BEFORE|AFTER><TAB><C|P><TAB><exact path><TAB><EACCES|EPERM>
#         once per exact evidence-derived protected path that cannot be enumerated, ordered by token then path bytes;
#         the path's lstat identity remains when available; an approved lstat denial leaves only the marker
#     VARFOLDERS-DELTA<TAB><added|changed|removed><TAB><C|P|T><TAB><path><TAB><before><TAB><after>
#         one per changed path (each root itself is the path .), ordered by root token then path bytes; <before> is -
#         for an added path and <after> is - for a removed one
#     VARFOLDERS<TAB>COMPLETE<TAB><n>   exit 0: n deltas, all of T or C; a delta alone is reportable and may coexist
#         with PASS
#   or every delta, at least one of P, then VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>   exit 2: a change beside T and C
#         is reported in full and is never a pass
#   or [the roots and parent lines] VARFOLDERS<TAB>INCONCLUSIVE<TAB><reason>   exit 2, no delta: the roots are unusable
#         or changed identity (getconf answer, symlink target, or a directory's device/inode), T and C have no common
#         parent, or a snapshot (of T, C or the parent census) is missing or incomplete
# A snapshot is ROOT<TAB>token<TAB>path<TAB>device<TAB>inode per root, then one line per path, the root (.) and every
# entry below it: token<TAB>path<TAB>"type mode uid gid nlink size mtime_ns ctime_ns inode sha256 link" (type f d l p
# s c b o; sha256 of a regular file's bytes, else -; a symlink's target, else -; ctime catches every other inode
# change, such as an extended attribute or a hard link), in path byte order, then END<TAB><path count>. An entry that
# cannot be read makes the snapshot incomplete except for EACCES/EPERM at the exact six C and nine P protected pairs;
# any other error or path remains incomplete. Every path-bearing field is ``b64:`` plus canonical padded URL-safe
# Base64 of the filesystem bytes, including arbitrary control and non-UTF-8 bytes; decoded bytes determine identity,
# policy and order. A
# protected pair must be skipped on both sides with the same normalized reason. Nothing here uses a here-document
# (macOS /bin/bash 3.2 writes each to a temp file in $TMPDIR, by default
# the audited temp root), and every python3 child runs with TMPDIR set to the evidence dir. /usr/bin/python3 is named
# explicitly (-I -B -X utf8: no user site, no bytecode written anywhere, UTF-8 whatever the locale). The embedded
# sources remain Python 3.9 syntax and the registered codec oracle executes them under Python development warnings.

__VF_SNAPSHOT_PY='
import base64, binascii, errno, hashlib, os, stat, sys
def evidence_field(value):
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")
def decode_field(field):
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    if evidence_field(raw) != field:
        raise ValueError("not a canonical evidence field")
    return raw
roots, root_errors = [], []
try:
    with open(sys.argv[1], encoding="ascii") as source:
        root_lines = source.read().splitlines()
    for line in root_lines:
        token, field = line.split("\t")
        if token not in ("T", "C", "P"):
            raise ValueError("invalid root token")
        roots.append((token, decode_field(field)))
    if [token for token, _root in roots] != ["T", "C", "P"]:
        raise ValueError("invalid root set")
except (OSError, UnicodeError, ValueError, binascii.Error):
    roots = []
    root_errors.append("P\t%s\tmalformed roots evidence" % evidence_field(b"."))
side = sys.argv[3] if len(sys.argv) == 4 else ""
heads, rows, row_keys, errors, skipped = [], [], set(), list(root_errors), {}
PROTECTED = frozenset((
    ("C", b"com.apple.WebKit.GPU.Sandbox"),
    ("C", b"com.apple.WebKit.Networking.Sandbox"),
    ("C", b"com.apple.WebKit.WebContent.Sandbox"),
    ("C", b"com.apple.WorkflowKit.BackgroundShortcutRunner/ShortcutsSandboxCache"),
    ("C", b"com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache"),
    ("C", b"com.apple.siriactionsd/ShortcutsSandboxCache"),
    ("P", b"0/com.apple.LaunchServices.dv"),
    ("P", b"0/com.apple.ScreenTimeAgent/Store"),
    ("P", b"0/com.apple.SharedWebCredentials"),
    ("P", b"0/com.apple.exchangesync"),
    ("P", b"0/com.apple.lockoutagent"),
    ("P", b"0/com.apple.nsurlsessiond"),
    ("P", b"0/com.apple.progressd/ClassKit"),
    ("P", b"0/com.apple.routined/dv"),
    ("P", b"0/dmd"),
))
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"),
        (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))
def error_row(token, rel, e):
    errors.append("%s\t%s\t%s" % (token, evidence_field(rel), " ".join((e.strerror or type(e).__name__).split())))
def unreadable(token, rel, e):
    if side in ("BEFORE", "AFTER") and (token, rel) in PROTECTED and e.errno in (errno.EACCES, errno.EPERM):
        skipped[(token, rel)] = errno.errorcode[e.errno]
        return True
    error_row(token, rel, e)
    return False
def digest(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    h = hashlib.sha256()
    with os.fdopen(fd, "rb") as stream:
        for chunk in iter(lambda: stream.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()
def entry(token, root, path, rel):
    rel = os.fsencode(rel)
    key = (token, rel)
    if key in row_keys:
        return
    try:
        st = os.lstat(path)
        kind = next((name for test, name in KIND if test(st.st_mode)), "o")
        link = os.readlink(path) if kind == "l" else None
    except OSError as e:
        if key in skipped and e.errno in (errno.EACCES, errno.EPERM):
            return
        error_row(token, rel, e)
        return
    try:
        sha = digest(path) if kind == "f" else "-"
    except OSError as e:
        if not unreadable(token, rel, e):
            return
        sha = "-"
    link_field = evidence_field(link) if kind == "l" else "-"
    meta = "%s %o %d %d %d %d %d %d %d %s %s" % (kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_nlink,
                                                st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, sha, link_field)
    rows.append((token, rel, "%s\t%s\t%s" % (token, evidence_field(rel), meta)))
    row_keys.add(key)
skip = {os.path.basename(root) for token, root in roots if token in ("T", "C")}
for token, root in roots:
    def err(e, token=token, root=root):
        named = os.fsencode(e.filename) if e.filename else b"?"
        rel = os.path.relpath(named, root)
        if unreadable(token, rel, e):
            entry(token, root, named, rel)
    try:
        rst = os.lstat(root)
    except OSError as e:
        err(e)
        continue
    if not stat.S_ISDIR(rst.st_mode):
        errors.append("%s\t%s\tthe root is not a directory" % (token, evidence_field(b".")))
        continue
    heads.append("ROOT\t%s\t%s\t%d\t%d" % (token, evidence_field(root), rst.st_dev, rst.st_ino))
    entry(token, root, root, b".")
    for dirpath, dirs, names in os.walk(root, onerror=err, followlinks=False):
        if token == "P" and dirpath == root:
            dirs[:] = [name for name in dirs if name not in skip]
            names = [name for name in names if name not in skip]
        dirs.sort()
        for name in sorted(dirs + names):
            path = os.path.join(dirpath, name)
            entry(token, root, path, os.path.relpath(path, root))
with open(sys.argv[2], "w", encoding="ascii") as stream:
    for head in heads:
        stream.write(head + "\n")
    for _token, _rel, line in sorted(rows):
        stream.write(line + "\n")
    for (token, rel), reason in sorted(skipped.items()):
        stream.write("SKIPPED-PROTECTED\t%s\t%s\t%s\t%s\n" % (side, token, evidence_field(rel), reason))
    for error in errors:
        stream.write("ERROR\t" + error + "\n")
    stream.write("END\t%d\n" % (len(rows) + len(skipped)))
sys.exit(3 if errors else 0)
'

__VF_DIFF_PY='
import base64, binascii, os, sys
PROTECTED = frozenset((
    ("C", b"com.apple.WebKit.GPU.Sandbox"),
    ("C", b"com.apple.WebKit.Networking.Sandbox"),
    ("C", b"com.apple.WebKit.WebContent.Sandbox"),
    ("C", b"com.apple.WorkflowKit.BackgroundShortcutRunner/ShortcutsSandboxCache"),
    ("C", b"com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache"),
    ("C", b"com.apple.siriactionsd/ShortcutsSandboxCache"),
    ("P", b"0/com.apple.LaunchServices.dv"),
    ("P", b"0/com.apple.ScreenTimeAgent/Store"),
    ("P", b"0/com.apple.SharedWebCredentials"),
    ("P", b"0/com.apple.exchangesync"),
    ("P", b"0/com.apple.lockoutagent"),
    ("P", b"0/com.apple.nsurlsessiond"),
    ("P", b"0/com.apple.progressd/ClassKit"),
    ("P", b"0/com.apple.routined/dv"),
    ("P", b"0/dmd"),
))
def evidence_field(value):
    return "b64:" + base64.urlsafe_b64encode(os.fsencode(value)).decode("ascii")
def decode_field(field):
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    if evidence_field(raw) != field:
        raise ValueError("not a canonical evidence field")
    return raw
def load(path, side):
    try:
        with open(path, encoding="ascii") as source:
            lines = source.read().splitlines()
    except (OSError, UnicodeError):
        return None, None, None, "missing"
    if not lines or not lines[-1].startswith("END\t"):
        return None, None, None, "truncated"
    try:
        heads, index = [], 0
        while index < len(lines) - 1 and lines[index].startswith("ROOT\t"):
            fields = lines[index].split("\t")
            if len(fields) != 5 or fields[1] not in ("T", "C", "P"):
                raise ValueError("malformed root")
            heads.append((fields[1], decode_field(fields[2]), int(fields[3]), int(fields[4])))
            index += 1
        if [head[0] for head in heads] != ["T", "C", "P"]:
            raise ValueError("malformed root set")
        out, row_order, markers, marker_order, seen = {}, [], [], [], set()
        marker_phase = False
        errors = []
        for line in lines[index:-1]:
            if line.startswith("ERROR\t"):
                fields = line.split("\t", 3)
                if len(fields) != 4 or fields[1] not in ("T", "C", "P") or not fields[3]:
                    raise ValueError("malformed error")
                decode_field(fields[2])
                errors.append(line)
                continue
            if line.startswith("SKIPPED-PROTECTED\t"):
                marker_phase = True
                fields = line.split("\t")
                if len(fields) != 5 or fields[1] != side or fields[2] not in ("C", "P") \
                        or fields[4] not in ("EACCES", "EPERM"):
                    raise ValueError("malformed marker")
                rel = decode_field(fields[3])
                key = (fields[2], rel)
                if key not in PROTECTED or key in seen:
                    raise ValueError("malformed marker identity")
                seen.add(key)
                markers.append((key[0], key[1], fields[4]))
                marker_order.append(key)
                continue
            if marker_phase:
                raise ValueError("ordinary row after marker")
            fields = line.split("\t", 2)
            if len(fields) != 3 or fields[0] not in ("T", "C", "P"):
                raise ValueError("malformed row")
            rel = decode_field(fields[1])
            key = (fields[0], rel)
            meta = fields[2].split(" ", 10)
            if len(meta) != 11:
                raise ValueError("malformed metadata")
            if meta[0] == "l":
                decode_field(meta[10])
            elif meta[10] != "-":
                raise ValueError("unexpected link target")
            if key in out:
                raise ValueError("duplicate row")
            out[key] = fields[2]
            row_order.append(key)
        if errors:
            return None, None, None, "incomplete: " + "; ".join(errors[:3])
        if row_order != sorted(row_order, key=lambda key: (key[0], key[1])) \
                or marker_order != sorted(marker_order, key=lambda key: (key[0], key[1])):
            raise ValueError("unordered evidence")
        if lines[-1] != "END\t%d" % (len(out) + len(markers)):
            raise ValueError("wrong end count")
    except (ValueError, binascii.Error):
        return None, None, None, "malformed"
    return heads, out, markers, ""
hb, before, sb, why_b = load(sys.argv[1], "BEFORE")
ha, after, sa, why_a = load(sys.argv[2], "AFTER")
def inconclusive(reason):  # exactly three fields: a reason never holds a tab
    print("VARFOLDERS\tINCONCLUSIVE\t" + " ".join(reason.split()))
    sys.exit(2)
if before is None or after is None:
    inconclusive("before snapshot %s, after snapshot %s" % (why_b or "ok", why_a or "ok"))
if hb != ha:
    inconclusive("a root changed identity during the run: %s -> %s" % (hb, ha))
if sb != sa:
    inconclusive("the protected-skip set changed during the run")
common_markers = set(sb).intersection(sa)
if any(((token, rel) in before) != ((token, rel) in after) for token, rel, _reason in common_markers):
    inconclusive("a protected path changed identity availability during the run")
for side, markers in (("BEFORE", sb), ("AFTER", sa)):
    for token, rel, reason in markers:
        print("SKIPPED-PROTECTED\t%s\t%s\t%s\t%s" % (side, token, evidence_field(rel), reason))
rows = []
for key in sorted(set(before) | set(after), key=lambda item: (item[0], item[1])):
    b, a = before.get(key), after.get(key)
    if b == a:
        continue
    kind = "added" if b is None else "removed" if a is None else "changed"
    rows.append((key[0], "VARFOLDERS-DELTA\t%s\t%s\t%s\t%s\t%s" %
                 (kind, key[0], evidence_field(key[1]), b or "-", a or "-")))
for _token, row in rows:
    print(row)
outside = sum(1 for token, _row in rows if token == "P")
if outside:  # every delta is printed above; a change outside the reviewed T/C roots is never a pass
    inconclusive("%d change(s) outside the reviewed T/C roots, beside them in the per-user parent" % outside)
print("VARFOLDERS\tCOMPLETE\t%d" % len(rows))
'

__vf_roots() { # $1=evidence dir; prints tokens plus canonical encoded physical paths, or a reason on stderr; 1
  local ev="${1:?evidence dir}" t c pt pc pp et ec ep
  t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || { echo "getconf DARWIN_USER_TEMP_DIR failed" >&2; return 1; }
  c=$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null) || { echo "getconf DARWIN_USER_CACHE_DIR failed" >&2; return 1; }
  [ -n "$t" ] && [ -n "$c" ] || { echo "getconf gave an empty root" >&2; return 1; }
  pt=$(cd -- "$t" 2>/dev/null && pwd -P) || { echo "temp root $t is not a directory" >&2; return 1; }
  pc=$(cd -- "$c" 2>/dev/null && pwd -P) || { echo "cache root $c is not a directory" >&2; return 1; }
  [ "$pt" != "$pc" ] || { echo "temp and cache roots are the same directory $pt" >&2; return 1; }
  pp=${pt%/*}   # the per-user parent: its other entries (0, X, ...) are census-only, outside the exception
  [ -n "$pp" ] && [ "${pc%/*}" = "$pp" ] \
    || { echo "temp root $pt and cache root $pc have no common parent" >&2; return 1; }
  et=$(__vf_field "$ev" "$pt") && ec=$(__vf_field "$ev" "$pc") && ep=$(__vf_field "$ev" "$pp") \
    || { echo "root path encoding failed" >&2; return 1; }
  printf 'T\t%s\nC\t%s\nP\t%s\n' "$et" "$ec" "$ep"
}

__vf_python() { # $1=evidence dir, then the python3 arguments: a child that never writes under the audited roots
  local ev="$1"; shift
  TMPDIR="$ev/" /usr/bin/python3 -I -B -X utf8 "$@"
}

__vf_field() { # $1=evidence dir, $2=one filesystem path; canonical padded URL-safe Base64 over os.fsencode bytes
  local ev="$1" value="$2"
  __vf_python "$ev" -c 'import base64, os, sys; print("b64:" + base64.urlsafe_b64encode(os.fsencode(sys.argv[1])).decode("ascii"))' "$value"
}

__vf_refuse() { # $1=reason: the one bounded line of a refused begin (fail closed, SilverRidge 3661c9b8)
  local why="${1//$'\t'/ }"
  why="${why//$'\n'/ }"
  printf 'VARFOLDERS\tINCONCLUSIVE\tbegin refused, no complete before snapshot: %s\n' "${why:0:400}"
  return 2
}

varfolders_begin() { # $1=evidence dir; exit 0 with a complete before snapshot, else 2 (refused: start nothing)
  local ev="${1:?evidence dir}"
  mkdir -p -- "$ev" 2>/dev/null && ev=$(cd -- "$ev" 2>/dev/null && pwd -P) \
    || { __vf_refuse "the evidence dir $1 cannot be made"; return; }   # one line only: mkdir's own message is dropped
  if ! __vf_roots "$ev" > "$ev/varfolders-roots" 2> "$ev/varfolders-roots.err"; then
    __vf_refuse "$(cat "$ev/varfolders-roots.err" 2>/dev/null)"
    return
  fi
  if ! __vf_python "$ev" -c "$__VF_SNAPSHOT_PY" "$ev/varfolders-roots" "$ev/varfolders-before.tsv" BEFORE \
      2> "$ev/varfolders-before.err"; then
    __vf_refuse "$(grep -m 3 '^ERROR' "$ev/varfolders-before.tsv" 2>/dev/null || cat "$ev/varfolders-before.err")"
    return
  fi
}

varfolders_end() { # $1=evidence dir; exit 0 COMPLETE, 2 INCONCLUSIVE
  local ev="${1:?evidence dir}" now why rt rc rp
  if ! ev=$(cd -- "$ev" 2>/dev/null && pwd -P) || ! [ -s "$ev/varfolders-roots" ]; then
    why=$(tr '\n' ' ' 2>/dev/null < "$ev/varfolders-roots.err")
    printf 'VARFOLDERS\tINCONCLUSIVE\tno recorded roots: %s\n' "${why:-the evidence dir or its roots file is missing}"
    return 2
  fi
  now=$(__vf_roots "$ev" 2>&1) || { printf 'VARFOLDERS\tINCONCLUSIVE\troots now unusable: %s\n' "${now//$'\t'/ }"; return 2; }
  if [ "$now" != "$(cat "$ev/varfolders-roots")" ]; then
    printf 'VARFOLDERS\tINCONCLUSIVE\tthe roots changed during the run\n'
    return 2
  fi
  { IFS= read -r rt && IFS= read -r rc && IFS= read -r rp; } < "$ev/varfolders-roots"   # plain bash: BSD sed, tr differ
  printf 'VARFOLDERS_ROOTS\t%s\t%s\n' "$rt" "$rc"
  printf 'VARFOLDERS_PARENT\t%s\n' "${rp#P$'\t'}"
  __vf_python "$ev" -c "$__VF_SNAPSHOT_PY" "$ev/varfolders-roots" "$ev/varfolders-after.tsv" AFTER \
    2> "$ev/varfolders-after.err"
  __vf_python "$ev" -c "$__VF_DIFF_PY" "$ev/varfolders-before.tsv" "$ev/varfolders-after.tsv"
}
