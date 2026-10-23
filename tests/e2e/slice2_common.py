#!/usr/bin/env python3
"""Shared helpers for Slice 2 WebKitGTK app-shell E2E tests."""

from __future__ import annotations

import atexit
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

SKIP_EXIT = 77
HARNESS_EXIT_PREFIX = "ZB_HARNESS_EXIT"
WIN_GATE_ENV = "ZB_WIN_GATE"


def gate_skip_exit(reason: str) -> int:
    """Exit code for a missing precondition (Windows plan WS0.9, D.1): SKIP_EXIT when a human runs the test
    standalone; 1 under the gate (ZB_WIN_GATE=1), where a skip is a failure. Use as `return gate_skip_exit(...)`."""
    print(reason, file=sys.stderr)
    if os.environ.get(WIN_GATE_ENV) == "1":
        print(f"{WIN_GATE_ENV}=1: precondition missing; a skip is a failure under the gate", file=sys.stderr)
        return 1
    return SKIP_EXIT
# The one launcher for E2E browsers (see its docstring): the browser keeps
# its own PID, and a guardian ends it and its private Xvfb if the test dies.
XSESSION = Path(__file__).resolve().parent / "xsession.py"


def xsession_prefix(xvfb: bool, screen: str | None = None) -> list[str]:
    """Command prefix that runs a browser under xsession.py (--xvfb: on its
    own Xvfb display, never the caller's)."""
    prefix = [sys.executable, str(XSESSION)]
    if xvfb:
        prefix.append("--xvfb")
    if screen is not None:
        prefix += ["--screen", screen]
    return prefix + ["--"]


# An agent helper's processes (chat-drawer plan S5.5): the helper's launch
# (`python -m zb_agent_host ...`), netd (`.../zb_agent_host/netd.py`) and the relay.
AGENT_HELPER_MARKERS = ("zb_agent_host", "zb-net-relay")


def agent_helper_processes(root: int) -> list[list[str]]:
    """The argv of every live descendant of `root` that is an agent helper process."""
    kids: dict[int, list[int]] = {}
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            fields = Path(f"/proc/{entry}/stat").read_text().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue
        if fields[0] != "Z":
            kids.setdefault(int(fields[1]), []).append(int(entry))
    found, todo = [], [root]
    while todo:
        for child in kids.get(todo.pop(), []):
            todo.append(child)
            try:
                argv = [a.decode(errors="replace") for a in Path(f"/proc/{child}/cmdline").read_bytes().split(b"\0") if a]
            except OSError:
                continue
            if any(marker in arg for arg in argv for marker in AGENT_HELPER_MARKERS):
                found.append(argv[:4])
    return found


GUARDIAN_GONE_SEC = 30.0  # xsession's worst case: helper grace 8 s + group TERM/KILL 10 s + Xvfb TERM 5 s


def _xsession_guardian(pid: int) -> int | None:
    """The xsession.py guardian watching browser `pid`: the process whose argv names xsession.py and which holds a
    pidfd for `pid` (its fdinfo names the pid while `pid` is alive or not yet reaped). None without /proc (Windows,
    macOS) or when there is none. Only observed, never signalled."""
    if not os.path.isdir("/proc"):
        return None
    for entry in filter(str.isdigit, os.listdir("/proc")):
        try:
            if b"xsession.py" not in Path(f"/proc/{entry}/cmdline").read_bytes():
                continue
            for fd in os.listdir(f"/proc/{entry}/fd"):
                if os.readlink(f"/proc/{entry}/fd/{fd}") != "anon_inode:[pidfd]":
                    continue
                if ["Pid:", str(pid)] in (line.split() for line in
                                          Path(f"/proc/{entry}/fdinfo/{fd}").read_text().splitlines()):
                    return int(entry)
        except OSError:
            continue  # gone meanwhile, or not ours to read
    return None


def _running(pid: int) -> bool:
    """Running (a zombie awaiting its reaper counts as gone)."""
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def stop_browser(proc: subprocess.Popen, grace_sec: float = 8.0, agent_helpers_allowed: bool = False) -> int | None:
    """Shared teardown for a browser started with an xsession prefix: SIGINT
    (a clean shutdown); a browser still running after `grace_sec` gets
    SIGKILL with its whole process group (browser and WebKit helpers). After
    a clean exit the helpers are left to exit on their own (tests assert
    that); the guardian ends any that linger, then removes the private
    display, and once the browser has exited this waits (at most
    GUARDIAN_GONE_SEC) for that guardian to finish: a driver that exits next,
    ending its PID namespace, would otherwise SIGKILL the guardian and Xvfb
    mid-cleanup and leave /tmp/.X<n>-lock and the X socket behind
    (zigBrowser-44h). Safe to call more than once. Returns the browser's exit
    status.

    The drawer is on by default (S5.5), and nothing starts an agent helper
    until its Send: unless `agent_helpers_allowed` (the agent tests), a
    helper process found under the browser fails the test with an
    AssertionError, after the teardown."""
    guardian = _xsession_guardian(proc.pid) if proc.returncode is None else None  # before anything reaps it
    helpers = agent_helper_processes(proc.pid) if proc.poll() is None and not agent_helpers_allowed else []
    code = _stop(proc, grace_sec)
    if guardian is not None and code is not None:
        deadline = time.monotonic() + GUARDIAN_GONE_SEC
        while _running(guardian):
            if time.monotonic() >= deadline:
                raise AssertionError(f"the xsession guardian of browser {proc.pid} did not finish its display "
                                     f"cleanup within {GUARDIAN_GONE_SEC:.0f} s")
            time.sleep(0.02)
    if helpers:
        raise AssertionError(f"an agent helper ran in a test that never pressed Send: {helpers}")
    return code


def _stop(proc: subprocess.Popen, grace_sec: float) -> int | None:
    if proc.poll() is None:
        try:
            proc.send_signal(signal.SIGINT)
            proc.wait(timeout=grace_sec)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    return proc.returncode


def eprint(msg: str) -> None:
    print(msg, file=os.sys.stderr)


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _read_lines(stream, sink: list[str]) -> None:
    try:
        for line in stream:
            sink.append(line.rstrip("\n"))
    finally:
        stream.close()


def child_pids_linux(proc_pid: int) -> set[int]:
    children_file = Path(f"/proc/{proc_pid}/task/{proc_pid}/children")
    if children_file.exists():
        raw = children_file.read_text(encoding="utf-8").strip()
        if not raw:
            return set()
        return {int(item) for item in raw.split() if item.isdigit()}

    pgrep = shutil.which("pgrep")
    if pgrep is None:
        return set()
    result = subprocess.run([pgrep, "-P", str(proc_pid)], capture_output=True, text=True, check=False)
    if result.returncode not in (0, 1):
        return set()
    return {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}


def assert_children_exit(children: Iterable[int], timeout_sec: float) -> tuple[bool, list[int]]:
    deadline = time.monotonic() + timeout_sec
    children_set = set(children)
    while time.monotonic() < deadline:
        alive = [pid for pid in children_set if is_pid_alive(pid)]
        if not alive:
            return True, []
        time.sleep(0.05)
    alive = [pid for pid in children_set if is_pid_alive(pid)]
    return len(alive) == 0, alive


def isolate_profile_env(env: dict[str, str]) -> dict[str, str]:
    """Point XDG data/cache homes at a fresh temp root (removed at exit).

    zigBrowser defaults its persistent profile to $XDG_DATA_HOME/zigbrowser/
    profile, so without this every E2E launch would read and write the
    developer's real cookies and site data and share them across parallel
    tests."""
    root = tempfile.mkdtemp(prefix="zb-e2e-xdg-")
    atexit.register(shutil.rmtree, root, True)
    env["XDG_DATA_HOME"] = os.path.join(root, "data")
    env["XDG_CACHE_HOME"] = os.path.join(root, "cache")
    return env


def automation_auth(socket_path: Path) -> str | None:
    """The per-session token zigBrowser writes next to its socket
    (<socket>.token, mode 0600) when no --automation-token-file is given."""
    try:
        return (Path(str(socket_path) + ".token")).read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def detect_runner(prefer_xvfb: bool) -> tuple[list[str], dict[str, str], str] | None:
    """(command prefix, env, note) for launching the browser. Every prefix
    is an xsession.py one, so the browser never outlives the test."""
    env = isolate_profile_env(dict(os.environ))
    xvfb = shutil.which("Xvfb") is not None and shutil.which("xauth") is not None
    display = env.get("DISPLAY")

    # Local default: live display first.
    if not prefer_xvfb:
        if display:
            return xsession_prefix(False), env, f"DISPLAY={display}"
        if Path("/tmp/.X11-unix/X1").exists():
            env["DISPLAY"] = ":1"
            return xsession_prefix(False), env, "DISPLAY=:1"

    # CI / explicit xvfb preference: a private Xvfb owned by xsession.py.
    if xvfb:
        return xsession_prefix(True), env, "xvfb"

    # Fallback to live display when xvfb is requested but unavailable.
    if display:
        return xsession_prefix(False), env, f"DISPLAY={display}"
    if Path("/tmp/.X11-unix/X1").exists():
        env["DISPLAY"] = ":1"
        return xsession_prefix(False), env, "DISPLAY=:1"

    eprint("SKIP: no DISPLAY and no Xvfb/xauth; install xvfb or export DISPLAY")
    return None


def require_file(path: Path, label: str) -> bool:
    if path.exists():
        return True
    eprint(f"SKIP: missing {label}: {path}")
    return False


def protocol_rows(lines: list[str], prefix: str) -> list[list[str]]:
    tag = f"{prefix}\t"
    return [line.split("\t") for line in lines if line.startswith(tag)]


def harness_exit_code(lines: list[str]) -> int | None:
    for line in reversed(lines):
        row = line.split("\t")
        if len(row) != 2 or row[0] != HARNESS_EXIT_PREFIX:
            continue
        try:
            return int(row[1], 10)
        except ValueError:
            return None
    return None


@dataclass
class RunResult:
    returncode: int
    stdout_lines: list[str]
    stderr_lines: list[str]
    tracked_children: set[int]
    timed_out: bool = False
    pid: int | None = None


@dataclass
class ScheduledTaskProcess:
    pid: int | None
    returncode: int | None

    def poll(self) -> int | None:
        return self.returncode


def run_interactive_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], Any], bool],
    on_tick: Callable[[list[str], list[str], Any], None] | None = None,
) -> tuple[bool, RunResult]:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    assert proc.stdout is not None
    assert proc.stderr is not None

    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    out_thread = threading.Thread(target=_read_lines, args=(proc.stdout, stdout_lines), daemon=True)
    err_thread = threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True)
    out_thread.start()
    err_thread.start()

    tracked_children: set[int] = set()
    matched = False
    deadline = time.monotonic() + timeout_sec

    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        tracked_children.update(child_pids_linux(proc.pid))
        if on_tick is not None:
            on_tick(stdout_lines, stderr_lines, proc)
        if condition(stdout_lines, stderr_lines, proc):
            matched = True
            break
        time.sleep(0.05)

    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            pass
    stop_browser(proc, grace_sec=0)

    out_thread.join(timeout=1)
    err_thread.join(timeout=1)

    result = RunResult(
        returncode=proc.returncode,
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=tracked_children,
    )
    return matched, result


def _ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _read_file_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except (FileNotFoundError, PermissionError, OSError):
        return []


def _read_int_file(path: Path) -> int | None:
    try:
        raw = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None
    try:
        return int(raw, 10)
    except ValueError:
        return None


# Every m8 browser launch gets its own WebView2 user-data folder (NavyCanyon e80e0352): without --profile-dir the
# shim leaves WebView2 on the one shared `<exe>.WebView2` folder beside the staged exe, and a second launch on that
# folder failed CreateCoreWebView2Controller with 0x800700AA (ERROR_BUSY) on Win11. An inherited
# WEBVIEW2_USER_DATA_FOLDER (or the WebView2 UserDataFolder policy) would redirect every launch to one folder, so the
# runners and the task wrapper refuse it.
WEBVIEW2_OVERRIDE_ENV = "WEBVIEW2_USER_DATA_FOLDER"
_PROFILE_LABEL = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")


def browser_profile_dir(run_root: Path, label: str) -> Path:
    """A fresh profile directory for ONE browser launch, under `run_root/profiles` (the run's own folder). Prints the
    effective WebView2 user-data folder (`<dir>\\WebView2`, src/webview2_shim.cpp) as a WEBVIEW2_USER_DATA row."""
    if not _PROFILE_LABEL.fullmatch(label):
        raise ValueError(f"profile label {label!r} is not a plain lowercase token")
    base = run_root.resolve()
    path = (base / "profiles" / f"{label}-{uuid.uuid4().hex[:12]}").resolve()
    if base not in path.parents:
        raise ValueError(f"profile {path} escapes the run root {base}")
    path.mkdir(parents=True, exist_ok=False)
    print(f"WEBVIEW2_USER_DATA\t{label}\t{path}\\WebView2", flush=True)
    return path


def _webview2_override_refused(env: dict[str, str]) -> RunResult | None:
    """A failing result when `env` would redirect the WebView2 user-data folder; None when it is clean."""
    keys = [k for k in env if k.upper() == WEBVIEW2_OVERRIDE_ENV]
    if not keys:
        return None
    return RunResult(
        returncode=1,
        stdout_lines=[],
        stderr_lines=[f"runner: refused: {keys[0]} is set; it would redirect every launch's WebView2 user-data folder"],
        tracked_children=set(),
    )


# The task's process tree is owned by a kill-on-close job (Windows plan WS0.4; NavyCanyon 7eafbae option (a), wait
# only). The wrapper creates the program SUSPENDED and BORN INTO the job, the drawer harness's launch that ran on the
# Win11 VM (tests/windows/win_drawer_test.py LaunchOwned), so every descendant, msedgewebview2.exe included, is a job
# member. After a normal exit the wrapper waits, within ONE budget of JOB_DRAIN_DEADLINE_SEC, for the job to drain by
# itself; only an empty job passes. Survivors at the deadline are recorded, then contained by closing the job, and
# the run fails. The runner may end its own still-running test through the job (stop.txt) after a matched stop
# condition or a hard timeout; a timeout stays a failure. No process is ever killed by pid. The wrapper writes one
# census line to job.txt: `ZB_RUNNER_JOB\t<drained|survivors|left|stopped>\t<n>`.
JOB_PREFIX = "ZB_RUNNER_JOB"
JOB_DRAIN_DEADLINE_SEC = 60.0  # the one drain budget (at most 60 s, as tests/windows/webview2_cleanup.DEADLINE_S)
JOB_CENSUS_GRACE_SEC = 15.0  # past the budget: the job close (an 8 s settle) and the census write

_JOB_CS = r"""
using System;
using System.Runtime.InteropServices;
public static class ZbJob {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr lpAttributeList; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSD; public int bInherit; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long per; public long job; public uint flags; public UIntPtr minws; public UIntPtr maxws; public UIntPtr pa; public UIntPtr count; public long sched; }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong r,w,o,rb,wb,ob; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION basic; public IO_COUNTERS io; public UIntPtr pmem, jmem, ppmem, jpmem; }
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool CreateProcess(string app, string cmd, ref SECURITY_ATTRIBUTES pa, ref SECURITY_ATTRIBUTES ta,
    bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32", SetLastError=true)] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32", SetLastError=true)] static extern bool TerminateJobObject(IntPtr j, uint c);
  [DllImport("kernel32", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j, int cls, IntPtr info, uint len);
  [DllImport("kernel32", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr j, int cls, IntPtr info, uint len, IntPtr ret);
  [DllImport("kernel32", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  const uint CREATE_SUSPENDED = 0x4, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, CREATE_ALWAYS = 2;
  const uint KILL_ON_CLOSE = 0x2000, GENERIC_READ = 0x80000000, OPEN_EXISTING = 3, STARTF_USESTDHANDLES = 0x100;
  const uint WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 258, EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
  static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = (IntPtr)0x0002000D;
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
  static IntPtr Job, _hProc, _hThread;
  public static bool Stopped;
  // The kill-on-close job, then the program SUSPENDED and born into it (STARTUPINFOEX + PROC_THREAD_ATTRIBUTE_JOB_LIST),
  // membership checked, then resumed. Returns the program's pid.
  public static int Launch(string cmdline, string cwd, string outPath, string errPath) {
    Job = CreateJobObject(IntPtr.Zero, null); if (Job == IntPtr.Zero) Fail("CreateJobObject");
    var eli = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION(); eli.basic.flags = KILL_ON_CLOSE;
    int sz = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); IntPtr pe = Marshal.AllocHGlobal(sz);
    try { Marshal.StructureToPtr(eli, pe, false);
      if (!SetInformationJobObject(Job, 9, pe, (uint)sz)) Fail("SetInformationJobObject"); }
    finally { Marshal.FreeHGlobal(pe); }
    IntPtr hOut = OpenWrite(outPath), hErr = OpenWrite(errPath), hIn = OpenNul();
    IntPtr alSize = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref alSize);
    IntPtr attrList = Marshal.AllocHGlobal(alSize);
    IntPtr jobArr = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobArr, Job);
    var six = new STARTUPINFOEX();
    six.si.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
    six.si.dwFlags = (int)STARTF_USESTDHANDLES; six.si.hStdInput = hIn; six.si.hStdOutput = hOut; six.si.hStdError = hErr;
    var pa = new SECURITY_ATTRIBUTES(); pa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    var ta = new SECURITY_ATTRIBUTES(); ta.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    PROCESS_INFORMATION pi = new PROCESS_INFORMATION(); bool ok = false;
    try {
      if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref alSize)) Fail("InitializeProcThreadAttributeList");
      if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, jobArr, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) Fail("UpdateProcThreadAttribute");
      six.lpAttributeList = attrList;
      ok = CreateProcess(null, cmdline, ref pa, ref ta, true, CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, cwd, ref six, out pi);
      if (ok) { _hProc = pi.hProcess; _hThread = pi.hThread; }
    } finally {
      if (attrList != IntPtr.Zero) DeleteProcThreadAttributeList(attrList);
      Marshal.FreeHGlobal(attrList); Marshal.FreeHGlobal(jobArr);
    }
    bool cOut = CloseHandle(hOut), cErr = CloseHandle(hErr), cIn = CloseHandle(hIn);
    if (!ok) Fail("CreateProcess");
    if (!cOut || !cErr || !cIn) { TerminateJobObject(Job, 1); Fail("CloseHandle(std)"); }
    if (Count() < 1) { TerminateJobObject(Job, 1); throw new Exception("job membership not verified"); }
    if (ResumeThread(pi.hThread) == 0xFFFFFFFF) { TerminateJobObject(Job, 1); Fail("ResumeThread"); }
    return pi.dwProcessId;
  }
  // Processes the job owns now (the owned-tree census; not a machine-wide name count).
  public static int Count() {
    if (Job == IntPtr.Zero) return 0;
    int sz = 8 + IntPtr.Size * 512; IntPtr buf = Marshal.AllocHGlobal(sz);
    try {
      if (!QueryInformationJobObject(Job, 3 /*BasicProcessIdList*/, buf, (uint)sz, IntPtr.Zero)) Fail("QueryInformationJobObject");
      return Marshal.ReadInt32(buf, 4); // NumberOfProcessIdsInList
    } finally { Marshal.FreeHGlobal(buf); }
  }
  // The program's exit code, or -1 once the runner asked to stop (stopPath exists).
  public static int Wait(string stopPath) {
    while (true) {
      uint w = WaitForSingleObject(_hProc, 200);
      if (w == WAIT_OBJECT_0) { uint code; if (!GetExitCodeProcess(_hProc, out code)) Fail("GetExitCodeProcess"); return unchecked((int)code); }
      if (w != WAIT_TIMEOUT) Fail("WaitForSingleObject");
      if (System.IO.File.Exists(stopPath)) { Stopped = true; return -1; }
    }
  }
  // Waits (bounded) for the job to hold no process; returns what is still in it.
  static int Settle(int ms) {
    var sw = System.Diagnostics.Stopwatch.StartNew(); int n = Count();
    while (n > 0 && sw.ElapsedMilliseconds < ms) { System.Threading.Thread.Sleep(100); n = Count(); }
    return n;
  }
  static void Close() {
    if (Job != IntPtr.Zero) CloseHandle(Job);  // KILL_ON_CLOSE: the backstop for anything the count missed
    Job = IntPtr.Zero;
    if (_hThread != IntPtr.Zero) CloseHandle(_hThread);
    if (_hProc != IntPtr.Zero) CloseHandle(_hProc);
    _hThread = IntPtr.Zero; _hProc = IntPtr.Zero;
  }
  // The runner asked to stop its still-running test: end the job's tree, close the job. "stopped\t<n>" (n ended) or
  // "left\t<n>" (n outlived the end).
  public static string Stop() {
    int n = Count();
    if (!TerminateJobObject(Job, 1)) Fail("TerminateJobObject");
    int left = Settle(8000);
    Close();
    return left > 0 ? "left\t" + left : "stopped\t" + n;
  }
  // After the drain budget (the wrapper's one $ZbDrainEnd): an empty job is "drained\t0". Survivors are recorded
  // ("survivors\t<n>"), THEN contained by ending the job; the runner fails the run either way. "left\t<n>" if even
  // that leaves processes.
  public static string Finish() {
    int n = Count();
    if (n == 0) { Close(); return "drained\t0"; }
    if (!TerminateJobObject(Job, 1)) Fail("TerminateJobObject");
    int left = Settle(8000);
    Close();
    return left > 0 ? "left\t" + left : "survivors\t" + n;
  }
}
"""


def _write_windows_task_wrapper(
    script_path: Path,
    cmd: list[str],
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    exit_path: Path,
    pid_path: Path,
    cwd: Path,
    job_path: Path,
    stop_path: Path,
) -> None:
    if not cmd:
        raise ValueError("scheduled task command must not be empty")

    env_lines = []
    for key, value in sorted(env.items()):
        if not (key.startswith("ZB_") or key.startswith("WEBVIEW2_") or key == "WINRT_INCLUDE"):
            continue
        if not key.replace("_", "").isalnum():
            continue
        env_lines.append(f"$env:{key} = {_ps_quote(value)}")

    # CreateProcess resolves a bare program name against the wrapper's process directory and PATH, never the
    # Set-Location below (a relative `zigBrowser.exe` was "not found" on the Win11 VM), so a program in the run's cwd
    # goes in absolute.
    program = Path(cmd[0])
    if not program.is_absolute() and (cwd / program).is_file():
        program = cwd / program
    cmdline = subprocess.list2cmdline([str(program), *[str(item) for item in cmd[1:]]])
    # "\n" here: write_text(newline="\r\n") makes it CRLF; a "\r\n" join would give "\r\r\n", which the here-string
    # opener `@'` below must not meet.
    script = "\n".join(
        [
            "$ErrorActionPreference = 'Stop'",
            f"$stdoutPath = {_ps_quote(str(stdout_path))}",
            f"$stderrPath = {_ps_quote(str(stderr_path))}",
            f"$exitPath = {_ps_quote(str(exit_path))}",
            f"$pidPath = {_ps_quote(str(pid_path))}",
            f"$jobPath = {_ps_quote(str(job_path))}",
            f"$stopPath = {_ps_quote(str(stop_path))}",
            f"$ZbDrainBudgetSec = {JOB_DRAIN_DEADLINE_SEC:g}",
            "$census = $null",
            "try {",
            f"  Set-Location -LiteralPath {_ps_quote(str(cwd))}",
            *[f"  {line}" for line in env_lines],
            # NavyCanyon e80e0352: nothing on the host may redirect the WebView2 user-data folder
            f"  if ($env:{WEBVIEW2_OVERRIDE_ENV}) {{ throw 'refused: {WEBVIEW2_OVERRIDE_ENV} is set in the task environment' }}",
            "  foreach ($root in @('HKCU:', 'HKLM:')) {",
            "    $policy = Get-Item -LiteralPath \"$root\\Software\\Policies\\Microsoft\\Edge\\WebView2\\UserDataFolder\" -ErrorAction SilentlyContinue",
            "    if ($null -ne $policy -and $policy.ValueCount -gt 0) { throw \"refused: the WebView2 UserDataFolder policy is set under $root\" }",
            "  }",
            "  Add-Type -TypeDefinition @'",
            *_JOB_CS.strip("\n").splitlines(),
            "'@",
            f"  $p = [ZbJob]::Launch({_ps_quote(cmdline)}, {_ps_quote(str(cwd))}, $stdoutPath, $stderrPath)",
            "  $p | Set-Content -LiteralPath $pidPath -Encoding ASCII",
            "  $exitCode = [ZbJob]::Wait($stopPath)",
            "  if ([ZbJob]::Stopped) { $exitCode = 1 }",
            "  $exitCode | Set-Content -LiteralPath $exitPath -Encoding ASCII",
            f"  Add-Content -LiteralPath $stdoutPath -Encoding UTF8 -Value (\"{HARNESS_EXIT_PREFIX}`t{{0}}\" -f $exitCode)",
            "  if ([ZbJob]::Stopped) {",
            "    $census = [ZbJob]::Stop()",
            "  } else {",
            "    $ZbDrainEnd = [DateTime]::UtcNow.AddSeconds($ZbDrainBudgetSec)",
            "    while ([ZbJob]::Count() -gt 0 -and [DateTime]::UtcNow -lt $ZbDrainEnd) { Start-Sleep -Milliseconds 200 }",
            "    $census = [ZbJob]::Finish()",
            "  }",
            "} catch {",
            "  $_ | Out-String | Add-Content -LiteralPath $stderrPath -Encoding UTF8",
            "  if (-not (Test-Path -LiteralPath $exitPath)) {",
            "    1 | Set-Content -LiteralPath $exitPath -Encoding ASCII",
            f"    Add-Content -LiteralPath $stdoutPath -Encoding UTF8 -Value \"{HARNESS_EXIT_PREFIX}`t1\"",
            "  }",
            "}",
            # no census after a failure inside the wrapper: the runner fails the run (the job handle closes with
            # this process, so KILL_ON_CLOSE still contains the tree)
            f"if ($null -ne $census) {{ Set-Content -LiteralPath $jobPath -Encoding ASCII -Value (\"{JOB_PREFIX}`t\" + $census) }}",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8", newline="\r\n")


def _cmd_script_quote(path: Path) -> str:
    return '"' + str(path).replace('"', '""') + '"'


def _cmd_set_line(key: str, value: str) -> str:
    return f'set "{key}={value.replace("%", "%%").replace(chr(34), chr(34) + chr(34))}"'


def _write_windows_cmd_wrapper(
    script_path: Path,
    cmd: list[str],
    env: dict[str, str],
    stdout_path: Path,
    stderr_path: Path,
    cwd: Path,
) -> None:
    if not cmd:
        raise ValueError("scheduled task command must not be empty")

    env_lines = []
    for key, value in sorted(env.items()):
        if not (key.startswith("ZB_") or key.startswith("WEBVIEW2_") or key == "WINRT_INCLUDE"):
            continue
        if not key.replace("_", "").isalnum():
            continue
        env_lines.append(_cmd_set_line(key, value))

    cmd_line = subprocess.list2cmdline([str(item) for item in cmd])
    exit_marker = f"{HARNESS_EXIT_PREFIX}\t%ZB_EXIT_CODE%"
    script = "\r\n".join(
        [
            "@echo off",
            "setlocal",
            f"cd /d {_cmd_script_quote(cwd)}",
            *env_lines,
            f"{cmd_line} > {_cmd_script_quote(stdout_path)} 2> {_cmd_script_quote(stderr_path)}",
            "set \"ZB_EXIT_CODE=%ERRORLEVEL%\"",
            f">> {_cmd_script_quote(stdout_path)} echo {exit_marker}",
            "exit /b %ZB_EXIT_CODE%",
            "",
        ]
    )
    script_path.write_text(script, encoding="utf-8", newline="\r\n")


def _run_schtasks(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


# The task runs at least privilege (Windows plan WS0.4 item 4): a standard test user cannot request `/rl highest`
# ("ERROR: Access is denied." at /create on the Win11 VM, review c70c24e), and nothing here needs elevation.
TASK_RUN_LEVEL = "limited"


def _failed(what: str, proc: subprocess.CompletedProcess[str]) -> str:
    return f"runner: {what} failed (rc={proc.returncode}): {(proc.stderr or proc.stdout).strip()}"


def _end_windows_task(task_name: str) -> list[str]:
    """Ends the task (its wrapper) when the wrapper never answered with a census: closing the wrapper closes its
    kill-on-close job. Never a pid kill. Returns a diagnostic if the end failed; the run fails on the missing census."""
    proc = _run_schtasks(["schtasks", "/end", "/tn", task_name])
    return [] if proc.returncode == 0 else [_failed("schtasks /end", proc)]


def _read_job_census(path: Path) -> str | None:
    """The wrapper's census text once completely written (it ends with a newline), else None."""
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    return raw if raw.endswith("\n") else None


def _settle_job(task_name: str, job_path: Path, stop_path: Path, stop_requested: bool) -> tuple[str | None, list[str]]:
    """Asks a still-running test to stop through its job (stop.txt), then waits for the wrapper's census within one
    deadline: the drain budget plus the job close. No census in time: the task is ended (never by pid)."""
    if stop_requested:
        stop_path.write_text("stop\n", encoding="ascii")
    deadline = time.monotonic() + JOB_DRAIN_DEADLINE_SEC + JOB_CENSUS_GRACE_SEC
    census = _read_job_census(job_path)
    while census is None and time.monotonic() < deadline:
        time.sleep(0.1)
        census = _read_job_census(job_path)
    return census, ([] if census is not None else _end_windows_task(task_name))


def _census_problem(raw: str | None, stop_requested: bool) -> str | None:
    """None when the census proves the run's tree gone the right way, else why the run fails."""
    if raw is None:
        return "runner: no job census from the task wrapper: the run's process tree is not proven gone"
    lines = [line for line in raw.lstrip("\ufeff").replace("\r", "").split("\n") if line]
    row = lines[0].split("\t") if len(lines) == 1 else []
    if len(row) == 3 and row[0] == JOB_PREFIX and re.fullmatch(r"[0-9]+", row[2]):
        verdict, n = row[1], int(row[2], 10)
        if verdict == "drained" and n == 0:
            return None
        if verdict == "stopped" and n > 0 and stop_requested:
            return None
        if verdict == "survivors" and n > 0:
            return (f"runner: {n} process(es) of the run were still alive at the {JOB_DRAIN_DEADLINE_SEC:g} s drain "
                    "deadline; closing the job contained them, and the run fails")
        if verdict == "left" and n > 0:
            return f"runner: {n} process(es) of the run survived the job close"
    return f"runner: invalid job census {raw.strip()!r}"


def _delete_windows_task(task_name: str) -> str | None:
    """Deletes the task. A task left behind fails the run (WS0.4 item 4): returns the failure, or None."""
    proc = _run_schtasks(["schtasks", "/delete", "/tn", task_name, "/f"])
    return None if proc.returncode == 0 else _failed(f"schtasks /delete /tn {task_name}", proc)


def _fail_on_cleanup(matched: bool, result: RunResult, notes: list[str], delete_error: str | None,
                     census_problem: str | None = None) -> bool:
    """Adds the cleanup diagnostics to the result; a failed delete or a job census that does not prove the run's tree
    gone (see _census_problem) makes the run fail. Returns `matched`."""
    result.stderr_lines.extend(notes)
    errors = [e for e in (delete_error, census_problem) if e is not None]
    if not errors:
        return matched
    result.stderr_lines.extend(errors)
    if result.returncode == 0:
        result.returncode = 1
    return False


def run_windows_interactive_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], ScheduledTaskProcess], bool],
    on_tick: Callable[[list[str], list[str], ScheduledTaskProcess], None] | None = None,
    cwd: Path | None = None,
) -> tuple[bool, RunResult]:
    if os.name != "nt":
        raise RuntimeError("interactive scheduled-task runner is Windows-only")
    refused = _webview2_override_refused(env)
    if refused is not None:
        return False, refused

    task_name = f"zb_m8_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    work_dir = Path(tempfile.mkdtemp(prefix="zb_m8_task_"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    exit_path = work_dir / "exit.txt"
    pid_path = work_dir / "pid.txt"
    job_path = work_dir / "job.txt"
    stop_path = work_dir / "stop.txt"
    script_path = work_dir / "run.ps1"
    cwd_path = (cwd or Path.cwd()).resolve()
    _write_windows_task_wrapper(script_path, cmd, env, stdout_path, stderr_path, exit_path, pid_path, cwd_path,
                                job_path, stop_path)

    task_cmd = f'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{script_path}"'
    create = _run_schtasks(
        [
            "schtasks",
            "/create",
            "/tn",
            task_name,
            "/tr",
            task_cmd,
            "/sc",
            "once",
            "/st",
            "23:59",
            "/it",
            "/rl",
            TASK_RUN_LEVEL,
            "/f",
        ]
    )
    if create.returncode != 0:
        return False, RunResult(
            returncode=create.returncode,
            stdout_lines=create.stdout.splitlines(),
            stderr_lines=create.stderr.splitlines(),
            tracked_children=set(),
        )

    run = _run_schtasks(["schtasks", "/run", "/tn", task_name])
    if run.returncode != 0:
        result = RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )
        return _fail_on_cleanup(False, result, [], _delete_windows_task(task_name)), result

    matched = False
    timed_out = False
    deadline = time.monotonic() + timeout_sec
    pid: int | None = None
    returncode: int | None = None
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    try:
        while time.monotonic() < deadline:
            stdout_lines = _read_file_lines(stdout_path)
            stderr_lines = _read_file_lines(stderr_path)
            pid = _read_int_file(pid_path) or pid
            returncode = _read_int_file(exit_path)
            proc = ScheduledTaskProcess(pid=pid, returncode=returncode)
            if on_tick is not None:
                on_tick(stdout_lines, stderr_lines, proc)
            if condition(stdout_lines, stderr_lines, proc):
                matched = True
                break
            if returncode is not None:
                break
            time.sleep(0.1)
        else:
            timed_out = True
    finally:
        stop_requested = returncode is None
        census, stop_notes = _settle_job(task_name, job_path, stop_path, stop_requested)
        delete_error = _delete_windows_task(task_name)
    if stop_requested:
        returncode = None  # the runner ended it: its exit code is the stop, not the program's answer

    stdout_lines = _read_file_lines(stdout_path)
    stderr_lines = _read_file_lines(stderr_path)
    pid = _read_int_file(pid_path) or pid
    result = RunResult(
        returncode=returncode if returncode is not None else (0 if matched else 1),
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=set(),
        timed_out=timed_out,
        pid=pid,
    )
    return _fail_on_cleanup(matched, result, stop_notes, delete_error, _census_problem(census, stop_requested)), result


def run_windows_interactive_cmd_until(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    condition: Callable[[list[str], list[str], ScheduledTaskProcess], bool],
    cwd: Path | None = None,
) -> tuple[bool, RunResult]:
    if os.name != "nt":
        raise RuntimeError("interactive scheduled-task cmd runner is Windows-only")
    refused = _webview2_override_refused(env)
    if refused is not None:
        return False, refused

    task_name = f"zb_m8_cmd_{os.getpid()}_{uuid.uuid4().hex[:8]}"
    work_dir = Path(tempfile.mkdtemp(prefix="zb_m8_cmd_"))
    stdout_path = work_dir / "stdout.txt"
    stderr_path = work_dir / "stderr.txt"
    pid_path = work_dir / "pid.txt"
    job_path = work_dir / "job.txt"
    stop_path = work_dir / "stop.txt"
    cmd_script_path = work_dir / "run.cmd"
    script_path = work_dir / "run.ps1"
    cwd_path = (cwd or Path.cwd()).resolve()
    _write_windows_cmd_wrapper(cmd_script_path, cmd, env, stdout_path, stderr_path, cwd_path)
    # run.cmd keeps the program's own exit code (its ZB_HARNESS_EXIT row in stdout.txt); the job wrapper owns its tree.
    _write_windows_task_wrapper(script_path, ["cmd.exe", "/d", "/c", "call", str(cmd_script_path)], {},
                                work_dir / "task_stdout.txt", work_dir / "task_stderr.txt", work_dir / "exit.txt",
                                pid_path, cwd_path, job_path, stop_path)

    task_cmd = f'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{script_path}"'
    create = _run_schtasks(
        [
            "schtasks",
            "/create",
            "/tn",
            task_name,
            "/tr",
            task_cmd,
            "/sc",
            "once",
            "/st",
            "23:59",
            "/it",
            "/rl",
            TASK_RUN_LEVEL,
            "/f",
        ]
    )
    if create.returncode != 0:
        return False, RunResult(
            returncode=create.returncode,
            stdout_lines=create.stdout.splitlines(),
            stderr_lines=create.stderr.splitlines(),
            tracked_children=set(),
        )

    run = _run_schtasks(["schtasks", "/run", "/tn", task_name])
    if run.returncode != 0:
        result = RunResult(
            returncode=run.returncode,
            stdout_lines=run.stdout.splitlines(),
            stderr_lines=run.stderr.splitlines(),
            tracked_children=set(),
        )
        return _fail_on_cleanup(False, result, [], _delete_windows_task(task_name)), result

    matched = False
    timed_out = False
    deadline = time.monotonic() + timeout_sec
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []

    try:
        while time.monotonic() < deadline:
            stdout_lines = _read_file_lines(stdout_path)
            stderr_lines = _read_file_lines(stderr_path)
            proc = ScheduledTaskProcess(pid=None, returncode=harness_exit_code(stdout_lines))
            if condition(stdout_lines, stderr_lines, proc):
                matched = True
                break
            if proc.returncode is not None:
                break
            time.sleep(0.1)
        else:
            timed_out = True
    finally:
        # still running (matched or not): end it through its job, as the ps1 runner does
        stop_requested = harness_exit_code(stdout_lines) is None
        census, stop_notes = _settle_job(task_name, job_path, stop_path, stop_requested)
        delete_error = _delete_windows_task(task_name)

    stdout_lines = _read_file_lines(stdout_path)
    stderr_lines = _read_file_lines(stderr_path)
    returncode = None if stop_requested else harness_exit_code(stdout_lines)
    result = RunResult(
        returncode=returncode if returncode is not None else (0 if matched else 1),
        stdout_lines=stdout_lines,
        stderr_lines=stderr_lines,
        tracked_children=set(),
        timed_out=timed_out,
    )
    return _fail_on_cleanup(matched, result, stop_notes, delete_error, _census_problem(census, stop_requested)), result


def run_windows_interactive_to_exit(
    cmd: list[str],
    env: dict[str, str],
    timeout_sec: float,
    cwd: Path | None = None,
) -> RunResult:
    matched, result = run_windows_interactive_until(
        cmd,
        env,
        timeout_sec,
        lambda _stdout, _stderr, proc: proc.poll() is not None,
        cwd=cwd,
    )
    if not matched and result.returncode == 0:
        result.returncode = 1
    return result


def print_fail_context(label: str, result: RunResult) -> None:
    eprint(f"{label}: return={result.returncode} tracked_children={sorted(result.tracked_children)}")
    eprint("stdout:\n" + "\n".join(result.stdout_lines))
    eprint("stderr:\n" + "\n".join(result.stderr_lines))
