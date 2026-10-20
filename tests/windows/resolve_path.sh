#!/usr/bin/env bash
# resolve_path.sh — production reparse/junction resolver for the WS0.5 fence (gate.sh default).
#
# Given one Windows path, print its REAL resolved target (reparse points / junctions followed) on
# ONE line, and exit 0. gate.sh then re-checks that resolved path against the lexical fence, so a
# junction under zb\ that targets outside the root is denied. Exit nonzero / empty / multiline is
# treated by the gate as fail-closed (DENY).
#
# The selftest replaces this via ZB_RESOLVE_CMD; this real implementation resolves on the Windows
# host over SSH and is LIVE-VERIFY PENDING (needs the VM up + the snapshot taken first):
#   GetFinalPathNameByHandle on an opened handle returns the canonical path with junctions resolved.
set -uo pipefail
p="${1:?usage: resolve_path.sh <windows-path>}"

host="${ZB_WIN11_HOST:-${ZB_WIN10_HOST:-}}"
port="${ZB_WIN11_PORT:-22}"
user="${ZB_GUEST_USER:-}"
key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
kh="${ZB_WIN_KNOWN_HOSTS:-tests/windows/known_hosts}"
[ -n "$host" ] && [ -n "$user" ] || { echo "resolve_path: no host/user configured" >&2; exit 1; }

# PowerShell: open the path and read its final (reparse-resolved) name. Base64 to dodge quoting.
read -r -d '' PS <<PSEOF || true
\$ErrorActionPreference='Stop'
Add-Type -Namespace Zb -Name P -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern System.IntPtr CreateFile(string n, uint a, uint s, System.IntPtr sa, uint c, uint f, System.IntPtr t);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandle(System.IntPtr h, System.Text.StringBuilder o, uint n, uint flags);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@
\$h=[Zb.P]::CreateFile('$p',0x80000000,1,[IntPtr]::Zero,3,0x02000000,[IntPtr]::Zero)
if(\$h -eq [IntPtr](-1)){ exit 3 }
\$sb=New-Object System.Text.StringBuilder 1024
[void][Zb.P]::GetFinalPathNameByHandle(\$h,\$sb,1024,0)
[void][Zb.P]::CloseHandle(\$h)
(\$sb.ToString() -replace '^\\\\\\\\\\?\\\\','')
PSEOF
b64=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
exec env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh \
  -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 \
  -p "$port" "$user@$host" "powershell -NoProfile -NonInteractive -EncodedCommand $b64"
