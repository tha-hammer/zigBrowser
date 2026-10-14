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

A record is written only if the notification is still valid after it was read
(NOTIF_ID_VALID). Each record: seq, pid and ancestors (host PIDs, the parent chain while the exec
waits), argv, path (as passed to exec), real (resolved against the caller's
cwd), exists (a regular file there; an exec of a missing path, as in a PATH
search, runs nothing). The supervisor is double-forked before the filter
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


def _read_cstring(pid, addr, limit=4096):
    try:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as mem:
            mem.seek(addr)
            data = mem.read(limit)
    except (OSError, ValueError, OverflowError):
        return None
    return data.split(b"\0", 1)[0].decode("utf-8", "replace")


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


def _read_argv(pid, addr, limit=64):
    """The exec's argv: a NULL-terminated array of string pointers in the caller's memory."""
    argv = []
    try:
        with open(f"/proc/{pid}/mem", "rb", buffering=0) as mem:
            for i in range(limit):
                mem.seek(addr + 8 * i)
                ptr = struct.unpack("<Q", mem.read(8))[0]
                if ptr == 0:
                    break
                argv.append(_read_cstring(pid, ptr, 512))
    except (OSError, ValueError, OverflowError, struct.error):
        pass
    return argv


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
        poller = select.poll()
        poller.register(listener, select.POLLIN)
        while True:
            events = poller.poll()
            if any(ev & (select.POLLHUP | select.POLLERR) and not ev & select.POLLIN for _fd, ev in events):
                return
            buf = ctypes.create_string_buffer(NOTIF.size)
            if libc.ioctl(listener, NOTIF_RECV, buf) != 0:
                continue  # the caller died between notify and receive
            nid, pid, _flags, nr, _arch, _ip, *args = NOTIF.unpack(buf.raw)
            path_arg, argv_arg = (args[0], args[1]) if nr == NR_EXECVE else (args[1], args[2])
            path = _read_cstring(pid, path_arg)
            seq += 1
            real = _resolve(pid, path)
            chain = _ancestors(pid)
            # Still the same waiting exec? (The caller may have died, and its PID been
            # reused, while we read its memory.) If not, nothing ran: no record.
            if libc.ioctl(listener, NOTIF_ID_VALID, ctypes.byref(ctypes.c_uint64(nid))) != 0:
                continue
            log.write(json.dumps({"seq": seq, "pid": pid, "ppid": chain[0] if chain else None, "ancestors": chain,
                                  "path": path, "real": real, "exists": bool(real) and os.path.isfile(real),
                                  "argv": _read_argv(pid, argv_arg)}) + "\n")
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
