"""VM-side driver for the live Job Object containment test (bead zigBrowser-d1d, part 2).

Exercises the real `wincontain_win32.launch_in_job` on Windows and reports what the OS actually did, so a
Linux test can assert the containment contract against the real API:

    python jobobject_oracle.py <mode>        # mode: "correct" | "noflag"

  * correct  -> job carries KILL_ON_JOB_CLOSE; the child is created suspended, assigned, resumed.
  * noflag   -> same sequence but WITHOUT KILL_ON_JOB_CLOSE (a negative control: the child must survive the
               job handle closing, proving the flag is what kills).

The direct child is `cmd.exe`, which spawns `ping.exe` as a DESCENDANT inside the same job. To prove the
contract's real claim — *every* process in the job dies when the job handle closes, not only the direct
child — the driver finds that descendant by parent PID (Toolhelp snapshot) and reports whether it, too, is
gone after close. In `correct` mode the descendant must die; in `noflag` it must survive (then the driver
cleans up both so nothing lingers on the VM).

Prints on stdout:
  {"mode","pid","in_job","running_before_close","killed_on_close",
   "descendant_pid","descendant_found","descendant_running_before_close","descendant_killed_on_close"}
"""
import ctypes
import json
import pathlib
import sys
import time
from ctypes import wintypes

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wincontain_win32 as wj  # noqa: E402

# A benign ~30 s sleeper; kill-on-close (correct mode) ends it at once, so the test never waits that long.
# `> nul` keeps the child's output off this driver's stdout, which must be JSON only. cmd.exe spawns ping.exe
# as a child process (a true descendant), which is what lets us prove the whole job tree dies.
_CHILD = r"C:\Windows\System32\cmd.exe /c ping -n 30 127.0.0.1 > nul"

_TH32CS_SNAPPROCESS = 0x00000002
_INVALID_HANDLE = ctypes.c_void_p(-1).value

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]


_CreateToolhelp32Snapshot = _k32.CreateToolhelp32Snapshot
_CreateToolhelp32Snapshot.restype = wintypes.HANDLE
_CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
_Process32FirstW = _k32.Process32FirstW
_Process32FirstW.restype = wintypes.BOOL
_Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]
_Process32NextW = _k32.Process32NextW
_Process32NextW.restype = wintypes.BOOL
_Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_PROCESSENTRY32W)]


def _snapshot():
    """[(pid, parent_pid, exe_lower)] of every process now, from a Toolhelp snapshot."""
    snap = _CreateToolhelp32Snapshot(_TH32CS_SNAPPROCESS, 0)
    if not snap or ctypes.cast(snap, ctypes.c_void_p).value == _INVALID_HANDLE:
        raise OSError(f"CreateToolhelp32Snapshot failed (GetLastError={ctypes.get_last_error()})")
    try:
        entry = _PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
        rows = []
        ok = _Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            rows.append((entry.th32ProcessID, entry.th32ParentProcessID, entry.szExeFile.lower()))
            ok = _Process32NextW(snap, ctypes.byref(entry))
        return rows
    finally:
        wj._CloseHandle(snap)


def _find_descendant(parent_pid, exe="ping.exe", attempts=30, delay=0.1):
    """PID of the first `exe` whose parent is parent_pid, or None. Polls: the spawn is not instant."""
    for _ in range(attempts):
        for pid, ppid, name in _snapshot():
            if ppid == parent_pid and name == exe:
                return pid
        time.sleep(delay)
    return None


def _is_alive(pid, exe="ping.exe"):
    """True if a process with this exact PID and image name exists now (guards against PID reuse)."""
    return any(p == pid and name == exe for p, _, name in _snapshot())


def main():
    mode = sys.argv[1]
    kill = (mode != "noflag")
    child = wj.launch_in_job(_CHILD, kill_on_close=kill)

    desc_pid = _find_descendant(child.pid)
    out = {
        "mode": mode,
        "pid": child.pid,
        "in_job": child.is_in_job(),
        "running_before_close": child.still_running(),
        "descendant_pid": desc_pid,
        "descendant_found": desc_pid is not None,
        "descendant_running_before_close": _is_alive(desc_pid) if desc_pid is not None else False,
    }
    # A short wait bounds the noflag case (the child is expected to survive); kill-on-close is near-instant.
    out["killed_on_close"] = child.close_job_and_wait(2000)
    # Give the OS a moment to tear down the descendant after the job handle dropped, then check it directly.
    if desc_pid is not None:
        desc_gone = False
        for _ in range(20):
            if not _is_alive(desc_pid):
                desc_gone = True
                break
            time.sleep(0.1)
        out["descendant_killed_on_close"] = desc_gone
    else:
        out["descendant_killed_on_close"] = False

    # Clean up anything that outlived the job (noflag, by design) so nothing lingers on the VM.
    if child.still_running():
        wj._TerminateProcess(child.hprocess, 1)
    if desc_pid is not None and _is_alive(desc_pid):
        _PROCESS_TERMINATE = 0x0001
        h = _k32.OpenProcess(_PROCESS_TERMINATE, False, desc_pid)
        if h:
            _k32.TerminateProcess(h, 1)
            wj._CloseHandle(h)
    child.close_handles()
    print(json.dumps(out))


if __name__ == "__main__":
    main()
