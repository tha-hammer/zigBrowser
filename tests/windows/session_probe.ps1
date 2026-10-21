# session_probe.ps1 — WS0.1 "is this an ACTIVE, UNLOCKED console session?", for a STANDARD user.
#
# A network (SSH) logon is a different session from the console and cannot read the console's lock
# state (verified on win11-m8: SSH session=0, console=2). So this helper must run IN the console
# session, as a scheduled task that runs as the test user "only when logged on" (interactive). The
# task is provisioned EXTERNALLY on the VM (as the test user, AFTER the shut-off snapshot) — see the
# plan's WS0 session-helper provisioning. The gate does NOT create it; before triggering, the gate
# pin-verifies the task (name `zb-session-probe`, action = this script, principal = the test user, and
# this script's SHA-256) and fails closed on any mismatch, then triggers it over SSH with a per-run
# nonce and reads the session.json it writes (nonce + ts correlated). session.json/nonce.txt are VM
# writes, post-snapshot. Nothing of this runs against the read-only file server.
#
# Lock detection uses the WTS session-lock flag: WTSQuerySessionInformation(WTSSessionInfoEx) returns
# WTSINFOEX_LEVEL1.SessionFlags, where WTS_SESSIONSTATE_LOCK(0)=locked, WTS_SESSIONSTATE_UNLOCK(1)=unlocked;
# with a LogonUI-in-console fallback. This is standard-user-safe (no WMI, no privileged session queries).
# input_desktop (OpenInputDesktop) is kept only as a DIAGNOSTIC — on the win11-m8 LOCKED VM console it
# returned "Default" (observed 2026-10-21), so it is NOT trusted for the lock verdict (the earlier
# OpenInputDesktop-only signal mis-reported a locked console as unlocked).
param([string]$OutDir = "$env:USERPROFILE\zb\runs\session")
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Add-Type -Namespace Zb -Name Sess -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
[DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool ProcessIdToSessionId(uint pid, out uint sid);
[DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool WTSQuerySessionInformationW(IntPtr hServer, uint sessionId, int infoClass, out IntPtr ppBuffer, out uint pBytesReturned);
[DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr pMemory);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetUserObjectInformation(IntPtr h, int index, System.Text.StringBuilder pv, int n, out int len);
[DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
'@

$DESKTOP_READOBJECTS = 0x0001
$UOI_NAME = 2
$WTS_SESSIONINFOEX = 25   # WTSQuerySessionInformation info class returning WTSINFOEX

# >>> ZB_LOCK_FN — the lock VERDICT as a PURE function of the WTS session-lock flag, with a
# LogonUI-in-console fallback. On Win8+/10/11 WTSINFOEX_LEVEL1.SessionFlags is
# WTS_SESSIONSTATE_LOCK(0)=locked, WTS_SESSIONSTATE_UNLOCK(1)=unlocked. OpenInputDesktop is NOT the
# verdict: on the win11-m8 LOCKED VM console it still returned "Default" (observed 2026-10-21), so it is
# kept only as a diagnostic field. host_live_test.py extracts this function VERBATIM between these markers
# and exercises it with locked/unlocked fixtures.
function Get-ZbLockVerdict {
  param([bool]$WtsOk, [int]$SessionFlags, [bool]$LogonUiInConsole)
  # FAIL CLOSED: the ONLY definitely-unlocked verdict is the WTS flag explicitly reporting UNLOCK(1).
  # Anything else — WTS LOCK(0), any other/unknown flag, or no WTS at all — is treated as locked, so an
  # unreadable signal can never be accepted by gate.sh as an active, unlocked console session.
  if ($WtsOk) {
    if ($SessionFlags -eq 1) { return $false }   # WTS_SESSIONSTATE_UNLOCK -> unlocked (the only $false)
    return $true                                 # WTS_SESSIONSTATE_LOCK(0) or any other flag -> locked
  }
  if ($LogonUiInConsole) { return $true }        # WTS unavailable: the secure/lock UI present -> locked
  return $true                                   # UNKNOWN (no WTS flag, no LogonUI) -> fail closed: locked
}
# <<< ZB_LOCK_FN

# >>> ZB_WTS_FN — parse WTSINFOEX_LEVEL1.SessionFlags from the raw WTSQuerySessionInformation(WTSSessionInfoEx)
# buffer. The WTSINFOEXW union is 8-byte aligned (WTSINFOEX_LEVEL1_W begins with LARGE_INTEGER times), so the
# Level-1 data starts at offset 8, NOT 4: SessionId@8, SessionState@12, SessionFlags@16. Reading @12 (the old
# bug) returns SessionState (0 = WTSActive for any live session), so it reported LOCK in both states — a
# live byte dump on win11-m8 showed 232 bytes, Level@0=1, SessionId@8=1, SessionState@12=0, SessionFlags@16=1
# (UNLOCK). Returns the SessionFlags int, or $null (fail closed) when the buffer is short, Level != 1, or the
# SessionId at @8 does not equal the queried console session — an unexpected layout must never read as a flag.
function Get-ZbWtsSessionFlags {
  param([byte[]]$Bytes, [int]$QueriedSession)
  if ($null -eq $Bytes -or $Bytes.Length -lt 20) { return $null }
  if ([System.BitConverter]::ToInt32($Bytes, 0) -ne 1) { return $null }     # Level must be 1
  if ([System.BitConverter]::ToInt32($Bytes, 8) -ne $QueriedSession) { return $null }  # SessionId@8 layout check
  return [System.BitConverter]::ToInt32($Bytes, 16)                         # SessionFlags@16
}
# <<< ZB_WTS_FN

$console = [int][Zb.Sess]::WTSGetActiveConsoleSessionId()
$mine = 0; [void][Zb.Sess]::ProcessIdToSessionId([Zb.Sess]::GetCurrentProcessId(), [ref]$mine)
$inConsole = ($mine -eq $console -and $console -ge 0)

# WS0.1/0.7: who is logged on at the physical console (WTSUserName=5). Empty => nobody at the console,
# so the gate must not run on top of a real operator's session. Read-only, standard-user-safe.
$consoleUser = $null
try {
  $ptr = [IntPtr]::Zero; $nb = 0
  if ([Zb.Sess]::WTSQuerySessionInformationW([IntPtr]::Zero, [uint32]$console, 5, [ref]$ptr, [ref]$nb)) {
    try { $consoleUser = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) } finally { [Zb.Sess]::WTSFreeMemory($ptr) }
  }
} catch {}
if ($consoleUser) { $consoleUser = $consoleUser.Trim() }

# input_desktop stays as a DIAGNOSTIC only — it is unreliable for lock state on a VM console (win11-m8
# returns "Default" even when locked); the authoritative verdict is the WTS session-lock flag below.
$deskName = $null
$h = [Zb.Sess]::OpenInputDesktop($DESKTOP_READOBJECTS, $false, $DESKTOP_READOBJECTS)
if ($h -ne [IntPtr]::Zero) {
  $sb = New-Object System.Text.StringBuilder 256
  $len = 0
  [void][Zb.Sess]::GetUserObjectInformation($h, $UOI_NAME, $sb, $sb.Capacity, [ref]$len)
  $deskName = $sb.ToString()
  [void][Zb.Sess]::CloseDesktop($h)
} else {
  $deskName = '<secure-desktop-or-denied>'
}

# Authoritative lock signal: WTSINFOEX_LEVEL1.SessionFlags for the console session. Copy the native buffer
# to managed bytes and parse it via Get-ZbWtsSessionFlags (8-byte-aligned layout; SessionFlags@16).
$wtsOk = $false
$sessionFlags = -1
$pb = [IntPtr]::Zero; $pbn = 0
if ([Zb.Sess]::WTSQuerySessionInformationW([IntPtr]::Zero, [uint32]$console, $WTS_SESSIONINFOEX, [ref]$pb, [ref]$pbn)) {
  try {
    if ($pb -ne [IntPtr]::Zero -and $pbn -ge 20) {
      $buf = New-Object byte[] ([int]$pbn)
      [System.Runtime.InteropServices.Marshal]::Copy($pb, $buf, 0, [int]$pbn)
      $sf = Get-ZbWtsSessionFlags -Bytes $buf -QueriedSession $console
      if ($null -ne $sf) { $sessionFlags = [int]$sf; $wtsOk = $true }
    }
  } finally { [Zb.Sess]::WTSFreeMemory($pb) }
}

# Fallback signal: does LogonUI (the lock/secure-desktop UI) own the console session?
$logonUiInConsole = $false
try {
  $logonUiInConsole = [bool](Get-Process LogonUI -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $console })
} catch {}

$locked = Get-ZbLockVerdict -WtsOk $wtsOk -SessionFlags $sessionFlags -LogonUiInConsole $logonUiInConsole

# Per-run nonce: the gate writes it to nonce.txt in $OutDir just before triggering this task; we echo it
# back into session.json so the gate's probe trusts this result only when the nonce matches (replay/stale
# protection). Absent nonce => $null (the gate then fails closed — a result with no nonce is not trusted).
$nonce = $null
try { $nonce = (Get-Content -LiteralPath (Join-Path $OutDir 'nonce.txt') -Raw -ErrorAction Stop).Trim() } catch {}

$o = [ordered]@{
  schema              = 1
  console_session_id  = $console
  my_session_id       = $mine
  in_console          = $inConsole
  input_desktop       = $deskName
  session_flags       = $sessionFlags
  wts_lock_ok         = $wtsOk
  logonui_in_console  = $logonUiInConsole
  locked              = $locked
  interactive_session = ($inConsole -and -not $locked)
  console_user        = $consoleUser
  nonce               = $nonce
  ts                  = (Get-Date).ToString('o')
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$json = $o | ConvertTo-Json -Compress
$json | Set-Content -Path (Join-Path $OutDir 'session.json') -Encoding ascii
Write-Output $json
