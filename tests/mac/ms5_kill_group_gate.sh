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
# usage: tests/mac/ms5_kill_group_gate.sh [commit]   (default: HEAD)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-killgroup-XXXXXX")
# Validated cleanup (RoseCat 7186): only our own mktemp dirs, by find -delete, never an unguarded rm -rf.
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-killgroup-??????) find "${stage:?}" -delete;; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(tests/kill_group/kill_group_test.c tests/kill_group/kill_group_fake.c src/agent_spawn_posix.c
       src/agent_spawn_posix.h)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
if ! grep -q 'pid <= 1' "${stage:?}/src/agent_spawn_posix.c"; then
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
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-killgroup-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
CC=(xcrun clang -std=gnu11 -Wall -Wextra -Werror)
"${CC[@]}" -Isrc -dynamiclib -o libzbspawn.dylib src/agent_spawn_posix.c -install_name @rpath/libzbspawn.dylib
"${CC[@]}" -Isrc -dynamiclib -o libzbfake.dylib tests/kill_group/kill_group_fake.c -install_name @rpath/libzbfake.dylib
"${CC[@]}" -Isrc -o kill_group_test tests/kill_group/kill_group_test.c -L. -lzbfake -lzbspawn -Wl,-rpath,@executable_path
./kill_group_test </dev/null
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: kill-group $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms5_kill_group_gate "$host" "$arch" "$out" $'PASS\tkill-group\t8 cases' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-kill-group-gate\tboth-arches\n'
exit "$overall"
