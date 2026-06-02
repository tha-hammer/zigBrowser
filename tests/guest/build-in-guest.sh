#!/usr/bin/env bash
# Sync the local WORKING TREE to the Win11 guest and run the windows build over
# Tailscale SSH. Lets an agent iterate the webview2_shim compile autonomously
# (no coordinator round-trip). Usage:
#   bash tests/guest/build-in-guest.sh                 # full -Dtarget=x86_64-windows-msvc build
#   bash tests/guest/build-in-guest.sh ipc-test-win    # run a specific build step
set -euo pipefail

KEY="${ZB_GUEST_KEY:-/home/maceo/vms/win11-m8/zb_guest_key}"
HOST="${ZB_GUEST_HOST:-maceo@100.103.8.90}"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no)

# Windows-side SDK paths (discovered on the provisioned guest).
INC='C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\include'
LIB='C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\x64'
WINRT='C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\winrt'

STEP="${1:-}"

cd "$(git rev-parse --show-toplevel)"

# Push the working tree (committed or not) as a tarball, extract in the guest.
tar -cf /tmp/zb_worktree.tar src build.zig build.zig.zon tests 2>/dev/null
scp "${SSH[@]:1}" /tmp/zb_worktree.tar "$HOST":zb_worktree.tar >/dev/null
"${SSH[@]}" "$HOST" 'powershell -NoProfile -Command "$d=$env:USERPROFILE+'"'"'\zigBrowser'"'"'; if(!(Test-Path $d)){New-Item -ItemType Directory $d|Out-Null}; tar -xf $env:USERPROFILE\zb_worktree.tar -C $d"'

# Build in the guest.
"${SSH[@]}" "$HOST" "cd zigBrowser && zig build ${STEP} \"-Dtarget=x86_64-windows-msvc\" \"-Dwebview2_include=$INC\" \"-Dwebview2_lib=$LIB\" \"-Dwinrt_include=$WINRT\" 2>&1"
