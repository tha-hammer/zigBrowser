#!/usr/bin/env python3
"""WS0 gate selftest (Linux-side) — drives tests/windows/gate.sh against fake ssh/virsh/tar.

RED for the Windows two-host gate. Every case here fails today because `tests/windows/gate.sh`
does not exist: invoking it raises FileNotFoundError. Each case encodes the exact behavior the
gate must have, so they go green once gate.sh exists and behaves as specified. This file is
intentionally NOT registered in build.zig until the green commit (red stays outside gate-
registered steps; it registers then as the `windows-gate-selftest` step).

Cases implemented here (all pure-Linux, no Windows host needed — they run gate.sh against fakes):
  * WS0.2  the gate fails closed when no Windows host is configured (headline banner)
  * WS0.3  no child the gate starts carries DISPLAY / WAYLAND_DISPLAY / XAUTHORITY
  * WS0.5  the remote-path fence: allowed(path) is true only under C:\\Users\\zbtest\\zb\\
  * WS0.8  transport hygiene: StrictHostKeyChecking=yes, tar without 2>/dev/null, tar status checked

Cases that need a live host (WS0.1 probe schema, WS0.4 bounded/clean runner, WS0.6 VM identity /
down-VM, WS0.7 file-server fence) and the per-case mutants land in the GREEN commit. See the
Windows launch plan rev 2, section "WS0", for each assertion and mutant.

Contract gate.sh must honor for this selftest (implemented in green):
  * `gate.sh` with no ZB_WIN10_HOST/ZB_WIN11_HOST set -> prints the WS0.2 banner, exits nonzero.
  * `gate.sh --allowed-path <path>` -> prints exactly "ALLOW" or "DENY" and exits 0 (WS0.5 oracle).
  * `gate.sh --selftest-stage` -> performs the stage-to-host step against the configured host and
    exits (WS0.3 / WS0.8 observation point), honoring the ZB_SELFTEST_* record env below.
  * It must invoke `ssh`/`tar`/`virsh` only from PATH so these fakes intercept them.
  * ZB_SELFTEST_SSH_LOG / ZB_SELFTEST_TAR_LOG: files the fakes append their argv to.
  * ZB_SELFTEST_ENV_LOG: file the fake ssh appends any surviving display vars to.
  * ZB_SELFTEST_TAR_FAIL: when set, the fake tar exits 2 (partial-archive case).

Run alone:  python3 -I tests/windows/gate_selftest.py -v
"""
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"

# A minimal clean PATH so the gate under test never reaches the real ssh/virsh/tar/X on this box.
_BASE_PATH = "/usr/bin:/bin"

_SSH_STUB = r"""
if [ -n "${ZB_SELFTEST_SSH_LOG:-}" ]; then printf '%s\n' "$*" >> "$ZB_SELFTEST_SSH_LOG"; fi
if [ -n "${ZB_SELFTEST_ENV_LOG:-}" ]; then
  for v in DISPLAY WAYLAND_DISPLAY XAUTHORITY; do
    if [ -n "${!v:-}" ]; then printf '%s=%s\n' "$v" "${!v}" >> "$ZB_SELFTEST_ENV_LOG"; fi
  done
fi
exit 0
"""

_TAR_STUB = r"""
if [ -n "${ZB_SELFTEST_TAR_LOG:-}" ]; then printf '%s\n' "$*" >> "$ZB_SELFTEST_TAR_LOG"; fi
if [ -n "${ZB_SELFTEST_TAR_FAIL:-}" ]; then exit 2; fi
exit 0
"""

_VIRSH_STUB = r"""
case "$1" in
  domstate) echo "${ZB_SELFTEST_VIRSH_STATE:-running}" ;;
  domuuid)  echo "${ZB_SELFTEST_VIRSH_UUID:-f6e88ab5-3481-463e-b19b-e793b695f02c}" ;;
  *)        echo "fake-virsh $*" >&2 ;;
esac
exit 0
"""

# The test user is NOT hard-coded into the gate: the gate derives the fence root from
# ZB_GUEST_USER (as tests/guest/ssh.sh already does). This fixture drives one user through
# that seam. win11-m8's account is `zbtext` (the orchestrator confirmed the user typed it that
# way and we keep it); the physical Windows 10 file-server uses `zbtest`. The fence logic is the
# same either way, so one representative user exercises it.
_TEST_USER = os.environ.get("ZB_GUEST_USER", "zbtext")
_FENCE_ROOT = rf"C:\Users\{_TEST_USER}\zb"
_BAD_PATHS = [
    r"..\x",
    rf"C:\Users\{_TEST_USER}\zb\..\..\Windows\System32",
    r"\\server\share\x",             # UNC escape
    r"C:\Windows\System32",          # other dir
    r"D:\x",                         # other drive
    f"C:/Users/{_TEST_USER}/zb/../secret",  # mixed slashes + ..
    r"relative\segment",             # not absolute
    rf"C:\Users\{_TEST_USER}\zbEVIL\x",     # prefix-but-not-a-subdir (defeats naive startswith)
]
_GOOD_PATH = rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png"


def _write_stub(path: pathlib.Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)


def _fake_bin(dirpath: pathlib.Path) -> str:
    """Create ssh/tar/virsh stubs that never reach a real host. Returns the dir for PATH."""
    _write_stub(dirpath / "ssh", _SSH_STUB)
    _write_stub(dirpath / "tar", _TAR_STUB)
    _write_stub(dirpath / "virsh", _VIRSH_STUB)
    return str(dirpath)


def _fake_win11_env():
    """A healthy fake Win11 host so the gate proceeds past the fail-closed check (green)."""
    return {
        "ZB_WIN11_HOST": "127.0.0.1",
        "ZB_WIN11_PORT": "2222",
        "ZB_WIN11_DOMAIN": "win11-m8",
        "ZB_GUEST_USER": _TEST_USER,
    }


class _GateCase(unittest.TestCase):
    def _run_gate(self, env_overrides, path_prefix, args=None):
        env = {
            "PATH": path_prefix + os.pathsep + _BASE_PATH,
            "HOME": os.environ.get("HOME", "/tmp"),
        }
        env.update(env_overrides)
        # Direct invocation: with gate.sh absent this raises FileNotFoundError (the red).
        # subprocess.run fully reaps the child, so no ResourceWarning leaks.
        return subprocess.run(
            [str(GATE), *(args or [])],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )


class FailClosedTests(_GateCase):
    def test_no_windows_host_configured_fails_closed(self):
        """WS0.2 headline: neither ZB_WIN10_HOST nor ZB_WIN11_HOST set => fail closed."""
        with tempfile.TemporaryDirectory() as td:
            path_prefix = _fake_bin(pathlib.Path(td))
            proc = self._run_gate({}, path_prefix)
            detail = f"\n--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "gate must exit nonzero with no host" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr, detail)
            self.assertIn("ZB_WIN10_HOST", proc.stderr, detail)


class NoDisplayTests(_GateCase):
    def test_no_child_sees_the_linux_display(self):
        """WS0.3: with DISPLAY=:0 in the driver env, no child ssh carries any display var."""
        with tempfile.TemporaryDirectory() as td:
            tdp = pathlib.Path(td)
            path_prefix = _fake_bin(tdp)
            env_log = tdp / "env.log"
            env = _fake_win11_env()
            env.update({
                "DISPLAY": ":0",
                "WAYLAND_DISPLAY": "wayland-0",
                "XAUTHORITY": "/home/maceo/.Xauthority",
                "ZB_SELFTEST_ENV_LOG": str(env_log),
            })
            self._run_gate(env, path_prefix, args=["--selftest-stage"])
            recorded = env_log.read_text() if env_log.exists() else ""
            self.assertNotIn("DISPLAY=", recorded, "a child inherited DISPLAY")
            self.assertNotIn("WAYLAND_DISPLAY=", recorded, "a child inherited WAYLAND_DISPLAY")
            self.assertNotIn("XAUTHORITY=", recorded, "a child inherited XAUTHORITY")


class PathFenceTests(_GateCase):
    def _allowed(self, path, path_prefix):
        proc = self._run_gate({"ZB_GUEST_USER": _TEST_USER}, path_prefix, args=["--allowed-path", path])
        out = (proc.stdout or "").strip()
        self.assertIn(out, ("ALLOW", "DENY"), f"--allowed-path must print ALLOW/DENY, got {out!r}")
        return out == "ALLOW"

    def test_remote_path_fence(self):
        """WS0.5 property: allowed() is true only for a real subpath of the zbtest root."""
        with tempfile.TemporaryDirectory() as td:
            path_prefix = _fake_bin(pathlib.Path(td))
            for p in _BAD_PATHS:
                self.assertFalse(self._allowed(p, path_prefix), f"fence must DENY {p!r}")
            self.assertTrue(self._allowed(_GOOD_PATH, path_prefix), f"fence must ALLOW {_GOOD_PATH!r}")


class TransportHygieneTests(_GateCase):
    def test_strict_hostkey_and_checked_tar(self):
        """WS0.8: ssh pins host keys and tar runs without 2>/dev/null."""
        with tempfile.TemporaryDirectory() as td:
            tdp = pathlib.Path(td)
            path_prefix = _fake_bin(tdp)
            ssh_log = tdp / "ssh.log"
            tar_log = tdp / "tar.log"
            env = _fake_win11_env()
            env.update({"ZB_SELFTEST_SSH_LOG": str(ssh_log), "ZB_SELFTEST_TAR_LOG": str(tar_log)})
            self._run_gate(env, path_prefix, args=["--selftest-stage"])
            ssh_argv = ssh_log.read_text() if ssh_log.exists() else ""
            tar_argv = tar_log.read_text() if tar_log.exists() else ""
            self.assertIn("StrictHostKeyChecking=yes", ssh_argv, "ssh must pin host keys")
            self.assertNotIn("2>/dev/null", tar_argv, "tar output must not be swallowed")

    def test_partial_tar_fails_the_gate(self):
        """WS0.8: a tar that exits nonzero must fail the gate, not be ignored."""
        with tempfile.TemporaryDirectory() as td:
            path_prefix = _fake_bin(pathlib.Path(td))
            env = _fake_win11_env()
            env["ZB_SELFTEST_TAR_FAIL"] = "1"
            proc = self._run_gate(env, path_prefix, args=["--selftest-stage"])
            self.assertNotEqual(proc.returncode, 0, "a failed tar must fail the gate")


if __name__ == "__main__":
    unittest.main()
