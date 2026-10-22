"""Setup's sandboxed runs as an owned process group (RoseCat 7418, 7422): the whole tree a run starts ends at its
bound, and no signal ever reaches anything but that group.

run() starts the command as the leader of its own session and process group, reads its output, and waits for the
leader to exit WITHOUT reaping it (os.waitid with WNOWAIT, or kqueue NOTE_EXIT where there is no waitid: macOS's
Python 3.12), so the leader's pid, alive or a zombie, keeps the group ours. Then, every time, stop_group() SIGKILLs
the group (descendants that outlive the leader, or still hold its pipes, end with it) and reaps the leader. A run
whose leader or pipes outlive the bound raises subprocess.TimeoutExpired after that. A pipe that is STILL open once
the group is proven gone is held by a process that left the group (its own session): that is never signalled here
(holding our pipe is not proof that it is ours; RoseCat 7443), and run() raises StopFailed instead, so the caller
keeps its scratch and reports it.

stop_group() signals only after proving the target: an exact int pid above 1, not this process or its own group,
this process's child, and the leader of its own group; anything else is Refused before any signal. killpg(1) is
kill(-1): every process the user owns (a MagicMock pid indexes as 1; it logged the user out twice on 2026-10-21).
"""
import os
import select
import selectors
import signal
import subprocess
import sys
import time


STOP_S = 5  # the bound on reaping the leader and on proving the group gone after SIGKILL
DRAIN_AFTER_STOP_S = 1  # a stopped group's pipes close at once; one still open is held from outside it


class Refused(Exception):
    """A process group this module will not signal."""


# Which stop proof failed, as fixed app-owned codes (the only thing a caller may print about a StopFailed; e567a51).
REASONS = ("not_ours", "kill_refused", "reap_timeout", "table_unreadable", "members_alive", "output_held")


class StopFailed(subprocess.SubprocessError):
    """An owned group whose stop could not be completed or proven (RoseCat 7436): the kill was refused, the leader
    was not reaped, or a member was still alive at the bound. `proc` is the leader, possibly unreaped; nothing was
    claimed stopped, so the caller must not clean up after it. `reason` is one of REASONS: which proof failed."""

    def __init__(self, message, proc=None, reason=None):
        if reason not in REASONS:
            raise ValueError(f"not a StopFailed reason: {reason!r}")
        super().__init__(message)
        self.proc = proc
        self.reason = reason


def _ps(args):
    """Darwin's /bin/ps output lines, or None when it timed out, failed or could not run (never an exception: a caller
    that cannot read the table refuses or fails the stop, explicitly)."""
    try:
        done = subprocess.run(["/bin/ps", *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.splitlines() if done.returncode in (0, 1) else None


def _parent_and_group(pid):
    """(ppid, pgid) of `pid`, an unreaped zombie included, or None: /proc/<pid>/stat on Linux; ps on Darwin, where
    getpgid and getsid fail with ESRCH on a zombie but ps still reports it."""
    if sys.platform == "darwin":
        lines = _ps(["-o", "ppid=,pgid=", "-p", str(pid)])
        out = lines[0].split() if lines and len(lines) == 1 else []
        return (int(out[0]), int(out[1])) if len(out) == 2 and all(x.isdigit() for x in out) else None
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
    except OSError:
        return None
    return int(fields[1]), int(fields[2])


def _live_members(pgid):
    """Pids of the live (non-zombie) processes in process group `pgid`, or None when the table cannot be read."""
    found = []
    if sys.platform == "darwin":
        lines = _ps(["-axo", "pid=,pgid=,stat="])
        if lines is None:
            return None
        for line in lines:
            parts = line.split()
            if len(parts) != 3 or not parts[0].isdigit() or not parts[1].isdigit():
                return None
            if int(parts[1]) == pgid and not parts[2].startswith("Z"):
                found.append(int(parts[0]))
        return found
    try:
        names = os.listdir("/proc")
    except OSError:
        return None
    for name in names:
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
        except OSError:
            continue  # gone meanwhile
        if int(fields[2]) == pgid and fields[0] != "Z":
            found.append(int(name))
    return found


def _await_unreaped(pid, deadline):
    """True once our child `pid` has exited, False at the deadline; it is never reaped here."""
    if hasattr(os, "waitid"):
        while time.monotonic() < deadline:
            if os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
                return True
            time.sleep(0.01)
        return False
    # kqueue NOTE_EXIT fires at once for a child that is already a zombie, and an unreaped child of ours cannot
    # vanish, so ESRCH at registration also means it has exited.
    kq = select.kqueue()
    try:
        ev = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                           fflags=select.KQ_NOTE_EXIT)
        try:
            kq.control([ev], 0, 0)
        except ProcessLookupError:
            return True
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            if kq.control(None, 1, left):
                return True
    finally:
        kq.close()


def stop_group(proc):
    """SIGKILL the process group `proc` leads, reap `proc`, and prove no member is left alive, all within STOP_S.
    Refused, with no signal sent, unless `proc` is this process's own child leading its own group (alive or an
    unreaped zombie). StopFailed, never an unbounded wait, when the kill is refused or the stop cannot be proven."""
    pid = getattr(proc, "pid", None)
    if type(pid) is not int or pid <= 1 or pid == os.getpid() or pid == os.getpgrp():
        raise Refused(f"refusing to signal process group {pid!r}: not a real child pid")
    if _parent_and_group(pid) != (os.getpid(), pid):
        raise Refused(f"refusing to signal process group {pid!r}: not our child leading its own group")
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass  # no member left to signal; the proof below still decides
    except OSError as exc:
        raise StopFailed(f"process group {pid} could not be stopped: {exc.strerror or exc}", proc,
                         "kill_refused") from None
    try:
        proc.wait(timeout=STOP_S)
    except subprocess.TimeoutExpired:
        raise StopFailed(f"process group {pid}'s leader was not reaped within {STOP_S} s", proc,
                         "reap_timeout") from None
    deadline = time.monotonic() + STOP_S
    while True:
        members = _live_members(pid)
        if members == []:
            return
        if members is None:
            raise StopFailed(f"process group {pid}'s members could not be read", proc, "table_unreadable")
        if time.monotonic() >= deadline:
            raise StopFailed(f"process group {pid} still had a live member at the bound", proc, "members_alive")
        time.sleep(0.02)


def _exited_now(pid):
    """True when our child `pid` has already exited; never waits and never reaps."""
    if hasattr(os, "waitid"):
        return os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
    return _await_unreaped(pid, time.monotonic())


def _read_until(sel, chunks, until):
    """Reads whatever the open pipes give until `until()` or both are at EOF; True when both reached EOF."""
    while sel.get_map():
        if until():
            return False
        for key, _ in sel.select(timeout=0.02):
            data = os.read(key.fd, 65536)
            if data:
                chunks[key.data].append(data)
            else:
                sel.unregister(key.fd)
    return True


def run(argv, *, env=None, pass_fds=(), timeout):
    """Runs `argv` as an owned process group; a subprocess.CompletedProcess (text) when the leader exited and its
    output ended within `timeout`, else subprocess.TimeoutExpired; StopFailed when the group could not be stopped
    and proven gone, or a process outside it still holds the output. The group is always stopped and the leader
    reaped first."""
    if not hasattr(os, "waitid") and not hasattr(select, "kqueue"):
        raise RuntimeError("no way to await a process group leader without reaping it")
    proc = subprocess.Popen(argv, env=env, pass_fds=pass_fds, start_new_session=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    chunks = {"out": [], "err": []}
    sel = None
    try:  # everything after the spawn is under this guard: nothing below may leave the group behind (RoseCat 7450)
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout.fileno(), selectors.EVENT_READ, "out")
        sel.register(proc.stderr.fileno(), selectors.EVENT_READ, "err")
        deadline = time.monotonic() + timeout
        exited = [False]

        def leader_done_or_late():
            if not exited[0]:
                exited[0] = _exited_now(proc.pid)
            return time.monotonic() >= deadline

        drained = _read_until(sel, chunks, leader_done_or_late)
        while drained and not exited[0] and time.monotonic() < deadline:
            exited[0] = _await_unreaped(proc.pid, deadline)
        finished = drained and exited[0]
        stop_group(proc)  # every time, while the leader is unreaped: the whole group ends here
        stop_end = time.monotonic() + DRAIN_AFTER_STOP_S
        if not _read_until(sel, chunks, lambda: time.monotonic() >= stop_end):
            raise StopFailed(f"process group {proc.pid} is stopped, but a process outside it still holds the run's "
                             "output (it left the group; not signalled)", proc, "output_held")
    except StopFailed:
        raise  # already explicit
    except BaseException as exc:
        # Any other way out still stops the group first; a stop that cannot be completed or proven WINS over the
        # earlier error (kept as its cause), and a refusal about our own leader is a stop failure, never a pass:
        # the caller must not clean up around a group nobody proved gone (RoseCat 7450).
        if proc.returncode is None:
            try:
                stop_group(proc)
            except (Refused, StopFailed) as stop_exc:
                reason = stop_exc.reason if isinstance(stop_exc, StopFailed) else "not_ours"
                raise StopFailed(f"process group {proc.pid} could not be stopped after {type(exc).__name__}",
                                 proc, reason) from exc
        if isinstance(exc, Refused):
            raise StopFailed(f"process group {proc.pid} could not be proven ours", proc, "not_ours") from exc
        raise
    finally:
        if sel is not None:
            sel.close()
        for stream in (proc.stdout, proc.stderr):
            stream.close()
    out = b"".join(chunks["out"]).decode("utf-8", "replace")
    err = b"".join(chunks["err"]).decode("utf-8", "replace")
    if not finished:
        raise subprocess.TimeoutExpired(argv, timeout, output=out, stderr=err)
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)
