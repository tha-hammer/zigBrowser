#!/usr/bin/env python3
"""Deterministic fixture server for Phase 1 automation E2E tests."""

import http.server
import threading
import unittest
import urllib.request


FIXTURE_HTML = """<!doctype html>
<html data-fixture-origin="local">
  <head>
    <meta charset="utf-8">
    <title>zigBrowser Automation Fixture</title>
  </head>
  <body>
    <main data-testid="automation-root">
      <button data-testid="ready-button">Ready</button>
    </main>
  </body>
</html>
"""


class _AutomationFixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404, "not found")
            return

        body = FIXTURE_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class AutomationFixtureServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.host = host
        self.port = port
        self._server = None
        self._thread = None
        self.base_url = None

    def __enter__(self):
        self._server = http.server.ThreadingHTTPServer(
            (self.host, self.port),
            _AutomationFixtureHandler,
        )
        actual_host, actual_port = self._server.server_address
        self.base_url = f"http://{actual_host}:{actual_port}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        return False

    def fetch(self, path):
        if self.base_url is None:
            raise RuntimeError("fixture server is not running")
        with urllib.request.urlopen(f"{self.base_url}{path}", timeout=5) as response:
            return response.read().decode("utf-8")


class AutomationFixtureServerTest(unittest.TestCase):
    def test_root_endpoint_returns_deterministic_html_without_external_network(self):
        with AutomationFixtureServer() as server:
            first = server.fetch("/")
            second = server.fetch("/")

        self.assertEqual(first, second)
        self.assertIn("<!doctype html>", first.lower())
        self.assertIn('data-fixture-origin="local"', first)
        self.assertNotIn("https://", first)
        self.assertNotIn("http://", first)


if __name__ == "__main__":
    unittest.main()
