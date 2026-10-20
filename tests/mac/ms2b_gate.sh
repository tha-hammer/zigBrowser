#!/usr/bin/env bash
# MS2b gate — the WKWebView native-input port (nativeKey / nativeText) on BOTH Macs (unsigned build).
#
# Builds zigBrowser NATIVELY on each Mac (no -Dtarget) and runs the MS2b native-input e2e there: trusted
# key/text delivery, the FIFO ack, the ack-error and documentToken DOC_CHANGED guards, the per-pair
# ownership transition that closes the check->send race, and the partial-timeout contract. Like ms2a,
# WKWebView needs the WindowServer, so this runs as the console user (no xvfb). Driven from Linux over
# Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
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
  echo "        the MS2b two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-420}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-600}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(ssh_opts "$key")
  echo "== build + MS2b e2e on $host ($label) ==" >&2
  ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" timeout "$BUILD_TIMEOUT" bash tests/mac/build-on-mac.sh || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s <<'REMOTE' || { echo "FAIL: MS2b leg on $host timed out/failed" >&2; return 1; }
set -euo pipefail
cd "$HOME/zigBrowser"
python3 tests/e2e/mac_ms2b_native_input_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_key_text_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_ack_error_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_doc_changed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_text_doc_changed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_partial_type_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_pair_race_test.py --browser zig-out/bin/zigBrowser
REMOTE
  printf 'PASS\tms2b-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS2b leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS2b leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms2b-gate\tboth-arches\n'
else
  echo "MS2b gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
