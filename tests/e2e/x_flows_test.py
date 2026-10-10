#!/usr/bin/env python3
"""N11 E2E: x.post / x.schedule_post / x.login_check against the real binary
on tests/fixtures/x/composer.html (never x.com).

Asserts what the fixture recorded (window.__xResult): the exact text (the
restored stale draft is replaced, not appended to), the schedule dialog's
selected values, which Post button was clicked (a hidden decoy is skipped),
that a racing page command does not interleave with a running flow, and the
logged-out gate. Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import signal
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


def run_scenarios(socket_path: Path, base: str, timeout_sec: float) -> list[str]:
    passed: list[str] = []
    rpc = RpcClient(socket_path, timeout_sec + 30)

    def recorded():
        return rpc.call("page.evaluate", {"expression": "window.__xResult"})["result"]

    # x.post replaces the restored draft and clicks the compose-page button.
    text = "hello from zigBrowser, café ✓"
    expect_equal("x.post", rpc.call("x.post", {"text": text, "compose_url": f"{base}?mode=compose"}), {"ok": True})
    expect_equal("posted text (stale draft replaced)", recorded(), {"text": text, "scheduled": None, "button": "tweetButton"})
    expect_equal("toast", rpc.call("dom.getText", {"selector": "testid=toast"})["text"], "Your post was sent.")
    passed.append("x.post")

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

    # Timeline layout: a hidden tweetButton decoy precedes the visible inline button.
    expect_equal("x.post home", rpc.call("x.post", {"text": "from the timeline", "compose_url": f"{base}?mode=home"}), {"ok": True})
    expect_equal("decoy skipped", recorded()["button"], "tweetButtonInline")
    passed.append("hidden-decoy")

    # A page command from another client waits for the whole flow (one queue turn).
    done: dict[str, float] = {}

    def racer():
        other = RpcClient(socket_path, timeout_sec + 30)
        time.sleep(0.15)
        other.call("page.title")
        done["title"] = time.monotonic()
        other.close()

    t = threading.Thread(target=racer)
    t.start()
    expect_equal("x.post racing", rpc.call("x.post", {"text": "no interleaving", "compose_url": f"{base}?mode=compose"}), {"ok": True})
    done["post"] = time.monotonic()
    t.join(timeout=timeout_sec + 30)
    if not ("title" in done and done["title"] >= done["post"]):
        raise AssertionError(f"page.title interleaved with the running x.post: {done}")
    expect_equal("racing text", recorded()["text"], "no interleaving")
    passed.append("single-queue-turn")

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

    base = FIXTURE.as_uri()
    with tempfile.TemporaryDirectory(prefix="zb-x-flows-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{base}?mode=compose", "--automation-api"],
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
            passed = run_scenarios(socket_path, base, args.timeout_sec)
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
