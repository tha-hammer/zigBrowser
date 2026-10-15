"""The hook filter probe (chat-drawer plan rev 16.2, §3c.6; S3n2). A hook runs it as

    /usr/bin/python3 -I -S hook_filter_probe.py <out.json>

and it records, without raising, what the hook's seccomp filter lets it do:
- the denied calls: unshare(CLONE_NEWUSER), setns, mount, io_uring_setup,
  clone with CLONE_NEWUSER, and clone3 (which must say ENOSYS so glibc falls
  back to clone);
- what must keep working: fork, a subprocess, and threads;
- the descriptors it holds (only 0, 1 and 2 may be open), and where every
  descriptor of every process it can see points (bwrap's PID 1 included):
  the token-descriptor census.
Each result is {"ok": bool, "errno": name or None}. Standard library only."""

import ctypes
import errno
import json
import os
import subprocess
import sys
import threading

LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.syscall.restype = ctypes.c_long
CLONE_NEWUSER, SIGCHLD = 0x10000000, 17
NR = {"setns": 308, "io_uring_setup": 425, "clone": 56, "clone3": 435}


def result(ret):
    if ret >= 0:
        return {"ok": True, "errno": None}
    return {"ok": False, "errno": errno.errorcode.get(ctypes.get_errno(), str(ctypes.get_errno()))}


def raw_clone_newuser():
    """clone(CLONE_NEWUSER | SIGCHLD) with no new stack: the child continues like a fork and exits."""
    pid = LIBC.syscall(NR["clone"], ctypes.c_ulong(CLONE_NEWUSER | SIGCHLD), 0, 0, 0, 0)
    if pid == 0:
        os._exit(0)
    if pid > 0:
        os.waitpid(pid, 0)
    return result(pid)


def io_uring():
    params = ctypes.create_string_buffer(120)
    fd = LIBC.syscall(NR["io_uring_setup"], 1, params)
    if fd >= 0:
        os.close(fd)
    return result(fd)


def forked():
    pid = os.fork()
    if pid == 0:
        os._exit(7)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 7


def threaded():
    seen = []
    t = threading.Thread(target=seen.append, args=(1,))
    t.start()
    t.join()
    return seen == [1]


def open_fds():
    fds = []
    for fd in range(3, 1024):
        try:
            os.fstat(fd)
        except OSError:
            continue
        fds.append(fd)
    return fds


def fd_links():
    """[pid, fd, target] for every descriptor of every process in this PID namespace."""
    links = []
    for pid in sorted(int(p) for p in os.listdir("/proc") if p.isdigit()):
        try:
            fds = os.listdir(f"/proc/{pid}/fd")
        except OSError as exc:
            links.append([pid, None, errno.errorcode.get(exc.errno, str(exc.errno))])
            continue
        for fd in fds:
            try:
                links.append([pid, int(fd), os.readlink(f"/proc/{pid}/fd/{fd}")])
            except OSError:
                pass
    return links


def main(out):
    fds = open_fds()  # first, before this probe opens anything of its own
    record = {
        "fds_above_2": fds,
        "fd_links": fd_links(),
        "unshare_newuser": result(LIBC.unshare(CLONE_NEWUSER)),
        "setns": result(LIBC.syscall(NR["setns"], -1, 0)),
        "mount": result(LIBC.mount(b"none", b"/tmp", b"tmpfs", 0, None)),
        "io_uring_setup": io_uring(),
        "clone_newuser": raw_clone_newuser(),
        "clone3": result(LIBC.syscall(NR["clone3"], None, 0)),
        "fork": forked(),
        "subprocess": subprocess.run(["/usr/bin/true"]).returncode == 0,
        "thread": threaded(),
    }
    with open(out, "w") as f:
        json.dump(record, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
