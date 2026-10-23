#!/usr/bin/env python3
"""WS2a.3 (Windows plan rev 2.21, NavyCanyon c36ba6a R2): the WS2a.3 debug seams are compiled ONLY into the
ws2a3-async-ownership-win slice executable, never into the WebView2 product build.

The seams (WS2a.3d: zb_automation_debug_abandon_at_start; WS2a.3a: zb_automation_debug_complete_hold_ms, _live_jobs; WS2a.3b: _step_hold_ms, _waiter_grace,
_late_dispatches, _strings_live) and their hot-path instrumentation (the completion hold in job_complete, the
live-job counter in job_submit / job_release, the step hold and late-dispatch count in cdp_job_call, the waiter
grace in job_submit, the string count in dup_c / zb_automation_free) sit under
`#ifdef ZB_WS2A3_SEAMS` in src/webview2_shim.cpp, and build.zig defines ZB_WS2A3_SEAMS on that one module.

Hostless: the real compiler preprocesses the real shim for x86_64-windows-gnu twice, as the product build sees it
(no define) and as the slice build sees it (-DZB_WS2A3_SEAMS=1). The WebView2 SDK and WRL headers are not on
Linux, so they are empty stand-ins here (preprocessing needs no types); windows.h and the rest are zig's. Only the
lines the preprocessor attributes to webview2_shim.cpp itself are read (webkit_shim.h declares
zb_automation_debug_live_jobs for the GTK build; a declaration is not a definition). Then:
  * product: none of the seam definitions or instrumentation is present, and production code is (non-vacuous);
  * slice: every seam definition and every instrumentation site is present;
  * build.zig: ZB_WS2A3_SEAMS is defined exactly once, on ws2a3_module.

Run:  python3 -I tests/windows/ws2a3_seam_gating_test.py [--zig <zig>]   (registered: windows-ws2a3-seam-gating)
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SHIM = REPO / "src" / "webview2_shim.cpp"
BUILD = REPO / "build.zig"
STAND_INS = ("wrl.h", "WebView2.h", "WebView2EnvironmentOptions.h")

ZIG = "zig"
if "--zig" in sys.argv:
    i = sys.argv.index("--zig")
    ZIG = sys.argv[i + 1]
    del sys.argv[i:i + 2]

# What the slice must have and the product must not, as the preprocessed shim reads.
SEAMS = {
    "hold seam export": r'extern\s+"C"\s+void\s+zb_automation_debug_complete_hold_ms\s*\(',
    "live-jobs seam export": r'extern\s+"C"\s+int\s+zb_automation_debug_live_jobs\s*\(',
    "hold seam state": r"volatile\s+LONG\s+g_debug_complete_hold_ms\b",
    "live-jobs state": r"volatile\s+LONG\s+g_live_jobs\b",
    "completion hold in job_complete": r"InterlockedCompareExchange\s*\(\s*&g_debug_complete_hold_ms",
    "live-job count on allocation": r"InterlockedIncrement\s*\(\s*&g_live_jobs\s*\)",
    "live-job count on release": r"InterlockedDecrement\s*\(\s*&g_live_jobs\s*\)",
    # WS2a.3b
    "step-hold seam export": r'extern\s+"C"\s+void\s+zb_automation_debug_step_hold_ms\s*\(',
    "waiter-grace seam export": r'extern\s+"C"\s+void\s+zb_automation_debug_waiter_grace\s*\(',
    "late-dispatches seam export": r'extern\s+"C"\s+int\s+zb_automation_debug_late_dispatches\s*\(',
    "strings-live seam export": r'extern\s+"C"\s+int\s+zb_automation_debug_strings_live\s*\(',
    "step-hold state": r"volatile\s+LONG\s+g_debug_step_hold_ms\b",
    "waiter-grace state": r"volatile\s+LONG\s+g_debug_waiter_grace_ms\b",
    "late-dispatches state": r"volatile\s+LONG\s+g_late_dispatches\b",
    "strings-live state": r"volatile\s+LONG\s+g_strings_live\b",
    "step hold in cdp_job_call": r"InterlockedCompareExchange\s*\(\s*&g_debug_step_hold_ms",
    "waiter grace in job_submit": r"InterlockedCompareExchange\s*\(\s*&g_debug_waiter_grace_ms",
    "late-dispatch count in cdp_job_call": r"InterlockedIncrement\s*\(\s*&g_late_dispatches\s*\)",
    "string count in dup_c": r"InterlockedIncrement\s*\(\s*&g_strings_live\s*\)",
    "string count in zb_automation_free": r"InterlockedDecrement\s*\(\s*&g_strings_live\s*\)",
    # WS2a.3d
    "abandon-at-start seam export": r'extern\s+"C"\s+void\s+zb_automation_debug_abandon_at_start\s*\(',
    "abandon-at-start state": r"volatile\s+LONG\s+g_debug_abandon_at_start\b",
    "abandoned handling deferred in WM_ZB_ABANDONED":
        r"case\s+WM_ZB_ABANDONED\s*:\s*if\s*\(\s*_?InterlockedCompareExchange\s*\(\s*&g_debug_abandon_at_start",
    "abandoned handling at NavigationStarting":
        r"&g_debug_abandon_at_start\s*,\s*0\s*,\s*0\s*\)\s*!=\s*0\s*\)\s*\{\s*stop_abandoned\s*\(\s*app\s*\)",
}
PRODUCTION = (r"\bzb_automation_eval_json\b", r"\bjob_submit\b", r"\bkWaiterGraceMs\b")


def shim_lines(defines):
    """The preprocessed lines that come from webview2_shim.cpp itself."""
    with tempfile.TemporaryDirectory(prefix="zb-ws2a3-gate-") as stub:
        for name in STAND_INS:
            pathlib.Path(stub, name).write_text("/* stand-in: the SDK is not on Linux; preprocessing needs no types */\n")
        cmd = [ZIG, "c++", "-target", "x86_64-windows-gnu", "-std=c++17", "-E", "-I", stub, "-I", str(REPO / "src"),
               *defines, str(SHIM)]
        proc = subprocess.run(cmd, cwd=stub, capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise AssertionError(f"preprocessing failed ({' '.join(cmd)}):\n{proc.stderr[-3000:]}")
    keep, out = False, []
    marker = re.compile(r'^# \d+ "([^"]*)"')
    for line in proc.stdout.splitlines():
        m = marker.match(line)
        if m:
            keep = pathlib.Path(m.group(1)).name == SHIM.name
            continue
        if keep:
            out.append(line)
    return "\n".join(out)


class SeamGating(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.product = shim_lines([])
        cls.slice = shim_lines(["-DZB_WS2A3_SEAMS=1"])

    def test_product_build_reads_production_code(self):
        for pattern in PRODUCTION:
            with self.subTest(pattern=pattern):
                self.assertRegex(self.product, pattern, "the product preprocess read no production code (vacuous)")

    def test_product_build_omits_every_seam_and_its_instrumentation(self):
        for what, pattern in SEAMS.items():
            with self.subTest(what=what):
                self.assertIsNone(re.search(pattern, self.product), f"{what} is compiled into the product build")

    def test_slice_build_has_every_seam_and_its_instrumentation(self):
        for what, pattern in SEAMS.items():
            with self.subTest(what=what):
                self.assertRegex(self.slice, pattern, f"{what} is missing from the slice build")

    def test_build_defines_the_seams_on_the_slice_module_only(self):
        text = BUILD.read_text()
        self.assertEqual(len(re.findall(r'"ZB_WS2A3_SEAMS"', text)), 1, "ZB_WS2A3_SEAMS must be defined exactly once")
        self.assertRegex(text, r'\bws2a3_module\.addCMacro\(\s*"ZB_WS2A3_SEAMS"', "it must be set on ws2a3_module")


if __name__ == "__main__":
    unittest.main()
