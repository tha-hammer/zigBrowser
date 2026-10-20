"""macOS plan rev 14 item 5: setup dies with the browser on Darwin, where there is no PR_SET_PDEATHSIG.

A SIGKILLed browser runs no exit path, so setup watches the browser itself and, on its death, SIGKILLs
its own whole process group (itself and every descendant). `arm` is the fail-closed sequence that sets
the watch up with no gap between a check and the watch (RoseCat 6771, 6773); the OS calls are injected
(`ops`), so the sequence is tested on Linux. `darwin_ops` gives the real calls (kqueue EVFILT_PROC/
NOTE_EXIT), built lazily so this module imports anywhere.
"""
import os
import signal


def _kill_group(ops):
    ops.killpg(ops.getpid(), signal.SIGKILL)  # setup leads its group: pgid == pid


def arm(browser_pid, ops):
    """Arms the watch, or kills the whole group. True only when the watcher is running."""
    # 1. The leader of its own group, else it never killpg's a group it does not lead (it could be the
    #    browser's); no child exists yet, so killing itself is enough.
    if ops.getpgid(0) != ops.getpid():
        ops.kill(ops.getpid(), signal.SIGKILL)
        return False
    #    Still the browser's child.
    if ops.getppid() != browser_pid:
        _kill_group(ops)
        return False
    # 2. Watch for its exit; any failure to watch counts as its death.
    try:
        ops.register(browser_pid)
    except OSError:
        _kill_group(ops)
        return False
    # 3. A browser that died before the watch re-parents setup to launchd; this also covers a reused pid.
    if ops.getppid() != browser_pid:
        _kill_group(ops)
        return False

    # 4. The watcher: the wait ending, or failing, is the browser's death.
    def watch(wait):
        try:
            wait()
        except BaseException:  # noqa: BLE001 (a failed wait is the browser's death too)
            pass
        _kill_group(ops)

    ops.start_watcher(watch)
    return True


class DarwinOps:
    """The real calls on macOS: a kqueue holding one EVFILT_PROC/NOTE_EXIT on the browser."""

    def __init__(self):
        import select  # noqa: PLC0415 (kqueue exists only on BSD/macOS)
        self._select = select
        self._kq = None

    getppid = staticmethod(os.getppid)
    getpid = staticmethod(os.getpid)
    getpgid = staticmethod(os.getpgid)
    killpg = staticmethod(os.killpg)
    kill = staticmethod(os.kill)

    def register(self, pid):
        select = self._select
        self._kq = select.kqueue()
        event = select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                              fflags=select.KQ_NOTE_EXIT)
        for result in self._kq.control([event], 0, 0):
            if result.flags & select.KQ_EV_ERROR:
                raise OSError(result.data, "kevent EV_ERROR")

    def start_watcher(self, watch):
        import threading  # noqa: PLC0415
        kq = self._kq

        def wait():
            kq.control(None, 1, None)  # blocks until NOTE_EXIT (or raises)

        threading.Thread(target=watch, args=(wait,), name="zb-parent-watch", daemon=True).start()
