# session_probe.ps1 — WS0.1 "is this an ACTIVE, UNLOCKED console session?", for a STANDARD user.
#
# A network (SSH) logon is a different session from the console and cannot read the console's lock
# state (verified on win11-m8: SSH session=0, console=2). So this helper must run IN the console
# session. The gate installs it as a scheduled task that runs as the test user "only when logged
# on" (interactive), triggers it over SSH, waits, then reads the session.json it writes. Creating
# the task and writing session.json are VM writes — they happen only AFTER the shut-off snapshot.
#
# Lock detection uses the input desktop: in an unlocked interactive session the input desktop is
# "Default"; when locked, the secure desktop is active and OpenInputDesktop is denied (or returns a
# non-Default name). This is a standard-user-safe signal — no WMI, no privileged session queries.
#
# LIVE-VERIFY PENDING: the OpenInputDesktop access flag and the locked/unlocked desktop names must
# be confirmed on the real VM in both states before this is accepted as green.
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

$deskName = $null
$locked = $true
$h = [Zb.Sess]::OpenInputDesktop($DESKTOP_READOBJECTS, $false, $DESKTOP_READOBJECTS)
if ($h -ne [IntPtr]::Zero) {
  $sb = New-Object System.Text.StringBuilder 256
  $len = 0
  [void][Zb.Sess]::GetUserObjectInformation($h, $UOI_NAME, $sb, $sb.Capacity, [ref]$len)
  $deskName = $sb.ToString()
  [void][Zb.Sess]::CloseDesktop($h)
  $locked = ($deskName -ne 'Default')
} else {
  $deskName = '<secure-desktop-or-denied>'
  $locked = $true
}

$o = [ordered]@{
  schema              = 1
  console_session_id  = $console
  my_session_id       = $mine
  in_console          = $inConsole
  input_desktop       = $deskName
  locked              = $locked
  interactive_session = ($inConsole -and -not $locked)
  console_user        = $consoleUser
  ts                  = (Get-Date).ToString('o')
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$json = $o | ConvertTo-Json -Compress
$json | Set-Content -Path (Join-Path $OutDir 'session.json') -Encoding ascii
Write-Output $json
