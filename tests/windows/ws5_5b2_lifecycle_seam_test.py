"""WS5.5b-2 finding #3 (registered gate step windows-drawer-lifecycle). RoseCat 2dcf84e / R3(d).

Two production-bound proofs; neither is a detached mirror:

1. TEARDOWN no-kill DECISION — a DRIVEN recording-seam model of the embedded C# runner Teardown, BOUND to the
   production _RUNNER bytes by a minimal tripwire (test_production_teardown_is_bound): a no-kill exit requires the
   leader to exit (WAIT_OBJECT_0 on a valid handle) AND the settled owned-Job census to be zero; anything else
   terminates + reaps + fails. The teardown lives in the C# harness, so a driven model + a source tripwire + the
   one bounded Win11 run is the R1/R3 shape.

2. LIVE-COUNT LIFECYCLE (per-HWND register, partial-control cleanup, retire-once WM_DESTROY, the live/peak
   transitions) is NOT modelled here anymore — it moved to the portable Zig layer (src/agent_drawer.zig:
   DrawerLive + drawerLiveInc/drawerLiveDec + retireExtraWindow) and is DRIVEN directly in
   tests/windows/agent_drawer_props_test.zig ("drawer live lifecycle ..."). Here we keep only a narrow CALL-SITE
   tripwire that the shim routes its live transitions through those Zig functions and keeps no C++ atomic counter,
   so the shim cannot drift from the driven Zig bytes.
"""
import os
import pathlib
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import win_drawer_test as _wd  # noqa: E402  # the production _RUNNER (C# Teardown) + extractors

WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
INFINITE = 0xFFFFFFFF
SHIM = (pathlib.Path(__file__).resolve().parents[2] / "src" / "webview2_shim.cpp").read_text(encoding="utf-8")


class TeardownSeam:
    """Records the owned-Job teardown's Win32 calls so the no-kill decision can be driven offline."""

    def __init__(self, wait_returns=WAIT_OBJECT_0, job_members=0):
        self.ops = []                    # ("wait", ms) / ("job_count",) / ("terminate_job",) / ("final_reap",)
        self.no_kill_needed = False
        self._wait_returns = wait_returns
        self.job_members = job_members   # the settled owned-Job member count after the leader's wait

    def wait(self, ms):
        self.ops.append(("wait", ms))
        return self._wait_returns

    def job_count(self):
        self.ops.append(("job_count",))  # the bounded, fail-closed settled owned-Job census
        return self.job_members

    def terminate_job(self):
        self.ops.append(("terminate_job",))

    def final_reap(self):
        self.ops.append(("final_reap",))


class TeardownFailed(Exception):
    pass


def teardown(ws, expect_normal_exit, force_fail="none", have_leader=True):
    """The embedded runner's Teardown decision, driven through the recording seam (mirrors the C# Teardown). A
    no-kill exit requires BOTH the leader to exit (WAIT_OBJECT_0 on a valid handle) AND the owned Job to have
    drained to zero (RoseCat 28d6f8d #1); a missing leader, a non-signal, or a nonzero count kills + reaps + fails."""
    if expect_normal_exit:
        w = WAIT_TIMEOUT if (force_fail == "wait_fail" or not have_leader) else ws.wait(8000)  # no leader => refuse
        members = ws.job_count() if w == WAIT_OBJECT_0 else -1   # bounded, fail-closed
        if w == WAIT_OBJECT_0 and members == 0:
            ws.no_kill_needed = True
            return                                              # leader exited AND no owned child survives
        ws.terminate_job()
        ws.final_reap()
        raise TeardownFailed((w, members))
    # non-self-closing run: kill first (unchanged contract)
    ws.terminate_job()
    w = WAIT_TIMEOUT if force_fail == "wait_fail" else ws.wait(8000)
    if w != WAIT_OBJECT_0:
        ws.final_reap()
        raise TeardownFailed(w)


def clean_selfclose_ok(ws):
    """The self-closing teardown contract: wait (finite + positive) THEN the owned-Job census, NoKillNeeded set,
    and NO TerminateJobObject."""
    return (ws.no_kill_needed is True
            and len(ws.ops) == 2
            and ws.ops[0][0] == "wait" and 0 < ws.ops[0][1] < INFINITE
            and ws.ops[1] == ("job_count",)
            and ("terminate_job",) not in ws.ops)


class Ws55b2TeardownSeamTest(unittest.TestCase):
    def test_selfclose_waits_then_counts_then_records_no_kill(self):
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0, job_members=0)
        teardown(ws, expect_normal_exit=True)
        self.assertEqual(ws.ops, [("wait", 8000), ("job_count",)], "a clean self-close waits, censuses, never kills")
        self.assertTrue(ws.no_kill_needed, "leader exit + zero owned members must record NoKillNeeded")
        self.assertTrue(clean_selfclose_ok(ws))
        self.assertTrue(0 < ws.ops[0][1] < INFINITE, "the wait must be finite and positive")

    def test_selfclose_child_survives_kills_not_no_kill(self):
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0, job_members=1)
        with self.assertRaises(TeardownFailed):
            teardown(ws, expect_normal_exit=True)
        self.assertEqual(ws.ops, [("wait", 8000), ("job_count",), ("terminate_job",), ("final_reap",)],
                         "a surviving owned child takes wait -> census -> kill -> reap")
        self.assertFalse(ws.no_kill_needed, "a surviving owned child is not a no-kill exit")

    def test_selfclose_no_leader_handle_refuses(self):
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0, job_members=0)
        with self.assertRaises(TeardownFailed):
            teardown(ws, expect_normal_exit=True, have_leader=False)
        self.assertEqual(ws.ops, [("terminate_job",), ("final_reap",)], "no leader -> refuse, no wait/census")
        self.assertFalse(ws.no_kill_needed)

    def test_selfclose_timeout_kills_then_reaps_then_raises(self):
        ws = TeardownSeam(wait_returns=WAIT_TIMEOUT)
        with self.assertRaises(TeardownFailed):
            teardown(ws, expect_normal_exit=True)
        self.assertEqual(ws.ops, [("wait", 8000), ("terminate_job",), ("final_reap",)],
                         "timeout -> kill + reap (no census on a non-signal)")
        self.assertFalse(ws.no_kill_needed)

    def test_non_selfclose_kills_first(self):
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0)
        teardown(ws, expect_normal_exit=False)
        self.assertEqual(ws.ops, [("terminate_job",), ("wait", 8000)], "a non-self-closing run keeps kill-first")
        self.assertFalse(ws.no_kill_needed)

    def test_teardown_mutants_rejected(self):
        def teardown_killfirst(ws):
            ws.terminate_job()
            if ws.wait(8000) == WAIT_OBJECT_0:
                ws.no_kill_needed = True
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0); teardown_killfirst(ws)
        self.assertFalse(clean_selfclose_ok(ws), "kill-first violates the self-close contract")

        def teardown_zero(ws):
            if ws.wait(0) == WAIT_OBJECT_0:
                ws.job_count(); ws.no_kill_needed = True
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0); teardown_zero(ws)
        self.assertFalse(clean_selfclose_ok(ws), "a 0 ms wait is not a bounded positive wait")

        def teardown_inf(ws):
            if ws.wait(INFINITE) == WAIT_OBJECT_0:
                ws.job_count(); ws.no_kill_needed = True
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0); teardown_inf(ws)
        self.assertFalse(clean_selfclose_ok(ws), "an INFINITE wait is not finite")

        def teardown_norecord(ws):
            ws.wait(8000); ws.job_count()   # no no_kill_needed set
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0); teardown_norecord(ws)
        self.assertFalse(clean_selfclose_ok(ws), "a clean exit that does not record NoKillNeeded fails the contract")

        def teardown_ignore_members(ws):
            if ws.wait(8000) == WAIT_OBJECT_0:
                ws.no_kill_needed = True   # MUTANT: never calls job_count()
        ws = TeardownSeam(wait_returns=WAIT_OBJECT_0, job_members=1); teardown_ignore_members(ws)
        self.assertFalse(clean_selfclose_ok(ws), "claiming NoKillNeeded without the owned-Job census must fail")

    def test_production_teardown_is_bound(self):
        # Bind the model to PRODUCTION bytes (R2 minimal tripwire): the real C# Teardown's self-close branch waits
        # for the leader, then gates NoKillNeeded behind the SETTLED owned-Job census == 0. Runtime: the Win11 run.
        td = re.sub(r"\s+", "", _wd.strip_cpp(_wd.extract_csharp_method(_wd._RUNNER, "Teardown")))
        self.assertIn("if(ExpectNormalExit)", td, "the self-close branch must exist")
        self.assertIn("WaitForSingleObject(_hProc,8000)", td, "it must wait for the leader first")
        self.assertIn("JobProcessCountSettled(3000,100)", td, "it must census the owned Job (bounded, settled)")
        self.assertIn("w==WAIT_OBJECT_0&&members==0", td, "NoKillNeeded is gated behind leader-exit AND zero members")
        self.assertIn("NoKillNeeded=true", td, "it must record NoKillNeeded on the clean path")


class Ws55b2ShimLiveWiringTest(unittest.TestCase):
    """Narrow call-site tripwire (no parser): the shim routes its live-count transitions through the portable Zig
    counter whose behaviour is DRIVEN in agent_drawer_props_test.zig, and keeps no C++ atomic counter of its own."""

    def setUp(self):
        self.s = re.sub(r"\s+", "", _wd.strip_cpp(SHIM))

    def test_shim_live_count_is_bound_to_the_zig_counter(self):
        self.assertIn("staticDrawerLiveg_drawer_live_state", self.s, "the live state is the portable DrawerLive struct")
        self.assertIn("zb_drawer_live_inc(&g_drawer_live_state)", self.s, "a full drawer registers via the Zig inc")
        self.assertIn("zb_drawer_live_dec(&g_drawer_live_state)", self.s, "a retired window decs via the Zig dec")
        self.assertIn("zb_drawer_retire_extra(", self.s, "WM_DESTROY retires-once via the Zig helper (gates the dec)")

    def test_shim_keeps_no_cpp_atomic_live_counter(self):
        # the old C++ atomic counting must be gone, so the shim cannot drift from the driven Zig transitions
        self.assertNotIn("g_drawer_live.fetch", self.s, "no C++ atomic fetch_add/sub live counting may remain")
        self.assertNotIn("g_drawer_live_peak", self.s, "no C++ atomic peak counter may remain")


if __name__ == "__main__":
    unittest.main()
