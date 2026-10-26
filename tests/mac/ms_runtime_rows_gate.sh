#!/usr/bin/env bash
# Runtime-fix rows on BOTH Macs (macOS plan R30-MS2/MS3, bd zigBrowser-3ui.1: 4pa.55, 4pa.58, 4pa.57, 4pa.56,
# 4pa.60). Records the reds (and later the greens) of e2e files that are not yet in a slice gate, so recording a red
# never puts a failing test into a registered gate.
#
# Builds ${ZB_GATE_COMMIT:-HEAD} NATIVELY on each Mac through tests/mac/build-on-mac.sh (git archive of the exact
# commit into a fresh ~/zb-gate-<sha>-<nonce>, pinned host keys, both zig caches in that run dir; mac_gate_lib.sh),
# then works ONLY in that run root (SilverRidge fe4542e):
#   - HOME, CFFIXED_USER_HOME, TMPDIR and the XDG directories are exported to directories it creates beneath the
#     run root, so every test, its temp dirs and every browser launch stay inside it; ZB_E2E_SOCKET_DIR is a short
#     <run root>/s for the automation sockets (macOS caps a socket path at 104 bytes; the tests fail closed above);
#   - ZB_DEBUG_EPHEMERAL_DATA_STORE=1 (e2e-only hook 16; every row launches with --e2e-protocol and an in-run
#     --profile-dir) gives every window a non-persistent WKWebsiteDataStore, so no website data is written to
#     WebKit's own location under the account Library.
# A ROW is `<tests/e2e file>|<red|green>|<test id>`, judged on the Mac (SilverRidge cf7a783):
#   red   exit 1 and exactly one `RED_SHAPE<TAB><test id>` line, which the test prints (tests/e2e/red_shape.py) only
#         when every assertion of its accepted red vector ran and failed or passed exactly as that vector says,
#         nothing else ran, and no precondition or unexpected error intervened; any RED_SHAPE_MISMATCH,
#         PRECONDITION or binary-missing line is a MISMATCH;
#   green exit 0, its own `PASS<TAB><test id>` line, and no FAIL<TAB> line.
# Every browser launch in these rows stops the browser with SIGTERM only (tests/e2e/mac_term_teardown.py): the
# session brief forbids SIGKILL on a Mac, so a browser that does not quit is left running and its row fails.
# A LEAK STOPS THAT HOST (SilverRidge cf16730): the leg runs no further row, prints HOST_STOPPED and the exact
# identity of each process left running (LEAKED<TAB>pid<TAB>pgid<TAB>start<TAB>command), writes them to
# <run root>/LEAKED and exits 3; this side then KEEPS that run root (no cleanup of it) for a person to stop exactly
# that process first. A leg that finds any ~/zb-gate-*/LEAKED on its host runs nothing (HOST_HELD, exit 4). The
# marker is DURABLE (SilverRidge c78a1f6): the leg writes <run root>/LEAKED as RUNNING before its first row and
# removes it only after every row finished with no leak, so a leg that timed out or died leaves it and the next run
# on that host is held; this side keeps a timed-out leg's run root too.
# /var/folders (the owner's rule, 2026-10-23; SilverRidge 94ebe76b): a row may write under this Mac user's own
# /var/folders (WebKit's cache and temp), and nowhere else outside the run root. The leg sources the one shared helper
# tests/mac/mac_varfolders_audit.sh, snapshots the physical roots of getconf DARWIN_USER_TEMP_DIR and
# DARWIN_USER_CACHE_DIR before the first row and after the last (also before a leak stop), prints every added, changed
# or removed path there unfiltered (VARFOLDERS-DELTA lines) and deletes nothing there. A delta alone is reportable; an
# incomplete audit (VARFOLDERS<TAB>INCONCLUSIVE) holds the leg from PASS: it exits 5 and its host is INCONCLUSIVE. A
# begin that cannot take a complete before snapshot refuses (SilverRidge 3661c9b8): the leg exits 5 at once, before
# it writes its RUNNING marker, runs any row or launches a browser.
# Before both begins, a self-audit (SilverRidge 5f1ce9a5) runs one full cycle of each helper inside an outer
# /var/folders audit on this Mac's real /bin/bash 3.2 and /usr/bin/python3: unless the outer end is COMPLETE 0 (the
# helpers themselves changed nothing there), the leg exits 5 and starts nothing. Its output is printed SELFAUDIT<TAB>...
# Crash reports: the leg lists the Mac user's real ~/Library/Logs/DiagnosticReports before the first row and after the
# last (also before a leak stop) through tests/mac/mac_crashreports_audit.sh, read-only, and prints each new, changed
# or removed report (CRASHREPORT<TAB>kind<TAB>name<TAB>sha256); any of them makes the leg exit 5, INCONCLUSIVE. A
# refused crash-report begin also exits 5 before the RUNNING marker.
# Evidence and cleanup (SilverRidge 0632602f): after its self-audit the leg arms an EXIT trap that packs
# <run root>/evidence (every row's whole output, the self-audit, /var/folders and crash-report records) into a
# deterministic evidence.tar (sorted names, fixed mtimes, ustar) with its sha256 beside it; the packer itself is a
# self-audit step. This side keeps the leg's output in $ZB_MAC_EVIDENCE_DIR/<arch>/leg.out, copies both files there
# and verifies the sha256 (EVIDENCE<TAB>host<TAB>arch<TAB>sha256<TAB>bytes<TAB>path, else FAILED or NONE). A run dir is
# removed only after its evidence is verified (or when no leg ran in it, a failed build), through the shared,
# verified mac_remove_run_dirs, before the gate's PASS line: REMOVED, or RETAINED and no PASS. A leak stop, a timeout
# or unverified evidence keeps the dir (RETAINED). ZB_MAC_EVIDENCE_DIR must be an existing, empty, absolute dir that
# is not a symlink, or the gate is NOT RUN before any contact.
# Every row runs (one row's result never stops the next); each prints its output and a
# ROW<TAB><file><TAB><want><TAB>rc=<n><TAB>MATCH|MISMATCH line. The gate prints PASS<TAB>ms-runtime-rows-gate<TAB>both-arches
# only when every row on both Macs matched. Console user, no xvfb (WKWebView needs the WindowServer), like ms2a/ms2c.
# Hostless selftests: tests/mac/mac_gate_callers_selftest.sh (structure, and this leg's verdicts and environment;
# zig build test-mac-build-script).
set -euo pipefail


# The rows: one per red (its accepted vector is RED_VECTOR in the test file) or green (4pa.55's two rows, since its
# green), plus the coverage row of the e2e-only ephemeral store (hook 16). A run request names its rows with
# ZB_RUNTIME_ROWS="<test id> ..." (unset: every row); the want of each stays here.
ROWS=(
  "tests/e2e/mac_signal_runtime_test.py|green|mac-signal-runtime"
  "tests/e2e/mac_ephemeral_store_test.py|green|ms3-ephemeral-store"
  "tests/e2e/mac_ms2a_load_fail_no_quit_test.py|green|ms2a-load-fail-no-quit"
  "tests/e2e/mac_ms2c_recover_slow_server_test.py|green|ms2c-recover-slow-server"
  "tests/e2e/mac_ms2c_close_button_test.py|red|ms2c-close-button"
  "tests/e2e/mac_ms2c_close_primary_test.py|red|ms2c-close-primary"
  "tests/e2e/mac_ms2b_dialog_popup_id_test.py|red|ms2b-dialog-popup-id"
  "tests/e2e/mac_cookie_timeout_test.py|red|ms3-cookie-timeout"
  "tests/e2e/mac_profile_pacing_persist_test.py|red|ms3-profile-pacing-persist"
)

cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
for row in "${ROWS[@]}"; do   # fail closed on a malformed row, before any host is touched
  [[ "$row" =~ ^tests/e2e/mac_[a-z0-9_]+_test\.py\|(red|green)\|[a-z0-9-]+$ ]] || { echo "FAIL: bad row $row" >&2; exit 1; }
done
# The rows this run executes, in ROWS order, decided before any host is touched: an unknown, duplicate or empty
# selection is NOT RUN, and so is one that selects no row.
RUN_ROWS=("${ROWS[@]}")
if [ -n "${ZB_RUNTIME_ROWS+set}" ]; then
  read -r -a want_ids <<<"$ZB_RUNTIME_ROWS"
  declare -A picked=()
  for id in "${want_ids[@]+"${want_ids[@]}"}"; do
    [ -z "${picked[$id]:-}" ] || { echo "NOT RUN: ZB_RUNTIME_ROWS names $id twice" >&2; exit 1; }
    known=0
    for row in "${ROWS[@]}"; do [ "${row##*|}" = "$id" ] && known=1; done
    [ "$known" -eq 1 ] || { echo "NOT RUN: ZB_RUNTIME_ROWS names $id, which is not a row of this gate" >&2; exit 1; }
    picked[$id]=1
  done
  RUN_ROWS=()
  for row in "${ROWS[@]}"; do [ -n "${picked[${row##*|}]:-}" ] && RUN_ROWS+=("$row"); done
  [ "${#RUN_ROWS[@]}" -gt 0 ] || { echo "NOT RUN: ZB_RUNTIME_ROWS selects no row" >&2; exit 1; }
fi
printf 'ROWS_SELECTED'; for row in "${RUN_ROWS[@]}"; do printf '\t%s' "${row##*|}"; done; printf '\n'
EVD=${ZB_MAC_EVIDENCE_DIR:-}   # where each leg's evidence lands on this side, checked before any host is touched
if [[ "$EVD" != /* ]] || [ ! -d "$EVD" ] || [ -L "$EVD" ] || [ -n "$(ls -A -- "$EVD" 2>/dev/null)" ]; then
  echo "NOT RUN: ZB_MAC_EVIDENCE_DIR must be an existing, empty, absolute directory that is not a symlink (got '$EVD')" >&2
  exit 1
fi
. tests/mac/mac_gate_lib.sh
. tests/mac/mac_gate_output.sh

# The signal row consumes one universal DMG made by the repository's real package entry point in a fresh,
# exact-commit controller checkout. The ordinary per-host builds below may create build outputs only; neither they
# nor either runtime leg may create a DMG or substitute an app directory for this producer artifact.
NEED_SIGNAL=0
for row in "${RUN_ROWS[@]}"; do [ "${row##*|}" = mac-signal-runtime ] && NEED_SIGNAL=1; done
COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
PRODUCER_ROOT=
PACKAGE_DMG=
PACKAGE_IDENTITY=
cleanup_controller() {
  local rc=$?
  mac_remove_run_dirs
  if [ -n "$PRODUCER_ROOT" ]; then
    case "$PRODUCER_ROOT" in "${TMPDIR:-/tmp}"/zb-runtime-package-*)
      rm -rf -- "${PRODUCER_ROOT:?}"
    esac
  fi
  return "$rc"
}
trap cleanup_controller EXIT
if [ "$NEED_SIGNAL" -eq 1 ]; then
  PRODUCER_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zb-runtime-package-XXXXXX")
  PRODUCER_REPO="$PRODUCER_ROOT/repo"
  PACKAGE_LOG="$EVD/package-producer.log"
  git clone -q --no-local --no-checkout "$PWD" "$PRODUCER_REPO"
  git -C "$PRODUCER_REPO" checkout -q --detach "$COMMIT"
  [ "$(git -C "$PRODUCER_REPO" rev-parse HEAD)" = "$COMMIT" ] \
    && [ -z "$(git -C "$PRODUCER_REPO" status --porcelain)" ] \
    || { echo "FAIL: package producer checkout is not clean exact commit $COMMIT" >&2; exit 1; }
  PACKAGE_DMG="$PRODUCER_REPO/zigBrowser_0.2.0_macos.dmg"
  PACKAGE_IDENTITY="$PRODUCER_ROOT/signal-package.identity"
  [ ! -e "$PACKAGE_DMG" ] && [ ! -L "$PACKAGE_DMG" ] \
    || { echo "FAIL: fresh producer checkout already contains the fixed-name DMG" >&2; exit 1; }
  package_rc=0
  (cd "$PRODUCER_REPO" && ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh) > "$PACKAGE_LOG" 2>&1 || package_rc=$?
  cat -- "$PACKAGE_LOG"
  [ "$package_rc" -eq 0 ] || { echo "FAIL: packaging/macos/build-dmg.sh failed (exit $package_rc)" >&2; exit 1; }
  package_done=$(sed -n 's/^==> Done: //p' "$PACKAGE_LOG")
  [ "$(printf '%s\n' "$package_done" | grep -c .)" -eq 1 ] && [ "$package_done" = "$PACKAGE_DMG" ] \
    || { echo "FAIL: package producer did not name exactly $PACKAGE_DMG" >&2; exit 1; }
  [ -f "$PACKAGE_DMG" ] && [ ! -L "$PACKAGE_DMG" ] && [ -s "$PACKAGE_DMG" ] \
    || { echo "FAIL: package producer did not create a regular nonempty DMG" >&2; exit 1; }
  PACKAGE_SHA=$(sha256sum "$PACKAGE_DMG" | awk '{print $1}')
  PACKAGE_BYTES=$(wc -c < "$PACKAGE_DMG")
  [[ "$PACKAGE_SHA" =~ ^[0-9a-f]{64}$ ]] && [ "$PACKAGE_BYTES" -gt 0 ] \
    || { echo "FAIL: package producer DMG digest/size is invalid" >&2; exit 1; }
  printf '%s\t%s\n' "$COMMIT" "$PACKAGE_SHA" > "$PACKAGE_IDENTITY"
  printf 'PRODUCER_DMG\tpackaging/macos/build-dmg.sh\t%s\t%s\t%s\n' \
    "$COMMIT" "$PACKAGE_SHA" "$PACKAGE_BYTES"
fi


BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-600}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-900}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  local -a SCP; mapfile -d '' SCP < <(mac_scp_opts "$key")
  echo "== build + runtime rows on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  if [ "$NEED_SIGNAL" -eq 1 ]; then
    "${SCP[@]}" "$PACKAGE_DMG" "$host:$MAC_RDIR/zigBrowser-exact.dmg" </dev/null \
      || { echo "FAIL: could not stage the producer DMG on $host" >&2; return 1; }
    "${SCP[@]}" "$PACKAGE_IDENTITY" "$host:$MAC_RDIR/signal-package.identity" </dev/null \
      || { echo "FAIL: could not stage the producer identity on $host" >&2; return 1; }
  fi
  local leg_rc=0 row legout="$EVD/$label/leg.out"
  local -a qrows=()
  # ssh hands the remote command to the login shell as ONE string: quote each row, or its `|` would be a pipe there.
  for row in "${RUN_ROWS[@]}"; do qrows+=("$(printf '%q' "$row")"); done
  mkdir -m 700 -- "$EVD/$label" || { echo "FAIL: cannot make $EVD/$label" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" "${qrows[@]}" > "$legout" 2>&1 <<'REMOTE' || leg_rc=$?
set -uo pipefail
cd "$HOME/${1:?}"
shift
# Everything below stays in the run root: a private home, temp dir and XDG dirs, and an ephemeral website store.
root=$PWD
crash_dir="$HOME/Library/Logs/DiagnosticReports"   # the Mac user's REAL home: listed read-only, never changed
T=$'\t'
pack_evidence() { # pack_evidence <dir>: <dir>.tar (sorted names, every mtime 2000-01-01 00:00 UTC, ustar) and
  # <dir>.tar.sha256 beside it; silent, and non-zero with neither file left on any failure
  local d=${1:?} p n
  p=${d%/*} n=${d##*/}
  ( export LC_ALL=C TZ=UTC && cd "$p" && /usr/bin/find "$n" -exec /usr/bin/touch -h -t 200001010000 {} + \
      && /usr/bin/find "$n" -print | /usr/bin/sort > "$n.list" \
      && /usr/bin/tar --format=ustar --no-recursion -cf "$n.tar" -T "$n.list" \
      && /usr/bin/shasum -a 256 "$n.tar" > "$n.tar.sha256" ) || { rm -f -- "$d.tar" "$d.tar.sha256"; return 1; }
}
for m in ../zb-gate-*/LEAKED; do   # a host whose earlier run left a process running is held until a person acts
  if [ -e "$m" ]; then printf 'HOST_HELD\t%s\n' "$m"; sed 's/^/    /' "$m"; exit 4; fi
done
mkdir -p run-env/home run-env/tmp run-env/xdg-data run-env/xdg-cache run-env/xdg-config run-env/xdg-runtime s || exit 1
chmod 700 run-env/xdg-runtime s || exit 1
export HOME="$root/run-env/home" CFFIXED_USER_HOME="$root/run-env/home" TMPDIR="$root/run-env/tmp/" \
  XDG_DATA_HOME="$root/run-env/xdg-data" XDG_CACHE_HOME="$root/run-env/xdg-cache" \
  XDG_CONFIG_HOME="$root/run-env/xdg-config" XDG_RUNTIME_DIR="$root/run-env/xdg-runtime" \
  ZB_E2E_SOCKET_DIR="$root/s" ZB_DEBUG_EPHEMERAL_DATA_STORE=1
# The before snapshot of this user's /var/folders, ahead of the first browser launch (evidence in the run root).
. "$root/tests/mac/mac_varfolders_audit.sh" || exit 1
. "$root/tests/mac/mac_crashreports_audit.sh" || exit 1
# Self-audit (SilverRidge 5f1ce9a5): on this Mac's own /bin/bash and /usr/bin/python3, one complete cycle of each
# helper, inside an outer /var/folders audit, must complete and retain every reported delta; otherwise start nothing.
# Its whole output is evidence: each step's lines as SELFAUDIT<TAB><step><TAB>..., then SELFAUDIT_STATUS<TAB><step><TAB>
# <exit status>, for the steps outer-begin (silent), inner-varfolders and inner-crashreports (each a full cycle ending
# in a canonical COMPLETE count) and outer-end (a canonical COMPLETE count).
self_ev="$root/evidence/selfaudit"
mkdir -p "$self_ev" || exit 1
selfstep() { # selfstep <step> <terminal it must end with, or - for silent> <command...>: run, record, judge
  local step=$1 want=$2 rc last
  shift 2
  "$@" > "$self_ev/$step.out" 2>&1; rc=$?
  last=$(tail -n 1 "$self_ev/$step.out")
  sed "s/^/SELFAUDIT$T$step$T/" "$self_ev/$step.out"
  printf 'SELFAUDIT_STATUS\t%s\t%s\n' "$step" "$rc"
  [ "$rc" -eq 0 ] || return 5
  if [ "$want" = - ]; then
    [ ! -s "$self_ev/$step.out" ] || return 5
  elif [ "$want" = VARFOLDERS-COMPLETE ]; then
    local count deltas
    [[ "$last" =~ ^VARFOLDERS${T}COMPLETE${T}(0|[1-9][0-9]*)$ ]] || return 5
    [ "$(grep -c "^VARFOLDERS${T}COMPLETE${T}" "$self_ev/$step.out")" -eq 1 ] || return 5
    ! grep -q "^VARFOLDERS${T}INCONCLUSIVE${T}" "$self_ev/$step.out" || return 5
    count=${last##*"$T"}
    deltas=$(grep -c "^VARFOLDERS-DELTA${T}" "$self_ev/$step.out")
    [ "$deltas" = "$count" ] || return 5
  else
    [ "$last" = "$want" ] || return 5
  fi
}
vf_cycle() { varfolders_begin "$1" && varfolders_end "$1"; }
cr_cycle() { crashreports_begin "$1" "$crash_dir" && crashreports_end "$1" "$crash_dir"; }
ev_cycle() { mkdir -p "$1/sample" && printf 'sample\n' > "$1/sample/a" && pack_evidence "$1/sample"; }
selfaudit() { # every step must succeed with its exact terminal, in this order, or the leg starts nothing
  selfstep outer-begin - varfolders_begin "$self_ev/outer" || return 5
  selfstep inner-varfolders VARFOLDERS-COMPLETE vf_cycle "$self_ev/inner" || return 5
  selfstep inner-crashreports "CRASHREPORTS${T}COMPLETE${T}0" cr_cycle "$self_ev/crash" || return 5
  selfstep inner-evidence - ev_cycle "$self_ev/pack" || return 5
  selfstep outer-end VARFOLDERS-COMPLETE varfolders_end "$self_ev/outer" || return 5
}
selfaudit || exit 5   # a helper changed something there or did not complete: no RUNNING marker, no row, no browser
# From here every exit packs the evidence first (the packer is proven above); this side copies it back.
trap 'pack_evidence "$root/evidence" || printf "EVIDENCE_PACK_FAILED\n"' EXIT
printf 'EVIDENCE_ARMED\n'
varfolders_begin "$root/evidence/varfolders" || exit 5   # refused (fail closed): no RUNNING marker, no row, no browser
# The crash-report listing (orchestrator 2026-10-23): any new report there makes this leg INCONCLUSIVE, never a pass.
crashreports_begin "$root/evidence/crashreports" "$crash_dir" || exit 5   # refused, as above

# Only the signal row needs the package. Its DMG and controller identity arrive before this leg starts; verify that
# exact digest before attach, preserve it through read-only attach/ditto/detach, and bind the universal executable,
# shim reference, signature and exact commit into one fixed manifest before the runtime row can launch.
app_digest() {
  local app=${1:?}
  /usr/bin/python3 - "$app" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
app = Path(sys.argv[1])
entries = []
for dirpath, dirs, names in os.walk(app, followlinks=False):
    dirs.sort(key=os.fsencode); names.sort(key=os.fsencode); base = Path(dirpath)
    for name in dirs + names:
        path = base / name
        entries.append((os.fsencode(os.path.relpath(path, app)), path))
digest = hashlib.sha256()
for rel, path in sorted(entries):
    info = path.lstat()
    if stat.S_ISREG(info.st_mode):
        item = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""): item.update(chunk)
        kind, payload = b"f", item.digest()
    elif stat.S_ISDIR(info.st_mode): kind, payload = b"d", b""
    elif stat.S_ISLNK(info.st_mode): kind, payload = b"l", os.fsencode(os.readlink(path))
    else: raise SystemExit(1)
    for field in (rel, kind, ("%o" % stat.S_IMODE(info.st_mode)).encode(), payload):
        digest.update(len(field).to_bytes(8, "big")); digest.update(field)
print(digest.hexdigest())
PY
}
prepare_signal_package() {
  local identity commit want_dmg extra dmg dmg_before dmg_after dmg_bytes att dev mp mounted_app mounted_sha
  local app app_sha exe build shim exe_sha build_sha shim_sha exe_bytes build_bytes shim_bytes
  local exe_archs shim_archs x86_refs arm_refs
  identity="$root/signal-package.identity"
  [ -f "$identity" ] && [ ! -L "$identity" ] || return 1
  IFS=$'\t' read -r commit want_dmg extra < "$identity" || return 1
  [ -z "${extra:-}" ] && [[ "$commit" =~ ^[0-9a-f]{40}$ ]] && [[ "$want_dmg" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  [ "$(wc -l < "$identity")" -eq 1 ] || return 1
  local run_commit=${root##*/zb-gate-}; run_commit=${run_commit%%-*}
  [ "$run_commit" = "$commit" ] || return 1
  dmg="$root/zigBrowser-exact.dmg"
  [ -f "$dmg" ] && [ ! -L "$dmg" ] && [ -s "$dmg" ] || return 1
  dmg_before=$(shasum -a 256 "$dmg" | awk '{print $1}') || return 1
  [ "$dmg_before" = "$want_dmg" ] || return 1
  canonical_bytes() { # canonical_bytes <regular file>: one unpadded nonnegative decimal or nonzero
    local raw
    raw=$(wc -c < "${1:?}") || return 1
    [[ "$raw" =~ ^[[:space:]]*(0|[1-9][0-9]*)[[:space:]]*$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
  }
  dmg_bytes=$(canonical_bytes "$dmg") || return 1
  [[ "$dmg_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  mkdir "$root/mnt" "$root/app" || return 1
  att=$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$root/mnt" "$dmg") || return 1
  dev=$(printf '%s\n' "$att" | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {print $1; exit}')
  mp=$(printf '%s\n' "$att" | awk -F'\t' -v m="$root/mnt" '$NF == m {print $NF; exit}')
  [ -n "$dev" ] && [ "$mp" = "$root/mnt" ] || return 1
  mounted_app="$root/mnt/zigBrowser.app"
  [ -d "$mounted_app" ] && [ ! -L "$mounted_app" ] || { hdiutil detach "$dev"; return 1; }
  mounted_sha=$(app_digest "$mounted_app") || { hdiutil detach "$dev"; return 1; }
  ditto "$mounted_app" "$root/app/zigBrowser.app" || { hdiutil detach "$dev"; return 1; }
  app="$root/app/zigBrowser.app"
  app_sha=$(app_digest "$app") || { hdiutil detach "$dev"; return 1; }
  hdiutil detach "$dev" || return 1
  dmg_after=$(shasum -a 256 "$dmg" | awk '{print $1}') || return 1
  [ "$dmg_before" = "$dmg_after" ] && [ "$mounted_sha" = "$app_sha" ] || return 1
  exe="$app/Contents/MacOS/zigBrowser"
  build="$root/zig-out/bin/zigBrowser"
  shim="$app/Contents/Frameworks/libwkwebview_shim.dylib"
  [ -f "$exe" ] && [ ! -L "$exe" ] && [ -s "$exe" ] && [ -x "$exe" ] || return 1
  [ -f "$build" ] && [ ! -L "$build" ] && [ -s "$build" ] || return 1
  [ -f "$shim" ] && [ ! -L "$shim" ] && [ -s "$shim" ] || return 1
  exe_sha=$(shasum -a 256 "$exe" | awk '{print $1}')
  build_sha=$(shasum -a 256 "$build" | awk '{print $1}')
  shim_sha=$(shasum -a 256 "$shim" | awk '{print $1}')
  exe_bytes=$(canonical_bytes "$exe") || return 1
  build_bytes=$(canonical_bytes "$build") || return 1
  shim_bytes=$(canonical_bytes "$shim") || return 1
  [[ "$exe_bytes" =~ ^[1-9][0-9]*$ ]] && [[ "$build_bytes" =~ ^[1-9][0-9]*$ ]] \
    && [[ "$shim_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$exe_sha" != "$build_sha" ] && ! [ "$exe" -ef "$build" ] || return 1
  exe_archs=$(lipo -archs "$exe" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ') || return 1
  shim_archs=$(lipo -archs "$shim" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ') || return 1
  [ "$exe_archs" = 'arm64 x86_64 ' ] && [ "$shim_archs" = 'arm64 x86_64 ' ] || return 1
  codesign --verify --strict --deep --verbose=2 "$app" > "$root/evidence/package.codesign" 2>&1 || return 1
  otool -arch x86_64 -L "$exe" > "$root/evidence/package.otool-x86_64" 2>&1 || return 1
  otool -arch arm64 -L "$exe" > "$root/evidence/package.otool-arm64" 2>&1 || return 1
  x86_refs=$(grep -cF "${T}@executable_path/../Frameworks/libwkwebview_shim.dylib (" \
    "$root/evidence/package.otool-x86_64")
  arm_refs=$(grep -cF "${T}@executable_path/../Frameworks/libwkwebview_shim.dylib (" \
    "$root/evidence/package.otool-arm64")
  [ "$x86_refs" -eq 1 ] && [ "$arm_refs" -eq 1 ] || return 1
  {
    printf 'PACKAGE_COMMIT\t%s\n' "$commit"
    printf 'PACKAGE_PRODUCER\tpackaging/macos/build-dmg.sh\t%s\t%s\n' "$commit" "$want_dmg"
    printf 'PACKAGE_FLOW\thdiutil-attach-readonly\tditto\n'
    printf 'PACKAGE_DMG\t%s\t%s\t%s\n' "$dmg_after" "$dmg_bytes" "$dmg"
    printf 'PACKAGE_APP\t%s\t%s\n' "$app_sha" "$app"
    printf 'PACKAGE_EXECUTABLE\t%s\t%s\t%s\n' "$exe_sha" "$exe_bytes" "$exe"
    printf 'PACKAGE_BUILD_EXECUTABLE\t%s\t%s\t%s\n' "$build_sha" "$build_bytes" "$build"
    printf 'PACKAGE_SHIM\t%s\t%s\t%s\n' "$shim_sha" "$shim_bytes" "$shim"
    printf 'PACKAGE_UNIVERSAL\texecutable=arm64,x86_64\tshim=arm64,x86_64\n'
    printf 'PACKAGE_CODESIGN\t--verify --strict --deep\trc=0\n'
    printf 'PACKAGE_SHIM_REF\t%s\tx86_64=1\tarm64=1\n' \
      '@executable_path/../Frameworks/libwkwebview_shim.dylib'
  } > "$root/evidence/package.manifest"
}
need_signal=0
for selected in "$@"; do [ "${selected##*|}" = mac-signal-runtime ] && need_signal=1; done
if [ "$need_signal" -eq 1 ]; then prepare_signal_package || { printf 'PACKAGE_REFUSED\n'; exit 1; }; fi
# Durable before any row: only a clean finish below removes it, so a timeout or a death holds this host.
printf 'RUNNING\t%s\tthe leg did not finish; processes may be left running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$root/LEAKED" || exit 1
overall=0
for row in "$@"; do
  IFS='|' read -r file want id <<<"$row"
  # bd 3ui.16: the row's whole output is collected into a file first and only then searched, never through a pipe
  # (under pipefail an early-exiting `grep -q` can SIGPIPE its producer, and a LEAK line followed by more output than a
  # pipe holds would be missed). A search that cannot read the file stops the host as a possible leak.
  rowlog="$root/evidence/rows/${id}.out"
  mkdir -p "$root/evidence/rows" || exit 1
  if [ "$id" = mac-signal-runtime ]; then
    commit=${root##*/zb-gate-}; commit=${commit%%-*}
    python3 "$file" --browser "$root/app/zigBrowser.app/Contents/MacOS/zigBrowser" --package-evidence "$root/evidence/package.manifest" --package-commit "$commit" > "$rowlog" 2>&1; rc=$?
  else
    python3 "$file" --browser "$root/zig-out/bin/zigBrowser" > "$rowlog" 2>&1; rc=$?
  fi
  { grep -E "^(ASSERT|RED_SHAPE|RED_SHAPE_MISMATCH|PASS|FAIL)$T" "$rowlog"; tail -n 40 "$rowlog"; } | sed "s|^|    $file: |"
  verdict=MATCH
  case "$want" in
    red) [ "$rc" -eq 1 ] || verdict=MISMATCH
         [ "$(grep -cxF "RED_SHAPE$T$id" "$rowlog")" -eq 1 ] || verdict=MISMATCH
         grep -qE 'RED_SHAPE_MISMATCH|PRECONDITION|binary-missing' "$rowlog"; [ "$?" -eq 1 ] || verdict=MISMATCH ;;
    green) [ "$rc" -eq 0 ] && grep -qxF "PASS$T$id" "$rowlog" || verdict=MISMATCH
           grep -q "^FAIL$T" "$rowlog"; [ "$?" -eq 1 ] || verdict=MISMATCH ;;
    *) verdict=MISMATCH ;;
  esac
  printf 'ROW\t%s\t%s\trc=%s\t%s\n' "$file" "$want" "$rc" "$verdict"
  grep -q "^LEAK$T" "$rowlog"; leak=$?   # 0 a leak, 1 none, anything else: the output could not be searched
  if [ "$leak" -ne 1 ]; then   # a process was left running (or may have been): stop this host now
    grep "^LEAK$T" "$rowlog" | sed 's/^LEAK/LEAKED/' > "$root/LEAKED"   # grep and sed each read all their input
    [ -s "$root/LEAKED" ] || printf 'LEAKED\tUNKNOWN\tthe output of %s could not be searched\n' "$file" > "$root/LEAKED"
    printf 'HOST_STOPPED\t%s\t%s\n' "$file" "$root"
    cat "$root/LEAKED"
    varfolders_end "$root/evidence/varfolders"   # the rows so far wrote what they wrote: report it; a leak still wins
    crashreports_end "$root/evidence/crashreports" "$crash_dir"
    exit 3
  fi
  [ "$verdict" = MATCH ] || overall=1
done
rm -f -- "${root:?}/LEAKED"   # every row finished and none left a process running
audit=0
varfolders_end "$root/evidence/varfolders" || audit=5
crashreports_end "$root/evidence/crashreports" "$crash_dir" || audit=5
[ "$audit" -eq 0 ] || exit 5   # INCONCLUSIVE: the rows are not judged
exit "$overall"
REMOTE
  cat -- "$legout"
  local ev=0 exact=1
  # The exact remote success lines are judged first (bd 3ui.14), before any evidence retrieval; the evidence is still
  # fetched after a refusal, so a refused leg keeps it.
  if [ "$leg_rc" -eq 0 ]; then leg_output_exact "$host" "$label" "$legout" || exact=0; fi
  fetch_evidence "$host" "$key" "$label" "$legout" && ev=1
  case "$leg_rc" in   # which run dirs stay: a leak stop or a timeout always, any other leg without verified evidence
    3|124) mac_keep_run_dir "$host" "$MAC_RDIR" "leg exit $leg_rc: a process may be left running; kept and held for a person" ;;
    *) [ "$ev" -eq 1 ] || mac_keep_run_dir "$host" "$MAC_RDIR" "its evidence was not copied and verified; kept for a person" ;;
  esac
  case "$leg_rc" in
    0) [ "$exact" -eq 1 ] || return 1 ;;
    3|124)
      echo "STOPPED: $host ($label): $([ "$leg_rc" -eq 3 ] && echo 'a row left a process running (LEAKED lines above)' \
        || echo 'the leg timed out; processes may be left running'). Run dir ~/$MAC_RDIR is KEPT. A person must stop" \
        "exactly the reported process before any cleanup of it or further work on $host." >&2
      return 1 ;;
    4) echo "HELD: $host ($label) still has a run dir with a leaked process (HOST_HELD above); nothing ran" >&2; return 1 ;;
    5) echo "INCONCLUSIVE: $host ($label): the helper self-audit, the /var/folders audit or the crash-report listing" \
         "is INCONCLUSIVE (above); its rows are not judged" >&2; return 1 ;;
    *) echo "FAIL: rows leg on $host failed (exit $leg_rc)" >&2; return 1 ;;
  esac
  [ "$ev" -eq 1 ] || { echo "FAIL: $host ($label): no verified evidence archive (EVIDENCE above)" >&2; return 1; }
  printf 'PASS\tms-runtime-rows-leg\t%s\t%s\n' "$host" "$label"
}

leg_output_exact() { # $1=host $2=arch $3=leg output: the exact remote success lines of this leg (bd 3ui.14), else
  # FAIL<TAB>remote-success<TAB>ms_runtime_rows_gate<TAB>host<TAB>arch<TAB>missing and non-zero
  local host=$1 arch=$2 f=$3 row file want id step
  local -a need=()
  for row in "${RUN_ROWS[@]}"; do
    IFS='|' read -r file want id <<<"$row"
    need+=("ROW"$'\t'"$file"$'\t'"$want"$'\t'"rc=$([ "$want" = green ] && echo 0 || echo 1)"$'\t'"MATCH")
  done
  for step in outer-begin inner-varfolders inner-crashreports inner-evidence outer-end; do
    need+=("SELFAUDIT_STATUS"$'\t'"$step"$'\t'"0")
  done
  need+=($'CRASHREPORTS\tCOMPLETE\t0' EVIDENCE_ARMED)
  local line bad=0   # every required record exactly once (a duplicate is no pass), then mac_require_lines for presence
  [ "$(grep -c $'^ROW\t' "$f")" -eq "${#RUN_ROWS[@]}" ] && [ "$(grep -cE $'^VARFOLDERS\tCOMPLETE\t[0-9]+$' "$f")" -eq 1 ] || bad=1
  for line in "${need[@]}"; do [ "$(grep -cxF -- "$line" "$f")" -le 1 ] || bad=1; done
  if [ "$bad" -ne 0 ]; then
    printf 'FAIL\tremote-success\t%s\t%s\t%s\tmissing\n' ms_runtime_rows_gate "$host" "$arch" >&2; return 1
  fi
  mac_require_lines ms_runtime_rows_gate "$host" "$arch" "$(cat -- "$f")" "${need[@]}"
}
fetch_evidence() { # $1=host $2=key $3=arch $4=leg output: copy the leg's evidence archive and its sha256 into
  # $EVD/<arch> and verify it; prints one EVIDENCE line; non-zero unless the copy matches the Mac's sha256
  local host=$1 key=$2 dst="$EVD/$3" want got f
  local -a SCP
  if ! grep -qx 'EVIDENCE_ARMED' "$4"; then
    printf 'EVIDENCE\t%s\t%s\tNONE\tthe leg ended before it armed its evidence archive\n' "$host" "$3"; return 1
  fi
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  for f in evidence.tar evidence.tar.sha256; do
    if ! "${SCP[@]}" "$host:$MAC_RDIR/$f" "$dst/$f" </dev/null; then
      printf 'EVIDENCE\t%s\t%s\tFAILED\tcould not copy %s\n' "$host" "$3" "$f"; return 1
    fi
  done
  want=$(awk 'NR == 1 { print $1 }' "$dst/evidence.tar.sha256")
  got=$(sha256sum "$dst/evidence.tar" | awk '{ print $1 }')
  if ! [[ "$want" =~ ^[0-9a-f]{64}$ ]] || [ "$want" != "$got" ]; then
    printf 'EVIDENCE\t%s\t%s\tFAILED\tthe copy (%s) is not the Mac archive (%s)\n' "$host" "$3" "$got" "$want"; return 1
  fi
  printf 'EVIDENCE\t%s\t%s\t%s\t%s\t%s\n' "$host" "$3" "$got" "$(wc -c < "$dst/evidence.tar")" "$dst/evidence.tar"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 rows leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 rows leg" >&2; overall=1; fi

# Every evidence copy is done: remove the run dirs and verify each is gone (a dir that may remain is no PASS).
mac_remove_run_dirs || { echo "FAIL: a run dir was not confirmed removed (RETAINED above)" >&2; overall=1; }
if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms-runtime-rows-gate\tboth-arches\n'
else
  echo "runtime rows gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
