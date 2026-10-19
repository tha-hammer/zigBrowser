"""A local stand-in for Anthropic's Messages API (a true system boundary).

It serves POST /v1/messages from a script of turns, streamed as SSE when the
request asks for it, and records every request (method, path, headers, body).
Any other path gets 404 and is recorded too. It also acts as an HTTP proxy that
records and refuses every CONNECT tunnel and every proxied request for another
host (`tunnels`), so a run that points HTTPS_PROXY/HTTP_PROXY at it (with
NO_PROXY=127.0.0.1) proves no other host was contacted.

A turn is a dict: {"text": str} and/or {"tool_use": {"name": str, "input": {}}};
or {"deltas": [str, ...]}: one text block whose streamed form is one text delta per
item (its text is their join), with an optional {"stall": threading.Event}: the
stream holds after the first delta (flushed) until the event is set, at most 30 s;
or {"status": int, "body": {...}}: that HTTP status with a JSON error body (the
default body names the status), streamed request or not (chat-drawer plan S5a);
or {"endless": str}: one text block streamed as that piece over and over until the
client goes away, at most ENDLESS_MAX_S (S5c-1, plan S5.6); `endless_ended` counts
the streams the client left.
`responder(request, index)` may pick the turn for each messages request; the
default takes the scripted turns in order and answers "ok" once they run out.
"""

import json
import ssl
import subprocess
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

MODEL = "claude-fake-model"


def _usage():
    return {"input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}


STALL_MAX_S = 30.0
ENDLESS_MAX_S = 120.0


def _endless(piece):
    import time
    end = time.monotonic() + ENDLESS_MAX_S
    while time.monotonic() < end:
        yield piece


def _content(turn, index):
    blocks = []
    if turn.get("endless") is not None:
        blocks.append({"type": "text", "text": ""})
    if turn.get("text") is not None:
        blocks.append({"type": "text", "text": turn["text"]})
    if turn.get("deltas") is not None:
        blocks.append({"type": "text", "text": "".join(turn["deltas"])})
    if turn.get("tool_use") is not None:
        use = turn["tool_use"]
        blocks.append({"type": "tool_use", "id": use.get("id", f"toolu_fake_{index}"), "name": use["name"], "input": use.get("input", {})})
    return blocks or [{"type": "text", "text": ""}]


def _message(turn, index, content=None):
    stop = "tool_use" if turn.get("tool_use") is not None else "end_turn"
    return {
        "id": f"msg_fake_{index}",
        "type": "message",
        "role": "assistant",
        "model": MODEL,
        "content": _content(turn, index) if content is None else content,
        "stop_reason": stop,
        "stop_sequence": None,
        "usage": _usage(),
    }


def _sse_events(turn, index):
    start = _message(turn, index, content=[])
    start["stop_reason"] = None
    yield "message_start", {"type": "message_start", "message": start}
    for i, block in enumerate(_content(turn, index)):
        if block["type"] == "text":
            yield "content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}}
            if turn.get("endless") is not None:
                pieces = _endless(turn["endless"])
            else:
                pieces = turn["deltas"] if turn.get("deltas") is not None else [block["text"]]
            for n, piece in enumerate(pieces):
                yield "content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": piece}}
                if n == 0 and turn.get("stall") is not None:
                    turn["stall"].wait(STALL_MAX_S)  # the delta above is already flushed
        else:
            empty = dict(block, input={})
            yield "content_block_start", {"type": "content_block_start", "index": i, "content_block": empty}
            yield "content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}
        yield "content_block_stop", {"type": "content_block_stop", "index": i}
    stop = "tool_use" if turn.get("tool_use") is not None else "end_turn"
    yield "message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


FAKE_HOST = "fake.zb.invalid"


class _QuietServer(ThreadingHTTPServer):
    """A peer that resets or never finishes the TLS handshake (a probe, a refused hook) is
    part of what the tests drive: it is counted in `connections`, not printed."""

    def handle_error(self, request, client_address):
        import sys
        if isinstance(sys.exc_info()[1], OSError):
            return
        super().handle_error(request, client_address)


def make_test_cert(directory, host=FAKE_HOST):
    """A throwaway self-signed certificate for `host` (one day, P-256), written to
    `directory`. Returns (cert, key); the cert is also the CA the CLI is told to
    trust (NODE_EXTRA_CA_CERTS, chat-drawer plan rev 16.2 §3c.4)."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    cert, key = directory / "fake-api-cert.pem", directory / "fake-api-key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", f"/CN={host}",
                    "-addext", f"subjectAltName=DNS:{host}"],
                   check=True, capture_output=True)
    return cert, key


class FakeAnthropicApi:
    """`tls=(cert, key)` serves HTTPS (for the route through relay and netd, where
    netd's --test-allow maps fake.zb.invalid to this port); otherwise plain HTTP."""

    def __init__(self, turns=None, responder=None, tls=None):
        self.tls = tls
        self.turns = list(turns or [])
        self.responder = responder
        self.requests = []
        # One entry per accepted connection: the authorization values of the requests that
        # came on it (S4.4: a connection with no Bearer request was not the CLI's).
        self.connections = []
        self.tunnels = []
        self.messages_count = 0
        self.endless_ended = 0
        self._lock = threading.Lock()
        self._server = None
        self._thread = None

    @property
    def base_url(self):
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def connections_without_bearer(self, token):
        """How many accepted connections carried no `Bearer <token>` request (a TLS
        handshake that never sends a request counts too)."""
        want = f"Bearer {token}"
        with self._lock:
            return sum(1 for c in self.connections if want not in c["authorizations"])

    @property
    def port(self):
        return self._server.server_address[1]

    def start(self):
        api = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def setup(self):
                super().setup()
                self.zb_connection = {"authorizations": []}
                with api._lock:
                    api.connections.append(self.zb_connection)

            def _record(self, body):
                headers = {k.lower(): v for k, v in self.headers.items()}
                parsed = body
                if body:
                    try:
                        parsed = json.loads(body)
                    except ValueError:
                        parsed = body.decode("utf-8", "replace")
                split = urlsplit(self.path)
                path = split.path + (f"?{split.query}" if split.query else "")
                entry = {"method": self.command, "path": path, "target": self.path, "headers": headers, "body": parsed}
                with api._lock:
                    api.requests.append(entry)
                    self.zb_connection["authorizations"].append(headers.get("authorization"))
                return entry

            def _read_body(self):
                length = int(self.headers.get("content-length") or 0)
                return self.rfile.read(length) if length else b""

            def _send(self, code, payload, ctype="application/json"):
                data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_CONNECT(self):
                with api._lock:
                    api.tunnels.append(self.path)
                self._record(b"")
                self.send_response(403)
                self.send_header("content-length", "0")
                self.send_header("connection", "close")
                self.end_headers()
                self.close_connection = True

            def _foreign(self):
                # An absolute-form request (proxy use) for any host but this server.
                split = urlsplit(self.path)
                if not split.netloc or split.netloc == "%s:%d" % self.server.server_address[:2]:
                    return False
                with api._lock:
                    api.tunnels.append(self.path)
                self._send(403, b"", "text/plain")
                return True

            def do_GET(self):
                self._record(self._read_body())
                if self._foreign():
                    return
                self._send(404, {"type": "error", "error": {"type": "not_found_error", "message": "not found"}})

            do_HEAD = do_GET
            do_PUT = do_GET
            do_DELETE = do_GET

            def do_POST(self):
                entry = self._record(self._read_body())
                if self._foreign():
                    return
                if entry["path"].split("?", 1)[0] != "/v1/messages":
                    self._send(404, {"type": "error", "error": {"type": "not_found_error", "message": "not found"}})
                    return
                with api._lock:
                    index = api.messages_count
                    api.messages_count += 1
                turn = api._turn(entry, index)
                if turn.get("status") is not None:
                    status = turn["status"]
                    self._send(status, turn.get("body") or {"type": "error", "error": {"type": "api_error", "message": f"fake {status}"}})
                    return
                body = entry["body"] if isinstance(entry["body"], dict) else {}
                if not body.get("stream"):
                    self._send(200, _message(turn, index))
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("cache-control", "no-cache")
                self.send_header("connection", "close")
                self.end_headers()
                try:
                    for name, data in _sse_events(turn, index):
                        self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
                        self.wfile.flush()
                except OSError:
                    if turn.get("endless") is None:
                        raise
                    with api._lock:
                        api.endless_ended += 1
                self.close_connection = True

        self._server = _QuietServer(("127.0.0.1", 0), Handler)
        if self.tls is not None:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(*map(str, self.tls))
            # The handshake runs in each request's thread, not in the accept loop.
            self._server.socket = context.wrap_socket(self._server.socket, server_side=True,
                                                      do_handshake_on_connect=False)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def _turn(self, entry, index):
        if self.responder is not None:
            turn = self.responder(entry, index)
            if turn is not None:
                return turn
        with self._lock:
            if self.turns:
                return self.turns.pop(0)
        return {"text": "ok"}

    def stop(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    def messages_requests(self):
        with self._lock:
            return [r for r in self.requests if r["method"] == "POST" and r["path"].split("?", 1)[0] == "/v1/messages"]

    def other_paths(self):
        with self._lock:
            return sorted({f'{r["method"]} {r["path"].split("?", 1)[0]}' for r in self.requests
                           if r["method"] != "CONNECT" and r["path"].split("?", 1)[0] != "/v1/messages"})
