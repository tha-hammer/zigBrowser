#!/usr/bin/env bash
# MS6.5 signal-free Mac identity probe on BOTH Macs (RoseCat 175efb8): compiles src/agent_run_reaper.c with
# tests/mac/ms6_5_reaper_census_probe.c and runs it. It is CENSUS ONLY — zero kill, zero signal — so it is safe
# to run while the destructive reaper gate (ms6_5_reaper_gate.sh) stays off. It proves F_GETPATH from the held
# run-dir fd names that dir, and that a decoy (cwd /tmp) and a scrubber (cwd /) do NOT classify once the pinned
# fd is not leaked to them. Per-run ~/zb-reaper-census-<nonce>, deleted on exit; nothing installed. BatchMode,
# strict host keys, no askpass; the arm64 host is required (no default).
# usage: tests/mac/ms6_5_reaper_census_gate.sh [commit]   (default: HEAD)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-census-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-reaper-census-??????) find "${stage:?}" -delete;; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
FILES=(src/agent_run_reaper.c src/agent_run_reaper.h tests/mac/ms6_5_reaper_census_probe.c)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
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
xcrun clang -std=gnu11 -Wall -Wextra -Werror -Isrc src/agent_run_reaper.c \
  tests/mac/ms6_5_reaper_census_probe.c -o census_probe
./census_probe </dev/null
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-5-reaper-census-gate\tboth-arches\n'
exit "$overall"
