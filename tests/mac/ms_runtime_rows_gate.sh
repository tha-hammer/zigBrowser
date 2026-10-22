#!/usr/bin/env bash
# Runtime-fix rows on BOTH Macs (macOS plan R30-MS2/MS3, bd zigBrowser-3ui.1: 4pa.55, 4pa.58, 4pa.57, 4pa.56,
# 4pa.60). Records the reds (and later the greens) of e2e files that are not yet in a slice gate, so recording a red
# never puts a failing test into a registered gate.
#
# Builds ${ZB_GATE_COMMIT:-HEAD} NATIVELY on each Mac through tests/mac/build-on-mac.sh (git archive of the exact
# commit into a fresh ~/zb-gate-<sha>-<nonce>, pinned host keys, both zig caches in that run dir; mac_gate_lib.sh),
# then runs each ROW below in that run dir only. A row is `<tests/e2e file>=<red|green>`, judged on the Mac:
#   red   the test exits 1, prints its own FAIL<TAB> line, and no PRECONDITION or binary-missing failure (a red that
#         fails for the wrong reason does not count);
#   green the test exits 0 and prints its own PASS<TAB> line.
# Every row runs (one row's result never stops the next); each prints its output and a
# ROW<TAB><file><TAB><want><TAB>rc=<n><TAB>MATCH|MISMATCH line. The gate prints PASS<TAB>ms-runtime-rows-gate<TAB>both-arches
# only when every row on both Macs matched. Console user, no xvfb (WKWebView needs the WindowServer), like ms2a/ms2c.
# Hostless selftest: tests/mac/mac_gate_callers_selftest.sh (zig build test-mac-build-script).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

# The run request: two controls (the build and the defect exist), then one row per red.
ROWS=(
  tests/e2e/mac_ms2a_routed_test.py=green                 # control: build, socket and browser work
  tests/e2e/mac_ms2a_user_nav_failure_test.py=green       # control: today's oracle passes because the browser QUITS (4pa.55)
  tests/e2e/mac_ms2a_load_fail_no_quit_test.py=red        # 4pa.55 rows 1-3 (row 5 passes)
  tests/e2e/mac_ms2c_recover_slow_server_test.py=red      # 4pa.55 row 4
  tests/e2e/mac_ms2c_close_button_test.py=red             # 4pa.58 MS2c.6
  tests/e2e/mac_ms2b_dialog_popup_id_test.py=red          # 4pa.57
  tests/e2e/mac_cookie_timeout_test.py=red                # 4pa.56
  tests/e2e/mac_profile_pacing_persist_test.py=red        # 4pa.60 Red 2
)

cd "$(git rev-parse --show-toplevel)"
for row in "${ROWS[@]}"; do   # fail closed on a malformed row, before any host is touched
  [[ "$row" =~ ^tests/e2e/mac_[a-z0-9_]+_test\.py=(red|green)$ ]] || { echo "FAIL: bad row $row" >&2; exit 1; }
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
overall=0
for row in "$@"; do
  file=${row%=*} want=${row##*=}
  out=$(python3 "$file" --browser zig-out/bin/zigBrowser 2>&1); rc=$?
  printf '%s\n' "$out" | tail -n 60 | sed "s|^|    $file: |"
  verdict=MISMATCH
  if [ "$want" = red ] && [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q $'^FAIL\t' \
     && ! printf '%s\n' "$out" | grep -qE 'PRECONDITION|binary-missing'; then verdict=MATCH; fi
  if [ "$want" = green ] && [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q $'^PASS\t'; then verdict=MATCH; fi
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
