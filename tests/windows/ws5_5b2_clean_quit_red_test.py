"""WS5.5b-2 terminal-live-row fix RED (UNREGISTERED). RoseCat 4124a1b — EXTRACT-AND-BIND, not global substrings.

Binds the corrected clean-close contract to REAL extracted code with ordering + mutants:
1. The shim's create_controller branch: a successful e2e/drawer/WINDOWS gate, spawn_extra_drawer_windows(app),
   then EXACTLY ONE PostMessageW(app->hwnd, WM_CLOSE, 0, 0) after it. Mutants (lexer-stripped): comment decoy,
   wrong gate, close-before-spawn, extra-WndProc close (not the primary), bare PostQuitMessage.
2. Each of the four WINDOWS-seam methods (base peak, close-one, panel-fail, icon-fail) has EXACTLY ONE
   ZB_SETTLE_KINDS=live.
3. The runner Teardown: a BOUNDED WaitForSingleObject BEFORE the Job kill, recording NoKillNeeded on a normal
   exit; the Job kill is the backstop. Mutants: kill-first, unbounded (INFINITE), false-status.

Red now: create_controller has no primary close, the four methods don't settle on `live`, and Teardown
kills first with no NoKillNeeded.
"""
import pathlib
import re
import unittest

import win_drawer_test as wd  # extract_cpp_function, strip_cpp, extract_csharp_method, _RUNNER

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHIM = (ROOT / "src" / "webview2_shim.cpp").read_text(encoding="utf-8")
BEH = (ROOT / "tests" / "windows" / "win_drawer_behaviors_test.py").read_text(encoding="utf-8")

CLOSE = "PostMessageW(app->hwnd, WM_CLOSE, 0, 0)"
GATE = "app->e2e_protocol && app->agent_drawer_on && app->windows_seam_set"


def controller_ok(body):
    b = " ".join(wd.strip_cpp(body).split())
    if "spawn_extra_drawer_windows(app)" not in b or b.count(CLOSE) != 1 or GATE not in b:
        return False
    return b.index("spawn_extra_drawer_windows(app)") < b.index(CLOSE)  # spawn first, close second


def _py_method(src, name):
    m = re.search(r"\n    def " + re.escape(name) + r"\(self\):", src)
    assert m, f"method {name} not found"
    start = m.start() + 1
    nxt = re.search(r"\n    def ", src[start + 1:])
    return src[start:(start + 1 + nxt.start()) if nxt else len(src)]


def teardown_ok(body):
    td = " ".join(wd.strip_cpp(body).split())
    if "WaitForSingleObject" not in td or "TerminateJobObject" not in td or "NoKillNeeded" not in td:
        return False
    if "INFINITE" in td:  # the normal wait must be bounded
        return False
    return td.index("WaitForSingleObject") < td.index("TerminateJobObject")  # wait BEFORE the kill


class Ws55b2CleanCloseRed(unittest.TestCase):
    def test_controller_branch_spawns_then_closes_the_primary(self):
        cc = wd.extract_cpp_function(SHIM, "create_controller")
        self.assertTrue(controller_ok(cc), "create_controller must gate, spawn, then post exactly one WM_CLOSE to the primary")
        # causal mutants (synthetic), proving the predicate is not vacuous
        good = (f"if ({GATE}) {{ spawn_extra_drawer_windows(app); {CLOSE}; }}")
        self.assertTrue(controller_ok(good))
        self.assertFalse(controller_ok(f"if ({GATE}) {{ spawn_extra_drawer_windows(app); /* {CLOSE}; */ }}"), "comment decoy")
        self.assertFalse(controller_ok(f"if (app->screenshot) {{ spawn_extra_drawer_windows(app); {CLOSE}; }}"), "wrong gate")
        self.assertFalse(controller_ok(f"if ({GATE}) {{ {CLOSE}; spawn_extra_drawer_windows(app); }}"), "close before spawn")
        self.assertFalse(controller_ok(f"if ({GATE}) {{ spawn_extra_drawer_windows(app); PostMessageW(extra, WM_CLOSE, 0, 0); }}"), "extra-WndProc close, not the primary")
        self.assertFalse(controller_ok(f"if ({GATE}) {{ spawn_extra_drawer_windows(app); PostQuitMessage(0); }}"), "bare PostQuitMessage")

    def test_each_windows_seam_method_settles_on_live(self):
        for name in ("test_ws5_5_live_count_peak_then_zero",
                     "test_ws5_5b2_closing_one_extra_drops_the_live_count_by_exactly_one",
                     "test_ws5_5b2_extra_fail_panel_drives_partial_cleanup",
                     "test_ws5_5b2_extra_fail_icon_drives_partial_cleanup"):
            body = _py_method(BEH, name)
            self.assertEqual(body.count('ZB_SETTLE_KINDS="live"'), 1, f"{name} must set exactly one ZB_SETTLE_KINDS=live")

    def test_teardown_waits_normally_before_the_job_kill(self):
        td = wd.extract_csharp_method(wd._RUNNER, "Teardown")
        self.assertTrue(teardown_ok(td), "Teardown must bounded-wait for a normal exit before the Job kill and record NoKillNeeded")
        # causal mutants (synthetic)
        self.assertTrue(teardown_ok("uint w = WaitForSingleObject(_hProc, 8000); if (w==0) NoKillNeeded=true; else TerminateJobObject(Job,1);"))
        self.assertFalse(teardown_ok("TerminateJobObject(Job,1); uint w = WaitForSingleObject(_hProc, 8000); NoKillNeeded=true;"), "kill-first")
        self.assertFalse(teardown_ok("uint w = WaitForSingleObject(_hProc, INFINITE); if (w==0) NoKillNeeded=true; else TerminateJobObject(Job,1);"), "unbounded")
        self.assertFalse(teardown_ok("uint w = WaitForSingleObject(_hProc, 8000); if (w==0) TerminateJobObject(Job,1);"), "false status / no NoKillNeeded")


if __name__ == "__main__":
    unittest.main()
