#!/usr/bin/env python3
r"""The ONE shared WebView2 run-folder cleanup (tests/windows/webview2_cleanup.py; NavyCanyon 6dd7fda), driven
hostless through the real helper and BOTH real callers: the WS2a session path (spike_driver.run_spike, which
removes %USERPROFILE%\zb\build\run-<sha>) and the m8 path (m8_live_test.run_on_host, which removes
%USERPROFILE%\zb\runs\<id>).

A fake VM answers every command the helper and the callers send (census, folder kind, rmdir, absence, marker,
mkdir, the m8 tests, schtasks). The run under test starts WebView2 helpers (msedgewebview2) that hold the folder:
while one is alive an rmdir leaves files behind, as on the real VM (WS2a.3a red 2264489). A fake monotonic clock
makes the 60 s deadline instant. Cases (6dd7fda):
  * immediate match: no helper outlives the run -> one rmdir, removed;
  * transient helpers then match: the helpers leave after a few census reads -> the helper waits, then exactly one
    rmdir, removed;
  * permanent survivor / timeout: a helper never leaves -> failure within the 60 s deadline, NO rmdir;
  * census failure: the census cannot be read at cleanup -> failure, NO rmdir;
  * deletion failure: the folder survives the one rmdir -> failure, no second rmdir.
cc8f0b0 R2 cases: a slow or stalled census probe cannot outlast the ONE 60 s deadline (every cleanup census gets only
the remaining budget as its timeout; a first probe that times out is a census failure); an unreadable start time
(`na`) deletes nothing;
`runs\.` and every other non-caller path shape are refused without contacting the host.
Dropping or bypassing the wait makes the transient, survivor and census-failure cases red.
649755f7 (the m8 1032dbb incident): a remaining-budget probe that expires at the deadline after a census that did
not match reports deadline exhaustion with the last survivor set (helper and both callers), never a generic
census failure, and deletes nothing; losing that diagnostic makes those cases red.

Run:  python3 -I tests/windows/webview2_cleanup_test.py   (registered: windows-webview2-cleanup-selftest)
"""
import contextlib
import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import m8_live_test  # noqa: E402
import spike_driver  # noqa: E402
import webview2_cleanup as wc  # noqa: E402

BASE = {("msedgewebview2", 6772, "638966399451927630"), ("msedgewebview2", 6988, "638966399472423174")}
HELPERS = {("msedgewebview2", 4244, "638967035511111111"), ("msedgewebview2", 5632, "638967035522222222")}
SURVIVORS = [f"('msedgewebview2', {pid}, '{ticks}')" for _, pid, ticks in sorted(HELPERS)]
MARKER = "zb-test-marker"


class CP:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


class FakeTime:
    def __init__(self):
        self.now = 1000.0

    def monotonic(self):
        return self.now

    def sleep(self, s):
        assert s >= 0
        self.now += s


class FakeVM:
    """linger: census reads the run's helpers survive (None = forever); census_fail_at: the census read (1-based)
    that fails; rm_fails: the folder survives rmdir even with no helper; clock + stall_at / slow_s: from that census
    read on, a probe never answers (or takes slow_s) and, like subprocess.run, uses up its timeout and raises
    TimeoutExpired (a probe with no timeout is an error); na_at: from that census read on, a helper's start time is
    unreadable (`na`)."""

    def __init__(self, linger=0, census_fail_at=None, rm_fails=False, clock=None, stall_at=None, slow_s=None,
                 na_at=None):
        self.linger, self.census_fail_at, self.rm_fails = linger, census_fail_at, rm_fails
        self.clock, self.stall_at, self.slow_s, self.na_at = clock, stall_at, slow_s, na_at
        self.census_timeouts = []
        self.census_calls = 0
        self.spawned_at = None  # census read count when the run started its helpers
        self.folders = set()
        self.rm_targets = []
        self.log = []

    def helpers_alive(self):
        if self.spawned_at is None:
            return False
        return self.linger is None or self.census_calls - self.spawned_at < self.linger

    def spawn(self):
        if self.spawned_at is None:
            self.spawned_at = self.census_calls

    def run(self, cmd, timeout=None):
        self.log.append(cmd)
        if cmd == wc.CENSUS_CMD:
            self.census_calls += 1
            self.census_timeouts.append(timeout)
            if self.census_fail_at is not None and self.census_calls >= self.census_fail_at:
                return CP(1, "", "Get-Process : Access is denied")
            takes = None
            if self.stall_at is not None and self.census_calls >= self.stall_at:
                takes = float("inf")
            elif self.slow_s is not None and self.census_calls >= 2:  # read 1 is the before-run census
                takes = self.slow_s
            if takes is not None:
                assert timeout is not None, "a census probe without a timeout"
                if takes > timeout:
                    self.clock.now += timeout
                    raise subprocess.TimeoutExpired(cmd, timeout)
                self.clock.now += takes
            procs = BASE | (HELPERS if self.helpers_alive() else set())
            na = self.na_at is not None and self.census_calls >= self.na_at
            return CP(0, "".join(f"{n}\t{p}\t{'na' if na and (n, p, t) in HELPERS else t}\r\n"
                                 for n, p, t in sorted(procs)) + "END\r\n")
        if cmd.startswith("powershell") and "Get-Item" in cmd:
            target = next((f for f in self.folders if f.split("\\")[-1] in cmd), None)
            return CP(0, "DIR\r\n" if target else "ABSENT\r\n")
        if cmd.startswith("rmdir /s /q "):
            target = cmd[len("rmdir /s /q "):].strip('"')
            self.rm_targets.append(target)
            if self.helpers_alive() or self.rm_fails:
                return CP(0, "", "lockfile - The process cannot access the file because it is being used by another process.")
            self.folders.discard(target)
            return CP(0)
        if cmd.startswith('if exist "'):
            target = cmd[len('if exist "'):].split('"')[0]
            return CP(0, "LEFT\r\n" if target in self.folders else "GONE\r\n")
        if cmd.startswith("type ") and ".gate-identity" in cmd:
            return CP(0, MARKER + "\r\n")
        if cmd.startswith('mkdir "'):
            self.folders.add(cmd[len('mkdir "'):].split('\\tmp"')[0])
            return CP(0)
        if " -E -s tests\\e2e\\" in cmd:  # an m8 test: the browser (and its WebView2 helpers) run in the folder
            self.spawn()
            return CP(0, "PASS\tm8\nASSERTS 3\n")
        if cmd.startswith("schtasks "):
            return CP(0, "")
        raise AssertionError(f"unexpected VM command: {cmd!r}")


class Case(unittest.TestCase):
    def setUp(self):
        self.clock = FakeTime()
        patcher = mock.patch.object(wc, "time", self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def assert_waited_then_one_rmdir(self, vm):
        rm_at = max(i for i, c in enumerate(vm.log) if c.startswith("rmdir "))
        last_census = max(i for i, c in enumerate(vm.log[:rm_at]) if c == wc.CENSUS_CMD)
        self.assertGreaterEqual(vm.census_calls - (vm.spawned_at or 0), vm.linger or 0, "the wait read the census until it matched")
        self.assertLess(last_census, rm_at)
        self.assertEqual(len(vm.rm_targets), 1, "exactly one rmdir")

    def assert_deadline_exhaustion(self, why, vm):
        self.assertIn("did not return to the pre-run identities", why)
        for s in SURVIVORS:
            self.assertIn(s, why, "the last known survivor set is reported")
        self.assertNotIn("census failed", why)
        self.assertEqual(vm.rm_targets, [], "nothing is deleted")


# ---- the helper itself ---------------------------------------------------------------------------------------
class Helper(Case):
    DIR = r"%USERPROFILE%\zb\build\run-" + "a" * 40

    def go(self, vm):
        before = wc.census(vm.run)
        vm.folders.add(self.DIR)
        vm.spawn()
        return wc.remove_after_webview2(vm.run, self.DIR, before)

    def test_immediate_match_removes_with_one_rmdir(self):
        vm = FakeVM(linger=0)
        ok, why = self.go(vm)
        self.assertTrue(ok, why)
        self.assertEqual(vm.rm_targets, [self.DIR])

    def test_transient_helpers_are_waited_for_then_one_rmdir(self):
        vm = FakeVM(linger=4)
        ok, why = self.go(vm)
        self.assertTrue(ok, why)
        self.assert_waited_then_one_rmdir(vm)
        self.assertNotIn(self.DIR, vm.folders)

    def test_permanent_survivor_times_out_without_rmdir(self):
        vm = FakeVM(linger=None)
        start = self.clock.now
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertIn("did not return to the pre-run identities", why)
        self.assertEqual(vm.rm_targets, [], "no rmdir while a helper survives")
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 0.001, "one total deadline of at most 60 s")

    def test_census_failure_fails_closed_without_rmdir(self):
        vm = FakeVM(linger=2, census_fail_at=2)
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertIn("census failed", why)
        self.assertEqual(vm.rm_targets, [])

    def test_deletion_failure_is_fatal_and_not_retried(self):
        vm = FakeVM(linger=0, rm_fails=True)
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertEqual(vm.rm_targets, [self.DIR], "exactly one rmdir, no retry")

    def test_stalled_probe_cannot_exceed_the_total_deadline(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)  # read 2 sees the survivors, read 3 never answers
        start = self.clock.now
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assert_deadline_exhaustion(why, vm)
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6, "a stalled probe outlasted the deadline")

    def test_a_first_probe_that_stalls_is_a_census_failure(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=2)  # no census succeeded: no survivor set to report
        start = self.clock.now
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertIn("census failed", why)
        self.assertEqual(vm.rm_targets, [])
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6)

    def test_slow_probes_share_the_one_total_deadline(self):
        vm = FakeVM(linger=None, clock=self.clock, slow_s=25.0)
        start = self.clock.now
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertEqual(vm.rm_targets, [])
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6, "slow probes outlasted the deadline")
        cleanup = vm.census_timeouts[1:]  # [0] is the before-run census
        self.assertTrue(all(t is not None and 0 < t <= wc.DEADLINE_S for t in cleanup), cleanup)
        self.assertLess(cleanup[-1], cleanup[0], "each census gets only the remaining budget")
        self.assert_deadline_exhaustion(why, vm)  # 25 s, 25 s, then the 10 s left run out

    def test_unreadable_start_time_deletes_nothing(self):
        vm = FakeVM(linger=2, na_at=2)
        ok, why = self.go(vm)
        self.assertFalse(ok)
        self.assertIn("unreadable start time", why)
        self.assertEqual(vm.rm_targets, [])

    def test_unreadable_start_time_is_not_an_identity(self):
        with self.assertRaises(wc.CensusError):
            wc.census(lambda cmd: CP(0, "msedgewebview2\t12\tna\r\nEND\r\n"))

    def test_unparsable_census_fails_closed(self):
        vm = FakeVM()
        with mock.patch.object(vm, "run", return_value=CP(0, "msedgewebview2\t12\r\n")):  # no END line
            with self.assertRaises(wc.CensusError):
                wc.census(vm.run)

    def test_refuses_paths_outside_the_run_folders(self):
        vm = FakeVM()
        for bad in (r"%USERPROFILE%\zb", r"C:\Windows\Temp\x", r"%USERPROFILE%\zb\runs\..\..\x", "",
                    r"%USERPROFILE%\zb\runs\.", r"%USERPROFILE%\zb\runs\..", r"%USERPROFILE%\zb\runs\x",
                    r"%USERPROFILE%\zb\runs\m8-1-abc", r"%USERPROFILE%\zb\runs\m8-1-aaaaaaaaaaaa\.",
                    r"%USERPROFILE%\zb\build\run-" + "a" * 39, r"%USERPROFILE%\zb\build\run-" + "a" * 40 + ".",
                    r"C:\Users\zbtext\zb\build\run-" + "a" * 40, r"%USERPROFILE%\zb\build\run-" + "A" * 40):
            with self.subTest(path=bad):
                ok, why = wc.remove_after_webview2(vm.run, bad, frozenset())
                self.assertFalse(ok)
                self.assertIn("refused", why)
        self.assertEqual(vm.log, [], "a refused path sends nothing")


# ---- caller 1: the WS2a session path (spike_driver.run_spike) -------------------------------------------------
class SpikeDriverCaller(Case):
    def go(self, vm):
        sha = "c0ffee" * 6 + "c0ff"  # what `git rev-parse` answers (faked: the gate may run from an export)
        target = rf"%USERPROFILE%\zb\build\run-{sha}"

        def fake_run(argv, **kw):
            if argv[0] == "ssh":
                r = vm.run(argv[-1], timeout=kw.get("timeout"))
                return subprocess.CompletedProcess(argv, r.returncode, r.stdout, r.stderr)
            if argv[0] == "git":
                return subprocess.CompletedProcess(argv, 0, sha + "\n", "")
            if argv[0] == "bash":  # build-on-windows.sh: stages the run folder, runs the spike (WebView2 starts)
                vm.folders.add(target)
                vm.spawn()
                return subprocess.CompletedProcess(argv, 0, "ok   the spike ran\n", "")
            raise AssertionError(f"unexpected argv {argv!r}")

        env = {"ZB_WIN11_HOST": "fake.invalid", "ZB_WIN11_MARKER": MARKER, "ZB_BUILD_COMMIT": "HEAD",
               # bd zigBrowser-ong.25: every selector explicit (subprocess.run is faked; nothing is contacted)
               "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext", "ZB_WIN11_KEY": "/nonexistent/key",
               "ZB_WIN11_KNOWN_HOSTS": "/nonexistent/known_hosts"}
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env), mock.patch.object(spike_driver.subprocess, "run", fake_run), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = spike_driver.run_spike("fake-step", ("the spike ran",), "fake-tag")
        return rc, target, out.getvalue() + err.getvalue()

    def test_immediate_match(self):
        vm = FakeVM(linger=0)
        rc, target, text = self.go(vm)
        self.assertEqual(rc, 0, text)
        self.assertEqual(vm.rm_targets, [target])

    def test_transient_helpers_then_match(self):
        vm = FakeVM(linger=4)
        rc, target, text = self.go(vm)
        self.assertEqual(rc, 0, text)
        self.assert_waited_then_one_rmdir(vm)
        self.assertEqual(vm.rm_targets, [target])

    def test_permanent_survivor_fails_the_run_without_rmdir(self):
        vm = FakeVM(linger=None)
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assertEqual(vm.rm_targets, [])
        self.assertIn("cleanup failed", text)

    def test_census_failure_fails_the_run_without_rmdir(self):
        vm = FakeVM(linger=3, census_fail_at=2)
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assertEqual(vm.rm_targets, [])

    def test_stalled_probe_cannot_exceed_the_total_deadline(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=2)
        start = self.clock.now
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assertEqual(vm.rm_targets, [])
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6, "the 300 s ssh probe timeout leaked")

    def test_a_probe_out_of_budget_after_a_nonmatching_census_reports_the_survivors(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assert_deadline_exhaustion(text, vm)

    def test_unreadable_start_time_deletes_nothing(self):
        vm = FakeVM(linger=2, na_at=2)
        rc, _, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assertEqual(vm.rm_targets, [])

    def test_deletion_failure_fails_the_run(self):
        vm = FakeVM(linger=0, rm_fails=True)
        rc, target, text = self.go(vm)
        self.assertEqual(rc, 1, text)
        self.assertEqual(vm.rm_targets, [target])


# ---- caller 2: the m8 path (m8_live_test.run_on_host) ---------------------------------------------------------
class M8Caller(Case):
    def go(self, vm):
        env = {"ZB_WIN11_HOST": "fake.invalid", "ZB_WIN11_MARKER": MARKER}
        with mock.patch.dict(os.environ, env):
            h = m8_live_test.Host("win11", "ZB_WIN11", "2222", "zbtext", "k", "kh", r"C:\Python314\python.exe")
        h.ssh = lambda command, timeout=120: vm.run(command, timeout=timeout)
        h.scp_into = lambda sources, rel: CP(0)
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as stage, mock.patch.dict(os.environ, env), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            ok, total = m8_live_test.run_on_host(h, pathlib.Path(stage))
        return ok, out.getvalue() + err.getvalue()

    def target(self, vm):
        return next(c[len("mkdir \""):].split("\\tmp\"")[0] for c in vm.log if c.startswith("mkdir "))

    def test_immediate_match(self):
        vm = FakeVM(linger=0)
        ok, text = self.go(vm)
        self.assertTrue(ok, text)
        self.assertEqual(vm.rm_targets, [self.target(vm)])

    def test_transient_helpers_then_match(self):
        vm = FakeVM(linger=4)
        ok, text = self.go(vm)
        self.assertTrue(ok, text)
        self.assert_waited_then_one_rmdir(vm)

    def test_permanent_survivor_fails_the_host_without_rmdir(self):
        vm = FakeVM(linger=None)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertEqual(vm.rm_targets, [])

    def test_census_failure_at_cleanup_fails_without_rmdir(self):
        vm = FakeVM(linger=3, census_fail_at=2)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertEqual(vm.rm_targets, [])

    def test_census_failure_before_the_run_fails_closed(self):
        vm = FakeVM(census_fail_at=1)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertFalse(any(c.startswith(("mkdir", "rmdir")) for c in vm.log), "nothing staged, nothing deleted")

    def test_stalled_probe_cannot_exceed_the_total_deadline(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=2)
        start = self.clock.now
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertEqual(vm.rm_targets, [])
        self.assertLessEqual(self.clock.now - start, wc.DEADLINE_S + 1e-6, "the 120 s ssh probe timeout leaked")

    def test_a_probe_out_of_budget_after_a_nonmatching_census_reports_the_survivors(self):
        vm = FakeVM(linger=None, clock=self.clock, stall_at=3)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assert_deadline_exhaustion(text, vm)

    def test_unreadable_start_time_deletes_nothing(self):
        vm = FakeVM(linger=2, na_at=2)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertEqual(vm.rm_targets, [])

    def test_deletion_failure_fails_the_host(self):
        vm = FakeVM(linger=0, rm_fails=True)
        ok, text = self.go(vm)
        self.assertFalse(ok, text)
        self.assertEqual(len(vm.rm_targets), 1)


if __name__ == "__main__":
    unittest.main()
