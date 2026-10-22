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
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

# The watchdog branch waits for the navigation timeout (kNavigationTimeoutMs = 15 s); give it headroom.
# $args: <dir> <mode> <e2e>. e2e='1' passes --e2e-protocol (arms the seam); e2e='0' omits it, so the
# env var alone must NOT fire any forced branch — the shipped normal screenshot path stays inert.
_RUNNER = r"""
$ErrorActionPreference='SilentlyContinue'
$dir = $args[0]; $mode = $args[1]; $e2e = $args[2]
$exe = Join-Path $dir 'zigBrowser.exe'
$shot = Join-Path $dir ('shot-' + $mode + '-' + $e2e + '.png')
$err = Join-Path $dir ('err-' + $mode + '-' + $e2e + '.txt')
Remove-Item $shot,$err -ErrorAction SilentlyContinue
$env:ZB_E2E_FORCE_SCREENSHOT_FAIL = $mode
$argList = @('--screenshot',$shot,'https://example.invalid/')
if ($e2e -eq '1') { $argList += '--e2e-protocol' }
$p = Start-Process -FilePath $exe -ArgumentList $argList `
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
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM screenshot-branch test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, "ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
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

    def _run_modes(self, e2e):
        """Stage exe + loader + runner in a fresh VM dir and run every mode with the given e2e flag
        ('1' arms --e2e-protocol, '0' omits it). Returns {mode: result-dict} and cleans up."""
        import json
        rel = f"zb/branches-{os.getpid()}-{secrets.token_hex(4)}-{e2e}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {base_win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        runner = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbbr-{secrets.token_hex(4)}.ps1"
        results = {}
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
            for mode in _EXPECT:
                run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                "-File", f"{base_win}\\run.ps1", base_win, mode, e2e, timeout=120)
                self.assertEqual(run.returncode, 0, f"[{mode}/{e2e}] runner failed: {run.stdout}\n{run.stderr}")
                results[mode] = json.loads(run.stdout.strip().splitlines()[-1])
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
            try:
                runner.unlink()
            except OSError:
                pass
        return results

    def test_each_forced_branch_exits_nonzero_with_its_exact_diagnostic(self):
        results = self._run_modes("1")
        for mode, needle in _EXPECT.items():
            result = results[mode]
            self.assertNotEqual(result["exit"], 0,
                                f"[{mode}] forced failure must exit nonzero: {result!r}")
            self.assertIn(needle, result["stderr"],
                          f"[{mode}] must print the exact branch diagnostic {needle!r}: {result!r}")

    def test_env_without_e2e_flag_keeps_the_seam_inert(self):
        # 52a5aba (RoseCat 6bea364): with ZB_E2E_FORCE_SCREENSHOT_FAIL set but WITHOUT --e2e-protocol,
        # the shipped normal screenshot path must stay inert — NONE of the forced diagnostics may appear
        # (the real navigation to example.invalid fails on its own; that is not the forced branch). If a
        # mutant drops the production e2e_protocol guards, a forced diagnostic leaks here and this reds.
        results = self._run_modes("0")
        for mode, needle in _EXPECT.items():
            result = results[mode]
            self.assertNotIn(needle, result["stderr"],
                             f"[{mode}] the forced diagnostic {needle!r} must NOT appear without "
                             f"--e2e-protocol (seam must stay inert): {result!r}")


if __name__ == "__main__":
    live_gate.main()
