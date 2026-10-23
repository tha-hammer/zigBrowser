#!/usr/bin/env bash
# macOS netd gate (BlueBeaver 6971; JadeBeacon 7004): runs agent/host/zb_agent_host/netd.py natively on BOTH Macs with
# the system python3 (tests/mac/netd_darwin_driver.py): the exact `netd ready 127.0.0.1:<port>` line, one listener on
# 127.0.0.1 (lsof), the CONNECT/SNI allowlist against a private fake on 127.0.0.1, and a clean exit on EOF. No display,
# no browser, no install, no network beyond loopback: each leg copies the two files into a per-run nonce dir under
# $HOME and deletes that exact dir. Every ssh/scp: BatchMode=yes, strict host keys, no askpass.
# usage: tests/mac/ms6_netd_darwin_gate.sh [commit]   (default: HEAD)
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

stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-netdmac-XXXXXX")
trap 'case "$stage" in */zb-netdmac-*) rm -rf -- "${stage:?}";; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
git archive "$SHA" -- tests/mac/netd_darwin_driver.py agent/host/zb_agent_host/netd.py | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-netdmac-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$stage/agent/host/zb_agent_host/netd.py" "$stage/tests/mac/netd_darwin_driver.py" \
    "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
echo "== $(uname -m) macOS $(sw_vers -productVersion) $(/usr/bin/python3 -V 2>&1)"
/usr/bin/python3 -I "$d/netd_darwin_driver.py"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms6-netd-darwin $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms6_netd_darwin_gate "$host" "$arch" "$out" $'PASS\tms6-netd-darwin\t7 cases' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-netd-darwin-gate\tboth-arches\n'
exit "$overall"
