import itertools
import json
import socket
import struct

from zigbrowser.errors import AutomationError


class DomNamespace:
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def click(self, selector: str, **options) -> dict:
        params = {"selector": selector}
        if options:
            params["options"] = options
        return self._client.call("dom.click", params)

    def fill(self, selector: str, value: str, **options) -> dict:
        params = {"selector": selector, "value": value}
        if options:
            params["options"] = options
        return self._client.call("dom.fill", params)

    def type(self, selector: str, text: str, **options) -> dict:
        params = {"selector": selector, "text": text}
        if options:
            params["options"] = options
        return self._client.call("dom.type", params)

    def query(self, selector: str, timeout_ms: int | None = None) -> dict:
        params = {"selector": selector}
        if timeout_ms is not None:
            params["timeout_ms"] = timeout_ms
        return self._client.call("dom.query", params)

    def get_text(self, selector: str) -> dict:
        return self._client.call("dom.getText", {"selector": selector})

    def get_attribute(self, selector: str, name: str) -> dict:
        return self._client.call(
            "dom.getAttribute", {"selector": selector, "name": name}
        )

    def wait_for(self, selector: str, **options) -> dict:
        params = {"selector": selector}
        if options:
            params["options"] = options
        return self._client.call("dom.waitFor", params)


class PageNamespace:
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def navigate(self, url: str, wait_until: str | None = None) -> dict:
        params = {"url": url}
        if wait_until is not None:
            params["waitUntil"] = wait_until
        return self._client.call("page.navigate", params)

    def reload(self, wait_until: str | None = None) -> dict:
        params = {}
        if wait_until is not None:
            params["waitUntil"] = wait_until
        return self._client.call("page.reload", params)

    def screenshot(self, **options) -> dict:
        return self._client.call("page.screenshot", options or {})

    def evaluate(self, expression: str) -> dict:
        return self._client.call(
            "page.evaluate", {"expression": expression}
        )


class LinkedInNamespace:
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
        return self._client.call(
            "linkedin.extract", {"profileUrl": profile_url}
        )


class InstagramNamespace:
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
    def __init__(self, client: "ZigBrowser"):
        self._client = client

    def get_all(self) -> dict:
        return self._client.call("cookies.getAll")

    def set(self, name: str, value: str, **options) -> dict:
        params = {"name": name, "value": value, **options}
        return self._client.call("cookies.set", params)

    def delete(self, name: str) -> dict:
        return self._client.call("cookies.delete", {"name": name})


class ZigBrowser:
    _id_counter = itertools.count(1)

    def __init__(self, socket_path: str, token: str | None = None):
        self._socket_path = socket_path
        self._token = token
        self._sock: socket.socket | None = None
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
