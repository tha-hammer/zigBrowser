#!/usr/bin/env bash
# MS5.3 seam gate (macOS plan rev 14 item 7): zb_mac_token_to_fd on BOTH Macs, headless, against a disposable
# keychain with a canary (tests/mac/token_fd_test.m). No display, no browser, no install: each leg compiles
# the seam (src/agent_token_fd_mac.c, when it exists), JadeBeacon's Keychain seam (src/agent_secrets_mac.m)
# and the test with xcrun clang in a per-run nonce dir under $HOME, runs it, and deletes that exact dir.
# Every ssh/scp: BatchMode=yes, strict host keys, no askpass (no prompt on the user's desktop).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-jj@100.119.156.28}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)

FILES=(src/agent_secrets_mac.h src/agent_secrets_mac.m tests/mac/token_fd_test.m)
[ -f src/agent_token_fd_mac.c ] && FILES+=(src/agent_token_fd_mac.c src/agent_token_fd_mac.h)

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-tokfd-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "${FILES[@]}" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
srcs=(token_fd_test.m agent_secrets_mac.m)
[ -f agent_token_fd_mac.c ] && srcs+=(agent_token_fd_mac.c)
xcrun clang -fobjc-arc -Wno-deprecated-declarations -I "$d" -framework Security -framework Foundation \
  -Wl,-U,_zb_mac_token_to_fd "${srcs[@]}" -o tokfd_test
./tokfd_test
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-token-fd-gate\tboth-arches\n'
exit "$overall"
