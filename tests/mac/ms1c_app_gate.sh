#!/usr/bin/env bash
# MS1c GATE (plan R30-MS1 Red 2, bd zigBrowser-4pa.73; SilverRidge 94ebe76b): the .app the shipping script makes runs on
# BOTH Macs. It builds ONE universal dmg with packaging/macos/build-dmg.sh at the exact commit ${ZB_GATE_COMMIT:-HEAD},
# copies those exact bytes to each Mac, unpacks the .app inside that Mac's run root and runs the MS1b workload on it.
#
#   - The dmg: build-dmg.sh runs as a subprocess in an isolated clean tree of the commit (git archive, committed as a
#     scratch repo whose tree id must equal the commit's), so its EXIT trap and its fixed dmg name stay out of this
#     script's state. Its SHA-256 is recorded; each leg requires exactly those bytes.
#   - Each Mac: tests/mac/build-on-mac.sh puts the commit's tests and fixtures in a fresh ~/zb-gate-<sha>-<nonce>
#     (mac_gate_lib.sh); every runnable zig-out output is removed before anything runs, so nothing can fall back to it.
#     `hdiutil attach -readonly -nobrowse -noautoopen -mountpoint <run root>/mnt` (device and mountpoint captured, a
#     MOUNTED marker and an EXIT trap detach it on every path), `ditto` the .app into the run root, detach.
#   - Product checks on the unpacked .app: every Mach-O in it is fat with exactly x86_64 and arm64 (`file`, `lipo
#     -archs`); `codesign --verify --strict --deep`; the exe's `otool -L` reference
#     @executable_path/../Frameworks/libwkwebview_shim.dylib resolves to the bundled regular file.
#   - The workload, in a private environment under the run root (HOME, CFFIXED_USER_HOME, TMPDIR, the XDG dirs, the
#     socket and capture dirs, ZB_DEBUG_EPHEMERAL_DATA_STORE=1): m9_render, m9_reply_channel, m9_load_fail and
#     exec_arch_probe with --browser <the unpacked exe>, then the native-arch proof of the MS1b gate. Every browser
#     runs in its own process group and is stopped with SIGTERM only (tests/e2e/mac_term_teardown.py). A LEAK line
#     STOPS THAT HOST: no further row runs there, LEAKED<TAB>... goes to <run root>/LEAKED and the run root is KEPT.
#     The LEAKED marker is durable: written as RUNNING first, removed only by a leg that finished with no leak.
#   - The control (owner decision 2026-10-23, crash reports): a private copy of the .app inside the run root, its
#     dylib removed, launched once (SIGTERM-only teardown); it must exit non-zero with dyld's exact load failure of
#     the bundled shim, referenced from that copy's exe.
#   - Audit: the user's /var/folders roots from getconf DARWIN_USER_TEMP_DIR and DARWIN_USER_CACHE_DIR (physical) and
#     the physical account home (all but this run root) are snapshotted before the workload and after the control.
#     Every /var/folders change is reported (VARFOLDERS-DELTA) and allowed (owner decision 2026-10-23). In the home,
#     the only allowed change is a new crash report under ~/Library/Logs/DiagnosticReports that names the control's
#     exe (CRASHREPORT<TAB>name<TAB>sha256), with that folder's own size/mtime; every other change is HOME-DELTA and
#     INCONCLUSIVE. Nothing is ever deleted outside the run root.
# Verdicts: a product failure (dmg build, signature, inventory, arch, reference, workload, a control that is accepted
# or names the wrong failure) is FAIL; a safety or infrastructure failure (other dmg bytes, leak, held host, a missing
# or incomplete snapshot or evidence, an outside-root write, attach/detach/remove failure, timeout) is INCONCLUSIVE.
# A leg exits 0 PASS, 1 FAIL, 2 INCONCLUSIVE, 3 LEAK (root kept), 4 HELD (nothing ran), 5 DETACH FAILED (root kept).
# Evidence is copied back before any removal; the run prints MANIFEST<TAB><sha256 of its manifest> and EVIDENCE<TAB>dir
# and `PASS<TAB>ms1c-app-gate<TAB>both-arches<TAB><dmg sha256>` only when both legs passed with the same dmg, the
# evidence is complete and every run root was removed. Exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
# Hostless selftest: tests/mac/ms1c_app_gate_selftest.sh.
set -uo pipefail
TAB=$'\t'

cd "$(git rev-parse --show-toplevel)" || exit 2
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
. tests/mac/mac_gate_lib.sh
TOP=$PWD
COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}") || { echo "INCONCLUSIVE: no commit" >&2; exit 2; }
BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-900}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1200}"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-stage-XXXXXX") || exit 2
EV=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-evidence-XXXXXX") || exit 2
declare -A LEGV=() LEGSHA=() EVSTATE=()   # EVSTATE[host<TAB>run dir]: "launched" once its leg starts, "copied" once its
                                          # evidence is back here
keep_uncopied() { # a run root whose leg started but whose evidence never came back is kept, never removed
  local entry h k d
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r h k d <<<"$entry"
    if [ "${EVSTATE[$h$TAB$d]:-}" = launched ]; then mac_keep_run_dir "$h" "$d" "its leg ran but its evidence was not copied back"; fi
  done
}
on_exit() { # an early exit keeps every root without copied evidence; any other root's removal must be confirmed
  local st=$?
  keep_uncopied
  if ! mac_remove_run_dirs; then
    echo "INCONCLUSIVE: a run root's removal was not confirmed (RETAINED above)" >&2
    [ "$st" -ne 0 ] || st=2
  fi
  rm -rf -- "${STAGE:?}"
  exit "$st"
}
trap on_exit EXIT
trap 'echo "INCONCLUSIVE: interrupted by a signal" >&2; exit 2' HUP INT TERM
printf 'EVIDENCE\t%s\n' "$EV"
printf 'COMMIT\t%s\n' "$COMMIT" | tee "$EV/commit"

# ── The one dmg ──
SRC="$STAGE/src"
mkdir "$SRC" || exit 2
git archive "$COMMIT" | tar -x -C "$SRC"
st=$?
[ "$st" -eq 0 ] || { echo "INCONCLUSIVE: could not export $COMMIT" >&2; exit 2; }
G=(git -C "$SRC" -c user.name=ms1c-gate -c user.email=ms1c-gate@invalid -c commit.gpgsign=false)
"${G[@]}" init -q && "${G[@]}" add -A -f && "${G[@]}" commit -q -m "ms1c clean tree of $COMMIT"   # -f: tracked files .gitignore matches
st=$?
SRC_COMMIT=$("${G[@]}" rev-parse HEAD)
src_tree=$("${G[@]}" rev-parse "HEAD^{tree}")
want_tree=$(git rev-parse "$COMMIT^{tree}")
printf 'CLEANTREE\t%s\t%s\t%s\n' "$SRC_COMMIT" "$src_tree" "$want_tree" | tee "$EV/cleantree"
[ "$st" -eq 0 ] && [ "$src_tree" = "$want_tree" ] || { echo "INCONCLUSIVE: the clean tree is not $COMMIT's tree" >&2; exit 2; }
(cd "$SRC" && ZB_GATE_COMMIT="$SRC_COMMIT" bash packaging/macos/build-dmg.sh) > "$EV/build-dmg.log" 2>&1 </dev/null
dmg_rc=$?
dmg_path=$(sed -n 's/^==> Done: //p' "$EV/build-dmg.log" | tail -n 1)
printf 'DMGBUILD\trc=%s\t%s\n' "$dmg_rc" "$dmg_path" | tee -a "$EV/dmg"
if [ "$dmg_rc" -ne 0 ] || [ -z "$dmg_path" ] || [ "${dmg_path%/*}" != "$SRC" ] || [ ! -f "$dmg_path" ]; then
  tail -n 20 "$EV/build-dmg.log" >&2
  echo "FAIL: build-dmg.sh made no dmg (exit $dmg_rc)" >&2
  exit 1
fi
cp -- "$dmg_path" "$STAGE/zigBrowser.dmg" || exit 2
DMG_SHA=$(sha256sum "$STAGE/zigBrowser.dmg" | awk '{ print $1 }')
printf 'DMG\t%s\t%s\n' "$DMG_SHA" "${dmg_path##*/}" | tee -a "$EV/dmg"


leg() { # $1=host $2=key $3=arch
  local host="$1" key="$2" arch="$3" rd rc st line v sha
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  LEGV[$arch]=INCONCLUSIVE
  echo "== MS1c leg $arch on $host ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT"
  st=$?
  [ "$st" -eq 0 ] || { printf 'LEG\t%s\tINCONCLUSIVE\tthe tests tree did not build on %s\n' "$arch" "$host"; return; }
  rd=$MAC_RDIR
  "${SCP[@]}" "$STAGE/zigBrowser.dmg" "$host:$rd/zigBrowser.dmg" >/dev/null
  st=$?
  [ "$st" -eq 0 ] || { printf 'LEG\t%s\tINCONCLUSIVE\tthe dmg did not reach %s\n' "$arch" "$host"; return; }
  EVSTATE[$host$TAB$rd]=launched
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$rd" "$DMG_SHA" "$arch" > "$EV/$arch.leg.out" 2>&1 <<'REMOTE'
set -uo pipefail
RDN=${1:?} WANT_SHA=${2:?} ARCH=${3:?}
T=$'\t'
REAL_HOME=$(cd -P "$HOME" && pwd) || exit 2
RD="$REAL_HOME/$RDN"
cd "$RD" || exit 2
# Every temp file of this leg (a here-document, sort) stays in the run root, never in /tmp or the audited /var/folders.
mkdir -p "$RD/leg-tmp" && export TMPDIR="$RD/leg-tmp/" || exit 2
for m in "$REAL_HOME"/zb-gate-*/LEAKED "$REAL_HOME"/zb-gate-*/MOUNTED; do   # an earlier run left a process or a mount
  if [ -e "$m" ]; then printf 'HOST_HELD\t%s\n' "$m"; exit 4; fi
done
EV="$RD/evidence"
mkdir "$EV" || exit 2
printf 'RUNNING\t%s\tthe leg did not finish; processes may be left running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RD/LEAKED" || exit 2
verdict=PASS leaked=0 dev= code=
reasons=()
fail() { [ "$verdict" = INCONCLUSIVE ] || verdict=FAIL; reasons+=("FAIL: $*"); }
inconclusive() { verdict=INCONCLUSIVE; reasons+=("INCONCLUSIVE: $*"); }
log() { printf '%s\n' "$*" | tee -a "$EV/leg.log"; }

detach() { # detach the image if it is attached; a failure keeps MOUNTED and makes the leg exit 5
  local st
  [ -n "$dev" ] || return 0
  hdiutil detach "$dev" > "$EV/detach.out" 2>&1
  st=$?
  log "DETACH${T}$dev${T}rc=$st"
  if [ "$st" -ne 0 ]; then inconclusive "hdiutil detach $dev failed"; code=5; return 1; fi
  dev=
  rm -f -- "$RD/MOUNTED"
}
finish() {
  local r
  detach
  for r in "${reasons[@]+"${reasons[@]}"}"; do log "REASON${T}$r"; done
  log "LEG${T}$ARCH${T}$verdict"
  tar -C "$RD" -cf "$RD/evidence.tar" evidence
  if [ "$leaked" -eq 0 ] && [ -z "$code" ]; then rm -f -- "$RD/LEAKED"; fi
  if [ -n "$code" ]; then exit "$code"; fi
  case "$verdict" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac
}
trap 'detach' EXIT

# The exact bytes.
got=$(shasum -a 256 "$RD/zigBrowser.dmg" | awk '{ print $1 }')
log "DMG${T}$got"
if [ "$got" != "$WANT_SHA" ]; then inconclusive "the dmg here is $got, not $WANT_SHA"; finish; fi

# Nothing may fall back to the tests tree's own build.
rm -rf -- "$RD/zig-out"
st=$?
if [ "$st" -ne 0 ] || [ -e "$RD/zig-out" ]; then inconclusive "zig-out was not removed"; finish; fi
log "ZIGOUT${T}removed"

# Unpack the .app inside the run root.
mkdir "$RD/mnt" "$RD/app" || { inconclusive "no mountpoint"; finish; }
printf 'ATTACHING\t%s\n' "$RD/mnt" > "$RD/MOUNTED"
att=$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$RD/mnt" "$RD/zigBrowser.dmg" 2> "$EV/attach.err")
st=$?
printf '%s\n' "$att" > "$EV/attach.out"
dev=$(awk '$1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }' "$EV/attach.out")
mp=$(awk -F'\t' -v m="$RD/mnt" '{ v = $NF; sub(/[ \t]+$/, "", v) } v == m { print v; exit }' "$EV/attach.out")
log "ATTACH${T}rc=$st${T}${dev:--}${T}${mp:--}"
if [ -n "$dev" ]; then printf '%s\t%s\n' "$dev" "$RD/mnt" > "$RD/MOUNTED"; fi
if [ "$st" -ne 0 ] || [ -z "$dev" ] || [ "$mp" != "$RD/mnt" ]; then
  inconclusive "hdiutil attach did not mount the dmg at $RD/mnt"
  if [ -z "$dev" ]; then code=5; fi   # no device to detach: whatever was attached stays, so the host is held
  finish
fi
ditto "$RD/mnt/zigBrowser.app" "$RD/app/zigBrowser.app"
st=$?
log "COPY${T}rc=$st"
detach || finish
[ "$st" -eq 0 ] || { inconclusive "ditto of the .app failed"; finish; }

APP="$RD/app/zigBrowser.app"
EXE="$APP/Contents/MacOS/zigBrowser"
SHIM_REF="@executable_path/../Frameworks/libwkwebview_shim.dylib"

# Product checks: every Mach-O is fat with both slices, the strict deep signature, the shim reference.
: > "$EV/census"
nmacho=0 thin=0
while IFS= read -r -d '' f; do
  kind=$(file -b "$f")
  case "$kind" in
    Mach-O*)
      archs=$(lipo -archs "$f" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
      printf 'MACHO\t%s\t%s\n' "${f#"$APP/"}" "${archs% }" >> "$EV/census"
      nmacho=$((nmacho + 1))
      [ "${archs% }" = "arm64 x86_64" ] || thin=$((thin + 1)) ;;
  esac
done < <(find "$APP" -type f -print0)
log "CENSUS${T}$nmacho Mach-O${T}$thin not fat with exactly x86_64 and arm64"
grep -qxF "MACHO${T}Contents/MacOS/zigBrowser${T}arm64 x86_64" "$EV/census" || fail "the exe is not fat with both slices"
grep -qxF "MACHO${T}Contents/Frameworks/libwkwebview_shim.dylib${T}arm64 x86_64" "$EV/census" || fail "the shim is not fat with both slices"
[ "$thin" -eq 0 ] || fail "$thin Mach-O file(s) in the .app are not fat with exactly x86_64 and arm64"
codesign --verify --strict --deep --verbose=2 "$APP" > "$EV/codesign.out" 2>&1
st=$?
log "CODESIGN${T}rc=$st"
[ "$st" -eq 0 ] || fail "codesign --verify --strict --deep failed"
for slice in x86_64 arm64; do
  otool -arch "$slice" -L "$EXE" > "$EV/otool.$slice.out" 2>&1
  st=$?
  ref=$(grep -cF "${T}$SHIM_REF (" "$EV/otool.$slice.out")
  log "OTOOL${T}$slice${T}rc=$st${T}refs=$ref"
  [ "$st" -eq 0 ] && [ "$ref" -eq 1 ] || fail "the $slice exe slice does not load $SHIM_REF"
done
if [ ! -f "$APP/Contents/Frameworks/libwkwebview_shim.dylib" ] || [ -L "$APP/Contents/Frameworks/libwkwebview_shim.dylib" ]; then
  fail "$SHIM_REF does not resolve to the bundled regular file"
fi

# Audit roots and the before snapshots: /var/folders through the shared helper, the account home here.
. "$RD/tests/mac/mac_varfolders_audit.sh"
log "HOMEROOT${T}$REAL_HOME${T}excluding $RD"
DIAG="$REAL_HOME/Library/Logs/DiagnosticReports"
# The account home is recorded the way the shared /var/folders helper records its roots (SilverRidge 0be64570): every
# entry's lstat identity "type mode uid gid nlink size mtime_ns ctime_ns inode sha256 link" (sha256 of a regular file's
# bytes, a symlink's target), in path byte order, with only the exact run root left out (matched by device and inode,
# not by name). Every path and symlink target is a canonical b64: field (padded URL-safe Base64 of its os.fsencode
# bytes), while ordering and exact protected-list membership use the decoded original bytes. Only EACCES/EPERM while
# reading an exact path in the committed reviewed list retains the ordinary lstat row plus a side-tagged
# SKIPPED-PROTECTED marker. Any other traversal, stat or read failure is an ERROR line: the snapshot is incomplete.
# The before snapshot then starts nothing; the after one is INCONCLUSIVE.
HOME_SNAP_PY='
import base64, binascii, errno, hashlib, os, stat, sys
root, exclude, protected_file, side, out = sys.argv[1:6]
rows, errors, skipped = [], [], []
with open(protected_file, encoding="utf-8") as source:
    protected = {os.fsencode(line) for line in source.read().splitlines()}
if side not in ("BEFORE", "AFTER"):
    raise SystemExit("invalid snapshot side")
KIND = ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s"),
        (stat.S_ISCHR, "c"), (stat.S_ISBLK, "b"))
def evidence_field(value):
    raw = os.fsencode(value)
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")
def decode_field(field):
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    if evidence_field(raw) != field:
        raise ValueError("not a canonical evidence field")
    return raw
def digest(p):
    fd = os.open(p, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    h = hashlib.sha256()
    with os.fdopen(fd, "rb") as f:
        for chunk in iter(lambda: f.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()
def err(e):
    rel = os.path.relpath(e.filename, root) if e.filename else "?"
    errors.append("%s\t%s" % (evidence_field(rel), " ".join((e.strerror or type(e).__name__).split())))
def entry(p, rel):
    rel_field = evidence_field(rel)
    try:
        rel_raw = decode_field(rel_field)
    except (ValueError, binascii.Error):
        errors.append("%s\tthe path codec did not round trip" % rel_field)
        return
    try:
        st = os.lstat(p)
        kind = next((k for test, k in KIND if test(st.st_mode)), "o")
        link = os.readlink(p) if kind == "l" else "-"
    except OSError as e:
        err(e)
        return
    sha = "-"
    if kind == "f":
        try:
            sha = digest(p)
        except OSError as e:
            reason = {errno.EACCES: "EACCES", errno.EPERM: "EPERM"}.get(e.errno)
            if rel_raw in protected and reason:
                skipped.append((rel_raw, "SKIPPED-PROTECTED\t%s\tHOME\t%s\t%s" % (side, rel_field, reason)))
            else:
                err(e)
                return
    link_field = evidence_field(link) if kind == "l" else "-"
    meta = "%s %o %d %d %d %d %d %d %d %s %s" % (kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, st.st_nlink,
                                                st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, sha, link_field)
    rows.append((rel_raw, "%s\t%s" % (rel_field, meta)))
try:
    ex = os.lstat(exclude)
    rst = os.lstat(root)
except OSError as e:
    err(e)
else:
    if not stat.S_ISDIR(rst.st_mode):
        errors.append("%s\tthe home is not a directory" % evidence_field(b"."))
    else:
        entry(root, ".")
        excluded = 0
        for dirpath, dirs, names in os.walk(root, onerror=err, followlinks=False):
            if dirpath == root:
                kept = []
                for d in dirs:
                    try:
                        st = os.lstat(os.path.join(root, d))
                    except OSError as e:
                        err(e)
                        continue
                    if (st.st_dev, st.st_ino) == (ex.st_dev, ex.st_ino):
                        excluded += 1
                    else:
                        kept.append(d)
                dirs[:] = kept
            dirs.sort()
            for n in sorted(dirs + names):
                q = os.path.join(dirpath, n)
                entry(q, os.path.relpath(q, root))
        if excluded != 1:
            errors.append("%s\tthe run root was not found exactly once directly under the home" % evidence_field(b"."))
with open(out, "w", encoding="utf-8") as f:
    f.write("ROOT\t%s\t%s\n" % (evidence_field(root), evidence_field(exclude)))
    for _k, line in sorted(rows):
        f.write(line + "\n")
    for _k, line in sorted(set(skipped)):
        f.write(line + "\n")
    for e in errors:
        f.write("ERROR\t" + e + "\n")
    f.write("END\t%d\n" % len(rows))
sys.exit(3 if errors else 0)
'
# The home delta: added, changed or deleted entries, each a HOME-DELTA line. The only allowed change (owner decision
# 2026-10-23) is a new regular file directly in ~/Library/Logs/DiagnosticReports whose bytes name the control's exe
# (a CRASHREPORT line with its recorded sha256), with that folder changing only its nlink, size and times. Exit 0 clean,
# 2 for any other delta, 3 when either snapshot is incomplete (HOMEAUDIT INCONCLUSIVE, no delta judged).
HOME_DIFF_PY='
import base64, binascii, os, sys
before, after, root, diag, _control, protected_file = sys.argv[1:7]
ignored_file = sys.argv[7] if len(sys.argv) > 7 else None
root_raw, diag_raw = os.fsencode(root), os.fsencode(diag)
with open(protected_file, encoding="utf-8") as source:
    protected = {os.fsencode(line) for line in source.read().splitlines()}
def evidence_field(value):
    raw = os.fsencode(value)
    return "b64:" + base64.urlsafe_b64encode(raw).decode("ascii")
def decode_field(field):
    if not field.startswith("b64:") or not field.isascii():
        raise ValueError("not a canonical evidence field")
    raw = base64.b64decode(field[4:].encode("ascii"), altchars=b"-_", validate=True)
    if evidence_field(raw) != field:
        raise ValueError("not a canonical evidence field")
    return raw
def load(p, side):
    try:
        lines = open(p, encoding="ascii").read().split("\n")
    except (OSError, UnicodeError):
        return None
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) < 2 or not lines[-1].startswith("END\t"):
        return None
    roots = lines[0].split("\t")
    try:
        if len(roots) != 3 or roots[0] != "ROOT":
            return None
        decoded_roots = (decode_field(roots[1]), decode_field(roots[2]))
    except (ValueError, binascii.Error):
        return None
    body = lines[1:-1]
    if any(l.startswith("ERROR\t") for l in body):
        return None
    markers, row_lines = [], []
    for line in body:
        if line.startswith("SKIPPED-PROTECTED\t"):
            fields = line.split("\t")
            if len(fields) != 5 or fields[1] != side or fields[2] != "HOME" or fields[4] not in ("EACCES", "EPERM"):
                return None
            try:
                marker_path = decode_field(fields[3])
            except (ValueError, binascii.Error):
                return None
            if marker_path not in protected:
                return None
            markers.append((marker_path, fields[4]))
        else:
            row_lines.append(line)
    if lines[-1] != "END\t%d" % len(row_lines):
        return None
    rows, order = {}, []
    try:
        for line in row_lines:
            path_field, meta = line.split("\t", 1)
            rel = decode_field(path_field)
            fields = meta.split(" ", 10)
            if len(fields) != 11:
                return None
            if fields[0] == "l":
                decode_field(fields[10])
            elif fields[10] != "-":
                return None
            if rel in rows:
                return None
            rows[rel] = meta
            order.append(rel)
    except (ValueError, binascii.Error):
        return None
    if order != sorted(order) or markers != sorted(markers, key=lambda item: item[0]):
        return None
    marker_paths = {path for path, _reason in markers}
    return (rows, tuple(markers), decoded_roots) if len(markers) == len(marker_paths) else None
b_loaded, a_loaded = load(before, "BEFORE"), load(after, "AFTER")
b = b_loaded[0] if b_loaded else None
a = a_loaded[0] if a_loaded else None
for name, snap in (("before", b), ("after", a)):
    if snap is None:
        print("HOMEAUDIT\tINCONCLUSIVE\tthe %s snapshot is incomplete" % name)
        sys.exit(3)
if b_loaded[1] != a_loaded[1]:
    print("HOMEAUDIT\tINCONCLUSIVE\tthe protected-path skip set changed")
    sys.exit(3)
if b_loaded[2] != a_loaded[2] or b_loaded[2][0] != root_raw:
    print("HOMEAUDIT\tINCONCLUSIVE\tthe snapshot roots changed")
    sys.exit(3)
try:
    ignored_fields = open(ignored_file, encoding="ascii").read().splitlines() if ignored_file else []
    ignored = {decode_field(value) for value in ignored_fields}
except (OSError, UnicodeError, ValueError, binascii.Error):
    print("HOMEAUDIT\tINCONCLUSIVE\tthe crash-report census is incomplete")
    sys.exit(3)
if len(ignored) != len(ignored_fields) or any(os.path.dirname(rel) != diag_raw or not rel.endswith(b".ips") for rel in ignored):
    print("HOMEAUDIT\tINCONCLUSIVE\tthe crash-report census is invalid")
    sys.exit(3)
deltas = []
for rel in sorted(set(a) | set(b)):
    if rel in a and rel in b and a[rel] == b[rel]:
        continue
    if rel in ignored:
        continue
    kind = "ADDED" if rel not in b else "DELETED" if rel not in a else "CHANGED"
    if kind == "CHANGED" and rel == diag_raw and ignored:
        bf, af = b[rel].split(" "), a[rel].split(" ")
        if [bf[i] for i in (0, 1, 2, 3, 8, 9, 10)] == [af[i] for i in (0, 1, 2, 3, 8, 9, 10)]:
            continue
    deltas.append((kind, rel))
for kind, rel in deltas:
    path = root_raw if rel == b"." else os.path.join(root_raw, rel)
    print("HOME-DELTA\t%s\t%s\t%s\t%s" % (kind, evidence_field(path), b.get(rel, "-"), a.get(rel, "-")))
print("HOMEAUDIT\t%s\t%d" % ("CHANGED" if deltas else "CLEAN", len(deltas)))
sys.exit(2 if deltas else 0)
'
take() { # $1=before|after
  local st=0 side=BEFORE
  [ "$1" = after ] && side=AFTER
  if [ "$1" = before ]; then
    varfolders_begin "$EV/varfolders" > "$EV/varfolders.begin" 2>&1 || st=1
  else
    varfolders_end "$EV/varfolders" > "$EV/varfolders.end" 2>&1 || st=1
    tee -a "$EV/leg.log" < "$EV/varfolders.end"
  fi
  if [ "$st" -eq 0 ] || [ "$1" = after ]; then   # the after home snapshot is always taken: the diff reports it
    /usr/bin/python3 -I -B -X utf8 -c "$HOME_SNAP_PY" "$REAL_HOME" "$RD" \
      "$RD/tests/mac/ms1c_home_protected_paths.txt" "$side" "$EV/home.$1" || st=1
    grep -E "^(ERROR|SKIPPED-PROTECTED)${T}" "$EV/home.$1" >> "$EV/leg.log" 2>/dev/null
  fi
  log "SNAPSHOT${T}$1${T}rc=$st"
  [ "$st" -eq 0 ] || inconclusive "the $1 snapshot is missing or incomplete"
  return "$st"
}
take before
audit_ok=$?
if [ "$audit_ok" -ne 0 ]; then finish; fi   # an incomplete before snapshot starts nothing (the helper fails closed)

# The private environment of every launch.
mkdir -p run-env/home run-env/tmp run-env/xdg-data run-env/xdg-cache run-env/xdg-config run-env/xdg-runtime s cap || {
  inconclusive "no private environment"; finish; }
chmod 700 run-env/xdg-runtime s
export HOME="$RD/run-env/home" CFFIXED_USER_HOME="$RD/run-env/home" TMPDIR="$RD/run-env/tmp/" \
  XDG_DATA_HOME="$RD/run-env/xdg-data" XDG_CACHE_HOME="$RD/run-env/xdg-cache" \
  XDG_CONFIG_HOME="$RD/run-env/xdg-config" XDG_RUNTIME_DIR="$RD/run-env/xdg-runtime" \
  ZB_E2E_SOCKET_DIR="$RD/s" ZB_DEBUG_EPHEMERAL_DATA_STORE=1 ZB_ENABLE_M9_E2E=1 PYTHONDONTWRITEBYTECODE=1
unset ZB_M9_GUI_RUNNER
: > "$EV/browser-processes" || { inconclusive "no process ledger"; finish; }
chmod 600 "$EV/browser-processes" || { inconclusive "the process ledger is not private"; finish; }
export ZB_PROCESS_LEDGER="$EV/browser-processes"

row() { # $1=name $2=PASS id ('' = none) argv...: one status line per row; a LEAK stops the host
  local name="$1" pass="$2" rc pst count=1
  shift 2
  [ "$name" = render ] && count=2
  ZB_PROCESS_ROW="$name" "$@" > "$EV/row-$name.out" 2>&1
  rc=$?
  if grep -q "^LEAK${T}" "$EV/row-$name.out"; then
    log "ROW${T}$name${T}rc=$rc"
    grep "^LEAK${T}" "$EV/row-$name.out" | sed 's/^LEAK/LEAKED/' > "$RD/LEAKED"
    log "HOST_STOPPED${T}$name"
    cat "$RD/LEAKED" | tee -a "$EV/leg.log"
    leaked=1 code=3
    inconclusive "$name left a process running"
    return 1
  fi
  /usr/bin/python3 -I -B "$RD/tests/mac/ms1c_crash_audit.py" row \
    --ledger "$EV/browser-processes" --audit-marker "$EV/process-audit" --row "$name" \
    --expected-count "$count" --expected-exe "$EXE" --allow-status 0 > "$EV/process-$name" 2>&1
  pst=$?
  tee -a "$EV/leg.log" < "$EV/process-$name"
  if [ "$pst" -eq 1 ]; then rc=1
  elif [ "$pst" -ne 0 ]; then rc=2; inconclusive "$name process evidence is incomplete or contradictory"; fi
  log "ROW${T}$name${T}rc=$rc"
  if [ "$rc" -ne 0 ] || grep -q "^FAIL${T}" "$EV/row-$name.out"; then fail "$name exited $rc"; return 0; fi
  if [ -n "$pass" ] && ! grep -qE "^PASS${T}$pass(${T}|\$)" "$EV/row-$name.out"; then fail "$name printed no PASS${T}$pass"; fi
  return 0
}
after() { # the after snapshots and every delta
  local st crash_st
  take after   # an incomplete after snapshot is INCONCLUSIVE; the diff below still says which one and why
  [ "$audit_ok" -eq 0 ] || return
  /usr/bin/python3 -I -B "$RD/tests/mac/ms1c_crash_audit.py" reports \
    --ledger "$EV/browser-processes" --audit-marker "$EV/process-audit" --before "$EV/home.before" \
    --diag "$DIAG" --diag-rel Library/Logs/DiagnosticReports --control-exe "$CTL_EXE" \
    --control-err "$EV/control.err" --ignore-out "$EV/crash.ignore" > "$EV/crash.delta" 2>&1
  crash_st=$?
  tee -a "$EV/leg.log" < "$EV/crash.delta"
  grep "^CRASHREPORT${T}" "$EV/crash.delta" > "$EV/crashreports"
  /usr/bin/python3 -I -B -X utf8 -c "$HOME_DIFF_PY" "$EV/home.before" "$EV/home.after" "$REAL_HOME" \
    Library/Logs/DiagnosticReports "$CTL_EXE" "$RD/tests/mac/ms1c_home_protected_paths.txt" \
    "$EV/crash.ignore" > "$EV/home.delta" 2>&1
  st=$?
  tee -a "$EV/leg.log" < "$EV/home.delta"
  case "$st" in
    0) ;;
    2) inconclusive "the account home changed outside the run root (HOME-DELTA lines)" ;;
    *) inconclusive "the home audit is incomplete or failed (exit $st)" ;;
  esac
  case "$crash_st" in
    0) ;;
    2) fail "a launched zigBrowser process produced a crash report" ;;
    *) inconclusive "the process or crash-report evidence is incomplete (exit $crash_st)" ;;
  esac
}

CTL="$RD/control/zigBrowser.app"
CTL_EXE="$CTL/Contents/MacOS/zigBrowser"
row render m9-render-webview-screenshot python3 tests/e2e/m9_render_test.py --browser "$EXE" \
  --capture-path "$RD/cap/m9-render.png" --no-uniform-check || { after; finish; }
row reply m9-reply-channel-contract python3 tests/e2e/m9_reply_channel_test.py --browser "$EXE" || { after; finish; }
row loadfail m9-load-fail-contract python3 tests/e2e/m9_load_fail_test.py --browser "$EXE" || { after; finish; }
rm -f -- "$RD/cap/exec-arch.txt"
row arch '' python3 tests/mac/exec_arch_probe.py --browser "$EXE" --out "$RD/cap/exec-arch.txt" --socket-dir "$RD/s" || { after; finish; }
norm() { case "$1" in aarch64|arm64) echo arm64 ;; *) echo "$1" ;; esac; }
uname_m=$(uname -m)
reported=$(tr -d '[:space:]' < "$RD/cap/exec-arch.txt" 2>/dev/null)
translated=-
if [ "$ARCH" = arm64 ]; then translated=$(sysctl -n sysctl.proc_translated); fi
log "ARCH${T}uname=$uname_m${T}reported=${reported:--}${T}translated=$translated"
[ "$(norm "$uname_m")" = "$ARCH" ] || fail "uname -m $uname_m is not $ARCH"
[ "$(norm "$reported")" = "$ARCH" ] || fail "the app reported exec_arch '${reported}', not $ARCH"
if [ "$ARCH" = arm64 ] && [ "$translated" != 0 ]; then fail "proc_translated=$translated (not native)"; fi

# The control: a private copy without its dylib must fail with dyld's exact load failure of the bundled shim.
mkdir -p "$RD/control"
ditto "$APP" "$CTL"
st=$?
rm -f -- "$CTL/Contents/Frameworks/libwkwebview_shim.dylib"
if [ "$st" -ne 0 ] || [ -e "$CTL/Contents/Frameworks/libwkwebview_shim.dylib" ] || [ ! -f "$APP/Contents/Frameworks/libwkwebview_shim.dylib" ]; then
  inconclusive "the control copy could not be made"
  after; finish
fi
ZB_PROCESS_ROW=control python3 - "$CTL_EXE" > "$EV/control.out" 2> "$EV/control.err" <<'PY'
import sys
sys.path.insert(0, "tests/e2e")
from mac_term_teardown import run_term_only
r = run_term_only([sys.argv[1], "--version"], 30)
sys.stdout.write(r.stdout)
sys.stderr.write(r.stderr)
print(f"CONTROL_RC\t{r.returncode}")
PY
st=$?
crc=$(sed -n "s/^CONTROL_RC${T}//p" "$EV/control.out" | tail -n 1)
/usr/bin/python3 -I -B "$RD/tests/mac/ms1c_crash_audit.py" row \
  --ledger "$EV/browser-processes" --audit-marker "$EV/process-audit" --row control \
  --expected-count 1 --expected-exe "$CTL_EXE" --allow-status -6 > "$EV/process-control" 2>&1
pst=$?
tee -a "$EV/leg.log" < "$EV/process-control"
case "$pst" in
  0) ;;
  1) fail "the control had an unexpected terminal status" ;;
  *) inconclusive "the control process evidence is incomplete or contradictory" ;;
esac
log "CONTROL${T}rc=$st${T}exe=${crc:--}"
if grep -q "^LEAK${T}" "$EV/control.out"; then
  grep "^LEAK${T}" "$EV/control.out" | sed 's/^LEAK/LEAKED/' > "$RD/LEAKED"
  log "HOST_STOPPED${T}control"
  leaked=1 code=3
  inconclusive "the control left a process running"
  after; finish
fi
if [ -z "$crc" ] || [ "$crc" = 0 ]; then
  fail "the control without its dylib was accepted (exit ${crc:-none})"
elif ! grep -qF "Library not loaded: $SHIM_REF" "$EV/control.err" \
     || ! grep -qE "Referenced from: (<[^>]*> )?$CTL_EXE\$" "$EV/control.err"; then
  fail "the control did not fail with dyld's load failure of the bundled shim from its own exe"
fi
for i in $(seq 1 30); do   # ReportCrash writes the control's report a moment later; let it land before the audit
  if grep -rlF "$CTL_EXE" "$DIAG" >/dev/null 2>&1; then break; fi
  sleep 1
done

after
finish
REMOTE
  rc=$?
  "${SCP[@]}" "$host:$rd/evidence.tar" "$EV/$arch.evidence.tar" >/dev/null
  st=$?
  if [ "$st" -eq 0 ]; then mkdir -p "$EV/$arch" && tar -C "$EV/$arch" -xf "$EV/$arch.evidence.tar"; st=$?; fi
  if [ "$st" -eq 0 ] && [ -f "$EV/$arch/evidence/leg.log" ]; then
    EVSTATE[$host$TAB$rd]=copied
    printf 'EVIDENCE-ARCHIVE\t%s\t%s\t%s\n' "$arch" "$(sha256sum "$EV/$arch.evidence.tar" | awk '{ print $1 }')" \
      "$(wc -c < "$EV/$arch.evidence.tar")"
  fi
  sed "s/^/  $arch: /" "$EV/$arch.leg.out" >&2
  line=$(grep "^LEG${TAB}$arch${TAB}" "$EV/$arch.leg.out" | tail -n 1)
  v=$(cut -f3 <<<"$line")
  sha=$(sed -n "s/^DMG${TAB}//p" "$EV/$arch.leg.out" | tail -n 1)
  LEGSHA[$arch]=$sha
  case "$rc" in
    3|5|124)
      mac_keep_run_dir "$host" "$rd" "leg exit $rc (leak, detach failure or timeout)"
      echo "STOPPED: $host ($arch): exit $rc. Run dir ~/$rd is KEPT. A person must stop the reported process or" \
        "detach the reported image before any cleanup of it or further work on $host." >&2
      v=INCONCLUSIVE ;;
    4) v=INCONCLUSIVE ;;
    0) [ "$v" = PASS ] || v=INCONCLUSIVE ;;
    1) [ "$v" = FAIL ] || v=INCONCLUSIVE ;;
    *) v=INCONCLUSIVE ;;
  esac
  if [ "${EVSTATE[$host$TAB$rd]}" != copied ]; then
    v=INCONCLUSIVE; echo "INCONCLUSIVE: no evidence from $host" >&2
    case "$rc" in 3|5|124) ;; *) mac_keep_run_dir "$host" "$rd" "its evidence was not copied back" ;; esac
  fi
  LEGV[$arch]=$v
  printf 'LEG\t%s\t%s\texit %s\n' "$arch" "$v" "$rc"
}

leg "$INTEL_HOST" "$KEY" x86_64
leg "$ARM_HOST" "$ARM_KEY" arm64

# Remove every run root that is not kept, and prove it is gone; a mount or a leak marker refuses the removal.
clean=0
for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
  IFS=$'\t' read -r host key rdir <<<"$entry"
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  "${SSH[@]}" "$host" "cd / && d=\"\$HOME/${rdir:?}\"; if [ -e \"\$d/MOUNTED\" ] || [ -e \"\$d/LEAKED\" ]; then exit 3; fi;" \
    "[ ! -d \"\$d\" ] || find \"\$d\" -delete; [ ! -e \"\$d\" ]" </dev/null
  st=$?
  printf 'CLEANUP\t%s\t%s\trc=%s\n' "$host" "$rdir" "$st" | tee -a "$EV/cleanup"
  if [ "$st" -ne 0 ]; then clean=1; printf 'RETAINED\t%s\t%s\tits removal was refused or not confirmed (rc=%s)\n' "$host" "$rdir" "$st" >&2; fi
done
MAC_RUN_DIRS=()

(cd "$EV" && find . -type f ! -name manifest.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$EV/manifest.sha256"
printf 'MANIFEST\t%s\n' "$(sha256sum "$EV/manifest.sha256" | awk '{ print $1 }')"

overall=PASS
for arch in x86_64 arm64; do
  case "${LEGV[$arch]}" in PASS) ;; FAIL) [ "$overall" = INCONCLUSIVE ] || overall=FAIL ;; *) overall=INCONCLUSIVE ;; esac
  [ "${LEGSHA[$arch]:-}" = "$DMG_SHA" ] || overall=INCONCLUSIVE
done
[ "$clean" -eq 0 ] || overall=INCONCLUSIVE
case "$overall" in
  PASS) printf 'PASS\tms1c-app-gate\tboth-arches\t%s\n' "$DMG_SHA"; exit 0 ;;
  FAIL) printf 'FAIL\tms1c-app-gate\n'; exit 1 ;;
  *) printf 'INCONCLUSIVE\tms1c-app-gate\n'; exit 2 ;;
esac
