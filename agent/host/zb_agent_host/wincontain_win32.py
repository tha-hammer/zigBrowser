"""Live Windows containment backend (bead zigBrowser-d1d, part 2): the Job Object launch sequence behind
`wincontain.Containment(create_suspended=True, kill_on_close=True)`.

Windows has no process-namespace sandbox, so the agent child is confined in a **Job Object**. The sequence
MUST be: create the child **suspended**, **assign** it to the job, and only **then resume** it — so the child
is already inside the job before it runs and cannot spawn or escape first. The job carries
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so when the browser drops the job handle (or exits) every process in
the job is terminated and nothing outlives the drawer.

Windows-only (ctypes + kernel32); import it only on win32. The pure decision of *what* to do lives in
`wincontain.py`; this module *does* it. No policy here beyond the launch mechanics.
"""
import ctypes
from ctypes import wintypes

_k32 = ctypes.WinDLL("kernel32", use_last_error=True)

# --- flags / constants ----------------------------------------------------------------------------------
CREATE_SUSPENDED = 0x00000004
_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
_JobObjectExtendedLimitInformation = 9
_INVALID_HANDLE = ctypes.c_void_p(-1).value
_STILL_ACTIVE = 259
_WAIT_OBJECT_0 = 0x0
_ULONG_PTR = ctypes.c_size_t


class _STARTUPINFO(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                ("lpReserved2", ctypes.c_void_p), ("hStdInput", wintypes.HANDLE),
                ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]


class _PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]


class _IO_COUNTERS(ctypes.Structure):
    _fields_ = [(n, ctypes.c_ulonglong) for n in
                ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                 "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]


class _JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", _ULONG_PTR), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]


class _JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [("BasicLimitInformation", _JOBOBJECT_BASIC_LIMIT_INFORMATION), ("IoInfo", _IO_COUNTERS),
                ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]


_CreateJobObjectW = _k32.CreateJobObjectW
_CreateJobObjectW.restype = wintypes.HANDLE
_CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
_SetInformationJobObject = _k32.SetInformationJobObject
_SetInformationJobObject.restype = wintypes.BOOL
_SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
_AssignProcessToJobObject = _k32.AssignProcessToJobObject
_AssignProcessToJobObject.restype = wintypes.BOOL
_AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
_CreateProcessW = _k32.CreateProcessW
_CreateProcessW.restype = wintypes.BOOL
_CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                            wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                            ctypes.c_void_p, ctypes.c_void_p]
_ResumeThread = _k32.ResumeThread
_ResumeThread.restype = wintypes.DWORD
_ResumeThread.argtypes = [wintypes.HANDLE]
_IsProcessInJob = _k32.IsProcessInJob
_IsProcessInJob.restype = wintypes.BOOL
_IsProcessInJob.argtypes = [wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)]
_CloseHandle = _k32.CloseHandle
_CloseHandle.restype = wintypes.BOOL
_CloseHandle.argtypes = [wintypes.HANDLE]
_WaitForSingleObject = _k32.WaitForSingleObject
_WaitForSingleObject.restype = wintypes.DWORD
_WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
_GetExitCodeProcess = _k32.GetExitCodeProcess
_GetExitCodeProcess.restype = wintypes.BOOL
_GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
_TerminateProcess = _k32.TerminateProcess
_TerminateProcess.restype = wintypes.BOOL
_TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]


class ContainmentError(Exception):
    """A Win32 call in the launch sequence failed — fail closed, never an unconfined child."""


class ContainedChild:
    """A child launched inside a kill-on-close Job Object. Close() drops the job handle, which terminates
    every process in the job (kill-on-close). The child/thread handles are closed too."""

    def __init__(self, job, hprocess, hthread, pid):
        self.job = job
        self.hprocess = hprocess
        self.hthread = hthread
        self.pid = pid

    def is_in_job(self):
        res = wintypes.BOOL(0)
        if not _IsProcessInJob(self.hprocess, self.job, ctypes.byref(res)):
            raise ContainmentError(f"IsProcessInJob failed (GetLastError={ctypes.get_last_error()})")
        return bool(res.value)

    def exit_code(self):
        code = wintypes.DWORD(0)
        if not _GetExitCodeProcess(self.hprocess, ctypes.byref(code)):
            raise ContainmentError(f"GetExitCodeProcess failed (GetLastError={ctypes.get_last_error()})")
        return code.value

    def still_running(self):
        return self.exit_code() == _STILL_ACTIVE

    def close_job_and_wait(self, timeout_ms=4000):
        """Drop the job handle (kill-on-close terminates the child), then wait for the process to exit.
        Returns True if the process is gone within the timeout."""
        _CloseHandle(self.job)
        self.job = None
        return _WaitForSingleObject(self.hprocess, timeout_ms) == _WAIT_OBJECT_0

    def close_handles(self):
        for h in (self.hthread, self.hprocess, self.job):
            if h:
                _CloseHandle(h)
        self.hthread = self.hprocess = self.job = None


def launch_in_job(command_line, kill_on_close=True):
    """Launch `command_line` confined in a fresh Job Object: create suspended, assign to the job, resume.

    `kill_on_close` sets JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE so dropping the job handle kills the child (the
    production backend always wants this). Fails closed on any Win32 error (and never leaves a resumed-but-
    unassigned child: if assignment fails the suspended child is terminated before it can run)."""
    job = _CreateJobObjectW(None, None)
    if not job or ctypes.cast(job, ctypes.c_void_p).value == _INVALID_HANDLE:
        raise ContainmentError(f"CreateJobObjectW failed (GetLastError={ctypes.get_last_error()})")
    try:
        if kill_on_close:
            info = _JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
            info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not _SetInformationJobObject(job, _JobObjectExtendedLimitInformation,
                                            ctypes.byref(info), ctypes.sizeof(info)):
                raise ContainmentError(f"SetInformationJobObject failed (GetLastError={ctypes.get_last_error()})")

        si = _STARTUPINFO()
        si.cb = ctypes.sizeof(si)
        pi = _PROCESS_INFORMATION()
        # CreateProcessW may modify the command-line buffer in place, so pass a mutable copy.
        cmd_buf = ctypes.create_unicode_buffer(command_line)
        if not _CreateProcessW(None, cmd_buf, None, None, False, CREATE_SUSPENDED, None, None,
                               ctypes.byref(si), ctypes.byref(pi)):
            raise ContainmentError(f"CreateProcessW failed (GetLastError={ctypes.get_last_error()})")

        # Assign WHILE suspended, before the child runs — so it (and anything it spawns) is in the job first.
        if not _AssignProcessToJobObject(job, pi.hProcess):
            err = ctypes.get_last_error()
            _TerminateProcess(pi.hProcess, 1)  # never resume an unassigned child
            _CloseHandle(pi.hThread)
            _CloseHandle(pi.hProcess)
            raise ContainmentError(f"AssignProcessToJobObject failed (GetLastError={err})")

        if _ResumeThread(pi.hThread) == 0xFFFFFFFF:
            err = ctypes.get_last_error()
            _TerminateProcess(pi.hProcess, 1)
            _CloseHandle(pi.hThread)
            _CloseHandle(pi.hProcess)
            raise ContainmentError(f"ResumeThread failed (GetLastError={err})")

        return ContainedChild(job, pi.hProcess, pi.hThread, pi.dwProcessId)
    except Exception:
        _CloseHandle(job)
        raise
