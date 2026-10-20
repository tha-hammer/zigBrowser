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
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$mySids = @($me.User.Value) + @($me.Groups | ForEach-Object { $_.Value })
$S = $me.User.Value
function W([string]$sddl){ $sd = New-Object System.Security.AccessControl.DirectorySecurity; $sd.SetSecurityDescriptorSddlForm($sddl); return (Get-ZbWritable $sd $mySids) }
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
                  "nulldacl": True}
        for k, v in expect.items():
            self.assertIn(k, got, "scenario %r missing from output:\n%s" % (k, proc.stdout))
            self.assertEqual(got[k], v, "scenario %r: expected %s got %s\n%s" % (k, v, got[k], proc.stdout))


# The ts is computed on the VM (now + ZB_SJ_OFFSET minutes) so the test is immune to host/VM clock skew.
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


if __name__ == "__main__":
    unittest.main()
