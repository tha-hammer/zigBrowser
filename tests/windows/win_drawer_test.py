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

Lifecycle (RoseCat b2595b0 #2 / 29e8852): the runner creates the exe **SUSPENDED**, assigns it to a Job it
OWNS (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) with the assignment CHECKED, then RESUMES — so every descendant
(including `msedgewebview2.exe`) is born inside the job and cannot escape. Teardown terminates/closes the job,
killing the whole tree; **no pid-based kill is ever used** (no reused-pid hazard). Every Win32 API failure
throws and FAILS the test (fail-closed). The owned window is found by the launched **pid** (not a global
`FindWindow`); the census is the **Job's process-id list** (empty after teardown), not a machine-wide name
count; and the host window's **child controls** are counted independently (a row-only impl has none).

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


# VM-side runner (RoseCat 29e8852): create the browser SUSPENDED, assign it to a Job we OWN
# (KILL_ON_JOB_CLOSE) and CHECK the assignment, then resume — so every descendant (incl. msedgewebview2.exe)
# is born inside the job and cannot escape. Teardown closes/terminates the job, which kills the whole tree;
# NO pid-based kill is ever used (no reused-pid hazard). Every Win32 API failure throws -> the test fails
# (fail-closed). The owned window is found by OUR pid (not a global FindWindow), and the Job's process-id
# list is the census (not a machine-wide name count).
_RUNNER = r"""
$ErrorActionPreference='Stop'
$dir = $args[0]
$exe = Join-Path $dir 'zigBrowser.exe'
$out = Join-Path $dir 'o.txt'; $err = Join-Path $dir 'e.txt'; $nul = 'NUL'
Remove-Item $out,$err -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Z {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSD; public int bInherit; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long per; public long job; public uint flags; public UIntPtr minws; public UIntPtr maxws; public UIntPtr pa; public UIntPtr count; public long sched; }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong r,w,o,rb,wb,ob; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION basic; public IO_COUNTERS io; public UIntPtr pmem, jmem, ppmem, jpmem; }

  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool CreateProcess(string app, string cmd, ref SECURITY_ATTRIBUTES pa, ref SECURITY_ATTRIBUTES ta,
    bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32", SetLastError=true)] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32", SetLastError=true)] static extern bool TerminateJobObject(IntPtr j, uint c);
  [DllImport("kernel32", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j, int cls, IntPtr info, uint len);
  [DllImport("kernel32", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr j, int cls, IntPtr info, uint len, IntPtr ret);
  [DllImport("kernel32", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32")] static extern bool GetClientRect(IntPtr h, out RECT r);

  const uint CREATE_SUSPENDED = 0x4, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, CREATE_ALWAYS = 2;
  const uint KILL_ON_CLOSE = 0x2000, GENERIC_READ = 0x80000000, OPEN_EXISTING = 3, STARTF_USESTDHANDLES = 0x100;
  const int INFINITE_WAIT = -1;
  static void Fail(string op) { throw new Exception(op + " failed: " + Marshal.GetLastWin32Error()); }
  static IntPtr OpenWrite(string path) {
    var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)); sa.bInherit = 1;
    IntPtr h = CreateFile(path, GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE, ref sa, CREATE_ALWAYS, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) Fail("CreateFile " + path); return h;
  }
  static IntPtr OpenNul() {
    var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)); sa.bInherit = 1;
    IntPtr h = CreateFile("NUL", GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE, ref sa, OPEN_EXISTING, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) Fail("CreateFile NUL"); return h;
  }
  public static IntPtr Job; static IntPtr _hProc, _hThread; public static int Pid;
  // Create the job (KILL_ON_JOB_CLOSE), the suspended process with inherited std handles, assign it to the
  // job (CHECKED) BEFORE it runs, then resume. Any failure throws.
  public static void LaunchOwned(string exe, string cmdline, string cwd, string outPath, string errPath) {
    Job = CreateJobObject(IntPtr.Zero, null); if (Job == IntPtr.Zero) Fail("CreateJobObject");
    var eli = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION(); eli.basic.flags = KILL_ON_CLOSE;
    int sz = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); IntPtr pe = Marshal.AllocHGlobal(sz);
    try { Marshal.StructureToPtr(eli, pe, false);
      if (!SetInformationJobObject(Job, 9, pe, (uint)sz)) Fail("SetInformationJobObject"); }
    finally { Marshal.FreeHGlobal(pe); }
    IntPtr hOut = OpenWrite(outPath), hErr = OpenWrite(errPath), hIn = OpenNul();
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
    si.dwFlags = (int)STARTF_USESTDHANDLES; si.hStdInput = hIn; si.hStdOutput = hOut; si.hStdError = hErr;
    var pa = new SECURITY_ATTRIBUTES(); pa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    var ta = new SECURITY_ATTRIBUTES(); ta.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    PROCESS_INFORMATION pi;
    bool ok = CreateProcess(exe, cmdline, ref pa, ref ta, true, CREATE_SUSPENDED, IntPtr.Zero, cwd, ref si, out pi);
    CloseHandle(hOut); CloseHandle(hErr); CloseHandle(hIn);  // the child keeps its own copies
    if (!ok) Fail("CreateProcess");
    _hProc = pi.hProcess; _hThread = pi.hThread; Pid = pi.dwProcessId;
    if (!AssignProcessToJobObject(Job, pi.hProcess)) Fail("AssignProcessToJobObject");  // CHECKED, before resume
    if (ResumeThread(pi.hThread) == 0xFFFFFFFF) Fail("ResumeThread");
  }
  // Number of processes currently owned by the job (the owned-tree census; not a machine-wide name count).
  public static int JobProcessCount() {
    int sz = 8 + IntPtr.Size * 512; IntPtr buf = Marshal.AllocHGlobal(sz);
    try {
      if (!QueryInformationJobObject(Job, 3 /*BasicProcessIdList*/, buf, (uint)sz, IntPtr.Zero)) Fail("QueryInformationJobObject");
      return Marshal.ReadInt32(buf, 4); // NumberOfProcessIdsInList
    } finally { Marshal.FreeHGlobal(buf); }
  }
  public static void Teardown() {
    if (Job != IntPtr.Zero) { if (!TerminateJobObject(Job, 1)) Fail("TerminateJobObject"); }
    if (_hProc != IntPtr.Zero) WaitForSingleObject(_hProc, 8000);
  }
  public static void Close() {
    if (_hThread != IntPtr.Zero) CloseHandle(_hThread);
    if (_hProc != IntPtr.Zero) CloseHandle(_hProc);
    if (Job != IntPtr.Zero) CloseHandle(Job);  // KILL_ON_JOB_CLOSE: belt-and-suspenders
  }
  static IntPtr _found; static uint _pid; static string _cls; static readonly EnumProc _findCb = FindCb;
  static bool FindCb(IntPtr h, IntPtr l) { uint p; GetWindowThreadProcessId(h, out p);
    if (p == _pid) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); if (sb.ToString() == _cls) { _found = h; return false; } } return true; }
  public static IntPtr FindOwnedWindow(int pid, string cls) { _pid = (uint)pid; _cls = cls; _found = IntPtr.Zero; EnumWindows(_findCb, IntPtr.Zero); return _found; }
  static int _kids; static readonly EnumProc _childCb = ChildCb;
  static bool ChildCb(IntPtr h, IntPtr l) { _kids++; return true; }
  public static int ChildCount(IntPtr parent) { _kids = 0; EnumChildWindows(parent, _childCb, IntPtr.Zero); return _kids; }
  public static bool Client(IntPtr h, out int w, out int ht) { RECT r; bool ok = GetClientRect(h, out r); w = r.right-r.left; ht = r.bottom-r.top; return ok; }
}
'@

$res = @{ stdout=''; stderr=''; client_w=0; client_h=0; pid=0; child_controls=0; job_count_before=0; job_count_after=0; window_found=$false; terminated=$false; timed_out=$false; error='' }
# e2e-only seams, set in this process so the child inherits them (honoured only under --e2e-protocol).
$env:ZIGBROWSER_AGENT_DRAWER_OPEN = '1'
$env:ZIGBROWSER_AGENT_DRAWER_DEMO = 'messages:2'
$cmdline = '"' + $exe + '" --e2e-protocol --agent-drawer on "' + $url + '"'
try {
  [Z]::LaunchOwned($exe, $cmdline, $dir, $out, $err)   # suspended -> job -> checked assign -> resume
  $res.pid = [Z]::Pid
  $deadline = (Get-Date).AddSeconds(18); $seen = $false
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    $o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
    if ($o -and ($o -match "DRAWER`t\d+`topen`t")) { $seen = $true; break }
  }
  if (-not $seen) { $res.timed_out = $true }
  $res.job_count_before = [Z]::JobProcessCount()
  $h = [Z]::FindOwnedWindow([Z]::Pid, 'zigBrowserWebView2Host')   # OUR window, by pid (not global FindWindow)
  if ($h -ne [IntPtr]::Zero) {
    $res.window_found = $true
    $w = 0; $ht = 0; if ([Z]::Client($h, [ref]$w, [ref]$ht)) { $res.client_w = $w; $res.client_h = $ht }
    $res.child_controls = [Z]::ChildCount($h)
  }
} catch { $res.error = $_.Exception.Message }
finally {
  try { [Z]::Teardown(); $res.terminated = $true } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  try { $res.job_count_after = [Z]::JobProcessCount() } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  [Z]::Close()
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
        # No broad `drawer-*` sweep here: deleting other dirs could hit a concurrent run's live tree
        # (RoseCat 29e8852/7640 #3). Each run owns and removes ONLY its own unique root, fail-closed.

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
            # Any Win32 API failure in the runner fails the test (fail-closed, RoseCat 29e8852).
            self.assertEqual(r.get("error", ""), "", f"runner reported a Win32 failure: {r.get('error')!r}")
            self.assertFalse(r["timed_out"], f"runner timed out waiting for the drawer rows\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}")
            self.assertTrue(r["terminated"], "the owned Job did not terminate the browser tree within the bound")
            # Owned-tree census (b2595b0 #2 / 29e8852 #2): the Job's process-id list — not a machine-wide name
            # count — must be empty after teardown (every descendant was born in the job and killed with it).
            self.assertEqual(r["job_count_after"], 0, f"the owned Job still had processes after teardown (job_count_after={r['job_count_after']})")
            self.assertGreaterEqual(r["job_count_before"], 1, f"the Job owned no process while running (job_count_before={r['job_count_before']})")
            # The window is OUR process's (found by pid, not a global FindWindow, 29e8852 #3), and it has real
            # child controls (independent HWND census — not just rows; a row-only impl has no children).
            self.assertTrue(r["window_found"], "no zigBrowserWebView2Host window owned by the launched pid was found")
            self.assertGreaterEqual(r["child_controls"], 2, f"the host window must have >=2 native child controls (panel+icon); got {r['child_controls']}")
            rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
            wins = {win for win, _, _ in rows}
            self.assertEqual(len(wins), 1, f"all DRAWER rows must share one window id; got {sorted(wins)}")
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
            # The owned Job (KILL_ON_JOB_CLOSE) kills the WHOLE tree — including the WebView2 children born
            # inside it — so the run dir's WebView2 cache is released and this unique root must come back
            # clean. Remove ONLY this run's root, bounded retry, and FAIL if it survives (29e8852/7640 #3/#4),
            # without masking a body failure.
            import sys as _sys
            import time as _t
            gone = False
            for _ in range(20):
                self._ssh("cmd", "/c", f"rmdir /s /q {base_win}")
                if "GONE" in self._ssh("cmd", "/c", f"if exist {base_win} (echo LEFT) else (echo GONE)").stdout:
                    gone = True
                    break
                _t.sleep(1)
            for p in (html, runner):
                try:
                    p.unlink()
                except OSError:
                    pass
            if not gone and _sys.exc_info()[0] is None:
                self.fail(f"run dir left behind (not removed): {base_win}")


if __name__ == "__main__":
    unittest.main()
