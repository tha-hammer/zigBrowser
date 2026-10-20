# provision_session_task.ps1 — (VM provisioning, run by the user/orchestrator post-snapshot, NOT by the gate)
# Registers the console session-helper task that verify_task.ps1 pins EXACTLY. Run as the test user in the
# VM console session, after staging session_probe.ps1 to %USERPROFILE%\zb\. Uses the CLI form, which Task
# Scheduler normalizes to exactly the fields the gate enforces: the canonical System32 PowerShell, the exact
# arguments, a single Exec under a single Principal = this user (InteractiveToken), LeastPrivilege (/RL
# LIMITED; the default, so Enabled/RunLevel are omitted = enabled/least-privilege), Actions Context=Author,
# no WorkingDirectory. (No /RU other-user, no stored password — a self-owned interactive task.)
$ErrorActionPreference = 'Stop'
# Task name seam: defaults to the production name; tests pass ZB_TASK_NAME for a disposable copy.
$taskName = if ($env:ZB_TASK_NAME) { $env:ZB_TASK_NAME } else { 'zb-session-probe' }
$ps     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $env:USERPROFILE 'zb\session_probe.ps1'
if (-not (Test-Path -LiteralPath $script)) { throw "stage session_probe.ps1 to $script first" }
$tr = '"' + $ps + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"'
# Drop to Continue for the native schtasks call so a nonzero exit is handled by the rc guard below rather
# than PowerShell throwing on its stderr (which would bypass the guard). We decide on $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$out = schtasks /Create /TN $taskName /TR $tr /SC ONCE /ST 23:59 /IT /RL LIMITED /F 2>&1
$rc = $LASTEXITCODE
Write-Output ('CREATE_RC=' + $rc + ' ' + (($out | ForEach-Object { "$_" }) -join ' '))
if ($rc -ne 0) { exit 1 }   # provisioning must fail hard when schtasks fails
