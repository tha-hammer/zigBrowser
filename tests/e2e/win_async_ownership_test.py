#!/usr/bin/env python3
r"""WS2a.3 driver (Windows plan rev 2.21; UNREGISTERED until the WS2a.3 green, then step
windows-async-ownership-live in windows-live): the UI-thread marshal's waits are bounded.

Builds and runs tests/windows/ws2a3_async_ownership.c on the Win11 VM through
`tests/windows/build-on-windows.sh ws2a3-async-ownership-win` (a clean `git archive` of ZB_BUILD_COMMIT, default
HEAD, built with MSVC on the VM; host key pinned there). The test links the real shim and calls only the
production ABI (zb_app_run, zb_automation_get_title) plus the shim's inert WS2a.3 test seams. This driver first
checks the host identity marker (%USERPROFILE%\zb\.gate-identity == ZB_WIN11_MARKER), then requires: exit 0, no
FAIL line, and an `ok` line for every REQUIRED check below; it prints `ASSERTS <number of ok lines>`.

Plan assertion: a call whose job is still completing gives up within deadline + waiter grace (250 ms) with
TIMEOUT; no INFINITE wait remains in the marshal. Mutant: restore the INFINITE wait -> the call answers only
after the held completion -> red.

Under ZB_WIN_GATE=1 a missing host or marker exits 1 ("no Windows host configured"); standalone it exits 77.
A host run needs NavyCanyon's exact-commit approval and the orchestrator's release.

Run:  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_MARKER=<nonce> ZB_BUILD_COMMIT=<sha> \
      python3 -I tests/e2e/win_async_ownership_test.py
"""
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = REPO / "tests" / "windows" / "build-on-windows.sh"
STEP = "ws2a3-async-ownership-win"
SKIP_EXIT = 77
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE")
REQUIRED = (
    "the fixture loads",
    "an ordinary call answers at once",
    "no job is live between calls",
    "a call whose completion is held gives up within deadline + waiter grace (TIMEOUT)",
    "the timed-out call returns no result",
    "the held job is released once its completion ends (no leak)",
    "the loop still answers afterwards",
    "closing the window ends zb_app_run",
)


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def precondition_exit(reason: str) -> int:
    say(reason)
    if os.environ.get("ZB_WIN_GATE") == "1":
        say("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


def main() -> int:
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    host = env.get("ZB_WIN11_HOST", "")
    marker = env.get("ZB_WIN11_MARKER", "")
    if not host:
        return precondition_exit("NOT RUN: no Windows host configured (set ZB_WIN11_HOST)")
    if not marker:
        return precondition_exit("NOT RUN: ZB_WIN11_MARKER unset: the host identity cannot be checked")

    key = env.get("ZB_WIN11_KEY", env.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key"))
    kh = env.get("ZB_WIN11_KNOWN_HOSTS", env.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts"))
    ssh = ["ssh", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", f"UserKnownHostsFile={kh}", "-o", "ConnectTimeout=15", "-p", env.get("ZB_WIN11_PORT", "2222"),
           f"{env.get('ZB_WIN11_USER', 'zbtext')}@{host}", r'type "%USERPROFILE%\zb\.gate-identity"']
    ident = subprocess.run(ssh, env=env, capture_output=True, text=True, timeout=120)
    seen = ident.stdout.strip() if ident.returncode == 0 else ""
    print(f"HOST\twin11\tidentity_marker={seen or '<unreadable>'}", flush=True)
    if seen != marker:
        say(f"FAIL: wrong host: marker {seen!r} != ZB_WIN11_MARKER (ssh rc={ident.returncode} {ident.stderr.strip()})")
        return 1

    run = subprocess.run(["bash", str(BUILD), STEP], cwd=REPO, env=env, capture_output=True, text=True,
                         timeout=1800)
    sys.stderr.write(run.stderr)
    sys.stdout.write(run.stdout)
    out = run.stdout + "\n" + run.stderr  # zig build may relay the spike's lines on either stream
    oks = re.findall(r"^ok   (.+?)\s*$", out, re.M)
    fails = re.findall(r"^FAIL (.+?)\s*$", out, re.M)
    missing = [name for name in REQUIRED if name not in oks]
    print(f"ASSERTS {len(oks)}", flush=True)
    if run.returncode != 0 or fails or missing or not oks:
        say(f"FAIL: spike rc={run.returncode}; {len(fails)} FAIL line(s); missing ok: {missing}")
        return 1
    print("PASS\tws2a3-async-ownership", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
