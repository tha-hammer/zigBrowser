r"""Live Windows backend-flag arm on the Win11 VM (bead zigBrowser-j76, WS3.2).

`webkit.applyBackendFlag(.windows, …)` is the WebView2 arm of the shared backend-flag seam. On Windows
`backendFlagDecision` accepts `media-source` and `hardware-acceleration` and refuses `renderer`; the arm must
APPLY the accepted ones through the shim's startup setters (`zb_app_set_media_source` / `zb_app_set_hw_policy`),
exactly as the macOS arm does. This test drives the real exe on the VM and asserts:

  * `--media-source off` makes `window.MediaSource` undefined in the loaded page (the arm applied the setter,
    so the shim injects its MSE-hide script) — the discriminator: a placeholder `.windows => {}` arm leaves MSE
    present and fails this;
  * `--media-source on` keeps `window.MediaSource` present.

(The renderer refusal reaching stderr on the Windows GUI exe is a separate seam, owned by
BlueBeaver's `tests/windows/refusal_stderr_live_test.py` per the j76 split.)

The page sets `document.title = 'MSE=' + typeof window.MediaSource`; with `--e2e-protocol` the backend prints a
`NAV\t<url>\t<title>` row we read. Skips cleanly without ZB_WIN11_HOST / ZB_WIN_EXE. Needs no Linux slot.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=zig-out/win/current/zigBrowser.exe \
           python3 -I tests/windows/win_config_flags_test.py -v
"""
import json
import os
import pathlib
import secrets
import subprocess
import unittest
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "windows"))
import live_gate  # noqa: E402  ZB_WIN_GATE=1: a missing host fails instead of skipping; prints ASSERTS <n>

# A page whose title reports whether MediaSource exists after its inline script runs.
_HTML = (
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>pre</title>"
    "<script>document.title = 'MSE=' + (typeof window.MediaSource);</script>"
    "</head><body>mse probe</body></html>\n"
)

# VM-side runner for the --e2e-protocol modes: start the GUI exe, let it load, read its protocol
# rows, then kill it (open mode never exits on its own). Prints one JSON line.
_E2E_RUNNER = r"""
$ErrorActionPreference='SilentlyContinue'
$dir = $args[0]
$ms  = $args[1]
$exe = Join-Path $dir 'zigBrowser.exe'
$out = Join-Path $dir 'o.txt'; $err = Join-Path $dir 'e.txt'
Remove-Item $out,$err -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')
$p = Start-Process -FilePath $exe -ArgumentList '--e2e-protocol','--media-source',$ms,$url `
     -PassThru -NoNewWindow -RedirectStandardError $err -RedirectStandardOutput $out
Start-Sleep -Seconds 6
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
$o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $o) { $o = '' }
$e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $e) { $e = '' }
[Console]::Out.Write((@{ stdout = $o; stderr = $e } | ConvertTo-Json -Compress))
"""


class WinConfigFlags(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            live_gate.skip_or_fail(self, "ZB_WIN11_HOST unset — live VM backend-flag test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            live_gate.skip_or_fail(self, "ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
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
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=120)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120)

    def _stage(self):
        rel = f"zb/cfg-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        self.assertEqual(self._ssh("cmd", "/c", f"mkdir {base_win}").returncode, 0)
        tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp"))
        html = tmp / f"cfg-{secrets.token_hex(4)}.html"
        e2e = tmp / f"cfge2e-{secrets.token_hex(4)}.ps1"
        html.write_text(_HTML, encoding="utf-8")
        e2e.write_text(_E2E_RUNNER, encoding="utf-8")
        for local, name in ((self.exe, "zigBrowser.exe"), (str(html), "test.html"),
                            (str(e2e), "e2e.ps1")):
            self.assertEqual(self._scp(local, f"{rel}/{name}").returncode, 0, f"scp {name}")
        return rel, base_win, [html, e2e]

    def _cleanup(self, base_win, locals_):
        self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
        for p in locals_:
            try:
                p.unlink()
            except OSError:
                pass

    def _nav_title(self, stdout):
        for line in stdout.splitlines():
            if line.startswith("NAV\t"):
                parts = line.split("\t")
                if len(parts) >= 3:
                    return parts[2]
        return None

    def test_media_source_off_disables_media_source(self):
        rel, base_win, locals_ = self._stage()
        try:
            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\e2e.ps1", base_win, "off")
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            title = self._nav_title(r["stdout"])
            self.assertEqual(title, "MSE=undefined",
                             f"--media-source off must hide window.MediaSource; NAV title={title!r}, rows={r['stdout']!r}")
        finally:
            self._cleanup(base_win, locals_)

    def test_media_source_on_keeps_media_source(self):
        rel, base_win, locals_ = self._stage()
        try:
            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\e2e.ps1", base_win, "on")
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            title = self._nav_title(r["stdout"])
            self.assertEqual(title, "MSE=function",
                             f"--media-source on must keep window.MediaSource; NAV title={title!r}, rows={r['stdout']!r}")
        finally:
            self._cleanup(base_win, locals_)


if __name__ == "__main__":
    live_gate.main()
