#!/usr/bin/env bash
# R1 environment check gate (BlueBeaver 6977; RoseCat 6958): zb_agent_host.proc_darwin's real libproc + sysctl
# KERN_PROCARGS2 calls on BOTH Macs (tests/mac/r1_env_driver.py). No display, no browser, no install: each leg copies
# proc_darwin.py (when it exists) and the driver into a per-run nonce dir under $HOME, builds a tiny sleeper with
# xcrun clang (ad-hoc signed, plus a hardened-runtime copy), starts one sleeper that is NOT the driver's descendant,
# runs the driver with the system python3 (-I), kills what it started and deletes that exact dir.
# Every ssh/scp: BatchMode=yes, strict host keys, no askpass (no prompt on the user's desktop).
# usage: tests/mac/ms5_r1_env_gate.sh [commit]   (default: the working tree)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-jj@100.119.156.28}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o ConnectTimeout=15)

stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-r1env-XXXXXX")
trap 'case "$stage" in */zb-r1env-*) rm -rf -- "${stage:?}";; esac' EXIT
if [ -n "${1:-}" ]; then
  git show "$1:tests/mac/r1_env_driver.py" > "$stage/r1_env_driver.py"
  git show "$1:agent/host/zb_agent_host/proc_darwin.py" > "$stage/proc_darwin.py" 2>/dev/null || rm -f "$stage/proc_darwin.py"
else
  cp tests/mac/r1_env_driver.py "$stage/"
  [ -f agent/host/zb_agent_host/proc_darwin.py ] && cp agent/host/zb_agent_host/proc_darwin.py "$stage/"
fi
FILES=("$stage"/*.py)

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-r1env-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "${FILES[@]}" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
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
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-r1-env-gate\tboth-arches\n'
exit "$overall"
