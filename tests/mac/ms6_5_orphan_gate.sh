#!/usr/bin/env bash
# MS6.5 orphan-cleanup gate (plan :1619) — on BOTH Macs, a hook that double-forks + setsid()s to escape setup's
# process group MUST still be reaped within 2 s of the browser's kill -9. zb_agent_spawn_group starts
# tests/mac/ms6_5_escape_stub.py as a group leader; the stub arms zb_agent_host.parent_watch and launches a
# detached escaping hook; ms6_5_orphan_test.c SIGKILLs the stand-in browser and checks the escapee is dead.
#
# RED-FIRST: this is EXPECTED to fail today — parent_watch reaps with killpg(setup's pgid), which a setsid'd
# survivor escapes (macOS has no PID namespace; the double-fork reparents it to launchd). It is intentionally
# NOT part of tests/mac/ms6_gate.sh (which stays green). A descendant-tree walk CANNOT close it (RoseCat 7043);
# it greens only once a truly non-escapable containment lands with its own threat proof — otherwise the VM
# fallback is required and Mac agent launch stays disabled (plan :285, :1619-1620). Per-run ~/zb-ms65o-<nonce>,
# deleted on exit; /usr/bin/python3 stdlib only; BatchMode, strict host keys, no askpass.
#
# Per-host key/host like the canonical MS6 gate (RoseCat 7043 SHOULD): ZB_MAC_ARM_KEY defaults to the main key,
# and ZB_MAC_ARM_HOST is REQUIRED (no built-in default).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host) — the MS6.5 gate needs both arches" >&2
  exit 1
fi

FILES=(tests/mac/ms6_5_orphan_test.c tests/mac/ms6_5_escape_stub.py)
[ -f src/agent_spawn_posix.c ] && FILES+=(src/agent_spawn_posix.c src/agent_spawn_posix.h)

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH SCP
  SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
       -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
  SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY scp -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
       -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
  local rdir="zb-ms65o-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir -p \"\$HOME/${rdir:?}/host/zb_agent_host\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "${FILES[@]}" "$host:${rdir}/" >/dev/null ||
     ! "${SCP[@]}" agent/host/zb_agent_host/__init__.py agent/host/zb_agent_host/parent_watch.py "$host:${rdir}/host/zb_agent_host/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
srcs=(ms6_5_orphan_test.c)
[ -f agent_spawn_posix.c ] && srcs+=(agent_spawn_posix.c)
xcrun clang -Wall -I "$d" -Wl,-U,_zb_agent_spawn_group "${srcs[@]}" -o ms6_5_orphan_test || { echo "FAIL: build"; exit 1; }

# zero matching processes anywhere for this user (RoseCat 7052 #1: assert immediately after the driver returns)
survivors() { ps -axo pid=,command= | grep -F 'ms6_5_escape_stub.py' | grep -v grep || true; }

# Scenario 1 — the gap: the escapee survives the browser's SIGKILL (MS6.5 UNMET). The driver exits non-zero with
# the SURVIVED assertion; cleanup must still leave zero survivors.
./ms6_5_orphan_test "$d/ms6_5_escape_stub.py" /usr/bin/python3 > o1 2>&1 || true
sed 's/^/  main| /' o1
grep -q "SURVIVED the browser" o1 || { echo "FAIL: scenario 1 did not reach the intended SURVIVED assertion"; exit 1; }
s1="$(survivors)"; [ -z "$s1" ] || { echo "FAIL: survivors after scenario 1:"; echo "$s1"; exit 1; }

# Scenario 2 — the deterministic late-publish race: readiness window 1 s, the escapee publishes at 3 s, so the
# driver body times out BEFORE learning the pid and only trusted_reap can reap it. Cleanup must leave zero.
./ms6_5_orphan_test "$d/ms6_5_escape_stub.py" /usr/bin/python3 1 3 > o2 2>&1 || true
sed 's/^/  late| /' o2
grep -q "never detached in the readiness window" o2 || { echo "FAIL: scenario 2 did not exercise the late-publish timeout"; exit 1; }
grep -q "still alive after trusted_reap" o2 && { echo "FAIL: scenario 2 left an escapee alive after trusted_reap"; exit 1; }
s2="$(survivors)"; [ -z "$s2" ] || { echo "FAIL: survivors after scenario 2 (the late-publish race leaked):"; echo "$s2"; exit 1; }

echo "ms6-5 $(uname -m): GAP CONFIRMED (escapee survives the kill — MS6.5 UNMET) and cleanup left ZERO survivors in both scenarios"
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg (cleanup/hygiene or gap-shape problem — see above)" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg (cleanup/hygiene or gap-shape problem — see above)" >&2; overall=1; }
if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms6-5-orphan-gate\tboth-arches (gap demonstrated + cleanup clean)\n'
  echo "NOTE: MS6.5 itself remains UNMET — the escapee survives the kill. This gate only proves the gap is real and" >&2
  echo "      the harness leaves no survivors. Closing MS6.5 needs the containment decision (sandbox_check SPI vs VM)." >&2
else
  echo "ms6-5-orphan-gate: a leg FAILED its hygiene/gap assertions (NOT the expected-unmet state) — see above" >&2
fi
exit "$overall"
