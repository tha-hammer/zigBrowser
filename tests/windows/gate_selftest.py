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
  * WS0.5 lexical property runs on a NAMED string-fence seam (`gate.sh --fence-string`) over the full
    separator×case×head×dot×tail CROSS PRODUCT, checked against an INDEPENDENT hand-rolled oracle.
  * Reparse resolution is MANDATORY: `gate.sh --allowed-path` always runs the resolver (the env hook
    only replaces it) and fails CLOSED on resolver failure, empty, multiline/malformed output, a
    missing resolver, or a resolved path that escapes the root.
  * ssh options are checked against OpenSSH's own grammar via `ssh -G` (case-insensitive keywords,
    both `Key=val` and `Key val`), with a separate scan that rejects any conflicting occurrence.
  * Each case runs with a private HOME, never the host's real HOME.

Run alone:  python3 -I tests/windows/gate_selftest.py -v
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"
RESOLVE = REPO / "tests" / "windows" / "resolve_path.sh"
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
# When the PRODUCTION default resolver (resolve_path.sh) calls ssh to run a remote powershell
# EncodedCommand, stand in for the host so the no-override path is exercised hermetically:
# optionally fail, or print a canned resolved path on stdout.
case " $* " in
  *powershell*EncodedCommand*)
    if [ -n "${ZB_SELFTEST_RESOLVE_FAIL:-}" ]; then exit 3; fi
    # Stand in for the host: resolve_path.sh reads line 1 = length, line 2 = resolved path.
    if [ -n "${ZB_SELFTEST_RESOLVE_OUT:-}" ] || [ -n "${ZB_SELFTEST_RESOLVE_N:-}" ]; then
      printf '%s\n%s\n' "${ZB_SELFTEST_RESOLVE_N:-50}" "${ZB_SELFTEST_RESOLVE_OUT:-}"
    fi
    exit 0
    ;;
esac
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
        # ZB_GATE_ROOT pins the repo root explicitly so the gate resolves it WITHOUT git — the suite must be
        # green from a clean git-archive export (no .git), not only from a checkout (RoseCat 7335). An
        # override can still unset it (the negative no-root test builds its own env instead).
        env = {"PATH": bindir + os.pathsep + _BASE_PATH, "HOME": home or "/nonexistent-zb-home",
               "ZB_GATE_ROOT": str(REPO)}
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
        """WS0.2: neither ZB_WIN10_HOST nor ZB_WIN11_HOST set => fail closed, naming both."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            proc = self._run_gate({}, _fakes(td), home=str(home))
            detail = f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "must exit nonzero" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr, detail)
            self.assertIn("ZB_WIN10_HOST", proc.stderr, detail)
            self.assertIn("ZB_WIN11_HOST", proc.stderr, detail)

    def test_fail_closed_when_only_win10_configured(self):
        """WS0.2: EITHER host missing must fail closed. Win10 set, Win11 missing => fail, name Win11."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            proc = self._run_gate({"ZB_WIN10_HOST": "zbtest@10.0.0.9"}, _fakes(td), home=str(home))
            detail = f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "one host is not a two-host gate" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr, detail)
            self.assertIn("ZB_WIN11_HOST", proc.stderr, detail)

    def test_fail_closed_when_only_win11_configured(self):
        """WS0.2: Win11 set, Win10 missing => fail, name Win10."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            proc = self._run_gate({"ZB_WIN11_HOST": "127.0.0.1"}, _fakes(td), home=str(home))
            detail = f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "one host is not a two-host gate" + detail)
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
    _DISPLAY = {"DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0", "XAUTHORITY": "/home/x/.Xauthority"}

    def test_no_child_of_any_class_sees_the_linux_display(self):
        """WS0.3: with DISPLAY/WAYLAND/XAUTHORITY in the gate's env, the whole-gate scrub keeps every
        child class — python (fence), ssh and tar (stage) — display-free; each is observed to run."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, _kh, logs = self._stage_env(td)   # shared ran/env logs across both invocations
            bindir = _fakes(td)
            # (1) stage: exercises the ssh and tar child classes
            e1 = dict(env); e1.update(self._DISPLAY)
            p1 = self._run_gate(e1, bindir, args=["--selftest-stage"], home=home)
            self.assertEqual(p1.returncode, 0, f"stage must succeed\n{p1.stderr}")
            # (2) fence: exercises the python child class
            e2 = dict(env); e2.update(self._DISPLAY)
            p2 = self._run_gate(e2, bindir, args=["--fence-string", rf"C:\Users\{_TEST_USER}\zb\x"], home=home)
            self.assertEqual((p2.stdout or "").strip(), "ALLOW", f"fence must run\n{p2.stderr}")
            ran = self._read(logs["ran"])
            for child in ("python", "ssh", "tar"):
                self.assertIn(child, ran, f"the {child} child must actually run (else nothing is observed)")
            env_log = self._read(logs["env"])
            detail = f"\nenv_log:\n{env_log}"
            for v in ("DISPLAY=", "WAYLAND_DISPLAY=", "XAUTHORITY="):
                self.assertNotIn(v, env_log, f"a child inherited {v}" + detail)

    def test_hostile_sentinel_cannot_defeat_the_scrub(self):
        """The scrub must be UNCONDITIONAL: a caller pre-setting the old ZB_GATE_SCRUBBED marker
        (or any sentinel) must not skip it and leak DISPLAY to a child."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, _kh, logs = self._stage_env(td)
            env.update(self._DISPLAY)
            env["ZB_GATE_SCRUBBED"] = "1"   # hostile: pretend the scrub already happened
            proc = self._run_gate(env, _fakes(td), args=["--fence-string", rf"C:\Users\{_TEST_USER}\zb\x"], home=home)
            self.assertEqual((proc.stdout or "").strip(), "ALLOW", f"fence must run\n{proc.stderr}")
            self.assertIn("python", self._read(logs["ran"]), "the python child must run")
            env_log = self._read(logs["env"])
            self.assertNotIn("DISPLAY=", env_log, "a hostile ZB_GATE_SCRUBBED must NOT defeat the scrub\n" + env_log)


class PathFenceTests(_GateCase):
    def _fence(self, path, bindir, home):
        """The LEXICAL seam (string normalization only)."""
        proc = self._run_gate({"ZB_GUEST_USER": _TEST_USER}, bindir, args=["--fence-string", path], home=home)
        out = (proc.stdout or "").strip()
        self.assertIn(out, ("ALLOW", "DENY"), f"--fence-string must print ALLOW/DENY, got {out!r}")
        return out == "ALLOW"

    def _allowed(self, path, bindir, home, resolver=None):
        """The full fence: lexical + MANDATORY reparse resolution."""
        env = {"ZB_GUEST_USER": _TEST_USER}
        if resolver is not None:
            env["ZB_RESOLVE_CMD"] = resolver
        proc = self._run_gate(env, bindir, args=["--allowed-path", path], home=home)
        out = (proc.stdout or "").strip()
        self.assertIn(out, ("ALLOW", "DENY"), f"--allowed-path must print ALLOW/DENY, got {out!r}")
        return out == "ALLOW"

    @staticmethod
    def _resolver(td, body):
        r = td / f"resolve_{abs(hash(body)) % 10000}.sh"
        r.write_text("#!/usr/bin/env bash\n" + body)
        r.chmod(0o755)
        return str(r)

    def test_lexical_fence_matches_oracle_over_cross_product(self):
        """WS0.5 property on the named string-fence seam: gate --fence-string == independent oracle,
        over the full separator×case×head×dot×tail cross product (interaction mutants cannot survive)."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            corpus = generate_paths(_TEST_USER)
            exp = {p: oracle_allowed(p, _TEST_USER) for p in corpus}
            self.assertGreaterEqual(len(corpus), 100, "property corpus should be combinatorial, not a handful")
            self.assertTrue(any(exp.values()) and not all(exp.values()), "corpus must contain ALLOW and DENY")
            for p in corpus:
                self.assertEqual(self._fence(p, bindir, str(home)), exp[p],
                                 f"lexical fence disagrees with oracle on {p!r} (oracle={exp[p]})")

    def test_prefix_collision_is_denied(self):
        """Explicit anchor: the prefix-not-subdir case a naive startswith would wrongly allow."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            self.assertFalse(self._fence(rf"C:\Users\{_TEST_USER}\zbEVIL\x", bindir, str(home)))
            self.assertTrue(self._fence(rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png", bindir, str(home)))

    def test_allowed_path_resolution_is_mandatory_and_fails_closed(self):
        """WS0.5 reparse: --allowed-path ALWAYS resolves; the env hook only REPLACES the resolver.
        Junction escape, resolver failure, empty, multiline/malformed, and a missing resolver all DENY."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            bindir = _fakes(td)
            good = rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png"   # string-OK sub-path
            identity = self._resolver(td, 'printf "%s\\n" "$1"\n')
            self.assertTrue(self._allowed(good, bindir, str(home), resolver=identity),
                            "a real sub-path with an identity resolver must be ALLOWED")
            escape = self._resolver(td, 'printf "%s\\n" "C:\\\\Windows\\\\System32"\n')
            self.assertFalse(self._allowed(good, bindir, str(home), resolver=escape),
                             "a junction resolving outside the root must be DENIED")
            failing = self._resolver(td, 'exit 7\n')
            self.assertFalse(self._allowed(good, bindir, str(home), resolver=failing),
                             "a resolver that fails must DENY (fail closed)")
            empty = self._resolver(td, 'exit 0\n')
            self.assertFalse(self._allowed(good, bindir, str(home), resolver=empty),
                             "a resolver with empty output must DENY")
            multi = self._resolver(td, 'printf "%s\\n%s\\n" "$1" "$1"\n')
            self.assertFalse(self._allowed(good, bindir, str(home), resolver=multi),
                             "a resolver with multiline/malformed output must DENY")
            self.assertFalse(self._allowed(good, bindir, str(home), resolver=str(td / "nope.sh")),
                             "a missing resolver must DENY (resolution is mandatory)")

    def test_default_resolver_rejects_zero_and_truncated_length(self):
        """The default resolver's zero (GetFinalPathNameByHandle==0) and n>=buffer (truncated)
        branches must fail closed -> the gate DENYs."""
        good = rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png"

        def verdict(extra):
            with tempfile.TemporaryDirectory() as t:
                td = pathlib.Path(t)
                env, home, _kh, _logs = self._stage_env(td)   # no ZB_RESOLVE_CMD: default resolver runs
                env.update(extra)
                proc = self._run_gate(env, _fakes(td), args=["--allowed-path", good], home=home)
                return (proc.stdout or "").strip()

        self.assertEqual(verdict({"ZB_SELFTEST_RESOLVE_OUT": good, "ZB_SELFTEST_RESOLVE_N": "0"}), "DENY",
                         "GetFinalPathNameByHandle returning 0 must DENY")
        self.assertEqual(verdict({"ZB_SELFTEST_RESOLVE_OUT": good, "ZB_SELFTEST_RESOLVE_N": "2000"}), "DENY",
                         "a resolved length >= the buffer (truncated) must DENY")

    def test_default_resolver_runs_without_override_and_fails_closed(self):
        """The PRODUCTION default resolver (gate.sh's resolve_path.sh) must actually run when no
        ZB_RESOLVE_CMD override is set — observed hermetically through the fake-SSH seam. Deleting
        the default-resolver code from gate.sh would make the escaping case fall back to a lexical
        ALLOW and fail this test."""
        good = rf"C:\Users\{_TEST_USER}\zb\runs\1\out.png"

        def verdict(extra):
            with tempfile.TemporaryDirectory() as t:
                td = pathlib.Path(t)
                env, home, _kh, logs = self._stage_env(td)   # sets host/user/key/known_hosts, NO ZB_RESOLVE_CMD
                env.update(extra)
                bindir = _fakes(td)
                proc = self._run_gate(env, bindir, args=["--allowed-path", good], home=home)
                out = (proc.stdout or "").strip()
                self.assertIn(out, ("ALLOW", "DENY"), f"got {out!r}\nstderr:\n{proc.stderr}")
                ran = self._read(logs["ran"])
                self.assertIn("ssh", ran, "the default resolver must reach the host via ssh (observed)")
                return out

        # default resolver returns an in-root path -> ALLOW (default path exercised end-to-end)
        self.assertEqual(verdict({"ZB_SELFTEST_RESOLVE_OUT": good}), "ALLOW")
        # default resolver returns an ESCAPING path -> DENY (deleting the default resolver survives only
        # if this fails: a lexical-only fallback would wrongly ALLOW the string-OK path)
        self.assertEqual(verdict({"ZB_SELFTEST_RESOLVE_OUT": r"C:\Windows\System32"}), "DENY")
        # default resolver's ssh fails -> DENY (fail closed)
        self.assertEqual(verdict({"ZB_SELFTEST_RESOLVE_FAIL": "1"}), "DENY")
        # default resolver returns empty -> DENY (fail closed)
        self.assertEqual(verdict({}), "DENY")


class TransportHygieneTests(_GateCase):
    # OpenSSH lowercases keywords in -G output and canonicalizes booleans (e.g. 10.0p2 emits
    # `stricthostkeychecking true` for the input `=yes`). The effective check accepts any ON
    # boolean; the raw scan below still requires the exact supplied value and rejects conflicts.
    _BOOL_ON = {"yes", "true", "on", "1"}
    _BOOL_KEYS = ("batchmode", "stricthostkeychecking", "identitiesonly")
    _EXACT_EFFECTIVE = {"connecttimeout": "15"}
    _RAW_SUPPLIED = {"batchmode": "yes", "stricthostkeychecking": "yes",
                     "connecttimeout": "15", "identitiesonly": "yes"}

    @staticmethod
    def _ssh_G_effective(argv_lines):
        """Resolve the EFFECTIVE ssh config the OpenSSH way (handles case-insensitive keys and both
        `Keyword=value` and `Keyword value` forms, first-occurrence-wins) without connecting."""
        ssh = shutil.which("ssh") or "/usr/bin/ssh"
        proc = subprocess.run([ssh, "-G", "-F", "/dev/null", *argv_lines],
                              capture_output=True, text=True, timeout=30)
        eff = {}
        for line in proc.stdout.splitlines():
            parts = line.split(None, 1)
            if parts:
                eff[parts[0].lower()] = parts[1] if len(parts) > 1 else ""
        return eff, proc

    @staticmethod
    def _raw_o_values(argv_lines):
        """key_lower -> set(values) for every -o, parsing BOTH `Key=val` and `Key val`, case-folded,
        so a conflicting occurrence is visible even when ssh -G would hide it (first wins)."""
        vals = {}
        i = 0
        while i < len(argv_lines):
            a = argv_lines[i]
            tok = None
            if a == "-o" and i + 1 < len(argv_lines):
                tok = argv_lines[i + 1]; i += 2
            elif a.startswith("-o") and len(a) > 2:
                tok = a[2:]; i += 1
            else:
                i += 1; continue
            if "=" in tok:
                k, v = tok.split("=", 1)
            else:
                parts = tok.split(None, 1)
                k, v = parts[0], (parts[1] if len(parts) > 1 else "")
            vals.setdefault(k.lower(), set()).add(v.strip())
        return vals

    def test_ssh_effective_options_no_conflicts_and_tar_stderr(self):
        """WS0.8 (findings 1,3,5): healthy stage; each security option's EFFECTIVE value (via ssh -G)
        is exactly approved; no conflicting occurrence in any grammar form; tar stderr reaches the gate."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env, home, kh, logs = self._stage_env(td)
            proc = self._run_gate(env, _fakes(td), args=["--selftest-stage"], home=home)
            detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}\nssh_log:\n{self._read(logs['ssh'])}"
            self.assertEqual(proc.returncode, 0, "healthy stage must exit 0" + detail)
            argv = self._read(logs["ssh"]).splitlines()
            tar_argv = self._read(logs["tar"])
            self.assertTrue(argv and tar_argv, "ssh and tar must both have run" + detail)
            # (a) effective config via ssh -G (OpenSSH grammar is authoritative). Booleans accept
            #     OpenSSH's canonical equivalents (yes==true==on), so a newer ssh that prints
            #     `stricthostkeychecking true` for `=yes` still passes.
            eff, gproc = self._ssh_G_effective(argv)
            self.assertEqual(gproc.returncode, 0, f"ssh -G failed: {gproc.stderr}" + detail)
            for k in self._BOOL_KEYS:
                self.assertIn((eff.get(k) or "").lower(), self._BOOL_ON,
                              f"effective ssh {k} must be an ON boolean, got {eff.get(k)!r}" + detail)
            for k, v in self._EXACT_EFFECTIVE.items():
                self.assertEqual(eff.get(k), v, f"effective ssh {k} must be {v!r}, got {eff.get(k)!r}" + detail)
            self.assertEqual(eff.get("userknownhostsfile"), str(kh),
                             "effective userknownhostsfile must be the configured pinned path" + detail)
            # (b) reject conflicting occurrences in the raw argv (both forms, case-folded), and
            #     require the exact SUPPLIED value the gate passes (`yes`), not a canonical alias.
            raw = self._raw_o_values(argv)
            for k, v in self._RAW_SUPPLIED.items():
                got = {x.lower() for x in raw.get(k, set())}
                self.assertTrue(got and got <= {v}, f"-o {k} conflicting/absent: {raw.get(k)}" + detail)
            ukh = raw.get("userknownhostsfile", set())
            self.assertTrue(ukh and ukh <= {str(kh)}, f"conflicting/absent UserKnownHostsFile: {ukh}" + detail)
            # (c) tar stderr sentinel reaches the gate (a parent 2>/dev/null would drop it)
            self.assertNotIn("2>/dev/null", tar_argv, "tar argv must not contain a redirection token" + detail)
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


class ResolvePathSafetyTests(unittest.TestCase):
    """SECURITY (item 1): resolve_path.sh must pass the Windows path to PowerShell as base64 DATA,
    never spliced into PowerShell source, so a quote/backtick/newline in a path cannot inject."""

    def _resolver_ssh_argv(self, path, td):
        bindir = _fakes(td)
        ssh_log = td / "ssh.log"
        env = {
            "PATH": bindir + os.pathsep + _BASE_PATH, "HOME": str(td),
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_GUEST_USER": _TEST_USER,
            "ZB_WIN_KEY": str(td / "k"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
            "ZB_SELFTEST_SSH_LOG": str(ssh_log),
        }
        (td / "k").write_text("x"); (td / "kh").write_text("#")
        subprocess.run([str(RESOLVE), path], env=env, capture_output=True, text=True, timeout=30)
        return ssh_log.read_text() if ssh_log.exists() else ""

    def test_path_is_encoded_data_not_powershell_source(self):
        import base64
        import re
        dangerous = [
            rf'C:\Users\{_TEST_USER}\zb\a"; Remove-Item C:\ -Recurse; "',  # quote break-out attempt
            rf'C:\Users\{_TEST_USER}\zb\a`b',                               # backtick (PS escape)
            'C:\\Users\\%s\\zb\\a\nb' % _TEST_USER,                         # embedded newline
        ]
        for path in dangerous:
            with tempfile.TemporaryDirectory() as t:
                argv = self._resolver_ssh_argv(path, pathlib.Path(t))
                self.assertIn("-EncodedCommand", argv, "resolver must deliver PS via -EncodedCommand")
                line = [l for l in argv.splitlines() if "-EncodedCommand" in l][0]
                b64 = line.split("-EncodedCommand", 1)[1].strip()
                ps = base64.b64decode(b64).decode("utf-16-le")
                # the raw dangerous path must NOT appear as PowerShell source
                self.assertNotIn(path, ps, f"raw path spliced into PS source: {path!r}")
                self.assertIn("FromBase64String(", ps, "PS must decode the path from base64 data")
                # and the embedded base64 must decode back to the exact path (pure data channel)
                m = re.search(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", ps)
                self.assertIsNotNone(m, "PS must carry the path as a base64 literal")
                self.assertEqual(base64.b64decode(m.group(1)).decode("utf-8"), path,
                                 "the path must round-trip through the base64 data channel unchanged")

    def _run_resolver(self, extra):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = _fakes(td)
            env = {
                "PATH": bindir + os.pathsep + _BASE_PATH, "HOME": str(td),
                "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_GUEST_USER": _TEST_USER,
                "ZB_WIN_KEY": str(td / "k"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
            }
            env.update(extra)
            (td / "k").write_text("x"); (td / "kh").write_text("#")
            return subprocess.run([str(RESOLVE), rf"C:\Users\{_TEST_USER}\zb\x"],
                                  env=env, capture_output=True, text=True, timeout=30)

    def test_resolver_rejects_zero_and_truncated_length(self):
        """resolve_path.sh's own bash branches: GetFinalPathNameByHandle==0 -> exit 4; length >=
        buffer -> exit 5; a normal length -> exit 0 and the resolved path on stdout."""
        good = rf"C:\Users\{_TEST_USER}\zb\x"
        p0 = self._run_resolver({"ZB_SELFTEST_RESOLVE_OUT": good, "ZB_SELFTEST_RESOLVE_N": "0"})
        self.assertEqual(p0.returncode, 4, f"zero length must exit 4\n{p0.stderr}")
        pc = self._run_resolver({"ZB_SELFTEST_RESOLVE_OUT": good, "ZB_SELFTEST_RESOLVE_N": "2000"})
        self.assertEqual(pc.returncode, 5, f"truncated length must exit 5\n{pc.stderr}")
        pn = self._run_resolver({"ZB_SELFTEST_RESOLVE_OUT": good, "ZB_SELFTEST_RESOLVE_N": "50"})
        self.assertEqual(pn.returncode, 0, f"normal length must exit 0\n{pn.stderr}")
        self.assertEqual(pn.stdout.strip(), good, "a normal resolve must print the resolved path")


class RootResolutionTests(_GateCase):
    """RoseCat 012e1bc: the gate must resolve its root from an explicit root or the Git root and FAIL
    CLOSED when neither exists — never silently `cd ""` and run in the caller's cwd (as an archive export
    without a .git did)."""

    def test_non_git_cwd_without_explicit_root_fails_closed(self):
        # cwd is a non-git dir and ZB_WIN* are unset; git rev-parse fails, so the gate must fail closed
        # with a clear message — not proceed (which the old `cd "$(git rev-parse ...)"` did via `cd ""`).
        with tempfile.TemporaryDirectory() as t:
            proc = subprocess.run([str(GATE), "--probe-only"], cwd=t,
                                  env={"PATH": _BASE_PATH, "HOME": t},
                                  capture_output=True, text=True, timeout=60)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "a non-git export without ZB_GATE_ROOT must fail closed" + detail)
            self.assertIn("cannot resolve a repo root", proc.stderr, detail)

    def test_explicit_gate_root_resolves_then_fails_on_no_host(self):
        # With ZB_GATE_ROOT set (git not consulted) from a non-git cwd, root resolution succeeds; the gate
        # then fails LATER for the EXACT downstream reason (no Windows host configured), proving it got past
        # root resolution and into the real checks.
        with tempfile.TemporaryDirectory() as t:
            proc = subprocess.run([str(GATE), "--probe-only"], cwd=t,
                                  env={"PATH": _BASE_PATH, "HOME": t, "ZB_GATE_ROOT": str(REPO)},
                                  capture_output=True, text=True, timeout=60)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotIn("cannot resolve a repo root", proc.stderr,
                             "an explicit ZB_GATE_ROOT must resolve the root" + detail)
            self.assertNotEqual(proc.returncode, 0, "no host configured must still fail" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr,
                          "resolution must reach the exact downstream no-host failure" + detail)

    def test_explicit_root_without_gate_is_rejected(self):
        # A ZB_GATE_ROOT that does not contain tests/windows/gate.sh must fail closed (not a blind cd).
        with tempfile.TemporaryDirectory() as t:
            proc = subprocess.run([str(GATE), "--probe-only"], cwd=t,
                                  env={"PATH": _BASE_PATH, "HOME": t, "ZB_GATE_ROOT": t},
                                  capture_output=True, text=True, timeout=60)
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "a root without the gate must fail closed" + detail)
            self.assertIn("cannot resolve a repo root", proc.stderr, detail)


if __name__ == "__main__":
    unittest.main()
