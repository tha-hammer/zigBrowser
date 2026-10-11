#!/usr/bin/env python3
"""N11 E2E: x.post / x.schedule_post / x.login_check against the real binary
on tests/fixtures/x/composer.html, served from a local HTTP server (never
x.com).

Asserts what the fixture recorded (window.__xResult): the exact text (the
restored stale draft is replaced, not appended to), the schedule dialog's
selected values, the Draft editor's event record, which Post button was
clicked (hidden copies are skipped, a late button is waited for), that a
racing page command waits for the whole flow (the server rejects it as
queued_past_deadline), and the
logged-out gate. The page is warmed first with a bounded 90 s navigate, and a
failed call reports its elapsed time and full error. Exit 77 (skip) without a
binary/display."""

from __future__ import annotations

import argparse
import http.server
import json
import signal
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures/x/composer.html"


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


class HoldServer:
    """Serves the X fixture over HTTP. GET /hold blocks until the test has
    sent the racing command, then answers; every request is logged in
    order so the test can check the racing page load came after /hold."""

    # Longer than the racer's 300 ms timeout, so a queued racer has waited
    # past its deadline by the time the flow ends.
    GRACE_SEC = 1.5

    def __init__(self) -> None:
        self.clicked = threading.Event()
        self.release = threading.Event()
        self._log: list[str] = []
        self._lock = threading.Lock()
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:  # quiet
                pass

            def do_GET(self) -> None:  # noqa: N802
                if self.path.startswith("/hold"):
                    outer.clicked.set()
                    outer.release.wait(60)
                    time.sleep(outer.GRACE_SEC)
                    outer._record("hold:answered")
                    body, kind = b"ok", "text/plain"
                elif self.path.startswith("/composer.html"):
                    if "marker=raced" in self.path:
                        outer._record("raced:requested")
                    body, kind = FIXTURE.read_bytes(), "text/html; charset=utf-8"
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.base = f"http://127.0.0.1:{self._server.server_address[1]}"

    def _record(self, event: str) -> None:
        with self._lock:
            self._log.append(event)

    def order(self) -> list[str]:
        with self._lock:
            return list(self._log)

    def __enter__(self) -> "HoldServer":
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc) -> None:
        self.release.set()
        self._server.shutdown()
        self._server.server_close()


class TimedRpcClient(RpcClient):
    """RpcClient whose failed calls say which client, which method, how long
    it took and the whole JSON-RPC error, so a load-only failure in a gate log
    can be told apart from a real one."""

    def __init__(self, socket_path: Path, timeout_sec: float, name: str) -> None:
        super().__init__(socket_path, timeout_sec)
        self.name = name

    def call(self, method: str, params: dict | None = None):
        started = time.monotonic()
        response = self.raw(method, params)
        if "error" in response:
            elapsed = time.monotonic() - started
            raise AssertionError(f"{self.name} {method} failed after {elapsed:.1f} s: {json.dumps(response['error'])}")
        return response["result"]


# The browser's cold start can take most of a flow's 30 s navigate step on a
# heavily loaded host (the first x.post once failed that way only during
# overlapping gates). Warm the page with a longer, still bounded, navigate so
# the flows measure the flows, not process startup. Test only: the flows'
# own timeouts are unchanged.
WARM_NAVIGATE_MS = 90_000
WARM_COMPOSER_MS = 30_000


def warm_up(socket_path: Path, compose_url: str) -> None:
    warm = TimedRpcClient(socket_path, (WARM_NAVIGATE_MS + WARM_COMPOSER_MS) / 1000 + 30, "warm-up")
    started = time.monotonic()
    try:
        warm.call("page.navigate", {"url": compose_url, "timeout_ms": WARM_NAVIGATE_MS})
        warm.call("dom.waitFor", {"selector": "testid=tweetTextarea_0", "state": "visible", "timeout_ms": WARM_COMPOSER_MS})
    finally:
        warm.close()
    eprint(f"warm-up: {time.monotonic() - started:.1f} s")


def run_scenarios(socket_path: Path, server: HoldServer, timeout_sec: float) -> list[str]:
    passed: list[str] = []
    base = f"{server.base}/composer.html"
    warm_up(socket_path, f"{base}?mode=compose")
    rpc = TimedRpcClient(socket_path, timeout_sec + 30, "rpc")

    def recorded():
        return rpc.call("page.evaluate", {"expression": "window.__xResult"})["result"]

    # x.post replaces the restored draft and clicks the compose-page button.
    text = "hello from zigBrowser, café ✓"
    expect_equal("x.post", rpc.call("x.post", {"text": text, "compose_url": f"{base}?mode=compose"}), {"ok": True})
    expect_equal("posted text (stale draft replaced)", recorded(), {"text": text, "scheduled": None, "button": "tweetButton"})
    # Draft behaviour: one deletion clears the stale draft, then one cancelled
    # beforeinput per character owned by the editor's model; never a native
    # input event (that would mean the browser edited behind the editor).
    events = rpc.call("page.evaluate", {"expression": "window.__xEvents"})["result"]
    expect_equal("draft events", events, ["beforeinput:deleteContentBackward"] + ["beforeinput:insertText"] * len(text))
    expect_equal("toast", rpc.call("dom.getText", {"selector": "testid=toast"})["text"], "Your post was sent.")
    passed.append("x.post")

    # An old toast still on screen must not confirm this post (RoseCat's
    # audit 7c9d68a): here Post does nothing, so before the fix the flow
    # reported success. Now Post is never clicked and nothing is posted.
    response = rpc.raw("x.post", {"text": "stale toast", "compose_url": f"{base}?mode=compose&stale=1"})
    error = response.get("error") or {}
    expect_equal("old toast still shown", (error.get("code"), (error.get("data") or {}).get("reason")), (-32001, "x_toast_already_shown"))
    expect_equal("old toast: nothing posted, Post never clicked", (recorded(), rpc.call("page.evaluate", {"expression": "window.__xPosts"})["result"]), (None, 0))
    # An old toast that goes away in time: the post goes through.
    expect_equal("old toast that fades", rpc.call("x.post", {"text": "after the toast", "compose_url": f"{base}?mode=compose&stale=fade"}), {"ok": True})
    expect_equal("old toast that fades: posted", recorded()["text"], "after the toast")
    # The Post copies move while the old toast fades (another composer's
    # disabled Post is inserted first): Post is looked for only after the
    # toast is gone, so this composer's own Post is the one clicked
    # (RoseCat 5185).
    expect_equal("Post copies move as the toast fades", rpc.call("x.post", {"text": "after the move", "compose_url": f"{base}?mode=compose&stale=reorder"}), {"ok": True})
    expect_equal("Post copies move: this composer posted, the other untouched", (recorded()["text"], rpc.call("page.evaluate", {"expression": "window.__xOtherPost"})["result"]), ("after the move", 0))
    passed.append("x.post-old-toast")

    expect_equal("x.login_check", rpc.call("x.login_check", {}), {"loggedIn": True, "platform": "x"})
    passed.append("x.login_check")

    # x.schedule_post drives the dialog's native selects (24h -> 12h).
    sched = rpc.call("x.schedule_post", {"text": "scheduled one", "date": "2026-11-05", "time": "14:07", "compose_url": f"{base}?mode=compose"})
    expect_equal("x.schedule_post", sched, {"ok": True, "scheduledFor": "2026-11-05T14:07"})
    expect_equal(
        "scheduled values",
        recorded(),
        {
            "text": "scheduled one",
            "scheduled": {"month": "11", "day": "5", "year": "2026", "hour": "2", "minute": "7", "ampm": "PM"},
            "button": "tweetButton",
        },
    )
    passed.append("x.schedule_post")

    # Timeline layout: two hidden tweetButton copies (display:none and
    # visibility:hidden with a real box) and an inline button that appears
    # late. Only the actionable inline button may be clicked.
    expect_equal("x.post home", rpc.call("x.post", {"text": "from the timeline", "compose_url": f"{base}?mode=home"}), {"ok": True})
    expect_equal("decoys skipped", recorded()["button"], "tweetButtonInline")
    passed.append("hidden-decoys+late-button")

    # /compose/post as a dialog over the home timeline (live, 2026-10-11):
    # the composer and the schedule option exist twice; the flows must use
    # the dialog's copies and never touch the timeline's.
    dialog = f"{base}?mode=dialog"
    inline = lambda: rpc.call("page.evaluate", {"expression": "window.__xInline"})["result"]  # noqa: E731
    expect_equal("x.post dialog", rpc.call("x.post", {"text": "from the dialog", "compose_url": dialog}), {"ok": True})
    expect_equal("dialog post", recorded(), {"text": "from the dialog", "scheduled": None, "button": "tweetButton"})
    expect_equal("timeline composer untouched", inline(), {"events": 0, "scheduleClicks": 0})
    sched = rpc.call("x.schedule_post", {"text": "dialog schedule", "date": "2027-01-31", "time": "00:05", "compose_url": dialog})
    expect_equal("x.schedule_post dialog", sched, {"ok": True, "scheduledFor": "2027-01-31T00:05"})
    expect_equal(
        "dialog scheduled values",
        recorded(),
        {
            "text": "dialog schedule",
            "scheduled": {"month": "1", "day": "31", "year": "2027", "hour": "12", "minute": "5", "ampm": "AM"},
            "button": "tweetButton",
        },
    )
    expect_equal("timeline schedule untouched", inline(), {"events": 0, "scheduleClicks": 0})
    passed.append("compose-dialog-over-timeline")

    # One queue turn per flow. After the Post click the fixture's toast
    # waits for GET /hold; the server answers /hold only once a second
    # client has sent page.navigate (timeout_ms 300) plus a grace longer
    # than that timeout. The oracle is the server's own answer, not timing:
    # a correctly queued navigate waits behind the whole flow and is then
    # rejected before it runs with navigation_timeout reason
    # "queued_past_deadline" (only a queued command can get that reason).
    # A navigate that bypassed the queue would run mid-flow: it would load
    # the raced page (seen by the server) and the toast would never appear.
    raced_url = f"{server.base}/composer.html?mode=compose&marker=raced"
    racer_result: dict[str, object] = {}

    def racer():
        other = RpcClient(socket_path, timeout_sec + 30)
        try:
            if not server.clicked.wait(timeout_sec + 30):
                racer_result["error"] = "the flow never reached the held step"
                return
            # Send without waiting, then let the server answer /hold.
            request = {"jsonrpc": "2.0", "method": "page.navigate", "id": 1, "params": {"url": raced_url, "timeout_ms": 300}}
            if other.token:
                request["auth"] = other.token
            payload = json.dumps(request).encode("utf-8")
            other.sock.sendall(struct.pack(">I", len(payload)) + payload)
            server.release.set()
            length = struct.unpack(">I", other._recv_exact(4))[0]
            response = json.loads(other._recv_exact(length).decode("utf-8"))
            racer_result["response"] = response
        finally:
            server.release.set()
            other.close()

    t = threading.Thread(target=racer)
    t.start()
    compose = f"{server.base}/composer.html?mode=compose&hold={server.base}/hold"
    outcome = rpc.call("x.post", {"text": "no interleaving", "compose_url": compose})
    t.join(timeout=timeout_sec + 30)
    expect_equal("x.post racing", outcome, {"ok": True})
    error = (racer_result.get("response") or {}).get("error") or {}
    expect_equal("racer code", error.get("code"), -32007)
    expect_equal("racer reason", (error.get("data") or {}).get("reason"), "queued_past_deadline")
    expect_equal("server order", server.order(), ["hold:answered"])
    expect_equal("page after the flow", rpc.call("page.url")["url"], compose)
    passed.append("single-queue-turn")

    # x.selfcheck: read-only selector-table report. With &all=1 every entry
    # matches; after removing the composer exactly that entry drops to 0.
    rpc.call("page.navigate", {"url": f"{base}?mode=compose&all=1"})
    report = rpc.call("x.selfcheck", {})
    expected_keys = [
        "composer", "post_button.tweetButton", "post_button.tweetButtonInline", "post_success",
        "schedule_option", "schedule_month", "schedule_day", "schedule_year", "schedule_hour",
        "schedule_minute", "schedule_ampm", "schedule_confirm", "dialog_close", "login_link",
    ]
    expect_equal("selfcheck keys", list(report), expected_keys)
    missing = [name for name, count in report.items() if count < 1]
    expect_equal("selfcheck all present", missing, [])
    rpc.call("page.evaluate", {"expression": "document.querySelector('[data-testid=\"tweetTextarea_0\"]').remove(), true"})
    after = rpc.call("x.selfcheck", {})
    expect_equal("selfcheck composer removed", after["composer"], 0)
    expect_equal("selfcheck others unchanged", {k: v for k, v in after.items() if k != "composer"}, {k: v for k, v in report.items() if k != "composer"})
    expect_equal("selfcheck did not navigate", rpc.call("page.url")["url"], f"{base}?mode=compose&all=1")
    passed.append("x.selfcheck")

    # A humanized native post of the full 280 characters, trusted end to end
    # (about 60-90 s; it also fits the 120 s default, so the route's budget
    # sizing is proven by the route-level test in automation_x_test.zig).
    long_text = "Zig " * 70
    slow = TimedRpcClient(socket_path, 650, "slow")
    started = time.monotonic()
    humanized = slow.call("x.post", {"text": long_text, "compose_url": f"{base}?mode=compose", "options": {"input": "native", "humanize": True}})
    elapsed = time.monotonic() - started
    slow.close()
    expect_equal("humanized 280-character post", humanized, {"ok": True})
    expect_equal("humanized 280-character text", recorded()["text"], long_text)
    if elapsed < 280 * 0.08:
        raise AssertionError(f"280 humanized characters took only {elapsed:.1f} s")
    eprint(f"humanized 280-character post: {elapsed:.1f} s")
    passed.append("humanized-280")

    # N20: an Arkose challenge on the composer stops x.post before any input;
    # X's daily-limit toast after Post is not a success.
    def x_signal(label, params):
        response = rpc.raw("x.post", params)
        error = response.get("error") or {}
        data = error.get("data") or {}
        expect_equal(f"{label} code", error.get("code"), -32010)
        return data.get("signal"), data.get("platform")

    expect_equal("captcha signal", x_signal("captcha", {"text": "blocked by a challenge", "compose_url": f"{base}?mode=compose&captcha=1"}), ("challenge", "x"))
    trust = rpc.call("page.evaluate", {"expression": "window.__xTrust"})["result"]
    if any(entry.startswith(("click:", "keydown:")) for entry in trust):
        raise AssertionError(f"input reached a challenged page: {trust}")
    expect_equal("captcha: nothing posted", recorded(), None)
    expect_equal("limit toast signal", x_signal("limit", {"text": "one too many", "compose_url": f"{base}?mode=compose&limit=1"}), ("toast", "x"))
    expect_equal("limit: nothing posted", recorded(), None)
    passed.append("x-platform-signals")

    # options.dry_run: up to the Post click, and no further. The text is never
    # typed (the restored draft stays), no key, edit or click reaches the
    # page (window.__xTrust records them before any handler), the schedule
    # dialog stays closed and nothing is posted. Over the timeline (dialog
    # mode) the target is the dialog's composer, never the timeline's.
    js = lambda expression: rpc.call("page.evaluate", {"expression": expression})["result"]  # noqa: E731
    for verb, params in (
        ("post", {"text": "never typed"}),
        ("schedule_post", {"text": "never typed", "date": "2026-11-05", "time": "14:07"}),
    ):
        result = rpc.call(f"x.{verb}", {**params, "compose_url": f"{base}?mode=dialog", "options": {"dry_run": True}})
        target = result.get("target") or {}
        expect_equal(f"x.{verb} dry run", (result.get("dry_run"), result.get("would_act"), target.get("tag"), target.get("label")), (True, verb, "div", "data-testid=tweetTextarea_0"))
        names = [c["name"] for c in result["checks"]]
        if "rate_limit_scans" not in names or ("schedule_option" in names) != (verb == "schedule_post"):
            raise AssertionError(f"x.{verb} dry run checks: {result['checks']}")
        trust = [entry for entry in js("window.__xTrust") if not entry.startswith("mousemove:")]
        expect_equal(f"x.{verb} dry run: no input event", trust, [])
        expect_equal(
            f"x.{verb} dry run: draft kept, dialog closed, nothing posted, timeline untouched",
            (js("window.__xEvents"), js("document.querySelector('#compose [data-testid=\"tweetTextarea_0\"]').textContent"), js("document.getElementById('schedule-dialog').hidden"), js("window.__xPosts"), recorded(), js("window.__xInline")),
            ([], "STALE DRAFT", True, 0, None, {"events": 0, "scheduleClicks": 0}),
        )
    passed.append("dry-run")

    # Logged-out page: login link, no composer -> -32011 logged_out, nothing posted.
    response = rpc.raw("x.post", {"text": "should not post", "compose_url": f"{base}?mode=loggedout"})
    error = response.get("error") or {}
    expect_equal("logged-out code", error.get("code"), -32011)
    expect_equal("logged-out reason", (error.get("data") or {}).get("reason"), "logged_out")
    expect_equal("nothing posted while logged out", recorded(), None)
    passed.append("logged-out-gate")

    rpc.close()
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary") or not require_file(FIXTURE, "x fixture"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with HoldServer() as server, tempfile.TemporaryDirectory(prefix="zb-x-flows-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{server.base}/composer.html?mode=compose", "--automation-api", "--profile-dir", str(Path(tmp) / "profile")],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        assert proc.stdout is not None and proc.stderr is not None
        stderr_lines: list[str] = []
        threading.Thread(target=_read_lines, args=(proc.stdout, []), daemon=True).start()
        threading.Thread(target=_read_lines, args=(proc.stderr, stderr_lines), daemon=True).start()
        try:
            passed = run_scenarios(socket_path, server, args.timeout_sec)
        except Exception as exc:  # noqa: BLE001
            print("FAIL\tx-flows")
            eprint(f"error={exc!r}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1
        rc = terminate(proc)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tx-flows-clean-shutdown")
            eprint(f"return={rc}")
            return 1

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tx-flows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
