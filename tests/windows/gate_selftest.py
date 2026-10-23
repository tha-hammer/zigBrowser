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
  * WS0.5 LEXICAL shape check runs on `gate.sh --fence-string` (string normalization only; no FS access,
    no authorization claim) over the full separator×case×head×dot×tail CROSS PRODUCT, checked against an
    INDEPENDENT hand-rolled oracle. It is kept only as the WS0.3 python-child observation point.
  * The reparse-resolving remote-path fence (`--allowed-path` / `allowed_path` / resolve_path.sh) was
    REMOVED (a name-only check/use boundary cannot close the junction-swap TOCTOU; RoseCat / bead
    zigBrowser-q92). RemotePathFenceRemovedTests pins that it stays gone.
  * ssh options are checked against OpenSSH's own grammar via `ssh -G` (case-insensitive keywords,
    both `Key=val` and `Key val`), with a separate scan that rejects any conflicting occurrence.
  * Each case runs with a private HOME, never the host's real HOME.

Run alone:  python3 -I tests/windows/gate_selftest.py -v
"""
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"
# zigBrowser-ong.17: the fakes aim at TEST-NET with keys that do not exist; fake_transport.problem is checked on
# every gate run's env and on the ssh argv the fake logged.
sys.path.insert(0, str(REPO / "tests" / "windows"))
from fake_transport import FAKE_WIN10_HOST, FAKE_WIN11_HOST, problem as transport_problem  # noqa: E402
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
        # ZB_GATE_ROOT pins the repo root explicitly so the gate resolves it WITHOUT git — the suite must be
        # green from a clean git-archive export (no .git), not only from a checkout (RoseCat 7335). An
        # override can still unset it (the negative no-root test builds its own env instead).
        env = {"PATH": bindir + os.pathsep + _BASE_PATH, "HOME": home or "/nonexistent-zb-home",
               "ZB_GATE_ROOT": str(REPO)}
        env.update(env_overrides)
        self.assertIsNone(transport_problem(env, []), "fake gate run is not fail-safe")
        # Direct invocation: with gate.sh absent this raises FileNotFoundError (the red).
        proc = subprocess.run(
            [str(GATE), *(args or [])],
            env=env, capture_output=True, text=True, timeout=120,
        )
        log = pathlib.Path(env.get("ZB_SELFTEST_SSH_LOG", "/nonexistent-zb-ssh.log"))
        argv = log.read_text().splitlines() if log.exists() else []   # one arg per line, every call
        self.assertIsNone(transport_problem(env, [argv] if argv else []), "fake gate run is not fail-safe")
        return proc

    def _stage_env(self, td: pathlib.Path):
        """A configured fake Win11 host + per-case logs + pinned known_hosts, with private HOME."""
        home = td / "home"; home.mkdir()
        kh = td / "no-such-known_hosts"
        logs = {k: td / f"{k}.log" for k in ("ran", "ssh", "tar", "env")}
        env = {
            "ZB_WIN11_HOST": FAKE_WIN11_HOST, "ZB_WIN11_PORT": "2222",
            "ZB_WIN11_DOMAIN": "win11-m8", "ZB_GUEST_USER": _TEST_USER,
            "ZB_WIN_KEY": str(td / "no-such-key"), "ZB_WIN_KNOWN_HOSTS": str(kh),
            "ZB_SELFTEST_RAN_LOG": str(logs["ran"]), "ZB_SELFTEST_SSH_LOG": str(logs["ssh"]),
            "ZB_SELFTEST_TAR_LOG": str(logs["tar"]), "ZB_SELFTEST_ENV_LOG": str(logs["env"]),
        }
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
            proc = self._run_gate({"ZB_WIN10_HOST": f"zbtest@{FAKE_WIN10_HOST}",
                                    "ZB_WIN_KEY": str(td / "no-such-key")}, _fakes(td), home=str(home))
            detail = f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertNotEqual(proc.returncode, 0, "one host is not a two-host gate" + detail)
            self.assertIn("NOT RUN: no Windows host configured", proc.stderr, detail)
            self.assertIn("ZB_WIN11_HOST", proc.stderr, detail)

    def test_fail_closed_when_only_win11_configured(self):
        """WS0.2: Win11 set, Win10 missing => fail, name Win10."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t); home = td / "home"; home.mkdir()
            proc = self._run_gate({"ZB_WIN11_HOST": FAKE_WIN11_HOST,
                                    "ZB_WIN_KEY": str(td / "no-such-key")}, _fakes(td), home=str(home))
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


class RemotePathFenceRemovedTests(unittest.TestCase):
    """The reparse-resolving remote-path fence was REMOVED, not reclassified: a name-only check/use
    boundary cannot close the junction-swap TOCTOU (RoseCat security review of aebb07b/9dbad76/7ea3c95;
    bead zigBrowser-q92). There is no `allowed_path`, no `--allowed-path`, and no resolver. A future
    remote file op that needs safety MUST use a single held-handle check-and-use (Windows plan, Option B),
    never a name-based pre-check. This pin keeps the fence from being silently re-added — no code means
    no TOCTOU and no caller-census to defeat (the previous caller pin missed `$(allowed_path ...)`)."""

    def setUp(self):
        self.assertTrue(GATE.exists(), "tests/windows/gate.sh must exist")
        self.gate = GATE.read_text()

    def test_no_authorization_fence_remains_in_the_gate(self):
        # No function, no dispatch, no resolver hook. Comments explaining the removal are allowed, so
        # only flag ACTUAL code: a function definition, a CLI case, or a resolver variable assignment.
        self.assertNotIn("allowed_path() {", self.gate, "allowed_path must stay removed")
        self.assertNotIn("--allowed-path)", self.gate, "the --allowed-path dispatch must stay removed")
        self.assertNotRegex(self.gate, r"ZB_(DEFAULT_)?RESOLVE_CMD=",
                            "no resolver hook may be reintroduced")
        self.assertNotRegex(self.gate, r'\n\s*allowed_path\b',
                            "no caller of allowed_path may exist (the function is gone)")

    def test_resolver_files_are_gone(self):
        self.assertFalse((REPO / "tests" / "windows" / "resolve_path.sh").exists(),
                         "resolve_path.sh must be deleted")
        self.assertFalse((REPO / "tests" / "windows" / "resolve_live_test.py").exists(),
                         "resolve_live_test.py must be deleted")

    def test_fence_str_is_documented_as_lexical_only_not_a_boundary(self):
        # The surviving lexical shape-check must stay labelled a non-boundary so it is not re-promoted.
        self.assertIn("NO remote-path authorization fence", self.gate)
        self.assertIn("NOT a boundary", self.gate)



# ---- WS0.4 item 4: the interactive scheduled-task runner never requests elevation; a failed task delete fails the
# run (plan WS0.4; red bf0e6b5). Drives the REAL slice2_common runners in a child Python against a recording fake
# schtasks that behaves like a standard user (it refuses `/rl highest` with the VM's exact "ERROR: Access is
# denied."). The child changes only slice2_common's own `os` name (a proxy reporting "nt"), so the Windows-only
# guard passes; argv, polling and result handling are production code. Mutants recorded in the green commit:
# restore `/rl highest`; ignore the /delete result.
# Recording fake schtasks: one argv line per call; behaves like a standard user's Task Scheduler.
_FAKE_SCHTASKS_04 = r"""#!/usr/bin/env bash
printf 'schtasks' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
verb="$1"; shift
tn=""; tr=""; rl=""
while [ $# -gt 0 ]; do
  case "$1" in
    /tn) tn="$2"; shift 2 ;;
    /tr) tr="$2"; shift 2 ;;
    /rl) rl="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$verb" in
  /create)
    if [ "$(printf '%s' "$rl" | tr 'A-Z' 'a-z')" = "highest" ] && [ -z "${ZB_FAKE_ALLOW_HIGHEST:-}" ]; then
      echo "ERROR: Access is denied." >&2; exit 1; fi
    printf '%s' "$tr" > "$ZB_FAKE_STATE/$tn.tr"; echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."; exit 0 ;;
  /run)
    [ -f "$ZB_FAKE_STATE/$tn.tr" ] || { echo "ERROR: The system cannot find the file specified." >&2; exit 1; }
    script=$(sed -E 's/.*"([^"]+)"[^"]*$/\1/' "$ZB_FAKE_STATE/$tn.tr"); dir=$(dirname "$script")
    printf 'PASS\tfake\nZB_HARNESS_EXIT\t0\n' > "$dir/stdout.txt"; : > "$dir/stderr.txt"
    case "$script" in *.ps1) echo 4242 > "$dir/pid.txt"; echo 0 > "$dir/exit.txt" ;; esac
    echo "SUCCESS: Attempted to run the scheduled task \"$tn\"."; exit 0 ;;
  /end) exit "${ZB_FAKE_END_RC:-0}" ;;
  /delete)
    if [ "${ZB_FAKE_DELETE_RC:-0}" != 0 ]; then echo "ERROR: Access is denied." >&2; exit "$ZB_FAKE_DELETE_RC"; fi
    rm -f "$ZB_FAKE_STATE/$tn.tr"; echo "SUCCESS: The scheduled task \"$tn\" was successfully deleted."; exit 0 ;;
esac
exit 0
"""
_FAKE_TASKKILL_04 = r"""#!/usr/bin/env bash
printf 'taskkill' >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
exit 0
"""

# The child: import the real runner, then let its Windows-only guard pass, then call it and print the result.
_RUNNER_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    # slice2_common's own `os`, reporting name "nt" so the runner's `os.name != "nt"` guard passes; every other
    # attribute is the real os module (pathlib, tempfile and subprocess keep their real, POSIX os).
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
which = sys.argv[2]
if which == "ps1":
    r = s.run_windows_interactive_to_exit(["C:\\zb\\fake.exe", "--flag"], {"ZB_X": "1"}, 10, cwd=pathlib.Path.cwd())
    matched = None
else:
    matched, r = s.run_windows_interactive_cmd_until(["C:\\zb\\fake.exe"], {}, 10,
                                                     lambda o, e, p: p.returncode is not None, cwd=pathlib.Path.cwd())
print(json.dumps({"matched": matched, "returncode": r.returncode, "stdout": r.stdout_lines, "stderr": r.stderr_lines}))
"""


class WS04RunnerLeastPrivilege(unittest.TestCase):
    def _run(self, which, **fake_env):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            for name, body in (("schtasks", _FAKE_SCHTASKS_04), ("taskkill", _FAKE_TASKKILL_04)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            log = td / "calls.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(log), "ZB_FAKE_STATE": str(state)}
            env.update(fake_env)
            proc = subprocess.run(["python3", "-I", "-c", _RUNNER_CHILD, str(REPO / "tests" / "e2e"), which], cwd=td,
                                  env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = (f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(map(shlex.join, calls)))
        self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
        return json.loads(proc.stdout.strip().splitlines()[-1]), calls, detail

    def _create_call(self, calls, detail):
        creates = [c for c in calls if c[:2] == ["schtasks", "/create"]]
        self.assertEqual(len(creates), 1, "exactly one task is created" + detail)
        return creates[0]

    def test_ps1_runner_creates_the_task_at_least_privilege(self):
        result, calls, detail = self._run("ps1")
        argv = self._create_call(calls, detail)
        self.assertNotIn("highest", [a.lower() for a in argv], "the runner must never request elevation" + detail)
        self.assertIn("/rl", argv, "the run level must be stated, not left to a default" + detail)
        self.assertEqual(argv[argv.index("/rl") + 1].lower(), "limited", "least privilege is /rl limited" + detail)
        self.assertIn("/it", argv, "the task must still run only in the interactive session" + detail)

    def test_cmd_runner_creates_the_task_at_least_privilege(self):
        result, calls, detail = self._run("cmd")
        argv = self._create_call(calls, detail)
        self.assertNotIn("highest", [a.lower() for a in argv], "the runner must never request elevation" + detail)
        self.assertEqual(argv[argv.index("/rl") + 1].lower(), "limited", detail)

    def test_standard_user_host_runs_the_task(self):
        # The fake refuses /rl highest exactly as the VM did; a least-privilege runner gets its task run.
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                result, calls, detail = self._run(which)
                self.assertEqual(result["returncode"], 0, "a standard user's task must be created and run" + detail)
                self.assertNotIn("ERROR: Access is denied.", result["stderr"], detail)
                self.assertTrue(any(c[:2] == ["schtasks", "/run"] for c in calls), "the task was run" + detail)

    def test_failed_task_delete_fails_the_run(self):
        for which in ("ps1", "cmd"):
            with self.subTest(runner=which):
                # The fake accepts any run level here, so this case isolates the delete result.
                result, calls, detail = self._run(which, ZB_FAKE_DELETE_RC="1", ZB_FAKE_ALLOW_HIGHEST="1")
                self.assertTrue(any(c[:2] == ["schtasks", "/delete"] for c in calls), "the delete was attempted" + detail)
                self.assertNotEqual(result["returncode"], 0, "a task left behind must fail the run" + detail)
                self.assertTrue(any("schtasks /delete" in l and "rc=1" in l for l in result["stderr"]),
                                "the failed delete must be named in the result's stderr" + detail)
                if which == "cmd":
                    self.assertFalse(result["matched"], "a run whose cleanup failed is not a match" + detail)


# ---- WS0.4: the runner starts a relative program from the run's own folder (red e1c4bbd). The Win11 m8 run at
# 2df192b failed m8_reply_channel_test with Start-Process -FilePath 'zigBrowser.exe' "cannot find the file": the
# wrapper's Set-Location does not set the process directory a bare FilePath resolves against. Drives the REAL
# runner with the WS0.4 fake schtasks and reads the wrapper it wrote. Mutant recorded in the green commit: drop
# the cwd resolution.
_PATH_CHILD = r"""
import json, os, sys, pathlib
sys.path.insert(0, sys.argv[1])
import slice2_common as s

class _WindowsName:
    name = "nt"
    def __getattr__(self, attr):
        return getattr(os, attr)

s.os = _WindowsName()
r = s.run_windows_interactive_to_exit([sys.argv[2], "file:///x"], {}, 10, cwd=pathlib.Path.cwd())
print(json.dumps({"returncode": r.returncode, "stderr": r.stderr_lines}))
"""


class WS04RunnerStartsRelativeProgramFromCwd(unittest.TestCase):
    def _wrapper_for(self, program, make_file):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            state = td / "state"; state.mkdir()
            work = td / "work"; work.mkdir()
            for name, body in (("schtasks", _FAKE_SCHTASKS_04), ("taskkill", _FAKE_TASKKILL_04)):
                (bindir / name).write_text(body); (bindir / name).chmod(0o755)
            if make_file:
                (work / program).write_text("fake exe")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td),
                   "ZB_FAKE_LOG": str(td / "calls.log"), "ZB_FAKE_STATE": str(state)}
            proc = subprocess.run(["python3", "-I", "-c", _PATH_CHILD, str(REPO / "tests" / "e2e"), program], cwd=work,
                                  env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
            detail = f"\nchild rc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "the child driver itself must not crash" + detail)
            wrappers = list(td.glob("zb_m8_task_*/run.ps1"))
            self.assertEqual(len(wrappers), 1, "the runner wrote one task wrapper" + detail)
            return wrappers[0].read_text(encoding="utf-8"), work, detail

    def test_relative_program_in_cwd_is_started_by_absolute_path(self):
        script, work, detail = self._wrapper_for("zigBrowser.exe", make_file=True)
        want = f"Start-Process -FilePath '{work / 'zigBrowser.exe'}' "
        self.assertIn(want, script, "a program found in the run's cwd must be started by its absolute path" + detail
                      + "\nwrapper:\n" + script)

    def test_path_program_not_in_cwd_is_left_as_given(self):
        script, _, detail = self._wrapper_for("powershell.exe", make_file=False)
        self.assertIn("Start-Process -FilePath 'powershell.exe' ", script, detail + "\nwrapper:\n" + script)

if __name__ == "__main__":
    unittest.main()
