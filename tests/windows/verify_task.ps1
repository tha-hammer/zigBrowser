# verify_task.ps1 — pin-verify an externally-provisioned console scheduled task by EXACT fields, zero-write.
# Streamed over ssh (never written to the host). Inputs via env:
#   ZB_TASK_NAME   the task to verify (e.g. zb-session-probe)
#   ZB_STAGED_PATH the script the task's action must run (and whose bytes we hash)
#   ZB_STAGED_SHA  the expected SHA-256 (lowercase hex) of that staged script
# Sets $ZB_VERIFY to 'OK' or a TASK_* reason and prints 'VERIFY=<value>'. gate.sh prepends this to the
# trigger (and only triggers when $ZB_VERIFY -eq 'OK'); host_live_test.py runs it against deliberately-bad
# tasks. It parses the task XML and compares the action command/arguments, the run-as principal, the
# InteractiveToken logon type and the enabled state EXACTLY — never a substring of localized list output.
$ErrorActionPreference = 'Stop'
$ZB_VERIFY = 'OK'
$staged = $env:ZB_STAGED_PATH
if (-not (Test-Path -LiteralPath $staged)) {
  $ZB_VERIFY = 'TASK_SCRIPT_MISSING'
} elseif (((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLower()) -ne $env:ZB_STAGED_SHA) {
  $ZB_VERIFY = 'TASK_SCRIPT_HASH_MISMATCH'
} else {
  $xml = $null; try { $xml = [xml]((schtasks /Query /TN $env:ZB_TASK_NAME /XML 2>$null) -join "`n") } catch {}
  if (-not $xml) {
    $ZB_VERIFY = 'TASK_MISSING'
  } else {
    $task = $xml.Task
    $execs = @($task.Actions.Exec)
    if ($execs.Count -ne 1) {
      $ZB_VERIFY = 'TASK_ACTION_COUNT'                       # exactly one Exec action, nothing else
    } else {
      $cmdLeaf = ((([string]$execs[0].Command).Trim().Trim('"')) -split '[\\/]')[-1].ToLower()
      if ($cmdLeaf -ne 'powershell' -and $cmdLeaf -ne 'powershell.exe') {
        $ZB_VERIFY = 'TASK_ACTION_MISMATCH'                  # action is not powershell
      } elseif (([string]$execs[0].Arguments) -notmatch [regex]::Escape($staged)) {
        $ZB_VERIFY = 'TASK_ACTION_MISMATCH'                  # action does not run the staged script
      } else {
        $prin = $task.Principals.Principal
        $uid = [string]$prin.UserId
        $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $meLeaf = (([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -split '\\')[-1].ToLower()
        if ($uid -ne $mySid -and (($uid -split '\\')[-1].ToLower()) -ne $meLeaf) {
          $ZB_VERIFY = 'TASK_PRINCIPAL_MISMATCH'             # runs as someone other than the test user
        } elseif (([string]$prin.LogonType) -ne 'InteractiveToken') {
          $ZB_VERIFY = 'TASK_NOT_INTERACTIVE'                # must run in the interactive console session
        } elseif (([string]$task.Settings.Enabled).ToLower() -eq 'false') {
          $ZB_VERIFY = 'TASK_DISABLED'
        }
      }
    }
  }
}
Write-Output ('VERIFY=' + $ZB_VERIFY)
