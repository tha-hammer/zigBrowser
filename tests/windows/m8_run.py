#!/usr/bin/env python3
r"""WS1.2: build ZB_BUILD_COMMIT on the Win11 VM, check what was published, run the m8 harness on it, clean up.

The reviewed caller NavyCanyon f52ef80 asks for, so no step of an m8 host run is left to hand:
  1. requires the Win11 configuration (ZB_WIN11_HOST/PORT/USER/KEY/KNOWN_HOSTS/MARKER and ZB_BUILD_COMMIT; no
     default key), and removes every ZB_WIN10_*, the legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS and ZB_HOST_LIVE from
     the environment of every child, so a leaked selector cannot reach the Win10 box;
  2. checks the host identity marker (%USERPROFILE%\zb\.gate-identity == ZB_WIN11_MARKER), then takes the WebView2
     process census BEFORE the build (webview2_cleanup.census);
  3. builds the full sha of ZB_BUILD_COMMIT with tests/windows/build-on-windows.sh (no step argument);
  4. resolves the published ZB_WIN_EXE once and requires the sibling `<exe>.sha` to equal the full commit, then
     prints `EXE\t<resolved path>\tsha256=<hex>\tcommit=<sha>`;
  5. runs tests/windows/m8_live_test.py with ZB_WIN_EXE set to that resolved path;
  6. always removes %USERPROFILE%\zb\build\run-<sha> through webview2_cleanup.remove_after_webview2 with the before
     census: the bounded wait, never kill, one rmdir. It deletes nothing else, and a failed cleanup fails the run.

Exit: the m8 harness's exit code when the provenance and the cleanup hold (a Win11-only run is 1, "INCOMPLETE: both
hosts are required"), else 1. A missing precondition is 1 under ZB_WIN_GATE=1, else 77. A host run needs
NavyCanyon's exact-commit approval and the orchestrator's release.

Run:  env -u ZB_WIN10_HOST ... ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_PORT=2222 ZB_WIN11_USER=zbtext \
      ZB_WIN11_KEY=... ZB_WIN11_KNOWN_HOSTS=... ZB_WIN11_MARKER=<nonce> ZB_BUILD_COMMIT=<full sha> \
      ZB_BUILD_MODE=ReleaseSafe python3 -I tests/windows/m8_run.py
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # `python3 -I` drops the script dir
import webview2_cleanup  # noqa: E402  the ONE shared WebView2 run-folder cleanup

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = REPO / "tests" / "windows" / "build-on-windows.sh"
M8 = REPO / "tests" / "windows" / "m8_live_test.py"
SKIP_EXIT = 77
REQUIRED = ("ZB_WIN11_HOST", "ZB_WIN11_PORT", "ZB_WIN11_USER", "ZB_WIN11_KEY", "ZB_WIN11_KNOWN_HOSTS",
            "ZB_WIN11_MARKER", "ZB_BUILD_COMMIT")
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE",
         "ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS", "ZB_HOST_LIVE")
BUILD_TIMEOUT_SEC = 1800
M8_TIMEOUT_SEC = 3600


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def child_env() -> dict:
    return {k: v for k, v in os.environ.items() if k not in SCRUB and not k.startswith("ZB_WIN10_")}


def precondition_exit(reason: str) -> int:
    say(reason)
    if os.environ.get("ZB_WIN_GATE") == "1":
        say("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


def published(exe_surface: str, sha: str) -> tuple[pathlib.Path | None, str]:
    """(resolved exe, why): the exe the surface points at, only if its sibling .sha is the full commit."""
    exe = pathlib.Path(os.path.realpath(exe_surface))
    try:
        recorded = (exe.parent / (exe.name + ".sha")).read_text().strip()
    except OSError as e:
        return None, f"provenance: no {exe.name}.sha next to {exe}: {e}"
    if recorded != sha:
        return None, f"provenance: {exe}.sha records {recorded!r}, not the commit {sha}"
    if not exe.is_file():
        return None, f"provenance: {exe} is not a file"
    return exe, ""


def main() -> int:
    missing = [k for k in REQUIRED if not os.environ.get(k)]
    if missing:
        return precondition_exit(f"NOT RUN: the Win11 configuration is incomplete: {' '.join(missing)} unset")
    env = child_env()
    ssh = ["ssh", "-i", env["ZB_WIN11_KEY"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
           "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={env['ZB_WIN11_KNOWN_HOSTS']}",
           "-o", "ConnectTimeout=15", "-p", env["ZB_WIN11_PORT"], f"{env['ZB_WIN11_USER']}@{env['ZB_WIN11_HOST']}"]

    def on_host(command, timeout=300):
        return subprocess.run(ssh + [command], env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)

    rev = subprocess.run(["git", "rev-parse", "--verify", env["ZB_BUILD_COMMIT"] + "^{commit}"], cwd=REPO, env=env,
                         capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    sha = rev.stdout.strip()
    if rev.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        say(f"FAIL: cannot resolve ZB_BUILD_COMMIT to a full sha: {rev.stderr.strip()}")
        return 1

    ident = on_host(r'type "%USERPROFILE%\zb\.gate-identity"', timeout=120)
    seen = ident.stdout.strip() if ident.returncode == 0 else ""
    print(f"HOST\twin11\tidentity_marker={seen or '<unreadable>'}", flush=True)
    if seen != env["ZB_WIN11_MARKER"]:
        say(f"FAIL: wrong host: marker {seen!r} != ZB_WIN11_MARKER (ssh rc={ident.returncode} {ident.stderr.strip()})")
        return 1
    try:
        before = webview2_cleanup.census(on_host)
    except webview2_cleanup.CensusError as e:
        say(f"FAIL: process census before the build: {e}")
        return 1

    rc = 1
    try:
        build = subprocess.run(["bash", str(BUILD)], cwd=REPO, env=env, capture_output=True, text=True,
                               timeout=BUILD_TIMEOUT_SEC, stdin=subprocess.DEVNULL)
        sys.stderr.write(build.stderr)
        if build.returncode != 0:
            say(f"FAIL: build-on-windows.sh rc={build.returncode}")
        else:
            exe, why = published(env.get("ZB_WIN_EXE", str(REPO / "zig-out" / "win" / "current" / "zigBrowser.exe")), sha)
            if exe is None:
                say(f"FAIL: {why}")
            else:
                digest = hashlib.sha256(exe.read_bytes()).hexdigest()
                print(f"EXE\t{exe}\tsha256={digest}\tcommit={sha}", flush=True)
                m8 = subprocess.run(["python3", "-I", str(M8)], cwd=REPO, env={**env, "ZB_WIN_EXE": str(exe)},
                                    timeout=M8_TIMEOUT_SEC, stdin=subprocess.DEVNULL)
                rc = m8.returncode
    finally:
        removed, why = webview2_cleanup.remove_after_webview2(on_host, rf"%USERPROFILE%\zb\build\run-{sha}", before)
        say(f"build folder cleanup: {why}")
    if not removed:
        say(f"FAIL: the build folder cleanup failed: {why}")
        return 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
