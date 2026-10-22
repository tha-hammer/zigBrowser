"""WS5.5b-2 finding #3 — causal recording-seam model (UNREGISTERED). RoseCat f1e9653 item 2.

Drives the drawer multi-window LIFECYCLE and the owned-Job TEARDOWN through a recording Win32 seam and asserts
the behaviour CAUSALLY (executed, not read from source):
  - per-HWND registration (each full window becomes one live record);
  - partial-control cleanup that counts nothing (a failed panel/icon window is destroyed, never registered);
  - retire-once on WM_DESTROY (a second destroy of the same HWND does not decrement again);
  - the exact live-count transitions 0 -> peak N -> intermediate -> 0;
  - the teardown decision: a self-closing ('live') run waits FIRST (finite, positive), records NoKillNeeded and
    does NOT kill on WAIT_OBJECT_0, and kills only on a timeout/failure; a non-self-closing run kills first.

The production mirrors are the C++ spawn body + zb_drawer_retire_extra (whose retire-once semantics are also
driven directly in agent_drawer_props_test.zig) and the embedded runner's Teardown. The one bounded Win11 run
confirms them live. Every mutant below is a durable row.
"""
import unittest

WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
INFINITE = 0xFFFFFFFF


class WinSeam:
    """Records window-lifecycle and owned-Job teardown operations so the behaviour can be driven offline."""

    def __init__(self, wait_returns=WAIT_OBJECT_0):
        self.live = 0
        self.peak = 0
        self.records = []          # [{"hwnd":int, "live":bool}] — the per-HWND app-owned records
        self.ops = []              # ordered teardown Win32 calls: ("wait", ms) / ("terminate_job",) / ("final_reap",)
        self.no_kill_needed = False
        self._wait_returns = wait_returns
        self._next = 1000

    def create_window(self):
        self._next += 1
        return self._next

    def _inc(self):
        self.live += 1
        self.peak = max(self.peak, self.live)

    def register(self, hwnd):
        """A FULL window: push its per-HWND record and count it exactly once."""
        self.records.append({"hwnd": hwnd, "live": True})
        self._inc()

    def wnddestroy(self, hwnd):
        """The WndProc WM_DESTROY path, retire-once (mirrors zb_drawer_retire_extra): decrement only if the
        record is still live; a second destroy / unregistered HWND decrements nothing."""
        for r in self.records:
            if r["hwnd"] == hwnd and r["live"]:
                r["live"] = False
                self.live -= 1
                return True
        return False

    # --- the teardown Win32 recording seam ---
    def wait(self, ms):
        self.ops.append(("wait", ms))
        return self._wait_returns

    def terminate_job(self):
        self.ops.append(("terminate_job",))

    def final_reap(self):
        self.ops.append(("final_reap",))


def mount_primary(ws):
    ws.register(ws.create_window())            # the primary drawer: live 0 -> 1


def spawn_extras(ws, count, fail=None):
    """Mirrors spawn_extra_drawer_windows(app, count): per-HWND registration, with partial-control cleanup that
    counts nothing (the window is destroyed BEFORE any record exists)."""
    for _ in range(count):
        hwnd = ws.create_window()
        panel_ok = fail != "panel"
        icon_ok = fail != "icon"
        if not (panel_ok and icon_ok):
            ws.wnddestroy(hwnd)                # partial: never registered -> no count, no decrement
            continue
        ws.register(hwnd)


def close_one_extra(ws):
    """The close-one-early seam: destroy ONE still-live extra (not the primary) via its record HWND."""
    for r in ws.records[1:]:
        if r["live"]:
            ws.wnddestroy(r["hwnd"])
            return


def teardown_remaining(ws):
    for r in list(ws.records):
        if r["live"]:
            ws.wnddestroy(r["hwnd"])


class TeardownFailed(Exception):
    pass


def teardown(ws, expect_normal_exit, force_fail="none"):
    """The embedded runner's Teardown, driven through the recording seam (mirrors the C# Teardown)."""
    if expect_normal_exit:
        w = WAIT_TIMEOUT if force_fail == "wait_fail" else ws.wait(8000)   # wait FIRST, finite + positive
        if w == WAIT_OBJECT_0:
            ws.no_kill_needed = True
            return                                                         # no kill
        ws.terminate_job()
        ws.final_reap()
        raise TeardownFailed(w)
    # non-self-closing run: kill first (unchanged contract)
    ws.terminate_job()
    w = WAIT_TIMEOUT if force_fail == "wait_fail" else ws.wait(8000)
    if w != WAIT_OBJECT_0:
        ws.final_reap()
        raise TeardownFailed(w)


def clean_selfclose_ok(ws):
    """The self-closing teardown contract: exactly one op, a wait, finite + positive, NoKillNeeded, and NO kill."""
    return (len(ws.ops) == 1 and ws.ops[0][0] == "wait"
            and 0 < ws.ops[0][1] < INFINITE and ws.no_kill_needed is True)


class Ws55b2LifecycleSeamTest(unittest.TestCase):
    # --- live-count transitions (seam=2: primary + 1 extra) ---
    def test_peak_then_zero(self):
        ws = WinSeam()
        mount_primary(ws)
        spawn_extras(ws, 1)
        self.assertEqual((ws.live, ws.peak), (2, 2), "peak must equal the N concurrent windows")
        teardown_remaining(ws)
        self.assertEqual((ws.live, ws.peak), (0, 2), "final 0, peak preserved")

    def test_close_one_drops_by_exactly_one(self):
        ws = WinSeam()
        mount_primary(ws)
        spawn_extras(ws, 1)
        self.assertEqual(ws.live, 2)
        close_one_extra(ws)
        self.assertEqual(ws.live, 1, "closing one extra drops the live count by exactly one (intermediate)")
        self.assertEqual(ws.peak, 2, "the running peak is unaffected")
        teardown_remaining(ws)
        self.assertEqual(ws.live, 0)

    def test_partial_control_cleanup_counts_nothing(self):
        for fail in ("panel", "icon"):
            with self.subTest(fail=fail):
                ws = WinSeam()
                mount_primary(ws)
                spawn_extras(ws, 1, fail=fail)
                self.assertEqual((ws.live, ws.peak), (1, 1), f"{fail}-fail extra must count nothing (primary only)")
                teardown_remaining(ws)
                self.assertEqual(ws.live, 0)

    def test_retire_once_no_double_decrement(self):
        ws = WinSeam()
        mount_primary(ws)
        spawn_extras(ws, 2)
        self.assertEqual(ws.live, 3)
        hwnd = ws.records[1]["hwnd"]
        self.assertTrue(ws.wnddestroy(hwnd))
        self.assertEqual(ws.live, 2, "first destroy decrements once")
        self.assertFalse(ws.wnddestroy(hwnd), "a second destroy retires nothing")
        self.assertEqual(ws.live, 2, "retire-once: no double decrement")

    # --- lifecycle mutants (durable rows) ---
    def test_lifecycle_mutants_rejected(self):
        # MUTANT: a WndProc that decrements without the live guard => double-decrement on a second destroy
        ws = WinSeam()
        mount_primary(ws)
        spawn_extras(ws, 1)
        hwnd = ws.records[1]["hwnd"]

        def wnddestroy_no_guard(h):
            for r in ws.records:
                if r["hwnd"] == h:
                    ws.live -= 1
                    return
        wnddestroy_no_guard(hwnd)
        wnddestroy_no_guard(hwnd)
        self.assertEqual(ws.live, 0, "the no-guard mutant double-decrements (2 -> 0), which the real retire-once forbids")
        self.assertNotEqual(ws.live, 1, "the correct retire-once would hold at 1 here")

        # MUTANT: counting a partial window (register before the control check) => peak too high
        ws2 = WinSeam()
        mount_primary(ws2)
        hwnd2 = ws2.create_window()
        ws2.register(hwnd2)          # WRONG: counted before the panel/icon failure is handled
        self.assertEqual(ws2.peak, 2, "counting the partial window inflates the peak (the real code counts nothing)")

    # --- teardown recording seam ---
    def test_selfclose_waits_first_and_records_no_kill(self):
        ws = WinSeam(wait_returns=WAIT_OBJECT_0)
        teardown(ws, expect_normal_exit=True)
        self.assertEqual(ws.ops, [("wait", 8000)], "a clean self-close waits once and never kills")
        self.assertTrue(ws.no_kill_needed, "WAIT_OBJECT_0 must record NoKillNeeded")
        self.assertTrue(clean_selfclose_ok(ws))
        _, ms = ws.ops[0]
        self.assertTrue(0 < ms < INFINITE, "the wait must be finite and positive")

    def test_selfclose_timeout_kills_then_reaps_then_raises(self):
        ws = WinSeam(wait_returns=WAIT_TIMEOUT)
        with self.assertRaises(TeardownFailed):
            teardown(ws, expect_normal_exit=True)
        self.assertEqual(ws.ops, [("wait", 8000), ("terminate_job",), ("final_reap",)], "timeout -> kill + reap")
        self.assertFalse(ws.no_kill_needed, "a timeout is not a no-kill exit")

    def test_non_selfclose_kills_first(self):
        ws = WinSeam(wait_returns=WAIT_OBJECT_0)
        teardown(ws, expect_normal_exit=False)
        self.assertEqual(ws.ops, [("terminate_job",), ("wait", 8000)], "a non-self-closing run keeps kill-first")
        self.assertFalse(ws.no_kill_needed)

    # --- teardown mutants (durable rows) ---
    def test_teardown_mutants_rejected(self):
        # kill-first in the self-close branch
        def teardown_killfirst(ws):
            ws.terminate_job()
            if ws.wait(8000) == WAIT_OBJECT_0:
                ws.no_kill_needed = True
        ws = WinSeam(wait_returns=WAIT_OBJECT_0); teardown_killfirst(ws)
        self.assertFalse(clean_selfclose_ok(ws), "kill-first violates the self-close contract")

        # 0 ms wait (not positive)
        def teardown_zero(ws):
            if ws.wait(0) == WAIT_OBJECT_0:
                ws.no_kill_needed = True
        ws = WinSeam(wait_returns=WAIT_OBJECT_0); teardown_zero(ws)
        self.assertFalse(clean_selfclose_ok(ws), "a 0 ms wait is not a bounded positive wait")

        # unbounded (INFINITE) wait
        def teardown_inf(ws):
            if ws.wait(INFINITE) == WAIT_OBJECT_0:
                ws.no_kill_needed = True
        ws = WinSeam(wait_returns=WAIT_OBJECT_0); teardown_inf(ws)
        self.assertFalse(clean_selfclose_ok(ws), "an INFINITE wait is not finite")

        # WAIT_OBJECT_0 but NoKillNeeded never recorded
        def teardown_norecord(ws):
            ws.wait(8000)   # no no_kill_needed set
        ws = WinSeam(wait_returns=WAIT_OBJECT_0); teardown_norecord(ws)
        self.assertFalse(clean_selfclose_ok(ws), "a clean exit that does not record NoKillNeeded fails the contract")


if __name__ == "__main__":
    unittest.main()
