#!/usr/bin/env python3
"""MS4.4 (macOS launch plan): the flows' login gate reads the session cookie through the platform's cookie port, and
opens only while that cookie is in the store.

The gate (src/automation/social_flow_routes.zig, C31) asks the server's CookiePort for the platform's session cookie
(li_at / sessionid) before any navigation; app.zig hands it the GTK port on Linux and the WKHTTPCookieStore port on
macOS (src/automation_macos_cookie_port.zig, MS3.3). Against the REAL binary, on the site-modelled fixtures of
social_flows_test (ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN), driven only through the Python SDK:
- closed: with no session cookie, linkedin.visit and instagram.story_view (dry run) are -32011 logged_out, and no
  request reaches the fixture site;
- through the port: cookies.set li_at and sessionid (127.0.0.1) and cookies.get_all reads both back;
- open: linkedin.visit succeeds on the profile page, and instagram.story_view (dry run) reaches its trial click;
- live: after cookies.delete li_at, linkedin.visit is -32011 logged_out again and reaches the site no more (the
  gate reads the store on every call; nothing is cached).
Linux: the browser runs under xsession.py on its own private Xvfb only (never a live display), and the test signals
only its own children, so it runs inside a private namespace:
  timeout -k 10 600 unshare --map-current-user --pid --fork --kill-child --mount-proc \\
    env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 tests/e2e/ms4_4_login_gate_test.py \\
    --binary zig-out/bin/zigBrowser
macOS: run as the console user (WKWebView needs the WindowServer); the browser is its own process group, stopped
with stop_browser_macos. The macOS run is a leg of tests/mac/ms4_gate.sh, only on a release. Unregistered."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from social_flows_test import (FixtureServer, INSTAGRAM, LINKEDIN, ZigBrowser, expect_equal,  # noqa: E402
                               expect_error, wait_for_socket)
from slice2_common import SKIP_EXIT, eprint, isolate_profile_env, require_file, xsession_prefix  # noqa: E402

DARWIN = sys.platform == "darwin"


def scenario(zb: ZigBrowser, origin: str, server: FixtureServer) -> list[str]:
    passed: list[str] = []
    profile = f"{origin}/in/sam/"
    zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)

    expect_error("closed: linkedin.visit without li_at", lambda: zb.linkedin.visit(profile), -32011, "logged_out")
    expect_error("closed: instagram.story_view without sessionid",
                 lambda: zb.instagram.story_view("sam.example", dry_run=True), -32011, "logged_out")
    if server.requested("/in/sam/") or server.requested("/stories/"):
        raise AssertionError(f"closed: a gated flow reached the site: {server.paths}")
    passed.append("closed")

    zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
    zb.cookies.set("sessionid", "fixture-session", domain="127.0.0.1")
    listed = zb.cookies.get_all(origin + "/")
    names = sorted(c.get("name") for c in (listed.get("cookies") if isinstance(listed, dict) else listed) or [])
    expect_equal("through the port: both session cookies read back", [n for n in names if n in ("li_at", "sessionid")],
                 ["li_at", "sessionid"])
    passed.append("through-the-port")

    expect_equal("open: linkedin.visit", zb.linkedin.visit(profile), {"ok": True})
    expect_equal("open: the profile page", zb.page.evaluate("window.__li.page")["result"], "profile:sam")
    dry = zb.instagram.story_view("sam.example", dry_run=True)
    expect_equal("open: instagram.story_view dry run", (dry.get("dry_run"), dry.get("would_act")),
                 (True, "story_view"))
    passed.append("open")

    zb.cookies.delete("li_at", domain="127.0.0.1")
    before = len([p for p in server.paths if "/in/sam/" in p])
    expect_error("live: linkedin.visit after li_at is deleted", lambda: zb.linkedin.visit(profile), -32011,
                 "logged_out")
    expect_equal("live: no further request for the profile", len([p for p in server.paths if "/in/sam/" in p]), before)
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
    if DARWIN:
        from mac_ms2a_routed_test import stop_browser_macos as stop
        prefix, env = [], dict(os.environ)
    else:
        from slice2_common import stop_browser as stop
        if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
            eprint("FAIL: a display is inherited; run with DISPLAY and WAYLAND_DISPLAY unset (private Xvfb only)")
            return 1
        prefix, env = xsession_prefix(True), isolate_profile_env(dict(os.environ))

    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-ms44-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        env["ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN"] = server.origin
        argv = [str(browser), f"{server.origin}/feed/", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")]
        proc = subprocess.Popen(
            prefix + argv,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=env, start_new_session=DARWIN)
        err: list[str] = []
        threading.Thread(target=lambda: err.extend(proc.stderr), daemon=True).start()
        try:
            wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                passed = scenario(zb, server.origin, server)
        except Exception as exc:  # noqa: BLE001 - every failure is reported the same way
            print("FAIL\tms4.4-login-gate")
            eprint(f"error={exc!r}")
            eprint(f"requests={server.paths[-12:]}")
            eprint(f"stderr={err[-8:]}")
            return 1
        finally:
            stop(proc)
    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tms4.4-login-gate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
