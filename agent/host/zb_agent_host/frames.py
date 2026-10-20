"""NDJSON frames (D7b): every frame is {"v":1,"seq":n,"type":...}, one per line."""

import json
import os
import select
import sys
import threading

SEAL_S = 1.0  # the longest the fail-closed path waits for a writer stuck on a full pipe


def encode(frame):
    """One frame's line as the app measures it (S5.6): UTF-8, not \\u escapes, so a
    non-ASCII text is sized as it is; a lone surrogate becomes U+FFFD, so the line
    is always valid UTF-8."""
    text = json.dumps(frame, separators=(",", ":"), ensure_ascii=False)
    return text.encode("utf-8", "replace").decode("utf-8")


class Emitter:
    def __init__(self, stream=None):
        self._stream = stream or sys.stdout
        self._seq = 0
        self._lock = threading.Lock()

    def emit(self, type_, **fields):
        with self._lock:
            self._write(type_, fields)

    def _write(self, type_, fields):
        self._seq += 1
        self._stream.write(encode({"v": 1, "seq": self._seq, "type": type_, **fields}) + "\n")
        self._stream.flush()

    def seal(self, last=(), timeout=SEAL_S):
        """The end of the output (chat's fail-closed path). The lock is taken, waiting at
        most `timeout` (a writer may be stuck on a full pipe: then it is not, and nothing is
        written), and never released, so no later frame of any kind follows. `last`'s
        (type, fields) frames are best effort: each is written whole in one nonblocking
        write of at most PIPE_BUF bytes (atomic on a pipe), or given up (RoseCat 6423)."""
        if not self._lock.acquire(timeout=timeout):
            return False
        try:
            fd = self._stream.fileno()
            os.set_blocking(fd, False)
            for type_, fields in last:
                self._seq += 1
                line = (encode({"v": 1, "seq": self._seq, "type": type_, **fields}) + "\n").encode()
                if len(line) > select.PIPE_BUF or os.write(fd, line) != len(line):
                    return False
        except (OSError, ValueError, AttributeError):
            return False
        return True
