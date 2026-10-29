#!/usr/bin/env python3
"""Installed-app OAuth popup round trip on macOS.

The real WKWebView opens an authorization popup, follows an HTTP 302 chain
through another origin after that origin sets a cookie, returns to the opener
origin, posts the result, and closes itself.  A second row covers providers
that finish by navigating the opener, and a third covers an intermediate page
that opens one more callback window.  The test observes only real page state
through the automation socket; it never injects a successful result.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import plistlib
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path


class Rpc:
    def __init__(self, path: Path, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        last: OSError | None = None
        while time.monotonic() < deadline:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.settimeout(timeout)
                self.sock.connect(str(path))
                break
            except OSError as exc:
                last = exc
                time.sleep(0.05)
        else:
            raise TimeoutError(f"automation socket unavailable: {last}")
        token = Path(f"{path}.token")
        self.token = token.read_text(encoding="ascii") if token.exists() else None
        self.next_id = 1

    def close(self) -> None:
        self.sock.close()

    def _exact(self, count: int) -> bytes:
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise ConnectionError("automation socket closed")
            data += chunk
        return data

    def call(self, method: str, params: dict | None = None):
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        self.next_id += 1
        if params is not None:
            request["params"] = params
        if self.token is not None:
            request["auth"] = self.token
        payload = json.dumps(request, separators=(",", ":")).encode()
        self.sock.sendall(struct.pack(">I", len(payload)) + payload)
        size = struct.unpack(">I", self._exact(4))[0]
        response = json.loads(self._exact(size))
        if "error" in response:
            raise AssertionError(f"{method}: {response['error']}")
        return response["result"]


def html(body: str) -> bytes:
    return ("<!doctype html><meta charset=utf-8>" + body).encode()


class OAuthFixture:
    def __init__(self) -> None:
        self.events: list[str] = []
        self.user_agents: list[tuple[str, str, str]] = []
        fixture = self

        class Opener(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                route = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(route.query)
                fixture.events.append(f"opener:{route.path}")
                fixture.user_agents.append(("opener", route.path, self.headers.get("User-Agent", "")))
                if route.path == "/callback":
                    mode = query.get("mode", [""])[0]
                    cookie = query.get("cookie", [""])[0]
                    if mode == "message":
                        source = f"""<title>OAuth callback</title><p>This may take a moment</p><script>
                          window.opener.postMessage({{kind:'oauth', cookie:{json.dumps(cookie)}}}, {json.dumps(self.server.origin)});
                          window.close();
                        </script>"""
                    elif mode == "navigate":
                        source = f"""<title>OAuth callback</title><p>This may take a moment</p><script>
                          window.opener.location = {json.dumps(self.server.origin + '/done?cookie=' + cookie)};
                          window.close();
                        </script>"""
                    elif mode == "relay":
                        source = f"""<title>OAuth callback</title><p>This may take a moment</p><script>
                          window.opener.postMessage({{kind:'relay', cookie:{json.dumps(cookie)}}}, '*');
                          window.close();
                        </script>"""
                    else:
                        source = "<title>bad callback</title>"
                elif route.path == "/done":
                    source = f"<title>OAuth complete</title><h1 id=result>navigated:{query.get('cookie', [''])[0]}</h1>"
                else:
                    source = f"""<title>OAuth opener</title><h1 id=result>waiting</h1><script>
                      window.popup = null;
                      window.addEventListener('message', event => {{
                        if (![{json.dumps(self.server.origin)}, {json.dumps(self.server.auth_origin)}].includes(event.origin) || event.source !== window.popup) return;
                        document.querySelector('#result').textContent = 'message:' + event.data.cookie;
                      }});
                      window.startOAuth = mode => {{
                        document.querySelector('#result').textContent = 'waiting:' + mode;
                        window.popup = window.open({json.dumps(self.server.auth_origin)} + '/authorize?mode=' + mode, 'oauth-provider');
                      }};
                      window.startUaPopup = () => {{
                        window.popup = window.open({json.dumps(self.server.auth_origin)} + '/ua-popup', 'ua-popup');
                      }};
                    </script>"""
                data = html(source)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_args) -> None:
                pass

        class Auth(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                route = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(route.query)
                mode = query.get("mode", [""])[0]
                fixture.events.append(f"auth:{route.path}:{'cookie' if 'oauth_session=ready' in (self.headers.get('Cookie') or '') else 'no-cookie'}")
                fixture.user_agents.append(("auth", route.path, self.headers.get("User-Agent", "")))
                if route.path == "/ua-popup":
                    data = html("<title>User Agent Popup</title><h1 id=ua></h1><script>document.querySelector('#ua').textContent=navigator.userAgent</script>")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if route.path == "/authorize":
                    self.send_response(302)
                    self.send_header("Set-Cookie", "oauth_session=ready; Path=/; HttpOnly; SameSite=Lax")
                    self.send_header("Location", f"/continue?mode={urllib.parse.quote(mode)}")
                    self.end_headers()
                    return
                if route.path == "/continue":
                    cookie = "ready" if "oauth_session=ready" in (self.headers.get("Cookie") or "") else "missing"
                    if mode == "third":
                        callback = f"{self.server.opener_origin}/callback"
                        data = html(f"""<title>This may take a moment</title>
                          <form id=finish action={json.dumps(callback)} method=get target=oauth-callback>
                            <input name=mode value=relay><input name=cookie value={json.dumps(cookie)}>
                          </form><script>
                          window.addEventListener('message', event => {{
                            if (event.data.kind !== 'relay') return;
                            window.opener.postMessage({{kind:'oauth', cookie:event.data.cookie}}, {json.dumps(self.server.opener_origin)});
                            window.close();
                          }});
                          document.querySelector('#finish').submit();
                        </script>""")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/html; charset=utf-8")
                        self.send_header("Content-Length", str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                        return
                    location = f"{self.server.opener_origin}/callback?mode={urllib.parse.quote(mode)}&cookie={cookie}"
                    self.send_response(302)
                    self.send_header("Location", location)
                    self.end_headers()
                    return
                self.send_error(404)

            def log_message(self, *_args) -> None:
                pass

        self.opener = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Opener)
        self.auth = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Auth)
        self.opener.daemon_threads = self.auth.daemon_threads = True
        self.opener.origin = f"http://127.0.0.1:{self.opener.server_address[1]}"
        self.auth.origin = f"http://127.0.0.1:{self.auth.server_address[1]}"
        self.opener.auth_origin = self.auth.origin
        self.auth.opener_origin = self.opener.origin
        self.threads = [
            threading.Thread(target=self.opener.serve_forever, daemon=True),
            threading.Thread(target=self.auth.serve_forever, daemon=True),
        ]

    @property
    def origin(self) -> str:
        return self.opener.origin

    def __enter__(self) -> "OAuthFixture":
        for thread in self.threads:
            thread.start()
        return self

    def __exit__(self, *_args) -> None:
        self.opener.shutdown()
        self.auth.shutdown()


def wait_until(label: str, timeout: float, read, wanted) -> None:
    deadline = time.monotonic() + timeout
    actual = None
    while time.monotonic() < deadline:
        actual = read()
        if wanted(actual):
            return
        time.sleep(0.05)
    raise AssertionError(f"{label}: last state {actual!r}")


def safari_user_agent() -> str:
    path = Path("/Applications/Safari.app/Contents/Info.plist")
    with path.open("rb") as stream:
        version = plistlib.load(stream).get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version:
        raise RuntimeError("Safari CFBundleShortVersionString is missing")
    return (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        f"Version/{version} Safari/605.1.15"
    )


def executable_pids(executable: Path) -> set[int]:
    found: set[int] = set()
    prefix = f"{executable}"
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == prefix or fields[1].startswith(prefix + " ")):
            found.add(int(fields[0]))
    return found


def stop_owned(pid: int | None, executable: Path, launcher: subprocess.Popen) -> None:
    if pid is not None and pid in executable_pids(executable):
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while pid in executable_pids(executable) and time.monotonic() < deadline:
            time.sleep(0.05)
        if pid in executable_pids(executable):
            raise RuntimeError(f"owned browser pid {pid} ignored SIGTERM")
    try:
        launcher.wait(timeout=10)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"owned LaunchServices waiter pid {launcher.pid} did not exit") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser", required=True)
    parser.add_argument("--png", required=True)
    parser.add_argument("--timeout-sec", type=float, default=20)
    args = parser.parse_args()
    browser = Path(args.browser).resolve()
    png = Path(args.png).resolve()
    if not browser.is_file():
        print(f"FAIL\toauth-popup\tbrowser missing: {browser}")
        return 1

    failures: list[str] = []
    observed_user_agent = "<not observed>"
    with OAuthFixture() as fixture, tempfile.TemporaryDirectory(prefix="zb-oauth-popup-") as raw:
        root = Path(raw)
        for name in ("home", "tmp", "data", "cache", "profile"):
            (root / name).mkdir(mode=0o700)
        socket_path = root / "automation.sock"
        stdout_path = root / "stdout"
        stderr_path = root / "stderr"
        env = {
            **os.environ,
            "HOME": str(root / "home"),
            "TMPDIR": str(root / "tmp"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "ZIGBROWSER_SOCKET": str(socket_path),
            "ZB_DEBUG_DRAWER_LAYOUT": "1",
            "ZB_DEBUG_WINDOW_SNAPSHOT_PNG": str(png),
            "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS": "7000",
        }
        app = browser.parent.parent.parent
        before = executable_pids(browser)
        launch = ["/usr/bin/open", "-n", "-W", "-o", str(stdout_path), "--stderr", str(stderr_path)]
        for key in (
            "HOME", "TMPDIR", "XDG_DATA_HOME", "XDG_CACHE_HOME", "ZIGBROWSER_SOCKET",
            "ZB_DEBUG_DRAWER_LAYOUT", "ZB_DEBUG_WINDOW_SNAPSHOT_PNG",
            "ZB_DEBUG_WINDOW_SNAPSHOT_DELAY_MS",
        ):
            launch.extend(("--env", f"{key}={env[key]}"))
        launch.extend((str(app), "--args", f"{fixture.origin}/", "--automation-api", "--e2e-protocol", "--profile-dir", str(root / "profile")))
        launcher = subprocess.Popen(
            launch,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        browser_pid: int | None = None
        discover_deadline = time.monotonic() + args.timeout_sec
        while time.monotonic() < discover_deadline:
            candidates = executable_pids(browser) - before
            if len(candidates) == 1:
                browser_pid = candidates.pop()
                break
            if launcher.poll() is not None:
                break
            time.sleep(0.05)
        if browser_pid is None:
            failures.append(f"installed application pid not discovered; launcher_rc={launcher.poll()}")
        rpc: Rpc | None = None
        try:
            if browser_pid is None:
                raise RuntimeError("installed application did not launch")
            rpc = Rpc(socket_path, args.timeout_sec)
            rpc.call("page.title")

            def pages():
                return rpc.call("page.list")["pages"]

            def result():
                return rpc.call("dom.getText", {"selector": "css=#result"})["text"]

            expected_user_agent = safari_user_agent()
            observed_user_agent = rpc.call("page.evaluate", {"expression": "navigator.userAgent"})["result"]
            if observed_user_agent != expected_user_agent:
                raise AssertionError(
                    f"main navigator.userAgent: got {observed_user_agent!r}, want {expected_user_agent!r}"
                )
            wait_until(
                "main request User-Agent", args.timeout_sec,
                lambda: [ua for origin, path, ua in fixture.user_agents if origin == "opener" and path == "/"],
                lambda values: values == [expected_user_agent],
            )

            rpc.call("page.evaluate", {"expression": "startUaPopup()"})
            wait_until(
                "user-agent popup", args.timeout_sec, pages,
                lambda values: len(values) == 2 and any((page.get("url") or "").endswith("/ua-popup") for page in values),
            )
            popup = next(page for page in pages() if (page.get("url") or "").endswith("/ua-popup"))
            popup_user_agent = rpc.call(
                "page.evaluate",
                {"window_id": popup["window_id"], "expression": "navigator.userAgent"},
            )["result"]
            if popup_user_agent != expected_user_agent:
                raise AssertionError(
                    f"popup navigator.userAgent: got {popup_user_agent!r}, want {expected_user_agent!r}"
                )
            wait_until(
                "popup request User-Agent", args.timeout_sec,
                lambda: [ua for origin, path, ua in fixture.user_agents if origin == "auth" and path == "/ua-popup"],
                lambda values: values == [expected_user_agent],
            )
            rpc.call("page.close", {"window_id": popup["window_id"]})
            wait_until("user-agent popup close", args.timeout_sec, pages, lambda values: len(values) == 1)

            for mode in ("message", "third"):
                rpc.call("page.evaluate", {"expression": f"startOAuth({json.dumps(mode)})"})
                wait_until(f"{mode} callback result", args.timeout_sec, result, lambda value: value == "message:ready")
                wait_until(f"{mode} popup close", args.timeout_sec, pages, lambda value: len(value) == 1)
                if mode == "message":
                    rpc.call("page.evaluate", {"expression": "document.querySelector('#result').textContent='waiting'"})

            rpc.call("page.evaluate", {"expression": "startOAuth('navigate')"})
            wait_until("opener navigation", args.timeout_sec, lambda: rpc.call("page.title")["title"], lambda value: value == "OAuth complete")
            wait_until("navigate popup close", args.timeout_sec, pages, lambda value: len(value) == 1)
            if rpc.call("dom.getText", {"selector": "css=#result"})["text"] != "navigated:ready":
                raise AssertionError("opener callback did not retain provider cookie result")
            wait_until("in-app PNG", args.timeout_sec, lambda: png.stat().st_size if png.exists() else 0, lambda value: value > 1024)
        except Exception as exc:  # noqa: BLE001
            failures.append(str(exc))
        finally:
            if rpc is not None:
                rpc.close()
            try:
                stop_owned(browser_pid, browser, launcher)
            except Exception as exc:  # noqa: BLE001
                failures.append(str(exc))

        if failures:
            print(f"FAIL\toauth-popup\t{failures[0]}")
            print("EVENTS\t" + " ".join(fixture.events))
            print("USER_AGENTS\t" + " | ".join(f"{origin}:{path}:{ua}" for origin, path, ua in fixture.user_agents))
            print("STDOUT\t" + " | ".join(stdout_path.read_text(errors="replace").splitlines()[-12:]))
            print("STDERR\t" + " | ".join(stderr_path.read_text(errors="replace").splitlines()[-12:]))
            return 1

    print(f"USER_AGENT\t{observed_user_agent}")
    print(f"PASS\toauth-popup\tSafari identity, message close, third-window relay, opener navigation\t{png}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
