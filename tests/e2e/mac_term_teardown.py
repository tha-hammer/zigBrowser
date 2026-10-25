"""SIGTERM-only process teardown for every Mac e2e test (the session brief forbids SIGKILL on a Mac; bd
zigBrowser-3ui.7). mac_ms2a_routed_test.stop_browser_macos, used by the ms2a/ms2b/ms2c gates, delegates here.

stop_browser_term_only: SIGTERM to the browser's whole process group (start_new_session: group id == pid), even
when the leader has already exited (dd0b456/6206: surviving group children must still be reached), wait, reap. A
leader that is not yet reaped holds its pid, so its group id cannot be reused; a reaped leader's group is signalled
only after a probe shows it still has members (a group id with live members cannot be reused either). The browser
handles SIGTERM itself (wkwebview_shim.m handle_signal) and quits. Nothing is ever escalated: a leader or group
member still running after the grace is LEFT running and recorded as a LEAK, and a test that leaked fails: its
process exits 1 at interpreter exit after printing `FAIL\tmac-teardown-leak` (leak_failures() also lists the leaks
for tests that report them themselves). At the leak it prints the exact identity of every process left in the group,
one `LEAK\t<pid>\t<pgid>\t<start time>\t<command>` line each (ps), so a person can stop exactly that process; the
rows gate stops that host on a LEAK line and keeps its run root (SilverRidge cf16730).

run_term_only: subprocess.run(capture_output=True, text=True) whose timeout uses the teardown above, because
subprocess.run's own timeout SIGKILLs the child.
"""
import atexit
import errno
import os
import signal
import stat
import subprocess
import sys
import time

GRACE_S = 10.0
_leaks: list = []


def record_terminal_process(proc: subprocess.Popen, executable=None) -> None:
    """Append one gate-owned terminal row from this Popen and the requested executable.

    GUI launches use a shell or launchctl envelope which execs the requested
    browser.  Those immutable launcher argv values are never process identity.
    The status is read here from the same Popen object and must already be an
    integer; callers cannot supply or reconstruct it.
    """
    ledger = os.environ.get("ZB_PROCESS_LEDGER")
    if ledger is None or getattr(proc, "_zb_process_recorded", False):
        return
    row = os.environ.get("ZB_PROCESS_ROW")
    pid = proc.pid
    status = proc.poll()
    argv = proc.args
    if executable is None:
        executable = argv[0] if isinstance(argv, (list, tuple)) and argv else None
    if isinstance(executable, os.PathLike):
        executable = os.fspath(executable)
    if (not row or any(c in row for c in "\t\r\n") or isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1
            or isinstance(status, bool) or not isinstance(status, int)
            or not isinstance(executable, str) or not executable or any(c in executable for c in "\t\r\n")):
        raise RuntimeError("invalid MS1c process-ledger record")
    flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(ledger, flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError("MS1c process ledger is not a regular file")
        line = f"{row}\t{pid}\t{status}\t{executable}\n".encode("utf-8", "strict")
        if os.write(fd, line) != len(line):
            raise RuntimeError("short write to MS1c process ledger")
        proc._zb_process_recorded = True
    finally:
        os.close(fd)


def _fail_at_exit() -> None:
    try:
        sys.stdout.flush()
        print(f"FAIL\tmac-teardown-leak\t{len(_leaks)}", flush=True)
        for msg in _leaks:
            print(f"  {msg}", file=sys.stderr, flush=True)
    finally:
        os._exit(1)


def _leak(msg: str, pgid=None) -> None:
    if not _leaks:
        atexit.register(_fail_at_exit)
    _leaks.append(msg)
    if pgid is not None:
        for ident in _group_identity(pgid):
            print("LEAK\t" + "\t".join(ident), flush=True)


def _group_identity(pgid: int) -> list:
    """(pid, pgid, start time, command) of every process in group `pgid`, read with ps (macOS and Linux)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,lstart=,command="], capture_output=True, text=True).stdout
    except OSError as exc:
        return [(str(pgid), str(pgid), "?", f"ps failed: {exc}")]
    found = []
    for line in out.splitlines():
        f = line.split(None, 7)  # pid pgid <weekday month day hh:mm:ss year> command
        if len(f) == 8 and f[1] == str(pgid):
            found.append((f[0], f[1], " ".join(f[2:7]), f[7]))
    return found or [(str(pgid), str(pgid), "?", "no process of the group found by ps")]


def _group_has_members(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # a member we may not signal still holds the group


def stop_browser_term_only(proc: subprocess.Popen, grace_s: float = GRACE_S, executable=None) -> None:
    """SIGTERM the browser's process group, wait, reap. Never SIGKILL; a survivor is a LEAK (the test fails)."""
    pid = proc.pid
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        _leak(f"teardown refused to signal pid {pid!r}")
        return
    status = proc.poll()
    if status is None:
        try:
            pgid = os.getpgid(pid)
        except OSError as exc:
            _leak(f"LEAK browser pid {pid}: actual process group could not be confirmed ({exc}; left running)", pid)
            return
        if pgid != pid:
            _leak(f"LEAK browser pid {pid}: actual process group {pgid} is not its spawned pid; no signal sent", pgid)
            return
    else:
        # A reaped start_new_session leader may still have children in its pid-named group.
        pgid = pid
    deadline = time.monotonic() + grace_s
    if status is not None and not _group_has_members(pgid):
        record_terminal_process(proc, executable)
        return  # reaped, and nothing left in its group: nothing to signal
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass  # the whole group is already gone
    except PermissionError as exc:
        if exc.errno != errno.EPERM:
            raise
        _leak(f"LEAK process group {pgid}: SIGTERM was refused with EPERM (left running unconfirmed)", pgid)
        return
    if proc.poll() is None:
        try:
            proc.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            _leak(f"LEAK browser pid {pgid} still running {grace_s:.0f}s after SIGTERM (left running: no SIGKILL on a Mac)",
                  pgid)
            return
    # The leader is reaped; its group id stays reserved while any member lives, so probing it is safe.
    while _group_has_members(pgid):
        if time.monotonic() >= deadline:
            _leak(f"LEAK process group {pgid} still has members {grace_s:.0f}s after SIGTERM (left running)", pgid)
            return
        time.sleep(0.05)
    status = proc.poll()
    if status is not None:
        record_terminal_process(proc, executable)


def install_term_only_cleanup(get_proc) -> None:
    """On SIGTERM/SIGINT (e.g. an outer gate timeout), stop the browser with SIGTERM only, then re-raise."""
    def handler(signum, _frame):
        proc = get_proc()
        if proc is not None:
            stop_browser_term_only(proc)
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, handler)


def run_term_only(argv: list, timeout_s: float) -> subprocess.CompletedProcess:
    """Like subprocess.run(argv, capture_output=True, text=True, timeout=timeout_s), but a timeout stops the child
    with stop_browser_term_only (SIGTERM only) before raising subprocess.TimeoutExpired."""
    requested_executable = argv[0] if argv else None
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        stop_browser_term_only(proc, executable=requested_executable)
        for stream in (proc.stdout, proc.stderr):
            stream.close()
        raise
    record_terminal_process(proc, requested_executable)
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def leak_failures() -> list:
    """One failure line per teardown that did not end the browser (the row must not pass)."""
    return [f"teardown: {msg}" for msg in _leaks]
