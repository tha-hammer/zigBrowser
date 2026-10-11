#!/usr/bin/env python3
"""N21 E2E: the social pacing state survives a restart of the REAL binary on
the same --profile-dir (<profile>/automation-pacing.json, mode 0600).

1. Start, set pacing (no delay, cap 100), do 2 linkedin.like actions on
   the local LinkedIn fixture: social.rate_status shows 98 left.
2. Stop and restart on the same profile: still 98 left, cap 100, and the
   file is 0600. A browser on a second profile starts at the defaults.
3. Corrupt the file and restart: defaults (100 left), and the browser's
   log says it fell back to defaults without printing the file's contents.
Never touches the live site. Exit 77 (skip) without a binary/display."""

from __future__ import annotations

import argparse
import os
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "sdk/python/src"))

from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file, stop_browser  # noqa: E402
from social_flows_test import LINKEDIN, FixtureServer, expect_equal, wait_for_socket  # noqa: E402
from zigbrowser import ZigBrowser  # noqa: E402

CORRUPT = '{"version": 1, "secret-looking-garbage-7f3a'


class Browser:
    """One run of the binary on `profile`; stderr is kept for log checks."""

    def __init__(self, prefix, env, binary: Path, origin: str, profile: Path, tmp: Path, run: int, timeout_sec: float):
        self.socket_path = tmp / f"automation-{run}.sock"
        self.stderr_path = tmp / f"stderr-{run}.log"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(self.socket_path)
        env["ZIGBROWSER_SOCIAL_FIXTURE_ORIGIN"] = origin
        self._stderr = self.stderr_path.open("w")
        self.proc = subprocess.Popen(
            prefix + [str(binary), f"{origin}/feed/", "--automation-api", "--profile-dir", str(profile)],
            stdout=subprocess.DEVNULL, stderr=self._stderr, text=True, env=env,
        )
        try:
            wait_for_socket(self.socket_path, timeout_sec)
        except BaseException:
            # A browser that never served its socket must not outlive the test.
            self.stop()
            raise

    def stop(self) -> None:
        stop_browser(self.proc)
        self._stderr.close()

    def log(self) -> str:
        return self.stderr_path.read_text(errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="zig-out/bin/zigBrowser")
    parser.add_argument("--timeout-sec", type=float, default=20.0)
    parser.add_argument("--prefer-xvfb", action="store_true")
    args = parser.parse_args()

    binary = Path(args.binary)
    for path, label in ((binary, "binary"), (LINKEDIN, "linkedin fixture")):
        if not require_file(path, label):
            return SKIP_EXIT
    runner = detect_runner(args.prefer_xvfb)
    if runner is None:
        return SKIP_EXIT
    prefix, env, runner_note = runner
    eprint(f"runner={runner_note}")

    passed: list[str] = []
    browser = None
    with FixtureServer() as server, tempfile.TemporaryDirectory(prefix="zb-pacing-") as tmp_name:
        tmp = Path(tmp_name)
        profile = tmp / "profile"
        state_file = profile / "automation-pacing.json"
        try:
            browser = Browser(prefix, env, binary, server.origin, profile, tmp, 1, args.timeout_sec)
            with ZigBrowser(socket_path=str(browser.socket_path)) as zb:
                zb.social.set_pacing(min_delay_ms=0, max_delay_ms=0, daily_cap=100)
                zb.cookies.set("li_at", "fixture-session", domain="127.0.0.1")
                for post in ("1", "2"):
                    expect_equal(f"like {post}", zb.linkedin.like(f"{server.origin}/feed/update/urn:li:activity:{post}/"), {"ok": True})
                expect_equal("remaining after 2 actions", zb.social.rate_status()["remaining_actions"], 98)
            browser.stop()
            mode = stat.S_IMODE(os.stat(state_file).st_mode)
            expect_equal("state file mode", oct(mode), oct(0o600))
            passed.append("saved")

            browser = Browser(prefix, env, binary, server.origin, profile, tmp, 2, args.timeout_sec)
            with ZigBrowser(socket_path=str(browser.socket_path)) as zb:
                status = zb.social.rate_status()
                expect_equal("remaining after restart", (status["remaining_actions"], status["daily_cap"]), (98, 100))
            browser.stop()
            passed.append("restored")

            other = tmp / "profile-b"
            browser = Browser(prefix, env, binary, server.origin, other, tmp, 4, args.timeout_sec)
            with ZigBrowser(socket_path=str(browser.socket_path)) as zb:
                status = zb.social.rate_status()
                expect_equal("another profile starts at the defaults", (status["remaining_actions"], status["daily_cap"]), (100, 100))
            browser.stop()
            passed.append("profile-isolation")

            state_file.write_text(CORRUPT)
            browser = Browser(prefix, env, binary, server.origin, profile, tmp, 3, args.timeout_sec)
            with ZigBrowser(socket_path=str(browser.socket_path)) as zb:
                status = zb.social.rate_status()
                expect_equal("defaults after a corrupt file", (status["remaining_actions"], status["daily_cap"]), (100, 100))
            browser.stop()
            log = browser.log()
            if "automation pacing" not in log or "using defaults" not in log:
                raise AssertionError(f"no fallback log line: {log[-600:]!r}")
            if "secret-looking-garbage" in log:
                raise AssertionError("the log printed the file's contents")
            passed.append("corrupt-defaults")
        except Exception as exc:  # noqa: BLE001 - report every failure the same way
            print("FAIL\tautomation-pacing-persist")
            eprint(f"error={exc!r}")
            if browser is not None:
                browser.stop()
                eprint(f"log={browser.log()[-800:]}")
            return 1

    for name in passed:
        print(f"PASS\t{name}")
    print("PASS\tautomation-pacing-persist")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
