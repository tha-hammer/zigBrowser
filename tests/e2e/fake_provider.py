"""S6b2's fake provider (chat-drawer plan rev 16.18.1, 16.18.15, 16.18.16): what the auth window
reaches through ZIGBROWSER_AGENT_AUTH_TEST, and nothing else.

- A throwaway certificate for claude.com and platform.claude.com (one day, P-256). The seam's
  `ca=` names it, and the auth window allows exactly this certificate for those two hosts.
- An HTTPS server on 127.0.0.1 that plays both hosts and records every request:
  - `/cai/oauth/authorize?...` (claude.com): the sign-in page. It sets the cookie `zbprovider=1`,
    shows `document.cookie` in `#cookies` (S6.3: no profile cookie may appear), has a popup
    button (`#popup`, window.open, which the window must refuse), and an Authorize link
    (`#authorize`) to the callback the current `variant` builds from the request's
    redirect_uri and state: `ok` (the exact callback), `wrong-state`, `missing-state`,
    `other-port` (:8443), `http`, `lookalike` (platform.claude.com.evil.example) or `no-code`.
  - `/oauth/code/callback` (platform.claude.com): the code page. A request for it is recorded
    in `callback_loads`; the window must never load it (the callback is captured).
- A recording loopback proxy (`seam_value()` names it): CONNECT to claude.com:443 or
  platform.claude.com:443 is tunnelled to the HTTPS server; every other CONNECT, and every
  plain-HTTP request, is refused with 403 and recorded in `refused`.
Standard library and the openssl CLI only. `code` is fixed per provider; `state` echoes the
request's."""

import html
import json
import select
import socket
import ssl
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

HOSTS = ("claude.com", "platform.claude.com")
VARIANTS = ("ok", "wrong-state", "missing-state", "other-port", "http", "lookalike", "no-code")
CODE = "zbFakeAuthCode-0123"


def make_provider_cert(directory: Path):
    directory.mkdir(parents=True, exist_ok=True)
    cert, key = directory / "provider-cert.pem", directory / "provider-key.pem"
    san = ",".join(f"DNS:{h}" for h in HOSTS)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", f"/CN={HOSTS[0]}",
                    "-addext", f"subjectAltName={san}"], check=True, capture_output=True)
    return cert, key


class _Quiet(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        import sys
        if isinstance(sys.exc_info()[1], OSError):
            return
        super().handle_error(request, client_address)


class FakeProvider:
    def __init__(self, tmp: Path, variant: str = "ok"):
        if variant not in VARIANTS:
            raise ValueError(variant)
        self.variant = variant
        self.lock = threading.Lock()
        self.requests: list[dict] = []        # every HTTPS request: host, path, query
        self.callback_loads: list[str] = []   # requests for the code page (must stay empty)
        self.connects: list[str] = []         # every CONNECT target the proxy saw
        self.refused: list[str] = []          # CONNECT targets or plain-HTTP URLs it refused
        self.cert, self.key = make_provider_cert(Path(tmp) / "provider")
        self._https = self._start_https()
        self._proxy = self._start_proxy()

    # --- the seam -------------------------------------------------------------------------
    def seam_value(self) -> str:
        return f"proxy=http://127.0.0.1:{self._proxy.server_address[1]},ca={self.cert}"

    @property
    def https_port(self) -> int:
        return self._https.server_address[1]

    def close(self) -> None:
        for server in (self._proxy, self._https):
            server.shutdown()
            server.server_close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # --- the callback the Authorize link goes to ------------------------------------------
    def callback_for(self, redirect_uri: str, state: str) -> str:
        r = urlsplit(redirect_uri)
        host, path = r.hostname or "", r.path
        code = f"code={CODE}"
        return {
            "ok": f"https://{host}{path}?{code}&state={state}",
            "wrong-state": f"https://{host}{path}?{code}&state=another-sign-in",
            "missing-state": f"https://{host}{path}?{code}",
            "other-port": f"https://{host}:8443{path}?{code}&state={state}",
            "http": f"http://{host}{path}?{code}&state={state}",
            "lookalike": f"https://{host}.evil.example{path}?{code}&state={state}",
            "no-code": f"https://{host}{path}?state={state}",
        }[self.variant]

    # --- the HTTPS server -----------------------------------------------------------------
    def _start_https(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                split = urlsplit(self.path)
                query = dict(parse_qsl(split.query, keep_blank_values=True))
                host = (self.headers.get("host") or "").split(":")[0]
                with provider.lock:
                    provider.requests.append({"host": host, "path": split.path, "query": query})
                if host == "claude.com" and split.path == "/cai/oauth/authorize":
                    target = provider.callback_for(query.get("redirect_uri", ""), query.get("state", ""))
                    body = PAGE.format(target=html.escape(target, quote=True)).encode()
                    return self._send(200, body, "text/html; charset=utf-8", cookie=True)
                if host == "platform.claude.com" and split.path == "/oauth/code/callback":
                    with provider.lock:
                        provider.callback_loads.append(self.path)
                    return self._send(200, b"<!doctype html><p id=code>the code page</p>", "text/html")
                return self._send(404, b"not found", "text/plain")

            def _send(self, status, body, ctype, cookie=False):
                self.send_response(status)
                self.send_header("content-type", ctype)
                self.send_header("content-length", str(len(body)))
                self.send_header("cache-control", "no-store")
                if cookie:
                    self.send_header("set-cookie", "zbprovider=1; Secure; Path=/")
                self.end_headers()
                self.wfile.write(body)

        server = _Quiet(("127.0.0.1", 0), Handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(self.cert), str(self.key))
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server

    # --- the recording proxy --------------------------------------------------------------
    def _start_proxy(self):
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_CONNECT(self):
                target = self.path
                with provider.lock:
                    provider.connects.append(target)
                host, _, port = target.rpartition(":")
                if host not in HOSTS or port != "443":
                    with provider.lock:
                        provider.refused.append(target)
                    return self._refuse()
                try:
                    upstream = socket.create_connection(("127.0.0.1", provider.https_port), timeout=10)
                except OSError:
                    return self._refuse()
                self.send_response(200, "Connection established")
                self.end_headers()
                self.wfile.flush()
                self._pump(self.connection, upstream)
                self.close_connection = True

            def _refuse(self):
                self.send_response(403)
                self.send_header("content-length", "0")
                self.send_header("connection", "close")
                self.end_headers()
                self.close_connection = True

            def _plain(self):
                with provider.lock:
                    provider.refused.append(self.path)
                self._refuse()

            do_GET = do_POST = do_HEAD = _plain

            @staticmethod
            def _pump(a, b):
                socks = [a, b]
                try:
                    while True:
                        ready, _, _ = select.select(socks, [], [], 30)
                        if not ready:
                            return
                        for s in ready:
                            data = s.recv(65536)
                            if not data:
                                return
                            (b if s is a else a).sendall(data)
                except OSError:
                    return
                finally:
                    b.close()

        server = _Quiet(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server

    def report(self) -> str:
        with self.lock:
            return json.dumps({"requests": self.requests, "callback_loads": self.callback_loads,
                               "connects": self.connects, "refused": self.refused})


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Fake sign-in</title></head>
<body>
<h1>Fake provider</h1>
<p>Cookies this page sees: <span id="cookies"></span></p>
<p><a id="authorize" href="{target}">Authorize</a></p>
<p><button id="popup" onclick="window.open('https://claude.ai/', '_blank')">Open a popup</button></p>
<script>document.getElementById('cookies').textContent = document.cookie;</script>
</body></html>
"""
