"""Proof that a test runs inside a PRIVATE PID namespace before it signals real processes (RoseCat 7422).

The launcher records its own PID-namespace inode before unshare and passes it in ZB_OUTER_PIDNS, e.g.
  outer=$(readlink /proc/self/ns/pid); unshare --user --map-root-user --pid --fork --mount-proc \\
    sh -c "setsid env ZB_OUTER_PIDNS=$outer python -m unittest ..."
Inside, this process's own /proc/self/ns/pid must differ from it, and pid 1 must be that launcher's shell or unshare
(never the host's init). Either missing means: not provably private, so the caller skips.
"""
import os


def private_pid_namespace():
    """(True, "") when provably inside a private PID namespace; else (False, why)."""
    outer = os.environ.get("ZB_OUTER_PIDNS", "")
    if not outer.startswith("pid:["):
        return False, "no ZB_OUTER_PIDNS from the launcher"
    try:
        inner = os.readlink("/proc/self/ns/pid")
        with open("/proc/1/comm") as f:
            init = f.read().strip()
    except OSError as exc:
        return False, f"cannot read the namespace: {exc}"
    if inner == outer:
        return False, "the PID namespace is the launcher's own"
    if init not in {"sh", "dash", "bash", "unshare"}:
        return False, f"pid 1 is {init!r}, not the namespace's launcher"
    return True, ""
