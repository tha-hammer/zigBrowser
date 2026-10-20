#!/usr/bin/env bash
# MS5 gate (Keychain seam half) — the macOS Keychain token store (agent_secrets_mac.m) on BOTH Macs.
#
# No display, no browser, no socket: compiles the seam + its disposable-canary test natively on each Mac
# (xcrun clang, Security + Foundation) and runs it headless. The test creates/unlocks its own throwaway
# keychain, so SecItem never touches the login keychain (which refuses headless, -25308) and never prompts.
# Driven from Linux over Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"

cd "$(git rev-parse --show-toplevel)"

ssh_opts() { printf '%s\0' ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10; }
scp_opts() { printf '%s\0' scp -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=15; }

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  echo "        the MS5 two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-180}"

verify_host() { # $1=host $2=key $3=label (the label is the EXPECTED uname -m, asserted on the host)
  local host="$1" key="$2" label="$3"
  local -a SSH SCP; mapfile -d '' SSH < <(ssh_opts "$key"); mapfile -d '' SCP < <(scp_opts "$key")
  echo "== MS5 Keychain seam on $host ($label) ==" >&2
  # Per-run nonce dir (RoseCat SHOULD): never a fixed shared tree, so concurrent runs can't collide, and
  # cleanup deletes only this exact validated path.
  local rdir="zb-ms5-$(date +%s)-$$-$RANDOM"
  # Best-effort exact-path cleanup for failures BEFORE the remote EXIT trap exists (mkdir/scp). The nonce
  # dir is validated (${rdir:?}) so this never expands to a bare $HOME.
  local rm_rdir="rm -rf \"\$HOME/${rdir:?}\""
  "${SSH[@]}" "$host" "mkdir -p \"\$HOME/${rdir}\"" || { echo "FAIL: mkdir ${rdir} on $host" >&2; return 1; }
  "${SCP[@]}" src/agent_secrets_mac.h src/agent_secrets_mac.m tests/mac/keychain_seam_test.m "$host":"${rdir}"/ >/dev/null \
    || { echo "FAIL: scp MS5 sources to $host" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
  # Pass the expected arch + the nonce dir into the (quoted) remote; the remote asserts the EXECUTING arch
  # against the label (RoseCat #3: two legs must be two architectures, not the same machine twice).
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_EXPECT_ARCH='${label}' ZB_RDIR='${rdir}' /bin/bash -s" <<'REMOTE' || { echo "FAIL: MS5 leg on $host timed out/failed" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT  # delete only this exact nonce dir; the test self-cleans its keychains
got="$(uname -m)"
if [ "$got" != "$ZB_EXPECT_ARCH" ]; then
  echo "FAIL: arch oracle — uname -m=$got but this leg expected $ZB_EXPECT_ARCH (same machine run twice?)" >&2
  exit 1
fi
cd "$d"
xcrun clang -fobjc-arc -Wno-deprecated-declarations -I "$d" \
  -framework Security -framework Foundation \
  keychain_seam_test.m agent_secrets_mac.m -o kc_seam_test
./kc_seam_test
REMOTE
  printf 'PASS\tms5-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS5 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS5 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms5-gate\tboth-arches\n'
else
  echo "MS5 gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
