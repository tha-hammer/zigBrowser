#!/usr/bin/env bash
# Sync the local WORKING TREE to the Win11 guest and run the windows build over
# Tailscale SSH. Lets an agent iterate the webview2_shim compile autonomously
# (no coordinator round-trip). Usage (all three variables are required; there is no default guest, key or pin):
#   ZB_GUEST_HOST=<user@host> ZB_GUEST_KEY=<key> ZB_GUEST_KNOWN_HOSTS=<pinned known_hosts> \
#     bash tests/guest/build-in-guest.sh [<build step, e.g. ipc-test-win>]
# The archive is staged locally in a fresh private directory under ${TMPDIR:-/tmp}, removed on every exit.
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

# bd zigBrowser-ong.24 (NavyCanyon 82565522): stage the archive in a fresh directory only this run owns, never a
# fixed shared path, and delete exactly that directory on every exit.
stage_root="${TMPDIR:-/tmp}"
[ "$stage_root" = / ] || stage_root="${stage_root%/}"
if ! stage=$(mktemp -d "$stage_root/zb-guest-stage.XXXXXXXXXX"); then
  echo "refused: could not create a private staging directory under $stage_root" >&2
  exit 2
fi
# Only a new, empty, private, non-symlink directory of ours directly under the stage root is used, and only then
# deleted; anything else is left alone.
if [ -L "$stage" ] || [ ! -d "$stage" ] || [ ! -O "$stage" ] || [ "$(stat -c %a -- "$stage")" != 700 ] ||
   [ -n "$(ls -A -- "$stage")" ] || [ "$(dirname -- "$stage")" != "$stage_root" ]; then
  echo "refused: mktemp gave $stage, which is not a new private directory under $stage_root; leaving it alone" >&2
  exit 2
fi

# Runs once, on the EXIT trap: keeps a failing status, and fails an otherwise successful run if the stage survives.
cleanup() {
  local rc=$? left=0
  trap - EXIT INT TERM
  rm -rf -- "${stage:?}" || left=1
  if [ -e "$stage" ] || [ -L "$stage" ]; then left=1; fi
  if [ "$left" -ne 0 ]; then
    echo "build-in-guest: cleanup failed: the staging directory $stage is still there; remove it by hand" >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
archive="$stage/zb_worktree.tar"

# Push the working tree (committed or not) as a tarball, extract in the guest.
tar -cf "$archive" src build.zig build.zig.zon tests
scp "${SSH_OPTS[@]}" "$archive" "$HOST":zb_worktree.tar >/dev/null
ssh "${SSH_OPTS[@]}" "$HOST" 'powershell -NoProfile -Command "$d=$env:USERPROFILE+'"'"'\zigBrowser'"'"'; if(!(Test-Path $d)){New-Item -ItemType Directory $d|Out-Null}; tar -xf $env:USERPROFILE\zb_worktree.tar -C $d"'

# Build in the guest.
ssh "${SSH_OPTS[@]}" "$HOST" "cd zigBrowser && zig build ${STEP} \"-Dtarget=x86_64-windows-msvc\" \"-Dwebview2_include=$INC\" \"-Dwebview2_lib=$LIB\" \"-Dwinrt_include=$WINRT\" 2>&1"
