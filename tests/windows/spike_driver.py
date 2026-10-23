"""Shared Linux driver for the Windows C spikes that run through `build-on-windows.sh <step>` on the Win11 VM
(the shape of WS2a.0's tests/e2e/win_private_world_spike.py; first used by WS2b.1's
tests/e2e/win_trusted_input_matrix.py).

run_spike(step, required, tag): checks the host identity marker (%USERPROFILE%\\zb\\.gate-identity ==
ZB_WIN11_MARKER), builds and runs the spike step on the VM (a clean `git archive` of ZB_BUILD_COMMIT, default
HEAD), then requires exit 0, no FAIL line, and an `ok` line for every name in `required`; it prints
`ASSERTS <number of ok lines>`. Afterwards it removes the run's own folder, %USERPROFILE%\zb\build\run-<sha>, through
the ONE shared WebView2 cleanup (tests/windows/webview2_cleanup.py, NavyCanyon 6dd7fda): a process census taken
before the build, a bounded wait for it to return, then one plain rmdir; a cleanup failure fails the run. Under ZB_WIN_GATE=1 a missing host or marker exits 1 ("no Windows host
configured"); standalone it exits 77. A host run needs the reviewer's exact-commit approval and the
orchestrator's release.
"""
import os
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import webview2_cleanup  # noqa: E402

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = REPO / "tests" / "windows" / "build-on-windows.sh"
SKIP_EXIT = 77
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE")


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def precondition_exit(reason: str) -> int:
    say(reason)
    if os.environ.get("ZB_WIN_GATE") == "1":
        say("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


def run_spike(step: str, required: tuple, tag: str) -> int:
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
    ident = subprocess.run(ssh, env=env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)

    def on_host(command, timeout=300):
        return subprocess.run(ssh[:-1] + [command], env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)

    seen = ident.stdout.strip() if ident.returncode == 0 else ""
    print(f"HOST\twin11\tidentity_marker={seen or '<unreadable>'}", flush=True)
    if seen != marker:
        say(f"FAIL: wrong host: marker {seen!r} != ZB_WIN11_MARKER (ssh rc={ident.returncode} {ident.stderr.strip()})")
        return 1

    rev = subprocess.run(["git", "rev-parse", "--verify", env.get("ZB_BUILD_COMMIT", "HEAD") + "^{commit}"], cwd=REPO,
                         env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    sha = rev.stdout.strip()
    if rev.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        say(f"FAIL: cannot resolve ZB_BUILD_COMMIT: {rev.stderr.strip()}")
        return 1
    try:
        before = webview2_cleanup.census(on_host)
    except webview2_cleanup.CensusError as e:
        say(f"FAIL: process census before the run: {e}")
        return 1
    try:
        run = subprocess.run(["bash", str(BUILD), step], cwd=REPO, env=env, capture_output=True, text=True,
                             timeout=1800, stdin=subprocess.DEVNULL)
    finally:
        removed, why = webview2_cleanup.remove_after_webview2(on_host, rf"%USERPROFILE%\zb\build\run-{sha}", before)
        say(f"cleanup: {why}")
    sys.stderr.write(run.stderr)
    sys.stdout.write(run.stdout)
    out = run.stdout + "\n" + run.stderr  # zig build may relay the spike's lines on either stream
    oks = re.findall(r"^ok   (.+?)\s*$", out, re.M)
    fails = re.findall(r"^FAIL (.+?)\s*$", out, re.M)
    missing = [name for name in required if name not in oks]
    print(f"ASSERTS {len(oks)}", flush=True)
    if run.returncode != 0 or fails or missing or not oks:
        say(f"FAIL: spike rc={run.returncode}; {len(fails)} FAIL line(s); missing ok: {missing}")
        return 1
    if not removed:
        say(f"FAIL: the run folder cleanup failed: {why}")
        return 1
    print(f"PASS\t{tag}", flush=True)
    return 0
