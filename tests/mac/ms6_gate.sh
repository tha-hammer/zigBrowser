#!/usr/bin/env bash
# MS6 gate (containment half) — the macOS agent Seatbelt sandbox on BOTH Macs.
#
# No display, no browser, no install: runs a stand-in helper under /usr/bin/sandbox-exec with the agent
# profile and asserts containment (denied file write/read + network fail closed, child contained, allowed
# workspace write works). sandbox-exec denials are silent EPERM — nothing appears on the Mac's screen.
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
  echo "        the MS6 two-arch gate is INCOMPLETE and cannot pass until it runs" >&2
  exit 1
fi

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-180}"

verify_host() { # $1=host $2=key $3=label (the label is the EXPECTED uname -m, asserted on the host)
  local host="$1" key="$2" label="$3"
  local -a SSH SCP; mapfile -d '' SSH < <(ssh_opts "$key"); mapfile -d '' SCP < <(scp_opts "$key")
  echo "== MS6 Seatbelt containment on $host ($label) ==" >&2
  local rdir="zb-ms6-$(date +%s)-$$-$RANDOM"
  local rm_rdir="rm -rf \"\$HOME/${rdir:?}\""
  "${SSH[@]}" "$host" "mkdir -p \"\$HOME/${rdir}\"" || { echo "FAIL: mkdir ${rdir} on $host" >&2; return 1; }
  "${SCP[@]}" tests/mac/agent_sandbox_containment_spike.sb tests/mac/sandbox_containment_test.sh \
    tests/mac/agent_sandbox_ms6_1_token_isolation.sb tests/mac/ms6_1_token_isolation_test.sh tests/mac/ms6_1_procinfo_probe.c \
    "$host":"${rdir}"/ >/dev/null \
    || { echo "FAIL: scp MS6 sources to $host" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_EXPECT_ARCH='${label}' ZB_RDIR='${rdir}' /bin/bash -s" <<'REMOTE' || { echo "FAIL: MS6 leg on $host timed out/failed" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
got="$(uname -m)"
if [ "$got" != "$ZB_EXPECT_ARCH" ]; then
  echo "FAIL: arch oracle — uname -m=$got but this leg expected $ZB_EXPECT_ARCH (same machine run twice?)" >&2
  exit 1
fi
/bin/sh "$d/sandbox_containment_test.sh" "$d/agent_sandbox_containment_spike.sb"
/bin/sh "$d/ms6_1_token_isolation_test.sh" "$d/agent_sandbox_ms6_1_token_isolation.sb"
REMOTE
  printf 'PASS\tms6-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS6 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS6 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms6-gate\tboth-arches\n'
else
  echo "MS6 gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
