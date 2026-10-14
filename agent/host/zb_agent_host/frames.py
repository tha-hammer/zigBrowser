"""NDJSON frames (D7b): every frame is {"v":1,"seq":n,"type":...}, one per line."""

import json
import sys
import threading


class Emitter:
    def __init__(self, stream=None):
        self._stream = stream or sys.stdout
        self._seq = 0
        self._lock = threading.Lock()

    def emit(self, type_, **fields):
        with self._lock:
            self._seq += 1
            frame = {"v": 1, "seq": self._seq, "type": type_, **fields}
            self._stream.write(json.dumps(frame, separators=(",", ":")) + "\n")
            self._stream.flush()
