#!/usr/bin/env python3
"""MS4.4 (macOS launch plan): the flows' login gate reads the session cookie through the platform's cookie port, and
opens only while that cookie is in the store.

The gate (src/automation/social_flow_routes.zig, C31) asks the server's CookiePort for the platform's session cookie
(li_at / sessionid) before any navigation; app.zig hands it the GTK port on Linux and the WKHTTPCookieStore port on
macOS (src/automation_macos_cookie_port.zig, MS3.3). Against the REAL binary, on the site-modelled fixtures of
social_flows_test (ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN), driven over the automation socket with the raw RpcClient of
automation_core_test (stdlib only, like every macOS e2e: the Python SDK needs Python 3.14 here; RoseCat 7888 (c)):
- closed: with no session cookie, linkedin.visit and instagram.story_view (dry run) are -32011 logged_out, and no
  request reaches the fixture site;
- through the port: cookies.set li_at and sessionid (127.0.0.1) and cookies.get_all reads both back;
- open: linkedin.visit succeeds on the profile page, and instagram.story_view (dry run) reaches its trial click;
- live: after cookies.delete li_at, linkedin.visit is -32011 logged_out again and reaches the site no more, and after
  cookies.delete sessionid, instagram.story_view (dry run) is -32011 logged_out with no further /stories/ request (the
  gate reads the store on every call; nothing is cached; RoseCat 7886 #2).
Linux: the browser runs under xsession.py on its own private Xvfb only (never a live display), and the test signals
only its own children, so it runs inside a private namespace:
  timeout -k 10 600 unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 tests/e2e/ms4_4_login_gate_test.py \\
    --binary zig-out/bin/zigBrowser
macOS: run as the console user (WKWebView needs the WindowServer). Every inherited ZB_* / ZIGBROWSER_* seam is
dropped before the test sets its socket and fixture origin. The browser is the leader of its own process group
(OwnedGroup): SIGTERM, SIGINT and SIGHUP to the driver (an outer timeout, an ssh drop) stop that exact group while its
leader is still unreaped, reap the leader, then re-raise (RoseCat 7886 #1; ms4_4_login_gate_cleanup_test proves it
without a browser). The macOS run is a leg of tests/mac/ms4_gate.sh, only on a release."""

from __future__ import annotations

import argparse
import http.server
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from automation_core_test import RpcClient  # noqa: E402
from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, xsession_prefix  # noqa: E402
from ms4_4_owned_group import OwnedGroup, install_cleanup, without_seams  # noqa: E402

DARWIN = sys.platform == "darwin"
REPO = HERE.parents[1]
LINKEDIN = REPO / "tests/fixtures/linkedin/index.html"
INSTAGRAM = REPO / "tests/fixtures/instagram/index.html"
LINKEDIN_PREFIXES = ("/in/", "/feed/")


class FixtureServer:
    """social_flows_test's fixture pages (LinkedIn-shaped paths get the LinkedIn page, the rest Instagram's), every
    requested path logged. Kept here so the test imports no SDK."""

    def __init__(self) -> None:
        self.paths: list[str] = []
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def do_GET(self) -> None:  # noqa: N802 - the stdlib's name
                with outer._lock:
                    outer.paths.append(self.path)
                body = (LINKEDIN if self.path.startswith(LINKEDIN_PREFIXES) else INSTAGRAM).read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.origin = f"http://127.0.0.1:{self._server.server_address[1]}"

    def requested(self, fragment: str) -> bool:
        with self._lock:
            return any(fragment in p for p in self.paths)

    def count(self, fragment: str) -> int:
        with self._lock:
            return len([p for p in self.paths if fragment in p])

    def __enter__(self) -> "FixtureServer":
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc) -> None:
        self._server.shutdown()
        self._server.server_close()


class Refused(Exception):
    def __init__(self, code, reason):
        super().__init__(f"{code} {reason}")
        self.code, self.reason = code, reason


def call(rpc: RpcClient, method: str, params: dict | None = None):
    response = rpc.raw(method, params)
    if "error" in response:
        error = response["error"] or {}
        raise Refused(error.get("code"), (error.get("data") or {}).get("reason"))
    return response.get("result")


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def expect_refused(label: str, rpc: RpcClient, method: str, params: dict, code: int, reason: str) -> None:
    try:
        result = call(rpc, method, params)
    except Refused as exc:
        expect_equal(f"{label} (code, reason)", (exc.code, exc.reason), (code, reason))
        return
    raise AssertionError(f"{label}: not refused ({result!r})")


def scenario(rpc: RpcClient, origin: str, server: FixtureServer) -> list[str]:
    passed: list[str] = []
    visit = {"profileUrl": f"{origin}/in/sam/"}
    story = {"username": "sam.example", "options": {"dry_run": True}}
    call(rpc, "social.set_pacing", {"min_delay_ms": 0, "max_delay_ms": 0, "daily_cap": 100})

    expect_refused("closed: linkedin.visit without li_at", rpc, "linkedin.visit", visit, -32011, "logged_out")
    expect_refused("closed: instagram.story_view without sessionid", rpc, "instagram.story_view", story, -32011,
                   "logged_out")
    if server.requested("/in/sam/") or server.requested("/stories/"):
        raise AssertionError(f"closed: a gated flow reached the site: {server.paths}")
    passed.append("closed")

    for name in ("li_at", "sessionid"):
        call(rpc, "cookies.set", {"name": name, "value": "fixture-session", "domain": "127.0.0.1"})
    listed = call(rpc, "cookies.getAll", {"url": origin + "/"})
    cookies = listed.get("cookies") if isinstance(listed, dict) else listed
    names = sorted(c.get("name") for c in cookies or [] if c.get("name") in ("li_at", "sessionid"))
    expect_equal("through the port: both session cookies read back", names, ["li_at", "sessionid"])
    passed.append("through-the-port")

    expect_equal("open: linkedin.visit", call(rpc, "linkedin.visit", visit), {"ok": True})
    page = call(rpc, "page.evaluate", {"expression": "window.__li.page"})
    expect_equal("open: the profile page", (page or {}).get("result"), "profile:sam")
    dry = call(rpc, "instagram.story_view", story) or {}
    expect_equal("open: instagram.story_view dry run", (dry.get("dry_run"), dry.get("would_act")), (True, "story_view"))
    passed.append("open")

    call(rpc, "cookies.delete", {"name": "li_at", "domain": "127.0.0.1"})
    before = server.count("/in/sam/")
    expect_refused("live: linkedin.visit after li_at is deleted", rpc, "linkedin.visit", visit, -32011, "logged_out")
    expect_equal("live: no further request for the profile", server.count("/in/sam/"), before)
    call(rpc, "cookies.delete", {"name": "sessionid", "domain": "127.0.0.1"})
    before = server.count("/stories/")
    expect_refused("live: instagram.story_view after sessionid is deleted", rpc, "instagram.story_view", story,
                   -32011, "logged_out")
    expect_equal("live: no further request for the stories", server.count("/stories/"), before)
    passed.append("live")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    args = parser.parse_args()
    browser = Path(args.binary)
    for path, label in ((browser, "binary"), (LINKEDIN, "linkedin fixture"), (INSTAGRAM, "instagram fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    group = None
    if DARWIN:
        install_cleanup(lambda: group)
        prefix, env = [], without_seams(dict(os.environ))
    else:
        from slice2_common import stop_browser as stop
        if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
            eprint("FAIL: a display is inherited; run with DISPLAY and WAYLAND_DISPLAY unset (private Xvfb only)")
            return 1
        prefix, env = xsession_prefix(True), without_seams(isolate_profile_env(dict(os.environ)))

    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-ms44-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN"] = server.origin
        argv = [str(browser), f"{server.origin}/feed/", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")]
        kw = dict(stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env)
        if DARWIN:
            group = OwnedGroup(prefix + argv, **kw)
            proc = group.proc
        else:
            proc = subprocess.Popen(prefix + argv, **kw)
        err: list[str] = []
        threading.Thread(target=lambda: err.extend(proc.stderr), daemon=True).start()
        rpc = None
        try:
            rpc = RpcClient(socket_path, args.timeout_sec)
            passed = scenario(rpc, server.origin, server)
        except Exception as exc:  # noqa: BLE001 - every failure is reported the same way
            print("FAIL\tms4.4-login-gate")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            eprint(f"stderr={err[-8:]}")
            return 1
        finally:
            if rpc is not None:
                rpc.close()
            if DARWIN:
                group.stop()
            else:
                stop(proc)
    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tms4.4-login-gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
