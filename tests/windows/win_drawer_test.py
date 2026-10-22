r"""WS5 native Win32 drawer — live reds on the Win11 VM (per OD-W6: native Win32 controls).

UNREGISTERED (red-first; registered in the WS5 green). The portable drawer logic (`agent_drawer.zig`,
`zb_drawer_*`) and its exports are already backend-agnostic; WS5's green is the Win32 BACKEND
(`src/agent_drawer_win.cpp`) that mounts the drawer from `zb_window_new`, plus the shim functions
`zb_app_set_agent_drawer` / `zb_app_get_agent_drawer` / `zb_drawer_debug_live_count` (today DEFINED only
by the GTK backend `src/agent_drawer.c`; absent in `src/webview2_shim.cpp`).

ENTRY RED (WS5.0): with `--agent-drawer on --e2e-protocol`, the GTK backend emits a `DRAWER <win> tree …`
census row at startup. The Windows backend emits NO `DRAWER` rows (there is no drawer), so this fails
today and passes once the Win32 backend mounts and emits the same census rows. The richer WS5.1-WS5.7
behaviors (dock resize, icon drag/keys/persist/hide, fold animation, selectable inert bubbles, per-window
live count, isolation from JS/socket, DPI) land as the green is built, each with the real-screen checks
the plan names (orchestrator + user, both screens).

Skips cleanly when ZB_WIN11_HOST / ZB_WIN_EXE is unset, so the hostless Linux gate stays green.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<built zigBrowser.exe> \
           python3 -I tests/windows/win_drawer_test.py -v
"""
import json
import os
import pathlib
import secrets
import subprocess
import unittest

# A trivial local page; the drawer is independent of page content.
_HTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>drawer</title></head><body>d</body></html>\n"

# VM-side runner: start the GUI exe with the drawer on + the e2e protocol, let it mount, read the
# protocol rows, then kill it (open mode never exits on its own). Prints one JSON line.
_RUNNER = r"""
$ErrorActionPreference='SilentlyContinue'
$dir = $args[0]
$exe = Join-Path $dir 'zigBrowser.exe'
$out = Join-Path $dir 'o.txt'; $err = Join-Path $dir 'e.txt'
Remove-Item $out,$err -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')
$env:ZIGBROWSER_AGENT_DRAWER_DEMO = 'messages:2'
$p = Start-Process -FilePath $exe -ArgumentList '--e2e-protocol','--agent-drawer','on',$url `
     -PassThru -NoNewWindow -RedirectStandardError $err -RedirectStandardOutput $out
Start-Sleep -Seconds 6
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
$o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $o) { $o = '' }
$e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $e) { $e = '' }
[Console]::Out.Write((@{ stdout = $o; stderr = $e } | ConvertTo-Json -Compress))
"""


class WinDrawerLive(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM drawer test skipped")
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
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=120)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120)

    def test_native_drawer_mounts_and_emits_census(self):
        rel = f"zb/drawer-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        self.assertEqual(self._ssh("cmd", "/c", f"mkdir {base_win}").returncode, 0)
        tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp"))
        html = tmp / f"drawer-{secrets.token_hex(4)}.html"
        runner = tmp / f"drawerrun-{secrets.token_hex(4)}.ps1"
        html.write_text(_HTML, encoding="utf-8")
        runner.write_text(_RUNNER, encoding="utf-8")
        try:
            pairs = [(self.exe, "zigBrowser.exe"), (str(html), "test.html"), (str(runner), "run.ps1")]
            loader = pathlib.Path(self.exe).with_name("WebView2Loader.dll")
            if loader.is_file():
                pairs.append((str(loader), "WebView2Loader.dll"))
            for local, name in pairs:
                self.assertEqual(self._scp(local, f"{rel}/{name}").returncode, 0, f"scp {name}")
            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\run.ps1", base_win)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            rows = [ln for ln in r["stdout"].splitlines() if ln.startswith("DRAWER\t")]
            self.assertTrue(rows,
                            "WS5: with --agent-drawer on --e2e-protocol the native Win32 drawer must mount "
                            "and emit DRAWER census rows (as the GTK backend does). Got none — the Windows "
                            f"drawer backend is not implemented yet.\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}")
        finally:
            self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
            for p in (html, runner):
                try:
                    p.unlink()
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
