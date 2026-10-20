# host_probe.ps1 — WS0.1 read-only host probe. Emits ONE JSON object (schema 1) to stdout.
#
# Standard-user safe by construction: no WMI/CIM (access-denied 0x80041003 for a standard user),
# no `tasklist /v`, no scheduled tasks, no writes to the host. It reports console_session_id and
# my_session_id, and leaves interactive_session/locked null — those come from the in-console
# session helper (a separate, snapshot-gated step), because a network (SSH) logon cannot read the
# console session's lock state on this security boundary.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # keep stdout pure JSON (no CLIXML progress records over SSH)

Add-Type -Namespace Zb -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool IsWow64Process2(IntPtr hProcess, out ushort pProcessMachine, out ushort pNativeMachine);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);
[DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
'@

function Get-NativeArch {
  try {
    $pm = 0; $nm = 0
    [void][Zb.Native]::IsWow64Process2([Zb.Native]::GetCurrentProcess(), [ref]$pm, [ref]$nm)
    switch ($nm) { 0x8664 { 'x64' } 0xAA64 { 'arm64' } 0x14c { 'x86' } default { ('0x{0:x}' -f $nm) } }
  } catch { $null }
}

function Get-Reg($path, $name) {
  try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { $null }
}

$wv2guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$wv2 = $null
foreach ($p in @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$wv2guid",
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$wv2guid",
    "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$wv2guid")) {
  $v = Get-Reg $p 'pv'; if ($v) { $wv2 = $v; break }
}

$cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$pyPath = (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$py = $null; if ($pyPath) { try { $py = (& $pyPath --version 2>&1 | Select-Object -First 1).ToString() } catch {} }
$zigPath = (Get-Command zig.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$zig = $null; if ($zigPath) { try { $zig = (& $zigPath version 2>&1 | Select-Object -First 1).ToString() } catch {} }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$groups = @()
foreach ($g in $id.Groups) {
  $name = $null
  try { $name = $g.Translate([Security.Principal.NTAccount]).Value } catch {}
  $groups += [pscustomobject]@{ sid = $g.Value; name = $name }
}

$freeGb = $null
try { $freeGb = [math]::Round([System.IO.DriveInfo]::new('C').AvailableFreeSpace / 1GB, 1) } catch {}

# WS0.7: the listening TCP ports, so the gate can diff pre-run vs post-run (a run must not open a new
# listener on the file server). Parsed from `netstat` (standard-user-safe; Get-NetTCPConnection goes
# through CIM/WMI, which is Access-denied for a standard user). All ports, sorted + unique; the gate
# ignores the ephemeral range (>=49152, which churns) when comparing.
$listeners = @()
try {
  $listeners = @(& netstat -ano -p TCP 2>$null | ForEach-Object {
      $f = $_ -split '\s+' | Where-Object { $_ -ne '' }
      if ($f.Count -ge 4 -and $f[0] -eq 'TCP' -and $f[3] -eq 'LISTENING') { [int]($f[1].Split(':')[-1]) }
    } | Sort-Object -Unique)
} catch {}

$mySess = 0;  try { [void][Zb.Native]::ProcessIdToSessionId([Zb.Native]::GetCurrentProcessId(), [ref]$mySess) } catch {}
$console = $null; try { $console = [int][Zb.Native]::WTSGetActiveConsoleSessionId() } catch {}

# WS0.6 identity marker (rev 2.2): the provisioning nonce the gate pins as ZB_WIN11_MARKER. Read-only;
# empty/absent when not provisioned (the gate then fails "wrong host"). Replaces the unreadable SMBIOS UUID.
$identityMarker = $null
try { $identityMarker = (Get-Content -LiteralPath (Join-Path $env:USERPROFILE 'zb\.gate-identity') -Raw -ErrorAction Stop).Trim() } catch {}

$o = [ordered]@{
  schema              = 1
  identity_marker     = $identityMarker
  test_user           = $id.Name
  os_build            = (Get-Reg $cv 'CurrentBuildNumber')
  display_version     = (Get-Reg $cv 'DisplayVersion')
  edition             = (Get-Reg $cv 'EditionID')
  native_arch         = (Get-NativeArch)
  webview2_pv         = $wv2
  python              = $py
  python_path         = $pyPath
  zig                 = $zig
  free_gb             = $freeGb
  groups              = $groups
  listeners           = $listeners
  console_session_id  = $console
  my_session_id       = $mySess
  interactive_session = $null   # filled by the in-console session helper (snapshot-gated)
  locked              = $null   # filled by the in-console session helper (snapshot-gated)
}
$o | ConvertTo-Json -Compress -Depth 5
