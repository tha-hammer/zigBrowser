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
[ -f src/agent_spawn_posix.c ] && FILES+=(src/agent_spawn_posix.c src/agent_spawn_posix.h)

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-spawn-$(date +%s)-$$-$RANDOM"
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
srcs=(spawn_group_test.c)
[ -f agent_spawn_posix.c ] && srcs+=(agent_spawn_posix.c)
xcrun clang -Wall -I "$d" -Wl,-U,_zb_agent_spawn_group "${srcs[@]}" -o spawn_test
./spawn_test "$d/watch_stub.py" /usr/bin/python3
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-spawn-gate\tboth-arches\n'
exit "$overall"
