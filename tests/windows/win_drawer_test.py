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


def check_success(r):
    """The discriminating oracle for a SUCCESSFUL drawer run. Raises AssertionError on any violation. Pure
    (takes the runner's JSON result dict), so it is exercised offline with injected results in WinDrawerOracle
    AND on the live result in WinDrawerLive (RoseCat 29e8852)."""
    assert r.get("error", "") == "", f"runner reported a Win32 failure: {r.get('error')!r}"
    assert not r["timed_out"], f"runner timed out waiting for the drawer rows\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}"
    assert r["terminated"], "the owned Job teardown did not reach WAIT_OBJECT_0 on the browser"
    # Owned-tree census: the Job's process-id list (not a machine-wide name count) is empty after teardown.
    assert r["job_count_after"] == 0, f"the owned Job still had processes after teardown (job_count_after={r['job_count_after']})"
    assert r["job_count_before"] >= 1, f"the Job owned no process while running (job_count_before={r['job_count_before']})"
    # The window is OUR process's, found by pid (not a global FindWindow).
    assert r["window_found"], "no zigBrowserWebView2Host window owned by the launched pid was found"
    # Exact DIRECT STATIC children: the drawer panel ("" text) + the "S" icon, and nothing else. A row-only /
    # null-control implementation (or EnumChildWindows counting WebView2's own HWNDs) does not pass.
    statics = [s for s in (r.get("controls") or "").split("|") if s]
    texts = sorted(s[len("STATIC:"):] for s in statics if s.startswith("STATIC:"))
    assert texts == ["", "S"], f"host window must have exactly the drawer panel + 'S' icon direct STATIC children; got {statics!r}"
    rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
    wins = {win for win, _, _ in rows}
    assert len(wins) == 1, f"all DRAWER rows must share one window id; got {sorted(wins)}"
    by_kind = {}
    for win, kind, fields in rows:
        by_kind.setdefault(kind, []).append(fields)
    for k in ("tree", "icon", "open"):
        assert k in by_kind, f"missing DRAWER `{k}` row (the native drawer backend must emit it); rows={r['stdout']!r}"
    px, py, pw, ph = rect_of(by_kind["open"][0])
    assert r["client_h"] > 0, "could not read the client rect (GetClientRect)"
    assert pw == r["client_w"], f"the panel must be full client width ({pw} != {r['client_w']})"
    assert py > 0, f"the panel must dock below a non-empty page region, not overlay (py={py})"
    assert py + ph == r["client_h"], f"page_h + panel_h must equal client_h ({py} + {ph} != {r['client_h']})"


def check_mounted_fail(r, which):
    """The oracle for a FORCED control-create failure (`which` in {panel, icon}, RoseCat 7646): the browser
    still runs and tears down cleanly, but NO drawer mounts — no DRAWER rows, no drawer controls — and the
    exact failure diagnostic is emitted. Pure; raises AssertionError on any violation."""
    assert r.get("error", "") == "", f"the browser itself must run (a forced drawer-control failure is a drawer branch, not a runner Win32 error): {r.get('error')!r}"
    assert r["terminated"], "teardown must reach WAIT_OBJECT_0 even when the drawer did not mount"
    assert r["job_count_after"] == 0, f"the owned Job must be empty after teardown (got {r['job_count_after']})"
    rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
    assert rows == [], f"a forced-{which}-fail mount must emit NO DRAWER rows; got {rows}"
    # NO direct drawer controls at all: neither the panel ("STATIC:" empty text) nor the "S" icon
    # ("STATIC:S"). For an ICON failure this causally proves the already-created panel was DESTROYED — a leaked
    # (not-destroyed, or failed-DestroyWindow) panel shows up as "STATIC:" and must fail here (RoseCat 7677).
    statics = [s for s in (r.get("controls") or "").split("|") if s]
    drawer_controls = [s for s in statics if s in ("STATIC:", "STATIC:S")]
    assert drawer_controls == [], f"a forced-{which}-fail mount must leave NO drawer controls (panel/icon); got {statics!r}"
    # The EXACT complete diagnostic (deterministic forced error 87 + "; drawer not mounted"), as a full line,
    # NOT a truncated substring (RoseCat 7677).
    expected = f"zigBrowser: agent-drawer {which} control failed (error 87); drawer not mounted"
    lines = [ln.rstrip("\r") for ln in (r.get("stderr") or "").splitlines()]
    assert expected in lines, f"the exact {which}-failure diagnostic (forced error 87) must be emitted; got {r.get('stderr')!r}"


def check_assign_fail(r):
    """Forced AssignProcessToJobObject failure (RoseCat fd17cba/7662): the suspended process is outside the
    job, so it must be terminated by its HELD handle and PROVEN gone — never a pid/name kill, no orphan."""
    assert r.get("launch_failed"), f"a forced assign failure must report launch_failed; got {r!r}"
    assert r.get("proc_gone"), "the held (unassigned, suspended) process must be proven terminated (proc_gone)"
    assert "AssignProcessToJobObject" in (r.get("error") or ""), f"the assign-failure error must be surfaced; got {r.get('error')!r}"
    rows = [row for row in (parse_drawer(ln) for ln in r.get("stdout", "").splitlines()) if row]
    assert rows == [], f"a process killed before resume must emit NO DRAWER rows; got {rows}"


def check_wait_fail(r):
    """Forced teardown WaitForSingleObject != WAIT_OBJECT_0 (RoseCat fd17cba/7662 #2): must be a test FAILURE,
    never a silent bounded success."""
    assert not r.get("terminated"), "a non-WAIT_OBJECT_0 teardown must NOT count as terminated"
    assert "WAIT_OBJECT_0" in (r.get("error") or ""), f"the wait failure must be surfaced as an error; got {r.get('error')!r}"


# VM-side runner (RoseCat 29e8852): create the browser SUSPENDED, assign it to a Job we OWN
# (KILL_ON_JOB_CLOSE) and CHECK the assignment, then resume — so every descendant (incl. msedgewebview2.exe)
# is born inside the job and cannot escape. Teardown closes/terminates the job, which kills the whole tree;
# NO pid-based kill is ever used (no reused-pid hazard). Every Win32 API failure throws -> the test fails
# (fail-closed). The owned window is found by OUR pid (not a global FindWindow), and the Job's process-id
# list is the census (not a machine-wide name count).
_RUNNER = r"""
$ErrorActionPreference='Stop'
$dir = $args[0]
$failMode = $args[1]    # '', 'panel' or 'icon' — drives the PRODUCTION control-factory failure seam
$forceMode = $args[2]   # '', 'assign_fail' or 'wait_fail' — drives the HARNESS job-lifecycle failure seam
if ($forceMode) { $env:ZB_E2E_DRAWER_FORCE = $forceMode }  # read by [Z]::ForceFail at first use
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
  [DllImport("kernel32", SetLastError=true)] static extern bool TerminateProcess(IntPtr h, uint code);
  [DllImport("kernel32", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", SetLastError=true)] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32")] static extern bool GetClientRect(IntPtr h, out RECT r);

  const uint CREATE_SUSPENDED = 0x4, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, CREATE_ALWAYS = 2;
  const uint KILL_ON_CLOSE = 0x2000, GENERIC_READ = 0x80000000, OPEN_EXISTING = 3, STARTF_USESTDHANDLES = 0x100;
  const uint GW_CHILD = 5, GW_HWNDNEXT = 2, WAIT_OBJECT_0 = 0, STILL_ACTIVE = 259;
  // e2e-only forced-failure seam for the OFFLINE/LIVE failure-branch proofs (inert unless set).
  public static string ForceFail = Environment.GetEnvironmentVariable("ZB_E2E_DRAWER_FORCE");
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
  public static IntPtr Job; static IntPtr _hProc, _hThread; public static int Pid; public static bool ProcGone;
  // Terminate the exact held process handle (never a pid) and PROVE it exited: TerminateProcess must succeed,
  // WaitForSingleObject must signal WAIT_OBJECT_0, and the exit code must not be STILL_ACTIVE. The handle is
  // closed/cleared ONLY when exit is proven; on an unproven stop the handle is RETAINED (a cleanup route) and
  // ProcGone stays false so the caller/oracle treats it as a failure. Returns ProcGone.
  static bool KillHeld() {
    if (_hProc == IntPtr.Zero) { ProcGone = true; return true; }
    bool term = TerminateProcess(_hProc, 1);
    uint w = WaitForSingleObject(_hProc, 8000);
    uint code = STILL_ACTIVE; bool got = GetExitCodeProcess(_hProc, out code);
    ProcGone = term && (w == WAIT_OBJECT_0) && got && code != STILL_ACTIVE;
    if (ProcGone) { CloseHandle(_hThread); CloseHandle(_hProc); _hThread = IntPtr.Zero; _hProc = IntPtr.Zero; }
    return ProcGone;
  }
  // Create the job (KILL_ON_JOB_CLOSE), the suspended process with inherited std handles, assign it to the
  // job (CHECKED) BEFORE it runs, then resume. On any post-create failure the HELD handle is terminated +
  // waited (no orphan). Any failure throws.
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
    // Store the process handles IMMEDIATELY (before reacting to any std-handle close failure), so KillHeld can
    // always reach the created suspended process. On CreateProcess failure there is no process to store.
    if (ok) { _hProc = pi.hProcess; _hThread = pi.hThread; Pid = pi.dwProcessId; }
    // Close all three inherited std handles (no short-circuit: close each, then react).
    bool cOut = CloseHandle(hOut), cErr = CloseHandle(hErr), cIn = CloseHandle(hIn);
    if (!ok) Fail("CreateProcess");
    if (!cOut || !cErr || !cIn) { KillHeld(); Fail("CloseHandle(std) (held process terminated; gone=" + ProcGone + ")"); }
    // Forced assignment failure (e2e seam): the suspended process is outside the job; it MUST be terminated
    // by the held handle (never a pid) and PROVEN gone (ProcGone).
    bool assigned = (ForceFail == "assign_fail") ? false : AssignProcessToJobObject(Job, pi.hProcess);
    if (!assigned) { KillHeld(); throw new Exception("AssignProcessToJobObject failed (held process terminated; gone=" + ProcGone + ")"); }
    if (ResumeThread(pi.hThread) == 0xFFFFFFFF) { KillHeld(); Fail("ResumeThread (held process terminated; gone=" + ProcGone + ")"); }
  }
  // Number of processes currently owned by the job (the owned-tree census; not a machine-wide name count).
  public static int JobProcessCount() {
    int sz = 8 + IntPtr.Size * 512; IntPtr buf = Marshal.AllocHGlobal(sz);
    try {
      if (!QueryInformationJobObject(Job, 3 /*BasicProcessIdList*/, buf, (uint)sz, IntPtr.Zero)) Fail("QueryInformationJobObject");
      return Marshal.ReadInt32(buf, 4); // NumberOfProcessIdsInList
    } finally { Marshal.FreeHGlobal(buf); }
  }
  // Terminate the job and REQUIRE the held process to reach WAIT_OBJECT_0 (a timeout/WAIT_FAILED throws).
  public static void Teardown() {
    uint wait = (ForceFail == "wait_fail") ? 258u /*WAIT_TIMEOUT*/ : 0xFFFFFFFFu;
    if (Job != IntPtr.Zero) { if (!TerminateJobObject(Job, 1)) Fail("TerminateJobObject"); }
    if (ForceFail != "wait_fail" && _hProc != IntPtr.Zero) wait = WaitForSingleObject(_hProc, 8000);
    else if (ForceFail != "wait_fail") wait = WAIT_OBJECT_0;
    if (wait != WAIT_OBJECT_0) throw new Exception("WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: " + wait);
  }
  public static void Close() {
    bool okT = _hThread == IntPtr.Zero || CloseHandle(_hThread);
    bool okP = _hProc == IntPtr.Zero || CloseHandle(_hProc);
    bool okJ = Job == IntPtr.Zero || CloseHandle(Job);  // KILL_ON_JOB_CLOSE: belt-and-suspenders
    if (!okT || !okP || !okJ) Fail("CloseHandle");
  }
  static IntPtr _found; static uint _pid; static string _cls; static readonly EnumProc _findCb = FindCb;
  static bool FindCb(IntPtr h, IntPtr l) { uint p; GetWindowThreadProcessId(h, out p);
    if (p == _pid) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); if (sb.ToString() == _cls) { _found = h; return false; } } return true; }
  public static IntPtr FindOwnedWindow(int pid, string cls) { _pid = (uint)pid; _cls = cls; _found = IntPtr.Zero; EnumWindows(_findCb, IntPtr.Zero); return _found; }
  // The DIRECT STATIC children of the host (GW_CHILD/GW_HWNDNEXT) — NOT EnumChildWindows (which also counts
  // WebView2's own HWND hierarchy). Returns "class:text" for each, so the oracle can require exactly the
  // drawer's panel ("" text) + "S" icon. A row-only impl has no such controls.
  public static string DirectStatics(IntPtr parent) {
    var parts = new System.Collections.Generic.List<string>();
    IntPtr c = GetWindow(parent, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (cls.ToString() == "STATIC") { var t = new StringBuilder(64); GetWindowText(c, t, 64); parts.Add("STATIC:" + t.ToString()); }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return String.Join("|", parts.ToArray());
  }
  public static bool Client(IntPtr h, out int w, out int ht) { RECT r; bool ok = GetClientRect(h, out r); w = r.right-r.left; ht = r.bottom-r.top; return ok; }
}
'@

$res = @{ stdout=''; stderr=''; client_w=0; client_h=0; pid=0; controls=''; job_count_before=0; job_count_after=0; window_found=$false; terminated=$false; timed_out=$false; proc_gone=$false; launch_failed=$false; error='' }
# e2e-only seams, set in this process so the child inherits them (honoured only under --e2e-protocol).
$env:ZIGBROWSER_AGENT_DRAWER_OPEN = '1'
$env:ZIGBROWSER_AGENT_DRAWER_DEMO = 'messages:2'
if ($failMode) { $env:ZIGBROWSER_AGENT_DRAWER_FAIL = $failMode }
$cmdline = '"' + $exe + '" --e2e-protocol --agent-drawer on "' + $url + '"'
$launched = $false
try {
  [Z]::LaunchOwned($exe, $cmdline, $dir, $out, $err)   # suspended -> job -> checked assign -> resume
  $launched = $true
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
    $res.controls = [Z]::DirectStatics($h)   # exact DIRECT STATIC children, "STATIC:<text>|..."
  }
} catch { $res.error = $_.Exception.Message; $res.proc_gone = [Z]::ProcGone; $res.launch_failed = (-not $launched) }
finally {
  if ($launched) {
    try { [Z]::Teardown(); $res.terminated = $true } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
    try { $res.job_count_after = [Z]::JobProcessCount() } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  }
  try { [Z]::Close() } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
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

    def _run_drawer(self, fail_mode="", force_mode="", body=None):
        """Stage + run run.ps1 (optionally with the production control-factory seam `fail_mode` and/or the
        harness job-lifecycle seam `force_mode`), parse the JSON result, invoke `body(r)`, and always tear
        down this run's unique root fail-closed."""
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
            args = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-File", f"{base_win}\\run.ps1", base_win]
            if fail_mode or force_mode:
                args.append(fail_mode)          # positional $args[1]
            if force_mode:
                args.append(force_mode)         # positional $args[2]
            run = self._ssh(*args)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            if body:
                body(r)
            return r
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
            if not gone:
                # Report cleanup exhaustion either way (never silently accepted); only raise if the body did
                # not already fail, so the original failure is preserved (29e8852 #4).
                _sys.stderr.write(f"CLEANUP: run dir left behind (not removed): {base_win}\n")
                if _sys.exc_info()[0] is None:
                    self.fail(f"run dir left behind (not removed): {base_win}")

    def test_native_drawer_mounts_docks_and_emits_census(self):
        self._run_drawer(body=check_success)

    def test_panel_create_failure_leaves_no_drawer(self):
        # WS5 (RoseCat 7646): forcing the panel CreateWindowExW to fail must mount NO drawer — no DRAWER rows,
        # no drawer controls — the browser still runs and tears down cleanly, with the panel diagnostic.
        self._run_drawer(fail_mode="panel", body=lambda r: check_mounted_fail(r, "panel"))

    def test_icon_create_failure_leaves_no_drawer(self):
        self._run_drawer(fail_mode="icon", body=lambda r: check_mounted_fail(r, "icon"))

    def test_assign_failure_terminates_held_process(self):
        # RoseCat fd17cba/7662: forcing AssignProcessToJobObject to fail must terminate the held (suspended)
        # process by its handle — proven gone (no pid/name kill, no orphan).
        self._run_drawer(force_mode="assign_fail", body=check_assign_fail)

    def test_wait_failure_is_reported(self):
        # A teardown that does not reach WAIT_OBJECT_0 must FAIL (never a silent bounded success).
        self._run_drawer(force_mode="wait_fail", body=check_wait_fail)


class WinDrawerOracle(unittest.TestCase):
    """OFFLINE (no VM) injected coverage proving the runner-result oracle is discriminating and fail-closed
    (RoseCat 29e8852 'add non-live injected coverage ...'). Each case feeds a crafted result dict to
    check_success and asserts it raises for the corresponding failure branch."""

    def _good(self):
        return {
            "error": "", "timed_out": False, "terminated": True, "job_count_after": 0, "job_count_before": 2,
            "window_found": True, "controls": "STATIC:|STATIC:S", "client_w": 1008, "client_h": 729,
            "stdout": ("DRAWER\t1\ttree\thost,page,icon,panel\n"
                       "DRAWER\t1\ticon\t928,649,56,56\n"
                       "DRAWER\t1\topen\t0,437,1008,292\n"),
            "stderr": "",
        }

    def test_good_passes(self):
        check_success(self._good())  # must NOT raise

    def _reject(self, mutate):
        r = self._good(); mutate(r)
        with self.assertRaises(AssertionError):
            check_success(r)

    def test_assign_failure_rejected(self):
        self._reject(lambda r: r.update(error="AssignProcessToJobObject failed (held process terminated; gone=True)"))

    def test_win32_error_rejected(self):
        self._reject(lambda r: r.update(error="CreateProcess failed: 2"))

    def test_wait_not_object0_rejected(self):
        self._reject(lambda r: r.update(terminated=False))

    def test_timed_out_rejected(self):
        self._reject(lambda r: r.update(timed_out=True))

    def test_job_survivor_rejected(self):
        self._reject(lambda r: r.update(job_count_after=1))

    def test_no_owned_window_rejected(self):
        self._reject(lambda r: r.update(window_found=False))

    def test_row_only_no_controls_rejected(self):
        self._reject(lambda r: r.update(controls=""))  # a row-only / null-control impl

    def test_wrong_or_extra_controls_rejected(self):
        self._reject(lambda r: r.update(controls="STATIC:|STATIC:S|STATIC:X"))

    def test_multiple_window_ids_rejected(self):
        self._reject(lambda r: r.update(stdout=r["stdout"].replace("DRAWER\t1\topen", "DRAWER\t2\topen")))

    def test_missing_open_row_rejected(self):
        self._reject(lambda r: r.update(stdout="DRAWER\t1\ttree\thost,page,icon,panel\nDRAWER\t1\ticon\t928,649,56,56\n"))

    def test_overlay_geometry_rejected(self):  # panel.y == 0 (overlay, not docked)
        self._reject(lambda r: r.update(stdout=r["stdout"].replace("0,437,1008,292", "0,0,1008,729")))

    def test_panel_not_full_width_rejected(self):
        self._reject(lambda r: r.update(client_w=1200))

    # --- forced control-create failure oracle (check_mounted_fail, RoseCat 7646) ---
    def _good_fail(self, which):
        return {"error": "", "terminated": True, "job_count_after": 0, "controls": "",
                "stdout": "NAV\tfile:///x/test.html\tdrawer\n",
                "stderr": f"zigBrowser: agent-drawer {which} control failed (error 87); drawer not mounted\n"}

    def test_panel_fail_good_passes(self):
        check_mounted_fail(self._good_fail("panel"), "panel")

    def test_icon_fail_good_passes(self):
        check_mounted_fail(self._good_fail("icon"), "icon")

    def test_fail_but_rows_emitted_rejected(self):
        r = self._good_fail("panel"); r["stdout"] += "DRAWER\t1\ttree\thost,page,icon,panel\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_but_icon_control_present_rejected(self):
        r = self._good_fail("icon"); r["controls"] = "STATIC:|STATIC:S"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_icon_fail_but_leaked_panel_rejected(self):
        # RoseCat 7677 survived mutant: an icon failure that LEAKS the panel ("STATIC:", no icon). The panel
        # must have been destroyed, so a leaked panel must fail.
        r = self._good_fail("icon"); r["controls"] = "STATIC:"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_fail_without_diagnostic_rejected(self):
        r = self._good_fail("panel"); r["stderr"] = ""
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_truncated_diagnostic_rejected(self):
        # RoseCat 7677 survived mutant: a truncated diagnostic (no "(error 87); drawer not mounted") must fail.
        r = self._good_fail("icon"); r["stderr"] = "zigBrowser: agent-drawer icon control failed\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_fail_wrong_error_code_rejected(self):
        # the pinned diagnostic requires the deterministic forced error 87; a different code must fail.
        r = self._good_fail("panel")
        r["stderr"] = "zigBrowser: agent-drawer panel control failed (error 5); drawer not mounted\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_but_not_torn_down_rejected(self):
        r = self._good_fail("panel"); r["terminated"] = False
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    # --- forced job-lifecycle failure oracles (check_assign_fail / check_wait_fail) ---
    def test_assign_fail_good_passes(self):
        check_assign_fail({"launch_failed": True, "proc_gone": True,
                           "error": "AssignProcessToJobObject failed (held process terminated; gone=True)", "stdout": ""})

    def test_assign_fail_orphan_survivor_rejected(self):
        with self.assertRaises(AssertionError):
            check_assign_fail({"launch_failed": True, "proc_gone": False,
                               "error": "AssignProcessToJobObject failed (held process terminated; gone=False)", "stdout": ""})

    def test_assign_fail_rows_emitted_rejected(self):
        with self.assertRaises(AssertionError):
            check_assign_fail({"launch_failed": True, "proc_gone": True,
                               "error": "AssignProcessToJobObject failed", "stdout": "DRAWER\t1\topen\t0,437,1008,292\n"})

    def test_wait_fail_good_passes(self):
        check_wait_fail({"terminated": False, "error": "WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: 258"})

    def test_wait_fail_silent_success_rejected(self):
        with self.assertRaises(AssertionError):
            check_wait_fail({"terminated": True, "error": ""})


if __name__ == "__main__":
    unittest.main()
