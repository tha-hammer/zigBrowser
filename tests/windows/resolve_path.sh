#!/usr/bin/env bash
# resolve_path.sh — CHECK-TIME remote-path diagnostic for gate.sh --allowed-path (the default resolver).
#
# SCOPE / NOT A SECURITY BOUNDARY: this maps a Windows path to its canonical target AT THE INSTANT OF
# THE CHECK and is a readiness/diagnostic only. It is NOT a time-of-use authorization boundary: the
# caller gets a verdict for a NAME, not a pinned handle, so the answer can be stale by the time any
# later operation reuses the name (a component could be renamed/replaced by a junction in between).
# No consumer may act on an ALLOW to open a path later — see the Windows plan: a future consumer that
# acts on a remote path MUST do a single held-handle check-and-use (Option B) and MUST NOT reuse an
# ALLOW (bead zigBrowser-q92; RoseCat security review of aebb07b/9dbad76).
#
# Given one Windows path, print its canonical target on ONE line, exit 0. It FAILS CLOSED (exit 3 ->
# gate DENY) on ANY reparse point in the path AND on ANY attribute read failure: it walks every
# component (GetFileAttributesW, which does not follow links) and exits 3 if any component is a reparse
# point (directory junction or symlink) OR cannot be read (missing / unreadable / raced away ==
# INVALID_FILE_ATTRIBUTES). In-root junctions are intentionally unsupported. With no reparse point and
# all components readable, CreateFile + GetFinalPathNameByHandle returns the canonical path for the
# lexical check; a path that cannot be opened fails closed via exit 3.
#
# SECURITY (injection): the path is passed to PowerShell as base64 DATA, never spliced into PowerShell
# source, so a quote/backtick/newline in the path cannot inject code on the host. The whole script is
# delivered as -EncodedCommand (no cmd-line quoting). The selftest replaces this via ZB_RESOLVE_CMD.
#
# TEST SEAM (DENY-ONLY, inert unless set): ZB_RESOLVE_SELFTEST_FAULT="reparse:<seg>" or "invalid:<seg>"
# forces the named path component to be seen as a reparse point / unreadable during the walk, so the
# live test can prove the walk's two DENY checks CAUSALLY on an ordinary directory (a real junction
# also trips CreateFile, which would mask whether the walk is what denied). It can ONLY cause a DENY,
# never an ALLOW, so it cannot weaken the check if ever set in production.
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
# DENY-only test seam (empty in production): base64 so it rides into the PS as data, never as source.
fb64=$(printf '%s' "${ZB_RESOLVE_SELFTEST_FAULT:-}" | base64 -w0)

# PowerShell reports the raw result only: line 1 = the GetFinalPathNameByHandle return (the length,
# or 0 on failure, or the required size when the buffer is too small), line 2 = the resolved name.
# The reject/accept DECISIONS live in bash below, so they are exercised by the selftest's fake-SSH
# seam. Quoted heredoc: NOTHING below is processed by bash; the path base64 is substituted into the
# __PB64__ placeholder afterwards — never the raw path.
RESOLVE_CAP=1024
read -r -d '' PS <<'PSEOF' || true
$ErrorActionPreference = 'Stop'
$p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PB64__'))
$flt = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__FLT64__'))
Add-Type -Namespace Zb -Name P -MemberDefinition @'
[DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
public static extern System.IntPtr CreateFile(string n,uint a,uint s,System.IntPtr sa,uint c,uint f,System.IntPtr t);
[DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandle(System.IntPtr h,System.Text.StringBuilder o,uint n,uint fl);
[DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
public static extern uint GetFileAttributesW(string n);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@
$B=0x02000000;$RP=0x400;$INV=[uint32]::MaxValue
$fm=$flt -split ':',2
foreach($seg in ($p -split '\\')){
  if($seg -eq ''){continue}
  if($acc -eq $null -or $acc -eq ''){$acc=$seg}else{$acc=$acc+'\'+$seg}
  $probe=$acc;if($probe -match '^[A-Za-z]:$'){$probe=$probe+'\'}
  $a=[Zb.P]::GetFileAttributesW($probe)
  if($fm.Count -eq 2 -and $seg -eq $fm[1]){if($fm[0] -eq 'reparse'){$a=$RP}elseif($fm[0] -eq 'invalid'){$a=$INV}}
  if($a -eq $INV){exit 3}
  if(($a -band $RP) -ne 0){exit 3}
}
$h=[Zb.P]::CreateFile($p,0,3,[IntPtr]::Zero,3,$B,[IntPtr]::Zero)
if($h -eq [IntPtr](-1)){exit 3}
try{$s=New-Object Text.StringBuilder 1024;$n=[Zb.P]::GetFinalPathNameByHandle($h,$s,1024,0);if($n -eq 0 -or $n -ge 1024){exit 3};[Console]::Out.WriteLine($s.Length);[Console]::Out.WriteLine($s.ToString())}finally{[void][Zb.P]::CloseHandle($h)}
PSEOF
PS="${PS//__PB64__/$pb64}"
PS="${PS//__FLT64__/$fb64}"

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
