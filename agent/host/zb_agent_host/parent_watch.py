"""macOS plan rev 14 item 5: setup dies with the browser on Darwin, where there is no PR_SET_PDEATHSIG.

A SIGKILLed browser runs no exit path, so setup watches the browser itself and, on its death, SIGKILLs
its own whole process group (itself and every descendant). `arm` is the fail-closed sequence that sets
the watch up with no gap between a check and the watch (RoseCat 6771, 6773); the OS calls are injected
(`ops`), so the sequence is tested on Linux. `darwin_ops` gives the real calls (kqueue EVFILT_PROC/
NOTE_EXIT), built lazily so this module imports anywhere.
"""
import os
import signal


_SESSION_CANARY_PREFIX = "zb-agent-session-"
_PROC_PIDUNIQIDENTIFIERINFO = 17
_SANDBOX_FILTER_NONE = 0
_SANDBOX_FILTER_PATH = 1


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


def reap_session(browser_pid, canary_path, ops, *, reaper_pid=None, max_passes=100, empty_passes=3):
    """Kill only stable processes carrying this launch's Seatbelt canary.

    ``ops`` is injectable so the full classify/revalidate/signal decision runs on every platform in unit tests.
    A private-API failure never widens authority: the accepted process-group watcher remains the only cleanup.
    """
    if not ops.sandbox_check_available():
        ops.log("sandbox_check unavailable; retaining process-group cleanup only")
        return False
    excluded = {browser_pid, reaper_pid if reaper_pid is not None else ops.getpid()}
    clean = 0
    for _ in range(max_passes):
        try:
            pids = ops.list_pids()
        except OSError as exc:
            ops.log(f"proc_listallpids failed; retaining process-group cleanup only: {exc}")
            return False
        if pids is None:
            ops.log("proc_listallpids failed; retaining process-group cleanup only")
            return False
        matched = False
        for pid in sorted(set(pids)):
            if pid <= 1 or pid in excluded:
                continue
            if not ops.can_signal(pid):
                continue
            first = ops.unique_id(pid)
            if first is None:
                continue
            try:
                belongs = ops.sandbox_allows_canary(pid, canary_path)
            except OSError:
                continue
            classified = ops.unique_id(pid)
            if not belongs or classified is None or classified != first:
                continue
            # This is deliberately the final operation before kill: a reused pid never inherits an earlier match.
            if ops.unique_id(pid) != first:
                continue
            try:
                ops.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as exc:
                matched = True
                ops.log(f"could not kill sandbox-matched pid {pid}: {exc}")
            else:
                matched = True
        if matched:
            clean = 0
        else:
            clean += 1
            if clean >= empty_passes:
                return True
        ops.sleep(0.02)
    ops.log("sandbox process cleanup did not reach a bounded fixed point")
    return False


def _remove_session_canary(path):
    """Guard-delete exactly the canary allocated by sandbox_macos, never a caller-selected path."""
    import tempfile  # noqa: PLC0415
    if not isinstance(path, str):
        return
    base = os.path.basename(path)
    suffix = base.removeprefix(_SESSION_CANARY_PREFIX)
    if (os.path.dirname(path) != os.path.realpath(tempfile.gettempdir())
            or not base.startswith(_SESSION_CANARY_PREFIX) or len(suffix) != 32
            or any(char not in "0123456789abcdef" for char in suffix)):
        return
    try:
        os.unlink(path)
    except OSError:
        pass


def _session_reaper_child(browser_pid, launch_pid, canary_path, ready_fd):
    """Out-of-group kqueue observer. It survives the launch group's SIGKILL and performs the sandbox sweep."""
    try:
        os.setsid()
        import select  # noqa: PLC0415 (kqueue exists only on Darwin)
        kq = select.kqueue()
        events = [select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                fflags=select.KQ_NOTE_EXIT)
                  for pid in (browser_pid, launch_pid)]
        for result in kq.control(events, 0, 0):
            if result.flags & select.KQ_EV_ERROR:
                raise OSError(result.data, "kevent EV_ERROR")
        os.write(ready_fd, b"1")
        os.close(ready_fd)
        kq.control(None, 2, None)
        reap_session(browser_pid, canary_path, DarwinSessionOps(), reaper_pid=os.getpid())
        _remove_session_canary(canary_path)
    except BaseException as exc:  # noqa: BLE001 (the observer must report failure without unwinding Python)
        try:
            os.write(ready_fd, b"0")
        except OSError:
            pass
        try:
            os.write(2, f"zigBrowser: agent: sandbox session reaper unavailable ({exc})\n".encode())
        except OSError:
            pass
    finally:
        try:
            os.close(ready_fd)
        except OSError:
            pass
        os._exit(0)


def spawn_session_reaper(browser_pid, launch_pid, canary_path):
    """Fork and synchronously arm the out-of-group session reaper before any sandboxed child exists."""
    if browser_pid <= 1 or launch_pid <= 1 or launch_pid != os.getpid():
        return False
    try:
        ready_r, ready_w = os.pipe()
        child = os.fork()
    except OSError as exc:
        try:
            os.write(2, f"zigBrowser: agent: cannot start sandbox session reaper ({exc})\n".encode())
        except OSError:
            pass
        return False
    if child == 0:
        os.close(ready_r)
        # The observer is trusted but must not retain the CLI/login token descriptors (fd 3/4) or any caller fd.
        try:
            import resource  # noqa: PLC0415
            limit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
            max_fd = 65536 if limit == resource.RLIM_INFINITY else min(int(limit), 65536)
        except (ImportError, OSError, ValueError):
            max_fd = 65536
        os.closerange(3, ready_w)
        os.closerange(ready_w + 1, max_fd)
        _session_reaper_child(browser_pid, launch_pid, canary_path, ready_w)
    os.close(ready_w)
    try:
        status = os.read(ready_r, 1)
    finally:
        os.close(ready_r)
    if status == b"1":
        return True
    try:
        os.waitpid(child, 0)
    except OSError:
        pass
    return False


class DarwinSessionOps:
    """Private Darwin process/sandbox queries, resolved lazily and used only by the trusted observer."""

    def __init__(self):
        import ctypes  # noqa: PLC0415
        import time  # noqa: PLC0415
        self._ctypes = ctypes
        self._time = time
        self._lib = ctypes.CDLL(None, use_errno=True)
        self._lib.dlsym.argtypes = (ctypes.c_void_p, ctypes.c_char_p)
        self._lib.dlsym.restype = ctypes.c_void_p
        address = self._lib.dlsym(ctypes.c_void_p(-2), b"sandbox_check")  # RTLD_DEFAULT on Darwin
        self._sandbox_check = None
        if address:
            # Confirm the private symbol with dlsym, then use ctypes' variadic call path. A fixed four-argument
            # CFUNCTYPE happens to work on x86_64 but violates Apple arm64's distinct variadic ABI.
            self._sandbox_check = self._lib.sandbox_check
            self._sandbox_check.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
            self._sandbox_check.restype = ctypes.c_int
        no_report = self._lib.dlsym(ctypes.c_void_p(-2), b"SANDBOX_CHECK_NO_REPORT")
        self._no_report = ctypes.c_int.from_address(no_report).value if no_report else 0
        self._lib.proc_listallpids.argtypes = (ctypes.c_void_p, ctypes.c_int)
        self._lib.proc_listallpids.restype = ctypes.c_int
        self._lib.proc_pidinfo.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                           ctypes.c_void_p, ctypes.c_int)
        self._lib.proc_pidinfo.restype = ctypes.c_int

        class UniqueInfo(ctypes.Structure):
            _fields_ = [("uuid", ctypes.c_ubyte * 16), ("uniqueid", ctypes.c_uint64),
                        ("parent_uniqueid", ctypes.c_uint64), ("idversion", ctypes.c_int32),
                        ("reserved2", ctypes.c_uint32), ("reserved3", ctypes.c_uint64),
                        ("reserved4", ctypes.c_uint64)]

        self._UniqueInfo = UniqueInfo

    getpid = staticmethod(os.getpid)
    kill = staticmethod(os.kill)

    def sandbox_check_available(self):
        return self._sandbox_check is not None

    @staticmethod
    def can_signal(pid):
        """Probe signal authority without delivering a signal."""
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    def list_pids(self):
        ctypes = self._ctypes
        count = self._lib.proc_listallpids(None, 0)
        if count <= 0:
            return None
        capacity = count + 256
        values = (ctypes.c_int * capacity)()
        got = self._lib.proc_listallpids(values, ctypes.sizeof(values))
        if got <= 0 or got > capacity:
            return None
        return tuple(values[index] for index in range(got))

    def unique_id(self, pid):
        ctypes = self._ctypes
        info = self._UniqueInfo()
        size = ctypes.sizeof(info)
        if self._lib.proc_pidinfo(pid, _PROC_PIDUNIQIDENTIFIERINFO, 0, ctypes.byref(info), size) != size:
            return None
        return info.uniqueid or None

    def sandbox_allows_canary(self, pid, canary_path):
        check = self._sandbox_check
        if check is None:
            return False
        # A path allow alone is unsafe: an unsandboxed browser allows every path. First prove Seatbelt applies.
        if check(pid, None, _SANDBOX_FILTER_NONE) != 1:
            return False
        encoded = os.fsencode(canary_path)
        return check(pid, b"file-read-data", _SANDBOX_FILTER_PATH | self._no_report,
                     self._ctypes.c_char_p(encoded)) == 0

    def sleep(self, seconds):
        self._time.sleep(seconds)

    @staticmethod
    def log(message):
        try:
            os.write(2, f"zigBrowser: agent: {message}\n".encode())
        except OSError:
            pass


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
