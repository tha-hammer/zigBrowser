#!/usr/bin/env bash
# R1 under Seatbelt, the KERNEL-PROPERTIES gate (RoseCat 7019 item 2, 7041 #3, 7050; BlueBeaver 7021, 7051): on BOTH
# Macs, the real setup profile (sandbox_macos.setup_sandbox with loopback_port) around an inner probe stand-in, with
# an unsandboxed control and setup's census outside (tests/mac/r1_kernel_driver.py). The production chain is the
# armed MS5 e2e's job, not this gate's. No display, no browser, no install: each leg copies the files into
# a per-run nonce dir under $HOME, builds a tiny sleeper with xcrun clang, and deletes that exact dir.
# Every ssh/scp: BatchMode=yes, strict host keys, no askpass.
# usage: tests/mac/ms6_r1_kernel_gate.sh [commit]   (default: the working tree)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-300}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
# Delete-guard oracle (RoseCat 7055): every rm COMMAND in this script (each one, up to its ; | & or end of line)
# names its target through ${VAR:?}; a guard elsewhere on the same line does not count.
if grep -v 'delete-guard-oracle' "$0" | grep -o 'rm -[a-z-]*[^;|&]*' | grep -v ':?}'; then  # delete-guard-oracle
  echo "FAIL: an unguarded rm in $0 (above)" >&2; exit 1  # delete-guard-oracle
fi  # delete-guard-oracle
ssh_cmd() { # $1=key
  SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes
       -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes
       -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)
}

stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-r1kmac-XXXXXX")
trap 'case "$stage" in */zb-r1kmac-*) rm -rf -- "${stage:?}";; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(tests/mac/r1_kernel_driver.py tests/mac/r1_kernel_inner.py agent/host/zb_agent_host/sandbox_macos.py)
git cat-file -e "$SHA:agent/host/zb_agent_host/proc_darwin.py" 2>/dev/null \
  && FILES+=(agent/host/zb_agent_host/proc_darwin.py)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
STAGED_FILES=("$stage/tests/mac/r1_kernel_driver.py" "$stage/tests/mac/r1_kernel_inner.py"
              "$stage/agent/host/zb_agent_host/sandbox_macos.py")
[ ! -f "$stage/agent/host/zb_agent_host/proc_darwin.py" ] \
  || STAGED_FILES+=("$stage/agent/host/zb_agent_host/proc_darwin.py")

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2"
  ssh_cmd "$3"
  local rdir="zb-r1kmac-$(date +%s)-$$-$RANDOM"
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
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c,char**v){sleep(c>1?atoi(v[1]):30);return 0;}\n' > sleeper.c
xcrun clang -O1 -o sleeper sleeper.c
cp sleeper sibling  # the same code at another path: the census matches the CLI by its exact path only
echo "== $(uname -m) macOS $(sw_vers -productVersion)"
/usr/bin/python3 -I "$d/r1_kernel_driver.py" "$d/sleeper" "$d/sibling"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms6-r1-kernel $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms6_r1_kernel_gate "$host" "$arch" "$out" $'PASS\tms6-r1-kernel\tkernel properties' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-r1-kernel-gate\tboth-arches\n'
exit "$overall"
