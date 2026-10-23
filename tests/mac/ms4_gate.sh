#!/usr/bin/env bash
# MS4 gate — site-flow / approval-grant groundwork on macOS (load_serial first) on BOTH Macs (unsigned build).
# MS4.4 (BlueBeaver; RoseCat 7886/7902): then the flows' login gate through the WKHTTPCookieStore port
# (tests/e2e/ms4_4_login_gate_test.py: raw RpcClient, local fixtures only, the browser's own process group stopped
# on exit or on SIGTERM/SIGINT/SIGHUP). Any non-zero exit, a skip (77) included, fails the leg.
#
# Builds zigBrowser NATIVELY on each Mac (no -Dtarget) and runs the MS4 e2e there. Like ms2a/b/c,
# WKWebView needs the WindowServer, so this runs as the console user (no xvfb). Driven from Linux over
# Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail


cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# Builds one exact commit into a fresh per-run dir and works only there; pinned host keys (bd 4pa.59, 4pa.77).
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT


BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-420}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-600}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  echo "== build + MS4 e2e on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" <<'REMOTE' || { echo "FAIL: MS4 leg on $host timed out/failed" >&2; return 1; }
set -euo pipefail
cd "$HOME/${1:?}"
python3 tests/e2e/mac_ms4_load_serial_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/ms4_4_login_gate_test.py --binary zig-out/bin/zigBrowser
REMOTE
  printf 'PASS\tms4-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS4 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS4 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms4-gate\tboth-arches\n'
else
  echo "MS4 gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
