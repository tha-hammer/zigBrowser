#!/usr/bin/env bash
# zb_agent_kill_group's ownership guard on BOTH Macs (tests/kill_group/kill_group_test.c; RoseCat 7172, 7182; the
# 2026-10-21 logouts). macOS has no PID namespace, so two layers keep a wrong pid away from a real signal here:
# - src/agent_spawn_posix.c is built as libzbspawn.dylib, and tests/kill_group/kill_group_fake.c as libzbfake.dylib,
#   whose __DATA,__interpose table routes that dylib's killpg/kill to the fake (it forwards only a SIGKILL to the one
#   child leader the test allowlisted), and the test's canary aborts before any case unless the fake intercepts;
# - this gate REFUSES to run a source whose zb_agent_kill_group lacks the `pid <= 1` refusal, so the unguarded code
#   (the red) is never executed on a Mac: the red is shown on Linux only, inside a PID namespace.
# Per-run ~/zb-killgroup-<nonce>, deleted on exit; nothing installed. BatchMode, strict host keys, no askpass; the
# arm64 host is required (no default).
# usage: tests/mac/ms5_kill_group_gate.sh [commit]   (default: the working tree)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  exit 1
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-killgroup-XXXXXX")
# Validated cleanup (RoseCat 7186): only our own mktemp dirs, by find -delete, never an unguarded rm -rf.
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-killgroup-??????) find "${stage:?}" -delete;; esac' EXIT
for f in tests/kill_group/kill_group_test.c tests/kill_group/kill_group_fake.c src/agent_spawn_posix.c \
         src/agent_spawn_posix.h; do
  if [ -n "${1:-}" ]; then git show "$1:$f" > "${stage:?}/$(basename "$f")"; else cp "$f" "${stage:?}/"; fi
done
if ! grep -q 'pid <= 1' "${stage:?}/agent_spawn_posix.c"; then
  echo "NOT RUN: agent_spawn_posix.c has no 'pid <= 1' refusal; the unguarded kill is never run on a Mac" >&2
  exit 1
fi

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-killgroup-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - . | "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
         echo "FAIL: staging on $host" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-killgroup-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
CC=(xcrun clang -std=gnu11 -Wall -Wextra -Werror)
"${CC[@]}" -dynamiclib -o libzbspawn.dylib agent_spawn_posix.c -install_name @rpath/libzbspawn.dylib
"${CC[@]}" -dynamiclib -o libzbfake.dylib kill_group_fake.c -install_name @rpath/libzbfake.dylib
"${CC[@]}" -o kill_group_test kill_group_test.c -L. -lzbfake -lzbspawn -Wl,-rpath,@executable_path
./kill_group_test </dev/null
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-kill-group-gate\tboth-arches\n'
exit "$overall"
