#!/usr/bin/env bash
# Sync the local WORKING TREE to the Win11 guest and run the windows build over
# Tailscale SSH. Lets an agent iterate the webview2_shim compile autonomously
# (no coordinator round-trip). Usage (all three variables are required; there is no default guest, key or pin):
#   ZB_GUEST_HOST=<user@host> ZB_GUEST_KEY=<key> ZB_GUEST_KNOWN_HOSTS=<pinned known_hosts> \
#     bash tests/guest/build-in-guest.sh [<build step, e.g. ipc-test-win>]
set -euo pipefail

# Never let a refused key open a graphical SSH password prompt on the user's DISPLAY :0.
export SSH_ASKPASS_REQUIRE=never

# bd zigBrowser-ong.22 / ong.23: a run names the guest, its key and the guest's pinned host key; anything less is
# refused before any git, tar, scp or ssh call.
missing=()
[ -n "${ZB_GUEST_HOST:-}" ] || missing+=(ZB_GUEST_HOST)
[ -n "${ZB_GUEST_KEY:-}" ] || missing+=(ZB_GUEST_KEY)
[ -n "${ZB_GUEST_KNOWN_HOSTS:-}" ] || missing+=(ZB_GUEST_KNOWN_HOSTS)
if [ "${#missing[@]}" -gt 0 ]; then
  echo "refused: no Win11 guest named: set ${missing[*]}; there is no default" >&2
  exit 2
fi
# bd zigBrowser-ong.23 (NavyCanyon 8ab66913): the pin must be a readable regular file (a symlink to one is fine).
if [ ! -f "$ZB_GUEST_KNOWN_HOSTS" ] || [ ! -r "$ZB_GUEST_KNOWN_HOSTS" ]; then
  echo "refused: ZB_GUEST_KNOWN_HOSTS=$ZB_GUEST_KNOWN_HOSTS is not a readable regular file (the guest's pinned host key)" >&2
  exit 2
fi
KEY="$ZB_GUEST_KEY"
HOST="$ZB_GUEST_HOST"
KNOWN_HOSTS="$ZB_GUEST_KNOWN_HOSTS"
# The ONE option set for every scp and ssh call: the explicit key only, no prompt, and only the pinned known_hosts
# can vouch for the guest (no other policy, no system known_hosts).
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes
          -o "UserKnownHostsFile=$KNOWN_HOSTS" -o GlobalKnownHostsFile=none)

# Windows-side SDK paths (discovered on the provisioned guest).
INC='C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\include'
LIB='C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\x64'
WINRT='C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\winrt'

STEP="${1:-}"

cd "$(git rev-parse --show-toplevel)"

# Push the working tree (committed or not) as a tarball, extract in the guest.
tar -cf /tmp/zb_worktree.tar src build.zig build.zig.zon tests 2>/dev/null
scp "${SSH_OPTS[@]}" /tmp/zb_worktree.tar "$HOST":zb_worktree.tar >/dev/null
ssh "${SSH_OPTS[@]}" "$HOST" 'powershell -NoProfile -Command "$d=$env:USERPROFILE+'"'"'\zigBrowser'"'"'; if(!(Test-Path $d)){New-Item -ItemType Directory $d|Out-Null}; tar -xf $env:USERPROFILE\zb_worktree.tar -C $d"'

# Build in the guest.
ssh "${SSH_OPTS[@]}" "$HOST" "cd zigBrowser && zig build ${STEP} \"-Dtarget=x86_64-windows-msvc\" \"-Dwebview2_include=$INC\" \"-Dwebview2_lib=$LIB\" \"-Dwinrt_include=$WINRT\" 2>&1"
