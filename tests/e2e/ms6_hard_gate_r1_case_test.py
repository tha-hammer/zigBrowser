"""The MS6.6 (B) hard-gate case's chain-release inspection, on Linux with fakes only (RoseCat 7306):
- _chain_alive classifies OUR processes from a canned `ps -axo pid=,uid=,stat=`: a process running the row's CLI, or a
  python whose argv (proc_darwin.environ_of gives list[bytes]) names one of the row's markers, is alive; a failed or
  unparsable ps is not inspected (a negative uid such as nobody's -2 parses; RoseCat/orchestrator after db1f05b); a
  read that fails while the pid has not vanished is unreadable; other users' pids,
  our own pid and zombies are skipped (never read);
- _chain_release returns (faults, survivors, last). Every scan that was not inspected or listed an unreadable pid is a
  sticky fault, kept even when a later scan is clean (RoseCat 7312); a survivor still alive after CHAIN_GRACE_S is a
  survivor; either way the chain is re-inspected (never signalled) until a clean, empty scan or the row's self-exit
  horizon, and `last` is that final scan.
- run(h) itself, against a FAKE staged zb_agent_host (setup/proc_darwin/sandbox/token written into a temp prefix), runs
  every row (positive/honest, planted, forge, hang) through _released with its own CLI (4e17273 on both Macs: the
  evidence label "positive" was used as the CLI key, KeyError; RoseCat 7358);
- each row's release gets that row's own CLI: the exact (label, cli) pairs run() hands _released are recorded
  (RoseCat 7366 #2: an empty fake ps cannot tell a wrong CLI apart);
- NO emitted check label carries token material (RoseCat 7366 #1: the census record's repr printed the whole probe
  token, in passing runs too), on a clean run, a dirty honest census and a failing probe;
- the probe diagnostics are bounded and token-free: _sanitize redacts the probe token (contiguous, in a Bearer header,
  in an env assignment, wrapped into 6-hex pieces, hex-encoded or base64-encoded) before it bounds the text, and a
  failing positive row shows the probe's rc and sanitized stdout/stderr tails.
No process is started and no signal is sent: h.spawn_group, setup's subprocess.run and proc_darwin are fakes, the
clock is fake, and os.kill / os.killpg are patched to raise.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_r1_case_test'
"""
import base64
import importlib.util
import os
import re
import shutil
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

CASE = Path(__file__).resolve().parents[2] / "tests" / "mac" / "hard_gate" / "case_ms6_6b_r1_chain.py"
CLI = "/scr/cli-hang/claude"
MARKERS = ["/scr/runtime-hang", "/scr/cli-hang"]
ME = os.getuid()


def load_case():
    spec = importlib.util.spec_from_file_location("zb_hg_case_r1_chain", CASE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FakeH:
    def __init__(self, code, rows):
        self.code, self.out = code, "".join(f"{r}\n" for r in rows).encode()

    def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
        assert argv == ["/bin/ps", "-axo", "pid=,uid=,stat="], argv
        return self.code, self.out, b""


class FakeProc:
    """path: pid -> str | None | OSError; argv: pid -> list[bytes] | OSError; a second path read may differ."""

    def __init__(self, path, argv=None, path_after=None):
        self._path, self._argv, self._after, self.reads = path, argv or {}, path_after or {}, []

    def path(self, pid):
        self.reads.append(pid)
        table = self._after if pid in self._after and self.reads.count(pid) > 1 else self._path
        v = table[pid]
        if isinstance(v, OSError):
            raise v
        return v

    def environ_of(self, pid):
        v = self._argv[pid]
        if isinstance(v, OSError):
            raise v
        return b"raw", v, [b"PATH=/usr/bin"]


class NoSignals(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached in a fakes-only test"))
            p.start()
            self.addCleanup(p.stop)
        self.case = load_case()


class ChainAlive(NoSignals):
    def scan(self, rows, proc, code=0):
        return self.case._chain_alive(FakeH(code, rows), proc, CLI, MARKERS)

    def test_a_python_whose_bytes_argv_names_a_marker_is_alive(self):
        proc = FakeProc({4242: "/fw/Python.app/Contents/MacOS/Python"},
                        {4242: [b"/fw/Python", b"-m", b"zb_agent_host", b"probe-r1", b"--wrapper",
                                b"/scr/runtime-hang/bin/zb-claude", b"--cli", b"/scr/cli-hang/claude"]})
        self.assertEqual(self.scan([f"4242 {ME} S"], proc), (True, [(4242, "/fw/Python.app/Contents/MacOS/Python")],
                                                            []))

    def test_a_python_without_a_marker_is_not_alive(self):
        proc = FakeProc({4242: "/usr/bin/python3"}, {4242: [b"/usr/bin/python3", b"/elsewhere/tool.py"]})
        self.assertEqual(self.scan([f"4242 {ME} S"], proc), (True, [], []))

    def test_a_process_running_the_cli_is_alive(self):
        self.assertEqual(self.scan([f"77 {ME} S"], FakeProc({77: CLI})), (True, [(77, CLI)], []))

    def test_an_unreadable_path_is_unreadable_never_vanished(self):
        inspected, alive, unreadable = self.scan([f"77 {ME} S"], FakeProc({77: PermissionError(1, "denied")}))
        self.assertEqual((inspected, alive, [p for p, _ in unreadable]), (True, [], [77]))

    def test_an_unreadable_argv_of_a_live_python_is_unreadable(self):
        proc = FakeProc({88: "/usr/bin/python3"}, {88: OSError(22, "procargs")})
        inspected, alive, unreadable = self.scan([f"88 {ME} S"], proc)
        self.assertEqual((inspected, alive, [p for p, _ in unreadable]), (True, [], [88]))

    def test_an_unreadable_argv_of_a_python_that_then_vanished_is_skipped(self):
        proc = FakeProc({88: "/usr/bin/python3"}, {88: OSError(22, "procargs")}, path_after={88: None})
        self.assertEqual(self.scan([f"88 {ME} S"], proc), (True, [], []))

    def test_a_vanished_pid_is_skipped(self):
        self.assertEqual(self.scan([f"99 {ME} S"], FakeProc({99: None})), (True, [], []))

    def test_a_failed_or_unparsable_ps_is_not_inspected(self):
        self.assertFalse(self.scan([f"99 {ME} S"], FakeProc({99: CLI}), code=1)[0])
        self.assertFalse(self.scan([f"99 {ME} S", "garbage"], FakeProc({99: CLI}))[0])

    def test_a_negative_uid_row_is_parsed_and_skipped(self):
        """macOS ps prints nobody's uid as -2 (db1f05b on both Macs: '344 -2 Ss', '997 -2 S'); it is another user's
        row, skipped, never a reason to call the whole table uninspected."""
        proc = FakeProc({77: CLI})
        self.assertEqual(self.scan(["344    -2 Ss", f"77 {ME} S"], proc), (True, [(77, CLI)], []))
        self.assertEqual(proc.reads, [77], "the -2 row is never read")

    def test_a_malformed_pid_or_uid_is_still_not_inspected(self):
        for row in (f"-5 {ME} S", "77 -x S", "77 - S", f"77 {ME}"):
            with self.subTest(row=row):
                self.assertFalse(self.scan([row], FakeProc({77: CLI}))[0])

    def test_other_users_our_own_pid_and_zombies_are_never_read(self):
        proc = FakeProc({})
        rows = [f"5 {ME + 1} S", f"{os.getpid()} {ME} S", f"6 {ME} Z+"]
        self.assertEqual(self.scan(rows, proc), (True, [], []))
        self.assertEqual(proc.reads, [])


class ChainRelease(NoSignals):
    def release(self, scans, started_at=0.0, clock_at=None):
        """Feeds `scans` (the last one repeats); the clock starts at `clock_at` (default: the row's start) and only
        moves by the case's own sleeps."""
        now = [started_at if clock_at is None else clock_at]
        seen = []

        def scan():
            r = scans[min(len(seen), len(scans) - 1)]
            seen.append(now[0])
            return r

        def sleep(s):
            now[0] += s

        faults, survivors, last = self.case._chain_release(scan, started_at, clock=lambda: now[0], sleep=sleep)
        return faults, survivors, last, seen

    CLEAN = (True, [], [])
    SURVIVOR = (True, [(77, CLI)], [])
    UNREADABLE = (True, [], [(77, "path: denied")])
    NO_PS = (False, [], [])

    def test_a_clean_first_scan_ends_at_once(self):
        self.assertEqual(self.release([self.CLEAN])[:3], ([], [], self.CLEAN))
        self.assertEqual(len(self.release([self.CLEAN])[3]), 1)

    def test_a_transient_fault_stays_a_fault_and_the_drain_still_completes(self):
        for bad in (self.UNREADABLE, self.NO_PS):
            with self.subTest(first=bad):
                faults, survivors, last, seen = self.release([bad, self.CLEAN])
                self.assertEqual(faults, [bad], "the failed first inspection is kept as row-failure evidence")
                self.assertEqual((survivors, last, len(seen)), ([], self.CLEAN, 2), "re-inspected to a clean scan")

    def test_a_fault_anywhere_in_the_drain_is_kept(self):
        faults, _survivors, last, _seen = self.release([self.SURVIVOR, self.SURVIVOR, self.NO_PS, self.CLEAN])
        self.assertEqual((faults, last), ([self.NO_PS], self.CLEAN))

    def test_a_survivor_that_ends_within_the_grace_is_no_failure(self):
        faults, survivors, last, seen = self.release([self.SURVIVOR] * 3 + [self.CLEAN])
        self.assertEqual((faults, survivors, last), ([], [], self.CLEAN))
        self.assertLess(seen[-1], self.case.CHAIN_GRACE_S)

    def test_a_survivor_past_the_grace_is_a_survivor_and_is_waited_out(self):
        faults, survivors, last, seen = self.release([self.SURVIVOR] * 40 + [self.CLEAN])
        self.assertEqual((faults, survivors, last), ([], [(77, CLI)], self.CLEAN))
        self.assertGreater(seen[-1], self.case.CHAIN_GRACE_S)

    def test_the_drain_is_bounded_by_the_rows_horizon(self):
        faults, _survivors, last, seen = self.release([self.UNREADABLE], started_at=1000.0)
        self.assertEqual(last, self.UNREADABLE)
        self.assertTrue(faults)
        self.assertLessEqual(seen[-1], 1000.0 + self.case.CHAIN_HORIZON_S)
        self.assertGreaterEqual(seen[-1], 1000.0 + self.case.CHAIN_HORIZON_S - 1)

    def test_a_late_row_still_gets_its_full_grace(self):
        """A row that ran past its horizon (the hang row's probe can take ~90 s) still gets CHAIN_GRACE_S: the row
        started at t=-95, release starts at t=0, its horizon ends at t=5, and the survivor lives until t=8, inside the
        grace (RoseCat 7317: an end of started_at + horizon alone returns the survivor at t=5)."""
        faults, survivors, last, seen = self.release([self.SURVIVOR] * 8 + [self.CLEAN], started_at=-95.0, clock_at=0.0)
        self.assertEqual((faults, survivors, last), ([], [], self.CLEAN))
        self.assertGreater(seen[-1], -95.0 + self.case.CHAIN_HORIZON_S)


TOKEN = "zb-probe-" + "a1b2c3d4e5f6" * 4  # letters among the digits: no port or pid can match a window

FAKE_SETUP = """
import os, socket, subprocess as _sp, types
from pathlib import Path
from . import proc_darwin
PLATFORM = "darwin"
PACKAGE_DIR = Path(__file__).resolve().parent.parent
PROBE_TIMEOUT_S = 30
RESULT = {"rc": 0, "out": '{"r1": true}\\n', "err": "", "honest_clean": True}
subprocess = types.SimpleNamespace(
    run=lambda argv, *a, **kw: _sp.CompletedProcess(argv, RESULT["rc"], RESULT["out"], RESULT["err"]),
    TimeoutExpired=_sp.TimeoutExpired)
def probe_r1(wrapper, cli):
    mode = os.path.basename(os.path.dirname(cli)).split("-", 1)[1]
    listener = socket.socket(); listener.bind(("127.0.0.1", 0)); listener.listen(1)
    ours, theirs = socket.socketpair()
    port = listener.getsockname()[1]
    profile = Path(wrapper).parent / "setup.sb"
    profile.write_text('(allow network-outbound (remote tcp "localhost:%d"))\\n' % port)
    try:
        argv = ["/usr/bin/sandbox-exec", "-f", str(profile), "-D", "SCRATCHPAD=/s", "py", "-m", "zb_agent_host",
                "probe-r1", "--wrapper", wrapper, "--cli", cli, "--listen-fd", str(listener.fileno()),
                "--listen-port", str(port), "--census-fd", str(theirs.fileno())]
        done = subprocess.run(argv, capture_output=True, text=True, timeout=60, env={},
                              pass_fds=(listener.fileno(), theirs.fileno()))
        if mode == "hang" or done.returncode != 0:
            return False
        canary = ("ANTHROPIC_BASE_URL=http://127.0.0.1:%d" % port).encode()
        return proc_darwin.cli_env_clean(os.path.realpath(cli), os.getpid(), proc_darwin.TOKEN, canary) is True
    finally:
        listener.close(); ours.close(); theirs.close()
"""

FAKE_PROC = """
import os
TOKEN = b"zb-probe-" + b"a1b2c3d4e5f6" * 4
LAST = {}
def _mode(exe):
    return os.path.basename(os.path.dirname(exe)).split("-", 1)[1]
def descendants_running(exe, root):
    LAST["mode"] = _mode(exe)
    return [4242]
def environ_of(pid):
    env = [b"ANTHROPIC_BASE_URL=http://127.0.0.1:1"]
    if LAST["mode"] in ("planted", "forge"):
        env.append(b"ZB_PLANTED=" + TOKEN)
    if LAST["mode"] == "forge":
        env.append(b"ZB_FORGED=1024,0,0")
    return b"raw", [b"claude"], env
def cli_env_clean(exe, root, token, canary):
    from . import setup
    return _mode(exe) == "honest" and setup.RESULT["honest_clean"]
def path(pid):
    return None
"""


class RunWithAFakeStagedHost(NoSignals):
    """run(h) end to end on Linux: the staged modules are fakes in a temp prefix; nothing is spawned."""

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix="zb-hg-r1-run-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.prefix = os.path.join(self.tmp, "agent-host")
        pkg = os.path.join(self.prefix, "zb_agent_host")
        os.makedirs(pkg)
        files = {
            "__init__.py": "",
            "setup.py": FAKE_SETUP,
            "proc_darwin.py": FAKE_PROC,
            "sandbox.py": "import types\ndef channel():\n"
                          "    return types.SimpleNamespace(fd=3, env='CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR')\n",
            "token.py": "def write_wrapper(path, cli, python='/usr/bin/python3'):\n"
                        "    with open(path, 'w') as f:\n"
                        "        f.write('#!%s -I\\n# %s\\n' % (python, cli))\n",
        }
        for name, text in files.items():
            with open(os.path.join(pkg, name), "w") as f:
                f.write(textwrap.dedent(text))
        self.scratch = os.path.join(self.tmp, "scratch")
        os.mkdir(self.scratch)
        self.addCleanup(self.forget)
        self.forget()

    def forget(self):
        for name in [m for m in sys.modules if m == "zb_agent_host" or m.startswith("zb_agent_host.")]:
            del sys.modules[name]
        while self.prefix in sys.path:
            sys.path.remove(self.prefix)

    def harness(self):
        test = self

        class H:
            scratch, prefix, python, cli = test.scratch, test.prefix, sys.executable, None
            checks = []

            def check(self, ok, label):
                self.checks.append((bool(ok), label))
                return bool(ok)

            def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
                if argv[:2] == ["/usr/bin/xcrun", "clang"]:
                    out = argv[argv.index("-o") + 1]
                    with open(out, "w") as f:
                        f.write("#!/bin/sh\n")
                    os.chmod(out, 0o700)
                    return 0, b"", b""
                assert argv == ["/bin/ps", "-axo", "pid=,uid=,stat="], argv
                return 0, b"", b""

        return H()

    def test_every_row_runs_and_is_released_with_its_own_cli(self):
        h = self.harness()
        self.case.run(h)  # a raise (4e17273's KeyError: 'positive') fails the test
        failed = [label for ok, label in h.checks if not ok]
        self.assertEqual(failed, [], "a consistent fake staged host passes every row")
        for label in ("positive", "planted", "forge", "hang"):
            for what in ("afterwards port", "every scan inspected", "no part of the probe chain",
                         "waited out unsignalled"):
                with self.subTest(row=label, check=what):
                    self.assertTrue(any(l.startswith(f"{label}: {what}") for _, l in h.checks), (label, what))

    def fake_setup(self):
        import importlib
        if self.prefix not in sys.path:
            sys.path.insert(0, self.prefix)
        return importlib.import_module("zb_agent_host.setup")

    def test_each_rows_release_gets_that_rows_own_cli(self):
        seen = []
        real = self.case._released

        def record(h, proc_darwin, label, cli, *rest):
            seen.append((label, cli))
            return real(h, proc_darwin, label, cli, *rest)

        with mock.patch.object(self.case, "_released", side_effect=record):
            self.case.run(self.harness())
        cli = lambda mode: os.path.realpath(os.path.join(self.scratch, f"cli-{mode}", "claude"))  # noqa: E731
        self.assertEqual(seen, [("positive", cli("honest")), ("planted", cli("planted")), ("forge", cli("forge")),
                                ("hang", cli("hang"))])

    def test_no_check_label_ever_carries_token_material(self):
        hexpart = TOKEN[9:]
        windows = {hexpart[i:i + 6] for i in range(len(hexpart) - 5)}
        scenarios = {
            "a clean run": {},
            "a dirty honest census": {"honest_clean": False},
            "a failing probe": {"rc": 1, "err": "Authorization: Bearer " + TOKEN + "\n" + TOKEN + "\n"},
        }
        for name, result in scenarios.items():
            with self.subTest(scenario=name):
                setup = self.fake_setup()
                setup.RESULT.update({"rc": 0, "out": '{"r1": true}\n', "err": "", "honest_clean": True}, **result)
                self.scratch = tempfile.mkdtemp(dir=self.tmp, prefix="scratch-")  # each run makes its own dirs
                h = self.harness()
                h.checks = []
                self.case.run(h)
                self.assertTrue(h.checks)
                for _ok, label in h.checks:
                    self.assertNotIn("zb-probe-", label)
                    leaked = [w for w in windows if w in label]
                    self.assertEqual(leaked, [], f"token hex in: {label[:300]}")

    def test_a_failing_positive_shows_the_probes_rc_and_token_free_tails(self):
        h = self.harness()
        setup = self.fake_setup()
        noise = "x" * 5000
        setup.RESULT.update(rc=1, honest_clean=False,
                            out=noise + "\nprobe said " + TOKEN + "\n",
                            err=noise + "\nTraceback ...\nAuthorization: Bearer " + TOKEN + "\n"
                                "ModuleNotFoundError: No module named 'claude_agent_sdk'\n")
        self.case.run(h)
        line = next(l for ok, l in h.checks if l.startswith("positive: an honest CLI"))
        self.assertIn("rc=1", line)
        self.assertIn("ModuleNotFoundError: No module named 'claude_agent_sdk'", line)
        self.assertNotIn(TOKEN[9:], line)
        self.assertIsNone(re.search(r"[0-9a-f]{6,}", line.split("rc=1", 1)[1]), line)
        self.assertLess(len(line), 2 * self.case.DIAG_MAX + 400, "bounded")


class Sanitize(NoSignals):
    HEX = TOKEN[9:]

    def assertTokenFree(self, out):
        self.assertNotIn(self.HEX, out)
        for i in range(0, len(self.HEX) - 5):
            self.assertNotIn(self.HEX[i:i + 6], out, "no 6 consecutive token hex characters survive")
        self.assertNotIn("zb-probe-", out)

    def test_every_form_of_the_token_is_redacted(self):
        forms = {
            "contiguous": f"token {TOKEN} end",
            "bearer": f"Authorization: Bearer {TOKEN}",
            "env": f"CLAUDE_CODE_OAUTH_TOKEN={self.HEX}",
            "wrapped into 6-hex pieces": "\n".join(self.HEX[i:i + 6] for i in range(0, 48, 6)),
            "hex-encoded": TOKEN.encode().hex(),
            "base64": base64.b64encode(TOKEN.encode()).decode(),
            "bytes": TOKEN.encode(),
            "straddling the tail cut": TOKEN + "y" * (self.case.DIAG_MAX - 30),  # the bound cuts inside it
        }
        for label, text in forms.items():
            with self.subTest(form=label):
                self.assertTokenFree(self.case._sanitize(text))

    def test_it_is_bounded_and_keeps_plain_diagnostics(self):
        out = self.case._sanitize("z" * 10000 + "\nModuleNotFoundError: No module named 'claude_agent_sdk'\n")
        self.assertLessEqual(len(out), self.case.DIAG_MAX)
        self.assertIn("ModuleNotFoundError: No module named 'claude_agent_sdk'", out)
        self.assertEqual(self.case._sanitize(None), "")


if __name__ == "__main__":
    unittest.main()
