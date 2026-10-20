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
[DllImport("wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool WTSQuerySessionInformationW(IntPtr hServer, uint sessionId, int infoClass, out IntPtr ppBuffer, out uint pBytesReturned);
[DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr pMemory);
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

# WS0.5/WS0.1: the allowed remote root for this user, and (WS0.7 / file server) the sshd network fence.
$root = Join-Path $env:USERPROFILE 'zb'
$sshdListen = @()
$sshdAllowUsers = @()
try {
  $cfg = Get-Content -LiteralPath 'C:\ProgramData\ssh\sshd_config' -ErrorAction Stop
  $sshdListen = @($cfg | ForEach-Object { if ($_ -match '^\s*ListenAddress\s+(\S+)') { $matches[1] } })
  $sshdAllowUsers = @($cfg | ForEach-Object { if ($_ -match '^\s*AllowUsers\s+(.+?)\s*$') { $matches[1] } })
} catch {}

$mySess = 0;  try { [void][Zb.Native]::ProcessIdToSessionId([Zb.Native]::GetCurrentProcessId(), [ref]$mySess) } catch {}
$console = $null; try { $console = [int][Zb.Native]::WTSGetActiveConsoleSessionId() } catch {}

# WS0.6 identity marker (rev 2.2): the provisioning nonce the gate pins as ZB_WIN11_MARKER. Read-only;
# empty/absent when not provisioned (the gate then fails "wrong host"). Replaces the unreadable SMBIOS UUID.
$identityMarker = $null
try { $identityMarker = (Get-Content -LiteralPath (Join-Path $env:USERPROFILE 'zb\.gate-identity') -Raw -ErrorAction Stop).Trim() } catch {}

# WS0.1: console_user (WTSUserName of the console session) is network-safe — a read-only SSH logon can
# read it directly, so the probe gets it with no in-console helper and no write (works on the file server
# under the read-only rule). Empty/absent => $null, and the gate fails closed.
$consoleUser = $null
try {
  $ptr = [IntPtr]::Zero; $nb = 0
  if ($console -ne $null -and [Zb.Native]::WTSQuerySessionInformationW([IntPtr]::Zero, [uint32]$console, 5, [ref]$ptr, [ref]$nb)) {
    try { $consoleUser = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) } finally { [Zb.Native]::WTSFreeMemory($ptr) }
  }
  if ($consoleUser) { $consoleUser = $consoleUser.Trim() }
} catch {}

# interactive_session / locked need the console's INPUT DESKTOP lock state, which a network logon cannot
# read, so they come from the in-console session helper's session.json. Absent => $null. The VM readiness
# requires them (GUI host, helper registered post-snapshot); the physical file server runs no GUI and no
# helper under the read-only rule, so there they are not_applicable (the FS schema does not require them).
$interactive = $null; $locked = $null
try {
  $sj = Join-Path $env:USERPROFILE 'zb\runs\session\session.json'
  if (Test-Path -LiteralPath $sj) {
    $sess = Get-Content -LiteralPath $sj -Raw -ErrorAction Stop | ConvertFrom-Json
    $interactive = $sess.interactive_session
    $locked      = $sess.locked
  }
} catch {}

# WS0.7: the SMB shares this box serves (from the standard-user-readable LanmanServer\Shares registry;
# `net share` / Get-SmbShare need elevation and fail as a standard user), and which of them the test
# user can WRITE (must be []). Owner rule (b): pure read-only as the test user. If the shares cannot be
# enumerated at all (registry unreadable), BOTH stay $null so the gate fails closed — never a silent [].
$shares = $null; $writePaths = $null
try {
  $sp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares' -ErrorAction Stop
  $paths = @()
  foreach ($prop in $sp.PSObject.Properties) {
    if ($prop.Name -like 'PS*') { continue }
    foreach ($elem in @($prop.Value)) { if ($elem -match '^(?i)\s*Path=(.+)$') { $paths += $matches[1].Trim() } }
  }
  $shares = @($paths | Sort-Object -Unique)
  $me = [Security.Principal.WindowsIdentity]::GetCurrent()
  $mySids = @($me.User.Value) + @($me.Groups | ForEach-Object { $_.Value })
  $w = @()
  foreach ($p in $shares) {
    try {
      $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
      foreach ($ace in $acl.Access) {
        $sid = $null; try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
        if ($sid -and ($mySids -contains $sid) -and $ace.AccessControlType -eq 'Allow' -and
            ($ace.FileSystemRights.ToString() -match 'Write|Modify|FullControl')) { $w += $p; break }
      }
    } catch { $w += $p }   # cannot read the ACL => treat as possibly writable (fail-safe, never hide)
  }
  $writePaths = @($w | Sort-Object -Unique)
} catch {}

# WS0.7: a fingerprint of the firewall rule set so a run that opens a hole is caught (pre vs post).
# netsh is standard-user-safe (Get-NetFirewallRule is CIM/denied). Cannot read => $null (fail closed).
$fwHash = $null
try {
  $fwRaw = & netsh advfirewall firewall show rule name=all 2>$null
  if ($LASTEXITCODE -eq 0 -and $fwRaw) {
    $norm = @($fwRaw | Where-Object { $_ -match '^(Rule Name|Direction|Action|Protocol|LocalPort|Profiles):' } |
             ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
    if ($norm.Count -gt 0) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes(($norm -join "`n"))
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try { $fwHash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower() }
      finally { $sha.Dispose() }
    }
  }
} catch {}

$o = [ordered]@{
  schema              = 2
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
  root                = $root
  groups              = $groups
  shares              = $shares
  zbtest_write_paths  = $writePaths
  listeners           = $listeners
  fw_rules_hash       = $fwHash
  sshd_listen         = $sshdListen
  sshd_allowusers     = $sshdAllowUsers
  console_session_id  = $console
  my_session_id       = $mySess
  console_user        = $consoleUser   # from the in-console session helper (session.json); $null => fail closed
  interactive_session = $interactive   # from the in-console session helper (session.json); $null => fail closed
  locked              = $locked        # from the in-console session helper (session.json); $null => fail closed
}
$o | ConvertTo-Json -Compress -Depth 5
