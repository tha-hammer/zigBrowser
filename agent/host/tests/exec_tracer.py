#!/usr/bin/python3 -I
"""Test-only exec census (D11, P0.5): a lifecycle-complete record of every program
run below the helper's sandbox, written outside the sandbox.

`exec_tracer.py LOG CMD [args...]` is the parent of the sandbox: it installs a
seccomp filter that turns every execve/execveat of itself and of all its
descendants (the helper, the CLI, hooks, nested namespaces) into a user
notification, hands the listener to a supervisor process, then execs CMD (the
sandbox's bwrap), so the death chain is unchanged. The supervisor records each
exec as one JSON line in LOG before letting it continue: no exec can happen
unseen, however short-lived its process, which snapshots of /proc can miss
(RoseCat's P0 blocker 1). A fork that never execs runs no new program and is
not recorded.

Rev 12 named a ptrace tracer for this oracle. A seccomp user notification gives
the same guarantee (every exec of every descendant stops until it is recorded)
from the same place, without tracing every thread and signal of the CLI.

The log starts with `START <supervisor pid>` and, once every traced process is
gone, ends with `END <record count>`; a log without END is red. If the
supervisor dies, the kernel fails every later exec with ENOSYS, so nothing runs
unrecorded. A record is written only if the notification is still valid after
it was read (NOTIF_ID_VALID). Each record: seq, pid and ancestors (host PIDs,
the parent chain while the exec waits), form (execve, or execveat with its
dirfd and flags), path and argv read in full (argv until its NULL, at most 4096
pointers; strings up to MAX_ARG_STRLEN; the path up to PATH_MAX), complete
(false when a bound was reached or a read failed), resolved (execve and the
plain execveat form, AT_FDCWD with flags 0, only), real (the path resolved
against the caller's cwd, when complete and resolved), exists (a regular file
there; an exec of a missing path, as in a PATH search, runs nothing).
Incomplete or unresolved records are UNEXPECTED to the census (census.py).
Stated limit: another thread could rewrite argv between this read and the
kernel's copy; the census watches the CLI's own behaviour, and the sandbox and
the seccomp filter are the boundary. The supervisor is double-forked before the filter
exists, so its listener reports POLLHUP once every traced process is gone.
Standard library only.
"""

import ctypes
import json
import os
import select
import socket
import struct
import sys

NR_SECCOMP, NR_EXECVE, NR_EXECVEAT = 317, 59, 322
PR_SET_NO_NEW_PRIVS = 38
SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER = 1, 1 << 3
AUDIT_ARCH_X86_64 = 0xC000003E
RET_ALLOW, RET_USER_NOTIF = 0x7FFF0000, 0x7FC00000
NOTIF_RECV, NOTIF_SEND, NOTIF_ID_VALID = 0xC0502100, 0xC0182101, 0x40082102
FLAG_CONTINUE = 1
AT_FDCWD = -100
MAX_ARGV = 4096          # pointers read before a record is called incomplete
MAX_ARG_STRLEN = 131072  # the kernel's limit for one argv string
PATH_MAX = 4096
PAGE = 4096
NOTIF = struct.Struct("<QIIiIQ6Q")  # id, pid, flags, nr, arch, ip, args[6]
RESP = struct.Struct("<QqiI")       # id, val, error, flags


class _Prog(ctypes.Structure):
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_char_p)]


def program():
    insns = [
        (0x20, 0, 0, 4),                  # A = arch
        (0x15, 0, 3, AUDIT_ARCH_X86_64),  # not x86_64 -> allow at 5 (the outer filter handles other ABIs)
        (0x20, 0, 0, 0),                  # A = nr
        (0x15, 2, 0, NR_EXECVE),          # -> notify
        (0x15, 1, 0, NR_EXECVEAT),        # -> notify
        (0x06, 0, 0, RET_ALLOW),
        (0x06, 0, 0, RET_USER_NOTIF),
    ]
    return b"".join(struct.pack("<HBBI", *i) for i in insns)


def _read_cstring(mem, addr, limit):
    """(text, complete): the NUL-terminated string at addr, read page by page. Incomplete
    when no NUL is found within `limit` bytes or the memory cannot be read."""
    data = b""
    try:
        while len(data) <= limit:
            mem.seek(addr + len(data))
            chunk = mem.read(PAGE - (addr + len(data)) % PAGE)
            if not chunk:
                break
            end = chunk.find(b"\0")
            if end >= 0:
                data += chunk[:end]
                return data.decode("utf-8", "replace"), len(data) <= limit
            data += chunk
    except (OSError, ValueError, OverflowError):
        pass
    return data[:limit].decode("utf-8", "replace"), False


def _ppid(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return int(f.read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        return None


def _ancestors(pid):
    """Parent, grandparent, ... up to PID 1 (the caller is stopped in exec, so its chain is stable)."""
    chain, seen = [], {pid}
    cur = _ppid(pid)
    while cur and cur not in seen:
        chain.append(cur)
        seen.add(cur)
        cur = _ppid(cur) if cur != 1 else None
    return chain


def _read_argv(mem, addr):
    """(argv, complete): the exec's NULL-terminated argv, every string read in full."""
    argv = []
    try:
        for i in range(MAX_ARGV + 1):
            mem.seek(addr + 8 * i)
            ptr = struct.unpack("<Q", mem.read(8))[0]
            if ptr == 0:
                return argv, True
            if i == MAX_ARGV:
                break
            text, complete = _read_cstring(mem, ptr, MAX_ARG_STRLEN)
            argv.append(text)
            if not complete:
                return argv, False
    except (OSError, ValueError, OverflowError, struct.error):
        pass
    return argv, False


def read_exec(pid, nr, args):
    """What a waiting execve/execveat asks to run. Only execve and the plain execveat form
    (dirfd AT_FDCWD, flags 0) are resolved; any other execveat is recorded unresolved."""
    if nr == NR_EXECVE:
        dirfd, path_arg, argv_arg, flags = AT_FDCWD, args[0], args[1], 0
    else:
        dirfd = ctypes.c_int(args[0] & 0xFFFFFFFF).value
        path_arg, argv_arg, flags = args[1], args[2], args[4] & 0xFFFFFFFF
    try:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as mem:
            path, path_ok = _read_cstring(mem, path_arg, PATH_MAX)
            argv, argv_ok = _read_argv(mem, argv_arg)
    except OSError:
        path, path_ok, argv, argv_ok = None, False, [], False
    resolved = nr == NR_EXECVE or (dirfd == AT_FDCWD and flags == 0)
    form = "execve" if nr == NR_EXECVE else f"execveat dirfd={dirfd} flags={flags:#x}"
    return {"path": path, "argv": argv, "complete": path_ok and argv_ok, "resolved": resolved, "form": form}


def _resolve(pid, path):
    """The executable's real path, resolved in the supervisor's mount namespace (the one
    non-hook processes share; hook processes are classified by ancestry, not path)."""
    if path is None:
        return None
    try:
        base = path if path.startswith("/") else os.path.join(os.readlink(f"/proc/{pid}/cwd"), path)
    except OSError:
        return path
    return os.path.realpath(base)


def supervise(listener, log_path):
    libc = ctypes.CDLL(None, use_errno=True)
    seq = 0
    with open(log_path, "a", buffering=1) as log:
        log.write(f"START {os.getpid()}\n")
        poller = select.poll()
        poller.register(listener, select.POLLIN)
        while True:
            events = poller.poll()
            if any(ev & (select.POLLHUP | select.POLLERR) and not ev & select.POLLIN for _fd, ev in events):
                log.write(f"END {seq}\n")  # every traced process is gone
                return
            buf = ctypes.create_string_buffer(NOTIF.size)
            if libc.ioctl(listener, NOTIF_RECV, buf) != 0:
                continue  # the caller died between notify and receive
            nid, pid, _flags, nr, _arch, _ip, *args = NOTIF.unpack(buf.raw)
            record = read_exec(pid, nr, args)
            real = _resolve(pid, record["path"]) if record["resolved"] and record["complete"] else None
            chain = _ancestors(pid)
            # Still the same waiting exec? (The caller may have died, and its PID been
            # reused, while we read its memory.) If not, nothing ran: no record.
            if libc.ioctl(listener, NOTIF_ID_VALID, ctypes.byref(ctypes.c_uint64(nid))) != 0:
                continue
            seq += 1
            log.write(json.dumps({"seq": seq, "pid": pid, "ppid": chain[0] if chain else None, "ancestors": chain,
                                  **record, "real": real, "exists": bool(real) and os.path.isfile(real)}) + "\n")
            resp = ctypes.create_string_buffer(RESP.pack(nid, 0, 0, FLAG_CONTINUE), RESP.size)
            libc.ioctl(listener, NOTIF_SEND, resp)


def main(argv):
    if len(argv) < 2:
        print("usage: exec_tracer.py LOG CMD [args...]", file=sys.stderr)
        return 2
    log_path, target = argv[0], argv[1]
    ours, theirs = socket.socketpair()
    child = os.fork()
    if child == 0:
        ours.close()
        if os.fork() != 0:
            os._exit(0)
        _msg, fds, _flags, _addr = socket.recv_fds(theirs, 1, 1)
        # The supervisor keeps only its listener and socket (not the token's fd 3,
        # the seccomp program or the helper's pipes).
        low = 3
        for keep in sorted({fds[0], theirs.fileno()}):
            os.closerange(low, keep)
            low = keep + 1
        os.closerange(low, os.sysconf("SC_OPEN_MAX"))
        theirs.sendall(b"r")
        theirs.close()
        try:
            supervise(fds[0], log_path)
        finally:
            os._exit(0)
    theirs.close()
    os.waitpid(child, 0)
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    ulong = ctypes.c_ulong  # prctl() and syscall() are variadic: pass full 64-bit values
    if libc.prctl(ctypes.c_int(PR_SET_NO_NEW_PRIVS), ulong(1), ulong(0), ulong(0), ulong(0)) != 0:
        raise OSError(ctypes.get_errno(), "prctl(NO_NEW_PRIVS)")
    data = program()
    prog = _Prog(len(data) // 8, data)
    listener = libc.syscall(ctypes.c_long(NR_SECCOMP), ulong(SECCOMP_SET_MODE_FILTER),
                            ulong(SECCOMP_FILTER_FLAG_NEW_LISTENER), ctypes.byref(prog))
    if listener < 0:
        raise OSError(ctypes.get_errno(), "seccomp(NEW_LISTENER)")
    socket.send_fds(ours, [b"l"], [listener])
    os.close(listener)
    if ours.recv(1) != b"r":
        return 1
    ours.close()
    os.execv(target, [target, *argv[2:]])
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
