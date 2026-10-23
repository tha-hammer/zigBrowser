"""SIGTERM-only process teardown for every Mac e2e test (the session brief forbids SIGKILL on a Mac; bd
zigBrowser-3ui.7). mac_ms2a_routed_test.stop_browser_macos, used by the ms2a/ms2b/ms2c gates, delegates here.

stop_browser_term_only: SIGTERM to the browser's whole process group (start_new_session: group id == pid), even
when the leader has already exited (dd0b456/6206: surviving group children must still be reached), wait, reap. A
leader that is not yet reaped holds its pid, so its group id cannot be reused; a reaped leader's group is signalled
only after a probe shows it still has members (a group id with live members cannot be reused either). The browser
handles SIGTERM itself (wkwebview_shim.m handle_signal) and quits. Nothing is ever escalated: a leader or group
member still running after the grace is LEFT running and recorded as a LEAK, and a test that leaked fails: its
process exits 1 at interpreter exit after printing `FAIL\tmac-teardown-leak` (leak_failures() also lists the leaks
for tests that report them themselves).

run_term_only: subprocess.run(capture_output=True, text=True) whose timeout uses the teardown above, because
subprocess.run's own timeout SIGKILLs the child.
"""
import atexit
import os
import signal
import subprocess
import sys
import time

GRACE_S = 10.0
_leaks: list = []


def _fail_at_exit() -> None:
    try:
        sys.stdout.flush()
        print(f"FAIL\tmac-teardown-leak\t{len(_leaks)}", flush=True)
        for msg in _leaks:
            print(f"  {msg}", file=sys.stderr, flush=True)
    finally:
        os._exit(1)


def _leak(msg: str) -> None:
    if not _leaks:
        atexit.register(_fail_at_exit)
    _leaks.append(msg)


def _group_has_members(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # a member we may not signal still holds the group


def stop_browser_term_only(proc: subprocess.Popen, grace_s: float = GRACE_S) -> None:
    """SIGTERM the browser's process group, wait, reap. Never SIGKILL; a survivor is a LEAK (the test fails)."""
    pgid = proc.pid
    if isinstance(pgid, bool) or not isinstance(pgid, int) or pgid <= 1:
        _leak(f"teardown refused to signal pid {pgid!r}")
        return
    deadline = time.monotonic() + grace_s
    if proc.returncode is not None and not _group_has_members(pgid):
        return  # reaped, and nothing left in its group: nothing to signal
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass  # the whole group is already gone
    if proc.returncode is None:
        try:
            proc.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            _leak(f"LEAK browser pid {pgid} still running {grace_s:.0f}s after SIGTERM (left running: no SIGKILL on a Mac)")
            return
    # The leader is reaped; its group id stays reserved while any member lives, so probing it is safe.
    while _group_has_members(pgid):
        if time.monotonic() >= deadline:
            _leak(f"LEAK process group {pgid} still has members {grace_s:.0f}s after SIGTERM (left running)")
            return
        time.sleep(0.05)


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
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        stop_browser_term_only(proc)
        for stream in (proc.stdout, proc.stderr):
            stream.close()
        raise
    return subprocess.CompletedProcess(argv, proc.returncode, out, err)


def leak_failures() -> list:
    """One failure line per teardown that did not end the browser (the row must not pass)."""
    return [f"teardown: {msg}" for msg in _leaks]
