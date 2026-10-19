#!/usr/bin/env bash
# Sync the local WORKING TREE to the macOS build host and run the macos build
# over Tailscale SSH (key auth). The macOS analog of tests/guest/build-in-guest.sh.
# Lets an agent iterate the wkwebview_shim compile autonomously (no coordinator
# round-trip). Usage:
#   bash tests/mac/build-on-mac.sh                 # full -Dtarget=x86_64-macos build
#   bash tests/mac/build-on-mac.sh test            # run a specific build step
#
# STABLE CHANNEL CONTRACT (see `bd memories macos`):
#   - Remote Login (system sshd) ON, Tailscale SSH OFF — both on cycles port 22.
#   - Laptop must have `caffeinate -dimsu` running or it sleeps off the tailnet.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ServerAliveInterval=10)
ZIG='$HOME/.local/bin/zig'

STEP="${1:-}"

cd "$(git rev-parse --show-toplevel)"

# Push the working tree (committed or not) as a tarball, extract on the Mac.
# MS1: include packaging/ so the universal gate's entitlements.plist and build-dmg.sh
# (lipo + ad-hoc sign + verify) are present on the Mac, and zigbrowser.json because
# build.zig:136 reads it (the build-time site config, 32362d4) and panics if it is absent.
tar -cf /tmp/zb_worktree_mac.tar src build.zig build.zig.zon zigbrowser.json tests packaging 2>/dev/null
scp "${SSH[@]:1}" /tmp/zb_worktree_mac.tar "$HOST":zb_worktree_mac.tar >/dev/null
"${SSH[@]}" "$HOST" 'd="$HOME/zigBrowser"; mkdir -p "$d"; tar -xf "$HOME/zb_worktree_mac.tar" -C "$d"'

# Build on the Mac NATIVELY (host = x86_64-macos). Do NOT pass -Dtarget: an explicit
# target flips Zig into cross-compile mode and it stops auto-detecting the Xcode SDK
# framework search paths (WebKit/Cocoa/Foundation -> "searched paths: none"). Native
# build resolves the SDK via the detected sysroot. resolveBackend(native macos) still
# selects macos_backend, so the backend wiring is unchanged.
"${SSH[@]}" "$HOST" "cd \"\$HOME/zigBrowser\" && $ZIG build ${STEP} 2>&1"
