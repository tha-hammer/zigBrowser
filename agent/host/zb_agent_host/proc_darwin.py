"""macOS process inspection for setup's R1 probe (BlueBeaver 6977; RoseCat 6958): macOS has no /proc, so the probe
finds its CLI descendants with libproc and reads each one's arguments and environment with sysctl KERN_PROCARGS2.
Pure stdlib (ctypes), so it also runs on a Mac without the SDK (tests/mac/ms5_r1_env_gate.sh).

macOS returns another same-user process's environment for an ordinary binary, hardened runtime included, but hides
it for some Apple platform binaries (macOS 15.3, Intel): the probe's verdict therefore requires a canary entry in
the parsed environment and never treats a hidden environment as clean."""

import ctypes
import ctypes.util
import errno
import os
import struct

_CTL_KERN = 1
_KERN_PROCARGS2 = 49
_PATH_MAX = 4096
_ARGC = struct.Struct("=i")
# The census's fixed, token-free reasons (RoseCat 7986): a reason never names a pid, path, argv, environment value,
# the token or exception text, so it can be logged as-is.
CENSUS_REASONS = ("ok", "walk-unreadable", "cli-not-found", "env-unreadable", "canary-missing", "token-found")

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


def _listchildpids(libproc, pid, buf, size):
    """One proc_listchildpids call. libproc turns a failed __proc_info into a return of 0 with errno set (Apple's
    libproc.c, proc_listpids; RoseCat 7015), so errno is cleared first and read right after: 0 with errno 0 is a
    real empty list, and 0 (or less) with errno set is a failure (ESRCH maps to ProcessLookupError)."""
    ctypes.set_errno(0)
    n = libproc.proc_listchildpids(pid, buf, size)
    err = ctypes.get_errno()
    if n < 0 or (n == 0 and err != 0):
        raise OSError(err or errno.EIO, f"proc_listchildpids({pid}): {os.strerror(err or errno.EIO)}")
    return n


def children(pid):
    """The direct children of `pid` (proc_listchildpids). ProcessLookupError when `pid` has vanished (ESRCH); any
    other failure is another OSError."""
    _, libproc = _libs()
    for _ in range(4):
        n = _listchildpids(libproc, pid, None, 0)
        cap = max(n * 2, 16)
        arr = (ctypes.c_int * cap)()
        got = _listchildpids(libproc, pid, arr, ctypes.sizeof(arr))
        if got < cap:
            return [arr[i] for i in range(got) if arr[i] > 0]
    raise OSError(f"proc_listchildpids({pid}): the child list kept growing")


def path(pid):
    """The executable path of `pid` (proc_pidpath), or None when `pid` has vanished (ESRCH). Any other failure is an
    OSError (RoseCat 7011): an unreadable path is never "not the CLI"."""
    _, libproc = _libs()
    buf = ctypes.create_string_buffer(_PATH_MAX)
    ctypes.set_errno(0)  # no stale errno can decide the verdict (RoseCat 7015)
    if libproc.proc_pidpath(pid, buf, _PATH_MAX) <= 0:
        err = ctypes.get_errno()
        if err == errno.ESRCH:
            return None
        raise OSError(err or errno.EIO, f"proc_pidpath({pid}): {os.strerror(err or errno.EIO)}")
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


def cli_env_clean(exe, root, token, canary):
    """Setup's R1 census verdict (RoseCat 7019; BlueBeaver 7021): run by setup OUTSIDE Seatbelt over its own
    descendants (`root`), never by the probe or the CLI it tests. True only when cli_env_census says "ok"."""
    return cli_env_census(exe, root, token, canary) == "ok"


def cli_env_census(exe, root, token, canary):
    """The census's reason, one of CENSUS_REASONS (RoseCat 7986): "ok" only when at least one descendant runs `exe`,
    the walk inspected every descendant (a denied listing or path is not clean; RoseCat 7011), and each CLI's
    KERN_PROCARGS2 reads and parses, holds the `token` bytes nowhere, argv included, and holds the exact `canary` entry
    in its environment (an environment the OS hid is never "clean"). A CLI whose buffer cannot be read is
    env-unreadable even when it vanished: only the walk may skip a vanished process."""
    try:
        pids = descendants_running(exe, root)
    except OSError:
        return "walk-unreadable"
    if not pids:
        return "cli-not-found"
    for pid in pids:
        try:
            raw, _argv, env = environ_of(pid)
        except OSError:
            return "env-unreadable"
        if token in raw:
            return "token-found"
        if canary not in env:
            return "canary-missing"
    return "ok"


def descendants_running(exe, root):
    """Every descendant of `root` whose executable path is `exe` (a breadth-first walk; each pid visited once).
    Only a vanished process is skipped, and only when that is confirmed: ESRCH (children() raises ProcessLookupError,
    path() returns None), or a failed lookup whose immediate re-probe says ESRCH. A denied child list or an unreadable
    path otherwise raises OSError, so the caller never mistakes an uninspected subtree for an empty one (RoseCat 7011,
    7986)."""
    found, seen, queue = [], {root}, [root]
    while queue:
        pid = queue.pop(0)
        try:
            kids = children(pid)
        except ProcessLookupError:
            if pid == root:  # the census root never vanishes: ESRCH on it is a failed walk (RoseCat 7995 #1)
                raise
            continue
        except OSError:
            if pid != root and path(pid) is None:  # the re-probe confirms it vanished; the root never does
                continue
            raise
        for kid in kids:
            if kid in seen:
                continue
            seen.add(kid)
            try:
                kid_path = path(kid)
            except OSError:
                if path(kid) is None:  # vanished between children() and path(), confirmed by the re-probe
                    continue
                raise OSError(f"proc_pidpath({kid}): unreadable") from None
            queue.append(kid)
            if kid_path == exe:
                found.append(kid)
    return found
