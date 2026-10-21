"""macOS process inspection for setup's R1 probe (BlueBeaver 6977; RoseCat 6958): macOS has no /proc, so the probe
finds its CLI descendants with libproc and reads each one's arguments and environment with sysctl KERN_PROCARGS2.
Pure stdlib (ctypes), so it also runs on a Mac without the SDK (tests/mac/ms5_r1_env_gate.sh).

macOS returns another same-user process's environment for an ordinary binary, hardened runtime included, but hides
it for some Apple platform binaries (macOS 15.3, Intel): the probe's verdict therefore requires a canary entry in
the parsed environment and never treats a hidden environment as clean."""

import ctypes
import ctypes.util
import os
import struct

_CTL_KERN = 1
_KERN_PROCARGS2 = 49
_PATH_MAX = 4096
_ARGC = struct.Struct("=i")

_libc = None
_libproc = None


def _libs():
    global _libc, _libproc
    if _libc is None:
        _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        _libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    return _libc, _libproc


def _oserror(what):
    err = ctypes.get_errno() or 1
    return OSError(err, f"{what}: {os.strerror(err)}")


def children(pid):
    """The direct children of `pid` (proc_listchildpids). OSError when the call fails."""
    _, libproc = _libs()
    for _ in range(4):
        n = libproc.proc_listchildpids(pid, None, 0)
        if n < 0:
            raise _oserror(f"proc_listchildpids({pid})")
        cap = max(n * 2, 16)
        arr = (ctypes.c_int * cap)()
        got = libproc.proc_listchildpids(pid, arr, ctypes.sizeof(arr))
        if got < 0:
            raise _oserror(f"proc_listchildpids({pid})")
        if got < cap:
            return [arr[i] for i in range(got) if arr[i] > 0]
    raise OSError(f"proc_listchildpids({pid}): the child list kept growing")


def path(pid):
    """The executable path of `pid` (proc_pidpath), or None when it cannot be read."""
    _, libproc = _libs()
    buf = ctypes.create_string_buffer(_PATH_MAX)
    if libproc.proc_pidpath(pid, buf, _PATH_MAX) <= 0:
        return None
    return os.fsdecode(buf.value)


def procargs2(pid):
    """The raw KERN_PROCARGS2 buffer of `pid`. OSError when the read fails."""
    libc, _ = _libs()
    mib = (ctypes.c_int * 3)(_CTL_KERN, _KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        raise _oserror(f"sysctl KERN_PROCARGS2({pid})")
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        raise _oserror(f"sysctl KERN_PROCARGS2({pid})")
    return buf.raw[:size.value]


def parse_procargs2(raw):
    """(argv, env) from a KERN_PROCARGS2 buffer: argc, the exec path, NUL padding, argc argv strings, then the
    environment up to the first empty string. None when the buffer does not hold that shape: never a guess."""
    if len(raw) < _ARGC.size:
        return None
    (argc,) = _ARGC.unpack_from(raw)
    if argc < 0:
        return None
    end = raw.find(b"\0", _ARGC.size)
    if end < 0:
        return None
    pos = end
    while pos < len(raw) and raw[pos] == 0:
        pos += 1
    argv = []
    for _ in range(argc):
        end = raw.find(b"\0", pos)
        if end < 0:
            return None
        argv.append(raw[pos:end])
        pos = end + 1
    env = []
    while pos < len(raw):
        end = raw.find(b"\0", pos)
        if end < 0 or end == pos:
            break
        env.append(raw[pos:end])
        pos = end + 1
    return argv, env


def environ_of(pid):
    """(raw, argv, env) for `pid`. OSError when the read fails or the buffer does not parse."""
    raw = procargs2(pid)
    parsed = parse_procargs2(raw)
    if parsed is None:
        raise OSError(f"KERN_PROCARGS2({pid}): the buffer does not parse")
    return (raw, *parsed)


def descendants_running(exe, root):
    """Every descendant of `root` whose executable path is `exe` (a breadth-first walk; each pid visited once)."""
    found, seen, queue = [], {root}, [root]
    while queue:
        pid = queue.pop(0)
        try:
            kids = children(pid)
        except OSError:
            continue
        for kid in kids:
            if kid in seen:
                continue
            seen.add(kid)
            queue.append(kid)
            if path(kid) == exe:
                found.append(kid)
    return found
