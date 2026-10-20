#!/usr/bin/env bash
# MS2a gate — the WKWebView routed-command port runs on BOTH Macs (unsigned build).
#
# Builds zigBrowser NATIVELY on each Mac (no -Dtarget) and runs the MS2a e2e there: the routed
# commands (page.navigate/url/title + the dom.getText eval in the automation world) and the
# main-thread-bridge hang guard. MS2a runs the UNSIGNED build (parallel with MS1b). Driven from
# Linux over Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

cd "$(git rev-parse --show-toplevel)"

ssh_opts() { printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10; }

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  echo "        the MS2a two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

# Build natively on the host, then run the MS2a e2e there (console user, no xvfb — WKWebView needs
# the WindowServer, like tests/mac/gate.sh).
# Outer bounds (seconds): a wedged build or a hung browser must not hang the gate forever (RoseCat).
# GNU `timeout` runs on the Linux driver (it wraps the SSH/build calls, not the Mac side).
BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-420}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-420}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key")
  echo "== build + MS2a e2e on $host ($label) ==" >&2
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" timeout "$BUILD_TIMEOUT" bash tests/mac/build-on-mac.sh || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s <<'REMOTE' || { echo "FAIL: MS2a leg on $host timed out/failed" >&2; return 1; }
set -euo pipefail
cd "$HOME/zigBrowser"
python3 tests/e2e/mac_ms2a_routed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_private_world_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_abi_census_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_late_completion_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_string_ownership_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_timeout_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_nav_failure_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_dispatch_race_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_teardown_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_refused_start_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_user_nav_failure_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_hook_inert_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_stale_callback_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_stale_failure_test.py --browser zig-out/bin/zigBrowser
REMOTE
  printf 'PASS\tms2a-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS2a leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS2a leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms2a-gate\tboth-arches\n'
else
  echo "MS2a gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
