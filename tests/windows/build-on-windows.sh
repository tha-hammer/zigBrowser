#!/usr/bin/env bash
# WS1 build driver — build the Windows release exe on the Win11 VM over SSH (MSVC target) and fetch it
# to Linux for the WS1.1 PE census. Generalizes tests/guest/build-in-guest.sh:
#   * WS0.8 transport hygiene: pinned host key (StrictHostKeyChecking=yes + UserKnownHostsFile), BatchMode,
#     ConnectTimeout, and every child display-scrubbed (no DISPLAY/WAYLAND/XAUTHORITY reaches the guest).
#   * the test user zbtext (ZB_WIN11_USER), staging under C:\Users\<user>\zb\ only (WS0.5).
#   * zig + the WebView2 SDK + WinRT paths read from the environment (hosts.env), NOT hardcoded to the old
#     maceo profile (which is ACL-denied to zbtext — bead zigBrowser-4dr).
#
# A plain build is not a gate run, so this needs no Linux slot; the build itself runs remotely on the VM.
# LIVE-VERIFY PENDING: zig + the WebView2 SDK must be made readable/executable by zbtext first (bead
# zigBrowser-4dr); MSVC (VS18 BuildTools, VC Tools 14.51) and the Windows SDK are already machine-wide.
#
# Usage:
#   ZB_ZIG=... ZB_WEBVIEW2_INCLUDE=... ZB_WEBVIEW2_LIB=... bash tests/windows/build-on-windows.sh
#   bash tests/windows/build-on-windows.sh ipc-test-win     # a specific build step instead of the exe
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

host="${ZB_WIN11_HOST:?set ZB_WIN11_HOST (see tests/windows/hosts.env)}"
port="${ZB_WIN11_PORT:-2222}"
user="${ZB_WIN11_USER:-zbtext}"
key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
kh="${ZB_WIN_KNOWN_HOSTS:-/home/maceo/vms/win11-m8/known_hosts}"
zig="${ZB_ZIG:-zig}"                               # zig.exe on the host (once zbtext can run it)
inc="${ZB_WEBVIEW2_INCLUDE:?set ZB_WEBVIEW2_INCLUDE (WebView2 SDK include dir on the host)}"
lib="${ZB_WEBVIEW2_LIB:?set ZB_WEBVIEW2_LIB (WebView2 SDK x64 lib dir on the host)}"
winrt="${ZB_WINRT_INCLUDE:-C:\\Program Files (x86)\\Windows Kits\\10\\Include\\10.0.26100.0\\winrt}"
mode="${ZB_BUILD_MODE:-ReleaseSafe}"
step="${1:-}"

SSH=(-i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh"
     -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3)
scrub=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY)

echo "build-on-windows: staging working tree to $user@$host:zb\\build" >&2
"${scrub[@]}" tar -c -f - src build.zig build.zig.zon tests tools agent \
  | "${scrub[@]}" ssh "${SSH[@]}" -p "$port" "$user@$host" \
      "cmd /c \"if not exist %USERPROFILE%\\zb\\build mkdir %USERPROFILE%\\zb\\build\" & cd zb\\build && tar -x -f -"
rc_tar=${PIPESTATUS[0]} rc_ssh=${PIPESTATUS[1]}
[ "$rc_tar" -eq 0 ] || { echo "build-on-windows: tar failed (rc=$rc_tar)" >&2; exit "$rc_tar"; }
[ "$rc_ssh" -eq 0 ] || { echo "build-on-windows: stage ssh failed (rc=$rc_ssh)" >&2; exit "$rc_ssh"; }

echo "build-on-windows: zig build $step -Dtarget=x86_64-windows-msvc -Doptimize=$mode" >&2
"${scrub[@]}" ssh "${SSH[@]}" -p "$port" "$user@$host" \
  "cd zb\\build && \"$zig\" build $step \"-Dtarget=x86_64-windows-msvc\" \"-Doptimize=$mode\" \"-Dwebview2_include=$inc\" \"-Dwebview2_lib=$lib\" \"-Dwinrt_include=$winrt\" 2>&1"
rc=$?
[ "$rc" -eq 0 ] || { echo "build-on-windows: build failed (rc=$rc)" >&2; exit "$rc"; }

# With no explicit step, fetch the built exe to Linux for the WS1.1 census (set ZB_WIN_EXE to it).
if [ -z "$step" ]; then
  out="${ZB_WIN_EXE:-zig-out/win/zigBrowser.exe}"
  mkdir -p "$(dirname "$out")"
  "${scrub[@]}" scp -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh" \
    -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3 -P "$port" \
    "$user@$host:zb/build/zig-out/bin/zigBrowser.exe" "$out"
  rc=$?
  [ "$rc" -eq 0 ] || { echo "build-on-windows: fetch failed (rc=$rc)" >&2; exit "$rc"; }
  echo "build-on-windows: fetched $out"
fi
