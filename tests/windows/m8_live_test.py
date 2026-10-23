#!/usr/bin/env python3
r"""WS1.2: the m8 harness. Run the three m8 e2e tests on the Windows hosts from Linux, fail closed.

Plan rev 2.21, WS1.2 / WS1.2-W10 (thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md).
The m8 tests (tests/e2e/m8_render_test.py, m8_reply_channel_test.py, m8_load_fail_test.py) run ON Windows: each
starts the real zigBrowser.exe in the console session through slice2_common's interactive scheduled-task runner.
This driver is the Linux-side step command that puts them there, per configured host:

  1. checks the host identity: the provisioning nonce in %USERPROFILE%\zb\.gate-identity must equal
     ZB_WIN11_MARKER / ZB_WIN10_MARKER (required under ZB_WIN_GATE=1);
  2. stages the exe, the three tests, slice2_common.py and tests/fixtures/app/ under
     %USERPROFILE%\zb\runs\<id>\ (TEMP/TMP point inside it, so the tests write nothing outside zb\);
  3. runs each test with the host's Python, ZB_WIN_GATE=1 and ZB_ENABLE_M8_E2E=1, and requires exit 0, a PASS
     row and `ASSERTS <n>` with n > 0;
  4. fails if any zb_m8_* scheduled task is left on the host, deletes runs\<id>\ and fails if it survives.

Output (stdout): `HOST\t<label>\tidentity_marker=<nonce>`, one `RESULT\t<label>\t<test>\tPASS\tASSERTS <n>` or
`RESULT\t<label>\t<test>\tFAIL\t<reason>` per test, then one total `ASSERTS <n>`.

Exit codes: 0 only when every test passed on BOTH hosts. Under ZB_WIN_GATE=1: no host configured => 1
("NOT RUN: no Windows host configured"); one host only => that host runs, then 1 ("INCOMPLETE: both hosts are
required"); a missing exe, Python or marker => 1. Standalone (no ZB_WIN_GATE) a missing host or exe => 77.

Every ssh/scp runs with BatchMode=yes, IdentitiesOnly=yes, StrictHostKeyChecking=yes, the pinned known_hosts,
and DISPLAY, WAYLAND_DISPLAY, XAUTHORITY and SSH_ASKPASS removed. A host run needs NavyCanyon's exact-commit
approval and the orchestrator's release.

Run:  ZB_WIN_GATE=1 ZB_WIN11_HOST=127.0.0.1 ZB_WIN11_MARKER=<nonce> ZB_WIN_EXE=<zigBrowser.exe> \
      python3 -I tests/windows/m8_live_test.py
"""
import os
import pathlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # `python3 -I` drops the script dir
import webview2_cleanup  # noqa: E402  the ONE shared WebView2 run-folder cleanup (NavyCanyon 6dd7fda)

REPO = pathlib.Path(__file__).resolve().parents[2]
M8_TESTS = ("m8_render_test.py", "m8_reply_channel_test.py", "m8_load_fail_test.py")
STAGED_E2E = (*M8_TESTS, "slice2_common.py")
FIXTURE_DIR = REPO / "tests" / "fixtures" / "app"
SKIP_EXIT = 77
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE")
RUN_ID_RE = re.compile(r"^m8-[0-9]+-[0-9a-f]{12}$")
ASSERTS_RE = re.compile(r"^ASSERTS (\d+)\s*$", re.M)
TEST_TIMEOUT_SEC = 600
NO_HOST = "no Windows host configured"


def gated() -> bool:
    return os.environ.get("ZB_WIN_GATE") == "1"


def say(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def precondition_exit(reason: str) -> int:
    say(reason)
    if gated():
        say("ZB_WIN_GATE=1: precondition missing; a skip is a failure under the gate")
        return 1
    return SKIP_EXIT


class Host:
    def __init__(self, label: str, prefix: str, port: str, user: str, key: str, known_hosts: str,
                 python: str | None):
        env = os.environ
        self.label = label
        self.host = env.get(f"{prefix}_HOST", "")
        self.port = env.get(f"{prefix}_PORT", port)
        self.user = env.get(f"{prefix}_USER", user)
        self.key = env.get(f"{prefix}_KEY", key)
        self.known_hosts = env.get(f"{prefix}_KNOWN_HOSTS", known_hosts)
        self.marker = env.get(f"{prefix}_MARKER", "")
        self.python = env.get(f"{prefix}_PYTHON", python or "")
        self.marker_var = f"{prefix}_MARKER"
        self.python_var = f"{prefix}_PYTHON"

    def _opts(self) -> list[str]:
        return ["-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", "ConnectTimeout=15"]

    @staticmethod
    def _env() -> dict:
        return {k: v for k, v in os.environ.items() if k not in SCRUB}

    def ssh(self, command: str, timeout: int = 120) -> subprocess.CompletedProcess:
        argv = ["ssh", *self._opts(), "-p", self.port, f"{self.user}@{self.host}", command]
        return subprocess.run(argv, env=self._env(), capture_output=True, text=True, timeout=timeout)

    def scp_into(self, sources: list[str], remote_rel: str) -> subprocess.CompletedProcess:
        argv = ["scp", "-O", *self._opts(), "-P", self.port, "-r", *sources, f"{self.user}@{self.host}:{remote_rel}"]
        return subprocess.run(argv, env=self._env(), capture_output=True, text=True, timeout=300)


def configured_hosts() -> list[Host]:
    k = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
    kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
    hosts = [
        Host("win11", "ZB_WIN11", "2222", "zbtext", k, kh, r"C:\Python314\python.exe"),
        Host("win10", "ZB_WIN10", "22", "zbtest", "/home/maceo/vms/win11-m8/zb_win_key",
             "/home/maceo/vms/win10-fs/known_hosts", None),
    ]
    return [h for h in hosts if h.host]


def stage_local(exe: pathlib.Path) -> pathlib.Path:
    stage = pathlib.Path(tempfile.mkdtemp(prefix="zb-m8-stage-"))
    shutil.copy2(exe, stage / "zigBrowser.exe")
    e2e = stage / "tests" / "e2e"
    e2e.mkdir(parents=True)
    for name in STAGED_E2E:
        shutil.copy2(REPO / "tests" / "e2e" / name, e2e / name)
    shutil.copytree(FIXTURE_DIR, stage / "tests" / "fixtures" / "app")
    return stage


def run_on_host(h: Host, stage: pathlib.Path) -> tuple[bool, int]:
    """Run the three m8 tests on one host. Returns (all passed, asserts counted)."""
    ok = True
    total = 0
    mk = h.ssh(r'type "%USERPROFILE%\zb\.gate-identity"')
    seen = mk.stdout.strip() if mk.returncode == 0 else ""
    print(f"HOST\t{h.label}\tidentity_marker={seen or '<unreadable>'}", flush=True)
    if not seen or (h.marker and seen != h.marker) or (gated() and not h.marker):
        why = f"{h.marker_var} unset" if not h.marker else f"marker {seen!r} != {h.marker_var}"
        say(f"FAIL: wrong host {h.label} ({h.user}@{h.host}:{h.port}): {why}; ssh rc={mk.returncode} {mk.stderr.strip()}")
        return False, 0
    if not h.python:
        say(f"FAIL: {h.python_var} unset: no Windows Python known for {h.label}")
        return False, 0

    # The census of WebView2 helpers (and zigBrowser) before anything of this run starts; the run folder is removed
    # only once the census is back to it (webview2_cleanup). A census that cannot be read fails the host closed.
    try:
        before = webview2_cleanup.census(h.ssh)
    except webview2_cleanup.CensusError as e:
        say(f"FAIL: {h.label}: process census before the run: {e}")
        return False, 0

    run_id = f"m8-{os.getpid()}-{secrets.token_hex(6)}"
    assert RUN_ID_RE.match(run_id), run_id
    rel = f"zb/runs/{run_id}"
    win_dir = rf"%USERPROFILE%\zb\runs\{run_id}"
    try:
        mk = h.ssh(f'mkdir "{win_dir}\\tmp"')
        if mk.returncode != 0:
            say(f"FAIL: {h.label}: mkdir {win_dir} rc={mk.returncode}: {mk.stderr.strip()}")
            return False, 0
        cp = h.scp_into([str(stage / "zigBrowser.exe"), str(stage / "tests")], rel)
        if cp.returncode != 0:
            say(f"FAIL: {h.label}: staging scp rc={cp.returncode}: {cp.stderr.strip()}")
            return False, 0
        for name in M8_TESTS:
            stem = name[: -len(".py")]
            cmd = (f'cd /d "{win_dir}" && set "TEMP={win_dir}\\tmp" && set "TMP={win_dir}\\tmp" '
                   f'&& set "ZB_WIN_GATE=1" && set "ZB_ENABLE_M8_E2E=1" '
                   f'&& "{h.python}" -E -s tests\\e2e\\{name} --binary zigBrowser.exe')
            try:
                r = h.ssh(cmd, timeout=TEST_TIMEOUT_SEC)
            except subprocess.TimeoutExpired:
                print(f"RESULT\t{h.label}\t{stem}\tFAIL\tdriver timeout {TEST_TIMEOUT_SEC}s", flush=True)
                ok = False
                continue
            sys.stderr.write(f"--- {h.label} {stem} rc={r.returncode}\n{r.stdout}{r.stderr}")
            m = ASSERTS_RE.findall(r.stdout)
            n = int(m[-1]) if m else 0
            passed = re.search(r"^PASS\t", r.stdout, re.M) is not None
            if r.returncode == 0 and passed and n > 0:
                total += n
                print(f"RESULT\t{h.label}\t{stem}\tPASS\tASSERTS {n}", flush=True)
            else:
                why = f"rc={r.returncode}" if r.returncode else ("no PASS row" if not passed else "no ASSERTS n>0")
                print(f"RESULT\t{h.label}\t{stem}\tFAIL\t{why}", flush=True)
                ok = False
        tasks = h.ssh("schtasks /query /fo csv /nh")
        left = [line for line in tasks.stdout.splitlines() if "zb_m8_" in line]
        if tasks.returncode != 0 or left:
            say(f"FAIL: {h.label}: leftover scheduled tasks (rc={tasks.returncode}): {left}")
            ok = False
    finally:
        removed, why = webview2_cleanup.remove_after_webview2(h.ssh, win_dir, before)
        say(f"{h.label}: cleanup: {why}")
        if not removed:
            say(f"FAIL: {h.label}: {win_dir} cleanup failed: {why}")
            ok = False
    return ok, total


def main() -> int:
    hosts = configured_hosts()
    if not hosts:
        rc = precondition_exit(f"NOT RUN: {NO_HOST} (set ZB_WIN11_HOST and ZB_WIN10_HOST)")
        return rc
    exe_env = os.environ.get("ZB_WIN_EXE", "")
    exe = pathlib.Path(exe_env)
    if not exe_env or not exe.is_file():
        return precondition_exit(f"NOT RUN: ZB_WIN_EXE unset or missing: {exe_env!r}")

    stage = stage_local(exe)
    ok = True
    total = 0
    try:
        for h in hosts:
            host_ok, n = run_on_host(h, stage)
            ok = ok and host_ok
            total += n
    finally:
        shutil.rmtree(stage)
    print(f"ASSERTS {total}", flush=True)
    labels = {h.label for h in hosts}
    if labels != {"win11", "win10"}:
        say(f"INCOMPLETE: both hosts are required (ran: {', '.join(sorted(labels))})")
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
