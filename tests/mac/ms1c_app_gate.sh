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
trap 'mac_remove_run_dirs; rm -rf -- "${STAGE:?}"' EXIT
printf 'EVIDENCE\t%s\n' "$EV"
printf 'COMMIT\t%s\n' "$COMMIT" | tee "$EV/commit"

# ── The one dmg ──
SRC="$STAGE/src"
mkdir "$SRC" || exit 2
git archive "$COMMIT" | tar -x -C "$SRC"
st=$?
[ "$st" -eq 0 ] || { echo "INCONCLUSIVE: could not export $COMMIT" >&2; exit 2; }
G=(git -C "$SRC" -c user.name=ms1c-gate -c user.email=ms1c-gate@invalid -c commit.gpgsign=false)
"${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -q -m "ms1c clean tree of $COMMIT"
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

declare -A LEGV=() LEGSHA=()

mac_keep_run_dir() { # $1=host $2=run dir: drop it from every cleanup (mac_gate_lib.sh MAC_RUN_DIRS)
  local entry h k d
  local -a keep=()
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r h k d <<<"$entry"
    if [ "$h" = "$1" ] && [ "$d" = "$2" ]; then continue; fi
    keep+=("$entry")
  done
  MAC_RUN_DIRS=("${keep[@]+"${keep[@]}"}")
}

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
otool -L "$EXE" > "$EV/otool.out" 2>&1
st=$?
ref=$(grep -cF "${T}$SHIM_REF (" "$EV/otool.out")
log "OTOOL${T}rc=$st${T}refs=$ref"
[ "$st" -eq 0 ] && [ "$ref" -eq 1 ] || fail "the exe does not load $SHIM_REF"
if [ ! -f "$APP/Contents/Frameworks/libwkwebview_shim.dylib" ] || [ -L "$APP/Contents/Frameworks/libwkwebview_shim.dylib" ]; then
  fail "$SHIM_REF does not resolve to the bundled regular file"
fi

# Audit roots and the before snapshots: /var/folders through the shared helper, the account home here.
. "$RD/tests/mac/mac_varfolders_audit.sh"
log "HOMEROOT${T}$REAL_HOME${T}excluding $RD"
DIAG="$REAL_HOME/Library/Logs/DiagnosticReports"
snap() { # $1=root $2=out [$3=excluded subtree]: sorted path|type|mode|inode|size|mtime; DENIED/VANISHED entries kept
  local root="$1" out="$2" ex="${3:-}" fst xst
  if [ -n "$ex" ]; then
    find -P "$root" -path "$ex" -prune -o -print0 2> "$out.err" | xargs -0 stat -f '%N|%HT|%p|%i|%z|%m' > "$out.raw" 2>> "$out.err"
  else
    find -P "$root" -print0 2> "$out.err" | xargs -0 stat -f '%N|%HT|%p|%i|%z|%m' > "$out.raw" 2>> "$out.err"
  fi
  fst=${PIPESTATUS[0]} xst=${PIPESTATUS[1]}
  sed -n -e 's/^find: \(.*\): \(Operation not permitted\|Permission denied\)$/\1|DENIED/p' \
    -e 's/^stat: \(.*\): No such file or directory$/\1|VANISHED/p' "$out.err" >> "$out.raw"
  LC_ALL=C sort -u "$out.raw" > "$out"
  if grep -qvE '^(find: .*: (Operation not permitted|Permission denied)|stat: .*: No such file or directory)$' "$out.err"; then return 1; fi
  [ "$fst" -le 1 ] && [ "$xst" -le 123 ] && [ -s "$out" ]
}
take() { # $1=before|after
  local st=0
  if [ "$1" = before ]; then
    varfolders_begin "$EV/varfolders" > "$EV/varfolders.begin" 2>&1 || st=1
  else
    varfolders_end "$EV/varfolders" > "$EV/varfolders.end" 2>&1 || st=1
    tee -a "$EV/leg.log" < "$EV/varfolders.end"
  fi
  if [ "$st" -eq 0 ]; then snap "$REAL_HOME" "$EV/home.$1" "$RD" || st=1; fi
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

row() { # $1=name $2=PASS id ('' = none) argv...: one status line per row; a LEAK stops the host
  local name="$1" pass="$2" rc
  shift 2
  "$@" > "$EV/row-$name.out" 2>&1
  rc=$?
  log "ROW${T}$name${T}rc=$rc"
  if grep -q "^LEAK${T}" "$EV/row-$name.out"; then
    grep "^LEAK${T}" "$EV/row-$name.out" | sed 's/^LEAK/LEAKED/' > "$RD/LEAKED"
    log "HOST_STOPPED${T}$name"
    cat "$RD/LEAKED" | tee -a "$EV/leg.log"
    leaked=1 code=3
    inconclusive "$name left a process running"
    return 1
  fi
  if [ "$rc" -ne 0 ] || grep -q "^FAIL${T}" "$EV/row-$name.out"; then fail "$name exited $rc"; return 0; fi
  if [ -n "$pass" ] && ! grep -qE "^PASS${T}$pass(${T}|\$)" "$EV/row-$name.out"; then fail "$name printed no PASS${T}$pass"; fi
  return 0
}
after() { # the after snapshots and every delta
  local s k
  take after || return
  [ "$audit_ok" -eq 0 ] || return
  for s in home; do
    awk -F'\t' 'NR == FNR { b[$1] = $2; next } { a[$1] = $2 }
      END { for (p in b) if (!(p in a)) print "DELETED\t" p "\t" b[p] "\t-";
            for (p in a) if (!(p in b)) print "ADDED\t" p "\t-\t" a[p]; else if (a[p] != b[p]) print "CHANGED\t" p "\t" b[p] "\t" a[p] }' \
      <(sed 's/|/\t/' "$EV/$s.before") <(sed 's/|/\t/' "$EV/$s.after") | LC_ALL=C sort -t"$T" -k2 > "$EV/$s.delta"
  done
  : > "$EV/crashreports"
  local kind p b a name sum ncrash=0
  while IFS="$T" read -r kind p b a; do
    if [ "$kind" = ADDED ] && [ "${p%/*}" = "$DIAG" ] && [ "${a%%|*}" = "Regular File" ] && grep -qF "$CTL_EXE" "$p" 2>/dev/null; then
      name=${p##*/}
      sum=$(shasum -a 256 "$p" | awk '{ print $1 }')
      printf 'CRASHREPORT\t%s\t%s\n' "$name" "$sum" | tee -a "$EV/crashreports" "$EV/leg.log"
      ncrash=$((ncrash + 1))
    fi
  done < "$EV/home.delta"
  while IFS="$T" read -r kind p b a; do
    if [ "$kind" = ADDED ] && grep -qF "${T}${p##*/}${T}" "$EV/crashreports" && [ "${p%/*}" = "$DIAG" ]; then continue; fi
    if [ "$kind" = CHANGED ] && [ "$p" = "$DIAG" ] && [ "$ncrash" -gt 0 ] \
       && [ "$(cut -d'|' -f1-3 <<<"$b")" = "$(cut -d'|' -f1-3 <<<"$a")" ]; then continue; fi
    log "HOME-DELTA${T}$kind${T}$p${T}$b${T}$a"
    inconclusive "the account home changed outside the run root: $kind $p"
  done < "$EV/home.delta"
}

CTL="$RD/control/zigBrowser.app"
CTL_EXE="$CTL/Contents/MacOS/zigBrowser"
row render m9-render-webview-screenshot python3 tests/e2e/m9_render_test.py --browser "$EXE" \
  --capture-path "$RD/cap/m9-render.png" --no-uniform-check || { after; finish; }
row reply m9-reply-channel-contract python3 tests/e2e/m9_reply_channel_test.py --browser "$EXE" || { after; finish; }
row loadfail m9-load-fail-contract python3 tests/e2e/m9_load_fail_test.py --browser "$EXE" || { after; finish; }
rm -f -- "$RD/cap/exec-arch.txt"
row arch '' python3 tests/mac/exec_arch_probe.py --browser "$EXE" --out "$RD/cap/exec-arch.txt" || { after; finish; }
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
python3 - "$CTL_EXE" > "$EV/control.out" 2> "$EV/control.err" <<'PY'
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
  sed "s/^/  $arch: /" "$EV/$arch.leg.out" >&2
  line=$(grep "^LEG${TAB}$arch${TAB}" "$EV/$arch.leg.out" | tail -n 1)
  v=$(cut -f3 <<<"$line")
  sha=$(sed -n "s/^DMG${TAB}//p" "$EV/$arch.leg.out" | tail -n 1)
  LEGSHA[$arch]=$sha
  case "$rc" in
    3|5|124)
      mac_keep_run_dir "$host" "$rd"
      echo "STOPPED: $host ($arch): exit $rc. Run dir ~/$rd is KEPT. A person must stop the reported process or" \
        "detach the reported image before any cleanup of it or further work on $host." >&2
      v=INCONCLUSIVE ;;
    4) v=INCONCLUSIVE ;;
    0) [ "$v" = PASS ] || v=INCONCLUSIVE ;;
    1) [ "$v" = FAIL ] || v=INCONCLUSIVE ;;
    *) v=INCONCLUSIVE ;;
  esac
  if [ "$st" -ne 0 ] || [ ! -f "$EV/$arch/evidence/leg.log" ]; then v=INCONCLUSIVE; echo "INCONCLUSIVE: no evidence from $host" >&2; fi
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
  [ "$st" -eq 0 ] || clean=1
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
