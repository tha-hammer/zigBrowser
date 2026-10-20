# verify_task.ps1 — pin-verify an externally-provisioned console scheduled task by EXACT fields, zero-write.
# Streamed over ssh (never written to the host). Inputs via env:
#   ZB_TASK_NAME   the task to verify (e.g. zb-session-probe)
#   ZB_STAGED_PATH the script the task's action must run (and whose bytes we hash)
#   ZB_STAGED_SHA  the expected SHA-256 (lowercase hex) of that staged script
# Sets $ZB_VERIFY to 'OK' or a TASK_* reason and prints 'VERIFY=<value>'. gate.sh prepends this to the
# trigger (and only triggers when $ZB_VERIFY -eq 'OK'); host_live_test.py runs it against deliberately-bad
# tasks AND feeds crafted XML directly to the extracted Test-ZbTaskXml (for principals it cannot register).
$ErrorActionPreference = 'Stop'

# >>> ZB_TASKXML_FN : exact task-XML verifier, extracted VERBATIM by tests/windows/host_live_test.py so the
# live negatives exercise this exact code. Self-contained. Returns 'OK' or a TASK_* reason for one task's XML.
function Test-ZbTaskXml {
  param([string]$xmlText, [string]$staged, [string]$mySid)
  $xml = $null
  try { $xml = [xml]$xmlText } catch { return 'TASK_MISSING' }
  if (-not $xml -or -not $xml.Task) { return 'TASK_MISSING' }
  $task = $xml.Task
  # EXACTLY one action node, and it must be Exec (a ComHandler/SendEmail/ShowMessage or a second action fails).
  $actionNodes = @($task.Actions.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
  if ($actionNodes.Count -ne 1 -or $actionNodes[0].LocalName -ne 'Exec') { return 'TASK_ACTION_COUNT' }
  $exec = $actionNodes[0]
  # Executable pinned to the EXACT canonical System32 PowerShell (no bare name, no attacker path/leaf trick).
  $canon = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
  $cmd = ([string]$exec.Command).Trim().Trim('"')
  if ($cmd.ToLower() -ne $canon.ToLower()) { return 'TASK_ACTION_MISMATCH' }
  # No WorkingDirectory may redirect the executable/script search (absent is required; our provisioning omits it).
  $wd = ([string]$exec.WorkingDirectory).Trim()
  if ($wd -ne '') { return 'TASK_ACTION_MISMATCH' }
  # Arguments must be the EXACT expected tuple (whitespace-normalized), not a substring — extra/hostile args fail.
  $argsNorm = (([string]$exec.Arguments) -replace '\s+', ' ').Trim()
  $expected  = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $staged)
  $expectedQ = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $staged + '"')
  if ($argsNorm -ne $expected -and $argsNorm -ne $expectedQ) { return 'TASK_ACTION_MISMATCH' }
  # EXACTLY one Principal, and the Actions run under it (Actions Context == that Principal's id).
  $prins = @($task.Principals.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.LocalName -eq 'Principal' })
  if ($prins.Count -ne 1) { return 'TASK_PRINCIPAL_MISMATCH' }
  $prin = $prins[0]
  $ctx = ([string]$task.Actions.Context).Trim()
  if ($ctx -ne ([string]$prin.id).Trim()) { return 'TASK_PRINCIPAL_MISMATCH' }
  # Principal resolved to an EXACT SID (no leaf/username fallback; an unknown principal fails closed).
  $uid = ([string]$prin.UserId).Trim()
  $uidSid = $null
  if ($uid -match '^S-\d') { $uidSid = $uid }
  else { try { $uidSid = ([System.Security.Principal.NTAccount]$uid).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $uidSid = $null } }
  if ($uidSid -ne $mySid) { return 'TASK_PRINCIPAL_MISMATCH' }
  if (([string]$prin.LogonType) -ne 'InteractiveToken') { return 'TASK_NOT_INTERACTIVE' }
  # Least-privilege: RunLevel absent (Task Scheduler omits the default = LeastPrivilege) or explicitly
  # LeastPrivilege; any other value (e.g. HighestAvailable) fails.
  $rl = ([string]$prin.RunLevel).Trim()
  if ($rl -ne '' -and $rl -ne 'LeastPrivilege') { return 'TASK_RUNLEVEL' }
  # Enabled: Task Scheduler omits the element when the task is enabled (the default), so ABSENT = enabled =
  # OK; if the element is PRESENT it must be exactly 'true' — an explicit 'false' or any malformed value fails.
  $enNode = $task.Settings.SelectSingleNode("*[local-name()='Enabled']")
  if ($null -ne $enNode -and ([string]$enNode.InnerText).Trim().ToLower() -ne 'true') { return 'TASK_DISABLED' }
  return 'OK'
}
# <<< ZB_TASKXML_FN

$ZB_VERIFY = 'OK'
$staged = $env:ZB_STAGED_PATH
if (-not (Test-Path -LiteralPath $staged)) {
  $ZB_VERIFY = 'TASK_SCRIPT_MISSING'
} elseif (((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLower()) -ne $env:ZB_STAGED_SHA) {
  $ZB_VERIFY = 'TASK_SCRIPT_HASH_MISMATCH'
} else {
  $xmlText = $null
  try { $xmlText = ((schtasks /Query /TN $env:ZB_TASK_NAME /XML 2>$null) -join "`n") } catch {}
  if (-not $xmlText -or -not $xmlText.Trim()) { $ZB_VERIFY = 'TASK_MISSING' }
  else { $ZB_VERIFY = Test-ZbTaskXml $xmlText $staged ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
}
Write-Output ('VERIFY=' + $ZB_VERIFY)
