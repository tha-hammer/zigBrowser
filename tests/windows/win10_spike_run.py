#!/usr/bin/env python3
r"""Copy-to-Win10 spike driver (WS2b.1-W10): build a Windows spike on the Win11 VM, run it on the Win10 box.

The Win10 box (zbtest) has no build toolchain, so run_on_win10(build_step, exe, inputs, required, tag):
  1. requires BOTH host configurations, ZB_WIN11_* and ZB_WIN10_* HOST/PORT/USER/KEY/KNOWN_HOSTS/MARKER (no default
     key), and ZB_BUILD_COMMIT; every child (the build driver, ssh, scp, git) gets an environment without any
     ZB_WIN10_*, the legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS or ZB_HOST_LIVE, so no selector leaks to the build;
  2. checks both identity markers (%USERPROFILE%\zb\.gate-identity), takes the WebView2 process census on both
     hosts (webview2_cleanup.census) and refuses a Win10 run folder that already exists, all BEFORE the build;
  3. builds the full sha with tests/windows/build-on-windows.sh <build_step> on Win11 (a step that installs the exe
     and runs nothing), fetches zig-out/bin/<exe> from %USERPROFILE%\zb\build\run-<sha> over the legacy scp
     protocol (-O), requires a PE (MZ), prints `EXE\t<path>\tsha256=<hex>\tcommit=<sha>`, and always removes that
     Win11 build folder through webview2_cleanup.remove_after_webview2 with the Win11 before census;
  4. stages the exe and `inputs`, taken from the exact commit (`git show <sha>:<path>`), into
     %USERPROFILE%\zb\build\run-<sha> on Win10, the only folder it writes there, each copy over scp -O;
  5. runs `<exe> <input names>` in that folder over ssh, requires exit 0, no FAIL line and an `ok` line for every
     name in `required`, and prints `ASSERTS <number of ok lines>`;
  6. removes the Win10 run folder through remove_after_webview2 with the Win10 before census, always once THIS run
     created it (an explicit ownership flag, set only after its `mkdir` of the previously absent folder succeeded);
     a failed create stages, runs and deletes nothing there (NavyCanyon 8974649e). It deletes nothing else, never
     kills, never retries; a failed cleanup on either host fails the run.
Then `PASS\t<tag>`, exit 0. A missing precondition is 1 under ZB_WIN_GATE=1, else 77.

A host run needs NavyCanyon's exact-commit approval and the orchestrator's release; the first Win10 build run also
waits for GrayHarbor's approved read-only Win10 probe (marker, scp -O, WebView2 runtime). Hostless proof:
tests/windows/win10_spike_run_selftest.py (fake TEST-NET transport, inside a network namespace).
"""
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # `python3 -I` drops the script dir
import scp_legacy  # noqa: E402  every copy over the legacy scp protocol (-O)
import webview2_cleanup  # noqa: E402  the ONE shared WebView2 run-folder cleanup

REPO = pathlib.Path(__file__).resolve().parents[2]
BUILD = REPO / "tests" / "windows" / "build-on-windows.sh"
SKIP_EXIT = 77
FIELDS = ("HOST", "PORT", "USER", "KEY", "KNOWN_HOSTS", "MARKER")
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE",
         "ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS", "ZB_HOST_LIVE")
BUILD_TIMEOUT_SEC = 1800
COPY_TIMEOUT_SEC = 300
RUN_TIMEOUT_SEC = 900


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def precondition_exit(reason: str) -> int:
    say(reason)
    if os.environ.get("ZB_WIN_GATE") == "1":
        say("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


def child_env() -> dict:
    return {k: v for k, v in os.environ.items() if k not in SCRUB and not k.startswith("ZB_WIN10_")}


class Host:
    """One Windows host from its ZB_<prefix>_* configuration; every command and copy is pinned and BatchMode."""

    def __init__(self, name: str, prefix: str, env: dict):
        self.name = name
        self.host, self.port, self.user, self.key, self.kh, self.marker = (
            os.environ[f"ZB_{prefix}_{f}"] for f in ("HOST", "PORT", "USER", "KEY", "KNOWN_HOSTS", "MARKER"))
        self.env = env

    def _opts(self) -> list:
        return ["-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "ConnectTimeout=15"]

    def run(self, command: str, timeout: float = 300):
        return subprocess.run(["ssh", *self._opts(), "-p", self.port, f"{self.user}@{self.host}", command],
                              env=self.env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def copy(self, src: str, dst: str):
        return subprocess.run(scp_legacy.scp_argv(*self._opts(), "-P", self.port, src, dst), env=self.env,
                              capture_output=True, text=True, timeout=COPY_TIMEOUT_SEC, stdin=subprocess.DEVNULL)

    def remote(self, rel: str) -> str:
        return f"{self.user}@{self.host}:{rel}"


def verdict(run, required) -> int:
    out = run.stdout + "\n" + run.stderr
    oks = re.findall(r"^ok   (.+?)\s*$", out, re.M)
    fails = re.findall(r"^FAIL (.+?)\s*$", out, re.M)
    missing = [name for name in required if name not in oks]
    print(f"ASSERTS {len(oks)}", flush=True)
    if run.returncode != 0 or fails or missing or not oks:
        say(f"FAIL: spike rc={run.returncode}; {len(fails)} FAIL line(s); missing ok: {missing}")
        return 1
    return 0


def run_on_win10(build_step: str, exe_name: str, inputs: tuple, required: tuple, tag: str) -> int:
    missing = [f"ZB_{p}_{f}" for p in ("WIN11", "WIN10") for f in FIELDS if not os.environ.get(f"ZB_{p}_{f}")]
    missing += [] if os.environ.get("ZB_BUILD_COMMIT") else ["ZB_BUILD_COMMIT"]
    if missing:
        return precondition_exit(f"NOT RUN: the two-host configuration is incomplete: {' '.join(missing)} unset")
    env = child_env()
    win11, win10 = Host("win11", "WIN11", env), Host("win10", "WIN10", env)

    rev = subprocess.run(["git", "rev-parse", "--verify", os.environ["ZB_BUILD_COMMIT"] + "^{commit}"], cwd=REPO,
                         env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    sha = rev.stdout.strip()
    if rev.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        say(f"FAIL: cannot resolve ZB_BUILD_COMMIT to a full sha: {rev.stderr.strip()}")
        return 1
    win_dir = rf"%USERPROFILE%\zb\build\run-{sha}"
    rel_dir = f"zb/build/run-{sha}"

    for host in (win11, win10):
        ident = host.run(r'type "%USERPROFILE%\zb\.gate-identity"', timeout=120)
        seen = ident.stdout.strip() if ident.returncode == 0 else ""
        print(f"HOST\t{host.name}\tidentity_marker={seen or '<unreadable>'}", flush=True)
        if seen != host.marker:
            say(f"FAIL: wrong host: {host.name} marker {seen!r} != its configured marker "
                f"(ssh rc={ident.returncode} {ident.stderr.strip()})")
            return 1
    try:
        before11 = webview2_cleanup.census(win11.run)
        before10 = webview2_cleanup.census(win10.run)
    except webview2_cleanup.CensusError as e:
        say(f"FAIL: process census before the build: {e}")
        return 1
    present = win10.run(f'if exist "{win_dir}\\" (echo PRESENT) else (echo ABSENT)', timeout=120)
    if present.returncode != 0 or present.stdout.strip() != "ABSENT":
        say(f"FAIL: the Win10 run folder {win_dir} is not absent ({present.stdout.strip()!r}, rc={present.returncode});"
            " nothing is staged or deleted")
        return 1

    with tempfile.TemporaryDirectory(prefix="zb-w10-") as tmp:
        exe = pathlib.Path(tmp) / exe_name
        fetched = False
        try:  # Win11: build and fetch; the build folder is always removed once the build started
            build = subprocess.run(["bash", str(BUILD), build_step], cwd=REPO, env=env, capture_output=True, text=True,
                                   timeout=BUILD_TIMEOUT_SEC, stdin=subprocess.DEVNULL)
            sys.stderr.write(build.stderr)
            if build.returncode != 0:
                say(f"FAIL: build-on-windows.sh {build_step} rc={build.returncode}")
            else:
                cp = win11.copy(win11.remote(f"{rel_dir}/zig-out/bin/{exe_name}"), str(exe))
                if cp.returncode != 0 or not exe.is_file() or exe.read_bytes()[:2] != b"MZ":
                    say(f"FAIL: fetching {exe_name} from {win11.name} (scp rc={cp.returncode} {cp.stderr.strip()})")
                else:
                    fetched = True
        finally:
            removed11, why11 = webview2_cleanup.remove_after_webview2(win11.run, win_dir, before11)
            say(f"win11 build folder cleanup: {why11}")
        if not removed11:
            say(f"FAIL: the Win11 build folder cleanup failed: {why11}")
            return 1
        if not fetched:
            return 1
        print(f"EXE\t{exe}\tsha256={hashlib.sha256(exe.read_bytes()).hexdigest()}\tcommit={sha}", flush=True)

        staged = [exe]
        for rel in inputs:  # the spike's inputs exactly as the commit has them
            show = subprocess.run(["git", "show", f"{sha}:{rel}"], cwd=REPO, env=env, capture_output=True, timeout=60,
                                  stdin=subprocess.DEVNULL)
            if show.returncode != 0:
                say(f"FAIL: git show {sha}:{rel}: {show.stderr.decode(errors='replace').strip()}")
                return 1
            path = pathlib.Path(tmp) / pathlib.PurePosixPath(rel).name
            path.write_bytes(show.stdout)
            staged.append(path)

        rc = 1
        owned = False  # True only once THIS run created the (previously absent) Win10 run folder
        removed10, why10 = False, ""
        try:  # Win10: create, stage and run; only a folder this run created is ever removed
            made = win10.run(f'mkdir "{win_dir}"', timeout=120)
            if made.returncode != 0:
                say(f"FAIL: mkdir {win_dir} on {win10.name}: rc={made.returncode} {made.stderr.strip()}; this run did "
                    "not create it, so nothing is staged, run or deleted there")
            else:
                owned = True
                for path in staged:
                    cp = win10.copy(str(path), win10.remote(f"{rel_dir}/{path.name}"))
                    if cp.returncode != 0:
                        say(f"FAIL: staging {path.name} on {win10.name}: scp rc={cp.returncode} {cp.stderr.strip()}")
                        break
                else:
                    names = " ".join(p.name for p in staged[1:])
                    run = win10.run(f'cd /d "{win_dir}" && {exe_name} {names}', timeout=RUN_TIMEOUT_SEC)
                    sys.stdout.write(run.stdout)
                    sys.stderr.write(run.stderr)
                    rc = verdict(run, required)
        finally:
            if owned:
                removed10, why10 = webview2_cleanup.remove_after_webview2(win10.run, win_dir, before10)
                say(f"win10 run folder cleanup: {why10}")
        if not owned:
            return 1
        if not removed10:
            say(f"FAIL: the Win10 run folder cleanup failed: {why10}")
            return 1
    if rc == 0:
        print(f"PASS\t{tag}", flush=True)
    return rc
