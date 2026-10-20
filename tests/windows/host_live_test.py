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
        env = _vm_env()
        hdr = ("$env:ZB_TASK_NAME='%s'; $env:ZB_STAGED_PATH='%s'; $env:ZB_STAGED_SHA='%s'\n"
               % (task_name, staged_path, staged_sha))
        p = _ssh_run(env, hdr + VERIFY_TASK)
        self.assertEqual(p.returncode, 0, "verify_task.ps1 ssh failed:\n" + p.stderr)
        m = re.search(r"VERIFY=(\S+)", p.stdout)
        self.assertIsNotNone(m, "no VERIFY= line:\n" + p.stdout)
        return m.group(1)

    def _create_task(self, tr):
        env = _vm_env()
        _ssh_run(env, "schtasks /Delete /TN %s /F 2>&1 | Out-Null" % self.TASK)
        p = _ssh_run(env, "schtasks /Create /TN %s /TR \"%s\" /SC ONCE /ST 23:59 /IT /F 2>&1 | Out-String"
                     % (self.TASK, tr))
        self.assertIn("SUCCESS", p.stdout, "task create failed:\n" + p.stdout + p.stderr)

    def test_real_task_verifies_ok(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-session-probe", _staged_path(env), _sess_sha()), "OK")

    def test_missing_task_rejected(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-does-not-exist", _staged_path(env), _sess_sha()), "TASK_MISSING")

    def test_hash_mismatch_rejected(self):
        env = _vm_env()
        self.assertEqual(self._verify("zb-session-probe", _staged_path(env), "deadbeef"), "TASK_SCRIPT_HASH_MISMATCH")

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
        self._create_task("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + _staged_path(env))
        _ssh_run(env, "schtasks /Change /TN %s /DISABLE 2>&1 | Out-Null; Write-Output DONE" % self.TASK)
        self.assertEqual(self._verify(self.TASK, _staged_path(env), _sess_sha()), "TASK_DISABLED")


@unittest.skipUnless(os.environ.get("ZB_EXPECT_LOCKED"), "locked-desktop check needs an owner-locked console (set ZB_EXPECT_LOCKED=1)")
@unittest.skipUnless(_vm_env(), "VM env not set")
class LockedDesktopLive(unittest.TestCase):
    """Owner-gated: lock the VM console, then run with ZB_EXPECT_LOCKED=1. session_probe must report locked=true.
    Cannot be automated over SSH (a network logon cannot lock the console), so it is skipped by default."""
    def test_locked_console_reports_locked(self):
        env = _vm_env()
        # Trigger the console task (console is locked by the owner) and read what session_probe wrote.
        _ssh_run(env, r"$d=Join-Path $env:USERPROFILE 'zb\runs\session'; New-Item -ItemType Directory -Force -Path $d|Out-Null; "
                      r"Set-Content -LiteralPath (Join-Path $d 'nonce.txt') -Value 'LOCKCHK' -NoNewline -Encoding ascii; "
                      r"Remove-Item -LiteralPath (Join-Path $d 'session.json') -EA SilentlyContinue; "
                      r"schtasks /Run /TN 'zb-session-probe' | Out-Null; Start-Sleep -Seconds 6; "
                      r"Get-Content -LiteralPath (Join-Path $d 'session.json') -Raw")
        p = _ssh_run(env, r"Get-Content -LiteralPath (Join-Path $env:USERPROFILE 'zb\runs\session\session.json') -Raw")
        import json
        d = json.loads(p.stdout.strip())
        self.assertEqual(d.get("locked"), True, "a locked console must report locked=true")


if __name__ == "__main__":
    unittest.main()
