import json
import os
import socket
import struct
import tempfile
import threading

import pytest


class MockUDSServer:
    def __init__(self, path: str):
        self.path = path
        self._response: dict | None = None
        self._last_request: dict | None = None
        self._notifications: list[dict] = []
        self._server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server_sock.bind(self.path)
        self._server_sock.listen(1)
        self._server_sock.settimeout(5.0)
        self._thread: threading.Thread | None = None
        self._running = False
        self._client_conn: socket.socket | None = None

    def set_response(self, response: dict) -> None:
        self._response = response

    def last_request(self) -> dict:
        assert self._last_request is not None, "No request received"
        return self._last_request

    def push_notification(self, notification: dict) -> None:
        if self._client_conn:
            data = json.dumps(notification).encode("utf-8")
            self._client_conn.sendall(struct.pack(">I", len(data)) + data)

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        while self._running:
            try:
                conn, _ = self._server_sock.accept()
                self._client_conn = conn
                conn.settimeout(5.0)
                while self._running:
                    try:
                        length_bytes = self._recv_exact(conn, 4)
                        if not length_bytes:
                            break
                        length = struct.unpack(">I", length_bytes)[0]
                        data = self._recv_exact(conn, length)
                        if not data:
                            break
                        self._last_request = json.loads(data.decode("utf-8"))

                        if self._response:
                            resp = dict(self._response)
                            resp["id"] = self._last_request.get("id", 1)
                            resp_data = json.dumps(resp).encode("utf-8")
                            conn.sendall(
                                struct.pack(">I", len(resp_data)) + resp_data
                            )
                    except (socket.timeout, OSError):
                        break
            except socket.timeout:
                continue
            except OSError:
                break

    @staticmethod
    def _recv_exact(sock: socket.socket, n: int) -> bytes | None:
        data = b""
        while len(data) < n:
            chunk = sock.recv(n - len(data))
            if not chunk:
                return None
            data += chunk
        return data

    def close(self) -> None:
        self._running = False
        if self._client_conn:
            try:
                self._client_conn.close()
            except OSError:
                pass
        try:
            self._server_sock.close()
        except OSError:
            pass
        if os.path.exists(self.path):
            os.unlink(self.path)


@pytest.fixture
def mock_uds_server(tmp_path):
    sock_path = str(tmp_path / "zb-test.sock")
    server = MockUDSServer(sock_path)
    server.start()
    yield server
    server.close()
