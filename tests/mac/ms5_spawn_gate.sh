#!/usr/bin/env bash
# MS5 item 5 gate (macOS plan rev 14): setup dies with the browser on BOTH Macs, without the browser itself.
# tests/mac/spawn_group_test.c is the browser stand-in: zb_agent_spawn_group (src/agent_spawn_posix.c, when it
# exists) starts tests/mac/watch_stub.py as a new process-group leader; the stub arms the real
# zb_agent_host.parent_watch (kqueue) and starts a descendant; the stand-in is SIGKILLed (also at the
# check-to-register barrier) and no member of the group may survive 2 s. Per-run ~/zb-spawn-<nonce>, deleted
# on exit; /usr/bin/python3 (stdlib only); nothing installed. BatchMode, strict host keys, no askpass.
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
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)

FILES=(tests/mac/spawn_group_test.c tests/mac/watch_stub.py)
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
git cat-file -e "$SHA:src/agent_spawn_posix.c" 2>/dev/null \
  && FILES+=(src/agent_spawn_posix.c src/agent_spawn_posix.h)
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-spawn-drv-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-spawn-drv-??????) rm -rf -- "${stage:?}";; esac' EXIT
git archive "$SHA" -- "${FILES[@]}" agent/host/zb_agent_host/__init__.py \
  agent/host/zb_agent_host/parent_watch.py | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-spawn-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && mkdir -p \"\$HOME/${rdir:?}/host/zb_agent_host\"" \
    || { echo "FAIL: mkdir on $host" >&2; return 1; }
  local -a staged_files=()
  local f
  for f in "${FILES[@]}"; do staged_files+=("$stage/$f"); done
  if ! "${SCP[@]}" "${staged_files[@]}" "$host:${rdir}/" >/dev/null ||
     ! "${SCP[@]}" "$stage/agent/host/zb_agent_host/__init__.py" \
       "$stage/agent/host/zb_agent_host/parent_watch.py" "$host:${rdir}/host/zb_agent_host/" >/dev/null; then
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
srcs=(spawn_group_test.c)
[ -f agent_spawn_posix.c ] && srcs+=(agent_spawn_posix.c)
xcrun clang -Wall -I "$d" -Wl,-U,_zb_agent_spawn_group "${srcs[@]}" -o spawn_test
./spawn_test "$d/watch_stub.py" /usr/bin/python3
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms5-spawn $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms5_spawn_gate "$host" "$arch" "$out" $'PASS\tms5-spawn-group\t2 cases' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-spawn-gate\tboth-arches\n'
exit "$overall"
