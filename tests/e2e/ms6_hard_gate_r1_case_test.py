"""The MS6.6 (B) hard-gate case's chain-release inspection, on Linux with fakes only (RoseCat 7306):
- _chain_alive classifies OUR processes from a canned `ps -axo pid=,uid=,stat=`: a process running the row's CLI, or a
  python whose argv (proc_darwin.environ_of gives list[bytes]) names one of the row's markers, is alive; a failed or
  unparsable ps is not inspected; a read that fails while the pid has not vanished is unreadable; other users' pids,
  our own pid and zombies are skipped (never read);
- _chain_release re-inspects after a non-clean first scan (a survivor, an unreadable pid, a failed ps) until a clean,
  empty scan or the row's self-exit horizon, and never only on `alive` (7306 #2).
No process is started and no signal is sent: h.spawn_group and proc_darwin are fakes, the clock is fake, and os.kill /
os.killpg are patched to raise.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_r1_case_test'
"""
import importlib.util
import os
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

    def test_other_users_our_own_pid_and_zombies_are_never_read(self):
        proc = FakeProc({})
        rows = [f"5 {ME + 1} S", f"{os.getpid()} {ME} S", f"6 {ME} Z+"]
        self.assertEqual(self.scan(rows, proc), (True, [], []))
        self.assertEqual(proc.reads, [])


class ChainRelease(NoSignals):
    def release(self, scans, started_at=0.0):
        """Feeds `scans` (the last one repeats); the clock only moves by the case's own sleeps."""
        now = [started_at]
        seen = []

        def scan():
            r = scans[min(len(seen), len(scans) - 1)]
            seen.append(now[0])
            return r

        def sleep(s):
            now[0] += s

        first, last = self.case._chain_release(scan, started_at, clock=lambda: now[0], sleep=sleep)
        return first, last, seen

    CLEAN = (True, [], [])
    SURVIVOR = (True, [(77, CLI)], [])
    UNREADABLE = (True, [], [(77, "path: denied")])
    NO_PS = (False, [], [])

    def test_a_clean_first_scan_ends_at_once(self):
        first, last, seen = self.release([self.CLEAN])
        self.assertEqual((first, last, len(seen)), (self.CLEAN, None, 1))

    def test_every_non_clean_first_scan_is_drained_to_a_clean_scan(self):
        for bad in (self.SURVIVOR, self.UNREADABLE, self.NO_PS):
            with self.subTest(first=bad):
                first, last, seen = self.release([bad] * 40 + [self.CLEAN])
                self.assertEqual(first, bad, "the first scan reports the failure")
                self.assertEqual(last, self.CLEAN, "re-inspected past the grace period until a clean, empty scan")
                self.assertGreater(seen[-1], self.case.CHAIN_GRACE_S)

    def test_the_drain_is_bounded_by_the_rows_horizon(self):
        first, last, seen = self.release([self.UNREADABLE], started_at=1000.0)
        self.assertEqual(last, self.UNREADABLE)
        self.assertLessEqual(seen[-1], 1000.0 + self.case.CHAIN_HORIZON_S)
        self.assertGreaterEqual(seen[-1], 1000.0 + self.case.CHAIN_HORIZON_S - 1)


if __name__ == "__main__":
    unittest.main()
