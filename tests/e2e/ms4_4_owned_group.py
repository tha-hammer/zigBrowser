"""MS4.4's macOS browser lifetime (RoseCat 7886 #1): the browser as the leader of its own process group, stopped
exactly, and the driver's SIGTERM/SIGINT/SIGHUP cleanup. Stdlib only, so ms4_4_login_gate_cleanup_test can prove it
without the SDK or a browser."""
import os
import signal
import subprocess
import time

SEAM_PREFIXES = ("ZB_", "ZIGBROWSER_")
PS = ("/bin/ps", "-A", "-o", "pid=", "-o", "pgid=", "-o", "stat=")
CENSUS_TIMEOUT_S = 5.0


class GroupCensusError(RuntimeError):
    """The census of a process group could not be taken or read: never evidence that the group is gone."""


def group_members(pgid: int) -> list[tuple[int, str]]:
    """(pid, ps state) of every process whose process group is `pgid`, from one bounded `ps` run (Linux and
    Darwin alike; zombies included, as state Z). Fails closed: a timeout, a non-zero exit or any malformed row
    raises GroupCensusError."""
    try:
        done = subprocess.run(PS, capture_output=True, text=True, timeout=CENSUS_TIMEOUT_S,
                              env={"PATH": "/bin:/usr/bin", "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GroupCensusError(f"ps did not run: {exc!r}") from exc
    if done.returncode != 0:
        raise GroupCensusError(f"ps exited {done.returncode}")
    members = []
    for line in done.stdout.splitlines():
        fields = line.split()
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            raise GroupCensusError(f"a malformed ps row: {line!r}")
        if int(fields[1]) == pgid:
            members.append((int(fields[0]), fields[2]))
    return members


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

    def _only_zombies_left(self) -> bool:
        """Darwin's EPERM is accepted only on an independent census of the exact group, taken while the leader is
        still unreaped (so the pgid cannot have been reused): its leader is there as a zombie and no member is live.
        A census error propagates (fail closed); nothing is reaped here."""
        members = group_members(self.proc.pid)
        leader = [state for pid, state in members if pid == self.proc.pid]
        return leader != [] and all(state.startswith("Z") for _pid, state in members)

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
            except PermissionError:
                # Darwin answers EPERM for a group whose only member is the exited, not yet reaped leader (5b48662
                # on both Macs): that group is gone, but only a census of it can say so (RoseCat 7912). A live
                # member, or a census that fails, keeps the refusal.
                if not self._only_zombies_left():
                    raise
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
