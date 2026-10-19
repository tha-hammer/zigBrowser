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
  * WS0.5 is a property over the full separator×case×head×dot×tail CROSS PRODUCT, checked against
    an INDEPENDENT normalization oracle (hand-rolled, not ntpath), plus a fakeable reparse/junction
    seam so a path that string-normalizes inside the root but resolves outside is denied.
  * The ssh option set is parsed from argv boundaries (one arg per line), and each security key's
    effective value must be exactly the approved one with no conflicting duplicate.
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
# Record argv with boundaries (one arg per line), so the test parses real -o settings rather
# than substring-matching a flattened $* (BatchMode=yes followed by BatchMode=no must be caught).
if [ -n "${ZB_SELFTEST_SSH_LOG:-}" ]; then printf '%s\n' "$@" >> "$ZB_SELFTEST_SSH_LOG"; fi
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


def _apply_case(s: str, c: str) -> str:
    return s.upper() if c == "upper" else s.lower() if c == "lower" else s


def _apply_sep(s: str, sp: str) -> str:
    if sp == "/":
        return s.replace("\\", "/")
    if sp == "mix":  # alternate \ and / to exercise mixed separators
        out, flip = [], False
        for ch in s:
            if ch == "\\":
                out.append("/" if flip else "\\")
                flip = not flip
            else:
                out.append(ch)
        return "".join(out)
    return s


def generate_paths(user: str):
    """WS0.5 property corpus: the CROSS PRODUCT of separator × case × head × dot-segment × tail,
    so interaction mutants (one dimension right, another wrong) cannot survive."""
    heads = [
        rf"C:\Users\{user}\zb",            # correct root
        r"D:\Users\%s\zb" % user,          # wrong drive
        r"\\srv\share\Users\%s\zb" % user, # UNC
        rf"C:\Users\{user}\zbEVIL",        # prefix collision
        rf"C:\Users\{user}",               # parent (too short)
    ]
    dots = ["", r"\..\..\Windows", r"\.\sub"]   # none, escaping, dot-noop
    tails = [r"\x", r"\runs\1\out.png"]
    cases = ["asis", "upper", "lower"]
    seps = ["\\", "/", "mix"]
    paths = set()
    for head in heads:
        for dot in dots:
            for tail in tails:
                base = head + dot + tail
                for c in cases:
                    for sp in seps:
                        paths.add(_apply_sep(_apply_case(base, c), sp))
    return sorted(paths)


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
    def _allowed(self, path, bindir, home, extra_env=None):
        env = {"ZB_GUEST_USER": _TEST_USER}
        if extra_env:
            env.update(extra_env)
        proc = self._run_gate(env, bindir, args=["--allowed-path", path], home=home)
        out = (proc.stdout or "").strip()
        self.assertIn(out, ("ALLOW", "DENY"), f"--allowed-path must print ALLOW/DENY, got {out!r}")
        return out == "ALLOW"

    def test_fence_matches_independent_oracle_over_cross_product(self):
        """WS0.5 property: over the full separator×case×head×dot×tail cross product, the gate's
        verdict equals an INDEPENDENT oracle's — so an interaction mutant cannot survive."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            corpus = generate_paths(_TEST_USER)
            exp = {p: oracle_allowed(p, _TEST_USER) for p in corpus}
            self.assertGreaterEqual(len(corpus), 100, "property corpus should be combinatorial, not a handful")
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

    def test_junction_reparse_escape_is_denied(self):
        """WS0.5 reparse seam: a path that STRING-normalizes inside the root but whose resolver
        (a fakeable junction resolver) reports a target OUTSIDE the root must be DENIED."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            resolver = td / "resolve.sh"
            # The 'linkout' junction resolves outside the root; everything else is identity.
            resolver.write_text(
                "#!/usr/bin/env bash\n"
                'case "$1" in\n'
                '  *linkout*) printf "%s\\n" "C:\\\\Windows\\\\System32" ;;\n'
                '  *) printf "%s\\n" "$1" ;;\n'
                "esac\n"
            )
            resolver.chmod(0o755)
            env = {"ZB_RESOLVE_CMD": str(resolver)}
            escaping = rf"C:\Users\{_TEST_USER}\zb\linkout\x"   # string-OK, junction escapes
            safe = rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png"  # string-OK, resolver identity
            self.assertFalse(self._allowed(escaping, bindir, str(home), env),
                             "a junction resolving outside the root must be DENIED")
            self.assertTrue(self._allowed(safe, bindir, str(home), env),
                            "a real sub-path must still be ALLOWED when the resolver is identity")


class TransportHygieneTests(_GateCase):
    @staticmethod
    def _parse_ssh_opts(ssh_log_text):
        """Parse -o settings from argv recorded one-per-line. Returns {key: [values...]} so a
        conflicting duplicate (BatchMode=yes then BatchMode=no) is visible, not hidden by $*."""
        opts = {}
        lines = ssh_log_text.splitlines()
        i = 0
        while i < len(lines):
            a = lines[i]
            kv = None
            if a == "-o" and i + 1 < len(lines):
                kv = lines[i + 1]; i += 2
            elif a.startswith("-o") and len(a) > 2:
                kv = a[2:]; i += 1
            else:
                i += 1
                continue
            if "=" in kv:
                k, v = kv.split("=", 1)
                opts.setdefault(k, []).append(v)
        return opts

    def test_full_ssh_option_set_and_tar_stderr_not_swallowed(self):
        """WS0.8 (findings 1,3,5): healthy stage; each security option's EFFECTIVE value is exactly
        the approved one with no conflicting duplicate; tar stderr reaches the gate."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, kh, logs = self._stage_env(td)
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\nssh_log:\n{self._read(logs['ssh'])}"
            self.assertEqual(proc.returncode, 0, "healthy stage must exit 0" + detail)
            ssh_argv = self._read(logs["ssh"])
            tar_argv = self._read(logs["tar"])
            self.assertTrue(ssh_argv and tar_argv, "ssh and tar must both have run" + detail)
            opts = self._parse_ssh_opts(ssh_argv)
            approved = {
                "StrictHostKeyChecking": "yes",
                "BatchMode": "yes",
                "ConnectTimeout": "15",
                "IdentitiesOnly": "yes",
                "UserKnownHostsFile": str(kh),
            }
            for key, val in approved.items():
                vals = opts.get(key)
                self.assertIsNotNone(vals, f"ssh must pass -o {key}" + detail)
                # every occurrence must equal the approved value: no conflicting duplicate survives
                self.assertEqual(set(vals), {val},
                                 f"-o {key} effective value must be exactly {val!r} with no conflict, got {vals}" + detail)
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
