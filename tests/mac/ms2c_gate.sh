#!/usr/bin/env bash
# MS2c gate — the WKWebView multi-window / freeze / recovery surface on BOTH Macs (unsigned build).
#
# Builds zigBrowser NATIVELY on each Mac (no -Dtarget) and runs the MS2c e2e there. Like ms2a/ms2b,
# WKWebView needs the WindowServer, so this runs as the console user (no xvfb). Driven from Linux over
# Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

cd "$(git rev-parse --show-toplevel)"
# Builds one exact commit into a fresh per-run dir and works only there; pinned host keys (bd 4pa.59, 4pa.77).
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  echo "        the MS2c two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-420}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-600}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  echo "== build + MS2c e2e on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" <<'REMOTE' || { echo "FAIL: MS2c leg on $host timed out/failed" >&2; return 1; }
set -euo pipefail
cd "$HOME/${1:?}"
python3 tests/e2e/mac_ms2c_list_windows_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_stable_ids_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_window_fifo_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_popup_chain_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_loading_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_process_group_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_oob_during_stuck_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_snapshot_oob_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_dialog_snapshot_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_script_close_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_health_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_close_window_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_crash_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_crash_recovery_controls_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_recover_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_recover_dialog_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2c_recover_stale_health_test.py --browser zig-out/bin/zigBrowser
REMOTE
  printf 'PASS\tms2c-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS2c leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS2c leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms2c-gate\tboth-arches\n'
else
  echo "MS2c gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
