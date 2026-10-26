#!/usr/bin/env bash
# MS6 gate (containment half) — the macOS agent Seatbelt sandbox on BOTH Macs.
#
# No display, no browser, no install: runs a stand-in helper under /usr/bin/sandbox-exec with the agent
# profile and asserts containment (denied file write/read + network fail closed, child contained, allowed
# workspace write works). sandbox-exec denials are silent EPERM — nothing appears on the Mac's screen.
# Driven from Linux over Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
#
# SCOPE (RoseCat 7120 #2): this is the containment and PROBE gate (MS6.1, MS6.2, MS6.4a and the fd-3 stand-in probe).
# It is NOT the MS6 hard gate. The real-CLI hard cases (MS6.3 fd-3, MS6.6 (B) R1 chain) run in
# tests/mac/ms6_hard_gate.sh, which stays NOT ARMED until the MS5 dependency decision pins the tree it stages.
# seatbelt_ready binds only to the complete gate, never to this one's PASS alone.
set -euo pipefail


export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"

ssh_opts() { printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$1" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  -o ConnectTimeout=15 -o ServerAliveInterval=10; }
scp_opts() { printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -F none -i "$1" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
  -o ConnectTimeout=15; }


LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-180}"
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-drv-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-ms6-drv-??????) rm -rf -- "${stage:?}";; esac' EXIT
FILES=(tests/mac/agent_sandbox_containment_spike.sb tests/mac/sandbox_containment_test.sh
       tests/mac/agent_sandbox_ms6_1_token_isolation.sb tests/mac/ms6_1_token_isolation_test.sh
       tests/mac/ms6_1_procinfo_probe.c tests/mac/ms6_generated_profile_test.sh
       tests/mac/ms6_3_fd3_reopen_test.sh tests/mac/ms6_3_fd3_reopen.c tests/mac/ms6_4_egress_test.sh
       tests/mac/ms6_4_connect_probe.c agent/host/zb_agent_host/__init__.py
       agent/host/zb_agent_host/files.py agent/host/zb_agent_host/launch.py agent/host/zb_agent_host/options.py
       agent/host/zb_agent_host/platforms.py agent/host/zb_agent_host/relay.py
       agent/host/zb_agent_host/sandbox.py agent/host/zb_agent_host/sandbox_macos.py
       agent/host/zb_agent_host/seatbelt_rules.py
       agent/host/zb_agent_host/seccomp.py agent/host/zb_agent_host/netd.py)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
STAGED_FILES=()
for f in "${FILES[@]}"; do STAGED_FILES+=("$stage/$f"); done

verify_host() { # $1=host $2=key $3=label (the label is the EXPECTED uname -m, asserted on the host)
  local host="$1" key="$2" label="$3"
  local -a SSH SCP; mapfile -d '' SSH < <(ssh_opts "$key"); mapfile -d '' SCP < <(scp_opts "$key")
  echo "== MS6 Seatbelt containment on $host ($label) ==" >&2
  local rdir="zb-ms6-$(date +%s)-$$-$RANDOM"
  local rm_rdir="rm -rf \"\$HOME/${rdir:?}\""
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir}\"" || { echo "FAIL: mkdir ${rdir} on $host" >&2; return 1; }
  "${SCP[@]}" "${STAGED_FILES[@]}" "$host":"${rdir}"/ >/dev/null \
    || { echo "FAIL: scp MS6 sources to $host" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_EXPECT_ARCH='${label}' ZB_RDIR='${rdir}' /bin/bash -s" <<'REMOTE'
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
/bin/sh "$d/ms6_generated_profile_test.sh" "$d"
/bin/sh "$d/ms6_3_fd3_reopen_test.sh" "$d"
/bin/sh "$d/ms6_4_egress_test.sh" "$d"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: MS6 leg on $host timed out/failed" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
  mac_require_lines ms6_gate "$host" "$label" "$out" $'PASS\tms6-containment' $'PASS\tms6.1-token-isolation' \
    $'PASS\tms6-generated-profiles' \
    $'PASS\tms6-3-fd3-reopen-PROBE (partial; MS6.3 real-CLI hard gate pending the MS5-gated harness)' \
    $'PASS\tms6-4-egress' || return 1
  printf 'PASS\tms6-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS6 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS6 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms6-containment-probe-gate\tboth-arches\t(not the MS6 hard gates: MS6.3 and MS6.6(B) are NOT ARMED; seatbelt_ready needs the complete gate)\n'
else
  echo "MS6 gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
