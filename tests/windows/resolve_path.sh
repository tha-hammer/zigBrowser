#!/usr/bin/env bash
# resolve_path.sh — production reparse/junction resolver for the WS0.5 fence (gate.sh default).
#
# Given one Windows path, print its REAL resolved target (reparse points / junctions followed) on
# ONE line, exit 0. gate.sh re-checks that resolved path against the lexical fence, so a junction
# under zb\ that targets outside the root is denied. Exit nonzero / empty / multiline is treated by
# the gate as fail-closed (DENY).
#
# SECURITY: the path is passed to PowerShell as base64 DATA, never spliced into PowerShell source,
# so a quote/backtick/newline in the path cannot inject code on the host. PowerShell decodes it,
# resolves via GetFinalPathNameByHandle, and rejects a 0 return (failure) or a length >= the buffer
# (truncation). The whole script is itself delivered as -EncodedCommand (no cmd-line quoting).
#
# The selftest replaces this via ZB_RESOLVE_CMD; this real implementation resolves on the Windows
# host over SSH. Its on-host behavior is live-verify pending (needs a junction fixture on the VM).
set -uo pipefail
p="${1:?usage: resolve_path.sh <windows-path>}"

host="${ZB_WIN11_HOST:-${ZB_WIN10_HOST:-}}"
port="${ZB_WIN11_PORT:-22}"
user="${ZB_GUEST_USER:-}"
key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
kh="${ZB_WIN_KNOWN_HOSTS:-tests/windows/known_hosts}"
[ -n "$host" ] && [ -n "$user" ] || { echo "resolve_path: no host/user configured" >&2; exit 1; }

# The path, base64-encoded. base64's alphabet has no quote/backtick/newline, so embedding it as a
# PowerShell single-quoted literal is injection-safe; PowerShell decodes it back to the real path.
pb64=$(printf '%s' "$p" | base64 -w0)

# Quoted heredoc: NOTHING below is processed by bash (so backslashes and $ stay literal). The path
# base64 is substituted into the __PB64__ placeholder afterwards — never the raw path.
read -r -d '' PS <<'PSEOF' || true
$ErrorActionPreference = 'Stop'
$p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PB64__'))
Add-Type -Namespace Zb -Name P -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern System.IntPtr CreateFile(string n, uint a, uint s, System.IntPtr sa, uint c, uint f, System.IntPtr t);
[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandle(System.IntPtr h, System.Text.StringBuilder o, uint n, uint flags);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@
$h = [Zb.P]::CreateFile($p, 0x80000000, 1, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
if ($h -eq [IntPtr](-1)) { exit 3 }
$cap = 1024
$sb = New-Object System.Text.StringBuilder $cap
$n = [Zb.P]::GetFinalPathNameByHandle($h, $sb, $cap, 0)
[void][Zb.P]::CloseHandle($h)
if ($n -eq 0) { exit 4 }
if ($n -ge $cap) { exit 5 }
$r = $sb.ToString()
if ($r.StartsWith('\\?\')) { $r = $r.Substring(4) }
$r
PSEOF
PS="${PS//__PB64__/$pb64}"

b64=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
exec env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh \
  -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 \
  -p "$port" "$user@$host" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $b64"
