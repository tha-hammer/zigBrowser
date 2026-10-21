#!/usr/bin/env bash
# MS6.5 signal-free Mac identity probe on BOTH Macs (RoseCat 175efb8): compiles src/agent_run_reaper.c with
# tests/mac/ms6_5_reaper_census_probe.c and runs it. It is CENSUS ONLY — zero kill, zero signal — so it is safe
# to run while the destructive reaper gate (ms6_5_reaper_gate.sh) stays off. It proves F_GETPATH from the held
# run-dir fd names that dir, and that a decoy (cwd /tmp) and a scrubber (cwd /) do NOT classify once the pinned
# fd is not leaked to them. Per-run ~/zb-reaper-census-<nonce>, deleted on exit; nothing installed. BatchMode,
# strict host keys, no askpass; the arm64 host is required (no default).
# usage: tests/mac/ms6_5_reaper_census_gate.sh [commit]   (default: the working tree)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  exit 1
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-census-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-reaper-census-??????) find "${stage:?}" -delete;; esac' EXIT
for f in src/agent_run_reaper.c src/agent_run_reaper.h tests/mac/ms6_5_reaper_census_probe.c; do
  if [ -n "${1:-}" ]; then git show "$1:$f" > "${stage:?}/$(basename "$f")"; else cp "$f" "${stage:?}/"; fi
done

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-reaper-census-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - . | "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
         echo "FAIL: staging on $host" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-reaper-census-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
xcrun clang -std=gnu11 -Wall -Wextra -Werror -I. agent_run_reaper.c ms6_5_reaper_census_probe.c -o census_probe
./census_probe </dev/null
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-5-reaper-census-gate\tboth-arches\n'
exit "$overall"
