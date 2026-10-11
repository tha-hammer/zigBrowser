#!/usr/bin/env python3
"""Python SDK against the REAL binary (not MockUDSServer).

Launches zigBrowser with --automation-api on the fixture server and drives it
only through `zigbrowser.ZigBrowser`: navigate -> type -> click -> getText,
plus a failing selector that must surface as AutomationError with a trace id
that telemetry.query can resolve. Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from automation_fixture_server import AutomationFixtureServer  # noqa: E402
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from zigbrowser import AutomationError, ZigBrowser  # noqa: E402


def wait_for_socket(path: Path, timeout_sec: float) -> None:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"socket {path} never appeared")


def expect_equal(label: str, actual, expected) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")


def scenario(zb: ZigBrowser, base_url: str) -> None:
    expect_equal("navigate", zb.page.navigate(f"{base_url}/core", timeout_ms=15000), {"ok": True})
    expect_equal("title", zb.page.title(), {"title": "zigBrowser Core Fixture"})

    expect_equal("type", zb.dom.type("css=#search", "zig sdk"), {"ok": True})
    expect_equal("typed mirror", zb.dom.get_text("css=#mirror"), {"text": "zig sdk"})

    zb.page.evaluate("window.__armLate(150)")
    expect_equal("click", zb.dom.click("css=#late", timeout_ms=5000), {"ok": True})
    expect_equal("getText after click", zb.dom.get_text("css=#late-status"), {"text": "clicked"})

    try:
        zb.dom.click("css=#does-not-exist", timeout_ms=200)
    except AutomationError as err:
        expect_equal("error code", err.code, -32001)
        expect_equal("error name", err.error_name, "element_not_found")
        if not err.trace_id:
            raise AssertionError("AutomationError without trace_id")
        spans = zb.call("telemetry.query", {"trace_id": err.trace_id})["spans"]
        expect_equal("trace root", spans[0]["name"], "automation.command")
        expect_equal("trace method", spans[0]["attributes"]["rpc.method"], "dom.click")
    else:
        raise AssertionError("missing selector did not raise AutomationError")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    browser = Path(args.binary)
    if not require_file(browser, "binary"):
        return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    with AutomationFixtureServer() as fixture, tempfile.TemporaryDirectory(prefix="zb-sdk-py-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{fixture.base_url}/nav-a", "--automation-api"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            wait_for_socket(socket_path, args.timeout_sec)
            with ZigBrowser(socket_path=str(socket_path)) as zb:
                scenario(zb, fixture.base_url)
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tsdk-python-live")
            eprint(f"error={exc!r}")
            stop_browser(proc, grace_sec=0)
            return 1
        finally:
            stop_browser(proc)

    print("PASS\tsdk-python-live")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
