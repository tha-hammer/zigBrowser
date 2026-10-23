# host_probe.ps1 — WS0.1 read-only host probe. Emits ONE JSON object (schema 2) to stdout.
# Streamed to the host over ssh stdin and run with `$input | Out-String | iex`; never written to disk
# on the host, and never compiled on the host.
#
# ZERO-WRITE by construction (required for the Win10 file server): no WMI/CIM (access-denied 0x80041003
# for a standard user), no `tasklist /v`, no scheduled tasks, NO writes, and critically NO `Add-Type`.
# Add-Type -MemberDefinition compiles C# via CodeDOM (csc.exe) on Windows PowerShell 5.1, which writes
# temporary source/compiler files into %TEMP% — a disk write on the file server (PowerShell #7914). The
# P/Invoke we need (console session id + console user) is instead built with Reflection.Emit in an
# in-memory dynamic assembly (AssemblyBuilderAccess.Run), which emits nothing to disk. native_arch and
# my_session_id come from managed .NET properties with no P/Invoke at all.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # keep stdout pure JSON (no CLIXML progress records over SSH)

# Zero-write P/Invoke: a dynamic in-memory assembly (Run = never saved, no csc, no temp files).
function New-ZbNative {
  $ab = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    (New-Object System.Reflection.AssemblyName('ZbNativeRE')),
    [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
  $tb = $ab.DefineDynamicModule('ZbNativeREMod').DefineType('ZbNativeRE', [System.Reflection.TypeAttributes]::Public)
  $pub = [System.Reflection.MethodAttributes]'Public,Static,PinvokeImpl'
  $std = [System.Reflection.CallingConventions]::Standard
  $winapi = [System.Runtime.InteropServices.CallingConvention]::Winapi
  $uni = [System.Runtime.InteropServices.CharSet]::Unicode
  $ansi = [System.Runtime.InteropServices.CharSet]::Ansi
  $ps = [System.Reflection.MethodImplAttributes]::PreserveSig
  $m1 = $tb.DefinePInvokeMethod('WTSGetActiveConsoleSessionId','kernel32.dll',$pub,$std,[uint32],@(),$winapi,$ansi)
  $m1.SetImplementationFlags($m1.GetMethodImplementationFlags() -bor $ps)
  $m2 = $tb.DefinePInvokeMethod('WTSQuerySessionInformationW','wtsapi32.dll',$pub,$std,[bool],
        @([IntPtr],[uint32],[int],[IntPtr].MakeByRefType(),[uint32].MakeByRefType()),$winapi,$uni)
  $m2.SetImplementationFlags($m2.GetMethodImplementationFlags() -bor $ps)
  $m3 = $tb.DefinePInvokeMethod('WTSFreeMemory','wtsapi32.dll',$pub,$std,[void],@([IntPtr]),$winapi,$ansi)
  $m3.SetImplementationFlags($m3.GetMethodImplementationFlags() -bor $ps)
  return $tb.CreateType()
}
$ZbN = New-ZbNative

# >>> ZB_ACL_FN : effective-writability via the REAL Win32 AccessCheck (zero-disk Reflection.Emit),
# extracted VERBATIM by tests/windows/host_live_test.py so the live DACL test runs this exact code. Keep it
# SELF-CONTAINED between the markers. AccessCheck consumes the caller's impersonation token, so the kernel —
# not our code — honors SID attributes (disabled / deny-only groups), restricted tokens, privileges, the
# object owner's implicit WRITE_DAC, inherit-only skipping and null/unsupported DACLs. We fail CLOSED
# (writable) whenever the token, the descriptor, or AccessCheck itself is unavailable.
function New-ZbAccessCheckType {
  $ab=[System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly((New-Object System.Reflection.AssemblyName('ZbAC')),[System.Reflection.Emit.AssemblyBuilderAccess]::Run)
  $tb=$ab.DefineDynamicModule('ZbACMod').DefineType('ZbAC',[System.Reflection.TypeAttributes]::Public)
  $pub=[System.Reflection.MethodAttributes]'Public,Static,PinvokeImpl'; $std=[System.Reflection.CallingConventions]::Standard
  $wa=[System.Runtime.InteropServices.CallingConvention]::Winapi; $psf=[System.Reflection.MethodImplAttributes]::PreserveSig; $ansi=[System.Runtime.InteropServices.CharSet]::Ansi
  $m=$tb.DefinePInvokeMethod('OpenProcessToken','advapi32.dll',$pub,$std,[bool],@([IntPtr],[uint32],[IntPtr].MakeByRefType()),$wa,$ansi); $m.SetImplementationFlags($m.GetMethodImplementationFlags()-bor$psf)
  $m=$tb.DefinePInvokeMethod('DuplicateToken','advapi32.dll',$pub,$std,[bool],@([IntPtr],[int],[IntPtr].MakeByRefType()),$wa,$ansi); $m.SetImplementationFlags($m.GetMethodImplementationFlags()-bor$psf)
  $m=$tb.DefinePInvokeMethod('AccessCheck','advapi32.dll',$pub,$std,[bool],@([byte[]],[IntPtr],[uint32],[IntPtr],[IntPtr],[IntPtr],[IntPtr],[IntPtr]),$wa,$ansi); $m.SetImplementationFlags($m.GetMethodImplementationFlags()-bor$psf)
  return $tb.CreateType()
}
function Initialize-ZbAccessCheck {
  try {
    $t=New-ZbAccessCheckType
    $primary=[IntPtr]::Zero
    if(-not $t::OpenProcessToken([System.Diagnostics.Process]::GetCurrentProcess().Handle,(0x2-bor0x8),[ref]$primary)){ return $null }
    $imp=[IntPtr]::Zero
    if(-not $t::DuplicateToken($primary,2,[ref]$imp)){ return $null }   # 2 = SecurityImpersonation
    return @{ T=$t; Token=$imp }
  } catch { return $null }
}
function Get-ZbWritable {
  param($acl, $ctx)
  if($null -eq $ctx){ return $true }
  $M=[System.Runtime.InteropServices.Marshal]
  try { $sdb=$acl.GetSecurityDescriptorBinaryForm() } catch { return $true }
  $gm=$M::AllocHGlobal(16); $psb=$M::AllocHGlobal(256); $psl=$M::AllocHGlobal(4); $ga=$M::AllocHGlobal(4); $st=$M::AllocHGlobal(4)
  try {
    # GENERIC_MAPPING for files (FILE_GENERIC_READ/WRITE/EXECUTE/ALL); our desired bits are specific.
    $M::WriteInt32($gm,0,0x120089);$M::WriteInt32($gm,4,0x120116);$M::WriteInt32($gm,8,0x1200A0);$M::WriteInt32($gm,12,0x1F01FF)
    foreach($bit in @(0x2,0x4,0x10000,0x40,0x40000,0x80000)){  # WriteData,AppendData,Delete,DeleteChild,WriteDAC,WriteOwner
      $M::WriteInt32($psl,0,256)
      if(-not $ctx.T::AccessCheck($sdb,$ctx.Token,[uint32]$bit,$gm,$psb,$psl,$ga,$st)){ return $true }  # API error => fail closed
      if($M::ReadInt32($st) -ne 0){ return $true }   # kernel granted this dangerous right => writable
    }
    return $false
  } catch { return $true } finally { $M::FreeHGlobal($gm);$M::FreeHGlobal($psb);$M::FreeHGlobal($psl);$M::FreeHGlobal($ga);$M::FreeHGlobal($st) }
}
# <<< ZB_ACL_FN

# >>> ZB_SHARE_FN — the PURE WS0.7 verdict for ONE served share path, given three booleans the caller
# derives with real IO (owner decision 2026-10-21, RoseCat WS0.7 exception): a path whose volume/root is
# ABSENT (the drive letter does not exist) is 'absent' (reported separately, never silently 'write'); a
# WRITABLE path on the exact-match owner exception list is 'excepted' (printed with its reason); any other
# writable path is 'write' (fails the gate); otherwise 'clean'. Fail-closed writability (unreadable ACL /
# no AccessCheck) is passed in as $Writable=$true by the caller, so it still lands in 'write' unless excepted.
function Get-ZbShareVerdict {
  param([bool]$DriveAbsent, [bool]$Writable, [bool]$Excepted)
  if ($DriveAbsent) { return 'absent' }
  if ($Writable) { if ($Excepted) { return 'excepted' } else { return 'write' } }
  return 'clean'
}
# <<< ZB_SHARE_FN
$ZbAcCtx = Initialize-ZbAccessCheck   # per-run AccessCheck context (impersonation token); $null => fail closed

function Get-NativeArch {
  # Managed, no P/Invoke: OSArchitecture is X64 / Arm64 / X86 (.NET 4.7.1+, present on Win10 22H2 / .NET 4.8).
  try {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()) {
      'x64'   { 'x64' }
      'arm64' { 'arm64' }
      'x86'   { 'x86' }
      default { [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower() }
    }
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

# WS0.7: the listening TCP endpoints as {port, pid}, so the gate can diff pre-run vs post-run by PID
# ownership (a run must not open a new listener; benign ephemeral churn by an existing process is tolerated
# — bead zigBrowser-bdq). Parsed from `netstat -ano` (standard-user-safe; Get-NetTCPConnection is CIM/WMI,
# Access-denied for a standard user). Column 5 of a `netstat -ano -p TCP` LISTENING row is the owning PID.
$listeners = @()
try {
  $listeners = @(& netstat -ano -p TCP 2>$null | ForEach-Object {
      $f = $_ -split '\s+' | Where-Object { $_ -ne '' }
      if ($f.Count -ge 5 -and $f[0] -eq 'TCP' -and $f[3] -eq 'LISTENING') {
        [pscustomobject]@{ port = [int]($f[1].Split(':')[-1]); pid = [int]$f[4] }
      }
    })
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

# my_session_id: managed property, no P/Invoke. console session id: zero-write Reflection.Emit P/Invoke.
$mySess = $null; try { $mySess = [int][System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch {}
$console = $null; try { $console = [int]$ZbN::WTSGetActiveConsoleSessionId() } catch {}

# WS0.6 identity marker (rev 2.2): the provisioning nonce the gate pins as ZB_WIN11_MARKER. Read-only;
# empty/absent when not provisioned (the gate then fails "wrong host"). Replaces the unreadable SMBIOS UUID.
$identityMarker = $null
try { $identityMarker = (Get-Content -LiteralPath (Join-Path $env:USERPROFILE 'zb\.gate-identity') -Raw -ErrorAction Stop).Trim() } catch {}

# WS0.1: console_user (WTSUserName of the console session) is network-safe — a read-only SSH logon can
# read it directly, so the probe gets it with no in-console helper and no write (works on the file server
# under the read-only rule). Empty/absent => $null, and the gate fails closed.
$consoleUser = $null
try {
  $ptr = [IntPtr]::Zero; $nb = [uint32]0
  if ($console -ne $null -and $ZbN::WTSQuerySessionInformationW([IntPtr]::Zero, [uint32]$console, 5, [ref]$ptr, [ref]$nb)) {
    try { $consoleUser = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) } finally { $ZbN::WTSFreeMemory($ptr) }
  }
  if ($consoleUser) { $consoleUser = $consoleUser.Trim() }
} catch {}

# interactive_session / locked need the console's INPUT DESKTOP lock state, which a network logon cannot
# read, so they come from the in-console session helper's session.json. Absent => $null. The VM readiness
# requires them (GUI host, helper registered post-snapshot). On the Win10 box the gate triggers the helper only in a
# product run (bd zigBrowser-ong.8), which then requires them; --probe-only never triggers it there and does not
# judge them. This probe itself stays zero-write on both hosts (WS0.1c).
#
# NONCE CORRELATION: the gate writes a fresh per-run nonce to zb\runs\session\nonce.txt, then triggers the
# in-console task which writes that same nonce into session.json. We trust interactive/locked ONLY when the
# session result carries the EXACT nonce the gate wrote (and is fresh). A stale, replayed, or future
# session.json has a different/absent nonce and is ignored (interactive stays $null => the gate fails
# closed). Without a product run's nonce.txt on the Win10 box these stay $null, which --probe-only does not judge.
$interactive = $null; $locked = $null
$expectedNonce = $null
try { $expectedNonce = (Get-Content -LiteralPath (Join-Path $env:USERPROFILE 'zb\runs\session\nonce.txt') -Raw -ErrorAction Stop).Trim() } catch {}
try {
  $sj = Join-Path $env:USERPROFILE 'zb\runs\session\session.json'
  if ($expectedNonce -and (Test-Path -LiteralPath $sj)) {
    $sess = Get-Content -LiteralPath $sj -Raw -ErrorAction Stop | ConvertFrom-Json
    # Fresh = within the last 15 min AND not in the future (a future ts is a clock lie / replay and is
    # rejected; a small +2 min skew tolerance only). Combined with the nonce match below.
    $fresh = $false
    try {
      $tsu = [datetime]::Parse($sess.ts).ToUniversalTime(); $now = (Get-Date).ToUniversalTime()
      $fresh = (($tsu -gt $now.AddMinutes(-15)) -and ($tsu -le $now.AddMinutes(2)))
    } catch {}
    if ($fresh -and ("$($sess.nonce)" -eq $expectedNonce)) {
      $interactive = $sess.interactive_session
      $locked      = $sess.locked
    }
  }
} catch {}

# WS0.7: the SMB shares this box serves (from the standard-user-readable LanmanServer\Shares registry;
# `net share` / Get-SmbShare need elevation and fail as a standard user), and which of them the test
# user can WRITE (must be []). Owner rule (b): pure read-only as the test user. If the shares cannot be
# enumerated at all (registry unreadable), BOTH stay $null so the gate fails closed — never a silent [].
$shares = $null; $writePaths = $null; $absentPaths = @(); $shareExceptions = @()
try {
  $sp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Shares' -ErrorAction Stop
  # Typed shares: {name, path} so a rename/alias (same path, new share name) is detectable pre/post.
  $shareList = @()
  foreach ($prop in $sp.PSObject.Properties) {
    if ($prop.Name -like 'PS*') { continue }
    $sharePath = $null
    foreach ($elem in @($prop.Value)) { if ($elem -match '^(?i)\s*Path=(.+)$') { $sharePath = $matches[1].Trim() } }
    if ($sharePath) { $shareList += [pscustomobject]@{ name = $prop.Name; path = $sharePath } }
  }
  $shares = @($shareList)
  # Owner exception list (decision 2026-10-21): ZB_WIN10_SHARE_EXCEPTIONS is newline-separated
  # "path=reason" entries, EXACT path match only. A writable path on the list is 'excepted' (logged with
  # its reason); a writable path NOT on the list still fails.
  $except = @{}
  if ($env:ZB_WIN10_SHARE_EXCEPTIONS) {
    foreach ($line in ($env:ZB_WIN10_SHARE_EXCEPTIONS -split "`r?`n")) {
      $line = $line.Trim(); if (-not $line) { continue }
      $eq = $line.IndexOf('='); if ($eq -lt 1) { continue }
      $ep = $line.Substring(0, $eq).Trim(); $er = $line.Substring($eq + 1).Trim()
      if ($ep) { $except[$ep] = $er }
    }
  }
  # RoseCat be655f3 (4): "absent" must be POSITIVELY established from a read-only drive inventory — not a
  # Test-Path that can be false for an access/query failure. Enumerate the existing filesystem drive roots
  # once; absence = the path's root is an EXACT drive-letter root (e.g. "K:\") that is NOT in the inventory.
  # If the inventory cannot be built, or the root is not a drive-letter root, the path is NOT absent (it then
  # goes through Get-Acl and any failure stays fail-closed = writable). A present-but-inaccessible drive is
  # still in the inventory, so it is never mis-read as absent.
  $driveRoots = @{}; $driveInvOk = $false
  try {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) { $driveRoots[$d.Name.ToUpperInvariant()] = $true }
    $driveInvOk = ($driveRoots.Count -gt 0)
  } catch { $driveInvOk = $false }
  # Which served paths the test user can WRITE, via Get-ZbWritable (real Win32 AccessCheck; see above).
  # Unreadable ACL or no AccessCheck context => fail-safe (treated writable, never hidden).
  $w = @(); $absent = @(); $exc = @()
  foreach ($sh in $shareList) {
    $p = $sh.path
    # NOTE: a distinct name ($shRoot) — never reuse the top-level $root (the emitted allowed-remote-root
    # field); PowerShell has no block scope, so reusing $root here would clobber it with the last share's
    # drive root (observed live: root reported F:\ instead of %USERPROFILE%\zb).
    $shRoot = $null; try { $shRoot = [System.IO.Path]::GetPathRoot($p) } catch {}
    $driveAbsent = $false
    if ($driveInvOk -and $shRoot -and ($shRoot -match '^[A-Za-z]:\\$')) {
      if (-not $driveRoots.ContainsKey($shRoot.ToUpperInvariant())) { $driveAbsent = $true }
    }
    $writable = $false
    if (-not $driveAbsent) {
      try {
        $acl = Get-Acl -LiteralPath $p -ErrorAction Stop
        $writable = [bool](Get-ZbWritable $acl $ZbAcCtx)
      } catch { $writable = $true }   # any Get-Acl failure on a present drive => fail closed (writable)
    }
    switch (Get-ZbShareVerdict -DriveAbsent $driveAbsent -Writable $writable -Excepted ($except.ContainsKey($p))) {
      'absent'   { $absent += $p }
      'excepted' { $exc += [pscustomobject]@{ path = $p; reason = $except[$p] } }
      'write'    { $w += $p }
      default    { }
    }
  }
  $writePaths = @($w | Sort-Object -Unique)
  $absentPaths = @($absent | Sort-Object -Unique)
  $shareExceptions = @($exc)
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
  absent_paths        = $absentPaths
  share_exceptions    = $shareExceptions
  listeners           = $listeners
  fw_rules_hash       = $fwHash
  sshd_listen         = $sshdListen
  sshd_allowusers     = $sshdAllowUsers
  console_session_id  = $console
  my_session_id       = $mySess
  console_user        = $consoleUser   # WTSUserName of the console session (direct, network-safe); $null => fail closed
  interactive_session = $interactive   # from the in-console session helper (session.json); $null => fail closed
  locked              = $locked        # from the in-console session helper (session.json); $null => fail closed
}
$o | ConvertTo-Json -Compress -Depth 5
