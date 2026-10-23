"""SIGTERM-only browser teardown for the Mac runtime rows (tests/mac/ms_runtime_rows_gate.sh).

The session brief forbids sending SIGKILL on a Mac, so these rows do not use
mac_ms2a_routed_test.stop_browser_macos (SIGTERM, 2 s grace, then SIGKILL to the group). The browser handles
SIGTERM itself (wkwebview_shim.m handle_signal) and quits; WebKit's helpers on macOS are XPC services, not
members of its process group. Only a live, not-yet-reaped browser is signalled, so its group id cannot have
been reused. If it is still running after the grace, nothing is killed: the row records a LEAK and fails
(leak_failures), so a teardown that needed SIGKILL can never pass silently.
"""
import os
import signal
import subprocess

GRACE_S = 10.0
_leaks: list = []


def stop_browser_term_only(proc: subprocess.Popen, grace_s: float = GRACE_S) -> None:
    """SIGTERM the browser's own process group (start_new_session: group id == pid), wait, reap. Never SIGKILL."""
    pgid = proc.pid
    if isinstance(pgid, bool) or not isinstance(pgid, int) or pgid <= 1:
        _leaks.append(f"teardown refused to signal pid {pgid!r}")
        return
    if proc.poll() is not None:
        return  # already exited and reaped: its group id may belong to someone else now
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=grace_s)
    except subprocess.TimeoutExpired:
        _leaks.append(f"LEAK browser pid {pgid} still running {grace_s:.0f}s after SIGTERM (left running: no SIGKILL on a Mac)")


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


def leak_failures() -> list:
    """One failure line per teardown that did not end the browser (the row must not pass)."""
    return [f"teardown: {msg}" for msg in _leaks]
