#!/usr/bin/env bash
# MS5 rev 14 item 6, the production path (RoseCat 6834): the real macOS zigBrowser binary, `--agent-setup`, with
# the Seatbelt backend not ready, on BOTH Macs. Each leg builds an exact commit natively (git archive -> a
# per-run ~/zb-setupref-<nonce>, deleted on exit; no -Dtarget, so the Xcode SDK is auto-detected) and runs it
# with an empty temporary HOME (no XDG_DATA_HOME) and ZB_AGENT_HOST_PYTHON pointing at a canary interpreter that
# would leave a marker if anything ever ran it. It must:
#   * exit 1;
#   * print exactly "zigBrowser: agent-setup: the macOS sandbox is not ready; setup will not run unsandboxed\n"
#     on stderr, and nothing on stdout;
#   * create nothing under HOME (no agent home, no lock, no runtime state) and never run the canary.
# No display, no credential, no install. BatchMode, strict host keys, no askpass.
# Usage: bash tests/mac/ms5_setup_refusal_gate.sh [commit]   (default HEAD)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-jj@100.119.156.28}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1500}"
COMMIT="${1:-HEAD}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
SHA=$(git rev-parse --verify "${COMMIT}^{commit}")
# Only the pinned Mac host keys are trusted, with no askpass or display (bd 3ui.5.1; as tests/mac/mac_gate_lib.sh).
# Hostless selftest: tests/mac/ms5_setup_hostkey_selftest.sh.
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$PWD/tests/mac/known_hosts" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$PWD/tests/mac/known_hosts" -o ConnectTimeout=15)
TAR=$(mktemp "${TMPDIR:-/tmp}/zb-setupref-XXXXXX.tar")
trap 'rm -f -- "$TAR"' EXIT
git archive --format=tar -o "$TAR" "$SHA" src build.zig build.zig.zon zigbrowser.json tests packaging agent tools

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2"
  local rdir="zb-setupref-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$TAR" "$host:${rdir}/src.tar" >/dev/null; then
    "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && tar -xf src.tar
# Both zig caches stay inside this run dir, never the owner's ~/.cache/zig (bd 3ui.5).
ZIG_LOCAL_CACHE_DIR="$d/.zig-cache" ZIG_GLOBAL_CACHE_DIR="$d/.zig-global-cache" \
  "$HOME/.local/bin/zig" build install --cache-dir "$d/.zig-cache" --global-cache-dir "$d/.zig-global-cache" > build.log 2>&1 || { tail -20 build.log; echo "FAIL: build" >&2; exit 1; }
home="$d/home"; mkdir "$home"; marker="$d/canary-ran"
printf '#!/bin/sh\ntouch "%s"\nexit 0\n' "$marker" > "$d/canary-python"; chmod 755 "$d/canary-python"
set +e
env -i PATH=/usr/bin:/bin HOME="$home" LANG=C ZB_AGENT_HOST_PYTHON="$d/canary-python" ZB_AGENT_HOST_DIR="$d/agent-host" \
  ./zig-out/bin/zigBrowser --agent-setup > out.txt 2> err.txt
code=$?
set -e
want='zigBrowser: agent-setup: the macOS sandbox is not ready; setup will not run unsandboxed'
fails=0
[ "$code" -eq 1 ] || { echo "  FAIL exit $code, want 1"; fails=$((fails+1)); }
[ "$(cat err.txt)" = "$want" ] && [ "$(wc -l < err.txt | tr -d ' ')" = "1" ] || { echo "  FAIL stderr: $(cat err.txt)"; fails=$((fails+1)); }
[ ! -s out.txt ] || { echo "  FAIL stdout not empty"; fails=$((fails+1)); }
[ -z "$(ls -A "$home")" ] || { echo "  FAIL HOME changed: $(cd "$home" && find . | head)"; fails=$((fails+1)); }
[ ! -e "$marker" ] || { echo "  FAIL the canary interpreter ran"; fails=$((fails+1)); }
if [ "$fails" -eq 0 ]; then printf 'PASS\tms5-setup-refusal\t%s\n' "$ZB_ARCH"; else printf 'FAIL\tms5-setup-refusal\t%s\t%d\n' "$ZB_ARCH" "$fails"; exit 1; fi
REMOTE
}

echo "== commit $SHA" >&2
overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-setup-refusal-gate\tboth-arches\t%s\n' "$SHA"
exit "$overall"
