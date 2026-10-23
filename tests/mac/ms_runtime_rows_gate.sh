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
# incomplete audit (VARFOLDERS<TAB>INCONCLUSIVE) holds the leg from PASS: it exits 5 and its host is INCONCLUSIVE.
# Every row runs (one row's result never stops the next); each prints its output and a
# ROW<TAB><file><TAB><want><TAB>rc=<n><TAB>MATCH|MISMATCH line. The gate prints PASS<TAB>ms-runtime-rows-gate<TAB>both-arches
# only when every row on both Macs matched. Console user, no xvfb (WKWebView needs the WindowServer), like ms2a/ms2c.
# Hostless selftests: tests/mac/mac_gate_callers_selftest.sh (structure, and this leg's verdicts and environment;
# zig build test-mac-build-script).
set -euo pipefail


# The run request: one row per red (its accepted vector is RED_VECTOR in the test file), plus the coverage row of
# the e2e-only ephemeral store (hook 16).
ROWS=(
  "tests/e2e/mac_ephemeral_store_test.py|green|ms3-ephemeral-store"
  "tests/e2e/mac_ms2a_load_fail_no_quit_test.py|red|ms2a-load-fail-no-quit"
  "tests/e2e/mac_ms2c_recover_slow_server_test.py|red|ms2c-recover-slow-server"
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
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT


BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-600}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-900}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  echo "== build + runtime rows on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  local leg_rc=0
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" "${ROWS[@]}" <<'REMOTE' || leg_rc=$?
set -uo pipefail
cd "$HOME/${1:?}"
shift
# Everything below stays in the run root: a private home, temp dir and XDG dirs, and an ephemeral website store.
root=$PWD
T=$'\t'
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
varfolders_begin "$root/evidence/varfolders" || exit 1
# Durable before any row: only a clean finish below removes it, so a timeout or a death holds this host.
printf 'RUNNING\t%s\tthe leg did not finish; processes may be left running\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$root/LEAKED" || exit 1
overall=0
for row in "$@"; do
  IFS='|' read -r file want id <<<"$row"
  out=$(python3 "$file" --browser zig-out/bin/zigBrowser 2>&1); rc=$?
  { printf '%s\n' "$out" | grep -E "^(ASSERT|RED_SHAPE|RED_SHAPE_MISMATCH|PASS|FAIL)$T"; printf '%s\n' "$out" | tail -n 40; } \
    | sed "s|^|    $file: |"
  verdict=MATCH
  case "$want" in
    red) [ "$rc" -eq 1 ] || verdict=MISMATCH
         [ "$(printf '%s\n' "$out" | grep -cxF "RED_SHAPE$T$id")" -eq 1 ] || verdict=MISMATCH
         if printf '%s\n' "$out" | grep -qE 'RED_SHAPE_MISMATCH|PRECONDITION|binary-missing'; then verdict=MISMATCH; fi ;;
    green) [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qxF "PASS$T$id" || verdict=MISMATCH
           if printf '%s\n' "$out" | grep -q "^FAIL$T"; then verdict=MISMATCH; fi ;;
    *) verdict=MISMATCH ;;
  esac
  printf 'ROW\t%s\t%s\trc=%s\t%s\n' "$file" "$want" "$rc" "$verdict"
  if printf '%s\n' "$out" | grep -q "^LEAK$T"; then   # a process was left running: stop this host now
    printf '%s\n' "$out" | grep "^LEAK$T" | sed 's/^LEAK/LEAKED/' > "$root/LEAKED"
    printf 'HOST_STOPPED\t%s\t%s\n' "$file" "$root"
    cat "$root/LEAKED"
    varfolders_end "$root/evidence/varfolders"   # the rows so far wrote what they wrote: report it; a leak still wins
    exit 3
  fi
  [ "$verdict" = MATCH ] || overall=1
done
rm -f -- "${root:?}/LEAKED"   # every row finished and none left a process running
varfolders_end "$root/evidence/varfolders" || exit 5   # INCONCLUSIVE: the rows are not judged
exit "$overall"
REMOTE
  case "$leg_rc" in
    0) ;;
    3|124)
      mac_keep_run_dir "$host" "$MAC_RDIR"
      echo "STOPPED: $host ($label): $([ "$leg_rc" -eq 3 ] && echo 'a row left a process running (LEAKED lines above)' \
        || echo 'the leg timed out; processes may be left running'). Run dir ~/$MAC_RDIR is KEPT. A person must stop" \
        "exactly the reported process before any cleanup of it or further work on $host." >&2
      return 1 ;;
    4) echo "HELD: $host ($label) still has a run dir with a leaked process (HOST_HELD above); nothing ran" >&2; return 1 ;;
    5) echo "INCONCLUSIVE: $host ($label): the /var/folders audit is incomplete (VARFOLDERS INCONCLUSIVE above);" \
         "its rows are not judged" >&2; return 1 ;;
    *) echo "FAIL: rows leg on $host failed (exit $leg_rc)" >&2; return 1 ;;
  esac
  printf 'PASS\tms-runtime-rows-leg\t%s\t%s\n' "$host" "$label"
}

mac_keep_run_dir() { # $1=host $2=run dir: drop it from the EXIT-trap cleanup (mac_gate_lib.sh MAC_RUN_DIRS)
  local entry h k d
  local -a keep=()
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r h k d <<<"$entry"
    if [ "$h" = "$1" ] && [ "$d" = "$2" ]; then continue; fi
    keep+=("$entry")
  done
  MAC_RUN_DIRS=("${keep[@]+"${keep[@]}"}")
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 rows leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 rows leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms-runtime-rows-gate\tboth-arches\n'
else
  echo "runtime rows gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
