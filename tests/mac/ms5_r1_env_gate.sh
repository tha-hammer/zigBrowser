#!/usr/bin/env bash
# R1 environment check gate (BlueBeaver 6977; RoseCat 6958): zb_agent_host.proc_darwin's real libproc + sysctl
# KERN_PROCARGS2 calls on BOTH Macs (tests/mac/r1_env_driver.py). No display, no browser, no install: each leg copies
# proc_darwin.py (when it exists) and the driver into a per-run nonce dir under $HOME, builds a tiny sleeper with
# xcrun clang (ad-hoc signed, plus a hardened-runtime copy), starts one sleeper that is NOT the driver's descendant,
# runs the driver with the system python3 (-I), kills what it started and deletes that exact dir.
# Every ssh/scp: BatchMode=yes, strict host keys, no askpass (no prompt on the user's desktop).
# usage: tests/mac/ms5_r1_env_gate.sh [commit]   (default: HEAD)
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

stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-r1env-XXXXXX")
trap 'case "$stage" in */zb-r1env-*) rm -rf -- "${stage:?}";; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(tests/mac/r1_env_driver.py)
git cat-file -e "$SHA:agent/host/zb_agent_host/proc_darwin.py" 2>/dev/null \
  && FILES+=(agent/host/zb_agent_host/proc_darwin.py)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
STAGED_FILES=("$stage/tests/mac/r1_env_driver.py")
[ ! -f "$stage/agent/host/zb_agent_host/proc_darwin.py" ] \
  || STAGED_FILES+=("$stage/agent/host/zb_agent_host/proc_darwin.py")

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-r1env-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "${STAGED_FILES[@]}" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
other=""
cleanup() { [ -n "$other" ] && kill -9 "$other" 2>/dev/null; rm -rf "$HOME/${ZB_RDIR:?}"; }
trap cleanup EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c,char**v){sleep(c>1?atoi(v[1]):30);return 0;}\n' > sleeper.c
xcrun clang -O1 -o sleeper sleeper.c
cp sleeper sleeper-hardened
codesign -s - -f -o runtime sleeper-hardened 2>/dev/null
sig=$(codesign -dv sleeper-hardened 2>&1 || true)  # captured first: grep -q under pipefail would SIGPIPE codesign
case "$sig" in *runtime*) ;; *) echo "FAIL: the hardened copy has no runtime flag: $sig" >&2; exit 1;; esac
"$d/sleeper" 60 & other=$!
echo "== $(uname -m) macOS $(sw_vers -productVersion)"
/usr/bin/python3 -I "$d/r1_env_driver.py" "$d/sleeper" "$d/sleeper-hardened" "$other"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms5-r1-env $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms5_r1_env_gate "$host" "$arch" "$out" $'PASS\tms5-r1-env\t5 cases' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-r1-env-gate\tboth-arches\n'
exit "$overall"
