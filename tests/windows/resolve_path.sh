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
# host over SSH. Live-verified on win11-m8: a normal in-root path resolves to itself; C:\Windows
# resolves to itself. CreateFile opens with dwDesiredAccess 0 (GetFinalPathNameByHandle needs only
# the handle) FOLLOWING reparse points — never OPEN_REPARSE_POINT, which would return the junction's
# own in-root path and MASK an escape. A junction that cannot be followed (CreateFile returns
# ERROR_CANT_RESOLVE_FILENAME / gle 448 on this build) fails closed via exit 3 -> gate DENY, which is
# safe; resolving a legitimate in-root junction's target is a tracked refinement (see beads).
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

# PowerShell reports the raw result only: line 1 = the GetFinalPathNameByHandle return (the length,
# or 0 on failure, or the required size when the buffer is too small), line 2 = the resolved name.
# The reject/accept DECISIONS live in bash below, so they are exercised by the selftest's fake-SSH
# seam. Quoted heredoc: NOTHING below is processed by bash; the path base64 is substituted into the
# __PB64__ placeholder afterwards — never the raw path.
RESOLVE_CAP=1024
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
$h = [Zb.P]::CreateFile($p, 0, 3, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
if ($h -eq [IntPtr](-1)) { exit 3 }
$sb = New-Object System.Text.StringBuilder 1024
$n = [Zb.P]::GetFinalPathNameByHandle($h, $sb, 1024, 0)
[void][Zb.P]::CloseHandle($h)
[Console]::Out.WriteLine($n)
[Console]::Out.WriteLine($sb.ToString())
PSEOF
PS="${PS//__PB64__/$pb64}"

b64=$(printf '%s' "$PS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
out=$(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh \
  -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 \
  -p "$port" "$user@$host" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"               # ssh / CreateFile failure (e.g. PS exit 3) — propagate
n=$(printf '%s\n' "$out" | sed -n '1p' | tr -d '\r')
path=$(printf '%s\n' "$out" | sed -n '2p' | tr -d '\r')
case "$n" in ''|*[!0-9]*) echo "resolve_path: non-numeric length '$n'" >&2; exit 6 ;; esac
[ "$n" -eq 0 ] && { echo "resolve_path: GetFinalPathNameByHandle returned 0 (failure)" >&2; exit 4; }
[ "$n" -ge "$RESOLVE_CAP" ] && { echo "resolve_path: resolved name truncated (n=$n >= $RESOLVE_CAP)" >&2; exit 5; }
pfx='\\?\'
path="${path#"$pfx"}"                        # strip the \\?\ long-path prefix if present
printf '%s\n' "$path"
