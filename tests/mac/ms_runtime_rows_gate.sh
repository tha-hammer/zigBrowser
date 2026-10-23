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
# A ROW is `<tests/e2e file>|<red|green>|<required line>...`, judged on the Mac:
#   red   exit 1, its own FAIL<TAB> line, EVERY required line present as a substring of the output (the exact
#         failing assertions, so a red that fails in another shape is a MISMATCH), and no PRECONDITION or
#         binary-missing line;
#   green exit 0, its own PASS<TAB> line, and every required line present.
# Every row runs (one row's result never stops the next); each prints its output and a
# ROW<TAB><file><TAB><want><TAB>rc=<n><TAB>MATCH|MISMATCH line. The gate prints PASS<TAB>ms-runtime-rows-gate<TAB>both-arches
# only when every row on both Macs matched. Console user, no xvfb (WKWebView needs the WindowServer), like ms2a/ms2c.
# Hostless selftests: tests/mac/mac_gate_callers_selftest.sh (structure, and this leg's verdicts and environment;
# zig build test-mac-build-script).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

T=$'\t'
# The run request: one row per red, with the exact assertion lines each must fail on today, plus the coverage row
# of the e2e-only ephemeral store (hook 16).
ROWS=(
  "tests/e2e/mac_ephemeral_store_test.py|green|PASS${T}ms3-ephemeral-store"
  "tests/e2e/mac_ms2a_load_fail_no_quit_test.py|red|row1-click-dead-link: the browser exited (rc=5)|row2-routed-then-location: the browser exited (rc=5)|PASS${T}row5-initial-load-exits"
  "tests/e2e/mac_ms2c_recover_slow_server_test.py|red|the browser exited (rc=8)"
  "tests/e2e/mac_ms2c_close_button_test.py|red|1: the natively closed popup|2: a command routed to the closed popup did not fail with no_window|5: the shared destroy path did not run"
  "tests/e2e/mac_ms2b_dialog_popup_id_test.py|red|1: dialog.get listed the confirm under 'window-2', page.list id is 'window-3'|2: dialog.get on window-3 did not report the open confirm|3: answering the listed window failed"
  "tests/e2e/mac_cookie_timeout_test.py|red|1 cookies.getAll: want the action_timeout error|2 cookies.getAll: returned after|1 cookies.set: want the action_timeout error|2 cookies.set: returned after|1 cookies.delete: want the action_timeout error|2 cookies.delete: returned after"
  "tests/e2e/mac_profile_pacing_persist_test.py|red|1: after run 1|2: after a restart on the same --profile-dir daily_cap is"
)

cd "$(git rev-parse --show-toplevel)"
for row in "${ROWS[@]}"; do   # fail closed on a malformed row, before any host is touched
  [[ "$row" =~ ^tests/e2e/mac_[a-z0-9_]+_test\.py\|(red|green)\|[^|]+ ]] || { echo "FAIL: bad row $row" >&2; exit 1; }
done
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  echo "        the two-arch rows gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-600}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-900}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  echo "== build + runtime rows on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" "${ROWS[@]}" <<'REMOTE' || { echo "FAIL: rows leg on $host timed out/failed" >&2; return 1; }
set -uo pipefail
cd "$HOME/${1:?}"
shift
# Everything below stays in the run root: a private home, temp dir and XDG dirs, and an ephemeral website store.
root=$PWD
mkdir -p run-env/home run-env/tmp run-env/xdg-data run-env/xdg-cache run-env/xdg-config run-env/xdg-runtime s || exit 1
chmod 700 run-env/xdg-runtime s || exit 1
export HOME="$root/run-env/home" CFFIXED_USER_HOME="$root/run-env/home" TMPDIR="$root/run-env/tmp/" \
  XDG_DATA_HOME="$root/run-env/xdg-data" XDG_CACHE_HOME="$root/run-env/xdg-cache" \
  XDG_CONFIG_HOME="$root/run-env/xdg-config" XDG_RUNTIME_DIR="$root/run-env/xdg-runtime" \
  ZB_E2E_SOCKET_DIR="$root/s" ZB_DEBUG_EPHEMERAL_DATA_STORE=1
overall=0
for row in "$@"; do
  IFS='|' read -r -a part <<<"$row"
  file=${part[0]} want=${part[1]}
  out=$(python3 "$file" --browser zig-out/bin/zigBrowser 2>&1); rc=$?
  printf '%s\n' "$out" | tail -n 60 | sed "s|^|    $file: |"
  verdict=MATCH
  case "$want" in
    red) [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q $'^FAIL\t' || verdict=MISMATCH
         if printf '%s\n' "$out" | grep -qE 'PRECONDITION|binary-missing'; then verdict=MISMATCH; fi ;;
    green) [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q $'^PASS\t' || verdict=MISMATCH ;;
    *) verdict=MISMATCH ;;
  esac
  for need in "${part[@]:2}"; do
    printf '%s\n' "$out" | grep -qF -- "$need" || { verdict=MISMATCH; printf '    MISSING %s\n' "$need"; }
  done
  printf 'ROW\t%s\t%s\trc=%s\t%s\n' "$file" "$want" "$rc" "$verdict"
  [ "$verdict" = MATCH ] || overall=1
done
exit "$overall"
REMOTE
  printf 'PASS\tms-runtime-rows-leg\t%s\t%s\n' "$host" "$label"
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
