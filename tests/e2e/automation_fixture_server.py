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


# M12 core fixture: every element the real-binary E2E drives.
_CORE_ITEMS = "\n".join(
    f'        <li class="item" data-index="{i}">Item {i} padding padding padding padding</li>'
    for i in range(120)
)

CORE_HTML = f"""<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>zigBrowser Core Fixture</title>
    <style>#late, #dynamic {{ margin: 8px; padding: 8px; }}</style>
  </head>
  <body>
    <p id="msg">Hello automation</p>
    <button id="late" hidden onclick="window.__lateClicks += 1; document.getElementById('late-status').textContent = 'clicked';">Late</button>
    <p id="late-status">idle</p>
    <label>Name <input id="name" autocomplete="off"></label>
    <label>Search <input id="search" autocomplete="off"></label>
    <p id="mirror"></p>
    <div id="dynamic-host"></div>
    <ul id="items">
{_CORE_ITEMS}
    </ul>
    <script>
      window.__lateClicks = 0;
      window.__keydowns = 0;
      window.__inputs = 0;
      const search = document.getElementById('search');
      search.addEventListener('keydown', () => {{ window.__keydowns += 1; }});
      search.addEventListener('input', () => {{ window.__inputs += 1; document.getElementById('mirror').textContent = search.value; }});
      window.__armLate = (ms) => setTimeout(() => {{ document.getElementById('late').hidden = false; }}, ms);
      window.__armDynamic = (ms) => setTimeout(() => {{
        const el = document.createElement('div');
        el.id = 'dynamic';
        el.textContent = 'Dynamic ready';
        document.getElementById('dynamic-host').appendChild(el);
      }}, ms);
    </script>
  </body>
</html>
"""

NAV_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title></head>
<body><h1 id="heading">{title}</h1></body></html>
"""

ROUTES = {
    "/": FIXTURE_HTML,
    "/core": CORE_HTML,
    "/nav-a": NAV_HTML.format(title="Nav A"),
    "/nav-b": NAV_HTML.format(title="Nav B"),
}


class _AutomationFixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        page = ROUTES.get(self.path)
        if page is None:
            self.send_error(404, "not found")
            return

        body = page.encode("utf-8")
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


    def test_core_and_nav_routes_are_served(self):
        with AutomationFixtureServer() as server:
            core = server.fetch("/core")
            self.assertIn("<title>zigBrowser Core Fixture</title>", core)
            self.assertEqual(core.count('class="item"'), 120)
            self.assertIn("<title>Nav B</title>", server.fetch("/nav-b"))


if __name__ == "__main__":
    unittest.main()
