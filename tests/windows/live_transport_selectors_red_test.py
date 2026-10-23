#!/usr/bin/env python3
r"""ong.25 RED (UNREGISTERED), NavyCanyon fb4d56d1 "ong.25 Windows live transport selectors — pre-red minimum".

Once a Windows host is configured, all five transport selectors are explicit: host, port, user, key and known_hosts
(ZB_WIN11_* for the VM, ZB_WIN10_* for the file server). Today the listed callers default the key and known_hosts
to the real Win11 files (/home/maceo/vms/win11-m8/...), read the legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS, default
port 2222/22 and user zbtext/zbtest, and the Win10 paths fall back to the Win11 key.

Behavioural proof: a real-caller matrix. Every listed entry point (each Python live test or driver, both m8 host
records, build-on-windows.sh, gate.sh --selftest-stage and gate.sh --probe-only for each host) runs as a child inside
`unshare --user --map-current-user --net`, with recording fake ssh/scp first on PATH (they answer nothing useful).
  - Partial configuration (the host plus all but one selector, or the host alone), with the legacy ZB_WIN_* values
    and the other host's values present as bait: no ssh/scp call at all, and a named refusal that names every
    missing variable. A unittest entry must fail or error (never skip); a CLI driver or script prints `refused:`
    and exits 2.
  - Complete TEST-NET configuration (192.0.2.1 / 198.51.100.15, ports 2201 / 2210, users zbuser11 / zbuser10, key
    and known_hosts paths under the test's temp dir that do not exist), with the same bait: at least one call per
    configured host, and every call carries exactly that host's user, host, port, key and known_hosts.
wsl_live_test's live entry needs the sha-pinned Alpine rootfs and the PID-1 backstop before its first ssh, so its
complete-config control drives that module's own ssh() helper instead (approved 456c9420; the green routes that helper
through the shared resolver); its partial-config cases drive the entry.
R2 (NavyCanyon 456c9420): win_transport_test's second account ZB_WIN11_OTHER_USER is a sixth selector for that test
only: with the primary five complete and it missing, a named non-skip failure and no transport. The gate stage's
transport user is ZB_WIN11_USER; ZB_GUEST_USER (the lexical-fence identity) is set to a deliberately different bait
and is never required to equal it.

Separately: fake_transport.problem() must itself reject default, legacy and cross-host resolution; and a source
tripwire (NOT the behavioural proof) checks every caller names the shared resolver tests/windows/live_transport.py
and carries no real-host literal, legacy selector or selector default.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/live_transport_selectors_red_test.py
"""
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
WIN = REPO / "tests" / "windows"
sys.path.insert(0, str(WIN))
import build_on_windows_selftest as bows  # noqa: E402  its fake git/ssh/scp world for build-on-windows.sh
import fake_transport  # noqa: E402
import gate_twohost_selftest as gtw  # noqa: E402  its fake ssh/virsh world for gate.sh

NETNS = fake_transport.NETNS
SELECTORS = ("PORT", "USER", "KEY", "KNOWN_HOSTS")
REAL_LITERAL = "/home/maceo/vms/"
HOSTS = {"ZB_WIN11": fake_transport.FAKE_WIN11_HOST, "ZB_WIN10": fake_transport.FAKE_WIN10_HOST}
PORTS = {"ZB_WIN11": "2201", "ZB_WIN10": "2210"}
USERS = {"ZB_WIN11": "zbuser11", "ZB_WIN10": "zbuser10"}
OTHER_USER = "zbother11"
FENCE_USER_BAIT = "zbfence-bait"  # ZB_GUEST_USER: the fence identity, never the transport user

_FAKE = r"""#!/usr/bin/env bash
{ printf 'ARGV:'; printf ' %q' "$@"; printf '\n'; } >> "$ZB_RED_CALLS"
echo "fake $(basename "$0"): no host here" >&2
exit 255
"""
_FAKE_ZIG = "#!/usr/bin/env bash\nexit 0\n"

# (label, kind, script, args, subject prefix, needs) — kind: "unittest" | "cli" | "bows" | "gate"
CALLERS = [
    ("screenshot_branches_live", "unittest", "tests/e2e/screenshot_branches_live_test.py", [], "ZB_WIN11", {"exe"}),
    ("win_transport", "unittest", "tests/e2e/win_transport_test.py", [], "ZB_WIN11", {"exe", "other"}),
    ("win_trusted_input_matrix", "cli", "tests/e2e/win_trusted_input_matrix.py", [], "ZB_WIN11", {"marker"}),
    ("win_async_ownership", "cli", "tests/e2e/win_async_ownership_test.py", [], "ZB_WIN11", {"marker"}),
    ("win_private_world_spike", "cli", "tests/e2e/win_private_world_spike.py", [], "ZB_WIN11", {"marker"}),
    ("refusal_stderr_live", "unittest", "tests/windows/refusal_stderr_live_test.py", [], "ZB_WIN11", {"exe"}),
    ("screenshot_live", "unittest", "tests/windows/screenshot_live_test.py", [], "ZB_WIN11", {"exe"}),
    ("win_config_flags", "unittest", "tests/windows/win_config_flags_test.py", [], "ZB_WIN11", {"exe"}),
    ("win_drawer", "unittest", "tests/windows/win_drawer_test.py", ["WinDrawerLive"], "ZB_WIN11", {"exe"}),
    ("wincontain_argv_live", "unittest", "tests/windows/wincontain_argv_live_test.py", [], "ZB_WIN11", set()),
    ("wincontain_job_live", "unittest", "tests/windows/wincontain_job_live_test.py", [], "ZB_WIN11", set()),
    ("wincontain_resolve_live", "unittest", "tests/windows/wincontain_resolve_live_test.py", [], "ZB_WIN11", set()),
    ("ws1_run", "unittest", "tests/windows/ws1_run_test.py", [], "ZB_WIN11", set()),
    ("wsl_live", "unittest", "tests/windows/wsl_live_test.py", ["WslTopologyLive"], "ZB_WIN11", set()),
    ("m8_live_win11", "cli", "tests/windows/m8_live_test.py", [], "ZB_WIN11", {"exe", "marker", "python"}),
    ("m8_live_win10", "cli", "tests/windows/m8_live_test.py", [], "ZB_WIN10", {"exe", "marker", "python"}),
    ("build_on_windows", "bows", "tests/windows/build-on-windows.sh", [], "ZB_WIN11", set()),
    ("gate_selftest_stage", "gate", "tests/windows/gate.sh", ["--selftest-stage"], "ZB_WIN11", set()),
    ("gate_probe_only_win11", "gate", "tests/windows/gate.sh", ["--probe-only"], "ZB_WIN11", {"both"}),
    ("gate_probe_only_win10", "gate", "tests/windows/gate.sh", ["--probe-only"], "ZB_WIN10", {"both"}),
]

# The resolver's callers for the source tripwire (spike_driver serves win_trusted_input_matrix / win_async_ownership).
TRIPWIRE_PY = [
    "tests/e2e/screenshot_branches_live_test.py", "tests/e2e/win_private_world_spike.py", "tests/e2e/win_transport_test.py",
    "tests/windows/refusal_stderr_live_test.py", "tests/windows/screenshot_live_test.py", "tests/windows/spike_driver.py",
    "tests/windows/win_config_flags_test.py", "tests/windows/win_drawer_test.py", "tests/windows/wincontain_argv_live_test.py",
    "tests/windows/wincontain_job_live_test.py", "tests/windows/wincontain_resolve_live_test.py",
    "tests/windows/ws1_run_test.py", "tests/windows/wsl_live_test.py", "tests/windows/m8_live_test.py",
]
TRIPWIRE_SH = ["tests/windows/build-on-windows.sh", "tests/windows/gate.sh"]


def _values(td, prefix):
    tag = prefix[-2:]
    return {f"{prefix}_HOST": HOSTS[prefix], f"{prefix}_PORT": PORTS[prefix], f"{prefix}_USER": USERS[prefix],
            f"{prefix}_KEY": str(td / f"k{tag}.key"), f"{prefix}_KNOWN_HOSTS": str(td / f"kh{tag}")}


def _bait(td, prefix):
    """Values a wrong resolver would pick up: the legacy selectors, and the other host's selectors (no host)."""
    other = "ZB_WIN10" if prefix == "ZB_WIN11" else "ZB_WIN11"
    bait = {"ZB_WIN_KEY": str(td / "legacy.key"), "ZB_WIN_KNOWN_HOSTS": str(td / "legacy.kh")}
    bait.update({k: v for k, v in _values(td, other).items() if not k.endswith("_HOST")})
    return bait


def _selectors(argv):
    """(user, host, port, key, known_hosts) of one logged ssh/scp argv; None where absent."""
    def after(flag):
        return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None
    target = next((a for a in argv if "@" in a and not a.startswith("-")), None)
    user = host = None
    if target:
        user, rest = target.split("@", 1)
        host = rest.split(":", 1)[0]
    kh = next((a.split("UserKnownHostsFile=", 1)[1] for a in argv if "UserKnownHostsFile=" in a), None)
    return user, host, after("-p") or after("-P"), after("-i"), kh


class _Matrix(unittest.TestCase):
    def _world(self, td, label, kind):
        bindir = td / "bin"
        bindir.mkdir()
        env = {"HOME": str(td / "home"), "TMPDIR": str(td / "tmp"), "LANG": "C.UTF-8"}
        (td / "home").mkdir()
        (td / "tmp").mkdir()
        if kind == "bows":
            root = td / "root"
            root.mkdir()
            env.update({"PATH": bows._fakes(bindir) + ":/usr/bin:/bin", "ZB_SELFTEST_ROOT": str(root),
                        "ZB_SELFTEST_SSH_LOG": str(td / "calls.log"), "ZB_SELFTEST_SCP_LOG": str(td / "calls.log"),
                        "ZB_WEBVIEW2_INCLUDE": r"C:\wv2\include", "ZB_WEBVIEW2_LIB": r"C:\wv2\lib\x64",
                        "ZB_ZIG": r"C:\tools\zig.exe", "ZB_WIN_EXE": str(td / "out" / "current" / "zigBrowser.exe"),
                        "ZB_SELFTEST_GIT_LOG": str(td / "git.log"), "ZB_SELFTEST_TIMEOUT_LOG": str(td / "timeout.log")})
        elif kind == "gate":
            env.update({"PATH": gtw._fakes(bindir) + ":/usr/bin:/bin", "ZB_GATE_ROOT": str(REPO),
                        "ZB_SELFTEST_SSH_LOG": str(td / "calls.log"), "ZB_GUEST_USER": FENCE_USER_BAIT,
                        "ZB_WIN11_DOMAIN": "win11-m8", "ZB_WIN11_MARKER": gtw.VM_MARKER,
                        "ZB_WIN11_SNAPSHOT": "pre-4dr-toolchain-2026-10-20", "ZB_WIN10_MARKER": gtw.FS_MARKER,
                        "ZB_SELFTEST_WIN10_CALLS": str(td / "win10.calls"),
                        "ZB_SELFTEST_PROBE_WIN11": gtw._vm_probe(), "ZB_SELFTEST_PROBE_WIN10": gtw._fs_probe()})
        else:
            for name in ("ssh", "scp"):
                (bindir / name).write_text(_FAKE)
                (bindir / name).chmod(0o755)
            (bindir / "zig").write_text(_FAKE_ZIG)
            (bindir / "zig").chmod(0o755)
            exe = td / "zigBrowser.exe"
            exe.write_text("not an exe")
            env.update({"PATH": f"{bindir}:/usr/bin:/bin", "ZB_RED_CALLS": str(td / "calls.log"),
                        "ZB_WIN_EXE": str(exe), "ZB_WIN11_MARKER": "M11", "ZB_WIN10_MARKER": "M10",
                        "ZB_WIN11_PYTHON": r"C:\Python314\python.exe", "ZB_WIN10_PYTHON": r"C:\Python314\python.exe",
                        "ZB_WIN11_OTHER_USER": OTHER_USER})
        (td / "calls.log").write_text("")
        return env

    def _calls(self, td):
        out = []
        for line in (td / "calls.log").read_text().splitlines():
            if line.startswith("ARGV:"):
                body = line[len("ARGV:"):]
                try:
                    out.append(shlex.split(body))
                except ValueError:
                    out.append(body.split())
        return out

    def _run(self, label, kind, script, args, env, td):
        if kind in ("bows", "gate"):
            cmd = [*NETNS, "bash", str(REPO / script), *args]
        else:
            cmd = [*NETNS, "python3", "-I", str(REPO / script), *args]
        proc = subprocess.run(cmd, cwd=td, env=env, capture_output=True, text=True, timeout=240,
                              stdin=subprocess.DEVNULL)
        return proc

    def _detail(self, label, env, proc, calls):
        shown = {k: v for k, v in env.items() if k.startswith(("ZB_WIN1", "ZB_WIN_"))}
        return (f"\n[{label}] rc={proc.returncode}\nenv={shown}\nstdout:\n{proc.stdout[-2500:]}\n"
                f"stderr:\n{proc.stderr[-2500:]}\ncalls: {calls[:6]}")

    def _partial(self, label, kind, script, args, prefix, needs, missing, drop=()):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env = self._world(td, label, kind)
            env.update(_bait(td, prefix))
            if "both" in needs:
                other = "ZB_WIN10" if prefix == "ZB_WIN11" else "ZB_WIN11"
                env.update(_values(td, other))
            env.update(_values(td, prefix))
            for name in missing:
                env.pop(f"{prefix}_{name}")
            for name in drop:
                env.pop(name)
            proc = self._run(label, kind, script, args, env, td)
            calls = self._calls(td)
        detail = self._detail(label, env, proc, calls)
        self.assertEqual(calls, [], "no ssh/scp call before the selectors are complete" + detail)
        text = proc.stdout + proc.stderr
        wanted = [f"{prefix}_{n}" for n in missing] + list(drop)
        if kind == "unittest":
            self.assertNotEqual(proc.returncode, 0, "a partial configuration fails the test" + detail)
            self.assertNotRegex(text, r"skipped=|\bskipped\b", "never a skip" + detail)
            for name in wanted:
                self.assertIn(name, text, detail)
        else:
            self.assertEqual(proc.returncode, 2, "a driver refuses with rc 2" + detail)
            refused = [l for l in text.splitlines() if "refused:" in l]
            self.assertTrue(refused, "a `refused:` line" + detail)
            for name in wanted:
                self.assertTrue(any(name in l for l in refused), f"the refusal names {name}" + detail)

    def _complete(self, label, kind, script, args, prefix, needs):
        prefixes = ["ZB_WIN11", "ZB_WIN10"] if "both" in needs else [prefix]
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            env = self._world(td, label, kind)
            env.update(_bait(td, prefix))
            for p in prefixes:
                env.update(_values(td, p))
            if label == "wsl_live":
                env["ZB_RED_WIN"] = str(WIN)
                proc = subprocess.run([*NETNS, "python3", "-I", "-c",
                                       "import os, sys; sys.path.insert(0, os.environ['ZB_RED_WIN']); "
                                       "import wsl_live_test as m; m.ssh('cmd', '/c', 'echo', 'x')"],
                                      cwd=td, env=env, capture_output=True, text=True, timeout=120,
                                      stdin=subprocess.DEVNULL)
            else:
                proc = self._run(label, kind, script, args, env, td)
            calls = self._calls(td)
            want = {p: _values(td, p) for p in prefixes}
        detail = self._detail(label, env, proc, calls)
        self.assertTrue(calls, "the complete configuration reaches the transport" + detail)
        by_host = {HOSTS[p]: p for p in prefixes}
        seen = set()
        for argv in calls:
            user, host, port, key, kh = _selectors(argv)
            self.assertIn(host, by_host, f"only a configured TEST-NET host is reached: {argv}" + detail)
            p = by_host[host]
            seen.add(p)
            v = want[p]
            users = {v[f"{p}_USER"]} | ({OTHER_USER} if "other" in needs else set())
            self.assertIn(user, users, f"{p}_USER reaches the call: {argv}" + detail)
            self.assertEqual(port, v[f"{p}_PORT"], f"{p}_PORT reaches the call: {argv}" + detail)
            self.assertEqual(key, v[f"{p}_KEY"], f"{p}_KEY reaches the call: {argv}" + detail)
            self.assertEqual(kh, v[f"{p}_KNOWN_HOSTS"], f"{p}_KNOWN_HOSTS reaches the call: {argv}" + detail)
            self.assertFalse(any(REAL_LITERAL in a or "legacy." in a for a in argv), f"no default or legacy: {argv}" + detail)
        self.assertEqual(seen, set(prefixes), "every configured host is reached with its own selectors" + detail)


def _add(label, kind, script, args, prefix, needs):
    def partial(self):
        for name in SELECTORS:
            with self.subTest(missing=name):
                self._partial(label, kind, script, args, prefix, needs, [name])
        with self.subTest(missing="all four"):
            self._partial(label, kind, script, args, prefix, needs, list(SELECTORS))

    def complete(self):
        self._complete(label, kind, script, args, prefix, needs)

    setattr(_Matrix, f"test_{label}_partial_configuration_is_refused_before_transport", partial)
    setattr(_Matrix, f"test_{label}_complete_configuration_reaches_exactly_its_selectors", complete)


for _c in CALLERS:
    _add(*_c)


def _win_transport_other_user(self):
    """R2: the primary five complete, ZB_WIN11_OTHER_USER missing."""
    label, kind, script, args, prefix, needs = next(c for c in CALLERS if c[0] == "win_transport")
    self._partial(label, kind, script, args, prefix, needs, [], drop=["ZB_WIN11_OTHER_USER"])


_Matrix.test_win_transport_missing_other_user_is_refused_before_transport = _win_transport_other_user


class FakeTransportModel(unittest.TestCase):
    """fake_transport.problem() rejects default, legacy and cross-host resolution, even inside a netns."""

    def _env(self, prefix, **over):
        td = pathlib.Path("/nonexistent-zb-red")
        env = _values(td, prefix)
        env.update(over)
        return {k: v for k, v in env.items() if v is not None}

    def test_complete_explicit_configuration_is_accepted(self):
        for prefix in ("ZB_WIN11", "ZB_WIN10"):
            with self.subTest(prefix=prefix):
                self.assertIsNone(fake_transport.problem(self._env(prefix), [], netns=True))

    def test_partial_default_legacy_and_cross_host_resolution_is_rejected(self):
        td = pathlib.Path("/nonexistent-zb-red")
        for prefix in ("ZB_WIN11", "ZB_WIN10"):
            for name in SELECTORS:
                with self.subTest(prefix=prefix, missing=name):
                    env = self._env(prefix, **{f"{prefix}_{name}": None})
                    self.assertIsNotNone(fake_transport.problem(env, [], netns=True), env)
            with self.subTest(prefix=prefix, case="legacy only"):
                env = self._env(prefix, **{f"{prefix}_KEY": None, f"{prefix}_KNOWN_HOSTS": None})
                env.update(ZB_WIN_KEY=str(td / "legacy.key"), ZB_WIN_KNOWN_HOSTS=str(td / "legacy.kh"))
                self.assertIsNotNone(fake_transport.problem(env, [], netns=True), env)
        with self.subTest(case="Win10 with only Win11 values"):
            env = self._env("ZB_WIN10", ZB_WIN10_KEY=None, ZB_WIN10_KNOWN_HOSTS=None)
            env.update(ZB_WIN11_KEY=str(td / "k11.key"), ZB_WIN11_KNOWN_HOSTS=str(td / "kh11"))
            self.assertIsNotNone(fake_transport.problem(env, [], netns=True), env)


class SourceTripwire(unittest.TestCase):
    """A tripwire only (the matrix above is the behavioural proof): the scoped callers use the one resolver."""

    _DEFAULT_PY = re.compile(r"""ZB_WIN(1[01])?_(PORT|USER|OTHER_USER|KEY|KNOWN_HOSTS)["']\s*,\s*["']""")
    _DEFAULT_SH = re.compile(r"\$\{ZB_WIN(1[01])?_(PORT|USER|KEY|KNOWN_HOSTS):-")

    def test_the_shared_resolver_exists(self):
        self.assertTrue((WIN / "live_transport.py").is_file(), "tests/windows/live_transport.py")

    def test_python_callers_use_the_resolver_and_carry_no_default(self):
        for rel in TRIPWIRE_PY:
            with self.subTest(file=rel):
                text = (REPO / rel).read_text()
                self.assertIn("live_transport", text)
                self.assertNotIn(REAL_LITERAL, text)
                self.assertNotRegex(text, r"""["']ZB_WIN_(KEY|KNOWN_HOSTS)["']""")
                self.assertNotRegex(text, self._DEFAULT_PY)

    def test_shell_callers_carry_no_default_or_legacy_selector(self):
        for rel in TRIPWIRE_SH:
            with self.subTest(file=rel):
                text = (REPO / rel).read_text()
                self.assertNotIn(REAL_LITERAL, text)
                self.assertNotRegex(text, r"\bZB_WIN_(KEY|KNOWN_HOSTS)\b")
                self.assertNotRegex(text, self._DEFAULT_SH)


if __name__ == "__main__":
    unittest.main()
