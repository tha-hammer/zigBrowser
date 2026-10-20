#!/usr/bin/python3 -I
"""Contract-only probe for the outer seccomp filter (P0.6): what ptrace and
process_vm_* give this process, and its seccomp mode.

Each call is harmless when allowed, and runs in a throwaway child where it
could change process state:
- ptrace_attach: a child attaches to its sibling (a sleeper);
- ptrace_traceme: a child asks to be traced by us;
- process_vm_readv: we read one byte of our own child;
- process_vm_writev: we write one byte into our own memory.
Under the filter each gives EPERM. Standard library only, so a hook can run it
with /usr/bin/python3 -I.
"""

import ctypes
import errno
import json
import os
import signal
import sys
import time


class NotOnWindows(RuntimeError):
    """WS7.5 (AzureRidge 6335): this POSIX-only script was reached on Windows (the same error as
    zb_agent_host.platforms.NotOnWindows; this file runs by path, outside the package)."""


def _posix_only():
    if sys.platform == "win32":
        raise NotOnWindows("zb_agent_host probe: not available on Windows yet")

PTRACE_TRACEME, PTRACE_ATTACH = 0, 16
NR_PROCESS_VM_READV, NR_PROCESS_VM_WRITEV = 310, 311

_libc = ctypes.CDLL(None, use_errno=True)
_libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
_libc.ptrace.restype = ctypes.c_long
_libc.syscall.restype = ctypes.c_long


class _Iovec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def _name(result, err):
    return "OK" if result >= 0 else errno.errorcode.get(err, str(err))


def _call(fn, *args):
    ctypes.set_errno(0)
    result = fn(*args)
    return _name(result, ctypes.get_errno())


def _in_child(action):
    """Runs action() in a forked child and returns the name it reports."""
    _posix_only()  # WS7.5: fork/exec
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            os.write(w, action().encode())
        finally:
            os._exit(0)
    os.close(w)
    out = os.read(r, 64).decode()
    os.close(r)
    os.waitpid(pid, 0)
    return out


def _sleeper():
    _posix_only()  # WS7.5: fork/exec
    pid = os.fork()
    if pid == 0:
        time.sleep(30)
        os._exit(0)
    return pid


def _vm(nr, pid, local_buf, remote_buf):
    local = _Iovec(ctypes.cast(local_buf, ctypes.c_void_p), 1)
    remote = _Iovec(ctypes.cast(remote_buf, ctypes.c_void_p), 1)
    # syscall() is variadic: every argument is passed as a full 64-bit value.
    return _call(_libc.syscall, ctypes.c_long(nr), ctypes.c_long(pid), ctypes.byref(local), ctypes.c_ulong(1),
                 ctypes.byref(remote), ctypes.c_ulong(1), ctypes.c_ulong(0))


def seccomp_mode():
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("Seccomp:"):
                return int(line.split()[1])
    return None


def syscalls():
    shared = ctypes.create_string_buffer(b"z")  # same address in a forked child
    scratch = ctypes.create_string_buffer(1)
    sibling = _sleeper()
    try:
        result = {
            "ptrace_attach": _in_child(lambda: _call(_libc.ptrace, PTRACE_ATTACH, sibling, None, None)),
            "ptrace_traceme": _in_child(lambda: _call(_libc.ptrace, PTRACE_TRACEME, 0, None, None)),
            "process_vm_readv": _vm(NR_PROCESS_VM_READV, sibling, scratch, shared),
            "process_vm_writev": _vm(NR_PROCESS_VM_WRITEV, os.getpid(), shared, scratch),
        }
    finally:
        os.kill(sibling, signal.SIGKILL)
        os.waitpid(sibling, 0)
    result["seccomp"] = seccomp_mode()
    return result


if __name__ == "__main__":
    print(json.dumps(syscalls()))
