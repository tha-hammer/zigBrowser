"""NDJSON frames (D7b): every frame is {"v":1,"seq":n,"type":...}, one per line."""

import json
import sys
import threading


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
            self._seq += 1
            self._stream.write(encode({"v": 1, "seq": self._seq, "type": type_, **fields}) + "\n")
            self._stream.flush()
