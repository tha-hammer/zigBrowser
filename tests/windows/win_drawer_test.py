r"""WS5 native Win32 drawer — live entry red on the Win11 VM (OD-W6: native Win32 controls).

UNREGISTERED (red-first; registered in the WS5 green). The portable drawer logic (`agent_drawer.zig`,
`zb_drawer_*`) is backend-agnostic and already exports for Windows; WS5's green is the Win32 BACKEND
(`src/agent_drawer_win.cpp`, mounted from `webview2_shim.cpp`) plus the shim functions
`zb_app_set_agent_drawer` / `zb_app_get_agent_drawer` / `zb_drawer_debug_live_count` (today DEFINED only by
the GTK backend `src/agent_drawer.c`, absent on Windows).

ENTRY RED (WS5.0/WS5.1), pinning the plan's authoritative red (plan: `DRAWER\topen` + the dock equation):
with `--agent-drawer on --e2e-protocol` the drawer mounts and, driven open by the e2e-only seam
`ZIGBROWSER_AGENT_DRAWER_OPEN=1` (a deterministic sibling of `ZIGBROWSER_AGENT_DRAWER_DEMO`, honoured only
under `--e2e-protocol`, so it never widens the page/socket surface WS5.6 forbids), emits the SAME DRAWER row
NAMES as the GTK backend (`src/agent_drawer.c`): a structural `tree` row, an `icon` rect row, and an `open`
panel rect. The test parses the protocol fields (it does NOT accept any `DRAWER\t<anything>` line — a
`DRAWER\tbogus` stub or a row-only stub that creates no Win32 control fails) and pins the **dock geometry**
in client coordinates: the panel is full-width, docked at the bottom, with a non-empty page region above it,
so `page_h + panel_h == client_h` (`panel.y > 0` and `panel.y + panel.h == client_h`). That kills both the
row-only-stub mutant and the panel-overlays-instead-of-docks mutant. Today the Windows backend emits NO
DRAWER rows, so the first assertion (the `tree` row) fails — the failing-first evidence that the drawer is
absent, not a link error in a registered step.

Lifecycle (RoseCat b2595b0 #2): the runner owns the WHOLE browser tree with a Win32 **Job Object**
(`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`), launches the exe into it, waits a bounded time for the rows, reads
the client rect via `GetClientRect`, then terminates the JOB (killing every WebView2 descendant), waits
boundedly for terminal status, and reports a before/after process census. A timeout or a surviving process is
a FAILURE surfaced to the test (not hidden by the cleanup `finally`).

Scope (RoseCat b2595b0 #3 / OD-W4): the live drawer runs on the **win11 VM only**. The read-only Windows 10
file server cannot receive an exe (the no-write rule), so — exactly as WS2.0 did at rev 2.10 — the
physical-Win10 drawer leg is withdrawn, not silently skipped; and under the OD-W4 Win10 scope Win10 ships the
browser with the agent drawer in its agent-OFF state. A separate writable Win10 host the owner authorises
would run this same test with `ZB_WIN_HOST` pointed at it.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<built zigBrowser.exe> \
           python3 -I tests/windows/win_drawer_test.py -v
"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import unittest

# A trivial local page; the drawer is independent of page content.
_HTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>drawer</title></head><body>d</body></html>\n"

_RECT = r"-?\d+,-?\d+,\d+,\d+"
# The subset of DRAWER row shapes this entry red pins (names identical to src/agent_drawer.c / agent_common).
_KINDS = {"icon": [_RECT], "open": [_RECT], "tree": [r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*"]}


def parse_drawer(line):
    """`DRAWER\\t<win>\\t<kind>\\t...` -> (win, kind, fields) with field validation, or None."""
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) < 3 or parts[0] != "DRAWER" or not re.fullmatch(r"[1-9]\d*", parts[1]):
        return None
    kind = parts[2]
    shape = _KINDS.get(kind)
    if shape is None:
        return None  # a row this red does not pin (or a bogus kind) is ignored, never a pass
    fields = parts[3:]
    if len(fields) != len(shape) or not all(re.fullmatch(p, f) for p, f in zip(shape, fields)):
        return None
    return int(parts[1]), kind, tuple(fields)


def rect_of(fields, i=0):
    x, y, w, h = (int(v) for v in fields[i].split(","))
    return x, y, w, h


# VM-side runner: owns the browser tree with a Job Object, drives the drawer open via the e2e seam, reads
# the rows + client rect, tears the whole tree down through the job, and prints one JSON line.
_RUNNER = r"""
$ErrorActionPreference='Stop'
$dir = $args[0]
$exe = Join-Path $dir 'zigBrowser.exe'
$out = Join-Path $dir 'o.txt'; $err = Join-Path $dir 'e.txt'
Remove-Item $out,$err -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Z {
  [DllImport("kernel32")] public static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32")] public static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32")] public static extern bool TerminateJobObject(IntPtr j, uint c);
  [DllImport("kernel32", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr j, int cls, IntPtr info, uint len);
  [DllImport("user32")] public static extern IntPtr FindWindow(string c, string w);
  [DllImport("user32")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct JELI { public long per; public long job; public uint flags; public UIntPtr minws; public UIntPtr maxws; public UIntPtr pa; public UIntPtr count; public long sched; }
  [StructLayout(LayoutKind.Sequential)] public struct JEILI { public JELI basic; public IOCTR io; }
  [StructLayout(LayoutKind.Sequential)] public struct IOCTR { public ulong r,w,o; public ulong rb,wb,ob; }
  public const uint KILL_ON_CLOSE = 0x2000;
  public static IntPtr MakeJob() {
    IntPtr j = CreateJobObject(IntPtr.Zero, null);
    JEILI e = new JEILI(); e.basic.flags = KILL_ON_CLOSE;
    int sz = Marshal.SizeOf(typeof(JEILI)); IntPtr p = Marshal.AllocHGlobal(sz);
    Marshal.StructureToPtr(e, p, false);
    SetInformationJobObject(j, 9 /*ExtendedLimitInformation*/, p, (uint)sz);
    Marshal.FreeHGlobal(p); return j;
  }
}
'@

function Census() { @(Get-Process -Name zigBrowser -ErrorAction SilentlyContinue).Count }

$res = @{ stdout=''; stderr=''; client_w=0; client_h=0; census_before=0; census_after=0; webview_kids_left=0; terminated=$false; timed_out=$false; error='' }
$res.census_before = Census
# e2e-only seams, set in this process so Start-Process's child inherits them (honoured only under --e2e-protocol).
$env:ZIGBROWSER_AGENT_DRAWER_OPEN = '1'
$env:ZIGBROWSER_AGENT_DRAWER_DEMO = 'messages:2'
$job = [Z]::MakeJob()
$p = Start-Process -FilePath $exe `
     -ArgumentList '--e2e-protocol','--agent-drawer','on',$url `
     -PassThru -NoNewWindow -RedirectStandardError $err -RedirectStandardOutput $out
try {
  [void][Z]::AssignProcessToJobObject($job, $p.Handle)
  # Wait (bounded) for the three rows to appear in the redirected stdout.
  $deadline = (Get-Date).AddSeconds(18); $seen = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
    if ($o -and ($o -match "DRAWER`t\d+`topen`t")) { $seen = $true; break }
  }
  if (-not $seen) { $res.timed_out = $true }
  $h = [Z]::FindWindow('zigBrowserWebView2Host', $null)
  if ($h -ne [IntPtr]::Zero) { $r = New-Object Z+RECT; if ([Z]::GetClientRect($h, [ref]$r)) { $res.client_w = $r.right - $r.left; $res.client_h = $r.bottom - $r.top } }
} catch { $res.error = $_.Exception.Message }
finally {
  [void][Z]::TerminateJobObject($job, 1)
  $exited = $p.WaitForExit(8000)
  $res.terminated = $exited
  # WebView2 spawns msedgewebview2.exe children that break away from the Job Object and hold this run's
  # user-data dir open. Own them by IDENTITY: kill only those whose command line references THIS run dir
  # (the --user-data-dir lives under $dir), then bounded-wait for them to exit.
  for ($i=0; $i -lt 60; $i++) {
    $kids = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $dir + '*') })
    if ($kids.Count -eq 0) { break }
    foreach ($k in $kids) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 250
  }
  $res.webview_kids_left = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $dir + '*') }).Count
  $res.census_after = Census
  $res.stdout = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $res.stdout) { $res.stdout = '' }
  $res.stderr = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $res.stderr) { $res.stderr = '' }
}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
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
        # Sweep any stale drawer-* dirs whose WebView2 cache has since been released (best-effort), so a
        # slow async file-release from a prior run never accumulates.
        self._ssh("powershell", "-NoProfile", "-Command",
                  "Get-ChildItem $env:USERPROFILE\\zb -Filter drawer-* -Directory -ErrorAction SilentlyContinue | "
                  "ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }")

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
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120).returncode

    def test_native_drawer_mounts_docks_and_emits_census(self):
        rel = f"zb/drawer-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        self.assertEqual(self._ssh("cmd", "/c", f"mkdir {base_win}").returncode, 0)
        tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp"))
        html = tmp / f"drawer-{secrets.token_hex(4)}.html"
        runner = tmp / f"drawerrun-{secrets.token_hex(4)}.ps1"
        html.write_text(_HTML, encoding="utf-8")
        runner.write_text(_RUNNER, encoding="utf-8", newline="\r\n")
        try:
            pairs = [(self.exe, "zigBrowser.exe"), (str(html), "test.html"), (str(runner), "run.ps1")]
            loader = pathlib.Path(self.exe).with_name("WebView2Loader.dll")
            if loader.is_file():
                pairs.append((str(loader), "WebView2Loader.dll"))
            for local, name in pairs:
                self.assertEqual(self._scp(local, f"{rel}/{name}"), 0, f"scp {name}")
            # run.ps1 sets the e2e-only open seam + demo seed in its own environment before Start-Process,
            # so the exe inherits them (honoured only under --e2e-protocol).
            run = self._ssh("powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                            "-File", f"{base_win}\\run.ps1", base_win)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            # Lifecycle first (b2595b0 #2): a timeout or a surviving process is a failure, before any cleanup.
            self.assertFalse(r["timed_out"], f"runner timed out waiting for the drawer rows\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}")
            self.assertTrue(r["terminated"], "the Job Object did not terminate the browser tree within the bound")
            self.assertEqual(r["census_after"], 0, f"a zigBrowser process survived job termination (census_after={r['census_after']})")
            self.assertEqual(r.get("webview_kids_left", 0), 0,
                             f"a WebView2 child of this run survived teardown (webview_kids_left={r.get('webview_kids_left')})")
            rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
            by_kind = {}
            for win, kind, fields in rows:
                by_kind.setdefault(kind, []).append(fields)
            # Structural rows (same names as GTK), parsed — not a bare "DRAWER" prefix (b2595b0 #1).
            self.assertIn("tree", by_kind,
                          "WS5: the native Win32 drawer must emit a structural `tree` row (as GTK does). "
                          f"Got none — the Windows drawer backend is not implemented yet.\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}")
            self.assertIn("icon", by_kind, f"WS5: the drawer must emit an `icon` rect row. rows={r['stdout']!r}")
            self.assertIn("open", by_kind, f"WS5: with the e2e open seam the drawer must emit an `open` panel rect. rows={r['stdout']!r}")
            # Dock geometry in client coords: full-width, docked at the bottom, page region above it,
            # so page_h + panel_h == client_h. Kills the overlay mutant (panel.y==0) and needs the real client rect.
            px, py, pw, ph = rect_of(by_kind["open"][0])
            self.assertGreater(r["client_h"], 0, "could not read the client rect (GetClientRect)")
            self.assertEqual(pw, r["client_w"], f"the panel must be full client width ({pw} != {r['client_w']})")
            self.assertGreater(py, 0, f"the panel must dock below a non-empty page region, not overlay ({py=})")
            self.assertEqual(py + ph, r["client_h"],
                             f"page_h + panel_h must equal client_h (panel.y {py} + panel.h {ph} != client_h {r['client_h']})")
        finally:
            # The tree is owned + proven dead by the process census above (b2595b0 #2). The run dir may still
            # hold WebView2's EBWebView cache files, which Windows releases asynchronously for tens of seconds
            # after the processes die — a file-release lag, not a surviving process — so dir removal is
            # best-effort with a generous retry (not a test failure). setUp() also sweeps stale drawer-* dirs
            # so nothing accumulates.
            import time as _t
            for _ in range(20):
                self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
                if "GONE" in self._ssh("cmd", "/c", f"if exist {base_win} (echo LEFT) else (echo GONE)").stdout:
                    break
                _t.sleep(1)
            for p in (html, runner):
                try:
                    p.unlink()
                except OSError:
                    pass


if __name__ == "__main__":
    unittest.main()
