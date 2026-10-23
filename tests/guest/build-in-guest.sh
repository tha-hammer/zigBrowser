#!/usr/bin/env bash
# Sync the local WORKING TREE to the Win11 guest and run the windows build over
# Tailscale SSH. Lets an agent iterate the webview2_shim compile autonomously
# (no coordinator round-trip). Usage (both variables are required; there is no default guest):
#   ZB_GUEST_HOST=<user@host> ZB_GUEST_KEY=<key> bash tests/guest/build-in-guest.sh               # full build
#   ZB_GUEST_HOST=<user@host> ZB_GUEST_KEY=<key> bash tests/guest/build-in-guest.sh ipc-test-win  # one build step
set -euo pipefail

# Never let a refused key open a graphical SSH password prompt on the user's DISPLAY :0.
export SSH_ASKPASS_REQUIRE=never

# bd zigBrowser-ong.22: a run names both the guest and its key; anything less is refused before any git, tar, scp or
# ssh call.
missing=()
[ -n "${ZB_GUEST_HOST:-}" ] || missing+=(ZB_GUEST_HOST)
[ -n "${ZB_GUEST_KEY:-}" ] || missing+=(ZB_GUEST_KEY)
if [ "${#missing[@]}" -gt 0 ]; then
  echo "refused: no Win11 guest named: set ${missing[0]}${missing[1]:+ and ${missing[1]}}; there is no default" >&2
  exit 2
fi
KEY="$ZB_GUEST_KEY"
HOST="$ZB_GUEST_HOST"
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o BatchMode=yes)

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
