#!/usr/bin/env python3
"""WS0 gate selftest (Linux-side) — drives tests/windows/gate.sh against fake ssh/tar/virsh.

RED for the Windows two-host gate. Every case invokes `tests/windows/gate.sh`; today it does not
exist, so each case errors (FileNotFoundError) — that is the red. Each case encodes the exact
behavior the gate must have, so they go green once gate.sh exists and behaves. This file is NOT
registered in build.zig until the green commit (red stays outside gate-registered steps; it
registers then as `windows-gate-selftest`).

Hardened per review of e36f5fa (RoseCat, d8d79d8) so the future green cannot false-pass:
  * Every stage case asserts the gate's return code and that every expected fake actually ran
    (a gate that exits before doing the work cannot pass).
  * Display-clean (WS0.3) is observed for EVERY child (ssh, tar, virsh), via one shared env log.
  * The tar-redirection check uses a stderr SENTINEL the fake tar emits; `tar ... 2>/dev/null`
    in the gate would swallow it, so the gate's captured stderr must contain it.
  * The partial-tar case requires tar to have run AND the exit code to propagate (plus a named
    diagnostic), so "tar never invoked" cannot satisfy it.
  * WS0.8 parses the FULL, non-conflicting ssh option set, not one substring.
  * WS0.5 is a property: a deterministic adversarial generator checked against an INDEPENDENT
    normalization oracle (implemented differently from the gate's ntpath approach).
  * Each case runs with a private HOME, never the host's real HOME.

Run alone:  python3 -I tests/windows/gate_selftest.py -v
"""
import os
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"
_BASE_PATH = "/usr/bin:/bin"
TAR_SENTINEL = "ZB_TAR_STDERR_SENTINEL"

# The gate derives the fence root from ZB_GUEST_USER; win11-m8's account is zbtext (Windows 10
# uses zbtest). One representative user exercises the seam.
_TEST_USER = os.environ.get("ZB_GUEST_USER", "zbtext")

# Each fake records: that it ran (RAN_LOG), its argv (<TOOL>_LOG), and any display var it still
# sees (shared ENV_LOG, tagged by tool). virsh also answers canned domstate/domuuid.
_FAKE_COMMON = r"""
tool="{tool}"
[ -n "${{ZB_SELFTEST_RAN_LOG:-}}" ] && printf '%s\n' "$tool" >> "$ZB_SELFTEST_RAN_LOG"
[ -n "${{ZB_SELFTEST_ENV_LOG:-}}" ] && for v in DISPLAY WAYLAND_DISPLAY XAUTHORITY; do
  if [ -n "${{!v:-}}" ]; then printf '%s %s=%s\n' "$tool" "$v" "${{!v}}" >> "$ZB_SELFTEST_ENV_LOG"; fi
done
"""

_SSH_STUB = _FAKE_COMMON.format(tool="ssh") + r"""
[ -n "${ZB_SELFTEST_SSH_LOG:-}" ] && printf '%s\n' "$*" >> "$ZB_SELFTEST_SSH_LOG"
exit 0
"""

_TAR_STUB = _FAKE_COMMON.format(tool="tar") + r"""
[ -n "${ZB_SELFTEST_TAR_LOG:-}" ] && printf '%s\n' "$*" >> "$ZB_SELFTEST_TAR_LOG"
echo "%(sentinel)s" >&2
if [ -n "${ZB_SELFTEST_TAR_FAIL:-}" ]; then exit 2; fi
exit 0
""" % {"sentinel": TAR_SENTINEL}

_VIRSH_STUB = _FAKE_COMMON.format(tool="virsh") + r"""
case "$1" in
  domstate) echo "${ZB_SELFTEST_VIRSH_STATE:-running}" ;;
  domuuid)  echo "${ZB_SELFTEST_VIRSH_UUID:-f6e88ab5-3481-463e-b19b-e793b695f02c}" ;;
  *)        : ;;
esac
exit 0
"""


def _write_stub(path: pathlib.Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)


def _fakes(bindir: pathlib.Path) -> str:
    _write_stub(bindir / "ssh", _SSH_STUB)
    _write_stub(bindir / "tar", _TAR_STUB)
    _write_stub(bindir / "virsh", _VIRSH_STUB)
    return str(bindir)


# ---- independent WS0.5 oracle (NOT ntpath; a hand-rolled stack normalizer) ----------------
def oracle_allowed(path: str, user: str) -> bool:
    root = ["c:", "users", user.lower(), "zb"]
    s = path.replace("/", "\\")
    if s.startswith("\\\\"):                      # UNC
        return False
    if len(s) < 2 or s[1] != ":" or not s[0].isalpha():
        return False                              # not drive-absolute
    drive = s[:2].lower()
    rest = s[2:]
    if not rest.startswith("\\"):                 # drive-relative (C:foo)
        return False
    stack = []
    for seg in rest.split("\\"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not stack:
                return False                      # escapes the drive root
            stack.pop()
        else:
            stack.append(seg.lower())
    comps = [drive] + stack
    return len(comps) > len(root) and comps[: len(root)] == root


def generate_paths(user: str):
    """Deterministic adversarial corpus: separators, case, drive/UNC, dot segments, prefix collisions."""
    out = []
    # legitimate sub-paths (various separators / case) — must ALLOW
    out += [
        rf"C:\Users\{user}\zb\a\b",
        f"C:/Users/{user}/zb/x/y",
        rf"C:\Users\{user}\zb\.\runs\1",
        rf"c:\USERS\{user.upper()}\ZB\deep\path",
        rf"C:\Users\{user}\zb\a\..\b",            # stays inside
    ]
    # escapes / wrong drive / UNC / relative — must DENY
    out += [
        r"..\x",
        rf"C:\Users\{user}\zb\..\..\Windows\System32",
        rf"C:/Users/{user}/zb/../secret",
        r"\\server\share\x",
        r"\\127.0.0.1\c$\x",
        r"C:\Windows\System32",
        r"D:\x",
        r"Z:\Users\%s\zb\x" % user,
        r"relative\segment",
        r"C:zb\x",                                # drive-relative
    ]
    # prefix collisions — must DENY (component-aware, not startswith)
    out += [
        rf"C:\Users\{user}\zbEVIL\x",
        rf"C:\Users\{user}\zb2\x",
        rf"C:\Users\{user}\zbbackup",
        rf"C:\Users\{user}EVIL\zb\x",
        rf"C:\Users\{user}\zb",                   # the root itself (not a strict sub-path) -> DENY
    ]
    # dedupe, keep order
    seen = set()
    uniq = []
    for p in out:
        if p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


class _GateCase(unittest.TestCase):
    def _run_gate(self, env_overrides, bindir, args=None, home=None):
        env = {"PATH": bindir + os.pathsep + _BASE_PATH, "HOME": home or "/nonexistent-zb-home"}
        env.update(env_overrides)
        # Direct invocation: with gate.sh absent this raises FileNotFoundError (the red).
        return subprocess.run(
            [str(GATE), *(args or [])],
            env=env, capture_output=True, text=True, timeout=120,
        )

    def _stage_env(self, td: pathlib.Path):
        """A configured fake Win11 host + per-case logs + pinned known_hosts, with private HOME."""
        home = td / "home"; home.mkdir()
        kh = td / "known_hosts"; kh.write_text("# pinned\n")
        logs = {k: td / f"{k}.log" for k in ("ran", "ssh", "tar", "env")}
        env = {
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222",
            "ZB_WIN11_DOMAIN": "win11-m8", "ZB_GUEST_USER": _TEST_USER,
            "ZB_WIN_KEY": str(td / "fake_key"), "ZB_WIN_KNOWN_HOSTS": str(kh),
            "ZB_SELFTEST_RAN_LOG": str(logs["ran"]), "ZB_SELFTEST_SSH_LOG": str(logs["ssh"]),
            "ZB_SELFTEST_TAR_LOG": str(logs["tar"]), "ZB_SELFTEST_ENV_LOG": str(logs["env"]),
        }
        (td / "fake_key").write_text("x")
        return env, str(home), kh, logs

    @staticmethod
    def _read(p: pathlib.Path) -> str:
        return p.read_text() if p.exists() else ""


class FailClosedTests(_GateCase):
    def test_no_windows_host_configured_fails_closed(self):
        """WS0.2: neither ZB_WIN10_HOST nor ZB_WIN11_HOST set => fail closed."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            proc = self._run_gate({}, _fakes(td), home=str(home))
            detail = f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "must exit nonzero" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr, detail)
            self.assertIn("ZB_WIN10_HOST", proc.stderr, detail)


class StageHealthyTests(_GateCase):
    def test_healthy_stage_exits_zero_and_runs_every_expected_fake(self):
        """Finding 1: a healthy --selftest-stage must exit 0 and actually run ssh AND tar."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, _kh, logs = self._stage_env(td)
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "healthy stage must exit 0" + detail)
            ran = self._read(logs["ran"])
            self.assertIn("tar", ran, "tar must run" + detail)
            self.assertIn("ssh", ran, "ssh must run" + detail)


class NoDisplayTests(_GateCase):
    def test_no_child_sees_the_linux_display(self):
        """WS0.3 (findings 1,2): with DISPLAY set, a HEALTHY stage runs and NO child carries display vars."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, _kh, logs = self._stage_env(td)
            env.update({"DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0",
                        "XAUTHORITY": str(td / ".Xauthority")})
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\nenv_log:\n{self._read(logs['env'])}"
            self.assertEqual(proc.returncode, 0, "stage must succeed so the scrub is actually exercised" + detail)
            ran = self._read(logs["ran"])
            self.assertIn("tar", ran, "tar must run" + detail)
            self.assertIn("ssh", ran, "ssh must run" + detail)
            env_log = self._read(logs["env"])
            self.assertNotIn("DISPLAY=", env_log, "a child inherited DISPLAY/WAYLAND/XAUTHORITY" + detail)
            self.assertNotIn("XAUTHORITY=", env_log, detail)


class PathFenceTests(_GateCase):
    def _allowed(self, path, bindir, home):
        proc = self._run_gate({"ZB_GUEST_USER": _TEST_USER}, bindir, args=["--allowed-path", path], home=home)
        out = (proc.stdout or "").strip()
        self.assertIn(out, ("ALLOW", "DENY"), f"--allowed-path must print ALLOW/DENY, got {out!r}")
        return out == "ALLOW"

    def test_fence_matches_independent_oracle_over_generated_corpus(self):
        """WS0.5 property: gate agrees with an independent oracle across the adversarial corpus."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            corpus = generate_paths(_TEST_USER)
            # sanity: the corpus is non-trivial (has both expected outcomes)
            exp = {p: oracle_allowed(p, _TEST_USER) for p in corpus}
            self.assertTrue(any(exp.values()) and not all(exp.values()), "corpus must contain ALLOW and DENY")
            for p in corpus:
                self.assertEqual(self._allowed(p, bindir, str(home)), exp[p],
                                 f"gate disagrees with oracle on {p!r} (oracle={exp[p]})")

    def test_prefix_collision_is_denied(self):
        """Explicit anchor: the prefix-not-subdir case a naive startswith would wrongly allow."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            self.assertFalse(self._allowed(rf"C:\Users\{_TEST_USER}\zbEVIL\x", bindir, str(home)))
            self.assertTrue(self._allowed(rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png", bindir, str(home)))


class TransportHygieneTests(_GateCase):
    _REQUIRED = ("StrictHostKeyChecking=yes", "BatchMode=yes", "ConnectTimeout=15", "IdentitiesOnly=yes")
    _FORBIDDEN = ("StrictHostKeyChecking=no", "UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=accept-new")

    def test_full_ssh_option_set_and_tar_stderr_not_swallowed(self):
        """WS0.8 (findings 1,3,5): healthy stage; full non-conflicting ssh opts; tar stderr reaches the gate."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, kh, logs = self._stage_env(td)
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\nssh_log:\n{self._read(logs['ssh'])}"
            self.assertEqual(proc.returncode, 0, "healthy stage must exit 0" + detail)
            ssh_argv = self._read(logs["ssh"])
            tar_argv = self._read(logs["tar"])
            self.assertTrue(ssh_argv and tar_argv, "ssh and tar must both have run" + detail)
            for opt in self._REQUIRED:
                self.assertIn(opt, ssh_argv, f"ssh must pass {opt}" + detail)
            self.assertIn(f"UserKnownHostsFile={kh}", ssh_argv, "ssh must pin the configured known_hosts" + detail)
            for bad in self._FORBIDDEN:
                self.assertNotIn(bad, ssh_argv, f"ssh must not pass {bad}" + detail)
            self.assertNotIn("2>/dev/null", tar_argv, "tar argv must not contain a redirection token" + detail)
            # the real check for a swallowed redirection: tar's stderr sentinel must reach the gate's stderr
            self.assertIn(TAR_SENTINEL, proc.stderr, "tar stderr was swallowed (a parent 2>/dev/null)" + detail)

    def test_partial_tar_fails_the_gate_with_diagnostic(self):
        """WS0.8 (finding 4): tar must have run AND its nonzero exit must propagate with a named diagnostic."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, _kh, logs = self._stage_env(td)
            env["ZB_SELFTEST_TAR_FAIL"] = "1"
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\nran:\n{self._read(logs['ran'])}"
            self.assertIn("tar", self._read(logs["ran"]), "tar must actually have been invoked" + detail)
            self.assertEqual(proc.returncode, 2, "the gate must propagate tar's exit code (2)" + detail)
            self.assertIn("tar failed", proc.stderr, "the gate must name the tar failure" + detail)


if __name__ == "__main__":
    unittest.main()
