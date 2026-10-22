#!/usr/bin/env bash
# MS6.5 (the user's decision 2026-10-21): the run-survivor reaper on BOTH Macs. Compiles src/agent_run_reaper.c
# with tests/mac/ms6_5_reaper_test.c and runs it: a detached escaper (setsid + double-fork) whose cwd is under a
# scratch run dir is found by the census and SIGKILLed by the guarded sweep; a decoy outside the run dir is
# neither found nor killed; a marker-scrubbing escaper (chdir "/") is the accepted residual the census cannot
# see. Public libproc only (no sandbox_check / private SPI). The sweep's guard (pid > 1, not self, same uid,
# marker re-checked immediately before the signal) keeps a wrong pid away from a real signal; the driver cleans
# up every process it starts. Per-run ~/zb-reaper-<nonce>, deleted on exit; nothing installed. BatchMode, strict
# host keys, no askpass; the arm64 host is required (no default).
# DISABLED BY DEFAULT (plan R29-SAFETY, bd zigBrowser-4pa.70): it stages one exact commit and refuses before any
# ssh unless ZB_REAPER_DESTRUCTIVE_APPROVED equals that commit AND the orchestrator's release token
# $HOME/.ntm/zb-release/reaper-gate-<commit> exists and holds it. Hostless selftest:
# tests/mac/ms6_5_reaper_gate_guard_selftest.sh (zig build test-mac-reaper-gate-guard).
# usage: tests/mac/ms6_5_reaper_gate.sh [commit]   (default: HEAD; never the working tree)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
disabled() { echo "DISABLED: destructive reaper gate ($1)" >&2; exit 1; }
commit=$(git rev-parse --verify --quiet "${1:-HEAD}^{commit}") || disabled "no such commit: ${1:-HEAD}"
[ "${ZB_REAPER_DESTRUCTIVE_APPROVED:-}" = "$commit" ] \
  || disabled "ZB_REAPER_DESTRUCTIVE_APPROVED is not the staged commit $commit"
release="$HOME/.ntm/zb-release/reaper-gate-$commit"
{ [ -f "$release" ] && [ "$(head -n 1 "$release")" = "$commit" ]; } \
  || disabled "no orchestrator release token for $commit at $release"
if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  exit 1
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-reaper-XXXXXX")
# Validated cleanup (RoseCat 7186): only our own mktemp dirs, by find -delete, never an unguarded rm -rf.
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-reaper-??????) find "${stage:?}" -delete;; esac' EXIT
for f in src/agent_run_reaper.c src/agent_run_reaper.h tests/mac/ms6_5_reaper_test.c; do
  git show "$commit:$f" > "${stage:?}/$(basename "$f")"
done

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-reaper-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - . | "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
         echo "FAIL: staging on $host" >&2; return 1; }
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
case "$ZB_RDIR" in zb-reaper-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d"
xcrun clang -std=gnu11 -Wall -Wextra -Werror -I. agent_run_reaper.c ms6_5_reaper_test.c -o reaper_gate
./reaper_gate </dev/null
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-5-reaper-gate\tboth-arches\n'
exit "$overall"
