import json
import struct
import threading
from collections.abc import Callable


class EventDispatcher:
    def __init__(self):
        self._listeners: dict[str, list[Callable]] = {}
        self._thread: threading.Thread | None = None
        self._running = False

    def on(self, event_type: str, callback: Callable) -> None:
        self._listeners.setdefault(event_type, []).append(callback)

    def dispatch(self, method: str, params: dict) -> None:
        for cb in self._listeners.get(method, []):
            cb(params)

    def start(self, sock) -> None:
        self._running = True
        self._thread = threading.Thread(
            target=self._listen, args=(sock,), daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._running = False

    def _listen(self, sock) -> None:
        while self._running:
            try:
                length_bytes = self._recv_exact(sock, 4)
                if not length_bytes:
                    break
                length = struct.unpack(">I", length_bytes)[0]
                data = self._recv_exact(sock, length)
                if not data:
                    break
                parsed = json.loads(data.decode("utf-8"))
                if "method" in parsed and "id" not in parsed:
                    self.dispatch(
                        parsed.get("method", ""),
                        parsed.get("params", {}),
                    )
            except OSError:
                break

    @staticmethod
    def _recv_exact(sock, n: int) -> bytes | None:
        data = b""
        while len(data) < n:
            try:
                chunk = sock.recv(n - len(data))
            except OSError:
                return None
            if not chunk:
                return None
            data += chunk
        return data
