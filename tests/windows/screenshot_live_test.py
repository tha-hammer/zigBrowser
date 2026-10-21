r"""Live Windows --screenshot capture on the Win11 VM (WS; bead zigBrowser Windows screenshot).

`zigBrowser.exe --screenshot <out.png> <url>` must render the page and write a real, NON-BLANK PNG
through `ICoreWebView2::CapturePreview` (src/webview2_shim.cpp `zb_run_screenshot`). Before the fix that
entry point was an unimplemented stub that returned ZB_EXIT_SNAPSHOT_FAILED (6) with no stderr, so the
smoke produced no image. This test drives the real backend on the VM and asserts:

  * the process exits 0 (ZB_EXIT_SUCCESS);
  * a PNG file is written and is non-empty;
  * the PNG is a valid, NON-UNIFORM image (not a blank/solid capture) per tests/windows/png_census.py.

CapturePreview renders offscreen, so this passes in the VM's session-0 SSH (no interactive desktop).

Skips cleanly (exit 0) when ZB_WIN11_HOST or ZB_WIN_EXE is unset, so the hostless Linux gate stays green.
Needs no Linux slot — the work runs on the VM. All writes stay under C:\Users\<user>\zb\.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=zig-out/win/current/zigBrowser.exe \
           python3 -I tests/windows/screenshot_live_test.py -v
"""
import json
import os
import pathlib
import secrets
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
CENSUS = REPO / "tests" / "windows" / "png_census.py"

# A page that is deliberately non-uniform: a diagonal gradient plus a heading.
_HTML = (
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>ZB shot</title>"
    "<style>html,body{margin:0;height:100%}"
    "body{background:linear-gradient(135deg,#ff0000,#0000ff);"
    "display:flex;align-items:center;justify-content:center}"
    "h1{color:#00ff00;font:bold 64px sans-serif}</style>"
    "</head><body><h1>ZB SHOT OK</h1></body></html>\n"
)

# VM-side runner: run --screenshot, wait (Start-Process waits for the GUI app), and print one JSON line.
_RUNNER = r"""
$ErrorActionPreference='SilentlyContinue'
$dir  = $args[0]
$exe  = Join-Path $dir 'zigBrowser.exe'
$shot = Join-Path $dir 'shot.png'
$err  = Join-Path $dir 'err.txt'
$out  = Join-Path $dir 'out.txt'
Remove-Item $shot,$err,$out -ErrorAction SilentlyContinue
if ($args.Count -ge 2 -and $args[1]) { $url = $args[1] }
else { $url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/') }
$p = Start-Process -FilePath $exe -ArgumentList '--screenshot', $shot, $url `
     -Wait -PassThru -NoNewWindow -RedirectStandardError $err -RedirectStandardOutput $out
$size = (Get-Item $shot -ErrorAction SilentlyContinue).Length
if ($null -eq $size) { $size = 0 }
$e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $e) { $e = '' }
$o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $o) { $o = '' }
$r = @{ exit = $p.ExitCode; shot = (Test-Path $shot); size = $size; stderr = $e; stdout = $o }
[Console]::Out.Write(($r | ConvertTo-Json -Compress))
"""


class ScreenshotLive(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM screenshot test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            self.skipTest("ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")

    def _scrub(self, *cmd):
        return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]

    def _ssh(self, *args):
        base = ["ssh", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-p", self.port, f"{self.user}@{self.host}"]
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=180)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=180)

    def _fetch(self, remote, local):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, f"{self.user}@{self.host}:{remote}", local]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=180)

    def test_screenshot_writes_a_nonblank_png(self):
        rel = f"zb/shot-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {base_win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        local_png = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbshot-{secrets.token_hex(4)}.png"
        try:
            html_path = local_png.with_suffix(".html")
            html_path.write_text(_HTML, encoding="utf-8")
            runner_path = local_png.with_suffix(".ps1")
            runner_path.write_text(_RUNNER, encoding="utf-8")
            for local, name in ((self.exe, "zigBrowser.exe"), (str(html_path), "test.html"),
                                (str(runner_path), "run.ps1")):
                r = self._scp(local, f"{rel}/{name}")
                self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")

            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\run.ps1", base_win)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            result = json.loads(run.stdout.strip().splitlines()[-1])

            self.assertEqual(result["exit"], 0,
                             f"--screenshot exited {result['exit']} (not SUCCESS); stderr={result['stderr']!r}")
            self.assertTrue(result["shot"], f"no PNG written: {result!r}")
            self.assertGreater(result["size"], 0, f"PNG is empty: {result!r}")

            fetched = self._fetch(f"{rel}/shot.png", str(local_png))
            self.assertEqual(fetched.returncode, 0, f"fetch shot.png failed: {fetched.stderr}")
            census = subprocess.run([sys.executable, "-I", str(CENSUS), "--require-nonuniform", str(local_png)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(census.returncode, 0,
                             f"PNG is not a valid non-uniform image: {census.stdout}\n{census.stderr}")
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
            for p in (local_png, local_png.with_suffix(".html"), local_png.with_suffix(".ps1")):
                try:
                    p.unlink()
                except OSError:
                    pass

    def test_screenshot_failure_is_not_silent(self):
        # A nonexistent local page makes NavigationCompleted fail. --screenshot runs with
        # e2e_protocol off, so the pre-fix code exited 5 with NO stderr. The capture must now exit
        # nonzero AND print a specific, non-empty diagnostic. (RoseCat 6624.)
        rel = f"zb/shot-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        mk = self._ssh("cmd", "/c", f"mkdir {base_win}")
        self.assertEqual(mk.returncode, 0, f"mkdir failed: {mk.stderr}")
        runner_path = pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / f"zbrun-{secrets.token_hex(4)}.ps1"
        try:
            runner_path.write_text(_RUNNER, encoding="utf-8")
            for local, name in ((self.exe, "zigBrowser.exe"), (str(runner_path), "run.ps1")):
                r = self._scp(local, f"{rel}/{name}")
                self.assertEqual(r.returncode, 0, f"scp {name} failed: {r.stderr}")
            missing = f"file:///C:/Users/{self.user}/zb/zb-nope-{secrets.token_hex(4)}.html"
            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\run.ps1", base_win, missing)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            result = json.loads(run.stdout.strip().splitlines()[-1])
            self.assertNotEqual(result["exit"], 0, f"a failed navigation must exit nonzero: {result!r}")
            # Assert the EXACT NavigationCompleted-failure diagnostic (not merely any nonempty stderr — an
            # unrelated warning must not false-green it; RoseCat 6c771ff). The source pin for all branches is
            # tests/windows/screenshot_diag_selftest.py.
            self.assertIn("zigBrowser: screenshot: navigation failed; the page did not load", result["stderr"],
                          f"a failed screenshot must print the exact NavigationCompleted diagnostic: {result!r}")
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
            try:
                runner_path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
