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
xcrun clang -Wall -I "$d" -Wl,-U,_zb_agent_spawn_group "${srcs[@]}" -o ms6_5_orphan_test
./ms6_5_orphan_test "$d/ms6_5_escape_stub.py" /usr/bin/python3
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "note: x86_64 leg failed (EXPECTED RED today)" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "note: arm64 leg failed (EXPECTED RED today)" >&2; overall=1; }
if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms6-5-orphan-gate\tboth-arches\n'
else
  echo "ms6-5-orphan-gate: RED (expected until a non-escapable containment lands — a tree-walk cannot close it, RoseCat 7043; else VM fallback, plan :285)" >&2
fi
exit "$overall"
