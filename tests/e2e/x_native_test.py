#!/usr/bin/env python3
"""N14 E2E: x.post / x.schedule_post with options {input: "native",
humanize: true} against the real binary on tests/fixtures/x/composer.html
(served locally, never x.com).

Asserts what the fixture saw: the composer click, the typing and the Post
click are trusted (isTrusted) real input; the pointer moved (trusted
mousemoves) before the trusted Post click; the editor received one trusted
keydown and one trusted insertText beforeinput per character; keys came at
human pace (80-200 ms, 300-600 ms before a space, plus dispatch latency);
the posted text is exact. For x.schedule_post the schedule option and the
confirm button are trusted clicks too. Exit 77 (skip) without a
binary/display."""

from __future__ import annotations

import argparse
import signal
import subprocess
import tempfile
import threading
from pathlib import Path

from automation_core_test import RpcClient, _read_lines, terminate
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file
from x_flows_test import FIXTURE, HoldServer, expect_equal

NATIVE = {"input": "native", "humanize": True}
# Page-observed gaps add dispatch and acknowledgement latency to the
# scheduled pause, never less than it.
KEY_GAP = (80, 200 + 150)
WORD_GAP = (300, 600 + 150)


def check_typing(label: str, text: str, trust: list[str], key_times: list[float]) -> None:
    keydowns = [e for e in trust if e.startswith("keydown:tweetTextarea_0:")]
    inserts = [e for e in trust if e.startswith("beforeinput:tweetTextarea_0:")]
    expect_equal(f"{label}: one keydown per character", len(keydowns), len(text))
    if not all(e.endswith(":true") for e in keydowns):
        raise AssertionError(f"{label}: untrusted keydown in {keydowns}")
    trusted_inserts = [e for e in inserts if e.endswith(":true")]
    if len(trusted_inserts) < len(text):
        raise AssertionError(f"{label}: expected {len(text)} trusted beforeinputs, got {inserts}")
    expect_equal(f"{label}: keydown times recorded", len(key_times), len(text))
    for i in range(1, len(text)):
        gap = key_times[i] - key_times[i - 1]
        low, high = WORD_GAP if text[i] == " " else KEY_GAP
        if not low - 1 <= gap <= high:
            raise AssertionError(f"{label}: gap before {text[i]!r} (#{i}) was {gap:.1f} ms, outside {low}-{high}")


def check_click(label: str, trust: list[str], target: str) -> int:
    clicks = [i for i, e in enumerate(trust) if e.startswith(f"click:{target}:")]
    expect_equal(f"{label}: one click on {target}", len(clicks), 1)
    expect_equal(f"{label}: the click on {target} is trusted", trust[clicks[0]], f"click:{target}:true")
    return clicks[0]


def run_scenarios(socket_path: Path, server: HoldServer, timeout_sec: float) -> list[str]:
    passed: list[str] = []
    base = f"{server.base}/composer.html"
    rpc = RpcClient(socket_path, timeout_sec + 90)

    def page(expression: str):
        return rpc.call("page.evaluate", {"expression": expression})["result"]

    text = "hi there"
    expect_equal("native humanized x.post", rpc.call("x.post", {"text": text, "compose_url": f"{base}?mode=compose", "options": NATIVE}), {"ok": True})
    expect_equal("posted text", page("window.__xResult"), {"text": text, "scheduled": None, "button": "tweetButton"})
    trust = page("window.__xTrust")
    check_typing("x.post", text, trust, page("window.__xKeyTimes"))
    post = check_click("x.post", trust, "tweetButton")
    moves = [i for i, e in enumerate(trust) if e.startswith("mousemove:")]
    if not any(i < post for i in moves) or not all(trust[i].endswith(":true") for i in moves):
        raise AssertionError(f"x.post: expected trusted mousemoves before the Post click, got {trust}")
    if trust[post - 1] != "mousemove:tweetButton:true":
        raise AssertionError(f"x.post: the pointer did not end on the Post button: {trust[max(0, post - 5):post + 1]}")
    if not any(e == "click:tweetTextarea_0:true" for e in trust[:post]):
        raise AssertionError(f"x.post: the composer was not focused by a trusted click: {trust}")
    expect_equal("one post", page("window.__xPosts"), 1)
    passed.append("x.post native humanized")

    sched = rpc.call("x.schedule_post", {"text": "later", "date": "2026-11-05", "time": "14:07",
                                        "compose_url": f"{base}?mode=compose", "options": NATIVE})
    expect_equal("native humanized x.schedule_post", sched, {"ok": True, "scheduledFor": "2026-11-05T14:07"})
    result = page("window.__xResult")
    expect_equal("scheduled text", result["text"], "later")
    expect_equal("scheduled for", result["scheduled"], {"month": "11", "day": "5", "year": "2026", "hour": "2", "minute": "7", "ampm": "PM"})
    trust = page("window.__xTrust")
    check_typing("x.schedule_post", "later", trust, page("window.__xKeyTimes"))
    option = check_click("x.schedule_post", trust, "scheduleOption")
    confirm = check_click("x.schedule_post", trust, "scheduledConfirmationPrimaryAction")
    post = check_click("x.schedule_post", trust, "tweetButton")
    if not option < confirm < post:
        raise AssertionError(f"x.schedule_post: clicks out of order: option {option}, confirm {confirm}, post {post}")
    passed.append("x.schedule_post native humanized")

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

    with HoldServer() as server, tempfile.TemporaryDirectory(prefix="zb-x-native-") as tmp:
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
            print("FAIL\tx-native")
            eprint(f"error={exc!r}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1
        rc = terminate(proc)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tx-native-clean-shutdown")
            eprint(f"return={rc}")
            return 1

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tx-native")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
