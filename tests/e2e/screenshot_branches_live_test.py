r"""WS1 / 6c771ff live screenshot-failure BRANCH selection on the Win11 VM (UNREGISTERED, VM-gated).

The screenshot path has four failure branches, each with an exact `zigBrowser: screenshot: <reason>`
diagnostic (pinned statically by tests/windows/screenshot_diag_selftest.py). NavigationCompleted is
exercised by the real failed navigation in screenshot_live_test.py; this drives the other THREE
deterministically via the shim's inert `--e2e-protocol` seam (ZB_E2E_FORCE_SCREENSHOT_FAIL):

The screenshot CLI takes `--e2e-protocol` as a TRAILING option (after the out path and URL), mirroring
--print-title; the shim forwards it into run_core so the seam (which gates on app->e2e_protocol) fires.

  * watchdog  -> the navigation watchdog fires: 'zigBrowser: screenshot: navigation timed out before the page loaded'
  * navigate  -> a synchronous Navigate failure:  'zigBrowser: screenshot: ICoreWebView2::Navigate failed to start'
  * docscript -> the document-script failure:     'zigBrowser: screenshot: AddScriptToExecuteOnDocumentCreated failed'

Each must exit NONZERO and print its EXACT diagnostic to stderr. The seam is inert in normal runs (only
consulted under --e2e-protocol when the env var is set).

Skips cleanly (exit 0 → the gate treats it as 77/skip) when ZB_WIN11_HOST or ZB_WIN_EXE is unset, so the
hostless Linux gate stays green. Unregistered; registers in the WS1 green. All writes stay under
C:\Users\<user>\zb\.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=zig-out/win/current/zigBrowser.exe \
           python3 -I tests/windows/../e2e/screenshot_branches_live_test.py -v
"""
import os
import pathlib
import secrets
import subprocess
import unittest

# The watchdog branch waits for the navigation timeout (kNavigationTimeoutMs = 15 s); give it headroom.
_RUNNER = r"""
$ErrorActionPreference='SilentlyContinue'
$dir = $args[0]; $mode = $args[1]
$exe = Join-Path $dir 'zigBrowser.exe'
$shot = Join-Path $dir ('shot-' + $mode + '.png')
$err = Join-Path $dir ('err-' + $mode + '.txt')
Remove-Item $shot,$err -ErrorAction SilentlyContinue
$env:ZB_E2E_FORCE_SCREENSHOT_FAIL = $mode
$p = Start-Process -FilePath $exe -ArgumentList '--screenshot',$shot,'https://example.invalid/','--e2e-protocol' `
     -Wait -PassThru -NoNewWindow -RedirectStandardError $err
$e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $e) { $e = '' }
$r = @{ exit = $p.ExitCode; stderr = $e }
[Console]::Out.Write(($r | ConvertTo-Json -Compress))
"""

_EXPECT = {
    "watchdog":  "zigBrowser: screenshot: navigation timed out before the page loaded",
    "navigate":  "zigBrowser: screenshot: ICoreWebView2::Navigate failed to start",
    "docscript": "zigBrowser: screenshot: AddScriptToExecuteOnDocumentCreated failed",
}


class ScreenshotBranchesLive(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM screenshot-branch test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            self.skipTest("ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    def _scrub(self, *cmd):
        return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]

    def _ssh(self, *args, timeout=120):
        base = ["ssh", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-p", self.port, f"{self.user}@{self.host}"]
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=timeout)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120)

    def test_each_forced_branch_exits_nonzero_with_its_exact_diagnostic(self):
        import json
        rel = f"zb/branches-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {base_win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        runner = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbbr-{secrets.token_hex(4)}.ps1"
        try:
            runner.write_text(_RUNNER, encoding="utf-8")
            pairs = [(self.exe, "zigBrowser.exe"), (str(runner), "run.ps1")]
            # A dynamic-loader build imports WebView2Loader.dll at load time; ship it beside the exe.
            loader = pathlib.Path(self.exe).with_name("WebView2Loader.dll")
            if loader.is_file():
                pairs.append((str(loader), "WebView2Loader.dll"))
            for local, name in pairs:
                r = self._scp(local, f"{rel}/{name}")
                self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")
            for mode, needle in _EXPECT.items():
                run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                "-File", f"{base_win}\\run.ps1", base_win, mode, timeout=120)
                self.assertEqual(run.returncode, 0, f"[{mode}] runner failed: {run.stdout}\n{run.stderr}")
                result = json.loads(run.stdout.strip().splitlines()[-1])
                self.assertNotEqual(result["exit"], 0,
                                    f"[{mode}] forced failure must exit nonzero: {result!r}")
                self.assertIn(needle, result["stderr"],
                              f"[{mode}] must print the exact branch diagnostic {needle!r}: {result!r}")
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
            try:
                runner.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
