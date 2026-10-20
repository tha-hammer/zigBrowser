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
    # EXACTLY one action, and it must be an Exec (no ComHandler/SendEmail/ShowMessage alongside or instead).
    $actionNodes = @($task.Actions.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
    if ($actionNodes.Count -ne 1 -or $actionNodes[0].LocalName -ne 'Exec') {
      $ZB_VERIFY = 'TASK_ACTION_COUNT'
    } else {
      $exec = $actionNodes[0]
      $cmd = ([string]$exec.Command).Trim().Trim('"')
      # Pin the executable exactly: bare 'powershell'/'powershell.exe' with NO path separator, so a planted
      # C:\attacker\powershell.exe (same leaf) is rejected.
      if ($cmd -match '[\\/]' -or ($cmd.ToLower() -ne 'powershell' -and $cmd.ToLower() -ne 'powershell.exe')) {
        $ZB_VERIFY = 'TASK_ACTION_MISMATCH'
      } else {
        # Arguments must be EXACTLY the expected tuple (whitespace-normalized) — not a substring, so extra
        # or hostile arguments are rejected. $staged is the exact script path we hashed above.
        $argsNorm = (([string]$exec.Arguments) -replace '\s+', ' ').Trim()
        $expected = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $staged)
        $expectedQ = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $staged + '"')
        if ($argsNorm -ne $expected -and $argsNorm -ne $expectedQ) {
          $ZB_VERIFY = 'TASK_ACTION_MISMATCH'
        } else {
          $prin = $task.Principals.Principal
          $uid = ([string]$prin.UserId).Trim()
          $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
          # Resolve the principal to an EXACT SID (no leaf/username fallback — a different domain or machine
          # account with the same leaf must not pass). A name is translated; a bad/unknown principal fails closed.
          $uidSid = $null
          if ($uid -match '^S-\d') { $uidSid = $uid }
          else { try { $uidSid = ([System.Security.Principal.NTAccount]$uid).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $uidSid = $null } }
          if ($uidSid -ne $mySid) {
            $ZB_VERIFY = 'TASK_PRINCIPAL_MISMATCH'
          } elseif (([string]$prin.LogonType) -ne 'InteractiveToken') {
            $ZB_VERIFY = 'TASK_NOT_INTERACTIVE'
          } elseif (([string]$task.Settings.Enabled).ToLower() -eq 'false') {
            $ZB_VERIFY = 'TASK_DISABLED'
          }
        }
      }
    }
  }
}
Write-Output ('VERIFY=' + $ZB_VERIFY)
