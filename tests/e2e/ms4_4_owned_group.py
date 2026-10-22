"""MS4.4's macOS browser lifetime (RoseCat 7886 #1): the browser as the leader of its own process group, stopped
exactly, and the driver's SIGTERM/SIGINT/SIGHUP cleanup. Stdlib only, so ms4_4_login_gate_cleanup_test can prove it
without the SDK or a browser."""
import os
import signal
import subprocess
import time

SEAM_PREFIXES = ("ZB_", "ZIGBROWSER_")


class OwnedGroup:
    """A child started as the leader of a new process group (start_new_session). stop() signals that exact group
    only while the leader is unreaped (so its pid, and so the group id, cannot have been reused): SIGTERM, a bounded
    grace observed without reaping (waitid WNOWAIT), SIGKILL to whatever of the group is left, then the leader is
    reaped. Idempotent; never signals anything once the leader is reaped. Plain POSIX, no /proc."""

    def __init__(self, argv, **kw):
        self.proc = subprocess.Popen(argv, start_new_session=True, **kw)
        self.status = None

    def _leader_exited(self) -> bool:
        if not hasattr(os, "waitid"):
            return False  # no way to look without reaping: wait the whole grace, then SIGKILL the group anyway
        try:
            return os.waitid(os.P_PID, self.proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        except ChildProcessError:
            return True

    def stop(self, grace_sec: float = 2.0):
        pid = self.proc.pid
        if self.status is None and self.proc.returncode is not None:
            self.status = self.proc.returncode  # reaped elsewhere (Popen.wait/poll): its pid may be reused now
        if self.status is not None or not isinstance(pid, int) or pid <= 1:
            return self.status
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pid, sig)
            except ProcessLookupError:
                break
            if sig == signal.SIGTERM:
                deadline = time.monotonic() + grace_sec
                while time.monotonic() < deadline and not self._leader_exited():
                    time.sleep(0.05)
        try:
            self.status = self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        return self.status


def install_cleanup(get_group) -> None:
    """SIGTERM, SIGINT and SIGHUP to the driver stop the owned group first, then the signal takes its default
    course (the driver's status names it)."""
    def handler(signum, _frame):
        group = get_group()
        if group is not None:
            group.stop()
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, handler)


def without_seams(env: dict) -> dict:
    return {k: v for k, v in env.items() if not k.startswith(SEAM_PREFIXES)}
