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
verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key")
  echo "== build + MS2a e2e on $host ($label) ==" >&2
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" bash tests/mac/build-on-mac.sh || return 1
  "${SSH[@]}" "$host" /bin/bash -s <<'REMOTE' || return 1
set -euo pipefail
cd "$HOME/zigBrowser"
python3 tests/e2e/mac_ms2a_routed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_timeout_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2a_nav_failure_test.py --browser zig-out/bin/zigBrowser
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
