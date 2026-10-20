"""The transcript scrub (chat-drawer plan S5.7, rev 16.20.2 to 16.20.8; S5c-2).

The CLI saves an API error's body in its transcript, and a server echoes the request's
credential in it. Until slice SX-standin lands, the CLI holds the real token, and this
scrub is the only protection for transcripts. Every `projects/<ws>/*.jsonl` under the CLI's
config directory is scanned for (1) the exact fd-3 token and (2) any Anthropic credential
shape (GENERIC), and each match is overwritten in place with `*` of the same length.

One owner: a single thread runs every scan (`run`). Its census (`poll`) runs every
SCRUB_POLL_S, paced at most SCRUB_RATE_BYTES_PER_S in any 1 s; a lifecycle scan (`scan`:
a prompt's end, a session's close, the start) reads every transcript in full, each pass
up to its snapshotted size, and answers only after a revalidation pass. Files are reached
from the pinned config directory's fd with `openat` and `O_NOFOLLOW` at every component
(the config directory itself included), read with `pread`, changed only with `pwrite` of the same length and
`fsync`. Anything unexpected is ScrubFailed: the caller fails closed (exit 3).

The kernel stamps mtime and ctime with a coarse clock, so a same-size rewrite inside one
tick leaves the change key as it was. The monitor therefore commits a key only for a file
whose ctime is older than SETTLE_NS: a later write lands in a later tick and moves the key.
Residual, stated: during a lifecycle scan (which must answer right after the CLI wrote), a
same-size rewrite inside one tick of the scan is not seen; the CLI only appends, which
always changes the size.

The config directory is the one the CLI writes in, as this process sees it. In the
sandbox that is the agent home's `.claude`, a read-only bind whose `projects` is the
writable bind of `state/projects` (sandbox.STATE_DIRS); the host's `state` is not
mounted there. The caller resolves the setup-made links to it once (chat.run); nothing
the agent can write is followed."""

import collections
import errno
import os
import re
import stat
import threading
import time

SCRUB_POLL_S = 0.25
SCRUB_CHUNK = 1 << 20
SCRUB_RATE_BYTES_PER_S = 64 << 20
SCRUB_LIFECYCLE_TRIES = 3
SETTLE_NS = 50_000_000  # over a few ticks of the kernel's coarse timestamp clock
GENERIC = r"sk-ant-[a-z0-9]{2,10}-[A-Za-z0-9_-]{20,}"
MASK = b"*"

_GENERIC = re.compile(GENERIC.encode())
_TAIL = re.compile(rb"[A-Za-z0-9_-]*")
_TAIL_MIN = 20
# The longest stretch a match can have before its tail is long enough to be one: the
# bytes a chunk edge may split off and the next chunk must see again.
_CARRY = len("sk-ant-") + 10 + 1 + _TAIL_MIN - 1
_DIR = os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_FILE = os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK  # never blocks on a FIFO
KINDS = ("prompt_end", "close", "start")
PROJECTS = ("projects",)  # typed keys: a workspace is ("workspace", name)


class ScrubFailed(Exception):
    """A transcript could not be reached, read or cleaned: fail closed."""


def _why(exc):
    return errno.errorcode.get(exc.errno, exc.errno) if isinstance(exc, OSError) else type(exc).__name__


class Files:
    """The file layer (tests wrap it to count bytes or inject faults)."""

    def open_root(self, path):
        return os.open(path, _DIR)

    def openat(self, dirfd, name, flags):
        return os.open(name, flags, dir_fd=dirfd)

    def scandir(self, fd):
        return sorted(os.listdir(fd))

    def lstat_at(self, dirfd, name):
        return os.stat(name, dir_fd=dirfd, follow_symlinks=False)

    def fstat(self, fd):
        return os.fstat(fd)

    def pread(self, fd, n, offset):
        return os.pread(fd, n, offset)

    def pwrite(self, fd, data, offset):
        return os.pwrite(fd, data, offset)

    def fsync(self, fd):
        os.fsync(fd)

    def close(self, fd):
        os.close(fd)


class Clock:
    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


class Request:
    """A lifecycle scan for the owner thread; `done` once it ran, `error` if it failed.
    `tag` is the caller's (a prompt's session and id), for the terminal path."""

    def __init__(self, kind, tag=None):
        self.kind, self.tag, self.done, self.error = kind, tag, False, None
        self.event = threading.Event()

    def finish(self, error=None):
        self.error, self.done = error, True
        self.event.set()


def _key(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def _dir_id(st):
    return (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns)


class _Matcher:
    """Both patterns over one file, chunk by chunk. It keeps only offsets for an open
    generic match, at most _CARRY bytes of a possible partial one, and the last
    len(token)-1 bytes for the exact token."""

    def __init__(self, token):
        self.token = token
        self.exact_tail = b""
        self.carry = b""
        self.open = None  # [start, tail_len] of a generic match still running

    def feed(self, data, offset):
        """The spans to mask that this chunk completes, as (start, end)."""
        spans = []
        if self.token:
            buf = self.exact_tail + data
            base = offset - len(self.exact_tail)
            at = buf.find(self.token)
            while at != -1:
                spans.append((base + at, base + at + len(self.token)))
                at = buf.find(self.token, at + 1)
            self.exact_tail = buf[-(len(self.token) - 1):] if len(self.token) > 1 else b""
        pos = 0
        if self.open is not None:  # an open generic match continues
            run = _TAIL.match(data).end()
            if run == len(data):
                self.open[1] += run
                return spans
            start, tail = self.open
            self.open = None
            if tail + run >= _TAIL_MIN:
                spans.append((start, offset + run))
            pos = run
            self.carry = b""
        buf = self.carry + data[pos:]
        base = offset + pos - len(self.carry)
        seen_until = offset + pos  # matches ending at or before it were found already
        for m in _GENERIC.finditer(buf):
            start, end = base + m.start(), base + m.end()
            if end <= seen_until:
                continue
            if m.end() == len(buf):  # it may go on in the next chunk
                tail = m.end() - (m.start() + buf[m.start() + 7:].index(b"-") + 8)
                self.open = [start, tail]
                self.carry = b""
                return spans
            spans.append((start, end))
        self.carry = buf[-_CARRY:]
        return spans

    def candidate(self, size):
        """An open generic match running to `size`, as (start, end)."""
        return (self.open[0], size) if self.open is not None else None


class Scrubber:
    def __init__(self, config, token, files=None, clock=None):
        self.files, self.clock = files or Files(), clock or Clock()
        self.token = token.encode() if isinstance(token, str) else token
        try:
            self.root = self.files.open_root(config)  # no-follow: a symlinked or missing one is refused
        except Exception as exc:  # noqa: BLE001 - every failure fails closed
            raise ScrubFailed(f"cannot open the config directory: {_why(exc)}") from None
        self.keys = {}  # (ws, name) -> the change key last committed by a clean monitor scan
        self.projects_id = None
        self.reads = collections.deque()  # (time, bytes) of the monitor's reads in the last 1 s
        self.requests = []
        self.lock = threading.Lock()
        self.wake = threading.Event()  # a request was posted: the owner thread runs it now
        self.failed = None  # the owner thread's failure: every later request gets it

    # --- the live tree, walked again from the root at every census ----------------------

    def _open_dir(self, dirfd, name, missing_ok):
        try:
            return self.files.openat(dirfd, name, _DIR)
        except FileNotFoundError:
            if missing_ok:
                return None
            raise ScrubFailed(f"{name} is missing") from None
        except OSError as exc:
            raise ScrubFailed(f"cannot open {name}: {_why(exc)}") from None

    def _list(self, fd, what):
        try:
            return self.files.scandir(fd)
        except OSError as exc:
            raise ScrubFailed(f"cannot list {what}: {_why(exc)}") from None

    def _walk(self):
        """(dirs, files): the identity and listing of `projects` and each workspace directory
        (typed keys), and each transcript as (ws, name, fd, fstat). Only a missing `projects`
        (no transcript yet) is not a failure."""
        dirs, found = {}, []
        projects = self._open_dir(self.root, "projects", missing_ok=True)
        if projects is None:
            return dirs, found
        try:
            listing = self._list(projects, "projects")
            dirs[PROJECTS] = (self._fstat(projects), tuple(listing))
            for ws in listing:
                try:
                    wfd = self.files.openat(projects, ws, _DIR)
                except FileNotFoundError:
                    continue
                except OSError as exc:
                    if exc.errno in (errno.ENOTDIR, errno.ELOOP) and stat.S_ISREG(self.files.lstat_at(projects, ws).st_mode):
                        continue  # a plain file beside the workspaces
                    raise ScrubFailed(f"cannot open workspace {ws}: {_why(exc)}") from None
                try:
                    names = [n for n in self._list(wfd, ws) if n.endswith(".jsonl")]
                    dirs[("workspace", ws)] = (self._fstat(wfd), tuple(names))
                    for name in names:
                        try:
                            fd = self.files.openat(wfd, name, _FILE)
                        except FileNotFoundError:
                            continue  # vanished between the listing and the open
                        except OSError as exc:
                            raise ScrubFailed(f"cannot open {ws}/{name}: {_why(exc)}") from None
                        try:
                            st = self._fstat(fd)
                        except ScrubFailed:
                            self.files.close(fd)
                            raise
                        if not stat.S_ISREG(st.st_mode):
                            self.files.close(fd)
                            raise ScrubFailed(f"{ws}/{name} is not a regular file")
                        found.append((ws, name, fd, st))
                finally:
                    self.files.close(wfd)
        except BaseException:
            for _ws, _name, fd, _st in found:
                self.files.close(fd)
            raise
        finally:
            self.files.close(projects)
        return dirs, found

    def _fstat(self, fd):
        try:
            return self.files.fstat(fd)
        except OSError as exc:
            raise ScrubFailed(f"fstat: {_why(exc)}") from None

    # --- one file ----------------------------------------------------------------------

    def _scan_file(self, fd, size, lifecycle):
        """Reads the file up to `size` (its snapshot), masking as it goes. Returns
        (complete, candidate, masked): complete is False after a short read, or when a
        generic match runs to `size` in a file that grew past it (it may go on)."""
        matcher, offset, masked = _Matcher(self.token), 0, False
        while offset < size:
            want = min(SCRUB_CHUNK, size - offset)
            if not lifecycle:
                self._pace(want)
            try:
                data = self.files.pread(fd, want, offset)
            except OSError as exc:
                raise ScrubFailed(f"pread: {_why(exc)}") from None
            for start, end in matcher.feed(data, offset):
                self._mask(fd, start, end)
                masked = True
            offset += len(data)
            if len(data) < want:  # a concurrent truncate: this scan ends
                if masked:
                    self._fsync(fd)
                return False, None, masked
            if not lifecycle:
                self._boundary()
        candidate = matcher.candidate(size)
        complete = True
        if candidate is not None and self._fstat(fd).st_size > size:
            candidate, complete = None, False  # it may go on: the next pass sees it whole
        if candidate is not None and lifecycle:
            self._mask(fd, *candidate)
            masked, candidate = True, None
        if masked:
            self._fsync(fd)
        return complete, candidate, masked

    def _mask(self, fd, start, end):
        """`*` over [start, end), at most one SCRUB_CHUNK per write (a generic tail has no
        length limit, RoseCat 6381); a short write is continued, a write of nothing fails."""
        at = start
        while at < end:
            size = min(end - at, SCRUB_CHUNK)
            try:
                wrote = self.files.pwrite(fd, MASK * size, at)
            except OSError as exc:
                raise ScrubFailed(f"pwrite: {_why(exc)}") from None
            if not 0 < wrote <= size:
                raise ScrubFailed(f"pwrite wrote {wrote} of {size}")
            at += wrote

    def _fsync(self, fd):
        try:
            self.files.fsync(fd)
        except OSError as exc:
            raise ScrubFailed(f"fsync: {_why(exc)}") from None

    # --- the monitor -------------------------------------------------------------------

    def _pace(self, n):
        """Before a monitor read of `n` bytes: sleep until the reads of the last 1 s plus
        these stay within SCRUB_RATE_BYTES_PER_S, then record it."""
        while True:
            now = self.clock.monotonic()
            while self.reads and self.reads[0][0] <= now - 1.0:
                self.reads.popleft()
            if not self.reads or sum(b for _t, b in self.reads) + n <= SCRUB_RATE_BYTES_PER_S:
                self.reads.append((now, n))
                return
            self.clock.sleep(self.reads[0][0] + 1.0 - now)

    def post(self, kind, tag=None):
        """A lifecycle request, run at the monitor's next chunk boundary (or by `serve`).
        After the owner failed, it raises that failure at once."""
        if kind not in KINDS:
            raise ValueError(kind)
        request = Request(kind, tag)
        with self.lock:  # the failed check and the enqueue are one step (RoseCat 6280)
            if self.failed is not None:
                raise self.failed
            self.requests.append(request)
        return request

    def _boundary(self):
        """Lifecycle requests run before monitor work, at the next quantum boundary."""
        while True:
            with self.lock:
                if not self.requests:
                    return
                request = self.requests.pop(0)
            try:
                self.scan(request.kind)
            except ScrubFailed:
                # The first lifecycle failure is terminal (RoseCat 6368, 6372): it goes
                # to the owner's one fail-closed path (run), this request first.
                with self.lock:
                    self.requests.insert(0, request)
                raise
            request.finish()

    serve = _boundary

    def request(self, kind, timeout=None, tag=None):
        """From the frame side: a lifecycle scan run by the owner thread (`run`), before
        any monitor work. Returns when it is clean; raises ScrubFailed otherwise."""
        request = self.post(kind, tag)
        self.wake.set()
        if not request.event.wait(timeout):
            raise ScrubFailed(f"no answer to the {kind} scan")
        if request.error is not None:
            raise request.error

    def run(self, on_failure):
        """The owner thread, for the helper's life: a census every SCRUB_POLL_S, and every
        posted request first. A failure is latched (no later request is taken), then
        `on_failure(exc, failed)` gets it and every request it failed, before any of them
        is woken: the helper's one terminal path (RoseCat 6379). Then they are answered
        with it, and the thread ends."""
        while True:
            try:
                self.poll()
            except ScrubFailed as exc:
                with self.lock:
                    self.failed = exc
                    failed, self.requests = self.requests, []
                try:
                    on_failure(exc, failed)
                finally:
                    for request in failed:
                        request.finish(exc)
                return
            self.wake.wait(SCRUB_POLL_S)
            self.wake.clear()

    def poll(self):
        """One monitor census: every transcript whose change key moved is scanned again
        from byte 0, paced. A key is committed only after a clean scan that changed
        nothing and found the file unchanged; a scan that masked commits none, so the next
        census reads it again."""
        try:
            self._poll()
        except ScrubFailed:
            raise
        except Exception as exc:  # noqa: BLE001 - every failure fails closed
            raise ScrubFailed(f"unexpected {_why(exc)}") from exc

    def _poll(self):
        self._boundary()
        dirs, found = self._walk()
        try:
            projects = dirs.get(PROJECTS)
            identity = (projects[0].st_dev, projects[0].st_ino) if projects else None
            if identity != self.projects_id:
                self.keys, self.projects_id = {}, identity
            for ws, name, fd, st in found:
                before = _key(st)
                if self.keys.get((ws, name)) == before:
                    continue
                complete, candidate, masked = self._scan_file(fd, st.st_size, lifecycle=False)
                after = self._fstat(fd)
                settled = time.time_ns() - after.st_ctime_ns > SETTLE_NS
                if complete and candidate is None and not masked and _key(after) == before and settled:
                    self.keys[(ws, name)] = before
                else:
                    self.keys.pop((ws, name), None)
        finally:
            for _ws, _name, fd, _st in found:
                self.files.close(fd)
        self._boundary()

    # --- the lifecycle scans -------------------------------------------------------------

    def scan(self, kind):
        """A lifecycle scan: every transcript in full, keys ignored, open matches masked.
        It answers only when a revalidation walk sees the tree and every file as scanned;
        after SCRUB_LIFECYCLE_TRIES passes that each saw a change, ScrubFailed."""
        if kind not in KINDS:
            raise ValueError(kind)
        try:
            self._scan(kind)
        except ScrubFailed:
            raise
        except Exception as exc:  # noqa: BLE001 - every failure fails closed
            raise ScrubFailed(f"unexpected {_why(exc)}") from exc

    def _scan(self, kind):
        for _ in range(SCRUB_LIFECYCLE_TRIES):
            dirs, found = self._walk()
            changed = False
            expected = {}
            try:
                for ws, name, fd, st in found:
                    complete, _, _ = self._scan_file(fd, st.st_size, lifecycle=True)
                    if not complete:
                        changed = True  # a short read, or growth past the snapshot: again
                        break
                    expected[(ws, name)] = _key(self._fstat(fd))
                if not changed:
                    changed = self._moved(dirs, found, expected)
            finally:
                for _ws, _name, fd, _st in found:
                    self.files.close(fd)
            if not changed:
                return
        raise ScrubFailed(f"the transcripts kept changing during {SCRUB_LIFECYCLE_TRIES} {kind} scans")

    def _moved(self, dirs, found, expected):
        """Whether the live tree or a scanned file differs from what the scan saw."""
        for ws, name, fd, st in found:
            after = self._fstat(fd)
            if _key(after) != expected[(ws, name)] or after.st_size != st.st_size:
                return True
        again, now = self._walk()
        try:
            if set(again) != set(dirs):
                return True
            for key, (st, listing) in again.items():
                old_st, old_listing = dirs[key]
                if _dir_id(st) != _dir_id(old_st) or listing != old_listing:
                    return True
            # The full key, not only the identity: a same-inode append between the checks
            # above and this walk is a change (RoseCat 6414).
            live = {(ws, name): _key(st) for ws, name, _fd, st in now}
            return live != expected
        finally:
            for _ws, _name, fd, _st in now:
                self.files.close(fd)
