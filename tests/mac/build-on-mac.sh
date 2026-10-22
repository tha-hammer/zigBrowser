#!/usr/bin/env bash
# Build ONE EXACT COMMIT on a macOS build host over Tailscale SSH (key auth). The macOS analog of
# tests/guest/build-in-guest.sh, shared by every Mac gate. Usage:
#   bash tests/mac/build-on-mac.sh                 # native build of HEAD
#   bash tests/mac/build-on-mac.sh test            # run a specific build step
#   ZB_GATE_COMMIT=<sha> bash tests/mac/build-on-mac.sh
#
# Plan R30-MS1 (bd 4pa.59, 4pa.77; owner decision R30.3 #2): the source is `git archive <sha>` (committed bytes only,
# never the working tree), written to a fresh local mktemp tar and extracted into a fresh per-run remote directory
# ~/zb-gate-<sha>-<nonce>. Every ssh pins the build Macs' host keys (tests/mac/known_hosts, StrictHostKeyChecking=yes).
# It prints ZB_REMOTE_DIR<TAB><remote dir> first and PASS<TAB>build-on-mac<TAB><sha><TAB><remote dir> last. Run
# alone, it removes the remote directory at the end; a gate that builds then runs in it sets ZB_KEEP_REMOTE_DIR=1,
# reads the directory from those lines, and removes it itself. On any failure the remote directory is removed.
# Hostless selftest:
# tests/mac/build_on_mac_selftest.sh (zig build test-mac-build-script).
#
# STABLE CHANNEL CONTRACT (see `bd memories macos`):
#   - Remote Login (system sshd) ON, Tailscale SSH OFF — both on cycles port 22.
#   - Laptop must have `caffeinate -dimsu` running or it sleeps off the tailnet.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ZIG='$HOME/.local/bin/zig'
STEP="${1:-}"

cd "$(git rev-parse --show-toplevel)"
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
# BatchMode=yes: agents have no terminal but inherit DISPLAY=:0 with ssh-askpass installed, so a brief key-auth
# refusal would otherwise pop a graphical password window on the user's Linux desktop.
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
export SSH_ASKPASS_REQUIRE=never

COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
RDIR="zb-gate-$COMMIT-$NONCE"
# A caller that keeps the directory reads it from this line, printed before any remote work, so it can remove the
# directory even when this script is killed (a timeout) before its PASS line.
printf 'ZB_REMOTE_DIR\t%s\n' "$RDIR"
TAR=$(mktemp "${TMPDIR:-/tmp}/zb-gate-XXXXXX")
remote_live=0   # 1 while the remote run dir may exist and is still ours to remove
cleanup() {
  rm -f -- "${TAR:?}"
  if [ "$remote_live" -eq 1 ]; then
    "${SSH[@]}" "$HOST" "d=\"\$HOME/${RDIR:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete; true" </dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP   # a killed build still runs cleanup

# Committed bytes only. zigbrowser.json is needed because build.zig reads it (the build-time site config); packaging/
# carries the entitlements and Info.plist the gates use.
git archive --format=tar "$COMMIT" -- src build.zig build.zig.zon zigbrowser.json tests packaging > "$TAR"
remote_live=1
"${SSH[@]}" "$HOST" "mkdir \"\$HOME/${RDIR:?}\" && tar -xf - -C \"\$HOME/${RDIR}\"" < "$TAR"

# Build on the Mac NATIVELY. Do NOT pass -Dtarget: an explicit target flips Zig into cross-compile mode and it stops
# auto-detecting the Xcode SDK framework search paths (WebKit/Cocoa/Foundation -> "searched paths: none").
"${SSH[@]}" "$HOST" "cd \"\$HOME/${RDIR}\" && $ZIG build ${STEP} 2>&1" </dev/null

if [ "${ZB_KEEP_REMOTE_DIR:-}" != 1 ]; then
  "${SSH[@]}" "$HOST" "cd / && find \"\$HOME/${RDIR:?}\" -delete" </dev/null
fi
remote_live=0
printf 'PASS\tbuild-on-mac\t%s\t%s\n' "$COMMIT" "$RDIR"
