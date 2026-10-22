"""Kernel proof that a test runs in a PID namespace below its launcher's, before it signals real processes (RoseCat
7422, 7433: a string naming a namespace, or a PID 1 called sh, is not proof).

The launcher opens its own PID namespace as an inherited fd BEFORE unshare and names that fd in ZB_OUTER_PIDNS_FD:
  sh -c 'exec 9</proc/self/ns/pid; exec unshare --user --map-root-user --pid --fork --mount-proc \\
    sh -c "\\"\\$@\\"; :" sh env ZB_OUTER_PIDNS_FD=9 python -m unittest ...'
(a shell stays pid 1, so orphans are adopted by it, never by the test process: as in production)
The guard arms only when all hold:
- the fd is a PID namespace (ioctl NS_GET_NSTYPE == CLONE_NEWPID);
- it is not this process's own PID namespace (st_dev/st_ino differ);
- this process's pid translates INTO it (ioctl NS_GET_TGID_IN_PIDNS), which the kernel allows only for an ancestor of
  this process's namespace; with the inodes differing, a strict ancestor: this process cannot signal outside a
  namespace nested below the one the launcher held;
- defense in depth: pid 1 is this process or its parent (unshare --fork's shape).
NS_GET_PARENT cannot be used: the parent namespace is outside the caller's scope (EPERM, measured inside and outside).
Anything missing, malformed, unsupported or ambiguous does not arm.
"""
import fcntl
import os

_NS_GET_NSTYPE = 0xB703  # _IO(0xb7, 0x3)
_NS_GET_TGID_IN_PIDNS = 0x8004B709  # _IOR(0xb7, 0x9, int)
_CLONE_NEWPID = 0x20000000


def private_pid_namespace():
    """(True, "") on kernel proof of a PID namespace strictly below the launcher's held one; else (False, why)."""
    raw = os.environ.get("ZB_OUTER_PIDNS_FD", "")
    if not raw.isdigit() or raw != str(int(raw)) or int(raw) < 3:
        return False, "no held outer namespace fd from the launcher (ZB_OUTER_PIDNS_FD)"
    outer = int(raw)
    try:
        if fcntl.ioctl(outer, _NS_GET_NSTYPE) != _CLONE_NEWPID:
            return False, "ZB_OUTER_PIDNS_FD is not a PID namespace"
        held = os.fstat(outer)
        own_fd = os.open("/proc/self/ns/pid", os.O_RDONLY | os.O_CLOEXEC)
        try:
            own = os.fstat(own_fd)
        finally:
            os.close(own_fd)
        if (held.st_dev, held.st_ino) == (own.st_dev, own.st_ino):
            return False, "the held namespace is this process's own"
        fcntl.ioctl(outer, _NS_GET_TGID_IN_PIDNS, os.getpid())  # ESRCH unless the held one is an ancestor
    except OSError as exc:
        return False, f"no kernel proof: {exc.strerror or exc}"
    if 1 not in (os.getpid(), os.getppid()):
        return False, "pid 1 is neither this process nor its parent"
    return True, ""
