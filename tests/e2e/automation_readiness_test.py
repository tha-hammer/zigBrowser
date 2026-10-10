#!/usr/bin/env python3
"""E2E: a first-RPC dom.waitFor during a slow initial load keeps the script's
timeout authoritative.

The fixture delays /core by more than the engine's 1 s native grace. The very
first socket request is dom.waitFor on a selector that never appears. The
answer must be the script's element_not_found (reason=timeout), not a native
action_timeout caused by readiness eating the grace, and it must arrive
within the request's deadline plus the grace."""

from __future__ import annotations

import argparse
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from automation_core_test import RpcClient, _read_lines, terminate
from automation_fixture_server import AutomationFixtureServer
from slice2_common import SKIP_EXIT, detect_runner, eprint, require_file

LOAD_DELAY_S = 2.0
WAIT_TIMEOUT_MS = 3000
NATIVE_GRACE_S = 1.0


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

    with AutomationFixtureServer(core_delay_s=LOAD_DELAY_S) as fixture, tempfile.TemporaryDirectory(prefix="zb-readiness-") as tmp:
        socket_path = Path(tmp) / "automation.sock"
        env = dict(env)
        env["ZIGBROWSER_SOCKET"] = str(socket_path)
        proc = subprocess.Popen(
            prefix + [str(browser), f"{fixture.base_url}/core", "--automation-api"],
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
            rpc = RpcClient(socket_path, args.timeout_sec)
            sent_at = time.monotonic()
            response = rpc.raw("dom.waitFor", {"selector": "css=#never", "state": "attached", "timeout_ms": WAIT_TIMEOUT_MS})
            elapsed = time.monotonic() - sent_at
            served_at = fixture.core_served_at
            rpc.close()
            if served_at is None or served_at < sent_at:
                raise AssertionError(f"waitFor was not sent during the initial load (sent={sent_at}, served={served_at})")
            error = response.get("error") or {}
            if error.get("code") != -32001 or (error.get("data") or {}).get("reason") != "timeout":
                raise AssertionError(f"expected script element_not_found/timeout, got {response}")
            if elapsed > WAIT_TIMEOUT_MS / 1000 + NATIVE_GRACE_S + 0.5:
                raise AssertionError(f"answer took {elapsed:.2f}s, beyond deadline + grace")
        except Exception as exc:
            print("FAIL\tautomation-readiness-waitfor")
            eprint(f"error={exc}")
            eprint(f"stderr={stderr_lines[-20:]}")
            terminate(proc)
            return 1

        rc = terminate(proc)
        if rc not in (0, 130, -signal.SIGINT):
            print("FAIL\tautomation-readiness-clean-shutdown")
            eprint(f"return={rc}")
            return 1

    print(f"PASS\tautomation-readiness-waitfor ({elapsed:.2f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
