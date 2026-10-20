#!/usr/bin/env python3
"""WS0 LIVE host tests on the Win11 VM (RoseCat 50a4c5b #3/#4): exercise the REAL probe code.

Unlike the hostless gate_twohost_selftest.py (which feeds canned JSON through fakes), this drives the
actual PowerShell on the VM over SSH:

  * AclLive  — extracts Get-ZbWritable VERBATIM from host_probe.ps1 (between the ZB_ACL_FN markers) and
               runs it against real on-disk DACLs: allow/deny, ACE order (explicit Allow before inherited
               Deny => writable), inherit-only (skipped), owner-implicit WRITE_DAC, a non-dangerous right
               (WriteAttributes), and each individual mutating right. The old aggregate / unsafe mutants
               fail these.
  * NonceLive — plants nonce.txt + session.json and runs the real host_probe.ps1, asserting
               interactive/locked are trusted ONLY on a nonce match with a fresh, non-future ts.

It is SKIPPED (not failed) when the VM env is absent, so it never runs in the hostless Linux gate; run it
with the VM env set (ZB_WIN11_HOST/PORT/USER/KEY/KNOWN_HOSTS) to verify on real Windows. All temp dirs and
planted files are under the VM's %TEMP% / %USERPROFILE%\\zb\\runs\\session and are cleaned up.
"""
import os
import pathlib
import re
import subprocess
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
HOST_PROBE = REPO / "tests" / "windows" / "host_probe.ps1"


def _vm_env():
    if not os.environ.get("ZB_WIN11_HOST"):
        return None
    return {
        "host": os.environ["ZB_WIN11_HOST"],
        "port": os.environ.get("ZB_WIN11_PORT", "2222"),
        "user": os.environ.get("ZB_WIN11_USER", "zbtext"),
        "key": os.environ.get("ZB_WIN11_KEY", os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")),
        "kh": os.environ.get("ZB_WIN11_KNOWN_HOSTS", os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")),
    }


def _ssh_run(env, ps_text, timeout=120):
    cmd = ["ssh", "-i", env["key"], "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", "UserKnownHostsFile=" + env["kh"], "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
           "-p", env["port"], env["user"] + "@" + env["host"],
           'powershell -NoProfile -NonInteractive -Command "$input | Out-String | iex"']
    return subprocess.run(cmd, input=ps_text, capture_output=True, text=True, timeout=timeout)


def _extract_acl_fn():
    m = re.search(r"# >>> ZB_ACL_FN.*?\n(.*?)\n# <<< ZB_ACL_FN", HOST_PROBE.read_text(), re.S)
    if not m:
        raise AssertionError("ZB_ACL_FN markers not found in host_probe.ps1")
    return m.group(1)


VERIFY_TASK_FILE = REPO / "tests" / "windows" / "verify_task.ps1"


def _extract_taskxml_fn():
    m = re.search(r"# >>> ZB_TASKXML_FN.*?\n(.*?)\n# <<< ZB_TASKXML_FN", VERIFY_TASK_FILE.read_text(), re.S)
    if not m:
        raise AssertionError("ZB_TASKXML_FN markers not found in verify_task.ps1")
    return m.group(1)


# In-memory DACLs via SDDL: precise control of owner, inherited (ID) and inherit-only (IO) flags, and null
# DACLs, with NO files and NO ownership privilege needed. Owner is SYSTEM (SY) for the non-owner cases (so
# owner-implicit WRITE_DAC does not fire), and the current user (injected as __MYSID__) for the owner case.
# Rights are hex FileSystemRights: WriteData 0x2, Delete 0x10000, WriteAttributes 0x100 (not dangerous).
_ACL_SCENARIOS = r'''
$S = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ctx = Initialize-ZbAccessCheck
if ($null -eq $ctx) { throw "Initialize-ZbAccessCheck returned null (AccessCheck unavailable)" }
function W([string]$sddl){ $sd = New-Object System.Security.AccessControl.DirectorySecurity; $sd.SetSecurityDescriptorSddlForm($sddl); return (Get-ZbWritable $sd $ctx) }
Write-Output ("R allow "       + (W ("O:SYG:SYD:(A;;0x2;;;"      + $S + ")")))
Write-Output ("R deny "        + (W ("O:SYG:SYD:(D;;0x2;;;"      + $S + ")")))
Write-Output ("R delete "      + (W ("O:SYG:SYD:(A;;0x10000;;;"  + $S + ")")))
Write-Output ("R writeattr "   + (W ("O:SYG:SYD:(A;;0x100;;;"    + $S + ")")))
# explicit Allow WriteData BEFORE an inherit-only (IO) Deny WriteData: the IO deny applies to children only
# and must be skipped => writable True.
Write-Output ("R inheritonly " + (W ("O:SYG:SYD:(A;;0x2;;;"      + $S + ")(D;OICIIO;0x2;;;" + $S + ")")))
# explicit Allow WriteData BEFORE an INHERITED (ID) Deny WriteData: first match in order is the Allow => True
# (the old OR-all-denies returned read-only here — the unsafe direction).
Write-Output ("R order "       + (W ("O:SYG:SYD:(A;;0x2;;;"      + $S + ")(D;ID;0x2;;;"      + $S + ")")))
# Deny WriteData BEFORE Allow WriteData: first match is the Deny => not writable.
Write-Output ("R denyfirst "   + (W ("O:SYG:SYD:(D;;0x2;;;"      + $S + ")(A;;0x2;;;"        + $S + ")")))
# Owner (me) with an empty DACL and no ACE for me: implicit WRITE_DAC => writable True.
Write-Output ("R owner "       + (W ("O:" + $S + "G:SYD:")))
# No DACL present at all (null DACL) => everyone full access => fail closed (writable True).
Write-Output ("R nulldacl "    + (W ("O:SYG:SY")))
# One scenario per remaining dangerous right (deleting any right's AccessCheck call reds exactly one):
Write-Output ("R appenddata "  + (W ("O:SYG:SYD:(A;;0x4;;;"      + $S + ")")))   # AppendData
Write-Output ("R deletechild " + (W ("O:SYG:SYD:(A;;0x40;;;"     + $S + ")")))   # DeleteSubdirectoriesAndFiles
Write-Output ("R writedac "    + (W ("O:SYG:SYD:(A;;0x40000;;;"  + $S + ")")))   # WRITE_DAC (ChangePermissions)
Write-Output ("R writeowner "  + (W ("O:SYG:SYD:(A;;0x80000;;;" + $S + ")")))    # WRITE_OWNER (TakeOwnership)
# Fail-closed: no AccessCheck context => writable True (never a silent read-only on a broken probe).
Write-Output ("R nullctx " + (Get-ZbWritable (New-Object System.Security.AccessControl.DirectorySecurity) $null))
'''


@unittest.skipUnless(_vm_env(), "VM env (ZB_WIN11_HOST...) not set; live host test skipped")
class AclLive(unittest.TestCase):
    def test_effective_rights_scenarios(self):
        env = _vm_env()
        proc = _ssh_run(env, _extract_acl_fn() + "\n" + _ACL_SCENARIOS)
        self.assertEqual(proc.returncode, 0, "ssh/powershell failed:\n" + proc.stderr + "\n" + proc.stdout)
        got = {}
        for line in proc.stdout.splitlines():
            m = re.match(r"R (\S+) (True|False)", line.strip())
            if m:
                got[m.group(1)] = (m.group(2) == "True")
        expect = {"allow": True, "deny": False, "delete": True, "writeattr": False,
                  "inheritonly": True, "order": True, "denyfirst": False, "owner": True,
                  "nulldacl": True, "appenddata": True, "deletechild": True,
                  "writedac": True, "writeowner": True, "nullctx": True}
        for k, v in expect.items():
            self.assertIn(k, got, "scenario %r missing from output:\n%s" % (k, proc.stdout))
            self.assertEqual(got[k], v, "scenario %r: expected %s got %s\n%s" % (k, v, got[k], proc.stdout))


# The ts is computed on the VM (now + ZB_SJ_OFFSET minutes) so the test is immune to host/VM clock skew.
_TASKXML_SCENARIOS = r'''
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ps  = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
$staged = (Join-Path $env:USERPROFILE 'zb\session_probe.ps1')
$argsLine = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $staged)
# A base XML that Test-ZbTaskXml accepts; each case mutates exactly one pinned field.
$base = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings>
  <Actions Context="Author"><Exec><Command>$ps</Command><Arguments>$argsLine</Arguments></Exec></Actions>
</Task>
"@
function Chk($name, $xml) { Write-Output ("R " + $name + " " + (Test-ZbTaskXml $xml $staged $sid)) }
Chk 'ok'            $base
Chk 'extra_action'  ($base -replace '</Exec></Actions>', ('</Exec><Exec><Command>'+$ps+'</Command></Exec></Actions>'))
Chk 'comhandler'    ($base -replace '<Exec>.*?</Exec>', '<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler>')
Chk 'attacker_cmd'  ($base -replace [regex]::Escape('<Command>'+$ps+'</Command>'), '<Command>C:\Temp\powershell.exe</Command>')
Chk 'workingdir'    ($base -replace '<Arguments>', '<WorkingDirectory>C:\Temp</WorkingDirectory><Arguments>')
Chk 'extra_arg'     ($base -replace [regex]::Escape($argsLine), ($argsLine + ' ; calc.exe'))
Chk 'wrong_sid'     ($base -replace [regex]::Escape($sid), 'S-1-5-21-1-2-3-4444')
Chk 'same_leaf'     ($base -replace [regex]::Escape('<UserId>'+$sid+'</UserId>'), '<UserId>NOPEDOMAIN\zbtext</UserId>')
Chk 'two_principal' ($base -replace '</Principals>', ('<Principal id="P2"><UserId>'+$sid+'</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>'))
Chk 'bad_context'   ($base -replace 'Context="Author"', 'Context="Other"')
Chk 'missing_id'    ($base -replace '<Principal id="Author">', '<Principal>')
Chk 'missing_context' ($base -replace '<Actions Context="Author">', '<Actions>')
Chk 'missing_id_and_ctx' (($base -replace '<Principal id="Author">', '<Principal>') -replace '<Actions Context="Author">', '<Actions>')
Chk 'non_interactive' ($base -replace '<LogonType>InteractiveToken</LogonType>', '<LogonType>Password</LogonType>')
Chk 'highestavail'  ($base -replace '</LogonType>', '</LogonType><RunLevel>HighestAvailable</RunLevel>')
Chk 'empty_runlevel' ($base -replace '</LogonType>', '</LogonType><RunLevel></RunLevel>')
Chk 'overquoted_cmd' ($base -replace [regex]::Escape('<Command>'+$ps+'</Command>'), ('<Command>"'+$ps+'"</Command>'))
Chk 'empty_wd'      ($base -replace '<Arguments>', '<WorkingDirectory></WorkingDirectory><Arguments>')
Chk 'missing_action' ($base -replace '<Exec>.*?</Exec>', '')
Chk 'malformed_xml' 'this is <not valid XML'
Chk 'disabled_false' ($base -replace '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>', '<Enabled>false</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>')
Chk 'enabled_garbage' ($base -replace '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>', '<Enabled>garbage</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>')
'''


_ONDISK_SCENARIOS = r'''
$ctx = Initialize-ZbAccessCheck
if ($null -eq $ctx) { throw "Initialize-ZbAccessCheck returned null" }
# Production path: Get-Acl on a REAL filesystem object, then Get-ZbWritable. An owned temp dir is writable
# (owner implicit WRITE_DAC); C:\Windows is NOT (standard user, not owner) — a genuine on-disk deny without
# needing to change ownership. Also prove the unreadable-descriptor direction fails closed.
$base = Join-Path $env:TEMP ("zbod_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $base | Out-Null
try {
  Write-Output ("R ondisk_owned " + (Get-ZbWritable (Get-Acl -LiteralPath $base) $ctx))
  Write-Output ("R ondisk_windows " + (Get-ZbWritable (Get-Acl -LiteralPath $env:SystemRoot) $ctx))
  $unreadable = $false
  try { $null = Get-Acl -LiteralPath (Join-Path $env:SystemDrive 'System Volume Information') -ErrorAction Stop }
  catch { $unreadable = $true }   # a standard user cannot read this ACL => host_probe's loop treats it writable
  Write-Output ("R ondisk_unreadable " + $unreadable)
}
finally { Remove-Item -LiteralPath $base -Recurse -Force -EA SilentlyContinue }
'''


_NONCE_PREP = r'''
$dir = Join-Path $env:USERPROFILE 'zb\runs\session'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'nonce.txt') -Value $env:ZB_EXP_NONCE -NoNewline -Encoding ascii
$ts = (Get-Date).ToUniversalTime().AddMinutes([double]$env:ZB_SJ_OFFSET).ToString('o')
$o = [ordered]@{ interactive_session=($env:ZB_SJ_INTER -eq 'True'); locked=($env:ZB_SJ_LOCK -eq 'True'); nonce=$env:ZB_SJ_NONCE; ts=$ts }
($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir 'session.json') -Encoding ascii
Write-Output 'PREPPED'
'''


@unittest.skipUnless(_vm_env(), "VM env (ZB_WIN11_HOST...) not set; live host test skipped")
class OnDiskAclLive(unittest.TestCase):
    def test_production_get_acl_on_disk(self):
        env = _vm_env()
        proc = _ssh_run(env, _extract_acl_fn() + "\n" + _ONDISK_SCENARIOS)
        self.assertEqual(proc.returncode, 0, "ssh/powershell failed:\n" + proc.stderr + "\n" + proc.stdout)
        got = {}
        for line in proc.stdout.splitlines():
            m = re.match(r"R (\S+) (True|False)", line.strip())
            if m:
                got[m.group(1)] = (m.group(2) == "True")
        self.assertEqual(got.get("ondisk_owned"), True, "an owned on-disk dir must be writable (owner):\n" + proc.stdout)
        self.assertEqual(got.get("ondisk_windows"), False, "C:\\Windows must NOT be writable by a standard user:\n" + proc.stdout)
        self.assertEqual(got.get("ondisk_unreadable"), True, "an unreadable ACL must be detected (host_probe treats it writable):\n" + proc.stdout)


@unittest.skipUnless(_vm_env(), "VM env (ZB_WIN11_HOST...) not set; live host test skipped")
class NonceLive(unittest.TestCase):
    @classmethod
    def tearDownClass(cls):
        # Remove the planted nonce.txt/session.json so a later real gate run starts clean.
        env = _vm_env()
        if env:
            _ssh_run(env, r"$d=Join-Path $env:USERPROFILE 'zb\runs\session'; "
                          r"Remove-Item -LiteralPath (Join-Path $d 'session.json') -EA SilentlyContinue; "
                          r"Remove-Item -LiteralPath (Join-Path $d 'nonce.txt') -EA SilentlyContinue; "
                          r"Write-Output CLEANED")

    def _prep_and_probe(self, exp_nonce, sj_nonce, offset_min, inter="True", lock="False"):
        import json
        env = _vm_env()
        prep = ("$env:ZB_EXP_NONCE='%s'; $env:ZB_SJ_NONCE='%s'; $env:ZB_SJ_OFFSET='%s'; $env:ZB_SJ_INTER='%s'; $env:ZB_SJ_LOCK='%s'\n"
                % (exp_nonce, sj_nonce, offset_min, inter, lock)) + _NONCE_PREP
        p1 = _ssh_run(env, prep)
        self.assertIn("PREPPED", p1.stdout, "prep failed:\n" + p1.stderr + p1.stdout)
        p2 = _ssh_run(env, HOST_PROBE.read_text())
        self.assertEqual(p2.returncode, 0, "probe failed:\n" + p2.stderr)
        d = json.loads(p2.stdout.strip())
        return d.get("interactive_session"), d.get("locked")

    def test_matching_fresh_nonce_is_trusted(self):
        inter, lock = self._prep_and_probe("N-MATCH-1", "N-MATCH-1", "0", inter="True", lock="False")
        self.assertEqual(inter, True, "matching fresh nonce must be trusted (interactive True)")
        self.assertEqual(lock, False)

    def test_mismatched_nonce_ignored(self):
        inter, _ = self._prep_and_probe("N-EXPECT", "N-OTHER", "0")
        self.assertIsNone(inter, "a session.json with a different nonce must be ignored (null)")

    def test_stale_ts_ignored(self):
        inter, _ = self._prep_and_probe("N-STALE", "N-STALE", "-30")
        self.assertIsNone(inter, "a stale (>15 min) session result must be ignored (null)")

    def test_future_ts_ignored(self):
        inter, _ = self._prep_and_probe("N-FUT", "N-FUT", "30")
        self.assertIsNone(inter, "a future-dated session result must be ignored (null)")


VERIFY_TASK = (REPO / "tests" / "windows" / "verify_task.ps1").read_text()


def _staged_path(env):
    return "C:\\Users\\%s\\zb\\session_probe.ps1" % env["user"]


def _sess_sha():
    import hashlib
    return hashlib.sha256((REPO / "tests" / "windows" / "session_probe.ps1").read_bytes()).hexdigest()


def _run_verify_task(env, task_name, staged, sha):
    hdr = ("$env:ZB_TASK_NAME='%s'; $env:ZB_STAGED_PATH='%s'; $env:ZB_STAGED_SHA='%s'\n"
           % (task_name, staged, sha))
    p = _ssh_run(env, hdr + VERIFY_TASK)
    m = re.search(r"VERIFY=(\S+)", p.stdout)
    return m.group(1) if m else ("NO_VERIFY_LINE rc=%d\n%s\n%s" % (p.returncode, p.stdout, p.stderr))


@unittest.skipUnless(_vm_env(), "VM env (ZB_WIN11_HOST...) not set; live host test skipped")
class TaskPinLive(unittest.TestCase):
    """Exercise the REAL verify_task.ps1 (the exact code gate.sh prepends) against real registered tasks."""
    TASK = "zb-pintest"

    @classmethod
    def tearDownClass(cls):
        env = _vm_env()
        if env:
            _ssh_run(env, "schtasks /Delete /TN %s /F 2>&1 | Out-Null; Write-Output DONE" % cls.TASK)

    def _verify(self, task_name, staged_path, staged_sha):
        return _run_verify_task(_vm_env(), task_name, staged_path, staged_sha)

    def _create_task(self, tr):
        env = _vm_env()
        _ssh_run(env, "schtasks /Delete /TN %s /F 2>&1 | Out-Null" % self.TASK)
        p = _ssh_run(env, "schtasks /Create /TN %s /TR \"%s\" /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-String"
                     % (self.TASK, tr))
        self.assertIn("SUCCESS", p.stdout, "task create failed:\n" + p.stdout + p.stderr)

    def _provision_disposable(self):
        # Exercise the PRODUCTION provisioner (provision_session_task.ps1) under a disposable task name seam,
        # so the test proves the real provisioner produces exactly the shape the verifier accepts.
        env = _vm_env()
        script = (REPO / "tests" / "windows" / "provision_session_task.ps1").read_text()
        p = _ssh_run(env, ("$env:ZB_TASK_NAME='%s'\n" % self.TASK) + script)
        self.assertIn("CREATE_RC=0", p.stdout, "production provisioner failed:\n" + p.stdout + p.stderr)

    def test_real_task_verifies_ok(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-session-probe", _staged_path(env), _sess_sha()), "OK")

    def test_production_provisioner_produces_accepted_task(self):
        # The production provisioner's output must pass the production verifier end-to-end.
        env = _vm_env()
        self._provision_disposable()
        self.assertEqual(self._verify(self.TASK, _staged_path(env), _sess_sha()), "OK")

    def test_production_provisioner_fails_hard_on_schtasks_error(self):
        # An illegal task name makes schtasks /Create fail; the provisioner must exit NONZERO (its
        # `if ($rc -ne 0) { exit 1 }` guard). Mutant: delete that guard -> process exits 0 -> this test reds.
        env = _vm_env()
        script = (REPO / "tests" / "windows" / "provision_session_task.ps1").read_text()
        p = _ssh_run(env, "$env:ZB_TASK_NAME='zb-pintest-bad?name'\n" + script)
        self.assertNotEqual(p.returncode, 0,
                            "provisioner must exit nonzero when schtasks /Create fails:\n" + p.stdout + p.stderr)
        self.assertNotIn("CREATE_RC=0", p.stdout, "schtasks must not have reported success")

    def test_missing_task_rejected(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-does-not-exist", _staged_path(env), _sess_sha()), "TASK_MISSING")

    def test_hash_mismatch_rejected(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-session-probe", _staged_path(env), "deadbeef"), "TASK_SCRIPT_HASH_MISMATCH")

    def test_missing_staged_script_rejected(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-session-probe", "C:\\Users\\zbtext\\zb\\nope-missing.ps1", _sess_sha()),
                         "TASK_SCRIPT_MISSING")

    def test_hostile_action_rejected(self):
        env = _vm_env()
        self._create_task("calc.exe")
        self.assertEqual(self._verify(self.TASK, _staged_path(env), _sess_sha()), "TASK_ACTION_MISMATCH")

    def test_wrong_action_script_rejected(self):
        env = _vm_env()
        self._create_task("powershell -NoProfile -File C:\\Windows\\Temp\\somethingelse.ps1")
        self.assertEqual(self._verify(self.TASK, _staged_path(env), _sess_sha()), "TASK_ACTION_MISMATCH")

    def test_disabled_task_rejected(self):
        env = _vm_env()
        self._provision_disposable()     # production shape, so only the disabled state should trip the verifier
        _ssh_run(env, "schtasks /Change /TN %s /DISABLE 2>&1 | Out-Null; Write-Output DONE" % self.TASK)
        self.assertEqual(self._verify(self.TASK, _staged_path(env), _sess_sha()), "TASK_DISABLED")


@unittest.skipUnless(_vm_env(), "VM env (ZB_WIN11_HOST...) not set; live host test skipped")
class CraftedTaskXmlLive(unittest.TestCase):
    """Exercise the EXTRACTED Test-ZbTaskXml (the exact verifier gate.sh uses) against crafted task XML for
    every pinned field — including cases a standard user cannot register (wrong principal SID, non-Interactive
    logon, extra principal). Registered-task coverage is in TaskPinLive; this covers the full field matrix."""
    def test_every_pinned_field(self):
        env = _vm_env()
        proc = _ssh_run(env, _extract_taskxml_fn() + "\n" + _TASKXML_SCENARIOS)
        self.assertEqual(proc.returncode, 0, "ssh/powershell failed:\n" + proc.stderr + "\n" + proc.stdout)
        got = {}
        for line in proc.stdout.splitlines():
            m = re.match(r"R (\S+) (\S+)", line.strip())
            if m:
                got[m.group(1)] = m.group(2)
        expect = {
            "ok": "OK",
            "extra_action": "TASK_ACTION_COUNT",
            "comhandler": "TASK_ACTION_COUNT",
            "attacker_cmd": "TASK_ACTION_MISMATCH",
            "workingdir": "TASK_ACTION_MISMATCH",
            "extra_arg": "TASK_ACTION_MISMATCH",
            "wrong_sid": "TASK_PRINCIPAL_MISMATCH",
            "same_leaf": "TASK_PRINCIPAL_MISMATCH",
            "two_principal": "TASK_PRINCIPAL_MISMATCH",
            "bad_context": "TASK_PRINCIPAL_MISMATCH",
            "missing_id": "TASK_PRINCIPAL_MISMATCH",
            "missing_context": "TASK_PRINCIPAL_MISMATCH",
            "missing_id_and_ctx": "TASK_PRINCIPAL_MISMATCH",
            "non_interactive": "TASK_NOT_INTERACTIVE",
            "highestavail": "TASK_RUNLEVEL",
            "empty_runlevel": "TASK_RUNLEVEL",
            "overquoted_cmd": "TASK_ACTION_MISMATCH",
            "empty_wd": "TASK_ACTION_MISMATCH",
            "missing_action": "TASK_ACTION_COUNT",
            "malformed_xml": "TASK_MISSING",
            "disabled_false": "TASK_DISABLED",
            "enabled_garbage": "TASK_DISABLED",
        }
        for k, v in expect.items():
            self.assertIn(k, got, "case %r missing from output:\n%s" % (k, proc.stdout))
            self.assertEqual(got[k], v, "case %r: expected %s got %s\n%s" % (k, v, got[k], proc.stdout))


@unittest.skipUnless(os.environ.get("ZB_EXPECT_LOCKED"), "locked-desktop check needs an owner-locked console (set ZB_EXPECT_LOCKED=1)")
@unittest.skipUnless(_vm_env(), "VM env not set")
class LockedDesktopLive(unittest.TestCase):
    """Owner-gated: lock the VM console, then run with ZB_EXPECT_LOCKED=1. session_probe must report locked=true.
    Cannot be automated over SSH (a network logon cannot lock the console), so it is skipped by default."""
    def test_locked_console_reports_locked(self):
        import json, uuid
        env = _vm_env()
        # 1. Verify the REAL task + staged script hash inside this test (do not depend on unittest order).
        v = _run_verify_task(env, "zb-session-probe", _staged_path(env), _sess_sha())
        self.assertEqual(v, "OK", "the real zb-session-probe task must verify OK first, got: " + v)
        # 2. Fresh unpredictable nonce; remove stale output; trigger once; bounded-poll for THIS nonce AND a
        #    fresh/non-future ts (checked VM-side for robust datetime parsing). Both SSH calls must succeed.
        nonce = "lock-" + uuid.uuid4().hex
        prep = _ssh_run(env, (r"$d=Join-Path $env:USERPROFILE 'zb\runs\session'; New-Item -ItemType Directory -Force -Path $d|Out-Null; "
                              r"Set-Content -LiteralPath (Join-Path $d 'nonce.txt') -Value '%s' -NoNewline -Encoding ascii; "
                              r"Remove-Item -LiteralPath (Join-Path $d 'session.json') -EA SilentlyContinue; Write-Output PREPPED") % nonce)
        self.assertEqual(prep.returncode, 0, "prep ssh failed:\n" + prep.stderr)
        self.assertIn("PREPPED", prep.stdout, "prep failed:\n" + prep.stdout + prep.stderr)
        try:
            poll = _ssh_run(env, (r"$d=Join-Path $env:USERPROFILE 'zb\runs\session'; schtasks /Run /TN 'zb-session-probe' | Out-Null; "
                                  r"$deadline=(Get-Date).AddSeconds(30); $sj=Join-Path $d 'session.json'; "
                                  r"while((Get-Date) -lt $deadline){ Start-Sleep -Milliseconds 1000; "
                                  r"  if(Test-Path -LiteralPath $sj){ try{ $s=Get-Content -LiteralPath $sj -Raw|ConvertFrom-Json; "
                                  r"    $now=(Get-Date).ToUniversalTime(); $tsu=[datetime]::Parse($s.ts).ToUniversalTime(); "
                                  r"    if(\"$($s.nonce)\" -eq '%s' -and $tsu -gt $now.AddMinutes(-15) -and $tsu -le $now.AddMinutes(2)){ "
                                  r"      Write-Output ($s|ConvertTo-Json -Compress); break } }catch{} } } ") % nonce)
            self.assertEqual(poll.returncode, 0, "poll ssh failed:\n" + poll.stderr)
            out = poll.stdout.strip()
            self.assertTrue(out, "no fresh nonce-matching session.json appeared within the timeout")
            d = json.loads(out.splitlines()[-1])
            self.assertEqual(d.get("nonce"), nonce, "session.json must carry this run's fresh nonce")
            self.assertTrue(str(d.get("console_user") or "").strip(), "console_user must be present")
            self.assertEqual(d.get("console_session_id"), d.get("my_session_id"),
                             "the helper must run IN the console session (console_session_id == my_session_id)")
            self.assertEqual(d.get("in_console"), True, "in_console must be true")
            self.assertEqual(d.get("interactive_session"), False, "a locked console is not an active interactive session")
            self.assertEqual(d.get("locked"), True, "a locked console must report locked=true")
            idesk = d.get("input_desktop")
            self.assertTrue(isinstance(idesk, str) and idesk.strip() and idesk != "Default",
                            "input_desktop must be a concrete non-Default desktop or the denied sentinel, got: %r" % idesk)
        finally:
            _ssh_run(env, r"$d=Join-Path $env:USERPROFILE 'zb\runs\session'; "
                          r"Remove-Item -LiteralPath (Join-Path $d 'session.json') -EA SilentlyContinue; "
                          r"Remove-Item -LiteralPath (Join-Path $d 'nonce.txt') -EA SilentlyContinue")


if __name__ == "__main__":
    unittest.main()
