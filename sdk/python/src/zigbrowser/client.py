import asyncio
import itertools
import json
import queue
import socket
import struct
import threading
from collections.abc import Callable

from zigbrowser.errors import AutomationError


def _drop_none(**params) -> dict:
    return {k: v for k, v in params.items() if v is not None}


class DomNamespace:
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def click(self, selector: str, **options) -> dict:
        """options: force, trial, timeout_ms, strict."""
        params = {"selector": selector}
        if options:
            params["options"] = options
        return self._client.call("dom.click", params)

    def fill(self, selector: str, value: str, **options) -> dict:
        params = {"selector": selector, "value": value}
        if options:
            params["options"] = options
        return self._client.call("dom.fill", params)

    def type(
        self, selector: str, text: str, delay_ms: int | None = None, **options
    ) -> dict:
        params = _drop_none(selector=selector, text=text, delay_ms=delay_ms)
        if options:
            params["options"] = options
        return self._client.call("dom.type", params)

    def press(
        self,
        key: str,
        selector: str | None = None,
        modifiers: list[str] | None = None,
        timeout_ms: int | None = None,
    ) -> dict:
        """Press one key (KeyboardEvent.key). No selector = focused element.
        modifiers: subset of Shift, Control, Alt, Meta."""
        return self._client.call(
            "dom.press",
            _drop_none(key=key, selector=selector, modifiers=modifiers, timeout_ms=timeout_ms),
        )

    def select_option(
        self,
        selector: str,
        value: str | None = None,
        label: str | None = None,
        index: int | None = None,
        timeout_ms: int | None = None,
    ) -> dict:
        """Select by exactly one of value, label or index."""
        if sum(x is not None for x in (value, label, index)) != 1:
            raise ValueError("select_option needs exactly one of value, label, index")
        return self._client.call(
            "dom.selectOption",
            _drop_none(selector=selector, value=value, label=label, index=index, timeout_ms=timeout_ms),
        )

    def query(self, selector: str, timeout_ms: int | None = None) -> dict:
        return self._client.call("dom.query", _drop_none(selector=selector, timeout_ms=timeout_ms))

    def get_text(self, selector: str, timeout_ms: int | None = None) -> dict:
        return self._client.call("dom.getText", _drop_none(selector=selector, timeout_ms=timeout_ms))

    def get_attribute(self, selector: str, name: str, timeout_ms: int | None = None) -> dict:
        return self._client.call(
            "dom.getAttribute", _drop_none(selector=selector, name=name, timeout_ms=timeout_ms)
        )

    def wait_for(
        self,
        selector: str,
        state: str | None = None,
        timeout_ms: int | None = None,
        strict: bool | None = None,
    ) -> dict:
        """state: attached | visible (default) | hidden | detached."""
        return self._client.call(
            "dom.waitFor",
            _drop_none(selector=selector, state=state, timeout_ms=timeout_ms, strict=strict),
        )


class PageNamespace:
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def navigate(
        self, url: str, wait_until: str | None = None, timeout_ms: int | None = None
    ) -> dict:
        return self._client.call(
            "page.navigate", _drop_none(url=url, waitUntil=wait_until, timeout_ms=timeout_ms)
        )

    def reload(self, wait_until: str | None = None, timeout_ms: int | None = None) -> dict:
        return self._client.call("page.reload", _drop_none(waitUntil=wait_until, timeout_ms=timeout_ms))

    def url(self) -> dict:
        return self._client.call("page.url")

    def title(self) -> dict:
        return self._client.call("page.title")

    def screenshot(self, **options) -> dict:
        return self._client.call("page.screenshot", options or {})

    def evaluate(self, expression: str) -> dict:
        return self._client.call(
            "page.evaluate", {"expression": expression}
        )


class LinkedInNamespace:
    """Not routed by the automation socket yet: every linkedin.* call answers
    -32601 (ProtocolError). Kept for request-shape parity with
    src/linkedin.zig. Use dom.*/page.* for LinkedIn automation today."""

    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def connect(self, profile_url: str, note: str | None = None) -> dict:
        params = {"profileUrl": profile_url}
        if note is not None:
            params["note"] = note
        return self._client.call("linkedin.connect", params)

    def visit(self, profile_url: str) -> dict:
        return self._client.call(
            "linkedin.visit", {"profileUrl": profile_url}
        )

    def message(
        self,
        text: str,
        conversation_url: str | None = None,
        profile_url: str | None = None,
    ) -> dict:
        params = {"text": text}
        if conversation_url is not None:
            params["conversationUrl"] = conversation_url
        if profile_url is not None:
            params["profileUrl"] = profile_url
        return self._client.call("linkedin.message", params)

    def like(self, post_url: str) -> dict:
        return self._client.call("linkedin.like", {"postUrl": post_url})

    def comment(self, post_url: str, text: str) -> dict:
        return self._client.call(
            "linkedin.comment", {"postUrl": post_url, "text": text}
        )

    def search(self, query: str, filters: dict | None = None) -> dict:
        params = {"query": query}
        if filters is not None:
            params["filters"] = filters
        return self._client.call("linkedin.search", params)

    def extract(self, profile_url: str) -> dict:
        """No Zig implementation exists (src/linkedin.zig has no extract)."""
        return self._client.call(
            "linkedin.extract", {"profileUrl": profile_url}
        )

    def follow(self, profile_url: str) -> dict:
        return self._client.call(
            "linkedin.follow", {"profileUrl": profile_url}
        )


class InstagramNamespace:
    """Not routed by the automation socket yet: every instagram.* call
    answers -32601 (ProtocolError)."""

    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def follow(self, profile_url: str) -> dict:
        return self._client.call(
            "instagram.follow", {"profileUrl": profile_url}
        )

    def like(self, post_url: str) -> dict:
        return self._client.call("instagram.like", {"postUrl": post_url})

    def comment(self, post_url: str, text: str) -> dict:
        return self._client.call(
            "instagram.comment", {"postUrl": post_url, "text": text}
        )

    def dm(self, username: str, text: str) -> dict:
        return self._client.call(
            "instagram.dm", {"username": username, "text": text}
        )

    def story_view(self, username: str) -> dict:
        return self._client.call(
            "instagram.story_view", {"username": username}
        )


class SocialNamespace:
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def login_check(self) -> dict:
        return self._client.call("social.login_check")

    def rate_status(self) -> dict:
        return self._client.call("social.rate_status")

    def pause(self, duration_ms: int) -> dict:
        return self._client.call(
            "social.pause", {"duration_ms": duration_ms}
        )

    def set_pacing(
        self,
        min_delay_ms: int | None = None,
        max_delay_ms: int | None = None,
        daily_cap: int | None = None,
    ) -> dict:
        params = {}
        if min_delay_ms is not None:
            params["min_delay_ms"] = min_delay_ms
        if max_delay_ms is not None:
            params["max_delay_ms"] = max_delay_ms
        if daily_cap is not None:
            params["daily_cap"] = daily_cap
        return self._client.call("social.set_pacing", params)


class CookiesNamespace:
    IMPORT_FORMATS = ("netscape", "json")

    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def get_all(self, url: str | None = None) -> dict:
        """All cookies, or those that would be sent to url."""
        return self._client.call("cookies.getAll", _drop_none(url=url))

    def set(
        self,
        name: str,
        value: str,
        domain: str,
        path: str | None = None,
        expires: int | None = None,
        http_only: bool | None = None,
        secure: bool | None = None,
        same_site: str | None = None,
    ) -> dict:
        """expires: unix seconds (-1 = session). same_site: Lax|Strict|None."""
        return self._client.call(
            "cookies.set",
            _drop_none(
                name=name, value=value, domain=domain, path=path, expires=expires,
                httpOnly=http_only, secure=secure, sameSite=same_site,
            ),
        )

    def delete(self, name: str, domain: str | None = None) -> dict:
        """No domain = delete the cookie on every domain."""
        return self._client.call("cookies.delete", _drop_none(name=name, domain=domain))

    def import_file(self, path: str, format: str) -> dict:
        """Import a cookies.txt (format="netscape") or a JSON export
        (format="json"). The path is read by the browser process."""
        if format not in self.IMPORT_FORMATS:
            raise ValueError(f"format must be one of {self.IMPORT_FORMATS}")
        return self._client.call("cookies.import", {"path": path, "format": format})


def _sidecar_token(socket_path: str) -> str | None:
    """Per-session token the browser writes next to its socket
    (<socket>.token, mode 0600) when no --automation-token-file is used."""
    try:
        with open(socket_path + ".token", encoding="utf-8") as f:
            token = f.read().strip()
    except OSError:
        return None
    return token or None


class ZigBrowser:
    _id_counter = itertools.count(1)

    def __init__(self, socket_path: str, token: str | None = None):
        self._socket_path = socket_path
        self._token = token
        self._sock: socket.socket | None = None
        self._event_listeners: dict[str, list[Callable]] = {}
        self._reader_thread: threading.Thread | None = None
        self._reader_running = False
        self._response_queue: queue.Queue = queue.Queue()
        self.dom = DomNamespace(self)
        self.page = PageNamespace(self)
        self.linkedin = LinkedInNamespace(self)
        self.instagram = InstagramNamespace(self)
        self.social = SocialNamespace(self)
        self.cookies = CookiesNamespace(self)

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
        if self._token is None:
            self._token = _sidecar_token(self._socket_path)

    def disconnect(self) -> None:
        self._reader_running = False
        if self._sock:
            self._sock.close()
            self._sock = None
        if self._reader_thread and self._reader_thread.is_alive():
            self._reader_thread.join(timeout=1.0)
            self._reader_thread = None

    def on(self, event_type: str, callback: Callable) -> None:
        self._event_listeners.setdefault(event_type, []).append(callback)
        if self._sock and not self._reader_running:
            self._start_reader()

    def _start_reader(self) -> None:
        self._reader_running = True
        self._reader_thread = threading.Thread(
            target=self._read_loop, daemon=True
        )
        self._reader_thread.start()

    def _read_loop(self) -> None:
        while self._reader_running and self._sock:
            try:
                length_bytes = self._recv_exact(4)
                if not length_bytes:
                    break
                length = struct.unpack(">I", length_bytes)[0]
                data = self._recv_exact(length)
                if not data:
                    break
                parsed = json.loads(data.decode("utf-8"))
                if "id" in parsed:
                    self._response_queue.put(parsed)
                elif "method" in parsed:
                    self._dispatch_event(
                        parsed.get("method", ""),
                        parsed.get("params", {}),
                    )
            except (OSError, ConnectionError):
                break

    def _dispatch_event(self, method: str, params: dict) -> None:
        for cb in self._event_listeners.get(method, []):
            cb(params)

    def call(self, method: str, params: dict | None = None) -> dict:
        if not self._sock:
            raise ConnectionError("Not connected")

        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": next(self._id_counter),
        }
        if self._token:
            request["auth"] = self._token
        self._send(json.dumps(request))

        if self._reader_running:
            parsed = self._response_queue.get(timeout=30.0)
        else:
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

    def _recv_exact(self, n: int) -> bytes | None:
        data = b""
        while len(data) < n:
            try:
                chunk = self._sock.recv(n - len(data))
            except OSError:
                return None
            if not chunk:
                if self._reader_running:
                    return None
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *args):
        self.disconnect()


class AsyncZigBrowser:
    _id_counter = itertools.count(1)

    def __init__(self, socket_path: str, token: str | None = None):
        self._socket_path = socket_path
        self._token = token
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None

    @property
    def connected(self) -> bool:
        return self._writer is not None

    async def connect(self) -> None:
        self._reader, self._writer = await asyncio.open_unix_connection(
            self._socket_path
        )
        if self._token is None:
            self._token = _sidecar_token(self._socket_path)

    async def disconnect(self) -> None:
        if self._writer:
            self._writer.close()
            await self._writer.wait_closed()
            self._writer = None
            self._reader = None

    async def call(self, method: str, params: dict | None = None) -> dict:
        if not self._writer:
            raise ConnectionError("Not connected")

        request = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
            "id": next(self._id_counter),
        }
        if self._token:
            request["auth"] = self._token
        data = json.dumps(request).encode("utf-8")
        self._writer.write(struct.pack(">I", len(data)) + data)
        await self._writer.drain()

        length_bytes = await self._reader.readexactly(4)
        length = struct.unpack(">I", length_bytes)[0]
        response_data = await self._reader.readexactly(length)
        parsed = json.loads(response_data.decode("utf-8"))

        if "error" in parsed:
            raise AutomationError.from_rpc_error(parsed["error"])
        return parsed.get("result")

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, *args):
        await self.disconnect()
