#!/usr/bin/env bash
# BlackRobin 7108 seam 1 gate (JadeBeacon 7143): zb_agent_spawn_group_io on BOTH Macs (tests/mac/spawn_group_io_test.c):
# the child holds exactly fds 0 1 2 (POSIX_SPAWN_CLOEXEC_DEFAULT drops a planted inheritable fd and every pipe end),
# leads its own group, round-trips a stdin line, exits on stdin EOF within 2 s; stdin -1 inherits; a stream fd in
# 0..2 is EINVAL; one duplex socket may be both streams; the census reaches past fd 300 (RoseCat 7150). Per-run
# ~/zb-spawnio-<nonce>, deleted on exit; nothing installed. BatchMode, strict host keys, no askpass; the arm64 host
# is required (no default).
# usage: tests/mac/ms5_spawn_io_gate.sh [commit]   (default: HEAD)
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
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-spawnio-XXXXXX")
trap 'case "$stage" in */zb-spawnio-*) rm -rf -- "${stage:?}";; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(tests/mac/spawn_group_io_test.c)
git cat-file -e "$SHA:src/agent_spawn_posix.c" 2>/dev/null \
  && FILES+=(src/agent_spawn_posix.c src/agent_spawn_posix.h)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
STAGED_FILES=("$stage/tests/mac/spawn_group_io_test.c")
[ ! -f "$stage/src/agent_spawn_posix.c" ] \
  || STAGED_FILES+=("$stage/src/agent_spawn_posix.c" "$stage/src/agent_spawn_posix.h")

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)
  local rdir="zb-spawnio-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "${STAGED_FILES[@]}" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
srcs=(spawn_group_io_test.c)
[ -f agent_spawn_posix.c ] && srcs+=(agent_spawn_posix.c)
xcrun clang -Wall -Wextra -Werror -I "$d" -Wl,-U,_zb_agent_spawn_group_io "${srcs[@]}" -o spawn_io_test
./spawn_io_test </dev/null
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms5-spawn-io $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms5_spawn_io_gate "$host" "$arch" "$out" $'PASS\tms5-spawn-io\t4 cases' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-spawn-io-gate\tboth-arches\n'
exit "$overall"
