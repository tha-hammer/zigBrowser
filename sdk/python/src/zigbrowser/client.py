import itertools
import json
import socket
import struct

from zigbrowser.errors import AutomationError


class ZigBrowser:
    _id_counter = itertools.count(1)

    def __init__(self, socket_path: str, token: str | None = None):
        self._socket_path = socket_path
        self._token = token
        self._sock: socket.socket | None = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(self._socket_path)
        except (FileNotFoundError, ConnectionRefusedError) as e:
            raise ConnectionError(
                f"Cannot connect to zigBrowser socket: {e}"
            ) from e
        self._sock = sock

    def disconnect(self) -> None:
        if self._sock:
            self._sock.close()
            self._sock = None

    def call(self, method: str, params: dict | None = None) -> dict:
        if not self._sock:
            raise ConnectionError("Not connected")

        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": next(self._id_counter),
        }
        self._send(json.dumps(request))
        response = self._recv()
        parsed = json.loads(response)

        if "error" in parsed:
            raise AutomationError.from_rpc_error(parsed["error"])
        return parsed.get("result")

    def _send(self, data: str) -> None:
        encoded = data.encode("utf-8")
        self._sock.sendall(struct.pack(">I", len(encoded)) + encoded)

    def _recv(self) -> str:
        length_bytes = self._recv_exact(4)
        length = struct.unpack(">I", length_bytes)[0]
        data = self._recv_exact(length)
        return data.decode("utf-8")

    def _recv_exact(self, n: int) -> bytes:
        data = b""
        while len(data) < n:
            chunk = self._sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.disconnect()
